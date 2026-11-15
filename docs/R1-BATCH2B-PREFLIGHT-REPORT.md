# R1 Batch 2B Preflight — 报告

日期：2026-11-15 · 仓库：`Skyline-Gazer/Forma` · 基线：`dev` @ `ff0d5b3`（#105）

本报告区分三类事实：

- **GitHub 已核实**：HEAD、PR、合并 SHA、CI（本会话查询）。
- **历史现场记录**：2A.2/2A.3 在真实 Mac 上由前序会话执行并写入 `docs/`；本会话**未重跑**。
- **未验证**：明确标注 NOT_VERIFIED/BLOCKED，不因"代码存在"而升级。

---

## 1. I1 收尾结果

| 项 | 事实 |
| --- | --- |
| 最终 HEAD | `e1a1379`（PR #75 合并） |
| 合并 PR | #71 默认拒绝写入边界、#72 预检修订、#73 隔离库绑定、#74 真实 MCP 写入适配器、#75 验收报告 |
| CI | `43581724081` success（push，`e1a1379`） |
| 结论 | **Import Integration Verified（Limited Scope）**；四个切片分别验收，不合并为"I1 全部通过" |
| 生产库 | 零写入（B2 报告记录） |
| 沙盒 | 2 个 Group、4 条合成记录，均未删除 |
| 证据目录 | 运行主机 `~/.forma/evidence/i1-b2/`；**本会话主机为 Linux，该目录不存在 → 原始证据复核 BLOCKED**，本报告不复述未亲验的原始文件内容 |

**未验证项（保持 NOT_VERIFIED）**：

1. `import_file` 精确返回结构（UUID 数量与嵌套）；
2. `dropped_fields` / 部分成功路径；
3. 请求发出后、响应前断连；
4. 写入中进程崩溃；
5. Metadata 语义已澄清：6 个字段写入非空值、2 个显式 null → missing、4 个未写入保持 missing；merge 未清除其他字段；
6. OneDrive hydration / 真实业务文件。

Issue 状态：#21（写入能力与 SHA）按原验收条件关闭；#22（Ledger/恢复）保持 open；#7（Epic）保持未完成；#24 保持 open/未授权；#51 保持 open（Eligibility 决策层已交付，不重复开发）。

## 2. R1 技术现状

### 2.1 能力审计（按真实源码）

| 能力 | 状态 | 证据 |
| --- | --- | --- |
| MCP stdio Process 生命周期 | 已实现 | `Sources/FormaCore/DEVONthink/MCPStdio.swift`（`Process` 启动/结束）；`MCPConnectionSupervisor.swift`（单飞连接、关闭） |
| MCP 初始化/超时/断连 | 已实现；**无自动重连** | `MCPStdio.swift` 行协议 + 超时；`MCPConnectionSupervisor` 失败返回错误，需显式重开 |
| ReadOnlyClient 与 WriteTransport 边界 | 已实现 | `DEVONthinkReadOnlyClient.swift`（无写工具）；`DEVONthinkWriteTransport.swift`（`GuardedImportWriteTransport`，唯一写通道，逐调用授权+预算） |
| SQLite Ledger 持久化 | 已实现（离线） | `ImportLedger.swift`（唯一 `key_digest`、相位迁移、`verify_required`）；`ImportSingleWriter.swift` |
| 启动恢复（未决写） | 已实现（只读） | `ImportSingleWriter.ImportRecovery.open`：在途 → `verify_required`；`ImportRecoveryCoordinator`/`ImportRecoveryReviewer` 只读回查 |
| Bookmark / Security Scoped | 已实现 | `Sources/SourceStore.swift`、`SourceWorkspace.swift`、`SourceAvailability.swift`（解析、撤销、重授权、身份校验） |
| Keychain | 已实现（设备专用、三态契约） | `ProviderKeyStore.swift`（`kSecUseDataProtectionKeychain`、删除/轮换、legacy 探测） |
| 退出保存 | 已实现 | `FormaAppDelegate.applicationWillTerminate`（同步非阻塞清理） |
| 下次启动状态恢复 | 已实现 | 打开 workspace 时 `ImportRecovery.open` + 横幅；2A 记录"不自动重试" |
| macOS 14+ 兼容 | 部署目标已设；**运行未验证** | `Package.swift` / 打包脚本；本机无 macOS 14.x |
| Keychain 锁定态 | **未实现验证** | 2A：文件 keychain 不可被 `SecItem*` 访问，未制造锁定态 |
| 写入中故障（超时/断连/崩溃） | **仅合成验证** | `ImportExecutorTests`、`ImportFaultMatrixTests`、`ImportB0BoundaryTests`、`ImportWriteBoundaryTests`、`ImportRuntimeTests` |

### 2.2 本轮现场与工程结果

| 项 | 结果 |
| --- | --- |
| 打包/启动（真实 Mac） | PASS（2A.2/2A.3 记录：资源 bundle、`codesign --strict`、启动冒烟） |
| 书签撤销/重授权/跨重启 | PASS（2A.3） |
| GUI 表单键入 + 只读回查 | PASS（2A.3，含输入法切换与逐字段回读） |
| 缺陷 A（失败提交后合法输入仍显示旧错误） | **工程已修**（#103，CI success）；**现场复测 NOT_VERIFIED** |
| M05（真实写入故障） | **未授权、未执行** |
| 签名/公证/发行 | 未授权、未执行 |

### 2.3 本轮工程改动

| PR | 合并 SHA | 变更 |
| --- | --- | --- |
| #103 | `e728ad5` | `RecoveryScopeDraft` 增加 `hasAttemptedConfirmation`/`feedback`；sheet 只渲染草稿反馈；Confirm 仅在 `.ready` 提交；6 个回归测试；GUI 文档更新 |
| #104 | `43dea29` | `docs/M05-PREFLIGHT.md`、`docs/M05-AUTHORIZATION-PROPOSAL.md` |
| #105 | `ff0d5b3` | Roadmap 状态收敛 |
| #106 | 本报告 | Batch 2B 报告与交接（文档） |

CI（本轮）：#103 head `2cf4699` → run `43688627800` success；#104 head `d26c206` → run `43688821087` success；`dev` @ `43dea29` → run `43689343834` success；`dev` @ `ff0d5b3` → run `43689914024` success；`e728ad5` 的合并后 run 被后续 push 取消，不是失败。

## 3. 下一阶段任务表

| Task ID | 工作内容 | 依赖 | 执行环境 | 需 Owner 授权 | 验收标准 |
| --- | --- | --- | --- | --- | --- |
| R1-F01 | 缺陷 A 现场复测（步骤 2–7） | #103 合并后的 artifact | Real macOS | 否（只读 GUI） | 第 4 步错误消失；第 5–7 步仍 PASS |
| M05-T01 | 目标绑定 + 3 工具 schema 核对 + 3 合成文件 SHA | Owner 批准目标库 | Real macOS | 是（只读绑定除外） | 绑定与基线逐字一致；plan 显示 3 条 would_execute |
| M05-T02 | 超时（`SIGSTOP` 子进程）→ 未知 → 只读回查 | M05-T01 | Real macOS | **是（真实写入）** | Ledger `verify_required`；attempts=1；无重复 |
| M05-T03 | 发送后断连（`SIGKILL` 子进程）→ 未知 → 只读回查 | M05-T02 | Real macOS | **是（真实写入）** | 同上；不重发 |
| M05-T04 | 崩溃注入（create 在途终止 Forma）→ 重启只读回查 | M05-T03 + 单独批准 | Real macOS | **是（进程终止）** | 重启后 `verify_required` + 明确结论；无重复记录 |
| R1-K01 | Keychain 锁定态与 GUI 提示 | — | Real macOS | 否（专用测试凭据） | 锁定态三态契约可观测 |
| R1-V01 | 外部卷 / iCloud / macOS 14.x | 对应硬件与系统 | Real macOS | 否 | 书签、路径、最低系统兼容 |
| R1-R01 | Developer ID 签名 + Hardened Runtime | Apple 账号/证书决策 | Real macOS + 发行环境 | **是** | `codesign --strict`、`spctl` 通过；MCP 子进程可启动 |
| R1-R02 | 公证 + staple | R1-R01 | 发行环境 | **是** | `notarytool` accepted；`stapler validate` 通过 |
| R1-R03 | 独立安装与发行渠道验证 | R1-R02 | 干净的发行目标机 | **是** | 安装、首次启动、卸载可复现 |
| R1-D01 | 2B 功能开发（若 Owner 决定继续） | Owner 决策 | DevBox + macOS CI | **是** | 按 #24 剩余项逐条验收 |

## 4. Owner 决策申请

1. **是否正式授权 R1 开发？** 在此之前不启动任何 R1 应用功能实现（当前仅完成只读现场验证与工程修复）。
2. **是否批准 M05 真实写入**（`docs/M05-AUTHORIZATION-PROPOSAL.md`：3 记录 / 2 组 / 3 合成文件 / ≤6 次 metadata）？崩溃注入是否单独批准？
3. **是否启动 R01–R03**（Developer ID、公证、独立安装）？需要 Owner 指定证书与分发目标。
4. 缺陷 A 的现场复测放在哪个 artifact / 时间窗口？

未获授权前，仓库保持现状：M05 不执行、无真实写入、无签名与发行。
