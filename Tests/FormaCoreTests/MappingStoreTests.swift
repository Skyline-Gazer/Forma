import Foundation
import GRDB
import Testing

@testable import FormaCore

/// Storage behaviour for the mapping layer: immutable revisions, the index that
/// carries validity, and the foreign keys that stop a manifest or an evidence
/// row from naming a source that does not exist.
@Suite("Mapping store")
struct MappingStoreTests {
    private struct Setup {
        let fixture: SourceFixture
        let scope: SourceScope
        let entries: [SourceEntry]
        let store: SourceStore
    }

    /// A real workspace with two scanned files, so every assertion runs against
    /// rows that satisfy the source foreign keys.
    private func prepared() async throws -> Setup {
        let fixture = try SourceFixture()
        _ = try fixture.write("tender notice", at: "示例项目_2026/01_招标/公告.pdf")
        _ = try fixture.write("datasheet", at: "厂商/产品A_数据表.pdf")
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let listing = try await workspace.scan(scope)
        let store = try SourceStore(url: fixture.database)
        return Setup(fixture: fixture, scope: scope, entries: listing.entries, store: store)
    }

    private func context(revision: Int, digest: String, members: [UUID], profile: MappingProfile,
                         scopeID: UUID) -> ProjectContext {
        ProjectContext(
            revision: revision, scopeID: scopeID, profileID: profile.profileID,
            profileVersion: profile.profileVersion, inputDigest: digest,
            candidates: members.isEmpty ? [] : [ContextCandidate(
                id: "c\(revision)", projectKey: "示例项目_2026", displayName: "示例项目",
                basis: [.directory], memberSourceIDs: Set(members), confidence: .medium
            )],
            unassignedSourceIDs: [], conflictedSourceIDs: [], builtAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test("a context revision survives a round trip and is only reused on a matching digest")
    func contextRoundTrip() async throws {
        let setup = try await prepared()
        defer { setup.fixture.cleanUp() }
        let profile = try MappingProfile.projectArchive()
        let first = context(revision: 1, digest: String(repeating: "a", count: 64),
                            members: setup.entries.map(\.id), profile: profile, scopeID: setup.scope.id)
        try await setup.store.database.write { db in
            try MappingStore.insertContext(first, scopeID: setup.scope.id, in: db)
        }

        let loaded = try await setup.store.database.read { db in
            try MappingStore.currentContext(scopeID: setup.scope.id, profile: profile,
                                            inputDigest: first.inputDigest, in: db)
        }
        #expect(loaded == first)
        let stale = try await setup.store.database.read { db in
            try MappingStore.currentContext(scopeID: setup.scope.id, profile: profile,
                                            inputDigest: String(repeating: "b", count: 64), in: db)
        }
        #expect(stale == nil, "a changed input digest must not return the old context")
        let next = try await setup.store.database.read { db in
            try MappingStore.nextContextRevision(scopeID: setup.scope.id, profile: profile, in: db)
        }
        #expect(next == 2)
    }

    @Test("a stored context stays readable at the revision a manifest cites")
    func contextRevisionStaysReadable() async throws {
        let setup = try await prepared()
        defer { setup.fixture.cleanUp() }
        let profile = try MappingProfile.projectArchive()
        let first = context(revision: 1, digest: String(repeating: "a", count: 64),
                            members: [setup.entries[0].id], profile: profile, scopeID: setup.scope.id)
        let second = context(revision: 2, digest: String(repeating: "c", count: 64),
                             members: [setup.entries[1].id], profile: profile, scopeID: setup.scope.id)
        try await setup.store.database.write { db in
            try MappingStore.insertContext(first, scopeID: setup.scope.id, in: db)
            try MappingStore.insertContext(second, scopeID: setup.scope.id, in: db)
        }
        // Reconciliation needs the exact revision a manifest references, not
        // just the newest one, or it cannot tell membership change from rebuild.
        let cited = try await setup.store.database.read { db in
            try MappingStore.context(scopeID: setup.scope.id, profile: profile, revision: 1, in: db)
        }
        #expect(cited == first)
        let newest = try await setup.store.database.read { db in
            try MappingStore.context(scopeID: setup.scope.id, profile: profile, revision: 3, in: db)
        }
        #expect(newest == nil)
    }

    @Test("evidence keeps its locator and status through storage")
    func evidenceRoundTrip() async throws {
        let setup = try await prepared()
        defer { setup.fixture.cleanUp() }
        let entry = try #require(setup.entries.first { $0.relativePath.contains("公告") })
        let record = EvidenceRecord(
            id: "ev_\(UUID().uuidString)", sourceID: entry.id, snapshotRevision: Int(entry.snapshotRevision),
            snapshotFingerprint: entry.snapshotFingerprint, source: .content,
            locator: .pdf(page: 2, characterRange: 5..<20), relativePath: nil,
            excerpt: "采购公告正文片段", extractionStatus: .truncated,
            extractorVersion: EvidenceRegistry.extractorVersion,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), contextCandidateID: "c7"
        )
        try await setup.store.database.write { db in try MappingStore.insertEvidence([record], in: db) }
        let loaded = try await setup.store.database.read { db in try MappingStore.evidence(for: entry.id, in: db) }
        #expect(loaded == [record])
        #expect(loaded[0].isUsable)
        #expect(loaded[0].locator == .pdf(page: 2, characterRange: 5..<20))
        #expect(loaded[0].contextCandidateID == "c7")

        // Re-reading a file replaces its evidence set; a stale excerpt must not
        // stay citable.
        let replacement = EvidenceRecord(
            id: "ev_\(UUID().uuidString)", sourceID: entry.id,
            snapshotRevision: Int(entry.snapshotRevision) + 1, snapshotFingerprint: "f", source: .content,
            locator: .pdf(page: 1, characterRange: 0..<4), relativePath: nil, excerpt: "新",
            extractionStatus: .ok, extractorVersion: EvidenceRegistry.extractorVersion,
            createdAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
        try await setup.store.database.write { db in
            try MappingStore.replaceEvidence([replacement], for: entry.id, in: db)
        }
        let after = try await setup.store.database.read { db in try MappingStore.evidence(for: entry.id, in: db) }
        #expect(after == [replacement])
        let missing = try await setup.store.database.read { db in
            try MappingStore.evidence(ids: [record.id], in: db)
        }
        #expect(missing.isEmpty)
    }

    @Test("evidence cannot name a source that does not exist")
    func evidenceRequiresARealSource() async throws {
        let setup = try await prepared()
        defer { setup.fixture.cleanUp() }
        let invented = EvidenceRecord(
            id: "ev_invented", sourceID: UUID(), snapshotRevision: 1, snapshotFingerprint: "x",
            source: .content, locator: nil, relativePath: nil, excerpt: "x", extractionStatus: .ok,
            extractorVersion: EvidenceRegistry.extractorVersion, createdAt: .now
        )
        var failure: (any Error)?
        do {
            try await setup.store.database.write { db in try MappingStore.insertEvidence([invented], in: db) }
        } catch {
            failure = error
        }
        #expect(failure != nil, "the registry must reject a citation of an unknown source")
    }

    @Test("invalidating a subset keeps the untouched entries and the original payload")
    func manifestInvalidationIsOverlayOnly() async throws {
        let setup = try await prepared()
        defer { setup.fixture.cleanUp() }
        let profile = try MappingProfile.projectArchive()
        let manifestID = UUID()
        let envelope = ManifestEnvelope(
            manifestID: manifestID, revision: 1, supersedesRevision: nil, scopeID: setup.scope.id,
            sourceRootID: setup.entries[0].rootID, profile: profile,
            casePack: ("forma-governance-cases", "1.0"),
            modelProvider: "anthropic", modelID: "claude-haiku-4-5-20251001", contextRevision: 1,
            promptVersion: "mapping.v1", extractorVersion: EvidenceRegistry.extractorVersion,
            redactionVersion: nil,
            inputDigest: String(repeating: "1", count: 64), contextDigest: String(repeating: "2", count: 64),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), state: .validated
        )
        let entries = setup.entries.map { item in
            ManifestEntry(sourceID: item.id, snapshotFingerprint: item.snapshotFingerprint,
                          snapshotRevision: Int(item.snapshotRevision), sourceVersion: Int(item.sourceVersion),
                          relativePath: item.relativePath, state: .validated,
                          target: ManifestTarget(databaseName: "Project_Archive",
                                                 groupPath: ["2026", "示例项目", "01_招标文件"], resolved: true),
                          eligibleForAutoExecution: true)
        }
        let manifest = Manifest(envelope: envelope, entries: entries)
        try await setup.store.database.write { db in
            try MappingStore.insertManifest(manifest, scopeID: setup.scope.id, in: db)
        }

        let changed = Set([entries[0].sourceID])
        try await setup.store.database.write { db in
            try MappingStore.invalidate(manifestID: manifestID, revision: 1, sourceIDs: changed,
                                        reason: "snapshot_changed", in: db)
        }
        let reloaded = try #require(try await setup.store.database.read { db in
            try MappingStore.manifest(id: manifestID, revision: 1, in: db)
        })
        #expect(reloaded.entry(for: entries[0].sourceID)?.state == .invalidated)
        #expect(reloaded.entry(for: entries[0].sourceID)?.eligibleForAutoExecution == false)
        #expect(reloaded.entry(for: entries[0].sourceID)?.invalidatedReason == "snapshot_changed")
        if entries.count > 1 {
            #expect(reloaded.entry(for: entries[1].sourceID)?.state == .validated)
            #expect(reloaded.entry(for: entries[1].sourceID)?.eligibleForAutoExecution == true)
        }
        // The stored artifact still records what was decided before the change.
        let rawPayload: Data? = try await setup.store.database.read { db in
            try Row.fetchOne(db, sql: "SELECT payload FROM manifests WHERE manifest_id = ? AND revision = ?",
                             arguments: [manifestID.sourceKey, 1])?["payload"]
        }
        let raw = try FormaJSON.decode(Manifest.self, from: try #require(rawPayload))
        #expect(raw.entry(for: entries[0].sourceID)?.state == .validated)
        let next = try await setup.store.database.read { db in
            try MappingStore.nextManifestRevision(manifestID: manifestID, in: db)
        }
        #expect(next == 2)
    }

    @Test("provider usage is recorded per attempt and a crashed run is not resumable")
    func runsAndCalls() async throws {
        let setup = try await prepared()
        defer { setup.fixture.cleanUp() }
        let profile = try MappingProfile.projectArchive()
        // The case pack arrives with a later slice; the run log only needs the
        // version string it would have cited.
        let run = MappingRun(scopeID: setup.scope.id, profile: profile, contextRevision: 1,
                             casePackVersion: "1.0", modelProvider: "openai", modelID: "gpt-4o-mini",
                             promptVersion: "mapping.v1")
        try await setup.store.database.write { db in
            try MappingStore.startRun(run, in: db)
            try MappingStore.recordProviderCall(ProviderCall(
                id: UUID(), runID: run.id, batchIndex: 0, attempt: 1, provider: "openai",
                modelID: "gpt-4o-mini", inputTokens: 1_200, outputTokens: 340, cacheReadTokens: 0,
                cacheCreationTokens: nil, latencyMilliseconds: 900, outcome: .invalidOutput,
                errorCode: "invalid_output", createdAt: .now
            ), in: db)
        }
        // Reopening without finishing leaves the run `running`; a fresh store
        // must convert it to `failed` rather than pretend it is in progress.
        let reopened = try SourceStore(url: setup.fixture.database)
        let state = try await reopened.database.read { db -> (String, String?)? in
            guard let row = try Row.fetchOne(db, sql: "SELECT state, error_code FROM mapping_runs WHERE id = ?",
                                             arguments: [run.id.sourceKey]) else { return nil }
            let code: String? = row["error_code"]
            return (row["state"], code)
        }
        #expect(state?.0 == "failed")
        #expect(state?.1 == "interrupted")

        try await reopened.database.write { db in
            try MappingStore.recordProviderCall(ProviderCall(
                id: UUID(), runID: run.id, batchIndex: 0, attempt: 2, provider: "openai",
                modelID: "gpt-4o-mini", inputTokens: 1_300, outputTokens: 400, cacheReadTokens: 1_024,
                cacheCreationTokens: nil, latencyMilliseconds: 1_100, outcome: .ok, errorCode: nil,
                createdAt: .now
            ), in: db)
        }
        let calls = try await reopened.database.read { db in try MappingStore.providerCalls(runID: run.id, in: db) }
        #expect(calls.count == 2)
        #expect(calls.map(\.attempt) == [1, 2])
        #expect(calls[1].cacheReadTokens == 1_024)
    }
}
