/// The rates of PLAN §8.2, at the unit that plan states them in.
///
/// Coverage, `precision_auto`, `hold_rate` and `high_confidence_error_rate` are
/// about a **record** - one gold file, one main decision - because that is how the
/// thresholds were written ("coverage = auto_mapped / total"). `field_precision`
/// and the two fill rates are about a **slot**, and are reported per field as well
/// as pooled. The units are not interchangeable: with forty records whose twelve
/// slots each got one right answer, file-level coverage is nil while slot-level
/// coverage reads 8%, and quoting the second under the first name would pass a
/// threshold the run did not meet.
///
/// Each measure restricts its own population, and that is the reason this file
/// exists: one accuracy number would silently mix "the engine did not answer", "it
/// answered wrongly", "its own evidence contradicts the answer" and "it filled a
/// slot nobody asked about", which the contract - and a reviewer acting on it -
/// treats differently.
public enum EvaluationMeasure: String, Codable, Sendable, CaseIterable, Comparable {
    case coverage
    case precisionAuto = "precision_auto"
    case highConfidenceErrorRate = "high_confidence_error_rate"
    case fieldPrecision = "field_precision"
    case holdRate = "hold_rate"
    case missedFillRate = "missed_fill_rate"
    case inventedFillRate = "invented_fill_rate"

    public static func < (lhs: EvaluationMeasure, rhs: EvaluationMeasure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Whether this rate's numerator and denominator count records or slots.
    ///
    /// Published because `EvaluationSlice.caseCount` coincides with the denominator
    /// only for the record-level measures; a reader comparing the two needs to know
    /// which unit they are looking at.
    public var unit: Unit {
        switch self {
        case .coverage, .precisionAuto, .highConfidenceErrorRate, .holdRate: .records
        case .fieldPrecision, .missedFillRate, .inventedFillRate: .slots
        }
    }

    public enum Unit: String, Codable, Sendable {
        case records, slots
    }

    /// Numerator and denominator contributed by one case.
    ///
    /// `runProfile` is the Profile the run executed under, required by PLAN §8.2's
    /// definition of a correct file; nil means the run did not name exactly one, so
    /// `precision_auto` and `high_confidence_error_rate` have no population at all
    /// - no records counted in either half, not a row of zeros - because an
    /// unattributable run has not measured those two rates, and PLAN §8.2 marks
    /// every zero denominator N/A. Reporting `0 / N` there would hand a reader an
    /// "observed 0% precision" for the fact that the run forgot to say who ran it,
    /// and `isQuotableOnOwnMerits` would then call it quotable.
    /// rather than a guess about the Profile component.
    func population(in judgement: CaseJudgement, runProfile: String?) -> (numerator: Int, denominator: Int) {
        let slots = judgement.fields
        switch self {
        case .coverage:
            // auto_mapped / total: one record, one policy-executable mapping.
            return (judgement.isAutoMapped ? 1 : 0, 1)
        case .precisionAuto:
            guard judgement.isAutoMapped, let runProfile else { return (0, 0) }
            return (judgement.mainDecisionIsCorrect(runProfile: runProfile) ? 1 : 0, 1)
        case .highConfidenceErrorRate:
            // The model's own claim, over the records it made one; PLAN §8.2 keeps
            // this separate from the policy verdict on purpose. Whether that claim
            // was right is the same unanswerable question `precision_auto` asks, so
            // an unattributed run leaves this population empty too.
            guard let runProfile, judgement.declaresHighConfidence, judgement.candidateState != nil else {
                return (0, 0)
            }
            return (judgement.mainDecisionIsCorrect(runProfile: runProfile) ? 0 : 1, 1)
        case .holdRate:
            // held / total. No entry is held as surely as an entry that was parked
            // mid-decision: the reviewer received nothing either way.
            let held = judgement.candidateState.map { $0 == .hold || $0 == .unknown } ?? true
            return (held ? 1 : 0, 1)
        case .fieldPrecision:
            // Every non-empty candidate, contradicted and invented included: of what
            // the engine asserted, how much was right.
            let asserted = slots.filter { $0.verdict.isCandidateAssertion }.count
            let correct = slots.filter { $0.verdict == .correct }.count
            return (correct, asserted)
        case .missedFillRate:
            // PLAN §8.2's 漏填: the reference had a value and the candidate did not.
            // `allowedUnknown` slots - where the reference declined to guess - are
            // not expectation slots, so they stay out of this denominator entirely:
            // an agreed unknown is not a miss, which is the distinction the plan asks
            // the report to keep visible.
            let expected = slots.filter { $0.verdict.isExpectationSlot }.count
            let missed = slots.filter { $0.verdict == .withheld }.count
            return (missed, expected)
        case .inventedFillRate:
            // Slots with no expectation, filled or wrongly filled.
            let nullExpectation = slots.filter { $0.verdict.isNullExpectation }.count
            let invented = slots.filter { $0.verdict == .invented }.count
            return (invented, nullExpectation)
        }
    }

    /// The same measure restricted to one field, for `field_precision`'s per-field
    /// rows (PLAN §8.2: "12 字段分别报告").
    func population(in field: FieldJudgement) -> (numerator: Int, denominator: Int) {
        let asserted = field.verdict.isCandidateAssertion
        return (field.verdict == .correct ? 1 : 0, asserted ? 1 : 0)
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
/// Which unit the denominator counts - records or slots - is stated by
/// `EvaluationMeasure.unit`, and `EvaluationSlice` publishes both the rate and the
/// record count so a reader never has to infer one from the other.
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
        // Wilson rather than the normal approximation: these rates sit near 0 and 1,
        // where a symmetric band runs outside the valid range and reports a
        // confidence a sample of a dozen does not carry. The bounds are the standard
        // interval with its exact values pinned by `wilsonBoundsTheStandardWay` - a
        // bracket that always spans [0, 1] satisfies every "is it inside the unit
        // interval" assertion ever written, which is how a wrong divisor here stayed
        // green.
        guard denominator > 0, let p = estimate else {
            wilson95Lower = nil; wilson95Upper = nil; return
        }
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
        /// `field` rows exist for `field_precision` only: PLAN §8.2 asks for the
        /// twelve fields separately, and the pooled row above them is the one with a
        /// cluster interval. A field row therefore carries Wilson and the counts, and
        /// reports `clusterInterval == nil` by construction, not by thinness.
        case overall, profile, category, field
    }

    public let measure: EvaluationMeasure
    public let stratum: Stratum
    /// The stratum's key - a Profile id, a scenario category, or nil for overall.
    public let key: String?
    /// Records this row's own evidence rests on: the judged records of the cut for
    /// every pooled row (equal to `rate.denominator` when `unit == .records`, and its
    /// usual multiple when `unit == .slots`), and for a `field_precision` `.field` row
    /// only the records that asserted something about that field. `isSparse` reads
    /// this, so the unit has to be the row's own or the gate would measure how big
    /// the run was instead of how thin the row is.
    public let caseCount: Int
    /// Clusters this stratum judged, published so a nil `clusterInterval` can be
    /// told apart: too few clusters to vary, this measure too thin in some draw, or
    /// the run asked for fewer than two draws (§5).
    public let clusterCount: Int
    public let rate: EvaluationRate
    /// Cluster-level bootstrap interval; see §5 of `docs/EVALUATION-METRICS.md` for
    /// the three reasons it can be nil.
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
        /// Clusters in the sample, which tells a nil interval apart: `clusterCount`
        /// below `minimumClusters` means the stratum cannot vary, enough clusters
        /// means either this measure was too thin to survive every draw or the run
        /// asked for fewer than two draws (`Request.resamples <= 1`), where no band
        /// can exist at all. Nothing floors that request - it is recorded in
        /// `EvaluationRunIdentity`, so a reader can tell the third cause from the
        /// second by the run's own resample count rather than by a silent correction.
        public let clusterCount: Int
    }

    /// Rate and interval for the requested measures over one sample.
    ///
    /// `populations` is the per-case tally for the whole corpus, in
    /// `EvaluationMeasure.allCases` order, computed once per run Profile by the
    /// caller (it is the only input that varies between strata of the same corpus);
    /// `indices`
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
        /// Cluster draws behind every `clusterInterval` in this run.
        ///
        /// One draw cannot make a band - the 2.5th and 97.5th percentile of a
        /// single number are that number, which would report zero uncertainty - so a
        /// request below two asks for the rates without the intervals, and every
        /// slice then has a nil `clusterInterval` for that reason rather than for
        /// thinness. Nothing floors the value: the number a run asked for is
        /// published in `EvaluationRunIdentity.bootstrapResamples`, and silently
        /// rewriting a parameter of the measurement is the one change a reader has
        /// the fewest means of discovering.
        public let resamples: Int
        public let seed: UInt64
        /// The Profile this run executed under, when the run named exactly one.
        /// PLAN §8.2 makes "correct" include the Profile component, so without it
        /// `precision_auto` and `high_confidence_error_rate` have no population; the
        /// per-Profile strata fill it in from their own key regardless.
        public let runProfileID: String?
        public init(resamples: Int = 2_000, seed: UInt64 = 0x9E37_79B9_7F4A_7C15,
                    runProfileID: String? = nil) {
            self.resamples = resamples
            self.seed = seed
            self.runProfileID = runProfileID
        }
    }

    /// The comparisons happen once per case and measure, per run Profile; every
    /// stratum reading that Profile gets the same table, because a cut is a
    /// selection, not a new measurement.
    public static func slices(for cases: [CaseJudgement], request: Request = Request()) -> [EvaluationSlice] {
        let measures = EvaluationMeasure.allCases
        let keys = cases.map(\.clusterKey)
        var tables: [String?: [[(numerator: Int, denominator: Int)]]] = [:]

        var output: [EvaluationSlice] = []
        for (stratum, key, sample) in cuts(of: cases) {
            // A per-Profile cut knows its own Profile; the rest of the run knows it
            // only if a single Profile was named. When it is not, the overall and
            // category rows leave `precision_auto` and `high_confidence_error_rate`
            // with no population - N/A, not 0% - and those two rates are read from
            // the per-Profile cuts, which is what they are for: a run that mixed
            // Vendor and Project Archive files has no single answer to "correct
            // under which Profile".
            let runProfile = stratum == .profile ? key : request.runProfileID
            let populations: [[(numerator: Int, denominator: Int)]]
            if let built = tables[runProfile] {
                populations = built
            } else {
                // `precision_auto` and `high_confidence_error_rate` are stated
                // relative to the Profile the run executed under, so a per-Profile
                // cut is the one place where the numbers genuinely differ; every
                // other cut in the run shares this table.
                populations = cases.map { judgement in
                    measures.map { $0.population(in: judgement, runProfile: runProfile) }
                }
                tables[runProfile] = populations
            }
            let summaries = ClusterBootstrap.summarize(measures: measures, populations: populations,
                                                       indices: sample, keys: keys,
                                                       resamples: request.resamples, seed: request.seed)
            for measure in measures {
                let summary = summaries[measure]!
                output.append(EvaluationSlice(measure: measure, stratum: stratum, key: key,
                                              caseCount: sample.count, clusterCount: summary.clusterCount,
                                              rate: summary.rate, clusterInterval: summary.interval))
            }
            if stratum == .overall {
                output.append(contentsOf: fieldRows(sample, cases))
            }
        }
        return output
    }

    /// Twelve `field_precision` rows, because a pooled number hides the one field
    /// that is actually failing - which for these profiles tends to be a date or an
    /// amount rather than the project name everyone watches.
    private static func fieldRows(_ sample: [Int], _ cases: [CaseJudgement]) -> [EvaluationSlice] {
        var rows: [EvaluationSlice] = []
        for field in MetadataFieldID.allCases {
            var numerator = 0
            var denominator = 0
            var contributing: [Int] = []
            for position in sample {
                guard let slot = cases[position].fields.first(where: { $0.field == field }) else { continue }
                let pair = EvaluationMeasure.fieldPrecision.population(in: slot)
                numerator += pair.numerator
                denominator += pair.denominator
                if pair.denominator > 0 { contributing.append(position) }
            }
            // Both counts stay in this row's own evidence: the records that asserted
            // something about this field, and the projects they came from. Filling
            // them from the whole cut would make `isSparse` measure the size of the
            // run rather than the thinness of the row, and a field with two
            // assertions out of forty records would be quotable on its own merits.
            rows.append(EvaluationSlice(measure: .fieldPrecision, stratum: .field, key: field.rawValue,
                                        caseCount: contributing.count,
                                        clusterCount: Set(contributing.map { cases[$0].clusterKey }).count,
                                        rate: EvaluationRate(numerator: numerator, denominator: denominator),
                                        clusterInterval: nil))
        }
        return rows
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
    /// PLAN §8.2 lists 拒判原因 beside the confusion matrix. The two answer
    /// different questions - confusion says which decision the engine reached, this
    /// says why the run did not publish what the reference answer expected - and they
    /// are reported in their own units, never summed.
    public struct Refusals: Codable, Sendable, Equatable {
        /// Records that did not go out on their own, by the decision state they
        /// stopped in, plus `absent` for sources the engine produced nothing for.
        public let byRecordState: [String: Int]
        /// Reference slots left unfilled, by the status the policy recorded for them.
        public let bySlotStatus: [String: Int]

        /// The keys come from the manifest's own vocabulary - `DecisionState` and
        /// `FieldOutcome.Status` raw values, plus `absent` for the engine having
        /// produced nothing - so a reader can look every one of them up.
    }

    public static func refusals(_ cases: [CaseJudgement]) -> Refusals {
        var states: [String: Int] = [:]
        var statuses: [String: Int] = [:]
        for judgement in cases {
            guard !judgement.isAutoMapped else { continue }
            let state = judgement.candidateState.map { $0.rawValue } ?? "absent"
            states[state, default: 0] += 1
            for field in judgement.fields where field.verdict == .withheld {
                let status = field.status.map { $0.rawValue } ?? "absent"
                statuses[status, default: 0] += 1
            }
        }
        return Refusals(byRecordState: states, bySlotStatus: statuses)
    }

    public static func confusion(_ cases: [CaseJudgement]) -> [String: Int] {
        Dictionary(grouping: cases, by: { "\($0.goldState.rawValue)->\($0.candidateState?.rawValue ?? "absent")" })
            .mapValues(\.count)
    }
}
