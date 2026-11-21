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

## 4. Import Plan 导出合同（PR #137）

导出的 `import-plan-rN.json` 是**机器可读的干跑声明**，不是脱敏产物、不是执行授权：

| 字段 | 值 | 含义 |
| --- | --- | --- |
| `dry_run` | `true` | 本次没有执行导入 |
| `writes_executed` | `false` | 程序没有任何写入路径 |
| `authorization_granted` | `false` | 文件本身不构成授权 |
| `purpose` | `review-only plan; not an execution authorization` | 用途 |
| `target_observed` | `false` | 目标组从未被观测，报告中为 `target_unresolved` |
| `source_observation` | `scan` / `manifest only` | 来源事实的观测范围 |
| `manifest_revision` | 整数 | 对应的 Manifest 修订；修订变化后旧计划失效 |

读取方规则：任何 `writes_executed: true` 或 `authorization_granted: true` 的文件都不是本产物，解码器会拒绝它。

**隐私**：计划逐行包含 `relative_path`，可能含客户名、项目名与敏感文件名。它不是脱敏件；不要上传 GitHub、远程日志或任何外部服务。公开评审只提供单独脱敏的汇总（计数与原因码）。

## 5. Manifest Schema 1.0/1.1 兼容性（Owner 已批准，范围限 Internal Alpha）

当前 Internal Alpha 产出的 Manifest 一律是 **1.0**。`schema_version` 取决于 `eligibility`：为空即 1.0，只有启用 eligibility 过滤才写 1.1；本构建默认过滤 `OFF`，App 也从不设置该选项。

两处 schema 的声明与实际编码一致：`confirmed_by_reviewer` 在 1.0 和 1.1 中都已列入；`model_provider = offline` 只列入了 1.0。

### 旧应用读取新产物的两条已知不兼容

| 新产物中的取值 | 旧应用（不含该取值）的表现 |
| --- | --- |
| 字段状态 `confirmed_by_reviewer` | **不支持**。旧 schema 的枚举判定产物非法；旧 `FieldOutcome.Status` 没有该 case，`Codable` 解码直接失败。 |
| `model_provider = offline` | **不支持**。同为旧 schema 枚举与解码器都不含该值，产物被判定非法或读不进来。 |

两者都不是"降级显示为未知"这样温和的失效。不含上述取值的 Manifest（纯模型驱动、无人工确认字段）旧应用照常可读。

### 当前 Alpha 的实际形态

- 离线 Alpha 使用 **Manifest 1.0**；1.0 同时接受 `offline` 与 `confirmed_by_reviewer`，因此本构建的产物能被本构建完整复检（导出即 `revalidate` 通过）。
- **Manifest 1.1 尚不接受 `offline`**：1.1 的 `model_provider` 枚举仍为 `openai / anthropic / local / none`。这是独立记录的兼容性缺口，只在"启用 eligibility 过滤（1.1）+ 离线映射"这一组合下暴露；默认过滤 `OFF` 使该组合在当前 Alpha 不可达，**不阻断当前 Alpha**。在启用该组合之前必须补齐 1.1 的 `offline` 取值。

### 合同差异

1.0 schema 文件被就地扩展（文件版本号未变，接受取值变多），范围限定 Internal Alpha。正式发行前重估 Schema 版本策略，**不宣称双向兼容**。`docs/SPEC.md` 与 `docs/PLAN.md` 未被修改。
