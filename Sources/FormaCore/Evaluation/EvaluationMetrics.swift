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
    /// and `isQuotableOnOwnMerits` would then call it quotable. §3 item 2 of
    /// `docs/EVALUATION-METRICS.md` is where this rule is written out.
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
    // These three are the slot categories of §3 of `docs/EVALUATION-METRICS.md`; that
    // table is where membership is defined, so nothing is restated here.
    var isExpectationSlot: Bool { self != .allowedUnknown && self != .invented }
    var isNullExpectation: Bool { self == .allowedUnknown || self == .invented }
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
    /// Records this row's own evidence rests on - the unit `isSparse` reads, so the
    /// gate measures the thinness of the row rather than the size of the run. Which
    /// records those are for each row kind, and how the number relates to
    /// `rate.denominator`, is stated once in §3 item 7 and §5 of
    /// `docs/EVALUATION-METRICS.md`.
    public let caseCount: Int
    /// Clusters this row's evidence rests on, published so a nil `clusterInterval`
    /// can be told apart: too few clusters to vary, this measure too thin in some draw,
    /// or fewer draws than `ClusterBootstrap.minimumResamples` (§5). A `field_precision`
    /// `.field` row sits outside that rule: it never has a cluster interval, by
    /// construction rather than by any verdict on the data, and its `clusterCount` only
    /// states how many projects asserted the field.
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

    /// The floor below which a run gets its rates without any cluster bands.
    ///
    /// At two draws or fewer the 2.5th and 97.5th percentile resolve to the same
    /// sample and the band has zero width - a rounding artefact published as
    /// uncertainty. Above that the indices separate, but nearest-rank percentiles of a
    /// handful of draws are the sample extremes: with twenty draws the lower bound is
    /// the minimum and the upper the maximum, which reads as a 95% band while stating
    /// only what the few clusters observed. Twenty is where reporting that band stops
    /// being defensible as a description of the sampling, not a mathematical boundary,
    /// and like `minimumClusters` and `EvaluationSlice.sparseCaseLimit` it is harness
    /// policy rather than a clause lifted from SPEC or PLAN (docs §5).
    public static let minimumResamples = 20

    /// One measure's rate over a sample, with its cluster interval.
    public struct Summary: Sendable, Equatable {
        public let rate: EvaluationRate
        public let interval: ClosedRange<Double>?
        /// Clusters in the sample, which tells a nil interval apart: `clusterCount`
        /// below `minimumClusters` means the stratum cannot vary, enough clusters
        /// means either this measure was too thin to survive every draw or the run
        /// asked for fewer than `minimumResamples` draws, where a band would be either
        /// zero-width (two draws) or just the extremes of a handful of samples. Nothing
        /// floors that request - it is recorded in `EvaluationRunIdentity`, so a
        /// reader tells the third cause from the second by the run's own resample
        /// count rather than by a silent correction.
        public let clusterCount: Int
    }

    /// One judged record's contribution to a bootstrap sample.
    ///
    /// The cluster key travels with the columns rather than arriving as a parallel
    /// array because `indices` selects positions in this one: with two parameters a
    /// caller can hand over the same length in a different order, and every row then
    /// gets charged to whichever project happens to sit at its index.
    public struct Row: Sendable {
        public let clusterKey: String
        /// One entry per measure, in `EvaluationMeasure.allCases` order.
        public let columns: [(numerator: Int, denominator: Int)]

        public init(clusterKey: String, columns: [(numerator: Int, denominator: Int)]) {
            self.clusterKey = clusterKey
            self.columns = columns
        }
    }

    /// Rate and interval for the requested measures over one sample.
    ///
    /// `rows` is the whole corpus, built once per run Profile by the caller - the slot
    /// comparisons behind it are the part worth sharing - and `indices` picks this
    /// stratum's rows out of it. Per stratum this function adds
    /// `O(measures x rows in this stratum)` integer pairs, because a per-Profile or
    /// per-category rate is a genuinely different sum.
    public static func summarize(measures: [EvaluationMeasure] = EvaluationMeasure.allCases,
                                 rows: [Row], indices: [Int],
                                 resamples: Int = 2_000, seed: UInt64 = 0x9E37_79B9_7F4A_7C15)
        -> [EvaluationMeasure: Summary] {
        guard !measures.isEmpty else { return [:] }
        // A subset request still reads the columns built for the full order.
        let columns = measures.map { EvaluationMeasure.allCases.firstIndex(of: $0)! }
        precondition(rows.allSatisfy { $0.columns.count == EvaluationMeasure.allCases.count },
                     "Row.columns holds one entry per measure, in `EvaluationMeasure.allCases` "
                         + "order; a subset `measures` request still reads those columns")

        // This stratum's positions, grouped by the cluster that owns them - built first
        // so a stratum with nothing to vary still reports why, and used as-is for the
        // totals below, so a row's cluster is read in exactly one place.
        var grouped: [String: [Int]] = [:]
        for offset in indices.indices {
            grouped[rows[indices[offset]].clusterKey, default: []].append(offset)
        }
        let clusterCount = grouped.count

        // Sorted because the draw indices mean something: a published band has to be
        // reproducible in another process, and dictionary order is not. Nothing
        // in-process can observe that - Swift fixes one dictionary's order for the life
        // of the process, so no test here would fail if the sort went away; it is the
        // run recorded twice on two machines that would disagree. The pooled rate is
        // then the sum of these cluster rows: one pass over the rows of this stratum,
        // and the same integers either way.
        let members = grouped.sorted { $0.key < $1.key }.map(\.value)
        var clusterTotals: [[(numerator: Int, denominator: Int)]] =
            members.map { _ in Array(repeating: (numerator: 0, denominator: 0), count: measures.count) }
        for (slot, offsets) in members.enumerated() {
            for offset in offsets {
                let source = rows[indices[offset]].columns
                for position in measures.indices {
                    clusterTotals[slot][position].numerator += source[columns[position]].numerator
                    clusterTotals[slot][position].denominator += source[columns[position]].denominator
                }
            }
        }

        var output: [EvaluationMeasure: Summary] = [:]
        for (position, measure) in measures.enumerated() {
            var numerator = 0
            var denominator = 0
            for totals in clusterTotals {
                numerator += totals[position].numerator
                denominator += totals[position].denominator
            }
            output[measure] = Summary(rate: EvaluationRate(numerator: numerator, denominator: denominator),
                                      interval: nil, clusterCount: clusterCount)
        }

        guard clusterCount >= minimumClusters, resamples >= minimumResamples else { return output }

        var generator = SplitMix64(seed: seed)
        var ratios: [[Double]] = measures.map { _ in [] }
        // Voiding is per measure: an undefined draw for `precision_auto` must not
        // also take away the draws of every measure listed after it.
        var voided = measures.map { _ in false }
        for _ in 0..<resamples {
            let picks = (0..<clusterCount).map { _ in Int(generator.next() % UInt64(clusterCount)) }
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
            // Not voided means every draw contributed a defined ratio, so this is
            // exactly `resamples` samples. The guard above also holds the run at
            // `minimumResamples`, and at twenty the two order statistics resolve to
            // indices 0 and 18 - `Int((n - 1) * 0.975) - Int((n - 1) * 0.025)`, which
            // widens with n. `singleDrawHasNoBand` is where that separation is tested;
            // `minimumResamples`'s own comment is where the choice of twenty is argued,
            // as opposed to the arithmetic minimum of two that merely separates them.
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
        /// Draws behind every `clusterInterval` in this run; below
        /// `ClusterBootstrap.minimumResamples` a row gets its rate with a nil band for
        /// that reason rather than for thinness. That constant and §5 of
        /// `docs/EVALUATION-METRICS.md` are where the reason is written once; nothing
        /// here raises the caller's number, and in a report the number comes from
        /// `EvaluationRunIdentity.bootstrapResamples`.
        public let resamples: Int
        public let seed: UInt64
        /// The Profile this run executed under, when the run named exactly one.
        /// PLAN §8.2 makes "correct" include the Profile component, so without it
        /// `precision_auto` and `high_confidence_error_rate` have no population; the
        /// per-Profile strata fill it in from their own key regardless.
        public let runProfileID: String?
        public init(resamples: Int = 2_000, seed: UInt64 = 0x9E37_79B9_7F4A_7C15,
                    runProfileID: String? = nil) {
            precondition(resamples >= 1, "a bootstrap needs at least one draw; zero asks for no measurement")
            self.resamples = resamples
            self.seed = seed
            self.runProfileID = runProfileID
        }
    }

    /// The comparisons happen once per case and measure for each distinct
    /// attribution, then every stratum reading that attribution takes its rows from
    /// the cache - a cut is a selection, not a new measurement. Cuts under different
    /// attributions are genuinely different measurements and get different tables;
    /// §3 item 2 of `docs/EVALUATION-METRICS.md` is where that consequence is written.
    public static func slices(for cases: [CaseJudgement], request: Request = Request()) -> [EvaluationSlice] {
        let measures = EvaluationMeasure.allCases
        var tables: [String?: [ClusterBootstrap.Row]] = [:]

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
            let table: [ClusterBootstrap.Row]
            if let built = tables[runProfile] {
                table = built
            } else {
                // One table per distinct attribution, not one per stratum: the
                // overall and category rows share whichever table matches the run's
                // own, and each Profile cut gets its own because `precision_auto` and
                // `high_confidence_error_rate` are stated relative to the Profile that
                // executed. With nothing named for the run those two columns are empty
                // in the nil-attribution table, which is what makes the pooled rows
                // read N/A rather than 0%. Cuts under different attributions are
                // different measurements, which is why they are not shared.
                table = cases.map { judgement in
                    ClusterBootstrap.Row(clusterKey: judgement.clusterKey,
                                         columns: measures.map {
                                             $0.population(in: judgement, runProfile: runProfile)
                                         })
                }
                tables[runProfile] = table
            }
            let summaries = ClusterBootstrap.summarize(measures: measures, rows: table, indices: sample,
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
        /// Reference slots left unfilled, by the status the policy recorded for
        /// them, counted over every judged record - including ones that went out on
        /// their own with fields empty, which is where an incomplete auto-publish
        /// shows up. Its total is `missed_fill_rate`'s numerator for the same set.
        public let bySlotStatus: [String: Int]

        /// The keys come from the manifest's own vocabulary - `DecisionState` and
        /// `FieldOutcome.Status` raw values, plus `absent` for the engine having
        /// produced nothing - so a reader can look every one of them up.
    }

    public static func refusals(_ cases: [CaseJudgement]) -> Refusals {
        var states: [String: Int] = [:]
        var statuses: [String: Int] = [:]
        for judgement in cases {
            if !judgement.isAutoMapped {
                let state = judgement.candidateState.map { $0.rawValue } ?? "absent"
                states[state, default: 0] += 1
            }
            // The slot half is unconditional, because the two halves answer
            // different questions. A record that went out on its own with three
            // fields empty is not a refusal at file level and is exactly the
            // reviewer's work at slot level - and skipping it here would hide the
            // incomplete auto-publishes, which is the case the report most needs a
            // reason for. It also makes this dictionary line up with
            // `missed_fill_rate`'s numerator instead of with some subset of it.
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
