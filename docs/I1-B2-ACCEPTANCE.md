# I1-B2 — Live Import Acceptance（脱敏报告）

状态：**Import Integration Verified（限定范围）**。

测试库 `Forma_I1B2_Sandbox`、测试组 `Forma_I1B2/r1`、4 条合成记录、8 个允许字段。所有写入经 `GuardedImportWriteTransport` → `DEVONthinkMCPWriteTransport`；生产库零写入。

真实库/组/记录 UUID、包内路径、原始响应与运行日志只保存在本机 `~/.forma/evidence/i1-b2/`，本文一律用占位符。

## 1. 仓库与 CI

| 项 | 值 |
| --- | --- |
| 执行基线 | `dev` @ `7c9c4f9`（PR #74：真实写入适配器） |
| 相关 PR | #71 默认拒绝边界 · #72 预检文档 · #73 库绑定 · **#74 适配器 + 组创建纳入边界 + 目标字节只读路径** |
| CI | #74 的 FormaCore tests / macOS app build / Benchmark smoke 全绿 |
| 本地 | `swift build --build-tests` + `swift test`：550 用例通过 |

## 2. 实际 MCP 工具调用矩阵

| 工具 | 次数 | 参数约束 | 结果 |
| --- | --- | --- | --- |
| `create_group_path` | 1 | `location=Forma_I1B2/r1`，`database_uuid=隔离库` | 返回载荷未给出可用 UUID，组身份由 children 回读确认 |
| `import_file` | 4 | `mode=import`，`destination=Forma_I1B2/r1`，`database_uuid=隔离库`，四个合成文件路径 | 4 次都**没有**返回唯一 UUID；记录身份由创建前后 children 差集 + 独立回读确认 |
| `set_record_custom_metadata` | 8 | `mode=merge`，仅 8 个允许 identifier | 4 次初始写入 + 冲突改写 1 + 冲突复原 1 + 超时探针 1（**实际已落库**）+ 最终 `documenttype` 复原 1 |
| 断连探针 | 0（未发出） | — | 连接已被杀死，请求在发送前失败 |

读侧只用了 `get_databases`、`get_record_children`、`get_record_parents`、`get_record_properties`、`get_record_custom_metadata`、`list_custom_metadata_fields`、`get_imported_record_path`。**边界拒绝 0 次**（说明计划内请求都合法），生产库调用 0 次。

## 3. 真实 `import_file` 返回结构

- 响应是合法 JSON，但**不包含恰好一个 UUID**：适配器按"唯一 UUID 才可作为身份"的规则返回空串，触发 `VERIFY_REQUIRED` 分支。
- 因此本报告的记录身份不来自返回值，而来自：创建前 children UUID 集合 → 创建后差集 → 独立回读的 `databaseUUID` + 父组 + 字节 SHA。
- 精确字段名未逐项枚举（不追加第 5 次导入：预算 4/4 已用尽，边界会拒绝）。**返回结构细节：NOT_VERIFIED**；"返回值不可当作身份"这一结论：**VERIFIED**。

## 4. Group 与记录身份

| 对象 | 数量 | 独立性证据 |
| --- | --- | --- |
| Group | 2（`Forma_I1B2`、`r1`） | children 回读的 `databaseUUID` 均为隔离库；父组关系经 `get_record_parents` 确认 |
| 记录 | 4 | 每条记录回读 `databaseUUID=隔离库`、父组=`r1`、字节 SHA 等于对应源文件 |

适配器对 `create_group_path` 的返回值同样不可用；组 UUID 完全来自回读。这条路径在预检阶段就被设计为"返回值不可信"。

## 5. 源/目标标准 SHA-256 对照

| 文件 | 源 SHA-256 | 目标 SHA-256 | 一致 |
| --- | --- | --- | --- |
| `forma-b1-probe-01.md` | `409833d4…3973e` | `409833d4…3973e` | 是 |
| `forma-b1-probe-02.txt` | `a6e8d35d…8e95f` | `a6e8d35d…8e95f` | 是 |
| `forma-b1-probe-03.csv` | `f2dc19a7…b1c0e` | `f2dc19a7…b1c0e` | 是 |
| `forma-b1-probe-04.png` | `ebda4d4a…efa1a0` | `ebda4d4a…efa1a0` | 是 |

目标字节通过 `get_imported_record_path` 取路径、宿主只读读取并计算；`export_record` 未用于本阶段。四种格式（markdown / plain text / CSV / PNG）均为字节级一致。

## 6. Metadata merge 与逐字段回读

写入 8 个允许字段：`projectname`、`documentcategory`、`documenttype`、`issuer`、`completionyear`、`biddeadline`（有值），`bidderentity`、`endcustomer`（显式 null）。

回读结果（4 条记录一致）：

| 字段 | 回读 |
| --- | --- |
| `projectname` | `FORMA-SYNTHETIC-PROJECT-001` |
| `documentcategory` | `99_TEST` |
| `documenttype` | `SYNTHETIC` |
| `issuer` | `FORMA-SYNTHETIC-ISSUER` |
| `completionyear` | `2099` |
| `biddeadline` | `2099-12-31` |
| `bidderentity` / `endcustomer` | missing（null 未落成字符串） |
| 未写入的 `department` / `salesowner` / `tenderreference` / `bsdcode` | 全部 missing（未被 merge 触碰） |

`mode=merge` 未清除未指定字段：**VERIFIED**。

## 7. 重复运行幂等

同一操作键再次执行：`phase=readback_verified` → 输出 `SKIP_VERIFIED`，`import_file` 调用数 **0**，记录 UUID 集合不变。四份文件全部走此路径。Ledger 的 `recordIntent` 以 `key_digest` 唯一索引拒绝第二次意图。

## 8. 冲突与断连恢复

| 场景 | 做法 | 观察 | 结论 |
| --- | --- | --- | --- |
| 冲突 | 经授权工具把 `projectname` 改为 B，再用同一操作的原意图写 A | 写前回读发现 B≠A → 拒绝覆盖，记录 `CONFLICT_HOLD`，`wrote=false` | **PASS**（随后经授权工具复原 A） |
| 超时 | 先暂停本次 MCP 子进程，再发出 metadata 写 | 客户端 `FormaError.timeout`；**恢复后回读发现该写入已落库** | **PASS**：正是必须 `VERIFY_REQUIRED` 的情形；未重试 |
| 断连 | 杀掉本次 MCP 子进程后再写 | `FormaError.disconnected`，请求未发出；恢复后目标字段仍是超时探针值 | **PASS**：先只读回查、无盲重试 |
| 重启恢复 | 新进程重跑同一操作键 | 全部 `SKIP_VERIFIED`；记录数仍为 4 | **PASS**（无重复记录） |

超时探针把 `documenttype` 改成了 `TIMEOUT-PROBE`，作为测试残留已被显式复原为 `SYNTHETIC`。

## 9. Ledger 与真实对象对账

| 项 | Ledger | 实际数据库 | 一致 |
| --- | --- | --- | --- |
| 操作数 | 4 | 4 条记录 | 是 |
| 阶段 | 全部 `readback_verified` | 全部已回读验证 | 是 |
| 目标库 | 隔离库 UUID | 记录 `databaseUUID` 相同 | 是 |
| 目标组 | `["Forma_I1B2","r1"]` | 父组为 `r1` | 是 |
| 源/目标 SHA | 两列同值 | 与源文件一致 | 是 |

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

## 12. 逐项结论

| 项 | 结论 |
| --- | --- |
| Preflight（库/工具/字段/文件） | **PASS** |
| 建组与组身份回读 | **PASS** |
| 4 条导入与记录身份 | **PASS** |
| 源/目标 SHA-256 | **PASS**（4/4 字节一致） |
| Metadata merge + 逐字段回读 | **PASS** |
| 未写入字段保持 | **PASS** |
| 重复运行幂等 | **PASS** |
| 冲突拒绝覆盖 | **PASS** |
| 超时 → VERIFY_REQUIRED（写后回读） | **PASS** |
| 断连恢复（无盲重试） | **PASS** |
| 重启恢复无重复 | **PASS** |
| 部分成功 / `dropped_fields` | **NOT_VERIFIED**（8 个字段均为 string，未构造出被服务端拒绝的值；不为此增加写预算） |
| `import_file` 精确返回结构 | **NOT_VERIFIED**（见 §3） |
| 异步可见性 | 观察为**立即可见**；延迟场景未构造 |
| Replicant / 多父组 | **NOT_VERIFIED**（本轮未授权） |
| 生产库 | **零写入** |

## 13. 是否达到 Import Integration Verified

**达到，限定于本轮范围**：隔离库 + 本轮创建的组 + 4 条合成记录 + 8 个允许字段 + 3 个授权工具。剩余阻塞项：

1. `import_file` 返回结构与 `dropped_fields` 部分成功路径仍未验证（需要新的写预算或另一份批准）。
2. Replicant / 多父组属于 I2，未授权。
3. 真实业务文件、OneDrive 占位文件、生产库迁移均不在本轮范围内。

原始证据（UUID、路径、日志、Ledger dump、审计 JSON）：`~/.forma/evidence/i1-b2/`。
