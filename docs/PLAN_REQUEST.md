# Forma — PLAN 编制任务书

**状态：已授权编制候选 PLAN；未授权项目拆解入 GitHub Project 或实施开发。**

## 输入（按优先级）

1. 当前仓库 [docs/SPEC.md](SPEC.md)，版本 **v0.1.1 FROZEN**；属于产品契约，不可自行变更。
2. 参考仓库 `Skyline-Gazer/tmp`，`tmp` 分支，固定提交 `cba4bc35831b67ebb3a41bfbc70a9fe89c7b428b`。只读参考其 DEVONthink MCP 经验、分类规则、纠正案例及生产失败教训。
3. 需要时核对 DEVONthink 官方 MCP/AppleScript 能力、Swift/macOS API 的实际限制；**未亲自实测的能力标记待验证**，不得臆测。
4. 本任务书和 [AGENTS.md](../AGENTS.md)。

## 目标

生成一个可执行、依赖明确、可逐阶段验收的 **`docs/PLAN.md`（候选计划）**，足以供 Owner 进行**一次集中复核**。计划不等于实施授权。

## 必须完成的 PLAN 内容

- 确定从扫描、身份/快照、文件簇候选、上下文、AI 映射、字段 Evidence、Manifest、Schema 校验、只读 MCP、执行引擎到回读的模块边界；界面/UI 作为这些能力的操作层。
- Prototype 优先：真实目录扫描 + PDF/DOCX/XLSX 最小只读抽取 + 双 Profile + 至少两种 AI Provider 的结构化输出兼容 + 按证据决定自动化资格 + Manifest 预览/导出 + **隔离库只读 MCP 查询**；不得写入 DEVONthink。
- 明确 `source_id` 持久化身份与 `snapshot_fingerprint` 的确定性算法/失效处理；重扫、文件移动、File Provider inode 变化、父子 `source_root` 重叠；提出测试。
- AI 评测方案：真实、独立、脱敏的金标准样本；Few-shot/评测集去重与项目簇隔离；分层指标公式、置信区间、成本/token/时延；现有 78 条有限正文核验**不等于**150 条已达标金标准，不能虚报。
- 12 个现有 Custom Metadata 字段使用实际 Identifier；项目字段与文档字段分离；字段级证据、冲突、可空与例外处理。
- Import 后续阶段：Preflight/OneDrive hydration、增量 SHA-256、SQLite ledger、写入三态和 `VERIFY_REQUIRED`、single-writer 强制、MCP 结果回读、失败恢复。
- Replicant 为**条件可选且非默认**；仅兼容且经官方能力实测后可用；元数据冲突独立记录。单独计划临时记录验证，不允许在生产记录上试错。
- 设计轻量 Correction Capture：纠正成为候选案例，经审核/脱敏才进入精选 Case Pack；禁止把自动结果循环训练成真值。
- macOS 原生体验与安全：Swift 6/SwiftUI、必要 AppKit、SQLite/GRDB、CryptoKit、Keychain、文件访问/云端占位、敏感信息脱敏和云端外发权限；不引入 Rust、Tauri、独立 RAG/Vector DB。
- 每一阶段列清输入/输出、依赖、验收证据、范围外、回退方案；给出对应未来 Epic/Feature/Task 的**草案**，但不实际创建 Github 事项。
- 单列 SPEC §11 的 V1–V7 验证项，标明阻塞哪一阶段；优先处理真正阻塞 Prototype 的事项，不为 Import/Release 的未决问题拖慢映射原型。

## 提交形式

- 主要成果：`docs/PLAN.md`，一份完整、凝练的实施计划。
- 可选：只在内容不能合理放入 PLAN 时增加一份 `docs/PLAN_OPEN_QUESTIONS.md`；默认不需要。
- 在 `plan/forma-v0.1.1` 分支提交，并创建**一个 PR 指向 main**供复核；不要自行合并。
- 最终汇报：分支、Commit、PR、阶段概览、关键风险与需 Owner 决策的少数问题。

## 禁止事项

- 不修改冻结 `docs/SPEC.md`；发现矛盾在 PLAN 单列提案，不擅改产品政策。
- 不创建 GitHub Project、Issues、Milestones；不开始应用代码、脚手架或测试实现。
- 不修改 DEVONthink、OneDrive 或已验收的 `Project_Archive` 991 条记录；MCP 能力核验仅允许只读（如必须写入验证，留到获授权的 Import 阶段）。
- 不复制、提交或泄露 `tmp` 仓库的真实文件清单、客户/人名、内部路径、报价、文档内容、UUID 级账本等敏感资料到公开的 Forma。
- 不为了 PLAN 自行扩展需求、搭建 RAG、过度工程化，或反复发起无实际价值的复审。
