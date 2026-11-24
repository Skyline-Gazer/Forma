# ADR：Provider P0 —— 可配置的 OpenAI-compatible 端点

> 状态：已接受（实现随本分支）。
> 关联：Issue #11（Provider 能力边界）、`docs/PRIVACY-EGRESS-CONTRACT.md`、PLAN §6.2/§8.3。
> 本 ADR 不改 SPEC：SPEC 冻结的产品语义（预览不是收据、每次发送一个授权、无静默云外发）在这里全部保持。

## 背景

Forma 此前只认识两个 Provider：OpenAI Responses 与 Anthropic Messages，端点硬编码。
用户需要一个能在本机（Ollama 类）或自有中继服务器上跑映射的选项，同时不能稀释既有外发契约。

## 协议事实矩阵

| 事实 | OpenAI Responses | Anthropic Messages | OpenAI Chat Completions（本 ADR 新增） | Jev / System One |
| --- | --- | --- | --- | --- |
| 端点 | `https://api.openai.com/v1/responses`（硬编码） | `https://api.anthropic.com/v1/messages`（硬编码） | 用户配置的 Base URL 规范化后的 `<base>/chat/completions`，单条精确值进 scope | 未验证 |
| 认证 | `Authorization: Bearer` | `x-api-key` + `anthropic-version: 2023-06-01` | `Authorization: Bearer`（不带任何 anthropic 头） | 未验证 |
| 结构化输出 | `text.format` = `json_schema` + `strict` | `output_config.format` | `response_format.json_schema` 嵌套对象 + `strict: true` | 未验证 |
| 完成/截断/拒答 | `status completed/incomplete` + `incomplete_details.reason` | `stop_reason end_turn/refusal/max_tokens` | `finish_reason stop/length/content_filter` + `message.refusal` | 未验证 |
| 用量 | `input_tokens`/`output_tokens`/`input_tokens_details.cached_tokens` | `input_tokens`/`output_tokens`/两个 cache 字段 | `prompt_tokens`/`completion_tokens`/`prompt_tokens_details.cached_tokens` | 未验证 |
| 不保留服务端数据 | `store:false` 强制 | Messages API 本身无 store 字段（未发送） | Chat Completions 无 store 字段；绝不发送 Responses-only 字段 | 未验证 |

OpenAI Responses / Chat Completions、Anthropic Messages 的字段名以上述官方文档口径核对为协议事实。
**Jev/System One：本仓库无任何引用，公开权威资料未能在离线 devbox 上完成逐条核对；状态为
NOT_VERIFIED，不实现、不接线、不 PoC。** 任何后续接入必须先补齐本矩阵的事实核对。

## 决策

1. **新 provider，而不是新端点字符串。** `ProbeProvider.openAICompatible = "openai-compatible"`。
   协议相同、主机不同，意味着 scope 不同、Keychain 账户不同（account 即 rawValue，天然隔离
   api.openai.com 的凭据）、能力探测必须按端点重跑（structured output 是逐服务器能力，不是继承保证）。
2. **端点只有一个真源。** `EgressEndpoint.target(provider:customBaseURL:)` 把 Base URL 规范化为完整
   Chat Completions URL：必须 https，仅回环（`127.0.0.0/8`、`localhost`、`::1`，按字面判定而非 DNS）允许
   http；拒绝 userinfo/query/fragment；`/v1` 或裸主机补全为 `/v1/chat/completions`；已含操作路径保留；
   其它路径是配置错误而不是猜测。grant、ticket、实际请求三方比对同一字符串。
3. **`.custom(URL)` 进 scope，模式随主机字面。** 回环 = `.local`：gate 不消费云端许可开关，但仍需精确
   目标的独立授权；公网 = `.cloud`：仍受 `allowCloud` 前置。换服务器 = `endpointMismatch`，授权绝不跨主机复用。
4. **严格 json_schema，无降级。** 服务器不支持时探测得到 400，映射得到 `remoteStatus`；不做
   `json_object`/提示词回退。缺失配置/模型 ID 在构建 grant 之前失败（`.incompatible`），UI 文案必须可操作。
5. **probe 与 mapping 共用一份配置。** `WorkspaceModel`（含新增 `customBaseURL`，UserDefaults
   `mappingCustomBaseURL`）上移到 `FormaApplicationState`；Settings 探测面板不再持有独立的
   `@AppStorage` 探测模型 ID —— 那正是漂移的旧根因。映射 run 的 endpoint 从 grant scope 读出，
   客户端参数里不存在第二个 URL 入口。
6. **重定向照旧整体拒绝**，凭据不会因 3xx 走第二跳；`response()` 发送前的 URL==ticket.endpoint
   复核对 `.custom` 同样生效。

## 备选与拒绝理由

- *把 compatible 当 OpenAI 的 URL 变体*：scope/凭据/能力三处都会撒谎，拒绝。
- *允许 http 出回环以外*：把私档文件名与摘录送进明文链路，拒绝。
- *按 DNS 解析结果判定本地*：TOCTOU + 语义漂移，按字面主机判定，拒绝。
- *每个 provider 一个 Base URL 表*：P0 只需要一条；一条即一个 scope，UI 与 gate 都更简单。将来要多端点时
  扩 `EgressEndpoint`，而不是绕开它。
- *探测沿用独立模型 ID 存储*：#144 记录的正是这种漂移，拒绝并已在 UI 层消除。

## 后果

- `networkCases` 增加第三个元素；以 `networkCases` 参数化的套件自动覆盖新 provider（本轮已补分支）。
- Manifest/报告里 `modelProvider` 为字符串，新 rawValue 无需 schema 变更。
- 真机验收不变：DevBox 只能证协议形状与 gate 行为；对真实 compatible 服务器的端到端调用需要
  显式出网授权 + 安全凭据 + 合成数据，仍属 BLOCKED。
