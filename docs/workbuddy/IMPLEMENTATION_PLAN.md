# Forma WorkBuddy Edition — Implementation Plan (Revised)

- **Status**: `PLAN_REVISION_COMPLETE` · **Implementation**: `NOT_STARTED` (`WAITING_FOR_OWNER_APPROVAL`)
- **Canonical Spec**: [`docs/specs/2026-11-27-workbuddy-edition.md`](../specs/2026-11-27-workbuddy-edition.md) (Immutable SHA: `110a469208a944a485b4389779795174dad7bc5b`)
- **Active Program**: [#217](https://github.com/Skyline-Gazer/Forma/issues/217) · **GitHub Project**: [#18](https://github.com/orgs/Skyline-Gazer/projects/18)
- **Revision Date**: 2026-11-27 (Supersedes initial draft `2d3d44168bef899bda88488298799ea0d45c00fc` per Owner review)
- **Engineering Principles**: Ponytail（复用优先、最小实现、证据驱动，拒绝为形态完整而自造轮子）。

> [!IMPORTANT]
> **Stop-Gate 声明**：本轮仅授权 Plan 修订、分支与 Issue 治理收敛、独立审查及向 `workbuddy/dev` 提交文档 PR。**未启动 `M1-A` 夹具构建或任何产品代码实施**；须待 Owner 审阅合并本规划 PR 并批准进入 `M1` 后，方可在整合后的 `workbuddy/dev` HEAD 上启动 `M1-A`。

---

## 0. Baseline Verification & Topology

| Item | Verified Value / SHA | Status / Note |
|---|---|---|
| Canonical `origin/main` | `38d455304bc4530b71e584c07de48fc06fd1f293` | Protected baseline, unchanged |
| Canonical `origin/dev` | `0ac64c4d0dffa02d6f2785aad28bd8ea44ceaa59` | Legacy SwiftUI track frozen, unchanged |
| Development Trunk `origin/workbuddy/dev` | `0ac64c4d0dffa02d6f2785aad28bd8ea44ceaa59` | 尚未包含 Spec/Plan；须先通过本轮文档 PR 合入 |
| Planning Branch `workbuddy/docs/implementation-plan` | Descends from `110a469208a944a485b4389779795174dad7bc5b` | Worktree `/home/ian/workspace/Forma-workbuddy-plan` |
| `origin/benchmark-evidence-v1` | `dae571dc784b9db509f04afdefee46764df17894` (perception `395e11a73558f9c021ab27d6147d818e822cc523`) | Evidence-only branch, never merged |
| ADS Pin (`.ads` & `ads-pin.txt`) | `16b99f4b49769555acc66a0c57b8cfcb8c8bac60` (`cnb/dev`) | `ADS_PIN_OK`; ADS 框架已冻结于 `v0.8.1` (`d19bacb2`) |
| GitHub Branch Protection | `main`/`dev`/`workbuddy/dev` 当前均未启用 GitHub Ruleset (HTTP 404) | 依赖 PR 纪律与现有 `.github/workflows/ci.yml` (`pull_request` / `push: [dev]`) |

---

## C1. Product Contract

- **产品定位**：Forma 是运行于 **WorkBuddy** 内的领域专家（Expert），而非独立应用。WorkBuddy 负责 Runtime、对话 UI、模型路由与原生工具调度；Forma 仅拥有：
  1. 文档整理领域知识与用户交互规范（简体中文为主）；
  2. 语义推理指令与防注入约束；
  3. 必要的确定性安全契约（范围 containment、碰撞/symlink 检测、审批绑定与操作日志）；
  4. WorkBuddy 及成熟外部工具无法满足的最小残余能力。
- **交互闭环（Alpha = Organize）**：召唤 Forma → 选定受控源/目标目录 → 默认干跑探查（`inspect` + 内容感知）→ 生成含证据与不确定性的不可变机读计划与简洁可读预览 → 用户审阅/修正并显式批准 → 确定性执行（`apply`）与映射校验报告 → 可选 DEVONthink Index/字段写回读与冲突感知恢复（`recover`）。
- **明确非目标**：不重建独立 GUI/Runtime/模型网关/数据库/搜索引擎/通用工作流框架/OCR 引擎/存储驱逐层；不预设实现语言；不执行无授权定时写入、生产库写入（禁碰 991 条 `Project_Archive`）、市场上架或公开迁移。增量更新置于 Alpha 体验通过后，历史审计/知识检索为 Backlog。

---

## C2. Target Architecture & Official Package Contract

- **包结构**（来自 2026-11-27 实抓 `open.workbuddy.cn/docs/expert`、`skill`、`connector`）：
  - `.codebuddy-plugin/plugin.json`、`agents/forma.md`、`avatars/expert.png`（512×512 PNG/JPG ≤500KB）、`skills/<name>/SKILL.md`、`README.md`；运行态日志/账本写于包外用户状态目录。
  - `plugin.json` 必填：`name`（小写+连字符，且等于 `plugin`）、`version`（SemVer）、`description`（英文简述）、`author`（真实授权信息）、`expertType: "agent"`（单 Agent，非 Team）、`agentName: "forma"`、`agents`、`displayName`/`profession`/`displayDescription`（中英双语，中文展示描述 **40–50 字**）、`categoryId: "04-DataAI"`、`tags`（3 个）、`quickPrompts`（3 个，首条等于 `defaultInitPrompt`）。
  - `agents/forma.md`：**严禁自填 `tools` 字段**（平台统一分配 `Read`/`Write`/`Grep`/`Glob`/`Bash` 等）。
  - `SKILL.md`：按官方双语 frontmatter 填写；`allowed-tools` 仅作提示，不作安全边界。
- **外部工具与可选集成**：
  - **文档解析**：优先直接调用 `docvortex convert` CLI（`0.6.26`, MIT），`.txt` 使用 WorkBuddy 原生读取；扫描件在 macOS 回退 `mac-ocr`（MIT）或等效 `VNRecognizeTextRequest`。
  - **DEVONthink（可选）**：**不写入 `plugin.json` 必填 `dependencies`**；优先 DEVONthink 4.4+ 内置 MCP 或极简 `osascript` (JXA/AppleScript)，仅允许隔离测试库；禁止将 macOS-only DEVONthink 包装为跨平台 CLI Connector。
  - **OneDrive（可选）**：仅作原件目录；严禁在 OneDrive 内放置活动 DEVONthink DB。

---

## C3. Reuse & Language Decision Summary

完整逐项分析见 [`REUSE_MATRIX.md`](./REUSE_MATRIX.md)。核心结论：
1. **无语言预设**：移除原 Plan 对 Python 3.11–3.14 / `pytest` / 5 子命令大一统 CLI 的强制要求；DocVortex 有 Python SDK 不等于 Forma 必须用 Python。
2. **最小残余代码（约 400–700 LOC）**：仅针对 WorkBuddy 原生工具无法保证的确定性缺口——本地 FS 原子移动/Journal/碰撞/`SF_DATALESS`/symlink 校验及长文档有界分块。
3. **语言锁定门禁**：由 **`M1-A`（宿主机可行性实测）** 的客观证据决定——若客户端 `Bash` 稳定支持 `python3` 则选用 **stdlib-only Python**（候选 A）；若环境/PATH 隔离阻断则选用 **单静态 Go 二进制或极窄 Swift CLI**（候选 B）。

---

## C4. Implementation Sequence & Branch Lifecycle

### 4.1 12-Step Branch & Integration Lifecycle (Track D)
1. 在 `workbuddy/docs/implementation-plan` 完成本轮 Plan 修订。
2. 对修订后的精确 Commit SHA 执行独立只读审查（OMP + DeepSeek）。
3. 提交 **Documentation-Only PR** 指向 `workbuddy/dev`（本轮止步于此 PR 就绪，**不合并**）。
4. 等待 Owner 审阅并批准合并该文档 PR。
5. 记录合并后最新的 `workbuddy/dev` HEAD SHA。
6. 从该已合入 Spec/Plan 的 `workbuddy/dev` HEAD 拉出 `M1` 分支（`workbuddy/feat/m1-feasibility-and-core`）。
7. 完成 **`M1-A: WorkBuddy Host Feasibility`** 并记录结果。
8. 仅在 `M1-A` 通过并锁定残余工具语言后，继续 **`M1-B: Residual Deterministic Tooling`**。
9. 验证 `M1` 并通过 PR 合入 `workbuddy/dev`（遵守实际 CI 检查，不设重复 CI）。
10. 从整合后的 `workbuddy/dev` HEAD 拉出 `M2` 分支（`workbuddy/feat/m2-expert-package`）。
11. 完成 `M2` 打包与静态校验，通过 PR 合入 `workbuddy/dev` 并产出精确 `.zip` + `SHA256`。
12. 从整合后的 `M2` HEAD 与精确包 `SHA256` 启动 `M3`（Mac 客户端安装、29 文档回归与 Owner UX 验收）。

### 4.2 Phased Scope, Gates & Rollback

| Phase | Spec IDs | Inputs & Preconditions | Concrete Deliverables | Verification & Acceptance | Failure / Rollback | Host |
|---|---|---|---|---|---|---|
| **M1-A** (`#218` 前置) | `§3`, `FR1`, `FR8` | 文档 PR 已合入 `workbuddy/dev` | 最小一次性官方格式 Expert/Skill 探针夹具（仅含无害只读脚本与合成目录） | Mac 实测 8 项未知：官方创建/加载、Skill 发现、只读脚本/CLI 调用、包内路径解析、真实可用运行时与依赖、合成目录 TCC 权限、原生工具审批行为、私有安装路径可用性 | 若平台阻断关键能力，立即停止后续编码并给出最小替代方案；绝不以 DevBox/OMP 冒充通过 | `DevBox` 制具 → `Mac` 实测 |
| **M1-B** (`#218` 残余) | `FR1`, `FR2`, `FR4`, `FR5`, `FR8` | `M1-A` 通过且语言/运行时已锁定 | 最小残余确定性执行器（`inspect/chunk/plan-verify/apply/recover`）+ `#136` 口径修复 + 确定性单测 | DevBox 确定性单测全部通过（路径/Unicode/symlink/过期计划/幂等/日志恢复/防注入）；macOS 专属（Vision/`SF_DATALESS`）标 `NOT_VERIFIED_ON_LINUX` | 仅在 `workbuddy/feat/*` 修正或回退，不污染 `workbuddy/dev` | `DevBox` (+ Mac 复核) |
| **M2** (`#219`) | `§3`, `FR3`, `FR6`, `FR8`, `§6`, `§9` | `M1` 已合入 `workbuddy/dev` | 完整 Expert 包、Skills、可读/机读包校验器、版本化 `.zip` + `SHA256`、安装/卸载指南、known gaps、DEVONthink 可选适配器、Spec §9 12 项报告 | 官方字段约束 100% 校验通过（含 `description`、40–50 字中文简介、禁用 `tools`）；合成端到端干跑；`MAC_HANDOFF` | 校验失败禁止产出发布包 | `DevBox` |
| **M3** (`#220`) | `FR1–FR8`, `§6`, `§7` (Alpha) | `M2` 已合入且包 `SHA256` 锁定 | Mac 客户端安装实录、29 文档回归 E2E（干跑→批准→执行→映射核验→可选 DT Index/写回读→断点恢复→重复幂等）、宿主恢复记录、Owner UX 结论 | Alpha 门禁：无需 Owner 手动串联命令；零丢失/覆盖/逃逸；DEVONthink 可选读回；Owner 体验批准（29 文档不作盲测成绩，不继承 92.34） | 未获 Owner UX 批准不得启动 `#213` 高成本盲测 | `Mac` + `Owner` |
| **Phase 4** (`#213`/`#214`/`#215`) | `FR6`, `FR7`, `§7` (Holdout) | `M3` 获 Owner UX 批准 | DevBox 冻结 100–200（目标 150）盲测语料/Gold/Rubric (30/20/15/10/10/10/5)；Mac 3 次独立运行 + 增量更新切片；`#214` OneDrive 大文件实测；`#215` DT 固化 | 均值 ≥90、最低 ≥85、3/3 流程、100% 项目/版本、≥95% 角色、零严重错归/丢失、≤5% 纠错、计数/分母透明；`#214` 独立评定（缺环境标 `BLOCKED`/`NOT_VERIFIED`） | 失败仅允许一次低成本定向修复建议；无可靠路径即止损 | `DevBox` + `Mac` |
| **Phase 5** (`#216`) | `FR8`, `§7`, `§8` | Phase 4 必需门禁通过 + Owner 真实试点隐私授权 | 含审阅确认在内省时对比（目标 ≥80%）、成本维护报告、`#216` 最终决策、Alpha 后 ADS 真实复用回报 | 任一必需 P0 门禁未知 => 仅限有条件/不得生产 GO | 止损或选择最小替代方案 | `Owner` + `Mac` |

---

## C4.5 Safety & Authorization Architecture (Track C)

### 4.5.1 Six Authorization Layers (Strict Distinction)
1. **对话级用户确认**：用户在聊天中同意方案预览（**非技术强制边界**，仅业务意图确认）。
2. **WorkBuddy 原生工具审批**：客户端对 `Bash`/`Write` 等工具调用的原生确认弹窗（**真实强制力待 `M1-A` 在 Mac 实测确认**）。
3. **宿主机 OS / TCC 文件系统权限**：macOS 对目录读写、Automation/AppleEvents 的系统级拦截（**平台强制边界**）。
4. **确定性执行器校验**：执行器内部对 `plan_hash`、`snapshot_hash`、containment、碰撞与单写锁的强校验（**仅当调用进入该执行器时生效**）。
5. **批准凭据来源（Approval Provenance）**：若批准凭据由 Agent 自行生成，则不防 Agent 伪造；须由用户交互确认或独立生成的一次性确认码/精确 `plan_hash` 摘要回传绑定，并在执行前重新校验源文件快照与目标状态。
6. **Prompt 指令与 `allowed-tools`**：仅作为行为引导（**明确不视为安全边界**，绝不宣称“LLM 指令不可绕过”）。

### 4.5.2 10-Threat Enforcement & Residual Limitation Matrix

| Threat | Mechanism | Enforced By | Residual Limitation & Acceptance Impact |
|---|---|---|---|
| 1. 未经批准写入 | 默认 dry-run；执行器要求显式批准输入；WorkBuddy 原生工具审批 | 执行器校验 + 平台工具审批（待 `M1-A` 核实） | 若平台允许免确认静默 `Write`/`Bash`，Agent 理论上可绕过；须在 `M1-A` 验证是否可设工具确认策略 |
| 2. 绕过预定执行器直写 | Skill 指令强制通过执行器；不提供直写 `mv` 示例 | **仅指令约束（非强制）**，除非平台限制原生 `Write`/`Bash` | **明确残余限制**：WorkBuddy 平台统一分配 `Write`/`Bash` 时，无法从技术上杜绝 LLM 绕过执行器；验收须核查操作日志与真实文件映射一致 |
| 3. 批准重放与过期批准 | 执行器在 Journal 记录已消费 `plan_id`/`plan_hash`，拒绝重复消费与超时计划 | 确定性执行器（单写锁 + Journal） | 依赖执行器状态文件完整性 |
| 4. 计划或源快照变更 | 执行前复核 `snapshot_hash`（源路径/大小/mtime/内容哈希）与 `plan_hash` | 确定性执行器（不一致即 `FAIL_CLOSED`） | 无 |
| 5. 路径越界与 Symlink 逃逸 | `realpath` 解析规范路径并校验严格位于授权 `source_root`/`dest_root` 内；拒绝跟随 symlink | 确定性执行器 + OS 权限 | 无（执行器路径内强保证） |
| 6. TOCTOU 竞态 | 原子 `os.rename`（同卷）前逐项复核源 inode/size/mtime/hash 与目标不存在 | 确定性执行器 + OS 内核语义 | 跨卷移动无法单次系统调用原子化，需“复制+哈希校验+写日志+删源”并在异常时进入 `CONFLICT_HOLD` |
| 7. 大小写与 Unicode 碰撞 | 规划与执行前统一按 NFC + 大小写折叠（APFS 默认大小写不敏感）预检冲突 | 确定性执行器 | 若目标目录在执行瞬间被外部进程并发写入，由 OS 拒绝覆盖并进入冲突恢复 |
| 8. 中断移动与冲突恢复 | Intent-before-side-effect append-only Journal；恢复前复核目标/源当前状态，拒绝覆盖用户独立编辑 | 确定性执行器（四态仲裁） | 跨系统（本地文件 + DEVONthink）无分布式原子事务，须分系统独立状态与补偿（符合 FR6） |
| 9. 文档内提示词注入 | 解析输出与正文片段隔离标记为不可信数据；执行器不解析文档内文本为命令，禁止未转义路径 shell 拼接 | 确定性执行器（参数化调用）+ Prompt 隔离 | LLM 语义判断仍可能受恶意文本干扰，由人工预览审阅与盲测注入样本（如原语料探针）把关 |
| 10. 越权修改授权范围外数据 | 执行器硬校验边界；macOS TCC 限制非授权目录；严禁触碰生产库 | OS TCC + 执行器边界 | 若用户授予了过宽父目录（如 `~`），OS 不再拦截，仅靠执行器 `source_root`/`dest_root` 约束 |

---

## C5. Verification Plan (分层验证)

保持 Spec §7 全部绝对验收门槛不变，不弱化、不叠加无依据门禁：
1. **DevBox 确定性单测**：仅覆盖便携确定性逻辑与包静态校验；Mac 专属项在 Linux 标 `NOT_VERIFIED_ON_LINUX`。
2. **Mac `M1-A` 可行性实测**：验证 8 项宿主机未知。
3. **Mac `M3` 29 文档回归 + Owner UX 验收**：回归夹具不作盲测证据，不继承 Codex `92.34`。
4. **`#213` 100–200 文档盲测 + 增量切片**：均值 ≥90、最低 ≥85、3/3 流程、100% 可判定项目/版本、≥95% 角色、零严重错归/丢失/覆盖/逃逸、≤5% 纠错率。
5. **`#214` OneDrive 存储与恢复**：大体积合成文件、实际字节与非预期下载统计，独立于语义分；缺环境标 `BLOCKED`/`NOT_VERIFIED`。
6. **`#216` 真实试点与最终决策**：含审阅时间在内人工省时 `>= 80%`（需单独隐私授权）。

---

## C6. Engineering Governance Simplification Proposal (Track E — Proposal Only)

> **本轮仅提交治理处置建议，未删除 `.ads`、未改写 `ads-pin.txt`、未修改全局配置或根 `AGENTS.md`。**

### 6.1 Inherited Governance Audit & Recommendation

结合 **ADS v0.8.1 框架冻结**（已终止框架迭代，个人核心迁至 `ADS/personal/AGENTS.md`）、**ALNILAM 轻量 `AGENTS.md` 实践**（精简契约 + 直接执行 + 依赖实际 CI，不强行保留整套 ADS 重型脚手架），以及本机已安装的 **Ponytail**（`ponytail`, `ponytail-audit`, `ponytail-review` 等），对旧 Forma 遗留治理项建议如下：

| Inherited Item | Current State | Recommendation | Rationale |
|---|---|---|---|
| **根 `AGENTS.md`** | 绑定旧 SwiftUI/DEVONthink 规范与 `.ads` 强制流程 | **Simplify (需 Owner 批准后更新)** | 在 `workbuddy/dev` 精简为面向 WorkBuddy 轨道的轻量项目边界（保留安全、Spec 锚定、991 生产库禁碰、隐私与分支纪律；移除 SwiftUI/CNB 过时耦合） |
| **`.ads/` submodule & `ads-pin.txt` & `check_ads_pin.py`** | Pinned at `16b99f4b` (`cnb/dev`), `ADS_PIN_OK` | **Defer-Remove / Optionalize (需单独批准)** | ADS 框架已冻结于 `v0.8.1`，新轨道无需重型子模块同步门禁；本轮保留不动，待 Owner 确认后决定保留只读归档或摘除子模块 |
| **`skills.lock.json` & `.agents/skills/` (`swiftui-expert-skill`, `swiftui-pro`)** | 锁定 SwiftUI 顾问技能 | **Separate & Freeze** | **明确区分“开发期 Agent Skill”（如 `ponytail`、`swiftui-*`）与“可分发 WorkBuddy 产品 Skill”（`workbuddy/expert/skills/`）**；SwiftUI Skill 随旧路线冻结保留在 `dev`，新轨道改用已安装的 `Ponytail` / `ponytail-audit` |
| **`.github/workflows/ci.yml` & `benchmark.yml` & 分支规则** | `macos-26` Swift CI（`pull_request`/`push: [dev]`）；无 GitHub Ruleset | **Preserve & Adapt Incrementally** | 不新建重复 CI；在 `workbuddy/dev` 推进时，对 `pull_request` 仅按需运行轻量文档/残余脚本校验，保留旧 Swift CI 不受破坏 |
| **旧 `docs/` (51 份 M0/M11/R1 文档) & 旧 worktree** | 保留在 `dev` | **Preserve Unmodified** | 仅作历史与复用证据索引；清理前须先审计 worktree/Agent 会话，不删未提交工作与历史证据 |

### 6.2 ADS Feedback Boundary (§11)
- **严禁**将本次 Plan 修订或理论架构作为“WorkBuddy 复用成功案例”上报 ADS。
- 若发现个人 `AGENTS.md` 通用经验（如“未核验模型路由不得默认报告为 DeepSeek”），单独记录于个人规范，不阻塞 Forma，不修改 ADS 上游。
- 下一份实质性 WorkBuddy 复用证据将在 **`M1-A` / `M3` 实际宿主机行为验证** 后再评估上报。
