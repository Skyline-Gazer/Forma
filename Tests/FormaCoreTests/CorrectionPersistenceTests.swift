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
        _ = try fixture.write("招标公告 示例项目_2026 归档完成 2026 年", at: "示例项目_2026/01_招标/公告.pdf")
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let listing = try await workspace.scan(scope)
        let profile = try MappingProfile.projectArchive()
        let registered = try await workspace.captureEvidence(listing.entries)
        let entry = try #require(listing.entries.first)
        let rows = registered[entry.id] ?? []
        // The row a completionyear citation may point at: it carries the year in
        // its excerpt, which is what the profile's rule looks for.
        let year = try #require(rows.first { ($0.excerpt ?? "").contains("2026") && $0.isUsable })
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
                modelID: "fake", contextRevision: 1, promptVersion: MappingPrompt.version,
                extractorVersion: EvidenceRegistry.extractorVersion, redactionVersion: nil,
                inputDigest: String(repeating: "1", count: 64), contextDigest: String(repeating: "2", count: 64),
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
}
