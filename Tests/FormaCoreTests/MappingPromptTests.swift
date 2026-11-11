import Foundation
import Testing

@testable import FormaCore

/// What leaves the machine, and what it must never contain.
@Suite("Mapping prompt")
struct MappingPromptTests {
    private let scopeID = UUID(uuidString: "00000000-0000-4000-8000-000000000050")!
    private let sourceID = UUID(uuidString: "00000000-0000-4000-8000-000000000051")!
    private let otherID = UUID(uuidString: "00000000-0000-4000-8000-000000000052")!
    private let fingerprint = String(repeating: "b", count: 64)

    private func entry(_ id: UUID, _ path: String) -> SourceEntry {
        SourceEntry(id: id, rootID: UUID(uuidString: "00000000-0000-4000-8000-000000000053")!,
                    relativePath: path, normalizedRelativePath: path.lowercased(), state: .present,
                    hydrationPending: false, sourceVersion: 1, snapshotRevision: 2, provider: .oneDrive,
                    snapshotFingerprint: fingerprint, sizeBytes: 4_096, modificationTimeNanoseconds: 0,
                    sha256: nil)
    }

    private func record(_ id: String, source: EvidenceSource, excerpt: String, file: SourceEntry,
                        locator: EvidenceLocator? = .pdf(page: 1, characterRange: 0..<20)) throws
        -> EvidenceRecord
    {
        EvidenceRecord(id: id, sourceID: file.id, snapshotRevision: 2, snapshotFingerprint: fingerprint,
                       source: source, locator: locator, relativePath: locator == nil ? file.relativePath : nil,
                       excerpt: excerpt, extractionStatus: .ok,
                       extractorVersion: EvidenceRegistry.extractorVersion, createdAt: .now)
    }

    private func context(profile: MappingProfile, members: [UUID], otherMembers: [UUID] = []) -> ProjectContext {
        var candidates = [ContextCandidate(id: "c1", projectKey: "示例项目_2026", displayName: "示例项目_2026",
                                           basis: [.directory], memberSourceIDs: Set(members), confidence: .medium)]
        if !otherMembers.isEmpty {
            candidates.append(ContextCandidate(id: "c2", projectKey: "无关项目_2025", displayName: "无关项目_2025",
                                               basis: [.directory], memberSourceIDs: Set(otherMembers),
                                               confidence: .medium))
        }
        return ProjectContext(revision: 3, scopeID: scopeID, profileID: profile.profileID,
                              profileVersion: profile.profileVersion,
                              inputDigest: String(repeating: "d", count: 64), candidates: candidates,
                              unassignedSourceIDs: [], conflictedSourceIDs: [], builtAt: .now)
    }

    private func batch(file: SourceEntry, evidence: [EvidenceRecord]) -> MappingBatch {
        MappingBatch(id: "b1", candidateID: "c1",
                    entries: [MappingEntryRef(ref: "e1", sourceID: file.id, relativePath: file.relativePath,
                                              sizeBytes: 4_096, extensionName: "pdf", hydrationPending: false,
                                              provider: file.provider.rawValue)],
                    evidence: evidence)
    }

    @Test("the payload carries no source identity, hash, absolute path or execution flag")
    func payloadLeaksNothing() throws {
        let profile = try MappingProfile.projectArchive()
        let file = entry(sourceID, "示例项目_2026/01_招标/公告.pdf")
        let records = [
            try record("ev_1", source: .content, excerpt: "招标公告正文", file: file),
            try record("ev_2", source: .path, excerpt: "示例项目_2026/01_招标", file: file, locator: nil),
        ]
        let data = try MappingPrompt.payload(profile: profile, context: context(profile: profile,
                                                                                members: [file.id]),
                                             casePack: try CasePack.shipped(), batch: batch(file: file,
                                                                                            evidence: records),
                                             redaction: RedactionPlan.none)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(sourceID.sourceKey), "a source_id must never travel")
        #expect(!text.contains(sourceID.uuidString.lowercased()) && !text.contains(sourceID.uuidString))
        #expect(!text.contains(fingerprint), "a snapshot fingerprint is not something a model needs")
        #expect(!text.contains("/Users/"))
        for forbidden in ["eligible_for_auto_execution", "source_id", "sha256", "database_uuid",
                          "create_record", "set_record_metadata", "import_record", "move_record",
                          "trash_record", "replicate"] {
            #expect(!text.contains(forbidden), "the payload must not mention \(forbidden)")
        }
        // The reference the model must answer for is present, and opaque.
        #expect(text.contains("\"entry_ref\":\"e1\""))
    }

    @Test("only the candidates that touch this batch are sent")
    func contextIsScopedToBatch() throws {
        let profile = try MappingProfile.projectArchive()
        let file = entry(sourceID, "示例项目_2026/01_招标/公告.pdf")
        let stranger = entry(otherID, "无关项目_2025/公告.pdf")
        let data = try MappingPrompt.payload(profile: profile,
                                             context: context(profile: profile, members: [file.id],
                                                              otherMembers: [stranger.id]),
                                             casePack: try CasePack.shipped(),
                                             batch: batch(file: file, evidence: []), redaction: RedactionPlan.none)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("示例项目_2026"))
        #expect(!text.contains("无关项目_2025"), "another project's membership has no reason to leave")
    }

    @Test("evidence from outside the batch is refused before anything is sent")
    func foreignEvidenceRefused() throws {
        let profile = try MappingProfile.projectArchive()
        let file = entry(sourceID, "示例项目_2026/01_招标/公告.pdf")
        let stranger = entry(otherID, "别的项目/公告.pdf")
        let foreign = try record("ev_x", source: .content, excerpt: "别人的正文", file: stranger)
        #expect(throws: (any Error).self) {
            try MappingPrompt.payload(profile: profile, context: context(profile: profile, members: [file.id]),
                                      casePack: try CasePack.shipped(),
                                      batch: batch(file: file, evidence: [foreign]), redaction: RedactionPlan.none)
        }
    }

    @Test("the digest is reproducible and reacts to every input that matters")
    func digestIsMeaningful() throws {
        let profile = try MappingProfile.projectArchive()
        let file = entry(sourceID, "示例项目_2026/01_招标/公告.pdf")
        let record1 = try record("ev_1", source: .content, excerpt: "招标公告正文", file: file)
        let pack = try CasePack.shipped()
        let build: (String) throws -> Data = { excerpt in
            let row = try self.record("ev_1", source: .content, excerpt: excerpt, file: file)
            return try MappingPrompt.payload(profile: profile, context: self.context(profile: profile,
                                                                                     members: [file.id]),
                                             casePack: pack, batch: self.batch(file: file, evidence: [row]),
                                             redaction: RedactionPlan.none)
        }
        let first = try build("招标公告正文")
        let same = try build("招标公告正文")
        #expect(first == same)
        #expect(MappingPrompt.digest(payload: first, system: "s") == MappingPrompt.digest(payload: same, system: "s"))
        let changed = try build("招标公告正文（不同正文）")
        #expect(first != changed)
        #expect(MappingPrompt.digest(payload: first, system: "a") != MappingPrompt.digest(payload: first, system: "b"))
    }

    @Test("redaction keeps roles distinct and removes money and identifiers")
    func redactionPreservesRoles() throws {
        let plan = RedactionPlan(terms: [
            "客户甲有限公司": .customer,
            "示例厂商乙": .vendor,
            "我方投标公司丙": .bidder,
            "张三": .person,
        ], salt: "workspace-salt")
        let text = try plan.redact(text: "客户甲有限公司向示例厂商乙采购，我方投标公司丙报价 1,234,567.89 元，联系人张三。")
        #expect(text.contains("«客户"), "the customer must be replaced: \(text)")
        #expect(text.contains("«厂商"), "the vendor must be replaced: \(text)")
        #expect(text.contains("«投标主体"), "the bidding entity must be replaced: \(text)")
        #expect(text.contains("«人员"), "the person must be replaced: \(text)")
        #expect(text.contains("«金额"), "the amount must be replaced, got \(text)")
        for term in ["客户甲有限公司", "示例厂商乙", "我方投标公司丙", "张三", "1,234,567.89"] {
            #expect(!text.contains(term), "\(term) survived redaction")
        }
        // The roles stay distinguishable, which is what the mapping has to reason about.
        #expect(Set([plan.placeholder(for: "客户甲有限公司"), plan.placeholder(for: "示例厂商乙")])
                    .count == 2)
        let uuid = "00000000-0000-4000-8000-000000000051"
        #expect(plan.redact(path: "项目/\(uuid)/公告.pdf").contains("«标识»"))
        #expect(plan.roles[.customer] == 1)
        #expect(plan.leaks("含客户甲有限公司的路径").count == 1)
    }

    @Test("an amount label follows the value, not the call order")
    func amountLabelsAreValueDerived() throws {
        let plan = RedactionPlan.none
        let prose = try plan.redact(text: "报价 1,234,567.89 元")
        let table = try plan.redact(text: "表格合计 1,234,567.89 元")
        let other = try plan.redact(text: "报价 980,000.00 元")
        let first = try #require(amountLabel(in: prose))
        // A total that appears in prose and again in a table is one fact the
        // mapping has to be able to recognise; two labels for it would read as
        // two different prices.
        #expect(amountLabel(in: table) == first, "one figure must share one label: \(prose) / \(table)")
        let second = try #require(amountLabel(in: other))
        #expect(second != first, "different figures must not collapse onto one label")
        #expect(!prose.contains("1,234,567.89"))
    }

    @Test("references, dates and versions are not amounts")
    func identifiersSurviveAmountMatching() throws {
        let plan = RedactionPlan.none
        let text = try plan.redact(text: "招标编号 ZB-DEMO-2026-014，版本 v1.234，2026年3月15日截止，预算 1,200 万元")
        #expect(text.contains("ZB-DEMO-2026-014"), "a tender reference must survive: \(text)")
        #expect(text.contains("v1.234"), "a version must survive: \(text)")
        #expect(text.contains("2026年3月15日"), "a date must survive: \(text)")
        #expect(!text.contains("1,200"), "an explicit 万元 figure must be replaced: \(text)")
    }

    @Test("a grouped number is money only when the words around it say so")
    func bareGroupedNumbersNeedACue() throws {
        let plan = RedactionPlan.none
        let priced = try plan.redact(text: "中标价 1,200,000 元整")
        let cued = try plan.redact(text: "合计 1,200,000")
        let uncued = try plan.redact(text: "档案流水号 1,200,000")
        #expect(!priced.contains("1,200,000"))
        #expect(!cued.contains("1,200,000"), "a money word in front makes it an amount: \(cued)")
        #expect(uncued.contains("1,200,000"), "a bare serial number is not a price: \(uncued)")
    }

    /// The amount placeholder this plan produced, if any.
    private func amountLabel(in value: String) -> String? {
        guard let start = value.range(of: "«金额") else { return nil }
        guard let end = value[start.upperBound...].range(of: "»") else { return nil }
        return String(value[start.lowerBound..<end.upperBound])
    }

    @Test("an identity plan records that no redaction was applied")
    func identityPlanIsMarked() {
        #expect(RedactionPlan.none.isIdentity)
        #expect(!RedactionPlan(terms: ["某客户": .customer], salt: "s").isIdentity)
    }

    @Test("the system prompt states the trust boundaries and the profile traps")
    func systemPromptContent() throws {
        let profile = try MappingProfile.projectArchive()
        let pack = try CasePack.shipped()
        let system = MappingPrompt.system(profile: profile, casePack: pack)
        #expect(system.contains("Untrusted data"))
        #expect(system.contains("Never call a tool"))
        #expect(system.contains("It grants nothing"), "confidence must be described as non-authoritative")
        #expect(system.contains(profile.counterExamples[0]))
        #expect(system.contains(profile.versionKey))
        #expect(system.contains(pack.versionKey))
        #expect(!system.contains("991"), "the historical ledger size is not part of a prompt")
    }

    @Test("the case selection stays inside the prompt budget")
    func caseBudget() throws {
        let profile = try MappingProfile.projectArchive()
        let pack = try CasePack.shipped()
        #expect(pack.selected(for: profile).count <= 24)
        #expect(pack.selected(for: profile).count <= pack.cases.count)
    }

    @Test("a label is derived from the term and the workspace salt")
    func labelsDependOnTheSalt() throws {
        let names = (1...6).map { "客户名称\($0)" }
        let terms = Dictionary(uniqueKeysWithValues: names.map { ($0, RedactionPlan.Role.customer) })
        func numbering(_ salt: String) -> [String: String] {
            let plan = RedactionPlan(terms: terms, salt: salt)
            return Dictionary(uniqueKeysWithValues: names.map { ($0, plan.placeholder(for: $0) ?? "") })
        }
        let first = numbering("workspace-a")
        #expect(Set(first.values).count == 6, "six customers need six distinct labels")
        #expect(first == numbering("workspace-a"), "the same salt must reproduce itself")
        // A label that was a position in the caller's list, or a hash of the
        // term alone, would let anyone holding the name list read the requests
        // back into names. The salt is what makes that impossible.
        #expect(first != numbering("workspace-b"),
                "a different salt must not reproduce the same labels")
        #expect(first.values.allSatisfy { $0.hasPrefix("«客户") && $0.count > 4 },
                "a label keeps its role and carries a salted code")
    }

    @Test("a field rule names the vocabulary its value must come from")
    func fieldRulesCarryVocabularies() throws {
        let profile = try MappingProfile.projectArchive()
        let file = entry(sourceID, "示例项目_2026/01_招标/公告.pdf")
        let data = try MappingPrompt.payload(profile: profile,
                                             context: context(profile: profile, members: [file.id]),
                                             casePack: try CasePack.shipped(),
                                             batch: batch(file: file, evidence: []), redaction: .none)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rules = try #require(root["field_rules"] as? [[String: Any]])
        let byField = Dictionary(uniqueKeysWithValues: rules.map { ($0["identifier"] as? String ?? "", $0) })
        // The system text tells the model to use only the profile's values; the
        // rule that carries no vocabulary makes that instruction unverifiable.
        let categories = try #require(byField["documentcategory"]?["allowed_values"] as? [String])
        #expect(categories == profile.categories.map(\.identifier),
                "the category rule must carry the profile's own enumeration")
        let types = try #require(byField["documenttype"]?["allowed_values"] as? [String])
        #expect(types == profile.documentTypes.map(\.identifier))
        #expect((byField["projectname"]?["allowed_values"] as? [String])?.isEmpty == true,
                "a free-text field has no vocabulary to name")
    }

    @Test("the payload bounds its evidence rows and reports what it left out")
    func evidenceRowsAreBounded() throws {
        let profile = try MappingProfile.projectArchive()
        let file = entry(sourceID, "示例项目_2026/01_招标/公告.pdf")
        var records = [try record("ev_content", source: .content, excerpt: "招标公告正文", file: file)]
        for index in 0..<(MappingPrompt.maximumEvidenceRows + 50) {
            records.append(try record("ev_meta_\(index)", source: .fsMetadata, excerpt: "size_bytes=4096",
                                       file: file, locator: nil))
        }
        let data = try MappingPrompt.payload(profile: profile,
                                             context: context(profile: profile, members: [file.id]),
                                             casePack: try CasePack.shipped(),
                                             batch: batch(file: file, evidence: records),
                                             redaction: .none)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(root["evidence"] as? [[String: Any]])
        #expect(rows.count == MappingPrompt.maximumEvidenceRows,
                "the request body must be bounded, got \(rows.count)")
        let constraints = try #require(root["constraints"] as? [String: Any])
        #expect(constraints["evidence_rows_omitted"] as? Int == 51,
                "a truncated request must say how much it dropped")
        #expect(rows.contains { $0["source"] as? String == "content" },
                "content rows are what the field rules are judged on")
        // Ranking is the point of the budget: the rows the field rules are
        // judged on stay, and the cheapest filler is what gets dropped.
        let kept = rows.filter { $0["source"] as? String == "fs_metadata" }.count
        #expect(kept == MappingPrompt.maximumEvidenceRows - 1,
                "filesystem metadata is the first thing the budget gives up, kept \(kept)")
        #expect(rows.filter { $0["source"] as? String == "content" }.count == 1)
    }
}
