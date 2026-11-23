# Forma — macOS 现场验证待办（MACOS-VALIDATION-BACKLOG）

> 状态：随 DevBox-First 开发（2026-11-12）建立。
> 本文登记**必须在真实 macOS / 真实 Apple 框架 / 真实 DEVONthink / 真实 OneDrive 才能确认的验证项**。
> DevBox（Ubuntu 24.04）上完成的部分写在各项的"已在 DevBox 完成"里；`docs/ROADMAP.md` 已有的授权边界不被本文改变，本文也不构成任何一项的通过声明。
> 三种状态不得混用：**DevBox Completed**（已写码/已测）、**macOS CI Verified**（GitHub macOS Runner 编译与单测通过）、**macOS Integration Deferred**（本文登记的现场验证，未做）。

## 0. 为什么 Linux 不能验证

| 依赖 | 出现位置 | 后果 |
| --- | --- | --- |
| `CryptoKit` | `EvidenceRegistry`、`SourceStore`、`MappingPrompt`、`MappingEngine`、`ManifestExport`、`DEVONthinkReadOnlyClient` | Linux 上无此框架，整包无法编译 |
| `Security`（Keychain） | `ProviderKeyStore`、`SourceWorkspace` | 凭据存取行为无法在 DevBox 复现 |
| `PDFKit` / `Darwin` | `EvidenceExtractor`、`SourceFilesystem`、`SourceEvidenceReader` | 真实 PDF 抽取路径无法执行 |
| `CoreFoundation` / `OSLog` | `ProviderTransport`、`Diagnostics` | 无等价运行时 |
| SwiftUI / AppKit | `FormaApp` | 无 GUI |

结论：**Linux 上不存在"整包 `swift test` 通过"这个 Gate**，也不应为了绿灯拆散现有架构（DevBox-First 指令 §7）。权威自动化验证是 GitHub macOS Runner（macOS 15 + Xcode 26.3 + Swift 6），它不属于本文延后的现场验证。

## 1. 汇总

| # | 项目 | 关联 | 当前状态 | 阻塞条件 |
| --- | --- | --- | --- | --- |
| M1 | 真实 DEVONthink MCP 能力与版本核验 | #10 / P0 | **Partially verified**（2026-11-14，I1-B1 现场探测完成） | 剩余：分页路径与跨版本漂移；读写范围仅限本轮授权 |
| M2 | Keychain 与原生权限行为 | #18 / P2 | Deferred | 真实 macOS 会话 |
| M3 | PDFKit 实际抽取兼容性 | #13 / P1 | Deferred | 真实文档夹具 |
| M4 | OneDrive SF_DATALESS / hydration / 书签恢复 | #13 / P1 | Deferred | 授权 OneDrive 目录 |
| M5 | SwiftUI 交互与真实 GUI 验证 | #17 #18 / P2 | Deferred | 人工交互 |
| M6 | Import 真实隔离库写入与崩溃恢复 | #21 #22 / I1 | **Verified（Limited Scope）**（2026-11-14，I1-B2）；响应前断连、写入中崩溃、partial success 仍 Deferred | 新写预算 / 真实崩溃注入 / 部分成功授权 |
| M7 | Developer ID 签名、公证与独立发行 | #24 / R1 | Deferred（未授权） | 证书与分发决策 |
| M8 | Mac App Store 沙盒兼容性 | #52 / R1 | Deferred（渠道未定） | 重新选择该渠道 |
| M9 | 10,000 文件真实扫描性能验收 | #20 / P3-A | Deferred | 真实目录 + 硬件记录 |
| M10 | 真实 Provider 外发授权、Keychain 与日志脱敏现场核验 | #20 / P3-A + P3-B | Deferred（部分未授权） | Provider 凭据、外发授权、真实 macOS 会话 |
|M11|Import Eligibility 生产接入与真实目录误排除复核|#51 / P3-A|**Implemented, default off**；现场 = **`MACOS_SYNTHETIC_PARTIAL`**（2026-11-17 Mac 执行 30/30 PASS，Owner 提供证据；B3 本地未验证/CI PASS、A8b 内存未测量）|真实目录与人工复核；默认启用需 Owner 再确认；切片 5 未授权|
|M12|D1 统一 App Shell 的窗口、布局、工具栏与 VoiceOver 现场核验|#150 #153 / Phase 2|Deferred（PR #157：代码与确定性 Presentation 测试已入 CI）|Owner Mac 人工交互（#153/M0 批次）|

## 2. 各项明细

### M1 真实 DEVONthink MCP 能力与版本核验

- **关联**：Issue #10（E0 / P0）。
- **已在 DevBox 完成**：`DEVONthinkReadOnlyClient` 的请求/响应编解码、`MCPStdio` 的子进程边界与超时、12 字段契约的类型与只读方法清单；`Tests/FormaCoreTests/MCPTests.swift` 用假传输覆盖了协议层。
- **macOS 现场完成（2026-11-14，I1-B1/B2）**：DEVONthink 4.4.2 + MCP 4.4.2（`devonthink-mcp` 1.0.0，协议 `2025-06-18`，`--stdio`）；`initialize`/`tools/list`（62 工具、单页无 `nextCursor`、全部无 `outputSchema`）；读工具真实响应形状、UUID 大小写敏感性、`get_record_parents`/`get_record_custom_metadata` 的批量封装均已记录，见 `docs/I1-B1-CAPABILITY-DISCOVERY.md`。
- **仍未验证**：跨 DEVONthink/MCP 版本的行为漂移（只测过 4.4.2）；`tools/list` 分页路径（现场未出现第二页，分页分支只有假传输覆盖）。
- **所需权限/资源**：只读访问；不得使用生产 `Project_Archive`（991 条记录不可修改）。
- **通过条件**：字段级对照表存在、未确认项显式标记 `unverified`、且无写入调用。
- **当前状态**：只读部分已验证；剩余项随 DEVONthink 升级复核，不阻塞 I1 收尾。

### M2 Apple Keychain 与原生权限行为

- **关联**：Issue #18（E3 / P2）。
- **已在 DevBox 完成**：`ProviderKeyStore` 的协议与错误映射、`ProviderTransport.validKey`/`validModelID` 的输入校验、日志不落密钥的约束与测试。
- **为什么无法在 Linux 验证**：`Security` 框架不存在；Keychain 的 ACL、锁定态、`kSecAttrAccessible` 语义只能在 macOS 观察。
- **需要**：macOS 14+，真实用户会话（含锁屏/解锁切换）。
- **所需权限/资源**：无沙盒/沙盒两种签名状态各一次；一个测试用 Provider 密钥（可撤销）。
- **测试步骤**：保存 → 读取 → 锁屏后读取 → 删除 → 读取；观察错误码与 UI 提示。
- **预期证据**：每步的实际返回与用户可见提示。
- **通过条件**：凭据不落日志、不落明文文件；锁定态失败可读且不泄漏存在性。
- **当前阻塞**：无 macOS 会话。

### M3 PDFKit 实际抽取兼容性

- **关联**：Issue #13（E1 / P1）。
- **已在 DevBox 完成**：`EvidenceLocator`（page/characterRange）、`OfficePackage`/`XLSXEvidence`/`DOCXEvidence` 的 zip/XML 路径、证据注册表的 id 派生与快照绑定；合成 zip 夹具在 macOS CI 覆盖。
- **为什么无法在 Linux 验证**：`import PDFKit`；真实 PDF 的文本层、扫描件、加密件只能在 macOS 观察。
- **需要**：macOS 14+；真实归档 PDF 的脱敏子集（含扫描件与加密件各至少一份）。
- **所需权限/资源**：只读目录；不得把真实正文提交仓库。
- **测试步骤**：抽取 → 证据 locator 回读 → 加密/损坏件的失败记录 → 快照变更后的失效路径。
- **预期证据**：每类文件的抽取状态、locator 可回读性、失败原因记录。
- **通过条件**：可抽取件有正文证据；不可抽取件有明确的 `extractionStatus` 与拒判原因，且不会静默产出空值。
- **当前阻塞**：真实 PDF 夹具未授权进入仓库。

### M4 OneDrive SF_DATALESS、hydration 与书签恢复

- **关联**：Issue #13（E1 / P1）。
- **已在 DevBox 完成**：`SourceEntry.hydrationPending` 的传播、`SourceScanIssue` 的 `hydrationPending` 分类、占位文件不产出正文证据的路径与测试。
- **为什么无法在 Linux 验证**：需要 `SF_DATALESS` 标志、File Provider 的按需下载与 iCloud/OneDrive 客户端行为。
- **需要**：macOS 14+；授权目录；OneDrive 客户端；足量占位文件。
- **所需权限/资源**：目录访问授权；不得下载与业务无关的数据。
- **测试步骤**：扫描 → 记录占位 → 触发 hydration → 重新扫描比对 `sourceVersion`/`snapshotRevision` → 断网重扫。
- **预期证据**：三态（未水合/水合中/已水合）各自的扫描结果与哈希。
- **通过条件**：水合前后的快照绑定正确；断网时报告为未完成而不是错误。
- **当前阻塞**：授权目录未提供。

### M5 SwiftUI 交互与真实 GUI 验证

- **关联**：Issue #17、#18（E3 / P2）。
- **已在 DevBox 完成**：`FormaApp` 的视图与 `FormaCore` 边界、脱敏预览与纠错回流的数据契约、Manifest 导出的离线路径。
- **为什么无法在 Linux 验证**：`import SwiftUI`；键盘焦点、动态字体、深/浅色、VoiceOver 与窗口恢复都需真实窗口服务器。
- **需要**：macOS 14+，真实显示器与辅助功能权限（做 a11y 抽查时）。
- **所需权限/资源**：无沙盒与沙盒两种构建；测试库一份。
- **测试步骤**：首启 → 扫描 → 映射预览 → 纠错回流 → 退出恢复 → 重启回查。
- **预期证据**：每步截图/录屏与状态文件。
- **通过条件**：默认 GUI 退出保存未决状态，下次启动先回查后恢复（ROADMAP Owner 决策 3）。
- **当前阻塞**：需人工交互。

### M6 Import 真实隔离库写入、原生 Metadata 回读与崩溃恢复

- **关联**：Issue #21、#22（E5 / I1）。
- **DevBox / macOS CI 已交付**：Preflight 20 码、`ImportLedger`（v1 + v2 授权摘要列）、`ImportSingleWriter` 租约、四态仲裁、`ImportExecutor`、默认拒绝边界 `ImportWriteBoundary`、`GuardedImportWriteTransport` 与真实适配器 `DEVONthinkMCPWriteTransport`；契约见 `docs/ADR-I1-A-IMPORT-CONTRACT.md`，实现见 PR #62–#75。
- **macOS 现场已验证（2026-11-14，I1-B2，限定范围）**：隔离库 + 2 个 Group + 4 条合成记录；源/目标标准 SHA-256 4/4 逐字节一致；Metadata merge 逐字段回读（6 非空 + 2 显式 null → missing，4 个未写入字段未被改动）；重复运行 `SKIP_VERIFIED` 且 `import_file` 调用 0；冲突拒绝覆盖；写请求超时后写入已落库 → `VERIFY_REQUIRED` 且未重试；发送前断连（请求未发出）无盲重试；进程重启后重跑无重复记录；生产库零写入；沙盒对象未删除。见 `docs/I1-B2-ACCEPTANCE.md`。
- **仍未验证（Deferred）**：请求发出后、响应前断连；写入进行中被强杀的崩溃恢复（真实 MCP；Fake Transport 已覆盖）；`dropped_fields` / 部分成功；`import_file` 精确返回结构；异步可见性延迟场景。
- **为什么无法在 DevBox 验证**：写入 DEVONthink 需要真实 MCP 写能力与隔离库；崩溃恢复需真实进程被杀与真实传输。
- **仍需**：新的写预算（返回结构、部分成功）与真实崩溃注入设计。
- **通过条件**：上述 Deferred 项在授权范围内各自取得实测证据；在此之前 M6 只按限定范围记录。

### M7 Developer ID 签名、公证与独立发行

- **关联**：Issue #24（E7 / R1）。
- **已在 DevBox 完成**：无（签名/公证属发行阶段，本阶段不开发独立更新系统）。
- **为什么无法在 Linux 验证**：需要 Apple Developer 证书、`notarytool` 与真实安装。
- **需要**：Developer ID 证书、公证凭据、发行渠道决策（ROADMAP 决策 3）。
- **所需权限/资源**：证书与 App-specific 凭据；不得提交仓库。
- **测试步骤**：签名 → 公证 → staple → 干净机器安装 → 首次启动 → Gatekeeper 评估。
- **预期证据**：`codesign -dv --verbose=4`、`spctl` 评估、公证记录。
- **通过条件**：公证通过且干净机器可直接打开。
- **当前阻塞**：发行阶段未开始。

### M8 Mac App Store 沙盒兼容性

- **关联**：Issue #52（R1 / V7）。
- **已在 DevBox 完成**：无。
- **为什么无法在 Linux 验证**：需 App Store 沙盒签名与审核环境。
- **需要**：重新选择 MAS 渠道（当前渠道未定，属"仅当重新选择该渠道时评估"）。
- **所需权限/资源**：MAS 证书、沙盒测试账号。
- **测试步骤**：沙盒签名构建 → 目录访问与 Keychain 行为 → 提交前自检。
- **预期证据**：沙盒下扫描/映射/凭据三项的实际行为。
- **通过条件**：三项在沙盒下可用或有明确的降级说明。
- **当前阻塞**：渠道未决定。

### M9 10,000 文件真实扫描性能验收

- **关联**：Issue #20（E4 / P3-A）、PLAN §8.2 性能采集。
- **已在 DevBox 完成**：运行器与遥测基础设施（批计划、有界并发、超时、重试、取消、Request/Attempt/Batch/Run 计数、P50/P95、TTFT 可用性判定、成本与计价版本），见 `docs/EVALUATION-METRICS.md` §10；切片 2c 增加可复现的 100 / 1k / 10k 合成夹具、7 阶段计时、并发 1/2/4/8 扫描、故障注入守恒断言、版本化结果结构与 opt-in 的 `FormaBenchmark` / `benchmark.yml`，见 `docs/EVALUATION-BENCHMARK.md`。**这些都是运行器/算法层证据**：不读磁盘、不经 `PDFKit`、不接 Provider。
- **为什么无法在 Linux 验证**：Linux 无法编译 `FormaCore`；且 PLAN §8.2 要求的是**真实本地 10,000 文件**的墙钟、峰值内存与硬件/系统/磁盘条件，合成压测只能作为运行器或算法层证据。
- **需要**：macOS 14+；≥10,000 文件的真实目录（不足则报告实际规模）；OneDrive 授权目录（分列元数据扫描/首次 hydration/缓存命中后读取/SHA/抽取耗时）。
- **所需权限/资源**：目录只读授权；记录硬件、系统版本、磁盘类型与可用内存。
- **测试步骤**：纯元数据扫描（墙钟/文件数/峰值内存）→ 证据抽取阶段分段计时 → 运行器吞吐与并发上限 → 结果按阶段落表。
- **预期证据**：分阶段耗时表 + 硬件/系统条件 + 峰值内存；合成数据单列。
- **通过条件**：报告可复现（同机同目录重跑偏差在声明范围内），且合成结果未被当作真实实测。
- **当前阻塞**：真实目录与硬件记录未提供；本项仍为 **Deferred**，不因 10k 合成基准在 macOS CI 跑通而改变状态。

### M10 真实 Provider 外发授权、Keychain 与日志脱敏现场核验

- **关联**：Issue #20（E4 / P3-A / P3-B）、PLAN §8.3、`docs/PRIVACY-EGRESS-CONTRACT.md`、P2-ACCEPTANCE 中已列 BLOCKED 的"脱敏判别力前后对照"。
- **已在 DevBox 完成**：版本化 `EgressScope` / `EgressAuthorization` / `EgressGate` 与唯一 wire 出口；预览/发送共用构建路径、按数据范围授权；repair/429 重试逐请求重判；`RedactionPlan` 覆盖 locator / CasePack / System Prompt 动态字段；identity 计划披露；可分享 manifest 与日志的 canary 测试；十组 Prompt Injection 结构性质测试。全部用 HTTP Stub 与合成夹具，无真实凭据或网络。
- **为什么无法在 Linux 验证**：Keychain ACL / 锁定态（`Security`）、`os_log` 隐私标记在真实系统日志里的效果、真实 Provider 的 3xx/429/错误正文、以及本地 API 服务模式端到端，都需要真实 macOS 会话与真实服务；`CryptoKit` 等依赖也使整包 Linux 不可编译。
- **需要**：macOS 14+；Keychain 可撤销测试凭据；经 Owner 批准的外发范围与 Provider 数据处理政策展示；一个隔离的本地 API 服务。
- **所需权限/资源**：只读/可撤销凭据；不得使用生产 `Project_Archive` 991 条记录；不得把真实业务正文推到公开仓库。
- **测试步骤**：无凭据/撤销/过期/范围不符 → 逐项确认零请求；真实 302 确认无第二跳；真实 429 确认单次重试；os_log / Console 检查无正文、客户、报价、路径、凭据；脱敏前后关键反例判别力对照。
- **预期证据**：真实请求摘要（脱敏）、Console 摘录（脱敏）、判别力对照汇总、通过/失败结论。
- **通过条件**：所有拒绝路径零请求、日志无敏感原文、判别力不因脱敏系统性下降；且 P3-B 前置条件全部满足。
- **当前阻塞**：P3-B 未授权（凭据、批准模型、外发范围、预算、隔离库、≥150 条独立核实样本）；本项为 **Deferred**，不把 Stub 通过写成现场验证通过。

### M11 Import Eligibility 生产接入与真实目录误排除复核

- **关联**：Issue #51（P3-A / I1）、PLAN §7.3、`docs/IMPORT-ELIGIBILITY-POLICY.md`。
- **已在 DevBox 完成（截至 2026-11-16）**：版本化 JSON Policy、原创 `EligibilityClassifier`、四态决策、解释性 `RuleMatch`、无副作用 `EligibilityView`、Owner 覆写与失效、dry-run 统计、五项资格指标、20 组合成误排除 fixture、10k 合成规模确定性测试；切片 2f 追加只读事实探测（`EligibilityFactCollector`：`CACHEDIR.TAG` 签名、嵌套 `.git`、`git ls-files` 索引）、`protection_facts` 排除门禁与 `eligibility.v2` 策略。
- **工程接入已完成并合并（#116–#121，`dev` @ `f9bd4ea`）**：Contract Delta A–E 已获 Owner 批准并修订冻结文本（SPEC v0.1.2 / PLAN v0.2，PR #116）；切片 1–4 已分别合并——#117 `inputDigest` 绑定 `policy_digest` + 判定指纹（完整清单模式逐字节不变）、#118 `buildContext(…, eligibility:)` / `MappingRunRequest.eligibility` 的 opt-in 接线（未入 Mapping 的记录在 outcome 具名）、#119 Manifest 可选资格块 + `schema_version 1.1` + 按声明版本校验、#120 运行级 `EligibilityReport` 与路径无关导出；#121 文档收敛。四片均经 macOS CI 全绿。**生产默认过滤仍未启用**（Owner 条件 3）；**切片 5（I1 Executor 写入前重判）未授权**。
- **仍需 macOS 现场确认的是行为，不是实现**：APFS 上的真实 `.git` 目录与 `gitdir:` 文件、`CACHEDIR.TAG` 的真实缓存目录、OneDrive dataless 与权限失败下的探测结果、以及真实业务目录上的误排除复核。**2026-11-16 本轮执行会话无可用 macOS 主机**（两台已配置 SSH 主机认证被拒，与 R1 Batch 2A 记录一致）→ 现场项一律 **NOT_VERIFIED**，不得以 CI 绿或合成夹具替代。
- **与 M10 的分工**：M10 覆盖真实 Provider 外发、Keychain 与日志脱敏；M11 覆盖资格策略、真实目录误排除与默认启用门。二者证据不可互相替代，也不得因为一项通过而关闭另一项。
- **需要（现场）**：可用的 macOS 主机；只读合成目录先跑合成验收（夹具与 Runbook 见 `docs/M11-SYNTHETIC-RUNBOOK.md`）；随后由 Owner 提供授权真实目录（不得使用生产 991 条记录）并做人工复核。
- **测试步骤**：合成目录 → `FormaAcceptance m11`（或按 Runbook 手工执行）→ 逐案例 PASS/FAIL/NOT_VERIFIED + 策略 digest；真实目录 → 扫描 → `probeEligibilityFacts` → dry-run → 与人工标注比对 → 复核每个 `EXCLUDE`/`REVIEW` → 记录规则命中、逐事实 provenance 与策略 digest。
- **通过条件**：应保护业务样本零误排除（或有明确人工确认记录）；扫描身份、missing 判定与 Context 默认行为未变；**默认启用另需 Owner 再确认**。
- **五级状态（本项）**：见下表；第 3 级为**部分达成**，不是完全达成。

| 级别 | 状态 | 证据 |
| --- | --- | --- |
| 1. DevBox Development Complete | **达成** | #116–#121 代码、单测与契约修订；`EligibilityReport` / Manifest 1.1 等 |
| 2. macOS CI Verified | **达成** | `macos-15` runner：build / tests / package / launch smoke 全绿（run `43858058846` 等） |
| 3. macOS Synthetic Field Verified | **部分达成 — `MACOS_SYNTHETIC_PARTIAL`** | 2026-11-17 Mac 执行 30/30 CLI PASS，**原始证据独立完整性复核 `VERIFIED`**（report.json / run.log 哈希逐字节一致）；偏差 B3 本地 `NOT_VERIFIED` / CI PASS，A8b 安全 PASS 但内存行为未测量；详见下条与报告 §8 |
| 4. Real Directory Acceptance Pending | **未开始** | 无授权真实目录、无人工复核记录 |
| 5. Production Default Activation Pending | **未授权** | Owner 条件 3；`FormaApp` 未改，生产调用不传 `eligibility` |

- **2026-11-17 macOS 现场执行（Owner 提供证据）**：主机 macOS 27.0.1（26A434）/ arm64 / MacBookPro18,3（Apple M1 Pro）/ APFS；Swift 6.4；Git 2.54.0。仓库 `Skyline-Gazer/Forma`，分支 `dev`，HEAD `a4da6f5`（跟踪工作树干净，既有未跟踪 `tmp/` 未触碰）。命令 `swift run FormaAcceptance m11 --output <path>`，**退出码 `0`**；**30 案例 PASS / 0 FAIL / 0 NOT_VERIFIED**（CLI case-summary 级）。策略 `eligibility.v2`；**policy digest `aa7796df…d2a57` 与仓库钉扎值一致（已独立核对）**；decisions digest `f5203037…3df7e` 为**主机相关值，本会话未重算**。
- **证据文件与哈希（2026-11-17 已独立复核 = `VERIFIED`）**：Owner 把 Mac 原件复制到 DevBox 后，本会话只读复算：`~/.forma/evidence/m11/report.json`（6,078 字节，SHA-256 `339e211622ef12f19da0d37d14ddc5f9c73051c4b40e4432eb6725da8f823586`）、`~/.forma/evidence/m11/run.log`（3,331 字节，SHA-256 `bad4ce801570ed442848cfa078efc10a4923ad3edae81977b2613f55714af1ff`）——均与 Owner 声明**逐字节一致**。`jq` 解析：`schema_version 1.0`、`policy_id forma-import-eligibility`、`policy_version eligibility.v2`、`generated_at 2026-11-17T01:18:04.934Z`、`host "Version 27.0.1 (Build 26A434)"`、`cases` 30 条且 ID 唯一、状态全 `PASS`；`policy_digest` 与仓库钉扎值逐字符一致，`decisions_digest f5203037…3df7e` 与声明一致；日志 30 行 `PASS` 与报告 `(status,id)` 序列逐行一致。**仍未由证据本身确认**：退出码 `0`、`arm64`/`MacBookPro18,3`（报告无架构字段）、`decisions_digest` 跨机重算、`A1` 的 `scan_state=incomplete`（夹具 `locked/` 权限 000 的预期结果，见 `SourceReconciliation.swift:78`）。**原始文件不入库**（`run.log` 末行含一处主机主目录路径，已脱敏）。
- **两处偏差（结论分开保留）**：**B3（Owner 编号）**——1.1 资格块缺必需字段应被拒：本地 `NOT_VERIFIED`，CI 通过（`ManifestEligibilityBlockTests.incompleteEligibilityBlockIsRefused`，run `43859870793`，head `a4da6f5`）；注意它与 CLI 案例 `B3`（1.0 工件不含 `eligibility` 键）不是同一检查。**A8b**——超大 `CACHEDIR.TAG`：安全性 **PASS**（不得 EXCLUDE），**运行时内存行为未测量**；源码检查确认 `readFile` 在 `fstat` 之后、分配缓冲区之前以 `sizeBytes > limit` 直接返回 `unreadable("oversized")`（marker 上限 1,024 字节），并有确定性边界测试 `oversizedMarker`（8 KB 标记 → `unreadable`/`oversized`），故"有界读取"由源码与测试成立，内存剖析未做、不宣称，**无需为此新开 Issue**。
- **安全声明（Owner）**：未访问真实业务目录、未做 DEVONthink 操作、未调用 Provider、未外发文件、未修改仓库、临时夹具已清理、资格默认仍关闭。
- **2026-11-18（第 4 级只读验收工具已就绪，真实目录验收仍未开始）**：新增 `swift run FormaAcceptance m11-real`（`--source`、`--evidence-dir`、`--dry-run` 均为必填；拒绝相对路径、证据目录落在源目录内、源目录与证据目录互相包含、软链接越界、非 dry-run 模式）。流程为只读扫描 → 事实探测 → 四态决策 → 私人审核表 → 脱敏摘要；产物含私人审核表、脱敏摘要、扫描完整性报告、误排除报告、OneDrive 覆盖矩阵（固定 `NOT_VERIFIED`）与 `SHA256SUMS`。人工标签可离线导入后重算指标，**无需重新扫描**；覆盖不完整显式记 `PARTIAL`（退出码 `3`），无人工标注时误排除为 `N/A`（不报零误排除）。**证据写入安全**：一次扫描必须对应一个**新的、空的**证据运行目录（已有内容拒绝，旧运行的人工标签与结论不可能被覆盖）；证据目录必须 `0700`、产物写为 `0600` 且读回校验；固定产物名与 SQLite 文件（含 `-wal`/`-shm`）为符号链接时拒绝；写入前重新解析目录并复核与源目录的分离，无法证明安全即失败关闭。**标签绑定**：导入要求 `--source`、审核表记录的授权目录、发布的 Policy digest 三者一致，标签可选携带 `snapshot_fingerprint`，与审核表不一致即拒绝，防止旧结论被套用到新内容或新策略上；审核表缺失、读不出或本构建无法解析（旧版本工具产物）分别记 `sheetMissing` / `sheetUnreadable` / `sheetInvalid`，一律拒绝而不是当作空表。用法与产物格式见 `docs/M11-LEVEL4-RUNBOOK.md`。
- **本轮报告**：`docs/M11-SYNTHETIC-ACCEPTANCE-REPORT.md` §8。合成验收**不构成**真实目录验收，也不构成关闭本项或开启默认过滤的依据。

### M12 D1 统一 App Shell 的窗口、布局、工具栏与 VoiceOver 现场核验

- **关联**：Issue #150（Phase 2 / D1，PR #157）、父计划 #148、验收批次 #153/M0。
- **已在 DevBox 完成**：单场景 shell（应用侧栏 + 区域内容 + `.inspector` + shell 工具栏）替换 `TabView` 与三个各自为政的 `NavigationSplitView`；列宽集中在 `ShellGeometry` 一处声明；工具栏命令集与内部码业务文案移入 FormaCore Presentation 层（`ShellCommands` / `businessCopy` / `ShellProfilePicker` / `EgressConsent`），由 `AppShellPresentationTests` 做确定性断言（命令集跨 busy/idle/planner 稳定、选择器永不空白、文案对当前外显码全覆盖、区域持久化 round-trip）。macOS CI 的 build/package/launch smoke 只是过程检查。
- **CI 不能证明、必须在 Owner Mac 核验的（全部 NOT_VERIFIED 直至现场）**：区域切换与分栏拖拽不改变外窗尺寸（100+ 切换、20+ 拖拽）；紧凑/默认/宽窗与明暗模式下无空白塌缩、无内容裁切；`VSplitView` 候选面板拖拽手感；inspector 折叠/展开与选中联动；VoiceOver 对侧栏、工具栏中文标签、外发确认对话框与「诊断详情」展开项的朗读顺序与标签；外发许可确认弹窗实际拦截一次运行。
- **通过条件**：#150 验收 §M0 全项；任何一条不成立则本项记失败并回到 shell 分支修复，不得以 CI 绿替代。

## 3. 维护规则

- 本清单只登记**现场验证**，不登记编译/单测（那由 GitHub macOS CI 负责，见 `.github/workflows/ci.yml`）。
- 每一项关闭时必须写入：验证日期、macOS/DEVONthink/OneDrive 版本、实际命令或步骤、证据位置、通过/失败结论；**不得**把"CI 绿了"写成该项通过。
- 新增延后项时同步更新 §1 汇总表；阶段推进后同步 `docs/ROADMAP.md` 的授权状态，不在两处各写一份状态。