# I1-B2 — Write Authorization Proposal（修订版，待 Owner 批准）

状态：**提案，未获授权。** 在本文件被 Owner 明确批准之前，不得调用任何创建、修改、移动或删除 DEVONthink 对象的工具。

修订：2026-11-14（I1-B2 Preflight）。相对上一版的变化见 §12。

依据：`docs/I1-B1-CAPABILITY-DISCOVERY.md`（现场能力与 schema 事实）、`docs/ADR-I1-A-IMPORT-CONTRACT.md`（执行契约）、`Sources/FormaCore/Import/ImportWriteBoundary.swift`（默认拒绝边界实现）。

本文件不含真实数据库名、UUID、本机路径或业务记录；真实值只写在本机授权位置的证据目录，下文用 `<…>` 占位。

## 1. 目标与边界

用**最小、可丢弃、可完全对账**的真实写入，验证三件目前 `NOT_VERIFIED` 的事实：

1. `import_file` 的真实输入/返回形状、目标库与目标组绑定、创建后的记录 UUID、是否存在异步可见性。
2. `set_record_custom_metadata` 的 merge 语义、空值清除、标识符约束、`dropped_fields` 的真实触发条件。
3. 源文件字节与目标记录字节的标准 SHA-256 是否一致，以及"重复执行不产生第二条记录"是否成立。

**本轮不授权**：自动删除记录或 Group、`trash_record`、`move_record`、`replicate_record`、`merge_records`、`convert_record`、`update_record`、`create_record`、`capture_*`、`ocr_record`、任何对生产库的写调用、任何 Replicant 操作、任何字段定义变更。

## 2. 授权对象

| 项 | 值 |
| --- | --- |
| 隔离数据库 | `<ISOLATED_DB_UUID>`（Owner 需在 DEVONthink GUI 中新建可丢弃库，建议名 `Forma_I1B2_Sandbox`；**不得**用 Inbox 或任何现存业务库替代） |
| 数据库校验 | 只读 `get_databases` 返回的 `uuid` 必须精确等于上式，且 `is_inbox == false` |
| 可丢弃测试 Group | `Forma_I1B2/<run-id>`（由 B2 第一步 `create_group_path` 在本库内创建） |
| 允许创建的测试记录上限 | **4 条**（对应 §6 的 4 个合成文件，各 1 条） |
| 允许创建的分组上限 | **2 个**（`Forma_I1B2` 与 `<run-id>`） |
| 允许删除的对象 | **无**（本轮不授权任何删除；清理由 Owner 手动执行或另行授权） |

## 3. 默认拒绝的执行边界（代码强制）

`ImportWriteBoundary.swift` 把下面的约束变成类型与状态，而不是约定：

| 维度 | 强制方式 |
| --- | --- |
| 工具白名单 | `ImportWriteTool` 只有 3 个 case；**边界上没有任何字符串工具名入口**，未知工具无法表达 |
| 数据库白名单 | 精确 UUID 比较（大小写不敏感），每次 `permit` 都校验 |
| Group 路径前缀 | 必须**等于或扩展** `Forma_I1B2/<run-id>`；仅共享字符串前缀（如 `Forma_I1B2X`）被拒 |
| Metadata identifier 白名单 | 逐个 identifier 校验；未列出的直接拒绝，**不给服务端自动建字段的机会** |
| 源文件路径白名单 | 规范化绝对路径精确匹配 4 个合成文件；未解析出路径即拒绝 |
| 数量预算 | 记录 4、分组 2；**授权即扣减**，崩溃循环无法超额 |
| Metadata 目标记录 | 必须先被证明属于本库（见 §8），否则拒绝 |
| 拒绝时机 | 全部发生在调用传输层之前；测试用例断言底层 `create/lookup/writeMetadata` 计数仍为 0 |

## 4. 精确允许的写工具与参数

| 工具 | 允许的参数 | 说明 |
| --- | --- | --- |
| `create_group_path` | `location = Forma_I1B2/<run-id>`，`database_uuid = <ISOLATED_DB_UUID>` | 仅建组，不改既有组 |
| `import_file` | `path ∈ {4 个合成文件}`，`mode = "import"`，`destination = Forma_I1B2/<run-id>`，`database_uuid = <ISOLATED_DB_UUID>` | **仅 `mode=import`**；`index` 被边界拒绝 |
| `set_record_custom_metadata` | `mode = "merge"`，`uuid` 为已证明在库内的记录，`metadata` 仅含 §5 的 identifier | 该工具 schema **没有 `database_uuid` 参数**，库绑定只能靠 §8 的独立核验 |

执行前必须重新核对三个工具的 `inputSchema` SHA-256（B1 实测值）：

| 工具 | digest |
| --- | --- |
| `create_group_path` | `6256d00d2755137648ed10e28fa1b946db9bc30b601feefc741b303758fd439a` |
| `import_file` | `3642cf6990596a9b7814c846a018004b4fe9694b6af35b5d2cd468a4611b0d2f` |
| `set_record_custom_metadata` | `f1aa770b370095f3c2280d8a617dbe3078eeee04da794a746ac925dd71a7fdb0` |

任一 digest 与现场不符 → 停止，按 schema 变更处理，不按旧契约继续。

服务端返回值一律视为**不可信输入**：`succeeded/failed/dropped_fields` 只作为线索，成功与否由独立回读判定。

## 5. 允许写入的 Metadata 字段

仅这 8 个，全部为现场确认为 `string` 且启用的字段：

`projectname`、`documentcategory`、`documenttype`、`issuer`、`bidderentity`、`endcustomer`、`completionyear`、`biddeadline`

- 值一律为合成值，例如 `projectname = "FORMA-SYNTHETIC-PROJECT-001"`。
- `completionyear = "2099"`、`biddeadline = "2099-12-31"`，便于识别。
- 不写 `department`、`salesowner`、`tenderreference`、`bsdcode`（留作"未写入字段不被改动"的对照）。
- 写入前必须重新调 `list_custom_metadata_fields`，确认 8 个 identifier 存在、类型为 `string`、未 disabled；任一项不符即停止。

## 6. 合成测试文件（可复现）

由仓库内 `scripts/make_i1_b2_synthetic.py` 确定性生成；不含任何业务数据。

| 文件 | 字节 | 标准 SHA-256（源） |
| --- | --- | --- |
| `forma-b1-probe-01.md` | 47 | `409833d4cfd51df2cc91339cf5dcc0d9d71eddbf781406f3e52e77517573973e` |
| `forma-b1-probe-02.txt` | 43 | `a6e8d35d00151ec72461b567efe3c5dd84432b8dd395d723cb703d36a748e95f` |
| `forma-b1-probe-03.csv` | 69 | `f2dc19a7443b23cc64be58cb500c533178dbf3f62650c0d73ab1623c281b1c0e` |
| `forma-b1-probe-04.png` | 75 | `ebda4d4ace3059d20d30b04f8fb1a9390f9e8bd8cd2117fca38db09ba2efa1a0` |

B2 执行时必须现场重算这 4 个值；任一不符即停止。

## 7. 执行顺序：先一条，再三条

1. **Preflight（只读）**：`get_databases{uuid}` 精确匹配 §2；`list_custom_metadata_fields` 校验 §5 的 8 个字段；核对 §4 的 3 个 schema digest。
2. **建组**：`create_group_path` 创建 `Forma_I1B2/<run-id>`；回读组 UUID 并登记 Ledger。
3. **首条记录**：只导 `forma-b1-probe-01.md` 一条。记录返回内容（**不假设形状**）、是否携带 UUID、是否立即在 `get_record_children` 中可见。
4. **首条完整验收**（全部通过才继续）：
   - 目标记录 UUID 能被独立回读证明属于本库、本 Group；
   - 源/目标字节标准 SHA-256 对照（或明确记录 `hash_unverified`）；
   - Metadata merge 写入 + 逐字段回读；
   - 重复执行同一文件 → `SKIP_VERIFIED`，不产生第二条。
5. **其余三条**：仅在首条全部通过后，按同一批准范围、同一预算继续；每条各自完成 3–4 的核对。

首条任一项未通过 → 停止，不进第 5 步。

## 8. 身份恢复：创建时没有初始 Metadata

`import_file` 没有 metadata 参数，记录创建完成到元数据写入之间存在一段"无字段可辨识"的窗口。因此：

1. **创建返回的 UUID 一律视为待证事实**。必须用独立只读客户端回读该 UUID，且回读载荷的 `databaseUUID` 等于 §2 的库、父组等于 §2 的 Group、标准 SHA-256 等于 §6 的源值。
2. **回读失败或 UUID 未落 Ledger 时**，进入 `VERIFY_REQUIRED`，用只读 children 枚举（不是 search）在该 Group 内查找候选：
   - 候选唯一且库/父组/SHA 全部吻合 → 记为本次操作产生的记录，补写 Ledger；
   - 候选不唯一、或无法证明归属 → **不得写入任何 Metadata**，保持 `VERIFY_REQUIRED` 并报告；
   - 只有"明确不存在候选"才允许重新执行导入。
3. **未知 Create 结果不得盲重试**。超时/断连后先只读回查；查不到明确结论就停在 `VERIFY_REQUIRED`。
4. 边界层同时要求：Metadata 写入的目标 UUID 必须已在本次运行中被证明属于本库（`recordVerified`），否则拒绝在调用前。

## 9. 冲突处理与断连

| 场景 | 方式 | 期望 |
| --- | --- | --- |
| 写前回读 | 每次写之前只读核对 UUID、库、父组、SHA、现有 Metadata | 与 Ledger 不一致即 `CONFLICT_HOLD`，不写 |
| 冲突 | 在允许字段上先由 Forma 写入 A，再人工改为 B，然后重跑写入 A | **拒绝覆盖**，`CONFLICT_HOLD`。该工具**没有原生条件写**（无 If-Match/版本参数），因此冲突检测只能靠写前回读 + 写后回读 |
| 断连 | 写入请求发出后杀掉 MCP 子进程 / 断开 stdio | `VERIFY_REQUIRED`，只读回查后才回到三态之一，**不重放写入** |
| 超时 | 对同一条记录制造超时 | 同上 |
| 部分成功 | 若出现 `dropped_fields` 非空 | 记录为部分成功，逐字段回读；不回滚、不重写未成功字段以外的内容 |

## 10. 停止规则

立即停止全部后续写入，只做只读回查，并报告：

1. 返回形状与 `docs/I1-B1-CAPABILITY-DISCOVERY.md` 记录不符，或 §4 的 schema digest 变化；
2. `succeeded/failed` 计数与预期不符，或出现 `failed_uuids`；
3. 记录出现在 §2 指定范围之外（任何其他 Group 或库）；
4. `get_record_children` 的 `total` 与 Ledger 不一致；
5. 任何工具报错且无法用只读查询解释；
6. 目标字节 SHA 与源 SHA 不一致且原因不明；
7. 边界层报出任何拒绝（`ImportWriteRefusal`）——拒绝本身即说明计划的请求越界，需人工复核而不是放宽边界。

停止后**不得**用重试、删除或"再导一次"来掩盖；先出对账报告。

## 11. 访问边界证明（不再依赖生产库计数）

改用两层证据，不再对生产库做任何 `get_record_children` 前后计数：

1. **工具调用审计**：边界层为每次授权记录 `{tool, 规范化请求摘要, 时间}`，并统计拒绝次数；B2 结束时导出该审计（不含业务内容），证明只出现 §4 的 3 个工具、只指向 §2 的库与 Group。
2. **库 UUID 白名单**：所有写请求的 `database_uuid` 与所有回读载荷的 `databaseUUID` 都必须等于 §2 的库；任何其他值在调用前被拒或被回读拒绝。

附加只读证据：B2 开始时的 `get_databases` 全量列表快照（证明生产库与隔离库同时可见而只有后者被绑定）。生产库 UUID 只以哈希前缀形式出现在对照表中。

## 12. 相对上一版的变化

- **删除**对生产库 `get_record_children` 的前后计数要求，改为 §11 的工具调用审计 + UUID 白名单。
- **明确**本轮不授权自动删除记录或 Group。
- **首次测试限定一条**合成记录，首条完整通过后才允许余下三条。
- **明确**未知 Create 结果不得盲重试，并给出 UUID 未落 Ledger 时的身份恢复路径（§8）。
- **明确**写前回读五项（UUID、库、父组、SHA、现有 Metadata）与冲突拒绝覆盖。
- **明确** Metadata 无原生条件写，冲突只能靠回读判定。
- **明确**取不到目标字节时维持 `hash_unverified`。
- 补充 §3 的默认拒绝边界实现与 §4 的 schema digest 复核。

## 13. 批准方式

Owner 回复中需明确：

1. 批准本提案（是/否）；
2. 在 GUI 中创建隔离库并给出其 UUID 与名称；
3. 确认 §4 的 3 个写工具、§2 的数量上限、§5 的 8 个字段；
4. 确认 §9 的冲突与断连测试可以在该隔离库执行；
5. 确认 §11 的访问边界证明方式。

未获上述明确确认前，I1-B2 不执行。
