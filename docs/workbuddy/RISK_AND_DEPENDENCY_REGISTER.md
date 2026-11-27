# Forma WorkBuddy Edition — Risk & Dependency Register

- **Canonical Spec**: `docs/specs/2026-11-27-workbuddy-edition.md` (`110a469208a944a485b4389779795174dad7bc5b`)
- **Date**: 2026-11-27

---

## 1. Epistemic Classification (事实 / 假设 / 未验证)

### 1.1 Confirmed Facts (已确认事实，附证据)
1. **WorkBuddy 官方文档边界**（2026-11-27 实抓 5 页）：Expert 禁止在 `agents/*.md` 中自填 `tools` 字段；`displayDescription.zh` 须 40–50 字；`quickPrompts` 固定 3 条且 `defaultInitPrompt == quickPrompts[0]`；**本地 zip 导入客户端未在官方文档中记载（`NOT_DOCUMENTED`）**。
2. **DocVortex `0.6.26` 平台与能力边界**（PyPI 2026-11-19 + `benchmark-v1-perception`）：MIT 许可（含 MIT/Apache-2.0/BSD-3-Clause 原生依赖）；**仅支持 macOS arm64 (macOS 14+) 与 Linux**，不支持 Intel Mac；不支持扫描件 PDF OCR（抛出 `pdf_ocr_unsupported`）。
3. **DEVONthink 4.4.2 自动化实测限制**（`dae571dc:benchmark-v1-storage/summary.md`）：UUID/重命名/移动/自定义字段读写通过（`C1`/`C2 PASS`），但 **AppleScript 不支持创建 Smart Group、不支持按自定义字段 key 搜索（`project_code:...` 返回 0）、不支持直接回读 tag 名称字符串**；Custom Metadata 仅 Pro/Server 版可用；4.4+ 内置 MCP 需 macOS Sequoia+。
4. **OneDrive File Provider 实测阻塞**（`dae571dc`）：`brctl evict` 拒绝 File Provider 路径；`fileproviderctl` 无驱逐命令；OneDrive 客户端无 CLI/AppleScript 接口；`B1`/`B4`/`C2c` 为 `BLOCKED_WITH_EVIDENCE`，`B6`/`B7`/`C2b` 为 `NOT_VERIFIED`。
5. **仓库与第三方许可现状**（`capability_audit.md` / `deps_research.md`）：`origin/dev` 缺失 `LICENSE` 文件；`dvcrn/mcp-server-devonthink`（1.10.0）`LICENSE` 为 GPL-3.0 而 `package.json` 误写 MIT；Sorty（v1.3.1）为 GPL-3.0；`TomBener/devonthink-mcp` 与 `schappim/macOCR` 无 `LICENSE` 文件；`#136` 存在 M11 Level 4 探测预算外条目误计入 `INCLUDE` 的已知缺陷。
6. **既有基准成绩不可迁移**：`92.34` 是 `Codex CLI 0.164.0 + gpt-6-luna low` 在 29 文档上的表现，`B1-C0`/`B1-C1` 原始证据分支中 `SUMMARY.md` 仍标 `INDEPENDENT_SCORING_PENDING`，且不能直接继承为 WorkBuddy 成绩。

### 1.2 Reasonable Assumptions (合理假设)
1. WorkBuddy 桌面客户端在 macOS 上可通过「我的专家 → 创建专家」或私有预览/本地技能目录加载方式运行包含 `scripts/` 的 Skill（需在 `M3` 真机验证）。
2. WorkBuddy 为 Expert 分配的 `Bash` 工具在获得用户授权目录访问后，可调用包内或受控路径下的 Python 3.11–3.14 环境及 `DocVortex 0.6.26`。
3. 以 `mac-ocr`（MIT）或 30 行 Swift `VNRecognizeTextRequest` 包装作为扫描件 OCR 回退，可复现 `benchmark-v1-perception` 中 D22/D28 的离线识别效果。

### 1.3 Unverified Items (`NOT_VERIFIED` / `BLOCKED`)
1. WorkBuddy Mac 客户端实际安装/加载本地 Expert 包的具体入口与私有预览权限（`NOT_VERIFIED`，`M3` 验证）。
2. WorkBuddy 内置模型路由在 29 文档与 150 文档盲测上的真实语义得分、延迟与 Token 成本（`NOT_VERIFIED`，`M3`/`#213` 验证）。
3. macOS TCC 权限弹窗（对 `Documents`/`Desktop`/`CloudStorage/OneDrive-*` 及 DEVONthink Automation 的授权交互）在 WorkBuddy 进程上下文下的真实行为（`NOT_VERIFIED`，`M3` 验证）。
4. OneDrive 在线占位符水合字节控制、人工释放空间后重搜及跨设备/新设备恢复（`BLOCKED` / `NOT_VERIFIED`，`#214` 验证）。
5. 真实业务场景下含人工审阅确认在内的 `>= 80%` 省时目标（`NOT_VERIFIED`，`#216` 验证）。

---

## 2. Risk & Mitigation Register

| ID | Category | Risk Description | Severity | Likelihood | Mitigation & Contingency Plan | Owner / Gate |
|---|---|---|---|---|---|---|
| **R-01** | 平台准入与安装 | 官方文档未记载本地 `.zip` 导入；若 Mac 客户端仅允许平台审核上架或手动 UI 创建，将阻塞直接导包体验 | High | Medium | `M3` 第一时间实测客户端「我的专家」创建/本地 Skill 目录挂载/私有预览路径；若被阻断则如实报 `BLOCKED` 并向 Owner 申请私有预览或调整分发形态 | `M3` |
| **R-02** | macOS TCC / 沙盒 | WorkBuddy 子进程执行 `Bash`/Python 访问用户目录或向 DEVONthink 发 AppleEvents 可能被 macOS TCC 拦截或静默失败 | High | Medium | 在 CLI 层对 `PermissionError`/AppleEvents `-1743` 做显式错误码透传（不伪装空结果）；在安装指南明确授权步骤；`M3` 真机实测 | `M3` |
| **R-03** | 模型数据出境与隐私 | 本地解析（DocVortex/Vision）不等于本地推理；文档原文进入 WorkBuddy 云端模型路由存在出境风险 | Critical | High | 严格执行 `FR8`：Alpha 与盲测全程仅用合成语料；文档明示模型路由与出境边界；真实试点必须由 Owner 单独书面授权精确数据集与目标 | `FR8` / 全程 |
| **R-04** | 运行时环境限制 | `DocVortex 0.6.26` 仅支持 Apple Silicon (arm64) + macOS 14+，且 0.x 版本迭代快 | Medium | Medium | 锁定 `docvortex==0.6.26`；在安装前检查架构/Python 版本（3.11–3.14）；Intel Mac 明确标为不支持或降级备选路径 | `M1` / `M3` |
| **R-05** | OneDrive 存储与恢复 | File Provider 占位符可能因扫描/哈希意外触发全量水合；且当前无 CLI 驱动驱逐，跨设备恢复未验证 | High | High | `inspect` 通过 `SF_DATALESS` 跳过未水合文件按需读取；严禁将活动 DEVONthink DB 放入 OneDrive；`#214` 独立验收，未验证前不得宣称存储通过 | `#214` |
| **R-06** | DEVONthink 自动化限制 | 4.4.2 AppleScript 无法建 Smart Group、无法按字段 key 搜索、tag 名称回读受限；且需 Pro/Server 许可 | Medium | High | 将 DEVONthink 保持为可选能力；优先 4.4+ 内置 MCP，回退 AppleScript 仅做 Index + 字段/标签写入与 UUID/路径/计数校验；不承诺脚本建 Smart Group | `M3` / `#215` |
| **R-07** | 许可与代码合规 | 根仓库缺少 `LICENSE`；`dvcrn/mcp-server-devonthink` 与 Sorty 为 GPL-3.0；`TomBener`/`schappim` 无许可 | Medium | Medium | 禁 Fork Sorty 与无许可库；仅复用 MIT/BSD 依赖（`DocVortex`/`mac-ocr`）；在 `M2` 前请求 Owner 确认本仓库/产物许可证；`#136` 缺陷在 `M1` 修复 | `M1` / `M2` |
| **R-08** | 盲测与真实采用偏差 | 29 文档回归过拟合或盲测未达均值 90 / 最低 85 / 省时 80% 门禁 | High | Medium | 盲测语料与 Gold 在 DevBox 独立冻结，隔离 3 次运行；若未达标仅允许一次低成本定向修复，无可靠路径则按 `#216` 止损 | `#213` / `#216` |
