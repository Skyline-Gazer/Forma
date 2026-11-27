# Forma WorkBuddy Edition — Implementation Plan

- **Status**: `SPEC_TO_PLAN_COMPLETE` · **Implementation**: `NOT_STARTED` (`WAITING_FOR_OWNER_APPROVAL`)
- **Canonical Spec**: [`docs/specs/2026-11-27-workbuddy-edition.md`](../specs/2026-11-27-workbuddy-edition.md) (Immutable SHA: `110a469208a944a485b4389779795174dad7bc5b`)
- **Active Program**: [#217](https://github.com/Skyline-Gazer/Forma/issues/217) · **GitHub Project**: [#18](https://github.com/orgs/Skyline-Gazer/projects/18)
- **Date**: 2026-11-27
- **Language**: 简体中文为主（面向用户与治理记录），包元数据与工程契约保持英文对等。

> [!IMPORTANT]
> **Stop-Gate 声明**：本轮仅授权基线核验、可复用能力调研、Spec-to-Plan、开发分支隔离与 Project/Issue 治理收敛。**未授权任何产品功能代码、Expert/Skill 文件、Connector、打包或发布实施**。须待 Owner 书面批准本 Plan 的具体 Commit SHA 后，方可进入 `M1` 实施阶段。

---

## 0. Baseline Verification & Lane Isolation

| Item | Verified Value / SHA | Status / Note |
|---|---|---|
| Canonical `origin/main` | `38d455304bc4530b71e584c07de48fc06fd1f293` | Protected, unchanged |
| Canonical `origin/dev` | `0ac64c4d0dffa02d6f2785aad28bd8ea44ceaa59` | Legacy SwiftUI track frozen; unchanged |
| New `origin/workbuddy/dev` | `0ac64c4d0dffa02d6f2785aad28bd8ea44ceaa59` | Branched from verified `origin/dev`, full history preserved |
| Planning branch `workbuddy/docs/implementation-plan` | Branched from `110a469208a944a485b4389779795174dad7bc5b` | Descendant of `workbuddy/dev`; worktree `/home/ian/workspace/Forma-workbuddy-plan` |
| Future feature / docs convention | `workbuddy/feat/*` / `workbuddy/docs/*` | Never merge legacy `integration/m0r2-candidate` or legacy PRs |
| `origin/benchmark-evidence-v1` | `dae571dc784b9db509f04afdefee46764df17894` (perception `395e11a73558f9c021ab27d6147d818e822cc523`) | Evidence-only branch; never merged into `dev`/`main` |
| ADS Pin (`.ads` & `ads-pin.txt`) | `16b99f4b49769555acc66a0c57b8cfcb8c8bac60` (`cnb/dev`) | `ADS_PIN_OK`; latest upstream release `v0.8.1` (`ffafa9d4`); no silent upgrade |
| `skills.lock.json` | Schema v1: `swiftui-expert-skill` (`62bd760f`), `swiftui-pro` (`f2920b63`) | Legacy SwiftUI advisory skills only; not WorkBuddy runtime deps |
| Worktree & Agent Audit | `/home/ian/workspace/Forma` (`fix/host-safety-isolation`, clean); `/home/ian/workspace/benchmark-review` (`395e11a` detached); OMP `v19.2.1` | 调研子任务通过 `omp -p --model deepseek/deepseek-flash` 执行，进程实际路由模型标识报告为 `magpie/group/free-glm`（如实记录） |

---

## C1. Product Contract (产品契约)

### 1.1 Final Deliverables
1. **WorkBuddy-native Expert 包**（主交付形态）：包含 `.codebuddy-plugin/plugin.json`、`agents/forma.md`、`avatars/expert.png`、`skills/<name>/SKILL.md`、`README.md`，以及打包在其 `skills/*/scripts/` 下的确定性 Python CLI 工具集。
2. **可复现构建与校验工具链**：包结构/Schema 校验脚本、Linux 可运行的确定性单元测试套件、版本化 `.zip` 产物 + `SHA256`、安装/卸载/客户端配置指南与 Mac 交接包。
3. **可选 DEVONthink 集成适配**：优先复用 DEVONthink 4.4+ 官方内置 MCP 或最小化 macOS AppleScript/JXA 读写回读脚本（非 Expert 强依赖）。

### 1.2 End-to-End User Interaction Flow
1. **召唤与选区**：用户在 WorkBuddy 客户端召唤 Forma Expert，或通过 3 个 `quickPrompts` 之一发起任务；显式指定受控源目录（`source_root`）与授权目标目录（`dest_root`），可选指定命名策略与隔离 DEVONthink 数据库。
2. **只读探查与感知（Dry-run 默认）**：确定性 CLI 枚举文件身份、大小/类型、内容哈希及不可读/离线/不支持状态（不跟随 symlink、不拉取未请求云端文件、不扫描范围外文件）；解析 PDF/DOCX/XLSX/PPTX/TXT（长文档分块检索，macOS 扫描件走 Apple Vision 回退，保留页/表/节证据与失败原因）。
3. **语义理解与方案预览**：WorkBuddy LLM 基于文档内容与语料上下文推断业务身份、角色、意图、项目边界、多方关系、版本状态与重复项，生成不可变机读计划（含 `plan_id`/`plan_hash`、输入快照、`source_id`、处置方式 `move/rename/keep/review`、证据、冲突与不确定性）及简洁可读摘要预览。
4. **审阅与显式授权**：用户可提出修正并重新生成计划；**仅当用户对精确 `plan_id/plan_hash` 与范围做出显式批准后**才允许写入。源文件或计划任一变更即作废既有授权。
5. **确定性执行与报告**：执行器复核边界 containment、symlink 逃逸、源哈希、过期计划、大小写/Unicode 碰撞、目标重复、权限、可用空间与单写锁，写入 append-only 操作日志（Journal），优先同卷原子移动，生成原始清单与实际输出映射校验报告。
6. **可选 DEVONthink 索引与恢复**：若用户启用 DEVONthink，则对目标文件执行 **Index**（不复制重复字节），写入已批准标签/自定义字段并回读 UUID/链接/路径；状态独立记录，支持基于日志的断点续传或带冲突检查的恢复。

### 1.3 Alpha Scope & Explicit Non-Goals
- **Alpha 范围**：仅覆盖 **Organize** 闭环（`inspect → perceive → plan → approve → apply → verify → recover`）。增量更新（new files / new versions / idempotent update）作为 Alpha 体验通过后的独立后续验收切片；历史审计与知识检索仅作 Backlog。
- **明确非目标（Non-Goals）**：
  - 不重建独立 GUI（SwiftUI/AppKit）、独立 Runtime、模型路由、数据库、搜索引擎、OCR 引擎、存储/驱逐层或通用工作流框架；
  - 不将旧 SwiftUI 代码或旧 `integration/m0r2-candidate` 合入 `workbuddy/dev`；
  - 不做无授权定时后台写入、生产库写入（严禁触碰 991 条生产 `Project_Archive`）、应用市场上架、公开迁移或正式发布；
  - 不以“文档内指令”作为命令执行（防 Prompt Injection）。

---

## C2. Target Architecture & Official Package Contract

### 2.1 Component Responsibilities & Dependency Boundaries
| Component | Responsibility | Boundary / Constraint |
|---|---|---|
| **WorkBuddy Client** (`Native Capability`) | 对话 UI、模型路由、上下文管理、平台工具分配（`Read`/`Write`/`Grep`/`Glob`/`Bash`） | Expert `agents/forma.md` **严禁**自定义 `tools` 字段；由平台统一分配 |
| **Forma Expert** (`.codebuddy-plugin/plugin.json` + `agents/forma.md`) | 单 Agent 专家定义、简体中文业务规则、调用预加载 Skills 与工作流编排 | 采用 `expertType: "agent"`（非 Expert Team）；`dependencies` **不强制**声明 DEVONthink |
| **Forma Skills + Deterministic CLI** (`skills/*/SKILL.md` + `scripts/`) | 将 FR1/FR2/FR4/FR5/FR6 的确定性逻辑封装为可测试的 Python CLI（JSON stdin/stdout），供 Agent 通过 `Bash` 调用 | 禁止 shell 拼接未转义路径；逻辑独立于宿主配置，DevBox Linux 可测部分与 macOS 专属部分严格分离 |
| **DEVONthink Adapter** (`Optional`) | Index 原始文件、写入批准的标签/自定义字段并独立回读校验 | 优先 DEVONthink 4.4+ 官方内置 MCP 或受控 AppleScript/JXA；仅允许隔离测试库；不得将 macOS-only DEVONthink 包装为跨平台 CLI Connector |
| **OneDrive File Provider** (`Optional`) | 仅作为原文件存储根目录 | 严禁将活动 DEVONthink 数据库置于 OneDrive 内；严禁在范围外触发批量水合（hydration） |
| **WorkBuddy Project** (`Optional`) | 可选团队共享上下文（指令/资料库） | 非 Alpha 强依赖；Buddy App 与市场审核延后 |

### 2.2 Official WorkBuddy Package Contract (Verified 2026-11-27)
官方来源（均于 2026-11-27 抓取核验）：
- Expert: `https://open.workbuddy.cn/docs/expert`
- Skill: `https://open.workbuddy.cn/docs/skill`
- Connector: `https://open.workbuddy.cn/docs/connector`
- Buddy App: `https://open.workbuddy.cn/docs/buddy-app`
- Project: `https://www.codebuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Project`

**包目录与清单硬性约束**：
- **目录结构**：`.codebuddy-plugin/plugin.json`、`agents/forma.md`、`avatars/expert.png`、`skills/<skill-name>/SKILL.md`、`README.md`（运行时日志/账本/快照写于包外用户工作区或指定状态目录，不污染包内）。
- **`plugin.json` 必填字段**：
  - `name`：小写字母+连字符（如 `"forma-organizer"`），且 `plugin` 字段与之完全一致；
  - `version`：SemVer（如 `"0.1.0-alpha.1"`）；
  - `description`：英文简短描述（`string`，官方必填基础字段）；
  - `author`：`{name, email}` 必须使用真实授权信息，严禁编造；
  - `expertType`: `"agent"`；`agentName`: `"forma"`（与 `agents/forma.md` 基名一致）；
  - `agents`: `["./agents/forma.md"]`；`skills`: 相对路径列表；
  - `displayName` / `profession` / `displayDescription`：中英双语 `{en, zh}`，其中 `displayDescription.zh` **严格 40–50 个汉字**；
  - `categoryId`: `"04-DataAI"`；`avatar`: `"avatars/expert.png"`（512×512 PNG/JPG，≤500 KB）；
  - `tags`: 固定 3 个双语对象；`quickPrompts`: 固定 3 个双语对象（1. 整理选定文件夹；2. 仅检查并生成整理方案不写入；3. 恢复/审阅上次方案或执行恢复），且 `defaultInitPrompt` **必须与 `quickPrompts[0]` 一致**。
- **`agents/forma.md` Frontmatter**：仅允许官方字段 `name`、`description`（英文）、`displayName`（en/zh）、`profession`（en/zh）、可选 `maxTurns`（默认 50）、可选 `skills`（预加载技能名列表）。**禁止 `tools` 字段**。
- **`SKILL.md` Frontmatter**：包含官方必填双语字段（`name`, `display_name`, `display_name_en`, `description`, `description_zh`, `description_en`, `version`, `author`），可选 `allowed-tools`（仅作提示，不替代显式执行授权边界）。
- **本地安装边界**：官方文档仅明确记载客户端「我的专家 → 创建专家」、技能市场安装及开放平台上传 zip；**本地 zip 直接导入在五份官方文档中均 `NOT_DOCUMENTED`**。因此 `M3` 阶段必须在 Mac 客户端实测官方支持的创建/导入或私有预览路径，如被平台阻断则如实记录 `BLOCKED`，不得臆测。

---

## C3. Reuse Matrix

完整能力复用矩阵与外部依赖审计见 [`REUSE_MATRIX.md`](./REUSE_MATRIX.md)（严格划分 `Native Capability` / `Configuration` / `Existing Tool Reuse` / `Minimal Adaptation` / `New Implementation`，并逐项记录来源、许可证与拒绝替代方案的理由）。

---

## C4. Implementation Sequence (实施阶段)

> 所有新开发均在 `workbuddy/dev` 派生的 `workbuddy/feat/*` 分支进行，禁止修改旧 SwiftUI 代码。

### Phase 1 (`M1`): Deterministic Core CLI & Contracts (DevBox)
- **Spec IDs**: `FR1`, `FR2`, `FR4`, `FR5`, `FR8`, `§4`, `§6`
- **Inputs & Preconditions**: Owner 批准本 Plan Commit SHA；`workbuddy/dev` (`0ac64c4d`)；`docs/workbuddy/REUSE_MATRIX.md`；`FormaCore` 既有规则（`forma-eligibility.v1.json`, `SourceFilesystem`, `ImportPreflight/Ledger/Arbitration`, `make_i18n/make_i1_b2_synthetic.py`）。
- **Deliverables**:
  - 便携 Python CLI 模块（`workbuddy/tools/forma_cli/`）：
    - `inspect`（FR1）：受控目录枚举、NFC/大小写碰撞检测、symlink 拒绝、云占位符（dataless）识别、资格策略过滤（修复 `#136` 预算外误计为 `INCLUDE` 的口径缺陷）、扩展名与魔数/内容失配检测；
    - `perceive`（FR2）：集成 `DocVortex 0.6.26`（PDF/DOCX/XLSX/PPTX）+ 原生 TXT 读取 + 分块检索 + 结构化证据与失败原因输出；在 macOS 上支持调用 Vision OCR 回退接口（Linux 仅测接口契约与降级错误码，不伪造 OCR PASS）；
    - `plan`（FR4）：不可变 JSON 计划校验与 `plan_id`/`plan_hash` 生成、输入快照绑定、可读 Markdown 摘要渲染、用户修正合并与重生成；
    - `apply` & `recover`（FR5）：Dry-run 默认、强制显式批准令牌（绑定 `plan_hash` + `snapshot_hash`）、containment/symlink/哈希/过期/碰撞/空间/单写锁校验、append-only SQLite/JSONL Journal、同卷原子移动、幂等键、四态仲裁与冲突感知恢复；
  - 合成测试夹具与 Linux 自动化测试集（覆盖 `FR1/FR4/FR5/FR8` 全部确定性边界）。
- **Modification Scope**: 新建 `workbuddy/feat/m1-core-cli` 分支；新增 `workbuddy/tools/`、`workbuddy/schemas/`、`workbuddy/tests/`（不触碰根 `Sources/`、`FormaApp/`）。
- **Test Methods**: `pytest` 确定性测试（路径规范化、Unicode NFC/NFD 碰撞、symlink 逃逸拒绝、过期计划拒绝、部分失败日志恢复、幂等重复执行、提示词注入文本仅作数据、无凭证泄露）；在 **Linux DevBox** 本地运行（若后续纳入 CI，仅在既有 `.github/workflows/ci.yml` 的 `pull_request` 触发中增量接入，不新建重复 CI 工作流；macOS 专属路径保持 `NOT_VERIFIED_ON_LINUX`）。
- **Acceptance Criteria**: 100% 确定性单测在 Linux DevBox 通过；`inspect/plan/apply/recover` 均输出稳定 JSON Schema；零 shell 字符串拼接；修复 `#136` 报告口径；Mac-only Vision 路径在 Linux 明确标记 `NOT_VERIFIED_ON_LINUX`。
- **Failure & Rollback**: 单测或契约失败时阻止进入 `M2`；隔离分支随时可回退至 `workbuddy/dev`，不影响旧主线。
- **Host Responsibility**: `DevBox`。

### Phase 2 (`M2`): WorkBuddy Expert Package, Skills & Reproducible Packaging (DevBox)
- **Spec IDs**: `§3`, `FR3`, `FR6`（接口/Skill 契约）, `FR8`, `§6`, `§9`
- **Inputs & Preconditions**: `M1` CLI 与测试通过；官方 WorkBuddy Schema（§2.2）。
- **Deliverables**:
  - Expert 包源码（`workbuddy/expert/`）：`.codebuddy-plugin/plugin.json`、`agents/forma.md`、`avatars/expert.png`（512×512 PNG ≤500KB）、`skills/`（如 `forma-inspect-perceive`、`forma-plan-apply`、`forma-devonthink-optional`）、`README.md`；
  - 可复现构建与校验脚本（校验 `plugin.json` 全部必填字段含 `description`、40–50 汉字 `displayDescription.zh`、3 个 `quickPrompts` 与 `defaultInitPrompt` 一致性、禁用 `tools` 字段、无硬编码密钥）；
  - 版本化 `.zip` 产物 + `.sha256` + 安装/卸载/原生客户端配置指南 + **known gaps** 清单 + `MAC_HANDOFF` + **Spec §9 12 项 DevBox 最终报告**（`CANONICAL_HEADS`, `SPEC_TO_PLAN`, `REUSE_MATRIX`, `OFFICIAL_PACKAGE_CONTRACT`, `IMPLEMENTATION_SHA`, `PACKAGE_SHA256`, `TEST_RESULTS`, `MAC_HANDOFF`, `PROJECT_18_RECONCILIATION`, `LEGACY_DISPOSITION`, `ADS_TRIGGER`, `BLOCKERS`）；
  - DEVONthink 可选 AppleScript/JXA 与官方 MCP 适配层代码（及 Linux mock 契约测试）。
- **Modification Scope**: `workbuddy/feat/m2-expert-package` 分支；新增 `workbuddy/expert/`、`workbuddy/scripts/`、`workbuddy/docs/`。
- **Test Methods**: 包结构/Schema 静态校验自动化测试；29 文档既有合成语料（来自 `benchmark-evidence-v1` 的合成目录）的端到端 CLI + Skill 干跑冒烟（不含真实 LLM 或明确记录所使用的模型路由）；`check_ads_pin.py` 检查。
- **Acceptance Criteria**: 可复现生成版本化 `.zip` + `SHA256`；全部官方字段约束校验 100% 通过；DevBox 静态与确定性测试全绿；`MAC_HANDOFF` 完整。
- **Failure & Rollback**: 校验脚本失败不得产出发布包；可独立修正 `workbuddy/expert/` 并重打版本化 `.zip`。
- **Host Responsibility**: `DevBox`。

### Phase 3 (`M3`): Mac WorkBuddy Client Installation, 29-Doc Alpha E2E & Owner UX Acceptance (Mac + Owner)
- **Spec IDs**: `FR1`–`FR8`, `§3`, `§6`, `§7` (Alpha Gate)
- **Inputs & Preconditions**: `M2` 精确 Commit SHA 与 `.zip` `SHA256`；Mac 环境（Apple Silicon macOS 14+、WorkBuddy 客户端、Python 3.11–3.14、`DocVortex 0.6.26`、可选隔离 DEVONthink 测试库）。
- **Deliverables**:
  - 实测安装步骤记录（官方客户端创建/导入/私有预览路径及任何权限/TCC 提示）；
  - 29 文档回归夹具完整端到端运行证据（干跑预览 → 显式批准 → 执行 → 映射核验 → 可选 DEVONthink Index/字段写入/回读 → 模拟中断恢复 → 重复执行幂等性）、真实截图、实际模型路由与版本记录；
  - 宿主状态恢复记录（仅清理任务自有合成路径，绝不触碰生产库）；
  - Owner 产品体验评审结论（`OWNER_UX_APPROVED` 或具体整改项）。
- **Modification Scope**: 仅在发现真实集成阻塞时于 `workbuddy/feat/*` 最小化修复并更新测试；证据写入独立证据分支或 `docs/workbuddy/` 索引（严禁把大日志/真实隐私塞入主分支）。
- **Test Methods**: 真实 WorkBuddy 客户端交互操作（禁止要求 Owner 手动串联命令行）；3 个 `quickPrompts` 逐一实测；Apple Vision 扫描件实测；DEVONthink 隔离库写/读回实测。
- **Acceptance Criteria** (Spec §7 Alpha Gate):
  - 在 WorkBuddy 中本地可用，无需 Owner 手动串联命令；
  - 干跑预览 + 绑定批准执行 + 正确文件映射 + 零丢失/覆盖/逃逸；
  - 可选 DEVONthink 写入与回读通过、恢复测试通过、Owner 体验批准；
  - **注意**：29 文档仅作回归夹具，不作为盲测通过依据，不宣称与 Codex 92.34 等价。
- **Failure & Rollback**: 若官方客户端安装或 TCC 权限被平台阻断，修复具体集成方式或如实报告 `BLOCKED`（严禁以其他宿主冒充等价）；Alpha 体验未通过前禁止进入高成本盲测。
- **Host Responsibility**: `Mac` + `Owner`。

### Phase 4 (`#213` / `#214` / `#215`): Blind Holdout, Incremental Update, OneDrive Storage & DEVONthink Integration
- **Spec IDs**: `FR6`, `FR7`, `§6`, `§7` (Holdout Gate), `#213`, `#214`, `#215`
- **Inputs & Preconditions**: Phase 3 (`M3`) 获得 Owner 体验批准；独立盲测语料/Gold/评分标准在 DevBox 冻结完成。
- **Deliverables**:
  - **DevBox (`#213` 评测端)**：独立构建 100–200 份新鲜盲测合成文档（目标 150 份，含多项目交叉、长 PDF、扫描件、多表 XLSX、多版本、共享供应商、冲突引用与合理歧义）、冻结 Gold 与原业务 Rubric（30/20/15/10/10/10/5）及自动/盲评计分器；
  - **Mac (`#213` 执行端)**：在隔离环境下以相同候选配置执行 3 次独立 100–200 文档盲测，另加 1 个独立增量更新场景（新文件/新版本/幂等更新）；
  - **Mac (`#214` 存储端，可并行)**：OneDrive File Provider 实测（使用有意义的大体积合成文件），量化实际占用字节与非预期下载，校验 Finder 原生释放、重启、选择性打开、跨设备同步恢复（环境缺失则标 `BLOCKED`/`NOT_VERIFIED`）；
  - **Mac (`#215` 集成端)**：DEVONthink Index + 字段写入/回读与部分失败补偿实测固化。
- **Acceptance Criteria** (Spec §7 Holdout Gate):
  - 语义总分均值 `>= 90/100`，单次最低 `>= 85/100`，`3/3` 流程完成；
  - 可判定条目：项目与版本准确率 `100%`，角色准确率 `>= 95%`；
  - 零跨项目错归、零共享误归专属、零强行归属歧义文件、零数据丢失/覆盖/逃逸；纠错率 `<= 5%`；
  - 报告全部计数与分母，区分合理确认与错误输出、不必要弃权与直通率；记录实际耗时/Token/成本（或 `NOT_VERIFIED`）；
  - 存储/恢复门禁独立评定，不得用语义分替代。
- **Failure & Rollback**: 任一门禁失败仅允许提出**一项**有证据支撑的低成本定向修复方案；若无可靠路径则立即停止，禁止无休止调参刷榜。
- **Host Responsibility**: `DevBox`（建库/冻结 Gold/计分） + `Mac`（盲测运行/存储验证）。

### Phase 5 (`#216`): Controlled Real-World Pilot & Final Adoption Decision
- **Spec IDs**: `FR8`, `§7` (Final Decision `#216`), `§8` (ADS 回报)
- **Inputs & Preconditions**: Phase 4 全部必需门禁通过（任何必需门禁未知 => 仅限有条件/不得生产 GO）；Owner 对真实脱敏试点数据集与目标路径的单独隐私授权。
- **Deliverables**:
  - 真实对照人工工作流耗时测量报告（含审阅/确认时间，验证人工省时 `>= 80%`）；
  - 成本/维护性评估与 `#216` 最终决策建议（按原样采用 / 最小适配 / 替代存储或宿主 / 停止）；
  - 真实可复用集成证据（Alpha 与最终采用结果）向 ADS 回报（不阻塞 Forma）。
- **Host Responsibility**: `Owner` + `Mac`。

---

## C5. Verification Plan (分层验证矩阵)

| Tier | Scope & Host | What It Proves | Explicitly Does NOT Prove |
|---|---|---|---|
| **1. DevBox 静态与确定性测试** | Linux DevBox / CI：包清单/Schema 校验、路径碰撞、symlink 逃逸、计划哈希、批准绑定、Journal/幂等/回滚、资格策略、合成测试 | 确定性安全边界、包合规性、Linux 可测模块稳定性 | 不证明 Mac TCC/Vision OCR、WorkBuddy 客户端加载、LLM 语义质量或 OneDrive 同步 |
| **2. Mac WorkBuddy 安装与 29 文档 E2E** | Mac 真实 WorkBuddy 客户端 + 隔离 DEVONthink 测试库（29 文档回归夹具） | 可安装、可召唤、端到端不报错、DEVONthink 写/回读、中断恢复与重复幂等 | 不证明新文档盲测泛化能力（29 文档仅为回归夹具，**不继承 Codex 92.34 分**） |
| **3. Owner 产品体验验收** | Owner 在 Mac 上直接操作 Expert（无手动命令行串联） | 交互简洁性、预览可读性、纠错流畅度满足产品预期 | 不证明大规模盲测精度或跨设备存储恢复 |
| **4. 100–200 文档盲测与增量切片** | DevBox 冻结独立 Gold/Rubric + Mac 3 次隔离运行 + 增量更新切片 | Spec §7 绝对语义门禁（均值 ≥90、最低 ≥85、100% 项目/版本、≥95% 角色、≤5% 纠错） | 不替代存储/恢复门禁 |
| **5. OneDrive 存储与跨设备恢复** | Mac 真实 File Provider + 大体积合成文件（`#214`） | 选择性下载、实际字节占用、重启/新设备同步恢复 | 若受网络/无第二设备/无驱动能力限制，须标 `BLOCKED`/`NOT_VERIFIED` |
| **6. 真实业务试点与最终采用** | Owner 单独授权的真实业务范围（`#216`） | 含审阅确认在内人工省时 `>= 80%` 及综合成本收益 | 未获明确隐私授权不得启动 |

---

## ADS Governance

- **当前 Pin**：`16b99f4b49769555acc66a0c57b8cfcb8c8bac60`（`cnb/dev`，`python3 scripts/check_ads_pin.py --verify-upstream` 返回 `ADS_PIN_OK`）。上游最新 Release 为 `v0.8.1`（`ffafa9d4c102c76bc4ae2c249d7c9b86e7137219`）。本轮**不升级 ADS pin**。
- **既有反馈核对**：ADS `#143`（v0.8.1 AI-native self-management）与 `#146`（绝对验收门禁 vs 相对提升）均已 `CLOSED`，本轮不重复提交。
- **Learning Loop (`#98`)**：继续适用“仅在触发条件发生时记录 5 字段复盘，不设为每 PR 必选项，不新增阻塞门禁”。
- **跨项目治理回报边界**：本轮尚处于 Spec-to-Plan 阶段，**严禁**将未验证的 WorkBuddy 架构设想作为成功复用案例上报 ADS；正式复用案例待 Phase 3 Alpha 实际验收后回报，且不等待 ADS 响应阻塞 Forma。
