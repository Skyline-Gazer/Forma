# R1 Batch 2A — Real macOS Acceptance（执行结果：BLOCKED）

状态：**BLOCKED — 执行主机不是 macOS**。本报告只记录实际执行到的部分与阻塞证据；没有执行的项目一律标记 BLOCKED，不写成 PASS/NOT_VERIFIED 的混合。

- 授权：Owner 2026-11-14 批准 R1 Batch 2A（仅无 DEVONthink 写入的现场验证）。
- 执行会话主机：Linux DevBox（`Linux 7.0.0-42-generic x86_64`）。
- 结论先行：**M01 / M02 / M03 / M04 / M06 全部 BLOCKED**；只有「§1 Baseline 与开发用 `.app` 的静态验收」部分可执行，且其中「启动路径 / 其他实例」仍为 BLOCKED。
- 真实 DEVONthink 写调用：**0 次**（原因见 §5：主机上不存在 DEVONthink，调用未被执行，而不是被拒绝）。

## 0. 主机事实（阻塞证据）

| 检查 | 结果 |
| --- | --- |
| 内核 | `Linux … x86_64`（非 Darwin） |
| `sw_vers` | 不存在 |
| `/Applications/DEVONthink.app` | 不存在 |
| `security` / `codesign` / `spctl` / `plutil` / `osascript` / `swift` | 均不存在 |
| `~/.forma` | 执行前不存在（本机从未产生过 I1-B2 现场证据） |
| 已配置 SSH 主机 | 2 个；`BatchMode` 认证均失败（`Permission denied (publickey,password)`） |
| 任何挂载的 macOS 共享 | 无 |

因此本会话无法访问：Security 框架（书签/Keychain）、AppKit/SwiftUI（GUI）、DEVONthink 与官方 MCP、`codesign`/`spctl`、macOS 14 运行时。

## 1. Baseline 与开发用 `.app` 静态验收

| 项 | 结果 | 证据 |
| --- | --- | --- |
| GitHub `dev` | `cab0936` | 与本地 HEAD 一致 |
| `main` | `38d4553`（未动） | — |
| `dev` CI | **success**（run `43594703178`：FormaCore tests / macOS app build / macOS app package） | — |
| Batch 2A 工程 PR | **不存在**：`dev` 历史止于 Batch 1 收尾（#79–#85），本轮没有新的工程 PR | — |
| 冻结基线 | `ads-pin.txt` / `.ads` / `.gitmodules` / `docs/SPEC.md` 自 `a3a3cf7` 起 0 变更 | — |
| Bundle ID | **PASS**：`io.github.skyline-gazer.forma` | 下载 CI 产物 `Forma-app-adhoc`，`Info.plist` 解析 |
| Bundle 结构 | **PASS**：`Contents/{Info.plist, MacOS/Forma, _CodeSignature/CodeResources}`；可执行文件为 Mach-O 64-bit arm64 | `file` 输出 |
| ad-hoc 签名（结构） | **PASS**：Mach-O 含 `LC_CODE_SIGNATURE`（dataoff 16160784 / size 145728），`_CodeSignature/CodeResources` 存在 | 本地解析 |
| ad-hoc 签名（有效性） | **macOS CI Verified**（非本机）：CI `codesign --verify --strict` 通过；`codesign -dv` 报 `flags=0x10002(adhoc,runtime)`、`Identifier=io.github.skyline-gazer.forma` | CI 日志 |
| 应用资源 | **PASS（按设计）**：`Contents/Resources` 不存在；`CFBundleIconFile=AppIcon` 指向未提供的图标，符合「图标入口已接线、资产未提供」 | 产物结构 |
| 启动路径 | **BLOCKED**：无法在非 macOS 上启动 `.app` | — |
| 是否存在其他 Forma 实例 | **BLOCKED**：无 macOS 进程视图 | — |
| `LSMinimumSystemVersion` | `14.0`（声明值，非运行验证） | `Info.plist` |

`.app` 来自 CI 产物（`gh run download`），不是本地重新构建：本机没有 Swift 工具链，按仓库脚本构建同样不可执行。

## 2. M01 — Bookmark

**BLOCKED**。Security-Scoped Bookmark 依赖 `Foundation` 的 `bookmarkData(options: .withSecurityScope)` 与 `startAccessingSecurityScopedResource`，只在 macOS 上存在；本机也无法创建「合成来源目录」以外的授权状态。

未执行项：首次授权、正常扫描、权限撤销、扫描进入 incomplete、历史记录不被标记 missing、重新授权、恢复后重扫、来源身份变化时拒绝静默复用。
外部卷与 iCloud：**BLOCKED**（无夹具，且按授权不得用真实业务目录替代）。

## 3. M02 — Keychain

**BLOCKED**。`Security` 框架不存在；无法创建独立测试 service/account，也无法观察锁定态。

未执行项：添加合成密钥、读取、更新、删除、访问性属性、锁定错误处理、GUI 提示。
既有 Provider Keychain 项：**未触碰**（本机无 Keychain）。

## 4. M03 — MCP Process

**BLOCKED**。DEVONthink 未安装，官方 MCP 不存在；无法建立任何真实连接。

未执行项：`initialize`、`tools/list`、只读连接、主动关闭、子进程异常终止、读连接重建、双连接并存、schema digest 复核。
写侧监督器：**未运行**（其契约复核需要真实 `tools/list`）。写工具调用：**0 次**。

## 5. M04 — App Lifecycle

**BLOCKED**。无 GUI、无 macOS 应用生命周期、无窗口服务器。

未执行项：启动、Workspace 加载、恢复状态展示、未授权只读回查拒绝、授权范围回查、正常退出、重启、恢复未决状态、不自动重试。
合成 Ledger 未生成：按授权只能在独立测试 `workspace.sqlite` 中生成，而该步骤必须配合真实 GUI 才有验收意义。

## 6. M06 — macOS 14.x

**BLOCKED**。无 macOS 14 环境。**不**用 macOS 15 编译成功替代运行时验收。

## 7. 真实 DEVONthink 写调用计数

**0 次**。精确表述：本会话没有发起任何 MCP 调用（读写都没有），因为主机上不存在 DEVONthink；这不是「边界拒绝了写调用」的证据，不能用于证明写路径安全。写路径的拒绝证据仍来自 I1-B2 现场与 `ImportWriteBoundary` 单测。

## 8. 证据位置

本机：`~/.forma/evidence/r1-batch2a/`

| 文件 | 内容 |
| --- | --- |
| `host.txt` | 内核、工具缺失、DEVONthink 缺失、SSH 认证失败 |
| `baseline.txt` | `dev`/`main` SHA、CI run、开放 PR 数、冻结文件 0 变更 |
| `bundle.txt` | 产物来源、结构、`file` 输出、Info.plist 全量键值、`LC_CODE_SIGNATURE`、CI `codesign` 摘要 |

仓库只提交本报告，不含原始日志与任何本机路径。

## 9. 逐项结论

| 项 | 结论 |
| --- | --- |
| §1 Bundle ID / 结构 / 签名结构 / 资源 | **PASS** |
| §1 ad-hoc 签名有效性 | **macOS CI Verified**（非本机） |
| §1 启动路径 / 其他实例 | **BLOCKED** |
| M01 Bookmark | **BLOCKED** |
| M02 Keychain | **BLOCKED** |
| M03 MCP Process | **BLOCKED** |
| M04 App Lifecycle | **BLOCKED** |
| M06 macOS 14.x | **BLOCKED** |
| 真实写入计数 | 0（未执行） |

## 10. 关于 R1 Batch 2B

**不能申请。** Batch 2B 的前置是 2A 的现场结论；2A 在本会话完全 BLOCKED，没有产生任何可用于判断 2B 范围的现场事实。

需要的执行环境：一台可交互的 macOS 14+ 机器，装有 DEVONthink 4.4.2（或记录实际版本）、可登录的桌面会话、可用的 Developer ID 无关的 ad-hoc 构建（CI 产物即可）、以及一个全新的合成来源目录。

## 11. 在 macOS 上的复跑程序（下一次会话直接执行）

1. 取 CI 产物或本地构建：`sh scripts/build_app.sh`（或 `gh run download <run-id> -n Forma-app-adhoc`）。
2. 记录环境：`sw_vers`、`system_profiler SPSoftwareDataType`、`mdls -name kMDItemVersion /Applications/DEVONthink.app`、`codesign -dv --verbose=4 Forma.app`、`spctl -a -vv Forma.app`。
3. 启动前确认无其他实例：`pgrep -fl 'Forma.app/Contents/MacOS/Forma'`。
4. 启动应用（`open Forma.app`），确认 Workspace 加载与恢复横幅（无未决操作时应不显示）。
5. M01：新建合成目录 → 添加 → 扫描 → 在「系统设置 → 隐私与安全性 → 文件与文件夹」撤销该目录 → 再扫描（应 `.incomplete` 且无 `.missing`）→ 重新添加授权 → 重扫。
6. M02：用独立 service/account（如 `io.github.skyline-gazer.forma.test`）执行 `security add-generic-password` / `find` / `delete`，并记录 `kSecAttrAccessible`；锁定态用「锁屏后读取」观察，若无法稳定复现则记 NOT_VERIFIED。
7. M03：用应用内「DEVONthink MCP」发现按钮建立只读连接；记录 `initialize`/`tools/list` 结果与 schema digest；用 `pkill -f 'DEVONthink MCP --stdio'` **只终止本次启动的子进程**（先 `pgrep -P` 确认父进程是本次 Forma 实例），再触发一次发现以验证重建。
8. M04：正常退出 → 确认 `pgrep` 无残留子进程 → 重启 → 确认恢复横幅与 `verify_required` 计数；未授权回查应显示 `no_authorized_scope`。
9. 证据写入 `~/.forma/evidence/r1-batch2a/`，仓库只提交脱敏报告。

每一步都要记录：GUI 实际显示、持久化数据变化、MCP 真实调用、以及是否涉及写入中恢复（本批不应涉及）。
