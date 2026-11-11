# P0 能力契约现场证据

**执行日期：** 2026-11-11  **执行环境：** 本地 macOS（Apple Silicon）开发构建，非 CI；CI 不接触 DEVONthink、OneDrive 或真实 AI API。

本文件只记录接口契约事实与状态，不包含任何记录内容、客户信息、内部路径或业务清单。

## V1 DEVONthink MCP

| 项 | 实测结果 | 状态 |
|---|---|---|
| 可执行文件 | `DEVONthink.app/Contents/Library/LoginItems/DEVONthink MCP.app/Contents/MacOS/DEVONthink MCP --stdio` 存在且可启动 | PASS |
| DEVONthink 版本 | 4.4.2 | PASS |
| 协议协商 | 请求 `2025-06-18`，服务器返回 `2025-06-18` | PASS |
| 服务器标识 | `devonthink-mcp`，版本 `1.0.0` | PASS |
| 工具发现 | 一次分页会话取得 62 个工具描述符，全部 `inputSchema.type=object`，无 `outputSchema`，候选只读工具带 `annotations.readOnlyHint=true`、`openWorldHint=false` | PASS |
| 工具清单摘要 | 描述符（名称 + 规范化 inputSchema）SHA-256 `838b1b98bdacf9970f534da77cbb9fd4a9cd665e95afebf173b607191fcd2df6` | PASS |
| `get_record_parents` | 已声明存在；输入为 `uuid`/`uuids`(≤500)/`database_uuid`/`kind ∈ groups,tags,both` | SUPPORTED / LIVE_QUERY_NOT_VERIFIED |
| 其余候选只读工具输入契约 | `search_records` 必含 `query`，可选 `database_uuid`/`group_uuid`/`limit` 1–1000/`offset` ≥0/`fields`/`sort`；`get_group_tree` 与 `get_record_children` 必含 `uuid`；`get_databases`/`get_record_properties`/`get_record_custom_metadata` 接受 `uuid`/`uuids`/`database_uuid`；`list_custom_metadata_fields` 仅 `include_disabled`，**无数据库范围参数** | PASS（结构）/ 响应语义 NOT_VERIFIED |

历史差异处理：固定参考提交的能力审计把 `get_record_parents` 记为 `SUPPORTED_UNTESTED`，而 SPEC §7 视其为已验证。本轮只确认“当前版本已声明该工具”，**未**确认其响应结构，因此 Forma 在该工具返回结构与已核实契约一致前不得宣称多父组支持已完成。

`list_custom_metadata_fields` 无库范围参数，属于应用级查询。Forma 只有在调用方显式声明本次 DEVONthink 实例仅包含隔离测试库时才允许调用；否则拒绝。未观察到任何响应封装格式，因此响应侧解析保持保守并失败即关闭。

**未执行项（BLOCKED）：** 隔离测试数据库的搜索、属性、父组与 12 字段现场核对。原因：本机无可确认的、获授权用于 Prototype 查询的隔离测试数据库标识；未向用户索取该标识前不发起任何数据工具调用。生产 Project_Archive 未被访问，写入调用数为 0。

## V3 12 个 Custom Metadata 字段

字段 Identifier 采用冻结 SPEC §5.2 的 12 个英文标识（`projectname`…`issuer`）。现场中文 Label、原生数据类型、枚举与空值表示需要隔离库只读核对；本轮未取得该环境，状态为 **BLOCKED**，Forma 不推测、不创建、不重命名字段。

## V4 AI Provider 探针

| 项 | 实测结果 | 状态 |
|---|---|---|
| 请求构造 | OpenAI `/v1/responses` 与 Anthropic `/v1/messages` 原生端点及各自结构化输出请求体；测试对方法、URL、鉴权头与请求体结构断言 | PASS（契约） |
| 本地 Schema 校验 | 闭集对象、必填字段、枚举、JSON 原生 boolean；16 组非法输出样本被拒绝 | PASS |
| 凭据存放 | macOS Keychain generic password，service `com.skyline-gazer.forma.provider-api-key`，account 为 provider | 已实现 / 现场写入 NOT_VERIFIED |
| 外发门禁 | 未显式同意不发出请求；同意仅对单次运行有效，切换 Provider 即复位 | PASS |
| 真实 API 调用 | 运行环境无 `OPENAI_API_KEY`/`ANTHROPIC_API_KEY`，Keychain 中无 Forma 条目；未发起任何真实请求 | **BLOCKED** |

真实验证缺失项：实际模型 ID 可用性、结构化输出稳定性、第二 Provider 的容错差异、token/延迟与计价数据。以上在项目内勾选外发授权并提供凭据后可现场复跑，Mock 结果不计为真实验证。

## V2 文档抽取

真实生成并通过定位回查的 PDF、DOCX、XLSX 样本已在单元测试覆盖（页码 + UTF-16 区间、部件 + 段落序号、工作表 + 单元格 + 公式/缓存值），加密、损坏、ZIP 越界、XML 实体、预算截断与读中变更均有分支。真实 OneDrive File Provider 云端占位文件的在线取样仍为 **NOT_VERIFIED**（本机未挂载已授权 OneDrive 目录），代码路径以 `SF_DATALESS`/`ubiquitousItemDownloadingStatus` 判定并返回 `hydration_pending`，不强制下载。

## 测试替身

`MCPTests` 使用真实 stdio 子进程假对端（换行分帧 JSON-RPC、stderr 分离、乱序与超时注入），`ProviderTests` 使用 `URLProtocol` 假传输。两者均不访问外部服务，其结果只证明客户端契约与错误分类，不记为真实 MCP/Provider 现场验证。

## 依赖选型：Draft 2020-12 JSON Schema 实现

PLAN §3 与 §12 要求为工件校验选定一个成熟 Swift JSON Schema 实现并锁定版本，且明确不得用 Codable 解码代替 Schema 验证。P0 未引入该依赖，本轮以真实构建探针固定。

| 候选 | 结论 | 依据 |
|---|---|---|
| `ajevans99/swift-json-schema` `0.14.2`（MIT，产品 `JSONSchema`） | **不采用** | 关键字覆盖本身满足要求，但其清单声明 swift-syntax 依赖；进入依赖图后本机 Command Line Tools 无法解析 swift-testing 的 `TestingMacros` 插件，`swift test` 直接编译失败 |
| `objecthub/swift-dynamicjson` `2.0.1`（Apache-2.0，产品 `DynamicJSON`） | **采用** | 零传递依赖、`.macOS(.v14)`、Swift 6 语言模式、Draft 2020-12 完整词表；与 GRDB 7.8.0 + ZIPFoundation 0.9.20 + 资源包同图构建并通过全部单测 |
| `kylef/JSONSchema.swift` | 不采用 | 上游 README 自述 2019-09/2020-12 支持不完整，2022 年后无发布，仅 Swift 5 模式 |
| `mattt/JSONSchema`、`kevinhermawan/swift-json-schema` | 不采用 | 只提供 Schema 模型，不做实例校验，等于没有验证 |

复现控制（同一台机器、同一 Command Line Tools 6.4）：最小包 A = 仅 `swift-json-schema` → swift-testing 测试可编译；最小包 B = GRDB + ZIPFoundation + `swift-json-schema` + 资源 → `plugin for module 'TestingMacros' not found`；最小包 C = GRDB + ZIPFoundation + `swift-dynamicjson` + 资源 → 通过。因此结论是依赖图组合触发，不是 Forma 代码差异。

**顺带登记的既有工具链缺陷：** 即便采用 C 组合，本机 `swift test` 仍会间歇性出现同一 `TestingMacros` 插件解析失败（同一命令重跑即恢复），与 P1 报告记录的现象一致。本轮采用「全新 scratch 路径 + 失败重试」作为本地验证方式，CI（Xcode 26.3）仍是唯一权威构建环境。

采用 DynamicJSON 后仍存在的规范陷阱，已在 `ArtifactSchemaValidator` 内以加载期规则封堵，并有对应测试：

1. 未知关键字按规范被忽略。拼错的 `additionalProperties` 会静默留下开放对象，因此加载时按关键字白名单遍历 Schema；`properties` 存在而 `additionalProperties` 不为 `false` 的 Schema 一律拒绝加载。
2. `format` 在 2020-12 默认只是注解，且只有固定名称会被断言。Forma 的工件 Schema 禁用 `format`，改用始终断言的 `pattern`；dialect 仍以 `validateFormat` 装载，避免规则静默失效。
3. `"required": "name"` 这类畸形取值会被求值为空需求列表而放行，因此 `required`/`enum`/`properties` 的形态在加载期显式检查。
4. 该库未公开元 Schema 校验入口，故上述形态检查由 Forma 侧规则承担；这一限制记录于此，不当作已通过元 Schema 验证。

本地实测：引入 `swift-json-schema` 时 `swift package resolve` 42.2s 且解析出 swift-collections、swift-syntax；改用 DynamicJSON 后依赖图仅 3 个 checkout。

## 失误记录

1. 早期一次文档 PR 在检查仍为 pending 时合并（已在 `docs/ADS-CNB-ACCEPTANCE.md` 记录，后续 PR 改为「两个检查全绿才合并」）。
2. 依赖调研子代理曾声称上游 README 含注入文本；直接抓取 `ajevans99/swift-json-schema` 与 `objecthub/swift-dynamicjson` 的 README 复核后确认不存在该内容，故不作为事实采纳。
