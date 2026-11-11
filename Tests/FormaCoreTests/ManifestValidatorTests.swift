import Foundation
import Testing

@testable import FormaCore

/// The validator is the only thing standing between a model's claim and an
/// executable-looking manifest, so each rule here is tested by trying to break
/// it with a plausible but unsupported answer.
@Suite("Manifest validator")
struct ManifestValidatorTests {
    private let rootID = UUID(uuidString: "00000000-0000-4000-8000-000000000040")!
    private let scopeID = UUID(uuidString: "00000000-0000-4000-8000-000000000041")!
    private let fileID = UUID(uuidString: "00000000-0000-4000-8000-000000000042")!
    private let otherID = UUID(uuidString: "00000000-0000-4000-8000-000000000043")!
    private let fingerprint = String(repeating: "a", count: 64)

    private func entry(_ id: UUID, _ path: String, hydration: Bool = false,
                       state: SourceEntryState = .present) -> SourceEntry {
        SourceEntry(id: id, rootID: rootID, relativePath: path, normalizedRelativePath: path.lowercased(),
                    state: state, hydrationPending: hydration, sourceVersion: 1, snapshotRevision: 3,
                    provider: .local, snapshotFingerprint: fingerprint, sizeBytes: 2_048,
                    modificationTimeNanoseconds: 0, sha256: nil)
    }

    private func evidence(_ id: String, source: EvidenceSource, value: String?, file: SourceEntry,
                          locator: EvidenceLocator? = nil, revision: Int = 3,
                          status: EvidenceStatus = .ok, candidate: String? = nil,
                          from sourceID: UUID? = nil) throws -> EvidenceRecord {
        EvidenceRecord(id: id, sourceID: sourceID ?? file.id, snapshotRevision: revision,
                       snapshotFingerprint: fingerprint, source: source, locator: locator,
                       relativePath: locator == nil ? file.relativePath : nil, excerpt: value,
                       extractionStatus: status, extractorVersion: EvidenceRegistry.extractorVersion,
                       createdAt: .now, contextCandidateID: candidate)
    }

    private func proposal(ref: String = "e1", category: String? = "02_投标文件",
                          type: String? = "Bid Document", metadata: [MetadataFieldID: String?] = [:],
                          citations: [EvidenceCitation] = [], unknown: [MetadataFieldID] = [],
                          conflicts: [ProposalConflict] = [],
                          association: ProposalAssociation? = ProposalAssociation(candidateRef: "示例项目_2026",
                                                                                  state: .confirmed),
                          confidence: DecisionConfidence = .high) -> ProposalEntry {
        var slots = MetadataValues.allUnknown
        slots[.documentcategory] = category
        slots[.documenttype] = type
        for (field, value) in metadata { slots[field] = value }
        return ProposalEntry(entryRef: ref, projectAssociation: association, documentCategory: category,
                             documentType: type, metadata: slots, evidence: citations,
                             unknownFields: Set(unknown), conflicts: conflicts, confidence: confidence,
                             reasoning: "正文含项目名称与投标编号，表格已填写实际参数。")
    }

    private struct Harness {
        let profile: MappingProfile
        let context: ProjectContext
        let entries: [SourceEntry]
        let registry: [UUID: [EvidenceRecord]]
    }

    /// A minimal but honest archive workspace: one candidate containing the file,
    /// with content evidence for the project name, the year and the category.
    private func archive(files: [SourceEntry]? = nil) throws -> Harness {
        let profile = try MappingProfile.projectArchive()
        let listed = files ?? [entry(fileID, "示例项目_2026/02_投标/技术标.pdf")]
        let context = ProjectContext(
            revision: 1, scopeID: scopeID, profileID: profile.profileID, profileVersion: profile.profileVersion,
            inputDigest: String(repeating: "d", count: 64),
            candidates: [ContextCandidate(id: "c1", projectKey: "示例项目_2026", displayName: "示例项目_2026",
                                          basis: [.directory], memberSourceIDs: Set(listed.map(\.id)),
                                          confidence: .medium)],
            unassignedSourceIDs: [], conflictedSourceIDs: [], builtAt: .now
        )
        let file = listed[0]
        let records = [
            try evidence("ev_name", source: .content, value: "示例项目_2026 智能化改造项目投标文件",
                         file: file, locator: .pdf(page: 1, characterRange: 0..<40)),
            try evidence("ev_year", source: .content, value: "归档完成 2026 年", file: file,
                         locator: .pdf(page: 3, characterRange: 0..<12)),
            try evidence("ev_category", source: .content, value: "02_投标文件 技术标", file: file,
                         locator: .pdf(page: 1, characterRange: 0..<20)),
            try evidence("ev_type", source: .content, value: "Bid Document 技术标", file: file,
                         locator: .pdf(page: 1, characterRange: 0..<22)),
        ]
        return Harness(profile: profile, context: context, entries: listed,
                       registry: [file.id: records])
    }

    private func validate(_ harness: Harness, answer: ProposalEntry?,
                          evidenceOverride: [UUID: [EvidenceRecord]]? = nil) -> ManifestValidator.Result {
        let input = ValidationInput(profile: harness.profile, context: harness.context, entries: harness.entries,
                                    evidence: evidenceOverride ?? harness.registry,
                                    proposals: [ProposalForEntry(sourceID: harness.entries[0].id, proposal: answer)])
        return ManifestValidator(input).validate()
    }

    private func citations(_ pairs: [(MetadataFieldID, String)]) -> [EvidenceCitation] {
        pairs.map { EvidenceCitation(field: $0.0, evidenceID: $0.1) }
    }

    @Test("a fully evidenced answer becomes validated and eligible")
    func cleanPass() throws {
        let harness = try archive()
        let answer = proposal(
            metadata: [.projectname: "示例项目_2026", .completionyear: "2026"],
            citations: citations([(.projectname, "ev_name"), (.completionyear, "ev_year"),
                                  (.documentcategory, "ev_category"), (.documenttype, "ev_type")])
        )
        let result = validate(harness, answer: answer)
        let item = try #require(result.entries.first)
        #expect(item.state == .validated)
        #expect(item.eligibleForAutoExecution, "a complete evidenced mapping should qualify under policy")
        #expect(item.metadata[.issuer] == nil)
        #expect(result.report.groups.allSatisfy { $0.status == .passed },
                "unexpected violations: \(result.report.allViolations.map(\.code))")
        #expect(result.report.counts.validated == 1)
    }

    @Test("a forged evidence identifier is rejected")
    func forgedEvidenceID() throws {
        let harness = try archive()
        let answer = proposal(metadata: [.projectname: "示例项目_2026", .completionyear: "2026"],
                             citations: citations([(.projectname, "ev_invented"), (.completionyear, "ev_year"),
                                                   (.documentcategory, "ev_category"), (.documenttype, "ev_type")]))
        let result = validate(harness, answer: answer)
        #expect(result.report.allViolations.contains { $0.code == "evidence_not_found" })
        #expect(result.entries[0].state == .hold)
        #expect(!result.entries[0].eligibleForAutoExecution)
    }

    @Test("evidence belonging to another source is rejected")
    func foreignEvidence() throws {
        let harness = try archive()
        let stranger = entry(otherID, "别的项目/公告.pdf")
        let planted = try evidence("ev_other", source: .content, value: "示例项目_2026 智能化改造项目投标文件",
                                   file: harness.entries[0], locator: .pdf(page: 1, characterRange: 0..<40),
                                   from: stranger.id)
        var registry = harness.registry
        registry[harness.entries[0].id]?.append(planted)
        let answer = proposal(metadata: [.projectname: "示例项目_2026", .completionyear: "2026"],
                             citations: citations([(.projectname, "ev_other"), (.completionyear, "ev_year"),
                                                   (.documentcategory, "ev_category"), (.documenttype, "ev_type")]))
        let result = validate(harness, answer: answer, evidenceOverride: registry)
        #expect(result.report.allViolations.contains { $0.code == "evidence_foreign_source" })
        #expect(!result.entries[0].eligibleForAutoExecution)
    }

    @Test("evidence from a superseded snapshot is rejected")
    func staleSnapshot() throws {
        let harness = try archive()
        let moved = entry(fileID, "示例项目_2026/02_投标/技术标.pdf")
        // Same path, new snapshot revision: the old excerpt can no longer speak.
        let stale = try evidence("ev_name", source: .content, value: "示例项目_2026 智能化改造项目投标文件",
                                 file: moved, locator: .pdf(page: 1, characterRange: 0..<40), revision: 2)
        var records = try archive().registry[moved.id] ?? []
        records[0] = stale
        let input = ValidationInput(
            profile: harness.profile, context: harness.context, entries: [moved],
            evidence: [moved.id: records],
            proposals: [ProposalForEntry(sourceID: moved.id, proposal: proposal(
                metadata: [.projectname: "示例项目_2026", .completionyear: "2026"],
                citations: citations([(.projectname, "ev_name"), (.completionyear, "ev_year"),
                                      (.documentcategory, "ev_category"), (.documenttype, "ev_type")])))]
        )
        let result = ManifestValidator(input).validate()
        #expect(result.report.allViolations.contains { $0.code == "evidence_snapshot_mismatch" })
        #expect(result.entries[0].state == .hold)
    }

    @Test("a value that the cited excerpt does not contain is refused")
    func quoteMismatch() throws {
        let harness = try archive()
        let answer = proposal(metadata: [.projectname: "另一个项目", .completionyear: "2026"],
                             citations: citations([(.projectname, "ev_name"), (.completionyear, "ev_year"),
                                                   (.documentcategory, "ev_category"), (.documenttype, "ev_type")]))
        let result = validate(harness, answer: answer)
        #expect(result.report.allViolations.contains { $0.code == "quote_mismatch" })
        #expect(result.entries[0].metadata[.projectname] == nil)
    }

    @Test("a category outside the profile vocabulary is refused")
    func unknownCategory() throws {
        let harness = try archive()
        let answer = proposal(category: "07_其他", metadata: [.projectname: "示例项目_2026", .completionyear: "2026"],
                             citations: citations([(.projectname, "ev_name"), (.completionyear, "ev_year"),
                                                   (.documenttype, "ev_type")]))
        let result = validate(harness, answer: answer)
        #expect(result.report.allViolations.contains { $0.code == "category_unknown" })
    }

    @Test("high confidence without evidence never grants eligibility")
    func confidenceIsNotAuthority() throws {
        let harness = try archive()
        let answer = proposal(metadata: [.projectname: "示例项目_2026", .completionyear: "2026"],
                             citations: [], confidence: .high)
        let result = validate(harness, answer: answer)
        #expect(result.entries[0].state == .hold)
        #expect(!result.entries[0].eligibleForAutoExecution)
        #expect(result.entries[0].confidence == .high, "confidence is kept for display, never for permission")
        #expect(result.report.allViolations.contains { $0.code == "evidence_missing" })
    }

    @Test("a brand or filename alone cannot establish the issuer")
    func issuerNeedsSignatureEvidence() throws {
        let harness = try archive()
        let brand = try evidence("ev_brand", source: .filename, value: "示例品牌A", file: harness.entries[0])
        var records = harness.registry[harness.entries[0].id] ?? []
        records.append(brand)
        let answer = proposal(
            metadata: [.projectname: "示例项目_2026", .completionyear: "2026", .issuer: "示例品牌A"],
            citations: citations([(.projectname, "ev_name"), (.completionyear, "ev_year"),
                                  (.documentcategory, "ev_category"), (.documenttype, "ev_type"),
                                  (.issuer, "ev_brand")])
        )
        let result = validate(harness, answer: answer, evidenceOverride: [harness.entries[0].id: records])
        #expect(result.report.allViolations.contains { $0.code == "insufficient_evidence" })
        #expect(result.entries[0].metadata[.issuer] == nil)
    }

    @Test("a date in a filename is not an archive completion year")
    func completionYearNeedsFact() throws {
        let harness = try archive()
        let dated = try evidence("ev_dated", source: .filename, value: "2026", file: harness.entries[0])
        var records = harness.registry[harness.entries[0].id] ?? []
        records.append(dated)
        let answer = proposal(metadata: [.projectname: "示例项目_2026", .completionyear: "2026"],
                             citations: citations([(.projectname, "ev_name"), (.completionyear, "ev_dated"),
                                                   (.documentcategory, "ev_category"), (.documenttype, "ev_type")]))
        let result = validate(harness, answer: answer, evidenceOverride: [harness.entries[0].id: records])
        // `filename` is not an allowed source for completionyear at all, so the
        // policy rejects the citation by kind before the insufficiency rule.
        #expect(result.report.allViolations.contains { $0.code == "source_not_allowed" })
        #expect(result.entries[0].metadata[.completionyear] == nil)
    }

    @Test("an unconfirmed project holds a Project Archive entry")
    func archiveNeedsProject() throws {
        let harness = try archive()
        let answer = proposal(metadata: [.completionyear: "2026"],
                             citations: citations([(.completionyear, "ev_year"), (.documentcategory, "ev_category"),
                                                   (.documenttype, "ev_type")]),
                             association: ProposalAssociation(candidateRef: "示例项目_2026", state: .unconfirmed))
        let result = validate(harness, answer: answer)
        #expect(result.entries[0].metadata[.projectname] == nil)
        #expect(result.entries[0].state == .hold)
    }

    @Test("a vendor document with no project is normal")
    func vendorWithoutProject() throws {
        let profile = try MappingProfile.vendorLibrary()
        let file = entry(fileID, "厂商资料/产品A_数据表.pdf")
        let context = ProjectContext(
            revision: 1, scopeID: scopeID, profileID: profile.profileID, profileVersion: profile.profileVersion,
            inputDigest: String(repeating: "d", count: 64), candidates: [],
            unassignedSourceIDs: [file.id], conflictedSourceIDs: [], builtAt: .now
        )
        let records = [
            try evidence("ev_cat", source: .content, value: "Datasheet 产品A 参数表", file: file,
                         locator: .pdf(page: 1, characterRange: 0..<24)),
            try evidence("ev_type", source: .content, value: "Datasheet", file: file,
                         locator: .pdf(page: 1, characterRange: 0..<9)),
        ]
        let answer = ProposalEntry(
            entryRef: "e1", projectAssociation: nil, documentCategory: "Datasheet", documentType: "Datasheet",
            metadata: {
                var slots = MetadataValues.allUnknown
                slots[.documentcategory] = "Datasheet"
                slots[.documenttype] = "Datasheet"
                return slots
            }(),
            evidence: citations([(.documentcategory, "ev_cat"), (.documenttype, "ev_type")]),
            unknownFields: [.projectname, .completionyear], conflicts: [], confidence: .medium,
            reasoning: "通用厂商数据表，正文未提及任何项目。"
        )
        let input = ValidationInput(profile: profile, context: context, entries: [file],
                                    evidence: [file.id: records],
                                    proposals: [ProposalForEntry(sourceID: file.id, proposal: answer)])
        let result = ManifestValidator(input).validate()
        let item = result.entries[0]
        #expect(item.metadata[.projectname] == nil)
        #expect(item.state == .validated, "vendor documents may legitimately have no project: \(result.report.allViolations.map(\.code))")
        #expect(item.eligibleForAutoExecution)
    }

    @Test("a candidate the context does not know is rejected")
    func inventedCandidate() throws {
        let harness = try archive()
        let answer = proposal(metadata: [.projectname: "示例项目_2026", .completionyear: "2026"],
                             citations: citations([(.projectname, "ev_name"), (.completionyear, "ev_year"),
                                                   (.documentcategory, "ev_category"), (.documenttype, "ev_type")]),
                             association: ProposalAssociation(candidateRef: "凭空项目", state: .confirmed))
        let result = validate(harness, answer: answer)
        #expect(result.report.allViolations.contains { $0.code == "candidate_unknown" })
        #expect(result.entries[0].state == .hold)
    }

    @Test("a file two candidates claim is held for review")
    func conflictedMembership() throws {
        var harness = try archive()
        let conflicted = ProjectContext(
            revision: harness.context.revision, scopeID: scopeID, profileID: harness.context.profileID,
            profileVersion: harness.context.profileVersion, inputDigest: harness.context.inputDigest,
            candidates: harness.context.candidates, unassignedSourceIDs: [],
            conflictedSourceIDs: [fileID], builtAt: harness.context.builtAt
        )
        harness = Harness(profile: harness.profile, context: conflicted, entries: harness.entries,
                          registry: harness.registry)
        let answer = proposal(metadata: [.projectname: "示例项目_2026", .completionyear: "2026"],
                             citations: citations([(.projectname, "ev_name"), (.completionyear, "ev_year"),
                                                   (.documentcategory, "ev_category"), (.documenttype, "ev_type")]))
        let result = validate(harness, answer: answer)
        #expect(result.report.allViolations.contains { $0.code == "membership_conflict" })
        #expect(!result.entries[0].eligibleForAutoExecution)
    }

    @Test("a cloud placeholder is never mapped from its name alone")
    func hydrationPending() throws {
        let profile = try MappingProfile.projectArchive()
        let file = entry(fileID, "示例项目_2026/02_投标/技术标.pdf", hydration: true)
        let context = ProjectContext(
            revision: 1, scopeID: scopeID, profileID: profile.profileID, profileVersion: profile.profileVersion,
            inputDigest: "d", candidates: [ContextCandidate(id: "c1", projectKey: "示例项目_2026",
                                                             displayName: nil, basis: [.directory],
                                                             memberSourceIDs: [file.id], confidence: .low)],
            unassignedSourceIDs: [], conflictedSourceIDs: [], builtAt: .now
        )
        let records = [try evidence("ev_name", source: .filename, value: "技术标.pdf", file: file)]
        let input = ValidationInput(profile: profile, context: context, entries: [file],
                                    evidence: [file.id: records],
                                    proposals: [ProposalForEntry(sourceID: file.id, proposal: proposal(
                                        metadata: [.projectname: "示例项目_2026", .completionyear: "2026"],
                                        citations: citations([(.projectname, "ev_name")])))])
        let result = ManifestValidator(input).validate()
        #expect(result.report.allViolations.contains { $0.code == "hydration_pending" })
        #expect(result.entries[0].state == .hold)
        #expect(result.entries[0].invalidatedReason == "hydration_pending")
    }

    @Test("a provider failure leaves the entry unknown, never mapped")
    func providerFailure() throws {
        let harness = try archive()
        let input = ValidationInput(profile: harness.profile, context: harness.context, entries: harness.entries,
                                    evidence: harness.registry,
                                    proposals: [ProposalForEntry(sourceID: harness.entries[0].id, proposal: nil,
                                                                 failure: .invalidOutput)])
        let result = ManifestValidator(input).validate()
        #expect(result.entries[0].state == .unknown)
        #expect(result.report.allViolations.contains { $0.code == "provider_invalid_output" })
        #expect(result.report.counts.unknown == 1)
    }

    @Test("a batch that drops a file is a coverage failure")
    func droppedEntry() throws {
        let harness = try archive()
        let input = ValidationInput(profile: harness.profile, context: harness.context, entries: harness.entries,
                                    evidence: harness.registry, proposals: [])
        let result = ManifestValidator(input).validate()
        #expect(result.report.allViolations.contains { $0.code == "entry_unanswered" })
    }

    @Test("a proposal naming a source outside the listing is refused")
    func unknownSource() throws {
        let harness = try archive()
        let input = ValidationInput(profile: harness.profile, context: harness.context, entries: harness.entries,
                                    evidence: harness.registry,
                                    proposals: [ProposalForEntry(sourceID: otherID, proposal: proposal())])
        let result = ManifestValidator(input).validate()
        #expect(result.report.allViolations.contains { $0.code == "entry_unknown" })
    }

    @Test("content evidence without an addressable locator is refused")
    func unlocatableContent() throws {
        let harness = try archive()
        let naked = try evidence("ev_naked", source: .content, value: "示例项目_2026 投标文件",
                                 file: harness.entries[0], locator: nil)
        var records = harness.registry[harness.entries[0].id] ?? []
        records.append(naked)
        let answer = proposal(metadata: [.projectname: "示例项目_2026", .completionyear: "2026"],
                             citations: citations([(.projectname, "ev_naked"), (.completionyear, "ev_year"),
                                                   (.documentcategory, "ev_category"), (.documenttype, "ev_type")]))
        let result = validate(harness, answer: answer, evidenceOverride: [harness.entries[0].id: records])
        #expect(result.report.allViolations.contains { $0.code == "locator_invalid" })
    }

    @Test("two excerpts that disagree hold the field instead of picking one")
    func conflictingExcerpts() throws {
        let harness = try archive()
        let second = try evidence("ev_year2", source: .content, value: "归档完成 2025 年",
                                  file: harness.entries[0], locator: .pdf(page: 4, characterRange: 0..<12))
        var records = harness.registry[harness.entries[0].id] ?? []
        records.append(second)
        let answer = proposal(metadata: [.projectname: "示例项目_2026", .completionyear: "2026"],
                             citations: citations([(.projectname, "ev_name"), (.completionyear, "ev_year"),
                                                   (.completionyear, "ev_year2"),
                                                   (.documentcategory, "ev_category"), (.documenttype, "ev_type")]))
        let result = validate(harness, answer: answer, evidenceOverride: [harness.entries[0].id: records])
        #expect(result.report.allViolations.contains { $0.code == "conflicting_evidence" })
        #expect(result.entries[0].metadata[.completionyear] == nil)
        #expect(result.entries[0].state == .hold)
    }

    @Test("an inherited project value names the membership it came from")
    func inheritedProject() throws {
        let harness = try archive()
        let inherited = try evidence("ev_inherit", source: .sibling,
                                     value: "inherited from 示例项目_2026/02_投标/公告.pdf: 示例项目_2026",
                                     file: harness.entries[0], candidate: "c1")
        var records = harness.registry[harness.entries[0].id] ?? []
        records.append(inherited)
        let answer = proposal(metadata: [.projectname: "示例项目_2026", .completionyear: "2026"],
                             citations: citations([(.projectname, "ev_inherit"), (.completionyear, "ev_year"),
                                                   (.documentcategory, "ev_category"), (.documenttype, "ev_type")]))
        let result = validate(harness, answer: answer, evidenceOverride: [harness.entries[0].id: records])
        let outcome = try #require(result.entries[0].outcome(for: .projectname))
        #expect(outcome.status == .inherited)
        // Inheriting a project field is legitimate when membership is confirmed,
        // so eligibility is not refused for that alone.
        #expect(result.entries[0].eligibleForAutoExecution)
        let issuer = result.entries[0].outcome(for: .issuer)
        #expect(issuer?.value == nil, "a document-level field is never inherited")
    }

    @Test("the validator never reports execution authority")
    func noExecutionAuthority() throws {
        let harness = try archive()
        let answer = proposal(metadata: [.projectname: "示例项目_2026", .completionyear: "2026"],
                             citations: citations([(.projectname, "ev_name"), (.completionyear, "ev_year"),
                                                   (.documentcategory, "ev_category"), (.documenttype, "ev_type")]))
        let result = validate(harness, answer: answer)
        #expect(harness.profile.grantsExecution == false)
        // Eligibility is a policy simulation; the manifest itself can never
        // claim the right to write.
        let envelope = ManifestEnvelope(
            manifestID: UUID(), revision: 1, supersedesRevision: nil, scopeID: scopeID, sourceRootID: rootID,
            profile: harness.profile, casePack: ("forma-governance-cases", "1.0"), modelProvider: "anthropic",
            modelID: nil, contextRevision: 1, promptVersion: "mapping.v1",
            extractorVersion: EvidenceRegistry.extractorVersion, redactionVersion: nil,
            inputDigest: String(repeating: "1", count: 64), contextDigest: String(repeating: "2", count: 64),
            createdAt: .now, state: .validated
        )
        let manifest = Manifest(envelope: envelope, entries: result.entries)
        let data = try FormaJSON.encode(manifest)
        let violations = try ArtifactSchemaValidator.manifest.violations(data)
        #expect(violations.isEmpty,
                "a validated manifest must satisfy the artifact schema: \(violations.map { $0.logSummary })")
        #expect(manifest.envelope.grantsExecution == false)
    }
}
