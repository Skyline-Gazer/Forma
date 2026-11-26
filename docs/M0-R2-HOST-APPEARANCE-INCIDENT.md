# M0-R2 宿主外观污染事件报告（Host Appearance Incident）

- 日期：2026-11-26
- 权威候选：`93f049de5afca348a0b8c6183c46a26a06d9ea9a`（CI run `45735254099`，4/4 success）
- 制品：`Forma-app-adhoc.tar.gz`，SHA-256 `57f4e7dd72cb86686ca517f8a5d8a0f1aa1ee9069adcff97582c28c656d49249`；内部 `Contents/MacOS/Forma` SHA-256 `7b852f980bef5728fd1b17259db6b38130fb9b67ad2da52d0b8b800a0a82aa7f`（两者本机复算一致）
- 宿主：物理 MacBookPro18,3（`kern.hv_vmm_present=0`），macOS 27.2.1（26B131），arm64，Aqua，显示 3024×1964 Retina（1512×982 pt），仅 Command Line Tools（无 `xcodebuild`/Instruments）
- 关联：Issue #153（M0-R2 物理验收）、Issue #206 / PR #205（宿主状态治理）
- 本地工作区注意：本机仓库 `dev` 停在 `006d1ab`（早于候选），候选对象由 `origin` 取得；本报告所有候选侧结论均基于 `93f049d` 的对象内容，不基于本地工作树。

## 0. 结论状态

```
HOST_APPEARANCE_INTEGRITY=FAIL
  2026-11-25 14:49:05 (+0800) 全局外观被一条 ad-hoc 验收命令改为 Light；当前宿主仍为 Light。
  2026-11-26 13:16–13:22 的受控复现未再产生任何外观写入（GlobalPreferences mtime 未变）。

ROOT_CAUSE_VERIFICATION=PASS
  该次写入有「命令原文 + 统一日志跳变 + 前后截图」三重证据，写入者不是 Forma、不是 WindowConfigurator、不是仓库脚本。
  另有一次独立的系统级翻转（macOS 27.2.1 升级），与本仓库无关，见 §2。

PHYSICAL_ACCEPTANCE=PARTIAL
  8 步中 1/3/4/5 PASS，2 PASS(隔离前提未满足)，7 FAIL，6/8 NOT_VERIFIED（源目录已被系统清理）。
```

## 1. 谁改写了全局外观

### 1.1 确认的写入者：验收会话中的 ad-hoc 截图命令

会话 `01a1dd21-6fec`，调用 `a64b2222`，标签 “Capturing light and dark appearance”，本地时间 2026-11-25 14:49:00：

```sh
E=~/.forma/evidence/m0-r1; T=~/.forma/evidence/r1-batch2a3/tools; P=33072
$T/raise $P >/dev/null; sleep 0.8
screencapture -x -o -D 1 $E/U-light-review.png
osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true'
sleep 2
screencapture -x -o -D 1 $E/U-dark-review.png
osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to false'
sleep 1
ls -l $E/U-*.png
```

同一模式在 2026-11-24 01:10:49 与 01:11:35 已执行过两次（`set dark mode to true` + 截图，随后 `set dark mode to false`）。

证据链：

| 证据 | 内容 |
| --- | --- |
| 命令原文 | 上列；执行者是 Agent 的 `bash` 工具调用，不在 `~/.zsh_history` 中 |
| 统一日志 | `Post-registration system appearance`：14:49:05 出现 `HLTB: 1`（Light）；此前 14:27:20 为 `HLTB: 2`（Dark） |
| 截图 | `U-light-review.png`（14:49:01）与 `U-dark-review.png`（14:49:03）**画面均为深色**——所谓 “light” 抓拍发生在切换之前 |
| 终态 | 命令最后一步 `set dark mode to false` 把宿主留在 Light，且未恢复原值 |

因此既有 “Light/Dark 视觉检查” 不成立：两张图都不是浅色外观；该步骤同时是宿主外观被污染的触发点。

### 1.2 不是谁

- `93f049d` 全树检索 `AppleInterfaceStyle|NSAppearance|preferredColorScheme|appearance preferences|set dark mode|defaults write|defaults delete`，唯一命中是 `scripts/smoke_geometry.sh:51` 的 `defaults delete io.github.skyline-gazer.forma`——只作用于应用自身域，不涉及 `NSGlobalDomain`。
- Forma 应用代码无任何外观读写（无 `NSAppearance`、无 `preferredColorScheme`、无 `NSWindow.appearance`）。应用级 `preferredColorScheme` 也只能改自身窗口，不能改系统外观。
- `~/.zsh_history` 无 `AppleInterfaceStyle` / `appearance preferences` / `set dark mode` 记录；工作区内无相关脚本。
- 结论：WindowConfigurator / SwiftUI 不成立；仓库脚本不成立；触发者是验收用的临时命令（Agent 生成，未入库）。

### 1.3 第二次、独立的翻转：系统升级

| 时间（本地） | 事件 | 证据 |
| --- | --- | --- |
| 2026-11-26 11:09:25 | 升级前最后一个外观注册：`HLTB: 2`（Dark） | 统一日志 |
| 11:12:49 | 当前启动（boot time） | `kern.boottime` |
| 11:13:50 | `templateMigrator` 从 `/<Previous System>/Applications/Forma.app` 迁移应用 | 统一日志 |
| 11:14:19 | 登录后首个外观注册：`HLTB: 1`（Light） | 统一日志 |
| 11:16:58 | `.GlobalPreferences.plist` 重写且**不含** `AppleInterfaceStyle` | 文件 mtime + `plutil -p` |

即：14:49 的写入把宿主留在 Light；其后某个时刻外观回到 Dark（无 Agent 命令记录，判定为人工操作）；macOS 27.2.1 安装/登录又把它重置为 Light。升级重置属系统行为，不是本仓库缺陷，但它会再次覆盖 Owner 的手工选择，需在验收记录中分开计数。

## 2. 宿主现状（只读快照，2026-11-26 13:07–13:22）

```
ProductVersion 27.2.1  BuildVersion 26B131
AppleInterfaceStyle: absent            -> Light
AppleInterfaceStyleSwitchesAutomatically: absent -> Auto 关闭
per-app override (io.github.skyline-gazer.forma AppleInterfaceStyle): none
Forma 进程: none
~/Library/Saved Application State/io.github.skyline-gazer.forma.savedState: 不存在
```

## 3. 宿主安全审计：`scripts/smoke_geometry.sh` @ `93f049d`

### 3.1 已确认的破坏性行为

| # | 代码 | 物理 Mac 上的后果 | 与外观的关系 |
| --- | --- | --- | --- |
| 1 | `cleanup() { osascript -e 'tell application "Forma" to quit' … }`，启动前与 EXIT 各执行一次 | 按**名称**退出 Owner 正在使用的实例 | 无 |
| 2 | `defaults delete io.github.skyline-gazer.forma` | 清空测试者的应用域（窗口 frame、首启标记、资料库类型、Provider/Model、目录书签） | 仅应用域，不写全局 |
| 3 | `rm -rf "$HOME/Library/Saved Application State/io.github.skyline-gazer.forma.savedState"` | 无条件删除用户保存态 | 无 |
| 4 | `open`（无 `-n`）+ 按进程名匹配 + `pgrep -x Forma` | 可能驱动/测量到别人的实例 | 无 |
| 5 | 无运行模式区分 | CI 习惯可被直接搬到日常账户 | 无 |

### 3.2 它不会做的事

脚本不含任何 `defaults write`，不写 `NSGlobalDomain`，不调用 `System Events` 的 `appearance preferences`。**几何 smoke 不是外观污染源**；外观污染来自 §1.1 的临时命令。

### 3.3 静态门禁结果（同一份 `check_host_safety.sh`，PR #205 引入）

```
候选 93f049d：FAIL
  R3 rm -rf on a host Library path: scripts/smoke_geometry.sh:52
  R4 name-based app control:        scripts/smoke_geometry.sh:42
PR #205 (88ce271)：PASS
  no global appearance writes, no unscoped defaults deletes,
  no user saved-state removal, no name-based app control
```

注：`R2` 只白名单化 `defaults delete` 的域名，不区分 ci/mac；真正的保护是 PR #205 的 `FORMA_SMOKE_MODE=mac` 分支——该分支没有删除逻辑，且在任何 Forma 实例存在时拒绝运行（exit 3）。

### 3.4 运行前受保护的数据范围（本机实测）

应用域 20 个键，含 `NSWindow Frame workspace`（历史值 `1665 468`）、`NSSplitView Subview Frames workspace`、`shell.selectedArea`、`selectedSourceScope`、`mappingProvider/mappingModel/mappingPlannerMode`、`NSNavPanelExpandedSizeForOpenMode`、`NSOSPLastRootDirectory`；另有 `~/Library/Application Support/Forma` 下的工作区数据库。任何 `defaults delete` / saved-state 删除都会让 Owner 丢失这些状态，且无法从仓库重建。

## 4. 隔离方案

| 层级 | 用途 | 隔离强度 | 规则 |
| --- | --- | --- | --- |
| GitHub Actions `macos-15` | 编译、单测、打包、启动 smoke、几何 smoke（ci 模式） | 一次性 Runner，可重置 | 只有这里允许 `defaults delete` + saved-state 清理，且经精确域名/精确路径白名单 |
| 专用 macOS 测试用户 | 首启几何、首次捕获、偏好相关断言 | **唯一真正的本机隔离**（NSUserDefaults 按 uid 经 cfprefsd 解析） | 用 `FORMA_MAC_FIRST_LAUNCH_ACCOUNT=1` 才断言首启尺寸 |
| Owner 日常账户 | 只读观察、手工点击、截图 | 无隔离 | mac 模式：不删任何状态、只驱动自己启动的 pid、外观前后审计 |

单独设置 `HOME` **不构成** macOS 偏好隔离：`defaults` / cfprefsd 走 uid，不看 `$HOME`；`Saved Application State` 也只覆盖了路径这一半。TCC（Accessibility/Automation）同样按用户与父进程授权，测试账户中的授权不会泄漏到日常账户。

外观审计契约（已由 PR #205 实现）：
- 运行前后各读一次 `defaults read -g AppleInterfaceStyle` 与 app 域 override；
- 任一变化即 FAIL，打印两值与写入者线索；
- **绝不静默恢复**（静默恢复会掩盖下一次写入）；
- 任何需要改变外观的检查，只能在测试账户/虚拟机内执行，并由 Owner 明确授权。

## 5. 安全复现（Phase C）

使用 PR #205 的 mac 模式脚本（`88ce271`，未合入）驱动候选制品，脚本自身即外观审计器：

```
host appearance baseline: global=Light app-override=none
owned pid: 42688
launch size: 1180x700 (isolated first launch: false)
first-launch band SKIPPED: shared host, restored frame expected
inline gate: identifiers=0 ok=false        # System Events 整树遍历在该机取不到 AXIdentifier
...
after navigating to workspace: 1180x728
after navigating to mapping:   1180x728
after navigating to import:    1512x949    # 断言失败：width 1180 -> 1512
host appearance audit: unchanged (Light)
```

- 外观：运行前后均为 Light，app override 均为 none；`~/Library/Preferences/.GlobalPreferences.plist` 的 mtime 在整段复现（13:16–13:22）保持 `11:16:58` 未变——受控复现未产生任何全局偏好写入。
- 应用域 hash 变化（`2d55d751…` → `cfcf5561…`）来自**应用自身**保存新的窗口 frame（`0 0 1512 949`），不是脚本删除；`selectedSourceScope`、Provider/Model 等键均在。这是应用正常行为，脚本未触碰。
- 无新增崩溃报告（最新仍是 2026-11-25 15:54）。
- 未能定性：脚本路径下 1180 → 1512 的跳变。直接 AX API 复测（§6）在同一窗口、同一区域序列上没有复现；System Events 的整树 `entire contents` 风暴会反复触发 SwiftUI 重渲染（脚本注释已记录），因此该跳变目前记为 **harness 侧未定性**，不作为几何回归结论，也不排除是托管层的内容拟合。需要用 mac 模式 + 直接 AX 的门禁重跑一次才能定性。

## 6. M0-R2 物理验收（候选 `93f049d`，8 步）

| 步 | 项目 | 结果 | 实测 |
| --- | --- | --- | --- |
| 1 | 启动稳定性 | **PASS** | 多次 `open -n` 启动即起窗口，存活；全流程无 trap |
| 2 | 首启落在资料整理台、内容 ≈1180×700 | **PASS（隔离前提未满足）** | 首次启动测得 `1180×700`（当时保存 frame 为越界的 `1665×468`，被拒绝恢复）；第二次为合法 frame `1512×949` 的正常恢复。真正首启断言仍需专用测试账户 |
| 3 | 窗口用户控制 | **PASS（拖拽 NOT_VERIFIED）** | 760×500 请求 → 精确 clamp `1012×672`（设置页与映射页各一次）；1400×900 请求 → 保留 `1400×900`（与 CI 的 1024×676 回缩不同，正是 Owner 关心的“粘性”）；鼠标拖边框未执行 |
| 4 | 六区导航 | **PASS** | 逐区选中后各页面出现自身 AX 子树：资料整理 14 个内容节点、工作区（来源不可用横幅 + 文件树）、映射（修订/上下文表）、归档 4、诊断、设置 1；1180×728 下六区宽度恒为 `1180×728`；连续 102 次切换后 frame 仍 `1180×728`，进程存活 |
| 5 | 崩溃栈比对 | **PASS** | 无崩溃；`DiagnosticReports` 最新仍是 2026-11-25 的 4 份 |
| 6 | 证据重读恢复（#173） | **NOT_VERIFIED** | 上次验收的合成源 `…/forma-m0-fixture/示例项目_2026` 已被系统清理，工作区正确显示「找不到该文件夹」；重新登记目录要驱动 `NSOpenPanel`，仓库文档已记录该路径不可自动化。未用删偏好/删库的方式伪造 |
| 7 | 混合语言 UI（#175） | **FAIL** | 来源映射出现成片英文可见标签：`Schema`、`Profile`、`CasePack`、`Provider`、`Model`、`Context revision`、`Prompt version`、`Extractor version`、`Redaction version`、`No value`；工作区出现英文散文 `Members disagree about the project` / `No candidate FormaCore could defend`。`资料库类型` 值 `Project Archive` 属机器值，按 #153 约定可保留 |
| 8 | TXT 证据（#176） | **NOT_VERIFIED** | 同步骤 6 的源目录阻塞；TXT 行进不了“可引用”状态，字符定位无法验证 |

补充事实：`spctl -a -t exec` = rejected（ad-hoc，符合预期）；`codesign --verify --deep --strict` = valid；无 `com.apple.quarantine`；应用 0.1.0 (1)；当前 frame `0,33 1180×728` 完整在屏内。

## 7. 对既有 M0-R2 验收的影响

1. `U-light-review.png` / `U-dark-review.png` **不能**作为明暗外观验收证据：两张都是深色，且拍摄过程改写了宿主外观。需在测试账户内重拍，并附 `defaults read -g AppleInterfaceStyle` 前后值。
2. 几何结论未被污染：CI 的 1180/1012/1024 断言与本次物理结果（1180 宽度不变、1012 精确 clamp、1400 保留）一致方向；M0-R1 的 1665/1645 属 `0ac64c4`，已被候选取代。
3. 步骤 6/8 的阻塞是**环境**（源目录被系统清理）而非候选缺陷；恢复方式是在测试账户内用 `~/.forma/evidence/m0-r2-fixtures/docs` 重新登记来源后重跑，不需要改应用。
4. PR #205 未合入：在它合入前，任何人不得在日常账户直接运行 `scripts/smoke_geometry.sh`（候选 tip 版本会删应用偏好与保存态）。
5. 外观污染不改变候选的源码结论，也不构成合并/发布授权；本报告未改动任何全局外观、未删除用户配置、未合并 PR。

## 8. 未决项

| 项目 | 状态 | 下一步 |
| --- | --- | --- |
| 14:49 之后回到 Dark 的写入者 | 未证实 | 无 Agent 命令记录；日志只保留“注册值”，建议 Owner 确认是否为人工操作 |
| 脚本路径下 1180→1512 跳变 | 未定性 | 用 mac 模式 + 直接 AX 门禁重跑；同时记录 System Events 遍历次数 |
| 首启 1180×700 的隔离证据 | PARTIAL | 在专用测试用户内以 `FORMA_MAC_FIRST_LAUNCH_ACCOUNT=1` 执行 |
| 步骤 6/8 | NOT_VERIFIED | 测试账户内重建合成源后重跑 |
| 混合语言残留 | FAIL | 归 #175；本次给出具体字符串清单 |
| 鼠标拖拽 / 分屏 / 全屏 / VoiceOver | NOT_VERIFIED | 需 Owner 手工或带 TCC 的交互会话 |

## 9. 证据位置（本机，仅合成内容）

`~/.forma/evidence/m0-r2-acceptance/`：`session.log`、`mac-mode-run.log`、`pre-run-baseline.txt`、`identifiers.txt`、`tree-*.txt`（六区 AX 子树）、`nav-*.png` + `area-*.png`（六区截图）、`final-review.png`。
