# Forma — Issue / PR Disposition & GitHub Project #18 Reconciliation

- **Canonical Spec**: `docs/specs/2026-11-27-workbuddy-edition.md` (`110a469208a944a485b4389779795174dad7bc5b`)
- **Active Program**: [#217](https://github.com/Skyline-Gazer/Forma/issues/217)
- **GitHub Project**: [#18](https://github.com/orgs/Skyline-Gazer/projects/18) (`PVT_kwDOEwGMMc4BtHPl`)

---

## 1. Branch & Task Mapping

| Branch | Base / Origin | Purpose | Linked Issues |
|---|---|---|---|
| `main` | `38d455304bc4530b71e584c07de48fc06fd1f293` | Protected baseline (unchanged) | — |
| `dev` | `0ac64c4d0dffa02d6f2785aad28bd8ea44ceaa59` | Legacy SwiftUI line (frozen, unchanged) | `#144`, `#148`, `#153` |
| `workbuddy/dev` | `46ec2301b916aff191badfbc0eb678a83c72899b` | Active WorkBuddy Edition development trunk (PR #222, #224, #225 merged) | `#217` |
| `workbuddy/feat/contract-consolidation-20261128` | PR #226 → `workbuddy/dev` | Final Canonical Spec closure, Organization Profile 1.0 candidate & governance alignment | `#217`, `#220`, `#215` |
| `workbuddy/feat/m1-feasibility-and-core` *(completed/merged)* | PR #222 | `M1-A` Host Feasibility → `M1-B` Residual Tooling | `#218` *(Closed / Done)* |
| `workbuddy/feat/m2-expert-package` *(completed/merged)* | PR #222 | M2 Expert Package, Skills, Validator & Zip | `#219` *(Closed / Done)* |
| `workbuddy/feat/m3-mac-alpha` *(planned)* | Integrated `workbuddy/dev` HEAD (post-§10.8 P0 convergence & package rebuild) | M3 P0 safety convergence, Mac Installation & 29-Doc Alpha E2E + DEVONthink publication/readback + Owner UX | `#220` *(Todo)*, `#215` *(Blocked on #220)*, `#213`–`#214` |

---

## 2. Open Issues Disposition Matrix (All 46 Open Issues)

| # | Title | Classification | Rationale | Project #18 Disposition |
|---|---|---|---|---|
| `#217` | `[Program][P0] Forma WorkBuddy Edition — Expert alpha, reuse-first implementation` | **Active** | 新版实施主任务（Spec §8） | Add → `In Progress` (`P0`, `Track C`) |
| `#218` | `[WorkBuddy][P0][M1] M1-A host feasibility & M1-B residual deterministic tooling` | **Closed (Done)** | `M1-A` 与 `M1-B` 工程基线已合入 `workbuddy/dev`（PR #222）；残余 P0 安全收敛转由 `#220` / Spec §10.8 追踪 | `Done` (`P0`) |
| `#219` | `[WorkBuddy][P0][M2] WorkBuddy Expert package, Skills, reproducible packaging & Linux CI verification` | **Closed (Done)** | M2 打包与 CI 已合入 `workbuddy/dev`（PR #222）；后续包重建随 `#220` 验收 | `Done` (`P0`) |
| `#220` | `[WorkBuddy][P0][M3] Mac WorkBuddy client installation, 29-doc Alpha E2E & Owner UX acceptance` | **Active (Open)** | 追踪 Spec §10.8 确定性安全收敛、真实审批边界验证与 Mac 完整产品验收（含 DEVONthink 闭环）；27/2 预览仅作回归证据（Spec §10.11），须以合并后重建包复测 | `Todo` (`P0`) |
| `#213` | `[WorkBuddy][P0][#213] WorkBuddy semantic acceptance & 100–200 doc blind holdout` | **Active (Gated)** | 已移除 `Start now` 与主动 Sorty 指令（历史记录保留）；保留独立盲测与增量更新门禁，仅在 `#220` (`M3` Owner UX 批准) 后启动 | `Blocked` (`P0`) |
| `#214` | `[WorkBuddy][P0][#214] DEVONthink Index + OneDrive — physical storage and fresh-device recovery` | **Active (Gated)** | 归属对齐 `#217`，保留存储/恢复门禁与 `dae571dc` 证据；OneDrive 仍为 `NOT_VERIFIED`，受真实环境阻塞（不阻塞本地隔离交付） | `Blocked` (`P0`) |
| `#215` | `[WorkBuddy][P0][#215] WorkBuddy -> DEVONthink metadata identity, publication & readback` | **Active (Current Product Delivery)** | 当前 DEVONthink 产品交付能力（非延期可选功能，Spec §10.13）：4.4.2 内置 MCP 优先、Index 原件、12 字段白名单 + Tags、强制独立回读与本地 MCP 安全边界 | `Blocked` (`P0`, gated on `#220` P0 convergence) |
| `#216` | `[Adoption][P0][D] Reuse-first decision, cost comparison and ADS consumer evidence` | **Active** | 承接最终采用决策与成本对比 | Keep `Blocked` (`P0`, awaits M3/213-215) |
| `#98` | `governance: ADS Learning Loop pilot (3–5 real deliveries)` | **Active** | 持续适用（按触发条件记录，不设新门禁） | Keep `In Progress` (`P1`) |
| `#212` | `[Program][P0] Reuse-first adoption gate — Sorty / DEVONthink Index / OneDrive` | **Superseded** | 转为历史决策父节点，主动执行移交 `#217`（保留历史） | Move `In Progress` → `Backlog` (`P0`) |
| `#10` | `[E0] 核对 DEVONthink MCP 只读能力、隔离库与 12 字段契约` | **Reusable Evidence** | 62 工具快照与字段契约可作 `#215` 输入（不直接宣称完成） | Keep `Blocked` (`P2`) |
| `#11` | `[E0] 双 Provider 与 PDF/DOCX/XLSX 抽取能力探针` | **Reusable Evidence** | 解析/Egress 契约可参考，实时 Key 探针被 WorkBuddy 路由替代 | Keep `Blocked` (`P2`) |
| `#19` | `[E4] 建立独立 Gold 分层评测与模型效果报告` | **Reusable Evidence** | 统计/门禁设计可参考用于 `#213` 盲测 | Keep `Blocked` (`P2`) |
| `#20` | `[E4] 测量扫描、OneDrive hydration、AI 成本/延迟和脱敏差异` | **Reusable Evidence** | 指标采集设计可参考用于 `#213`/`#214` | Keep `Blocked` (`P2`) |
| `#22` | `[E5] 实现 Preflight、single-writer、幂等 Ledger 与四态恢复` | **Reusable Evidence** | 强复用输入（防呆/日志/四态仲裁契约直接指导 `M1`） | Keep `Blocked` (`P2`) |
| `#51` | `[P3-A / I1] Mole-inspired Import Eligibility Policy — 缓存与非业务工件排除` | **Reusable Evidence** | `forma-eligibility.v1.json` 直接被 `M1` 复用 | Move `In Review` → `Backlog` (`P1`) |
| `#129` | `[E4 / M11] OneDrive FileProvider 独立验收矩阵与标记读取物化风险（dataless）` | **Reusable Evidence** | `SF_DATALESS` 检测与 8 行验收矩阵输入 `#214` | Move `In Review` → `Backlog` (`P1`) |
| `#130` | `[P3-A / M11] 本地 APFS 实体范围验收：与 FileProvider 样本对照` | **Reusable Evidence** | APFS 碰撞/symlink 夹具设计输入 `M1`/`#214` | Move `In Review` → `Backlog` (`P1`) |
| `#131` | `[P3-A / I1] 生成型诊断目录分类候选策略（log/ini/csv）` | **Reusable Evidence** | 噪声目录 `REVIEW` 策略输入 `M1` | Move `In Review` → `Backlog` (`P1`) |
| `#136` | `m11(level4): 探测预算外的记录计入 include，报告口径未区分` | **Reusable Evidence** | 已知口径缺陷，纳入 `M1` 复用修复 | Move `Todo` → `Backlog` (`P1`) |
| `#183` | `[CI flake][P2] EvaluationRunnerTests 墙钟边界断言间歇超时` | **Reusable Evidence** | 仅提醒移植测试时放宽墙钟容差；未在 Project #18 | Not in Project (no add needed) |
| `#206` | `Host safety: geometry smoke mutates physical-host state` | **Reusable Evidence** | 宿主安全隔离原则直接指导 `M3` Mac 验收 | Move `In Progress` → `Backlog` |
| `#2` | `[Epic E0 / P0] 契约与只读能力验证` | **Superseded** | 旧独立 App E0 史诗，已由 `#217` 替代（不标 Done） | Keep `Blocked` (`P2`) |
| `#4` | `[Epic E2 / P2] AI Mapping 与 Manifest 核心` | **Superseded** | 核心思想被 `M1`/`M2` 吸收，旧史诗不再推进 | Keep `Blocked` (`P2`) |
| `#6` | `[Epic E4 / P3] 独立质量评测与性能成本基线` | **Superseded** | 评测目标并入 `#213`/`#216` | Keep `Blocked` (`P2`) |
| `#7` | `[Epic E5 / I1] 可靠 Import 与读回验收` | **Superseded** | 目标并入 `M1`/`#215` | Keep `Blocked` (`P2`) |
| `#8` | `[Epic E6 / I2] 跨项目关联与可选 Replicant` | **Superseded** | 旧 E6 史诗（Replicant 非 Alpha 范围） | Keep `Blocked` (`P3`) |
| `#23` | `[E6] 实现 Project Association 导出对账及可选 Replicant 验证` | **Superseded** | 非 WorkBuddy Alpha 范围 | Keep `Blocked` (`P3`) |
| `#5` | `[Epic E3 / P2] 原生工作界面与纠正闭环` | **Legacy Frozen** | 旧 SwiftUI 原生界面路线冻结（Spec §8） | Move `Awaiting Acceptance` → `Backlog` (`P0`) |
| `#9` | `[Epic E7 / R1] macOS 发行、安全与退出恢复` | **Legacy Frozen** | 旧独立 `.app` 发行路线冻结 | Keep `Blocked` (`P2`) |
| `#24` | `[E7] 原生应用发行、授权与退出恢复验证` | **Legacy Frozen** | 旧独立 `.app` 发行验证冻结 | Keep `Blocked` (`P2`) |
| `#52` | `[R1 / V7] Commercial Mac App Store licensing, attributions & sandbox feasibility` | **Legacy Frozen** | 旧 MAS 发行调研冻结 | Keep `Blocked` (`P2`) |
| `#144` | `[UX Recovery] 将 Forma Alpha 从工程控制台重构为文档审核工作台` | **Legacy Frozen** | 旧原生 UI 恢复冻结 | Move `Awaiting Acceptance` → `Backlog` (`P0`) |
| `#148` | `[Program][Owner 2026-11-23] AI-native Forma · DevBox-first UI/UX Recovery` | **Legacy Frozen** | 旧原生 UI 计划冻结 | Move `Awaiting Acceptance` → `Backlog` (`P0`) |
| `#153` | `[M0][macOS FINAL ONLY] Forma native GUI, Instruments & field acceptance` | **Legacy Frozen** | 旧原生 GUI Mac 验收冻结 | Move `Awaiting Acceptance` → `Backlog` (`P0`) |
| `#172` | `[M0-R2 defect][P0] 外层窗口最小值取内容拟合宽度` | **Legacy Frozen** | 旧 SwiftUI 窗口缺陷冻结 | Move `In Review` → `Backlog` |
| `#173` | `[M0-R2 defect][P0] 源文件变更后重读证据不可恢复` | **Legacy Frozen** | 旧 WorkspaceModel 缺陷冻结（`M1` 计划已内置修正机制） | Move `In Review` → `Backlog` |
| `#174` | `[M0-R2 defect][P0] 约束更新期 SIGABRT` | **Legacy Frozen** | 旧 AppKit/SwiftUI 崩溃冻结 | Move `In Progress` → `Backlog` |
| `#175` | `[M0-R2 defect][P1] 普通工作流中英混杂` | **Legacy Frozen** | 旧原生 UI 文案冻结 | Move `In Review` → `Backlog` |
| `#176` | `[M0-R2 defect][P2] TXT 证据白名单挡下` | **Legacy Frozen** | 旧 WorkspaceView 缺陷冻结（`M1` 原生支持 TXT） | Move `In Review` → `Backlog` |
| `#208` | `[M0-R3][P1] Inspector 与主内容布局边界异常` | **Legacy Frozen** | 旧 SwiftUI 布局反馈冻结 | Not in Project (frozen) |
| `#209` | `[M0-R3][P1] 公共 Toolbar 视觉与交互契约不统一` | **Legacy Frozen** | 旧 SwiftUI Toolbar 反馈冻结 | Not in Project (frozen) |
| `#210` | `[M0-R3][P1] Settings 页面留白过多` | **Legacy Frozen** | 旧 SwiftUI Settings 反馈冻结 | Not in Project (frozen) |
| `#211` | `[M0-R3][P1] Product UX convergence` | **Legacy Frozen** | 旧原生界面架构反馈冻结 | Not in Project (frozen) |
| `#133` | `[Future / Research] 多版本文档增量存储与去重（CDC / CAS / CDP）` | **Deferred Research** | 远期研究，非当前范围 | Keep `Backlog` (`P3`) |
| `#162` | `[Future / Research] Embedding API + Hybrid Retrieval` | **Deferred Research** | 远期研究，未授权启动 | Keep `Backlog` (`P3`) |

---

## 3. Open PRs Disposition Matrix (All 9 Open PRs)

| PR # | Head → Base | Draft | Disposition | Reusable Patch / Value | Reason Preserved Unmerged |
|---|---|---|---|---|---|
| `#132` | `feat/m11-evidence-statistics` → `dev` | No | **Reusable Evidence — Unmerged** | `#136` 误排除统计口径文档说明 | 属旧 M11 轨道，待 `M1` 在 Python CLI 直接修口径 |
| `#135` | `test/m11-acceptance-preparation` → `dev` | No | **Reusable Evidence — Unmerged** | `#129`/`#130`/`#131` OneDrive 8 行矩阵与 APFS 夹具设计 | 直接作 `#214` 与 `M1` 输入，不合入旧 `dev` |
| `#166` | `docs/skills-host-merged` → `dev` | Yes | **Legacy Frozen — Do Not Merge** | 记录旧 SwiftUI Skills 安装脚本 | 对应旧原生路线，保留历史 |
| `#177` | `fix/m0r2-window-layout` → `dev` | No | **Legacy Frozen — Do Not Merge** | 无（SwiftUI 窗口约束） | 旧 UI 路线冻结 |
| `#178` | `fix/m0r2-evidence-recovery` → `dev` | No | **Legacy Frozen — Do Not Merge** | 重读证据刷新思路可供参考 | 旧 UI/Workspace 路线冻结 |
| `#179` | `fix/m0r2-product-language` → `dev` | No | **Legacy Frozen — Do Not Merge** | 中文产品术语表可供 `M2` Skill 参考 | 旧 UI 路线冻结 |
| `#180` | `integration/m0r2-candidate` → `dev` | Yes | **Legacy Frozen — Do Not Merge** | M0-R2 集成候选快照 | Spec §4/§8 明令禁止合入旧集成候选 |
| `#205` | `fix/host-safety-isolation` → `fix/m0r2-window-layout` | No | **Reusable Evidence — Unmerged** | `#206` 宿主安全隔离模式（`ci`/`mac` 分离与 pid 清理） | 借鉴其隔离原则用于 `M3`，不合入旧分支 |
| `#207` | `docs/m0r2-host-appearance-incident` → `dev` | Yes | **Legacy Frozen — Do Not Merge** | 宿主外观污染事故教训 | 警醒 `M3` 禁止修改全局宿主状态 |

---

## 4. Project #18 Reconciliation (Before vs After)

已通过 `gh project` CLI 核对并完成更新（Project ID: `PVT_kwDOEwGMMc4BtHPl`，`0` 项失败）：

### 4.1 Status Count Comparison

| Status | Before | After | Delta & Rationale |
|---|---:|---:|---|
| `Awaiting Acceptance` | 4 | 0 | `-4`：旧原生 UI 路线 `#5`, `#144`, `#148`, `#153` 移入 `Backlog`（冻结，未标 `Done`） |
| `In Review` | 8 | 0 | `-8`：旧 M0-R2 缺陷 `#172`, `#173`, `#175`, `#176` 与可复用输入 `#51`, `#129`, `#130`, `#131` 移入 `Backlog` |
| `In Progress` | 7 | 2 | `-5`：`#212` 移入 `Backlog`，`#174`/`#206` 移入 `Backlog`，`#213`–`#215` 移入 `Blocked`（受 `#220`/环境阻塞）；仅 `#217`, `#98` 处于活动状态 |
| `Todo` | 1 | 3 | `-1`（`#136` 移入 `Backlog`），`+3`（新建待批实施任务 `#218` [`M1-A`→`M1-B`], `#219` [`M2`], `#220` [`M3`]） |
| `Blocked` | 15 | 18 | `+3`：`#213`, `#214`, `#215`（与 `#216` 及历史阻塞/替代史诗 `#2, #4, #6–#11, #19, #20, #22–#24, #52` 共 18 项） |
| `Backlog` | 2 | 18 | `+16`：保留 `#133`, `#162`，并接纳冻结/过渡/可复用输入条目 |
| `Done` | 16 | 16 | 不变：未重开任何已完成历史条目（`#3, #12–#18, #21, #29, #138, #145, #149–#152`） |
| **Total** | **53** | **57** | **`+4`**（`#217`, `#218`, `#219`, `#220`） |

### 4.2 Newly Added / Created Items

| Issue | Status | Priority | Project Item ID | Scope / Constraint |
|---|---|---|---|---|
| `#217` | `In Progress` | `P0` | `PVTI_lADOEwGMMc4BtHPlzhMWrm8` | Active Program（`Track C · ADS Governance`） |
| `#218` | `Todo` | `P0` | `PVTI_lADOEwGMMc4BtHPlzhMWsxY` | `M1-A` host feasibility + `M1-B` residual tooling（Waiting for Owner approval of Docs PR） |
| `#219` | `Todo` | `P0` | `PVTI_lADOEwGMMc4BtHPlzhMWs7I` | `[M2]` Expert package, Skills & Linux CI（Waiting for Owner approval） |
| `#220` | `Todo` | `P0` | `PVTI_lADOEwGMMc4BtHPlzhMWtD0` | `[M3]` Mac installation, 29-doc Alpha & Owner UX（Waiting for Owner approval） |

- **Failures**: `0`（Project README 已同步更新）。

## 5. 2026-11-28 follow-up dispositions

| Item | Disposition |
|---|---|
| `#223` (Issue) | **CLOSED**（Project #18 状态 `Done`）：PR #224 (`c99d6910`) 修复两条可执行评审项（protection-fact 门、magic 探测 fail-closed）；其余 P0 确定性收敛项由 Spec §10.8 与 `#220` 独立追踪，不得报告为已随 #224 关闭。 |
| `#224` (PR) | **MERGED** 2026-11-28 至 `workbuddy/dev`（`c99d6910`，CI 全绿；评审项以 `test_12`/`test_13` 回归覆盖）。 |
| `#225` (PR) | **MERGED** 2026-11-28 至 `workbuddy/dev`（`46ec2301`）；保留统一 Roadmap，修正 `0.1.0-alpha.2` 基线归属表述。 |
| `#226` (PR) | **OPEN**（最终定向修正）：交付 Canonical Spec 最终一致性修订、完整 Organization Profile 1.0 候选（MD + JSON）、P0↔验收用例对照矩阵及治理文档对齐；待 Owner 批准后合并并派生最小 Implementation Plan。 |
