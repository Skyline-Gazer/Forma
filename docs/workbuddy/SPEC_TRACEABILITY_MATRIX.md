# Forma WorkBuddy Edition — Spec-to-Plan Traceability Matrix

- **Canonical Spec**: `docs/specs/2026-11-27-workbuddy-edition.md` (`110a469208a944a485b4389779795174dad7bc5b`)
- **Target Plan**: `docs/workbuddy/IMPLEMENTATION_PLAN.md`

---

## 1. Forward Traceability Matrix (Spec → Plan)

| Spec ID / Section | Requirement Summary | Plan Task / Section | Verification Tier & Method | Coverage Status |
|---|---|---|---|---|
| **§1 Product outcome** | WorkBuddy-native Expert（非独立应用）；召唤→选区→预览→批准→执行→报告；可选 DEVONthink Index+回读；OneDrive 仅存原件；Project 可选、Buddy App 延后；禁止自研 Runtime/UI/路由/DB/搜索/OCR/存储/框架 | `PLAN §C1`, `§C2`, `Phase 1–3` | `M2` 包静态校验 + `M3` Mac 客户端实测 | `COVERED` |
| **§1 Alpha scope** | Alpha 仅含 Organize（inspect/plan/approve/apply/verify/recover）；增量更新在 Alpha 体验通过后；历史审计/检索为 Backlog；无自动定时写入/上架/迁移/发布 | `PLAN §C1.3`, `Phase 3`, `Phase 4` | `M3` Owner 验收 + `Phase 4` 独立增量切片 | `COVERED` |
| **§2 Starting evidence** | 核对 `dev`/`main` 实际 HEAD；保留 `benchmark-evidence-v1` 不合并；继承 B1-C0/C1/D26 与 storage 阻断事实；核对 ADS pin 与 `#143`/`#146` 不重复 | `PLAN §0`, `§C5`, `§ADS Governance` | `Phase A` 已核验 + `check_ads_pin.py --verify-upstream` | `COVERED` |
| **§3 Official platform contract** | 核验 5 份官方文档并记录 URL/日期；单 Agent（非 Team）；精确包目录、`plugin.json` 字段（含 40–50 字中文描述、3 tags、3 quickPrompts、`defaultInitPrompt==quickPrompts[0]`、512×512 头像）；`agents/forma.md` 禁用 `tools`；Skill frontmatter；DEVONthink 不作必填依赖；不把 macOS DEVONthink 标为跨平台 CLI Connector；不臆测本地 zip 导入 | `PLAN §C2.1`, `§C2.2`, `Phase 2 (M2)`, `Phase 3 (M3)` | `M2` 清单自动化校验 + `M3` Mac 客户端实际安装验证 | `COVERED` |
| **§4 Reuse-first plan** | 审计 `#10/#11/#19/#20/#22/#23/#51/#129–131/#136/#133/#162` 与 M0 证据；对比 FormaCore/Sorty/WorkBuddy/DEVONthink 许可与维护状态；优先调用脚本/窄提取，不 Fork Sorty、不重造原生应用；记录能力矩阵与拒绝理由；使用 OMP + DeepSeek 并如实记录模型身份 | `REUSE_MATRIX.md`, `PLAN §0`, `Phase 1–2` | `M1/M2` 依赖清单与许可证核查 | `COVERED` |
| **FR1 Input** | 显式源/目标、dry-run 默认、枚举身份/大小/类型/哈希/不可读或离线状态、拒绝 symlink 逃逸与范围外云拉取、不扫范围外文件、碰撞与扩展名/内容失配检测、禁用生产语料 | `PLAN §C1.2`, `Phase 1 (M1 inspect)` | `M1` Linux `pytest`（symlink/碰撞/失配/dataless/作用域边界） + `#136` 口径修复 | `COVERED` |
| **FR2 Perception** | PDF/DOCX/XLSX/PPTX/TXT；DocVortex + macOS Vision OCR 回退；保留页/表/节证据、表格关系与失败原因；长文档有界分块检索；禁止仅凭文件名分类或静默截断；云 OCR 仅可选显式授权 | `PLAN §C1.2`, `Phase 1 (M1 perceive)`, `REUSE_MATRIX` | `M1` 解析/分块单测 + `M3` Mac Vision 扫描件实测 | `COVERED` |
| **FR3 Reasoning** | LLM 推断业务身份/角色/意图/项目边界/买方卖方/版本状态/跨文档关系；禁止硬编码分类表或枚举正则；支持命名策略、分离共享参考与歧义、避免编造、内容判重不删原件、文档指令不可信 | `PLAN §C1.2`, `Phase 2 (M2 Skills)` | `M3` 29 文档回归 + `Phase 4` 100–200 文档盲测计分 | `COVERED` |
| **FR4 Plan** | 机读不可变计划 + 可读预览；含稳定 source identity、源/目标、处置、证据、元数据变更、冲突/不确定性、输入快照、Schema 版本与 `plan_id`/`plan_hash`；可修正重生成；未精确批准不写入；文件/计划变更作废批准；安全拒绝不算成功执行 | `PLAN §C1.2`, `Phase 1 (M1 plan)` | `M1` 计划校验/过期失效单测 + `M3` 审阅批准交互实测 | `COVERED` |
| **FR5 Execution** | 校验 containment、symlink 逃逸、源哈希、过期计划、大小写/Unicode 碰撞、重复目标、权限、空间与单写锁；禁止未转义路径 shell 拼接、静默覆盖/删除/外部写入；Journal before/after、幂等、部分状态、冲突检查恢复；空目录清理须单独批准；同卷原子移动；输出映射校验与本地审计证据 | `PLAN §C1.2`, `Phase 1 (M1 apply & recover)` | `M1` 故障注入/幂等/恢复/碰撞单测 + `M3` 断点恢复与重复安全实测 | `COVERED` |
| **FR6 DEVONthink optional** | 显式隔离测试库；Index 原件（不导入重复字节）；复用 `#10` 精简必要字段契约写入并回读 UUID/链接/路径；分离原件与 DT 状态、部分失败精确报告与重试；不承诺跨系统原子事务；不用外部 SQLite 替代 Smart Group；禁写生产库 | `PLAN §C2.1`, `Phase 2`, `Phase 3`, `Phase 4 (#215)` | `M3` Mac 隔离库写入/回读与部分失败补偿实测 | `COVERED` |
| **FR7 OneDrive optional** | 选定 File Provider 为原件存储，活动 DT DB 禁入 OneDrive；不触发范围外水合；不自研存储/驱逐；核验 Finder 原生释放/重启/选择性打开/分配字节与非预期下载；用较大合成文件；区分本地保留与跨设备恢复；缺环境标 `BLOCKED`/`NOT_VERIFIED` | `PLAN §C2.1`, `Phase 4 (#214)`, `RISK_AND_DEPENDENCY_REGISTER` | `#214` Mac 物理实测矩阵 | `COVERED` |
| **FR8 Privacy** | 记录真实模型/API 路由、内容出境、抽取/日志留存；默认仅合成数据；禁记凭证或公开真实路径/内容/Token；本地解析≠本地推理；禁未经批准下载/提权/全局外观或 TCC 修改 | `PLAN §C1.3`, `§C5`, `Phase 1–5`, `RISK_AND_DEPENDENCY_REGISTER` | `M1` 日志脱敏单测 + `M3` 宿主恢复核查 | `COVERED` |
| **§6 Deliverables & host split** | DevBox（规划→可工作 Alpha 包、源码、校验、zip+SHA256、安装/卸载指南、合成测试、Mac 交接；Linux 不伪造 Mac PASS）→ Mac（安装与 29 文档 E2E、Owner 体验把关、恢复宿主）→ 后续（3 次 100–200 盲测、增量切片、`#214`、授权试点） | `PLAN §0`, `§C4 (Phase 1–5)`, `§C5` | 分阶段门禁；**本轮仅提交 Plan，等待 Owner 批准后再启动 M1/M2** | `COVERED` |
| **§7 Acceptance & stopping rules** | Alpha 门禁；Holdout 30/20/15/10/10/10/5 Rubric、均值 ≥90、最低 ≥85、3/3 流程、100% 项目/版本、≥95% 角色、零严重错归/丢失、≤5% 纠错、计数/分母、人工省时 ≥80%；失败仅一次定向低成本修复建议；`#216` 最终决策 | `PLAN §C4 (Phase 3–5)`, `§C5` | `M3` Alpha 验收 + `Phase 4` 盲测评分 + `Phase 5` 试点决策 | `COVERED` |
| **§8 GitHub & ADS convergence** | `#217` 主任务；全量 open issue/PR 分类保留证据；Project #18 以 `gh` 核对更新并保留历史；清理前审计 worktree/agent；ADS 仅在 Alpha 实证后正式回报 | `ISSUE_PR_DISPOSITION.md`, `PLAN §ADS Governance` | `Phase E` `gh` 实测输出 + 前后对比账本 | `COVERED` |
| **§9 Required final report** | 12 项报告字段；实事求是不虚报 Mac/存储/发布 | `PLAN §C4 (Phase 2)`, 本轮 Stop-Gate 报告 | 按阶段边界如实汇报（本轮为 Plan 阶段，package SHA256 在 `M2` 产出） | `COVERED` |

---

## 2. Reverse Traceability Matrix (Plan → Spec)

| Plan Phase / Task | Mapped Spec ID(s) | Justification |
|---|---|---|
| `Phase 1 (M1)`: Deterministic Core CLI (`inspect`, `perceive`, `plan`, `apply`, `recover`) & Linux Tests | `FR1`, `FR2`, `FR4`, `FR5`, `FR8`, `§4`, `§6` | 实现 Spec 要求的确定性输入、解析、不可变计划、安全执行与 Linux 可测基线 |
| `Phase 2 (M2)`: WorkBuddy Expert Package, Skills, Validator, Zip + SHA256, DEVONthink Adapter | `§3`, `FR3`, `FR6`, `FR8`, `§6`, `§9` | 实现 Spec 要求的官方标准 Expert 安装包、Skills 与 Mac 交接产物 |
| `Phase 3 (M3)`: Mac WorkBuddy Installation, 29-Doc Alpha E2E & Owner UX Gate | `§3`, `FR1–FR8`, `§6`, `§7` | 执行 Spec 规定的 Mac 真机安装、29 文档回归、DEVONthink 回读与 Owner 体验门禁 |
| `Phase 4`: 100–200 Doc Blind Holdout (`#213`), Incremental Slice, OneDrive (`#214`), DEVONthink (`#215`) | `§1`, `FR6`, `FR7`, `§6`, `§7`, `§8` | 执行 Spec 规定的盲测 Rubric 验收、增量切片、存储验证与集成固化 |
| `Phase 5`: Controlled Real-World Pilot & Final Adoption Decision (`#216`) + ADS Report | `FR8`, `§7`, `§8` | 执行 Spec 规定的真实省时测量（≥80%）、`#216` 最终裁定与 Alpha 后 ADS 回报 |
| `Phase E` Project #18 & Issue/PR Reconciliation (`M1/M2/M3` 规划 Issue) | `§8`, Mission §7 | 按 Spec 与 Mission 要求完成 `#217` 挂载、历史冻结分类与待实施任务登记 |

---

## 3. Traceability Gate Checklist

- **Spec Requirement Coverage**: `100%` (17/17 sections & FRs mapped)
- **Unmapped Mandatory Requirements**: `0`
- **Unauthorized Scope Expansion**: `0`
- **Weakened Acceptance Criteria**: `0`
- **Unapproved Architecture Changes**: `0`
- **Unowned Implementation Tasks**: `0`

---

## 4. `SPEC_CHANGE_PROPOSAL` Register

> 本轮核验 **未发现阻塞性的 Spec 内部矛盾**。以下仅记录非阻塞的事实澄清与治理边界对齐，**未对 Spec 做任何修改或弱化**：

| ID | Observation / Evidence | Impact on Spec | Proposed Handling (Awaiting Owner if needed) |
|---|---|---|---|
| **SCP-01** | Mission §1/§10 要求本轮在 Spec-to-Plan 后即停止（Stop Gate），而 Spec §6/§9 将 DevBox Alpha 包作为后续交付。 | 无矛盾，属于阶段拆分：Plan 批准前不进入 `M1/M2` 编码与打包。 | 在 `IMPLEMENTATION_PLAN.md` 明确将 Spec §6 DevBox 交付拆为“本轮 Plan 审批门禁 → 批准后执行 `M1/M2`”。 |
| **SCP-02** | WorkBuddy 5 份官方文档均未记载“本地 zip 直接导入客户端”（`NOT_DOCUMENTED`），仅记载客户端创建专家、技能市场及开放平台上传。 | 无矛盾：Spec §3 已明确禁止臆测本地 zip 导入，要求使用官方支持的创建/导入或私有预览路径并记录阻塞。 | `M3` 在 Mac 客户端实测官方可用加载方式，如受限则如实报 `BLOCKED`。 |
| **SCP-03** | `dae571dc` 实测 DEVONthink 4.4.2 AppleScript 无法按自定义元数据 key 搜索、不支持脚本创建 Smart Group、无法直接回读 tag 名称字符串（仅 tag 计数/按 tag 列表查找）。 | 不修改 FR6；FR6 已规定仅使用受支持原生 UI/API，禁止外部 SQLite。 | `M2`/`M3` 仅依赖受支持的 UUID/路径/自定义字段读写及按标签列表查询，不承诺脚本建 Smart Group。 |
| **SCP-04** | `origin/dev` 根目录缺少 `LICENSE` 文件。 | 不影响 Spec；但影响后续分发与复用声明（`REUSE_MATRIX`）。 | 建议 Owner 在 `M2` 打包前明确仓库/产物许可证（如 MIT）。 |
