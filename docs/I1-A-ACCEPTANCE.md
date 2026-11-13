# I1-A 离线阶段验收（I1-A-ACCEPTANCE）

> 状态：**Offline Verified**。不是 Import Integration Verified：本轮没有调用任何真实 DEVONthink 写工具、没有创建真实记录、没有访问生产库。I1-B 需 Owner 单独批准。

## 1. 交付范围

| 切片 | 内容 | PR | 合并 SHA |
| --- | --- | --- | --- |
| A1 | 契约 ADR、`ImportOperationKey`、源字节/业务记录身份分离、`ImportPreflight` 20 码 | #62 | `f00002a` |
| A2 | `ImportLedger` + `import-ledger-v1` + `ImportSingleWriter` 租约 + 重启清扫 | #63 | `0906345` |
| A3 | `ImportArbitration` 四态、写读分离传输契约、`ImportExecutor`、Fake Transport | #64 | `953cd70` |
| A4 | 故障矩阵、恢复回归、本报告 | #65 | 本 PR |

## 2. 状态迁移表

（引自 `docs/ADR-I1-A-IMPORT-CONTRACT.md` §4.2，测试 `transitionShape` 钉住形状）

| 从 | 到 | 守卫 |
| --- | --- | --- |
| planned | preflighted | Preflight pass |
| planned | deferred | 仅瞬时失败 |
| preflighted | intent_persisted | 意图已提交 |
| intent_persisted | skipped_verified | 只读查询证明已存在且一致 |
| intent_persisted | record_observed | 创建返回 UUID 或只读唯一命中 |
| intent_persisted / record_observed / metadata_observed | conflict_hold | 确认是同一条业务记录但位置/字段/内容不一致 |
| record_observed | metadata_observed | Metadata 写入被应答 |
| metadata_observed | readback_verified | 独立回读一致 |
| in-flight | verify_required | 超时/断连/进程终止/候选不唯一 |
| verify_required | record_observed / metadata_observed / readback_verified / skipped_verified / conflict_hold | 先只读核查 |
| 任意未终结 | failed / cancelled | 明确失败或取消 |

不存在的迁移：`verify_required → import`、`conflict_hold → 覆盖`、任何删除。

## 3. 故障矩阵

| 故障 | 注入点 | 期望 | 证据 |
| --- | --- | --- | --- |
| 创建前拒绝 | `create` 抛错且无记录 | VERIFY_REQUIRED，0 记录 | `createRefusedBeforeApply` |
| 创建后断连 | `create` 写入后抛错 | 只读找回，1 记录，READBACK_VERIFIED | `createUnknownOutcome` |
| lookup 超时 | `lookup` 抛错 | VERIFY_REQUIRED，0 写入 | `lookupTimeout` |
| lookup 结论性不足 | `conclusive=false` | VERIFY_REQUIRED，0 写入 | `inconclusiveLookup` |
| Metadata 写失败 | `writeMetadata` 抛错 | VERIFY_REQUIRED，1 记录 | `metadataFailure` |
| 回读失败 | `read` 抛错 | VERIFY_REQUIRED | `readbackFailure` |
| 回读不一致 | 回读篡改 | CONFLICT_HOLD | `readbackMismatch` |
| 已存在且一致 | 预置记录 | SKIP_VERIFIED，0 写入 | `existingMatch` |
| 已存在、仅锚点匹配但字段不同 | 预置差异记录 | VERIFY_REQUIRED（锚点 + 字段不足以确认） | `existingDifference` |
| 已确认（锚点 + 字段）但字节不同 | 预置同元数据异哈希记录 | CONFLICT_HOLD，0 写入 | `confirmedButBytesDiffer` |
| 同 SHA 无锚点 | 预置他项目记录 | VERIFY_REQUIRED，0 写入 | `sameBytesNoAnchor` |
| 重复执行 | 同 key 第二次 | 不再次创建 | `idempotentReexecution` |
| 重启后在途 | 进程中断 | 先标 verify_required，再只读解析 | `resumeAfterRestart` |
| 已知 UUID 续写 | 记录已建、Metadata 未写完 | 只补缺失步骤，不重建 | `resumeFinishesKnownRecord` |
| 重启后证明不存在 | 结论性空搜索 | failed(`absent_after_unknown`)，不写 | `resumeDoesNotImport` |
| Preflight 阻断 | 失败码 | 不落意图、不写 | `blockedPreflight` |

## 3.1 测试清单

| 套件 | 用例数 | 覆盖 |
| --- | --- | --- |
| `ImportIdentityTests` | 9 | 操作键稳定性/逐分量区分/规范化无歧义/解码校验；哈希不确认业务身份 |
| `ImportPreflightTests` | 19 | 20 个失败码、瞬时 vs 阻断、授权独立、Profile/Schema、SHA 不一致 |
| `ImportLedgerTests` | 15 | 唯一意图、迁移守卫、终态不可变、UUID 单写、追加式审计、重启清扫、租约 |
| `ImportSingleWriterTests` | 5 | 排他、预留、成功/抛错释放、第二个 writer 被拒 |
| `ImportArbitrationTests` | 9 | 四态判定顺序与未知优先 |
| `ImportExecutorTests` | 17 | 正常、幂等、创建后断连恢复、创建前拒绝、metadata/回读失败、取消、resume 三条路径、确认但字节不同 |
| `ImportFaultMatrixTests` | 4 | 故障矩阵扫描、崩溃后恢复、并同键、写前取消 |
| **合计** | **78** | 全部为合成来源 + 临时 SQLite + Fake Transport |

## 4. 未验证接口清单（I1-B 必须现场确认）

1. 真实 MCP 写工具名称、参数与错误码；写工具白名单。
2. 真实创建返回的 UUID 语义（是否持久、是否跨库唯一）。
3. 目标标准 SHA-256 的可得性与等价性；不可得时的 `hash_unverified` 路径。
4. Group 查询/分页语义：能否证明"不存在"，以及范围参数。
5. Metadata 写入的原子性与部分成功语义。
6. 断连/超时后的真实可观测状态。
7. DEVONthink 版本、隔离库 UUID 与可丢弃记录授权。
8. `SF_DATALESS` 与 OneDrive hydration 对读取的影响（M4/M9）。

## 5. macOS 现场验证步骤（I1-B 草案）

1. 指定隔离数据库与可丢弃 Group；确认写工具白名单。
2. 用 1 个合成文件执行 IMPORT：创建 → 回读 UUID/父组/字段/标准 SHA。
3. 注入断连（kill 进程）后重启，运行 `ImportRecovery.open` + `resume`，确认不产生第二份记录。
4. 重复执行同一操作键，确认 SKIP_VERIFIED 且无第二份记录。
5. 制造字段冲突，确认 CONFLICT_HOLD 且原记录未被覆盖。
6. 记录每步的 MCP 请求/响应摘要与回读证据；不合格项按 PASS/FAIL/BLOCKED/NOT_VERIFIED 报告。

## 6. 结论

- 离线可验证的部分全部通过合成夹具与 Fake Transport 验证；报告只覆盖 **Offline Verified**。
- 没有真实写入、没有真实记录、没有生产库访问、没有真实 Provider 请求。
- 未验证项与现场步骤见 §4/§5；在 I1-B 批准前不得宣称 Import Integration Verified。

## 7. 硬化复审（2026-11-13，Owner 授权 I1-A Hardening）

### 7.1 Confirmed / Rejected Defect Matrix

| # | 缺陷 | 结论 | 证据 |
| --- | --- | --- | --- |
| 1 | `resume()` 找不到 Ledger 操作时启动一次新 Import | **Confirmed** | 红灯 `resume without a ledger row writes nothing`：旧实现 `attempts = 2`、`createCalls > 0`，并落了一条 intent 行 |
| 2 | 已知 UUID 的恢复路径在补写前不读目标 | **Confirmed** | 红灯 `a record somebody else changed is not overwritten`：旧实现把外部写入的 `2019` 覆盖成 `2026`，`metadataCalls > 0` |
| 3 | `create()` 结果未知后的候选恢复取 `records.first` | **Confirmed** | 红灯 `two candidates after an unknown create: neither is chosen`：旧实现认领了 `uuid-a` |
| 4 | Preflight 结论可任意构造，未绑定事实 | **Confirmed** | 红灯 `a preflight pass that is not bound to this intent writes nothing`：旧实现照常导入并落 intent |
| 5 | `ImportCreateRequest` 缺真实文件导入的输入契约 | **Confirmed** | 类型层：请求只带 `sourceSHA256`，没有获授权的源文件、快照与读取会话 |
| 6 | 目标 SHA 不可验证时仍给出终态结论 | **Confirmed** | 红灯 `a target that cannot prove its bytes is not readback verified`：旧实现给 `conflict_hold`，把"无法证明"当成"不一致" |
| 7 | 恢复期间来源已变仍会继续 | **Confirmed** | 红灯 `resume with a snapshot that no longer matches writes nothing`：旧实现直接导入 |
| 8 | 候选身份未确认仍会被认领 | **Rejected（行为未触发，但无保证）** | 该用例在旧实现下通过：当时恢复查询没有给出可认领的候选；代码路径本身没有身份校验，因此仍按缺陷修复并由用例锁定 |

### 7.2 修复前失败测试

红灯证据：[CI 43445939480](https://github.com/Skyline-Gazer/Forma/actions/runs/43445939480) —— 7 个反例以行为断言失败（不是编译失败）。失败项：

| 反例 | 旧实现的实际结果 |
| --- | --- |
| resume without a ledger row writes nothing | `outcome = importRecord`、`attempts = 2`、`createCalls > 0`、intent 行已落 |
| resume with a snapshot that no longer matches writes nothing | `outcome = importRecord`、`createCalls > 0` |
| a record somebody else changed is not overwritten | `outcome = importRecord`、`metadataCalls > 0`、记录被改成 `2026` |
| two candidates after an unknown create: neither is chosen | `actualUUID = uuid-a` |
| a preflight pass that is not bound to this intent writes nothing | `outcome = importRecord`、`attempts = 2` |
| a target that cannot prove its bytes is not readback verified | `outcome = conflictHold`（应为 `verifyRequired`） |

### 7.3 修复后测试

绿灯证据：[CI 43453832289](https://github.com/Skyline-Gazer/Forma/actions/runs/43453832289)（FormaCore tests + macOS app build 全绿）。修复后新增/改写的用例：`ImportHardeningTests`（10）、`ImportExecutorTests`（13）、`ImportFaultMatrixTests`（4）、`ImportArbitrationTests`（10，新增"字节无法证明则不验证"）、`ImportPreflightTests`（19，改为断言绑定许可）。

### 7.4 Import 前置授权不变量

一次外部写入只有在下列全部成立时才可能发生（ADR §6.2）：

1. 存在与本次 Intent 事实绑定的 `ImportPreflightClearance`，且结论为 `pass`；许可的构造器是 **file-scoped**，只有 `ImportPreflight.evaluate` 能产出，测试与其他模块都无法手写一份许可。
2. 许可绑定的来源、快照、Manifest revision、目标与授权摘要，与本次 Intent 逐项一致（否则 `clearance_mismatch`，零写入）。
3. 执行器持有单写者租约，并对该来源与目标做了互斥预留。
4. Intent 行已持久化（`intent_persisted`），且本次操作键此前不存在。
5. 目标身份、字段与内容状态经**独立只读客户端**核对过，冲突项为零。
6. 目标能给出可验证的内容摘要；否则停在 `VERIFY_REQUIRED(hash_unverified)`。

### 7.5 恢复路径的 read-before-write 证据

| 场景 | 旧行为 | 现在 |
| --- | --- | --- |
| 已知 UUID，字段被外部改过 | 直接补写，覆盖外部值 | 先读 → `CONFLICT_HOLD(external_modification)`，只写仍缺失的槽位，外部值保留 |
| 已知 UUID，字段仍为空 | 全量补写 | 只写缺失的槽位 |
| 恢复时来源快照或字节已变 | 继续导入 | `source_changed`，零写入 |
| Ledger 中没有该操作 | 启动一次新导入 | `intent_missing`，零写入 |
| Create 结果未知、两个候选 | 认领第一条 | `VERIFY_REQUIRED`，未认领任何 UUID |
| Create 结果未知、候选身份未确认 | 认领并补写 | `VERIFY_REQUIRED`，零补写 |
| Create 结果未知、唯一且身份确认 | —— | 认领该 UUID 并继续到独立回读 |

### 7.6 ImportCreateRequest 真实输入契约

`ImportSourceBinding` 随创建请求传递：获授权的 `sourceID`、作用域、相对路径、快照指纹、**字节 SHA-256**、字节数与**读取会话**。

它刻意**不**携带可直接发送的工具参数：DEVONthink 文件导入工具的参数形状（路径、文件引用还是上传）尚未核实，猜一个会让适配器"看起来完成但不能工作"。映射留在 I1-B。

### 7.7 与 I1-B 真实 MCP 能力的未决对应关系

| 未决项 | 现状 |
| --- | --- |
| 写工具名称与参数 | 未核实；`ImportSourceBinding` 不假定形状 |
| 创建返回的 UUID 语义 | 未核实；离线用合成 UUID |
| 目标标准 SHA-256 可得性 | 未核实；不可得时走 `hash_unverified` |
| Group 查询能否证明"不存在" | 未核实；离线用 `conclusive` 开关模拟 |
| Metadata 写入的部分成功语义 | 未核实；离线用"创建为空记录"模拟 |
| 断连后的真实可观测状态 | 未核实；离线用异常注入模拟 |
| 写工具是否接受来源标记 | 未核实；ADR 明确不预设官方支持自定义属性 |

### 7.8 ADS / CNB 评审状态

按 ADS `deliver` 纪律执行：先复现缺陷（红灯证据）、修复、绿灯回归、按当前 head 复核再合并。CNB AI Code Review 尝试绑定本次 GitHub PR 的精确 head/base（CNB PR [#17](https://cnb.cool/KoolingMachine/Forma/-/pulls/17)，head `b7a62a3`、base `e340617`，日志确认 `PR 评审: b7a62a3b -> e3406171`），但流水线 `ai-code-review` 因平台额度用尽返回 `402 EXCEEDING_LIMIT`，**没有产生评审结论**。该结果按 `NOT_VERIFIED` 报告，不冒充通过的评审；CNB 评审不是本仓库配置的必需合并门禁（AGENTS.md：评审发现是反馈，不是自动合并授权）。本轮合并依据是 GitHub macOS CI 绿灯与 ADS 默认 development-first 流程。

### 7.9 I1-B Readiness Decision

**结论：Integration Boundary Ready，但仍未取得 Import Integration Verified。**

理由：五类执行边界缺陷已复现、修复并由红灯→绿灯的用例锁定；写入前置授权、读回证据与恢复语义现在都有可执行的契约与反例。缺口全部是**接口能力**而不是内部逻辑：I1-B 必须在真实隔离库上确认写工具、UUID、字段、Group 与标准 SHA 的真实行为，并验证断连、重复运行与崩溃恢复。

因此 I1-A 的状态仍写作 **Offline Verified**；只有 I1-B 在真实接口上跑完 §7.7 的每一行，才允许改写为 Import Integration Verified。
