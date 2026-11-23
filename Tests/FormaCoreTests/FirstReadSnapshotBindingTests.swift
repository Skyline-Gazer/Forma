import Foundation
import Testing

@testable import FormaCore

/// #145: the first Offline Mapping run computed the first SHA-256 while it
/// captured evidence. FormaCore then advanced the source's snapshot revision
/// and registered the evidence rows against that *post-read* revision, while
/// the run mapped the *pre-read* listing it entered on. The published manifest
/// bound the old snapshot, the registry only held the new one, and the
/// reviewer's very first correction - citing exactly the rows the sheet shows -
/// was refused forever.
///
/// These suites pin the repair at FormaCore level through the production
/// binding path `WorkspaceModel.runMapping` now uses: one scan, one context,
/// one capture batch, one mapping run, first correction on the first attempt,
/// persisted and re-readable - with no second scan and with the citation gates
/// left exactly as strict as they were.
@Suite("First-read mapping snapshot binding")
struct FirstReadSnapshotBindingTests {
    /// One scanned file with no SHA-256, one stored project context, and one
    /// first body capture - the exact state in which the GUI used to publish
    /// an uncorrectable manifest.
    private struct FirstCapture {
        let fixture: SourceFixture
        let workspace: SourceWorkspace
        let scope: SourceScope
        let profile: MappingProfile
        let context: ProjectContext
        let scanned: SourceListing
        let before: SourceEntry
        let captured: [UUID: [EvidenceRecord]]

        init() async throws {
            let fixture = try SourceFixture()
            let url = fixture.root.appendingPathComponent(
                "示例项目_2026/01_招标文件/01_招标公告.pdf")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try makePDF(["示例项目_2026 招标公告 归档完成 2027 年"]).write(to: url)
            let workspace = try SourceWorkspace(databaseURL: fixture.database)
            let scope = try await workspace.register(fixture.root)
            let scanned = try await workspace.scan(scope)
            let profile = try MappingProfile.projectArchive()
            let context = try await workspace.buildContext(scope: scope, profile: profile)
            let before = try #require(scanned.entries.first)
            let captured = try await workspace.captureEvidence(for: [before])
            self.fixture = fixture
            self.workspace = workspace
            self.scope = scope
            self.profile = profile
            self.context = context
            self.scanned = scanned
            self.before = before
            self.captured = captured
        }
    }

    @Test("one scan and first body capture bind the corrected offline manifest to the post-read snapshot")
    func firstReadEvidenceCanSupportFirstCorrection() async throws {
        let state = try await FirstCapture()
        defer { state.fixture.cleanUp() }
        let workspace = state.workspace
        let scope = state.scope
        let profile = state.profile
        let context = state.context
        let before = state.before
        #expect(before.snapshotRevision == 1)
        #expect(before.sha256 == nil)

        // The production binding `WorkspaceModel.runMapping` applies after the
        // capture batch: one database listing read, no second user Scan.
        let binding = try await workspace.bindCapturedTargets([before], captured: state.captured,
                                                              readFailures: [:], scope: scope,
                                                              profile: profile, context: context)
        guard case .bound(let targets, let evidence, let unread, let currentListing) = binding else {
            Issue.record("a first capture that only advances the snapshot must bind, not refuse")
            return
        }
        #expect(currentListing.scanID == state.scanned.scanID,
                "binding must not require a second scan")
        let current = try #require(targets.first)
        #expect(current.id == before.id)
        #expect(current.snapshotRevision > before.snapshotRevision)
        #expect(current.snapshotFingerprint != before.snapshotFingerprint)
        #expect(unread.isEmpty)
        let rows = try #require(state.captured[before.id])
        #expect(evidence[before.id]?.map(\.id) == rows.map(\.id))
        #expect(rows.allSatisfy {
            $0.sourceID == current.id
                && $0.snapshotRevision == Int(current.snapshotRevision)
                && $0.snapshotFingerprint == current.snapshotFingerprint
        })
        // Project-context membership binds stable IDs, paths and states, not
        // SHA-256 or snapshot revisions, so the normal first-hash update leaves
        // the stored context intact and no rebuild is demanded.
        #expect(ContextBuilder.inputDigest(scopeID: scope.id, profile: profile,
                                           entries: currentListing.entries) == context.inputDigest)

        let engine = MappingEngine(profile: profile, casePack: try CasePack.shipped(),
                                   answerer: OfflinePlannerAnswerer(), workspace: workspace)
        let result = await engine.run(
            MappingRunRequest(scope: scope, profile: profile, context: context,
                              entries: targets, evidence: evidence,
                              provider: .offline, model: OfflinePlannerAnswerer.modelID,
                              allowCloud: false))
        #expect(result.requests == 0)
        let entry = try #require(result.manifest.entries.first)
        #expect(entry.snapshotRevision == Int(current.snapshotRevision))
        #expect(entry.snapshotFingerprint == current.snapshotFingerprint)

        let stored = try await workspace.saveManifest(result.manifest, scopeID: scope.id)
        let citedPath = try #require(rows.first {
            $0.source == .path && $0.isUsable && ($0.excerpt ?? "").contains("示例项目_2026")
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

    @Test("a manifest mapped from the pre-capture listing stays refused, and the refusal names the stale snapshot")
    func stalePreCaptureMappingStaysRefused() async throws {
        let state = try await FirstCapture()
        defer { state.fixture.cleanUp() }
        let workspace = state.workspace
        let scope = state.scope
        let profile = state.profile
        let before = state.before

        // Exactly what `WorkspaceModel.runMapping` did on the failing build:
        // map the pre-capture entry while the registry holds only the
        // post-read rows.
        let engine = MappingEngine(profile: profile, casePack: try CasePack.shipped(),
                                   answerer: OfflinePlannerAnswerer(), workspace: workspace)
        let result = await engine.run(
            MappingRunRequest(scope: scope, profile: profile, context: state.context,
                              entries: [before], evidence: state.captured,
                              provider: .offline, model: OfflinePlannerAnswerer.modelID,
                              allowCloud: false))
        let stale = try #require(result.manifest.entries.first)
        #expect(stale.snapshotRevision == Int(before.snapshotRevision),
                "without binding, the manifest stays pinned to the pre-read snapshot")
        let stored = try await workspace.saveManifest(result.manifest, scopeID: scope.id)

        // The repair does not weaken the citation gate: a row from the newer
        // snapshot stays refused for the older-bound entry. What changes is
        // the honest diagnosis - a stale snapshot, not missing evidence - so
        // the review screen can ask for a re-read instead of a rescan, with no
        // path or content in the message.
        let rows = try #require(state.captured[before.id])
        let citedPath = try #require(rows.first {
            $0.source == .path && $0.isUsable && ($0.excerpt ?? "").contains("示例项目_2026")
        })
        let applied = try await workspace.applyCorrection(
            to: stored, sourceID: before.id, field: .projectname,
            correctedValue: "示例项目_2026", evidenceIDs: [citedPath.id],
            origin: .manual, scope: scope, profile: profile)
        #expect(applied.violations.contains { $0.code == "evidence_snapshot_mismatch" },
                "a superseded-snapshot citation must be reported as stale, not missing: \(applied.violations.map(\.code))")
        #expect(!applied.violations.contains { $0.code == "evidence_not_found" })
        #expect(applied.correction.reviewState == .rejected)
        #expect(applied.correction.producedRevision == nil)
        #expect(applied.manifest.entries.first?.metadata[.projectname] == nil)
        let reopened = try #require(try await workspace.currentManifest(scope: scope, profile: profile))
        #expect(reopened.envelope.revision == stored.envelope.revision,
                "a refused correction must not publish a revision")
    }

    @Test("binding separates a lost target from a moved context, and refuses neither silently")
    func bindingReportsStructureAndContextChanges() async throws {
        let fixture = try SourceFixture()
        defer { fixture.cleanUp() }
        let urlA = fixture.root.appendingPathComponent("示例项目_2026/01_招标文件/a.pdf")
        let urlB = fixture.root.appendingPathComponent("示例项目_2026/02_开标记录/b.pdf")
        try FileManager.default.createDirectory(at: urlA.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: urlB.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try makePDF(["示例项目_2026 招标公告"]).write(to: urlA)
        try makePDF(["开标记录 2026"]).write(to: urlB)
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let scanned = try await workspace.scan(scope)
        #expect(scanned.entries.count == 2)
        let profile = try MappingProfile.projectArchive()
        let context = try await workspace.buildContext(scope: scope, profile: profile)

        // A target whose id the scope listing no longer carries at all is a
        // listing change, and it is reported instead of mapped around. The
        // entry is constructed directly, the way the engine-level suites do,
        // because the point is the id, not how the listing lost it.
        let ghostPath = "示例项目_2026/03_合同/ghost.pdf"
        let ghost = SourceEntry(id: UUID(), rootID: scope.rootID, relativePath: ghostPath,
                                normalizedRelativePath: ghostPath.lowercased(), state: .present,
                                hydrationPending: false, sourceVersion: 1, snapshotRevision: 1,
                                provider: .local, snapshotFingerprint: String(repeating: "a", count: 64),
                                sizeBytes: 1_024, modificationTimeNanoseconds: 0, sha256: nil)
        let lost = try await workspace.bindCapturedTargets(scanned.entries + [ghost], captured: [:],
                                                           readFailures: [:], scope: scope,
                                                           profile: profile, context: context)
        guard case .listingChanged(let listing1) = lost else {
            Issue.record("ids the listing does not carry must be reported as a changed listing")
            return
        }
        #expect(listing1.entries.count == 2)

        // A file that leaves the present set and a file that joins it move
        // the membership digest: the stored context no longer describes the
        // listing, so the run needs a fresh context - reported, not faked,
        // and not demanded for the ordinary first-hash advance above.
        try FileManager.default.removeItem(at: urlB)
        let rescanned = try await workspace.scan(scope)
        let moved = try await workspace.bindCapturedTargets(scanned.entries, captured: [:],
                                                            readFailures: [:], scope: scope,
                                                            profile: profile, context: context)
        guard case .contextStale(let listing2) = moved else {
            Issue.record("a moved membership must be reported as a stale context")
            return
        }
        #expect(listing2.entries.count == rescanned.entries.count)
        #expect(listing2.entries.contains { $0.state == .missing })
    }

    @Test("binding drops rows that do not describe the reported snapshot and keeps read failures distinct")
    func bindingDropsMisboundRows() async throws {
        let state = try await FirstCapture()
        defer { state.fixture.cleanUp() }
        let workspace = state.workspace
        let scope = state.scope
        let currentListing = try await workspace.listing(scope)
        let current = try #require(currentListing.entries.first)

        // A row claiming a snapshot the listing does not report must never
        // enter a new manifest, even if a caller hands it over: the strict
        // source/snapshot gate is enforced here, not relaxed.
        let forged = EvidenceRecord(id: "ev_forged", sourceID: current.id,
                                    snapshotRevision: Int(current.snapshotRevision) + 7,
                                    snapshotFingerprint: String(repeating: "f", count: 64),
                                    source: .path, locator: nil, relativePath: current.relativePath,
                                    excerpt: "示例项目_2026", extractionStatus: .ok,
                                    extractorVersion: EvidenceRegistry.extractorVersion, createdAt: .now)
        let unreadID = UUID()
        let binding = try await workspace.bindCapturedTargets([current], captured: [current.id: [forged]],
                                                              readFailures: [unreadID: .unavailable],
                                                              scope: scope, profile: state.profile,
                                                              context: state.context)
        guard case .bound(let targets, let evidence, let unread, _) = binding else {
            Issue.record("ids and membership are unchanged here; binding must succeed")
            return
        }
        #expect(targets.count == 1 && targets[0].id == current.id)
        #expect(evidence.isEmpty, "rows from a snapshot the listing does not report must not be mapped")
        #expect(unread[current.id] == .sourceChanged,
                "a stale snapshot is reported as a moved source, distinctly")
        #expect(unread[unreadID] == .unavailable,
                "an unread file is a different failure from a stale snapshot")
    }
}
