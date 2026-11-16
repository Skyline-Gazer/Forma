import Foundation

/// One record in an eligibility report.
///
/// Path-free by construction: a source id, the decision, the rule that made
/// it, the reason code and the override state. The file name never appears,
/// because a report that names files is a report that leaks the directory it
/// describes.
public struct EligibilityReportRecord: Codable, Sendable, Equatable {
    public let sourceID: UUID
    public let decision: EligibilityDecision
    public let decidedByRuleID: String?
    public let explanationCode: String
    public let overrideState: EligibilityOverrideState
    /// Whether this record entered Mapping.
    public let mapped: Bool

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id", decision
        case decidedByRuleID = "decided_by_rule_id"
        case explanationCode = "explanation_code", overrideState = "override_state", mapped
    }

    public init(sourceID: UUID, decision: EligibilityDecision, decidedByRuleID: String?,
                explanationCode: String, overrideState: EligibilityOverrideState, mapped: Bool) {
        self.sourceID = sourceID
        self.decision = decision
        self.decidedByRuleID = decidedByRuleID
        self.explanationCode = explanationCode
        self.overrideState = overrideState
        self.mapped = mapped
    }
}

/// What the eligibility filter did, in a form a person can act on
/// (SPEC v0.1.2 §10.1-5).
///
/// The report answers the question a filtered Manifest raises on its own:
/// "which records did not enter Mapping, and why?" — per record, per decision
/// and per rule, with the counts that make the answer checkable.
///
/// It is a Core type on purpose. The numbers a run produces must exist before
/// any interface shows them, and the interface must not be the only place they
/// can be had.
public struct EligibilityReport: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let policyID: String
    public let policyVersion: String
    public let policyDigest: String
    public let decisionsDigest: String
    /// Records the scan discovered.
    public let discovered: Int
    /// Records that entered Mapping.
    public let mapped: Int
    /// Records that did not.
    public let unmapped: Int
    /// Count per decision, over every discovered record.
    public let perDecision: [String: Int]
    /// Count per deciding rule, over every discovered record.
    public let perRule: [String: Int]
    /// The per-record explanation.
    public let records: [EligibilityReportRecord]
    /// The five eligibility metrics, with their denominators.
    public let metrics: EligibilityMetrics

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", policyID = "policy_id"
        case policyVersion = "policy_version", policyDigest = "policy_digest"
        case decisionsDigest = "decisions_digest", discovered, mapped, unmapped
        case perDecision = "per_decision", perRule = "per_rule", records, metrics
    }

    public init(schemaVersion: String = "1.0", policyID: String, policyVersion: String, policyDigest: String,
                decisionsDigest: String, discovered: Int, mapped: Int, unmapped: Int,
                perDecision: [String: Int], perRule: [String: Int], records: [EligibilityReportRecord],
                metrics: EligibilityMetrics) {
        self.schemaVersion = schemaVersion
        self.policyID = policyID
        self.policyVersion = policyVersion
        self.policyDigest = policyDigest
        self.decisionsDigest = decisionsDigest
        self.discovered = discovered
        self.mapped = mapped
        self.unmapped = unmapped
        self.perDecision = perDecision
        self.perRule = perRule
        self.records = records
        self.metrics = metrics
    }

    /// The conservation identity a report must satisfy: every discovered
    /// record is either mapped or not, and the numbers say so.
    public var isConserved: Bool { discovered == mapped + unmapped }
}

extension EligibilityView {
    /// Builds the report of a run that mapped `mappedSourceIDs` out of this
    /// view.
    ///
    /// `mappedSourceIDs` is what the run actually mapped, so the report
    /// reflects the run rather than the policy's own opinion of it.
    public func report(mappedSourceIDs: Set<UUID>) -> EligibilityReport {
        var perDecision: [String: Int] = [:]
        var perRule: [String: Int] = [:]
        let records = entries.map { item -> EligibilityReportRecord in
            perDecision[item.decision.rawValue, default: 0] += 1
            let rule = item.decidedByRuleID ?? "undecided"
            perRule[rule, default: 0] += 1
            return EligibilityReportRecord(sourceID: item.sourceID, decision: item.decision,
                                           decidedByRuleID: item.decidedByRuleID,
                                           explanationCode: item.explanationCode,
                                           overrideState: item.overrideState,
                                           mapped: mappedSourceIDs.contains(item.sourceID))
        }
        let mapped = records.filter(\.mapped).count
        return EligibilityReport(
            policyID: policyID, policyVersion: policyVersion, policyDigest: policyDigest,
            decisionsDigest: decisionsDigest(), discovered: entries.count, mapped: mapped,
            unmapped: entries.count - mapped, perDecision: perDecision, perRule: perRule,
            records: records, metrics: metrics)
    }
}
