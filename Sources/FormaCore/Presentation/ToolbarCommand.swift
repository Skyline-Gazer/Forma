import Foundation

/// One toolbar command in the shell's grammar: identical data for a given
/// (area, busy, planner) triple, so the SwiftUI layer only renders what this
/// says and the CI can assert the set is stable.
///
/// `id` doubles as the accessibility identifier the views have always carried
/// (`add-source`, `run-mapping`, ...), which keeps the automation contract
/// across the shell rewrite. `isEnabled` is the part of enablement this pure
/// function can know - phase and planner mode; a view may still disable a
/// command for state it owns (an empty selection, a missing manifest) but must
/// never enable one core disabled.
public struct ToolbarCommand: Identifiable, Equatable, Sendable {
    /// Where the command sits. The shell uses one primary group per area plus a
    /// dedicated egress slot, so a command never jumps position between phases
    /// except by the allowed Cancel-to-primary-action swap.
    public enum Placement: String, Equatable, Sendable {
        case primary
        case egress
    }

    public let id: String
    public let title: String
    public let systemImage: String?
    public let placement: Placement
    public let isEnabled: Bool
    public let help: String

    public init(id: String, title: String, systemImage: String? = nil,
                placement: Placement = .primary, isEnabled: Bool, help: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.placement = placement
        self.isEnabled = isEnabled
        self.help = help
    }
}

public enum ShellCommands {
    /// The cancel command for an area, or nil where the area has no long-running
    /// action of its own. Busy swaps the area's primary action for this one.
    public static func cancelCommand(for area: AppArea) -> ToolbarCommand? {
        switch area {
        case .workspace:
            ToolbarCommand(id: "cancel-work", title: "取消", systemImage: "stop.circle",
                           isEnabled: true, help: "停止正在进行的扫描或构建")
        case .mapping:
            ToolbarCommand(id: "cancel-mapping", title: "取消", systemImage: "stop.circle",
                           isEnabled: true, help: "停止本次映射运行")
        case .exceptions:
            ToolbarCommand(id: "cancel-reprocess", title: "取消", systemImage: "stop.circle",
                           isEnabled: true, help: "停止本次重新处理")
        case .reviewDesk:
            // The desk runs the same model work the source areas start, so it
            // cancels through the same command id.
            ToolbarCommand(id: "cancel-work", title: "取消", systemImage: "stop.circle",
                           isEnabled: true, help: "停止正在进行的扫描、识别或 AI 理解")
        case .importArchive, .settings:
            nil
        }
    }

    /// Whether the area's primary (non-cancel) commands are the ones the busy
    /// state swaps out for its cancel command.
    public static func swapsForCancel(_ command: ToolbarCommand) -> Bool {
        ["scan-source", "build-context", "reconcile-manifest",
         "run-mapping", "assess-local", "reprocess-selected"].contains(command.id)
    }

    /// The one command set for one area at one moment.
    ///
    /// Stability contract, tested in CI: for every area the idle set and the
    /// busy set are equal except that busy removes exactly the swapping primary
    /// actions and appends the area's cancel command, and every surviving
    /// command keeps its id and placement while flipping only `isEnabled`.
    /// The offline/ai planner changes only the mapping set: `assess-local`
    /// exists for a Provider-backed run, because an offline planner never
    /// sends and a second "without egress" button would offer the same run
    /// twice under a misleading name.
    public static func commands(for area: AppArea, phase: BusyState, planner: PlannerMode) -> [ToolbarCommand] {
        let idle = !phase.isBusy
        switch area {
        case .workspace:
            var result = [
                ToolbarCommand(id: "add-source", title: "添加来源…", systemImage: "folder.badge.plus",
                               isEnabled: idle,
                               help: "登记一个本地或云盘文件夹，只读取清单与元数据"),
                ToolbarCommand(id: "reauthorize-source", title: "重新授权…", systemImage: "lock.open",
                               isEnabled: idle,
                               help: "重新选择同一个文件夹以续期 macOS 访问"),
            ]
            if idle {
                result += [
                    ToolbarCommand(id: "scan-source", title: "扫描", systemImage: "arrow.clockwise",
                                   isEnabled: true,
                                   help: "扫描来源文件夹，生成文件清单"),
                    ToolbarCommand(id: "build-context", title: "构建上下文", systemImage: "square.3.layers.3d",
                                   isEnabled: true,
                                   help: "FormaCore 依据目录结构聚类项目候选，不读取内容"),
                    ToolbarCommand(id: "reconcile-manifest", title: "核对清单", systemImage: "arrow.triangle.2.circlepath",
                                   isEnabled: true,
                                   help: "请 FormaCore 判断存储条目仍被快照绑定支持的有哪些"),
                ]
            } else if let cancel = cancelCommand(for: area) {
                result.append(cancel)
            }
            return result

        case .mapping:
            var result: [ToolbarCommand] = []
            if idle {
                result.append(ToolbarCommand(id: "run-mapping", title: "映射文件", systemImage: "square.text.square",
                                             isEnabled: true,
                                             help: planner == .offline
                                                ? "离线规划器：不发送任何数据，逐字段留空等待确认"
                                                : "先登记证据，再按批次发送映射请求"))
                if planner == .ai {
                    result.append(ToolbarCommand(id: "assess-local", title: "无外发评估", systemImage: "desktopcomputer",
                                                 isEnabled: true,
                                                 help: "FormaCore 拒绝每个 Provider 请求，并逐文件记录原因"))
                }
            } else if let cancel = cancelCommand(for: area) {
                result.append(cancel)
            }
            result += [
                ToolbarCommand(id: "export-manifest", title: "导出…", systemImage: "square.and.arrow.up",
                               isEnabled: idle,
                               help: "写出清单、报告、异常、证据行、版本与摘要"),
                ToolbarCommand(id: "open-bundle", title: "打开导出包", systemImage: "folder.badge.magnifyingglass",
                               isEnabled: idle,
                               help: "打开此前导出的映射包以离线复核"),
                ToolbarCommand(id: "revalidate-bundle", title: "离线复核", systemImage: "checkmark.seal",
                               isEnabled: idle,
                               help: "在本机重新校验导出包，不发送任何数据"),
            ]
            return result

        case .importArchive:
            return [
                ToolbarCommand(id: "build-plan", title: "生成计划", systemImage: "list.bullet.clipboard",
                               isEnabled: idle,
                               help: "从当前清单生成导入计划；此构建只读，不会写入"),
                ToolbarCommand(id: "export-plan", title: "导出计划…", systemImage: "square.and.arrow.up",
                               isEnabled: idle,
                               help: "把导入计划写到所选文件夹；计划含文件名，请按私密数据对待"),
            ]

        case .exceptions:
            var result: [ToolbarCommand] = []
            if idle {
                result.append(ToolbarCommand(id: "reprocess-selected", title: "重新处理所选",
                                             systemImage: "arrow.3.trianglepath",
                                             isEnabled: true,
                                             help: "仅对选中的文件重新运行映射引擎"))
            } else if let cancel = cancelCommand(for: area) {
                result.append(cancel)
            }
            result.append(ToolbarCommand(id: "clear-selection", title: "清除选择", systemImage: nil,
                                         isEnabled: true,
                                         help: "清空当前文件选择"))
            return result

        case .settings:
            // Settings owns its actions inside the form; the shell adds nothing.
            return []

        case .reviewDesk:
            // The guided desk reuses the existing command ids: every action it
            // offers is the same model call the engineering areas make, so a
            // scan started here and a scan started in 工作区 are one thing.
            // The AI/manual-draft triggers live inside the page because they
            // carry the egress confirmation; the toolbar never starts an
            // egress run without it.
            var result = [
                ToolbarCommand(id: "add-source", title: "添加来源…", systemImage: "folder.badge.plus",
                               isEnabled: idle,
                               help: "登记一个本地或云盘文件夹，只读取清单与元数据"),
            ]
            if idle {
                result += [
                    ToolbarCommand(id: "scan-source", title: "扫描", systemImage: "arrow.clockwise",
                                   isEnabled: true,
                                   help: "扫描来源文件夹，生成文件清单"),
                    ToolbarCommand(id: "build-context", title: "识别项目", systemImage: "square.3.layers.3d",
                                   isEnabled: true,
                                   help: "FormaCore 依据目录结构聚类项目候选，不读取内容"),
                ]
            } else if let cancel = cancelCommand(for: area) {
                result.append(cancel)
            }
            result += [
                ToolbarCommand(id: "build-plan", title: "归档预览", systemImage: "list.bullet.clipboard",
                               isEnabled: idle,
                               help: "从当前清单生成导入计划；此构建只读，不会写入"),
                ToolbarCommand(id: "export-manifest", title: "导出…", systemImage: "square.and.arrow.up",
                               isEnabled: idle,
                               help: "写出清单、报告、异常、证据行、版本与摘要"),
            ]
            return result
        }
    }
}

/// The Profile picker contract, as data: a picker is never blank. It shows the
/// selected profile's name, or this placeholder when nothing resolvable is
/// selected (no profiles, or a stale selection restored from defaults).
public enum ShellProfilePicker {
    /// The picker's own name for "nothing is selected".
    ///
    /// It names the same thing the label does. A picker labelled "Profile"
    /// that reads "未选择 Profile" while the rest of the app calls the same
    /// choice 资料库类型 asks the reader to know two words for one thing.
    public static let placeholder = "未选择资料库类型"

    /// The label a picker must render for `selected` among `options`.
    /// Always non-empty; stale or nil selections resolve to the placeholder so
    /// the control states its problem instead of showing nothing.
    public static func label(selected: String?, options: [(id: String, name: String)]) -> String {
        guard let selected else { return placeholder }
        return options.first { $0.id == selected }?.name ?? placeholder
    }

    /// Whether the picker itself is operable: an empty profile list is a
    /// disabled picker with the placeholder visible, not a blank one.
    public static func isEnabled(optionCount: Int) -> Bool { optionCount > 0 }
}

/// The planner mode's user-facing name. Moved out of the app model so the
/// "Offline Planner — Not AI" sentence is one tested string, not a view literal.
public func plannerModeLabel(_ mode: PlannerMode) -> String {
    switch mode {
    case .offline: "离线规划器（非 AI）"
    case .ai: "AI 映射"
    }
}

/// The shortened offline notice for the mapping area's run panel. The mode
/// switch stays in the diagnostics panel; the banner no longer lectures.
public let offlinePlannerShortNotice = "离线规划器：不调用 Provider，本批数据不离开本机；字段值需人工确认。"

/// The egress consent surface. The Exceptions toolbar never shows a full English
/// sentence in the titlebar: it shows this short label, and activation opens a
/// deliberate confirmation of what would leave the machine. Consent remains
/// per-run and default-off; this is presentation of the existing EgressGate
/// contract, not a new permission.
public enum EgressConsent {
    public static let shortLabel = "外发许可"
    public static let defaultOffNote = "默认关闭：仅对本次重新处理有效，运行结束即失效。"
    public static let confirmationHeading = "确认允许数据离开本机？"
    public static let confirmAction = "本次允许外发"
    public static let cancelAction = "保持关闭"

    /// What a consented run sends, in the user's terms. The authoritative
    /// categories are `EgressContract.EgressDataCategory`; these lines exist so
    /// the confirmation says the same thing the contract already enforces.
    public static let whatLeavesLines: [String] = [
        "文件相对路径",
        "已脱敏的证据摘录与候选字段值",
        "当前 Profile 规则与项目上下文",
        "CasePack 示例与提示词模板",
    ]

    public static let whatStaysLine = "原始文件不上传；API 密钥与外发之外的内容一律不出本机。"

    /// One sentence per category, business copy for the detail disclosure.
    public static func copy(for category: EgressDataCategory) -> String {
        switch category {
        case .filePaths: "文件相对路径"
        case .evidenceExcerpts: "已脱敏的证据摘录"
        case .projectContext: "项目上下文"
        case .casePackExamples: "CasePack 示例"
        case .profileRules: "Profile 字段规则"
        case .systemPrompt: "系统提示词"
        case .repairInstructions: "修复请求说明"
        case .syntheticProbe: "合成探针数据"
        }
    }
}
