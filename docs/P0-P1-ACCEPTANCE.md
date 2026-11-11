# Forma P0 / P1 验收报告

**日期：** 2026-11-11　**范围：** P0 技术契约与基础工程 + P1 来源事实层　**集成分支：** `dev`
**判定口径：** `PASS` 为本轮实际执行并读回结果；`FAIL` 为执行后确认不符要求；`BLOCKED` 为缺少凭据、环境或授权而无法执行；`NOT_VERIFIED` 为已实现但缺少现场证据。Mock 与单元测试不记为现场验证。

## 1. 交付与集成

| PR | 内容 | 合并提交 | 合并前 GitHub Actions（macos-15 + Xcode 26.3） |
|---|---|---|---|
| #25 | ADS 固定 SHA 子模块、`ads-pin.txt`、`AGENTS.md`、CNB 评审拓扑、`scripts/` 校验器 | `967b2e2` | tests 1m30s、app build 1m15s `pass`（run 42958695278） |
| #27 | FormaCore：来源注册、扫描、身份、snapshot.v1、按需 SHA、PDF/DOCX/XLSX 证据 | `4aa8e06` | tests 1m12s `pass`（run 42947948920，该 PR 引入单任务 CI） |
| #28 | DEVONthink MCP 只读客户端、OpenAI/Anthropic 探针、能力契约证据 | `844ade3` | tests 1m8s `pass`（run 42948504628） |
| #30 | 原生 SwiftUI Workspace 与 Connections 面板（`FormaApp` SwiftPM 可执行包） | `4a609ef` | tests 1m42s、app build 1m32s `pass`（run 42950294537） |
| #31 | CNB 评审发现的 ZIP 容器与身份契约整改 | `ee13ee8` | tests 1m33s、app build 2m3s `pass`（run 42958955100，head `9ac3f09`）；同一 head 的 CNB 评审结论 `passed`，0 发现 |
| #32 | P0/P1 验收报告与文档索引 | `f8499a1` | tests 1m23s、app build 1m11s `pass`（run 42960026866） |
| #33 | CNB 评审台账更正（真实运行时间与 FormaCore 复审记录） | `42dda09` | tests 1m26s、app build 1m22s `pass`（run 42960728974） |
| #34 | ADS 消费者接入与 CNB 评审验收报告（docs/ADS-CNB-ACCEPTANCE.md） | 本 PR 合并提交 | tests 1m29s、app build 1m6s `pass`（run 42961011990） |

工程与依赖：Swift 6（`swiftLanguageModes: [.v6]`）、macOS 14 部署目标、GRDB 7.8.0 与 ZIPFoundation 0.9.20 以 `exact` 锁定并提交 `Package.resolved`。GUI 是独立的 SwiftPM 可执行包，`FormaApp/.build` 不进入根包测试图，因此仅有 Command Line Tools 的机器仍可运行核心测试。

CI：`macos-15` 固定 `DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer`，不使用 `macos-latest`；权限 `contents: read`；不上传 artifacts；不访问 DEVONthink、OneDrive 或真实 AI API。

## 2. P0 结果

| 项目 | 状态 | 证据 |
|---|---|---|
| P0.1 原生工程可编译 | **PASS** | 上表 4 个 PR 的 `macOS app build` 任务在 Xcode 26.3 下全部成功 |
| P0.1 结构化错误与诊断 | **PASS** | 统一 `FormaError`（16 类语义）；全仓库只有一个日志调用点，内容为操作名与错误码，不含路径、正文、客户名或密钥 |
| P0.2 MCP 进程与协议 | **PASS（发现层）** | 本机 DEVONthink 4.4.2 实际 stdio 握手：protocol `2025-06-18`、server `devonthink-mcp 1.0.0`、62 个工具描述符；输入 Schema 规范化摘要 `838b1b98bdacf9970f534da77cbb9fd4a9cd665e95afebf173b607191fcd2df6` |
| P0.2 `get_record_parents` 现场核查 | **PASS（已声明）/ NOT_VERIFIED（响应语义）** | 当前版本清单含该工具，输入为 `uuid`/`uuids` ≤500、`database_uuid`、`kind ∈ groups,tags,both`；未对任何库发起查询，故不宣称父组结果已验证。SPEC §7 与固定提交审计（`SUPPORTED_UNTESTED`）的差异保留在代码注释与文档中 |
| P0.2 隔离测试库只读查询 | **BLOCKED** | 本机无可确认获授权的隔离测试数据库 UUID；未发起任何数据工具调用。生产 Project_Archive 未被访问，写入调用数为 0 |
| P0.2 12 字段现场核对 | **BLOCKED** | 字段定义查询是应用级 API（无数据库范围参数），需显式声明“本次实例仅含隔离库”；未取得该环境。Identifier 取自冻结 SPEC，未推测中文 Label 或原生类型 |
| P0.3 Provider 契约 | **PASS（契约）/ BLOCKED（真实调用）** | 覆盖两家原生端点请求体、原生结构化输出、本地闭集 Schema 校验（16 组非法输出全部拒绝）、token/延迟/模型 ID 遥测、Keychain 存储与当次外发同意；环境无 `OPENAI_API_KEY`/`ANTHROPIC_API_KEY`，Keychain 无 Forma 条目，未发起真实请求 |
| P0.4 三格式抽取 | **PASS** | 真实生成并回查的 PDF/DOCX/XLSX 定位（页码 + UTF-16 半开区间、部件 + 段落序号、工作表 + 单元格 + 公式/缓存值）；`ok / truncated / unavailable / encrypted / corrupt / hydration_pending / changed_during_read` 均有分支；未读取的文件不产出证据 |

## 3. P1 结果

| 项目 | 状态 | 证据（含实测规模） |
|---|---|---|
| P1.1 递归扫描与统计 | **PASS** | 合成项目树 10,000 文件 / 1,569 目录 / 192,906,752 字节：首次扫描 2.98s，第二次 1.53s，第三次 1.50s（Apple M1 Pro，macOS 27.0.1，APFS 大小写不敏感）；扩展名分布 8 类；工作区 SQLite 约 9.4 MB |
| P1.1 OneDrive 占位不强制下载 | **PASS（判定路径）/ NOT_VERIFIED（真实云文件）** | 扫描只用 `fstatat` 元数据；`SF_DATALESS` 与 File Provider 域判定相互独立；本机无已授权 OneDrive 目录，真实云端行为未现场验证 |
| P1.1 可取消与不完整扫描恢复 | **PASS** | 取消、中断、权限失败均落持久状态；非 `complete` 状态不批量标记 `missing` |
| P1.2 身份稳定性 | **PASS** | 同一来源连续扫描并重启进程后，10,000 条 `source_id` 集合完全一致（基准程序断言 `identicalIDSet=true`）；单测覆盖重启、改名、移动、同路径替换、硬链接、父子根重叠双向顺序、越根符号链接、Unicode 与大小写卷语义 |
| P1.2 移动与替换不误合并 | **PASS** | 仅当“同设备 + 同对象键 + 唯一一对一候选 + 旧路径本轮不再被占用 + 旧条目为 present”才续用身份并写 `path_history`；仅 inode 相同或仅 SHA 相同只生成候选关系，不改身份；折叠同一路径下的拼写差异复用身份并版本化快照 |
| P1.3 snapshot.v1 确定性 | **PASS** | PLAN §4.2 八字段固定顺序规范 JSON → SHA-256；同输入同指纹；内容变化递增 `source_version` 并新增不可变快照修订；弱快照→SHA-256 强快照以新修订升级，旧绑定失效；hydration 状态独立存储，占位标志变化不判为内容变化 |
| P1.3 按需流式 SHA | **PASS** | 1 MiB 缓冲流式计算；单文件抽样哈希 10.9 ms；`hash(for:)` 对超过 64 MiB 抽取预算的文件仍可哈希，`evidence(for:)` 在该情况下返回 `truncated` 且不读取内容 |
| P1.4 Evidence Extractor | **PASS** | 统一入口输出可定位片段；预算：输入 64 MiB、ZIP 条目 2,048、展开 64 MiB、单 XML 部件 8 MiB、PDF 前 3 页 / 12,000 UTF-16、DOCX 12,000、XLSX 每表 200 单元格 / 全簿 2,000 / 32,000 字符；ZIP64 与损坏容器在触库前失败关闭 |
| P1.5 最小 GUI | **PASS（编译）/ NOT_VERIFIED（人工交互）** | SwiftUI 源码在固定 Xcode 26.3 下编译通过；本机仅有 Command Line Tools（缺 `SwiftUIMacros`），无法构建 `.app` 并驱动文件选择器，因此 GUI 交互与重启后的可视状态未做人工验证。选择目录、扫描、清单/统计/问题、文件详情、证据片段、MCP 与 Provider 面板、SQLite 重启恢复这些行为在核心层已有测试证明 |

## 4. 评审与安全边界

- **DEVONthink：** Prototype 阶段零写入；无写客户端，无任意工具名透传；调用前按现场输入 Schema 校验，响应再校验数据库与记录身份，越权、跨库或身份不符在发送前或返回前失败关闭。
- **不可信文档内容：** ZIP 路径穿越、符号链接条目、XML DTD/外部实体、越出包根与百分号编码遍历关系目标、伪造条目数、跨越下一本地头的数据区间，均有用例证明被拒绝，而不是静默降级或空成功。
- **本地数据保护：** 工作区 SQLite 与 `-wal`/`-shm` 侧文件为 `0600`，父目录 `0700`。
- **公开仓库内容：** 仅合成或匿名示例；无客户信息、真实路径、报价、UUID 账本或 API 密钥。
- **Provider：** 每次外发需显式同意，切换 Provider 复位；Prompt 与响应正文不持久化；密钥只在 Keychain。

## 5. 已知限制

1. **三项现场验证 BLOCKED：** 隔离 DEVONthink 测试库 UUID、两个 Provider 凭据与首次外发授权、已授权 OneDrive 目录。这是环境缺口，不是代码缺口。
2. **本机工具链：** Command Line Tools 无 SwiftUI 与 Swift Testing 宏插件，且在增量重建测试目标时偶发丢失 `TestingMacros`，需全新 scratch 目录；因此本地只做全量重建验证，CI 为权威构建环境。GUI 人工交互验证需要安装完整 Xcode。
3. **P2/P3 未开始：** 项目上下文、双 Profile、Manifest/Validator、独立评测集（目标 ≥150 条金标准）、混淆矩阵与脱敏判别力对照均未实施，本文件不含任何映射质量结论。
4. **发行：** 签名、公证、沙盒、 entitlements 与退出恢复属于 R1；本轮只保证开发构建可编译。
5. **ZIP64：** 归档级 ZIP64 结束记录会让 ZIPFoundation 0.9.20 以不可捕获的 Range 前置条件崩溃，条目级 ZIP64 在解包时同样崩溃，因此 Forma 在触库前统一判为 `unsupported`。若后续要支持超大 Office 包，需要替换容器读取实现而不是放宽该判定。

## 6. 是否具备进入 P2 的技术条件

**具备，另需两项前置输入。** 已具备：可编译的原生工程与固定 CI、持久化来源身份与快照失效语义、三格式可定位证据抽取、统一错误与诊断隐私边界、只读 MCP 客户端与 Provider 契约层、评审发现的可执行回归证据。进入 Mapping Engine 前仍需要：

1. 隔离 DEVONthink 测试库 UUID（使 V1 只读闭环与 V3 的 12 字段现场核对从 BLOCKED 变为可执行）；
2. 两个 Provider 的凭据与首次外发授权（使 V4 的真实结构化输出、容错差异与 token/延迟/成本测量可执行）。

两项都不阻塞纯本地部分开工：Profile/Schema 数据化、Context Builder、Evidence 注册表、Validator 与 Manifest 快照绑定可以先行实现并在本地测试。
