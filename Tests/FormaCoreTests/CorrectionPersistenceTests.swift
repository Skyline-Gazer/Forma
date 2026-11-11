import Foundation
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
        func claim() -> CorrectionRecord {
            CorrectionRecord(manifestID: manifestID, manifestRevision: 1, producedRevision: 2,
                             sourceID: context.sourceID, field: .completionyear, previousValue: "2026",
                             correctedValue: "2027", evidenceIDs: [context.yearRow],
                             snapshotFingerprint: "f", contextRevision: 1, origin: .manual,
                             reviewState: .evidenceVerified)
        }
        try await store.database.write { db in try MappingStore.insertCorrection(claim(), in: db) }
        var failure: (any Error)?
        try await store.database.write { db in
            do { try MappingStore.insertCorrection(claim(), in: db) } catch { failure = error }
        }
        #expect(failure != nil,
                "one revision has at most one producing correction, and that is a constraint, not a habit")
    }
}
