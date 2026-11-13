import Foundation

/// One writer, one lease, one reservation per record.
///
/// PLAN §10.2 asks for "单个 Executor actor + SQLite 意图事务串行协调全部写操作".
/// The actor is this type; the SQLite half is the lease row in `import_leases`,
/// which is what stops a second process sharing the same database file from
/// believing it is the writer too.
///
/// A lease is not a distributed lock and this file does not pretend otherwise:
/// it says "this process may write", and the readback in the next phase is what
/// decides whether a write actually happened.
public actor ImportSingleWriter {
    private let ledger: ImportLedger
    public let owner: String
    private let leaseDuration: TimeInterval
    private let clock: @Sendable () -> Date
    private var holdsLease = false
    private var reservations: Set<String> = []

    public init(ledger: ImportLedger, owner: String = UUID().uuidString,
                leaseDuration: TimeInterval = 300,
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.ledger = ledger
        self.owner = owner
        self.leaseDuration = leaseDuration
        self.clock = clock
    }

    /// Takes the writer lease. False means another live owner holds it.
    @discardableResult
    public func acquire() throws -> Bool {
        guard !holdsLease else { return true }
        let acquired = try ledger.acquireLease(owner: owner, at: clock(), duration: leaseDuration)
        holdsLease = acquired
        return acquired
    }

    /// Releases the lease and every reservation. Safe to call more than once, so
    /// a cancellation path can always clean up.
    public func release() throws {
        reservations.removeAll()
        guard holdsLease else { return }
        holdsLease = false
        try ledger.releaseLease(owner: owner)
    }

    public var isWriter: Bool { holdsLease }

    /// Reserves the mutual-exclusion keys of one operation.
    ///
    /// Returns false when any key is already reserved by an operation in flight;
    /// the caller waits or defers rather than writing concurrently. Keys are the
    /// source and the target record/group, so two different files aimed at the
    /// same record cannot both proceed.
    public func reserve(_ keys: [String]) -> Bool {
        guard holdsLease else { return false }
        let wanted = Set(keys)
        guard reservations.isDisjoint(with: wanted) else { return false }
        reservations.formUnion(wanted)
        return true
    }

    public func releaseReservation(_ keys: [String]) {
        reservations.subtract(keys)
    }

    public func reservedKeys() -> [String] {
        reservations.sorted()
    }

    /// Runs `body` under the lease and the reservations, releasing both on every
    /// exit path — including a thrown `CancellationError`.
    public func withWriter<T: Sendable>(keys: [String],
                                        _ body: @Sendable (ImportLedger) async throws -> T) async throws -> T {
        guard try acquire() else { throw FormaError.unavailable }
        // Not a release: another operation in this process may be holding the
        // lease legitimately, and dropping it here would break that operation's
        // exclusivity.
        guard reserve(keys) else { throw FormaError.unavailable }
        do {
            let result = try await body(ledger)
            releaseReservation(keys)
            try release()
            return result
        } catch {
            releaseReservation(keys)
            try? release()
            throw error
        }
    }
}

/// What a fresh process must do before it may write anything.
public enum ImportRecovery {
    public struct Outcome: Sendable, Equatable {
        /// Operations that may have an external effect and must be checked
        /// read-only before any further write.
        public let inFlight: [ImportOperationRecord]
        /// Rows the sweep moved to `verify_required`.
        public let interrupted: Int
    }

    /// Marks in-flight operations as `verify_required` and returns them.
    ///
    /// Called once when a workspace opens. A process that died mid-operation left
    /// a state nobody can trust; the ledger says so rather than resuming as if
    /// the last attempt had failed cleanly.
    public static func open(_ ledger: ImportLedger, at date: Date = Date()) throws -> Outcome {
        let interrupted = try ledger.markInterrupted(at: date)
        return Outcome(inFlight: try ledger.inFlightOperations(), interrupted: interrupted)
    }
}
