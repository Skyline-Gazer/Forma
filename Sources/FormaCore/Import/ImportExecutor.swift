import CryptoKit
import Foundation

/// One record's journey from intent to verified readback.
///
/// The executor is deliberately small: it does not decide whether to import
/// (preflight did), does not decide what the record should contain (mapping did),
/// and does not decide whether a write succeeded (the independent readback does).
/// What it does is keep the ledger honest at every step, and refuse to guess when
/// a call's outcome is unknown.
public actor ImportExecutor {
    private let ledger: ImportLedger
    private let writer: ImportSingleWriter
    private let write: any ImportWriteTransport
    private let read: any ImportReadTransport
    private let clock: @Sendable () -> Date

    public init(ledger: ImportLedger, writer: ImportSingleWriter,
                write: any ImportWriteTransport, read: any ImportReadTransport,
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.ledger = ledger
        self.writer = writer
        self.write = write
        self.read = read
        self.clock = clock
    }

    /// Executes one operation.
    ///
    /// A preflight that did not pass creates no intent: nothing was going to be
    /// written, so there is nothing to recover. An operation whose key already
    /// exists is not re-executed; its stored state is returned.
    public func execute(_ intent: ImportIntent,
                        preflight: ImportPreflightResult) async throws -> ImportExecutionResult {
        guard preflight.verdict == .pass else {
            return ImportExecutionResult(phase: .planned, outcome: nil, actualUUID: nil,
                                         reason: nil, attempts: 0)
        }

        let keys = ["source:\(intent.key.sourceID.uuidString.lowercased())",
                    "group:\(intent.targetDatabase)|\(intent.groupPath.joined(separator: "/"))"]
        guard try await writer.acquire() else { throw FormaError.unavailable }
        // The lease stays with whoever holds it: releasing on a failed reservation
        // would break that operation's exclusivity.
        guard await writer.reserve(keys) else { throw FormaError.unavailable }
        do {
            let result = try await run(intent)
            await writer.releaseReservation(keys)
            try await writer.release()
            return result
        } catch {
            await writer.releaseReservation(keys)
            try? await writer.release()
            throw error
        }
    }

    /// Continues an operation whose outcome was unknown.
    ///
    /// The only permitted conclusions come from a read-only lookup. A proven
    /// absence is reported rather than retried: re-importing after an unknown
    /// write needs a new decision, not a resumed one.
    public func resume(_ intent: ImportIntent) async throws -> ImportExecutionResult {
        guard let stored = try ledger.operation(keyDigest: intent.key.digest) else {
            return try await execute(intent, preflight: ImportPreflightResult(failures: []))
        }
        guard stored.phase.isInFlight else {
            return ImportExecutionResult(phase: stored.phase, outcome: stored.phase.outcome,
                                         actualUUID: stored.actualUUID, reason: nil, attempts: 0)
        }

        let keys = ["source:\(intent.key.sourceID.uuidString.lowercased())",
                    "group:\(intent.targetDatabase)|\(intent.groupPath.joined(separator: "/"))"]
        guard try await writer.acquire() else { throw FormaError.unavailable }
        guard await writer.reserve(keys) else { throw FormaError.unavailable }
        do {
            let result: ImportExecutionResult
            if let uuid = stored.actualUUID {
                // The record is known to be ours (PLAN §10.3): continue only the
                // steps that are still missing, never a second create.
                result = try await finish(stored: stored, intent: intent, uuid: uuid, attempts: 0)
            } else {
                result = try await resolveUnknown(stored: stored, intent: intent)
            }
            await writer.releaseReservation(keys)
            try await writer.release()
            return result
        } catch {
            await writer.releaseReservation(keys)
            try? await writer.release()
            throw error
        }
    }

    private func resolveUnknown(stored: ImportOperationRecord,
                                intent: ImportIntent) async throws -> ImportExecutionResult {
        let query = ImportLookupQuery(database: intent.targetDatabase, groupPath: intent.groupPath,
                                      associationBasis: intent.associationBasis,
                                      sourceSHA256: intent.sourceSHA256)
        let lookup: ImportLookupResult
        do {
            lookup = try await write.lookup(query)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ImportExecutionResult(phase: .verifyRequired, outcome: .verifyRequired,
                                         actualUUID: stored.actualUUID, reason: .outcomeUnknown, attempts: 1)
        }
        let observed = lookup.records.first
        let decision = ImportArbitration.decide(ImportFacts(
            observedUUID: observed?.uuid, candidateCount: lookup.records.count,
            lookupConclusive: lookup.conclusive, requestOutcome: .succeeded,
            businessIdentity: Self.identity(observed, intent: intent),
            contentMatchesManifest: observed?.matches(groupPath: intent.groupPath,
                                                      metadata: intent.metadata,
                                                      sha256: intent.sourceSHA256) ?? false,
            metadataMatchesManifest: observed.map {
                ImportRecordSnapshot.sameMetadata($0.metadata, intent.metadata)
            } ?? false))

        switch decision.outcome {
        case .skipVerified, .conflictHold:
            try ledger.transition(keyDigest: stored.keyDigest, to: Self.phase(decision.outcome),
                                  at: clock(), errorCode: decision.reason.rawValue)
            if let observed {
                try recordObservation(operation: stored, snapshot: observed, matches: decision.outcome == .skipVerified)
            }
            return ImportExecutionResult(phase: Self.phase(decision.outcome), outcome: decision.outcome,
                                         actualUUID: observed?.uuid, reason: decision.reason, attempts: 1)
        case .importRecord:
            // Proven absent. That is not permission to write: a new decision is.
            try ledger.transition(keyDigest: stored.keyDigest, to: .failed, at: clock(),
                                  errorCode: "absent_after_unknown")
            return ImportExecutionResult(phase: .failed, outcome: nil, actualUUID: nil,
                                         reason: .absentAndConclusive, attempts: 1)
        case .verifyRequired:
            if let observed {
                try recordObservation(operation: stored, snapshot: observed, matches: false)
            }
            return ImportExecutionResult(phase: .verifyRequired, outcome: .verifyRequired,
                                         actualUUID: observed?.uuid, reason: decision.reason, attempts: 1)
        }
    }

    private func run(_ intent: ImportIntent) async throws -> ImportExecutionResult {
        let operation = ImportOperationRecord(
            runID: intent.runID, key: intent.key, targetDatabase: intent.targetDatabase,
            targetGroupPath: intent.groupPath,
            intendedMetadataDigest: Self.digest(intent.metadata),
            intendedMetadataJSON: Self.encode(intent.metadata),
            sourceSHA256: intent.sourceSHA256, createdAt: clock())
        let (stored, inserted) = try ledger.recordIntent(operation)
        guard inserted else {
            // The key is the idempotency guarantee: a second execution of the same
            // operation returns what is recorded instead of writing again.
            return ImportExecutionResult(phase: stored.phase, outcome: stored.phase.outcome,
                                         actualUUID: stored.actualUUID, reason: nil, attempts: 0)
        }

        try ledger.transition(keyDigest: stored.keyDigest, to: .preflighted, at: clock())
        try ledger.transition(keyDigest: stored.keyDigest, to: .intentPersisted, at: clock())

        let query = ImportLookupQuery(database: intent.targetDatabase, groupPath: intent.groupPath,
                                      associationBasis: intent.associationBasis,
                                      sourceSHA256: intent.sourceSHA256)
        let lookup: ImportLookupResult
        do {
            lookup = try await write.lookup(query)
        } catch is CancellationError {
            // Cancelled before any write: nothing external can have changed.
            try ledger.transition(keyDigest: stored.keyDigest, to: .cancelled, at: clock(),
                                  errorCode: "cancelled")
            throw CancellationError()
        } catch {
            try ledger.transition(keyDigest: stored.keyDigest, to: .verifyRequired, at: clock(),
                                  errorCode: Self.code(for: error))
            return ImportExecutionResult(phase: .verifyRequired, outcome: .verifyRequired,
                                         actualUUID: nil, reason: .outcomeUnknown, attempts: 0)
        }

        let observed = lookup.records.first
        let decision = ImportArbitration.decide(ImportFacts(
            observedUUID: observed?.uuid,
            candidateCount: lookup.records.count,
            lookupConclusive: lookup.conclusive,
            requestOutcome: .succeeded,
            businessIdentity: Self.identity(observed, intent: intent),
            contentMatchesManifest: observed?.matches(groupPath: intent.groupPath,
                                                      metadata: intent.metadata,
                                                      sha256: intent.sourceSHA256) ?? false,
            metadataMatchesManifest: observed.map {
                ImportRecordSnapshot.sameMetadata($0.metadata, intent.metadata)
            } ?? false))

        switch decision.outcome {
        case .skipVerified, .conflictHold, .verifyRequired:
            try ledger.transition(keyDigest: stored.keyDigest, to: Self.phase(decision.outcome),
                                  at: clock(), errorCode: decision.reason.rawValue)
            if let observed {
                try recordObservation(operation: stored, snapshot: observed, matches: decision.outcome == .skipVerified)
            }
            return ImportExecutionResult(phase: Self.phase(decision.outcome), outcome: decision.outcome,
                                         actualUUID: observed?.uuid, reason: decision.reason, attempts: 0)
        case .importRecord:
            break
        }

        // Create. A throw here is an unknown outcome, not a failure: the record may
        // exist. Recovery is a read-only lookup, never a second create.
        let uuid: String
        do {
            uuid = try await write.create(ImportCreateRequest(
                database: intent.targetDatabase, groupPath: intent.groupPath,
                associationBasis: intent.associationBasis, metadata: intent.metadata,
                sourceSHA256: intent.sourceSHA256))
            try recordAttempt(operation: stored, attempt: 1, before: .intentPersisted,
                              after: .recordObserved, request: intent, error: nil)
        } catch {
            try recordAttempt(operation: stored, attempt: 1, before: .intentPersisted,
                              after: nil, request: intent, error: Self.code(for: error))
            try ledger.transition(keyDigest: stored.keyDigest, to: .verifyRequired, at: clock(),
                                  errorCode: Self.code(for: error))
            guard let recovered = try? await write.lookup(query), recovered.conclusive,
                  let found = recovered.records.first else {
                return ImportExecutionResult(phase: .verifyRequired, outcome: .verifyRequired,
                                             actualUUID: nil, reason: .outcomeUnknown, attempts: 1)
            }
            // The record exists: continue from the observed state instead of
            // creating a second one.
            try ledger.observeActualUUID(found.uuid, keyDigest: stored.keyDigest, at: clock())
            try ledger.transition(keyDigest: stored.keyDigest, to: .recordObserved, at: clock())
            return try await finish(stored: stored, intent: intent, uuid: found.uuid, attempts: 1)
        }

        try ledger.observeActualUUID(uuid, keyDigest: stored.keyDigest, at: clock())
        try ledger.transition(keyDigest: stored.keyDigest, to: .recordObserved, at: clock())
        return try await finish(stored: stored, intent: intent, uuid: uuid, attempts: 1)
    }

    // MARK: - Phases after the record exists

    private func finish(stored: ImportOperationRecord, intent: ImportIntent, uuid: String,
                        attempts: Int) async throws -> ImportExecutionResult {
        // Idempotent on purpose: a resumed operation may already be past some of
        // these steps, and repeating a metadata write with the same intended
        // values is safe, while a duplicate transition is not.
        let current = try ledger.operation(keyDigest: stored.keyDigest) ?? stored
        let metadataStepAllowed = current.phase.canTransition(to: .metadataObserved)
            || current.phase == .metadataObserved
        do {
            try await write.writeMetadata(ImportMetadataRequest(uuid: uuid, metadata: intent.metadata,
                                                                sourceSHA256: intent.sourceSHA256))
            try recordAttempt(operation: stored, attempt: attempts + 1, before: current.phase,
                              after: metadataStepAllowed ? .metadataObserved : nil,
                              request: intent, error: nil)
        } catch {
            try recordAttempt(operation: stored, attempt: attempts + 1, before: current.phase,
                              after: nil, request: intent, error: Self.code(for: error))
            try ledger.transition(keyDigest: stored.keyDigest, to: .verifyRequired, at: clock(),
                                  errorCode: Self.code(for: error))
            return ImportExecutionResult(phase: .verifyRequired, outcome: .verifyRequired,
                                         actualUUID: uuid, reason: .outcomeUnknown, attempts: attempts + 1)
        }
        if current.phase.canTransition(to: .metadataObserved) {
            try ledger.transition(keyDigest: stored.keyDigest, to: .metadataObserved, at: clock())
        }

        // The readback is a separate client on purpose.
        let snapshot: ImportRecordSnapshot
        do {
            snapshot = try await read.read(uuid: uuid)
        } catch {
            try ledger.transition(keyDigest: stored.keyDigest, to: .verifyRequired, at: clock(),
                                  errorCode: Self.code(for: error))
            return ImportExecutionResult(phase: .verifyRequired, outcome: .verifyRequired,
                                         actualUUID: uuid, reason: .outcomeUnknown, attempts: attempts + 1)
        }

        let matches = snapshot.matches(groupPath: intent.groupPath, metadata: intent.metadata,
                                       sha256: intent.sourceSHA256)
        try recordObservation(operation: stored, snapshot: snapshot, matches: matches)
        if matches {
            if let sha = snapshot.standardSHA256 {
                try ledger.recordTargetSHA256(sha, keyDigest: stored.keyDigest, at: clock())
            }
            try ledger.transition(keyDigest: stored.keyDigest, to: .readbackVerified, at: clock())
            return ImportExecutionResult(phase: .readbackVerified, outcome: .importRecord,
                                         actualUUID: uuid, reason: .writeVerified, attempts: attempts + 1)
        }
        // Our record, but the target does not match the intent: hold rather than
        // overwrite, because the difference may be a user's later edit.
        try ledger.transition(keyDigest: stored.keyDigest, to: .conflictHold, at: clock(),
                              errorCode: ImportReason.confirmedButDiffers.rawValue)
        return ImportExecutionResult(phase: .conflictHold, outcome: .conflictHold,
                                     actualUUID: uuid, reason: .confirmedButDiffers, attempts: attempts + 1)
    }

    // MARK: - Evidence

    private static func identity(_ snapshot: ImportRecordSnapshot?,
                                 intent: ImportIntent) -> BusinessRecordIdentity {
        guard let snapshot else {
            return BusinessRecordIdentity(observedUUID: nil, corroboration: [])
        }
        var corroboration: Set<BusinessRecordIdentity.Corroboration> = []
        if let basis = intent.associationBasis, snapshot.associationBasis == basis {
            corroboration.insert(.targetAssociationMatch)
        }
        if ImportRecordSnapshot.sameMetadata(snapshot.metadata, intent.metadata) {
            corroboration.insert(.attributesMatch)
        }
        return BusinessRecordIdentity(observedUUID: snapshot.uuid, corroboration: corroboration)
    }

    private func recordObservation(operation: ImportOperationRecord, snapshot: ImportRecordSnapshot,
                                   matches: Bool) throws {
        try ledger.appendObservation(ImportObservationRecord(
            operationID: operation.id, observedAt: clock(), kind: .readback,
            actualUUID: snapshot.uuid, parentPath: snapshot.parentPath,
            metadataDigest: Self.digest(snapshot.metadata),
            targetSHA256: snapshot.standardSHA256, matches: matches,
            detailDigest: snapshot.associationBasis.map { Self.digest($0) }))
    }

    private func recordAttempt(operation: ImportOperationRecord, attempt: Int,
                               before: ImportPhase, after: ImportPhase?,
                               request: ImportIntent, error: String?) throws {
        try ledger.appendAttempt(ImportAttemptRecord(
            operationID: operation.id, attempt: attempt, phaseBefore: before, phaseAfter: after,
            requestDigest: Self.digest(request), responseDigest: nil, errorCode: error,
            startedAt: clock(), finishedAt: clock()))
    }

    private static func phase(_ outcome: ImportOutcome) -> ImportPhase {
        switch outcome {
        case .skipVerified: return .skippedVerified
        case .importRecord: return .readbackVerified
        case .conflictHold: return .conflictHold
        case .verifyRequired: return .verifyRequired
        }
    }

    static func code(for error: any Error) -> String {
        (error as? FormaError)?.code ?? "unknown_error"
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).hexadecimalDigest
    }

    static func digest(_ metadata: [String: String?]) -> String {
        let canonical = metadata.keys.sorted().map { "\($0)=\(metadata[$0] ?? "")" }.joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).hexadecimalDigest
    }

    static func digest(_ intent: ImportIntent) -> String {
        SHA256.hash(data: Data("\(intent.key.digest)|\(digest(intent.metadata))".utf8)).hexadecimalDigest
    }

    static func encode(_ metadata: [String: String?]) -> String {
        guard let data = try? JSONEncoder().encode(metadata) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct ImportIntent: Sendable, Equatable {
    public let runID: UUID
    public let entry: ManifestEntry
    public let key: ImportOperationKey
    public let targetDatabase: String
    public let groupPath: [String]
    public let associationBasis: String?
    /// The field values mapping already decided. The executor never re-decides them.
    public let metadata: [String: String?]
    public let sourceSHA256: String

    public init(runID: UUID, entry: ManifestEntry, key: ImportOperationKey, targetDatabase: String,
                groupPath: [String], associationBasis: String?, metadata: [String: String?],
                sourceSHA256: String) {
        self.runID = runID
        self.entry = entry
        self.key = key
        self.targetDatabase = targetDatabase
        self.groupPath = groupPath
        self.associationBasis = associationBasis
        self.metadata = metadata
        self.sourceSHA256 = sourceSHA256
    }
}

public struct ImportExecutionResult: Sendable, Equatable {
    public let phase: ImportPhase
    public let outcome: ImportOutcome?
    public let actualUUID: String?
    public let reason: ImportReason?
    /// Write attempts made by this execution; zero when nothing was written.
    public let attempts: Int
}
