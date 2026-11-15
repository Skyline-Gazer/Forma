# M05 — 真实写入授权申请（待 Owner 批准）

状态：**提案，未获授权。** 在 Owner 逐条批准本文件之前，不得发起任何真实 DEVONthink 写调用，也不得执行写入中的进程终止。

- 依据：`docs/M05-PREFLIGHT.md`（执行方案与预检证据）、`docs/I1-B2-ACCEPTANCE.md`（限定范围验收）、`docs/R1-BATCH2A1-REPORT.md`（打包/诊断基线）。
- 与 R01–R03（签名、公证、发行）**无关**，不构成本轮或下一轮的任何发行授权。

## 1. 请求批准的写入范围

| 项 | 请求值 |
| --- | --- |
| 目标数据库 | **1 个可丢弃库**。建议由 Owner 新建 `Forma_M05_Sandbox`；若 Owner 选择复用现有 `Forma_I1B2_Sandbox`，需明确同意在其中的**新组**写入 |
| 目标 Group | 2 个：`Forma_M05` 与 `<run-id>`（仅本轮） |
| 记录 | **3 条**（对应超时、发送后断连、崩溃三个探针，各 1 条） |
| 允许的写工具 | `create_group_path`、`import_file`（仅 `mode=import`）、`set_record_custom_metadata`（仅 `mode=merge`） |
| Metadata 字段 | 仅 B2 已确认的 8 个 string identifier：`projectname`、`documentcategory`、`documenttype`、`issuer`、`bidderentity`、`endcustomer`、`completionyear`、`biddeadline` |
| Metadata 调用上限 | ≤ 6（每条记录 ≤1 次 merge × 最多 2 个阶段）。这是**计划级**约束：guard 校验 identifier 与目标记录但不计次，执行时按调用计数对账 |
| 合成源文件 | 3 个，仓库内脚本生成、字节固定、SHA-256 可复算；不使用任何业务文件 |
| 删除 / 移动 / trash / Replicant / 字段定义变更 | **0** |
| 生产库记录级查询 | **0** |
| 真实崩溃注入 | **1 次**，且仅限在 create 在途时终止 **Forma 进程**；不终止 DEVONthink 主程序、不终止他人会话的 MCP 子进程。此项如需与 T/D 分开批准，可单列 |

所有请求都在 `ImportWriteScope` 中编码；guard 在调用传输层之前拒绝越界请求，被拒请求不消耗预算。

## 2. 执行前置（全部满足才启动）

1. Owner 批准本文件，并书面指定目标库（新建或复用）与 run id 前缀。
2. 只读绑定通过：UUID 精确、名称精确、`is_inbox == false`、与 `Project_Archive`/全局 `Inbox` 不同、root 组一致。
3. 3 个写工具的 `inputSchema` SHA-256 与 B1/B2 基线逐字一致。
4. 3 个合成文件生成完毕，SHA-256 记录在证据目录。
5. 无其他 Forma 实例；无未解释的在途 Import。
6. `plan` 输出与预期一致（3 条 `would_execute`，0 条阻断）。

## 3. 明确的停止条件

- 任一目标校验失败、schema digest 漂移、guard 拒绝、出现预期外对象、同一操作键产生第二条记录、观测到生产库；
- 任一探针进入 `VERIFY_REQUIRED` 后，必须先完成只读回查并记录结论，才可进行下一探针；
- 出现无法解释的返回形状或计数不符时，停止并报告，不"再试一次"。

## 4. 回滚与清理

MCP 没有事务，本授权**不包含删除**。因此：

- 无回滚。出错时停止执行、保留现场、导出 Ledger 与审计。
- 3 条记录与 2 个组在实测后保留；清理必须另行授权。
- 不得用 `set_record_custom_metadata` 掩盖失败状态（例如把测试值改成看似正常的值）。

## 5. 证据与统计

必须记录：

1. 每个探针的客户端错误码（`timeout` / `disconnected`）与时间点；
2. Ledger 相位轨迹（`intent_persisted → … → verify_required`）与 `attempts`；
3. 重启后的只读回查结论（`verified` / `differs` / `unverifiable`）；
4. 真实写调用计数（按工具）与 `refusalCounts`（必须为空）；
5. 记录/组实际数量与预算对账；
6. 目标字节与源字节的标准 SHA-256。

证据仅保存在运行主机 `~/.forma/evidence/m05/`；仓库只提交脱敏报告。

## 6. 不在本次申请内

- 任何生产库写入或记录级查询；
- OneDrive hydration、真实业务文件的 Import；
- `dropped_fields` / 部分成功的真实构造（仍为 NOT_VERIFIED）；
- Replicant / 多父组（I2）；
- Developer ID 签名、公证、发行（R01–R03）；
- 自动重试、后台 Worker、定时任务。

## 7. 批准后的产出

- `docs/M05-ACCEPTANCE.md`（脱敏结果，逐项 PASS/FAIL/BLOCKED）；
- Ledger 与审计摘录（不含真实 UUID/路径）；
- 是否足以关闭 Issue #22 中"写入中崩溃"一项的结论。
