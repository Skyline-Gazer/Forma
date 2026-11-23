import Foundation
import Testing

@testable import FormaCore

/// The #152 acceptance pack: do the bytes of a real file reach the model, and
/// does Forma still believe only what it read?
///
/// Every scenario runs the production path - a registered source root, a scan,
/// `SourceEvidenceReader` capture, `EvidenceRegistry` ids, `MappingPrompt`
/// payload, `MappingEngine` batching, `ManifestValidator` decision - and
/// substitutes only the provider. No scenario writes a row into the evidence
/// registry by hand: if the text is not in the file, there is no id for it, and
/// that is what turns "a model can only cite what was observed" from a sentence
/// into a check.
///
/// What this proves is the contract: TXT bodies become citable, locatable,
/// quotable evidence; citations that name nothing are refused; and a failure -
/// unreadable body, rate limit, malformed answer - ends in a named outcome
/// instead of a plausible-looking one. It says nothing about model quality. The
/// live provider call needs egress consent and credentials this round does not
/// have (#148: real API acceptance is a separate, later authorisation), so the
/// provider is a deterministic stand-in or a local HTTP stub, and every result
/// below is contract validation, not verification of a real model.

private struct FileSpec {
    let path: String
    let body: Data

    init(_ path: String, _ text: String) {
        self.path = path
        body = Data(text.utf8)
    }

    init(_ path: String, bytes: [UInt8]) {
        self.path = path
        body = Data(bytes)
    }
}

private struct Archive {
    let source: SourceFixture
    let workspace: SourceWorkspace
    let scope: SourceScope
    let profile: MappingProfile
    let context: ProjectContext
    let entries: [SourceEntry]
    let evidence: [UUID: [EvidenceRecord]]

    func entry(_ path: String) throws -> SourceEntry {
        try #require(entries.first { $0.relativePath == path }, "the scan must list \(path)")
    }

    func rows(_ path: String) throws -> [EvidenceRecord] { evidence[try entry(path).id] ?? [] }

    /// The body rows one read produced for a file: usable, located in the text,
    /// and quoted from it.
    func content(_ path: String) throws -> [EvidenceRecord] {
        try rows(path).filter { $0.source == .content && $0.isUsable }
    }

    /// The file as it sits on disk, so a locator can be re-read instead of
    /// trusted.
    func text(_ path: String) throws -> String {
        try String(contentsOf: source.root.appendingPathComponent(path), encoding: .utf8)
    }

    func cleanUp() { source.cleanUp() }
}

/// A bid announcement under an arbitrary name: nothing in the file name says
/// what this is, and the text says a great deal. Synthetic and anonymous, like
/// every other fixture in this suite.
private let bidBody = """
示例项目_2026 智能化改造项目 招标公告
项目编号 ZB2026-001
采购方 示例采购中心乙
本项目的投标主体为示例投标单位甲。
投标文件递交截止时间 2026-03-18 09:00
归档完成 2026 年，本项目资料按 01_招标文件、02_投标文件 分类装订。

本公告同时构成本项目澄清文件的起点。
"""

/// Scans a real directory and registers what the extractor read.
///
/// The listing is re-read after the capture because registering a body can
/// advance the snapshot revision (#145): rows from an older revision fail their
/// own citation check, so a scenario that skipped the re-read would be citing
/// evidence the current file does not have.
private func prepared(_ files: [FileSpec], profile: MappingProfile? = nil) async throws -> Archive {
    let chosen = try profile ?? MappingProfile.projectArchive()
    let source = try SourceFixture()
    for file in files {
        let url = source.root.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try file.body.write(to: url)
    }
    let workspace = try SourceWorkspace(databaseURL: source.database)
    let scope = try await workspace.register(source.root)
    let listing = try await workspace.scan(scope)
    let captured = try await workspace.captureEvidence(for: listing.entries)
    let current = try await workspace.scan(scope)
    let context = try await workspace.buildContext(scope: scope, profile: chosen)
    var rows: [UUID: [EvidenceRecord]] = [:]
    for entry in current.entries {
        rows[entry.id] = (captured[entry.id] ?? []).filter { $0.snapshotRevision == Int(entry.snapshotRevision) }
    }
    return Archive(source: source, workspace: workspace, scope: scope, profile: chosen, context: context,
                   entries: current.entries, evidence: rows)
}

private struct Cited {
    let id: MetadataFieldID
    var value: String?
    var cites: [String] = []
    var unknown: Bool = false
}

/// A schema-shaped answer for one batch, citing exactly the rows the scenario
/// names. An absent value is written as JSON null: a model that omits the key is
/// a different failure, and the strict decoder rejects the whole answer for it.
private func answerText(for batch: MappingBatch, association: (state: String, candidate: String?)? = nil,
                        fields: (MappingEntryRef) -> [Cited]) -> String {
    var entries: [[String: Any]] = []
    for item in batch.entries {
        var metadata: [String: Any] = [:]
        for field in MetadataFieldID.allCases { metadata[field.rawValue] = NSNull() }
        var declared: [MetadataFieldID: String] = [:]
        var citations: [[String: String]] = []
        var unknown: [String] = []
        for field in fields(item) {
            if let value = field.value {
                metadata[field.id.rawValue] = value
                declared[field.id] = value
            }
            if field.unknown { unknown.append(field.id.rawValue) }
            for id in field.cites { citations.append(["field": field.id.rawValue, "evidence_id": id]) }
        }
        var entry: [String: Any] = [
            "entry_ref": item.ref,
            "metadata": metadata,
            "evidence": citations,
            "unknown_fields": unknown,
            "conflicts": [],
            "confidence": "medium",
            "reasoning": "正文陈述了项目名称与归档类别，引用对应摘录。",
        ]
        if let category = declared[.documentcategory] { entry["document_category"] = category }
        if let type = declared[.documenttype] { entry["document_type"] = type }
        if let association {
            // An explicit null, never a boxed Swift nil: JSONSerialization
            // rejects the latter, and the failure would surface as an empty run.
            entry["project_association"] = ["candidate_ref": association.candidate.map { $0 as Any } ?? NSNull(),
                                            "state": association.state]
        }
        entries.append(entry)
    }
    let document: [String: Any] = ["schema_version": "1.0", "batch_id": batch.id, "entries": entries]
    guard let data = try? JSONSerialization.data(withJSONObject: document) else {
        Issue.record("the fake answer must serialise, or every assertion downstream of it tests nothing")
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
}

private func proposal(for batch: MappingBatch, association: (state: String, candidate: String?)? = nil,
                      fields: (MappingEntryRef) -> [Cited]) -> MappingProposal? {
    let decoded = decodedProposal(answerText(for: batch, association: association, fields: fields))
    #expect(decoded != nil, "the fake answer must decode, or this test proves nothing")
    return decoded
}

/// One mapping request over an archive with a stand-in provider.
private func mapped(_ archive: Archive, respond: @escaping @Sendable (MappingBatch, Int) -> MappingAttempt) async
    -> MappingRunOutcome {
    let engine = MappingEngine(profile: archive.profile, casePack: try! CasePack.shipped(),
                               answerer: FakeAnswerer(respond: respond), workspace: archive.workspace)
    let request = MappingRunRequest(scope: archive.scope, profile: archive.profile, context: archive.context,
                                    entries: archive.entries, evidence: archive.evidence,
                                    provider: .anthropic, model: "fake-model", allowCloud: true)
    return await engine.run(request)
}

/// The same run driven by a provider answer that has already been decided - a
/// real client attempt against a stub, replayed - so a transport outcome can be
/// read out of the manifest the engine wrote from it.
private func mapped(_ archive: Archive, attempt: MappingAttempt) async -> MappingRunOutcome {
    await mapped(archive) { _, _ in attempt }
}

private func batches(_ archive: Archive) -> [MappingBatch] {
    MappingEngine.plannedBatches(from: archive.entries, context: archive.context,
                                 limit: MappingPrompt.defaultEntryLimit, evidence: archive.evidence)
}

private func codes(_ outcome: MappingRunOutcome) -> [String] { outcome.manifest.report.allViolations.map(\.code) }

/// The body row in a batch that quotes a phrase, so an answer cites the row that
/// really says it rather than whatever happened to come first.
private func row(in batch: MappingBatch, saying needle: String) -> String {
    let body = batch.evidence.filter { $0.source == .content && $0.isUsable }
    guard let match = body.first(where: { ($0.excerpt ?? "").contains(needle) }) ?? body.first else {
        Issue.record("this batch has no body evidence at all")
        return "ev_missing"
    }
    if !(match.excerpt ?? "").contains(needle) { Issue.record("no body row in this batch says \(needle)") }
    return match.id
}

@Suite("Semantic evidence scenarios")
struct SemanticEvidenceScenariosTests {
    // MARK: - 1. The bytes really are read, and really are sent

    @Test("a txt file produces citable body evidence bound to this snapshot")
    func textBodiesBecomeCitableEvidence() async throws {
        let path = "示例项目_2026/abcd.txt"
        let archive = try await prepared([FileSpec(path, bidBody)])
        defer { archive.cleanUp() }
        let entry = try archive.entry(path)
        let rows = try archive.content(path)
        #expect(rows.count == 2, "the reported gap: a txt body produced no row at all under evidence.v1")
        #expect(rows.allSatisfy { $0.source == .content && $0.locator != nil })
        #expect(rows.allSatisfy { $0.extractorVersion == EvidenceRegistry.extractorVersion })
        #expect(Set(rows.map(\.id)).count == rows.count)
        let document = try archive.text(path)
        for record in rows {
            guard case .text(let range)? = record.locator else { Issue.record("expected a text locator"); continue }
            // The whole promise of a locator: reopen the document at these
            // offsets and this is what you read.
            #expect(slice(document, range) == record.excerpt, "\(range) must select \(record.excerpt ?? "nil")")
            #expect(range.upperBound <= document.utf16.count)
            // The block bound equals the stored-excerpt bound, so a text range
            // never over-describes its quote the way a long PDF page can.
            #expect(range.count <= EvidenceRegistry.maximumExcerptCharacters)
        }
        #expect(rows.allSatisfy { $0.sourceID == entry.id && $0.snapshotRevision == Int(entry.snapshotRevision) })
        // Re-reading the same bytes reproduces the same ids: a stored citation
        // survives a rescan, and a changed file does not fake one (#145).
        let again = try await archive.workspace.captureEvidence(for: [entry])
        #expect(Set((again[entry.id] ?? []).filter { $0.source == .content }.map(\.id)) == Set(rows.map(\.id)))
    }

    @Test("the plain-text block bound equals the registry's stored-excerpt bound")
    func textBlockBoundMatchesExcerptBound() {
        #expect(PlainTextEvidence.maximumBlockUTF16Characters == EvidenceRegistry.maximumExcerptCharacters,
                "a longer block would be stored truncated, and its locator would over-describe the quote")
    }

    @Test("the excerpt a txt row carries is in the provider payload the model would receive")
    func textExcerptReachesProviderMessage() async throws {
        let path = "示例项目_2026/abcd.txt"
        let archive = try await prepared([FileSpec(path, bidBody)])
        defer { archive.cleanUp() }
        let entry = try archive.entry(path)
        let batch = try #require(batches(archive).first)
        let payload = try MappingPrompt.payload(profile: archive.profile, context: archive.context,
                                                casePack: CasePack.shipped(), batch: batch, redaction: .none)
        let document = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let sent = try #require(document["evidence"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: batch.evidence.map { ($0.id, $0) })
        var textRows = 0
        for record in sent {
            let id = try #require(record["evidence_id"] as? String)
            guard let stored = byID[id], let locator = stored.locator, case .text = locator,
                  stored.source == .content else { continue }
            textRows += 1
            // Exactly what the transport would put on the wire for this row.
            #expect(record["excerpt"] as? String == RedactionPlan.none.redact(text: stored.excerpt ?? ""))
            #expect(record["status"] as? String == "ok")
            let summary = try #require(record["locator"] as? String)
            #expect(summary == MappingPrompt.locatorSummary(locator))
            #expect(summary.hasPrefix("text:utf16="), "the summary must name the kind it addresses")
        }
        #expect(textRows == 2)
        // The strongest form of the claim: phrases from the file's bytes appear
        // in the request itself, not merely a reference to them.
        let message = String(decoding: payload, as: UTF8.self)
        #expect(message.contains("智能化改造项目 招标公告"))
        #expect(message.contains("投标主体为示例投标单位甲"))
        // The model never receives a source id; it receives a batch-local ref.
        #expect(!message.contains(entry.id.uuidString) && !message.contains(entry.id.sourceKey))
    }

    // MARK: - 2. Content decides; the name does not

    @Test("an arbitrary file name plus bid content validates on body evidence")
    func contentEvidenceValidatesArbitraryName() async throws {
        let path = "示例项目_2026/abcd.txt"
        let archive = try await prepared([FileSpec(path, bidBody)])
        defer { archive.cleanUp() }
        let citable = Set(try archive.content(path).map(\.id))
        let outcome = await mapped(archive) { batch, _ in
            MappingAttempt(proposal: proposal(for: batch, association: ("confirmed", batch.candidateID)) { _ in
                [
                    Cited(id: .projectname, value: "示例项目_2026", cites: [row(in: batch, saying: "智能化改造项目")]),
                    Cited(id: .completionyear, value: "2026", cites: [row(in: batch, saying: "归档完成")]),
                    Cited(id: .documentcategory, value: "01_招标文件", cites: [row(in: batch, saying: "01_招标文件")]),
                    Cited(id: .tenderreference, value: "ZB2026-001", cites: [row(in: batch, saying: "ZB2026-001")]),
                    Cited(id: .bidderentity, value: "示例投标单位甲",
                          cites: [row(in: batch, saying: "投标主体为示例投标单位甲")]),
                    Cited(id: .issuer, value: "示例采购中心乙", cites: [row(in: batch, saying: "示例采购中心乙")]),
                    Cited(id: .documenttype, unknown: true),
                ]
            }, requests: 1)
        }
        let item = try #require(outcome.manifest.entries.first)
        #expect(codes(outcome).isEmpty, "unexpected violations: \(codes(outcome))")
        #expect(item.state == .validated)
        #expect(item.eligibleForAutoExecution, "body evidence at the current snapshot is what eligibility means")
        #expect(item.metadata[.documentcategory] == "01_招标文件")
        #expect(item.metadata[.projectname] == "示例项目_2026")
        #expect(item.metadata[.completionyear] == "2026")
        #expect(item.metadata[.tenderreference] == "ZB2026-001")
        #expect(item.metadata[.bidderentity] == "示例投标单位甲")
        #expect(item.metadata[.issuer] == "示例采购中心乙")
        // Left unknown, so it stays null instead of becoming a guess.
        #expect(item.metadata[.documenttype] == nil)
        let category = try #require(item.outcome(for: .documentcategory))
        #expect(category.status == .evidenced)
        #expect(!category.evidenceIDs.isEmpty)
        #expect(Set(category.evidenceIDs).isSubset(of: citable),
                "every accepted citation is a row this file actually produced")
        #expect(item.target.groupPath == ["2026", "示例项目_2026", "01_招标文件"])
        #expect(outcome.manifest.envelope.extractorVersion == "evidence.v2")
    }

    @Test("a name-only citation cannot carry the category, while the body can")
    func misleadingNameLosesToBody() async throws {
        // Filed and named like a quotation, written as an announcement.
        let path = "示例项目_2026/05_报价/价格final.txt"
        let archive = try await prepared([FileSpec(path, bidBody)])
        defer { archive.cleanUp() }
        let named = try archive.rows(path).filter { $0.source == .filename || $0.source == .path }
        #expect(!named.isEmpty, "the name and the directory were observed, and are recorded as such")

        let fromName = await mapped(archive) { batch, _ in
            let forName = batch.evidence.filter { $0.source == .filename || $0.source == .path }.map(\.id)
            return MappingAttempt(proposal: proposal(for: batch, association: ("confirmed", batch.candidateID)) { _ in
                [
                    Cited(id: .projectname, value: "示例项目_2026", cites: [row(in: batch, saying: "智能化改造项目")]),
                    Cited(id: .completionyear, value: "2026", cites: [row(in: batch, saying: "归档完成")]),
                    // 05_报价与商务 is exactly what the file name and folder claim.
                    Cited(id: .documentcategory, value: "05_报价与商务", cites: forName),
                ]
            }, requests: 1)
        }
        let nameAnswer = try #require(fromName.manifest.entries.first)
        #expect(codes(fromName).contains("insufficient_evidence"),
                "a name-only category must be refused: \(codes(fromName))")
        let rejected = try #require(nameAnswer.outcome(for: .documentcategory))
        #expect(rejected.status == .rejectedByPolicy)
        #expect(nameAnswer.metadata[.documentcategory] == nil, "refused means null, not the name's guess")
        // A refused field still names the rows it was offered, so a reviewer can
        // see what the model leaned on; what it must not do is carry a body row
        // it was never given.
        #expect(!rejected.evidenceIDs.isEmpty)
        #expect(Set(rejected.evidenceIDs).isSubset(of: Set(named.map(\.id))),
                "the retained trail is exactly the name/path rows that were cited")
        #expect(nameAnswer.state == .hold)
        #expect(!nameAnswer.eligibleForAutoExecution)

        // The same answer shape cited from the body: the content wins, and it
        // wins against the name rather than by agreeing with it.
        let fromBody = await mapped(archive) { batch, _ in
            MappingAttempt(proposal: proposal(for: batch, association: ("confirmed", batch.candidateID)) { _ in
                [
                    Cited(id: .projectname, value: "示例项目_2026", cites: [row(in: batch, saying: "智能化改造项目")]),
                    Cited(id: .completionyear, value: "2026", cites: [row(in: batch, saying: "归档完成")]),
                    Cited(id: .documentcategory, value: "01_招标文件", cites: [row(in: batch, saying: "01_招标文件")]),
                ]
            }, requests: 1)
        }
        let bodyAnswer = try #require(fromBody.manifest.entries.first)
        #expect(codes(fromBody).isEmpty, "unexpected violations: \(codes(fromBody))")
        #expect(bodyAnswer.metadata[.documentcategory] == "01_招标文件")
        #expect(bodyAnswer.outcome(for: .documentcategory)?.status == .evidenced)
        #expect(bodyAnswer.state == .validated)
    }

    // MARK: - 3. Nothing to say is a valid answer

    @Test("a body with no business signal stays unknown instead of becoming invented evidence")
    func numbersAloneSupportNothing() async throws {
        let path = "示例项目_2026/123456.txt"
        let archive = try await prepared([FileSpec(path, "123456")])
        defer { archive.cleanUp() }
        let rows = try archive.content(path)
        #expect(rows.count == 1, "the file really was read: one block, one row")
        #expect(rows.first?.excerpt == "123456")
        #expect(rows.first?.isUsable == true, "readable is not the same thing as informative")

        // A model that over-reads it: the values are not in what was observed.
        let invented = await mapped(archive) { batch, _ in
            let only = row(in: batch, saying: "123456")
            return MappingAttempt(proposal: proposal(for: batch, association: ("confirmed", batch.candidateID)) { _ in
                [
                    Cited(id: .projectname, value: "示例项目_2026", cites: [only]),
                    Cited(id: .completionyear, value: "2026", cites: [only]),
                    Cited(id: .documentcategory, value: "01_招标文件", cites: [only]),
                ]
            }, requests: 1)
        }
        let item = try #require(invented.manifest.entries.first)
        #expect(codes(invented).filter { $0 == "quote_mismatch" }.count >= 2,
                "the quoted excerpt has to contain the value: \(codes(invented))")
        #expect(item.metadata[.projectname] == nil, "an excerpt that does not say it must not become a value")
        #expect(item.metadata[.completionyear] == nil)
        #expect(item.metadata[.documentcategory] == nil)
        #expect(item.state == .hold)
        #expect(!item.eligibleForAutoExecution)

        // The honest answer: everything unknown. No value, no eligibility, and
        // the file is not silently dropped from the manifest either.
        let declined = await mapped(archive) { batch, _ in
            MappingAttempt(proposal: proposal(for: batch, association: ("unconfirmed", nil)) { _ in
                MetadataFieldID.allCases.map { Cited(id: $0, unknown: true) }
            }, requests: 1)
        }
        let answered = try #require(declined.manifest.entries.first)
        #expect(answered.fields.filter { $0.value != nil }.isEmpty, "unknown means null in every field")
        #expect(answered.state == .hold, "a required field left unknown holds the entry; it does not invent one")
        #expect(!answered.eligibleForAutoExecution)
        #expect(declined.manifest.entries.count == 1, "a held file is still reported, not dropped")
    }

    @Test("an empty file yields an explainable failure row, never a quoted blank")
    func emptyBodyIsUnavailableNotEvidence() async throws {
        let path = "示例项目_2026/空白.txt"
        let archive = try await prepared([FileSpec(path, "")])
        defer { archive.cleanUp() }
        let rows = try archive.rows(path)
        let content = rows.filter { $0.source == .content }
        #expect(content.count == 1, "the failure itself is recorded, so the Exceptions view can name a reason")
        #expect(content.first?.extractionStatus == .unavailable)
        #expect(content.first?.excerpt == nil)
        #expect(content.first?.isUsable == false)
        #expect(content.first?.locator == nil, "nothing was read, so nothing is locatable")
        // The name was still observed, and stays citable for what it can support.
        #expect(rows.contains { $0.source == .filename && $0.isUsable })

        let outcome = await mapped(archive) { batch, _ in
            let failure = batch.evidence.filter { $0.source == .content }.map(\.id)
            return MappingAttempt(proposal: proposal(for: batch, association: ("unconfirmed", nil)) { _ in
                [
                    Cited(id: .documentcategory, value: "99_待分类", cites: failure),
                    Cited(id: .projectname, unknown: true),
                    Cited(id: .completionyear, unknown: true),
                ]
            }, requests: 1)
        }
        let item = try #require(outcome.manifest.entries.first)
        #expect(codes(outcome).contains("locator_invalid"),
                "a failure row is not body evidence: \(codes(outcome))")
        #expect(item.metadata[.documentcategory] == nil)
        #expect(!item.eligibleForAutoExecution)
    }

    // MARK: - 4. Same owner, different projects

    @Test("two projects of one owner stay two separate citation scopes")
    func sameOwnerDifferentProjects() async throws {
        // Distinct file names on purpose: the same name filed under two project
        // directories is the profile's *other* conflict (`sameMaterialSourceIDs`)
        // and would hold both files before any citation was read.
        let a = "客户甲_智能化改造项目/智能化改造公告.txt"
        let b = "客户甲_运维服务项目/运维服务公告.txt"
        let archive = try await prepared([
            FileSpec(a, """
            客户甲_智能化改造项目 招标公告
            项目编号 ZB-A-001
            归档完成 2026 年，本项目资料按 01_招标文件 分类。
            """),
            FileSpec(b, """
            客户甲_运维服务项目 招标公告
            项目编号 ZB-B-002
            归档完成 2025 年，本项目资料按 01_招标文件 分类。
            """),
        ])
        defer { archive.cleanUp() }
        // Structure, not the shared 客户甲 prefix, decides the candidate: two
        // directories, two projects, each file claiming only its own body.
        #expect(archive.context.candidates.count == 2)
        let rowsA = try archive.content(a)
        let rowsB = try archive.content(b)
        #expect(Set(rowsA.map(\.id)).isDisjoint(with: Set(rowsB.map(\.id))),
                "one owner must not mean one evidence namespace")
        let entryA = try archive.entry(a)
        let candidateA = try #require(archive.context.candidates.first { $0.memberSourceIDs.contains(entryA.id) })
        let otherCandidateID = try #require(archive.context.candidates.first { $0.id != candidateA.id }).id
        let borrowedID = try #require(rowsB.first { ($0.excerpt ?? "").contains("客户甲_运维服务项目") }).id
        let intelligentName = "客户甲_智能化改造项目"

        // Correct: each file cites its own rows, inside its own batch.
        let own = await mapped(archive) { batch, _ in
            MappingAttempt(proposal: proposal(for: batch, association: ("confirmed", batch.candidateID)) { _ in
                let intelligent = batch.entries.contains { $0.relativePath == a }
                return [
                    Cited(id: .projectname, value: intelligent ? intelligentName : "客户甲_运维服务项目",
                          cites: [row(in: batch, saying: intelligent ? intelligentName : "客户甲_运维服务项目")]),
                    Cited(id: .completionyear, value: intelligent ? "2026" : "2025",
                          cites: [row(in: batch, saying: "归档完成")]),
                    Cited(id: .documentcategory, value: "01_招标文件", cites: [row(in: batch, saying: "01_招标文件")]),
                ]
            }, requests: 1)
        }
        #expect(codes(own).isEmpty, "unexpected violations: \(codes(own))")
        let validatedA = try #require(own.manifest.entries.first { $0.sourceID == entryA.id })
        #expect(validatedA.metadata[.projectname] == intelligentName)
        #expect(validatedA.state == .validated)

        // Wrong on purpose: both files answer from B's body. Another file's
        // excerpt is not this file's evidence, however well it fits.
        let borrowed = await mapped(archive) { batch, _ in
            MappingAttempt(proposal: proposal(for: batch, association: ("confirmed", batch.candidateID)) { _ in
                [
                    Cited(id: .projectname, value: "客户甲_运维服务项目", cites: [borrowedID]),
                    Cited(id: .completionyear, value: "2025", cites: [borrowedID]),
                    Cited(id: .documentcategory, value: "01_招标文件", cites: [borrowedID]),
                ]
            }, requests: 1)
        }
        let misplaced = try #require(borrowed.manifest.entries.first { $0.sourceID == entryA.id })
        // The engine hands the validator each source's own rows, so a citation
        // into another file's body cannot even resolve here: `evidence_not_found`
        // is the refusal, and the per-source registry scoping is what makes it
        // one. (`evidence_foreign_source` is the sibling code for a merged
        // registry, where a foreign row resolves and is then refused by source.)
        #expect(codes(borrowed).contains("evidence_not_found"),
                "a citation to another file's body is refused: \(codes(borrowed))")
        #expect(misplaced.metadata[.projectname] == nil)
        #expect(misplaced.state == .hold)
        #expect(!misplaced.eligibleForAutoExecution)
        // The very same citation is real evidence for B: it is foreign only for
        // A, which is what makes this check about provenance, not about content.
        let stillOwn = try #require(borrowed.manifest.entries.first { $0.sourceID != entryA.id })
        #expect(stillOwn.metadata[.projectname] == "客户甲_运维服务项目")

        // The other failure, separately: naming a real candidate that does not
        // contain this file is a wrong project, not a typo.
        let misfiled = await mapped(archive) { batch, _ in
            MappingAttempt(proposal: proposal(for: batch, association: ("confirmed", otherCandidateID)) { _ in
                [
                    Cited(id: .projectname, value: intelligentName, cites: [row(in: batch, saying: intelligentName)]),
                    Cited(id: .completionyear, value: "2026", cites: [row(in: batch, saying: "归档完成")]),
                    Cited(id: .documentcategory, value: "01_招标文件", cites: [row(in: batch, saying: "01_招标文件")]),
                ]
            }, requests: 1)
        }
        #expect(codes(misfiled).contains("membership_mismatch"),
                "a real candidate that does not hold this file must not read as a typo: \(codes(misfiled))")
    }

    // MARK: - 5. Vendor material that belongs to no project

    @Test("generic vendor collateral is not force-bound to a project")
    func vendorCollateralStaysUnaffiliated() async throws {
        let path = "厂商资料/产品线彩页合集.txt"
        let archive = try await prepared([FileSpec(path, """
        PRODUCT BROCHURE 2026 - 示例厂商全线交换机彩页
        本手册涵盖通用规格，不针对任何具体项目。
        """)], profile: try MappingProfile.vendorLibrary())
        defer { archive.cleanUp() }
        #expect(archive.context.candidates.isEmpty,
                "a vendor library invents no project directory, so nothing can be bound to one")
        let vendorRows = try archive.content(path)
        #expect(!vendorRows.isEmpty, "the body was still read, and is still citable")

        let outcome = await mapped(archive) { batch, _ in
            // No candidate_ref at all: a vendor file with no project is a normal
            // answer under this profile, not a failure.
            MappingAttempt(proposal: proposal(for: batch) { _ in
                [
                    Cited(id: .documentcategory, value: "Brochure", cites: [row(in: batch, saying: "BROCHURE")]),
                    Cited(id: .documenttype, value: "Brochure", cites: [row(in: batch, saying: "BROCHURE")]),
                    Cited(id: .projectname, unknown: true),
                    Cited(id: .completionyear, unknown: true),
                ]
            }, requests: 1)
        }
        let item = try #require(outcome.manifest.entries.first)
        #expect(codes(outcome).filter { $0.hasPrefix("association") || $0 == "membership_mismatch" }.isEmpty,
                "an unaffiliated vendor file must not be pushed into a project: \(codes(outcome))")
        #expect(item.metadata[.documentcategory] == "Brochure")
        #expect(item.metadata[.projectname] == nil, "no project was invented to make the entry fit a template")
        #expect(item.associations.isEmpty)
    }

    @Test("unconfirmed membership in a project archive holds rather than guesses")
    func unconfirmedProjectHolds() async throws {
        let path = "通用目录/产品规格书.txt"
        let archive = try await prepared([FileSpec(path, """
        通用规格书 示例厂商 Datasheet，适用于任意项目。
        """)])
        defer { archive.cleanUp() }
        let outcome = await mapped(archive) { batch, _ in
            MappingAttempt(proposal: proposal(for: batch, association: ("unconfirmed", nil)) { _ in
                MetadataFieldID.allCases.map { Cited(id: $0, unknown: true) }
            }, requests: 1)
        }
        let item = try #require(outcome.manifest.entries.first)
        #expect(codes(outcome).contains("association_unknown"),
                "a project archive needs a named candidate; declining to name one is honest: \(codes(outcome))")
        #expect(item.state == .hold)
        #expect(item.invalidatedReason == "association_unknown")
        #expect(!item.eligibleForAutoExecution)
        #expect(item.fields.filter { $0.value != nil }.isEmpty)
    }

    // MARK: - 6. Failures end in outcomes, not in evidence

    @Test("an undecodable body is a named failure with nothing citable")
    func undecodableBodyIsNotInventedEvidence() async throws {
        // The txt analogue of an encrypted or corrupt PDF: the bytes exist,
        // Forma will not pretend they are text, and no excerpt is invented to
        // fill the gap.
        let archive = try await prepared([
            FileSpec("示例项目_2026/乱码.txt", bytes: [0x80, 0x81, 0x82, 0x83, 0xA0]),
            FileSpec("示例项目_2026/二进制.txt", bytes: [0x70, 0x00, 0x61, 0x67, 0x65, 0x00]),
        ])
        defer { archive.cleanUp() }
        for path in ["示例项目_2026/乱码.txt", "示例项目_2026/二进制.txt"] {
            let content = try archive.rows(path).filter { $0.source == .content }
            #expect(content.count == 1)
            #expect(content.first?.excerpt == nil, "bytes that are not text must not be quoted as text")
            #expect(content.first?.isUsable == false)
            #expect(content.first?.locator == nil)
            #expect(content.first?.extractionStatus == .unavailable)
        }
        // One unreadable file does not blank its folder.
        let mixed = try await prepared([FileSpec("示例项目_2026/公告.txt", bidBody),
                                        FileSpec("示例项目_2026/乱码.txt", bytes: [0x80, 0x81, 0x82])])
        defer { mixed.cleanUp() }
        #expect(try !mixed.content("示例项目_2026/公告.txt").isEmpty)
        #expect(try mixed.rows("示例项目_2026/乱码.txt").filter { $0.source == .content && $0.isUsable }.isEmpty)
    }

    @Test("a rate-limited provider leaves every entry unknown with the status recorded")
    func rateLimitLeavesNothingInvented() async throws {
        let archive = try await prepared([FileSpec("示例项目_2026/abcd.txt", bidBody)])
        defer { archive.cleanUp() }
        let outcome = await mapped(archive) { _, _ in
            MappingAttempt(proposal: nil, error: .remoteStatus(429), requests: 2, rateLimitRetries: 1)
        }
        #expect(outcome.manifest.entries.allSatisfy { $0.state == .unknown })
        #expect(outcome.manifest.entries.allSatisfy { $0.invalidatedReason == "provider_remote_status" })
        #expect(outcome.failures.count == archive.entries.count)
        #expect(outcome.requests == 2, "a failed request still cost something and must be counted")
        #expect(outcome.manifest.report.allViolations.contains { $0.code == "provider_remote_status" })
        for item in outcome.manifest.entries {
            #expect(item.fields.flatMap(\.evidenceIDs).isEmpty,
                    "a provider failure is not a licence to cite, or to fall back on the name")
            #expect(!item.eligibleForAutoExecution)
        }
    }

    @Test("an answer that breaks the output shape is refused by the schema, then mapped to nothing")
    func malformedAnswerIsRejectedNotReshaped() async throws {
        let archive = try await prepared([FileSpec("示例项目_2026/abcd.txt", bidBody)])
        defer { archive.cleanUp() }
        let batch = try #require(batches(archive).first)
        let key = "probe-test-\(UUID().uuidString)"
        // A plausible provider answer that invents identity fields: the artifact
        // schema stops it before any decoding, and before the validator could
        // mistake the answer for data.
        let forged = """
        {"schema_version":"1.0","batch_id":"\(batch.id)","entries":[{"entry_ref":"\(batch.entries[0].ref)",\
        "source_id":"11111111-1111-1111-8111-111111111111","sha256":"aaaaaaaaaaaaaaaa",\
        "metadata":{"projectname":"示例项目_2026"}}]}
        """
        let stub = HTTPStub(response: .response(status: 200, body: ProbeProvider.openAI.successBody(text: forged)))
        ProbeURLProtocol.register(stub, for: key)
        defer { ProbeURLProtocol.unregister(key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeURLProtocol.self]
        let grant = EgressAuthorization(
            scope: EgressScope(provider: .openAI, model: "gpt-4o-mini", endpoint: .provider(.openAI), mode: .cloud,
                               categories: [.filePaths, .evidenceExcerpts, .projectContext, .casePackExamples,
                                            .profileRules, .systemPrompt, .repairInstructions],
                               redactionVersion: MappingPrompt.redactionVersion(for: .none),
                               identitySubstitution: true),
            binding: .dataRange)
        let client = ProviderMappingClient(session: URLSession(configuration: configuration),
                                          keyStore: MemoryKeyStore(keys: [.openAI: key]), authorization: grant)
        let pack = try CasePack.shipped()
        let attempt = await client.map(provider: .openAI, model: "gpt-4o-mini", allowCloud: true,
                                       profile: archive.profile, context: archive.context,
                                       casePack: pack, batch: batch, redaction: .none)
        #expect(attempt.proposal == nil, "a malformed answer never becomes a proposal")
        #expect(attempt.error == .invalidOutput, "the refusal is named, not swallowed: \(String(describing: attempt.error))")
        #expect(attempt.violations.isEmpty == false, "the repair call knew what was wrong")
        #expect(attempt.requests == 2, "first ask plus exactly one repair call, and both are counted")
        #expect(stub.requests.count == 2, "a local stub only: nothing left this machine")

        // What that outcome becomes in the manifest, with the rest of the
        // pipeline unchanged.
        let outcome = await mapped(archive, attempt: attempt)
        let item = try #require(outcome.manifest.entries.first)
        #expect(item.state == .unknown, "a refused answer maps nothing")
        #expect(item.invalidatedReason == "provider_invalid_output")
        #expect(item.fields.flatMap(\.evidenceIDs).isEmpty, "a rejected answer leaves no citations behind")
        #expect(!item.eligibleForAutoExecution)
        #expect(!codes(outcome).contains("evidence_not_found"),
                "the answer never reached the point of citing, so nothing reports a missing id")
    }

    // MARK: - 7. The validator is not softer for the new kind

    @Test("an evidence id the registry does not have still fails, txt included")
    func forgedReferenceStillFires() async throws {
        let path = "示例项目_2026/abcd.txt"
        let archive = try await prepared([FileSpec(path, bidBody)])
        defer { archive.cleanUp() }
        let outcome = await mapped(archive) { batch, _ in
            MappingAttempt(proposal: proposal(for: batch, association: ("confirmed", batch.candidateID)) { _ in
                [
                    Cited(id: .projectname, value: "示例项目_2026", cites: ["ev_not_in_registry_0000"]),
                    Cited(id: .completionyear, value: "2026", cites: [row(in: batch, saying: "归档完成")]),
                    Cited(id: .documentcategory, value: "01_招标文件", cites: [row(in: batch, saying: "01_招标文件")]),
                ]
            }, requests: 1)
        }
        let item = try #require(outcome.manifest.entries.first)
        #expect(codes(outcome).contains("evidence_not_found"),
                "the registry is the only thing a citation may resolve against: \(codes(outcome))")
        #expect(item.metadata[.projectname] == nil)
        #expect(item.state == .hold)
        #expect(!item.eligibleForAutoExecution)

        // A locator whose range does not address its own stored excerpt is a row
        // no read ever produced. Text is checked at least as strictly as PDF and
        // DOCX precisely because, for text, that check is decidable here.
        let entry = try archive.entry(path)
        let real = try #require(archive.content(path).first)
        let tampered = EvidenceRecord(id: "ev_tampered", sourceID: entry.id,
                                      snapshotRevision: Int(entry.snapshotRevision),
                                      snapshotFingerprint: entry.snapshotFingerprint, source: .content,
                                      locator: .text(characterRange: 0..<9_999), relativePath: nil,
                                      excerpt: real.excerpt, extractionStatus: .ok,
                                      extractorVersion: EvidenceRegistry.extractorVersion, createdAt: .now)
        var metadata = MetadataValues.allUnknown
        metadata[.documentcategory] = "01_招标文件"
        let answer = ProposalEntry(entryRef: "e1",
                                   projectAssociation: ProposalAssociation(candidateRef: nil, state: .unconfirmed),
                                   documentCategory: "01_招标文件", documentType: nil, metadata: metadata,
                                   evidence: [EvidenceCitation(field: .documentcategory,
                                                               evidenceID: "ev_tampered")],
                                   unknownFields: [], conflicts: [], confidence: .high,
                                   reasoning: "引用了一段与定位符区间长度不符的正文。")
        let registry: [UUID: [EvidenceRecord]] = [entry.id: [tampered] + (archive.evidence[entry.id] ?? [])]
        let checked = ManifestValidator(ValidationInput(profile: archive.profile, context: archive.context,
                                                        entries: [entry], evidence: registry,
                                                        proposals: [ProposalForEntry(sourceID: entry.id,
                                                                                     proposal: answer)])).validate()
        #expect(checked.report.allViolations.contains { $0.code == "locator_excerpt_mismatch" },
                "a text locator must address its quote: \(checked.report.allViolations.map(\.code))")
        #expect(checked.entries[0].metadata[.documentcategory] == nil)
        #expect(!checked.entries[0].eligibleForAutoExecution)
    }

    @Test("the evidence identifier formula stays put while the extractor moves")
    func identifierFormulaIsPinned() {
        // #145 depends on this. Ids are minted from source, snapshot, kind and
        // locator only; re-versioning the formula would re-mint every row of an
        // unchanged file, which is exactly how stored citations start failing
        // `evidence_not_found`. The extractor version is a separate label, and it
        // did move, because plain-text bodies now exist.
        #expect(EvidenceRegistry.identityVersion == "evidence.v1")
        #expect(EvidenceRegistry.extractorVersion == "evidence.v2")
        #expect(EvidenceExtraction.extractorVersion == "evidence.v2")
    }

    @Test("a stand-in answer is shaped like real provider output, not like the validator's convenience")
    func standInAnswersAreSchemaShaped() async throws {
        // These answers are only contract evidence if a real provider could have
        // written them: same closed schema, same required shape.
        let archive = try await prepared([FileSpec("示例项目_2026/abcd.txt", bidBody)])
        defer { archive.cleanUp() }
        let batch = try #require(batches(archive).first)
        let cited = try #require(batch.evidence.first).id
        let text = answerText(for: batch, association: ("confirmed", batch.candidateID)) { _ in
            [Cited(id: .documentcategory, value: "01_招标文件", cites: [cited])]
        }
        let violations = try ArtifactSchemaValidator.proposal.violations(Data(text.utf8))
        #expect(violations.isEmpty,
                "the stand-in answer must satisfy the output schema: \(violations.map(\.logSummary))")
    }
}
