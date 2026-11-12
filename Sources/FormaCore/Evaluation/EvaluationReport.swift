import Foundation

/// What produced a measurement, recorded with the numbers (PLAN §8.1).
public struct EvaluationRunIdentity: Codable, Sendable, Equatable {
    public let goldRevision: String
    public let splitID: String
    public let casePackID: String
    public let casePackVersion: String
    /// Profile id -> version key, so a re-run against an edited Profile cannot be
    /// mistaken for the same measurement.
    public let profileVersionKeys: [String: String]
    public let provider: String
    public let modelID: String?
    /// True when the answers came from a deterministic stand-in rather than a
    /// model. Every quality claim is refused while this is true.
    public let isSubstitute: Bool
    public let bootstrapResamples: Int
    public let bootstrapSeed: UInt64

    public init(goldRevision: String, splitID: String, casePackID: String, casePackVersion: String,
                profileVersionKeys: [String: String], provider: String, modelID: String?, isSubstitute: Bool,
                bootstrapResamples: Int, bootstrapSeed: UInt64) {
        self.goldRevision = goldRevision
        self.splitID = splitID
        self.casePackID = casePackID
        self.casePackVersion = casePackVersion
        self.profileVersionKeys = profileVersionKeys
        self.provider = provider
        self.modelID = modelID
        self.isSubstitute = isSubstitute
        self.bootstrapResamples = bootstrapResamples
        self.bootstrapSeed = bootstrapSeed
    }
}

/// Judged cases turned into a measurement, and the gate between "measured" and
/// "claimable".
///
/// The gate lives here rather than in whoever writes a summary, because the
/// tempting version of a summary is the one that omits the conditions.
public struct EvaluationReport: Codable, Sendable, Equatable {
    /// Why a run cannot carry a quality claim, or what it must disclose.
    public enum Blocker: String, Codable, Sendable, CaseIterable {
        /// Answers came from a deterministic stand-in.
        case substituteAnswers
        /// Fewer verified real samples than PLAN §8.1 requires.
        case insufficientIndependentSamples
        /// The evaluation set touches the prompt set without a declared removal.
        case undeclaredPromptOverlap
        /// Records in the directory that the split accounts for nowhere.
        case unaccountedRecords
        /// Disputed records were excluded from the denominators - disclosed, not
        /// disqualifying: a run with a few pending adjudications still measures
        /// what it measured, and hiding that fact would be the worse error.
        case pendingAdjudicationExcluded
        /// A candidate carries auto-publishable slots on an entry that is not
        /// `validated`, which is the same inconsistency `ManifestExport` reports as
        /// `eligibility_state`. Judged here rather than repaired here: a rate
        /// measured over a manifest the program would refuse to write is not a rate
        /// about this program, so the run loses the claim instead of the metrics
        /// layer quietly inventing a filter that hides the disagreement.
        case eligibilityStateInconsistent

        var preventsQualityClaim: Bool { self != .pendingAdjudicationExcluded }
    }

    /// A reason, with the count that produced it.
    public struct Finding: Codable, Sendable, Equatable {
        public let kind: Blocker
        public let detail: String
    }

    public let identity: EvaluationRunIdentity
    public let cases: Int
    public let clusters: Int
    public let slices: [EvaluationSlice]
    public let confusion: [String: Int]
    /// The dataset's own integrity findings, kept beside the rates they qualify.
    public let dataset: GoldDataset.Report
    public let claimBlockers: [Finding]
    public let isQualityClaimAllowed: Bool
    /// Measures whose overall denominator is large enough to quote at all
    /// (SPEC §10.1.6: below 30 observations a value is candidate only).
    public let quotableMeasures: [EvaluationMeasure]

    public init(cases: [CaseJudgement], identity: EvaluationRunIdentity, dataset: GoldDataset.Report,
                request: EvaluationMetrics.Request = EvaluationMetrics.Request()) {
        let grouped = Dictionary(grouping: cases, by: \.clusterKey)
        self.identity = identity
        self.cases = cases.count
        self.clusters = grouped.count
        let computedSlices = EvaluationMetrics.slices(for: cases, request: request)
        self.slices = computedSlices
        self.confusion = EvaluationMetrics.confusion(cases)
        self.dataset = dataset

        var blockers: [Finding] = []
        if identity.isSubstitute {
            blockers.append(Finding(kind: .substituteAnswers,
                                    detail: "答案来自确定性替身（\(identity.provider)），不反映任何真实模型的映射质量。"))
        }
        if !dataset.meetsIndependentTarget {
            blockers.append(Finding(kind: .insufficientIndependentSamples,
                                    detail: "独立核实的真实样本为 \(dataset.reviewedCountable) 条，低于 PLAN §8.1 要求的 "
                                        + "\(dataset.requiredMinimum) 条。"))
        }
        let inconsistent = cases.filter { judgement in
            judgement.candidateState != .validated && judgement.fields.contains(where: \.autoPublishable)
        }
        if !inconsistent.isEmpty {
            blockers.append(Finding(kind: .eligibilityStateInconsistent,
                                    detail: "\(inconsistent.count) 条候选在未达到 `validated` 的条目上带有可自动发布的槽位，"
                                        + "与导出校验的 eligibility_state 同一判据。"))
        }
        if !dataset.undeclaredOverlaps.isEmpty {
            blockers.append(Finding(kind: .undeclaredPromptOverlap,
                                    detail: "评测集中有 \(dataset.undeclaredOverlaps.count) 条记录与提示侧存在未声明交集。"))
        }
        if !dataset.unaccountedRecords.isEmpty {
            blockers.append(Finding(kind: .unaccountedRecords,
                                    detail: "目录中有 \(dataset.unaccountedRecords.count) 条记录未被 split 的三处清单登记。"))
        }
        if dataset.pendingAdjudication > 0 {
            blockers.append(Finding(kind: .pendingAdjudicationExcluded,
                                    detail: "\(dataset.pendingAdjudication) 条争议记录已按约定排除，分层结论不含它们。"))
        }
        self.claimBlockers = blockers
        self.isQualityClaimAllowed = !blockers.contains { $0.kind.preventsQualityClaim }
        // Over the local value: referring to `slices` here would capture self
        // before the remaining properties exist.
        self.quotableMeasures = EvaluationMeasure.allCases.filter { measure in
            computedSlices.contains { $0.measure == measure && $0.stratum == .overall && !$0.rate.isSparse }
        }
    }

    public func slice(_ measure: EvaluationMeasure, stratum: EvaluationSlice.Stratum = .overall,
                      key: String? = nil) -> EvaluationSlice? {
        slices.first { $0.measure == measure && $0.stratum == stratum && $0.key == key }
    }

    /// Whether a specific number may be quoted as a quality result.
    ///
    /// Sparse strata are refused per number instead of per report: a run can be
    /// large overall and two-record-deep in one counter-example category, and the
    /// category row is exactly where an over-claim tends to appear.
    public func isQuotable(_ measure: EvaluationMeasure, stratum: EvaluationSlice.Stratum = .overall,
                           key: String? = nil) -> Bool {
        guard isQualityClaimAllowed, let found = slice(measure, stratum: stratum, key: key),
              !found.rate.isSparse else { return false }
        return true
    }
}
