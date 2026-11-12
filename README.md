# Forma

**AI-native document standardization for DEVONthink on macOS.**

Forma 是一款使用 Swift 6 / SwiftUI 开发的 macOS 原生应用，目标是将非标准目录、文件清单与文档内容转换为可验证的结构化 Manifest，并在后续阶段经 DEVONthink 官方 MCP 安全落地。

> **当前状态：P0/P1 与 P2 已在 `dev`，P2 验收报告已发布；来源扫描、身份、快照、证据抽取、只读能力探针、双 Profile 与 Schema 门禁、Context Builder、Evidence Registry、Manifest Validator、Provider Mapping Engine、CasePack、脱敏与外发预览、Manifest 导出与离线重校验、Correction Capture、原生 SwiftUI 工作界面均已合并并由 GitHub Actions 验证。真实 Provider 调用、隔离 DEVONthink 库对齐、授权 OneDrive 目录三项现场验证仍为 BLOCKED，GUI 人工交互为 NOT_VERIFIED，逐项判定见 [P2 验收报告](docs/P2-ACCEPTANCE.md) 与 [P0 / P1 验收报告](docs/P0-P1-ACCEPTANCE.md)。**授权状态以 [ROADMAP 的「授权历史」](docs/ROADMAP.md) 为唯一权威来源**：2026-11-12 Owner 决策确认 P0/P1 已完成、P2 已授权且工程实现完成（外部现场验收项继续追踪，不等同于真实环境验证通过，也不宣称生产就绪）、P3-A 离线评测基础设施已授权、P3-B 真实模型评测与 I1/I2/R1 未授权。ADS 以不可变 SHA 接入（[ads-pin.txt](ads-pin.txt)、[docs/ADS-ADOPTION.md](docs/ADS-ADOPTION.md)）；阶段授权与权限边界由 [docs/ROADMAP.md](docs/ROADMAP.md) 和 [AGENTS.md](AGENTS.md) 在仓库内记录。**

## 文档入口

- [冻结的产品与技术规范](docs/SPEC.md) — 唯一已批准的产品/架构基线
- [已批准的 PLAN](docs/PLAN.md) — 技术实施阶段与验收契约
- [实施 Roadmap](docs/ROADMAP.md) — Owner 决策、阶段依赖与 Epic/Feature Issues
- [PLAN 编制任务书](docs/PLAN_REQUEST.md) — 规划过程归档
- [Agent 约束](AGENTS.md) — 仓库权限与边界
- [ADS 接入与 CNB 评审拓扑](docs/ADS-ADOPTION.md) — 提供方职责、固定 SHA 与评审证据
- [P0 / P1 验收报告](docs/P0-P1-ACCEPTANCE.md) — 实际执行结果、PASS/FAIL/BLOCKED/NOT_VERIFIED 判定与限制
- [ADS 与 CNB 评审验收报告](docs/ADS-CNB-ACCEPTANCE.md) — 接入一致性、评审闭环、SHA 绑定与三项独立结论

## 构建与运行

```bash
# 核心库测试（GRDB / ZIPFoundation 版本按 Package.resolved 锁定）
swift test --force-resolved-versions

# macOS 原生 GUI（SwiftUI 宏需要完整 Xcode；仅有 Command Line Tools 的机器无法编译此目标）
swift build --package-path FormaApp --product Forma
.build/FormaApp/debug/Forma
```

工具链基线：macOS 14 部署目标，Swift 6 严格并发。GitHub Actions 在 `macos-15` + Xcode 26.3 固定环境执行核心测试与 App 构建。P0/P1 不做签名、公证与发布。

使用方式：在 Workspace 选择本地或 OneDrive 目录 → **Scan** → 查看清单、统计与问题 → 选择文件后 **Read Evidence**（PDF/DOCX/XLSX 定位片段）或 **Compute SHA-256**（按需流式计算）。扫描仅读取元数据，不强制下载云端占位内容；状态与快照持久化在 Application Support 下的 SQLite，重启后继续可见。Settings 中的 **Connections** 提供 DEVONthink MCP 工具发现、隔离库只读核对与 Provider 探针（需 Keychain 凭据与当次外发授权）。

普通 CI 不访问 DEVONthink、OneDrive 或真实 AI API；真实能力验证状态记录在 [P0 能力契约证据](docs/P0-CONTRACT-EVIDENCE.md)，Mock 结果不计为现场验证。

## 确定的方向

- macOS Only；Swift 6、SwiftUI、必要时 AppKit
- AI 负责业务映射；Swift 负责扫描、校验、执行与回读
- Project Archive 与 Vendor Library 两种 Profile
- 精选案例 Few-shot；不引入独立 RAG/向量数据库
- SQLite 仅管理任务、Manifest、必要关系；DEVONthink 是最终档案来源
- 共享记录仅在元数据语义兼容且官方能力实测支持时考虑 Replicant，非默认去重策略
- 先验证 AI Mapping 的质量，再构建实际 Import 闭环

## 参考资料

历史 DEVONthink 迁移与分类治理在 [Skyline-Gazer/tmp](https://github.com/Skyline-Gazer/tmp) 的 `tmp` 分支，固定参考提交 `cba4bc35831b67ebb3a41bfbc70a9fe89c7b428b`。

**不要直接搬运历史业务数据、个人信息、客户信息、报价或未脱敏的样本到本公开仓库。** 参考规则需提炼成匿名/合成示例。该仓库不是旧 Python 工具的代码迁移工程。

## 当前审批边界

Agent 可根据已冻结 SPEC 编制候选 `docs/PLAN.md` 并通过独立分支/PR 提交供审核。未经 Owner 单独授权，不创建 GitHub Project、Issues，不合并实施 PR，也不开始应用代码开发。
