import Foundation

/// The user-facing product copy of the ordinary workflow, in one place.
///
/// M0-R1 physical acceptance (#153) found the same product speaking two
/// languages: the Review Desk read to the reviewer in Chinese while the
/// status strip, the Workspace, the archive plan and the recovery dialogs
/// stayed in engineering English ("Scanning…", "Blocked", "Exported 6
/// files…", "Bundle is self-consistent"). A person must not need
/// engineering knowledge to interpret an ordinary workflow state, and one
/// reviewer's screen must not call the same thing current in one pane and
/// `Validated` in another. So the sentences live here, the same way
/// `DeskGuidance`, `EvidenceCurrencyCopy` and `businessCopy(for:)` already
/// live here: they are tested strings, not view literals.
///
/// What deliberately does NOT move here:
/// - stable machine-readable codes (`evidence_snapshot_mismatch`,
///   `snapshot_changed`) - they are the contract FormaCore emits and the
///   诊断 surface quotes verbatim;
/// - product, provider and protocol names (Forma, FormaCore, DEVONthink,
///   OneDrive, MCP, SHA-256);
/// - the expandable diagnostic detail (token counters, extractor versions),
///   which is a support surface, not a workflow state.
public enum ProductCopy {
    /// The work the shell is doing right now: the status strip, the toolbar's
    /// Cancel neighbour, and the banners that name a phase.
    public enum Work {
        public static let idle = "空闲"
        public static let scanning = "正在扫描…"
        public static let buildingContext = "正在构建项目上下文…"
        public static func capturingEvidence(done: Int, total: Int) -> String {
            "正在登记证据 \(done.formatted()) / \(total.formatted()) 份…"
        }
        public static let mapping = "正在生成映射结果…"
        public static let exporting = "正在写入导出包…"
        public static let revalidating = "正在校验归档包…"
        public static let reconciling = "正在核对已存储的修订…"
        public static let loadingManifest = "正在读取已存储的清单…"
        public static let correcting = "正在记录修订…"
        public static let readingEvidence = "正在重新读取文件证据…"
        public static let discoveringMCP = "正在发现 MCP 服务…"
        public static let previewing = "正在构建请求预览…"
    }

    /// The Workspace area: the file table, its states, and the scan notices.
    public enum Workspace {
        public static let relativePath = "相对路径"
        public static let project = "项目"
        public static let size = "大小"
        public static let status = "状态"
        public static let present = "在位"
        public static let missing = "缺失"
        public static let cloudPlaceholder = "云端占位"
        public static let notDownloadedYet = "尚未下载"
        public static let cloudNotDownloaded =
            "Provider 还没有下载这个文件夹的内容；元数据仍然可以读取。"
        public static let symbolicLink = "符号链接"
        public static let unknown = "未知"
        public static let needsReview = "待复核"

        public static let chooseSource = "选择一个来源"
        public static let chooseSourceHint = "添加本地或 OneDrive 文件夹以扫描其中的文件。"
        public static let noContextYet =
            "还没有项目上下文：先选择资料库类型并扫描来源，再构建上下文；没有上下文时 FormaCore 不会映射文件。"
        public static let scanComplete = "扫描完成"
        public static let incompleteScan = "扫描不完整 · 重新扫描以恢复"
        public static let scanInterrupted = "扫描已中断 · 重新扫描以恢复"
        public static let scanCancelled = "扫描已取消 · 重新扫描以恢复"
        public static let readyToScan = "可以扫描"
        public static let issues = "个问题"
        public static let showingFirst25Issues = "仅显示前 25 个问题"
        public static let fileTypes = "文件类型"
        public static let noExtension = "无扩展名"
        public static let filesUnit = "个文件"
        public static let foldersUnit = "个文件夹"
        public static func profileLine(versionKey: String, target: String,
                                       categories: Int, granted: Bool) -> String {
            "资料库 \(versionKey) · 目标 \(target) · \(categories.formatted()) 个类别 · 执行授权\(granted ? "已授予" : "从未授予")"
        }
        public static let projectCandidates = "项目候选"
        public static let revisionLabel = "修订"
        public static let builtAt = "构建于"
        public static let contextInputsChanged = "上下文输入已变化 · 映射前请重新构建"
        public static let candidate = "候选"
        public static let filesCount = "文件数"
        public static let basis = "依据"
        public static let confidence = "置信度"
        public static let noFilesInCategory = "FormaCore 在当前清单中没有报告该类别的文件。"
        public static let readEvidence = "读取证据"
        public static let computeHash = "计算 SHA-256"
        public static let cancelEvidenceRead = "取消证据读取"
        public static let accessNeedsRenewing = "需要重新授权访问"
        public static let accessRevoked = "访问授权已撤销"
        public static let reauthorize = "重新授权…"
        public static let folderDifferentNow = "该文件夹与登记时已不同"
        public static let folderNotFound = "找不到该文件夹"
        public static let sourceAvailable = "来源可读"
        public static let sourceNeedsAttention = "来源需要关注"
        public static let sourceUnavailable = "来源不可用"
        public static let sourceReadable = "该来源可以读取。"
        public static let sourceAttentionHint = "该来源需要关注。"
        public static let renewsAccess = "只有当文件夹仍是同一个时，Forma 才会续期访问授权。"
        public static let sourceAvailableRead = "来源仍然可读。"
        public static let snapshotRevision = "快照修订"
        public static let sourceVersion = "来源版本"
        public static let storage = "存储"
        public static let local = "本地"
        public static let fileProvider = "File Provider"
        public static let noCachedValue = "无缓存值"
        public static func candidatesRevision(revision: Int) -> String {
            "项目候选 · 修订 \(revision.formatted())"
        }
        public static func bookmarkStaleDetail(path: String) -> String {
            "针对「\(path)」存储的授权已失效。请再次选择同一个文件夹以续期。"
        }
        public static func accessRevokedDetail(path: String) -> String {
            "macOS 不再允许 Forma 读取「\(path)」。文件没有被标记为缺失；续期访问授权后即可继续。"
        }
        public static func folderGoneDetail(path: String) -> String {
            "「\(path)」已不存在。在它恢复之前扫描保持不完整，以免把文件误标为缺失。"
        }
        public static func stateUnknownDetail(path: String) -> String {
            "Forma 无法确定「\(path)」的状态。"
        }
        public static let clusterMembershipNote =
            "项目成员关系由 FormaCore 判定。未归属与冲突的文件保持可见，不会被猜测性地归入项目。"
        public static func formulaLine(_ value: String) -> String { "公式：\(value)" }
        public static func cachedLine(_ value: String) -> String { "缓存值：\(value)" }
    }

    /// The archive area: the import plan and its dry-run promise.
    public enum Archive {
        public static let importPlan = "导入计划"
        public static let records = "记录"
        public static let blocked = "受阻"
        public static let deferred = "暂缓"
        public static let ready = "就绪"
        public static let noRecordsToPlan = "这份清单没有可规划的记录。"
        public static let dryRunBanner =
            "当前构建只做 Dry-Run：没有通往 DEVONthink 的写入路径，任何记录都不会被写入。"
        public static let privacyNote =
            "计划列出的是本机文件名；请将导出件按私密资料对待，而不是脱敏产物。"
        public static func sourceFacts(_ observation: String) -> String {
            "来源事实：\(observation)"
        }
        public static let targetNeverObserved =
            "目标分组从未被观测到，因此按未解析报告，而不是缺失"
        public static let noContentDigest =
            "没有记录内容摘要，因此本计划不对文件字节作任何声明"
        public static let noTargetGroup = "无目标分组"
        public static let unresolved = "未解析"
    }

    /// The diagnostics areas' shared business vocabulary: the columns and the
    /// decision states a reviewer filters by.
    public enum ReviewVocabulary {
        public static let state = "状态"
        public static let violations = "违规"
        public static let violationCode = "违规代码"
        public static let codes = "原因代码"
        public static let entries = "记录"
        public static let reason = "原因"
        public static let recordedReason = "记录的原因"
        public static let relativePath = "相对路径"
        public static let decisionState = "决策状态"
        public static let validated = "已验证"
        public static let invalidated = "已作废"
        public static let hold = "暂缓"
        public static let unknown = "未知"
        public static let eligible = "符合自动执行"
        public static let selected = "已选定"
        public static let shown = "显示"
        public static let revisionCounts = "修订计数"
        public static let reprocessing = "重新处理"
        public static let filesInScope = "范围内文件"
        public static let snapshot = "快照"
        public static let sourceIdentifier = "来源标识"
        public static let filter = "筛选"
        public static let allReasons = "全部原因"
        public static let unassigned = "未归属"
        public static let noContext = "无上下文"
        public static let run = "运行"
        public static let mode = "模式"
        public static let phase = "阶段"
        public static func manifestRevision(_ revision: Int) -> String {
            "清单修订 \(revision.formatted())"
        }
        public static let grantsExecution = "授予执行权限"
        public static let yes = "是"
        public static let no = "否"
        public static let nothingWritten = "不会写入任何内容"
        public static let identityRedaction = "身份方案（无词条）"
        public static func countPair(_ first: Int, _ second: Int) -> String {
            "\(first.formatted()) / \(second.formatted())"
        }
        public static let eligibleBySimulation = "政策模拟判定符合"
        public static let correctionAttempts = "修订尝试"
        public static let correctionNotRead = "该清单的修订尝试尚未从存储读取。"
        public static let correctionStoredElsewhere = "该归档包在别处导出；它的修订尝试不存在本机。"
        public static let correctionNone = "该清单还没有记录任何审阅者决策。"
        public static let correctionReadFailed =
            "无法从存储读取修订历史，这里只列出刚刚做出的决策，不是全部尝试。"
        public static let cleared = "清空"
        public static func correctionRecorded(produced: Int, superseded: Int,
                                              previous: String?) -> String {
            "已在修订 \(produced.formatted()) 记录，取代修订 \(superseded.formatted()) · 替换了\(previous ?? "（无原值）")"
        }
        public static func correctionRefused(against revision: Int) -> String {
            "已被 FormaCore 拒绝 · 针对修订 \(revision.formatted()) 尝试 · 未发布任何内容"
        }
        public static func correctionUnattributed(revision: Int) -> String {
            "针对修订 \(revision.formatted()) 的已验证决策 · 两次尝试记录了同一修订，版本 1 迁移未为这一次留下写入的修订"
        }
        public static func correctionAnomalous(id: UUID, state: String,
                                               produced: String?) -> String {
            "该行（\(id)）不属于审阅产生的两种形态（已验证并写明修订，或被拒绝且无修订）：状态为 \(state) · \(produced ?? "无写入修订")"
        }
        public static let validation = "验证"
        public static let fullyValid = "全部有效"
        public static let reconciliation = "核对"
        public static let invalidatedFiles = "已作废文件"
        public static let stillUsable = "仍可用"
        public static let export = "导出"
        public static let manifest = "清单"
        public static let offlineRevalidation = "离线校验结果"
        public static let artifactConsistent = "归档包自洽"
        public static let missingEvidenceRows = "缺失的证据行"
        public static let digestMismatches = "摘要不匹配"
        public static let modelSettings = "模型设置"
        public static let filesPerBatch = "每批请求文件数"
        public static let noExceptions = "没有例外"
        public static let reprocessedScopeNote =
            "重新处理只覆盖选中的文件，因此该修订的清单只列出这些条目。"
        public static let noViolationsForPath = "FormaCore 没有为该路径记录任何违规。"
        public static let selectException = "选择一条例外"
        public static func filesSelected(_ count: Int) -> String {
            "已选定 \(count.formatted()) 个文件"
        }
        public static let noMappingResult = "暂无映射结果"
        public static let confidenceModelReported = "置信度（模型报告）"
        public static let notReported = "未报告"
        public static let confidenceHelp =
            "该值由模型报告。决定是否符合自动执行的是 FormaCore 的证据规则，而不是这个值。"
        public static let eligibleSimulationColumn = "符合自动执行（政策模拟）"
        public static let simulatedYes = "模拟为是"
        public static let simulatedNo = "模拟为否"
        public static let policySimulationHelp = "仅为政策模拟。FormaCore 不会向任何数据库写入内容。"
        public static let evidenceCount = "证据数"
        public static let modelReportedConfidence = "模型报告的置信度"
        public static let eligibleForAutoExecution = "是否符合自动执行"
        public static let policySimulationNothingWritten = "政策模拟，不会写入任何内容"
        public static let targetGroup = "目标分组"
        public static let fileState = "文件状态"
        public static let invalidatedBy = "已被 FormaCore 作废"
        public static let providerFailure = "Provider 侧失败"
        public static let metadataSlots = "元数据槽位"
        public static let providerReasoning = "Provider 推理内容"
        public static let selectFile = "选择文件"
        public static let notWritten = "未写入"
        public static let required = "必填"
        public static let optional = "可选"
        public static let noValue = "无值"
        public static let noEvidenceCited = "该槽位没有引用任何证据"
        public static let correct = "修改…"
        public static let source = "来源"
        public static let locator = "定位"
        public static let extraction = "提取状态"
        public static let usable = "可用"
        public static let extractor = "提取器"
        public static let readAt = "读取时间"
        public static let path = "路径"
        public static let inheritedThroughCandidate = "经由候选继承"
        public static let noExcerptStored = "未存储摘录"
        public static func promptExcerpt(characters: Int) -> String {
            "提示词摘录（\(characters.formatted()) 字符以内）"
        }
        public static func evidenceRowNotRead(id: String, bundleFile: String) -> String {
            "证据行 \(id) 本次会话尚未读入。它保存在导出包的 \(bundleFile) 中；FormaCore 保留了旧修订引用过的每一行。"
        }
        public static let selectEvidenceChip = "选择一个证据标签，查看其摘录与定位。"
        public static let rowNotRead = "行未读入"
        public static let notInCurrentListing = "不在当前清单中"
        public static let noDatabaseNamed = "未命名数据库"
        public static let noGroupTemplate = "无分组模板"
        public static let resolved = "已解析"
        public static let unresolvedPlaceholder = "未解析占位"
        public static let noLocator = "无内容定位"
    }

    /// What the shell says when work finishes or refuses, in one place, so
    /// the status strip and the panels never paraphrase FormaCore's outcome.
    public enum Notice {
        public static func exported(files: Int, revision: Int) -> String {
            "已导出 \(files.formatted()) 个文件（修订 \(revision.formatted())）。"
        }
        public static func bundleConsistent(revision: Int) -> String {
            "归档包自洽 · 修订 \(revision.formatted())。"
        }
        public static func bundleChecked(files: Int, revision: Int) -> String {
            "已校验归档包：\(files.formatted()) 个文件，修订 \(revision.formatted())。"
        }
        public static let nothingToExport = "还没有可导出的清单。"
        public static let needsContextForPreview = "预览需要来源、资料库类型和已存储的项目上下文。"
        public static let chooseSourceAndProfileFirst = "请先选择来源和资料库类型。"
        public static let chooseSourceBeforeMapping = "映射之前请先选择一个来源。"
        public static let addAsNewSource = "请改为把它添加为新的来源。"
        public static let sourceNoLongerRegistered = "这个来源已经不在登记清单里了。"
        public static let selectedFilesNoLongerListed = "所选文件已不在当前清单中。"
        public static func folderNotRegisteredSource(pathHint: String) -> String {
            "这个文件夹不是该条目登记时所在的来源。\(pathHint)"
        }
        public static let correctionOtherSource =
            "这份修订是针对另一个来源或资料库类型打开的。请关闭对话框后重新打开。"
        public static let listingChangedDuringCapture =
            "证据读取期间来源清单发生了变化。请重新查看文件后再映射。"
        public static let structureChangedRebuildContext =
            "来源结构已变化。请重新构建项目上下文后再映射。"
        public static let cancelledDuringCapture = "证据读取时被取消 · 没有发出任何 Provider 请求。"
        public static let noStoredManifestToReconcile = "该资料库类型没有已存储的清单，无需核对。"
        public static let casePackLoadFailed = "随附的案例包无法加载，因此无法构建\(what)。"
        public static let casePackEngine = "引擎"
        public static let casePackRequest = "请求"
        public static let listingHasNoFiles = "当前清单没有可预览的文件。"
        public static let noManifestRunThisSession =
            "本次运行没有产生映射结果。从存储或归档包读取的清单不显示运行计数。"
        public static func accessRenewed(scope: String) -> String {
            "已续期对「\(scope)」的访问授权。"
        }
        public static let buildContextBeforeMapping =
            "请先构建项目上下文：没有上下文时 FormaCore 不会映射文件。"
        public static func runCancelled(batches: Int) -> String {
            "运行已在 \(batches.formatted()) 个批次后取消。已经返回的回答会记入运行历史，但不会发布：只有完整跑完的运行才写入修订，本次若发布会用不完整结果替换当前可用的完整修订。"
        }
        public static let resultHeldInMemory =
            "FormaCore 只在内存中保留了这次结果：该修订没有写入存储。"
        public static let importPlanNeedsManifestProfile = "生成导入计划需要清单和资料库类型。"
        public static let buildImportPlanFirst = "请先构建导入计划。"
        public static func planWritten(name: String) -> String {
            "已写入 \(name)：这是一份列出本机文件名的 Dry-Run 计划，请按私密资料对待，而不是脱敏产物。"
        }
        public static func bundleViolations(count: Int, revision: Int) -> String {
            "归档包存在 \(count.formatted()) 项违规 · 修订 \(revision.formatted())。"
        }
    }

    /// The shell's own chrome: commands, sheets, the recovery banner.
    public enum Shell {
        public static let openingWorkspace = "正在打开工作区…"
        public static let workspaceUnavailable = "工作区不可用"
        public static let chooseSourceFolder = "选择来源文件夹"
        public static let chooseExportFolder = "为导出包选择一个文件夹"
        public static let exportHere = "导出到此处"
        public static let writePlanHere = "写入计划到此文件夹"
        public static let readScope = "读取范围…"
        public static let confirmReadOnlyScope = "确认只读范围"
        public static let databaseUUID = "数据库 UUID"
        public static let databaseNameLabel = "数据库名称（仅用于显示）"
        public static let recoveryScopeHint = "请输入数据库 UUID、名称，并至少填写一个分组层级。"
        public static let invalidDatabaseUUID = "该数据库 UUID 不合法。"
        public static let readOnlyScopeStatement =
            "Forma 将只读取该数据库与分组中被打断操作的记录；从不写入，也从不重试导入。"
        public static let recheckReadOnly = "重新检查只读状态"
        public static let nothingPending = "没有待处理的操作。"
        public static let nothingAwaitingReadback = "没有任何操作在等待读回验证。"
        public static let cancel = "取消"
        public static func reauthorizeFolder(name: String) -> String {
            "请再次为「\(name)」选择它所在的文件夹"
        }
        public static let recoveryScopeTitle = "只读恢复范围"
        public static let groupPathPlaceholder = "分组路径，例如 Forma_I1B2/r1"
        public static let choosePlanFolder = "为导入计划选择一个文件夹"
        public static let ok = "好"
        public static let interruptedImports = "已中断的导入操作"
        public static func recoverySweepFailed(detail: String) -> String {
            "恢复扫描失败：\(detail)"
        }
        public static func readScopeLine(name: String, path: String) -> String {
            "读取范围：\(name) · \(path)"
        }
        public static let notStarted = "尚未开始"
        public static let intentRecorded = "已记录意图，未创建记录"
        public static let recordCreated = "已创建记录，字段待写入"
        public static let metadataAnswered = "字段已写入，待读回验证"
        public static let outcomeUnknown = "结果未知"
        public static let settled = "已确认"
        public static let nothingReviewed = "没有复核任何条目"
        public static func reviewVerdict(conclusive: Bool, parts: String) -> String {
            "只读重新检查（\(conclusive ? "已定论" : "未定论")）：\(parts)"
        }
        public static let needsScopeExplanation =
            "重新检查只读状态需要先确认只读范围；在确认之前，这些操作保持 VERIFY_REQUIRED，绝不自动重试。"
        public static let workspaceUnopenable = "无法打开工作区或台账，因此不尝试重新检查。"
    }
}
