# M05 — 写入中故障恢复 Preflight（未授权）

状态：**Preflight / dry-run only。真实写入与真实崩溃注入均未执行、未获授权。**

本文件是 M05 的执行方案与预检证据清单；真正的授权申请见 `docs/M05-AUTHORIZATION-PROPOSAL.md`。两者都不改变现有授权边界：当前仍**禁止**任何真实 DEVONthink 写调用。

## 1. 目标

在**可丢弃的隔离目标**上，验证"写入结果未知 → `VERIFY_REQUIRED` → 只读回查 → 重启后无重复"这条链路在真实 MCP 下的行为，覆盖三种触发点：

| 探针 | 触发方式 | 期望的副作用状态 |
| --- | --- | --- |
| T 超时 | 对**本次自己启动的** MCP 子进程 `SIGSTOP`，使请求超过客户端预算 | 请求已发出，可能已落库 |
| D 发送后断连 | 对本次 MCP 子进程 `SIGKILL`，在 create 发出后、响应前 | 请求已发出，结果未知 |
| C 崩溃 | 在 create 在途时终止 **Forma 进程**（不是 DEVONthink） | 进程死亡，Intent 已落库 |

`C` 是本轮**明确禁止**执行的项目；方案中保留，待授权。

## 2. 非目标

- 不测试生产库、不迁移数据、不做 Replicant/移动/删除。
- 不测试 `dropped_fields` 之外的未知服务端行为；不追求 exactly-once。
- 不修改 DEVONthink 主程序、不终止他人会话的 MCP 子进程。
- 不新增后台 Worker、定时任务或自动重试。

## 3. 目标身份校验（写入前，只读）

任何写入 scope 构造之前，必须逐项通过：

| 检查 | 方式 |
| --- | --- |
| 目标数据库精确绑定 | `get_databases{uuid}` 返回恰好 1 条；`uuid` 与授权值逐字相等 |
| 名称与角色 | 名称精确等于授权值；`is_inbox == false` |
| 与生产库不同 | UUID 与 `Project_Archive`、全局 `Inbox` 均不相等 |
| root Group | `rootUUID == database.uuid` |
| 组路径可达 | 从 root 逐级 `get_record_children` 命中授权前缀；不得用共享前缀（如 `X/` 与 `XY/`） |
| 初始计数 | root 子项与目标前缀子项计数记录在案，作为事后对账基线 |
| 工具契约 | 3 个写工具的 `inputSchema` SHA-256 与 B1/B2 基线一致；漂移即中止 |

生产库**不做**记录级查询；隔离仅靠上述白名单 + 工具审计证明。

## 4. 预算（提案值，需 Owner 批准）

| 维度 | 上限 |
| --- | --- |
| 目标数据库 | 1（可丢弃；优先新建 `Forma_M05_Sandbox`，不复用 I1-B2 沙盒） |
| Group | 2（`Forma_M05`、`<run-id>`） |
| 记录 | 3（对应 T/D/C 三个探针，各 1 条） |
| `import_file` 调用 | 3（`mode=import`，仅 3 个合成文件） |
| `set_record_custom_metadata` 调用 | ≤ 6 总数，且**每条记录 ≤ 1 次** |
| 合成源文件 | 3（字节固定，SHA-256 见 §12.1） |
| 删除 / 移动 / trash / Replicant | 0 |
| 字段定义变更 | 0 |

三类预算（imports / groups / metadata）都在 `ImportWriteScope` 中，并由
`ImportWriteAuthorization.permit` 在调用传输层之前检查：

- 被拒绝的请求不消耗预算，也到不了 transport；
- 预算在**授予**时消费，超时、断连、取消都不退还（防止崩溃循环超支）；
- metadata 除总数外还有逐记录上限，六个调用不能集中在一条记录上。

### 4.1 预算日志（跨实例）

已花费计数以**运行时授权 digest** 为 key，持久化在 Ledger v3 的
`import_write_budgets` 表。启动新进程、构造新 `ImportRuntime` 或新的
`ImportWriteAuthorization`，只要 identity 相同，就从已花费值继续。

- journal 读失败 → `budgetUnavailable`，拒绝授予；
- journal 写失败 → 回滚本次增量，`budgetUnavailable`，grant 不返回；
- 损坏的逐记录 JSON 视为 storage 错误，**不降级为零预算**。

## 5. 身份键与 Intent 持久化

- 幂等键：`(source_id, snapshot_fingerprint, manifest_revision, target_association_id, operation_kind)`，其 SHA-256 为 Ledger 的 `key_digest` 唯一索引。
- 每次操作先 `recordIntent`（`planned → preflighted → intent_persisted`）再发请求；Intent 与外部副作用之间没有事务，因此**不声明 exactly-once**。
- 恢复只读：`ImportRecoveryCoordinator`（只持有 `ImportReadTransport`）→ `ImportRecoveryReviewer`；越界条目零读取。
- 重新写入需要**新的执行决定**；同一 `key_digest` 永远不能二次执行（`recordIntent` 唯一约束），更换 operation id 不能绕过。

## 6. 未知结果的规则

| 观察 | 结论 |
| --- | --- |
| 请求返回且载荷唯一 | 按事实推进，仍以独立回读为准 |
| 超时 / 断连 / 进程死亡 | `VERIFY_REQUIRED`；**不重试** |
| 回查结论性证明不存在 | `failed(absent_after_unknown)`；**不重写** |
| 回查发现唯一候选且身份+字节确认 | 采用该 UUID，继续缺失步骤 |
| 回查发现多条候选 / 身份不足 / 字节不可证 | 保持 `VERIFY_REQUIRED` |
| 回读与意图不一致 | `CONFLICT_HOLD`，不覆盖 |

## 7. 重启后的独立只读回查

1. 启动清扫：`ImportRecovery.open` 把在途相位扫成 `verify_required`（保留 `lastKnownPhase`）。
2. 人工确认读范围（隔离库 UUID + 组路径）→ `Read Scope…` → `Recheck read-only`。
3. 逐条读取：库、父组、标准 SHA-256、元数据；结论只更新界面，**不写 Ledger**。
4. 判定后仍由人决定下一步；恢复流程不得调用 `create` 或 `writeMetadata`。

## 8. 触发点与操作序列（执行时）

前置：新 workspace、无其他 Forma 实例、隔离库已绑定、边界 scope 已构造、`plan` 输出核对通过。

| 步 | 操作 | 断言 |
| --- | --- | --- |
| 1 | 建组 `Forma_M05/<run-id>` | 回读 children 证明库与父组；返回载荷无 UUID 也可接受 |
| 2 | 记录 T：create 发出前 `SIGSTOP` 子进程，等待超时，恢复进程 | `FormaError.timeout`；Ledger `verify_required`；attempts=1 |
| 3 | 回查 T | 若记录存在且身份+字节确认 → `readback_verified`；否则保持 `verify_required` |
| 4 | 记录 D：create 发出后 `SIGKILL` 子进程 | `disconnected`；Ledger `verify_required`；**不重发** |
| 5 | 回查 D | 同上 |
| 6 | 记录 C（**未授权，暂不执行**）：create 在途终止 Forma 进程 | 重启后 `verify_required` + 只读结论 |

每步同时记录：guard 的 `log`（授权次数）、`refusalCounts`（必须为空）、`provenRecordIDs`、真实写调用计数。

## 9. 禁止自动重试与重复导入

- `ImportExecutor` 在未知结果后只做只读 lookup/adopt；不调用第二次 `create`。
- 同一 `key_digest` 的第二次执行返回已记录状态（`ImportExecutorTests`「a second execution of the same key does not create a second record」）。
- 恢复路径不得产生新 intent；`resume` 只允许只读结论（`ImportExecutorTests`「a lookup timeout writes nothing」「an inconclusive lookup does not import」）。

## 10. 真实写调用统计与清理边界

| 项 | 记录方式 |
| --- | --- |
| 授权写调用 | `GuardedImportWriteTransport` 的 grant 计数，逐工具 |
| 被拒调用 | `ImportWriteAuthorization.refusalCounts`，必须为空 |
| 记录/组实际数量 | 事后 children 回读，与预算对账 |
| 清理 | **无删除授权**：记录与组保留；不移动、不进回收站 |
| 回滚限制 | MCP 无事务、无删除授权 → 无法回滚，只能停止并记录；清理需 Owner 单独授权 |

## 11. 中止条件

任一命中即停，不继续后续探针：

1. 目标库校验任一失败（UUID/名称/inbox/生产库差异/root）；
2. 3 个写工具 schema digest 与基线不一致；
3. guard 报出任何拒绝；
4. 出现预期之外的记录、组或库；
5. 一个操作键产生第二条记录；
6. 回查无法解释（身份不足且字节不可证）且尚无人工结论；
7. 任何指向生产库的观测；
8. MCP 版本/协议与基线不一致。

中止后保持现状、导出 Ledger 与审计、记录 `BLOCKED`，不尝试"修好再跑"。

## 12. Fake Transport 预检证据（本轮已具备）

| 性质 | 测试 |
| --- | --- |
| 创建后断连 → 只读找回，不二次创建 | `ImportExecutorTests`「created then disconnected: recovered by lookup, not by a second create」 |
| 崩溃后 resume 不重建 | `ImportFaultMatrixTests`「a crash after create is resolved by resume without a second create」 |
| 故障矩阵守恒（无重复、相位合法） | `ImportFaultMatrixTests`「every injected fault ends in a permitted phase and never duplicates a record」 |
| 同键并发最多一条 | `ImportFaultMatrixTests`「two concurrent executions of one key create at most one record」 |
| lookup 超时零写入 / 非结论性不导入 | `ImportExecutorTests`「a lookup timeout writes nothing」「an inconclusive lookup does not import」 |
| 元数据失败保持未知 | `ImportExecutorTests`「a metadata failure leaves the record in place and the operation unknown」 |
| 目标/来源逐项阻断（A1–A7 / B1–B6） | `ImportB0BoundaryTests` |
| 默认拒绝与预算 | `ImportWriteBoundaryTests` |
| 运行入口授权（生产库/预算/一次性授权） | `ImportRuntimeTests` |
| 预算 journal 跨实例恢复 / 读写失败 fail-closed | `ImportWriteBoundaryTests`（SQLite journal、`budgetUnavailable`） |
| 拒绝不触达 transport、超时/断连/取消不退款 | `ImportWriteBoundaryTests` |
| scope 与计划一致（预算/字段表） | `ImportRuntimeTests`（`plan_exceeds_budget`、`plan_outside_scope`） |

### 12.1 离线 QA 执行编排（`M05QA`，仅测试目标）

`Tests/FormaCoreTests/M05QATestSupport.swift` + `M05QAExecutionTests.swift` 是
可复现的 M05 预演，不进入应用或 CLI，不新增后台任务：

- 默认 plan-only；没有显式 `Approval` 直接拒绝；
- 三份字节字面量合成文件，SHA-256 由内容重算：

| 文件 | 字节 | SHA-256 |
| --- | --- | --- |
| `synthetic/m05-t1.md` | 64 | `5d15b3be667c4a31bc62d80bd7f71ebf677be51288f19e5e851cbc6353ce863f` |
| `synthetic/m05-d2.md` | 68 | `310042446ae4086bc1a82cb9994661d444a0dd0920d0850af192308cd8a224ff` |
| `synthetic/m05-m3.md` | 61 | `5d8285744b36803e8ccf10d95a9df1ee3d028a0605b2698acf290a6c85d4de4f` |

- 三条独立 operation key；一次运行三个探针（已落库但响应丢失 / 已发送未落库 /
  metadata 失败），按 sourceID 注入故障，不依赖调用顺序；
- 断言每键恰好一次 create、无重复记录、未知结果保留为 `verify_required`；
- 重启用同一 SQLite 的新 handle + `ImportRecovery.open` + 只读 reviewer，
  断言写调用不增加；
- 崩溃残留用显式 `record_observed` 持久化状态模拟，清扫 `interrupted=1`；
- 报告含授权 digest、预算上限/已花费、三类调用计数、拒绝原因，JSON 稳定。

运行：macOS CI 的 `FormaCore tests` 全量执行（`swift test --filter "M05 QA execution"`）。
它证明状态机、预算与守卫；**不证明**真实 MCP、真实进程崩溃或 OS 级调度。

这些是**合成**证据：它们证明状态机与守卫，不证明真实 MCP 行为。

## 13. 执行清单（授权后）

1. Owner 批准 `docs/M05-AUTHORIZATION-PROPOSAL.md`（含预算与目标库）。
2. 只读绑定目标库，记录基线计数与 3 个工具 digest。
3. 生成 3 个合成文件并记录 SHA-256。
4. 先跑离线 QA 编排（§12.1），确认预算、计划、故障矩阵与报告格式；失败则停止。
5. 构造 scope；`plan` 必须输出 3 条 `would_execute`、`limits` 与
   `authorizationDigest`，且 `refusals` 为空。
6. 按 §8 执行 T、D；C 仅在 Owner 对崩溃注入单独批准后执行。
7. 每次触发后按 §6 判定，再按 §7 做重启回查。
8. 导出 Ledger、审计、预算 journal 行与 QA report JSON；按 §10 对账。
9. 记录 PASS/FAIL/BLOCKED；未获授权不清理。
