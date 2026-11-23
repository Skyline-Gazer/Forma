import Foundation

/// The one navigation grammar of the app shell: which areas exist, what they are
/// called in the user's language, and how a stored choice comes back.
///
/// This is presentation, not domain: nothing here decides a value FormaCore
/// produced. It only says where a thing lives in the window and what a person
/// may read it as. The raw values are the persisted and automated identifiers
/// (sidebar rows carry `area-<rawValue>`), so renaming a case is a migration,
/// not a refactor.
public enum AppArea: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The source listing, scan and context area.
    case workspace = "workspace"
    /// The mapping run, manifest and export area.
    case mapping = "mapping"
    /// The dry-run import plan area.
    case importArchive = "import"
    /// The blocked-entries area.
    case exceptions = "exceptions"
    /// The provider, redaction and versions area.
    case settings = "settings"

    public var id: String { rawValue }

    /// The sidebar label, in the user's language.
    public var title: String {
        switch self {
        case .workspace: "工作区"
        case .mapping: "映射"
        case .importArchive: "归档"
        case .exceptions: "诊断"
        case .settings: "设置"
        }
    }

    /// The sidebar icon. Stable per area: a person learns the shape, not the word.
    public var systemImage: String {
        switch self {
        case .workspace: "folder"
        case .mapping: "tablecells"
        case .importArchive: "tray.and.arrow.down"
        case .exceptions: "exclamationmark.triangle"
        case .settings: "slider.horizontal.3"
        }
    }

    /// How a stored selection comes back: an unknown or missing value is the
    /// workspace, never a blank window. A persisted id outliving a rename must
    /// degrade to a place the person can navigate from, not to nothing.
    public static func restored(from stored: String?) -> AppArea {
        guard let stored, let area = AppArea(rawValue: stored) else { return .workspace }
        return area
    }
}

/// Whether the shell's primary actions may run. The command grammar only needs
/// this much of the work phase; the phase itself stays in the app.
public enum BusyState: String, Codable, Sendable, Equatable {
    case idle
    case busy

    public init(isBusy: Bool) { self = isBusy ? .busy : .idle }

    public var isBusy: Bool { self == .busy }
}

/// Which answerer a mapping run would use, in the grammar's own vocabulary.
/// The app's mode maps onto this one-to-one; keeping them separate lets the
/// command set be tested without an app type.
public enum PlannerMode: String, Codable, Sendable, CaseIterable {
    case offline
    case ai
}

/// The business sentence behind an internal code, plus the code itself.
///
/// The shell shows `headline` in tables and filters and `sentence` in prose;
/// the raw code travels only inside this struct's `rawCode`, which the views
/// render in the expandable 诊断 detail and nowhere else. A code FormaCore
/// never surfaces to a person keeps its raw value here precisely so the
/// support path has something exact to ask about - the absence of a curated
/// sentence is never shown as an absence of a record.
public struct DiagnosticCopy: Equatable, Sendable {
    /// FormaCore's own code, verbatim. Diagnostic detail only.
    public let rawCode: String
    /// The short name a table cell or filter row can carry.
    public let headline: String
    /// The full sentence: what happened and what it means for the person.
    public let sentence: String

    public init(rawCode: String, headline: String, sentence: String) {
        self.rawCode = rawCode
        self.headline = headline
        self.sentence = sentence
    }
}

/// The one total mapping from an internal code to business copy.
///
/// Every code the shell can surface goes through here, so "the UI shows
/// `snapshot_changed`" cannot come back: either the code has a curated
/// sentence, or the fallback says in the user's language that FormaCore
/// recorded an internal code and where to read it. The raw text is preserved
/// in `rawCode` for the expandable 诊断 detail.
public func businessCopy(for code: String) -> DiagnosticCopy {
    switch code {
    // Manifest validation and reconciliation causes.
    case "snapshot_changed":
        DiagnosticCopy(rawCode: code, headline: "文件内容已变化",
                       sentence: "这个文件与你上次扫描时已经不同，FormaCore 不使用旧快照得出的结论；请重新扫描并映射。")
    case "membership_changed":
        DiagnosticCopy(rawCode: code, headline: "项目归属已变化",
                       sentence: "文件所属的项目候选发生了变化，FormaCore 不会沿用旧的归属关系。")
    case "membership_and_snapshot_changed":
        DiagnosticCopy(rawCode: code, headline: "内容与归属都已变化",
                       sentence: "这个文件的快照与项目归属同时发生了变化，需要重新扫描并映射。")
    case "source_missing":
        DiagnosticCopy(rawCode: code, headline: "文件已缺失",
                       sentence: "来源文件夹里已找不到这个文件；FormaCore 不会猜测它去了哪里。")
    case "evidence_not_found":
        DiagnosticCopy(rawCode: code, headline: "证据行未登记",
                       sentence: "该字段引用的证据没有在本机登记过，FormaCore 拒绝以无出处的引用确认字段。")
    case "evidence_incomplete":
        DiagnosticCopy(rawCode: code, headline: "证据不完整",
                       sentence: "现有证据不足以确认这个字段的值；补充证据文件或修正后重新映射。")
    case "association_unknown":
        DiagnosticCopy(rawCode: code, headline: "项目关联未知",
                       sentence: "FormaCore 无法确定这条记录与哪个项目候选相关联，因此保留为未知。")
    case "evidence_missing":
        DiagnosticCopy(rawCode: code, headline: "缺少证据",
                       sentence: "这个字段没有任何引用证据，FormaCore 不接受无证据的结论。")
    case "insufficient_evidence":
        DiagnosticCopy(rawCode: code, headline: "证据不足",
                       sentence: "引用的证据不够支撑这个字段的值。")
    case "conflicting_evidence":
        DiagnosticCopy(rawCode: code, headline: "证据相互矛盾",
                       sentence: "多条证据给出了不一致的值，FormaCore 不替你选择哪条是对的。")
    case "evidence_unusable":
        DiagnosticCopy(rawCode: code, headline: "证据不可用",
                       sentence: "登记过的那条证据当前不可用（内容缺失或抽取失败）。")
    case "evidence_foreign_source":
        DiagnosticCopy(rawCode: code, headline: "证据来自其它文件",
                       sentence: "引用的证据不属于这个文件，FormaCore 拒绝了这条引用。")
    case "evidence_snapshot_mismatch":
        DiagnosticCopy(rawCode: code, headline: "证据快照不匹配",
                       sentence: "证据登记时的文件快照与当前条目不一致。")
    case "quote_mismatch":
        DiagnosticCopy(rawCode: code, headline: "引文与原文不符",
                       sentence: "引用的文字没有在证据原文中找到。")
    case "locator_invalid":
        DiagnosticCopy(rawCode: code, headline: "证据定位无效",
                       sentence: "证据指向的页、段落或单元格无法解析。")
    case "hydration_pending":
        DiagnosticCopy(rawCode: code, headline: "云端文件未下载",
                       sentence: "这个占位文件还没有从云端下载内容，FormaCore 不会为它代读。")
    case "symlink_not_read":
        DiagnosticCopy(rawCode: code, headline: "符号链接未读取",
                       sentence: "这是一个符号链接，FormaCore 不读取其目标内容。")
    case "source_held":
        DiagnosticCopy(rawCode: code, headline: "来源被搁置",
                       sentence: "这个来源当前被标记为暂缓处理。")
    case "source_not_allowed":
        DiagnosticCopy(rawCode: code, headline: "来源不在允许范围",
                       sentence: "该证据的来源不在这次运行允许的清单内，FormaCore 拒绝了它。")
    case "association_conflict":
        DiagnosticCopy(rawCode: code, headline: "项目关联冲突",
                       sentence: "文件同时匹配多个互斥的项目候选，FormaCore 不猜。")
    case "membership_conflict":
        DiagnosticCopy(rawCode: code, headline: "项目归属冲突",
                       sentence: "两个项目候选都主张这个文件，需要人工确认后才有归属。")
    case "unknown_conflict":
        DiagnosticCopy(rawCode: code, headline: "结论相互冲突",
                       sentence: "多个来源对同一字段给出了冲突的结论，字段保持待定。")
    case "field_conflict":
        DiagnosticCopy(rawCode: code, headline: "字段值冲突",
                       sentence: "同一个字段出现了不一致的值。")
    case "value_type":
        DiagnosticCopy(rawCode: code, headline: "字段类型不符",
                       sentence: "字段的值不符合 Profile 声明的类型。")
    case "category_unknown":
        DiagnosticCopy(rawCode: code, headline: "分类未知",
                       sentence: "分类值不在 Profile 认可的分类表中。")
    case "document_type_unknown":
        DiagnosticCopy(rawCode: code, headline: "文档类型未知",
                       sentence: "文档类型值不在 Profile 认可的类型表中。")
    case "candidate_unknown":
        DiagnosticCopy(rawCode: code, headline: "项目候选未知",
                       sentence: "记录引用的项目候选不在当前上下文中。")
    case "entry_unanswered":
        DiagnosticCopy(rawCode: code, headline: "条目未被回答",
                       sentence: "清单要求的这个条目没有得到任何回答。")
    case "entry_unknown":
        DiagnosticCopy(rawCode: code, headline: "条目来源未知",
                       sentence: "清单里出现了无法对应到本次来源集合的条目。")
    case "eligibility_state":
        DiagnosticCopy(rawCode: code, headline: "资格状态受限",
                       sentence: "按资格规则这个文件不满足执行前提（仅模拟，不会写入）。")
    case "eligibility_authority":
        DiagnosticCopy(rawCode: code, headline: "缺少资格授权",
                       sentence: "资格判定所依赖的授权不完整。")
    case "provider_failed":
        DiagnosticCopy(rawCode: code, headline: "Provider 请求失败",
                       sentence: "这次映射请求在 Provider 侧失败，FormaCore 按文件记录了原因。")

    // Validation groups and outcomes, shown wherever a report group is read.
    case "schema":
        DiagnosticCopy(rawCode: code, headline: "结构校验",
                       sentence: "检查清单是否符合导出的数据格式。")
    case "evidence":
        DiagnosticCopy(rawCode: code, headline: "证据校验",
                       sentence: "检查每个字段是否有登记过的证据支撑。")
    case "profile_policy":
        DiagnosticCopy(rawCode: code, headline: "Profile 规则校验",
                       sentence: "检查字段值是否符合当前 Profile 的业务规则。")
    case "snapshot":
        DiagnosticCopy(rawCode: code, headline: "快照校验",
                       sentence: "检查条目是否仍与扫描时的文件快照一致。")
    case "association":
        DiagnosticCopy(rawCode: code, headline: "项目关联校验",
                       sentence: "检查记录与项目候选的关联是否成立。")
    case "eligibility":
        DiagnosticCopy(rawCode: code, headline: "执行资格校验",
                       sentence: "按策略模拟判断该记录是否具备执行资格（本构建不执行）。")
    case "passed":
        DiagnosticCopy(rawCode: code, headline: "通过", sentence: "这一组检查全部通过。")
    case "failed":
        DiagnosticCopy(rawCode: code, headline: "未通过", sentence: "这一组检查发现了未满足的条件。")
    case "blocked":
        DiagnosticCopy(rawCode: code, headline: "受阻", sentence: "这一组检查因前置条件缺失无法完成。")

    // Decision states, shown wherever an entry's state is read.
    case "hold":
        DiagnosticCopy(rawCode: code, headline: "待定",
                       sentence: "FormaCore 把它保持为待定：证据够了才会确认，不会替你猜。")
    case "unknown":
        DiagnosticCopy(rawCode: code, headline: "未知",
                       sentence: "FormaCore 没有得出结论；这个槽位不会被当作答案使用。")
    case "validated":
        DiagnosticCopy(rawCode: code, headline: "已验证",
                       sentence: "字段有证据支撑并通过了验证规则。")
    case "mapped":
        DiagnosticCopy(rawCode: code, headline: "已映射",
                       sentence: "字段已给出映射值，但还没有通过全部验证。")
    case "invalidated":
        DiagnosticCopy(rawCode: code, headline: "已作废",
                       sentence: "这个条目已被 FormaCore 作废，需要重新扫描或重新处理。")

    // Digest fingerprints: a version marker, not a judgement.
    case "digest":
        DiagnosticCopy(rawCode: code, headline: "内容摘要指纹",
                       sentence: "这是该版本输入与上下文的摘要指纹，用于离线复核一致性；它是技术标识，不代表内容质量。")

    default:
        DiagnosticCopy(rawCode: code, headline: "FormaCore 内部诊断项",
                       sentence: "FormaCore 记录了它的内部原因代码；展开「诊断详情」可以看到原文，向支持人员报告时请附上它。")
    }
}

/// The Exceptions filter grammar. The blocked states are FormaCore's
/// `DecisionState`s; the shell names them with the same business copy the
/// rows carry, so the filter and the table never speak two dialects.
public enum ExceptionFilterState: String, CaseIterable, Codable, Identifiable, Sendable {
    case all
    case hold
    case unknown
    case invalidated

    public var id: String { rawValue }

    /// The state this filter selects, or nil for "every blocked state".
    public var state: DecisionState? {
        switch self {
        case .all: nil
        case .hold: .hold
        case .unknown: .unknown
        case .invalidated: .invalidated
        }
    }

    public var title: String {
        switch self {
        case .all: "全部受阻状态"
        default: businessCopy(for: rawValue).headline
        }
    }
}
