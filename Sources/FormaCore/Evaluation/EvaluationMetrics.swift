import Foundation

/// The rates PLAN §8.2 defines, computed over judged cases.
///
/// Each measure restricts its own population, and that is the whole reason this
/// file exists: a single accuracy number would silently mix "the engine did not
/// answer", "the engine answered wrongly", "the answer was contradicted by other
/// evidence" and "the answer was a fill nobody asked for", which the contract
/// treats - and the reviewer acts on - differently.
public enum EvaluationMeasure: String, Codable, Sendable, CaseIterable, Comparable {
    case coverage
    case precisionAuto = "precision_auto"
    case highConfidenceErrorRate = "high_confidence_error_rate"
    case fieldPrecision = "field_precision"
    case holdRate = "hold_rate"
    case inventedFillRate = "invented_fill_rate"

    public static func < (lhs: EvaluationMeasure, rhs: EvaluationMeasure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Numerator and denominator over the slots of one case.
    ///
    /// When the engine produced no entry for the source at all - `candidateState`
    /// is nil - every reference value counts as held, and nothing can be
    /// contradicted or published, because there is nothing to publish.
    func population(in judgement: CaseJudgement) -> (numerator: Int, denominator: Int) {
        let held = judgement.candidateState.map { $0 == .hold || $0 == .unknown } ?? true
        let slots = judgement.fields

        switch self {
        case .coverage:
            // Reference has a value; the candidate gave one that nothing fought.
            let denominator = slots.filter { $0.verdict.isExpectationSlot }.count
            let numerator = slots.filter { $0.verdict == .correct || $0.verdict == .wrong }.count
            return (numerator, denominator)
        case .precisionAuto:
            let denominator = slots.filter { ($0.verdict == .correct || $0.verdict == .wrong)
                && $0.autoPublishable }.count
            let numerator = slots.filter { $0.verdict == .correct && $0.autoPublishable }.count
            return (numerator, denominator)
        case .highConfidenceErrorRate:
            let denominator = slots.filter { ($0.verdict == .correct || $0.verdict == .wrong)
                && $0.highConfidence }.count
            let numerator = slots.filter { $0.verdict == .wrong && $0.highConfidence }.count
            return (numerator, denominator)
        case .fieldPrecision:
            // Every non-empty candidate, contradicted and invented included: this
            // is "of what the engine asserted, how much was right".
            let denominator = slots.filter { $0.verdict.isCandidateAssertion }.count
            let numerator = slots.filter { $0.verdict == .correct }.count
            return (numerator, denominator)
        case .holdRate:
            let denominator = slots.filter { $0.verdict.isExpectationSlot }.count
            let withheld = slots.filter { $0.verdict == .withheld }.count
            // An entry parked in `hold`/`unknown` holds every slot it left filled
            // too, which is why the case-level state counts, not just empty values.
            let numerator = held ? denominator : withheld
            return (numerator, denominator)
        case .inventedFillRate:
            let denominator = slots.filter { $0.verdict.isNullExpectation }.count
            let numerator = slots.filter { $0.verdict == .invented }.count
            return (numerator, denominator)
        }
    }
}

extension FieldJudgement.Verdict {
    /// The reference answer has a value here.
    var isExpectationSlot: Bool { self != .allowedUnknown && self != .invented }
    /// The reference answer has no value here.
    var isNullExpectation: Bool { self == .allowedUnknown || self == .invented }
    /// The candidate asserted something, whether or not it stands up.
    var isCandidateAssertion: Bool { self == .correct || self == .wrong || self == .contradicted
        || self == .invented }
}

/// A fraction with the sample size attached.
///
/// The denominator is never dropped: SPEC §10.1.6 makes a rate over fewer than 30
/// observations a candidate value only, and that judgement is impossible to make
/// downstream if the count is not published beside the number.
public struct EvaluationRate: Codable, Sendable, Equatable {
    public let numerator: Int
    public let denominator: Int
    public let estimate: Double?
    public let wilson95Lower: Double?
    public let wilson95Upper: Double?
    public let isSparse: Bool

    static let sparseLimit = 30

    init(numerator: Int, denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
        self.estimate = denominator > 0 ? Double(numerator) / Double(denominator) : nil
        // Wilson rather than the normal approximation: these rates sit near 0 and
        // 1, where the symmetric interval runs outside the valid range and reports
        // confidence a sample of a dozen does not carry.
        guard denominator > 0, let p = estimate else {
            wilson95Lower = nil; wilson95Upper = nil; isSparse = true; return
        }
        let n = Double(denominator), z = 1.959_963_985_268_05
        let scale = z * z / n
        let centre = p + scale / 2
        let margin = z * ((p * (1 - p) + scale / 4) / (1 + scale)).squareRoot()
        wilson95Lower = max(0, (centre - margin) / (1 + scale))
        wilson95Upper = min(1, (centre + margin) / (1 + scale))
        isSparse = denominator < Self.sparseLimit
    }
}

/// One measure at one cut of the data.
public struct EvaluationSlice: Codable, Sendable, Equatable {
    public enum Stratum: String, Codable, Sendable, CaseIterable {
        case overall, profile, category
    }

    public let measure: EvaluationMeasure
    public let stratum: Stratum
    /// The stratum's key - a Profile id, a scenario category, or nil for overall.
    public let key: String?
    public let rate: EvaluationRate
    /// Cluster-level bootstrap interval, nil when there are too few clusters for
    /// resampling to mean anything.
    public let clusterInterval: ClosedRange<Double>?
}

/// Cluster-level resampling, and the rate that goes with it.
///
/// Records within one project are not independent observations, so a per-record
/// interval overstates certainty about a corpus of template families. Resampling
/// whole clusters with replacement answers the question the gate actually asks:
/// how much of this number is one project's shape.
///
/// Two properties are deliberate. The resampled quantity is a pair of integer
/// totals, so a resample adds cluster sums instead of re-walking judgements, and
/// the draws depend only on the seed and the cluster count - never on the measure.
/// And a draw with an empty denominator voids that one measure's interval rather
/// than being skipped: the surviving draws of such a sample are exactly the
/// clusters that happened to answer, which narrows the band precisely in the thin
/// strata where it should widen.
public enum ClusterBootstrap {
    /// Fewer than this many clusters and the resample cannot vary: report nil
    /// rather than an interval whose width is an artefact of the seed.
    public static let minimumClusters = 5

    /// One measure's rate over a sample, with its cluster interval.
    public struct Summary: Sendable, Equatable {
        public let rate: EvaluationRate
        public let interval: ClosedRange<Double>?
    }

    /// Rate and interval for every measure over one sample, from a single walk.
    ///
    /// `indices` selects the sample so a stratum does not need its own copy of the
    /// judgements; the slot comparison - the expensive part - then happens exactly
    /// once per case and measure, and both the totals and the resampling reuse it.
    public static func summarize(cases: [CaseJudgement], indices: [Int],
                                 measures: [EvaluationMeasure] = EvaluationMeasure.allCases,
                                 resamples: Int = 2_000, seed: UInt64 = 0x9E37_79B9_7F4A_7C15)
        -> [EvaluationMeasure: Summary] {
        guard !measures.isEmpty else { return [:] }
        let populations: [[(numerator: Int, denominator: Int)]] = indices.map { index in
            measures.map { $0.population(in: cases[index]) }
        }

        var output: [EvaluationMeasure: Summary] = [:]
        for (position, measure) in measures.enumerated() {
            var numerator = 0
            var denominator = 0
            for row in populations {
                numerator += row[position].numerator
                denominator += row[position].denominator
            }
            output[measure] = Summary(rate: EvaluationRate(numerator: numerator, denominator: denominator),
                                      interval: nil)
        }

        let clusters = clusterIndices(of: cases, sample: indices, populationCount: populations.count)
        guard clusters.count >= minimumClusters, resamples > 1 else { return output }

        // Cluster totals, from the same walk: summing per cluster is what turns a
        // resample into integer additions.
        var clusterTotals: [[(numerator: Int, denominator: Int)]] = []
        clusterTotals.reserveCapacity(clusters.count)
        for members in clusters {
            var row = Array(repeating: (numerator: 0, denominator: 0), count: measures.count)
            for member in members {
                let source = populations[member]
                for position in row.indices {
                    row[position].numerator += source[position].numerator
                    row[position].denominator += source[position].denominator
                }
            }
            clusterTotals.append(row)
        }

        var generator = SplitMix64(seed: seed)
        var ratios: [[Double]] = measures.map { _ in [] }
        // Voiding is per measure: an undefined draw for `precision_auto` must not
        // also take away the draws of every measure listed after it.
        var voided = measures.map { _ in false }
        for _ in 0..<resamples {
            let picks = (0..<clusters.count).map { _ in Int(generator.next() % UInt64(clusters.count)) }
            for position in measures.indices where !voided[position] {
                var numerator = 0
                var denominator = 0
                for pick in picks {
                    numerator += clusterTotals[pick][position].numerator
                    denominator += clusterTotals[pick][position].denominator
                }
                if denominator == 0 { voided[position] = true }
                else { ratios[position].append(Double(numerator) / Double(denominator)) }
            }
        }

        for (position, measure) in measures.enumerated() {
            guard !voided[position] else { continue }
            let sorted = ratios[position].sorted()
            guard sorted.count >= 2 else { continue }
            // Percentile bounds, not a normal fit: the resampled distribution of a
            // ratio over a handful of clusters is lumpy, and the lumps are the finding.
            let lower = sorted[Int(Double(sorted.count - 1) * 0.025)]
            let upper = sorted[Int(Double(sorted.count - 1) * 0.975)]
            output[measure] = Summary(rate: output[measure]!.rate, interval: lower...upper)
        }
        return output
    }

    /// The interval for one measure, for callers that want only it.
    public static func interval(cases: [CaseJudgement], measure: EvaluationMeasure,
                                resamples: Int = 2_000, seed: UInt64 = 0x9E37_79B9_7F4A_7C15)
        -> ClosedRange<Double>? {
        summarize(cases: cases, indices: Array(cases.indices), measures: [measure],
                  resamples: resamples, seed: seed)[measure]?.interval
    }

    public static func intervals(cases: [CaseJudgement], measures: [EvaluationMeasure],
                                 resamples: Int = 2_000, seed: UInt64 = 0x9E37_79B9_7F4A_7C15)
        -> [EvaluationMeasure: ClosedRange<Double>] {
        let summaries = summarize(cases: cases, indices: Array(cases.indices), measures: measures,
                                  resamples: resamples, seed: seed)
        // A voided measure is absent rather than mapped to a nil-valued dictionary:
        // callers ask "is there an interval", and `nil` answers it either way.
        return Dictionary(uniqueKeysWithValues: measures.compactMap { measure in
            summaries[measure]?.interval.map { (measure, $0) }
        })
    }

    /// Sample positions grouped by project cluster, ordered by cluster key so a
    /// given seed always produces the same resample.
    private static func clusterIndices(of cases: [CaseJudgement], sample: [Int],
                                       populationCount: Int) -> [[Int]] {
        var grouped: [String: [Int]] = [:]
        for position in sample.indices {
            grouped[cases[sample[position]].clusterKey, default: []].append(position)
        }
        // `grouping` never yields an empty bucket, so the key is always present.
        return grouped.keys.sorted().map { grouped[$0]! }
    }
}

/// SplitMix64: small, deterministic, and reproducible across Swift versions,
/// which `SystemRandomNumberGenerator` is not. A measurement run has to be
/// re-runnable from its recorded seed.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// All measures over the overall set and each declared stratum.
public enum EvaluationMetrics {
    public struct Request: Sendable {
        public let resamples: Int
        public let seed: UInt64
        public init(resamples: Int = 2_000, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
            self.resamples = resamples
            self.seed = seed
        }
    }

    public static func slices(for cases: [CaseJudgement], request: Request = Request()) -> [EvaluationSlice] {
        var output: [EvaluationSlice] = []
        for (stratum, key, sample) in cuts(of: cases) {
            let summaries = ClusterBootstrap.summarize(cases: cases, indices: sample,
                                                       resamples: request.resamples, seed: request.seed)
            for measure in EvaluationMeasure.allCases {
                let summary = summaries[measure]!
                output.append(EvaluationSlice(measure: measure, stratum: stratum, key: key,
                                              rate: summary.rate, clusterInterval: summary.interval))
            }
        }
        return output
    }

    /// The strata to report, each as positions into `cases`. Overall first, then
    /// the cuts that actually have members; a record belonging to two profiles
    /// appears in both strata and is still one record in each.
    private static func cuts(of cases: [CaseJudgement]) -> [(EvaluationSlice.Stratum, String?, [Int])] {
        var byProfile: [String: [Int]] = [:]
        for position in cases.indices {
            for profile in cases[position].profiles {
                byProfile[profile, default: []].append(position)
            }
        }
        var byCategory: [GoldRecord.Category: [Int]] = [:]
        for position in cases.indices {
            byCategory[cases[position].category, default: []].append(position)
        }
        var cuts: [(EvaluationSlice.Stratum, String?, [Int])] = [(.overall, nil, Array(cases.indices))]
        cuts.append(contentsOf: byProfile.keys.sorted().map { (.profile, $0, byProfile[$0]!) })
        cuts.append(contentsOf: byCategory.keys.sorted { $0.rawValue < $1.rawValue }
            .map { (.category, $0.rawValue, byCategory[$0]!) })
        return cuts
    }


    /// Reference state against the state the engine reached, one row per pair.
    public static func confusion(_ cases: [CaseJudgement]) -> [String: Int] {
        Dictionary(grouping: cases, by: { "\($0.goldState.rawValue)->\($0.candidateState?.rawValue ?? "absent")" })
            .mapValues(\.count)
    }
}
