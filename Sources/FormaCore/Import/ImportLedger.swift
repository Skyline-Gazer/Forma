import Foundation
import GRDB

/// The import ledger: intent first, observations after, nothing overwritten.
///
/// PLAN §10.3's rule is that an external side effect and a SQLite row are not one
/// transaction, so the only honest thing to persist is *what was intended* and
/// *what was observed*. This type never decides whether a write succeeded; it
/// records that a phase was reached and refuses transitions the contract does not
/// allow.

// MARK: - Phase

/// One operation's position in the contract's state machine.
///
/// The four arbitration results are phases too: `skipped_verified`,
/// `conflict_hold` and `verify_required` are places an operation stops or waits,
/// not separate flags that could disagree with `phase`.
public enum ImportPhase: String, Codable, Sendable, CaseIterable {
    case planned
    case preflighted
    /// Transient preflight failure: keep the intent, retry later. Not a skip.
    case deferred
    case intentPersisted = "intent_persisted"
    case recordObserved = "record_observed"
    case metadataObserved = "metadata_observed"
    case readbackVerified = "readback_verified"
    case skippedVerified = "skipped_verified"
    case conflictHold = "conflict_hold"
    case verifyRequired = "verify_required"
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .readbackVerified, .skippedVerified, .conflictHold, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    /// Phases after which an external effect may exist.
    public var isInFlight: Bool {
        switch self {
        case .intentPersisted, .recordObserved, .metadataObserved, .verifyRequired:
            return true
        default:
            return false
        }
    }

    /// The arbitration result this phase carries, if any.
    public var outcome: ImportOutcome? {
        switch self {
        case .skippedVerified: return .skipVerified
        case .readbackVerified: return .importRecord
        case .conflictHold: return .conflictHold
        case .verifyRequired: return .verifyRequired
        default: return nil
        }
    }

    /// The transitions the contract permits. Everything else is a bug, and a
    /// ledger that accepted it would be able to describe a state the engine can
    /// never reach.
    public func canTransition(to next: ImportPhase) -> Bool {
        switch (self, next) {
        case (.planned, .preflighted), (.planned, .deferred),
             (.deferred, .preflighted), (.deferred, .deferred):
            return true
        case (.preflighted, .intentPersisted):
            return true
        case (.intentPersisted, .skippedVerified), (.intentPersisted, .recordObserved):
            return true
        // A confirmed record that differs can be found at any point after the
        // intent: the lookup may see it before a create, and the readback may see
        // it after one. Both are holds, neither is an overwrite.
        case (.intentPersisted, .conflictHold), (.recordObserved, .conflictHold),
             (.metadataObserved, .conflictHold):
            return true
        case (.recordObserved, .metadataObserved):
            return true
        case (.metadataObserved, .readbackVerified):
            return true
        case (let from, .verifyRequired):
            return from.isInFlight
        case (.verifyRequired, .recordObserved), (.verifyRequired, .metadataObserved),
             (.verifyRequired, .readbackVerified), (.verifyRequired, .skippedVerified),
             (.verifyRequired, .conflictHold):
            return true
        case (let from, .failed), (let from, .cancelled):
            return !from.isTerminal
        default:
            return false
        }
    }
}

public enum ImportOutcome: String, Codable, Sendable, CaseIterable {
    case skipVerified = "skip_verified"
    case importRecord = "import"
    case conflictHold = "conflict_hold"
    case verifyRequired = "verify_required"
}

// MARK: - Records

public struct ImportRunRecord: Sendable, Equatable {
    public let id: UUID
    public let scopeID: UUID
    public let manifestID: UUID
    public let manifestRevision: Int
    public let profileID: String
    public let profileVersion: String
    public let schemaVersion: String
    public let authorizationDigest: String
    public let startedAt: Date
    public let state: State

    public enum State: String, Codable, Sendable {
        case running, completed, aborted
    }

    public init(id: UUID = UUID(), scopeID: UUID, manifestID: UUID, manifestRevision: Int,
                profileID: String, profileVersion: String, schemaVersion: String,
                authorizationDigest: String, startedAt: Date, state: State = .running) {
        self.id = id
        self.scopeID = scopeID
        self.manifestID = manifestID
        self.manifestRevision = manifestRevision
        self.profileID = profileID
        self.profileVersion = profileVersion
        self.schemaVersion = schemaVersion
        self.authorizationDigest = authorizationDigest
        self.startedAt = startedAt
        self.state = state
    }
}

public struct ImportOperationRecord: Sendable, Equatable {
    public let id: UUID
    public let runID: UUID
    public let keyDigest: String
    public let sourceID: UUID
    public let snapshotFingerprint: String
    public let manifestRevision: Int
    public let targetAssociationID: UUID
    public let operationKind: ImportOperationKind
    public var phase: ImportPhase
    public let targetDatabase: String
    public let targetGroupPath: [String]
    public let intendedMetadataDigest: String
    public let intendedMetadataJSON: String
    public var actualUUID: String?
    public var sourceSHA256: String?
    public var targetSHA256: String?
    /// Digest of the authorization the operation ran under. Added by ledger v2;
    /// rows written before it carry nothing.
    public var authorizationDigest: String?
    public var errorCode: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), runID: UUID, key: ImportOperationKey, phase: ImportPhase = .planned,
                targetDatabase: String, targetGroupPath: [String], intendedMetadataDigest: String,
                intendedMetadataJSON: String, actualUUID: String? = nil, sourceSHA256: String? = nil,
                targetSHA256: String? = nil, authorizationDigest: String? = nil,
                errorCode: String? = nil, createdAt: Date, updatedAt: Date? = nil) {
        self.id = id
        self.runID = runID
        self.keyDigest = key.digest
        self.sourceID = key.sourceID
        self.snapshotFingerprint = key.snapshotFingerprint
        self.manifestRevision = key.manifestRevision
        self.targetAssociationID = key.targetAssociationID
        self.operationKind = key.operationKind
        self.phase = phase
        self.targetDatabase = targetDatabase
        self.targetGroupPath = targetGroupPath
        self.intendedMetadataDigest = intendedMetadataDigest
        self.intendedMetadataJSON = intendedMetadataJSON
        self.actualUUID = actualUUID
        self.sourceSHA256 = sourceSHA256
        self.targetSHA256 = targetSHA256
        self.authorizationDigest = authorizationDigest
        self.errorCode = errorCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public var key: ImportOperationKey? {
        try? ImportOperationKey(sourceID: sourceID, snapshotFingerprint: snapshotFingerprint,
                                manifestRevision: manifestRevision,
                                targetAssociationID: targetAssociationID,
                                operationKind: operationKind)
    }
}

public struct ImportAttemptRecord: Sendable, Equatable {
    public let id: UUID
    public let operationID: UUID
    public let attempt: Int
    public let phaseBefore: ImportPhase
    public let phaseAfter: ImportPhase?
    public let requestDigest: String
    public let responseDigest: String?
    public let errorCode: String?
    public let startedAt: Date
    public let finishedAt: Date?

    public init(id: UUID = UUID(), operationID: UUID, attempt: Int, phaseBefore: ImportPhase,
                phaseAfter: ImportPhase?, requestDigest: String, responseDigest: String?,
                errorCode: String?, startedAt: Date, finishedAt: Date?) {
        self.id = id
        self.operationID = operationID
        self.attempt = attempt
        self.phaseBefore = phaseBefore
        self.phaseAfter = phaseAfter
        self.requestDigest = requestDigest
        self.responseDigest = responseDigest
        self.errorCode = errorCode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public struct ImportObservationRecord: Sendable, Equatable {
    public let id: UUID
    public let operationID: UUID
    public let observedAt: Date
    public let kind: Kind
    public let actualUUID: String?
    public let parentPath: [String]
    public let metadataDigest: String?
    public let targetSHA256: String?
    public let matches: Bool
    public let detailDigest: String?

    public enum Kind: String, Codable, Sendable {
        case readback, lookup
    }

    public init(id: UUID = UUID(), operationID: UUID, observedAt: Date, kind: Kind,
                actualUUID: String?, parentPath: [String], metadataDigest: String?,
                targetSHA256: String?, matches: Bool, detailDigest: String?) {
        self.id = id
        self.operationID = operationID
        self.observedAt = observedAt
        self.kind = kind
        self.actualUUID = actualUUID
        self.parentPath = parentPath
        self.metadataDigest = metadataDigest
        self.targetSHA256 = targetSHA256
        self.matches = matches
        self.detailDigest = detailDigest
    }
}

// MARK: - Ledger

public struct ImportLedger: Sendable {
    let database: DatabaseQueue

    public init(database: DatabaseQueue) {
        self.database = database
    }

    // MARK: Runs

    public func startRun(_ run: ImportRunRecord) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO import_runs (id, scope_id, manifest_id, manifest_revision, profile_id,
                                         profile_version, schema_version, authorization_digest,
                                         started_at, state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [run.id.uuidString.lowercased(), run.scopeID.uuidString.lowercased(),
                                 run.manifestID.uuidString.lowercased(), run.manifestRevision,
                                 run.profileID, run.profileVersion, run.schemaVersion,
                                 run.authorizationDigest, run.startedAt.timeIntervalSince1970,
                                 run.state.rawValue])
        }
    }

    public func finishRun(_ id: UUID, state: ImportRunRecord.State) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE import_runs SET state = ? WHERE id = ?",
                           arguments: [state.rawValue, id.uuidString.lowercased()])
        }
    }

    // MARK: Intents

    /// Persists the intent for one operation key.
    ///
    /// Returns the existing record when the key was already recorded: the unique
    /// index is the idempotency guarantee, and a second intent for the same key
    /// must not be able to slip through as a second row.
    @discardableResult
    public func recordIntent(_ operation: ImportOperationRecord) throws -> (record: ImportOperationRecord, inserted: Bool) {
        try database.write { db in
            if let existing = try Self.operation(db, keyDigest: operation.keyDigest) {
                return (existing, false)
            }
            try db.execute(sql: """
                INSERT INTO import_operations (id, run_id, key_digest, source_id, snapshot_fingerprint,
                                               manifest_revision, target_association_id, operation_kind,
                                               phase, outcome, target_database, target_group_path,
                                               intended_metadata_digest, intended_metadata, actual_uuid,
                                               source_sha256, target_sha256, authorization_digest,
                                               error_code, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    operation.id.uuidString.lowercased(), operation.runID.uuidString.lowercased(),
                    operation.keyDigest, operation.sourceID.uuidString.lowercased(),
                    operation.snapshotFingerprint, operation.manifestRevision,
                    operation.targetAssociationID.uuidString.lowercased(), operation.operationKind.rawValue,
                    operation.phase.rawValue, operation.phase.outcome?.rawValue,
                    operation.targetDatabase, Self.encode(operation.targetGroupPath),
                    operation.intendedMetadataDigest, operation.intendedMetadataJSON,
                    operation.actualUUID, operation.sourceSHA256, operation.targetSHA256,
                    operation.authorizationDigest, operation.errorCode,
                    operation.createdAt.timeIntervalSince1970,
                    operation.updatedAt.timeIntervalSince1970,
                ])
            return (operation, true)
        }
    }

    public func operation(keyDigest: String) throws -> ImportOperationRecord? {
        try database.read { db in try Self.operation(db, keyDigest: keyDigest) }
    }

    public func operations(runID: UUID) throws -> [ImportOperationRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM import_operations WHERE run_id = ? ORDER BY created_at, id",
                             arguments: [runID.uuidString.lowercased()]).map { try Self.operation($0) }
        }
    }

    // MARK: Transitions

    /// Moves one operation to `next`, refusing a transition the contract forbids
    /// and refusing to touch a terminal row.
    public func transition(keyDigest: String, to next: ImportPhase, at date: Date,
                           errorCode: String? = nil) throws {
        try database.write { db in
            guard var record = try Self.operation(db, keyDigest: keyDigest) else {
                throw FormaError.storage
            }
            guard !record.phase.isTerminal else { throw FormaError.storage }
            guard record.phase.canTransition(to: next) else { throw FormaError.storage }
            record.phase = next
            record.errorCode = errorCode ?? record.errorCode
            record.updatedAt = date
            try db.execute(sql: """
                UPDATE import_operations SET phase = ?, outcome = ?, error_code = ?, updated_at = ?
                WHERE key_digest = ?
                """, arguments: [next.rawValue, next.outcome?.rawValue, record.errorCode,
                                 date.timeIntervalSince1970, keyDigest])
        }
    }

    /// Writes the target UUID exactly once. A second write is an error, not a
    /// correction: the ledger would otherwise lose which UUID the create returned.
    public func observeActualUUID(_ uuid: String, keyDigest: String, at date: Date) throws {
        try database.write { db in
            guard let record = try Self.operation(db, keyDigest: keyDigest), record.actualUUID == nil else {
                throw FormaError.storage
            }
            try db.execute(sql: "UPDATE import_operations SET actual_uuid = ?, updated_at = ? WHERE key_digest = ?",
                           arguments: [uuid, date.timeIntervalSince1970, keyDigest])
        }
    }

    public func recordTargetSHA256(_ digest: String, keyDigest: String, at date: Date) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE import_operations SET target_sha256 = ?, updated_at = ? WHERE key_digest = ?",
                           arguments: [digest, date.timeIntervalSince1970, keyDigest])
        }
    }

    // MARK: Attempts and observations

    public func appendAttempt(_ attempt: ImportAttemptRecord) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO import_attempts (id, operation_id, attempt, phase_before, phase_after,
                                             request_digest, response_digest, error_code,
                                             started_at, finished_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    attempt.id.uuidString.lowercased(), attempt.operationID.uuidString.lowercased(),
                    attempt.attempt, attempt.phaseBefore.rawValue, attempt.phaseAfter?.rawValue,
                    attempt.requestDigest, attempt.responseDigest, attempt.errorCode,
                    attempt.startedAt.timeIntervalSince1970,
                    attempt.finishedAt?.timeIntervalSince1970,
                ])
        }
    }

    public func attempts(operationID: UUID) throws -> [ImportAttemptRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM import_attempts WHERE operation_id = ? ORDER BY attempt",
                             arguments: [operationID.uuidString.lowercased()]).map { try Self.attempt($0) }
        }
    }

    public func appendObservation(_ observation: ImportObservationRecord) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO import_observations (id, operation_id, observed_at, kind, actual_uuid,
                                                 parent_path, metadata_digest, target_sha256, matches, detail_digest)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    observation.id.uuidString.lowercased(), observation.operationID.uuidString.lowercased(),
                    observation.observedAt.timeIntervalSince1970, observation.kind.rawValue,
                    observation.actualUUID, Self.encode(observation.parentPath),
                    observation.metadataDigest, observation.targetSHA256, observation.matches ? 1 : 0,
                    observation.detailDigest,
                ])
        }
    }

    public func observations(operationID: UUID) throws -> [ImportObservationRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM import_observations WHERE operation_id = ? ORDER BY observed_at",
                             arguments: [operationID.uuidString.lowercased()]).map { try Self.observation($0) }
        }
    }

    // MARK: Recovery

    /// Operations that may have an external effect. On restart these are checked
    /// read-only before anything else happens.
    public func inFlightOperations() throws -> [ImportOperationRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM import_operations WHERE phase IN (?, ?, ?, ?) ORDER BY created_at, id
                """, arguments: [ImportPhase.intentPersisted.rawValue, ImportPhase.recordObserved.rawValue,
                                 ImportPhase.metadataObserved.rawValue, ImportPhase.verifyRequired.rawValue])
                .map { try Self.operation($0) }
        }
    }

    /// Marks every in-flight operation as `verify_required`.
    ///
    /// Called once when a workspace opens: a process that died mid-operation left
    /// a state nobody can trust, and the only safe next step is a read-only check.
    @discardableResult
    public func markInterrupted(at date: Date) throws -> Int {
        try database.write { db in
            try db.execute(sql: """
                UPDATE import_operations
                SET phase = ?, outcome = ?, error_code = ?, updated_at = ?
                WHERE phase IN (?, ?, ?)
                """, arguments: [ImportPhase.verifyRequired.rawValue, ImportOutcome.verifyRequired.rawValue,
                                 "process_interrupted", date.timeIntervalSince1970,
                                 ImportPhase.intentPersisted.rawValue, ImportPhase.recordObserved.rawValue,
                                 ImportPhase.metadataObserved.rawValue])
            return db.changesCount
        }
    }

    // MARK: Single-writer lease

    /// Takes the writer lease if nobody else holds an unexpired one.
    ///
    /// A lease is not a distributed lock: it is a statement in the same database
    /// as the intents, so two processes sharing the file cannot both believe they
    /// are the writer.
    public func acquireLease(owner: String, at date: Date, duration: TimeInterval) throws -> Bool {
        try database.write { db in
            try db.execute(sql: "DELETE FROM import_leases WHERE expires_at <= ?",
                           arguments: [date.timeIntervalSince1970])
            let held = try String.fetchOne(db, sql: "SELECT owner FROM import_leases LIMIT 1")
            guard held == nil || held == owner else { return false }
            try db.execute(sql: """
                INSERT INTO import_leases (id, owner, acquired_at, expires_at) VALUES ('writer', ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET owner = excluded.owner,
                                             acquired_at = excluded.acquired_at,
                                             expires_at = excluded.expires_at
                """, arguments: [owner, date.timeIntervalSince1970,
                                 date.addingTimeInterval(duration).timeIntervalSince1970])
            return true
        }
    }

    public func releaseLease(owner: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM import_leases WHERE id = 'writer' AND owner = ?", arguments: [owner])
        }
    }

    public func leaseOwner(at date: Date) throws -> String? {
        try database.read { db in
            try String.fetchOne(db, sql: "SELECT owner FROM import_leases WHERE expires_at > ?",
                                arguments: [date.timeIntervalSince1970])
        }
    }

    // MARK: Row mapping

    private static func operation(_ db: Database, keyDigest: String) throws -> ImportOperationRecord? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM import_operations WHERE key_digest = ?",
                                         arguments: [keyDigest]) else { return nil }
        return try operation(row)
    }

    static func operation(_ row: Row) throws -> ImportOperationRecord {
        ImportOperationRecord(
            id: try uuid(row["id"]), runID: try uuid(row["run_id"]), key: try key(row),
            phase: try phase(row["phase"]), targetDatabase: row["target_database"],
            targetGroupPath: try decode(row["target_group_path"]),
            intendedMetadataDigest: row["intended_metadata_digest"],
            intendedMetadataJSON: row["intended_metadata"],
            actualUUID: row["actual_uuid"], sourceSHA256: row["source_sha256"],
            targetSHA256: row["target_sha256"], authorizationDigest: row["authorization_digest"],
            errorCode: row["error_code"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
    }

    private static func key(_ row: Row) throws -> ImportOperationKey {
        try ImportOperationKey(sourceID: uuid(row["source_id"]),
                               snapshotFingerprint: row["snapshot_fingerprint"],
                               manifestRevision: row["manifest_revision"],
                               targetAssociationID: uuid(row["target_association_id"]),
                               operationKind: ImportOperationKind(rawValue: row["operation_kind"])
                                   ?? .createRecord)
    }

    private static func attempt(_ row: Row) throws -> ImportAttemptRecord {
        ImportAttemptRecord(
            id: try uuid(row["id"]), operationID: try uuid(row["operation_id"]),
            attempt: row["attempt"], phaseBefore: try phase(row["phase_before"]),
            phaseAfter: (row["phase_after"] as String?).flatMap(ImportPhase.init(rawValue:)),
            requestDigest: row["request_digest"], responseDigest: row["response_digest"],
            errorCode: row["error_code"],
            startedAt: Date(timeIntervalSince1970: row["started_at"]),
            finishedAt: (row["finished_at"] as Double?).map(Date.init(timeIntervalSince1970:)))
    }

    private static func observation(_ row: Row) throws -> ImportObservationRecord {
        ImportObservationRecord(
            id: try uuid(row["id"]), operationID: try uuid(row["operation_id"]),
            observedAt: Date(timeIntervalSince1970: row["observed_at"]),
            kind: ImportObservationRecord.Kind(rawValue: row["kind"]) ?? .lookup,
            actualUUID: row["actual_uuid"], parentPath: try decode(row["parent_path"]),
            metadataDigest: row["metadata_digest"], targetSHA256: row["target_sha256"],
            matches: (row["matches"] as Int64) != 0, detailDigest: row["detail_digest"])
    }

    private static func phase(_ raw: String) throws -> ImportPhase {
        guard let phase = ImportPhase(rawValue: raw) else { throw FormaError.storage }
        return phase
    }

    private static func uuid(_ raw: String) throws -> UUID {
        guard let value = UUID(uuidString: raw) else { throw FormaError.storage }
        return value
    }

    static func encode(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ raw: String) throws -> [String] {
        guard let data = raw.data(using: .utf8) else { throw FormaError.storage }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}

// MARK: - Migrations

public enum ImportLedgerMigrations {
    /// Ledger v1. Append-only by construction: no migration rewrites an attempt
    /// or an observation, and terminal rows are guarded in `transition`.
    public static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("import-ledger-v1") { db in
            try db.execute(sql: """
                CREATE TABLE import_runs (
                    id TEXT PRIMARY KEY NOT NULL,
                    scope_id TEXT NOT NULL,
                    manifest_id TEXT NOT NULL,
                    manifest_revision INTEGER NOT NULL,
                    profile_id TEXT NOT NULL,
                    profile_version TEXT NOT NULL,
                    schema_version TEXT NOT NULL,
                    authorization_digest TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    state TEXT NOT NULL
                );
                CREATE TABLE import_operations (
                    id TEXT PRIMARY KEY NOT NULL,
                    run_id TEXT NOT NULL REFERENCES import_runs(id),
                    key_digest TEXT NOT NULL UNIQUE,
                    source_id TEXT NOT NULL,
                    snapshot_fingerprint TEXT NOT NULL,
                    manifest_revision INTEGER NOT NULL,
                    target_association_id TEXT NOT NULL,
                    operation_kind TEXT NOT NULL,
                    phase TEXT NOT NULL,
                    outcome TEXT,
                    target_database TEXT NOT NULL,
                    target_group_path TEXT NOT NULL,
                    intended_metadata_digest TEXT NOT NULL,
                    intended_metadata TEXT NOT NULL,
                    actual_uuid TEXT,
                    source_sha256 TEXT,
                    target_sha256 TEXT,
                    error_code TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX import_operations_run ON import_operations(run_id);
                CREATE INDEX import_operations_phase ON import_operations(phase);
                CREATE TABLE import_attempts (
                    id TEXT PRIMARY KEY NOT NULL,
                    operation_id TEXT NOT NULL REFERENCES import_operations(id),
                    attempt INTEGER NOT NULL,
                    phase_before TEXT NOT NULL,
                    phase_after TEXT,
                    request_digest TEXT NOT NULL,
                    response_digest TEXT,
                    error_code TEXT,
                    started_at REAL NOT NULL,
                    finished_at REAL,
                    UNIQUE (operation_id, attempt)
                );
                CREATE TABLE import_observations (
                    id TEXT PRIMARY KEY NOT NULL,
                    operation_id TEXT NOT NULL REFERENCES import_operations(id),
                    observed_at REAL NOT NULL,
                    kind TEXT NOT NULL,
                    actual_uuid TEXT,
                    parent_path TEXT,
                    metadata_digest TEXT,
                    target_sha256 TEXT,
                    matches INTEGER NOT NULL,
                    detail_digest TEXT
                );
                CREATE INDEX import_observations_operation ON import_observations(operation_id);
                CREATE TABLE import_leases (
                    id TEXT PRIMARY KEY NOT NULL,
                    owner TEXT NOT NULL,
                    acquired_at REAL NOT NULL,
                    expires_at REAL NOT NULL
                );
                """)
        }
        // v2 records which authorization an operation ran under. The column is
        // nullable on purpose: a row written before it stays readable, and a
        // missing digest is an absent fact rather than a fabricated one.
        migrator.registerMigration("import-ledger-v2") { db in
            try db.execute(sql: "ALTER TABLE import_operations ADD COLUMN authorization_digest TEXT")
        }
    }
}
