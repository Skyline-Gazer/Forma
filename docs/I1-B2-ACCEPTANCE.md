# I1-B2 — Live Import Acceptance（脱敏报告）

状态：**Import Integration Verified（Limited Scope / 限定范围）**。

测试库 `Forma_I1B2_Sandbox`、测试组 `Forma_I1B2/r1`、4 条合成记录、8 个允许字段。所有写入经 `GuardedImportWriteTransport` → `DEVONthinkMCPWriteTransport`；生产库零写入。

真实库/组/记录 UUID、包内路径、原始响应与运行日志只保存在运行主机（macOS）的 `~/.forma/evidence/i1-b2/`，本文一律用占位符。

## 0. 适用边界与证据复核状态

### 0.1 本报告证明什么、不证明什么

| 范围 | 内容 | 结论 |
| --- | --- | --- |
| 在范围内 | 隔离库 + 本轮创建的 2 个 Group + 4 条合成记录 + 8 个允许字段 + 3 个授权工具 | 已验收（§13） |
| 在范围内 | 源/目标标准 SHA-256 逐字节一致（4/4）、merge 逐字段回读、未写入字段未被改动、重复运行幂等、冲突拒绝覆盖、超时后写后回读、发送前断连无盲重试、进程重启后无重复 | 已验收 |
| 不在范围内 | 真实业务文件、生产库迁移、OneDrive 占位文件、Replicant / 多父组（**属 I2**）、自动删除、字段定义变更 | 未授权 / 未验证 |
| 不在范围内 | `dropped_fields` 部分成功路径、`import_file` 精确返回结构、请求发出后响应前断连 | **NOT_VERIFIED**（§12） |

“Verified” 在本报告中始终指**上述限定范围内的集成行为**，不等于 Import 生产就绪，也不等于 Issue #7（E5 Epic）整体完成。

### 0.2 本轮（2026-11-14 收尾）的证据复核状态

本次收尾在 DevBox（Linux）上执行，**只做只读取证与文档纠错**：

| 复核对象 | 结果 |
| --- | --- |
| 仓库内容、PR 合并 SHA、CI 结论 | 已复核（§1） |
| 4 个合成夹具的字节与 SHA-256 | 已在本机重算，与 §5 逐字一致（`scripts/make_i1_b2_synthetic.py`，可复现） |
| `~/.forma/evidence/i1-b2/`（Ledger dump、审计 JSON、MCP transcript、原始工具响应、超时/断连探针记录） | **NOT_READ**：该目录在运行主机（macOS）上，本次复核主机不存在该目录。因此本文所有现场观察值均为**运行主机记录值**，本轮未独立重读原始文件 |
| 任何新的真实写入 | 未执行；未调用 `import_file`，未新增写预算 |

因此：§3 的返回结构细节、§8 的探针记录、§9 的 Ledger 对账**没有在本轮被重新证明**。它们保持原记录的结论强度，并且未验证项一律保持未验证——不得因本轮文档修订而升级为 PASS。

### 0.3 可复现性

| 项 | 状态 |
| --- | --- |
| 合成夹具 | **可复现**：`scripts/make_i1_b2_synthetic.py`（本机重算与 §5 一致） |
| 边界、Ledger、仲裁、执行器、写适配器 | **已入库**：`Sources/FormaCore/Import/*`、`Sources/FormaCore/DEVONthink/DEVONthinkWriteTransport.swift` |
| 现场运行驱动器 | **未入库**：仓库内 `ImportReadTransport` 只有测试用 `FakeImportTransport`，没有可读写真实隔离库的 `ImportReadTransport` 实现；本轮 4 次真实导入所用的装配代码没有提交 |

因此本轮现场结果**不可从仓库一键复现**：可以用已入库组件重建同样的流程，但重建的是相似流程，不是被验收的那次运行。补齐“可入库的真实驱动器 + 显式 opt-in 的现场运行入口”属于后续工作（见 `docs/R1-READINESS.md` 与 Issue #22），本轮不实现。

## 1. 仓库与 CI

| 项 | 值 |
| --- | --- |
| 执行基线 | `dev` @ `7c9c4f9`（PR #74：真实写入适配器） |
| 相关 PR | #71 默认拒绝边界 · #72 预检文档 · #73 库绑定 · **#74 适配器 + 组创建纳入边界 + 目标字节只读路径** · **#75 本报告** |
| 报告合并基线 | `dev` @ `e1a1379`（PR #75，合并后 CI run `43581724081` success） |
| CI | #74、#75 的 FormaCore tests / macOS app build / Benchmark smoke 全绿 |
| 本地（运行主机） | `swift build --build-tests` + `swift test`：550 用例通过 |

## 2. 实际 MCP 工具调用矩阵

| 工具 | 次数 | 参数约束 | 结果 |
| --- | --- | --- | --- |
| `create_group_path` | 1 | `location=Forma_I1B2/r1`，`database_uuid=隔离库` | 返回载荷未给出可用 UUID，组身份由 children 回读确认 |
| `import_file` | 4 | `mode=import`，`destination=Forma_I1B2/r1`，`database_uuid=隔离库`，四个合成文件路径 | 4 次都**没有**返回唯一 UUID；记录身份由创建前后 children 差集 + 独立回读确认 |
| `set_record_custom_metadata` | 8 | `mode=merge`，仅 8 个允许 identifier | 4 次初始写入 + 冲突改写 1 + 冲突复原 1 + 超时探针 1（**实际已落库**）+ 最终 `documenttype` 复原 1 |
| 断连探针（发送前） | 1 | 先杀 MCP 子进程，再发 metadata 写 | 请求**未发出**（§8 情况 B） |
| 断连探针（发送后、响应前） | **0** | — | **未构造**（§8 情况 C，NOT_VERIFIED） |

读侧只用了 `get_databases`、`get_record_children`、`get_record_parents`、`get_record_properties`、`get_record_custom_metadata`、`list_custom_metadata_fields`、`get_imported_record_path`。**边界拒绝 0 次**（说明计划内请求都合法），生产库调用 0 次。

## 3. `import_file` 返回结构的验证程度

分两层，结论强度不同：

**已验证（适配器层行为）**

- 4 次调用的响应都是合法 JSON（适配器能解析，未抛 `invalidResponse`）。
- 4 次响应都**不满足“载荷内恰好一个 UUID”**；`DEVONthinkMCPWriteTransport.uniqueUUID(in:)` 因此返回空串，创建路径进入 `VERIFY_REQUIRED` 分支。
- 结论：**返回值不能作为记录身份**（VERIFIED）。身份只能来自创建前后 children 差集 + 独立回读的 `databaseUUID`、父组与字节 SHA。

**未验证（结构细节）**

- 精确字段名、类型与嵌套层级：**NOT_VERIFIED**。运行记录只判定了“UUID 不唯一”，未逐项枚举字段。
- 究竟是不含 UUID、还是含 2 个及以上 UUID：**NOT_VERIFIED**（未记录该区分）。
- 是否含 `succeeded/failed/dropped_fields` 之类的信封字段：**NOT_VERIFIED**。
- 本轮**未**重新读取运行主机的原始响应（§0.2），也**未**为补齐结构而追加第 5 次导入（预算 4/4 已用尽，边界会拒绝）。

**明确禁止的补齐方式**：为枚举返回结构再次调用 `import_file`。该验证需要新的写预算与单独批准（见 Issue #22）。

## 4. Group 与记录身份

| 对象 | 数量 | 独立性证据 |
| --- | --- | --- |
| Group | 2（`Forma_I1B2`、`r1`） | children 回读的 `databaseUUID` 均为隔离库；父组关系经 `get_record_parents` 确认 |
| 记录 | 4 | 每条记录回读 `databaseUUID=隔离库`、父组=`r1`、字节 SHA 等于对应源文件 |

适配器对 `create_group_path` 的返回值同样不可用；组 UUID 完全来自回读。这条路径在预检阶段就被设计为“返回值不可信”。

## 5. 源/目标标准 SHA-256 对照

| 文件 | 源 SHA-256 | 目标 SHA-256 | 一致 |
| --- | --- | --- | --- |
| `forma-b1-probe-01.md` | `409833d4cfd51df2cc91339cf5dcc0d9d71eddbf781406f3e52e77517573973e` | 同左 | 是 |
| `forma-b1-probe-02.txt` | `a6e8d35d00151ec72461b567efe3c5dd84432b8dd395d723cb703d36a748e95f` | 同左 | 是 |
| `forma-b1-probe-03.csv` | `f2dc19a7443b23cc64be58cb500c533178dbf3f62650c0d73ab1623c281b1c0e` | 同左 | 是 |
| `forma-b1-probe-04.png` | `ebda4d4ace3059d20d30b04f8fb1a9390f9e8bd8cd2117fca38db09ba2efa1a0` | 同左 | 是 |

源值由 `scripts/make_i1_b2_synthetic.py` 确定性生成（2026-11-14 收尾时在 DevBox 重算，与 `docs/I1-B2-PREFLIGHT.md` §7 逐字一致）。目标字节通过 `get_imported_record_path` 取路径、宿主只读读取并计算；`export_record` 未用于本阶段。四种格式（markdown / plain text / CSV / PNG）均为字节级一致。

目标侧哈希是运行主机的观察值，本轮未重读原始日志（§0.2）；其可复现前提是源夹具未变（已重算确认）。

## 6. Metadata：6 个非空 + 2 个显式 null + 4 个未写入

写入请求包含 8 个允许 identifier，但**不是 8 个非空值**：

| 类别 | 字段 | 写入值 | 回读 |
| --- | --- | --- | --- |
| 非空字符串（6） | `projectname` | `FORMA-SYNTHETIC-PROJECT-001` | 原样回读 |
| | `documentcategory` | `99_TEST` | 原样回读 |
| | `documenttype` | `SYNTHETIC` | 原样回读 |
| | `issuer` | `FORMA-SYNTHETIC-ISSUER` | 原样回读 |
| | `completionyear` | `2099` | 原样回读 |
| | `biddeadline` | `2099-12-31` | 原样回读 |
| 显式 null（2） | `bidderentity`、`endcustomer` | `.null` | **missing**：null 未落成字符串，回读为缺失而非空串 |
| 未写入（4） | `department`、`salesowner`、`tenderreference`、`bsdcode` | 未出现在请求中 | **missing**：`mode=merge` 未触碰 |

结论：

- 6 个字段写入非空值并逐字回读：**VERIFIED**。
- 2 个字段以显式 null 写入后最终为 missing：**VERIFIED**（语义是“请求里出现过该键且值为 null”，与“从未写入”在回读上不可区分——这是本轮的观察，不是对服务端内部语义的断言）。
- 4 个未写入字段保持 missing，merge 未清除其他字段：**VERIFIED**。
- “8 个字段全部写入非空值”**不是**本轮事实，任何报告不得这样表述。

## 7. 重复运行幂等

同一操作键再次执行：`phase=readback_verified` → 输出 `SKIP_VERIFIED`，`import_file` 调用数 **0**，记录 UUID 集合不变。四份文件全部走此路径。Ledger 的 `recordIntent` 以 `key_digest` 唯一索引拒绝第二次意图。

## 8. 超时、发送前断连、发送后断连：三种情况分开

这是三件不同的事实，验收强度不同。**不得**用情况 B 的通过代替情况 C。

| 情况 | 事实 | 本轮做法与观察 | 验收 |
| --- | --- | --- | --- |
| **A. 写请求超时** | 请求已发出，实际写入已经落库 | 暂停 MCP 子进程后发出 metadata 写 → 客户端 `FormaError.timeout`；恢复进程后回读发现该写入**已落库** | **VERIFIED**：正确进入 `VERIFY_REQUIRED`，未重试；以只读回查判定 |
| **B. 发送前断连** | 请求未发出 | 先杀 MCP 子进程，再发 metadata 写 → `FormaError.disconnected`；请求未到达服务端 | **VERIFIED**：恢复后目标字段仍是超时探针值，无盲重试 |
| **C. 发送后、响应前断连** | 请求已发出，响应未返回 | **未构造** | **NOT_VERIFIED** |

情况 A 与 B 的差别正是“未知副作用”与“确定无副作用”的差别；情况 C 介于两者之间，当前没有任何实测证据，代码路径上它落在与 A 相同的 `VERIFY_REQUIRED` 分支（`ImportFacts.RequestOutcome.disconnected`），但这是设计推断，**不是实测**。

补充（同一维度下的其它已做项）：

| 场景 | 做法 | 观察 | 结论 |
| --- | --- | --- | --- |
| 冲突 | 经授权工具把 `projectname` 改为 B，再用同一操作的原意图写 A | 写前回读发现 B≠A → 拒绝覆盖，记录 `CONFLICT_HOLD`，`wrote=false` | **PASS**（随后经授权工具复原 A） |
| 进程重启 | 新进程重跑同一操作键 | 全部 `SKIP_VERIFIED`；记录数仍为 4 | **PASS**（无重复记录） |

“进程重启”是**重启后重跑**，不是“写入进行中被强杀”的崩溃注入；后者只在 Fake Transport 故障矩阵（I1-A）中覆盖，真实 MCP 下未构造。

超时探针把 `documenttype` 改成了 `TIMEOUT-PROBE`，作为测试残留已被显式复原为 `SYNTHETIC`。

## 9. Ledger 与真实对象对账

| 项 | Ledger | 实际数据库 | 一致 |
| --- | --- | --- | --- |
| 操作数 | 4 | 4 条记录 | 是 |
| 阶段 | 全部 `readback_verified` | 全部已回读验证 | 是 |
| 目标库 | 隔离库 UUID | 记录 `databaseUUID` 相同 | 是 |
| 目标组 | `["Forma_I1B2","r1"]` | 父组为 `r1` | 是 |
| 源/目标 SHA | 两列同值 | 与源文件一致 | 是 |

对账依据是运行主机上的 Ledger dump；本轮未重读该文件（§0.2）。

## 10. 生产库零写入的证据

1. **唯一写路径**：所有写调用都经过 `GuardedImportWriteTransport`，其 scope 的 `databaseID` 只有隔离库；任何其他库在 `permit` 阶段被拒（该拒绝有单测覆盖）。
2. **审计**：本次运行的 grants 只包含 3 个允许工具；`refusalCounts` 为空；`transcript` 中没有任何工具箱越过边界。
3. **未使用其他通道**：没有 AppleScript、没有直接访问 `.dtBase2` 写入、没有临时脚本绕过边界。
4. **未对生产库发起任何记录级查询**。按 Owner 批准的修订，本项不再用生产库前后计数，而由上述工具审计 + 库 UUID 白名单证明。

## 11. 测试库遗留对象（不自动删除）

| 对象 | 数量 | 说明 |
| --- | --- | --- |
| Group `Forma_I1B2` | 1 | 本轮创建 |
| Group `Forma_I1B2/r1` | 1 | 本轮创建 |
| 记录 | 4 | 合成文件，元数据为合成值 |
| 其他 | 0 | 无额外记录、无移动、无回收站操作 |

按要求**未删除任何对象**；清理留给 Owner 或后续明确授权。

## 12. 未验证项（不得升格为 PASS）

| 项 | 状态 | 补齐所需 |
| --- | --- | --- |
| `import_file` 精确返回结构（字段名/类型/嵌套、UUID 数量与解析） | **NOT_VERIFIED** | 新的写预算或另一次批准的只读 transcript 复核 |
| 发送后、响应前断连（情况 C） | **NOT_VERIFIED** | 真实 MCP 下的响应前断连注入 |
| 写入进行中被强杀的崩溃恢复 | **NOT_VERIFIED**（真实 MCP）；Fake Transport 下已覆盖 | 真实进程崩溃注入 |
| `dropped_fields` / 部分成功 | **NOT_VERIFIED**：8 个字段均为 string，未构造出被服务端拒绝的值；不为此增加写预算 | 新的写预算 + 明确的非法字段授权 |
| 异步可见性 | 观察为**立即可见**；延迟场景未构造 | 延迟场景设计 |
| Replicant / 多父组 | **NOT_VERIFIED**，属 **I2**，未授权 | I2 授权 |
| 真实业务文件 / OneDrive 占位 / 生产迁移 | 不在本轮范围 | 后续阶段授权 |

## 13. 逐项结论

| 项 | 结论 |
| --- | --- |
| Preflight（库/工具/字段/文件） | **PASS** |
| 建组与组身份回读 | **PASS** |
| 4 条导入与记录身份 | **PASS** |
| 源/目标 SHA-256 | **PASS**（4/4 字节一致） |
| Metadata merge + 逐字段回读 | **PASS**（6 非空 + 2 显式 null → missing，见 §6） |
| 未写入字段保持 | **PASS** |
| 重复运行幂等 | **PASS** |
| 冲突拒绝覆盖 | **PASS** |
| 超时 → VERIFY_REQUIRED（写后回读） | **PASS**（情况 A） |
| 发送前断连（请求未发出） | **PASS**（情况 B） |
| 发送后断连（响应前） | **NOT_VERIFIED**（情况 C） |
| 进程重启后重跑无重复 | **PASS** |
| 部分成功 / `dropped_fields` | **NOT_VERIFIED** |
| `import_file` 精确返回结构 | **NOT_VERIFIED**（见 §3） |
| Replicant / 多父组 | **NOT_VERIFIED**（属 I2） |
| 生产库 | **零写入** |

## 14. 是否达到 Import Integration Verified

**达到，限定于本轮范围**：隔离库 + 本轮创建的组 + 4 条合成记录 + 8 个允许字段 + 3 个授权工具。剩余阻塞项：

1. `import_file` 返回结构、`dropped_fields` 部分成功路径、情况 C 断连与写入中崩溃仍未验证（需要新的写预算或另一份批准，见 Issue #22）。
2. Replicant / 多父组属于 I2，未授权。
3. 真实业务文件、OneDrive 占位文件、生产库迁移均不在本轮范围内。

原始证据（UUID、路径、日志、Ledger dump、审计 JSON）：运行主机的 `~/.forma/evidence/i1-b2/`。本轮复核主机无法读取该目录（§0.2）。
