import Foundation
import Testing

@testable import FormaCore

/// The Alpha chain, end to end, over synthetic files only:
///
/// scan → offline mapping → human correction with real citations → revalidation →
/// reopen from the store → export bundle → revalidate the bundle → import dry run,
/// plus the invalidation a changed source must cause.
///
/// Two profiles are exercised: Project Archive (project-bound, so the project
/// name and completion year are required) and Vendor Library (no project at all,
/// so they are not).
///
/// No network, no Provider, no business directory: the sources are synthetic and
/// the only "external system" is the import planner, which is asked for a plan
/// and never for an execution.
@Suite("Alpha end-to-end")
struct AlphaEndToEndTests {
    private func offlineMapping(workspace: SourceWorkspace, scope: SourceScope,
                                 profile: MappingProfile, context: ProjectContext,
                                 entries: [SourceEntry]) async throws -> MappingRunOutcome {
        let engine = MappingEngine(profile: profile, casePack: try CasePack.shipped(),
                                   answerer: OfflinePlannerAnswerer(), workspace: workspace)
        return await engine.run(MappingRunRequest(scope: scope, profile: profile, context: context,
                                                  entries: entries, evidence: [:],
                                                  provider: .offline,
                                                  model: OfflinePlannerAnswerer.modelID,
                                                  allowCloud: false))
    }

    @Test("Project Archive: a corrected offline manifest survives the store, export and the dry run")
    func projectArchiveChain() async throws {
        // The shared fixture already holds a scanned source, a stored context and
        // registered body rows: the citation material a correction needs.
        let prepared = try await preparedMapping()
        let workspace = prepared.workspace
        let scope = prepared.scope
        let profile = prepared.profile
        let context = try await workspace.storedContext(
            scope: scope, profile: profile, revision: prepared.manifest.envelope.contextRevision)

        // 1. Offline mapping: the manifest says who produced it and claims nothing.
        let outcome = try await offlineMapping(workspace: workspace, scope: scope, profile: profile,
                                               context: context, entries: [prepared.entry])
        #expect(outcome.manifest.envelope.modelProvider == "offline")
        #expect(outcome.manifest.envelope.modelID == OfflinePlannerAnswerer.modelID)
        #expect(outcome.manifest.envelope.grantsExecution == false)
        let drafted = try #require(outcome.manifest.entries.first)
        #expect(drafted.metadata[.documentcategory] == nil)
        #expect(drafted.metadata[.projectname] == nil)
        #expect(drafted.state != .validated)

        // 2. Human correction with real citations: the row has to exist for this
        //    source and this snapshot.
        let projectRow = try #require(prepared.rows.first { ($0.excerpt ?? "").contains("示例项目_2026") })
        let categoryRow = try #require(prepared.rows.first { ($0.excerpt ?? "").contains("招标") })
        let category = try #require(profile.categories.first { !$0.identifier.hasSuffix("待分类") })
            .identifier
        var manifest = outcome.manifest
        let corrections: [(MetadataFieldID, String, String)] = [
            (MetadataFieldID.documentcategory, category, categoryRow.id),
            (MetadataFieldID.projectname, "示例项目_2026", projectRow.id),
            (MetadataFieldID.completionyear, "2027", prepared.yearRow),
        ]
        for (field, value, citation) in corrections {
            let applied = try await workspace.applyCorrection(
                to: manifest, sourceID: prepared.sourceID, field: field, correctedValue: value,
                evidenceIDs: [citation], origin: .manual, scope: scope, profile: profile)
            #expect(applied.violations.isEmpty,
                    "correction of \(field.rawValue) was rejected: \(applied.violations)")
            manifest = applied.manifest
        }

        // 3. The corrections are real: cited values, and a validated manifest for
        //    a profile that demands both project fields.
        let corrected = try #require(manifest.entries.first)
        #expect(corrected.metadata[.documentcategory] == category)
        #expect(corrected.metadata[.projectname] == "示例项目_2026")
        #expect(corrected.metadata[.completionyear] == "2027")
        #expect(corrected.outcome(for: .documentcategory)?.evidenceIDs.isEmpty == false)
        #expect(corrected.state == .validated)

        // 4. Reopen: the stored revision carries the corrections, not the draft.
        let reopened = try #require(try await workspace.currentManifest(scope: scope, profile: profile))
        let reopenedEntry = try #require(reopened.entries.first)
        #expect(reopenedEntry.metadata[.documentcategory] == category)
        #expect(reopenedEntry.metadata[.projectname] == "示例项目_2026")
        #expect(reopened.envelope.revision >= manifest.envelope.revision)

        // 5. Export the bundle and revalidate it offline.
        let exportDirectory = prepared.fixture.base.appendingPathComponent("export", isDirectory: true)
        let summary = try ManifestExport.export(manifest: manifest, evidence: prepared.rows,
                                                to: exportDirectory)
        let revalidation = try ManifestExport.revalidate(
            at: exportDirectory.appendingPathComponent(summary.manifestID))
        #expect(revalidation.artifactConsistent)
        #expect(revalidation.violations.isEmpty)

        // 6. The import planner consumes the corrected manifest and produces a
        //    dry run: nothing is authorized, nothing was written.
        let listing = try await workspace.scan(scope)
        let plan = ImportPlanner.plan(manifest: manifest, profile: profile,
                                      observations: ImportPlanner.Observations(sourceRoot: nil,
                                                                              listing: listing),
                                      authorization: nil, targetObserved: false)
        #expect(plan.writesInThisBuild == false)
        #expect(plan.rows.count == manifest.entries.count)
        #expect(plan.rows.allSatisfy { $0.codes.contains(.authorizationMissing) })
        #expect(plan.rows.allSatisfy { !$0.codes.contains(.targetMissing) })
        #expect(plan.rows.allSatisfy { !$0.codes.contains(.sourceChanged) })
        let data = try FormaJSON.encoder(pretty: true).encode(plan)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["dry_run"] as? Bool == true)
        #expect(object["writes_executed"] as? Bool == false)
        #expect(object["authorization_granted"] as? Bool == false)
    }

    @Test("Vendor Library: a vendor folder maps and exports without inventing a project")
    func vendorLibraryChain() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let folder = fixture.root.appendingPathComponent("厂商资料/说明", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("厂商说明".utf8).write(to: folder.appendingPathComponent("说明.pdf"))

        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let profile = try MappingProfile.vendorLibrary()
        let listing = try await workspace.scan(scope)
        let context = try await workspace.buildContext(scope: scope, profile: profile)

        let outcome = try await offlineMapping(workspace: workspace, scope: scope, profile: profile,
                                               context: context, entries: listing.entries)
        #expect(outcome.manifest.envelope.modelProvider == "offline")
        let entry = try #require(outcome.manifest.entries.first)
        // No project is invented for a vendor document, and the profile does not
        // demand one.
        #expect(entry.metadata[.projectname] == nil)
        #expect(entry.associations.isEmpty)
        #expect(profile.fields[.projectname]?.requiredForValidated == false)

        // The draft exports and revalidates like any other manifest.
        let exportDirectory = fixture.base.appendingPathComponent("export-vendor", isDirectory: true)
        let summary = try ManifestExport.export(manifest: outcome.manifest, evidence: [],
                                                to: exportDirectory)
        let revalidation = try ManifestExport.revalidate(
            at: exportDirectory.appendingPathComponent(summary.manifestID))
        #expect(revalidation.artifactConsistent)

        let plan = ImportPlanner.plan(manifest: outcome.manifest, profile: profile,
                                      observations: ImportPlanner.Observations(sourceRoot: nil,
                                                                              listing: listing),
                                      authorization: nil, targetObserved: false)
        #expect(plan.writesInThisBuild == false)
        #expect(plan.rows.count == outcome.manifest.entries.count)
    }

    @Test("a changed source makes the old mapping stop looking current")
    func changedSourceInvalidatesThePlan() async throws {
        let prepared = try await preparedMapping()
        let workspace = prepared.workspace
        let scope = prepared.scope
        let profile = prepared.profile
        let context = try await workspace.storedContext(
            scope: scope, profile: profile, revision: prepared.manifest.envelope.contextRevision)
        let before = try await workspace.scan(scope)
        let outcome = try await offlineMapping(workspace: workspace, scope: scope, profile: profile,
                                               context: context, entries: [prepared.entry])

        // A plan built on the listing the mapping was made from is consistent.
        let current = ImportPlanner.plan(manifest: outcome.manifest, profile: profile,
                                         observations: ImportPlanner.Observations(sourceRoot: nil,
                                                                                 listing: before),
                                         authorization: nil, targetObserved: false)
        #expect(current.rows.allSatisfy { !$0.codes.contains(.sourceChanged) })

        // Change the file and scan again: the same manifest no longer describes
        // the bytes on disk, and the plan says so instead of pretending the old
        // decision still applies.
        let url = prepared.entry.relativePath
        let file = prepared.fixture.root.appendingPathComponent(url)
        try Data("changed content".utf8).write(to: file)
        let after = try await workspace.scan(scope)

        let stale = ImportPlanner.plan(manifest: outcome.manifest, profile: profile,
                                       observations: ImportPlanner.Observations(sourceRoot: nil,
                                                                                listing: after),
                                       authorization: nil, targetObserved: false)
        #expect(stale.rows.contains { $0.codes.contains(.sourceChanged) })
        #expect(stale.rows.allSatisfy { !$0.codes.contains(.sourceMissing) })
    }
}
