# R1 Batch 2B Engineering Hardening — 报告

日期：2026-11-15 · 仓库：`Skyline-Gazer/Forma`

结论先行：**预算硬化与离线 M05 QA 已工程完成并通过 macOS CI；真实 DEVONthink 写调用 0 次；M05 真实运行仍不具备执行授权。** 本报告区分 GitHub 已核实、合成测试证据与 NOT_VERIFIED。

## 1. 基线、PR 与 CI

| 项 | 值 |
| --- | --- |
| 起始 HEAD | `dev` @ `28cf70f`（PR #106），CI `43691447945` success |
| 最终代码 HEAD | `dev` @ `43432f6`（#109 合并）；#111 只追加本报告、交接与 Roadmap 文档 |
| #107 | 预算硬化 → merge `312d06a`；head CI `43696577386` success |
| #110 | 离线 QA 编排 → merge `a2b2dc4`；head CI `43700795504` success（替代自动关闭的 #108） |
| #109 | M05 文档更新 → merge `43432f6`；head CI `43696709367` success |
| #111 | 本报告与 Roadmap 收敛 → 合并后仅文档变化 |
| 最终 CI | `43701712553` success（`43432f6`） |
| `main` / ADS pin / SPEC | 未修改 |

各 PR 的 head CI 与合并后 `dev` CI 均以 GitHub 实际 run 为准；本报告只记录已完成的结论。

## 2. 预算强制约束证据

| 要求 | 实现 | 确定性测试 |
| --- | --- | --- |
| metadata 总次数在传输层前强制 | `ImportWriteScope.metadataCallLimit` + `permit` 前置检查 | `metadataTotalBudgetStopsTheNextCallBeforeTheTransport` |
| 单记录 metadata 限制 | `metadataCallsPerRecordLimit` + 逐 UUID 计数 | `metadataPerRecordBudgetStopsTheSecondCallForOneRecord` |
| 三类预算分别对账 | `ImportWriteBudgetUsage`（imports/groups/metadata） | `reportIsCompleteAndStable`、`theLedgerJournalCarriesSpendAcrossAuthorizationInstances` |
| 拒绝不触达 transport | guard 仍先 `permit` 后调用 | 各预算测试断言 `base.*Calls == 0/…` |
| 超时/断连/取消不退款 | 授予时消费，永不退还 | `timeoutDoesNotRefund…`、`disconnectDoesNotRefund…`、`cancellationDoesNotRefund…` |
| 新实例不能刷新预算 | `ImportWriteBudgetJournal` + Ledger v3 `import_write_budgets` | `aSecondAuthorizationUnderTheSameJournal…`（imports/metadata）、`newRuntimeDoesNotRefreshBudget` |
| scope 与计划一致 | plan/execute 前置 `plan_exceeds_budget` / `plan_outside_scope`，plan 输出 `limits` 与 `authorizationDigest` | `planRefusesOversizedRun`、`planRefusesMetadataOutsideScope` |
| journal 故障 fail-closed | 读失败拒绝；写失败回滚增量 | `anUnreadableJournalRefusesInsteadOfGranting`、`anUnwritableJournalRollsBackTheGrant` |

语义补充：

- metadata 预算默认 `0`：升级不会让旧 scope 获得原本没有的写能力。
- 边界在传输层前拒绝时，执行器返回 `write_refused`（已知无副作用），不再把确定没写当成 `outcome_unknown`，也不会触发 adopt lookup。
- `key_digest` 唯一约束保持：同一操作键不会二次导入。
- 新建记录在 metadata 之前必须先由**独立 read** 证明（`ImportWriteSurface.recordVerified` → guard 复核观测到的数据库与组）。此前 guard 只从 lookup 建立证明，新建记录的 metadata 步骤会被拒绝；该缺口在本轮修复，M05 的 metadata 探针才可执行。

## 3. 合成故障矩阵（离线）

| 探针 | 注入点 | 观察 | 断言 |
| --- | --- | --- | --- |
| T | create 已落库、响应丢失（`createAfterApply`） | adopt 只读找回 | `readback_verified`；`createCalls` 恰 1/键 |
| D | create 已发送、未落库（`createBeforeApply`） | 结论性空回查 | `failed(absent_after_conclusive_lookup)`；不重发 |
| M | 记录已建、metadata 失败 | 结果未知 | `verify_required`；记录保留 |
| R | 重启（同一 SQLite 新 handle） | 清扫 + 只读复核 | 写调用不增加；review 只 read |
| C | 崩溃残留（显式 `record_observed`） | 清扫 `interrupted=1` | 只读复核 `verified`；无写调用 |

矩阵在 `M05QAExecutionTests` 中一次运行三个键，按 sourceID 注入，不依赖调用顺序；报告 JSON 含 digest、预算、计数与拒绝原因。

**真实进程崩溃、真实 MCP 超时/断连仍为 NOT_VERIFIED**：本轮没有连接 DEVONthink，也没有 `kill -9`。`SIGSTOP` 发生在发送前与服务端已收到写请求不是同一件事，预检文档明确区分 prepared/sent/may-have-executed/response。

## 4. 离线 QA 编排

`Tests/FormaCoreTests/M05QATestSupport.swift` + `M05QAExecutionTests.swift`：

- 默认 plan-only；无显式 `Approval` 与畸形 run id 均拒绝；
- 三份字节字面量文件（64/68/61 B），SHA-256 由内容重算；
- 三条独立 operation key；预算 3 imports / 2 groups / 6 metadata / 1 per record；
- 独立 Ledger + 可检查相位；
- 模拟超时、发送后断连、metadata 失败、重启、崩溃残留；
- 不重发未知 create；恢复只读；
- 输出预算、授权 digest、调用计数、拒绝原因，JSON 稳定可反序列化。

它位于测试目标，不进入应用或 CLI，不新增后台 Agent、定时任务或治理框架。

## 5. 剩余不可验证项（NOT_VERIFIED）

1. 真实 MCP 超时、发送后断连、进程崩溃的行为与返回形状；
2. `import_file` 精确返回结构；`dropped_fields` / 部分成功；
3. Keychain 锁定态、外部卷/iCloud、macOS 14.x 运行；
4. 签名、公证、Hardened Runtime 与 MCP 子进程启动；
5. 缺陷 A（表单旧错误）在新产物上的现场复测；
6. 真实 M05 预算对账（journal 行、children 计数、工具 schema digest）。

## 6. M05 真实写入是否具备申请条件

**具备申请条件，但不具备执行条件。**

- 方案、预算、强制约束、QA 编排、停止条件与证据格式已就绪（#109）；
- 仍需 Owner 批准目标库（优先新建 `Forma_M05_Sandbox`）与预算，且崩溃注入需单独批准；
- 批准前不得创建真实数据库/组/记录，也不得运行真实 M05。

## 7. DEVONthink 写调用次数

**0。** 本轮全部外部效果发生在 `FakeImportTransport` 内；没有 MCP 连接、没有真实文件读取、没有真实进程终止。

## 8. Learning Loop 状态

- 自然观察累计 **2 次**（Pilot 目标 3–5）：Observation 1 为夹具超时假 FAIL；Observation 2 为输入法干扰键入。
- 上轮处置评论把 Observation 1 误标为「MCP 工具契约过期」，已追加勘误（Issue #98），未改写原始记录；ROADMAP 同步更正。
- 本轮未制造新观察，不为凑数新增任务。

## 9. 下一阶段

| Task ID | 工作 | 依赖 | 环境 | Owner 授权 |
| --- | --- | --- | --- | --- |
| R1-F01 | 缺陷 A 现场复测 | #103 artifact | Real macOS | 否 |
| M05-T01 | 目标库绑定 + schema digest + plan 核对 | Owner 指定新库 | Real macOS | 部分 |
| M05-T02/03 | 超时 / 发送后断连探针 | M05-T01 | Real macOS | **是** |
| M05-T04 | 崩溃注入 + 重启回查 | 单独批准 | Real macOS | **是** |
| R1-K01/V01 | Keychain 锁定态、外部卷/iCloud、macOS 14.x | 硬件 | Real macOS | 否 |
| R1-R01–R03 | 签名、公证、发行 | 证书决策 | 发行环境 | **是** |

## 10. Owner 决策申请

1. 是否批准 M05 真实写入（`docs/M05-AUTHORIZATION-PROPOSAL.md`），目标库是否采用新建 `Forma_M05_Sandbox`？
2. 崩溃注入是否与本轮 T/D 分开批准？
3. 是否启动 R01–R03？
4. 缺陷 A 现场复测的 artifact 与时间窗口。
