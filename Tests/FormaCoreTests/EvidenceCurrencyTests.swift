import Foundation
import Testing

@testable import FormaCore

/// #145 follow-up: the correction gate has to be able to say *why* a citation
/// failed, because the reviewer's next move differs per reason. Evidence that
/// was read from a snapshot the file has since left is expired evidence - the
/// fix is to re-read the file's evidence and cite the new rows. Evidence the
/// registry never held is missing evidence - no re-read will ever produce it,
/// because it was never there.
///
/// The old gate could only see the rows a source holds right now. An expired
/// row was therefore answered as missing evidence, and the review screen then
/// told the reviewer to go and look for evidence that had never been lost.
/// The refusal has to be exact, and the recovery has to be reachable.
@Suite("Evidence currency at the correction gate")
struct EvidenceCurrencyTests {
    private let scopeID = UUID(uuidString: "00000000-0000-4000-8000-000000000080")!
    private let rootID = UUID(uuidString: "00000000-0000-4000-8000-000000000081")!
    private let sourceID = UUID(uuidString: "00000000-0000-4000-8000-000000000082")!
    private let otherSourceID = UUID(uuidString: "00000000-0000-4000-8000-000000000083")!
    private let fingerprint = String(repeating: "a", count: 64)

    private func source(revision: Int64 = 2, snapshotFingerprint: String? = nil) -> SourceEntry {
        SourceEntry(id: sourceID, rootID: rootID, relativePath: "示例项目_2026/01_招标/公告.pdf",
                    normalizedRelativePath: "示例项目_2026/01_招标/公告.pdf", state: .present,
                    hydrationPending: false, sourceVersion: 1, snapshotRevision: revision, provider: .local,
                    snapshotFingerprint: snapshotFingerprint ?? fingerprint, sizeBytes: 10,
                    modificationTimeNanoseconds: 0, sha256: nil)
    }

    private func record(id: String, excerpt: String?, revision: Int = 2, owner: UUID? = nil,
                        status: EvidenceStatus = .ok, snapshotFingerprint: String? = nil) -> EvidenceRecord {
        EvidenceRecord(id: id, sourceID: owner ?? sourceID, snapshotRevision: revision,
                       snapshotFingerprint: snapshotFingerprint ?? fingerprint, source: .content,
                       locator: .pdf(page: 1, characterRange: 0..<12), relativePath: nil, excerpt: excerpt,
                       extractionStatus: status, extractorVersion: EvidenceRegistry.extractorVersion,
                       createdAt: .now)
    }

    private func context(profile: MappingProfile) -> ProjectContext {
        ProjectContext(revision: 2, scopeID: scopeID, profileID: profile.profileID,
                       profileVersion: profile.profileVersion, inputDigest: String(repeating: "1", count: 64),
                       candidates: [ContextCandidate(id: "c1", projectKey: "示例项目_2026", displayName: nil,
                                                      basis: [.directory], memberSourceIDs: [sourceID],
                                                      confidence: .medium)],
                       unassignedSourceIDs: [], conflictedSourceIDs: [], builtAt: .now)
    }

    private func manifest(_ profile: MappingProfile, state: DecisionState) -> Manifest {
        let envelope = ManifestEnvelope(
            manifestID: UUID(), revision: 1, supersedesRevision: nil, scopeID: scopeID, sourceRootID: rootID,
            profile: profile, casePack: ("forma-governance-cases", "1.0"), modelProvider: "anthropic",
            modelID: "claude-haiku-4-5-20251001", contextRevision: 2, promptVersion: MappingPrompt.version,
            extractorVersion: EvidenceRegistry.extractorVersion, redactionVersion: nil,
            inputDigest: String(repeating: "2", count: 64), contextDigest: String(repeating: "3", count: 64),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), state: .draft
        )
        var metadata = MetadataValues.allUnknown
        metadata[.documentcategory] = "01_招标文件"
        metadata[.projectname] = "示例项目_2026"
        metadata[.completionyear] = "2026"
        let citations: [MetadataFieldID: [String]] = [
            .documentcategory: ["ev_cat"],
            .projectname: ["ev_name"],
            .completionyear: ["ev_year"],
        ]
        var fields: [FieldOutcome] = []
        for field in MetadataFieldID.allCases {
            let value = metadata[field]
            fields.append(FieldOutcome(field: field, value: value,
                                       status: value == nil ? .unknown : .evidenced,
                                       evidenceIDs: citations[field] ?? []))
        }
        let entry = ManifestEntry(
            sourceID: sourceID, snapshotFingerprint: fingerprint, snapshotRevision: 2, sourceVersion: 1,
            relativePath: "示例项目_2026/01_招标/公告.pdf", state: state,
            target: ManifestTarget(databaseName: "Project_Archive",
                                   groupPath: ["2026", "示例项目_2026", "01_招标文件"], resolved: true),
            metadata: metadata, fields: fields
        )
        return Manifest(envelope: envelope, entries: [entry])
    }

    private func rows() -> [EvidenceRecord] {
        [
            record(id: "ev_cat", excerpt: "01_招标文件 招标公告"),
            record(id: "ev_name", excerpt: "示例项目_2026 智能化项目"),
            record(id: "ev_year", excerpt: "归档完成 2026 年"),
        ]
    }

    @Test("a citation the registry never held is missing evidence")
    func fabricatedCitationIsMissingEvidence() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        let applied = engine.apply(to: manifest(profile, state: .hold), sourceID: sourceID,
                                   field: .completionyear, correctedValue: "2027",
                                   evidenceIDs: ["ev_never_registered"], origin: .manual,
                                   context: context(profile: profile),
                                   evidence: [sourceID: rows()], currentEntries: [source()])
        #expect(applied.violations.contains { $0.code == "evidence_not_found" },
                "violations: \(applied.violations.map(\.code))")
        #expect(!applied.violations.contains { $0.code == "evidence_snapshot_mismatch" },
                "an id nobody ever registered is missing, not expired")
        #expect(applied.correction.producedRevision == nil)
    }

    @Test("a citation of a row from an older snapshot is expired evidence, not missing evidence")
    func expiredCitationIsStaleEvidence() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        // The row is in the registry, under this source, and readable - it was
        // read from revision 1 of the file, and the file has since been
        // re-read as revision 2.
        let expired = record(id: "ev_old", excerpt: "归档完成 2025 年", revision: 1)
        let applied = engine.apply(to: manifest(profile, state: .hold), sourceID: sourceID,
                                   field: .completionyear, correctedValue: "2027",
                                   evidenceIDs: ["ev_old"], origin: .manual,
                                   context: context(profile: profile),
                                   evidence: [sourceID: rows() + [expired]], currentEntries: [source()])
        #expect(applied.violations.contains { $0.code == "evidence_snapshot_mismatch" },
                "violations: \(applied.violations.map(\.code))")
        #expect(!applied.violations.contains { $0.code == "evidence_not_found" },
                "an expired row exists; the reviewer has to re-read the file, not hunt for a lost row")
        #expect(applied.correction.producedRevision == nil)
        #expect(applied.manifest.envelope.revision == 1)
    }

    @Test("a file that moved under the manifest expires every citation, even the manifest's own rows")
    func movedFileExpiresEveryCitation() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        // The manifest still describes revision 2 and the row still describes
        // revision 2 - but the file in front of the reviewer is revision 3
        // now. Publishing on the old row would describe a document state
        // nobody is looking at any more.
        let moved = source(revision: 3, snapshotFingerprint: String(repeating: "b", count: 64))
        let applied = engine.apply(to: manifest(profile, state: .hold), sourceID: sourceID,
                                   field: .completionyear, correctedValue: "2027",
                                   evidenceIDs: ["ev_year"], origin: .manual,
                                   context: context(profile: profile),
                                   evidence: [sourceID: rows()], currentEntries: [moved])
        #expect(applied.violations.contains { $0.code == "evidence_snapshot_mismatch" },
                "violations: \(applied.violations.map(\.code))")
        #expect(applied.correction.producedRevision == nil)
        #expect(applied.manifest.envelope.revision == 1,
                "a refused correction must not publish a revision")
    }

    @Test("a citation of another file's row is a foreign citation")
    func foreignCitationIsItsOwnRefusal() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        let foreign = record(id: "ev_foreign", excerpt: "另一个项目的归档完成 2025 年", owner: otherSourceID)
        let applied = engine.apply(to: manifest(profile, state: .hold), sourceID: sourceID,
                                   field: .completionyear, correctedValue: "2027",
                                   evidenceIDs: ["ev_foreign"], origin: .manual,
                                   context: context(profile: profile),
                                   evidence: [sourceID: rows()], currentEntries: [source()],
                                   citedRecords: ["ev_foreign": foreign])
        #expect(applied.violations.contains { $0.code == "evidence_foreign_source" },
                "violations: \(applied.violations.map(\.code))")
        #expect(!applied.violations.contains { $0.code == "evidence_not_found" },
                "the row exists; it belongs to another file")
        #expect(applied.correction.producedRevision == nil)
    }

    @Test("a citation of a row the program could not read is unusable, not missing")
    func unusableCitationIsItsOwnRefusal() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        let unreadable = record(id: "ev_broken", excerpt: nil, status: .corrupt)
        let applied = engine.apply(to: manifest(profile, state: .hold), sourceID: sourceID,
                                   field: .completionyear, correctedValue: "2027",
                                   evidenceIDs: ["ev_broken"], origin: .manual,
                                   context: context(profile: profile),
                                   evidence: [sourceID: rows() + [unreadable]], currentEntries: [source()])
        #expect(applied.violations.contains { $0.code == "evidence_unusable" },
                "violations: \(applied.violations.map(\.code))")
        #expect(!applied.violations.contains { $0.code == "evidence_not_found" },
                "the row exists and is registered; it simply cannot support a value")
    }

    @Test("a citation whose row only the registry history knows is expired evidence")
    func citationFromRegistryHistoryIsStaleEvidence() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        // The row is not among the rows this source holds right now - it was
        // registered under an earlier revision of the file, and the store kept
        // it. Looking it up by id across the registry is what lets the refusal
        // say "expired" instead of "missing".
        let expired = record(id: "ev_history", excerpt: "归档完成 2025 年", revision: 1)
        let applied = engine.apply(to: manifest(profile, state: .hold), sourceID: sourceID,
                                   field: .completionyear, correctedValue: "2027",
                                   evidenceIDs: ["ev_history"], origin: .manual,
                                   context: context(profile: profile),
                                   evidence: [sourceID: rows()], currentEntries: [source()],
                                   citedRecords: ["ev_history": expired])
        #expect(applied.violations.contains { $0.code == "evidence_snapshot_mismatch" },
                "violations: \(applied.violations.map(\.code))")
        #expect(!applied.violations.contains { $0.code == "evidence_not_found" })
    }
}

/// The field failure this gate was wrong about: a file whose content changed,
/// a rescan, and a review desk that still showed the rows of the previous
/// snapshot. Citing them has to be refused as expired evidence, with the
/// reviewer's next move named - and after re-reading the file and mapping it
/// again, the same reviewer must be able to correct it in one attempt.
@Suite("A changed file refuses its expired rows and recovers by re-reading")
struct ChangedFileEvidenceRecoveryTests {
    private func fixture() throws -> SourceFixture {
        let fixture = try SourceFixture()
        let url = fixture.root.appendingPathComponent("示例项目_2026/01_招标文件/01_招标公告.pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try makePDF(["示例项目_2026 招标公告 归档完成 2027 年"]).write(to: url)
        return fixture
    }

    @Test("an expired citation is refused as expired, and a re-read makes the correction succeed")
    func expiredCitationRefusedThenRecoveredByReReading() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let scanned = try await workspace.scan(scope)
        let profile = try MappingProfile.projectArchive()
        let context = try await workspace.buildContext(scope: scope, profile: profile)
        let before = try #require(scanned.entries.first)

        // The production path: capture, bind, map, publish.
        let captured = try await workspace.captureEvidence(for: [before])
        let binding = try await workspace.bindCapturedTargets([before], captured: captured,
                                                              readFailures: [:], scope: scope,
                                                              profile: profile, context: context)
        guard case .bound(let targets, let evidence, _, _) = binding else {
            Issue.record("the first capture must bind")
            return
        }
        let engine = MappingEngine(profile: profile, casePack: try CasePack.shipped(),
                                   answerer: OfflinePlannerAnswerer(), workspace: workspace)
        let result = await engine.run(
            MappingRunRequest(scope: scope, profile: profile, context: context,
                              entries: targets, evidence: evidence,
                              provider: .offline, model: OfflinePlannerAnswerer.modelID,
                              allowCloud: false))
        let stored = try await workspace.saveManifest(result.manifest, scopeID: scope.id)
        let boundEntry = try #require(stored.entries.first)
        let oldRow = try #require(captured[before.id]?.first {
            $0.source == .path && $0.isUsable && ($0.excerpt ?? "").contains("示例项目_2026")
        })

        // The file changes under the manifest, and the reviewer rescans.
        let url = fixture.root.appendingPathComponent("示例项目_2026/01_招标文件/01_招标公告.pdf")
        try makePDF(["示例项目_2026 招标公告 归档完成 2028 年 修订"]).write(to: url)
        let rescanned = try await workspace.scan(scope)
        let moved = try #require(rescanned.entries.first)
        #expect(moved.snapshotRevision > boundEntry.snapshotRevision,
                "a changed file is a new snapshot")

        // The review desk still shows the rows of the previous snapshot, and
        // the reviewer cites one of them.
        let refused = try await workspace.applyCorrection(
            to: stored, sourceID: before.id, field: .projectname,
            correctedValue: "示例项目_2026", evidenceIDs: [oldRow.id],
            origin: .manual, scope: scope, profile: profile)
        #expect(refused.violations.contains { $0.code == "evidence_snapshot_mismatch" },
                "an expired row must be reported as expired: \(refused.violations.map(\.code))")
        #expect(!refused.violations.contains { $0.code == "evidence_not_found" },
                "the row exists in the registry; it describes an older snapshot")
        #expect(refused.correction.producedRevision == nil)
        #expect(refused.manifest.envelope.revision == stored.envelope.revision,
                "a refused correction must not publish a revision")
        let reopened = try await workspace.currentManifest(scope: scope, profile: profile)
        #expect(reopened?.envelope.revision == stored.envelope.revision)

        // The recovery the review screen offers: re-read the file's evidence
        // and map it again. The same reviewer then corrects in one attempt.
        let recaptured = try await workspace.captureEvidence(for: [moved])
        let rebinding = try await workspace.bindCapturedTargets([moved], captured: recaptured,
                                                                readFailures: [:], scope: scope,
                                                                profile: profile, context: context)
        guard case .bound(let newTargets, let newEvidence, _, _) = rebinding else {
            Issue.record("a re-read must bind")
            return
        }
        let secondRun = await engine.run(
            MappingRunRequest(scope: scope, profile: profile, context: context,
                              entries: newTargets, evidence: newEvidence,
                              provider: .offline, model: OfflinePlannerAnswerer.modelID,
                              allowCloud: false))
        let republished = try await workspace.saveManifest(secondRun.manifest, scopeID: scope.id)
        let newRow = try #require(recaptured[moved.id]?.first {
            $0.source == .path && $0.isUsable && ($0.excerpt ?? "").contains("示例项目_2026")
        })
        #expect(newRow.id != oldRow.id,
                "a re-read registers the rows of the new snapshot under new ids")
        let applied = try await workspace.applyCorrection(
            to: republished, sourceID: moved.id, field: .projectname,
            correctedValue: "示例项目_2026", evidenceIDs: [newRow.id],
            origin: .manual, scope: scope, profile: profile)
        #expect(applied.violations.isEmpty,
                "the correction must succeed after the re-read: \(applied.violations.map(\.code))")
        #expect(applied.manifest.envelope.revision > republished.envelope.revision)
    }
}
