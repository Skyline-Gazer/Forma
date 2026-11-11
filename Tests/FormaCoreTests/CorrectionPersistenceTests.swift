import Foundation
import GRDB
import Testing

@testable import FormaCore

/// Where a reviewer's decision actually lands.
///
/// `CorrectionEngine` decides in isolation; this suite is the path the app uses,
/// where the workspace gathers the listing, the context revision and the
/// registered rows, the engine rules the decision, and the store keeps what
/// happened. The two things worth pinning are that an accepted correction
/// becomes a real stored revision and that a refused one changes no revision at
/// all while still being readable afterwards.
@Suite("Correction persistence")
struct CorrectionPersistenceTests {
    private struct Prepared {
        let fixture: SourceFixture
        let workspace: SourceWorkspace
        let scope: SourceScope
        let profile: MappingProfile
        let manifest: Manifest
        let sourceID: UUID
        let yearRow: String
    }

    /// A workspace with one scanned file, its body evidence registered, and a
    /// stored manifest that cites rows the registry can resolve.
    private func prepared() async throws -> Prepared {
        let fixture = try SourceFixture()
        // A real PDF, because a correction has to cite body evidence: text
        // under a `.pdf` name yields no content rows, and the test would then
        // be judging a citation to a filename.
        let body = try makePDF(["示例项目_2026 招标公告 归档完成 2027 年"])
        let url = fixture.root.appendingPathComponent("示例项目_2026/01_招标/公告.pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try body.write(to: url)
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let listing = try await workspace.scan(scope)
        let profile = try MappingProfile.projectArchive()
        // The context a manifest was decided from has to exist in the store,
        // because that is the context the correction is revalidated against.
        // Building it here is what makes the fixture describe a real revision
        // instead of inventing one.
        let context = try await workspace.buildContext(scope: scope, profile: profile)
        let registered = try await workspace.captureEvidence(for: listing.entries)
        // Re-read the listing after capturing: registering a body can advance
        // the snapshot revision, and a manifest built from the pre-capture
        // revision would be blocked by its own snapshot binding before the
        // correction is even judged.
        let current = try await workspace.scan(scope)
        let entry = try #require(current.entries.first)
        let rows = (registered[entry.id] ?? []).filter { $0.snapshotRevision == entry.snapshotRevision }
        // The body says 2027; the stored manifest claims 2026. That is the
        // mistake a reviewer corrects, and the row that supports the fix.
        let year = try #require(rows.first { ($0.excerpt ?? "").contains("2027") && $0.isUsable })
        let category = try #require(rows.first { ($0.excerpt ?? "").contains("招标") && $0.isUsable })

        var metadata = MetadataValues.allUnknown
        metadata[.documentcategory] = "01_招标文件"
        metadata[.projectname] = "示例项目_2026"
        metadata[.completionyear] = "2026"
        var fields: [FieldOutcome] = []
        for field in MetadataFieldID.allCases {
            let value = metadata[field]
            let citations: [String]
            switch field {
            case .documentcategory: citations = [category.id]
            case .completionyear: citations = [year.id]
            default: citations = []
            }
            fields.append(FieldOutcome(field: field, value: value,
                                       status: value == nil ? .unknown : .evidenced,
                                       evidenceIDs: citations))
        }
        let manifest = Manifest(
            envelope: ManifestEnvelope(
                manifestID: UUID(), revision: 1, supersedesRevision: nil, scopeID: scope.id,
                sourceRootID: scope.rootID, profile: profile,
                casePack: ("forma-governance-cases", "1.0"), modelProvider: "anthropic",
                modelID: "fake", contextRevision: context.revision, promptVersion: MappingPrompt.version,
                extractorVersion: EvidenceRegistry.extractorVersion, redactionVersion: nil,
                inputDigest: context.inputDigest, contextDigest: MappingEngine.contextDigest(context),
                createdAt: .now, state: .draft
            ),
            entries: [ManifestEntry(
                sourceID: entry.id, snapshotFingerprint: entry.snapshotFingerprint,
                snapshotRevision: Int(entry.snapshotRevision), sourceVersion: Int(entry.sourceVersion),
                relativePath: entry.relativePath, state: .validated,
                target: ManifestTarget(databaseName: "Project_Archive",
                                       groupPath: ["2026", "示例项目_2026", "01_招标文件"], resolved: true),
                metadata: metadata, fields: fields, associations: [],
                eligibleForAutoExecution: false, invalidatedReason: nil, confidence: .medium,
                providerReasoning: nil
            )]
        )
        let stored = try await workspace.saveManifest(manifest, scopeID: scope.id)
        return Prepared(fixture: fixture, workspace: workspace, scope: scope, profile: profile,
                        manifest: stored, sourceID: entry.id, yearRow: year.id)
    }

    @Test("an accepted correction is stored as the next revision and read back")
    func acceptedCorrectionPersists() async throws {
        let context = try await prepared()
        defer { context.fixture.cleanUp() }
        let applied = try await context.workspace.applyCorrection(
            to: context.manifest, sourceID: context.sourceID, field: .completionyear,
            correctedValue: "2027", evidenceIDs: [context.yearRow], origin: .manual,
            scope: context.scope, profile: context.profile)
        #expect(applied.violations.isEmpty, "violations: \(applied.violations.map(\.code))")
        let stored = try #require(await context.workspace.currentManifest(scope: context.scope,
                                                                         profile: context.profile))
        #expect(stored.envelope.revision > context.manifest.envelope.revision,
                "the accepted decision has to become a later revision")
        #expect(stored.entries[0].metadata[.completionyear] == "2027")
        let history = try await context.workspace.corrections(manifestID: context.manifest.envelope.manifestID)
        #expect(history.count == 1)
        #expect(history[0].reviewState == .evidenceVerified)
        #expect(history[0].previousValue == "2026", "the value it replaced is part of the record")
    }

    @Test("a refused correction stores the attempt and changes no revision")
    func refusedCorrectionChangesNothing() async throws {
        let context = try await prepared()
        defer { context.fixture.cleanUp() }
        // A value with nothing cited: an opinion, not a decision.
        let applied = try await context.workspace.applyCorrection(
            to: context.manifest, sourceID: context.sourceID, field: .issuer,
            correctedValue: "示例厂商乙", evidenceIDs: [], origin: .manual,
            scope: context.scope, profile: context.profile)
        #expect(applied.violations.contains { $0.code == "evidence_not_found" })
        let stored = try #require(await context.workspace.currentManifest(scope: context.scope,
                                                                        profile: context.profile))
        #expect(stored.envelope.revision == context.manifest.envelope.revision,
                "a refused attempt must not publish a revision")
        #expect(stored.entries[0].metadata[.issuer] == nil)
        let history = try await context.workspace.corrections(manifestID: context.manifest.envelope.manifestID)
        #expect(history.count == 1, "the refusal itself is the record a reviewer needs")
        #expect(history[0].reviewState == .rejected)
    }

    @Test("a correction citing another snapshot is refused")
    func staleSnapshotCitationRefused() async throws {
        let context = try await prepared()
        defer { context.fixture.cleanUp() }
        // `ev_from_another_build` is not in the registry at all, which is the
        // same failure as citing a row from a superseded snapshot: the manifest
        // could not resolve it later.
        let applied = try await context.workspace.applyCorrection(
            to: context.manifest, sourceID: context.sourceID, field: .completionyear,
            correctedValue: "2028", evidenceIDs: ["ev_absent"], origin: .manual,
            scope: context.scope, profile: context.profile)
        #expect(applied.violations.contains { $0.code == "evidence_not_found" })
        let stored = try #require(await context.workspace.currentManifest(scope: context.scope,
                                                                        profile: context.profile))
        #expect(stored.entries[0].metadata[.completionyear] == "2026")
    }

    @Test("a correction never writes project context history")
    func correctionLeavesContextHistoryAlone() async throws {
        let context = try await prepared()
        defer { context.fixture.cleanUp() }
        // An unrelated file appears after the manifest was produced. Rebuilding
        // the context at correction time - which is what this path used to do -
        // would persist a new context revision behind a human click and judge
        // the edited entry against candidate sets that never generated the
        // answer under review, so a correct fix could be refused for citing a
        // candidate this manifest never had.
        let url = context.fixture.root.appendingPathComponent("示例项目_2026/01_招标/补充.pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try makePDF(["示例项目_2026 补充说明"]).write(to: url)
        _ = try await context.workspace.scan(context.scope)
        let cited = context.manifest.envelope.contextRevision
        let applied = try await context.workspace.applyCorrection(
            to: context.manifest, sourceID: context.sourceID, field: .completionyear,
            correctedValue: "2027", evidenceIDs: [context.yearRow], origin: .manual,
            scope: context.scope, profile: context.profile)
        #expect(applied.violations.isEmpty, "violations: \(applied.violations.map(\.code))")
        #expect(try await context.workspace.storedContext(scope: context.scope, profile: context.profile,
                                                          revision: cited + 1) == nil,
                "a correction decides about a manifest, not an event in the context history")
        let published = try #require(await context.workspace.currentManifest(scope: context.scope,
                                                                            profile: context.profile))
        #expect(published.envelope.contextRevision == cited,
                "the published revision still answers the context revision it cites")
    }

    @Test("a refusal and a later decision do not claim the same revision")
    func refusalAndAcceptanceStayDistinguishable() async throws {
        let context = try await prepared()
        defer { context.fixture.cleanUp() }
        // Refused first: it cites nothing, so it publishes nothing.
        let refused = try await context.workspace.applyCorrection(
            to: context.manifest, sourceID: context.sourceID, field: .issuer,
            correctedValue: "示例厂商乙", evidenceIDs: [], origin: .manual,
            scope: context.scope, profile: context.profile)
        #expect(!refused.violations.isEmpty)
        // Then accepted against the revision that is still current. The pair is
        // the sequence that made one column ambiguous: a refusal aimed at
        // revision 1 and a decision that produced revision 2 both named a
        // revision number, and nothing said which kind.
        let current = try #require(await context.workspace.currentManifest(scope: context.scope,
                                                                          profile: context.profile))
        let accepted = try await context.workspace.applyCorrection(
            to: current, sourceID: context.sourceID, field: .completionyear,
            correctedValue: "2027", evidenceIDs: [context.yearRow], origin: .manual,
            scope: context.scope, profile: context.profile)
        #expect(accepted.violations.isEmpty, "violations: \(accepted.violations.map(\.code))")
        let history = try await context.workspace.corrections(manifestID: context.manifest.envelope.manifestID)
        #expect(history.count == 2)
        let refusal = try #require(history.first { $0.reviewState == .rejected })
        let decision = try #require(history.first { $0.reviewState == .evidenceVerified })
        #expect(refusal.producedRevision == nil, "a refusal produces nothing, so it names no revision")
        #expect(refusal.manifestRevision == current.envelope.revision,
                "the version the reviewer was looking at is still part of the record")
        #expect(decision.manifestRevision == 1 && decision.producedRevision == 2,
                "the accepted decision names both what it read and what it wrote")
    }

    @Test("storage refuses two corrections claiming the same revision")
    func producedRevisionIsUniqueInStorage() async throws {
        let context = try await prepared()
        defer { context.fixture.cleanUp() }
        let store = try SourceStore(url: context.fixture.database)
        let manifestID = context.manifest.envelope.manifestID
        // Two claims on one produced revision, different rows and different
        // fields, so the only thing they share is the version they say they
        // created. Both records are built outside the transactions: a value
        // that a `@Sendable` write closure has to reach across a suspension
        // boundary is exactly what the concurrency checks refuse, and a test
        // that only compiles on one toolchain proves nothing.
        let first = CorrectionRecord(id: UUID(), manifestID: manifestID, manifestRevision: 1,
                                     producedRevision: 2, sourceID: context.sourceID, field: .completionyear,
                                     previousValue: "2026", correctedValue: "2027", evidenceIDs: [context.yearRow],
                                     snapshotFingerprint: "f", contextRevision: 1, origin: .manual,
                                     reviewState: .evidenceVerified)
        let second = CorrectionRecord(id: UUID(), manifestID: manifestID, manifestRevision: 1,
                                      producedRevision: 2, sourceID: context.sourceID, field: .issuer,
                                      previousValue: nil, correctedValue: "示例厂商乙",
                                      evidenceIDs: [context.yearRow], snapshotFingerprint: "f",
                                      contextRevision: 1, origin: .manual, reviewState: .evidenceVerified)
        try await store.database.write { db in try MappingStore.insertCorrection(first, in: db) }
        var refusal: (any Error)?
        do {
            try await store.database.write { db in try MappingStore.insertCorrection(second, in: db) }
        } catch {
            refusal = error
        }
        #expect(refusal != nil,
                "one revision has at most one producing correction, and that is a constraint, not a habit")
    }

    @Test("an existing history is split without losing who produced what")
    func legacyRowsSplitOntoTheNewColumns() throws {
        // The two `UPDATE`s in the migration do nothing at all on a fresh
        // database: version 1 creates the table, version 2 immediately splits a
        // column of an empty one. Every other test in this suite therefore
        // passes without ever executing the arithmetic that decides which
        // stored row created which revision. This is that arithmetic, run
        // against a database shaped like the version the migration expects to
        // find - one accepted decision that produced revision 2, one refusal
        // aimed at revision 3 that produced nothing.
        // Every identifier here is in the shape the store writes: the row's own
        // id is read back through the same decoder that would refuse a value it
        // cannot parse, so inventing a readable label would fail on the read
        // rather than test the split.
        let manifestID = UUID()
        let sourceID = UUID()
        let acceptedID = UUID()
        let refusedID = UUID()
        let db = try DatabaseQueue()
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE source_entries (id TEXT PRIMARY KEY NOT NULL);
                CREATE TABLE case_candidates (id TEXT PRIMARY KEY NOT NULL);
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
                    origin TEXT NOT NULL,
                    review_state TEXT NOT NULL,
                    case_candidate_id TEXT REFERENCES case_candidates(id),
                    created_at REAL NOT NULL
                );
                INSERT INTO source_entries (id) VALUES ('\(sourceID.sourceKey)');
                INSERT INTO corrections (id, manifest_id, manifest_revision, supersedes_revision,
                    source_id, field, previous_value, corrected_value, evidence_ids,
                    snapshot_fingerprint, context_revision, origin, review_state,
                    case_candidate_id, created_at)
                VALUES ('\(acceptedID.sourceKey)', '\(manifestID.sourceKey)', 2, 1, '\(sourceID.sourceKey)',
                        'completionyear', '2026', '2027', X'5B5D', 'f', 1, 'manual',
                        'evidence_verified', NULL, 1),
                       ('\(refusedID.sourceKey)', '\(manifestID.sourceKey)', 3, NULL, '\(sourceID.sourceKey)',
                        'issuer', NULL, '示例厂商乙', X'5B5D', 'f', 1, 'manual',
                        'rejected', NULL, 2);
                """)
        }
        try db.write { db in try db.execute(sql: MappingCorrectionMigrations.revisionSplitSQL) }
        let rows = try db.read { db in try MappingStore.corrections(manifestID: manifestID, in: db) }
        #expect(rows.count == 2)
        let accepted = try #require(rows.first { $0.reviewState == .evidenceVerified })
        #expect(accepted.manifestRevision == 1 && accepted.producedRevision == 2,
                "the row that created revision 2 must not end up calling 2 the version it read")
        let refused = try #require(rows.first { $0.reviewState == .rejected })
        #expect(refused.manifestRevision == 3 && refused.producedRevision == nil,
                "a refusal targeted 3 and produced nothing, and the split has to say so")
    }

    @Test("an existing version 1 history survives the registered migration")
    func registeredMigrationSplitsAVersionOneHistory() async throws {
        // `legacyRowsSplitOntoTheNewColumns` runs the statements against a
        // hand-made table; this runs the migration the way an updater does. The
        // difference is not cosmetic: `DROP COLUMN supersedes_revision` on the
        // real `corrections` goes through SQLite's rebuild path while a foreign
        // key from `case_candidates` and two indexes point at that table, and
        // only the registered migrator exercises that ordering. A migration
        // that broke there would leave every reviewer's existing workspace
        // unopenable - `Workspace unavailable` on launch - while a test that
        // only checks the SQL text stayed green.
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.write("示例项目_2026 招标公告 归档完成 2027 年", at: "示例项目_2026/01_招标/公告.txt")
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let listing = try await workspace.scan(scope)
        // A source row that really exists: `corrections.source_id` references
        // `source_entries` and foreign keys are on, so an invented label would
        // fail the insert for the wrong reason.
        let sourceID = try #require(listing.entries.first).id
        let manifestID = UUID()
        let acceptedID = UUID()
        let refusedID = UUID()
        let collidingID = UUID()

        // Rewind to what version 1 left behind: one revision column whose
        // meaning depended on `review_state`. The accepted row says it produced
        // revision 2 out of revision 1; the refusal read revision 3 and produced
        // nothing. The third row is the case that mattered: version 1 never
        // checked that the revision under review was current, so a second
        // accepted row can claim it read revision 1 as well, one decision
        // after the first - and computing `target + 1` for both would put two
        // rows in front of the unique index claiming to have written revision 2.
        try fixture.execute("""
            DELETE FROM grdb_migrations WHERE identifier = 'mapping-corrections-v2';
            DROP INDEX IF EXISTS corrections_produced;
            ALTER TABLE corrections DROP COLUMN produced_revision;
            ALTER TABLE corrections ADD COLUMN supersedes_revision INTEGER;
            INSERT INTO corrections (id, manifest_id, manifest_revision, supersedes_revision,
                source_id, field, previous_value, corrected_value, evidence_ids,
                snapshot_fingerprint, context_revision, origin, review_state,
                case_candidate_id, created_at)
            VALUES ('\(acceptedID.sourceKey)', '\(manifestID.sourceKey)', 2, 1, '\(sourceID.sourceKey)',
                    'completionyear', '2026', '2027', X'5B5D', 'f', 1, 'manual',
                    'evidence_verified', NULL, 1),
                   ('\(refusedID.sourceKey)', '\(manifestID.sourceKey)', 3, NULL, '\(sourceID.sourceKey)',
                    'issuer', NULL, '示例厂商乙', X'5B5D', 'f', 1, 'manual',
                    'rejected', NULL, 2),
                   ('\(collidingID.sourceKey)', '\(manifestID.sourceKey)', 4, 1, '\(sourceID.sourceKey)',
                    'projectname', '示例项目_2026', '示例项目_2027', X'5B5D', 'f', 1, 'manual',
                    'evidence_verified', NULL, 3);
            """)

        // Reopening *is* the migration: the workspace registers and applies the
        // pending version, so nothing here reruns the statements by hand.
        let reopened = try SourceWorkspace(databaseURL: fixture.database)
        let rows = try await reopened.corrections(manifestID: manifestID)
        #expect(rows.count == 3)
        let accepted = try #require(rows.first { $0.id == acceptedID })
        #expect(accepted.reviewState == .evidenceVerified
                && accepted.manifestRevision == 1 && accepted.producedRevision == 2,
                "the migrated history must still say which revision this decision wrote")
        let refused = try #require(rows.first { $0.reviewState == .rejected })
        #expect(refused.manifestRevision == 3 && refused.producedRevision == nil,
                "a refusal keeps the version it was aimed at and gains none")
        // The later duplicate is not given a number that matches nothing: it
        // keeps the revision it says it read and loses the claim it never
        // recorded, which is what the review screen then reports.
        let colliding = try #require(rows.first { $0.id == collidingID })
        #expect(colliding.reviewState == .evidenceVerified
                && colliding.manifestRevision == 1 && colliding.producedRevision == nil,
                "two accepted rows aimed at one revision must not both claim its successor")
        // Both halves of the migration have to survive: the index is what stops
        // two rows claiming one revision on the next write, and the old column
        // must be gone so no writer can reintroduce the ambiguity.
        #expect(try fixture.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'index' "
                + "AND name = 'corrections_produced'") == "1")
        #expect(try fixture.scalar("SELECT count(*) FROM pragma_table_info('corrections') "
                + "WHERE name = 'supersedes_revision'") == "0")
    }

    @Test("a correction built on a superseded revision is refused")
    func staleBaseIsRefused() async throws {
        let context = try await prepared()
        defer { context.fixture.cleanUp() }
        let current = try #require(await context.workspace.currentManifest(scope: context.scope,
                                                                          profile: context.profile))
        let advanced = try await context.workspace.applyCorrection(
            to: current, sourceID: context.sourceID, field: .completionyear,
            correctedValue: "2027", evidenceIDs: [context.yearRow], origin: .manual,
            scope: context.scope, profile: context.profile)
        #expect(advanced.violations.isEmpty, "violations: \(advanced.violations.map(\.code))")
        #expect(advanced.manifest.envelope.revision == 2)
        // The version on the first reviewer's screen is now an old one. Publishing
        // a decision built on it would number the new revision 3 and silently
        // discard what revision 2 decided, so the store refuses the base instead.
        await #expect(throws: FormaError.sourceChanged) {
            _ = try await context.workspace.applyCorrection(
                to: current, sourceID: context.sourceID, field: .completionyear,
                correctedValue: "2028", evidenceIDs: [context.yearRow], origin: .manual,
                scope: context.scope, profile: context.profile)
        }
        let stillCurrent = try #require(await context.workspace.currentManifest(scope: context.scope,
                                                                               profile: context.profile))
        #expect(stillCurrent.envelope.revision == 2, "the refusal must not publish a revision")
        let history = try await context.workspace.corrections(manifestID: current.envelope.manifestID)
        #expect(history.compactMap(\.producedRevision).allSatisfy { $0 <= 2 },
                "nothing may claim a revision that was never written")
    }

    @Test("a correction whose revision is already claimed publishes nothing")
    func preclaimedRevisionIsRefused() async throws {
        let context = try await prepared()
        defer { context.fixture.cleanUp() }
        let current = try #require(await context.workspace.currentManifest(scope: context.scope,
                                                                          profile: context.profile))
        let next = current.envelope.revision + 1
        // A row that already claims the revision this click is about to write.
        // Only the version 1 migration or a hand-edited store leaves this
        // state, so what is under test is the store refusing the write - and
        // that the refusal is reported as the published storage failure rather
        // than as the raw constraint error or as a reviewer's mistake.
        try context.fixture.execute("""
            INSERT INTO corrections (id, manifest_id, manifest_revision, produced_revision, source_id,
                field, previous_value, corrected_value, evidence_ids, snapshot_fingerprint,
                context_revision, origin, review_state, case_candidate_id, created_at)
            VALUES ('\(UUID().sourceKey)', '\(current.envelope.manifestID.sourceKey)', \(current.envelope.revision), \(next),
                '\(context.sourceID.sourceKey)', 'issuer', NULL, '示例厂商乙', X'5B5D', 'f', 1, 'manual',
                'evidence_verified', NULL, 0);
            """)
        await #expect(throws: FormaError.storage) {
            _ = try await context.workspace.applyCorrection(
                to: current, sourceID: context.sourceID, field: .completionyear,
                correctedValue: "2027", evidenceIDs: [context.yearRow], origin: .manual,
                scope: context.scope, profile: context.profile)
        }
        // Both writes belong to the refused transaction: a rejected publish
        // must not leave the new revision sitting in the store with no
        // decision behind it, because the next honest click would then be
        // refused by the row this one failed to write.
        let after = try #require(await context.workspace.currentManifest(scope: context.scope,
                                                                        profile: context.profile))
        #expect(after.envelope.revision == current.envelope.revision,
                "the manifest the constraint refused must not have been stored either")
    }
}
