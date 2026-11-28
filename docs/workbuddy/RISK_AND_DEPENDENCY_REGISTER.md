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

### 1.3 M1-A Closure & Remaining Unverified Items
- **`CORE_HOST_FEASIBILITY_VERIFIED`**：Mac 实测已确认 Expert 本地安装注册、Skill 自动发现与调用、自然语言驱动、脚本执行、包内资源路径、Python/Node.js/Swift 运行时及升级卸载可用。
- **`NATIVE_SECURITY_ARCHITECTURE_DOCUMENTED`**：已核对 `Permission-Modes` 官方文档，WorkBuddy 原生提供工作空间沙箱、默认权限确认、3000MB 自动备份、删除保护、敏感保护、Tool 管控与工具内容注入防护。
- **`PRODUCT_SECURITY_ACCEPTANCE_PENDING`**（待 `M3` 实测）：
  1. 此前 `M1-A` 权限测试使用 `bypassPermissions`，**默认权限模式与安全中心规则在真实业务流程中的拦截效果须在 `M3` 实测验收**；
  2. WorkBuddy 内置模型路由在 29 文档与 150 文档盲测上的真实语义得分与成本（`NOT_VERIFIED`，`M3`/`#213`）；
  3. OneDrive 在线占位符水合字节控制与跨设备恢复（`BLOCKED`/`NOT_VERIFIED`，`#214`）；
  4. 真实业务含审阅在内的 `>= 80%` 省时目标（`NOT_VERIFIED`，`#216`）。

---

## 2. Risk & Mitigation Register

| ID | Category | Risk Description | Severity | Likelihood | Mitigation & Contingency | Gate |
|---|---|---|---|---|---|---|
| **R-01** | 平台准入与安装 | `M1-A` 已验证本地安装/升级/卸载与 Skill 调用可用；残余风险为 `M3` 默认权限与安全中心配置实测 | Low | Low | 已在 `M1-A` 验证；`M3` 按默认权限+安全中心指南实测（`PRODUCT_SECURITY_ACCEPTANCE_PENDING`） | `M3` |
| **R-02** | 可选解析工具缺省 | `M1-A` 环境未预装 `docvortex`/`mac-ocr`；但这不否定 WorkBuddy 原生文档读取能力 | Low | Medium | 采用 Native-First 策略：优先 WorkBuddy 原生 PDF/Office/TXT/图片读取，仅在扫描件或复杂多表时提示可选安装 `docvortex`/`mac-ocr` | `M3` |
| **R-03** | 授权绕过与静默覆盖风险 (Track C / B1) | 1. WorkBuddy 统一分配 `Write`/`Bash`，Prompt/`allowed-tools` 不是安全边界；2. 标准 POSIX `rename()` 会静默覆盖已存在目标，预检后`rename()` 存在 TOCTOU 竞态；3. OneDrive/File Provider 原子语义未确认 | High | Medium | 1. `M1-A` 实测原生工具审批强制力；2. 执行器强制使用 `renamex_np(RENAME_EXCL)` / `renameat2(RENAME_NOREPLACE)`，不支持则 **fail closed**，并配套并发出现目标竞态测试；3. File Provider 目标单独隔离，未验证不宣称支持 | `M1-A` / `M1-B` / `#214` |
| **R-04** | 模型数据出境与隐私 | 本地解析≠本地推理；文档正文进入 WorkBuddy 云端模型路由存在出境风险 | Critical | High | Alpha 与盲测仅用合成语料；明确披露模型路由与出境边界；真实试点须 Owner 单独书面授权 | `FR8` |
| **R-05** | OneDrive 存储与恢复 | 扫描/哈希可能意外触发 File Provider 批量水合；且无 CLI 驱逐接口 | High | High | `inspect` 通过 `SF_DATALESS` 跳过未水合文件按需读取；活动 DT DB 禁入 OneDrive；`#214` 独立验收 | `#214` |
| **R-06** | DEVONthink 限制 | 4.4.2 AppleScript 不支持建 Smart Group、按自定义字段 key 搜索与 tag 名称回读 | Medium | High | 保持 DEVONthink 可选；优先 4.4+ 内置 MCP 或极简 `osascript` 仅做 Index + 字段/标签写入与 UUID/路径/计数回读 | `M3` / `#215` |
| **R-07** | 许可与分支保护治理 | 仓库缺 `LICENSE`；`workbuddy/dev` 尚无 GitHub 分支保护 Ruleset | Medium | Medium | `M2` 前请 Owner 明确仓库/产物许可证；通过 PR 流程整合至 `workbuddy/dev`（可由 Owner 按需开启分支保护） | `M2` / Docs PR |
| **R-08** | 盲测与省时未达标 | 盲测未达均值 90 / 最低 85 或真实省时 <80% | High | Medium | 独立盲测 Gold 冻结；失败仅一次定向低成本修复建议，无可靠路径则按 `#216` 止损 | `#213` / `#216` |
| **R-09** | 确定性内核残余（#223 后续） | #224 仅收口两条评审项（protection-fact 门、magic 探测 fail-closed）；eligibility 不强制、SKIP_VERIFIED 不复核、null-hash fail-open、recover 无锁/无边界、`source_id=dev:inode` 等 Spec §10.8 项仍在主干 | High | 已确认 | §10.8 P0 独立收敛并补回归测试；收敛合入后重建包方可执行 M3 复测，不得视为已随 #224 关闭 | `M3` / Spec §10.8 |
| **R-10** | 包溯源 | `0.1.0-alpha.2` zip 出自未合并的评审修复分支，zip↔源码核验未完成 | Medium | 已确认 | 从合并后 `workbuddy/dev` 重建 + SHA256，在隔离 Mac 环境完成 zip↔源核验 | `#220` |
| **R-11** | DEVONthink metadata schema 污染 | 4.4.2 内置 MCP `set_record_custom_metadata` 对未知 key 自动创建数据库字段（实测） | High | 已确认 | Approved Profile key 白名单 + 字段 pre-read；未声明 key 拒写；readback 一致才记录 published | Spec §10.4/§10.9 |
| **R-12** | M11 扫描原始完整性 | OneDrive 3,357 文件只读扫描无写痕，但缺 pre/post manifest，HISTORICAL_ORIGINAL_INTEGRITY = NOT_VERIFIABLE | Medium | 已确认 | 后续真实语料操作必须携带 pre/post manifest；COPY ONLY 测试协议（Spec §10.12）已固化该要求 | `#214` |
