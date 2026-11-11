# Forma

**AI-native document standardization for DEVONthink on macOS.**

Forma 是一款使用 Swift 6 / SwiftUI 开发的 macOS 原生应用，目标是将非标准目录、文件清单与文档内容转换为可验证的结构化 Manifest，并在后续阶段经 DEVONthink 官方 MCP 安全落地。

> **当前状态：SPEC 与 PLAN 已批准，Roadmap 和 Issues 已建立；尚未批准应用代码开发。**

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

## 参考资料

历史 DEVONthink 迁移与分类治理在 [Skyline-Gazer/tmp](https://github.com/Skyline-Gazer/tmp) 的 `tmp` 分支，固定参考提交 `cba4bc35831b67ebb3a41bfbc70a9fe89c7b428b`。

**不要直接搬运历史业务数据、个人信息、客户信息、报价或未脱敏的样本到本公开仓库。** 参考规则需提炼成匿名/合成示例。该仓库不是旧 Python 工具的代码迁移工程。

## 当前审批边界

Agent 可根据已冻结 SPEC 编制候选 `docs/PLAN.md` 并通过独立分支/PR 提交供审核。未经 Owner 单独授权，不创建 GitHub Project、Issues，不合并实施 PR，也不开始应用代码开发。
