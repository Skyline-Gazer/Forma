# R1 Mac Field Closure & M05 Authorization Gate（现场结果）

状态：**F01（缺陷 A）现场复测 PASS**；**M05-T01 TARGET_NOT_PREPARED**（`Forma_M05_Sandbox` 不存在，未创建、未复用 I1-B2 沙盒）；**T02/T03 发送边界的可观测性不成立 → NOT_VERIFIED**，未执行任何真实故障注入或写入；**真实写入仍未获授权**。

- 执行主机：真实 macOS（Darwin 27.0.1 / 26A434 / arm64 / `launchctl managername` = Aqua），DEVONthink 4.4.2 运行中。
- 基线：`dev` @ `f891819`（PR #112 merged），CI run `43714739978` success；`main` `38d4553` 未动；Issue #98 OPEN。
- 本轮 DEVONthink 写调用 **0**；未创建/修改任何记录、Group 或数据库；未连接真实写入执行路径；未执行 M05-T02/T03/T04；未启动 R01–R03；未改 `main` / ADS pin / SPEC。
- 证据原件仅在本机 `~/.forma/evidence/r1-f01/`（F01）与 `~/.forma/evidence/m05/`（T01 schema/合成文件）；本文不含真实数据库 UUID、记录 UUID 或业务路径。

## 1. F01 — 缺陷 A 现场复测（PASS）

产物：CI run `43714739978` 的 `Forma-app-adhoc.tar.gz`（未修补原件）。

| 项 | 值 |
| --- | --- |
| SHA-256 | **`28db7ba21ffd57370ff4e2b821614924d28a9dca36044b5af9028eace154fe4a`** |
| 归档结构 | 根 `Forma.app/`，资源在 `Contents/Resources/Forma_FormaCore.bundle` |
| `verify_app_bundle.sh` | **PASS**：结构、`plutil`、bundle id、必需资源、`.app` 根无 `.bundle`、`codesign --verify --strict` |
| `smoke_app.sh` | **PASS**：启动后进程存在、`alive after 5s: yes`、退出后无残留 |

复测步骤（真实 macOS 窗口会话，恢复合成 Ledger 夹具）：

| # | 检查 | 观察 | 判定 |
| --- | --- | --- | --- |
| 1 | 空表单提交后显示错误 | 打开时无错误；点 Confirm → `Enter a database UUID, a name and at least one group component.`，sheet 不关闭 | PASS |
| 2 | 非法 UUID 显示错误 | UUID = `not-a-uuid` + 名称 + 组路径 → `The database UUID is not a valid UUID.` | PASS |
| 3 | **修正为合法数据后错误立即消失** | 把 UUID 改为隔离库 UUID（尚未点 Confirm）→ 错误文本**消失**，sheet 保持打开 | **PASS（缺陷 A 修复生效）** |
| 4 | Confirm 正确更新 Read Scope | 点 Confirm → sheet 关闭；横幅 `Read scope: Forma_I1B2_Sandbox · Forma_I1B2/r1`；Recheck 变为可用 | PASS |
| 5 | Cancel 不修改已确认范围 | 重新打开后 Cancel → 横幅仍是同一范围 | PASS |
| 6 | 再次打开不保留旧错误 | 空表单提交（出现错误）→ Cancel → 重新打开：草稿为空、**无错误残留** | PASS |
| 7 | Recovery 仍只读、无自动重试 | `Recheck read-only` → `Read-only check conclusive: 1 verified`；Ledger 仍 `verify_required`、attempts **0**；无 MCP 子进程残留 | PASS |

补充事实：

- 本轮 F01 的键入使用**投递到 App 进程的键盘事件**（`CGEventKeyboardSetUnicodeString` + `postToPid`），不是 AX `setValue`。原因是本机 System Events 键入会被 Rime 输入法合成拼音（承 Issue #98 既有经验），而 `NSOpenPanel` 的文本框由 XPC 服务承载、对该投递不响应；**应用内 SwiftUI 字段**则由这条事件路径正常驱动——步骤 2→3→4 的三段观察（非法→合法→Confirm 生效）即为其驱动 SwiftUI `Binding` 的证据。
- 结束后应用退出、MCP 子进程为 0；应用数据库已还原为测试前状态（scopes 0 / import_operations 0）。

**结论：缺陷 A 的现场状态可更新为 VERIFIED（仅此一项）。** 这不构成 R1 整体 PASS，也不改变其它 NOT_VERIFIED / BLOCKED 项。

## 2. M05-T01 — 真实只读目标绑定

| 检查 | 结果 |
| --- | --- |
| DEVONthink / MCP | 4.4.2 / `devonthink-mcp 1.0.0`，protocol `2025-06-18` |
| 工具目录 | 62 个工具，与 I1-B1 基线一致（逐项比对见 §3） |
| `Forma_M05_Sandbox` | **不存在** |
| 现存数据库 | `Forma_I1B2_Sandbox`（沙盒）、`Inbox`（`is_inbox=true`）、`Project_Archive`（生产） |
| 与生产库区分 | 若目标存在也须与 `Project_Archive` / `Inbox` 不同；本轮无目标可绑定 |
| 结论 | **TARGET_NOT_PREPARED** |

按授权边界：**未创建数据库、未创建 Group、未创建记录，未复用 I1-B2 沙盒**，未执行 plan-only（没有可绑定的目标）。

## 3. 三个写工具的 schema digest 核对（只读）

方法：`tools/list` → 按 FormaCore 的规范化方式（sorted keys、无转义斜杠、紧凑 JSON）重算 `inputSchema` 的 SHA-256；先用**全部 62 个工具**与 I1-B1 基线自校，再报告三个写工具。

| 工具 | inputSchema SHA-256 | 字节 | 与基线 |
| --- | --- | --- | --- |
| `create_group_path` | `6256d00d2755137648ed10e28fa1b946db9bc30b601feefc741b303758fd439a` | 273 | 一致 |
| `import_file` | `3642cf6990596a9b7814c846a018004b4fe9694b6af35b5d2cd468a4611b0d2f` | 557 | 一致 |
| `set_record_custom_metadata` | `f1aa770b370095f3c2280d8a617dbe3078eeee04da794a746ac925dd71a7fdb0` | 632 | 一致 |

自校结果：62/62 与 I1-B1 `client-digests.json` 逐项相等（0 处漂移）。三个写工具的 `readOnlyHint` 均为 `false`（如预期）。

合成文件（字节字面量，按 `M05-PREFLIGHT.md` §12.1 重算）：

| 文件 | 字节 | SHA-256 | 与文档 |
| --- | --- | --- | --- |
| `m05-t1.md` | 64 | `5d15b3be667c4a31bc62d80bd7f71ebf677be51288f19e5e851cbc6353ce863f` | 一致 |
| `m05-d2.md` | 68 | `310042446ae4086bc1a82cb9994661d444a0dd0920d0850af192308cd8a224ff` | 一致 |
| `m05-m3.md` | 61 | `5d8285744b36803e8ccf10d95a9df1ee3d028a0605b2698acf290a6c85d4de4f` | 一致 |

## 4. 三条 plan 与预算对应关系

没有目标库，**未执行**真实 plan-only，因此没有真实 `would_execute` / `authorizationDigest` 输出。对应关系按文档固定，并与探针一一绑定：

| 探针 | 合成文件 | `import_file` | 记录 | metadata | 备注 |
| --- | --- | --- | --- | --- | --- |
| T02 超时 | `m05-t1.md` | 1 | 1 | ≤1 | 需 §5 的可观测性 |
| T03 发送后断连 | `m05-d2.md` | 1 | 1 | ≤1 | 同上 |
| T04 崩溃（未批准） | `m05-m3.md` | 1（预留） | 1（预留） | ≤1（预留） | 独立申请，不得挪用 |

合计仍为 1 库 / 2 Group / 3 记录 / 3 次 `import_file` / ≤6 次 metadata（`M05-PREFLIGHT.md` §4）。离线 QA 编排（`M05QAExecutionTests`）在 CI 中构造三条 `wouldExecute` 与预算、并断言形态；**本机无法复跑**：CLT-only 工具链缺少 `TestingMacros` 插件（`swift test` 构建失败），按仓库规则以 GitHub macOS CI 为唯一构建/测试权威（run `43714739978` 的 `FormaCore tests` success）。

## 5. T02/T03 发送边界是否可验证

**不可验证 → NOT_VERIFIED；本轮未做任何真实故障注入。**

| 阶段 | 客户端证据 | 结论 |
| --- | --- | --- |
| prepared | guard 授予计数、`refusalCounts` | 可留存 |
| request bytes written / fully framed | `MCPStdio.send` 要求写满整帧，否则立即 `.disconnected`；**但没有事件或日志** | 不可留存（只能由"超时而非断开"间接推断） |
| server may have executed | 无 | 不可观测 |
| response received | `transcript.append(tool)` 仅在成功返回后追加 | 可留存 |

补充事实：

- `timeout` 蕴含 `send()` 已返回成功（写失败会立刻以 `.disconnected` 结束），但这是结构推断；超时后连接被丢弃，之后到达的响应不可归因。
- 服务端在统一日志只输出 `[MCP] <private>`，内容不可读。
- `MCPConfiguration` 为 internal，生产初始化器硬编码 `.devonThink`，**没有可替换端点**，因此无法在不改代码的前提下插入本地 stdio relay。
- `SIGSTOP`/`SIGKILL` 可证明作用于本次自己启动的子进程（ppid），但施加时刻与"帧是否已写出"无法对齐。

结论与要求写入 `docs/M05-PREFLIGHT.md` §14（本次修正）：在具备"可留存的发送事件"或"显式端点覆盖的本地 relay"之前，不得以随机 sleep、PID 存活或客户端超时充当发送成功证据。

## 6. 是否具备真实写入的正式授权申请条件

| 条件 | 状态 |
| --- | --- |
| 目标库已准备（`Forma_M05_Sandbox`） | **不满足**（TARGET_NOT_PREPARED） |
| 三个写工具 schema 与基线一致 | 满足 |
| 合成文件与文档字节一致 | 满足 |
| 预算按探针拆分、T04 额度独立 | 满足（文档已拆分） |
| plan 输出可核对 | 无目标，未执行 |
| 发送边界可观测（T02/T03 前提） | **不满足**（NOT_VERIFIED） |
| 离线 QA 编排可复跑 | 本机不具备工具链；CI 通过 |
| 真实多进程预算争用 | **未验证** |

**判断：不具备提交"可执行"真实写入申请的条件。** 可提交的只有**方案性**申请：A（T02/T03）必须以 §5 的可观测性落地为前提，B（T04 崩溃注入）必须独立批准；两者都还需要 Owner 先准备 `Forma_M05_Sandbox` 并明确 run id 前缀。

## 7. 预算与授权复核（只读，依据 PR #112）

| 项 | 结论 | 依据 |
| --- | --- | --- |
| 生产路径使用事务化 Ledger Journal | **是** | `ImportLedger.spend` 在单个 `database.write` 内读取→校验→递增→UPSERT；`ImportWriteSessionFactory` 把 `journal: ledger` 与 `identity: authorization.digest` 注入 guard，生产与离线 QA 共用同一工厂 |
| 授权 digest 与 scope 一致 | **是** | `permit` 以 scope 的 limits 与 journal 的 identity 判定；`plan` 同时输出 `limits` 与 `authorizationDigest` |
| 新实例不能重置消费计数 | **是** | 计数按 identity 持久化；`ensureLoaded`/全量 `save` 已删除，有 journal 时只采用事务返回值 |
| 真实多进程争用 | **未验证** | `DatabaseQueue` 为单进程串行；跨进程同文件行为未测，属真实运行观察项 |
| 运行时绕过 Guard 的写调用 | **未发现** | `DEVONthinkMCPWriteTransport(` 在 `Sources/` 仅出现在运行时公开初始化器；guard 在共享工厂中构造；`ImportRecoveryCoordinator` 只持只读传输 |

本轮未消耗任何预算、未创建 journal 行（未连接写入路径）。

## 8. DEVONthink 调用统计

| 类别 | 次数 |
| --- | --- |
| 写工具调用（`import_file` / `create_group_path` / `set_record_custom_metadata` / move / trash 等） | **0** |
| 预算消费 / journal 写入 | 0 |
| 生产库记录级查询 | 0 |
| 只读调用 | `initialize`（2 次）、`tools/list`（2 次）、`get_databases`（1 次）、`get_record_children`（1 次，沙盒 `r1` 组）、应用侧回查 1 次（`1 verified`） |
| 沙盒对象变化 | 无：`r1` 组子项 JSON 摘要与上一轮完全相同（`28275fdf…`） |

## 9. 仍未验证 / 未授权

- macOS 14.x 运行时（本机仅 27.0.1）；外部卷 / iCloud 书签；Keychain 锁定态与真机可访问性复测。
- M05：T02/T03 触发点（§5）、T04 崩溃注入（未批准）、真实多进程预算争用、`import_file` 精确返回结构、`dropped_fields` 部分成功、异步可见性延迟。
- Developer ID 签名、公证、staple、干净机 Gatekeeper、DMG 与更新机制（R01–R03，未授权）。
- 不宣布 Release Ready。

## 10. Learning Loop

Issue #98 维持 **2 条**已确认观察，本轮**不新增**。

- #112 的并发预算缺陷由**安全审计**发现（设计层面：先读后整写回会丢更新），修复后由 8 路并发测试钉住；但没有"先失败的运行"作为独立失败证据——测试是修复后新增的，旧实现也没有 `spend` 入口可供同一测试复现。
- 若用受控变异人为制造失败，属于"为凑数制造失败"，与本 Pilot 的规则冲突，故不登记。
- 已确认的两条观察不变；本轮的环境事实（CLT 无法构建测试、输入法拦截键入）已在报告中记录，不重复计入。

## 11. 文档修正（本轮）

`docs/M05-PREFLIGHT.md`：

- §1 探针表改为"客户端可确认的事实"，移除"SIGSTOP ⇒ 请求已发出、可能已落库"的混淆；新增修订说明。
- §4 预算按 T02/T03/T04 三列拆分，明确 T04 预留额度未批准不得使用，总预算不变。
- §8 执行序列：T02/T03 前先确认发送边界可观测，否则不执行；T04 明确为独立申请。
- 新增 §14「发送边界的可观测性复核」：四阶段证据划分、服务端日志与服务端边界的限制、relay 注入点缺失、具备条件的前置项。

`docs/M05-AUTHORIZATION-PROPOSAL.md`：新增 §1.1「申请拆分」，把 A（T02/T03）与 B（T04）的批准、前置条件与额度分开。

`docs/ROADMAP.md`：追加本轮现场结论（见下条提交）。

## 12. 证据索引（本机）

| 路径 | 内容 |
| --- | --- |
| `~/.forma/evidence/r1-f01/artifact/` | CI 原件与 SHA-256 |
| `~/.forma/evidence/r1-f01/verify.txt`、`smoke.txt` | 结构/验签/启动 |
| `~/.forma/evidence/r1-f01/m04/` | 八步复测的 AX 转储（空表单、非法 UUID、合法后错误消失、Confirm、Cancel、重开、回查） |
| `~/.forma/evidence/m05/t01-schema-digests.json` | 62 工具 schema 自校与三个写工具 digest |
| `~/.forma/evidence/m05/synthetic/` | 三份合成文件 |
| `~/.forma/evidence/m05/r1-children-now.json` | 沙盒 `r1` 组子项，与上一轮基线摘要相同 |
