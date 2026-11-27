# Forma WorkBuddy Edition — Risk & Dependency Register (Revised)

- **Canonical Spec**: `docs/specs/2026-11-27-workbuddy-edition.md` (`110a469208a944a485b4389779795174dad7bc5b`)
- **Date**: 2026-11-27

---

## 1. Epistemic Classification (已确认事实 / 合理假设 / 未验证项)

### 1.1 Confirmed Facts (已确认事实)
1. **WorkBuddy 官方文档边界**（2026-11-27 实抓 5 页）：`agents/*.md` 禁止 `tools` 字段；`displayDescription.zh` 须 40–50 字；`quickPrompts` 固定 3 条且 `defaultInitPrompt == quickPrompts[0]`；**本地 zip 导入客户端 `NOT_DOCUMENTED`**；Connector 托管 `node`/`python` 运行时仅文档化于 `cli.json`/`mcp.json`，**不得假设**对普通 Skill 自动生效。
2. **DocVortex `0.6.26` 平台与能力**（PyPI + `benchmark-v1-perception`）：MIT 许可；**仅支持 macOS arm64 (macOS 14+) 与 Linux**，不支持 Intel Mac；不含 OCR（扫描件抛出 `pdf_ocr_unsupported`）。
3. **DEVONthink 4.4.2 自动化实测限制**（`dae571dc`）：UUID/重命名/移动/自定义字段读写 `PASS`，但 AppleScript 不支持建 Smart Group、不支持按自定义字段 key 搜索、tag 名称回读受限；Custom Metadata 需 Pro/Server；内置 MCP 需 4.4+ & macOS Sequoia+。
4. **OneDrive File Provider 阻断**（`dae571dc`）：`brctl evict` 拒绝 File Provider，`fileproviderctl` 无驱逐命令，OneDrive 无 CLI/AppleScript；`B1`/`B4`/`C2c` 为 `BLOCKED_WITH_EVIDENCE`，`B6`/`B7`/`C2b` 为 `NOT_VERIFIED`。
5. **仓库保护与许可现状**：`main`/`dev`/`workbuddy/dev` 当前均未启用 GitHub 分支保护 Ruleset（HTTP 404），仅靠 PR 纪律与 `.github/workflows/ci.yml`；`origin/dev` 缺少 `LICENSE`；`dvcrn/mcp-server-devonthink` 与 Sorty 为 GPL-3.0；`#136` 存在预算外误计 `INCLUDE` 缺陷；`92.34` Codex 成绩不可迁移。

### 1.2 Reasonable Assumptions (合理假设)
1. WorkBuddy Mac 客户端可通过官方支持的「我的专家 → 创建专家」或私有预览路径加载单 Agent Expert 与 `skills/*/SKILL.md`（将在 **`M1-A`** 实测验证）。
2. `docvortex convert` CLI 可在目标 Apple Silicon Mac 上由 WorkBuddy `Bash` 或预配置环境调用（将在 **`M1-A`** 验证）。

### 1.3 Unverified Items (`NOT_VERIFIED` / `BLOCKED`)
1. WorkBuddy 客户端实际加载机制、Skill 发现、可用运行时（`python3` vs 预编译二进制）、包内相对路径解析、合成目录 TCC 权限与原生工具审批弹窗强制力（`NOT_VERIFIED`，**`M1-A` 首要验证目标**）。
2. WorkBuddy 内置模型路由在 29 文档与 150 文档盲测上的真实语义得分与成本（`NOT_VERIFIED`，`M3`/`#213`）。
3. OneDrive 在线占位符水合字节控制与跨设备恢复（`BLOCKED`/`NOT_VERIFIED`，`#214`）。
4. 真实业务含审阅在内的 `>= 80%` 省时目标（`NOT_VERIFIED`，`#216`）。

---

## 2. Risk & Mitigation Register

| ID | Category | Risk Description | Severity | Likelihood | Mitigation & Contingency | Gate |
|---|---|---|---|---|---|---|
| **R-01** | 平台准入与安装 | 官方文档未记载本地 zip 导入；若客户端无法加载本地 Expert/Skill，将阻塞全流程 | High | Medium | 通过新增 **`M1-A`** 在 `M1-B` 编码前第一时间在 Mac 客户端实测；若被阻断立即停工上报 `BLOCKED` | `M1-A` |
| **R-02** | macOS TCC / 运行时路径 | WorkBuddy `Bash` 子进程可能因 PATH 隔离找不到 `python3`/`docvortex`，或预编译二进制被 Gatekeeper 拦截，或被 TCC 静默拒绝 | High | Medium | `M1-A` 实测可用运行时与合成目录 TCC 后再锁定残余执行器语言（stdlib Python vs 单静态 Go/Swift 二进制） | `M1-A` |
| **R-03** | 授权绕过风险 (Track C) | WorkBuddy 统一分配 `Write`/`Bash` 工具；Prompt/`allowed-tools` 不是安全边界，Agent 理论上可能绕过预定执行器直写 | High | Medium | 1. `M1-A` 实测原生工具审批是否可强制逐次确认；2. 执行器内部强制复核 `plan_hash`/`snapshot_hash`/containment/Journal；3. 验收核查真实文件映射与操作日志一致性 | `M1-A` / `M3` |
| **R-04** | 模型数据出境与隐私 | 本地解析≠本地推理；文档正文进入 WorkBuddy 云端模型路由存在出境风险 | Critical | High | Alpha 与盲测仅用合成语料；明确披露模型路由与出境边界；真实试点须 Owner 单独书面授权 | `FR8` |
| **R-05** | OneDrive 存储与恢复 | 扫描/哈希可能意外触发 File Provider 批量水合；且无 CLI 驱逐接口 | High | High | `inspect` 通过 `SF_DATALESS` 跳过未水合文件按需读取；活动 DT DB 禁入 OneDrive；`#214` 独立验收 | `#214` |
| **R-06** | DEVONthink 限制 | 4.4.2 AppleScript 不支持建 Smart Group、按自定义字段 key 搜索与 tag 名称回读 | Medium | High | 保持 DEVONthink 可选；优先 4.4+ 内置 MCP 或极简 `osascript` 仅做 Index + 字段/标签写入与 UUID/路径/计数回读 | `M3` / `#215` |
| **R-07** | 许可与分支保护治理 | 仓库缺 `LICENSE`；`workbuddy/dev` 尚无 GitHub 分支保护 Ruleset | Medium | Medium | `M2` 前请 Owner 明确仓库/产物许可证；通过 PR 流程整合至 `workbuddy/dev`（可由 Owner 按需开启分支保护） | `M2` / Docs PR |
| **R-08** | 盲测与省时未达标 | 盲测未达均值 90 / 最低 85 或真实省时 <80% | High | Medium | 独立盲测 Gold 冻结；失败仅一次定向低成本修复建议，无可靠路径则按 `#216` 止损 | `#213` / `#216` |
