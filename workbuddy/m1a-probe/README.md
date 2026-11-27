# Forma M1-A: WorkBuddy Host Feasibility Probe (Mac Handoff)

- **Branch**: `workbuddy/feat/m1a-host-feasibility`
- **Purpose**: 一次性最小只读探针，用于在进入 `M1-B` 编码前实测 Mac WorkBuddy 客户端的真实宿主机行为。
- **Strict Scope**: 严禁在此阶段执行真实文件移动、生产目录扫描或 DEVONthink 写入。

## 1. Mac 验证步骤（按顺序记录实际观察）

1. **首次安装 / 创建与私有分发测试**：
   - 记录在 Mac WorkBuddy 客户端中实际可用的加载方式（例如「我的专家 → 创建专家」、导入本地目录或私有预览；**若本地 ZIP 导入不可用，如实记录，勿臆测**）。
   - 记录依赖发现、首次安装耗时与任何权限提示。
2. **召唤与 Skill 发现**：
   - 使用 3 条 `quickPrompts` 召唤 `Forma M1-A 探针`。
   - 验证 `forma-host-probe` 是否被自动发现并加载。
3. **资源路径与只读命令执行**：
   - 触发读取 `@references/probe-checklist.md`（核对输出含 `FORMA_M1A_REFERENCE_LOADED_OK`）。
   - 引导探针运行 `sh scripts/host_probe.sh "<本仓库路径>/workbuddy/m1a-probe/synthetic-fixture"`。
   - 观察并记录：**WorkBuddy 是否弹出 `Bash`/`Read` 工具审批确认**（能否强制逐次审批，还是静默执行）。
4. **运行时与目录权限观察**：
   - 记录脚本输出的 `TOOL_python3`、`TOOL_docvortex`、`TOOL_mac-ocr`、`TOOL_swift`、`TOOL_go`、`TOOL_node`、`TOOL_osascript` 状态与 `PATH`。
   - 若把 `synthetic-fixture` 复制到 `~/Documents/forma-m1a-test`（合成测试目录），观察 macOS TCC 是否弹出目录授权提示。
5. **重复调用、升级与卸载**：
   - 重复发起 2 次对话确认幂等可用；测试更新 `plugin.json` 版本号（如 `0.0.1-probe.2`）后的升级刷新体验；测试从客户端卸载/移除探针是否干净。

## 2. 清理与回传

- 验证完成后，卸载一次性探针专家并删除临时复制的 `~/Documents/forma-m1a-test`（不要修改系统全局 TCC 或删除其他工作区）。
- 将 8 项实测结果回填至 Issue `#218`，再由 Owner 裁定是否进入 `M1-B` 及锁定残余工具语言。
