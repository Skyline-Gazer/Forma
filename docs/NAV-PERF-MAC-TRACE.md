# D2 导航性能现场测量配方（NAV-PERF-MAC-TRACE）

状态：**待执行**。本文件是 Issue #151（Phase 2 / D2，父计划 #148）的 Mac 侧执行配方，对应 `MACOS-VALIDATION-BACKLOG` 的 **M13**。它描述如何采集与判定，不声称任何数字已经采集。

> 一句话边界：DevBox 与 GitHub CI 能证明的只有「编译通过 + 状态规则与投影结果的确定性测试」。
> **窗口帧稳定性、真实切换延迟、Instruments 里的任何数字一律是 `NOT_VERIFIED`，直到在 Owner Mac 上按本文件跑完并回填 M13。**
> 用 CI 绿替代现场结论，是 #151 明确禁止的验收方式。

## 0. 仪器是什么（先读代码再读轨道）

 instrumentation 只有两条通道，都在 `FormaApp/Sources/Forma/FormaPerf.swift`，由 `Sources/FormaCore/Presentation/PerfTrace.swift` 驱动：

- **os_signpost**：subsystem `com.forma.perf`，category `Navigation`。名字全部是编译期字面量（`StaticString`），因此不可能携带路径、文件名、UUID 或 token。
- **os_log**：同一 subsystem / category，携带计数（`count=` 与 `shortCircuited=`），用来区分 6 文件与 1,000 文件两种规模。

可观测的名字（这是全部；新增一个就必须同时新增一处 `PerfFact.Stage` 与其测试）：

| 类型 | 名字 | 含义 |
| --- | --- | --- |
| event | `area-switch` | 区域切换发生了，规则没有排任何工作 |
| event | `panel-appearance` | 某个区域内容出现（过去这里会重读证据注册表） |
| event | `evidence-cache-hit` | 命中 `(source, snapshot revision)` 缓存，未读注册表 |
| event | `evidence-load-coalesced` | 同一 key 的读取已在飞行中，本次并入 |
| event | `evidence-load-stale` | 读取返回时 key 已移动，结果被丢弃 |
| interval | `evidence-load` | 一次注册表读取的跨度 |
| interval | `refresh-rows` | 映射行与例外行重建 |
| interval | `reload-listing` / `reload-context` / `reload-manifest` | `reload()` 的三个阶段 |
| interval | `export-bundle` / `revalidate-bundle` | 离线导出与复检（已移出主线程） |
| event | `progress-coalesced` | 被进度合并抑制的整模型发布次数 |

CI 侧的对应物：`Tests/FormaCoreTests/ShellNavigationTests.swift`（切换不排工作、计数、发布与重载合并、事实字段无路径）与 `Tests/FormaCoreTests/WorkspaceProjectionTests.swift`（索引结果与旧逐条扫描结果逐字段相等，且代价是线性形状）。它们证明**规则与形状**，不证明**速度**。

## 1. 前置条件（执行前逐条确认并记录）

1. macOS 15.x：`sw_vers -productVersion`；架构 `uname -m`；记录机器型号。
2. Xcode 26.3（与 CI 同一工具链口径）：`xcodebuild -version`、`swift --version`。工具链不一致时，本文件的结果只能在同版本间比较。
3. 仓库位于包含 #157（D1 shell）与 #155（技能 pin）合入后的 `dev`：`git log -1 --format=%H`。
4. 构建应用：`./scripts/build_app.sh`（产物路径以脚本输出为准）。合成夹具用**匿名**目录，例如 `mktemp -d` 下生成的 6 个与 1,000 个占位文本文件；不使用任何真实业务目录。
5. 关掉可能干扰计量的东西：其他大型应用、屏幕录制、iCloud 同步风暴；电源接交流电。

## 2. 技能脚本安装与「先看再跑」门槛

技能按 #155 引入的 `scripts/install_skills.sh` 安装，固定 SHA `62bd760f005093d1e2e4de5db156e456a5f96400`（`AvdLee/SwiftUI-Agent-Skill`），落地目录 `.agents/skills`，技能名 `skills/swiftui-expert-skill`，其追踪脚本为 `scripts/record_trace.py` 与 `scripts/analyze_trace.py`，配套 `references/trace-recording.md`、`references/trace-analysis.md`。

**硬性门槛：第一次运行前必须自己读完这三样**：

```bash
sed -n '1,200p' .agents/skills/skills/swiftui-expert-skill/references/trace-recording.md
sed -n '1,200p' .agents/skills/skills/swiftui-expert-skill/references/trace-analysis.md
python3 .agents/skills/skills/swiftui-expert-skill/scripts/record_trace.py --help
python3 .agents/skills/skills/swiftui-expert-skill/scripts/analyze_trace.py --help
```

原因：脚本参数随上游版本变化，本文件不复制它们的签名。下文只描述**需要覆盖的能力**（录制 macOS 应用、按名字列 signpost、按时间窗过滤、两次 trace 对比）；若 help 里的旗标名与此处不同，**以 help 为准**，并在 M13 记录里写下实际使用的命令行。特别注意：上游录制脚本可能默认面向 iOS 模板，macOS 采集必须显式选择 macOS 模板或以 `--attach` 附加到已启动的 Forma，否则拿到的是空轨道。

## 3. 采集流程（每轮都记录开始时间戳）

### 3.1 冷启动一轮

1. 启动 Forma（打开合成 bundle 前）。开始录制（脚本或 Instruments 的 Time Profiler + os_signpost 模板）。
2. 依次：选择 scope → 触发扫描 → 让上下文与 manifest 就绪 → 打开 6 文件 bundle。
3. 停止录制。关注 `reload-listing` / `reload-context` / `reload-manifest` 三个区间是否首尾相接、有无重叠重复（#151 审计项 5 的重复重载）。

### 3.2 热切换 100 次（#151 的核心目标）

1. 在 Workspace 与 Mapping 之间来回点击侧栏 100 次（约每秒 1–2 次，不要拖动窗口）。
2. 结束录制。期望：
   - `area-switch` 事件 = 100 次；
   - **每次切换之间没有** `evidence-load` 区间、没有 `refresh-rows` 区间、没有任何扫描/映射/重载区间；
   - `evidence-cache-hit` 只应出现在重新出现同一文件详情时；
   - oslog 里不出现任何路径、文件名、token（若出现即 **FAIL**，见 §5）。
3. 从 `area-switch` 事件序列计算相邻切换的 UI 响应延迟（Instruments 的 SwiftUI/Hang 轨道或脚本时间窗），取 **median 与 p95**。目标线：**warm p95 ≤ 150 ms（6 文件夹具）**。这是目标，不是承诺；未达到就记 `FAIL` 并附数据。

### 3.3 20 次分栏拖拽（帧检查）

拖拽 sidebar / detail 分隔柱与 inspector 边缘共 20 次，覆盖最小、默认、宽三种宽度与明暗模式。检查项：拖拽期间无掉帧尖峰群（System Trace / Hang 轨道），外窗尺寸不变（M12/#151 同源），拖拽结束后不触发 `refresh-rows`。

### 3.4 规模对比：6 文件 vs 1,000 文件

同一轮步骤分别对 6 文件与 1,000 条合成记录的 bundle 执行：打开 bundle、一次 `refresh-rows`、导出、复检。用脚本的对比能力（`--diff` 一类）对齐两份 trace，看的是**增长形状**：

| 观测 | 期望形状 |
| --- | --- |
| `refresh-rows` 跨度 | 线性，不出现按行数平方放大的台阶 |
| `evidence-load` 次数（重看同一文件 100 次） | 6 文件与 1,000 文件都应为 1 次 |
| 导出 / 复检的主线程占用 | 主线程不应被 `export-bundle` / `revalidate-bundle` 阻塞（审计项 4） |
| Keychain 保存、bundle 读取 | 不出现在主线程采样栈里 |

### 3.5 状态自检（与 trace 并行）

现场同时看应用自己的账：`model.shellState.counters` 与 `model.workCounters` 的差值。切换区域后两者对 scan / context / mapping / reload / export 的增量都必须是 **0**。若 trace 显示有工作而账上为 0，说明工作从规则之外进来（视图里残留的 `.task`），同样要记 `FAIL` 并定位到具体 view。

## 4. 判定与记录

每个步骤给出四种状态之一，不允许混用：

- **PASS** — 数字达到 §3 的目标，且隐私检查无泄漏。
- **FAIL** — 未达到目标、出现不该出现的区间、或 oslog/signpost 携带了标识符。FAIL 必须附证据（trace 路径 + 哪个名字/多久）并回到代码修，不得改本文件的期望值来迁就结果。
- **BLOCKED** — 环境不具备（缺技能脚本、Xcode 版本不符、无 `.trace` 权限）。写清缺什么。
- **NOT_VERIFIED** — 尚未执行。**任何**未在 Mac 上跑过的项都是这个状态，包括 CI 全绿的时候。

回填到 `MACOS-VALIDATION-BACKLOG.md` 的 M13：执行日期、macOS/Xcode 版本、bundle 规模、实际命令行、trace 与统计文件的位置、每个步骤的状态与数字（median/p95/区间时长）。

## 5. 隐私红线（一次泄漏即失败）

- signpost 名字只允许来自 `FormaPerf.name(_:)` 的字面量表；任何带 `String` 参数的 API 都不存在，这是机制而非约定。
- 若 trace 或 oslog 出现真实路径、文件名、项目名、UUID 或凭据：**停止**，把 §3 全部标记 `FAIL`，删掉证据文件，回到 `PerfTrace` / `FormaPerf` 修复并补测试，然后重跑。
- `.trace` 文件本身是用户数据：留在本地，不提交仓库，不放进 issue 附件。

## 6. 本文件不覆盖的内容

- 10,000 文件真实目录的扫描验收仍是 **M9**（#20 / P3-A），不在 #151 范围。
- 窗口尺寸、VoiceOver、inspector 折叠等交互核验属于 **M12**（#150）。
- 把状态族拆成子模型或迁移 `@Observable` 属于 **D4（#154）**；本轮只做发布合并，若 §3.2/§3.3 的数据仍指向整模型广播，请把证据带回 D4 而不是在 D2 里加抽象层。
