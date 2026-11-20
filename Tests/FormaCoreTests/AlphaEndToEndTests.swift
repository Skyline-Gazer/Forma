import Foundation
import Testing

@testable import FormaCore

/// The Alpha chain, end to end, over synthetic files only:
///
/// scan → offline mapping → human correction with real citations → revalidation →
/// save → reopen → export bundle → revalidate the bundle → import dry run →
/// and the invalidation that must follow a changed source file.
///
/// Two profiles are exercised: Project Archive (a project-bound archive, where
/// the project name and the completion year are required) and Vendor Library (a
/// vendor folder with no project at all, where they are not).
///
/// No network, no Provider, no business directory: the sources are written into
/// a temporary directory, and the only "external system" is the import planner,
/// which is asked for a plan and never for an execution.
@Suite("Alpha end-to-end")
struct AlphaEndToEndTests {
    /// A synthetic archive with one real PDF, so the evidence rows contain text
    /// a correction can cite.
    private func makeSource(_ fixture: SourceFixture, name: String, folder: String) throws -> URL {
        let body = try makePDF(["示例项目_2026 招标公告 归档完成 2027 年"])
        let url = fixture.root.appendingPathComponent(folder).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingPathComponent(),
                                                withIntermediateDirectories: true)
        try body.write(to: url)
        return url
    }

    /// Scans, registers the evidence and scans again: registering a body can
    /// advance the snapshot revision, and a mapping built from the older
    /// revision would be blocked by its own binding before the correction.
    private func scanWithEvidence(_ fixture: SourceFixture,
                                   workspace: SourceWorkspace,
                                   scope: SourceScope) async throws -> (SourceListing, [UUID: [EvidenceRecord]]) {
        let first = try await workspace.scan(scope)
        let captured = try await workspace.captureEvidence(for: first.entries)
        let second = try await workspace.scan(scope)
        return (second, captured)
    }

    private func offlineMapping(workspace: SourceWorkspace, scope: SourceScope,
                                 profile: MappingProfile, context: ProjectContext,
                                 listing: SourceListing) async throws -> MappingRunOutcome {
        let engine = MappingEngine(profile: profile, casePack: try CasePack.shipped(),
                                   answerer: OfflinePlannerAnswerer(), workspace: workspace)
        return await engine.run(MappingRunRequest(scope: scope, profile: profile, context: context,
                                                  entries: listing.entries, evidence: [:],
                                                  provider: .offline,
                                                  model: OfflinePlannerAnswerer.modelID,
                                                  allowCloud: false))
    }

    @Test("Project Archive: a corrected offline manifest survives save, reopen, export and the dry run")
    func projectArchiveChain() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        try makeSource(fixture, name: "公告.pdf", folder: "2026_示例项目/01_招标")

        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let profile = try MappingProfile.projectArchive()
        let (listing, captured) = try await scanWithEvidence(fixture, workspace: workspace, scope: scope)
        let context = try await workspace.buildContext(scope: scope, profile: profile)

        // 1. Offline mapping: the manifest says who produced it and claims nothing.
        let outcome = try await offlineMapping(workspace: workspace, scope: scope, profile: profile,
                                               context: context, listing: listing)
        #expect(outcome.manifest.envelope.modelProvider == "offline")
        #expect(outcome.manifest.envelope.modelID == OfflinePlannerAnswerer.modelID)
        #expect(outcome.manifest.envelope.grantsExecution == false)
        #expect(outcome.manifest.entries.count == listing.entries.count)
        let entry = try #require(outcome.manifest.entries.first)
        #expect(entry.metadata[.documentcategory] == nil)
        #expect(entry.metadata[.projectname] == nil)
        #expect(entry.state != .validated)

        // 2. Human correction with real citations: the row has to exist for this
        //    source and this snapshot.
        let sourceID = entry.sourceID
        let rows = try #require(captured[sourceID]?.filter { $0.isUsable && $0.snapshotRevision == Int(listing.entries.first?.snapshotRevision ?? 0) })
        let categoryRow = try #require(rows.first { ($0.excerpt ?? "").contains("招标") })
        let projectRow = try #require(rows.first { ($0.excerpt ?? "").contains("示例项目_2026") })
        let yearRow = try #require(rows.first { ($0.excerpt ?? "").contains("2027") })
        let category = try #require(profile.categories.first { !$0.identifier.hasSuffix("待分类") })
            .identifier

        var manifest = outcome.manifest
        for (field, value, row) in [
            (MetadataFieldID.documentcategory, category, categoryRow),
            (MetadataFieldID.projectname, "示例项目_2026", projectRow),
            (MetadataFieldID.completionyear, "2027", yearRow),
        ] {
            let applied = try await workspace.applyCorrection(
                to: manifest, sourceID: sourceID, field: field, correctedValue: value,
                evidenceIDs: [row.id], origin: .manual, scope: scope, profile: profile)
            #expect(applied.violations.isEmpty, "correction of \(field.rawValue) was rejected: \(applied.violations)")
            manifest = applied.manifest
        }

        // 3. The corrections are real: the values are cited and the manifest is
        //    validated for a profile that requires both project fields.
        let corrected = try #require(manifest.entries.first)
        #expect(corrected.metadata[.documentcategory] == category)
        #expect(corrected.metadata[.projectname] == "示例项目_2026")
        #expect(corrected.metadata[.completionyear] == "2027")
        #expect(corrected.outcome(for: .documentcategory)?.evidenceIDs.isEmpty == false)
        #expect(corrected.state == .validated)

        // 4. Save and reopen: the stored revision is the one that was corrected.
        let saved = try await workspace.saveManifest(manifest, scopeID: scope.id)
        let reopened = try await workspace.currentManifest(scope: scope, profile: profile)
        let reopenedEntry = try #require(reopened?.entries.first)
        #expect(reopenedEntry.metadata[.documentcategory] == category)
        #expect(reopenedEntry.metadata[.projectname] == "示例项目_2026")
        #expect(reopened?.envelope.revision == saved.envelope.revision)

        // 5. Export the bundle and revalidate it offline.
        let allRows = captured.values.flatMap { $0 }
        let exportDirectory = fixture.base.appendingPathComponent("export", isDirectory: true)
        let summary = try ManifestExport.export(manifest: saved, evidence: allRows, to: exportDirectory)
        let revalidation = try ManifestExport.revalidate(
            at: exportDirectory.appendingPathComponent(summary.manifestID))
        #expect(revalidation.artifactConsistent)
        #expect(revalidation.violations.isEmpty)

        // 6. The import planner consumes the corrected manifest and produces a
        //    dry run: nothing is authorized, nothing was written.
        let plan = ImportPlanner.plan(manifest: saved, profile: profile,
                                      observations: ImportPlanner.Observations(sourceRoot: nil,
                                                                              listing: listing),
                                      authorization: nil, targetObserved: false)
        #expect(plan.writesInThisBuild == false)
        #expect(plan.manifestRevision == saved.envelope.revision)
        #expect(plan.rows.count == saved.entries.count)
        #expect(plan.rows.allSatisfy { $0.codes.contains(.authorizationMissing) })
        #expect(plan.rows.allSatisfy { !$0.codes.contains(.targetMissing) })
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
        try makeSource(fixture, name: "厂商说明.pdf", folder: "厂商资料/说明")

        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let profile = try MappingProfile.vendorLibrary()
        let (listing, captured) = try await scanWithEvidence(fixture, workspace: workspace, scope: scope)
        let context = try await workspace.buildContext(scope: scope, profile: profile)

        let outcome = try await offlineMapping(workspace: workspace, scope: scope, profile: profile,
                                               context: context, listing: listing)
        #expect(outcome.manifest.envelope.modelProvider == "offline")
        let entry = try #require(outcome.manifest.entries.first)
        // No project is invented for a vendor document.
        #expect(entry.metadata[.projectname] == nil)
        #expect(entry.associations.isEmpty)

        let rows = try #require(captured[entry.sourceID]?.filter(\.isUsable))
        let category = try #require(profile.categories.first { !$0.identifier.hasSuffix("待分类") })
            .identifier
        let applied = try await workspace.applyCorrection(
            to: outcome.manifest, sourceID: entry.sourceID, field: .documentcategory,
            correctedValue: category, evidenceIDs: [try #require(rows.first).id],
            origin: .manual, scope: scope, profile: profile)
        #expect(applied.violations.isEmpty)
        #expect(applied.manifest.entries.first?.metadata[.documentcategory] == category)
        // The project field stays unknown: a vendor document has no project, and
        // the profile does not demand one.
        #expect(applied.manifest.entries.first?.metadata[.projectname] == nil)

        let saved = try await workspace.saveManifest(applied.manifest, scopeID: scope.id)
        let exportDirectory = fixture.base.appendingPathComponent("export-vendor", isDirectory: true)
        let summary = try ManifestExport.export(manifest: saved,
                                                evidence: captured.values.flatMap { $0 },
                                                to: exportDirectory)
        let revalidation = try ManifestExport.revalidate(
            at: exportDirectory.appendingPathComponent(summary.manifestID))
        #expect(revalidation.artifactConsistent)

        let plan = ImportPlanner.plan(manifest: saved, profile: profile,
                                      observations: ImportPlanner.Observations(sourceRoot: nil,
                                                                              listing: listing),
                                      authorization: nil, targetObserved: false)
        #expect(plan.writesInThisBuild == false)
        #expect(plan.rows.count == saved.entries.count)
    }

    @Test("a changed source invalidates the mapping and the plan built on it")
    func changedSourceInvalidatesThePlan() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let url = try makeSource(fixture, name: "公告.pdf", folder: "2026_示例项目/01_招标")

        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let profile = try MappingProfile.projectArchive()
        let (listing, captured) = try await scanWithEvidence(fixture, workspace: workspace, scope: scope)
        let context = try await workspace.buildContext(scope: scope, profile: profile)
        let outcome = try await offlineMapping(workspace: workspace, scope: scope, profile: profile,
                                               context: context, listing: listing)

        // A plan built now is consistent with the source as it stands.
        let before = ImportPlanner.plan(manifest: outcome.manifest, profile: profile,
                                         observations: ImportPlanner.Observations(sourceRoot: nil,
                                                                                 listing: listing),
                                         authorization: nil, targetObserved: false)
        #expect(before.rows.allSatisfy { !$0.codes.contains(.sourceChanged) })

        // Change the file, rescan, and reconcile: the stored mapping no longer
        // describes the bytes on disk.
        try Data("changed content".utf8).write(to: url)
        let rescan = try await workspace.scan(scope)
        try await workspace.reconcile(scope: scope, profile: profile)

        let after = ImportPlanner.plan(manifest: outcome.manifest, profile: profile,
                                        observations: ImportPlanner.Observations(sourceRoot: nil,
                                                                                 listing: rescan),
                                        authorization: nil, targetObserved: false)
        // The old manifest's snapshot no longer matches, so the plan says so
        // instead of pretending the decision still applies.
        #expect(after.rows.contains { $0.codes.contains(.sourceChanged) })
        #expect(after.rows.allSatisfy { !$0.codes.contains(.sourceMissing) })
    }
}
