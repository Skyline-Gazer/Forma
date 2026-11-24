# Forma UX Recovery — Internal Alpha 工作台设计与验收

状态：实施中。总任务 #144，首次人工修正证据故障 #145。Owner Mac 现场 S1 = FAIL，S2–S5 = NOT_VERIFIED，S6 = launch PASS。任何新 App 构建都不能在未经现场复测时声称 Field Accepted。

## 0. 2026-11-23 重构说明：审核工作台并入统一 App Shell（取代首轮独立 Tab）

本节为规范性说明；下文 §1–§7 保留为历史记录（含首轮 06e7166 的 Tab 形态），其信息架构部分已被本节取代。

Owner 决定（#148，2026-11-23）确认 Forma 是 AI-native 文档理解与归档助手：不存在 Offline-First 产品要求，LLM 语义路径是默认；确定性 Offline Planner 是内部替代/手动草稿工具，不是产品特性。据此，本 PR（#146，同分支重建）做了三件事：

1. **撤销独立入口**：首轮 Review Desk 在顶部 TabView 追加「资料整理」Tab，加剧了 #148 指出的碎片化。该 Tab 已随 D1 统一 Shell（#157，`NavigationSplitView` + Inspector + 命令语法）并入而删除；资料整理改为 Shell 的**一个 AppArea**（`review`，Presentation 层 `AppArea` 追加，旧 rawValue 全部保留，Codable 兼容），并且是新的默认落地页（`AppArea.defaultLanding`；旧值「未选择/未知」恢复时落到工作台，已持久化的工程区域选择保持有效）。旧的 Workspace/Mapping/Import/Exceptions/Settings 五个区域原样保留为高级/诊断路径，未删除任何界面。
2. **AI 默认 + 明示回退**：流程为 选择来源 → 扫描 → 项目上下文 → **AI 理解**（默认下一步）→ 逐份审核 → 归档预览（ImportPlanner Dry-Run，无写入）。AI 运行前必过 EgressConsent 确认（复用 #157 的确认弹窗与模型/许可摘要），无密钥或无许可时只做设置引导，绝不产出模拟的「AI 结果」；Offline Planner 仅以「手动草稿（非 AI 理解）」按钮显式呈现，措辞与结果均不按成功/智能框架。状态机在 Core Presentation（`ReviewDeskFlow.swift`）：阶段、每阶段允许动作、Save & Next 仅当 FormaCore 发布了新修订才前进（拒绝则保持当前文件、错误按 缺少证据/证据过期/冲突/权限 就近显示，原始代码只进「诊断详情」）。
3. **复用业务组件**：字段中文标签、类别 Profile 枚举下拉、按 文件名/来源目录/正文（页·段）分组的证据勾选、被拒保留草稿、归档预览与导出，均为首轮 P1/P2 组件的延续，但承载在共享 Shell 的页内 + Inspector + 共享修正表单里，不再有第二套导航。

依赖与边界（合并顺序敏感）：本 PR 以 D1（#157）为宿主；#158（D3）落地后，证据定位渲染补一行 `.text → 正文 · 字符 a–b`（当前新枚举统一走 `default:` 防御，不引用任何仅存在于 D3 分支的 API）；`evidence_snapshot_mismatch`（#147）同样按字符串匹配，不引用其符号；`WorkspaceModel` 仅追加工作台状态段（与 D2 #151 的改动面保持文本级可解）。FormaCore 验证器/快照/证据语义零改动。视觉与交互的最终验收属 Owner Mac 现场（#153），CI 只证明可构建与确定性合同。

## 1. 成熟产品参考

| 产品 | 采用模式 | 不照搬 |
| --- | --- | --- |
| [Paperless-ngx](https://docs.paperless-ngx.com/usage/) | Inbox 待处理队列、文档详情、可读字段、逐份审核 | Web 服务架构与自动分类假设 |
| [Zotero](https://www.zotero.org/support/quick_start_guide) | Collection → 文件 → 属性面板；[Zotero 7 可折叠 Item Pane](https://www.zotero.org/support/dev/zotero_7_for_developers) | 学术条目型复杂表单 |
| [Eagle](https://eagle.cool/support/article/interface-inspector) | 文档内容/预览与属性同一上下文 | 图片资产缩略图瀑布流 |
| [Hazel](https://www.noodlesoft.com/manual/hazel/work-with-folders-rules/create-edit-rules/preview-a-rule/) | 操作前预览规则匹配、展示阻断结果 | 自动移动或写入文件 |

## 2. 要解决的用户任务

选择本地资料目录 → 扫描和识别项目 → 逐份审核中文业务字段与其支持证据 → 查看符号目标 Group 与阻断原因 → 导出只读结果。

用户不需要理解 Manifest、Snapshot、Evidence ID、CasePack、Eligibility、Cloud Provider、Revision。核心流程必须不依赖在 Workspace / Mapping / Import / Exceptions 之间反复切换。

## 3. 信息架构与交互

主入口：**资料整理**。第一轮在单页集中展示「选择目录」「扫描」「识别项目」「开始离线审核」「归档预览」，以及文件队列与右侧业务字段。
旧工程页保持可用，作为高级诊断入口，待新路径通过现场测试再整合/收起。

**项目归档首要字段**：项目名称、归档完成年份、文件分类。
**厂商资料首要字段**：文件分类、文件类型、出具单位。
其余字段默认折叠。所有字段用中文业务名称，类别必须是当前 Profile 枚举 Picker，不是自由文本。

文件队列需要清晰区分：尚未确认 / 信息待补充 / 已验证 / 来源已变更。显示文件名而不是截断的完整长路径。证据显示正文、目录和文件名的摘录，隐藏内部哈希 ID；保存时仍引用真实 Evidence ID。

**绝不伪造结果**：Offline Planner 继续生成全部未知字段；无内容证据的文件不猜测分类；没有经过 Core 验证和存储的决定不能显示「保存成功」。

## 4. P0 功能正确性优先（#145）

真机第一次扫描 → 建立上下文 → 离线 Mapping 后，选择真实路径证据修正项目名返回 evidence_not_found 两次。需验证 captureEvidence 首次计算 SHA-256 时 SourceReconciliation.publishEvidence 增加 Snapshot revision，而 WorkspaceModel.runMapping 使用捕获前列表构建 Manifest，导致 Evidence 与 Manifest 绑定版本不同。必须基于失败测试确认最终根因。

修复要求：**一遍扫描、一遍 Mapping、第一次修正成功**。要同步 Capture 后 Snapshot、Context、Manifest 的真实绑定；不得削弱 Validator、删除校验、虚构 Evidence 或把重复扫描当成正常交互。独立小 PR，完整 macOS CI，Owner Mac 复验。

## 5. P1 审核工作台（本分支首轮代码）

- 新默认可见的 Review Desk：来源/资料库选择、流程行动、文件队列、右侧审核；
- 关键字段中文化，类别 Profile 下拉；展开显示其他业务字段；
- 真实本地正文摘录可阅读，证据勾选以内容为主而非哈希 ID；
- 修正被拒绝时在主界面显示人话与未保存结果，内部错误码保留在高级诊断；
- 内嵌 ImportPlanner 的只读目标 Group 和阻断原因概览，绝不执行导入。

P1 第一轮不包含完整 PDFKit/QuickLook 预览，不包含项目级批量继承，不包含自动保存并下一份，不谎称所有 UX 已完成。这些纳入现场反馈后的下一轮。

## 6. P2 体验迭代（须由 P1 Field Feedback 驱动）

- 受 sandbox/bookmark 控制的 PDF/Office 预览，尊重 dataless 占位符，不能预览时诚实显示提取文本；
- 待审核/已验证/需关注筛选，成功后前往下一份，拒绝保存不前进；
- 项目级字段集中确认，继承必须经过 Evidence/Context 合同验证；
- 读屏、焦点、暗亮色、键盘快捷键与不同窗口宽度。

## 7. 验收

工程 Gate：macOS FormaCore tests、app build、package、launch smoke、必要的 UI 回归；不变更 main、不绕过 exact HEAD 合并授权；不启用真实 Cloud egress 或 DEVONthink 写入。

现场 Gate：Owner 用 6 个合成文件独立完成首次扫描和第一条项目名修正；正文/路径证据与值匹配；完成年、类别连续修正不丢失；保存重开数据不丢；归档 Dry Run 目标正确，阻断清晰且无执行按钮；Vendor Library 不虚构项目；无有效证据的错误可理解。

达成 Gate 前：ALPHA_ENGINEERING_READY 可保留历史工程定义，ALPHA_FIELD_ACCEPTED = NO，不进行正式 Release。
