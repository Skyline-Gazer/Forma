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
public enum ClusterBootstrap {
    /// Fewer than this many clusters and the resample cannot vary: report nil
    /// rather than an interval whose width is an artefact of the seed.
    public static let minimumClusters = 5

    public static func interval(cases: [CaseJudgement], measure: EvaluationMeasure,
                                resamples: Int = 2_000, seed: UInt64 = 0x9E37_79B9_7F4A_7C15)
        -> ClosedRange<Double>? {
        let grouped = Dictionary(grouping: cases, by: \.clusterKey)
        guard grouped.count >= minimumClusters, resamples > 1 else { return nil }
        let clusters = grouped.keys.sorted().compactMap { grouped[$0] }

        var generator = SplitMix64(seed: seed)
        var ratios: [Double] = []
        ratios.reserveCapacity(resamples)
        for _ in 0..<resamples {
            var sample: [CaseJudgement] = []
            sample.reserveCapacity(cases.count)
            for _ in clusters.indices {
                sample.append(contentsOf: clusters[Int(generator.next() % UInt64(clusters.count))])
            }
            let pair = sample.reduce((0, 0)) { soFar, judgement in
                let next = measure.population(in: judgement)
                return (soFar.0 + next.numerator, soFar.1 + next.denominator)
            }
            if pair.1 > 0 { ratios.append(Double(pair.0) / Double(pair.1)) }
        }
        guard ratios.count >= 2 else { return nil }
        ratios.sort()
        // Percentile bounds, not a normal fit: the resampled distribution of a
        // ratio over a handful of clusters is lumpy, and the lumps are the finding.
        let lower = ratios[Int(Double(ratios.count - 1) * 0.025)]
        let upper = ratios[Int(Double(ratios.count - 1) * 0.975)]
        return lower...upper
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
        // Grouping happens once, not once per measure: the cuts are properties of
        // the sample, and re-deriving them six times invites them to disagree.
        let byProfile = Dictionary(grouping: cases.flatMap { judgement in
            judgement.profiles.map { ($0, judgement) }
        }, by: { $0.0 })
        let profiles = byProfile.keys.sorted()
        let profileCases = Dictionary(uniqueKeysWithValues: profiles.map {
            ($0, byProfile[$0]?.map { $0.1 } ?? [])
        })
        let byCategory = Dictionary(grouping: cases, by: \.category)
        let categories = byCategory.keys.sorted { $0.rawValue < $1.rawValue }

        for measure in EvaluationMeasure.allCases {
            output.append(slice(measure, .overall, key: nil, cases, request))
            for profile in profiles {
                output.append(slice(measure, .profile, key: profile, profileCases[profile] ?? [], request))
            }
            for category in categories {
                output.append(slice(measure, .category, key: category.rawValue,
                                    byCategory[category] ?? [], request))
            }
        }
        return output
    }

    private static func slice(_ measure: EvaluationMeasure, _ stratum: EvaluationSlice.Stratum, key: String?,
                              _ cases: [CaseJudgement], _ request: Request) -> EvaluationSlice {
        let pair = cases.reduce((0, 0)) { soFar, judgement in
            let next = measure.population(in: judgement)
            return (soFar.0 + next.numerator, soFar.1 + next.denominator)
        }
        return EvaluationSlice(measure: measure, stratum: stratum, key: key,
                               rate: EvaluationRate(numerator: pair.0, denominator: pair.1),
                               clusterInterval: ClusterBootstrap.interval(cases: cases, measure: measure,
                                                                          resamples: request.resamples,
                                                                          seed: request.seed))
    }

    /// Reference state against the state the engine reached, one row per pair.
    public static func confusion(_ cases: [CaseJudgement]) -> [String: Int] {
        Dictionary(grouping: cases, by: { "\($0.goldState.rawValue)->\($0.candidateState?.rawValue ?? "absent")" })
            .mapValues(\.count)
    }
}
