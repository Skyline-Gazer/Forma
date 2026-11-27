---
name: forma-host-probe
display_name: 宿主机可行性探针
display_name_en: Host Feasibility Probe
description: Read-only probe to verify Skill discovery, reference path resolution, runtime availability, and synthetic directory access.
description_zh: 只读探测技能发现、参考资料路径解析、可用运行时与合成目录访问权限。
description_en: Read-only probe for Skill discovery, reference path resolution, runtime tools, and synthetic folder access.
version: 0.0.1
author: "Mark D."
---

# 宿主机可行性探针技能 (M1-A)

本技能仅执行无害只读检查，用于验证 WorkBuddy 宿主机环境是否满足 Forma 后续开发前置条件。

## 执行步骤
1. 读取参考文件 `@references/probe-checklist.md`，确认相对资源路径可被正常解析。
2. 通过 `Bash` 工具运行只读探针脚本（将 `<synthetic_dir>` 替换为用户指定的合成目录路径）：
   ```sh
   sh scripts/host_probe.sh "<synthetic_dir>"
   ```
3. 将脚本输出的完整 JSON/文本结果原样整理汇报给用户，并记录是否触发了 WorkBuddy 工具审批弹窗或 macOS TCC 目录授权弹窗。

## 禁止事项
- 禁止执行任何写操作（`mv`/`cp`/`rm`/`touch`/`mkdir`）。
- 禁止访问用户指定的合成目录之外的路径。
