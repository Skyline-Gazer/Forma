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
    /// Draws behind every `clusterInterval` in the run, and the number
    /// `EvaluationReport` computes with: the report takes no second copy, so §5's third
    /// nil cause - a short draw - is readable from the published value alone.
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
        /// How much the dataset kept out of its countable set. Disclosed, never
        /// disqualifying; §6's table says why.
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
        /// Which Profile x category cells the dataset is short of. Disclosed, never
        /// disqualifying: §6's row carries the arithmetic (16 cells x 10 is already more
        /// than §8.1's 150) and points at §5's floor for what a thin cell may be used for.
        case stratumQuotasUnmet

        /// The two disclosure-only kinds; every other case vetoes.
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

    /// PLAN §8.2's suggested business targets next to what this run measured.
    ///
    /// The clause is 必须展示实际值与差距, and it governs numbers the Owner has not
    /// adopted - PLAN says 阈值是建议、不是已批准政策, and that no final quality gate may
    /// be claimed as passed before approval. So this is a display surface: a missed
    /// target vetoes nothing here, and `isQualityClaimAllowed` remains a function of
    /// `claimBlockers` alone. Two lines of the same PLAN paragraph are deliberately
    /// absent: 关键反例不能出现系统性混淆 and per-field reporting are not numeric
    /// thresholds in the PLAN text, and manufacturing one would dress a harness guess
    /// in PLAN's authority. The confusion matrix and the twelve `.field` rows are where
    /// a reader judges those, each with its own `caseCount`.
    public struct Target: Codable, Sendable, Equatable {
        public enum Direction: String, Codable, Sendable {
            /// Higher is better; the suggestion is a floor.
            case atLeast
            /// Lower is better; the suggestion is a ceiling.
            case atMost
        }

        public let measure: EvaluationMeasure
        public let direction: Direction
        /// The number written in PLAN §8.2, unmodified.
        public let suggested: Double
        /// What the run measured overall; nil when the measure had no population,
        /// which PLAN §8.2 marks N/A rather than zero.
        public let actual: Double?
        /// How far the run fell short of the suggestion: positive when the suggestion
        /// is not met, zero or negative when it is, nil exactly with `actual` - there
        /// is nothing to be short of in a measure the run could not evaluate.
        public let shortfall: Double?
        /// What `actual` was computed over - the row's own denominator, which for a
        /// record-level measure is the number of files judged in that run. PLAN §8.2
        /// asks for the sample size beside the zero-error observations; it is published
        /// for every row rather than some.
        public let population: Int
        /// Records the row rests on, so a met target on three records does not read
        /// like one on three hundred. Not the same as `population`: a row can be blank
        /// for want of attribution while the run judged plenty of files.
        public let caseCount: Int
        public let clusterCount: Int
        /// The run's cluster band for the measure, when it has one (§5).
        public let interval: ClosedRange<Double>?

        init(measure: EvaluationMeasure, direction: Direction, suggested: Double, slice: EvaluationSlice?) {
            let actual = slice?.rate.estimate
            self.measure = measure
            self.direction = direction
            self.suggested = suggested
            self.actual = actual
            switch (direction, actual) {
            case (.atLeast, let value?): shortfall = suggested - value
            case (.atMost, let value?): shortfall = value - suggested
            case (_, nil): shortfall = nil
            }
            self.population = slice.map { $0.rate.denominator } ?? 0
            self.caseCount = slice?.caseCount ?? 0
            self.clusterCount = slice?.clusterCount ?? 0
            self.interval = slice?.clusterInterval
        }

        /// Whether the suggestion is met, nil exactly when `actual` is.
        public var isMet: Bool? { shortfall.map { $0 <= 0 } }

        /// PLAN §8.2's numeric suggestions, in the order PLAN lists them; §6.1 of
        /// `docs/EVALUATION-METRICS.md` is that table and says why the last row is a
        /// ceiling of none.
        static let proposals: [(measure: EvaluationMeasure, direction: Direction, suggested: Double)] = [
            (.precisionAuto, .atLeast, 0.95),
            (.coverage, .atLeast, 0.70),
            (.fieldPrecision, .atLeast, 0.98),
            (.highConfidenceErrorRate, .atMost, 0.02),
            (.holdRate, .atMost, 0.30),
            (.inventedFillRate, .atMost, 0.0),
        ]
    }

    /// The proposals above as this run measured them.
    public let targets: [Target]

    /// Bands are drawn with `identity.bootstrapResamples` and `identity.bootstrapSeed`.
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
            // count of judged records that are still `adjudication_pending`. The
            // closing clause therefore reads the gate that is actually in force, not
            // `pending` alone: a run whose case set was rejected for duplicates or
            // off-split rows is already refused a conclusion, and this row must not
            // then offer "everything disputed is excluded" as a clean bill beside it.
            let caseSetVetoed = blockers.contains { $0.kind == .caseSetNotDerivedFromSplit }
            let agreement: String
            if pending > 0 {
                agreement = "；本次分母确实含争议记录，已由 caseSetNotDerivedFromSplit 否决本次结论。"
            } else if caseSetVetoed {
                agreement = "；用例集合已因越界或重复判定被 caseSetNotDerivedFromSplit 否决，"
                    + "本行不为「本次分母不含争议记录」作保。"
            } else {
                agreement = "；本次判定的记录全部落在 countableRecordIDs 内且无争议条目，故本次分母不含"
                    + "争议记录——本行只为这一句作保，排除动作本身发生在数据集层。"
            }
            blockers.append(Finding(kind: .pendingAdjudicationExcluded,
                                    detail: "`GoldDataset` 的可计数集合不含 \(dataset.pendingAdjudication) 条争议记录"
                                        + "（分母由喂进来的用例决定，本行不代表本次运行做过排除）；"
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
                                        + "；这些格远低 §5 的 30 条可引用下限，本就只能作描述读，故本条仅披露。"
                                        + "（格子按 gold-record-1.0 的单值 scenario 互斥计数，"
                                        + "PLAN §8.1 的\"场景可交叉计数\"在该 schema 下不可表达）"))
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
        self.targets = Target.proposals.map { proposal in
            Target(measure: proposal.measure, direction: proposal.direction, suggested: proposal.suggested,
                   slice: computedSlices.first { $0.measure == proposal.measure && $0.stratum == .overall })
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
