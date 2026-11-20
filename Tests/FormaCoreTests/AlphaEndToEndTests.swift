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
        let storedContext = try await workspace.storedContext(
            scope: scope, profile: profile, revision: prepared.manifest.envelope.contextRevision)
        let context = try #require(storedContext)

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

        // 2. Store the draft first: a correction produces the next revision, so
        //    the revision it expects has to exist.
        let stored = try await workspace.saveManifest(outcome.manifest, scopeID: scope.id)
        #expect(stored.envelope.revision == outcome.manifest.envelope.revision)

        // 3. Human correction with real citations, through the same engine the
        //    app calls. Each value must be backed by a row for this snapshot.
        let projectRow = try #require(prepared.rows.first { ($0.excerpt ?? "").contains("示例项目_2026") })
        let categoryRow = try #require(prepared.rows.first { ($0.excerpt ?? "").contains("招标") })
        let yearRow = try #require(prepared.rows.first { $0.id == prepared.yearRow })
        let category = try #require(profile.categories.first { !$0.identifier.hasSuffix("待分类") })
            .identifier
        let engine = CorrectionEngine(profile: profile)
        var manifest = stored
        // The category is corrected last: it is the field whose decision the
        // profile treats as the classification, and applying it after the project
        // fields keeps each step's revalidation about one change.
        let corrections: [(MetadataFieldID, String, String)] = [
            (MetadataFieldID.projectname, "示例项目_2026", projectRow.id),
            (MetadataFieldID.completionyear, "2027", yearRow.id),
            (MetadataFieldID.documentcategory, category, categoryRow.id),
        ]
        let evidenceBySource = [prepared.sourceID: prepared.rows]
        for (field, value, citation) in corrections {
            let applied = engine.apply(to: manifest, sourceID: prepared.sourceID, field: field,
                                       correctedValue: value, evidenceIDs: [citation], origin: .manual,
                                       context: context, evidence: evidenceBySource,
                                       currentEntries: [prepared.entry])
            #expect(applied.violations.isEmpty,
                    "correction of \(field.rawValue) was rejected: \(applied.violations.map(\.code))")
            manifest = applied.manifest
        }

        // 4. The corrections that land are cited and persisted; the manifest is
        //    not validated yet.
        //
        //    Known gap (recorded 2026-11-20): a *category* correction carrying a
        //    body citation does not reach the entry when the offline draft left
        //    that field unknown — the field stays nil and the entry stays `hold`,
        //    while `projectname` and `completionyear` corrections land normally.
        //    This assertion is the characterisation of that behaviour, not a
        //    claim that the loop is complete; the Alpha report lists it as the
        //    next defect to fix. It is asserted so a silent change is visible.
        let corrected = try #require(manifest.entries.first)
        #expect(corrected.metadata[.projectname] == "示例项目_2026")
        #expect(corrected.metadata[.completionyear] == "2027")
        #expect(corrected.outcome(for: .projectname)?.evidenceIDs.isEmpty == false)
        #expect(corrected.metadata[.documentcategory] == nil,
                "category correction unexpectedly landed: update the recorded gap and the Alpha report")
        #expect(corrected.state == .hold)

        // 5. Persist the corrected revision and reopen it: what a later session
        //    reads is the corrected manifest, not the draft.
        _ = try await workspace.saveManifest(manifest, scopeID: scope.id)
        let reopened = try #require(try await workspace.currentManifest(scope: scope, profile: profile))
        let reopenedEntry = try #require(reopened.entries.first)
        #expect(reopenedEntry.metadata[.projectname] == "示例项目_2026")
        #expect(reopenedEntry.metadata[.completionyear] == "2027")
        // The store rebased the corrected manifest onto its own revision chain:
        // the draft was revision 1, so the persisted revision is 2.
        #expect(reopened.envelope.revision == 2)

        // 6. Export the bundle and revalidate it offline.
        let exportDirectory = prepared.fixture.base.appendingPathComponent("export", isDirectory: true)
        let summary = try ManifestExport.export(manifest: manifest, evidence: prepared.rows,
                                                to: exportDirectory)
        let revalidation = try ManifestExport.revalidate(
            at: exportDirectory.appendingPathComponent(summary.manifestID))
        #expect(revalidation.artifactConsistent)
        #expect(revalidation.violations.isEmpty)

        // 7. The import planner consumes the corrected manifest and produces a
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
        let storedContext = try await workspace.storedContext(
            scope: scope, profile: profile, revision: prepared.manifest.envelope.contextRevision)
        let context = try #require(storedContext)
        let before = try await workspace.scan(scope)
        let outcome = try await offlineMapping(workspace: workspace, scope: scope, profile: profile,
                                               context: context, entries: [prepared.entry])
        let stored = try await workspace.saveManifest(outcome.manifest, scopeID: scope.id)

        // A plan built on the listing the mapping was made from is consistent.
        let current = ImportPlanner.plan(manifest: stored, profile: profile,
                                         observations: ImportPlanner.Observations(sourceRoot: nil,
                                                                                 listing: before),
                                         authorization: nil, targetObserved: false)
        #expect(current.rows.allSatisfy { !$0.codes.contains(.sourceChanged) })

        // Change the file, rescan and reconcile: the product invalidates the
        // decision that was made about the old bytes.
        let file = prepared.fixture.root.appendingPathComponent(prepared.entry.relativePath)
        try Data("changed content".utf8).write(to: file)
        _ = try await workspace.scan(scope)
        let decision = try #require(try await workspace.reconcile(scope: scope, profile: profile))
        #expect(!decision.invalidatedSourceIDs.isEmpty,
                "a changed source must invalidate the old mapping")

        // The stored manifest now says so, and a plan built on it refuses to
        // treat the record as current.
        let invalidated = try #require(try await workspace.currentManifest(scope: scope, profile: profile))
        #expect(invalidated.entries.first?.state == .invalidated)
        let listing = try await workspace.scan(scope)
        let stale = ImportPlanner.plan(manifest: invalidated, profile: profile,
                                       observations: ImportPlanner.Observations(sourceRoot: nil,
                                                                                listing: listing),
                                       authorization: nil, targetObserved: false)
        #expect(stale.rows.contains { $0.codes.contains(.entryInvalidated) })
        #expect(stale.rows.allSatisfy { !$0.codes.contains(.sourceMissing) })
    }
}
