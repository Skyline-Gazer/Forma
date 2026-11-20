import Foundation
import Testing

@testable import FormaCore

/// The category is the one field whose *value* is Forma's own vocabulary: a
/// contract says "招标公告", never "01_招标文件". A reviewer therefore has to be
/// able to confirm the classification from evidence that supports the business
/// judgement, while every other field keeps the strict literal-quote rule and a
/// model still cannot claim a category without the text backing it.
@Suite("Reviewer-confirmed classification")
struct CategoryCorrectionTests {
    private let scopeID = UUID(uuidString: "00000000-0000-4000-8000-000000000080")!
    private let rootID = UUID(uuidString: "00000000-0000-4000-8000-000000000081")!
    private let sourceID = UUID(uuidString: "00000000-0000-4000-8000-000000000082")!
    private let otherSourceID = UUID(uuidString: "00000000-0000-4000-8000-000000000083")!
    private let fingerprint = String(repeating: "a", count: 64)

    private func source(revision: Int64 = 2, fingerprint: String? = nil) -> SourceEntry {
        SourceEntry(id: sourceID, rootID: rootID, relativePath: "示例项目_2026/01_招标/公告.pdf",
                    normalizedRelativePath: "示例项目_2026/01_招标/公告.pdf", state: .present,
                    hydrationPending: false, sourceVersion: 1, snapshotRevision: revision,
                    provider: .local, snapshotFingerprint: fingerprint ?? self.fingerprint,
                    sizeBytes: 10, modificationTimeNanoseconds: 0, sha256: nil)
    }

    /// The excerpt a real tender notice carries: the business words, not the
    /// category identifier.
    private func record(id: String, excerpt: String, revision: Int = 2,
                        fingerprint: String? = nil, sourceID: UUID? = nil,
                        kind: EvidenceSource = .content) -> EvidenceRecord {
        EvidenceRecord(id: id, sourceID: sourceID ?? self.sourceID, snapshotRevision: revision,
                       snapshotFingerprint: fingerprint ?? self.fingerprint, source: kind,
                       locator: kind == .content ? .pdf(page: 1, characterRange: 0..<12) : nil,
                       relativePath: nil, excerpt: excerpt, extractionStatus: .ok,
                       extractorVersion: EvidenceRegistry.extractorVersion, createdAt: .now)
    }

    private func context(_ profile: MappingProfile) -> ProjectContext {
        ProjectContext(revision: 2, scopeID: scopeID, profileID: profile.profileID,
                       profileVersion: profile.profileVersion,
                       inputDigest: String(repeating: "1", count: 64),
                       candidates: [ContextCandidate(id: "c1", projectKey: "示例项目_2026",
                                                     displayName: nil, basis: [.directory],
                                                     memberSourceIDs: [sourceID], confidence: .medium)],
                       unassignedSourceIDs: [], conflictedSourceIDs: [], builtAt: .now)
    }

    /// A draft in the shape the offline planner produces: every field unknown.
    private func draft(_ profile: MappingProfile) -> Manifest {
        let envelope = ManifestEnvelope(
            manifestID: UUID(), revision: 1, supersedesRevision: nil, scopeID: scopeID,
            sourceRootID: rootID, profile: profile, casePack: ("forma-governance-cases", "1.0"),
            modelProvider: "local", modelID: "offline-planner.v1", contextRevision: 2,
            promptVersion: MappingPrompt.version, extractorVersion: EvidenceRegistry.extractorVersion,
            redactionVersion: nil, inputDigest: String(repeating: "2", count: 64),
            contextDigest: String(repeating: "3", count: 64),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), state: .draft)
        var fields: [FieldOutcome] = []
        for field in MetadataFieldID.allCases {
            fields.append(FieldOutcome(field: field, value: nil, status: .unknown, evidenceIDs: []))
        }
        let entry = ManifestEntry(sourceID: sourceID, snapshotFingerprint: fingerprint,
                                  snapshotRevision: 2, sourceVersion: 1,
                                  relativePath: "示例项目_2026/01_招标/公告.pdf", state: .hold,
                                  target: ManifestTarget(databaseName: "Project_Archive",
                                                         groupPath: [], resolved: false),
                                  metadata: .allUnknown, fields: fields)
        return Manifest(envelope: envelope, entries: [entry])
    }

    private func evidence(revision: Int = 2, fingerprint: String? = nil) -> [UUID: [EvidenceRecord]] {
        [sourceID: [
            record(id: "ev_notice", excerpt: "示例项目_2026 招标公告 归档完成 2026 年",
                   revision: revision, fingerprint: fingerprint),
            record(id: "ev_path", excerpt: "示例项目_2026/01_招标", revision: revision,
                   fingerprint: fingerprint, kind: .path),
        ]]
    }

    private func apply(_ engine: CorrectionEngine, to manifest: Manifest, field: MetadataFieldID,
                       value: String?, citations: [String], profile: MappingProfile,
                       evidence rows: [UUID: [EvidenceRecord]],
                       confirmations: [CorrectionRecord] = []) -> CorrectionEngine.Applied {
        engine.apply(to: manifest, sourceID: sourceID, field: field, correctedValue: value,
                     evidenceIDs: citations, origin: .manual, context: context(profile),
                     evidence: rows, currentEntries: [source()],
                     reviewerConfirmations: confirmations)
    }

    @Test("a reviewer can confirm a category from a quote that does not contain its identifier")
    func reviewerConfirmsCategoryFromBusinessQuote() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        let applied = apply(engine, to: draft(profile), field: .documentcategory,
                            value: "01_招标文件", citations: ["ev_notice"], profile: profile,
                            evidence: evidence())

        #expect(applied.violations.isEmpty, "violations: \(applied.violations.map(\.code))")
        let entry = try #require(applied.manifest.entries.first)
        #expect(entry.metadata[.documentcategory] == "01_招标文件")
        let outcome = try #require(entry.outcome(for: .documentcategory))
        #expect(outcome.status == .confirmedByReviewer)
        #expect(outcome.evidenceIDs == ["ev_notice"])
        // The receipt and the revision agree.
        #expect(applied.correction.producedRevision == applied.manifest.envelope.revision)
        #expect(applied.correction.reviewState == .evidenceVerified)
    }

    @Test("a model answer gets no exemption: the same quote cannot carry a category")
    func modelAnswerStillNeedsTheLiteralValue() throws {
        let profile = try MappingProfile.projectArchive()
        let rows = evidence()
        // The validator reads values from `metadata`, so the model answer has to
        // put the category there as well.
        var metadata = MetadataValues.allUnknown
        metadata[.documentcategory] = "01_招标文件"
        let proposal = ProposalEntry(
            entryRef: "e1", projectAssociation: .init(candidateRef: nil, state: .unconfirmed),
            documentCategory: "01_招标文件", documentType: nil, metadata: metadata,
            evidence: [EvidenceCitation(field: .documentcategory, evidenceID: "ev_notice")],
            unknownFields: [], conflicts: [], confidence: .high,
            reasoning: "model guessed the category")
        let input = ValidationInput(
            profile: profile, context: context(profile), entries: [source()], evidence: rows,
            proposals: [ProposalForEntry(sourceID: sourceID, proposal: proposal)])
        let result = ManifestValidator(input).validate()

        let entry = try #require(result.entries.first)
        // Without a reviewer confirmation the literal-quote rule applies, so the
        // value is rejected exactly as before.
        #expect(entry.metadata[.documentcategory] == nil)
        // Rejected by the field policy, whichever rule caught it: without a
        // reviewer confirmation a model answer cannot carry a category.
        #expect(entry.outcome(for: .documentcategory)?.status == .rejectedByPolicy)
    }

    @Test("evidence from an older snapshot is refused")
    func oldSnapshotCitationIsRefused() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        let applied = apply(engine, to: draft(profile), field: .documentcategory,
                            value: "01_招标文件", citations: ["ev_notice"], profile: profile,
                            evidence: evidence(revision: 1))

        #expect(applied.violations.contains { $0.code == "evidence_not_found" })
        #expect(applied.correction.reviewState == .rejected)
        #expect(applied.correction.producedRevision == nil)
        #expect(applied.manifest.entries.first?.metadata[.documentcategory] == nil)
    }

    @Test("evidence belonging to another source is refused")
    func foreignSourceCitationIsRefused() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        let rows: [UUID: [EvidenceRecord]] = [sourceID: [
            record(id: "ev_foreign", excerpt: "别的文件 招标公告", sourceID: otherSourceID),
        ]]
        let applied = apply(engine, to: draft(profile), field: .documentcategory,
                            value: "01_招标文件", citations: ["ev_foreign"], profile: profile,
                            evidence: rows)

        #expect(applied.violations.contains { $0.code == "evidence_not_found" })
        #expect(applied.correction.reviewState == .rejected)
    }

    @Test("a category outside the profile is refused")
    func unknownCategoryIsRefused() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        let applied = apply(engine, to: draft(profile), field: .documentcategory,
                            value: "07_其他", citations: ["ev_notice"], profile: profile,
                            evidence: evidence())

        #expect(applied.violations.contains { $0.code == "category_unknown" })
        #expect(applied.correction.reviewState == .rejected)
        #expect(applied.manifest.entries.first?.metadata[.documentcategory] == nil)
    }

    @Test("classifying one field does not relax the others")
    func otherFieldsKeepTheStrictRule() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        // The completion year "2026" does appear in the quote, so it lands; a
        // year that is not in the text must still be refused.
        let appliedCategory = apply(engine, to: draft(profile), field: .documentcategory,
                                    value: "01_招标文件", citations: ["ev_notice"],
                                    profile: profile, evidence: evidence())
        let wrongYear = apply(engine, to: appliedCategory.manifest, field: .completionyear,
                              value: "2019", citations: ["ev_notice"], profile: profile,
                              evidence: evidence())
        #expect(wrongYear.violations.contains { $0.code == "quote_mismatch" })
        #expect(wrongYear.correction.reviewState == .rejected)
        // The earlier classification is untouched by the refused attempt.
        #expect(wrongYear.manifest.entries.first?.metadata[.documentcategory] == "01_招标文件")
    }

    @Test("a confirmed category survives a later correction")
    func classificationSurvivesLaterCorrections() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        let first = apply(engine, to: draft(profile), field: .documentcategory,
                          value: "01_招标文件", citations: ["ev_notice"], profile: profile,
                          evidence: evidence())
        #expect(first.violations.isEmpty, "violations: \(first.violations.map(\.code))")
        // The later correction is made against the decision the store verified,
        // not against a status in the manifest.
        let second = apply(engine, to: first.manifest, field: .completionyear,
                           value: "2026", citations: ["ev_notice"], profile: profile, evidence: evidence(),
                           confirmations: [first.correction])

        #expect(second.violations.isEmpty)
        let entry = try #require(second.manifest.entries.first)
        #expect(entry.metadata[.documentcategory] == "01_招标文件")
        #expect(entry.outcome(for: .documentcategory)?.status == .confirmedByReviewer)
        #expect(entry.metadata[.completionyear] == "2026")
        // The project name is still unknown, so the entry is not validated yet.
        #expect(entry.state != .validated)
    }

    @Test("a classification does not follow the file into a new snapshot")
    func confirmationDoesNotSurviveANewSnapshot() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        let first = apply(engine, to: draft(profile), field: .documentcategory,
                          value: "01_招标文件", citations: ["ev_notice"], profile: profile,
                          evidence: evidence())
        #expect(first.violations.isEmpty, "violations: \(first.violations.map(\.code))")
        // The file moved. The entry now describes revision 3, while the
        // classification still rests on the row of revision 2 - the decision
        // was made against bytes that are no longer the file.
        let rows: [UUID: [EvidenceRecord]] = [sourceID: [
            record(id: "ev_notice", excerpt: "示例项目_2026 招标公告 归档完成 2026 年", revision: 2),
            record(id: "ev_new", excerpt: "示例项目_2026 招标公告 归档完成 2027 年", revision: 3),
        ]]
        var moved = first.manifest
        let original = try #require(moved.entries.first)
        moved.entries[0] = ManifestEntry(sourceID: original.sourceID,
                                         snapshotFingerprint: original.snapshotFingerprint,
                                         snapshotRevision: 3, sourceVersion: original.sourceVersion,
                                         relativePath: original.relativePath, state: original.state,
                                         target: original.target, metadata: original.metadata,
                                         fields: original.fields, associations: original.associations,
                                         eligibleForAutoExecution: original.eligibleForAutoExecution)
        let applied = engine.apply(to: moved, sourceID: sourceID, field: .completionyear,
                                   correctedValue: "2027", evidenceIDs: ["ev_new"], origin: .manual,
                                   context: context(profile), evidence: rows,
                                   currentEntries: [source(revision: 3)],
                                   reviewerConfirmations: [first.correction])

        #expect(applied.violations.isEmpty, "the correction itself is sound: \(applied.violations.map(\.code))")
        let entry = try #require(applied.manifest.entries.first)
        #expect(entry.metadata[.completionyear] == "2027")
        // The confirmation was real, and it was made against revision 2. The
        // exemption it buys is from the literal-quote rule, not from the
        // requirement that the evidence still describes this file.
        #expect(entry.metadata[.documentcategory] == nil,
                "a classification belongs to the snapshot it was made against")
        #expect(entry.outcome(for: .documentcategory)?.status == .rejectedByPolicy)
    }

    @Test("a manifest that only claims the status gets no exemption")
    func claimedStatusIsNotAConfirmation() throws {
        let profile = try MappingProfile.projectArchive()
        let engine = CorrectionEngine(profile: profile)
        // A manifest that says the classification was reviewed, without the
        // decision that says so. The status is what a review leaves behind, not
        // the proof of one, and a manifest that arrived from elsewhere could
        // claim it for itself.
        var manifest = draft(profile)
        var metadata = manifest.entries[0].metadata
        metadata[.documentcategory] = "01_招标文件"
        manifest.entries[0].metadata = metadata
        manifest.entries[0].setOutcome(FieldOutcome(field: .documentcategory, value: "01_招标文件",
                                                     status: .confirmedByReviewer,
                                                     evidenceIDs: ["ev_notice"]))
        let applied = apply(engine, to: manifest, field: .completionyear,
                            value: "2026", citations: ["ev_notice"], profile: profile, evidence: evidence())

        #expect(applied.violations.isEmpty, "the correction itself is sound: \(applied.violations.map(\.code))")
        let entry = try #require(applied.manifest.entries.first)
        #expect(entry.metadata[.completionyear] == "2026")
        #expect(entry.metadata[.documentcategory] == nil,
                "a claimed status is not a review: the category still needs its decision")
        #expect(entry.outcome(for: .documentcategory)?.status == .rejectedByPolicy)
    }
}
