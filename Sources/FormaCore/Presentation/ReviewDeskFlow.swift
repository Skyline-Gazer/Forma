import Foundation

/// The business Review Desk (#144, corrected by the #148 product decision), as
/// data: which stage the desk is in, what the single clear next action is,
/// which actions the stage allows, when a Save & Next click may move the
/// cursor, and how a FormaCore decision state reads as a chip or a triage row.
///
/// Everything here is presentation arithmetic over facts the app already
/// publishes (scope, listing, context, manifest, plan, busy). Nothing decides
/// a value FormaCore owns: a stage never implies a revision, and an advance
/// predicate only reports the revision change the store actually made. The
/// AI path is the default because the product is AI-native; the deterministic
/// Offline Planner appears only as the explicitly labelled 手动草稿 fallback,
/// never framed as intelligence.
public enum DeskStage: String, Codable, Sendable, CaseIterable, Equatable {
    case chooseSource
    case scan
    case projectContext
    case aiUnderstanding
    case fileReview
    case archivePreview

    /// One-based position for the stage indicator; the order is the pipeline,
    /// and `allCases` is the declaration order, so the indicator cannot drift.
    public var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    public var title: String {
        switch self {
        case .chooseSource: "选择来源"
        case .scan: "扫描目录"
        case .projectContext: "项目上下文"
        case .aiUnderstanding: "AI 理解"
        case .fileReview: "逐份审核"
        case .archivePreview: "归档预览"
        }
    }
}

/// The actions the desk can take, named once so the stage matrix, the page and
/// the tests speak the same verb list. The view maps each id onto the model
/// call that already exists; no action here creates a Core-side effect.
public enum DeskAction: String, Codable, Sendable, CaseIterable, Equatable {
    case chooseSource
    case addSource
    case configureProfile
    case scan
    case buildContext
    case aiUnderstanding
    case manualDraft
    case reviewFiles
    case buildPlan
    case exportBundle
    case openSettings
    case cancel

    public var title: String {
        switch self {
        case .chooseSource: "选择资料目录"
        case .addSource: "添加目录…"
        case .configureProfile: "选择资料库类型"
        case .scan: "扫描文件"
        case .buildContext: "识别项目"
        case .aiUnderstanding: "开始 AI 理解"
        case .manualDraft: "手动草稿（非 AI 理解）"
        case .reviewFiles: "逐份审核"
        case .buildPlan: "生成归档预览"
        case .exportBundle: "导出清单与审核表"
        case .openSettings: "前往设置"
        case .cancel: "停止当前任务"
        }
    }

    public var systemImage: String {
        switch self {
        case .chooseSource, .addSource: "folder.badge.plus"
        case .configureProfile: "square.stack.3d.up"
        case .scan: "arrow.clockwise"
        case .buildContext: "square.3.layers.3d"
        case .aiUnderstanding: "sparkles"
        case .manualDraft: "hand.draw"
        case .reviewFiles: "checklist"
        case .buildPlan: "list.bullet.clipboard"
        case .exportBundle: "square.and.arrow.up"
        case .openSettings: "slider.horizontal.3"
        case .cancel: "stop.circle"
        }
    }
}

/// The stable business sentences the desk shows. They are tested strings, not
/// view literals: the no-pretend-AI promise and the manual-draft framing are
/// exactly what the Owner asked to be unmissable.
public enum DeskGuidance {
    public static let aiNeedsConsent = "AI 路径会把脱敏后的证据摘录分批发送。在你确认外发许可之前，Forma 不会发出任何数据。"
    public static let keyMissingHint = "本机没有可用的 API 密钥时，AI 理解会逐文件失败；请先在设置中保存密钥。"
    public static let manualDraftNotice = "手动草稿由离线规划器生成，不是 AI 理解：字段全部留待人工确认，不计为已验证。"
    public static let recoverySnapshot = "部分文件内容已变化，旧快照的审核结论不再有效：请重新扫描并识别项目后继续。"
    public static let providerError = "有文件在 Provider 侧失败。可以安全重试，已完成的审核结果不会丢失。"
    public static let noPretendResult = "没有密钥或外发许可时，Forma 不产出任何「AI 结果」；本页不做模拟推断。"
    public static let dryRunOnly = "归档预览只做 Dry-Run：显示目标目录与阻断原因，不会执行任何写入。"
    public static let chooseSourceHint = "选择要整理的资料目录；Forma 只登记清单，不修改任何文件。"
}

/// The one desk state machine. The inputs are the published facts, so the same
/// facts always produce the same stage and next action - the contract UI test
/// surface for the #144 state matrix without a GUI runner.
public struct ReviewDeskFlow: Equatable, Sendable {
    public struct Inputs: Equatable, Sendable {
        public var hasScope: Bool
        public var hasProfile: Bool
        public var hasListing: Bool
        public var hasContext: Bool
        public var hasManifest: Bool
        public var hasPlan: Bool
        public var isBusy: Bool
        /// At least one manifest entry is `invalidated`: the recovery row of
        /// the state matrix overrides "continue reviewing".
        public var hasInvalidatedFiles: Bool

        public init(hasScope: Bool = false, hasProfile: Bool = false, hasListing: Bool = false,
                    hasContext: Bool = false, hasManifest: Bool = false, hasPlan: Bool = false,
                    isBusy: Bool = false, hasInvalidatedFiles: Bool = false) {
            self.hasScope = hasScope
            self.hasProfile = hasProfile
            self.hasListing = hasListing
            self.hasContext = hasContext
            self.hasManifest = hasManifest
            self.hasPlan = hasPlan
            self.isBusy = isBusy
            self.hasInvalidatedFiles = hasInvalidatedFiles
        }
    }

    public let stage: DeskStage
    public let next: DeskAction
    public let allowed: Set<DeskAction>
    public let guidance: String

    /// A deterministic total function of the published facts. The switch is
    /// written as the pipeline: each fact unlocks the next stage, and a busy
    /// phase replaces the pipeline action with its cancel, as the state matrix
    /// demands ("Analysis in progress: progress/cancel with live context
    /// intact").
    public static func evaluate(_ inputs: Inputs) -> ReviewDeskFlow {
        if !inputs.hasScope {
            return ReviewDeskFlow(stage: .chooseSource, next: .chooseSource,
                                  allowed: [.chooseSource, .addSource],
                                  guidance: DeskGuidance.chooseSourceHint)
        }
        if !inputs.hasListing {
            return ReviewDeskFlow(stage: .scan, next: inputs.isBusy ? .cancel : .scan,
                                  allowed: inputs.isBusy ? [.cancel] : [.chooseSource, .addSource, .scan, .cancel],
                                  guidance: "扫描建立文件清单。未扫描的目录不会出现在审核队列里。")
        }
        if !inputs.hasProfile || !inputs.hasContext {
            return ReviewDeskFlow(stage: .projectContext,
                                  next: inputs.isBusy ? .cancel : (!inputs.hasProfile ? .configureProfile : .buildContext),
                                  allowed: inputs.isBusy ? [.cancel]
                                      : [.chooseSource, .addSource, .scan, .configureProfile, .buildContext, .cancel],
                                  guidance: "识别项目按目录结构聚类候选项目，不读取文件内容；资料库类型决定字段规则。")
        }
        if !inputs.hasManifest {
            // The AI-native default: semantic path first, manual draft offered
            // beside it only as the labelled fallback (#148).
            return ReviewDeskFlow(stage: .aiUnderstanding, next: inputs.isBusy ? .cancel : .aiUnderstanding,
                                  allowed: inputs.isBusy ? [.cancel]
                                      : [.scan, .configureProfile, .buildContext, .aiUnderstanding, .manualDraft, .openSettings, .cancel],
                                  guidance: DeskGuidance.aiNeedsConsent)
        }
        if inputs.hasInvalidatedFiles {
            return ReviewDeskFlow(stage: .fileReview, next: inputs.isBusy ? .cancel : .scan,
                                  allowed: inputs.isBusy ? [.cancel] : [.scan, .buildContext, .aiUnderstanding, .cancel],
                                  guidance: DeskGuidance.recoverySnapshot)
        }
        if !inputs.hasPlan {
            return ReviewDeskFlow(stage: .fileReview, next: inputs.isBusy ? .cancel : .reviewFiles,
                                  allowed: inputs.isBusy ? [.cancel]
                                      : [.reviewFiles, .aiUnderstanding, .manualDraft, .buildPlan, .cancel],
                                  guidance: "逐份确认业务字段；只有 FormaCore 发布了新修订，保存并下一份才会前进。")
        }
        return ReviewDeskFlow(stage: .archivePreview, next: inputs.isBusy ? .cancel : .exportBundle,
                              allowed: inputs.isBusy ? [.cancel]
                                  : [.reviewFiles, .buildPlan, .exportBundle, .openSettings, .cancel],
                              guidance: DeskGuidance.dryRunOnly)
    }

    /// The Save & Next gate: the cursor moves only across a revision FormaCore
    /// actually published. A refused correction leaves the revision untouched,
    /// so a `false` here keeps the file selected; missing values on either side
    /// also refuse to advance - absence of a revision is never a success.
    public static func advances(baselineRevision: Int?, currentRevision: Int?) -> Bool {
        guard let baselineRevision, let currentRevision else { return false }
        return currentRevision > baselineRevision
    }

    /// The queue cursor for Save & Next: the first entry after the current one
    /// in the visible order, wrapping to the head when the review reached the
    /// end (a single-entry bucket wraps to itself, i.e. the cursor simply
    /// stays). An order without the current id starts at its first entry; an
    /// empty order selects nothing.
    public static func nextAfter(_ id: String, in order: [String]) -> String? {
        guard !order.isEmpty else { return nil }
        guard let index = order.firstIndex(of: id) else { return order.first }
        let rest = order.enumerated().filter { $0.offset > index }.map(\.element)
        return rest.first ?? order.first
    }

    /// The refusal codes travel as themselves now - `WorkspaceModel
    /// .lastRefusalCodes` publishes them - so this view used to parse a
    /// sentence to recover them, and the parser is gone. A sentence is not an
    /// interface: it forced the refusal notice to stay in one language and
    /// one shape, and the desk to guess at what the sentence meant.
}

/// The per-file status chip (#144 P1): four business states, mapped total
/// over every decision state - an unexpected future state reads as 待审核,
/// never as a false 已验证.
public enum DeskChip: String, Codable, Sendable, CaseIterable, Equatable {
    case pendingReview = "待审核"
    case insufficientInformation = "信息不足"
    case validated = "已验证"
    case sourceChanged = "来源已变化"

    public var title: String { rawValue }

    public var systemImage: String {
        switch self {
        case .pendingReview: "circle.dotted"
        case .insufficientInformation: "questionmark.circle"
        case .validated: "checkmark.circle"
        case .sourceChanged: "arrow.triangle.2.circlepath"
        }
    }
}

public func deskChip(for state: DecisionState) -> DeskChip {
    switch state {
    case .validated: .validated
    case .hold: .insufficientInformation
    case .invalidated: .sourceChanged
    default: .pendingReview
    }
}

/// The triage filter (#144 P2): 待处理 / 已验证 / 需关注. Same totality rule
/// as the chips: the pending bucket is the fallback bucket, so a state Forma
/// does not know yet stays in the reviewer's queue instead of vanishing.
public enum DeskTriage: String, Codable, Sendable, CaseIterable, Equatable {
    case pending = "待处理"
    case validated = "已验证"
    case attention = "需关注"

    public var title: String { rawValue }
}

public func deskTriage(for state: DecisionState) -> DeskTriage {
    switch state {
    case .validated: .validated
    case .invalidated: .attention
    default: .pending
    }
}

/// The 12 metadata fields in business language (#144 P1), one tested mapping.
/// The raw identifiers keep their exact use in storage, exports and 诊断详情;
/// this is the only form the desk shows.
public func metadataFieldLabel(_ field: MetadataFieldID) -> String {
    switch field {
    case .projectname: "项目名称"
    case .completionyear: "归档完成年份"
    case .bidderentity: "投标主体"
    case .department: "部门"
    case .salesowner: "业务负责人"
    case .endcustomer: "最终客户"
    case .biddeadline: "投标截止日期"
    case .tenderreference: "招标编号"
    case .bsdcode: "内部 BSD 编码"
    case .documentcategory: "文件分类"
    case .documenttype: "文件类型"
    case .issuer: "出具单位"
    default: field.rawValue
    }
}

/// The provenance name of an evidence row, in the reviewer's words. Opaque
/// registry ids stay out of this sentence: they belong to 诊断详情.
public func deskEvidenceSourceLabel(_ source: EvidenceSource) -> String {
    switch source {
    case .filename: "文件名"
    case .path: "来源目录"
    case .content: "正文摘录"
    case .sibling: "同项目文件"
    case .fsMetadata: "文件属性"
    case .mcp: "只读历史记录"
    default: source.rawValue
    }
}

/// Where inside the document an excerpt came from, business-worded and
/// location-shaped (文件名/页/段 grouping, #144 P1). `.text` will arrive with
/// #158 and land in the `default` bucket as 正文摘录 until one line adds
/// `正文 · 字符 a–b`; no desk build may fail because Core grew a case.
public func deskEvidenceLocatorLabel(_ locator: EvidenceLocator?) -> String {
    switch locator {
    case .pdf(let page, let range): "第 \(page) 页 · 字符 \(range.lowerBound)–\(range.upperBound)"
    case .docx(_, let paragraph, let range): "段落 \(paragraph) · 字符 \(range.lowerBound)–\(range.upperBound)"
    case .xlsx(let sheet, let cell): "工作表 \(sheet) · 单元格 \(cell)"
    case nil: "目录与文件名"
    default: "正文摘录"
    }
}

/// The four refusal buckets (#144 P0/P1): the actionable words the reviewer
/// reads beside the field. Matching is on the code strings FormaCore emits;
/// `evidence_snapshot_mismatch` is named here as a literal because the emitter
/// lands with PR #147 - the string contract is the code itself, not a symbol.
public enum DeskRefusalKind: String, Codable, Sendable, CaseIterable, Equatable {
    case missingEvidence = "缺少证据"
    case evidenceStale = "证据过期"
    case conflict = "字段冲突"
    case permission = "权限不足"
    case other = "校验未通过"

    public var sentence: String {
        switch self {
        case .missingEvidence: "这个字段还缺少能支撑它的证据，Forma 不接受无出处的结论。"
        case .evidenceStale: "引用的证据不再属于文件当前的快照版本，请基于重新扫描后的证据重新选择。"
        case .conflict: "多个来源对这个字段给出了不一致的值，Forma 不替你选择。"
        case .permission: "这次操作所需的许可或授权不满足，Forma 停在原地。"
        case .other: "FormaCore 拒绝保存这条修正，原因见下方诊断详情。"
        }
    }
}

public func deskRefusalKind(forCode code: String) -> DeskRefusalKind {
    switch code {
    case "evidence_missing", "evidence_not_found", "insufficient_evidence", "evidence_incomplete", "entry_unanswered":
        .missingEvidence
    case "evidence_snapshot_mismatch", "snapshot_changed", "membership_changed", "membership_and_snapshot_changed",
         "source_changed", "source_missing", "evidence_unusable", "quote_mismatch":
        .evidenceStale
    case "conflicting_evidence", "field_conflict", "unknown_conflict", "association_conflict", "membership_conflict":
        .conflict
    case "source_not_allowed", "source_unauthorized", "authorization_missing", "authorization_expired",
         "target_outside_authorization", "eligibility_authority", "eligibility_state":
        .permission
    default:
        .other
    }
}

/// The inline refusal line: the bucket words first, then the curated sentence
/// for the specific code - businessCopy's own fallback keeps an uncurated code
/// readable instead of silent. The raw code travels only in 诊断详情.
public func deskRefusalSentence(forCode code: String) -> String {
    let kind = deskRefusalKind(forCode: code)
    let copy = businessCopy(for: code)
    return "\(kind.rawValue)·\(copy.headline)：" + kind.sentence
}

/// Archive-plan target line: the symbols the plan would use, never a claim of
/// success. Empty group path is stated as undecided, not blank.
public func deskPlanTargetLine(databaseName: String?, groupPath: [String]) -> String {
    let database = databaseName ?? "资料库待定"
    guard !groupPath.isEmpty else { return "\(database) · 归档位置尚未确定" }
    return "\(database) · " + groupPath.joined(separator: " / ")
}
