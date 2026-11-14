# I1-B1 — DEVONthink MCP Live Capability Discovery（脱敏报告）

状态：**MCP Discovery Verified**；只读集成 **Partial**（修复后读路径实测通过，自动化属主明确指定隔离库的库级验收仍 **BLOCKED**）；写能力 **Schema Discovered / Unverified**；Import 集成 **NOT_VERIFIED**。

本文件只含工具名、schema 摘要、字段定义与合成数据。真实的数据库名称、UUID、记录标识与本机路径只保存在本机授权位置（本地证据目录），不入库。

- 探测时间：2026-11-14
- 宿主：macOS（arm64），GitHub Actions 为唯一编译/测试权威
- DEVONthink：4.4.2（`/Applications/DEVONthink.app`）
- DEVONthink MCP：`com.devon-technologies.think.mcp-server` 4.4.2；serverInfo `devonthink-mcp` 1.0.0；协议 **2025-06-18**；`--stdio`
- 写工具调用数：**0**（没有任何调用创建、修改、移动或删除 DEVONthink 对象）。全部调用为 `initialize` / `tools/list` 与只读工具。
- 另有 **1 次 `export_record`**：该工具注解为 `readOnlyHint:false`，但它只把一条既有合成记录的字节复制到临时目录（不触碰数据库），用于验证标准 SHA-256 获取路径；临时输出在摘要后已删除。详见 §9。

## 1. 基线

- B0 合并提交：`e8ba384`（PR #68），CI run 43480472882 成功；本地 `dev` 已快进到该提交。
- `ads-pin.txt` 指向 ADS `cnb/dev` @ `16b99f4`，与 `.ads` 子模块记录一致。
- 工作树除用户自有的未跟踪 `tmp/` 外无改动。

## 2. 协议层现实

| 项 | 实测 |
| --- | --- |
| 协商版本 | `2025-06-18`（客户端首选值，服务端原样接受） |
| `capabilities` | `{"tools":{}}`，无 resources / prompts / logging |
| `instructions` | 服务端返回一段较长的安全说明（数据库包不可直接改文件、优先批量、去重建议） |
| 工具总数 | **62**，单页返回，**无 `nextCursor`** |
| `outputSchema` | **62 个工具全部没有**。客户端不能依赖声明式输出契约 |
| 成功信封 | `{"content":[{"type":"text","text":"<JSON>"}],"isError":false}`；本轮所有调用都没有 `structuredContent` |
| 错误信封 | `{"isError":true,"content":[{"type":"text","text":"Record not found: …"}]}`；未知工具走 JSON-RPC `-32602` |
| 响应 UUID | 大写带连字符（如 `XXXXXXXX-XXXX-…`） |

现场耗时：`initialize` ≈85 ms，`tools/list` ≈1 ms；读调用均为毫秒级。

## 3. UUID 语义（重要）

- **记录 UUID 查询区分大小写**：同一记录用大写 UUID 命中，用小写返回 `Record not found`。
- `database_uuid` 大小写不敏感：小写也能正确定位数据库。
- Forma 现在发送 `UUID.uuidString`（大写），与该行为一致；这条约束必须保留，任何"宽松转小写"的改动都会打断读路径。

## 4. 读工具实测响应形状

以下为真实返回（字段名逐字）：

| 工具 | 形状 |
| --- | --- |
| `get_databases {uuid}` | `[{uuid, rootUUID, name, comment, tagCount, is_current, is_inbox, versioning, tagging{…}, trashGroupUUID, tagsGroupUUID, incomingGroupUUID}]`；根组 UUID 与库 UUID 相同 |
| `search_records` | `{results:[{uuid, databaseUUID, databaseName, name, type, kind, location, tags, tagCount, indexed, additionDate, modificationDate, score}], offset, total, limit}` |
| `get_record_children` | `{items:[…brief record…], offset, count, total, limit}`；`limit` 缺省=剩余全部（服务端上限 1000） |
| `get_record_properties` | 扁平属性字典（uuid, databaseUUID, name, type, location, indexed, tags, 各类日期、计数、label/rating/flagged/unread…）；**仅当记录确有自定义元数据时才带 `customMetadata` 键** |
| `get_record_custom_metadata {uuid}` | 裸字典 `{identifier: value}`，**无记录或数据库标识**；无元数据时为 `{}` |
| `get_record_custom_metadata {uuids}` | `{operation, succeeded, failed, results:[{uuid, metadata}]}` |
| `get_record_parents {uuid}` | `{kind, count, primary_parent, parents}`，**无顶层 `uuid`** |
| `get_record_parents {uuids}` | `{operation, succeeded, failed, failed_uuids?, results:[{uuid, kind, primary_parent?, parents, count}]}` |
| `list_custom_metadata_fields` | `[{identifier, title, type, disabled, values?}]`；`values` 仅 set 类型有 |

## 5. 读路径的三个语义务必记住

1. **搜索不是全集**：默认排除已入回收站的记录。对同一库，`search_records` 只返回 2 条，而该库 `Trash` 组里还有 16 条同类记录（`get_record_children` 可见）。所以 **空搜索结果不能证明"不存在"**。
2. **`name:=="…"` 精确谓词实测返回 0**，而裸词（子串）命中；`query:"*"` 在目标库返回 0 条。搜索语法不可当作可靠的枚举手段，枚举应走 `get_record_children` 并按 `total` 校验分页。
3. **分页稳定**：`offset/limit` 分页的 `total` 在多次调用间一致；`offset` 超过 `total` 返回空 `results` 且保留真实 `total`。

## 6. 写工具 schema（只发现，未调用）

| 工具 | 输入 | 备注 |
| --- | --- | --- |
| `import_file` | `path`(必填, POSIX 路径), `destination`(组 UUID **或** location path), `database_uuid`, `mode`(import\|index) | **只接受路径**，不接受 file URL、不接受二进制 payload；**没有初始 metadata 参数** |
| `create_group_path` | `location`(必填, POSIX 风格路径), `database_uuid` | `idempotentHint:true`，mkidr -p 语义 |
| `set_record_custom_metadata` | `metadata`(必填, 对象), `uuid`\|`uuids`, `mode`(replace\|merge) | 见下 |
| `export_record` | `path`(必填), `uuid`\|`uuids` | 写文件系统；`destructiveHint:true` |
| `get_imported_record_path` | `uuid`\|`uuids`, `database_uuid?` | 只读，返回 `.dtBase2` 包内路径 |

`set_record_custom_metadata` 的服务端自述语义：

- 默认 **replace**（未列出的字段被丢弃）；`mode:"merge"` 为增量。
- `NSNull` 或空字符串都表示 **清空该字段**（两种 mode 相同）。
- 标识符只允许字母数字加 `?`、`.`；大小写自动归一为小写；`md` 存储前缀可省略。
- **写入不存在的标识符会被 DEVONthink 自动建成新字段**（拼写错误会污染字段表）。
- 返回 `{uuid, metadata, dropped_fields, rejection_reasons?}`；`dropped_fields` 非空表示部分成功。
- **没有任何版本号 / If-Match / 冲突检测参数**。

### 6.1 File Import 的确定答案

| 问题 | 答案 | 依据 |
| --- | --- | --- |
| 是否提供 import_file 或等价能力 | 是，工具名 `import_file` | `tools/list` |
| 输入形式 | 仅 **POSIX 路径字符串**（`path`，必填）。**不接受 file URL，不接受二进制 payload** | inputSchema |
| 能否指定目标数据库 UUID | 能（`database_uuid`） | inputSchema |
| 能否指定目标 Group UUID | 能（`destination` 接受 Group UUID **或** location path；路径形式的真实解析行为未验证） | inputSchema + 描述 |
| 能否指定初始 Metadata | **不能**。`import_file` 没有 metadata 参数，元数据只能事后用 `set_record_custom_metadata` 写 | inputSchema |
| 是否返回创建的 record UUID | **NOT_VERIFIED**（无 outputSchema，描述未声明返回值；需真实写入才能确定） | 无 outputSchema |
| 是否存在异步/延迟可见性 | **NOT_VERIFIED**（同上） | — |

### 6.2 Metadata Write 的确定答案

| 问题 | 答案 | 依据 |
| --- | --- | --- |
| 修改 Custom Metadata 的工具 | `set_record_custom_metadata` | `tools/list` |
| 是否支持部分字段更新 | 支持，`mode:"merge"`；默认 `replace` 会丢弃未列出的字段 | 描述 |
| null / 空字符串 / 缺失字段 | `NSNull` 与空字符串都表示**清空该字段**；`merge` 下未出现的键保持原值，`replace` 下被丢弃 | 描述 |
| 输入用 identifier 还是中文 Label | **identifier**（如 `projectname`）。Label 不参与写入；大小写归一为小写，`md` 前缀可省略 | 描述 |
| 是否有字段类型约束 | 服务端按字段原生类型校验；对 `set` 类型给自由文本会被拒并计入 `dropped_fields`。12 个治理字段均为 `string`，无枚举约束 | 描述 + `list_custom_metadata_fields` |
| 是否返回更新后的完整记录 | **否**。返回 `{uuid, metadata, dropped_fields, rejection_reasons?}`，不含完整属性字典；独立回读仍必须用 `get_record_properties` / `get_record_custom_metadata` | 描述 |
| 是否有冲突检测或版本条件参数 | **没有**。无 If-Match / 版本号 / 条件写 | inputSchema |

### 6.3 Identity / Group 语义的确定答案

| 问题 | 答案 |
| --- | --- |
| UUID 是否是持久记录身份 | 是（同一记录在多次调用间稳定返回同一 UUID）。跨重启/重导入的持久性**未验证** |
| Record UUID 与 Database UUID 如何绑定 | 每条记录载荷都携带 `databaseUUID`（`get_record_properties`、`children`、`search` 三处均已实测）；`database_uuid` 参数只是"加速查找"，**服务端不据此强制作用域**，必须由客户端自行校验 |
| Group UUID 与 Group path 能否互相核验 | **部分**。`get_group_tree` 给出 uuid+name；`get_record_children` 的条目带 `location`（父组路径）。但 `lookup_records{location:"/"}` 与 `{location:"/Trash/"}` 实测均返回 0 条，**路径反查 UUID 不可靠** |
| 搜索结果是否包含完整数据库身份 | 是（`databaseUUID` + `databaseName` 都在 brief 里） |
| 能否完整枚举指定 Group 的记录 | 能，用 `get_record_children` 按 `offset/limit` 翻页并以 `total` 收敛；**不要用 search 枚举**（它排除回收站） |
| 分页是否有一致性保证 | 静态数据下 `total` 与条目稳定；**没有快照隔离保证**，并发修改时的分页一致性未验证 |
| 空查询是否足以证明不存在 | **不足**。搜索排除回收站、`name:=="…"` 精确谓词实测无命中、`query:"*"` 返回 0 条，都是反例 |

## 7. 12 个受治理字段的现场定义

`list_custom_metadata_fields` 全量 33 个字段，其中启用 12 个，与 SPEC §5.2 的标识符集合**完全一致**：

| identifier | 现场 Label | 原生类型 | disabled |
| --- | --- | --- | --- |
| `projectname` | 项目名称 | string | false |
| `completionyear` | 完成年份 | string | false |
| `bidderentity` | 投标主体 | string | false |
| `department` | 业务部门 | string | false |
| `salesowner` | 销售负责人 | string | false |
| `endcustomer` | 最终客户 | string | false |
| `biddeadline` | 投标截止日期 | string | false |
| `tenderreference` | 招标编号 | string | false |
| `bsdcode` | BSD标识 | string | false |
| `documentcategory` | 文档类别 | string | false |
| `documenttype` | 文档类型 | string | false |
| `issuer` | 出具厂商 | string | false |

全部为原生 `string`，均无枚举值；只有 `status`、`format` 两个非治理字段是 set 类型。因此 `biddeadline` 的 `YYYY-MM-DD` 文本约定不涉及类型迁移，`completionyear` 也存储为字符串。

## 8. ReadOnlyClient 兼容性（三态）

现场对照 `Sources/FormaCore/DEVONthink/DEVONthinkReadOnlyClient.swift`：

| 项 | 结论 |
| --- | --- |
| 工具名 | **Compatible**（6 个白名单工具全部存在且 `readOnlyHint:true`） |
| 输入 schema | **Compatible**（`uuids` 数组形式本轮补上；其余未知约束仍失败关闭） |
| 输出 schema | **Not verified**（服务端 62 个工具都没有 outputSchema，不构成任何语义保证） |
| UUID 表示 | **Compatible**（大写查询；输出大写解析无误） |
| 数据库作用域 | **Compatible**（`get_databases{uuid}` 返回单元素且校验 `id == scope.databaseID`；跨库记录被拒绝） |
| 分页 | **Compatible**（`offset/total` 一致；搜索与 children 分别校验键名） |
| 记录属性 | **Compatible** |
| 记录父组 | **Incompatible → 已修复**：单条形态没有顶层 `uuid`，旧解析必然 `invalidResponse` |
| Metadata | **Incompatible → 已修复**：无元数据时 `get_record_properties` 省略 `customMetadata` 键，旧解析抛 `invalidResponse` |
| 原生字段定义 | **Compatible**（12 个全部解析出，含中文 Label 与 disabled 标志） |
| 错误响应 | **Compatible**（`isError` → `.refused`；JSON-RPC 错误 → `.remoteStatus`）。注：`Record not found` 被映射为 `.refused`，描述文案不准确但类型正确 |
| 超时/取消 | **Not verified**（真实服务响应过快，未触发超时路径；取消语义仅由假传输覆盖） |

两处缺陷已在独立 PR [#69](https://github.com/Skyline-Gazer/Forma/pull/69)（squash 合并为 `fa1dde6`）修复：`parents(of:)` 与 `metadata(of:)` 改用 `uuids` 批量形态，并以回显的 `uuid` 与 `succeeded/failed` 计数绑定/校验；`customMetadata` 不再从属性响应推断。该 PR 的 macOS CI（FormaCore tests / macOS app build / Benchmark smoke）全部通过。修复后对真实服务的全部读路径实测通过。

## 9. 隔离范围内的只读证据

- 本轮 Owner **未指定**隔离测试库。按既定边界，**未使用生产 `Project_Archive` 做任何记录级查询**（它只出现在全局 `get_databases` 列表里，属允许的全局发现）。
- 实际只读探测对象是 DEVONthink 自带的全局 Inbox 库：只含既有的合成 MCP harness 记录，不含业务数据；全程零写入。
- 已实测：库查找、根组、父子关系、搜索、分页一致性与 total、记录 UUID 查找、属性、12 字段定义、记录元数据回读、内容读取与导出、标准 SHA-256 获取路径。
- 明细：`get_databases`（全局列表 + 单库查询）、`get_group_tree`、`get_record_children`（分页与 total 一致性）、`get_record_parents`（单条与批量）、`search_records`（含 `group_uuid` 限定）、`lookup_records`、`get_record_properties`、`get_record_custom_metadata`（单条与批量）、`list_custom_metadata_fields`、`get_record_text`、`extract_record_content`、`get_record_duplicates`、`get_imported_record_path`、`is_running`。
- `export_record` 调用过一次：源为 Inbox 中既有的合成 harness 记录（内容为无意义短文本），目标是新建的临时目录；导出字节与库包内同一文件字节完全一致（标准 SHA-256 相同），临时目录随后删除。**没有创建、修改、移动或删除任何 DEVONthink 对象。**
- 未调用任何 `create_*` / `set_*` / `update_*` / `move_*` / `trash_*` / `import_file` / `replicate_record` / `merge_records` / `capture_*` / `ocr_record` 等写工具。
- 因此**正式库级验收（Owner 指定隔离库 + 授权 Group + 授权记录集）仍为 BLOCKED**，缺项见 §11。

## 10. 标准 SHA-256

- **没有任何工具返回哈希。** `get_record_duplicates` 内部按"内容哈希"判重，但不暴露该值，也没有官方等价性说明。
- 可用路径是取字节自行计算：
  - `export_record` 导出到文件系统（实测导出字节与库包内文件字节一致，SHA-256 相同）；
  - `get_imported_record_path` 返回 `.dtBase2` 包内路径，按只读方式读取字节自行摘要（工具自述明确警告只能读、不可改）。
- 因此 `hash_unverified` 的维持规则：**只有实际取得目标字节并本地计算，才可写标准 SHA-256；文件名/大小/元数据相同都不算。** 对"未来导入的记录，其存储字节是否等于源字节"仍是 **NOT_VERIFIED**（DEVONthink 会做格式转换，例如由文本生成 markdown 记录），必须靠 I1-B2 的源/目标字节对照来确认。

## 11. 阻塞项

| 编号 | 阻塞 | 影响 |
| --- | --- | --- |
| B1 | Owner 未指定隔离测试库 UUID / 授权 Group / 授权记录集 | 库级验收标记 BLOCKED |
| B2 | 未取得写入授权 | `import_file`、`set_record_custom_metadata` 行为全部 NOT_VERIFIED |
| B3 | 无 outputSchema + 无哈希工具 | 每个响应形状只能靠实测契约维护，schema 变更需重新探测 |
| B4 | 无版本/冲突参数 | 并发写冲突只能由 Forma 的 Ledger + 回读检测 |
| B5 | 未知元数据标识符会被自动建字段 | 写入前必须先用 `list_custom_metadata_fields` 校验标识符 |
| B6 | 搜索排除回收站/精确谓词异常 | 幂等与"不存在"判定必须走 children 枚举 + total 校验 |

## 12. 后续

1. Owner 指定隔离库并批准 `docs/I1-B2-AUTHORIZATION-PROPOSAL.md` 后，才可执行真实写入。
2. 写入验证必须包含：源/目标字节 SHA-256 对照、创建后 UUID 回读、Metadata 逐字段回读、重复执行幂等、断连与 `VERIFY_REQUIRED` 仲裁。
3. `import_file` 的真实返回形状、异步可见性、初始 metadata 注入能力，全部依赖 B2 实测，当前不得假设。

## 13. 证据位置

- 本机授权位置保留原始工件：`tools/list` 全量响应、每次只读调用摘要、schema 摘要、客户端快照、合成测试文件及其 SHA-256。
- 仓库内只放：本报告、脱敏能力快照（`docs/I1-B1-CAPABILITY-SNAPSHOT.json`）、B2 授权申请与合成测试定义。
