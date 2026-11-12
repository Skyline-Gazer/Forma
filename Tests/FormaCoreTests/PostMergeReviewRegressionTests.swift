import Foundation
import Testing

@testable import FormaCore

/// Each test here is a defect that reached `dev` during P2 and was fixed after
/// the merge that introduced it (#45). They are pinned at the storage boundary
/// the app actually uses, because that is where each one was wrong: what a read
/// returns, and which rows a write had.
///
/// The screen itself is not covered here - FormaApp has no test target and the
/// app target cannot be type-checked off CI - so each test names the app-side
/// mistake it stands for, and the guarantee it provides is the core-side
/// property the app depends on.
@Suite("Post-merge review regressions")
struct PostMergeReviewRegressionTests {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A second manifest for the same scope and profile, created later.
    ///
    /// The store tolerates this: `manifests` is keyed by manifest id, and
    /// "current" is a query about the pair. Opening an exported bundle next to
    /// locally mapped material produces exactly this state.
    private func sibling(of prepared: MappingContext) async throws -> Manifest {
        let envelope = prepared.manifest.envelope
        let later = ManifestEnvelope(
            manifestID: UUID(), revision: 1, supersedesRevision: nil, scopeID: envelope.scopeID,
            sourceRootID: envelope.sourceRootID, profile: prepared.profile,
            casePack: (envelope.casePackID, envelope.casePackVersion),
            modelProvider: envelope.modelProvider, modelID: envelope.modelID,
            contextRevision: envelope.contextRevision, promptVersion: envelope.promptVersion,
            extractorVersion: envelope.extractorVersion, redactionVersion: envelope.redactionVersion,
            inputDigest: envelope.inputDigest, contextDigest: envelope.contextDigest,
            createdAt: envelope.createdAt.addingTimeInterval(3_600), state: .draft
        )
        return try await prepared.workspace.saveManifest(
            Manifest(envelope: later, entries: prepared.manifest.entries), scopeID: prepared.scope.id)
    }

    @Test("a correction returns the manifest it wrote, not the newest of the pair")
    func writeReturnsItsOwnManifest() async throws {
        let prepared = try await preparedMapping()
        defer { prepared.fixture.cleanUp() }
        let corrected = prepared.manifest
        let other = try await sibling(of: prepared)
        #expect(other.envelope.manifestID != corrected.envelope.manifestID)

        let applied = try await prepared.workspace.applyCorrection(
            to: corrected, sourceID: prepared.sourceID, field: .completionyear,
            correctedValue: "2027", evidenceIDs: [prepared.yearRow], origin: .manual,
            scope: prepared.scope, profile: prepared.profile)
        #expect(applied.violations.isEmpty, "violations: \(applied.violations.map(\.code))")

        // The returned manifest is the one the click corrected, at the revision
        // it wrote. Nothing about it depends on which manifest the store happens
        // to consider current for this scope and profile.
        #expect(applied.manifest.envelope.manifestID == corrected.envelope.manifestID)
        #expect(applied.manifest.envelope.revision == corrected.envelope.revision + 1)
        #expect(applied.manifest.entries[0].metadata[.completionyear] == "2027")

        // And the trap the old code fell into is real, not hypothetical: asking
        // for "the current manifest" here answers with the sibling, whose header
        // and entries describe a listing this decision never touched. A screen
        // that painted that read-back would show the wrong table under a notice
        // about the right revision.
        let newest = try await prepared.workspace.currentManifest(scope: prepared.scope,
                                                                  profile: prepared.profile)
        #expect(newest?.envelope.manifestID != applied.manifest.envelope.manifestID,
                "if this ever stops holding, the read-back the app removed would be harmless again")
    }

    @Test("a fresh session reads the rows a stored manifest cites")
    func citedRowsSurviveTheSession() async throws {
        let prepared = try await preparedMapping()
        defer { prepared.fixture.cleanUp() }
        let cited = Set(prepared.manifest.entries.flatMap { $0.fields.flatMap(\.evidenceIDs) })
        #expect(!cited.isEmpty)

        // A new workspace over the same database: no scan, no capture, nothing
        // "opened". This is the state of an app launched onto an existing store,
        // which is where exporting from a session cache lost rows.
        let reopened = try SourceWorkspace(databaseURL: prepared.fixture.database)
        let scope = try await reopened.register(prepared.fixture.root)
        let stored = try #require(await reopened.currentManifest(scope: scope, profile: prepared.profile))
        let grouped = try await reopened.registeredEvidence(for: Set(stored.entries.map(\.sourceID)))
        let readable = Set(grouped.values.flatMap { $0 }.map(\.id))

        #expect(cited.isSubset(of: readable),
                "citations the registry cannot answer: \(cited.subtracting(readable).sorted())")

        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try ManifestExport.export(manifest: stored, evidence: grouped.values.flatMap { $0 }, to: directory)
        // The bundle is the subdirectory named by the manifest id; revalidating
        // the parent is a different operation that fails for the wrong reason.
        let bundle = directory.appendingPathComponent(stored.envelope.manifestID.sourceKey, isDirectory: true)
        let check = try ManifestExport.revalidate(at: bundle)
        #expect(check.missingEvidence.isEmpty, "bundle cites rows it does not carry: \(check.missingEvidence)")
        #expect(check.artifactConsistent, "violations: \(check.violations.map(\.code))")
    }

    @Test("verification finds every cited row across a long history")
    func longHistoryCitations() async throws {
        let prepared = try await preparedMapping()
        defer { prepared.fixture.cleanUp() }
        let snapshot = Int(prepared.entry.snapshotRevision)

        // Superseded snapshots, so the row list for this source is long and only
        // some of it is usable for the entry the reviewer is correcting. The
        // count is not the point; the mixture is - a rewrite that indexed the
        // wrong copy would still pass a single-row fixture.
        var stale: [EvidenceRecord] = []
        for revision in (1...24).reversed() where revision != snapshot {
            stale.append(EvidenceRecord(
                id: "stale-\(revision)", sourceID: prepared.sourceID, snapshotRevision: revision,
                snapshotFingerprint: String(repeating: "\(revision % 10)", count: 64),
                source: .content, locator: .pdf(page: 1, characterRange: 0..<8), relativePath: nil,
                excerpt: "旧快照 \(revision)", extractionStatus: .ok,
                extractorVersion: EvidenceRegistry.extractorVersion, createdAt: .now))
        }
        try await prepared.workspace.recordEvidence(stale, for: prepared.sourceID)

        let current = try await prepared.workspace.evidenceRegistry(for: prepared.sourceID,
                                                                    snapshotRevision: snapshot)
        let usable = current.filter { $0.isUsable }
        #expect(!usable.isEmpty)
        let older = try await prepared.workspace.evidenceRegistry(for: prepared.sourceID)
        #expect(older.count > usable.count, "the history has to be longer than the current snapshot")

        // Citing the current snapshot's row still verifies, with the noise in the
        // same list.
        let year = try #require(usable.first { ($0.excerpt ?? "").contains("2027") })
        let accepted = try await prepared.workspace.applyCorrection(
            to: prepared.manifest, sourceID: prepared.sourceID, field: .completionyear,
            correctedValue: "2027", evidenceIDs: [year.id], origin: .manual,
            scope: prepared.scope, profile: prepared.profile)
        #expect(accepted.violations.isEmpty, "violations: \(accepted.violations.map(\.code))")

        // Citing a superseded snapshot is still refused, however far down the
        // list it sits: the binding is to the snapshot the manifest describes.
        let refused = try await prepared.workspace.applyCorrection(
            to: accepted.manifest, sourceID: prepared.sourceID, field: .issuer,
            correctedValue: "某招标代理有限公司", evidenceIDs: [stale[3].id], origin: .manual,
            scope: prepared.scope, profile: prepared.profile)
        #expect(!refused.violations.isEmpty, "a row from another snapshot was accepted")
    }
}

