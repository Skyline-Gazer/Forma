# Forma

**AI-native document standardization for DEVONthink on macOS.**

Forma 是一款使用 Swift 6 / SwiftUI 开发的 macOS 原生应用，目标是将非标准目录、文件清单与文档内容转换为可验证的结构化 Manifest，并在后续阶段经 DEVONthink 官方 MCP 安全落地。

> **当前状态：SPEC / PLAN / Roadmap 已批准；P0/P1 已获 Owner 授权实施，开发集成分支为 `dev`。**

## 文档入口

- [冻结的产品与技术规范](docs/SPEC.md) — 唯一已批准的产品/架构基线
- [已批准的 PLAN](docs/PLAN.md) — 技术实施阶段与验收契约
- [实施 Roadmap](docs/ROADMAP.md) — Owner 决策、阶段依赖与 Epic/Feature Issues
- [PLAN 编制任务书](docs/PLAN_REQUEST.md) — 规划过程归档
- [Agent 约束](AGENTS.md) — 仓库权限与边界

## 确定的方向

- macOS Only；Swift 6、SwiftUI、必要时 AppKit
- AI 负责业务映射；Swift 负责扫描、校验、执行与回读
- Project Archive 与 Vendor Library 两种 Profile
- 精选案例 Few-shot；不引入独立 RAG/向量数据库
- SQLite 仅管理任务、Manifest、必要关系；DEVONthink 是最终档案来源
- 共享记录仅在元数据语义兼容且官方能力实测支持时考虑 Replicant，非默认去重策略
- 先验证 AI Mapping 的质量，再构建实际 Import 闭环

## 本地开发

- macOS 14+；标准工具链为 Xcode 26.3（Swift 6）。GitHub Actions 在 `macos-15` 依次执行 Swift Package 单元测试与 macOS App 构建。仅有 Command Line Tools 的机器可以运行 `swift test`，但无法编译 SwiftUI App 目标。
- 测试：`swift test --force-resolved-versions`。
- 构建：`xcodebuild -project Forma.xcodeproj -scheme Forma -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build`。也可在 Xcode 打开 `Forma.xcodeproj` 并运行共享 `Forma` scheme。
- 在 Workspace 选择本地或 OneDrive 目录后执行 **Scan**。清单与历史快照存入本机 SQLite，重启后可继续查看。选择 PDF、DOCX 或 XLSX 文件后使用 **Read Evidence** 查看定位片段。扫描只读取元数据。占位文件未就绪时，应用保留清单并报告状态。

## 参考资料

历史 DEVONthink 迁移与分类治理在 [Skyline-Gazer/tmp](https://github.com/Skyline-Gazer/tmp) 的 `tmp` 分支，固定参考提交 `cba4bc35831b67ebb3a41bfbc70a9fe89c7b428b`。

**不要直接搬运历史业务数据、个人信息、客户信息、报价或未脱敏的样本到本公开仓库。** 参考规则需提炼成匿名/合成示例。该仓库不是旧 Python 工具的代码迁移工程。

## 当前审批边界

P0/P1 在 `dev` 通过可独立审查的 PR 开发。P2、I1、I2 和发行需要单独授权。Prototype 只对明确授权的隔离 DEVONthink 数据库查询，禁止任何 DEVONthink 写入。
