import Foundation

/// One field of one reference answer judged against one candidate.
///
/// The six verdicts are not a convenience: PLAN §8.2 defines each metric over a
/// differently restricted population - `coverage` excludes contradicted candidates,
/// `precision_auto` additionally restricts to what the program would publish,
/// `field_precision` does not - and a single "was it right" boolean cannot serve
/// all three without quietly redefining their denominators.
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
    /// Whether this slot is excluded from every denominator. Only the slots the
    /// reference answer itself declares unknown, where neither an empty nor a
    /// filled candidate is evidence about the model.
    public let excluded: Bool
    public let autoPublishable: Bool
    public let highConfidence: Bool

    public init(field: MetadataFieldID, verdict: Verdict, excluded: Bool, autoPublishable: Bool,
                highConfidence: Bool) {
        self.field = field
        self.verdict = verdict
        self.excluded = excluded
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
        // The entry's own accessor, so "which outcome describes this field" has
        // one definition even if the lookup ever becomes anything but a linear scan.
        let outcome = entry?.outcome(for: field)
        // An empty or whitespace-only value is not a claim about the field, so it
        // is withheld rather than wrong. `ValueNormalization.equal` already
        // refuses to let an empty string agree with anything; letting it count as
        // an assertion would put a "wrong" in `field_precision` for a slot the
        // engine never actually filled.
        let candidateValue = (outcome?.value).flatMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
        let allowsUnknown = gold.expected.allowedUnknownFields.contains(field)

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
        self.excluded = allowsUnknown && goldValue == nil
        // `eligibleForAutoExecution` is the Validator's verdict about the whole
        // entry; a slot is publishable only if the entry is, and the slot itself
        // stands on a citation of a supportable kind. Re-deriving either half here
        // would let the measurement disagree with the program that decides.
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
    public let fields: [FieldJudgement]

    public init(gold: GoldRecord, entry: ManifestEntry?) {
        self.recordID = gold.recordID
        self.profiles = gold.profiles
        self.category = gold.scenario.category
        self.clusterKey = gold.source.projectClusterKey
        self.goldState = gold.expected.state
        self.candidateState = entry?.state
        self.fields = MetadataFieldID.allCases.map { FieldJudgement(gold: gold, field: $0, entry: entry) }
    }
}
