# R1 Batch 2A.3 — 真实 macOS 现场验收（执行结果）

状态：**打包/启动与交互项均已在真实 macOS 现场执行**；**§4 表单输入、Recovery 只读回查、退出/重启/子进程清理取得现场证据**；现场发现 1 个 UI 缺陷（表单纠错后错误提示不消失），其余已知 BLOCKED 项（macOS 14.x、外部卷/iCloud）仍为 BLOCKED。

- 授权：Owner 批准本轮现场验收；桌面会话由 Owner 让出，系统权限（桌面文件夹访问）由 Owner 在本机勾选。
- 本轮未调用任何 DEVONthink 写工具；未创建或修改任何 DEVONthink 记录；未触碰生产库；未修改 Keychain 凭据；未签名/公证/发行；未改 `main` / ADS pin / 冻结 SPEC；未执行 M05 / R01–R03。
- 证据原件仅在本机 `~/.forma/evidence/r1-batch2a3/`；本文不含真实数据库 UUID、记录 UUID、沙盒路径或业务数据。

## 0. 执行主机与系统

| 检查 | 值 |
| --- | --- |
| 内核 / 架构 | `Darwin` / `arm64` |
| macOS | 27.0.1（26A434） |
| 机型 / CPU | MacBookPro18,3 / Apple M1 Pro |
| 工具链 | `/Library/Developer/CommandLineTools`（无完整 Xcode），Swift 6.4 |
| 窗口会话 | `launchctl managername` = **Aqua** |
| `codesign` / `security` / `launchctl` | 均存在 |
| DEVONthink | 4.4.2（含 MCP 4.4.2），运行中 |
| GitHub 访问 | `gh` 已认证，仓库读/下载正常 |

现场期间出现过两次系统级弹窗，均由本轮操作触发、均按"不擅自授权"处理：

1. Apple Events（"Ghostty.app 想要控制访达.app"）——误触 `tell application "Finder"` 后出现，选择**不允许**，未授予。
2. 「Forma.app 想访问桌面文件夹」——隔离库位于桌面的 `.dtBase2` 包内，属 TCC `SystemPolicyDesktopFolder`。先按**不允许**（§4 步骤 5 因此得到 `unverifiable`），在 Owner 明确授权并在系统设置勾选后才重跑并取得 `verified`。

## 1. Baseline 与 Artifact

| 项 | 值 |
| --- | --- |
| `dev` | `eaf308b`（与任务给定基线一致；`main` 仍为 `38d4553`，未动） |
| CI run | `43668217896`（HEAD `eaf308b`），jobs：`macOS app build` / `FormaCore tests` / `macOS app package` / `macOS app launch smoke` 全 success |
| Artifact | `Forma-app-adhoc.tar.gz`，**SHA-256 `045a1a272f032be69a0f5884268c49b669c5091a5706a9162b8347ea3a0d4481`** |
| 归档结构 | 24 个条目，根为 `Forma.app/`；资源在 `Contents/Resources/Forma_FormaCore.bundle` |
| 参考 artifact | run `43625876979` 的 `e3aae74f…` **未使用**，避免与新 run 混用证据 |
| Learning Loop | Issue #98 仍 OPEN，本轮见 §7 |

本轮的 `.app` 是**未经任何人工修补**的 CI 原件。

## 2. 原生 App 验收（§2）

| # | 检查 | 结果 | 原始证据 |
| --- | --- | --- | --- |
| 1 | `.app` 完整结构 | **PASS** | `verify_app_bundle.sh`：`plutil -lint` OK、bundle id `io.github.skyline-gazer.forma`、`Contents/MacOS/Forma` 可执行、`Contents/Resources/Forma_FormaCore.bundle` 存在、`.app` 根无 `.bundle` |
| 2 | 资源 bundle 完整性 | **PASS** | 脚本断言 6 个必需资源全部存在；应用启动后资源加载器未触发任何 `FormaError.unavailable` |
| 3 | `codesign --verify --strict` | **PASS** | `valid on disk` / `satisfies its Designated Requirement`；`flags=0x10002(adhoc,runtime)`；Mach-O thin arm64 |
| 4 | 真实 GUI 启动 | **PASS** | `smoke_app.sh`：`pid: 8874`、`alive after 5s: yes`、`result: PASS` |
| 5 | 主窗口出现 | **PASS** | AX：`AXWindow title=Forma`，detail 显示 `Choose a source` / `Add a local or OneDrive folder to scan its files.` |
| 6 | 正常退出 | **PASS** | `⌘Q` 后进程消失（多轮，含恢复夹具轮次） |
| 7 | 无异常残留进程 | **PASS** | 退出后无 `Forma` 进程、无 `DEVONthink MCP` 子进程 |

与 Batch 2A 的差别：上一轮的"能启动/可签名互斥"缺陷已由 #92 修复，本轮**原件**同时满足严格验签与启动。

## 3. Bookmark 现场验收（§3）

全部使用本轮新建的合成目录，经**真实 `NSOpenPanel`** 授权；无业务目录参与。

| 场景 | 观察 | 判定 |
| --- | --- | --- |
| 首次授权（真实面板选目录） | 选择合成目录 → `register` 成功，`security_scoped=1`，窗口标题变为该来源 | PASS |
| 扫描与历史 entry ID | `Scan` → `Scan complete · 3 files`；3 条 entry（`a.txt` / `b.txt` / `sub/c.txt`）全 `present`，ID 稳定 | PASS |
| 删除来源根目录 | 重启后横幅 **`Folder not found`** + "… is gone. Scans stay incomplete until it is back, so nothing is marked missing by accident."；3 条历史 entry 仍为 `present`，`missing` 计数 0 | PASS |
| 历史记录未被误删 | 同上：条目行数不变、状态未改 | PASS |
| 同路径换成另一个目录（新 inode） | 横幅 **`This folder is different now`**（`identityChanged`），提示"Add it as a new source instead" | PASS |
| 权限被收回 | 阻断父目录后重启 → 横幅 **`Access was revoked`** + 「Reauthorize…」按钮；说明文案"Files were not marked missing" | PASS |
| 重授权（同一目录） | 面板再次选择同一目录 → **`Access to … was renewed.`**；横幅消失、扫描 `complete` | PASS |
| 来源身份校验（重授权选别的目录） | 面板选另一目录 → 提示 **`That folder is not the source this entry was registered from.`**，可用性状态不变、无静默替换 | PASS |
| 外部卷 / iCloud | 未做（无隔离夹具，不拿真实目录替代） | BLOCKED |

## 4. GUI 输入与 Recovery（§4 八步）

输入方式（必须记录）：**真实按键事件**（System Events 键盘事件，走 App 的文本输入链），**未使用 AX `setValue`**。按钮动作为 AX `AXPress`（框架真实动作）。上一轮已证伪的 AX 文本注入本轮**未使用**。

> 输入法事实：本机输入源为 Rime（Squirrel），`//`、字母会被合成拼音（实测键入长路径得到 `///.//让-把它茬吖/没`）。本轮按 Owner 授权把输入源临时切到 `ABC` 完成键入，结束后已切回 Rime。这是**验收方法**的约束，不是产品行为。

| 步骤 | 操作 | 观察 | 判定 |
| --- | --- | --- | --- |
| 1 | 打开 **Read Scope…** | 三个字段为空，无红色错误，Confirm 可点 | PASS |
| 2 | 直接 Confirm | sheet 不关闭；出现 `Enter a database UUID, a name and at least one group component.` | PASS |
| 3 | UUID 键入 `not-a-uuid`，其余填好 | 红色错误持续显示（`invalidUUID`）；sheet 不关闭 | PASS |
| 4 | UUID 改为隔离库 UUID，名称与组路径填 `Forma_I1B2/r1` | **错误提示没有消失**（见缺陷 A）；Confirm 后 sheet 关闭，横幅出现 `Read scope: Forma_I1B2_Sandbox · Forma_I1B2/r1` | **FAIL（仅"错误消失"一项）** |
| 5 | **Recheck read-only** | 未授予桌面访问时：`Read-only check inconclusive: 1 unverifiable`；Owner 授权桌面访问后：**`Read-only check conclusive: 1 verified`** | PASS |
| 6 | 重新打开后 Cancel | 草稿为空；关闭后横幅仍是已确认范围 | PASS |
| 7 | 同一范围再确认一次 | 允许；sheet 关闭，横幅范围不变 | PASS |
| 8 | 全程写调用 | DEVONthink 写工具 **0**；目标记录属性摘要前后逐字节相同；`r1` 组子项列表摘要前后相同；Ledger 仍 `verify_required`、attempts 0 | PASS |

### 缺陷 A（现场新发现，未修）

"恢复读范围"表单的红色错误在表单**已经合法**后仍不消失，直到按下 Confirm。

- 根因：`RecoveryScopeSheet.isInvalid` 同时读 `state.recoveryReviewReason == "invalid_scope"` 与 `draft.validation == .invalidUUID`。第 2 步的空表单 Confirm 把 reason 置为 `invalid_scope`，该值只在成功确认时清除，因此表单合法后仍渲染错误文案。
- 影响：与 `docs/R1-GUI-VERIFICATION.md` §4 第 4 步"错误消失"的预期相反；用户会把"已经填对"读成"仍然填错"。
- 建议修法（未实施）：错误显示只由 `draft.validation` 决定；`recoveryReviewReason` 只作为横幅理由，或在草稿变更时清除。

## 5. DEVONthink 读写调用统计

| 类别 | 次数 |
| --- | --- |
| 写工具（`import_file` / `create_group_path` / `set_record_custom_metadata` / `move_record` / `trash_record` 等） | **0** |
| 生产库记录级查询 | **0** |
| 隔离库只读调用（本轮探针 + 应用回查） | `initialize`、`tools/list`、`get_databases`、`get_record_properties`、`get_record_parents`、`get_record_children`、`get_imported_record_path`；应用侧回查 3 次（2 次 inconclusive、1 次 verified） |
| 记录级写后核对 | 目标记录属性 JSON 摘要 `cb2d8868…` 前后一致；`r1` 子项摘要 `28275fdf…` 前后一致 |
| Keychain 修改 | 0 |
| 签名 / 公证 / 发布 | 0 |

服务端事实：`devonthink-mcp 1.0.0`，protocol `2025-06-18`，`tools/list` 62 个工具；隔离库名 `Forma_I1B2_Sandbox`，其 UUID 与既有合成 Ledger 夹具中的目标库 UUID **一致**（本文不记录该 UUID）。

## 6. 应用与 MCP 生命周期

| 项 | 结果 |
| --- | --- |
| `⌘Q` 退出 | 进程立即结束（`applicationWillTerminate` 路径），无残留 |
| 退出时 MCP 子进程 | 无（回查结束后子进程已自行退出） |
| 回查期间 MCP 子进程 | 观察到 1 个子进程（pid 记录于证据），回查结束即消失；有一次因系统弹窗被阻塞约 90s，弹窗关闭后仍正常退出，**未产生孤儿进程** |
| 重启后未决状态 | 横幅恢复 `Interrupted import operations` / `1 outcome unknown`；`import_operations.phase` 仍 `verify_required`、attempts 0 |
| 自动重试 | 无：两次启动后 Ledger 未变，应用启动不主动起 MCP 子进程 |
| 读范围持久化 | 不持久（session-only），重启后需重新确认，符合设计 |

## 7. Learning Loop 新观察（1 条，已具备证据）

触发条件 5（验收方法失效）。**不计入**历史校准案例。

```text
Failure:      本机（Rime/Squirrel 输入源）用 System Events 键入 ASCII 长串时，
              文本被输入法合成：输入 "…/m01" 得到 "///.//让-把它茬吖/没"，
              字段显示与预期不符，且不同 App 表现一致。
Root cause:   验收脚本假设"按键事件 == 字面文本"，忽略了输入法位于按键链上；
              同时 NSOpenPanel 的文本框由 openAndSavePanelService 承载，
              把 CGEvent 直接投递给 Forma 的 pid 不生效。
Prevention:   现场验收在键入前先确认输入源（本机 `im.rime...Squirrel.Hans`），
              需要 ASCII 时显式切到 ABC 并在结束后恢复；每条键入都要用
              字段内容 + 下游行为（Confirm 生效/错误消失）双向证明，
              不以"AX 里看得见"作为输入证据。
Evidence:      ~/.forma/evidence/r1-batch2a3/m01/ax-*（含 Goto 字段被合成的原始 AX 值）；
              ~/.forma/evidence/r1-batch2a3/tools/inputsource.swift；
              本文件 §4 输入方式说明。
Scope:        适用于任何有人在场的 macOS 验收；不适用于无 IME 的 CI 环境，
              也不适用于 AX setValue（那是另一类失效，见 #95）。
```

缺陷 A 属产品缺陷（非复发、非假 PASS），按 §4 缺陷条目记录，不计作 Lesson。

## 8. Batch 2B 前置条件判断

| 2A/2A.2 提出的前置项 | 本轮状态 |
| --- | --- |
| 1. 资源 bundle 布局 + CI 启动冒烟 | **满足**（原件现场 PASS） |
| 2. 删除根目录分类 `.missing` | **满足**（现场 UI 为 `Folder not found`，历史保留） |
| 3. Keychain 可访问性契约 | 已按三态契约修复并有测试；**本轮未复测**（现场未做 M02） |
| 4. GUI 真实键入手段 | **满足（有约束）**：真实按键 + 输入源约束；缺陷 A 待修 |
| 5. macOS 14.x 运行时 | **仍 BLOCKED**（本机仅 27.0.1） |
| 外部卷 / iCloud 书签 | **仍 BLOCKED**（无隔离夹具） |

结论：**Batch 2B 的交互类前置条件已基本具备**，但仍有 3 项不满足或未覆盖：macOS 14.x（BLOCKED）、外部卷/iCloud（BLOCKED）、Keychain 现场复测（NOT_VERIFIED）；另有缺陷 A 建议先修再进入 Batch 2B 的 GUI 验收。**本轮不宣布 Release Ready。**

## 9. 文档纠错（§5）

`docs/R1-BATCH2A2-REPORT.md` 原引用不存在的 `docs/R1-BATCH2A-REPORT.md` §12.2 / §12.5 / §12.6（该文件 §12 只有一段"上一轮执行记录"，无子节）。已改为真实目标：

- 删除根目录与重授权 → `docs/R1-BATCH2A-REPORT.md` §2 + `Tests/FormaCoreTests/SourceAvailabilityClassificationTests.swift`
- Recovery 只读回查 → `docs/R1-BATCH2A-REPORT.md` §5 + `docs/R1-GUI-VERIFICATION.md` §4（步骤 4–5）
- 退出/重启/子进程 → `docs/R1-BATCH2A-REPORT.md` §5 对应两行 + `scripts/smoke_app.sh`

历史验收事实未改动，仅修正交叉引用。所有被引用的路径已逐一确认存在。

## 10. 证据索引（本机 `~/.forma/evidence/r1-batch2a3/`）

| 文件 | 内容 |
| --- | --- |
| `artifact/Forma-app-adhoc.tar.gz` | CI 原件（含 SHA-256 校验） |
| `verify-app-bundle.txt` / `smoke-app.txt` | 结构、严格验签、启动存活 |
| `m01/ax-*.txt`、`m01/scr-*.png` | 面板、扫描、`.missing`、`identityChanged`、`revoked`、重授权、身份不符 |
| `m01/entries-after-scan.json`、`m01/workspace-after-scan.sqlite` | 历史 entry ID 与扫描后数据库 |
| `m04/ax-*.txt` | 八步表单、错误提示、回查结果、重启恢复 |
| `m04/record-before.json` / `record-after.json`、`m04/r1-children-*.json` | 目标记录与组子项前后摘要 |
| `m04/mcp-child-pids.txt` | 回查期间子进程 pid 观察 |
| `host-facts.txt` | 主机与工具链事实 |
