import CryptoKit
import Foundation

// A synthetic dataset at the sizes the runner has to survive, built the way a real
// dataset is built.
//
// Three rules make this a benchmark fixture rather than a second mapping engine:
//
// 1. It produces `GoldRecord`s and a `GoldSplit` and hands them to `GoldDataset`,
//    so the split check, the leak check, the countable set and every denominator
//    are the production ones. Nothing here re-implements a rule that
//    `GoldDataset` or `MappingEngine` already owns.
// 2. It is derived, not random: the spec (counts, seed, version) is the whole
//    input, the order of generation is fixed, and no wall clock or process state
//    enters a record. Two processes given the same spec produce byte-identical
//    ids, clusters and splits, so a request digest means the same thing twice.
// 3. It is synthetic on its face: paths live under `synthetic/`, no file is read,
//    no hash is claimed (`sha256` is nil because nobody measured one), and the
//    review record says `synthetic`. A fixture that looked like a customer's
//    archive would be a privacy incident waiting for a copy-paste.
//
// What the fixture varies on purpose: cluster count (the engine's grouping unit),
// field sparsity (which decides how many evidence rows a record has), category and
// document type (the strata a report slices by), and the three boundary lists
// (evaluation / prompt-side / withdrawn) that decide the denominators. Batch size
// is not a fixture property: it is `MappingEngine.plannedBatches`' own limit.
public enum EvaluationBenchmarkFixture {
    /// Bumped when the record shape changes, because a fixture is only comparable
    /// to another fixture of the same version.
    public static let version = "bench-1.0.0"

    /// The whole input to a fixture, and therefore its identity.
    public struct Spec: Codable, Sendable, Equatable {
        /// Evaluation records: the ones that may enter a denominator.
        public let recordCount: Int
        /// Project clusters the evaluation records are spread over.
        public let clusterCount: Int
        /// Few-shot records: listed on the prompt side, never countable.
        public let promptRecordCount: Int
        /// Withdrawn records: named by the split, never countable.
        public let removedRecordCount: Int
        public let seed: UInt64
        public let version: String

        enum CodingKeys: String, CodingKey {
            case recordCount = "record_count", clusterCount = "cluster_count"
            case promptRecordCount = "prompt_record_count", removedRecordCount = "removed_record_count"
            case seed, version
        }

        public init(recordCount: Int, clusterCount: Int, promptRecordCount: Int = 0,
                    removedRecordCount: Int = 0, seed: UInt64 = 0x9E37_79B9_7F4A_7C15,
                    version: String = EvaluationBenchmarkFixture.version) {
            self.recordCount = max(0, recordCount)
            self.clusterCount = max(1, clusterCount)
            self.promptRecordCount = max(0, promptRecordCount)
            self.removedRecordCount = max(0, removedRecordCount)
            self.seed = seed
            self.version = version
        }

        /// The identity material. Order is fixed, so the digest is comparable
        /// across processes and across machines.
        public var material: String {
            "forma.benchmark.fixture.v1|\(version)|\(recordCount)|\(clusterCount)|\(promptRecordCount)"
                + "|\(removedRecordCount)|\(seed)"
        }

        public var id: String { EvaluationBenchmarkFixture.digest(material) }

        /// Total records handed to `GoldDataset`, boundary lists included.
        public var totalRecordCount: Int { recordCount + promptRecordCount + removedRecordCount }
    }

    /// A built fixture: the dataset, its identity, and what building it cost.
    public struct Fixture: Sendable {
        public let spec: Spec
        public let dataset: GoldDataset
        /// Spec identity. Two fixtures with the same id asked the same question,
        /// whatever machine built them.
        public let fixtureID: String
        /// Harness cost, measured here rather than inside the run: a fixture that
        /// took ten seconds must not read as a slow request path.
        public let constructionMilliseconds: Int
        /// Records the split counts as scoreable. Published so a benchmark result
        /// can check `telemetry.sampleCount` against it instead of assuming.
        public let countableRecords: Int
    }

    /// The categories the shipped Project Archive Profile accepts, in Profile
    /// order. A fixture value outside this list would be rejected by the validator
    /// and quietly turn every record into a hold, which is not a benchmark.
    private static let categories = [
        "01_招标文件", "02_投标文件", "03_厂商支持文件", "04_技术资料与编制素材", "05_报价与商务",
    ]

    /// A subset of the Profile's document types, in Profile order.
    private static let documentTypes = [
        "Tender Announcement", "Procurement Requirement", "Bid Document", "Commercial Volume",
        "Price Volume", "Technical Response Table",
    ]

    /// The optional slots a sparse record leaves empty. `documenttype` is the
    /// interesting one: the stand-in and the reference answer agree on it when it
    /// is present, so a withheld slot is a measurement rather than a defect.
    private static let sparseSlots: [MetadataFieldID] = [.documenttype, .biddeadline, .tenderreference, .issuer]

    public static func build(_ spec: Spec) throws -> Fixture {
        let start = EvaluationStageTimings.now()
        let pack = try CasePack.shipped()
        var records: [GoldRecord] = []
        var index = 0

        for _ in 0..<spec.recordCount {
            records.append(try record(index: index, kind: .evaluation, spec: spec))
            index += 1
        }
        for _ in 0..<spec.promptRecordCount {
            records.append(try record(index: index, kind: .prompt, spec: spec))
            index += 1
        }
        for _ in 0..<spec.removedRecordCount {
            records.append(try record(index: index, kind: .withdrawn, spec: spec))
            index += 1
        }

        let evaluation = Set(records.prefix(spec.recordCount).map(\.recordID))
        let prompt = Set(records.dropFirst(spec.recordCount).prefix(spec.promptRecordCount).map(\.recordID))
        let withdrawn = records.suffix(spec.removedRecordCount)
        let split = try GoldSplit(
            splitID: "bench-split", datasetRevision: spec.version, generatedOn: "2026-11-12",
            casePack: .init(id: pack.id, version: pack.version),
            promptRecordIDs: prompt, evaluationRecordIDs: evaluation,
            removed: withdrawn.map { GoldSplit.Removal(recordID: $0.recordID,
                                                       reason: $0.scenario.category == .negative
                                                           ? .privacyReviewFailed : .adjudicationUnresolved,
                                                       counterpartyRecordID: nil) },
            notes: "synthetic benchmark fixture; not a real dataset")

        let dataset = try GoldDataset(records: records, split: split, casePack: pack)
        return Fixture(spec: spec, dataset: dataset, fixtureID: spec.id,
                       constructionMilliseconds: EvaluationStageTimings.milliseconds(from: start),
                       countableRecords: dataset.countableIDs.count)
    }

    // MARK: - Record construction

    private static func record(index: Int, kind: FixtureRecordKind, spec: Spec) throws -> GoldRecord {
        // One generator per record, seeded from the spec and the record's own
        // index: a record's fields do not depend on how many records came before
        // it, so a record can be regenerated or inspected on its own.
        var generator = SplitMix64(seed: spec.seed ^ UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
        let draw = { Double(generator.next() >> 11) / Double(1 << 53) }

        let digits = String(index)
        let recordID = "bench-\(kind.prefix)-" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
        // Prompt-side records use their own cluster space: a shared cluster key
        // would make every evaluation record in that cluster a leak, and the
        // fixture would measure an empty denominator instead of a big one.
        let clusterKey: String
        switch kind {
        case .prompt: clusterKey = "bench-prompt-cluster-\(index % spec.clusterCount)"
        case .evaluation, .withdrawn: clusterKey = "bench-cluster-\(index % spec.clusterCount)"
        }
        let category = categories[index % categories.count]
        let documentType = documentTypes[index % documentTypes.count]
        // Sparsity is drawn from the spec's seed, so the seed changes the logical
        // input rather than just the fixture label: roughly a third of records
        // state no document type, and a quarter also leave the optional project
        // slots empty. Both are legal reference answers - the validator only
        // requires the three validated slots.
        let withholdsType = draw() < 1.0 / 3.0
        let withholdsProjectSlots = draw() < 0.25
        let completionYear = 2015 + index % 11

        var metadata = MetadataValues.allUnknown
        metadata[.projectname] = "合成项目_\(clusterKey)"
        metadata[.completionyear] = String(completionYear)
        metadata[.documentcategory] = category
        if !withholdsType { metadata[.documenttype] = documentType }
        if !withholdsProjectSlots {
            metadata[.biddeadline] = "2026-01-01"
            metadata[.tenderreference] = "BENCH-\(index)"
        }
        var allowedUnknown: Set<MetadataFieldID> = []
        for slot in sparseSlots where metadata[slot] == nil { allowedUnknown.insert(slot) }

        let usage: GoldRecord.Usage
        switch kind {
        case .evaluation, .withdrawn: usage = .evaluation
        case .prompt: usage = .fewshot
        }

        return try GoldRecord(
            recordID: recordID, datasetRevision: spec.version,
            profiles: [ProjectArchiveContract.id, VendorLibraryContract.id],
            scenario: .init(category: scenarioCategory(index: index, draw: draw), description: "synthetic benchmark record"),
            source: .init(projectClusterKey: clusterKey, sourceUUID: nil, sha256: nil,
                          redactedRelativePath: "synthetic/\(clusterKey)/\(recordID).pdf",
                          redactedFilename: "\(recordID).pdf", nearDuplicateGroup: nil),
            expected: .init(state: .mapped, projectReference: clusterKey,
                            targetCategory: metadata[.documentcategory], targetType: metadata[.documenttype],
                            metadata: metadata, allowedUnknownFields: allowedUnknown),
            citations: [.init(label: "bench-citation", excerpt: "合成证据片段", locator: nil)],
            annotation: .init(annotatorCode: "B1", annotatedOn: "2026-11-12", basis: "synthetic"),
            review: .init(status: .confirmed, redaction: .synthetic, reviewerCode: "B1", reviewedOn: "2026-11-12"),
            usage: usage)
    }

    /// The stratum a record belongs to. The first records spread over every
    /// category in order, then the tail is drawn so a stratum count is not an
    /// artefact of `recordCount % 8`.
    private static func scenarioCategory(index: Int, draw: () -> Double) -> GoldRecord.Category {
        let spread = GoldRecord.Category.allCases
        if index < spread.count { return spread[index] }
        return spread[Int(draw() * Double(spread.count)) % spread.count]
    }

    static func digest(_ material: String) -> String {
        String(SHA256.hash(data: Data(material.utf8)).hexadecimalDigest.prefix(32))
    }
}

/// The three boundary lists a fixture can put a record in.
private enum FixtureRecordKind {
    case evaluation, prompt, withdrawn

    var prefix: String {
        switch self {
        case .evaluation: return "eval"
        case .prompt: return "prompt"
        case .withdrawn: return "withdrawn"
        }
    }
}