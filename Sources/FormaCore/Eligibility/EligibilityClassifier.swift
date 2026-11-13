import Foundation

// The classifier: pure, deterministic, and deliberately small.
//
// It reads the facts it was handed, matches the policy's declarative rules, and
// applies a fixed set of structural guards. The guards are the part that makes
// the safety properties true even if a policy is edited badly:
//
//   * an EXCLUDE never survives confirmed business evidence;
//   * an EXCLUDE never survives on weak evidence (the policy loader rejects such
//     a rule, and the classifier downgrades it anyway);
//   * a missing entry, a path collision, a moved snapshot, an access failure or
//     an incomplete scan produce DEFER, not a guess;
//   * a rule that needs document content cannot decide a dataless file.
//
// Nothing here reads a file, opens a socket, calls a model or runs a command.

/// One rule that matched, kept so a reviewer can see every candidate reason and
/// not only the winner.
public struct EligibilityRuleMatch: Codable, Sendable, Equatable {
    public let ruleID: String
    public let priority: Int
    public let decision: EligibilityDecision
    public let evidenceStrength: EligibilityEvidenceStrength
    public let explanationCode: String

    init(_ rule: EligibilityRule) {
        ruleID = rule.ruleID
        priority = rule.priority
        decision = rule.decision
        evidenceStrength = rule.evidenceStrength
        explanationCode = rule.explanationCode
    }
}

public struct EligibilityClassification: Sendable, Equatable {
    public let decision: EligibilityDecision
    /// Every matching rule, highest priority first.
    public let matchedRules: [EligibilityRuleMatch]
    public let decidedByRuleID: String?
    public let explanationCode: String
    public let followUp: EligibilityFollowUp?
    /// Structural facts that changed or qualified the rule's outcome.
    public let notes: [String]

    init(decision: EligibilityDecision, matchedRules: [EligibilityRuleMatch] = [],
         decidedByRuleID: String? = nil, explanationCode: String,
         followUp: EligibilityFollowUp? = nil, notes: [String] = []) {
        self.decision = decision
        self.matchedRules = matchedRules
        self.decidedByRuleID = decidedByRuleID
        self.explanationCode = explanationCode
        self.followUp = followUp
        self.notes = notes
    }

    public var matchedRuleIDs: [String] { matchedRules.map(\.ruleID) }
}

public enum EligibilityClassifier {
    /// The structural reason codes. Kept as constants so a report and a test
    /// name the same string.
    public enum Reason {
        public static let sourceMissing = "source_missing"
        public static let pathCollision = "path_collision"
        public static let snapshotChanged = "snapshot_changed"
        public static let accessFailed = "access_failed"
        public static let scanIncomplete = "scan_incomplete"
        public static let policyNotApplicable = "policy_not_applicable"
        public static let businessEvidenceOverridesExclusion = "business_evidence_overrides_exclusion"
        public static let exclusionNeedsStrongEvidence = "exclusion_needs_strong_evidence"
        public static let contentNotRead = "content_not_read"
        public static let contentNotHydrated = "content_not_hydrated"
        public static let noRuleMatched = "no_rule_matched"
        public static let ownerIncludeOverride = "owner_include_override"
        public static let ownerExcludeOverride = "owner_exclude_override"
        public static let overrideBlockedByDefer = "override_blocked_by_defer"
        public static let overrideBlockedByBusinessEvidence = "override_blocked_by_business_evidence"
        public static let gitTrackedProtected = "git_tracked_protected"
        public static let nestedRepositoryProtected = "nested_repository_protected"
        public static let sourceCodeProtected = "source_code_protected"
    }

    /// Why an otherwise strong exclusion must not be applied. Ordered by how
    /// decisive the protection is: confirmed business material first, then the
    /// facts that make a file part of a working project rather than noise.
    private static func protectionAgainstExclusion(_ facts: EligibilityFacts)
        -> (String, EligibilityFollowUp)?
    {
        if facts.businessEvidence == .confirmed {
            return (Reason.businessEvidenceOverridesExclusion, .confirmBusinessUse)
        }
        if facts.gitTracked == .yes {
            return (Reason.gitTrackedProtected, .confirmBusinessUse)
        }
        if facts.nestedRepository == .yes {
            return (Reason.nestedRepositoryProtected, .confirmNestedRepository)
        }
        if facts.sourceCodeOrDeployment == .yes {
            return (Reason.sourceCodeProtected, .confirmSourceCode)
        }
        return nil
    }

    public static func classify(_ facts: EligibilityFacts, policy: EligibilityPolicy) -> EligibilityClassification {
        let matched = policy.orderedRules.filter { $0.matches(facts) }.map(EligibilityRuleMatch.init)
        let winner = matched.first
        let entry = facts.entry

        // 1. The entry itself cannot be decided from this listing.
        if entry.state == .missing {
            return EligibilityClassification(decision: .defer, matchedRules: matched,
                                             decidedByRuleID: winner?.ruleID,
                                             explanationCode: Reason.sourceMissing,
                                             followUp: .reconcileSnapshot)
        }
        if facts.pathCollision {
            return EligibilityClassification(decision: .defer, matchedRules: matched,
                                             decidedByRuleID: winner?.ruleID,
                                             explanationCode: Reason.pathCollision,
                                             followUp: .resolvePathCollision)
        }
        if facts.snapshotChanged {
            return EligibilityClassification(decision: .defer, matchedRules: matched,
                                             decidedByRuleID: winner?.ruleID,
                                             explanationCode: Reason.snapshotChanged,
                                             followUp: .reconcileSnapshot)
        }
        let accessReasons: Set<String> = [SourceScanIssue.Reason.authorization.rawValue,
                                          SourceScanIssue.Reason.unreadable.rawValue]
        if facts.scanIssues.contains(where: { accessReasons.contains($0.reason.rawValue) }) {
            return EligibilityClassification(decision: .defer, matchedRules: matched,
                                             decidedByRuleID: winner?.ruleID,
                                             explanationCode: Reason.accessFailed,
                                             followUp: .restoreAccess)
        }

        // 2. A strong exclusion does not depend on a complete scan: a `.DS_Store`
        //    is technical noise whether or not another directory was unreadable.
        //    But strong evidence is not enough on its own: tracked content, a
        //    nested repository, source/deployment files and confirmed business
        //    material are protected even inside a cache directory.
        if let winner, winner.decision == .exclude {
            guard winner.evidenceStrength == .strong else {
                return EligibilityClassification(decision: .review, matchedRules: matched,
                                                 decidedByRuleID: winner.ruleID,
                                                 explanationCode: Reason.exclusionNeedsStrongEvidence,
                                                 followUp: .confirmBusinessUse)
            }
            if let protection = protectionAgainstExclusion(facts) {
                return EligibilityClassification(decision: .review, matchedRules: matched,
                                                 decidedByRuleID: winner.ruleID,
                                                 explanationCode: protection.0,
                                                 followUp: protection.1)
            }
            return EligibilityClassification(decision: .exclude, matchedRules: matched,
                                             decidedByRuleID: winner.ruleID,
                                             explanationCode: winner.explanationCode)
        }

        // 3. Everything else needs a complete scan: an incomplete one leaves the
        //    facts a REVIEW or INCLUDE would rest on unchecked.
        guard facts.scanState == .complete else {
            return EligibilityClassification(decision: .defer, matchedRules: matched,
                                             decidedByRuleID: winner?.ruleID,
                                             explanationCode: Reason.scanIncomplete,
                                             followUp: .completeScan)
        }

        // 4. The winning rule, with the content guard.
        if let winner {
            guard !(winner.decision == .exclude) else {
                // Defensive: a policy that slipped past validation still cannot
                // exclude on weak evidence.
                return EligibilityClassification(decision: .review, matchedRules: matched,
                                                 decidedByRuleID: winner.ruleID,
                                                 explanationCode: Reason.exclusionNeedsStrongEvidence,
                                                 followUp: .confirmBusinessUse)
            }
            var notes: [String] = []
            if entry.hydrationPending { notes.append(Reason.contentNotHydrated) }
            if winner.decision != .defer, ruleNeedsContent(winner, policy: policy), entry.hydrationPending {
                return EligibilityClassification(decision: .defer, matchedRules: matched,
                                                 decidedByRuleID: winner.ruleID,
                                                 explanationCode: Reason.contentNotRead,
                                                 followUp: .hydrateBeforeMapping)
            }
            return EligibilityClassification(decision: winner.decision, matchedRules: matched,
                                             decidedByRuleID: winner.ruleID,
                                             explanationCode: winner.explanationCode,
                                             followUp: followUp(for: winner, policy: policy),
                                             notes: notes)
        }

        // 5. No rule matched. Conservative default: a person looks.
        return EligibilityClassification(decision: .review, matchedRules: [],
                                         explanationCode: Reason.noRuleMatched,
                                         followUp: .confirmBusinessUse)
    }

    /// The policy is a value; the classifier needs the rule body to know whether
    /// it declared a content requirement, and the match only keeps the summary.
    private static func ruleNeedsContent(_ match: EligibilityRuleMatch, policy: EligibilityPolicy) -> Bool {
        policy.rules.first { $0.ruleID == match.ruleID }?.requiresContentEvidence ?? false
    }

    private static func followUp(for match: EligibilityRuleMatch, policy: EligibilityPolicy) -> EligibilityFollowUp? {
        policy.rules.first { $0.ruleID == match.ruleID }?.followUp
    }

    /// Every entry of a listing that cannot be classified because the policy was
    /// written for other profiles. Stated rather than silently defaulted.
    public static func notApplicable() -> EligibilityClassification {
        EligibilityClassification(decision: .defer, explanationCode: Reason.policyNotApplicable)
    }
}
