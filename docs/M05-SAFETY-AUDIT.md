# M05 真实写入前安全审计（DevBox，只读 + 合成测试）

基线：`dev` @ `6092d26` · 审计日期：2026-11-15

结论：

| 项 | 结论 |
| --- | --- |
| Budget journal 并发一致性 | **FAIL（审计时）→ 修复后 PASS** |
| 真实 M05 执行路径一致性 | **READY**（结构同一；T/D 触发可观测性 NOT_VERIFIED） |
| 剩余授权绕过路径 | **未发现运行时路径**（残余为“直接实例化公开类型”的开发面，见 §3） |
| 真实写工具调用 | **0** |
| M05-T02/T03 独立授权申请 | **可提交**，但需附带“发送后故障触发点”的可观测方案 |

## 1. Budget Journal 并发一致性

### 1.1 审计时的实现与缺陷

- `ImportWriteAuthorization.ensureLoaded` 读一次 `budgetUsage`，`permit` 在 actor 内
  比较本地 `usage`，`spend` 再把整个 `ImportWriteBudgetUsage` 覆盖写回
  （`budgetUsage` → 判定 → `save`）。
- 同一 `identity` 的两个 authorization actor 各自加载、各自判定、各自写回
  `old+1`，后写者覆盖先写者 → **丢更新**；实际授予数可超过 `recordLimit` /
  `metadataCallLimit` / `groupLimit`。
- `ImportSingleWriter` 的租约不足以排除该路径：
  - 租约覆盖 `ImportExecutor` 的 create；组创建不经过 executor；
  - 同一 writer actor 的 `acquire` 在已持有租约时直接返回 true，两个共享
    writer 的 runtime 实例可并发；
  - 不同 writer owner 的第二个实例会在 `acquire` 失败，但预算在更内层，
    不能作为预算互斥的证明。

### 1.2 修复（PR #112）

- `ImportWriteBudgetJournal.spend(_:limits:identity:at:)` 成为唯一变更入口：
  - `ImportLedger` 在单个 `database.write` 事务内完成 读取 → 校验 → 递增 → UPSERT；
  - 命中上限时抛 `ImportWriteBudgetRejection(reason, usage)`，携带权威快照；
  - 读损坏/写失败仍抛 storage 错误，授权层映射为 `budgetUnavailable`（fail-closed）。
- `ImportWriteAuthorization` 删除 `ensureLoaded` 与全量 `save`；有 journal 时只
  采用事务返回值（拒绝时也更新本地审计快照），无 journal 时保持 actor 内计数。
- 授权语义、denial code、预算数字未改变。

### 1.3 确定性证据

`Tests/FormaCoreTests/ImportBudgetConcurrencyTests.swift`：

| 测试 | 断言 |
| --- | --- |
| 8 路并发 `ledger.spend(.importRecord)`，limit=1 | 恰好 1 次成功；存储 usage=1 |
| 8 个独立 `ImportWriteAuthorization` 共享同一 ledger/identity，limit=1 | 恰好 1 次 `permit` 成功；usage=1 |
| 8 路并发 metadata，total=2、perRecord=1、两个记录 | 恰好 2 次成功；每记录各 1 次 |

并发由 `withThrowingTaskGroup` 发起；SQLite 单写事务串行化，测试不依赖时序窗口。

### 1.4 适用范围与剩余风险

- 原子性属于 **journal 实现契约**：自定义 `ImportWriteBudgetJournal` 必须把
  `spend` 实现为原子操作；测试用 `MemoryBudgetJournal` 用同一把锁满足该契约。
- 两个进程使用**不同**数据库文件 → 是两个独立预算，这是 scope/identity 设计
  的一部分，不是丢更新。
- 未覆盖：真实 SQLite 多进程争用（`DatabaseQueue` 单进程内串行）；本项属于
  真实 M05 运行观察项。

**状态：PASS（修复后）**。

## 2. 真实 M05 执行路径一致性

`ImportWriteSessionFactory`（`Sources/FormaCore/Import/ImportRuntime.swift`）是
唯一构造写入 session 的地方：

| 组成 | 生产 `ImportRuntime` | 离线 `M05QA` harness |
| --- | --- | --- |
| Runtime | `ImportRuntime` actor | 同类型 |
| Session 构造 | `ImportWriteSessionFactory.make` | 同工厂 |
| Guard | `GuardedImportWriteTransport` | 同类型、同工厂 |
| 预算 Journal | `ImportLedger`（v3 `import_write_budgets`） | 同类型 SQLite ledger |
| Identity | 运行时授权 digest | 同 digest 规则 |
| Intent/Ledger | `ImportExecutor` + `ImportLedger` | 同执行器与表 |
| 独立只读 Recovery | `ImportRecoveryCoordinator(read:)` | 同类型（fake read） |
| Transport | `DEVONthinkMCPWriteTransport` | `FakeImportTransport` |

差异只有 transport 与来源：这是离线 QA 能提供同等状态机证据、又不触碰真实
DEVONthink 的原因。

### 2.1 绕过路径审计

- `DEVONthinkMCPWriteTransport(` 在 `Sources/` 仅出现于 `ImportRuntime` 的公开
  初始化器；其余出现在测试。
- `GuardedImportWriteTransport(` 在 `Sources/` 仅出现于共享工厂。
- `ImportExecutor(` 在 `Sources/` 仅出现于 `ImportRuntime.execute`。
- 写协议方法只由 `ImportExecutor` 调用；执行器持有 `ImportWriteSurface`，运行时
  传入的正是 guard。
- `ImportRecoveryCoordinator` 只接受 `ImportReadTransport`，没有写方法。
- 残余：`DEVONthinkMCPWriteTransport` 是 public 类型，库的其他调用方可以自行
  实例化并绕过 guard。这不是 Forma 运行时路径，但无法由类型系统阻止；真实
  M05 运行只允许 `ImportRuntime` 公开初始化器。

**运行时路径：未发现绕过**。

### 2.2 prepared / sent / may-have-executed / received

| 阶段 | 含义 | 离线可确定性构造 | 真实 MCP 可观测性 |
| --- | --- | --- | --- |
| prepared | 请求已构造、guard 已授予，尚未进入 transport | 是（guard 前置拒绝/预算拒绝） | 客户端可观测 |
| sent | transport 方法已被调用，字节可能已写出 | 是（fake 事件日志在 apply 前） | **无法仅凭客户端确认** |
| server may have executed | 服务端可能已执行，响应未收到 | 是（`createAfterApply`） | 只能由事后只读回查推断 |
| response received | 收到完整响应 | 是（正常返回） | 客户端可观测 |

- `SIGSTOP` 发生在 create 调用之前时**不等价于**“服务端已收到写请求”；本轮不把
  该探针标为已具备现场验证能力。
- M05-T02/T03 的真实触发点需要可观测方案（例如受控的本地 MCP 代理记录请求边界，
  或服务端审计日志），否则只能标记为 NOT_VERIFIED。

**真实 M05 执行路径：READY；发送后故障触发能力：NOT_VERIFIED。**

## 3. M05-T02/T03 授权申请

可以提交独立申请，前提是申请中明确：

1. T02/T03 的触发方式与其**可观测性证据**（不仅是客户端超时/断连）；
2. 未知结果只做只读回查，不重发 create；
3. 预算由事务化 journal 强制，拒绝不触达 transport；
4. 真实崩溃注入仍单列批准；
5. 真实写调用计数与 journal 行作为对账证据。

## 4. 证据与边界

- 真实 DEVONthink 写调用：**0**；无 MCP 连接、无 `kill -9`、无真实数据库。
- 未修改 `main`、ADS pin、SPEC、CNB。
- 代码改动与回归见 PR #112；exact-SHA CI 见 PR 检查与合并后 `dev` run。
