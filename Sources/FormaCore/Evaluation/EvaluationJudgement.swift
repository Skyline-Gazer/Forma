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
    /// The one use of this flag is §6's `eligibilityStateInconsistent` check, which
    /// asks whether a slot the program would publish sits on an entry that never
    /// reached `validated`. No rate reads it.
    public let autoPublishable: Bool

    public init(field: MetadataFieldID, verdict: Verdict, autoPublishable: Bool) {
        self.field = field
        self.verdict = verdict
        self.autoPublishable = autoPublishable
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

    /// PLAN §8.2's `auto_mapped`: the program's own policy would execute this
    /// mapping. That is the entry flag plus a `validated` state, and deliberately
    /// **not** the model's self-reported confidence - the plan says so out loud
    /// ("不能用模型自报 high 替代"), because a model that is confident about a
    /// rejected placement still gets rejected.
    public let isAutoMapped: Bool
    /// The three components PLAN §8.2 requires for a file-level prediction to count
    /// as correct. Each is stated separately so a wrong number can be traced to the
    /// component that made it wrong instead of being a single opaque boolean.
    ///
    /// An expectation the reference answer does not state (`nil`) is satisfied
    /// vacuously: the harness cannot invent a project or category the annotator
    /// left unspecified, and calling that unspecified thing a miss would penalise
    /// the run for the dataset's own silence.
    public let matchesProjectReference: Bool
    public let matchesTargetCategory: Bool
    /// The entry's declared confidence, kept apart from `isAutoMapped` because
    /// `high_confidence_error_rate` measures that claim, not the policy verdict.
    public let declaresHighConfidence: Bool

    /// Profile, project attribution, target category - all three, per PLAN §8.2.
    /// `runProfile` is nil when the run does not name a single Profile, in which
    /// case the first component cannot be established and no file counts as
    /// correct: an unanswerable check is reported as no measurement, never as a
    /// pass.
    public func mainDecisionIsCorrect(runProfile: String?) -> Bool {
        guard let runProfile else { return false }
        return profiles.contains(runProfile) && matchesProjectReference && matchesTargetCategory
    }

    /// `projectKeys` is the run's candidate table: the opaque `candidate_ref` the
    /// prompt issued mapped to the project cluster key it names, as
    /// `ProjectContext.candidates` states it (`ContextCandidate.id` →
    /// `ContextCandidate.projectKey`). It has to come from outside because the
    /// manifest never records a cluster key in an association: `ManifestValidator`
    /// writes `"context revision N candidate <ref>"`, while the reference answer
    /// names the cluster key (GOLD-DATASET「期望项目归属」). A judgement built
    /// without the table can still read the project from the metadata slot and the
    /// placement, but an entry whose only project evidence is an unresolved ref is
    /// judged as not matching - the alternative is scoring attribution correct
    /// because nobody could check it.
    public init(gold: GoldRecord, entry: ManifestEntry?, projectKeys: [String: String] = [:]) {
        self.recordID = gold.recordID
        self.profiles = gold.profiles
        self.category = gold.scenario.category
        self.clusterKey = gold.source.projectClusterKey
        self.goldState = gold.expected.state
        self.candidateState = entry?.state
        self.pendingAdjudication = gold.isPendingAdjudication
        self.fields = MetadataFieldID.allCases.map { FieldJudgement(gold: gold, field: $0, entry: entry) }
        self.isAutoMapped = entry.map { $0.state == .validated && $0.eligibleForAutoExecution } ?? false
        self.declaresHighConfidence = entry?.confidence == .high
        self.matchesProjectReference = CaseJudgement.matches(
            gold.expected.projectReference,
            in: entry.map { entry in
                CaseJudgement.attributedProjectKeys(in: entry, projectKeys: projectKeys)
                    + [entry.outcome(for: .projectname)?.value]
                    + entry.target.groupPath + [entry.target.databaseName]
            } ?? [])
        self.matchesTargetCategory = CaseJudgement.matches(gold.expected.targetCategory,
                                                           in: entry?.target.groupPath ?? [])
    }

    /// The cluster keys the entry's `project_candidate` associations stand for. The
    /// ref appears as a whitespace-separated token of the association basis, the only
    /// place production writes it; a basis naming several refs resolves to several
    /// keys.
    ///
    /// Where a file has more than one candidate, the association set is every project
    /// claiming it rather than the one the program picked, because
    /// `evaluateAssociation` records `candidateIDs` for all of them. That ambiguity
    /// does not reach `precision_auto`: a conflicted membership blocks eligibility, so
    /// such a record sits outside the population. The residual risk is a table built
    /// from a context whose conflicted set did not match its candidates.
    private static func attributedProjectKeys(in entry: ManifestEntry,
                                              projectKeys: [String: String]) -> [String?] {
        entry.associations.filter { $0.kind == .projectCandidate }.flatMap { link in
            let tokens = Set(link.basis.split(separator: " ").map(String.init))
            return projectKeys.compactMap { reference, key in tokens.contains(reference) ? key : nil }
        }
    }

    /// Same-value comparison as the validator's, against every candidate string the
    /// entry offers for that role.
    private static func matches(_ expected: String?, in candidates: [String?]) -> Bool {
        guard let expected, !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        return candidates.contains { ValueNormalization.equal($0, expected) }
    }
}
