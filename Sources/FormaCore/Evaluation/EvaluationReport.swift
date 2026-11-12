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
        /// Disputed records are kept out of every accuracy denominator, as PLAN
        /// §8.1 requires, and the excluded volume is reported so a rate can be read
        /// against it. Disclosed, not disqualifying: a run with a few pending
        /// adjudications still measured what it measured, and treating the honest
        /// exclusion as a defect would only discourage recording it.
        ///
        /// Disclosing it is only honest because the exclusion is enforced two ways:
        /// a judged record outside `Report.countableRecordIDs` is caught by
        /// `caseSetNotDerivedFromSplit`, and a record still marked `adjudication_pending`
        /// is caught there too, by its own flag - so the claim does not depend on the
        /// caller having built that id list consistently with the review statuses.
        case pendingAdjudicationExcluded
        /// A judged record is not in the dataset's countable set, or the same record
        /// was judged more than once. Either way the denominators are no longer
        /// derived from the versioned split: withdrawn, disputed or prompt-side
        /// material would be scored, or one record counted twice.
        case caseSetNotDerivedFromSplit
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
    /// Measures whose overall stratum judged enough records to quote at all; see
    /// `EvaluationSlice.sparseCaseLimit` for what that threshold is and is not.
    public let quotableMeasures: [EvaluationMeasure]

    public init(cases: [CaseJudgement], identity: EvaluationRunIdentity, dataset: GoldDataset.Report,
                request: EvaluationMetrics.Request = EvaluationMetrics.Request()) {
        let grouped = Dictionary(grouping: cases, by: \.clusterKey)
        self.identity = identity
        self.cases = cases.count
        self.clusters = grouped.count
        // A run that executed under exactly one Profile knows what PLAN §8.2 needs
        // for "correct"; a multi-Profile run must say which, per stratum, because
        // guessing from the record's own profile list would score every file correct
        // simply by being listed somewhere.
        let metricsRequest: EvaluationMetrics.Request
        if request.runProfileID == nil, identity.profileVersionKeys.count == 1,
           let only = identity.profileVersionKeys.keys.first {
            metricsRequest = EvaluationMetrics.Request(resamples: request.resamples, seed: request.seed,
                                                       runProfileID: only)
        } else {
            metricsRequest = request
        }
        let computedSlices = EvaluationMetrics.slices(for: cases, request: metricsRequest)
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
        let allowed = Set(dataset.countableRecordIDs)
        var seen = Set<String>()
        var offSplit = 0
        var duplicates = 0
        var pending = 0
        for judgement in cases {
            if !allowed.contains(judgement.recordID) { offSplit += 1 }
            if !seen.insert(judgement.recordID).inserted { duplicates += 1 }
            if judgement.pendingAdjudication { pending += 1 }
        }
        if offSplit > 0 || duplicates > 0 || pending > 0 {
            // Nothing is silently dropped here: the run is measured as it was fed,
            // and the claim is refused. Quietly filtering would hide a runner that
            // builds its case set wrongly, which is the mistake worth surfacing.
            blockers.append(Finding(kind: .caseSetNotDerivedFromSplit,
                                    detail: "\(offSplit) 条被判定记录不在数据集的可计数集合内，"
                                        + "\(duplicates) 条被重复判定，\(pending) 条仍为 adjudication_pending。"))
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
                                    detail: "数据集把 \(dataset.pendingAdjudication) 条争议记录排除在可计数集合之外，"
                                        + "因此它们不在任何分母里；若有争议记录仍被判定，会另由 "
                                        + "caseSetNotDerivedFromSplit 否决本次结论。"))
        }
        self.claimBlockers = blockers
        self.isQualityClaimAllowed = !blockers.contains { $0.kind.preventsQualityClaim }
        // Over the local value: referring to `slices` here would capture self
        // before the remaining properties exist.
        let overall = computedSlices.filter { slice in
            slice.stratum == .overall && slice.isQuotableOnOwnMerits
        }
        self.quotableMeasures = EvaluationMeasure.allCases.filter { measure in
            overall.contains { $0.measure == measure }
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
              found.isQuotableOnOwnMerits else { return false }
        return true
    }
}
