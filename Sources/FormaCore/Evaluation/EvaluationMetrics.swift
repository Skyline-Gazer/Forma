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

/// Percentile interval from resampling whole project clusters.
///
/// Records within one project are not independent observations, so a per-record
/// interval overstates certainty about a corpus of template families. Resampling
/// clusters with replacement answers the question the gate actually asks: how
/// much of this number is one project's shape.
///
/// Two things about this are deliberate. The resampled unit is a cluster, and the
/// resampled quantity is the pair of integer totals - so a resample sums cluster
/// totals instead of re-walking every case, which keeps a six-measure report at
/// `resamples x clusters` integer work rather than re-running the judgements six
/// times over. And a resample whose denominator is zero makes the whole interval
/// nil: dropping those draws and reporting a percentile range over the rest would
/// quietly measure only the clusters that happened to answer, narrowing the band
/// exactly when the stratum is too thin to support one.
public enum ClusterBootstrap {
    /// Fewer than this many clusters and the resample cannot vary: report nil
    /// rather than an interval whose width is an artefact of the seed.
    public static let minimumClusters = 5

    /// Intervals for several measures over one sample, from one set of draws.
    ///
    /// The draws do not depend on the measure, so computing them per measure would
    /// spend the same random numbers repeatedly and could drift apart in any future
    /// edit that made the generator stateful across calls.
    public static func intervals(cases: [CaseJudgement], measures: [EvaluationMeasure],
                                 resamples: Int = 2_000, seed: UInt64 = 0x9E37_79B9_7F4A_7C15)
        -> [EvaluationMeasure: ClosedRange<Double>] {
        guard resamples > 1 else { return [:] }
        let clusters = clusterIndices(of: cases)
        guard clusters.count >= minimumClusters else { return [:] }
        guard !measures.isEmpty else { return [:] }

        // One pass over the cases per cluster, then the resample only adds integers.
        let totals: [[(numerator: Int, denominator: Int)]] = clusters.map { indices in
            measures.map { measure in
                indices.reduce((0, 0)) { soFar, index in
                    let next = measure.population(in: cases[index])
                    return (soFar.0 + next.numerator, soFar.1 + next.denominator)
                }
            }
        }

        var generator = SplitMix64(seed: seed)
        var ratios: [[Double]] = measures.map { _ in [] }
        for _ in 0..<resamples {
            let picks = (0..<clusters.count).map { _ in Int(generator.next() % UInt64(clusters.count)) }
            for (position, measure) in measures.enumerated() {
                var numerator = 0
                var denominator = 0
                for pick in picks {
                    numerator += totals[pick][position].numerator
                    denominator += totals[pick][position].denominator
                }
                // An undefined draw is not skipped: see the type comment.
                guard denominator > 0 else { ratios[position] = []; break }
                ratios[position].append(Double(numerator) / Double(denominator))
            }
        }

        var output: [EvaluationMeasure: ClosedRange<Double>] = [:]
        for (position, measure) in measures.enumerated() {
            let sorted = ratios[position].sorted()
            guard sorted.count >= 2 else { continue }
            // Percentile bounds, not a normal fit: the resampled distribution of a
            // ratio over a handful of clusters is lumpy, and the lumps are the finding.
            let lower = sorted[Int(Double(sorted.count - 1) * 0.025)]
            let upper = sorted[Int(Double(sorted.count - 1) * 0.975)]
            output[measure] = lower...upper
        }
        return output
    }

    public static func interval(cases: [CaseJudgement], measure: EvaluationMeasure,
                                resamples: Int = 2_000, seed: UInt64 = 0x9E37_79B9_7F4A_7C15)
        -> ClosedRange<Double>? {
        intervals(cases: cases, measures: [measure], resamples: resamples, seed: seed)[measure]
    }

    /// Case indices grouped by project cluster, ordered by cluster key so a given
    /// seed always produces the same resample.
    private static func clusterIndices(of cases: [CaseJudgement]) -> [[Int]] {
        let grouped = Dictionary(grouping: cases.indices, by: { cases[$0].clusterKey })
        return grouped.keys.sorted().map { grouped[$0] ?? [] }
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
        // Grouping happens once, not once per measure: the cuts are properties of
        // the sample, and re-deriving them six times invites them to disagree.
        let byProfile = Dictionary(grouping: cases.flatMap { judgement in
            judgement.profiles.map { ($0, judgement) }
        }, by: { $0.0 })
        let profiles = byProfile.keys.sorted()
        let byCategory = Dictionary(grouping: cases, by: \.category)
        let categories = byCategory.keys.sorted { $0.rawValue < $1.rawValue }

        var output: [EvaluationSlice] = []
        for (stratum, key, members) in cuts(profiles: profiles, byProfile: byProfile,
                                            categories: categories, byCategory: byCategory, cases: cases) {
            output.append(contentsOf: slice(members, stratum: stratum, key: key, request: request))
        }
        return output
    }

    /// The strata to report, with their cases. Overall first, then the cuts.
    private static func cuts(profiles: [String],
                             byProfile: [String: [(String, CaseJudgement)]],
                             categories: [GoldRecord.Category],
                             byCategory: [GoldRecord.Category: [CaseJudgement]],
                             cases: [CaseJudgement])
        -> [(EvaluationSlice.Stratum, String?, [CaseJudgement])] {
        var cuts: [(EvaluationSlice.Stratum, String?, [CaseJudgement])] = [(.overall, nil, cases)]
        cuts.append(contentsOf: profiles.map { profile in
            (.profile, profile, byProfile[profile]?.map { $0.1 } ?? [])
        })
        cuts.append(contentsOf: categories.map { category in
            (.category, category.rawValue, byCategory[category] ?? [])
        })
        return cuts
    }

    /// Every measure at one cut. The judgements are walked once for all measures
    /// and the bootstrap draws are shared between them.
    private static func slice(_ cases: [CaseJudgement], stratum: EvaluationSlice.Stratum, key: String?,
                              request: Request) -> [EvaluationSlice] {
        let measures = EvaluationMeasure.allCases
        let intervals = ClusterBootstrap.intervals(cases: cases, measures: measures,
                                                   resamples: request.resamples, seed: request.seed)
        return measures.map { measure in
            let pair = cases.reduce((0, 0)) { soFar, judgement in
                let next = measure.population(in: judgement)
                return (soFar.0 + next.numerator, soFar.1 + next.denominator)
            }
            return EvaluationSlice(measure: measure, stratum: stratum, key: key,
                                   rate: EvaluationRate(numerator: pair.0, denominator: pair.1),
                                   clusterInterval: intervals[measure])
        }
    }


    /// Reference state against the state the engine reached, one row per pair.
    public static func confusion(_ cases: [CaseJudgement]) -> [String: Int] {
        Dictionary(grouping: cases, by: { "\($0.goldState.rawValue)->\($0.candidateState?.rawValue ?? "absent")" })
            .mapValues(\.count)
    }
}
