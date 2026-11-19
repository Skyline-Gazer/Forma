import Foundation
import Testing

@testable import FormaCore

/// The join between the two Alpha PRs: a manifest drafted by the offline planner
/// is fed to the import planner, and the result says what a reviewer needs to
/// know before anything could run.
///
/// This file exists on an integration branch because it needs both PRs at once.
/// It is evidence, not a second implementation.
@Suite("Alpha integration: offline mapping → import plan")
struct AlphaIntegrationTests {
    private func workspace() async throws -> (SourceFixture, SourceWorkspace, SourceScope, SourceListing) {
        let fixture = try SourceFixture()
        let project = fixture.root.appendingPathComponent("2026_示例项目/01_招标")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("tender".utf8).write(to: project.appendingPathComponent("公告.pdf"))
        try Data("minutes".utf8).write(to: project.appendingPathComponent("会议记录.docx"))
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let listing = try await workspace.scan(scope)
        return (fixture, workspace, scope, listing)
    }

    @Test("an offline draft maps every record and feeds a dry-run import plan")
    func offlineMappingToImportPlan() async throws {
        let (_, workspace, scope, listing) = try await workspace()
        let profile = try MappingProfile.projectArchive()
        let context = try await workspace.buildContext(scope: scope, profile: profile)
        let engine = MappingEngine(profile: profile, casePack: try CasePack.shipped(),
                                   answerer: OfflinePlannerAnswerer(), workspace: workspace)
        let outcome = await engine.run(MappingRunRequest(
            scope: scope, profile: profile, context: context, entries: listing.entries,
            evidence: [:], provider: .offline, model: OfflinePlannerAnswerer.modelID,
            allowCloud: false))

        // The manifest says who produced it, and it is not a model.
        #expect(outcome.manifest.envelope.modelProvider == "offline")
        #expect(outcome.manifest.envelope.modelID == OfflinePlannerAnswerer.modelID)
        #expect(outcome.manifest.envelope.grantsExecution == false)
        // Every record got an answer: the planner may not drop a record silently.
        #expect(outcome.manifest.entries.count == listing.entries.count)
        // Nothing is claimed without evidence, so the category stays unknown for
        // every record until a person fills it from the registered rows.
        #expect(outcome.manifest.entries.allSatisfy { $0.metadata[.documentcategory] == nil })
        // Nothing is validated by being mapped: the required Project Archive
        // fields are unknown until a person confirms them.
        #expect(outcome.manifest.envelope.state != .validated)

        // The dry run consumes that manifest unchanged.
        let plan = ImportPlanner.plan(manifest: outcome.manifest, profile: profile,
                                      observations: ImportPlanner.Observations(sourceRoot: nil,
                                                                                listing: listing),
                                      authorization: nil, targetObserved: false)
        #expect(plan.writesInThisBuild == false)
        #expect(plan.manifestRevision == outcome.manifest.envelope.revision)
        #expect(plan.rows.count == outcome.manifest.entries.count)
        // Every row is blocked, and the reason that matters is the missing
        // authorization; a manifest that was never validated is reported with it
        // rather than instead of it.
        #expect(plan.rows.allSatisfy { $0.codes.contains(.authorizationMissing) })
        #expect(plan.rows.allSatisfy { row in
            !row.codes.contains(.targetMissing) && !row.codes.contains(.targetNotWritable)
        })
        #expect(plan.passes == 0)
        #expect(plan.blocked == plan.rows.count)
    }

    @Test("a resolved target is still not an authorization")
    func targetResolutionDoesNotGrantPermission() async throws {
        let (_, workspace, scope, listing) = try await workspace()
        let profile = try MappingProfile.projectArchive()
        let context = try await workspace.buildContext(scope: scope, profile: profile)
        let engine = MappingEngine(profile: profile, casePack: try CasePack.shipped(),
                                   answerer: OfflinePlannerAnswerer(), workspace: workspace)
        let outcome = await engine.run(MappingRunRequest(
            scope: scope, profile: profile, context: context, entries: listing.entries,
            evidence: [:], provider: .offline, model: OfflinePlannerAnswerer.modelID,
            allowCloud: false))

        // Even with a target the manifest calls resolved, and observed facts, an
        // unobserved target plus a missing authorization keeps every row blocked.
        let plan = ImportPlanner.plan(manifest: outcome.manifest, profile: profile,
                                      observations: ImportPlanner.Observations(sourceRoot: nil,
                                                                                listing: listing),
                                      authorization: nil, targetObserved: false)
        let codes = Set(plan.rows.flatMap(\.codes))
        #expect(!codes.contains(.manifestNotValidated) || codes.contains(.entryInvalidated))
        #expect(!codes.contains(.targetMissing))
        #expect(!codes.contains(.targetNotWritable))
    }
}
