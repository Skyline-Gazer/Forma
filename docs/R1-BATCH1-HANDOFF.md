# R1 Batch 1 — Handoff

> 给下一个 Session 的接续说明。状态口径严格区分 **DevBox Implemented**、**macOS CI Verified**、**Real macOS NOT_VERIFIED**、**Release NOT_VERIFIED**。

## 1. 本批范围与授权

- Owner 授权：R1 Batch 1（R1-T01 / T02 / T03 / T04 / T07 / T08），仅 DevBox + 合成测试 + GitHub macOS CI 验证。
- **未授权**：真实 DEVONthink 写入、生产导入、真实 Provider 请求、Developer ID 签名与公证、Batch 2。
- 冻结基线不变：`main`、ADS pin、SPEC v0.1.1。

## 2. 交付（PR 与合并）

| 任务 | 交付 | PR |
| --- | --- | --- |
| T01 | `DEVONthinkImportReadAdapter`（生产 `ImportReadTransport`）+ 13 例测试 | #79 |
| T03 | `MCPConnectionSupervisor` + 写工具契约复核 + 13 例测试 | #80 |
| T02 | `ImportRuntime`（显式授权、默认 dry-run、一次授权一次运行）+ 11 例测试 | #83 |
| T04 | 启动清扫、六态呈现、只读回查入口、有界退出 + 9 例测试 | #84 |
| T07 | `Info.plist` / entitlements / `scripts/build_app.sh` / CI package job | #81 |
| T08 | 诊断事件、闭集错误码、stderr 有界缓冲、显式授权导出 + 7 例测试 | #82 |

契约文本修正（随 #79）：`verify_required → intent_persisted` 不存在；重新写入需要新的操作键。

## 3. 关键不变量（下一批不得破坏）

1. **重建连接 ≠ 重试请求**：supervisor 从不重发；写结果未知 → `VERIFY_REQUIRED` → 只读回查。
2. **一次授权一次运行**：`ImportRuntime` 以授权 digest 记账，重复调用拒绝，预算不可刷新。
3. **生产库永不作为目标**：目标必须 `declaredDisposable`、名字不得命中保留生产库、scope 与目标完全一致。
4. **诊断无自由文本**：事件只有闭集 stage/code 与整数；stderr 原文只在本机内存，导出只有 digest 与长度。
5. **退出不等待**：清理在 `applicationWillTerminate` 里同步执行（取消任务、关闭 discovery 的 MCP 连接），不做任何等待，因此不可能阻塞退出；Intent/Ledger 在此之前已落库。`applicationShouldTerminate` / `terminateLater` **没有**被使用。
6. **未验证项不得升格**：任何 Batch 1 结果都不能当作真实 macOS 集成通过。

## 4. 仍未验证（Batch 2 清单）

| 项 | 原因 |
| --- | --- |
| 真实 macOS 下的书签撤销/恢复、外部卷、iCloud | 需真实 Apple 框架 |
| Keychain 锁定/重装/迁移 | 同上；service 名迁移未做（明确禁止） |
| MCP 子进程启停、断连重连、双进程并发的真实现场 | 需真实 DEVONthink |
| 退出/重启回查（含在途写） | 需真实进程生命周期 |
| 写入中强杀（`kill -9`）崩溃恢复 | 需真实进程 + **独立写预算** |
| 公证后的 `.app` 内 `Process()` 拉起 MCP | 需 Developer ID 与公证 |
| 干净机安装与 Gatekeeper | 需发行环境 |
| macOS 14.x 运行时 | CI 只有 14 目标编译 + 15 运行 |
| 正式图标、DMG、更新机制 | 未开始 |

## 5. CI 与验证口径

- Swift 编译与测试**只能**在 GitHub macOS CI（macos-15 + Xcode 26.3）验证；DevBox 无 Swift 工具链。
- 打包由 `macOS app package` job 验证：组装、`plutil -lint`、bundle id 断言、`codesign --verify --strict`、ad-hoc 签名报告、产物上传。
- 真实 DESKTOP 行为一律记为 NOT_VERIFIED。

## 6. 下一批建议（需 Owner 单独授权）

1. R1-T05 书签失效恢复流程（DevBox 逻辑 + 真实 macOS 验证）。
2. R1-T06 Keychain 迁移与可访问性（bundle id 定案后）。
3. R1-M01–M06 现场验证（含崩溃注入的独立写预算）。
4. R1-R01–R03 发行环境（Developer ID、公证、渠道评估、仓库转 private）。

## 7. Batch 2A 执行结果（2026-11-14）

Owner 授权了 Batch 2A（真实 macOS 现场验证，仅只读）。执行会话主机为 **Linux DevBox**，无 DEVONthink、Security、AppKit、`codesign`/`spctl`，两个已配置 SSH 主机认证失败 → **M01/M02/M03/M04/M06 全部 BLOCKED**。

唯一可执行部分：§1 打包静态验收（Bundle ID、bundle 结构、`LC_CODE_SIGNATURE`、CI 的 `codesign --verify` 与 `adhoc,runtime` 标志）与 baseline 核对（`dev` @ `cab0936`，CI success，无 Batch 2A 工程 PR）。

真实 DEVONthink 写调用 **0 次**（未执行，不是被拒绝）。详见 `docs/R1-BATCH2A-REPORT.md`。

### 7.1 无真实写入的工程部分（同日另行授权）

Owner 随后授权了 Batch 2A 的工程范围（无真实写入），已完成：

| Task | 交付 |
| --- | --- |
| T05 书签恢复 | 可用性七态（stale / 撤权 / 缺失 / 云端未下载 / 身份变化 / 不可用 / 可用）、身份校验的重授权、侧栏与横幅引导（#87） |
| T06 Keychain | 设备专用可访问性、删除/轮换、锁定态与缺失区分、只读 legacy 探测、可回滚迁移接口；**未改 service 名、未自动迁移、未触碰真实凭据**（#88） |
| T04 补齐 | 读范围显式确认 + 真实调用 `ImportRecoveryReviewer` + 结果只更新界面；未授权/跨库/跨组零读取（#89） |

这些是 **DevBox Implemented · macOS CI Verified**，不是现场验证。撤销授权、stale security-scoped bookmark、锁定 Keychain、真实 MCP 回查与 GUI 交互仍待真实 macOS 执行。

**下一步**：在一台可交互的 macOS 14+ 机器上按该报告 §11 的步骤复跑 2A；2B 不具备申请条件。

未获 Owner 对 Batch 2B 的单独授权前，不得开始任何真实 macOS 写入、签名或发行工作。
