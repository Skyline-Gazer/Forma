# I1-B2 Preflight 报告（只读）

状态：**B2 Preflight Ready — Awaiting Owner Write Authorization**

结论先说：默认拒绝边界已实现并有 **14 例**拦截测试；隔离库 `Forma_I1B2_Sandbox` 已由 Owner 在 GUI 创建，并已通过只读 `get_databases` 绑定成功（名称精确、`is_inbox=false`、与生产库 UUID 不同、初始为空）。真实 UUID 只保存在本机授权位置，不入库。

本轮 MCP 写工具调用数：**0**。

## 1. 最新 dev SHA

`37ea73f`（PR #71，默认拒绝写入边界）；前序 `0ce0d38`（PR #72，B2 文档）、`db2e9d5`（PR #70，B1 报告）。`dev` 的 CI（FormaCore tests / macOS app build / Benchmark smoke）success。

## 2. DEVONthink 与 MCP 版本

| 项 | 值 |
| --- | --- |
| DEVONthink app | 4.4.2 |
| MCP bundle | `com.devon-technologies.think.mcp-server` 4.4.2 |
| serverInfo | `devonthink-mcp` 1.0.0 |
| 协议 | `2025-06-18` |
| 工具总数 | 62（36 个 `readOnlyHint:true`，0 个 outputSchema） |

## 3. 隔离库 UUID

**已绑定。** 只读 `get_databases` 发现三个库：隔离库 `Forma_I1B2_Sandbox`、DEVONthink 全局 `Inbox`（`is_inbox=true`）与生产 `Project_Archive`。

| 校验 | 结果 |
| --- | --- |
| 名称精确等于 `Forma_I1B2_Sandbox` | 是 |
| `is_inbox == false` | 是 |
| UUID 与 `Project_Archive` 不同 | 是 |
| UUID 与全局 `Inbox` 不同 | 是 |
| root Group UUID 等于库 UUID | 是 |
| `get_databases{uuid}` 只返回 1 条 | 是 |

真实 UUID、root/Trash/Inbox/Tags 组 UUID 与绑定时间只写在本机 `~/.forma/evidence/i1-b2/binding.json`，不入库。**未**用 Inbox 或其他现存业务库替代；对生产库零记录级查询。

## 4. 测试库初始状态

| 项 | 值 |
| --- | --- |
| 文档/记录数 | **0** |
| 根组直接文档数 | 0 |
| Group 总数 | 6（3 个系统组 + 3 个智能组） |
| 结构 | `Trash`、`Inbox`（库内接收组）、`Tags`，加智能组 `Duplicates`、`All PDF Documents`、`All Images` |
| 各系统组记录数 | `Trash` 0、`Inbox` 0、`Tags` 0 |
| 版本控制 | 关闭（`versioning=false`） |
| 标签 | 0 |

依据：`get_record_children{root, limit=1000}`（`total=6`，全部为 group/smart_group，无文档）、`get_group_tree{max_depth=10, include_documents=true}`（每个节点 `directDocumentCount=0`）、三个系统组各自的 children（`total=0`）。`search_records{query:"*"}` 返回 0 仅作旁证——按 B1 结论，搜索为空不能单独证明不存在。

## 5. 工具 schema digest（现场复核）

| 工具 | digest | 与 B1 一致 |
| --- | --- | --- |
| `create_group_path` | `6256d00d2755137648ed10e28fa1b946db9bc30b601feefc741b303758fd439a` | 是 |
| `import_file` | `3642cf6990596a9b7814c846a018004b4fe9694b6af35b5d2cd468a4611b0d2f` | 是 |
| `set_record_custom_metadata` | `f1aa770b370095f3c2280d8a617dbe3078eeee04da794a746ac925dd71a7fdb0` | 是 |

绑定当日再次现场复核：三项 digest 与上表逐字一致（无 schema 漂移）。

三项注解：`create_group_path` idempotent、`import_file` 非幂等、`set_record_custom_metadata` destructive+idempotent。`set_record_custom_metadata` 的 inputSchema **没有 `database_uuid` 参数**——库绑定只能靠独立回读，这一点已写入边界与提案 §4/§8。

## 6. 八个允许字段的现场校验

`list_custom_metadata_fields`（只读）：8 个 identifier 全部存在、`type=string`、未 disabled，无一被阻塞。

| identifier | type | enabled |
| --- | --- | --- |
| `projectname` | string | true |
| `documentcategory` | string | true |
| `documenttype` | string | true |
| `issuer` | string | true |
| `bidderentity` | string | true |
| `endcustomer` | string | true |
| `completionyear` | string | true |
| `biddeadline` | string | true |

现场启用字段共 12 个，其余 4 个（`department`、`salesowner`、`tenderreference`、`bsdcode`）留作"未写入字段不被改动"的对照。

## 7. 四个源文件的标准 SHA-256（重新计算）

| 文件 | 字节 | SHA-256 |
| --- | --- | --- |
| `forma-b1-probe-01.md` | 47 | `409833d4cfd51df2cc91339cf5dcc0d9d71eddbf781406f3e52e77517573973e` |
| `forma-b1-probe-02.txt` | 43 | `a6e8d35d00151ec72461b567efe3c5dd84432b8dd395d723cb703d36a748e95f` |
| `forma-b1-probe-03.csv` | 69 | `f2dc19a7443b23cc64be58cb500c533178dbf3f62650c0d73ab1623c281b1c0e` |
| `forma-b1-probe-04.png` | 75 | `ebda4d4ace3059d20d30b04f8fb1a9390f9e8bd8cd2117fca38db09ba2efa1a0` |

由 `scripts/make_i1_b2_synthetic.py` 生成；与 B1 证据目录中的清单逐字一致（diff 无差异）。绑定当日重新计算，四个值与上表逐字一致。提案值无需修订。

## 8. 实际权限白名单

由 `Sources/FormaCore/Import/ImportWriteBoundary.swift` 在代码中强制，**默认拒绝**：

| 维度 | 允许值 |
| --- | --- |
| 工具 | `create_group_path`、`import_file`、`set_record_custom_metadata`（枚举，无字符串入口） |
| 数据库 | 隔离库精确 UUID（已在 §3 绑定；真实值仅本地）。构造 scope 时填入；当前未实例化任何 scope，故不存在任何写路径 |
| Group 路径 | 等于或扩展 `Forma_I1B2/<run-id>` |
| Metadata identifier | 上述 8 个 |
| 源文件路径 | 上述 4 个规范化绝对路径 |
| 预算 | 记录 4、分组 2（授权即扣减） |
| Metadata 目标 | 必须已由**观测到的** `databaseUUID` 与 `parentPath` 证明属于本库且位于授权 Group 内 |
| `import_file` 模式 | 仅 `mode=import` |

拒绝发生在调用传输层之前；拒绝不消耗预算。

## 9. 工具调用拦截测试

`Tests/FormaCoreTests/ImportWriteBoundaryTests.swift`，14 例全部通过（本地 `swift test`：542 用例通过）：

| 用例 | 断言 |
| --- | --- |
| 复制外工具不可表达 / 未在 scope 内的工具 | 拒绝；`grantedCount == 0` |
| 他库 `lookup` / `create` | 拒绝；底层 `lookupCalls==0`、`createCalls==0` |
| 前缀碰撞 `Forma_I1B2X`、缺 run-id、他路径、空路径 | 拒绝 |
| 未批准源路径 / 无法解析路径 | 拒绝；`createCalls==0` |
| `mode=index` | 拒绝 |
| 未知 metadata identifier | 拒绝；`metadataCalls==0` |
| 未证明记录的 metadata 写入 | 拒绝；`metadataCalls==0` |
| 同库但父组在授权前缀之外的记录 | 拒绝（不作为 metadata 目标）；`metadataCalls==0` |
| 记录预算第 5 条 / 分组预算第 3 个 | 拒绝；底层计数停在上限 |
| 被拒请求不消耗预算 | 后续合法请求仍可通过 |
| 回读返回他库记录 | 整体拒绝，且不记入已证明集合 |
| 批准路径 | 底层 `create` 恰好调用一次 |

## 10. B2 真实写入步骤与停止条件

与提案 §7–§10 一致，摘要：

1. 只读 Preflight（库 UUID、8 字段、3 个 schema digest、4 个源 SHA）。
2. `create_group_path` 建 `Forma_I1B2/<run-id>`，回读组 UUID。
3. **仅导一条** `forma-b1-probe-01.md`；不假设返回形状。
4. 首条完整验收：独立回读证明（库 + 父组 + SHA）、Metadata merge 写后逐字段回读、重复执行 `SKIP_VERIFIED`。
5. 首条全通过后才继续余下三条；首条任一失败即停。

停止条件：schema digest 变化、返回形状不符、`failed_uuids` 出现、记录越界（他库/他组）、`total` 与 Ledger 不符、无法解释的错误、SHA 不一致原因不明、**边界层报出任何拒绝**。未知 Create 结果进入 `VERIFY_REQUIRED`，按提案 §8 的身份恢复路径处理，**不盲重试**；查询为空不构成重新创建的依据，重新创建必须另行作出可审计的新执行决定。

## 11. Owner Approval Required

需要 Owner：

1. ~~在 DEVONthink GUI 新建可丢弃库 `Forma_I1B2_Sandbox`~~ —— **已完成并绑定**（§3）；
2. 批准修订后的 `docs/I1-B2-AUTHORIZATION-PROPOSAL.md`（含 3 个写工具、8 个字段、4 条记录上限、冲突/断连测试、访问边界证明方式，以及 §8 的未知 Create 恢复策略）；
3. 确认本轮不授权任何自动删除。

在上述 2、3 确认之前，不构造任何写入 scope、不发起任何写调用。库已绑定但未获写授权，这是有意为之的失败关闭。
