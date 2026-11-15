# R1 Batch 2B — 交接（Preflight，未授权）

更新：2026-11-15 · 基线：`dev` @ `43dea29`（#104 合并）

## 1. 当前状态一句话

R1 的**只读工程与现场验证**已到"打包/启动/书签/GUI/只读回查"闭环；**没有任何 R1 应用开发授权**，也没有任何真实写调用。下一步的写入门槛是 M05，下一步的发行门槛是 R01–R03；两者都需要 Owner 决定。

## 2. 本轮发生了什么

| PR | 合并 SHA | 内容 |
| --- | --- | --- |
| #103 | `e728ad5` | 缺陷 A 修复：表单反馈只由 `RecoveryScopeDraft` 决定；6 个回归测试 |
| #104 | `43dea29` | `docs/M05-PREFLIGHT.md`、`docs/M05-AUTHORIZATION-PROPOSAL.md` |
| #105 | 见 `docs/ROADMAP.md` | Roadmap 状态收敛（2A.2/2A.3、缺陷 A、M05） |

Issue：#98 观察 2 重新编号 + 处置评论；#24 现场结果评论；#22 M05 现状评论；#51 P3-A 交付核对评论。#21 保持关闭，#7/#22/#24/#51 保持 open。

## 3. 仍需的真实现场验证

按优先级：

1. **缺陷 A 复测**（只读 GUI）：用 #103 之后的 CI artifact，重跑 `docs/R1-GUI-VERIFICATION.md` 步骤 2–7；第 4 步应从 FAIL 变 PASS。
2. **M05 T/D 探针**（真实写入，需授权）：超时、发送后断连 → `VERIFY_REQUIRED` → 只读回查；预算见 `docs/M05-AUTHORIZATION-PROPOSAL.md`。
3. **M05 C 探针**（真实崩溃注入，需单独批准）：create 在途终止 Forma，重启后只读回查。
4. **Keychain 锁定态**、**外部卷/iCloud**、**macOS 14.x**（需对应硬件/系统）。
5. **R01–R03**：Developer ID、Hardened Runtime、公证、独立安装与发行渠道。

## 4. 不能做（除非新授权）

- 任何真实 `create_group_path` / `import_file` / `set_record_custom_metadata`；任何真实崩溃注入或 `kill -9`。
- 删除/移动 B2 沙盒记录或组；访问生产库记录级内容。
- 修改 SPEC、ADS pin、`main`、发行渠道决策；同步 CNB。
- 提前实现 R1 应用功能（2B 功能开发尚未授权）。

## 5. 新 Session 的起手顺序

1. `git fetch origin && git log --oneline -5 origin/dev`；确认 `dev` 绿（`gh run list --branch dev --limit 3`）。
2. 读 `docs/ROADMAP.md` 顶部状态与 `docs/M05-PREFLIGHT.md`。
3. 若只做只读收尾：执行 §3.1，更新 `docs/R1-GUI-VERIFICATION.md` 与报告。
4. 若 Owner 批准写入：严格按 `docs/M05-PREFLIGHT.md` §8 执行，先 `plan` 后写，逐探针记录。
5. 任何新事实先落到 `docs/`，再改 Issue/ROADMAP；未验证项不得改写成 PASS。

## 6. 现场环境事实（避免重复踩坑）

- DevBox 为 Linux：无 DEVONthink、无 Security/AppKit、无 `codesign`/`spctl`；只能做纯逻辑、Fake Transport、CI 触发。
- 真实 Mac 上：输入法（Rime/Squirrel）会拦截 `System Events` 键入，需显式切换输入源并逐字段回读；`NSOpenPanel` 文本框不受 CGEvent 直投（见 Issue #98 观察 2）。
- MCP：握手 `2025-06-18`、62 工具；schema digest 与 I1-B1 一致；无自动重连，超时/断连即错误（`MCPConnectionSupervisor`）。
- 证据目录在运行主机 `~/.forma/evidence/`；仓库只放脱敏内容。

## 7. 授权状态速查

| 项 | 状态 |
| --- | --- |
| R1 只读工程/现场验证 | 已授权并完成（2A/2A.1/2A.2/2A.3） |
| R1 应用功能开发（2B） | **未授权** |
| M05 真实写入 | **未授权**（申请 #104） |
| 崩溃注入 | **未授权**（需单独批准） |
| R01–R03 签名/公证/发行 | **未授权** |
| P3-B 真实模型评测 | **未授权** |
| I2 Replicant / 生产迁移 | **未授权** |
