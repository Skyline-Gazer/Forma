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
    /// Draws behind every `clusterInterval` in the run. `EvaluationReport` computes
    /// its slices with this number rather than with one of its own, so §5's third nil
    /// cause - a short draw - is readable from the published value alone.
    public let bootstrapResamples: Int
    public let bootstrapSeed: UInt64

    public init(goldRevision: String, splitID: String, casePackID: String, casePackVersion: String,
                profileVersionKeys: [String: String], provider: String, modelID: String?, isSubstitute: Bool,
                bootstrapResamples: Int, bootstrapSeed: UInt64) {
        precondition(bootstrapResamples >= 1,
                     "the identity names the draws the report will compute with; zero names none")
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
        /// `GoldDataset` keeps disputed records out of `countableRecordIDs`, as PLAN
        /// §8.1 requires, and this report refuses any judged record still marked
        /// `adjudication_pending` through `caseSetNotDerivedFromSplit`; the excluded
        /// volume is disclosed so a rate can be read against it. Disclosed, not disqualifying: a run with a few pending
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
        /// The run's identity does not describe the dataset it was measured against:
        /// `goldRevision`/`splitID`/`casePackVersion` disagree with the dataset report
        /// handed to the same `EvaluationReport`. PLAN §8.2's gate is stated over all
        /// of these being the same, and nothing else in this layer can catch it - a
        /// judged case carries a record id, not a revision, so a runner that pairs one
        /// dataset's numbers with another's label would publish a reproducible-looking
        /// report that no re-run could reproduce. Vetoing rather than relabelling: the
        /// numbers stay visible, the claim goes.
        case identityDisagreesWithDataset
        /// `GoldDataset.Report.shortfalls` is non-empty: some Profile x scenario-category
        /// cell holds fewer than `GoldDataset.stratumTarget` countable records, so the
        /// dataset does not meet PLAN §8.1's sampling plan.
        ///
        /// Disclosed, not disqualifying, and the reason is arithmetic rather than
        /// tolerance: the cells are 2 Profiles x every category at 10 each, which
        /// already exceeds the 150 independent samples §8.1 asks for, so a dataset can
        /// satisfy its total and still miss several cells on the way there. A run whose
        /// claim depends on such a cell cannot quote it anyway - a cell below the quota
        /// is far below `EvaluationSlice.sparseCaseLimit` (30), which is where §5 stops
        /// a stratum from being cited on its own merits - so the quota finding tells the
        /// reader which parts of the table are structural gaps rather than thin
        /// measurements, and nothing more.
        case stratumQuotasUnmet

        /// Two findings describe the run without disqualifying it: how many disputed
        /// records were left out, and which quota cells the dataset is short of. Both
        /// are properties of the sample the reader needs next to the numbers, not
        /// reasons the numbers cannot be numbers - and both have their own §6 entry
        /// saying where the actual protection lives (§5's quotability floor).
        var preventsQualityClaim: Bool { !Self.disclosureOnly.contains(self) }

        static let disclosureOnly: Set<Blocker> = [.pendingAdjudicationExcluded, .stratumQuotasUnmet]
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
    /// PLAN §8.2's 拒判原因, beside the confusion matrix: why the run did not publish
    /// what the reference answer expected, in records that stopped somewhere and the
    /// slots they left empty.
    public let refusals: EvaluationMetrics.Refusals
    /// The dataset's own integrity findings, kept beside the rates they qualify.
    public let dataset: GoldDataset.Report
    public let claimBlockers: [Finding]
    public let isQualityClaimAllowed: Bool
    /// Measures whose overall stratum judged enough records to quote at all; see
    /// `EvaluationSlice.sparseCaseLimit` for what that threshold is and is not.
    public let quotableMeasures: [EvaluationMeasure]

    /// The run identity is the only source for how the bands were drawn. Both numbers
    /// used to also be parameters of this initialiser, so a caller could publish
    /// `bootstrapResamples = 1` over slices computed from the default 2,000 draws -
    /// and §5's third nil cause is read from the published number, which would then
    /// have told a reader the run was short-drawn when nothing about it was short.
    /// Deriving them here is what makes the contradiction impossible to express.
    public init(cases: [CaseJudgement], identity: EvaluationRunIdentity, dataset: GoldDataset.Report) {
        let grouped = Dictionary(grouping: cases, by: \.clusterKey)
        self.identity = identity
        self.cases = cases.count
        self.clusters = grouped.count
        // A run that executed under exactly one Profile knows what PLAN §8.2 needs
        // for "correct"; a multi-Profile run must say which, per stratum, because
        // guessing from the record's own profile list would score every file correct
        // simply by being listed somewhere.
        let metricsRequest = EvaluationMetrics.Request(resamples: identity.bootstrapResamples,
                                                       seed: identity.bootstrapSeed,
                                                       runProfileID: identity.profileVersionKeys.count == 1
                                                           ? identity.profileVersionKeys.keys.first
                                                           : nil)
        let computedSlices = EvaluationMetrics.slices(for: cases, request: metricsRequest)
        self.slices = computedSlices
        self.confusion = EvaluationMetrics.confusion(cases)
        self.refusals = EvaluationMetrics.refusals(cases)
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
            // Both halves of the claim belong in this row, because the sentence it
            // publishes ("those records are in no denominator") is only true of the
            // run if the cases fed to it actually exclude them. `pending` is the
            // count of judged records that are still `adjudication_pending`, which
            // the check above turns into a veto when non-zero: the row states both
            // numbers and whether they agree, so a reader never has to take the
            // disclosure's word for the exclusion.
            let agreement = pending == 0
                ? "，即本次判定的用例已全部排除争议记录。"
                : "，已由 caseSetNotDerivedFromSplit 否决本次结论。"
            blockers.append(Finding(kind: .pendingAdjudicationExcluded,
                                    detail: "数据集把 \(dataset.pendingAdjudication) 条争议记录排除在可计数集合之外；"
                                        + "本次判定的 \(cases.count) 条记录中有 \(pending) 条仍为 "
                                        + "adjudication_pending" + agreement))
        }
        var disagreed: [String] = []
        if identity.goldRevision != dataset.datasetRevision { disagreed.append("goldRevision/datasetRevision") }
        if identity.splitID != dataset.splitID { disagreed.append("splitID") }
        if identity.casePackVersion != dataset.casePackVersion { disagreed.append("casePackVersion") }
        if !disagreed.isEmpty {
            blockers.append(Finding(kind: .identityDisagreesWithDataset,
                                    detail: "运行身份与所测数据集在 " + disagreed.joined(separator: "、")
                                        + " 上不一致；这份数字属于哪一批样本无法确定，因此不给出质量结论。"))
        }
        if !dataset.shortfalls.isEmpty {
            let cells = dataset.shortfalls.map { "\($0.profile)/\($0.category.rawValue)=\($0.count)" }
            let named = cells.prefix(6).joined(separator: "、")
            blockers.append(Finding(kind: .stratumQuotasUnmet,
                                    detail: "\(cells.count) 个 Profile x 类别格未达 \(GoldDataset.stratumTarget) 条："
                                        + named + (cells.count > 6 ? " 等" : "")
                                        + "；这些格远低 §5 的 30 条可引用下限，本就只能作描述读，故本条仅披露。"))
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
