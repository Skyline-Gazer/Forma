# Forma — Agent 工作边界

Owner 已授权实施 P0/P1。操作前阅读冻结的 `docs/SPEC.md`、已批准的 `docs/PLAN.md`、`docs/ROADMAP.md` 和对应 GitHub Issues。

1. `docs/SPEC.md` 是已冻结的产品与技术规范，不能自行改动。
2. 本轮范围为 P0/P1 原生工程、只读探针、来源扫描与最小 Workspace，以及标准构建与测试。P2、I1、I2 和发行需要单独授权。
3. 只读使用 `Skyline-Gazer/tmp@cba4bc35831b67ebb3a41bfbc70a9fe89c7b428b` 作为领域经验参考；不要复制真实内部业务数据到公开的 Forma。
4. Prototype 阶段禁止一切 DEVONthink 写入。数据查询仅限明确授权的隔离数据库。不得访问生产档案进行验证，也不得修改已有 991 条记录。
5. 未验证的 MCP、AppleScript、沙盒能力必须明确标识，不可当成已支持。
6. 将 Prototype 和 Import/Release 阶段区分；一次集中复核即可，不添加无批准的强门禁。
7. 在 `dev` 集成可独立审查的功能 PR。每个 PR 在 GitHub-hosted macOS runner 使用固定 Xcode 执行 Swift Package 测试与 App 构建。现场验证在本地 Mac 执行，缺少条件时明确记录。未经授权不得合并至 `main`。
