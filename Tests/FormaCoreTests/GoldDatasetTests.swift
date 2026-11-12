import Foundation
import Testing

@testable import FormaCore

/// The measurement set's own integrity: a number computed over records the
/// model may have seen, or over a split nobody can re-derive, is not evidence.
@Suite("Gold dataset")
struct GoldDatasetTests {
    private static let revision = "1.0.0"

    /// Every one of the twelve slots has to be present, including the empty
    /// ones: assigning `nil` into `[Key: String?]` removes the key rather than
    /// storing a null, so the map is built from the case list directly.
    private func metadata(_ values: [MetadataFieldID: String?] = [:]) throws -> MetadataValues {
        try MetadataValues(Dictionary(uniqueKeysWithValues: MetadataFieldID.allCases.map {
            ($0, values[$0] ?? nil)
        }))
    }

    /// Built through the encoder/decoder pair, so every domain rule in
    /// `GoldRecord.check` runs exactly as it does for a file on disk - a
    /// hand-assembled struct would let a test assert against a record that
    /// could never load.
    private func record(_ id: String,
                        category: GoldRecord.Category = .positive,
                        profiles: [String] = [ProjectArchiveContract.id],
                        cluster: String? = nil,
                        uuid: String? = nil,
                        sha: String? = nil,
                        filename: String,
                        path: String? = nil,
                        nearGroup: String? = nil,
                        status: GoldRecord.ReviewStatus = .confirmed,
                        redaction: GoldRecord.Redaction = .reviewed,
                        usage: GoldRecord.Usage = .evaluation,
                        revision: String = GoldDatasetTests.revision,
                        citations: Int = 1) throws -> GoldRecord {
        let built = try GoldRecord(
            recordID: id,
            datasetRevision: revision,
            profiles: profiles,
            scenario: .init(category: category, description: "synthetic scenario for " + id),
            source: .init(projectClusterKey: cluster ?? "cluster-" + id, sourceUUID: uuid, sha256: sha,
                          redactedRelativePath: path ?? "synthetic/\(id)/" + filename,
                          redactedFilename: filename, nearDuplicateGroup: nearGroup),
            expected: .init(state: .mapped, projectReference: "PRJ-A", targetCategory: "项目档案",
                            targetType: "投标书", metadata: try metadata(), allowedUnknownFields: []),
            citations: citations > 0
                ? (1...citations).map { .init(label: "cite-\($0)", excerpt: "脱敏正文片段 \($0)", locator: nil) }
                : [],
            annotation: .init(annotatorCode: "A1", annotatedOn: "2026-11-12", basis: "verified_document_text"),
            review: .init(status: status, redaction: redaction, reviewerCode: "R1", reviewedOn: "2026-11-12"),
            usage: usage)
        return try FormaJSON.decode(GoldRecord.self, from: FormaJSON.encoder(pretty: true).encode(built))
    }

    private func split(evaluation: [String], prompt: [String] = [], removed: [GoldSplit.Removal] = [],
                       revision: String = GoldDatasetTests.revision) throws -> GoldSplit {
        try GoldSplit(splitID: "split-test", datasetRevision: revision, generatedOn: "2026-11-12",
                  casePack: .init(id: "forma-governance-cases", version: "1.0"),
                  promptRecordIDs: Set(prompt), evaluationRecordIDs: Set(evaluation),
                  removed: removed, notes: nil)
    }

    private func dataset(records: [GoldRecord], split: GoldSplit) throws -> GoldDataset {
        try GoldDataset(records: records, split: split, casePack: try CasePack.shipped())
    }

    @Test("a short dataset reports its gaps instead of passing")
    func gapReporting() throws {
        let records = try (1...12).map { try record("g\($0)", filename: "gap-case-\($0).docx") }
        let subject = try dataset(records: records, split: split(evaluation: records.map(\.recordID)))
        let report = subject.report()

        #expect(report.countableRecords == 12)
        #expect(report.reviewedCountable == 12)
        #expect(!report.meetsIndependentTarget)
        #expect(report.requiredMinimum == GoldDataset.independentTarget)
        // Twelve positives cannot cover the counter-example strata: every other
        // category has to show up as short, or the report hides the thinness it
        // exists to disclose.
        let short = Set(report.shortfalls.map { "\($0.profile)/\($0.category.rawValue)" })
        for category in GoldRecord.Category.allCases where category != .positive {
            #expect(short.contains("\(ProjectArchiveContract.id)/\(category.rawValue)"))
        }
        #expect(report.shortfalls.allSatisfy { $0.required == GoldDataset.stratumTarget })
        // Both profiles are enumerated even though every record names one: a
        // vendor-library gap is invisible if only observed profiles are listed.
        #expect(Set(report.shortfalls.map(\.profile)) == [ProjectArchiveContract.id, VendorLibraryContract.id])
    }

    @Test("one hundred and fifty confirmed records reach the independent target")
    func meetsTarget() throws {
        let records = try (1...150).map { try record("g\($0)", filename: "full-case-\($0).docx") }
        let subject = try dataset(records: records, split: split(evaluation: records.map(\.recordID)))
        #expect(subject.report().countableRecords == 150)
        #expect(subject.report().reviewedCountable == 150)
        #expect(subject.report().meetsIndependentTarget)
    }

    @Test("synthetic rows exercise the harness but cannot certify the target")
    func syntheticCannotCertify() throws {
        let synthetic = try (1...150).map {
            try record("s\($0)", filename: "synthetic-case-\($0).docx", redaction: .synthetic)
        }
        let report = try dataset(records: synthetic, split: try split(evaluation: synthetic.map(\.recordID)))
            .report()

        // All one hundred and fifty are usable: confirmed, cited, split-clean.
        // What they cannot do is meet PLAN §8.1's independent sample requirement,
        // which is about real business material verified by a person.
        #expect(report.countableRecords == 150)
        #expect(report.reviewedCountable == 0)
        #expect(!report.meetsIndependentTarget)
    }

    @Test("a disputed record leaves the denominator and stays in the count")
    func pendingAdjudication() throws {
        let kept = try record("kept", filename: "kept-case.docx")
        let disputed = try record("disputed", filename: "disputed-case.docx", status: .adjudicationPending)
        let subject = try dataset(records: [kept, disputed], split: split(evaluation: ["kept", "disputed"]))
        let report = subject.report()

        #expect(report.evaluationRecords == 2)
        #expect(report.countableRecords == 1)
        #expect(report.pendingAdjudication == 1)
    }

    @Test("a filename family shared with the pack is excluded and named")
    func promptFamilyLeak() throws {
        let taught = try CasePack.shipped().cases[0]
        let colliding = try record("leak", filename: taught.input.redactedFilename)
        let other = try record("other", filename: "unrelated-case.docx")
        let subject = try dataset(records: [colliding, other],
                                  split: try split(evaluation: ["leak", "other"], prompt: [taught.caseID]))

        // Both halves of the consequence: the record leaves every denominator,
        // and the report says which record leaked through which axis.
        #expect(subject.countableIDs == ["other"])
        #expect(subject.report().undeclaredOverlaps == ["leak~" + taught.caseID + ":[family]"])
        #expect(subject.report().countableRecords == 1)
    }

    @Test("a leak declared away is no longer in the evaluation set at all")
    func properlyRemovedLeak() throws {
        let taught = try CasePack.shipped().cases[0]
        let colliding = try record("leak", filename: taught.input.redactedFilename)
        let other = try record("other", filename: "unrelated-case.docx")
        let honest = try split(evaluation: ["other"], prompt: [taught.caseID],
                               removed: [.init(recordID: "leak", reason: .promptFilenameFamilyOverlap,
                                               counterpartyRecordID: taught.caseID)])
        let subject = try dataset(records: [colliding, other], split: honest)

        #expect(subject.report().undeclaredOverlaps.isEmpty)
        #expect(subject.countableIDs == ["other"])
        // A record cannot be both scored and withdrawn: the contradiction is
        // refused rather than silently resolved in favour of the evaluation list.
        #expect(throws: FormaError.incompatible) {
            try dataset(records: [colliding, other],
                        split: try split(evaluation: ["leak", "other"], prompt: [taught.caseID],
                                         removed: [.init(recordID: "leak",
                                                         reason: .promptFilenameFamilyOverlap,
                                                         counterpartyRecordID: taught.caseID)]))
        }
    }

    @Test("a hash overlap names the axis that collided")
    func hashOverlapAxis() throws {
        let digest = String(repeating: "a", count: 64)
        let taught = try record("taught", sha: digest, filename: "taught.docx", usage: .fewshot)
        let evaluation = try record("scored", sha: digest, filename: "scored.docx")
        let subject = try dataset(records: [taught, evaluation],
                                  split: try split(evaluation: ["scored"], prompt: ["taught"]))
        // Names never match here, so only the hash could reveal the leak - and
        // the report has to say which axis it was, not just that something is off.
        #expect(subject.report().undeclaredOverlaps == ["scored~taught:[sha]"])
        #expect(subject.countableIDs.isEmpty)
    }

    @Test("the shipped pack can only be matched by filename family")
    func packAxesAreLimited() throws {
        let taught = try CasePack.shipped().cases[0]
        // Nothing name-wise connects these two, and the pack states a relative
        // path that does match - yet the record is not flagged, because a pack
        // case carries no cluster key, UUID or hash. Cluster isolation between
        // gold and the shipped pack is a property of how the dataset was built,
        // not something FormaCore can prove here. Pinning the limit stops a later
        // reader from taking a clean overlap list as proof of separation.
        let distant = try record("distant", cluster: "cluster-" + taught.caseID,
                                 filename: "entirely-other-name.docx",
                                 path: taught.input.redactedRelativePath)
        let subject = try dataset(records: [distant],
                                  split: try split(evaluation: ["distant"], prompt: [taught.caseID]))
        #expect(subject.report().undeclaredOverlaps.isEmpty)
        #expect(subject.countableIDs == ["distant"])
    }

    @Test("a cluster collision is caught even when names differ completely")
    func clusterIsolation() throws {
        let taught = try record("taught", cluster: "shared-cluster", filename: "one.docx", usage: .fewshot)
        let evaluation = try record("scored", cluster: "shared-cluster", filename: "two.docx")
        let subject = try dataset(records: [taught, evaluation],
                                  split: split(evaluation: ["scored"], prompt: ["taught"]))
        #expect(subject.countableIDs.isEmpty)
        #expect(subject.report().undeclaredOverlaps == ["scored~taught:[cluster]"])
    }

    @Test("a renamed copy of the same document is a leak")
    func renamedCopy() throws {
        let taught = try record("taught", filename: "投标报告 v2.docx", usage: .fewshot)
        let copy = try record("scored", filename: "投标报告 副本(最终).docx")
        #expect(GoldRecord.filenameFamily(of: "投标报告 v2.docx")
                == GoldRecord.filenameFamily(of: "投标报告 副本(最终).docx"))
        let subject = try dataset(records: [taught, copy], split: split(evaluation: ["scored"], prompt: ["taught"]))
        #expect(subject.countableIDs.isEmpty)
    }

    @Test("a record the split never decided about is reported, not ignored")
    func unaccountedRecord() throws {
        let scored = try record("scored", filename: "scored.docx")
        let forgotten = try record("forgotten", filename: "forgotten.docx")
        let subject = try dataset(records: [scored, forgotten], split: split(evaluation: ["scored"]))

        // An absent decision is not a negative decision: the file sits in the
        // directory, contributes to no denominator, and would leave the ledger
        // unreproducible for anyone recomputing it from the manifest.
        #expect(subject.report().unaccountedRecords == ["forgotten"])
        #expect(subject.countableIDs == ["scored"])

        // Listing it anywhere - scored, prompt-side or withdrawn - closes it.
        let withdrawn = try dataset(records: [scored, forgotten],
                                    split: split(evaluation: ["scored"],
                                                 removed: [.init(recordID: "forgotten",
                                                                 reason: .adjudicationUnresolved,
                                                                 counterpartyRecordID: nil)]))
        #expect(withdrawn.report().unaccountedRecords.isEmpty)
        // Withdrawing it also means it is scored by nobody, so no denominator
        // may quietly grow: only `scored` remains countable.
        #expect(withdrawn.countableIDs == ["scored"])
    }

    @Test("one record cannot be both taught and scored")
    func splitOnBothSides() throws {
        let both = try record("g1", filename: "one.docx")
        #expect(throws: FormaError.incompatible) {
            try dataset(records: [both], split: split(evaluation: ["g1"], prompt: ["g1"]))
        }
    }

    @Test("a removed record may not also sit in the evaluation set")
    func removalStillListed() throws {
        let g = try record("g1", filename: "one.docx")
        #expect(throws: FormaError.incompatible) {
            try dataset(records: [g], split: split(evaluation: ["g1"],
                                                   removed: [.init(recordID: "g1", reason: .nearDuplicate,
                                                                   counterpartyRecordID: nil)]))
        }
    }

    @Test("a manifest naming a record the directory does not hold is refused")
    func manifestOverstates() throws {
        let g = try record("g1", filename: "one.docx")
        #expect(throws: FormaError.invalidSource) {
            try dataset(records: [g], split: split(evaluation: ["g1", "g2"]))
        }
    }

    @Test("a prompt id that belongs to nothing is refused")
    func danglingPromptID() throws {
        let g = try record("g1", filename: "one.docx")
        #expect(throws: FormaError.invalidSource) {
            try dataset(records: [g], split: split(evaluation: ["g1"], prompt: ["ghost"]))
        }
    }

    @Test("mixing dataset revisions in one split is refused")
    func revisionDrift() throws {
        let current = try record("g1", filename: "one.docx")
        let stale = try record("g2", filename: "two.docx", revision: "0.9.0")
        #expect(throws: FormaError.incompatible) {
            try dataset(records: [current, stale], split: split(evaluation: ["g1", "g2"]))
        }
    }

    @Test("duplicate record ids are refused")
    func duplicateIDs() throws {
        let a = try record("g1", filename: "one.docx")
        let b = try record("g1", filename: "two.docx")
        #expect(throws: FormaError.invalidOutput) {
            try dataset(records: [a, b], split: split(evaluation: ["g1"]))
        }
    }

    @Test("an unredacted record cannot be decoded at all")
    func unredactedRefused() throws {
        #expect(throws: FormaError.incompatible) {
            try record("g1", filename: "one.docx", redaction: .unredacted)
        }
    }

    @Test("a rejected answer cannot claim evaluation use")
    func rejectedAsEvaluation() throws {
        #expect(throws: FormaError.incompatible) {
            try record("g1", filename: "one.docx", status: .rejected)
        }
        // Rejected and marked out of scope is the audit trail PLAN asks to keep.
        let history = try record("g1", filename: "one.docx", status: .rejected, usage: .excluded)
        #expect(history.review.status == .rejected)
        #expect(!history.isCountable)
    }

    @Test("a record without citations cannot be scored")
    func answerNeedsEvidence() throws {
        #expect(throws: FormaError.incompatible) { try record("g1", filename: "one.docx", citations: 0) }
    }

    // MARK: - File layout and schema

    @Test("a directory written in the documented layout loads and reports")
    func loadsFromDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("forma-gold-\(UUID().uuidString)", isDirectory: true)
        let recordsDir = dir.appendingPathComponent("records", isDirectory: true)
        try FileManager.default.createDirectory(at: recordsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let encoder = FormaJSON.encoder(pretty: true)
        let kept = try record("kept", uuid: "U-1", sha: String(repeating: "c", count: 64),
                              filename: "disk-only-kept.docx")
        let disputed = try record("disputed", filename: "disk-only-disputed.docx",
                                  status: .adjudicationPending)
        try encoder.encode(kept).write(to: recordsDir.appendingPathComponent("kept.json"))
        try encoder.encode(disputed).write(to: recordsDir.appendingPathComponent("disputed.json"))
        try encoder.encode(split(evaluation: ["kept", "disputed"]))
            .write(to: dir.appendingPathComponent("split-manifest.json"))

        let report = try GoldDataset.load(directory: dir).report()
        #expect(report.totalRecords == 2)
        #expect(report.countableRecords == 1)
        #expect(report.pendingAdjudication == 1)
        #expect(report.datasetRevision == GoldDatasetTests.revision)
    }

    @Test("a missing split manifest is refused rather than guessed")
    func missingManifest() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("forma-gold-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("records", isDirectory: true),
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: FormaError.invalidSource) { try GoldDataset.load(directory: dir) }
    }

    @Test("the schema refuses an invented thirteenth metadata slot")
    func schemaRejectsExtraField() throws {
        let clean = try FormaJSON.encoder(pretty: true).encode(try record("g1", filename: "one.docx"))
        // The thirteenth slot is injected through the parsed object, so the test
        // does not depend on how the encoder happens to space its nulls.
        // Injected before the key rather than after the value: `prettyPrinted`
        // writes `"issuer" : null`, with a space the standard library owns and
        // this test must not assume. Inserting at the key keeps valid JSON for
        // either spacing.
        let text = String(data: clean, encoding: .utf8) ?? ""
        let polluted = text.replacingOccurrences(of: "\"issuer\"",
                                                 with: "\"customercontact\": null, \"issuer\"")
        #expect(polluted != text)

        let extraSlot = try ArtifactSchemaValidator.goldRecord.violations(Data(polluted.utf8))
        #expect(!extraSlot.isEmpty)
        // The same record before the injection is schema-clean, so the assertion
        // above is not passing for an unrelated reason.
        #expect(text.contains("\"issuer\""))
        let cleanViolations = try ArtifactSchemaValidator.goldRecord.violations(clean)
        #expect(cleanViolations.isEmpty)
    }

    @Test("the split schema is the one the encoder satisfies")
    func splitSchemaKeys() throws {
        let manifest = try split(evaluation: ["a"], prompt: ["b"])
        let data = try FormaJSON.encoder(pretty: true).encode(manifest)
        #expect(try ArtifactSchemaValidator.goldSplit.violations(data).isEmpty)
        let text = String(data: data, encoding: .utf8) ?? ""
        let broken = text.replacingOccurrences(of: "\"generated_on\"", with: "\"generated_at\"")
        let renamed = try ArtifactSchemaValidator.goldSplit.violations(Data(broken.utf8))
        #expect(!renamed.isEmpty)
    }

    @Test("a gold record round-trips through its documented keys")
    func roundTrip() throws {
        let original = try record("g1", profiles: [ProjectArchiveContract.id, VendorLibraryContract.id],
                                  uuid: "U-1", sha: String(repeating: "d", count: 64),
                                  filename: "one.docx", nearGroup: "nd-1")
        let data = try FormaJSON.encoder(pretty: true).encode(original)
        let decoded = try FormaJSON.decode(GoldRecord.self, from: data)
        #expect(decoded == original)
        let json = String(data: data, encoding: .utf8) ?? ""
        for key in ["record_id", "dataset_revision", "project_cluster_key", "sha256", "annotator_code",
                    "reviewer_code", "allowed_unknown_fields", "near_duplicate_group", "target_type"] {
            #expect(json.contains("\"" + key + "\""))
        }
        // Two profiles is one record counted in both strata, never two records.
        #expect(Set(decoded.profiles).count == 2)
    }

    @Test("two axes colliding with one counterpart is one leak, reported once")
    func multipleAxesAggregate() throws {
        // Same cluster, same filename family, and both records carry the same
        // hash: three axes match one counterpart. Before aggregation this
        // printed three rows and read like three leaks.
        let digest = String(repeating: "b", count: 64)
        let taught = try record("taught", cluster: "shared", sha: digest, filename: "报告.docx", usage: .fewshot)
        let scored = try record("scored", cluster: "shared", sha: digest, filename: "报告 副本.docx")
        let subject = try dataset(records: [taught, scored],
                                  split: try split(evaluation: ["scored"], prompt: ["taught"]))
        // Three axes match - cluster, hash, and the filename family after the
        // copy marker is stripped - and they must collapse into one row.
        #expect(subject.report().undeclaredOverlaps == ["scored~taught:[cluster,family,sha]"])
        #expect(subject.countableIDs.isEmpty)
    }

    @Test("a record cannot be both prompt-side and withdrawn")
    func promptAndRemovedClash() throws {
        let fewshot = try record("taught", filename: "taught.docx", usage: .fewshot)
        let scored = try record("scored", filename: "scored.docx")
        #expect(throws: FormaError.incompatible) {
            try split(evaluation: ["scored"], prompt: ["taught"],
                      removed: [.init(recordID: "taught", reason: .adjudicationUnresolved,
                                      counterpartyRecordID: nil)])
        }
        // The three lists partition the dataset, which is what lets the report
        // claim a record was left undecided rather than merely unseen.
        let honest = try split(evaluation: ["scored"], prompt: ["taught"])
        #expect(try dataset(records: [fewshot, scored], split: honest).report().unaccountedRecords.isEmpty)
    }
}
