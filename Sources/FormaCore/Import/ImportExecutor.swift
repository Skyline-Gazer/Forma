import CryptoKit
import Foundation

/// One record's journey from intent to verified readback.
///
/// The executor is deliberately small: it does not decide whether to import
/// (preflight did), does not decide what the record should contain (mapping did),
/// and does not decide whether a write succeeded (the independent readback does).
/// What it does is keep the ledger honest at every step, and refuse to guess when
/// a call's outcome is unknown.
///
/// Three rules shape every path below:
///
/// 1. **Nothing is written without a clearance bound to this operation.** A
///    conclusion about another source, another snapshot, another target or
///    another authorization is not a permission here.
/// 2. **Read before write.** A record is read through the independent client
///    before any field is written, so an edit made while the operation was
///    interrupted is preserved instead of overwritten.
/// 3. **Unknown is not absence.** A candidate is adopted only when the lookup is
///    conclusive, the candidate is unique, and its business identity is
///    confirmed; anything else stops at VERIFY_REQUIRED with zero writes.
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

    // MARK: - Execution

    /// Executes one operation under a clearance that is bound to it.
    ///
    /// A clearance for other facts, or a conclusion that did not pass, creates no
    /// intent: nothing was going to be written, so there is nothing to recover.
    /// An operation whose key already exists is not re-executed; its stored state
    /// is returned.
    public func execute(_ intent: ImportIntent,
                        clearance: ImportPreflightClearance) async throws -> ImportExecutionResult {
        guard Self.clearanceMatches(clearance, intent) else {
            return ImportExecutionResult(phase: .planned, outcome: nil, actualUUID: nil,
                                         reason: .clearanceMismatch, attempts: 0)
        }
        guard clearance.verdict == .pass else {
            return ImportExecutionResult(phase: .planned, outcome: nil, actualUUID: nil,
                                         reason: nil, attempts: 0,
                                         blockingCodes: clearance.blockingCodes)
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
    /// The only permitted conclusions come from a read-only lookup, and the
    /// source must still be the bytes the decision was made from. A proven
    /// absence is reported rather than retried: re-importing after an unknown
    /// write needs a new decision, not a resumed one.
    public func resume(_ intent: ImportIntent,
                       source: ImportSourceFacts) async throws -> ImportExecutionResult {
        guard let stored = try ledger.operation(keyDigest: intent.key.digest) else {
            // No intent, no operation: there is nothing to continue. Starting an
            // import here would turn a recovery request into a new write.
            return ImportExecutionResult(phase: .planned, outcome: .verifyRequired,
                                         actualUUID: nil, reason: .intentMissing, attempts: 0)
        }
        guard stored.phase.isInFlight else {
            return ImportExecutionResult(phase: stored.phase, outcome: stored.phase.outcome,
                                         actualUUID: stored.actualUUID, reason: nil, attempts: 0)
        }
        // The bytes must still be the ones the decision was made from.
        guard source.snapshotFingerprint == intent.source.snapshotFingerprint,
              source.sha256 == nil || source.sha256 == intent.source.contentSHA256 else {
            try? markUnresolved(stored, reason: .sourceChanged)
            return ImportExecutionResult(phase: stored.phase, outcome: .verifyRequired,
                                         actualUUID: stored.actualUUID, reason: .sourceChanged, attempts: 0)
        }

        let keys = ["source:\(intent.key.sourceID.uuidString.lowercased())",
                    "group:\(intent.targetDatabase)|\(intent.groupPath.joined(separator: "/"))"]
        guard try await writer.acquire() else { throw FormaError.unavailable }
        guard await writer.reserve(keys) else { throw FormaError.unavailable }
        do {
            let result: ImportExecutionResult
            if let uuid = stored.actualUUID {
                // The record is known to be ours (PLAN §10.3): read it, then
                // continue only the steps that are still missing.
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

    // MARK: - Fresh execution

    private func run(_ intent: ImportIntent) async throws -> ImportExecutionResult {
        let operation = ImportOperationRecord(
            runID: intent.runID, key: intent.key, targetDatabase: intent.targetDatabase,
            targetGroupPath: intent.groupPath,
            intendedMetadataDigest: Self.digest(intent.metadata),
            intendedMetadataJSON: Self.encode(intent.metadata),
            sourceSHA256: intent.source.contentSHA256,
            authorizationDigest: intent.authorizationDigest, createdAt: clock())
        let (stored, inserted) = try ledger.recordIntent(operation)
        guard inserted else {
            // The key is the idempotency guarantee: a second execution of the same
            // operation returns what is recorded instead of writing again.
            return ImportExecutionResult(phase: stored.phase, outcome: stored.phase.outcome,
                                         actualUUID: stored.actualUUID, reason: nil, attempts: 0)
        }

        try ledger.transition(keyDigest: stored.keyDigest, to: .preflighted, at: clock())
        try ledger.transition(keyDigest: stored.keyDigest, to: .intentPersisted, at: clock())

        let query = Self.query(for: intent)
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
        let decision = ImportArbitration.decide(Self.facts(lookup: lookup, observed: observed,
                                                          intent: intent))
        switch decision.outcome {
        case .skipVerified, .conflictHold, .verifyRequired:
            try ledger.transition(keyDigest: stored.keyDigest, to: Self.phase(decision.outcome),
                                  at: clock(), errorCode: decision.reason.rawValue)
            if let observed {
                try recordObservation(operation: stored, snapshot: observed,
                                      matches: decision.outcome == .skipVerified)
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
                source: intent.source))
            try recordAttempt(operation: stored, attempt: 1, before: .intentPersisted,
                              after: .recordObserved, request: intent, error: nil)
        } catch {
            try recordAttempt(operation: stored, attempt: 1, before: .intentPersisted,
                              after: nil, request: intent, error: Self.code(for: error))
            try ledger.transition(keyDigest: stored.keyDigest, to: .verifyRequired, at: clock(),
                                  errorCode: Self.code(for: error))
            return try await adoptAfterUnknownCreate(stored: stored, intent: intent, query: query)
        }

        try ledger.observeActualUUID(uuid, keyDigest: stored.keyDigest, at: clock())
        try ledger.transition(keyDigest: stored.keyDigest, to: .recordObserved, at: clock())
        return try await finish(stored: stored, intent: intent, uuid: uuid, attempts: 1)
    }

    /// Looks for the record a lost create may have left behind.
    ///
    /// Adoption needs all three: a conclusive lookup, exactly one candidate, and
    /// a confirmed business identity. "The first record that came back" is not
    /// evidence of anything.
    private func adoptAfterUnknownCreate(stored: ImportOperationRecord, intent: ImportIntent,
                                         query: ImportLookupQuery) async throws -> ImportExecutionResult {
        let lookup: ImportLookupResult
        do {
            lookup = try await write.lookup(query)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ImportExecutionResult(phase: .verifyRequired, outcome: .verifyRequired,
                                         actualUUID: stored.actualUUID, reason: .outcomeUnknown, attempts: 1)
        }

        guard lookup.conclusive else {
            return ImportExecutionResult(phase: .verifyRequired, outcome: .verifyRequired,
                                         actualUUID: stored.actualUUID, reason: .searchInconclusive,
                                         attempts: 1)
        }
        guard lookup.records.count == 1 else {
            let reason: ImportReason = lookup.records.isEmpty ? .absentAndConclusive : .candidatesAmbiguous
            if lookup.records.isEmpty {
                // Proven absent: the create did not land. That is reported, not
                // retried; a new decision is needed to write again.
                try ledger.transition(keyDigest: stored.keyDigest, to: .failed, at: clock(),
                                      errorCode: "absent_after_unknown")
                return ImportExecutionResult(phase: .failed, outcome: nil, actualUUID: nil,
                                             reason: .absentAndConclusive, attempts: 1)
            }
            return ImportExecutionResult(phase: .verifyRequired, outcome: .verifyRequired,
                                         actualUUID: stored.actualUUID, reason: reason, attempts: 1)
        }

        let candidate = lookup.records[0]
        guard Self.identity(candidate, intent: intent).isConfirmed else {
            try recordObservation(operation: stored, snapshot: candidate, matches: false)
            return ImportExecutionResult(phase: .verifyRequired, outcome: .verifyRequired,
                                         actualUUID: nil, reason: .identityUnconfirmed, attempts: 1)
        }

        try ledger.observeActualUUID(candidate.uuid, keyDigest: stored.keyDigest, at: clock())
        try ledger.transition(keyDigest: stored.keyDigest, to: .recordObserved, at: clock())
        return try await finish(stored: stored, intent: intent, uuid: candidate.uuid, attempts: 1)
    }

    // MARK: - Recovery of an operation with no known UUID

    private func resolveUnknown(stored: ImportOperationRecord,
                                intent: ImportIntent) async throws -> ImportExecutionResult {
        let query = Self.query(for: intent)
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
        let decision = ImportArbitration.decide(Self.facts(lookup: lookup, observed: observed,
                                                          intent: intent))

        switch decision.outcome {
        case .skipVerified, .conflictHold:
            try ledger.transition(keyDigest: stored.keyDigest, to: Self.phase(decision.outcome),
                                  at: clock(), errorCode: decision.reason.rawValue)
            if let observed {
                try recordObservation(operation: stored, snapshot: observed,
                                      matches: decision.outcome == .skipVerified)
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

    // MARK: - Phases after the record exists

    /// Reads the record, writes only what is missing, then reads it back.
    ///
    /// The read comes first on purpose: a field the record already holds at a
    /// different value was changed by somebody else, and the operation holds
    /// instead of overwriting it.
    private func finish(stored: ImportOperationRecord, intent: ImportIntent, uuid: String,
                        attempts: Int) async throws -> ImportExecutionResult {
        let current = try ledger.operation(keyDigest: stored.keyDigest) ?? stored

        let snapshot: ImportRecordSnapshot
        do {
            snapshot = try await read.read(uuid: uuid)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ledger.transition(keyDigest: stored.keyDigest, to: .verifyRequired, at: clock(),
                                  errorCode: Self.code(for: error))
            return ImportExecutionResult(phase: .verifyRequired, outcome: .verifyRequired,
                                         actualUUID: uuid, reason: .outcomeUnknown, attempts: attempts)
        }

        // The record must be provably ours before anything is written to it.
        guard Self.identity(snapshot, intent: intent).isConfirmed else {
            try recordObservation(operation: stored, snapshot: snapshot, matches: false)
            try? markUnresolved(stored, reason: .identityUnconfirmed)
            return ImportExecutionResult(phase: .verifyRequired, outcome: .verifyRequired,
                                         actualUUID: uuid, reason: .identityUnconfirmed, attempts: attempts)
        }

        // Fields somebody else changed survive.
        let conflicts = Self.conflictingFields(snapshot.metadata, intent.metadata)
        if !conflicts.isEmpty {
            try recordObservation(operation: stored, snapshot: snapshot, matches: false)
            try ledger.transition(keyDigest: stored.keyDigest, to: .conflictHold, at: clock(),
                                  errorCode: ImportReason.externalModification.rawValue)
            return ImportExecutionResult(phase: .conflictHold, outcome: .conflictHold,
                                         actualUUID: uuid, reason: .externalModification, attempts: attempts)
        }

        // Only the slots that are still missing are written.
        let missing = Self.missingFields(snapshot.metadata, intent.metadata)
        if !missing.isEmpty {
            do {
                try await write.writeMetadata(ImportMetadataRequest(uuid: uuid, metadata: missing,
                                                                    source: intent.source))
                try recordAttempt(operation: stored, attempt: attempts + 1, before: current.phase,
                                  after: .metadataObserved, request: intent, error: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try recordAttempt(operation: stored, attempt: attempts + 1, before: current.phase,
                                  after: nil, request: intent, error: Self.code(for: error))
                try ledger.transition(keyDigest: stored.keyDigest, to: .verifyRequired, at: clock(),
                                      errorCode: Self.code(for: error))
                return ImportExecutionResult(phase: .verifyRequired, outcome: .verifyRequired,
                                             actualUUID: uuid, reason: .outcomeUnknown, attempts: attempts + 1)
            }
        }
        if current.phase.canTransition(to: .metadataObserved) {
            try ledger.transition(keyDigest: stored.keyDigest, to: .metadataObserved, at: clock())
        }

        // The readback is a separate client on purpose.
        let after: ImportRecordSnapshot
        do {
            after = try await read.read(uuid: uuid)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ledger.transition(keyDigest: stored.keyDigest, to: .verifyRequired, at: clock(),
                                  errorCode: Self.code(for: error))
            return ImportExecutionResult(phase: .verifyRequired, outcome: .verifyRequired,
                                         actualUUID: uuid, reason: .outcomeUnknown, attempts: attempts + 1)
        }

        // A target that cannot prove the content digest proves nothing: the
        // operation stays unverified instead of being called complete.
        guard after.shaVerified else {
            try recordObservation(operation: stored, snapshot: after, matches: false)
            try ledger.transition(keyDigest: stored.keyDigest, to: .verifyRequired, at: clock(),
                                  errorCode: ImportReason.hashUnverified.rawValue)
            return ImportExecutionResult(phase: .verifyRequired, outcome: .verifyRequired,
                                         actualUUID: uuid, reason: .hashUnverified, attempts: attempts)
        }

        let matches = after.matches(groupPath: intent.groupPath, metadata: intent.metadata,
                                    sha256: intent.source.contentSHA256)
        try recordObservation(operation: stored, snapshot: after, matches: matches)
        if matches {
            if let sha = after.standardSHA256 {
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

    // MARK: - Facts

    private static func query(for intent: ImportIntent) -> ImportLookupQuery {
        ImportLookupQuery(database: intent.targetDatabase, groupPath: intent.groupPath,
                          associationBasis: intent.associationBasis, source: intent.source)
    }

    private static func facts(lookup: ImportLookupResult, observed: ImportRecordSnapshot?,
                              intent: ImportIntent) -> ImportFacts {
        ImportFacts(
            observedUUID: observed?.uuid,
            candidateCount: lookup.records.count,
            lookupConclusive: lookup.conclusive,
            requestOutcome: .succeeded,
            businessIdentity: identity(observed, intent: intent),
            contentMatchesManifest: observed?.matches(groupPath: intent.groupPath,
                                                      metadata: intent.metadata,
                                                      sha256: intent.source.contentSHA256) ?? false,
            metadataMatchesManifest: observed.map {
                ImportRecordSnapshot.sameMetadata($0.metadata, intent.metadata)
            } ?? false,
            targetHashVerified: observed?.shaVerified ?? false)
    }

    /// Whether a clearance was decided for this operation.
    static func clearanceMatches(_ clearance: ImportPreflightClearance, _ intent: ImportIntent) -> Bool {
        let binding = clearance.binding
        return binding.sourceID == intent.key.sourceID
            && binding.snapshotFingerprint == intent.key.snapshotFingerprint
            && binding.manifestRevision == intent.key.manifestRevision
            && binding.targetDatabase == intent.targetDatabase
            && binding.targetGroupPath == intent.groupPath
            && binding.authorizationDigest == intent.authorizationDigest
    }

    /// Whether the observed record can be called the record this operation is
    /// about: the anchor ties it to this source, the attributes do not contradict
    /// the decision.
    static func identity(_ snapshot: ImportRecordSnapshot?,
                         intent: ImportIntent) -> BusinessRecordIdentity {
        guard let snapshot else {
            return BusinessRecordIdentity(observedUUID: nil, corroboration: [])
        }
        var corroboration: Set<BusinessRecordIdentity.Corroboration> = []
        if let basis = intent.associationBasis, snapshot.associationBasis == basis {
            corroboration.insert(.targetAssociationMatch)
        }
        if attributesAgree(snapshot.metadata, intent.metadata) {
            corroboration.insert(.attributesMatch)
        }
        return BusinessRecordIdentity(observedUUID: snapshot.uuid, corroboration: corroboration)
    }

    /// A field that is absent on the record is not yet written; a field that
    /// holds a different value was changed by somebody else.
    static func attributesAgree(_ observed: [String: String?], _ intended: [String: String?]) -> Bool {
        conflictingFields(observed, intended).isEmpty
    }

    static func conflictingFields(_ observed: [String: String?], _ intended: [String: String?]) -> [String] {
        var conflicts: [String] = []
        for (key, intendedValue) in intended {
            guard let intendedValue else { continue }
            guard let current = observed[key] ?? nil else { continue }
            if current != intendedValue { conflicts.append(key) }
        }
        return conflicts.sorted()
    }

    static func missingFields(_ observed: [String: String?], _ intended: [String: String?]) -> [String: String?] {
        var missing: [String: String?] = [:]
        for (key, intendedValue) in intended {
            guard let intendedValue else { continue }
            if (observed[key] ?? nil) == nil { missing[key] = intendedValue }
        }
        return missing
    }

    private func markUnresolved(_ stored: ImportOperationRecord, reason: ImportReason) throws {
        guard stored.phase.canTransition(to: .verifyRequired) else { return }
        try ledger.transition(keyDigest: stored.keyDigest, to: .verifyRequired, at: clock(),
                              errorCode: reason.rawValue)
    }

    // MARK: - Evidence

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
    /// The authorized source file: which bytes, from which snapshot, under which
    /// read session.
    public let source: ImportSourceBinding
    public let targetDatabase: String
    public let groupPath: [String]
    public let associationBasis: String?
    /// The field values mapping already decided. The executor never re-decides them.
    public let metadata: [String: String?]
    /// Digest of the authorization the operation runs under. A clearance for
    /// another authorization is not a permission here.
    public let authorizationDigest: String

    public init(runID: UUID, entry: ManifestEntry, key: ImportOperationKey,
                source: ImportSourceBinding, targetDatabase: String, groupPath: [String],
                associationBasis: String?, metadata: [String: String?],
                authorizationDigest: String) {
        self.runID = runID
        self.entry = entry
        self.key = key
        self.source = source
        self.targetDatabase = targetDatabase
        self.groupPath = groupPath
        self.associationBasis = associationBasis
        self.metadata = metadata
        self.authorizationDigest = authorizationDigest
    }
}

public struct ImportExecutionResult: Sendable, Equatable {
    public let phase: ImportPhase
    public let outcome: ImportOutcome?
    public let actualUUID: String?
    public let reason: ImportReason?
    /// Write attempts made by this execution; zero when nothing was written.
    public let attempts: Int
    /// Preflight failures, when the execution stopped at the clearance.
    public let blockingCodes: [ImportPreflightCode]

    public init(phase: ImportPhase, outcome: ImportOutcome?, actualUUID: String?,
                reason: ImportReason?, attempts: Int,
                blockingCodes: [ImportPreflightCode] = []) {
        self.phase = phase
        self.outcome = outcome
        self.actualUUID = actualUUID
        self.reason = reason
        self.attempts = attempts
        self.blockingCodes = blockingCodes
    }
}
