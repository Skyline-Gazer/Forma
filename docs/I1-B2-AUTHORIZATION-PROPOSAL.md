# I1-B2 — Write Authorization Proposal（待 Owner 批准）

状态：**提案，未获授权。** 在本文件被 Owner 明确批准之前，不得调用任何创建、修改、移动或删除 DEVONthink 对象的工具。

依据：`docs/I1-B1-CAPABILITY-DISCOVERY.md`（现场能力与 schema 事实）、`docs/ADR-I1-A-IMPORT-CONTRACT.md`（执行契约）、`docs/SPEC.md` §4.2 / §8.3 / §10.2。

本文件不含真实数据库名、UUID、本机路径或业务记录。真实值只写在本机授权位置的证据目录；下文用 `<…>` 占位。

## 1. 目标

用**最小、可丢弃、可完全对账**的真实写入，验证三件目前 `NOT_VERIFIED` 的事实：

1. `import_file` 的真实输入/返回形状、目标库与目标组绑定、创建后的记录 UUID、是否存在异步可见性。
2. `set_record_custom_metadata` 的 merge 语义、空值清除、标识符约束、`dropped_fields` 的真实触发条件。
3. 源文件字节与目标记录字节的标准 SHA-256 是否一致，以及"重复执行不产生第二条记录"是否成立。

明确**不做**的事：不写生产库、不创建/修改/删除任何业务记录、不改 Group 结构之外的对象、不启用 Replicant、不改 12 个字段的定义。

## 2. 授权对象

| 项 | 值 |
| --- | --- |
| 隔离数据库 | `<ISOLATED_DB_UUID>`（必须是 Owner 明确指定的可丢弃库；不得是生产 `Project_Archive`） |
| 数据库名称 | `<ISOLATED_DB_NAME>` |
| 可丢弃测试 Group | `<DISPOSABLE_GROUP_UUID>`（由 B2 第一步 `create_group_path` 在本库内创建，路径 `Forma_I1B2/<run-id>`） |
| 允许创建的测试记录上限 | **4 条**（对应 §5 的 4 个合成文件，各 1 条） |
| 允许创建的分组上限 | **2 个**（`Forma_I1B2` 与 `<run-id>`） |
| 允许删除的对象 | 仅本次 run-id 下由 Forma 创建的 4 条记录与 2 个分组 |

## 3. 精确允许的写工具

只允许这 3 个，且只允许在本提案 §2 的范围内调用：

| 工具 | 允许的用途 |
| --- | --- |
| `create_group_path` | 在本库内创建 `Forma_I1B2/<run-id>` |
| `import_file` | 仅 `mode:"import"`；`path` 指向 §5 的合成文件；`database_uuid` 与 `destination` 固定为 §2 的值 |
| `set_record_custom_metadata` | 仅 `mode:"merge"`；只写 §4 列出的字段；只对本次创建的记录调用 |

**明确禁止**：`trash_record`、`move_record`、`duplicate_record`、`merge_records`、`convert_record`、`replicate_record`、`update_record`、`update_record_content`、`set_record_tags`、`create_record`（用文本建记录）、`create_group_path` 之外的任何结构操作、以及任何指向生产库的调用。清理只由 Owner 在本机手动执行或单独授权。

## 4. 允许写入的 Metadata 字段

仅这 8 个，全部为现场确认为 `string` 且启用的字段：

`projectname`、`documentcategory`、`documenttype`、`issuer`、`bidderentity`、`endcustomer`、`completionyear`、`biddeadline`

- 值一律为合成值，例如 `projectname = "FORMA-SYNTHETIC-PROJECT-001"`。
- `completionyear = "2099"`、`biddeadline = "2099-12-31"`，便于识别。
- 不写 `department`、`salesowner`、`tenderreference`、`bsdcode`（留给 B2 的"未写入字段不被改动"对照）。
- 写入前必须先调 `list_custom_metadata_fields`，确认标识符存在且启用；**只要有任何标识符不在该列表中，立即停止**，因为服务端会静默创建新字段。

## 5. 合成测试文件（可复现）

由仓库内 `scripts/make_i1_b2_synthetic.py` 确定性生成；不含任何业务数据。

| 文件 | 字节 | 标准 SHA-256（源） |
| --- | --- | --- |
| `forma-b1-probe-01.md` | 47 | `409833d4cfd51df2cc91339cf5dcc0d9d71eddbf781406f3e52e77517573973e` |
| `forma-b1-probe-02.txt` | 43 | `a6e8d35d00151ec72461b567efe3c5dd84432b8dd395d723cb703d36a748e95f` |
| `forma-b1-probe-03.csv` | 69 | `f2dc19a7443b23cc64be58cb500c533178dbf3f62650c0d73ab1623c281b1c0e` |
| `forma-b1-probe-04.png` | 75 | `ebda4d4ace3059d20d30b04f8fb1a9390f9e8bd8cd2117fca38db09ba2efa1a0` |

B2 执行时必须现场重算这 4 个值；任一不符即停止。

## 6. 执行顺序与判据

每一步都先持久化 Intent，再发请求，再回读。

1. **Preflight（只读）**：`get_databases{uuid}` 确认是 §2 的库；`list_custom_metadata_fields` 确认 §4 的 8 个标识符全部存在且启用；确认生产库不在本次任何调用的参数里。
2. **建组**：`create_group_path` 创建 `Forma_I1B2/<run-id>`；回读 `lookup_records{location}` 或 `get_record_children` 确认 UUID，登记到 Ledger。
3. **单条导入**：先导 1 个文件；记录返回内容（**不假设形状**）、耗时、是否立即在 `get_record_children` 中可见。若不可见，按 `VERIFY_REQUIRED` 只读重查，不重试导入。
4. **字节核对**：用 `get_imported_record_path` 取路径、只读读字节并本地算 SHA-256，与 §5 的源 SHA 对照。**只有字节相等才记 `shaVerified=true`**；不等则记为格式转换差异，`standardSHA256` 保留目标字节值并注明不等于源。
5. **Metadata 写入**：`mode:"merge"` 写 §4 的 8 个字段；逐字段回读，核对 12 个字段中未被写入的 4 个仍为写入前的状态。
6. **重复执行**：对同一文件再跑一次完整 Preflight → 仲裁 → 期望 `SKIP_VERIFIED`，**不得**产生第 2 条记录。记录两次的 children 数量与 UUID 集合。
7. **其余 3 个文件**：重复 3–6。

## 7. 冲突与断连测试

| 场景 | 方式 | 期望 |
| --- | --- | --- |
| 冲突 | 在 §4 的字段上先由 Forma 写入 A，再人工（Owner 或本地脚本，不经 Forma）改为 B，然后重跑 Forma 写入 A | 必须 `CONFLICT_HOLD`，不得覆盖 B |
| 断连 | 在写入请求发出后立即杀掉 MCP 子进程（或断开 stdio） | 进入 `VERIFY_REQUIRED`；只读回查判定实际状态后才回到三态之一；**不自动重放写入** |
| 超时 | 对同一条记录制造超时 | 同上，禁止重试写入 |
| 部分成功 | 用 `set_record_custom_metadata` 写一个 set 类型的非治理字段（若 Owner 另行批准）以触发 `dropped_fields` | 记录为部分成功，逐字段回读；本提案默认不做此项 |

## 8. 执行后如何识别测试产生的记录

全部记录必须同时满足：

- 位于本次 run-id 的 Group 下；
- `projectname` 为 `FORMA-SYNTHETIC-PROJECT-001`；
- 文件名为 §5 的 4 个名字之一；
- UUID 在 B2 开始前登记的 Ledger 中不存在。

任一不满足即视为"来源不明"，停止并交给 Owner。

## 9. 出现未知结果时的停止规则

立即停止全部后续写入，只做只读回查，并报告：

1. 返回形状与 `docs/I1-B1-CAPABILITY-DISCOVERY.md` 记录不符；
2. `succeeded`/`failed` 计数与预期不符，或出现 `failed_uuids`；
3. 记录出现在 §2 指定范围之外（任何其他 Group 或库）；
4. `get_record_children` 的 `total` 与 Ledger 不一致；
5. 任何工具报"Database not found"以外的错误且无法用只读查询解释；
6. 目标字节 SHA 与源 SHA 不一致且差异原因不明。

停止后**不得**用重试、删除或"再导一次"来掩盖；先出对账报告。

## 10. 证明未访问生产库

B2 结束时提交：

- 全部 MCP 调用的**参数摘要**（工具名 + `database_uuid` 的哈希前缀 + 时间戳），不含业务内容；
- Ledger 中每条记录的库 UUID 前缀，证明均为 §2 的隔离库；
- `get_databases` 的全量列表快照，证明生产库的记录级工具从未被调用；
- 执行前后生产库的 `get_record_children` 计数对照（只读），证明记录数未变。

生产库 UUID 只在与隔离库 UUID 对照时以哈希前缀出现，不输出完整值。

## 11. 批准方式

Owner 回复中需明确：

1. 批准本提案（是/否）；
2. 指明隔离库 UUID 与名称；
3. 确认 §3 的 3 个写工具、§2 的数量上限、§4 的字段集合；
4. 确认 §7 的冲突与断连测试可以在该隔离库执行。

未获上述四项明确确认前，I1-B2 不执行。
