import Foundation
import Testing

@testable import FormaCore

/// #147 red-on-dev demonstration. Replays the failing production flow with
/// `origin/dev` APIs only: a first Offline Mapping run captured evidence from
/// the pre-capture listing, so the published manifest bound the pre-read
/// snapshot while the registry holds only the post-read rows. The reviewer's
/// first correction must be refused, and on the repaired tree the refusal is
/// diagnosed honestly as a stale snapshot (`evidence_snapshot_mismatch`)
/// rather than collapsed into missing evidence (`evidence_not_found`).
/// On `origin/dev` this test fails: the correction engine reports the stale
/// citation as if no evidence existed at all.
@Suite("Issue 145 red-on-dev demonstration")
struct Issue145RedDemoTests {
    @Test("a first-capture correction refusal must name the stale snapshot")
    func staleSnapshotRefusalIsDiagnosed() async throws {
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
        let profile = try MappingProfile.projectArchive()
        let context = try await workspace.buildContext(scope: scope, profile: profile)

        // The pre-capture run exactly as the failing build performed it.
        let captured = try await workspace.captureEvidence(for: [before])
        let rows = try #require(captured[before.id])
        let engine = MappingEngine(profile: profile, casePack: try CasePack.shipped(),
                                   answerer: OfflinePlannerAnswerer(), workspace: workspace)
        let result = await engine.run(
            MappingRunRequest(scope: scope, profile: profile, context: context,
                              entries: [before], evidence: captured,
                              provider: .offline, model: OfflinePlannerAnswerer.modelID,
                              allowCloud: false))
        let stale = try #require(result.manifest.entries.first)
        #expect(stale.snapshotRevision == Int(before.snapshotRevision))
        let stored = try await workspace.saveManifest(result.manifest, scopeID: scope.id)

        // The first reviewer correction citing the rows the sheet shows.
        let citedPath = try #require(rows.first {
            $0.source == .path && $0.isUsable && ($0.excerpt ?? "").contains("示例项目_2026")
        })
        let applied = try await workspace.applyCorrection(
            to: stored, sourceID: before.id, field: .projectname,
            correctedValue: "示例项目_2026", evidenceIDs: [citedPath.id],
            origin: .manual, scope: scope, profile: profile)
        #expect(applied.violations.contains { $0.code == "evidence_snapshot_mismatch" },
                "a superseded-snapshot citation must be reported as stale evidence, "
                    + "not as missing evidence: \(applied.violations.map(\.code))")
        #expect(!applied.violations.contains { $0.code == "evidence_not_found" })
        #expect(applied.correction.reviewState == .rejected)
        #expect(applied.correction.producedRevision == nil)
    }
}
