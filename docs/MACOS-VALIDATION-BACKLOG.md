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
| M1 | 真实 DEVONthink MCP 能力与版本核验 | #10 / P0 | Deferred | 隔离测试库与只读凭据 |
| M2 | Keychain 与原生权限行为 | #18 / P2 | Deferred | 真实 macOS 会话 |
| M3 | PDFKit 实际抽取兼容性 | #13 / P1 | Deferred | 真实文档夹具 |
| M4 | OneDrive SF_DATALESS / hydration / 书签恢复 | #13 / P1 | Deferred | 授权 OneDrive 目录 |
| M5 | SwiftUI 交互与真实 GUI 验证 | #17 #18 / P2 | Deferred | 人工交互 |
| M6 | Import 真实隔离库写入与崩溃恢复 | #21 #22 / I1 | Deferred（未授权） | I1 授权 + 隔离库 |
| M7 | Developer ID 签名、公证与独立发行 | #24 / R1 | Deferred（未授权） | 证书与分发决策 |
| M8 | Mac App Store 沙盒兼容性 | #52 / R1 | Deferred（渠道未定） | 重新选择该渠道 |
| M9 | 10,000 文件真实扫描性能验收 | #20 / P3-A | Deferred | 真实目录 + 硬件记录 |

## 2. 各项明细

### M1 真实 DEVONthink MCP 能力与版本核验

- **关联**：Issue #10（E0 / P0）。
- **已在 DevBox 完成**：`DEVONthinkReadOnlyClient` 的请求/响应编解码、`MCPStdio` 的子进程边界与超时、12 字段契约的类型与只读方法清单；`Tests/FormaCoreTests/MCPTests.swift` 用假传输覆盖了协议层。
- **为什么无法在 Linux 验证**：需要真实 DEVONthink 应用、`tools/list` 实际返回值与隔离测试库；假传输不能证明线上能力。
- **需要**：macOS 14+、DEVONthink 版本（待现场记录）、隔离测试库 UUID。
- **所需权限/资源**：只读访问；不得使用生产 `Project_Archive`（991 条记录不可修改）。
- **测试步骤**：只读探针 → `tools/list` 与 `classify_record`/`lookup_records` 逐项对照 → 记录返回字段与 `nativeTypeStatus` 的差距。
- **预期证据**：真实 MCP 响应原文（脱敏）、字段级对照表、V3 未确认项清单。
- **通过条件**：12 字段中可确认项有明确证据，未确认项显式标记 `unverified`，且无写入调用。
- **当前阻塞**：隔离测试库与只读凭据未提供。

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
- **已在 DevBox 完成**：无。I1 **未授权**；当前只允许设计/类型/合成验证，且不得把模拟通过写成 Import 验收成功。
- **为什么无法在 Linux 验证**：写入 DEVONthink 需要真实 MCP 写能力与隔离库；崩溃恢复需真实进程被杀。
- **需要**：I1 授权、隔离测试库、单写者状态机与 Ledger schema 冻结。
- **所需权限/资源**：隔离库读写；生产库永不触碰。
- **测试步骤**：Preflight → 单记录写入 → 幂等重复 → 创建后崩溃 → 重启恢复 → 冲突 hold。
- **预期证据**：四态（`SKIP_VERIFIED`/`IMPORT`/`CONFLICT_HOLD`/`VERIFY_REQUIRED`）的真实转移记录与原生 Metadata 回读值。
- **通过条件**：写入后回读一致、重复不产生第二条、崩溃后可恢复到确定状态。
- **当前阻塞**：I1 未授权（外部授权阻塞，不是技术阻塞）。

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

## 3. 维护规则

- 本清单只登记**现场验证**，不登记编译/单测（那由 GitHub macOS CI 负责，见 `.github/workflows/ci.yml`）。
- 每一项关闭时必须写入：验证日期、macOS/DEVONthink/OneDrive 版本、实际命令或步骤、证据位置、通过/失败结论；**不得**把"CI 绿了"写成该项通过。
- 新增延后项时同步更新 §1 汇总表；阶段推进后同步 `docs/ROADMAP.md` 的授权状态，不在两处各写一份状态。