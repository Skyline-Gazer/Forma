import Foundation
import Testing

@testable import FormaCore

/// M0-R2 (#153 physical acceptance): the recovery the Review Desk promises -
/// "re-read the file's evidence and cite the current rows" - was unreachable.
///
/// The gate judged a citation against the manifest's own binding *and* demanded
/// that the manifest still match the listing. After a file moved, the freshly
/// re-extracted rows - the only rows that honestly describe the file the
/// reviewer is looking at - matched the listing but not the manifest, so every
/// row on screen was expired and no correction could ever succeed.
///
/// These tests pin the repaired contract:
/// - a row stamped with the current listing snapshot is citable even while the
///   manifest still describes the superseded one, and publishing the correction
///   rebinds the entry to the current snapshot;
/// - a row from any other generation stays refused as `evidence_snapshot_mismatch`;
/// - re-reading an unchanged file registers the same row ids, so repeated
///   re-reads cannot grow the current evidence;
/// - the generation semantics survive a reopen;
/// - a text locator carries its character range to the reviewer, and the
///   UTF-16 range selects exactly its stored quote - for multilingual text.
@Suite("M0-R2: a re-read row is citable while the manifest lags the file")
struct M0R2CorrectionGateRecoveryTests {
    private let scopeID = UUID(uuidString: "00000000-0000-4000-8000-000000000090")!
    private let rootID = UUID(uuidString: "00000000-0000-4000-8000-000000000091")!
    private let sourceID = UUID(uuidString: "00000000-0000-4000-8000-000000000092")!
    private let fingerprintA = String(repeating: "a", count: 64)
    private let fingerprintB = String(repeating: "b", count: 64)

    private func source(revision: Int64, fingerprint: String) -> SourceEntry {
        SourceEntry(id: sourceID, rootID: rootID, relativePath: "示例项目_2026/01_招标/公告.pdf",
                    normalizedRelativePath: "示例项目_2026/01_招标/公告.pdf", state: .present,
                    hydrationPending: false, sourceVersion: 1, snapshotRevision: revision, provider: .local,
                    snapshotFingerprint: fingerprint, sizeBytes: 10,
                    modificationTimeNanoseconds: 0, sha256: nil)
    }

    private func record(id: String, excerpt: String, revision: Int, fingerprint: String,
                        locator: EvidenceLocator?) -> EvidenceRecord {
        EvidenceRecord(id: id, sourceID: sourceID, snapshotRevision: revision,
                       snapshotFingerprint: fingerprint, source: .content,
                       locator: locator ?? .pdf(page: 1, characterRange: 0..<excerpt.utf16.count),
                       relativePath: nil, excerpt: excerpt,
                       extractionStatus: .ok, extractorVersion: EvidenceRegistry.extractorVersion,
                       createdAt: .now)
    }

    private func context(_ profile: MappingProfile) -> ProjectContext {
        ProjectContext(revision: 2, scopeID: scopeID, profileID: profile.profileID,
                       profileVersion: profile.profileVersion, inputDigest: String(repeating: "1", count: 64),
                       candidates: [ContextCandidate(id: "c1", projectKey: "示例项目_2026", displayName: nil,
                                                      basis: [.directory], memberSourceIDs: [sourceID],
                                                      confidence: .medium)],
                       unassignedSourceIDs: [], conflictedSourceIDs: [], builtAt: .now)
    }

    /// The manifest the reviewer holds: every value cites rows read from the
    /// file at revision 2 under fingerprint A.
    private func laggingManifest(_ profile: MappingProfile) -> Manifest {
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
            .documentcategory: ["old_cat"],
            .projectname: ["old_name"],
            .completionyear: ["old_year"],
        ]
        var fields: [FieldOutcome] = []
        for field in MetadataFieldID.allCases {
            let value = metadata[field]
            fields.append(FieldOutcome(field: field, value: value,
                                       status: value == nil ? .unknown : .evidenced,
                                       evidenceIDs: citations[field] ?? []))
        }
        let entry = ManifestEntry(
            sourceID: sourceID, snapshotFingerprint: fingerprintA, snapshotRevision: 2, sourceVersion: 1,
            relativePath: "示例项目_2026/01_招标/公告.pdf", state: .hold,
            target: ManifestTarget(databaseName: "Project_Archive",
                                   groupPath: ["2026", "示例项目_2026", "01_招标文件"], resolved: true),
            metadata: metadata, fields: fields
        )
        return Manifest(envelope: envelope, entries: [entry])
    }

    private var oldRows: [EvidenceRecord] {
        [
            record(id: "old_cat", excerpt: "01_招标文件 招标公告", revision: 2, fingerprint: fingerprintA,
                   locator: .pdf(page: 1, characterRange: 0..<11)),
            record(id: "old_year", excerpt: "归档完成 2026 年", revision: 2, fingerprint: fingerprintA,
                   locator: .pdf(page: 1, characterRange: 0..<8)),
        ]
    }

    @Test("a row stamped with the current listing snapshot is citable while the manifest describes the superseded one")
    func rereadRowIsCitableAgainstALaggingManifest() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        // The file has moved to revision 3 under fingerprint B; the reviewer
        // re-read its evidence and the rows carry that stamp. The manifest in
        // hand still describes revision 2 - that lag is exactly what the
        // re-read recovery exists to survive.
        let newRow = record(id: "new_name", excerpt: "示例项目_2026 智能化项目",
                            revision: 3, fingerprint: fingerprintB,
                            locator: .pdf(page: 1, characterRange: 0..<20))
        let applied = engine.apply(to: laggingManifest(profile), sourceID: sourceID,
                                   field: .projectname, correctedValue: "示例项目_2026",
                                   evidenceIDs: [newRow.id], origin: .manual,
                                   context: context(profile),
                                   evidence: [sourceID: oldRows + [newRow]],
                                   currentEntries: [source(revision: 3, fingerprint: fingerprintB)])
        #expect(applied.violations.isEmpty, "violations: \(applied.violations.map(\.code))")
        #expect(applied.correction.producedRevision == 2,
                "the recovery correction must publish a new revision")
        let published = try #require(applied.manifest.entries.first)
        #expect(published.snapshotRevision == 3 && published.snapshotFingerprint == fingerprintB,
                "the published revision rebinds the entry to the snapshot the reviewer corrected")
        #expect(applied.correction.snapshotFingerprint == fingerprintB,
                "the audit receipt names the reviewed generation, not the superseded one - evidence IDs and produced revision belong to B")
        #expect(published.outcome(for: .projectname)?.value == "示例项目_2026")
    }

    @Test("a row matching neither the file in front of the reviewer nor any current state stays refused")
    func intermediateGenerationStaysStale() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        // The file moved twice (revision 2 -> 3 -> 4); a row from the third
        // generation nobody re-read, plus rows from generation 2, describe
        // documents the reviewer is not looking at.
        let stale = record(id: "mid", excerpt: "示例项目_2026 智能化项目",
                           revision: 3, fingerprint: fingerprintB,
                           locator: .pdf(page: 1, characterRange: 0..<20))
        let applied = engine.apply(to: laggingManifest(profile), sourceID: sourceID,
                                   field: .projectname, correctedValue: "示例项目_2026",
                                   evidenceIDs: [stale.id], origin: .manual,
                                   context: context(profile),
                                   evidence: [sourceID: oldRows + [stale]],
                                   currentEntries: [source(revision: 4,
                                                           fingerprint: String(repeating: "c", count: 64))])
        #expect(applied.violations.contains { $0.code == "evidence_snapshot_mismatch" },
                "violations: \(applied.violations.map(\.code))")
        #expect(applied.correction.producedRevision == nil)
        #expect(applied.manifest.envelope.revision == 1)
    }

    @Test("a row matching only the manifest's binding is refused once the file has moved")
    func manifestMatchingRowIsStaleAfterTheFileMoves() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        let applied = engine.apply(to: laggingManifest(profile), sourceID: sourceID,
                                   field: .completionyear, correctedValue: "2027",
                                   evidenceIDs: ["old_year"], origin: .manual,
                                   context: context(profile),
                                   evidence: [sourceID: oldRows],
                                   currentEntries: [source(revision: 3, fingerprint: fingerprintB)])
        #expect(applied.violations.contains { $0.code == "evidence_snapshot_mismatch" },
                "a row that stopped describing the file must never be citable, manifest binding or not")
        #expect(applied.correction.producedRevision == nil)
    }
}

/// The end-to-end field sequence: scan, map, save a valid correction, modify
/// the source, rescan, refuse the expired rows, re-read, and correct - without
/// a second full mapping run. Also pins that repeated re-reads register the
/// same current rows rather than a growing pile, and that a reopened workspace
/// reads the same generation semantics back.
@Suite("M0-R2: source mutation recovers by re-read alone")
struct M0R2RereadRecoveryEndToEndTests {
    private func fixture() throws -> SourceFixture {
        let fixture = try SourceFixture()
        let url = fixture.root.appendingPathComponent("示例项目_2026/01_招标文件/01_招标公告.pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try makePDF(["示例项目_2026 招标公告 归档完成 2027 年"]).write(to: url)
        return fixture
    }

    @Test("re-read then correct: one attempt, new revision, no duplicate growth, stable after reopen")
    func rereadThenCorrectRecoversTheWorkflow() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let workspace = try SourceWorkspace(databaseURL: fixture.database)
        let scope = try await workspace.register(fixture.root)
        let scanned = try await workspace.scan(scope)
        let profile = try MappingProfile.projectArchive()
        let context = try await workspace.buildContext(scope: scope, profile: profile)
        let before = try #require(scanned.entries.first)

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

        // The source changes under the manifest, and the reviewer rescans.
        let url = fixture.root.appendingPathComponent("示例项目_2026/01_招标文件/01_招标公告.pdf")
        try makePDF(["示例项目_2026 招标公告 归档完成 2028 年 修订"]).write(to: url)
        let rescanned = try await workspace.scan(scope)
        let moved = try #require(rescanned.entries.first)
        #expect(moved.snapshotRevision > boundEntry.snapshotRevision,
                "a changed file is a new snapshot")

        // The old rows are refused as expired, not missing.
        let oldRow = try #require(captured[before.id]?.first {
            $0.source == .path && $0.isUsable && ($0.excerpt ?? "").contains("示例项目_2026")
        })
        let refused = try await workspace.applyCorrection(
            to: stored, sourceID: before.id, field: .projectname,
            correctedValue: "示例项目_2026", evidenceIDs: [oldRow.id],
            origin: .manual, scope: scope, profile: profile)
        #expect(refused.violations.contains { $0.code == "evidence_snapshot_mismatch" },
                "an expired row must read as expired: \(refused.violations.map(\.code))")
        #expect(refused.correction.producedRevision == nil)

        // The recovery the desk offers, and nothing else: re-read the file.
        let recaptured = try await workspace.captureEvidence(for: [moved])
        let newRow = try #require(recaptured[moved.id]?.first {
            $0.source == .path && $0.isUsable && ($0.excerpt ?? "").contains("示例项目_2026")
        })
        #expect(newRow.id != oldRow.id,
                "the re-read rows describe the new snapshot under new ids")
        // publishEvidence appends the snapshot revision the moment the body
        // read makes the new hash known, so the rows describe the post-read
        // entry - exactly what the desk's refreshed listing shows beside them
        // (rereadEvidence lists again after capture; bindCapturedTargets
        // exists in the core for the same reason). The pre-capture scan entry
        // lags one body-read behind, by design.
        let authoritative = try #require((try await workspace.listing(scope)).entries.first)
        #expect(newRow.snapshotRevision == Int(authoritative.snapshotRevision)
                && newRow.snapshotFingerprint == authoritative.snapshotFingerprint,
                "the re-read rows are stamped with the snapshot the listing now reports")

        // A repeated re-read of an unchanged file must not mint a second
        // generation: same rows, same ids - this is the accumulation the
        // physical acceptance measured as 4 rows becoming 8 and growing.
        // The desk re-reads against the refreshed listing, so the entry it
        // hands the core is the one the core last published (the fingerprint
        // guard in publishEvidence refuses stale entries outright).
        let again = try await workspace.captureEvidence(for: [authoritative])
        let againRow = try #require(again[moved.id]?.first {
            $0.source == .path && $0.isUsable && ($0.excerpt ?? "").contains("示例项目_2026")
        })
        #expect(againRow.id == newRow.id,
                "re-reading an unchanged file re-registers the same rows, not a new pile")

        // The correction now succeeds against the manifest in hand - no second
        // mapping run is required for the file that was re-read.
        let applied = try await workspace.applyCorrection(
            to: stored, sourceID: moved.id, field: .projectname,
            correctedValue: "示例项目_2026", evidenceIDs: [newRow.id],
            origin: .manual, scope: scope, profile: profile)
        #expect(applied.violations.isEmpty,
                "the recovery correction must publish: \(applied.violations.map(\.code))")
        #expect(applied.manifest.envelope.revision == stored.envelope.revision + 1)
        let published = try #require(applied.manifest.entries.first)
        #expect(Int(published.snapshotRevision) == Int(authoritative.snapshotRevision)
                && published.snapshotFingerprint == authoritative.snapshotFingerprint,
                "the new revision is bound to the snapshot the reviewer corrected")

        // The previous revision is still the one that was saved - history is
        // not rewritten by the rebind.
        let reopened = try await workspace.currentManifest(scope: scope, profile: profile)
        #expect(reopened?.envelope.revision == applied.manifest.envelope.revision)

        // A reopen of the store reads the current generation back as the
        // citable rows, and exactly the same four of them.
        let second = try SourceWorkspace(databaseURL: fixture.database)
        let current = try await second.evidenceRegistry(for: moved.id,
                                                        snapshotRevision: Int(authoritative.snapshotRevision))
        #expect(Set(current.map(\.id)) == Set((recaptured[moved.id] ?? []).map(\.id)),
                "persistence must retain the evidence-generation semantics")
    }
}

/// The desk's locator sentence for a text row: the range is the one address a
/// plain-text excerpt honestly has, and it must reach the reviewer. The
/// physical acceptance found TXT rows labelled "正文摘录" with no position.
@Suite("M0-R2: text evidence carries its character position")
struct M0R2TextLocatorTests {
    @Test("a text locator is read as its UTF-16 character range")
    func textLocatorLabel() {
        #expect(deskEvidenceLocatorLabel(.text(characterRange: 12..<40)) == "字符 12–40")
    }

    @Test("every locator kind reaches the reviewer as its own position")
    func everyKindHasALabel() {
        #expect(deskEvidenceLocatorLabel(.pdf(page: 2, characterRange: 0..<9)) == "第 2 页 · 字符 0–9")
        #expect(deskEvidenceLocatorLabel(.docx(part: "word/document.xml", paragraph: 3,
                                               characterRange: 0..<6)) == "段落 3 · 字符 0–6")
        #expect(deskEvidenceLocatorLabel(.xlsx(sheet: "报价", cell: "B4")) == "工作表 报价 · 单元格 B4")
        #expect(deskEvidenceLocatorLabel(nil) == "目录与文件名")
    }

    @Test("multilingual text ranges select their stored quote exactly")
    func multilingualRangesSelectTheirQuote() throws {
        // CJK, a surrogate-pair emoji, combining marks, and both line-ending
        // styles, so the contract is pinned in the same units the locator
        // names: UTF-16 code units of the decoded document.
        let text = "项目名称：示例项目_2026 🎉\u{1F1E6}\u{1731}\r\n第二行，带变音符 é̍\r第三行\r\n"
        let extraction = try PlainTextEvidence.blocks(of: text)
        #expect(!extraction.items.isEmpty)
        let utf16 = Array(text.utf16)
        for item in extraction.items {
            guard case .text(let range) = item.locator, let excerpt = item.text else {
                Issue.record("a text block must carry a text locator")
                return
            }
            let slice = String(utf16CodeUnits: Array(utf16[range]), count: range.count)
            #expect(slice == excerpt,
                    "the range must select exactly the text stored beside it: \(excerpt)")
            #expect(range.upperBound - range.lowerBound == excerpt.utf16.count)
        }
    }
}
