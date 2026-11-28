# Forma WorkBuddy Edition — Capability Reuse & Language Decision Matrix

- **Canonical Spec**: `docs/specs/2026-11-27-workbuddy-edition.md` (revised 2026-11-28 in PR #226; original baseline `110a469208a944a485b4389779795174dad7bc5b`)
- **Audit Baseline**: `origin/dev` (`0ac64c4d0dffa02d6f2785aad28bd8ea44ceaa59`) & `origin/benchmark-evidence-v1` (`dae571dc784b9db509f04afdefee46764df17894`); active `workbuddy/dev` HEAD `46ec2301b916aff191badfbc0eb678a83c72899b`
- **Principle**: 严格按优先级选择方案——(1) WorkBuddy 原生能力 → (2) Expert/Skill 配置与指令 → (3) 成熟可执行工具/原生集成 → (4) 直接复用既有 Forma 组件 → (5) 最小适配 → (6) 仅对已证实的残余缺口新建最小实现。**严禁预设实现语言，不重建独立应用。**

---

## 1. Capability-by-Capability Reuse Decision

| Capability / Requirement | Preference Level & Classification | Existing Capability & Evidence | Reuse Method | Remaining Gap | Selected Approach & Language/Runtime | Estimated Burden & Trade-offs |
|---|---|---|---|---|---|---|
| **Runtime、对话 UI、模型路由、基础工具 (`Read`/`Write`/`Grep`/`Glob`/`Bash`)** (`§1`, `§3`) | (1) `WorkBuddy Native Capability` | WorkBuddy 官方文档 (`open.workbuddy.cn/docs/expert`, 2026-11-27) | 直接使用客户端内置能力；`agents/forma.md` 禁止自定义 `tools` | 无 | **无需代码** | 零维护；受 WorkBuddy 工具审批机制约束（见 Plan §C4.5） |
| **Expert / Skill 编排、命名策略、语义分类与推理** (`§3`, `FR3`) | (2) `WorkBuddy Configuration / Instructions` | `agents/*.md` + `skills/*/SKILL.md`；`benchmark-v1-perception/prompts/` | 以中文为主的 Skill 指令约束 LLM 基于内容推断角色/项目/关系/重复 | 无（防注入规则与不确定性显式标示由指令+Plan 校验协同） | **Markdown + YAML Frontmatter**，无需独立推理代码 | 维护成本极低；禁止硬编码正则/分类表，不 Fork Sorty |
| **`.txt` 文件读取** (`FR2`) | (1) `WorkBuddy Native Capability` | WorkBuddy 原生 `Read` 工具 | Agent 直接读取或通过现有工具读取 | 仅长文档需防静默截断（与下方分块策略统一） | **原生 `Read` / shell 标准读取**，不单建解析器 | 零新增代码 |
| **PDF/DOCX/XLSX/PPTX 内容解析** (`FR2`) | (1)/(2) `WorkBuddy Native First` → (3) `Optional Fallback` | WorkBuddy 官方文档 (`Practice-One`, `Conversation`, 2026-11-27) 原生支持 PDF/Word/Excel/PPT/TXT 读取；`DocVortex 0.6.26` (MIT) 为已验证的备选 | **优先使用 WorkBuddy 原生读取与官方办公文档技能**；仅当遇到扫描件、复杂多表或原生抽取失败时才回退 `docvortex convert` | 长文档有界分块检索与失败原因透传 | **原生读取优先**，不默认强制预装外部解析器 | 零安装阻塞；避免无端引入重型依赖 |
| **扫描件 PDF OCR 回退** (`FR2`) | (1) `WorkBuddy Native` → (3) `Optional Fallback` | WorkBuddy 支持图片/多模态读图；`benchmark-v1-perception` D22/D28 Apple Vision 结果；`privatenumber/mac-ocr` (`v1.2.1`, MIT) | 原生读图优先；大批量扫描 PDF 回退 macOS Apple Vision / `mac-ocr` | 不强制预装 | **原生优先 + 可选 `mac-ocr`/Vision**，不自研 OCR 引擎 | 仅 macOS 运行；拒绝强制云端 OCR（D26 教训） |
| **目录枚举、NFC/大小写碰撞、Symlink 检查、云占位符识别** (`FR1`) | (4)/(5) `Forma Contract Reuse + Minimal Adaptation` | `FormaCore/Sources/SourceFilesystem.swift` (`SourcePath.normalize`, `SF_DATALESS`), `M11RealDirectoryAcceptance.swift` (`assertNotSymlink`), `#51`/`#136` (`forma-eligibility.v1.json`) | 复用 `forma-eligibility.v1.json` 与碰撞/symlink/`SF_DATALESS` 校验规则；修复 `#136` 预算外误计 `INCLUDE` 口径 | WorkBuddy `Glob`/`Read` 无法原生检测 Unicode NFC/大小写碰撞与 Darwin `SF_DATALESS` 标记（避免误触发 OneDrive 水合） | **并入唯一残余确定性执行器**（语言由 `M1-A` 门禁锁定，见 §2） | ~150–250 LOC；显著低于移植整个 `FormaCore` |
| **不可变计划校验、批准绑定、本地 FS 原子移动、Journal 与冲突恢复** (`FR4`, `FR5`) | (4)/(6) `Forma Contract Reuse + Residual New Implementation` | `FormaCore/Import/`（`ImportPreflight`, `ImportLedger`, `ImportArbitration`, `ImportSingleWriter` 契约）+ `sorty-plan.json` v2 预期字段 | 复用四态仲裁、单写租约、append-only 日志与 `plan_hash`/`snapshot_hash` 绑定契约 | **真正残余缺口**：`FormaCore` 的 `ImportWriteSurface` 仅支持 DEVONthink 写记录，无本地文件系统 `move/rename` 执行与碰撞/TOCTOU 防护 | **新建最小确定性本地 FS 执行器**（语言由 `M1-A` 门禁锁定，见 §2） | ~250–450 LOC；避免重造原生 App，避免混入 GPL-3.0 `sorty_helper.py` |
| **DEVONthink 索引、白名单元数据发布与强制回读** (`FR6`, `#10`, `#215`) | (3) `Existing Native Integration` | DEVONthink 4.4.2 官方内置 MCP（`localhost:8420`, macOS Sequoia+）；`dae571dc` 验证的 AppleScript/JXA (`C1/C2 PASS`) | 优先使用 DEVONthink 4.4.2 内置 MCP（无内置 MCP 时才回退极简 `osascript`）：Index 原件 + `list_custom_metadata_fields` 白名单预检 + 写入 Profile 批准的 12 字段与白名单 Tags + **强制独立回读** UUID/路径/Tags/字段 | 仅做部分失败精确状态记录与重试前实时状态查询；保持适配器可替换但**当前产品验收不可省略**；不引入必填 Connector | **原生配置（内置 MCP）或 `osascript` 最小脚本**；不建跨平台 CLI Connector | 零长期守护进程；严禁外部直连 SQLite；`auth.required=false` 须作显式安全约束处理 |
| **OneDrive File Provider 存储** (`FR7`, `#214`) | (1)/(2) `OS Native + Configuration` | macOS 原生 File Provider；`SF_DATALESS` 规避水合 | 作为选定原件目录；通过 `inspect` 与 Skill 规则禁止范围外扫描或放入活动 DT DB | 平台无 CLI 驱逐接口（`B1/B4/C2c BLOCKED_WITH_EVIDENCE`） | **无代码（配置与规避策略）** | 不自研存储/驱逐层 |
| **包清单校验与盲测计分** (`§6`, `§7`) | (3)/(6) `Reuse + Minimal Script` | `scripts/check_ads_pin.py`, `scripts/make_i1_b2_synthetic.py`；`benchmark-evidence-v1` 29 文档 | 复用既有脚本模式 | `benchmark-evidence-v1` 无现成盲测 Rubric 计分器；需包结构校验器 | 轻量开发期校验脚本（不随产品发布） | <200 LOC，随 `M2`/`#213` 按需建立 |

> **关键澄清**：普通 Skill 中通过 `Bash` 调用脚本，**不得假设** Connector 专属的托管 Node.js/Python 运行时（`connector.json` 中的 `runtime` 字段仅用于 Connector，见 `workbuddy_docs.md`）对普通 Skill 自动可用。

---

## 2. Language & Runtime Evaluation for Residual Gap

**残余自定义代码规模说明**：下表与既有文档中的 ~400–850 LOC（或历史 ~150 LOC）均为初期工程估算，**不是验收标准，也不构成对 Spec §10.8 P0 确定性安全收敛、3D 准入判定、最小 `sqlite3` 持久化或 DEVONthink 回读契约的代码行数限制**。不对“无需自定义代码”的推理、UI、路由、OCR、存储引入任何语言。

| Candidate | WorkBuddy 执行与打包兼容 | macOS 安装与依赖负担 | DevBox 开发与验证 | 现有代码复用 | FS 安全与恢复 (NFC/Symlink/Atomic) | 分发与更新复杂度 | 许可兼容 | 长期维护与规模 |
|---|---|---|---|---|---|---|---|---|
| **Pure WorkBuddy Native (无自定义代码)** | 原生 100% 兼容 | 零依赖 | 不可在 Linux 确定性单测 | 无法复用 `SF_DATALESS` / 账本契约 | **不足**：原生 `Bash`/`Write` 缺原子日志、Unicode 碰撞预检与 `SF_DATALESS` 防水合 | 零 | N/A | 不满足 `FR1`/`FR5` 安全门槛（**否决**） |
| **Shell (`bash`/`zsh`) + UNIX 工具** | 兼容 `Bash` | 零依赖 | Linux/macOS `stat`/flags 语法差异大 | 需重写账本与 JSON 解析 | **弱**：路径含空格/换行/Unicode 极易出错，JSON 构造脆弱 | 低 | N/A | 复杂日志状态机难以维护（**否决**） |
| **Python (仅标准库，零第三方包)** | Skill `scripts/` 调用 `python3`；**待 `M1-A` 实测宿主机 `python3` 与 PATH** | 若用系统/已有 `python3`（且 `docvortex` 本身已有 Python）则零额外运行时；否则需引导 | DevBox (Python 3.14) 可直接跑 `unittest`（零 `pytest` 强依赖） | 可直接迁移 `FormaCore` 算法规则与 `make_i1_b2_synthetic.py` 风格 | `os.path.realpath`、`unicodedata.normalize('NFC')`、`sqlite3`/`json`、`ctypes` 调用 `renamex_np(RENAME_EXCL)`/`renameat2(RENAME_NOREPLACE)` 与 `SF_DATALESS`（不支持时 fail closed；禁用静默覆盖的 `os.rename`） | 随 Skill `scripts/` 直接打包，无需跨架构编译 | PSF (兼容) | ~450–650 LOC；可读性高、单语言内聚（**候选 A**） |
| **Node.js / TypeScript** | Skill 不共享 Connector 托管 Node；需用户自装 Node | 增加非必要运行时负担（DocVortex 已用 Python） | DevBox 需额外维护 Node/TS 构建 | 零复用 | `fs` + `sqlite`（Node <22 无稳定内置 SQLite） | 若用 TS 需编译产物或打包 `node_modules` | MIT | 多引入一门运行时，无必要多语言（**否决**） |
| **Go (单静态二进制)** | Skill 直接调用编译好的 macOS arm64 二进制，不依赖用户 `python3` | **零运行时依赖**，不受客户机 Python PATH 破坏影响 | DevBox (Linux) 可交叉编译 `GOOS=darwin GOARCH=arm64` 并跑 `go test` | 规则移植成本与 Python 相近 | 强类型、原生 `filepath.EvalSymlinks`、`syscall.Stat_t.Flags` (`SF_DATALESS`)、`unix.RenamexNp(..., RENAME_EXCL)` / `Renameat2(..., RENAME_NOREPLACE)`（禁用静默覆盖的 `os.Rename`） | 需分发预编译二进制（可能触发 macOS Gatekeeper/quarantine，须 `M1-A` 实测） | BSD-3-Clause | ~500–750 LOC；若 `M1-A` 发现 Python PATH 不稳则为最优备选（**候选 B**） |
| **Existing Swift (`FormaCore` 窄 CLI)** | 可调用预编译 arm64 CLI | 依赖 Xcode/macOS 14+ 运行库，且 `FormaCore` 绑定 `CryptoKit`/`Security`/GRDB | **Linux DevBox 无法编译测试**（CI 仅 `macos-26`） | 可直接复用 `SourceFilesystem` / `ImportLedger` | 原生 `Darwin.renamex_np(RENAME_EXCL)` 最强 | 需在 Mac 构建/签名，DevBox 无法本地出包 | 仓库缺 `LICENSE` | 拉入 GRDB/ZIPFoundation 重型依赖（**备选，非首选**） |

### 2.1 M1-A Closure & Runtime Choice
- **M1-A 收口状态**：`CORE_HOST_FEASIBILITY_VERIFIED` · `NATIVE_SECURITY_ARCHITECTURE_DOCUMENTED` · `PRODUCT_SECURITY_ACCEPTANCE_PENDING`。
- **实际运行环境选择**：`M1-A` 已在 Mac WorkBuddy 实测验证 Expert 本地安装、Skill 自动发现、自然语言驱动、脚本执行、包内资源路径、Python/Node.js/Swift 运行时及升级卸载均可用；因此残余确定性安全内核采用 **零第三方依赖的标准库 Python 3 (`forma_fs.py`)**，无需额外编译或 Connector 包装，也不强制预装 `docvortex`/`mac-ocr`。
- **声明复用 ≠ 语义等价**：本矩阵的复用条目是来源声明，不证明运行时等价；#223 实测 alpha 内核与声明的 Sorty-style plan/eligibility 语义不一致，两条可执行评审项已由 PR #224 修复合入（bf20192），其余 P0 收敛项由 Spec §10.8 单独追踪；`0.1.0-alpha.2` 包先于修复构建，#220 必须以合并后重建包复测。

---

## 3. External Dependency Audit

| Dependency | Official Source | Latest Version (Date) | License & Redistribution | Maintenance | Platform Limits | Decision |
|---|---|---|---|---|---|---|
| **DocVortex** | PyPI `docvortex` / `github.com/myhloli/DocVortex` | `0.6.26` (2026-11-19) | MIT（含 MIT/Apache-2.0/BSD-3-Clause 原生依赖） | 极活跃（2026-11-27） | **仅 macOS arm64 (macOS 14+)** / Linux；不支持 Intel Mac；不含 OCR | **直接调用 `docvortex convert` CLI** |
| **mac-ocr** | `github.com/privatenumber/mac-ocr` | `1.2.1` (2026-10-17) | MIT | 活跃（2026-10） | 仅 macOS（Vision 框架，纯离线） | 扫描件 OCR 回退候选（或等价 30 行 Swift `VNRecognizeTextRequest`） |
| **DEVONthink 4.4+ & 内置 MCP** | `devontechnologies.com` | `4.4.2` (2026-10-19) | 专有商业软件（Custom Metadata 需 Pro/Server） | 厂商维护 | 仅 macOS（内置 MCP 需 Sequoia+） | 宿主既有软件配置使用，不打包分发 |
| **dvcrn/mcp-server-devonthink** | `github.com/dvcrn/mcp-server-devonthink` | `1.10.0` (2026-04-27) | **GPL-3.0**（`LICENSE` 为 GPLv3，`package.json` 误标 MIT） | 活跃（2026-09） | 仅 macOS（JXA） | 仅当内置 MCP 不可用时作用户侧可选参考，不混入包体 |
| **Sorty** | `github.com/sorty-organizer/Sorty` | `v1.3.1`（HEAD `9c5ad2ed`，零上游变更） | GPL-3.0 | 活跃 | macOS 15+ | **patterns-only**：吸收成熟设计与可合法复用能力（含 26 项平台无关 pytest 内核模式）；不引入第二文件操作内核、不分发 GPL 代码/二进制、不继承其宽松授权策略 |
| **Forma 原仓库许可缺口** | `origin/dev` 根目录 | 无 `LICENSE` 文件 | 未声明（默认保留所有权利） | 内部仓库 | — | `M2` 打包前须由 Owner 明确仓库/产物许可证 |
