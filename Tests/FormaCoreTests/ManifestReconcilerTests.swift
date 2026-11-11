import Foundation
import GRDB
import Testing

@testable import FormaCore

/// Reconciliation is the only production path that decides whether a stored
/// revision may still be used, so its branches are tested through the workspace
/// rather than only through the storage layer.
@Suite("Manifest reconciliation")
struct ManifestReconcilerTests {
    private struct Setup {
        let fixture: SourceFixture
        let workspace: SourceWorkspace
        let scope: SourceScope
        let store: SourceStore
        let profile: MappingProfile
    }

    private func prepared() async throws -> Setup {
        let fixture = try SourceFixture()
        _ = try fixture.write("notice", at: "示例项目_2026/01_招标/公告.pdf")
        _ = try fixture.write("bid", at: "示例项目_2026/02_投标/技术标.pdf")
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        _ = try await workspace.scan(scope)
        let store = try SourceStore(url: fixture.database)
        return Setup(fixture: fixture, workspace: workspace, scope: scope, store: store,
                     profile: try MappingProfile.projectArchive())
    }

    /// Stores a manifest for the current listing and context revision.
    private func file(_ setup: Setup) async throws -> Manifest {
        let listing = try await setup.workspace.listing(setup.scope)
        let context = try await setup.workspace.buildContext(scope: setup.scope, profile: setup.profile)
        let entries = listing.entries.map { item in
            ManifestEntry(
                sourceID: item.id, snapshotFingerprint: item.snapshotFingerprint,
                snapshotRevision: Int(item.snapshotRevision), sourceVersion: Int(item.sourceVersion),
                relativePath: item.relativePath, state: .validated,
                target: ManifestTarget(databaseName: "Project_Archive",
                                       groupPath: ["示例项目_2026", "01_招标文件"], resolved: true)
            )
        }
        let envelope = ManifestEnvelope(
            manifestID: UUID(), revision: 1, supersedesRevision: nil, scopeID: setup.scope.id,
            sourceRootID: listing.entries[0].rootID, profile: setup.profile,
            casePack: ("forma-governance-cases", "1.0"), modelProvider: "anthropic", modelID: nil,
            contextRevision: context.revision, promptVersion: "mapping.v1",
            extractorVersion: EvidenceRegistry.extractorVersion, redactionVersion: nil,
            inputDigest: context.inputDigest, contextDigest: String(repeating: "e", count: 64),
            createdAt: .now, state: .validated
        )
        let manifest = Manifest(envelope: envelope, entries: entries)
        return try await setup.workspace.saveManifest(manifest, scopeID: setup.scope.id)
    }

    @Test("an unchanged workspace reports nothing moved")
    func unchangedIsQuiet() async throws {
        let setup = try await prepared()
        defer { setup.fixture.cleanUp() }
        _ = try await file(setup)
        let decision = try await setup.workspace.reconcile(scope: setup.scope, profile: setup.profile)
        let value = try #require(decision)
        #expect(value.invalidatedSourceIDs.isEmpty)
        #expect(value.reason == "unchanged")
    }

    @Test("a new directory in another project invalidates only what moved")
    func membershipChangeIsScoped() async throws {
        let setup = try await prepared()
        defer { setup.fixture.cleanUp() }
        let stored = try await file(setup)
        // A second project appears; the first project's membership is untouched.
        _ = try setup.fixture.write("new project notice", at: "另一项目_2027/01_招标/公告.pdf")
        _ = try await setup.workspace.scan(setup.scope)
        let decision = try #require(await setup.workspace.reconcile(scope: setup.scope, profile: setup.profile))
        // The rebuilt context is stored, not fabricated: reconciliation must
        // compare two real revisions.
        let revisions = try await setup.store.database.read { db in
            try Row.fetchOne(db, sql: "SELECT COUNT(*) AS count FROM context_revisions")
        }
        #expect((revisions?["count"] as Int) == 2)
        #expect(decision.invalidatedSourceIDs.isEmpty,
                "an untouched project keeps its decisions, got \(decision.reason)")
        // Now the existing project itself grows, which must invalidate exactly
        // the file that joined it.
        _ = try setup.fixture.write("clarification", at: "示例项目_2026/03_澄清/说明.pdf")
        _ = try await setup.workspace.scan(setup.scope)
        let moved = try #require(await setup.workspace.reconcile(scope: setup.scope, profile: setup.profile))
        #expect(moved.reason == "membership_changed")
        #expect(!moved.invalidatedSourceIDs.isEmpty)
        let listing = try await setup.workspace.listing(setup.scope)
        let stillValid = Set(listing.entries.map(\.id)).subtracting(moved.invalidatedSourceIDs)
        #expect(!stillValid.isEmpty, "the entries that did not move stay usable")
        #expect(stored.entries.count == 2)
    }

    @Test("a second pass does not re-report an invalidation already made")
    func invalidationIsReportedOnce() async throws {
        let setup = try await prepared()
        defer { setup.fixture.cleanUp() }
        _ = try await file(setup)
        _ = try setup.fixture.write("clarification", at: "示例项目_2026/03_澄清/说明.pdf")
        _ = try await setup.workspace.scan(setup.scope)
        let first = try #require(await setup.workspace.reconcile(scope: setup.scope, profile: setup.profile))
        #expect(!first.invalidatedSourceIDs.isEmpty)
        // Nothing further moved, so the second pass must say so instead of
        // presenting the same damage as new.
        let second = try #require(await setup.workspace.reconcile(scope: setup.scope, profile: setup.profile))
        #expect(second.invalidatedSourceIDs.isEmpty)
        #expect(second.reason == "already_invalidated")
    }

    @Test("a content change invalidates that entry through its snapshot")
    func snapshotChangeIsScoped() async throws {
        let setup = try await prepared()
        defer { setup.fixture.cleanUp() }
        let stored = try await file(setup)
        let target = try #require(stored.entries.first)
        let url = setup.fixture.root.appendingPathComponent(target.relativePath)
        try Data("replacement body".utf8).write(to: url)
        _ = try await setup.workspace.scan(setup.scope)
        let decision = try #require(await setup.workspace.reconcile(scope: setup.scope, profile: setup.profile))
        #expect(decision.invalidatedSourceIDs == [target.sourceID])
        #expect(decision.reason == "snapshot_changed")
        // The stored revision keeps what it decided; only the validity index
        // changes, so the old revision stays auditable.
        let payload: Data? = try await setup.store.database.read { db in
            try Row.fetchOne(db, sql: "SELECT payload FROM manifests WHERE manifest_id = ? AND revision = ?",
                             arguments: [stored.envelope.manifestID.sourceKey, 1])?["payload"]
        }
        let original = try FormaJSON.decode(Manifest.self, from: try #require(payload))
        #expect(original.entry(for: target.sourceID)?.state == .validated)
        let overlaid = try #require(await setup.workspace.currentManifest(scope: setup.scope, profile: setup.profile))
        #expect(overlaid.entry(for: target.sourceID)?.state == .invalidated)
    }
}
