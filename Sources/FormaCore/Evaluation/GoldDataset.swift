import Foundation

/// An independent gold dataset plus the split it was fixed with.
///
/// Three jobs, in this order: refuse a dataset that cannot be audited, refuse to
/// count a record whose answer could have been seen by the model being measured,
/// and then report what was actually measured - including what was not.
///
/// The ≥150 sample requirement from PLAN §8.1 is a *reported* condition, not an
/// exception: P3-A has to be able to run against a smaller local set and say
/// which strata are short. Silently passing a thin dataset would invent quality
/// evidence; throwing on one would make the gap impossible to measure.
public struct GoldDataset: Sendable {
    /// A stratum that did not reach its target count. `required` is PLAN's
    /// "争取 ≥10" figure; it is reported so a reader can weigh the interval,
    /// never treated as a pass/fail switch inside FormaCore.
    public struct Shortfall: Codable, Sendable, Equatable {
        public let profile: String
        public let category: GoldRecord.Category
        public let count: Int
        public let required: Int
    }

    /// The outcome of loading and verifying a dataset. Written as JSON by the
    /// evaluation report so a later reader can re-derive the denominators.
    public struct Report: Codable, Sendable, Equatable {
        public let datasetRevision: String
        public let splitID: String
        public let casePackVersion: String
        public let totalRecords: Int
        public let evaluationRecords: Int
        public let countableRecords: Int
        /// Countable records whose material was reviewed rather than synthesised.
        /// PLAN §8.1's ≥150 is a requirement about *independent verification of
        /// real business material*, so the target is measured against this
        /// number: a harness can be exercised on synthetic rows, but synthetic
        /// rows cannot certify a quality gate.
        public let reviewedCountable: Int
        public let pendingAdjudication: Int
        public let perProfileCountable: [String: Int]
        public let perCategoryCountable: [String: Int]
        public let shortfalls: [Shortfall]
        public let undeclaredOverlaps: [String]
        public let meetsIndependentTarget: Bool
        public let requiredMinimum: Int
    }

    public static let independentTarget = 150
    public static let stratumTarget = 10

    public let records: [GoldRecord]
    public let split: GoldSplit
    /// The pack the prompt side is actually made of. Kept on the dataset rather
    /// than passed to each check: the leak comparison and the reported overlaps
    /// must use the same pack, or the two could disagree about what was taught.
    public let casePack: CasePack

    /// Records that may enter a denominator, by id: split membership, review
    /// status, revision agreement and leak checks all have to agree before a
    /// record is counted, so the set is computed once and reused by the metrics.
    public let countableIDs: Set<String>

    public init(records: [GoldRecord], split: GoldSplit, casePack: CasePack) throws {
        try Self.verify(records: records, split: split, casePack: casePack)
        self.records = records
        self.split = split
        self.casePack = casePack
        self.countableIDs = Self.countable(records: records, split: split, casePack: casePack)
    }

    // MARK: - Loading

    /// Reads `<directory>/split-manifest.json` and `<directory>/records/*.json`.
    ///
    /// Gold data itself is not committed to the public repository; this is the
    /// layout the local directory is expected to follow, and the shape every
    /// synthetic test fixture imitates.
    public static func load(directory: URL) throws -> GoldDataset {
        let splitURL = directory.appendingPathComponent("split-manifest.json")
        guard let splitData = try? Data(contentsOf: splitURL) else { throw FormaError.invalidSource }
        try ArtifactSchemaValidator.goldSplit.validate(splitData)
        let split = try FormaJSON.decode(GoldSplit.self, from: splitData)

        let recordsDir = directory.appendingPathComponent("records", isDirectory: true)
        let found = try FileManager.default.contentsOfDirectory(at: recordsDir,
                                                                includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles])
        let schema = try ArtifactSchemaValidator.goldRecord
        var records: [GoldRecord] = []
        for url in found.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard url.pathExtension == "json" else { continue }
            let data = try Data(contentsOf: url)
            try schema.validate(data)
            records.append(try FormaJSON.decode(GoldRecord.self, from: data))
        }
        return try GoldDataset(records: records, split: split, casePack: try CasePack.shipped())
    }

    static func verify(records: [GoldRecord], split: GoldSplit, casePack: CasePack) throws {
        let ids = records.map(\.recordID)
        guard Set(ids).count == ids.count else {
            // Two files claiming one id would make every denominator a guess.
            throw FormaError.invalidOutput
        }
        guard records.allSatisfy({ $0.datasetRevision == split.datasetRevision }) else {
            // Mixing revisions is the quiet way a number stops being reproducible.
            throw FormaError.incompatible
        }
        let listed = Set(ids)
        guard split.evaluationRecordIDs.isSubset(of: listed) else {
            // The manifest naming a record the directory does not contain would
            // inflate the denominator by the missing rows.
            throw FormaError.invalidSource
        }
        // Every record the manifest calls prompt-side has to be findable: either
        // a case in the shipped pack or a record marked `fewshot`. A dangling id
        // would let a split claim isolation it never computed.
        let promptUniverse = Set(casePack.cases.map { $0.caseID })
            .union(records.filter { $0.usage == .fewshot }.map { $0.recordID })
        // Both ids are references out of the manifest, so both failures are the
        // same thing: the split points at material that is not there.
        guard split.promptRecordIDs.isSubset(of: promptUniverse) else { throw FormaError.invalidSource }
    }

    static func countable(records: [GoldRecord], split: GoldSplit, casePack: CasePack) -> Set<String> {
        let promptKeys = promptIdentityKeys(casePack: casePack, records: records)
        var allowed: Set<String> = []
        for record in records {
            guard split.evaluationRecordIDs.contains(record.recordID), record.isCountable else { continue }
            if !overlaps(record: record, promptKeys: promptKeys).isEmpty { continue }
            allowed.insert(record.recordID)
        }
        return allowed
    }

    /// Identity the prompt side is known by. The shipped pack states a filename
    /// only, so that is the single axis it can be matched on; a record marked
    /// `fewshot` carries all five, because gold records do.
    ///
    /// The asymmetry is real, not a shortcut: a pack case has no cluster key or
    /// hash, so a pack sample and a gold record can only be matched by filename
    /// family, and cluster isolation has to be asserted by the split manifest.
    /// That is why PLAN §8.1 asks for conservative cluster assignment rather
    /// than assuming two different names mean two different documents.
    static func promptIdentityKeys(casePack: CasePack, records: [GoldRecord]) -> [String: Set<String>] {
        var keys: [String: Set<String>] = [:]
        for sample in casePack.cases {
            keys[sample.caseID] = ["family:" + GoldRecord.filenameFamily(of: sample.input.redactedFilename)]
        }
        for record in records where record.usage == .fewshot {
            keys[record.recordID] = record.independenceKeys
        }
        return keys
    }

    /// The prompt-side records whose identity collides with this evaluation
    /// record, keyed by the axis that collided.
    static func overlaps(record: GoldRecord, promptKeys: [String: Set<String>]) -> [(axis: String, promptID: String)] {
        let mine = record.independenceKeys
        var found: [(String, String)] = []
        for (promptID, theirs) in promptKeys.sorted(by: { $0.key < $1.key }) {
            for key in mine where theirs.contains(key) {
                found.append((String(key.split(separator: ":", maxSplits: 1).first ?? ""), promptID))
            }
        }
        return found
    }

    // MARK: - Reporting

    public func report(includingUndeclared: Bool = true) -> Report {
        let evaluation = records.filter { split.evaluationRecordIDs.contains($0.recordID) }
        let countable = records.filter { countableIDs.contains($0.recordID) }
        let pending = records.filter { $0.isPendingAdjudication && $0.usage == .evaluation }.count

        var perProfile: [String: Int] = [:]
        var perCategory: [String: Int] = [:]
        for record in countable {
            perCategory[record.scenario.category.rawValue, default: 0] += 1
            for profile in record.profiles { perProfile[profile, default: 0] += 1 }
        }

        var shortfalls: [Shortfall] = []
        for profile in [ProjectArchiveContract.id, VendorLibraryContract.id] {
            for category in GoldRecord.Category.allCases {
                let n = countable.filter { $0.profiles.contains(profile) && $0.scenario.category == category }.count
                if n < Self.stratumTarget {
                    shortfalls.append(Shortfall(profile: profile, category: category, count: n,
                                                required: Self.stratumTarget))
                }
            }
        }

        var undeclared: [String] = []
        if includingUndeclared {
            let promptKeys = Self.promptIdentityKeys(casePack: casePack, records: records)
            // There is no legal state in which an evaluation record has a
            // declared removal: `GoldSplit.check` refuses a record that sits in
            // both lists. So anything reaching here that overlaps the prompt side
            // is by definition undeclared, and naming it is the whole job.
            for record in evaluation where record.isCountable {
                for (axis, promptID) in Self.overlaps(record: record, promptKeys: promptKeys) {
                    undeclared.append("\(record.recordID)~\(promptID):\(axis)")
                }
            }
        }

        return Report(datasetRevision: split.datasetRevision, splitID: split.splitID,
                      casePackVersion: split.casePack.version, totalRecords: records.count,
                      evaluationRecords: evaluation.count, countableRecords: countable.count,
                      reviewedCountable: countable.filter { $0.review.redaction == .reviewed }.count,
                      pendingAdjudication: pending, perProfileCountable: perProfile,
                      perCategoryCountable: perCategory, shortfalls: shortfalls,
                      undeclaredOverlaps: undeclared,
                      meetsIndependentTarget: countable.filter { $0.review.redaction == .reviewed }.count
                          >= Self.independentTarget,
                      requiredMinimum: Self.independentTarget)
    }
}
