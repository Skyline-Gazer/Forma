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

/// A fraction with the observation count attached.
///
/// The denominator is never published alone: every one of these rates counts
/// field-level slots, so a five-record run can show a denominator in the tens and
/// a 150-record run can show a denominator of zero for `precision_auto`. What a
/// rate cannot say is how many *records* produced it - that is on
/// `EvaluationSlice.caseCount`, and it is the number the candidate-value gate uses.
public struct EvaluationRate: Codable, Sendable, Equatable {
    public let numerator: Int
    public let denominator: Int
    public let estimate: Double?
    public let wilson95Lower: Double?
    public let wilson95Upper: Double?

    init(numerator: Int, denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
        self.estimate = denominator > 0 ? Double(numerator) / Double(denominator) : nil
        // Wilson rather than the normal approximation: these rates sit near 0 and
        // 1, where the symmetric interval runs outside the valid range and reports
        // confidence a sample of a dozen does not carry.
        guard denominator > 0, let p = estimate else {
            wilson95Lower = nil; wilson95Upper = nil; return
        }
        // Wilson, not the normal approximation: these rates sit near 0 and 1,
        // where a symmetric band runs outside the valid range and reports a
        // confidence a sample of a dozen does not carry. The bounds are the
        // standard interval - the exact values are pinned by `wilsonBoundsThe
        // StandardWay`, because a bracket that always spans [0, 1] would satisfy
        // every "is it inside the unit interval" assertion ever written.
        let n = Double(denominator), z = 1.959_963_985_268_05
        let scale = z * z / n
        let centre = (p + scale / 2) / (1 + scale)
        let margin = z / (1 + scale) * ((p * (1 - p) + scale / 4) / n).squareRoot()
        wilson95Lower = max(0, centre - margin)
        wilson95Upper = min(1, centre + margin)
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
    /// Records judged in this stratum. Distinct from `rate.denominator`, which
    /// counts slots.
    public let caseCount: Int
    /// Clusters this stratum judged, published so a nil `clusterInterval` can be
    /// told apart: too few clusters to vary, or this measure too thin.
    public let clusterCount: Int
    public let rate: EvaluationRate
    /// Cluster-level bootstrap interval; see §5 of `docs/EVALUATION-METRICS.md` for
    /// the two reasons it can be nil.
    public let clusterInterval: ClosedRange<Double>?

    /// Below this many judged *records*, a rate is a candidate value only.
    ///
    /// This is a harness policy, not a requirement lifted from SPEC or PLAN:
    /// neither fixes a minimum cell size, and PLAN §13 item 1 lists the quality
    /// thresholds as pending the Owner's decision. Stated here so the number is
    /// arguable rather than hidden,
    /// and so no reader mistakes it for a frozen clause.
    public static let sparseCaseLimit = 30

    public var isSparse: Bool { caseCount < Self.sparseCaseLimit }

    /// Whether this number could be quoted on its own merits, before any judgement
    /// about the run: enough records, and a population for the measure to have seen
    /// anything. A measure with no observations is not "0%" and not a finding.
    public var isQuotableOnOwnMerits: Bool { !isSparse && rate.denominator > 0 }
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
        /// Clusters in the sample. A nil interval with `clusterCount` below
        /// `minimumClusters` means the stratum cannot vary; one with enough clusters
        /// means this measure was too thin to survive every draw. The two need
        /// separating, because only the second says anything about the measure.
        public let clusterCount: Int
    }

    /// Rate and interval for the requested measures over one sample.
    ///
    /// `populations` is the per-case slot tally for the whole corpus, in
    /// `EvaluationMeasure.allCases` order, computed once by the caller; `indices`
    /// picks this stratum's rows out of it and `keys` names each row's cluster. No
    /// judgement is re-walked here, so measuring eleven strata costs no more slot
    /// comparisons than measuring one.
    public static func summarize(measures: [EvaluationMeasure] = EvaluationMeasure.allCases,
                                 populations: [[(numerator: Int, denominator: Int)]],
                                 indices: [Int], keys: [String],
                                 resamples: Int = 2_000, seed: UInt64 = 0x9E37_79B9_7F4A_7C15)
        -> [EvaluationMeasure: Summary] {
        guard !measures.isEmpty else { return [:] }
        // A subset request still reads the columns built for the full order.
        let columns = measures.map { EvaluationMeasure.allCases.firstIndex(of: $0)! }

        // Positions within this sample, grouped by cluster key. Computed before the
        // totals so a stratum with nothing to vary still reports why.
        var grouped: [String: [Int]] = [:]
        for position in indices.indices {
            grouped[keys[indices[position]], default: []].append(position)
        }
        let clusterCount = grouped.count

        var output: [EvaluationMeasure: Summary] = [:]
        for (position, measure) in measures.enumerated() {
            var numerator = 0
            var denominator = 0
            for index in indices {
                numerator += populations[index][columns[position]].numerator
                denominator += populations[index][columns[position]].denominator
            }
            output[measure] = Summary(rate: EvaluationRate(numerator: numerator, denominator: denominator),
                                      interval: nil, clusterCount: clusterCount)
        }

        guard clusterCount >= minimumClusters, resamples > 1 else { return output }
        let clusters = grouped.keys.sorted().map { grouped[$0]! }

        var clusterTotals: [[(numerator: Int, denominator: Int)]] = []
        clusterTotals.reserveCapacity(clusters.count)
        for members in clusters {
            var row = Array(repeating: (numerator: 0, denominator: 0), count: measures.count)
            for member in members {
                let source = populations[indices[member]]
                for position in row.indices {
                    row[position].numerator += source[columns[position]].numerator
                    row[position].denominator += source[columns[position]].denominator
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
            // Not voided means every draw had a denominator, so there are exactly
            // `resamples` ratios - more than one, because of the guard above.
            guard !voided[position] else { continue }
            let sorted = ratios[position].sorted()
            let lower = sorted[Int(Double(sorted.count - 1) * 0.025)]
            let upper = sorted[Int(Double(sorted.count - 1) * 0.975)]
            output[measure] = Summary(rate: output[measure]!.rate, interval: lower...upper,
                                      clusterCount: clusterCount)
        }
        return output
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

    /// The slot comparisons happen once per case and measure; every stratum below
    /// reads that table, because a cut is a selection, not a new measurement.
    public static func slices(for cases: [CaseJudgement], request: Request = Request()) -> [EvaluationSlice] {
        let measures = EvaluationMeasure.allCases
        let populations: [[(numerator: Int, denominator: Int)]] = cases.map { judgement in
            measures.map { $0.population(in: judgement) }
        }
        let keys = cases.map(\.clusterKey)

        var output: [EvaluationSlice] = []
        for (stratum, key, sample) in cuts(of: cases) {
            let summaries = ClusterBootstrap.summarize(measures: measures, populations: populations,
                                                       indices: sample, keys: keys,
                                                       resamples: request.resamples, seed: request.seed)
            for measure in measures {
                let summary = summaries[measure]!
                output.append(EvaluationSlice(measure: measure, stratum: stratum, key: key,
                                              caseCount: sample.count, clusterCount: summary.clusterCount,
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
