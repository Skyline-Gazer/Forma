import Foundation

/// One field of one reference answer judged against one candidate.
///
/// The six verdicts are not a convenience: PLAN §8.2 defines each metric over a
/// differently restricted population, and a single "was it right" boolean cannot
/// serve them without quietly redefining their denominators. What each one counts
/// is defined once, in `docs/EVALUATION-METRICS.md` §3; the wording there is
/// deliberately fussy (a contradicted slot, for instance, stays in `coverage`'s
/// denominator and only fails to enter its numerator) because "excludes
/// contradicted" read loosely shrinks a denominator someone will later quote.
public struct FieldJudgement: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable, CaseIterable {
        /// Candidate states a value and it agrees with the reference answer.
        case correct
        /// Candidate states a value that disagrees. Contradiction is separate:
        /// a value the validator found fought by other evidence is not merely
        /// wrong, it is a value that must never auto-publish.
        case wrong
        /// Candidate states a value the entry itself carries a conflict for.
        case contradicted
        /// The reference answer has a value and the candidate gave none: this is
        /// the miss `coverage` and `hold_rate` count, not an error.
        case withheld
        /// The reference answer has no value and the candidate produced one -
        /// the fill the 空漏填 side of the contract is about, and the reason a
        /// high field count is not by itself good news.
        case invented
        /// Neither side has a value: correct withholding, and the state
        /// `allowed_unknown_fields` is designed to make reachable.
        case allowedUnknown
    }

    public let field: MetadataFieldID
    public let verdict: Verdict
    public let autoPublishable: Bool
    public let highConfidence: Bool

    public init(field: MetadataFieldID, verdict: Verdict, autoPublishable: Bool, highConfidence: Bool) {
        self.field = field
        self.verdict = verdict
        self.autoPublishable = autoPublishable
        self.highConfidence = highConfidence
    }

    /// Judge one slot of a gold record against one engine entry.
    ///
    /// `entry` is nil when the engine produced nothing for this source at all:
    /// then every reference value is withheld, and no slot can be called
    /// contradicted or auto-publishable, because there is no candidate to publish.
    public init(gold: GoldRecord, field: MetadataFieldID, entry: ManifestEntry?) {
        let goldValue = gold.expected.metadata[field] ?? nil
        let outcome = entry?.outcome(for: field)
        // An empty or whitespace-only value is not a claim about the field, so it
        // is withheld rather than wrong. `ValueNormalization.equal` already
        // refuses to let an empty string agree with anything; letting it count as
        // an assertion would put a "wrong" in `field_precision` for a slot the
        // engine never actually filled.
        let candidateValue = (outcome?.value).flatMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }

        let verdict: Verdict
        if goldValue == nil, candidateValue == nil {
            verdict = .allowedUnknown
        } else if goldValue == nil {
            verdict = .invented
        } else if candidateValue == nil {
            verdict = .withheld
        } else if outcome?.conflicts.isEmpty == false {
            verdict = .contradicted
        } else {
            verdict = ValueNormalization.equal(candidateValue, goldValue) ? .correct : .wrong
        }

        self.field = field
        self.verdict = verdict
        // The entry-level half is taken as given: `computeEligibility` already
        // requires `validated`, a resolved target, no slot in `.conflict`, and that
        // *some* slot cites a record that still matches this snapshot. What it does
        // not require is that the slot being measured cites anything itself - the
        // citation set is a union across the entry - and it says nothing about a
        // slot sitting in `unknown`, `rejected_by_policy` or `not_applicable` while
        // carrying a value. Those two are the slot-level half added here, and the
        // only reason `precision_auto` is not simply the entry flag.
        self.autoPublishable = entry?.eligibleForAutoExecution == true
            && (outcome.map { Self.publishableStatuses.contains($0.status) && !$0.evidenceIDs.isEmpty } ?? false)
        self.highConfidence = entry?.confidence == .high
    }

    /// The field statuses a publication decision may rest on. `unknown`,
    /// `conflict`, `rejected_by_policy` and `not_applicable` are excluded because
    /// the engine itself refuses to publish on them.
    static let publishableStatuses: Set<FieldOutcome.Status> = [.evidenced, .inherited]
}

/// One reference answer judged as a whole.
public struct CaseJudgement: Codable, Sendable, Equatable {
    public let recordID: String
    public let profiles: [String]
    public let category: GoldRecord.Category
    /// Resampling happens over this key, never over records: two files of one
    /// project are not two independent observations, and treating them as such
    /// is how a cluster of near-identical documents manufactures confidence.
    public let clusterKey: String
    public let goldState: DecisionState
    /// nil when the engine returned nothing for this source.
    public let candidateState: DecisionState?
    /// The reference answer was not agreed between annotators, so PLAN §8.1 keeps
    /// it out of every accuracy denominator. Carried here because the report has to
    /// be able to tell that a case set was filtered, rather than being told.
    public let pendingAdjudication: Bool
    public let fields: [FieldJudgement]

    public init(gold: GoldRecord, entry: ManifestEntry?) {
        self.recordID = gold.recordID
        self.profiles = gold.profiles
        self.category = gold.scenario.category
        self.clusterKey = gold.source.projectClusterKey
        self.goldState = gold.expected.state
        self.candidateState = entry?.state
        self.pendingAdjudication = gold.isPendingAdjudication
        self.fields = MetadataFieldID.allCases.map { FieldJudgement(gold: gold, field: $0, entry: entry) }
    }
}
