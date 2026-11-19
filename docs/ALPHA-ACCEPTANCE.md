# Forma Internal Alpha 验收清单（Read-only Mapping & Import Planning）

状态：本文件随 Slice B（Import 预检与 Dry Run）提交。**Alpha 尚未发布**；下列场景中只有标注 `CI` 的部分由自动化验证，其余必须在 Owner Mac 上人工执行，未执行即 `NOT_VERIFIED`。

## 0. 这一版是什么

- 可启动、可选来源、可扫描、可生成/修正 Manifest、可保存与导出、可查看 Import Dry Run。
- **不可写入 DEVONthink**：本构建没有任何 MCP 写调用路径；Import 页面只做计划与原因说明。
- 离线映射（不接 Provider）尚属 Slice A，未随本版交付；当前映射仍需要 Provider 凭据，或使用测试路径。

## 1. 由 CI 保证（每次 PR）

| 项 | 证据 |
| --- | --- |
| FormaCore 全部单测（含 Import 预检/运行时/Ledger/边界） | `FormaCore tests` job |
| `ImportPlannerTests`（干跑语义、未观测目标、原因聚合） | 同上 |
| App 可编译 | `macOS app build` |
| App 可打包、结构/签名自检、可启动 | `macOS app package` + `macOS app launch smoke` |
| Benchmark 冒烟 | `Benchmark smoke (100 records)` |

## 2. 人工场景（Owner Mac，逐条记录结果）

每条记录：日期 / App 构建来源（CI run ID）/ 结论（`PASS` / `FAIL` / `NOT_VERIFIED`）。

### S1 Project Archive 主流程
1. 准备一个**合成**投标项目目录（含 6 类文件与噪声文件）。
2. Workspace 选择该目录 → 扫描 → 确认记录数、错误、issue。
3. 选择 Profile = Project Archive → 构建上下文 → 运行 Mapping。
4. Mapping 页查看目标、证据、未知字段与冲突。
5. 修正一条分类／字段 → 重新验证 → 状态变化可见。
6. 保存并重新打开 Manifest → 内容一致。
7. 导出 bundle → 用 `revalidate` 复检通过。

### S2 Vendor Library
1. 选一个**无项目归属**的厂商资料目录。
2. Profile = Vendor Library → Mapping 成功，不出现虚构项目名。
3. 导出的 Manifest 目标组不含项目占位。

### S3 中断恢复
1. 扫描或 Mapping 进行中强制退出 App。
2. 重启后：状态可读、未完成的运行被标为中断、已确认的修正不丢失。

### S4 来源变更
1. 修改来源中一个已映射文件的内容。
2. 重新扫描 → 旧 manifest/决策按合同失效，不得继续显示为可执行。

### S5 Import Dry Run
1. Mapping 页确认 Manifest 为已验证状态。
2. Import 页 → Build plan。
3. 检查：横幅说明干跑；blocked/deferred/ready 计数；原因 chips；逐条目标组。
4. 导出 `import-plan-rN.json`，确认含 `"writesInThisBuild": false`。
5. 确认**不存在**任何执行按钮或写入触发。

### S6 打包版
1. 从 CI artifact 解包 `Forma.app`，启动。
2. 重复 S5 的最短路径（选择来源 → 扫描 → 计划）。
3. 记录 App 版本、CI run ID 与结果。

## 3. 明确未验证（不得写成 PASS）

| 能力 | 状态 | 原因 |
| --- | --- | --- |
| 真实 Provider 映射质量 | `NOT_VERIFIED` | 无凭据；离线映射未交付 |
| OneDrive / FileProvider 真实行为 | `NOT_VERIFIED` | 未授权真实云样本；仅协议与模拟 |
| 真实 DEVONthink 导入 | `NOT_AUTHORIZED` | 本构建无写路径 |
| 正式签名/公证 | 未开始 | 内部构建仅 ad-hoc 签名 |
| Level 5 默认过滤 | `NOT_AUTHORIZED` | 保持 `OFF` |
