import Foundation

/// What the recovery sweep found, in the words a person needs.
///
/// The six states are the six things an interrupted run can mean. Keeping them
/// apart matters because they call for different actions: "no record was created"
/// is not the same as "a record exists but its fields may be missing", and
/// neither is "we do not know whether anything was written".
public struct ImportRecoveryEntry: Sendable, Equatable {
    public enum State: String, Sendable, Equatable, CaseIterable, Codable {
        /// Planned, preflighted or deferred: nothing external can have happened.
        case notStarted = "not_started"
        /// The intent is durable but no record is known to exist.
        case intentRecorded = "intent_recorded"
        /// A record is known to exist; its fields may be incomplete.
        case recordCreated = "record_created"
        /// The metadata write was answered; the independent readback is missing.
        case metadataAnswered = "metadata_answered"
        /// The outcome is unknown: a timeout, a disconnect or a crash.
        case outcomeUnknown = "outcome_unknown"
        /// A terminal state: verified, skipped, held or failed.
        case settled
    }

    public let keyDigest: String
    public let state: State
    /// The phase as it is now (usually `verify_required` after a sweep).
    public let phase: ImportPhase
    /// The phase before this process swept the operation, when that is known.
    public let lastKnownPhase: ImportPhase
    public let targetDatabase: String
    public let groupPath: [String]
    public let actualUUID: String?
    /// The source digest the operation was decided on. Nil for a ledger row that
    /// never recorded one; a recheck then cannot prove the bytes.
    public let intendedSHA256: String?
    public let errorCode: String?

    public init(keyDigest: String, state: State, phase: ImportPhase,
                lastKnownPhase: ImportPhase, targetDatabase: String, groupPath: [String],
                actualUUID: String?, intendedSHA256: String?, errorCode: String?) {
        self.keyDigest = keyDigest
        self.state = state
        self.phase = phase
        self.lastKnownPhase = lastKnownPhase
        self.targetDatabase = targetDatabase
        self.groupPath = groupPath
        self.actualUUID = actualUUID
        self.intendedSHA256 = intendedSHA256
        self.errorCode = errorCode
    }
}

public struct ImportRecoveryOverview: Sendable, Equatable {
    public let entries: [ImportRecoveryEntry]

    public init(entries: [ImportRecoveryEntry]) {
        self.entries = entries
    }

    public static let empty = ImportRecoveryOverview(entries: [])

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }
    /// True when at least one operation may have an external effect nobody has
    /// looked at yet.
    public var requiresReview: Bool { entries.contains { $0.state == .outcomeUnknown } }
    public var counts: [ImportRecoveryEntry.State: Int] {
        entries.reduce(into: [:]) { counts, entry in counts[entry.state, default: 0] += 1 }
    }
}

/// Maps stored phases onto the recovery states. Pure, so the mapping is testable
/// without a database or a process.
public enum ImportRecoveryPresenter {
    public static func state(for phase: ImportPhase) -> ImportRecoveryEntry.State {
        switch phase {
        case .planned, .preflighted, .deferred:
            return .notStarted
        case .intentPersisted:
            return .intentRecorded
        case .recordObserved:
            return .recordCreated
        case .metadataObserved:
            return .metadataAnswered
        case .verifyRequired:
            return .outcomeUnknown
        case .readbackVerified, .skippedVerified, .conflictHold, .failed, .cancelled:
            return .settled
        }
    }

    /// Builds the startup view of pending work.
    ///
    /// `before` is what the ledger held before this process swept it: it is the
    /// only record of what the previous process had actually done. `after` is the
    /// swept set, from which target, group and UUID are read.
    public static func overview(before: [ImportOperationRecord],
                                after: [ImportOperationRecord]) -> ImportRecoveryOverview {
        let prior = Dictionary(before.map { ($0.keyDigest, $0.phase) }, uniquingKeysWith: { first, _ in first })
        let entries = after.map { record -> ImportRecoveryEntry in
            let lastKnown = prior[record.keyDigest] ?? record.phase
            // A record that was already `verify_required` before this launch keeps
            // that state; it was not interrupted by us.
            let state = ImportRecoveryPresenter.state(for: lastKnown)
            return ImportRecoveryEntry(
                keyDigest: record.keyDigest, state: state, phase: record.phase,
                lastKnownPhase: lastKnown, targetDatabase: record.targetDatabase,
                groupPath: record.targetGroupPath, actualUUID: record.actualUUID,
                intendedSHA256: record.sourceSHA256, errorCode: record.errorCode)
        }
        return ImportRecoveryOverview(entries: entries)
    }
}

/// The authority a read-only recovery check runs under.
///
/// It is a value the caller has to state: which database and which group the
/// recheck may read. An operation aimed anywhere else is reported as out of
/// scope without a single call.
public struct ImportRecoveryScope: Sendable, Equatable {
    public let databaseID: String
    public let groupPath: [String]

    public init(databaseID: String, groupPath: [String]) {
        self.databaseID = databaseID
        self.groupPath = groupPath
    }
}

public struct ImportRecoveryReviewResult: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable {
        /// The record exists and matches what the ledger says was intended.
        case verified
        /// The record exists but differs: a hold, never an overwrite.
        case differs
        /// The target cannot prove the fact (missing digest, no UUID, read error).
        case unverifiable = "unverifiable"
        /// The operation addresses a database or group this check may not read.
        case outsideScope = "outside_scope"
    }

    public let keyDigest: String
    public let outcome: Outcome
    /// Stable, non-sensitive reason code.
    public let reason: String
    /// Whether a read was actually attempted.
    public let readAttempted: Bool

    public init(keyDigest: String, outcome: Outcome, reason: String, readAttempted: Bool) {
        self.keyDigest = keyDigest
        self.outcome = outcome
        self.reason = reason
        self.readAttempted = readAttempted
    }
}

/// Rechecks an interrupted operation using only the independent read client.
///
/// It never writes, and it never decides that a record is absent: proving absence
/// needs the write channel's lookup, which is a different authority. An operation
/// without a known UUID therefore stays `unverifiable`, and a person decides what
/// to do next.
public struct ImportRecoveryReviewer: Sendable {
    private let read: any ImportReadTransport

    public init(read: any ImportReadTransport) {
        self.read = read
    }

    public func review(_ entry: ImportRecoveryEntry,
                       scope: ImportRecoveryScope) async -> ImportRecoveryReviewResult {
        guard entry.targetDatabase.uppercased() == scope.databaseID.uppercased(),
              entry.groupPath == scope.groupPath else {
            return ImportRecoveryReviewResult(keyDigest: entry.keyDigest, outcome: .outsideScope,
                                              reason: "scope_mismatch", readAttempted: false)
        }
        guard let uuid = entry.actualUUID, !uuid.isEmpty else {
            return ImportRecoveryReviewResult(keyDigest: entry.keyDigest, outcome: .unverifiable,
                                              reason: "no_record_uuid", readAttempted: false)
        }

        let snapshot: ImportRecordSnapshot
        do {
            snapshot = try await read.read(uuid: uuid)
        } catch {
            return ImportRecoveryReviewResult(
                keyDigest: entry.keyDigest, outcome: .unverifiable,
                reason: (error as? FormaError)?.code ?? "unknown_error", readAttempted: true)
        }

        guard snapshot.database.uppercased() == scope.databaseID.uppercased() else {
            return ImportRecoveryReviewResult(keyDigest: entry.keyDigest, outcome: .outsideScope,
                                              reason: "observed_other_database", readAttempted: true)
        }
        guard snapshot.parentPath == entry.groupPath else {
            return ImportRecoveryReviewResult(keyDigest: entry.keyDigest, outcome: .differs,
                                              reason: "target_location_changed", readAttempted: true)
        }
        guard snapshot.shaVerified, let sha = snapshot.standardSHA256 else {
            return ImportRecoveryReviewResult(keyDigest: entry.keyDigest, outcome: .unverifiable,
                                              reason: "hash_unverified", readAttempted: true)
        }
        guard let intended = entry.intendedSHA256 else {
            return ImportRecoveryReviewResult(keyDigest: entry.keyDigest, outcome: .unverifiable,
                                              reason: "source_sha_unavailable", readAttempted: true)
        }
        guard sha == intended else {
            return ImportRecoveryReviewResult(keyDigest: entry.keyDigest, outcome: .differs,
                                              reason: "target_sha_mismatch", readAttempted: true)
        }
        return ImportRecoveryReviewResult(keyDigest: entry.keyDigest, outcome: .verified,
                                          reason: "readback_matches", readAttempted: true)
    }
}
