# Forma WorkBuddy Edition — Spec-to-Plan Traceability & Acceptance Consistency

- **Canonical Spec**: `docs/specs/2026-11-27-workbuddy-edition.md` (`110a469208a944a485b4389779795174dad7bc5b`, unmodified)
- **Target Plan**: `docs/workbuddy/IMPLEMENTATION_PLAN.md` (Revised)

---

## 1. Forward Traceability Matrix (Spec → Plan)

| Spec ID / Section | Requirement Summary | Plan Task / Section | Verification | Coverage |
|---|---|---|---|---|
| **§1 Product outcome** | WorkBuddy-native Expert（非独立应用）；召唤→选区→预览→批准→执行→报告；可选 DT Index+回读；OneDrive 仅存原件；Project 可选、Buddy App 延后；禁自研 Runtime/UI/路由/DB/搜索/OCR/存储/框架 | `PLAN §C1`, `§C2`, `M1-A`, `M1-B`, `M2`, `M3` | `M1-A` 宿主实测 + `M2` 静态校验 + `M3` E2E | `COVERED` |
| **§1 Alpha scope** | Alpha 仅 Organize；增量更新在 Alpha 体验通过后；历史审计/检索为 Backlog；无自动定时写入/上架/迁移/发布 | `PLAN §C1`, `§C4.2 (M3, Phase 4)` | `M3` Owner UX 验收 + `Phase 4` 增量切片 | `COVERED` |
| **§2 Starting evidence** | 核对 `dev`/`main` HEAD；保留 `benchmark-evidence-v1` 不合并；继承 B1-C0/C1/D26 与 storage 阻断事实；ADS `#143`/`#146` 不重复 | `PLAN §0`, `§C5`, `§6.2` | `Phase A` 已核验 + `check_ads_pin.py` | `COVERED` |
| **§3 Official platform contract** | 5 份官方文档 URL/日期；单 Agent；包目录、`plugin.json`（含 `description`、40–50 字中文、3 tags/quickPrompts、`defaultInitPrompt==quickPrompts[0]`、512×512 头像）；`forma.md` 禁 `tools`；Skill frontmatter；DT 非必填；禁跨平台 DT CLI Connector；不臆测本地 zip 导入 | `PLAN §C2`, `M1-A`, `M2`, `M3` | `M1-A` 首次安装/依赖/重复/升级/卸载实测 + `M2` 清单校验 | `COVERED` |
| **§4 Reuse-first plan** | 审计历史 Issue/M0 证据与许可；优先原生/配置/现有 CLI；不 Fork Sorty；记录拒绝理由与能力矩阵；OMP+DeepSeek 调研并如实记录路由 | `REUSE_MATRIX.md §1–§3`, `PLAN §C3` | `M1-A` 语言锁定 + `M2` 许可核查 | `COVERED` |
| **FR1 Input** | 显式源/目标、dry-run 默认、枚举身份/大小/类型/哈希/不可读或离线状态、禁 symlink 逃逸与范围外云拉取、碰撞与扩展名/内容失配检测、禁用生产语料 | `PLAN §C4.2 (M1-A/M1-B)`, `§C4.5`, `REUSE_MATRIX` | `M1-B` 确定性单测（含 `#136` 修复） | `COVERED` |
| **FR2 Perception** | PDF/DOCX/XLSX/PPTX/TXT；`docvortex` CLI + macOS Vision 回退；保留页/表/节证据与失败原因；长文档有界分块；禁仅凭文件名或静默截断；云 OCR 仅可选授权 | `PLAN §C2`, `REUSE_MATRIX §1`, `M1-B` | `M1-B` 解析/分块测试 + `M3` Mac Vision 实测 | `COVERED` |
| **FR3 Reasoning** | LLM 推断业务身份/角色/意图/项目边界/买方卖方/版本状态/跨文档关系；禁硬编码分类表/正则；支持命名策略、分离共享/歧义、禁编造、判重不删原件、文档指令不可信 | `PLAN §C2`, `§C4.5 (Threat 9)`, `M2` | `M3` 29 文档回归 + `#213` 盲测 | `COVERED` |
| **FR4 Plan** | 机读不可变计划 + 可读预览；含 source identity、源/目标、处置、证据、元数据变更、冲突/不确定性、快照、Schema 版本与 `plan_id`/`plan_hash`；可修正重生成；未精确批准不写入；变更作废批准；安全拒绝非成功 | `PLAN §C1`, `§C4.5 (Threat 1,3,4)` | `M1-B` 过期/篡改拒绝单测 + `M3` 交互实测 | `COVERED` |
| **FR5 Execution** | containment/symlink/哈希/过期/碰撞/重复目标/权限/空间/单写锁；禁未转义 shell 拼接与静默覆盖；**强制排他原子重命名（`RENAME_EXCL`/`RENAME_NOREPLACE`，不支持则 fail closed）**；Journal before/after、幂等、冲突检查恢复；空目录清理须单独批准；File Provider 单独隔离；映射校验与审计证据 | `PLAN §C4.2 (M1-B)`, `§C4.5 (10 Threats)` | `M1-B` 并发目标竞态/Unicode/大小写/跨卷/恢复单测 + `M3` 实测 | `COVERED` |
| **FR6 DEVONthink optional** | 隔离测试库；Index 原件；复用 `#10` 精简必要字段写入并回读 UUID/链接/路径；分离状态与部分失败补偿；不承诺跨系统原子事务；禁外部 SQLite；禁写生产库 | `PLAN §C2`, `REUSE_MATRIX`, `M3`, `#215` | `M3` Mac 隔离库写入/回读与部分失败实测 | `COVERED` |
| **FR7 OneDrive optional** | 选定 File Provider 为原件存储，活动 DT DB 禁入 OneDrive；禁范围外水合；不自研存储/驱逐；核验 Finder 释放/重启/选择性打开/分配字节与非预期下载；较大合成文件；缺环境标 `BLOCKED`/`NOT_VERIFIED` | `PLAN §C2`, `§C5`, `Phase 4 (#214)` | `#214` Mac 物理实测矩阵 | `COVERED` |
| **FR8 Privacy** | 记录真实模型/API 路由、内容出境、日志留存；默认合成数据；禁记凭证或公开真实路径/Token；本地解析≠本地推理；禁未经批准提权/TCC/全局修改 | `PLAN §C1`, `§C4.2`, `§C5`, `RISK_REGISTER` | `M1-B` 脱敏单测 + `M3` 宿主恢复核查 | `COVERED` |
| **§6 Deliverables & host split** | DevBox→Mac 分工与早置可行性；可工作 Alpha 包、zip+SHA256、安装/卸载指南、known gaps、Mac 交接；Linux 不伪造 Mac PASS；3 次 100–200 盲测、增量切片、`#214`、授权试点 | `PLAN §C4.1 (12-step)`, `§C4.2 (M1-A..Phase 5)` | 分阶段门禁（本轮止于 Docs PR 提交） | `COVERED` |
| **§7 Acceptance & stopping rules** | Alpha 门禁；Holdout 30/20/15/10/10/10/5、均值 ≥90、最低 ≥85、3/3 流程、100% 项目/版本、≥95% 角色、零严重错归/丢失、≤5% 纠错、计数/分母、人工省时 ≥80%；失败仅一次定向低成本修复；`#216` 最终决策 | `PLAN §C4.2`, `§C5`, `#213`, `#216` | `M3` + `Phase 4` + `Phase 5` | `COVERED` |
| **§8 GitHub & ADS convergence** | `#217` 主任务；全量 open issue/PR 分类；Project #18 实测更新；worktree/agent 审计；治理简化提案；ADS 仅 Alpha 后回报 | `ISSUE_PR_DISPOSITION.md`, `PLAN §C6`, `§6.2` | `gh` 实测输出 + Docs PR | `COVERED` |
| **§9 Required final report** | 12 项 DevBox 报告字段；实事求是不虚报 Mac/存储/发布 | `PLAN §C4.2 (M2)`, 本轮 §12 报告 | `M2` 交付检查 + 本轮 Stop Gate 报告 | `COVERED` |

---

## 2. Reverse Traceability Matrix (Plan → Spec)

| Plan Phase / Section | Mapped Spec ID(s) | Justification |
|---|---|---|
| `M1-A: WorkBuddy Host Feasibility` (`#218`) | `§3`, `FR1`, `FR8`, `§6` | 在大规模编码前于真实 WorkBuddy 宿主验证平台加载、脚本执行、运行时与 TCC 未知项 |
| `M1-B: Residual Deterministic Tooling` (`#218`) | `FR1`, `FR2`, `FR4`, `FR5`, `FR8`, `§4` | 仅实现 WorkBuddy 原生与成熟工具无法满足的最小安全执行与分块缺口 |
| `C4.5 Safety & Authorization Architecture` | `FR4`, `FR5`, `FR8` | 明确 6 层授权边界与 10 类威胁防护，诚实标注平台无法技术防绕过的残余限制 |
| `M2: Expert Package & Reproducible Build` (`#219`) | `§3`, `FR3`, `FR6`, `FR8`, `§6`, `§9` | 产出符合官方契约的 Expert 安装包、校验脚本与 Mac 交接清单 |
| `M3: Mac Installation, 29-Doc E2E & Owner UX` (`#220`) | `§3`, `FR1–FR8`, `§6`, `§7` | 完成客户端实装、29 文档回归与 Owner 体验门槛 |
| `Phase 4 (#213/#214/#215)` & `Phase 5 (#216)` | `§1`, `FR6`, `FR7`, `§7`, `§8` | 盲测 Rubric 验收、增量切片、存储恢复、DEVONthink 固化、省时测量与最终决策 |
| `C6 Governance Simplification Proposal` | `§8`, ADS v0.8.1 冻结 | 仅提案清理 SwiftUI 遗留重型治理，不越权删改 `.ads` 或全局配置 |

---

## 3. Track G — 15-Point Acceptance Consistency Checklist

- [x] 官方支持的 Expert 安装与召唤方式（`M1-A` 提前实测，不臆测本地 zip 导入）
- [x] 全部必需文档格式（PDF/DOCX/XLSX/PPTX/TXT）
- [x] 证据完整性、表格关系与长文档有界分块处理
- [x] 禁止静默截断与仅凭文件名分类
- [x] 显式解析失败与不支持状态上报
- [x] 批准绑定执行与独立输出映射校验
- [x] 安全恢复（冲突感知）与重复幂等执行
- [x] DEVONthink 与 OneDrive 保持可选
- [x] 29 文档回归夹具先于高成本盲测
- [x] Owner 产品体验验收先于盲测（`M3` 门禁）
- [x] 原业务绝对语义门槛完整保留（均值 ≥90、最低 ≥85、3/3 流程、100% 项目/版本、≥95% 角色、≤5% 纠错）
- [x] 零严重错归、零数据丢失、零静默覆盖、零范围逃逸
- [x] 独立存储/恢复门禁（不与语义分互相替代）
- [x] 实测人工省时（含审阅/确认在内 ≥80%）
- [x] 隐私与真实模型数据出境披露

**Traceability Gates**: Coverage = `100%` | Unmapped Mandatory = `0` | Weakened Criteria = `0` | Arbitrary Added Gates = `0` | Spec Modified = `NO` (`110a469208a944a485b4389779795174dad7bc5b`).
