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
5. **退出有界**：`applicationShouldTerminate` 最多等待 300 ms，Intent/Ledger 已先落库。
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

未获授权前，不得开始 Batch 2 代码或任何真实写入。
