import Foundation

/// Identifies one read of the evidence registry.
///
/// A source's rows are keyed by the snapshot revision the listing says the
/// file is at, which is the pairing #151 asks for: the rows a mapping run
/// could cite are the rows of the snapshot the run read, and a rescan that
/// moves the revision moves the key, so a stale set cannot be served under a
/// new one. The revision is `Int` because FormaCore's own row and manifest
/// fields are `Int`; a listing's `Int64` is converted by the caller.
public struct EvidenceCacheKey: Hashable, Sendable {
    public let sourceID: UUID
    public let snapshotRevision: Int

    public init(sourceID: UUID, snapshotRevision: Int) {
        self.sourceID = sourceID
        self.snapshotRevision = snapshotRevision
    }
}

/// Proof that a read was claimed against a specific generation of one source.
///
/// The epoch is the race guard. A capture or a correction that lands while a
/// read is in flight bumps the source's epoch, and the read's rows are then
/// known to be at least one write behind - which is exactly the case the old
/// code documented when it refused to cache anything at all. Returning the
/// ticket through `publish` makes the guard impossible to forget, because the
/// only way to store rows is to hand back the ticket `claim` gave out.
public struct EvidenceReadTicket: Hashable, Sendable {
    public let key: EvidenceCacheKey
    let epoch: Int

    init(key: EvidenceCacheKey, epoch: Int) {
        self.key = key
        self.epoch = epoch
    }
}

public enum EvidenceReadClaim: Sendable {
    /// The rows for this key are already held; publish nothing.
    case cached([EvidenceRecord])
    /// Another read for this exact key is in flight; doing a second one would
    /// be the "duplicate work" #151 lists as a failure.
    case coalesced
    /// Go and read the registry, then publish through the ticket.
    case read(EvidenceReadTicket)
}

/// The (source, snapshot revision) -> rows cache behind `loadEvidence`.
///
/// Why the cache is allowed at all, against the comment it replaces: the old
/// `loadEvidence` re-read the registry on every appearance and said a
/// "already loaded" marker "would be a cache with no invalidation". The
/// invalidation is now explicit and is the only place rows can go stale -
/// capture, correction, bundle load and a changed selection each call
/// `invalidate` - and every removal also bumps the source's epoch, so a read
/// that was already in flight when the invalidation landed is dropped instead
/// of published. The counters (`hits`, `coalesced`, `stale`) are what the
/// tests and the signposts read; `EvidenceCacheTests` pins each transition.
public struct EvidenceCache: Sendable {
    public private(set) var hits: Int = 0
    public private(set) var misses: Int = 0
    public private(set) var coalesced: Int = 0
    public private(set) var stale: Int = 0
    public private(set) var invalidations: Int = 0

    private var rowsByKey: [EvidenceCacheKey: [EvidenceRecord]] = [:]
    private var inFlight: Set<EvidenceCacheKey> = []
    private var epochBySource: [UUID: Int] = [:]

    public init() {}

    /// The rows currently held for a key, without touching the counters.
    public func rows(for key: EvidenceCacheKey) -> [EvidenceRecord]? { rowsByKey[key] }

    public var storedKeys: Int { rowsByKey.count }
    public var pendingReads: Int { inFlight.count }

    /// Decides whether one appearance has to read the registry.
    ///
    /// Claiming marks the key in flight, so two callers that appear at once -
    /// the shell's `.task(id:)` and a correction sheet opened from the same
    /// file - cannot both start a read and then publish the same rows twice.
    public mutating func claim(_ key: EvidenceCacheKey) -> EvidenceReadClaim {
        if let rows = rowsByKey[key] {
            hits += 1
            return .cached(rows)
        }
        if inFlight.contains(key) {
            coalesced += 1
            return .coalesced
        }
        misses += 1
        inFlight.insert(key)
        return .read(EvidenceReadTicket(key: key, epoch: epochBySource[key.sourceID] ?? 0))
    }

    /// Stores a read's rows, or refuses them.
    ///
    /// Returns false when the source was invalidated after the claim: the
    /// caller must still merge nothing, because what it read may no longer be
    /// what the registry holds. Either way the key stops being in flight, so a
    /// later appearance can try again.
    @discardableResult
    public mutating func publish(_ rows: [EvidenceRecord], against ticket: EvidenceReadTicket) -> Bool {
        inFlight.remove(ticket.key)
        guard (epochBySource[ticket.key.sourceID] ?? 0) == ticket.epoch else {
            stale += 1
            return false
        }
        rowsByKey[ticket.key] = rows
        return true
    }

    /// Gives up a claimed read after the registry call threw.
    ///
    /// A failed read must not leave the key in flight forever, and it must not
    /// be stored: an error is not a set of rows.
    public mutating func abandon(_ ticket: EvidenceReadTicket) {
        inFlight.remove(ticket.key)
    }

    /// Drops everything known about one source.
    ///
    /// Called wherever FormaCore may have written rows for it: an evidence
    /// capture, an accepted correction, a re-read of the file.
    public mutating func invalidate(sourceID: UUID) {
        epochBySource[sourceID, default: 0] += 1
        let held = rowsByKey.keys.filter { $0.sourceID == sourceID }.count
            + inFlight.filter { $0.sourceID == sourceID }.count
        rowsByKey = rowsByKey.filter { $0.key.sourceID != sourceID }
        inFlight = inFlight.filter { $0.sourceID != sourceID }
        if held > 0 { invalidations += 1 }
    }

    /// Drops the whole cache: the listing that supplied the keys is gone (a
    /// scope or profile switch), so every revision in it may be resolvable to
    /// different rows.
    public mutating func invalidateAll() {
        for sourceID in epochBySource.keys { epochBySource[sourceID, default: 0] += 1 }
        if !rowsByKey.isEmpty || !inFlight.isEmpty { invalidations += 1 }
        rowsByKey.removeAll()
        inFlight.removeAll()
    }
}

/// Decides whether a per-file progress publish is worth a model-wide
/// invalidation.
///
/// The capture loop inside one mapping run writes `phase` once per file. That
/// is correct for six files - which is the case the owner's failure names - and
/// it is one whole-shell invalidation per file for a listing of a thousand,
/// where the label's own text ("Registering evidence 412 of 1000") cannot be
/// read between two frames anyway. This coalesces by *count*, not by time: the
/// decision is a pure function of (index, total), so a CI run with a synthetic
/// fixture produces the same publish count as the Mac does, which a wall-clock
/// throttle never would. The first and the last file always publish, so nobody
/// watches a bar that appears stuck at zero or finishes short.
public struct CaptureProgressCoalescing: Sendable {
    /// How many publishes a run aims for at most, whatever the file count.
    public let maximumPublishes: Int

    public init(maximumPublishes: Int = 20) {
        self.maximumPublishes = max(1, maximumPublishes)
    }

    /// Call once per file, before publishing. Small runs publish per file.
    public func shouldPublish(index: Int, total: Int) -> Bool {
        guard total > 0, index >= 0, index < total else { return false }
        // At or below the budget every file is its own step: six files stay
        // six publishes, and the semantics of the label are untouched.
        guard total > maximumPublishes else { return true }
        if index == 0 || index == total - 1 { return true }
        let stride = (total + maximumPublishes - 1) / maximumPublishes
        return index % stride == 0
    }
}

/// Decides whether a second reload may start now, or must be re-run later.
///
/// `restore()` already suppresses the reloads its own assignments would
/// schedule; the case left open is a person changing scope and profile in
/// quick succession, which starts two overlapping reloads, each reading the
/// listing, context and manifest and each publishing on return - the
/// "duplicate work" and per-completion publish the audit names. The first call
/// runs; a call that arrives while it is running is remembered as one pending
/// pass, because what matters is the selection at the end, not every selection
/// that was passed through. It is a *coalescer*, not a debounce: nothing is
/// dropped, and the pass that runs afterwards sees the current state.
public struct ReloadCoalescing: Sendable {
    public private(set) var isRunning = false
    public private(set) var pending = false
    public private(set) var started = 0
    public private(set) var coalesced = 0

    public init() {}

    /// True when the caller must run the reload itself right now.
    public mutating func request() -> Bool {
        guard isRunning else {
            isRunning = true
            started += 1
            return true
        }
        pending = true
        coalesced += 1
        return false
    }

    /// Called when a pass finishes. True means the selection moved while the
    /// pass was running and another pass is owed.
    public mutating func complete() -> Bool {
        guard pending else {
            isRunning = false
            return false
        }
        pending = false
        started += 1
        return true
    }

    /// Called when the running pass was cancelled rather than completed.
    ///
    /// `cancelAll()` stops work on request, so a pass owed by a selection
    /// change made before the cancel must not run afterwards: the person asked
    /// for the work to stop, and restarting it from a queue would be a
    /// reload nobody asked for. This forgets the pending pass and leaves the
    /// coalescer idle, so the next genuine change starts a pass as usual.
    public mutating func cancel() {
        isRunning = false
        pending = false
    }
}
