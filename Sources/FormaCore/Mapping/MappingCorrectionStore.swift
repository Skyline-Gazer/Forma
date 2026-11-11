import Foundation
import GRDB

/// Corrections and case candidates keep their own history rather than a column
/// on the manifest they describe: a correction is an append-only revision, and
/// a candidate case is not admissible until a reviewer says so.
enum MappingCorrectionMigrations {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("mapping-corrections-v1") { db in
            // `case_candidates` first: `corrections.case_candidate_id`
            // references it. SQLite does not resolve a foreign key's target
            // when the table is created, so the wrong order builds without
            // complaint and only fails on the first write with
            // `PRAGMA foreign_keys = ON` - which is exactly the kind of defect
            // that shows up on a user's machine rather than in a schema test.
            try db.execute(sql: """
                CREATE TABLE case_candidates (
                    id TEXT PRIMARY KEY NOT NULL,
                    correction_ids BLOB NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('candidate','reviewed','accepted','rejected')),
                    scenario TEXT NOT NULL,
                    profiles BLOB NOT NULL,
                    redaction_checked INTEGER NOT NULL,
                    duplicate_of TEXT REFERENCES case_candidates(id),
                    created_at REAL NOT NULL,
                    reviewed_at REAL
                );
                CREATE TABLE corrections (
                    id TEXT PRIMARY KEY NOT NULL,
                    manifest_id TEXT NOT NULL,
                    manifest_revision INTEGER NOT NULL,
                    supersedes_revision INTEGER,
                    source_id TEXT NOT NULL REFERENCES source_entries(id),
                    field TEXT NOT NULL,
                    previous_value TEXT,
                    corrected_value TEXT,
                    evidence_ids BLOB NOT NULL,
                    snapshot_fingerprint TEXT NOT NULL,
                    context_revision INTEGER NOT NULL,
                    origin TEXT NOT NULL CHECK(origin IN
                        ('manual','evidence_reextraction','history_reconciliation')),
                    review_state TEXT NOT NULL CHECK(review_state IN
                        ('pending','evidence_verified','rejected')),
                    case_candidate_id TEXT REFERENCES case_candidates(id),
                    created_at REAL NOT NULL
                );
                CREATE INDEX corrections_manifest ON corrections(manifest_id, manifest_revision);
                CREATE INDEX corrections_source ON corrections(source_id, field);
                """)
        }
        // The first version of this table stored one revision number whose
        // meaning depended on `review_state`: the revision produced on the
        // accepted path, the revision targeted on the refused one. Two rows for
        // one manifest could then claim the same revision while describing
        // different facts, and nothing in the schema stopped it. v2 states the
        // two facts in two columns and makes "one revision has at most one
        // producing correction" a constraint instead of a convention.
        migrator.registerMigration("mapping-corrections-v2") { db in
            try db.execute(sql: revisionSplitSQL)
        }
    }

    /// The statements that split the one ambiguous column into two honest ones.
    ///
    /// Named rather than inlined because an existing database is the only place
    /// the two `UPDATE`s do any work: a fresh one runs them over an empty table,
    /// so without a test that shapes version 1 and fills it, the arithmetic that
    /// decides which stored row created which revision would never be executed
    /// before it met a reviewer's real history.
    static let revisionSplitSQL = """
        ALTER TABLE corrections ADD COLUMN produced_revision INTEGER;
        UPDATE corrections SET produced_revision = supersedes_revision + 1
            WHERE supersedes_revision IS NOT NULL;
        UPDATE corrections SET manifest_revision = supersedes_revision
            WHERE supersedes_revision IS NOT NULL;
        ALTER TABLE corrections DROP COLUMN supersedes_revision;
        CREATE UNIQUE INDEX corrections_produced
            ON corrections(manifest_id, produced_revision)
            WHERE produced_revision IS NOT NULL;
        """
}

extension MappingStore {
    // MARK: - Corrections and case candidates

    static func insertCorrection(_ correction: CorrectionRecord, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO corrections (id, manifest_id, manifest_revision, produced_revision, source_id,
                    field, previous_value, corrected_value, evidence_ids, snapshot_fingerprint,
                    context_revision, origin, review_state, case_candidate_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [correction.id.sourceKey, correction.manifestID.sourceKey, correction.manifestRevision,
                        correction.producedRevision, correction.sourceID.sourceKey, correction.field.rawValue,
                        correction.previousValue, correction.correctedValue,
                        try FormaJSON.encode(correction.evidenceIDs), correction.snapshotFingerprint,
                        correction.contextRevision, correction.origin.rawValue, correction.reviewState.rawValue,
                        correction.caseCandidateID?.sourceKey, correction.createdAt.timeIntervalSince1970]
        )
    }

    static func corrections(manifestID: UUID, in db: Database) throws -> [CorrectionRecord] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM corrections WHERE manifest_id = ? ORDER BY created_at, manifest_revision
            """, arguments: [manifestID.sourceKey])
        return try rows.map { row in
            let rawOrigin: String = row["origin"]
            let rawState: String = row["review_state"]
            let rawField: String = row["field"]
            guard let origin = CorrectionRecord.Origin(rawValue: rawOrigin),
                  let state = CorrectionRecord.ReviewState(rawValue: rawState),
                  let field = MetadataFieldID(rawValue: rawField) else { throw FormaError.storage }
            let ids: [String] = try FormaJSON.decode([String].self, from: row["evidence_ids"])
            let candidate: String? = row["case_candidate_id"]
            return CorrectionRecord(
                id: try sourceUUID(row["id"]), manifestID: try sourceUUID(row["manifest_id"]),
                manifestRevision: row["manifest_revision"], producedRevision: row["produced_revision"],
                sourceID: try sourceUUID(row["source_id"]), field: field,
                previousValue: row["previous_value"], correctedValue: row["corrected_value"],
                evidenceIDs: ids, snapshotFingerprint: row["snapshot_fingerprint"],
                contextRevision: row["context_revision"], origin: origin, reviewState: state,
                caseCandidateID: try candidate.map { try sourceUUID($0) },
                createdAt: Date(timeIntervalSince1970: row["created_at"])
            )
        }
    }

    static func insertCaseCandidate(_ candidate: CaseCandidate, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO case_candidates (id, correction_ids, status, scenario, profiles, redaction_checked,
                    duplicate_of, created_at, reviewed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [candidate.id.sourceKey,
                        try FormaJSON.encode(candidate.correctionIDs.map { $0.sourceKey }),
                        candidate.status.rawValue, candidate.scenario, try FormaJSON.encode(candidate.profiles),
                        candidate.redactionChecked, candidate.duplicateOf?.sourceKey,
                        candidate.createdAt.timeIntervalSince1970, candidate.reviewedAt?.timeIntervalSince1970]
        )
    }

    static func updateCaseCandidate(id: UUID, status: CaseCandidate.Status, reviewedAt: Date?,
                                    redactionChecked: Bool, in db: Database) throws {
        try db.execute(
            sql: "UPDATE case_candidates SET status = ?, reviewed_at = ?, redaction_checked = ? WHERE id = ?",
            arguments: [status.rawValue, reviewedAt?.timeIntervalSince1970, redactionChecked, id.sourceKey]
        )
    }

    static func caseCandidates(in db: Database) throws -> [CaseCandidate] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM case_candidates ORDER BY created_at")
        return try rows.map { row in
            let rawStatus: String = row["status"]
            guard let status = CaseCandidate.Status(rawValue: rawStatus) else { throw FormaError.storage }
            let keys: [String] = try FormaJSON.decode([String].self, from: row["correction_ids"])
            let profiles: [String] = try FormaJSON.decode([String].self, from: row["profiles"])
            let duplicate: String? = row["duplicate_of"]
            let reviewed: Double? = row["reviewed_at"]
            return CaseCandidate(
                id: try sourceUUID(row["id"]), correctionIDs: try keys.map { try sourceUUID($0) },
                status: status, scenario: row["scenario"], profiles: profiles,
                redactionChecked: row["redaction_checked"], duplicateOf: try duplicate.map { try sourceUUID($0) },
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                reviewedAt: reviewed.map { Date(timeIntervalSince1970: $0) }
            )
        }
    }
}
