import Foundation
import Testing

@testable import FormaCore

/// The GUI used to make a Manifest from its pre-capture listing while the
/// evidence registry held rows produced by the first SHA-256 read. This test
/// proves the underlying first-read revision transition and the exact binding
/// that WorkspaceModel must use *without* asking the user to scan twice.
@Suite("First-read mapping snapshot binding")
struct FirstReadSnapshotBindingTests {
    @Test("one scan and first body capture produce evidence that a corrected offline manifest can cite")
    func firstReadEvidenceCanSupportFirstCorrection() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let url = fixture.root.appendingPathComponent(
            "示例项目_2026/01_招标文件/01_招标公告.pdf")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makePDF(["示例项目_2026 招标公告 归档完成 2027 年"]).write(to: url)

        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let scanned = try await workspace.scan(scope)
        let before = try #require(scanned.entries.first)
        #expect(before.snapshotRevision == 1)
        #expect(before.sha256 == nil)
        let profile = try MappingProfile.projectArchive()
        let context = try await workspace.buildContext(scope: scope, profile: profile)

        // No second Scan. A first read may advance the snapshot to bind the
        // newly obtained SHA-256. The evidence belongs to the new revision.
        let rows = try await workspace.captureEvidence(for: before)
        let latestListing = try await workspace.listing(scope)
        let current = try #require(latestListing.entries.first)
        #expect(current.id == before.id)
        #expect(current.snapshotRevision > before.snapshotRevision)
        #expect(current.snapshotFingerprint != before.snapshotFingerprint)
        #expect(rows.allSatisfy {
            $0.sourceID == current.id
                && $0.snapshotRevision == Int(current.snapshotRevision)
                && $0.snapshotFingerprint == current.snapshotFingerprint
        })
        // Project-context membership binds stable IDs and paths, not SHA.
        #expect(ContextBuilder.inputDigest(scopeID: scope.id, profile: profile,
                                           entries: latestListing.entries) == context.inputDigest)

        let engine = MappingEngine(profile: profile, casePack: try CasePack.shipped(),
                                   answerer: OfflinePlannerAnswerer(), workspace: workspace)
        let result = await engine.run(
            MappingRunRequest(scope: scope, profile: profile, context: context,
                              entries: [current], evidence: [current.id: rows],
                              provider: .offline, model: OfflinePlannerAnswerer.modelID,
                              allowCloud: false))
        let entry = try #require(result.manifest.entries.first)
        #expect(entry.snapshotRevision == Int(current.snapshotRevision))
        #expect(entry.snapshotFingerprint == current.snapshotFingerprint)
        #expect(result.requests == 0)

        let stored = try await workspace.saveManifest(result.manifest, scopeID: scope.id)
        let citedPath = try #require(rows.first {
            $0.source == .path && $0.isUsable
                && ($0.excerpt ?? "").contains("示例项目_2026")
        })
        let applied = try await workspace.applyCorrection(
            to: stored, sourceID: current.id, field: .projectname,
            correctedValue: "示例项目_2026", evidenceIDs: [citedPath.id],
            origin: .manual, scope: scope, profile: profile)
        #expect(applied.violations.isEmpty,
                "First correction was refused: \(applied.violations.map(\.code))")
        #expect(applied.manifest.envelope.revision > stored.envelope.revision)
        #expect(applied.manifest.entries.first?.metadata[.projectname] == "示例项目_2026")
        let reopened = try #require(try await workspace.currentManifest(scope: scope, profile: profile))
        #expect(reopened.entries.first?.metadata[.projectname] == "示例项目_2026")
        #expect(reopened.entries.first?.outcome(for: .projectname)?.evidenceIDs == [citedPath.id])
    }
}
