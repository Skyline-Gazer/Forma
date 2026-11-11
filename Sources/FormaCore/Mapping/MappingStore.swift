import Foundation
import GRDB

/// SQLite state for the mapping layer.
///
/// Following PLAN §4.3, the authoritative artifact is the JSON document; the
/// database keeps immutable revisions plus the indexes needed to find, bind and
/// invalidate them. A payload row is never rewritten: invalidation is recorded
/// in the entry index, so an old revision stays readable and auditable while
/// nothing may act on it.
enum MappingMigrations {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("mapping-v1") { db in
            try db.execute(sql: """
                CREATE TABLE context_revisions (
                    id TEXT PRIMARY KEY NOT NULL,
                    scope_id TEXT NOT NULL REFERENCES source_scopes(id),
                    profile_id TEXT NOT NULL,
                    profile_version TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    input_digest TEXT NOT NULL,
                    built_at REAL NOT NULL,
                    payload BLOB NOT NULL,
                    UNIQUE(scope_id, profile_id, profile_version, revision)
                );
                CREATE INDEX context_scope ON context_revisions(scope_id, profile_id, profile_version);
                -- Membership is indexed so an invalidation can name exactly the
                -- entries that depended on a context, instead of re-running the
                -- whole workspace.
                CREATE TABLE context_membership (
                    revision_id TEXT NOT NULL REFERENCES context_revisions(id),
                    source_id TEXT NOT NULL REFERENCES source_entries(id),
                    candidate_id TEXT NOT NULL,
                    PRIMARY KEY(revision_id, source_id, candidate_id)
                );
                CREATE INDEX context_membership_source ON context_membership(source_id);
                CREATE TABLE evidence_items (
                    id TEXT PRIMARY KEY NOT NULL,
                    source_id TEXT NOT NULL REFERENCES source_entries(id),
                    snapshot_revision INTEGER NOT NULL,
                    snapshot_fingerprint TEXT NOT NULL,
                    source TEXT NOT NULL CHECK(source IN
                        ('filename','path','content','sibling','fs_metadata','mcp')),
                    locator BLOB,
                    relative_path TEXT,
                    excerpt TEXT,
                    extraction_status TEXT NOT NULL,
                    extractor_version TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    context_candidate_id TEXT
                );
                CREATE INDEX evidence_source ON evidence_items(source_id, snapshot_revision);
                CREATE TABLE mapping_runs (
                    id TEXT PRIMARY KEY NOT NULL,
                    scope_id TEXT NOT NULL REFERENCES source_scopes(id),
                    profile_id TEXT NOT NULL,
                    profile_version TEXT NOT NULL,
                    context_revision INTEGER NOT NULL,
                    case_pack_version TEXT NOT NULL,
                    model_provider TEXT NOT NULL,
                    model_id TEXT,
                    prompt_version TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    finished_at REAL,
                    state TEXT NOT NULL CHECK(state IN ('running','completed','failed','cancelled')),
                    batches INTEGER NOT NULL DEFAULT 0,
                    error_code TEXT
                );
                CREATE TABLE provider_calls (
                    id TEXT PRIMARY KEY NOT NULL,
                    run_id TEXT NOT NULL REFERENCES mapping_runs(id),
                    batch_index INTEGER NOT NULL,
                    attempt INTEGER NOT NULL,
                    provider TEXT NOT NULL,
                    model_id TEXT,
                    input_tokens INTEGER,
                    output_tokens INTEGER,
                    cache_read_tokens INTEGER,
                    cache_creation_tokens INTEGER,
                    latency_ms INTEGER,
                    outcome TEXT NOT NULL CHECK(outcome IN ('ok','invalid_output','refused','truncated',
                        'network','timeout','remote_status','cancelled','unauthorized','credential_missing')),
                    error_code TEXT,
                    created_at REAL NOT NULL,
                    UNIQUE(run_id, batch_index, attempt)
                );
                CREATE TABLE manifests (
                    manifest_id TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    scope_id TEXT NOT NULL REFERENCES source_scopes(id),
                    profile_id TEXT NOT NULL,
                    profile_version TEXT NOT NULL,
                    context_revision INTEGER NOT NULL,
                    case_pack_version TEXT NOT NULL,
                    model_provider TEXT NOT NULL,
                    model_id TEXT,
                    input_digest TEXT NOT NULL,
                    context_digest TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('draft','validated','partially_validated','invalidated')),
                    created_at REAL NOT NULL,
                    payload BLOB NOT NULL,
                    PRIMARY KEY(manifest_id, revision)
                );
                CREATE INDEX manifests_scope ON manifests(scope_id, profile_id, created_at);
                CREATE TABLE manifest_entries (
                    manifest_id TEXT NOT NULL,
                    manifest_revision INTEGER NOT NULL,
                    source_id TEXT NOT NULL REFERENCES source_entries(id),
                    snapshot_fingerprint TEXT NOT NULL,
                    snapshot_revision INTEGER NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('unknown','hold','mapped','validated','invalidated')),
                    eligible_for_auto_execution INTEGER NOT NULL,
                    invalidated_reason TEXT,
                    PRIMARY KEY(manifest_id, manifest_revision, source_id),
                    FOREIGN KEY(manifest_id, manifest_revision) REFERENCES manifests(manifest_id, revision)
                );
                CREATE INDEX manifest_entries_source ON manifest_entries(source_id);
                CREATE TABLE manifest_entry_evidence (
                    manifest_id TEXT NOT NULL,
                    manifest_revision INTEGER NOT NULL,
                    source_id TEXT NOT NULL,
                    field TEXT NOT NULL,
                    evidence_id TEXT NOT NULL REFERENCES evidence_items(id),
                    PRIMARY KEY(manifest_id, manifest_revision, source_id, field, evidence_id)
                );
                """)
        }
    }
}

enum MappingStore {
    // MARK: - Context revisions

    static func insertContext(_ context: ProjectContext, scopeID: UUID, in db: Database) throws {
        let id = UUID()
        let payload = try FormaJSON.encode(context)
        try db.execute(
            sql: """
                INSERT INTO context_revisions (id, scope_id, profile_id, profile_version, revision,
                    input_digest, built_at, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [id.sourceKey, scopeID.sourceKey, context.profileID, context.profileVersion,
                        context.revision, context.inputDigest, context.builtAt.timeIntervalSince1970, payload]
        )
        for candidate in context.candidates {
            for sourceID in candidate.memberSourceIDs {
                try db.execute(
                    sql: "INSERT INTO context_membership (revision_id, source_id, candidate_id) VALUES (?, ?, ?)",
                    arguments: [id.sourceKey, sourceID.sourceKey, candidate.id]
                )
            }
        }
    }

    /// The newest context for a scope and profile version whose recorded inputs
    /// still match. A digest mismatch returns nil rather than a stale context.
    static func currentContext(scopeID: UUID, profile: MappingProfile, inputDigest: String,
                               in db: Database) throws -> ProjectContext? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT payload FROM context_revisions
            WHERE scope_id = ? AND profile_id = ? AND profile_version = ? AND input_digest = ?
            ORDER BY revision DESC LIMIT 1
            """, arguments: [scopeID.sourceKey, profile.profileID, profile.profileVersion, inputDigest]),
              let data: Data = row["payload"] else { return nil }
        return try FormaJSON.decode(ProjectContext.self, from: data)
    }

    /// The stored context at one exact revision. Reconciliation compares a
    /// manifest's own context against the current one, so the revision it cites
    /// must stay readable after newer revisions exist.
    static func context(scopeID: UUID, profile: MappingProfile, revision: Int, in db: Database) throws
        -> ProjectContext?
    {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT payload FROM context_revisions WHERE scope_id = ? AND profile_id = ? AND profile_version = ?
              AND revision = ?
            """, arguments: [scopeID.sourceKey, profile.profileID, profile.profileVersion, revision]),
              let payload: Data = row["payload"] else { return nil }
        return try FormaJSON.decode(ProjectContext.self, from: payload)
    }

    static func nextContextRevision(scopeID: UUID, profile: MappingProfile, in db: Database) throws -> Int {
        let row = try Row.fetchOne(db, sql: """
            SELECT MAX(revision) AS revision FROM context_revisions
            WHERE scope_id = ? AND profile_id = ? AND profile_version = ?
            """, arguments: [scopeID.sourceKey, profile.profileID, profile.profileVersion])
        let stored: Int? = row?["revision"]
        return (stored ?? 0) + 1
    }

    // MARK: - Evidence registry

    /// Registers what a read observed, without deleting what an earlier read
    /// observed.
    ///
    /// A stored manifest cites evidence by id, and `manifest_entry_evidence`
    /// carries a foreign key into `evidence_items`. Deleting the previous rows
    /// therefore failed that constraint the moment a filed document was read
    /// again, and even without the key it would have destroyed the only record
    /// of what an older revision was decided from. Rows are keyed by source,
    /// snapshot revision and locator, so history accumulates and a caller
    /// selects the revision it means.
    static func recordEvidence(_ records: [EvidenceRecord], in db: Database) throws {
        try insertEvidence(records, in: db)
    }

    static func insertEvidence(_ records: [EvidenceRecord], in db: Database) throws {
        for record in records {
            let locator = try record.locator.map { try FormaJSON.encode($0) }
            try db.execute(
                sql: """
                    INSERT INTO evidence_items (id, source_id, snapshot_revision, snapshot_fingerprint, source,
                        locator, relative_path, excerpt, extraction_status, extractor_version, created_at,
                        context_candidate_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        source_id = excluded.source_id,
                        snapshot_revision = excluded.snapshot_revision,
                        snapshot_fingerprint = excluded.snapshot_fingerprint,
                        source = excluded.source,
                        locator = excluded.locator,
                        relative_path = excluded.relative_path,
                        excerpt = excluded.excerpt,
                        extraction_status = excluded.extraction_status,
                        extractor_version = excluded.extractor_version,
                        created_at = excluded.created_at,
                        context_candidate_id = excluded.context_candidate_id
                    """,
                arguments: [record.id, record.sourceID.sourceKey, record.snapshotRevision,
                            record.snapshotFingerprint, record.source.rawValue, locator, record.relativePath,
                            record.excerpt, record.extractionStatus.rawValue, record.extractorVersion,
                            record.createdAt.timeIntervalSince1970, record.contextCandidateID]
            )
        }
    }

    static func evidence(ids: Set<String>, in db: Database) throws -> [String: EvidenceRecord] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM evidence_items WHERE id IN (\(placeholders))",
            arguments: StatementArguments(Array(ids))
        )
        var result: [String: EvidenceRecord] = [:]
        for row in rows {
            let record = try Self.decodeEvidence(row)
            result[record.id] = record
        }
        return result
    }

    /// Every row ever registered for a source, oldest first by id. Audit and
    /// offline revalidation read this; a mapping request must use the current
    /// snapshot revision instead.
    static func evidence(for sourceID: UUID, in db: Database) throws -> [EvidenceRecord] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM evidence_items WHERE source_id = ? ORDER BY id
            """, arguments: [sourceID.sourceKey])
        return try rows.map { try Self.decodeEvidence($0) }
    }

    /// The rows that describe the file as it is now. Evidence from a superseded
    /// snapshot is still in the table for audit, but it may not support a
    /// current decision.
    static func evidence(for sourceID: UUID, snapshotRevision: Int, in db: Database) throws
        -> [EvidenceRecord]
    {
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM evidence_items WHERE source_id = ? AND snapshot_revision = ? ORDER BY id
            """, arguments: [sourceID.sourceKey, snapshotRevision])
        return try rows.map { try Self.decodeEvidence($0) }
    }

    private static func decodeEvidence(_ row: Row) throws -> EvidenceRecord {
        let rawSource: String = row["source"]
        let rawStatus: String = row["extraction_status"]
        guard let source = EvidenceSource(rawValue: rawSource),
              let status = EvidenceStatus(rawValue: rawStatus) else { throw FormaError.storage }
        let locatorData: Data? = row["locator"]
        return EvidenceRecord(
            id: row["id"],
            sourceID: try sourceUUID(row["source_id"]),
            snapshotRevision: row["snapshot_revision"],
            snapshotFingerprint: row["snapshot_fingerprint"],
            source: source,
            locator: try locatorData.map { try FormaJSON.decode(EvidenceLocator.self, from: $0) },
            relativePath: row["relative_path"],
            excerpt: row["excerpt"],
            extractionStatus: status,
            extractorVersion: row["extractor_version"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            contextCandidateID: row["context_candidate_id"]
        )
    }

    // MARK: - Manifests

    /// Stores one immutable revision. The payload keeps the original decision
    /// states; the index carries the current validity flags.
    static func insertManifest(_ manifest: Manifest, scopeID: UUID, in db: Database) throws {
        let payload = try FormaJSON.encode(manifest)
        try db.execute(
            sql: """
                INSERT INTO manifests (manifest_id, revision, scope_id, profile_id, profile_version,
                    context_revision, case_pack_version, model_provider, model_id, input_digest,
                    context_digest, state, created_at, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [manifest.envelope.manifestID.sourceKey, manifest.envelope.revision,
                        scopeID.sourceKey, manifest.envelope.profileID, manifest.envelope.profileVersion,
                        manifest.envelope.contextRevision, manifest.envelope.casePackVersion,
                        manifest.envelope.modelProvider, manifest.envelope.modelID,
                        manifest.envelope.inputDigest, manifest.envelope.contextDigest,
                        manifest.envelope.state.rawValue,
                        manifest.envelope.createdAt.timeIntervalSince1970, payload]
        )
        for entry in manifest.entries {
            try db.execute(
                sql: """
                    INSERT INTO manifest_entries (manifest_id, manifest_revision, source_id,
                        snapshot_fingerprint, snapshot_revision, state, eligible_for_auto_execution,
                        invalidated_reason)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [manifest.envelope.manifestID.sourceKey, manifest.envelope.revision,
                            entry.sourceID.sourceKey, entry.snapshotFingerprint, entry.snapshotRevision,
                            entry.state.rawValue, entry.eligibleForAutoExecution, entry.invalidatedReason]
            )
            for outcome in entry.fields {
                for evidenceID in outcome.evidenceIDs {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO manifest_entry_evidence (manifest_id, manifest_revision,
                                source_id, field, evidence_id)
                            VALUES (?, ?, ?, ?, ?)
                            """,
                        arguments: [manifest.envelope.manifestID.sourceKey, manifest.envelope.revision,
                                    entry.sourceID.sourceKey, outcome.field.rawValue, evidenceID]
                    )
                }
            }
        }
    }

    /// Reads a revision and overlays the stored validity flags, so an
    /// invalidated entry is reported as invalidated without rewriting history.
    static func manifest(id: UUID, revision: Int, in db: Database) throws -> Manifest? {
        guard let header = try Row.fetchOne(db, sql: """
            SELECT payload, state FROM manifests WHERE manifest_id = ? AND revision = ?
            """, arguments: [id.sourceKey, revision]),
              let payload: Data = header["payload"] else { return nil }
        var manifest = try FormaJSON.decode(Manifest.self, from: payload)
        let indexRows = try Row.fetchAll(db, sql: """
            SELECT source_id, state, eligible_for_auto_execution, invalidated_reason
            FROM manifest_entries WHERE manifest_id = ? AND manifest_revision = ?
            """, arguments: [id.sourceKey, revision])
        var bySource: [UUID: Row] = [:]
        for row in indexRows {
            bySource[try sourceUUID(row["source_id"])] = row
        }
        for position in manifest.entries.indices {
            guard let row = bySource[manifest.entries[position].sourceID] else { continue }
            let rawState: String = row["state"]
            if let state = DecisionState(rawValue: rawState) { manifest.entries[position].state = state }
            let eligible: Bool = row["eligible_for_auto_execution"]
            manifest.entries[position].eligibleForAutoExecution = eligible
            manifest.entries[position].invalidatedReason = row["invalidated_reason"]
        }
        let rawManifestState: String = header["state"]
        manifest.envelope.state = ManifestEnvelope.ManifestState(rawValue: rawManifestState) ?? .draft
        return manifest
    }

    static func latestManifest(scopeID: UUID, profile: MappingProfile, in db: Database) throws -> Manifest? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT manifest_id, revision FROM manifests
            WHERE scope_id = ? AND profile_id = ? AND profile_version = ?
            ORDER BY created_at DESC, revision DESC LIMIT 1
            """, arguments: [scopeID.sourceKey, profile.profileID, profile.profileVersion]),
              let storedID: String = row["manifest_id"] else { return nil }
        let revision: Int = row["revision"]
        return try manifest(id: try sourceUUID(storedID), revision: revision, in: db)
    }

    static func nextManifestRevision(manifestID: UUID, in db: Database) throws -> Int {
        let row = try Row.fetchOne(db, sql: "SELECT MAX(revision) AS revision FROM manifests WHERE manifest_id = ?",
                                   arguments: [manifestID.sourceKey])
        let stored: Int? = row?["revision"]
        return (stored ?? 0) + 1
    }

    /// Marks the named entries of a revision unusable. Entries not listed keep
    /// their state, which is what "only the affected items" means.
    static func invalidate(manifestID: UUID, revision: Int, sourceIDs: Set<UUID>?, reason: String,
                           in db: Database) throws {
        if let sourceIDs, !sourceIDs.isEmpty {
            let keys = sourceIDs.map(\.sourceKey)
            let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
            let head: [(any DatabaseValueConvertible)?] = [reason, manifestID.sourceKey, revision]
            let tail: [(any DatabaseValueConvertible)?] = keys.map { $0 as (any DatabaseValueConvertible)? }
            try db.execute(
                sql: """
                    UPDATE manifest_entries SET state = 'invalidated', eligible_for_auto_execution = 0,
                        invalidated_reason = ?
                    WHERE manifest_id = ? AND manifest_revision = ? AND source_id IN (\(placeholders))
                    """,
                arguments: StatementArguments(head + tail)
            )
        } else {
            try db.execute(
                sql: """
                    UPDATE manifest_entries SET state = 'invalidated', eligible_for_auto_execution = 0,
                        invalidated_reason = ?
                    WHERE manifest_id = ? AND manifest_revision = ?
                    """,
                arguments: [reason, manifestID.sourceKey, revision]
            )
        }
        try db.execute(
            sql: "UPDATE manifests SET state = 'invalidated' WHERE manifest_id = ? AND revision = ?",
            arguments: [manifestID.sourceKey, revision]
        )
    }

    // MARK: - Runs and provider calls

    static func startRun(_ run: MappingRun, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO mapping_runs (id, scope_id, profile_id, profile_version, context_revision,
                    case_pack_version, model_provider, model_id, prompt_version, started_at, state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'running')
                """,
            arguments: [run.id.sourceKey, run.scopeID.sourceKey, run.profileID, run.profileVersion,
                        run.contextRevision, run.casePackVersion, run.modelProvider, run.modelID,
                        run.promptVersion, run.startedAt.timeIntervalSince1970]
        )
    }

    static func finishRun(id: UUID, state: MappingRun.State, batches: Int, error: FormaError?,
                          finishedAt: Date, in db: Database) throws {
        try db.execute(
            sql: "UPDATE mapping_runs SET state = ?, batches = ?, error_code = ?, finished_at = ? WHERE id = ?",
            arguments: [state.rawValue, batches, error?.code, finishedAt.timeIntervalSince1970, id.sourceKey]
        )
    }

    /// Runs left `running` by a crash are reported, never silently resumed: the
    /// engine treats them as failed so a manifest cannot cite an unfinished run.
    static func markInterruptedRuns(in db: Database) throws {
        try db.execute(
            sql: """
                UPDATE mapping_runs SET state = 'failed', error_code = 'interrupted'
                WHERE state = 'running'
                """,
            arguments: []
        )
    }

    static func recordProviderCall(_ call: ProviderCall, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO provider_calls (id, run_id, batch_index, attempt, provider, model_id,
                    input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, latency_ms,
                    outcome, error_code, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [call.id.sourceKey, call.runID.sourceKey, call.batchIndex, call.attempt,
                        call.provider, call.modelID, call.inputTokens, call.outputTokens,
                        call.cacheReadTokens, call.cacheCreationTokens, call.latencyMilliseconds,
                        call.outcome.rawValue, call.errorCode, call.createdAt.timeIntervalSince1970]
        )
    }

    static func providerCalls(runID: UUID, in db: Database) throws -> [ProviderCall] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM provider_calls WHERE run_id = ? ORDER BY batch_index, attempt
            """, arguments: [runID.sourceKey])
        return try rows.map { row in
            let rawOutcome: String = row["outcome"]
            guard let outcome = MappingOutcome(rawValue: rawOutcome) else { throw FormaError.storage }
            return ProviderCall(
                id: try sourceUUID(row["id"]),
                runID: try sourceUUID(row["run_id"]),
                batchIndex: row["batch_index"],
                attempt: row["attempt"],
                provider: row["provider"],
                modelID: row["model_id"],
                inputTokens: row["input_tokens"],
                outputTokens: row["output_tokens"],
                cacheReadTokens: row["cache_read_tokens"],
                cacheCreationTokens: row["cache_creation_tokens"],
                latencyMilliseconds: row["latency_ms"],
                outcome: outcome,
                errorCode: row["error_code"],
                createdAt: Date(timeIntervalSince1970: row["created_at"])
            )
        }
    }
}

public struct MappingRun: Sendable {
    public enum State: String, Sendable {
        case running, completed, failed, cancelled
    }

    public let id: UUID
    public let scopeID: UUID
    let profileID: String
    let profileVersion: String
    let contextRevision: Int
    let casePackVersion: String
    let modelProvider: String
    let modelID: String?
    let promptVersion: String
    let startedAt: Date

    /// The run identity is built from the versions that produced it, so a report
    /// can say which profile, context, case pack and model answered.
    public init(id: UUID = UUID(), scopeID: UUID, profile: MappingProfile, contextRevision: Int,
                casePackVersion: String, modelProvider: String, modelID: String?, promptVersion: String,
                startedAt: Date = .now) {
        self.id = id
        self.scopeID = scopeID
        self.profileID = profile.profileID
        self.profileVersion = profile.profileVersion
        self.contextRevision = contextRevision
        self.casePackVersion = casePackVersion
        self.modelProvider = modelProvider
        self.modelID = modelID
        self.promptVersion = promptVersion
        self.startedAt = startedAt
    }
}

/// One provider request inside a run: what was asked, what it cost, how long it
/// took and how it ended. The interface shows these, so every field is public.
public struct ProviderCall: Sendable {
    public let id: UUID
    public let runID: UUID
    public let batchIndex: Int
    public let attempt: Int
    public let provider: String
    public let modelID: String?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheCreationTokens: Int?
    public let latencyMilliseconds: Int?
    public let outcome: MappingOutcome
    public let errorCode: String?
    public let createdAt: Date

    public init(id: UUID, runID: UUID, batchIndex: Int, attempt: Int, provider: String, modelID: String?,
                inputTokens: Int?, outputTokens: Int?, cacheReadTokens: Int?, cacheCreationTokens: Int?,
                latencyMilliseconds: Int?, outcome: MappingOutcome, errorCode: String?, createdAt: Date) {
        self.id = id
        self.runID = runID
        self.batchIndex = batchIndex
        self.attempt = attempt
        self.provider = provider
        self.modelID = modelID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.latencyMilliseconds = latencyMilliseconds
        self.outcome = outcome
        self.errorCode = errorCode
        self.createdAt = createdAt
    }
}
