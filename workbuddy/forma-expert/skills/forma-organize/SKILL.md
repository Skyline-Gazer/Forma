---
name: forma-organize
display_name: Forma 业务文档整理
display_name_en: Forma Business Document Organizer
description: Inspect selected folders read-only, understand business documents, preview an immutable organization plan, apply safely with exclusive no-replace moves, and recover via journal.
description_zh: 只读探查目录、理解业务文档关系、生成不可变整理方案预览，并在批准后执行排他无覆盖归档与日志恢复。
description_en: Read-only folder inspection, business document reasoning, immutable plan preview, approval-bound exclusive no-replace apply, and journal recovery.
version: 0.1.0
author: "Mark D."
---

# Forma 文档整理技能 (`forma-organize`)

本技能将 WorkBuddy 的原生文档理解、对话预览确认能力与确定性本地文件系统安全内核 `scripts/forma_fs.py` 结合，实现 `探查 → 理解 → 预览 → 批准 → 执行 → 核验 → 恢复` 闭环。

## 必读参考规范
- 领域理解与命名规则：`@references/domain-contract.md`
- 原生优先解析与长文档/OCR 回退策略：`@references/perception-fallback.md`
- 资格过滤策略：`@references/eligibility-policy.json`

## 标准执行命令（所有状态产物放 `~/.forma-workbuddy/state/<run_id>/`，勿写入工作区）

1. **只读探查（生成快照）**：
   ```sh
   python3 scripts/forma_fs.py inspect --source "<source_root>" --out "$HOME/.forma-workbuddy/state/<run_id>/snapshot.json"
   ```
2. **校验并生成不可变计划与预览**：
   ```sh
   python3 scripts/forma_fs.py plan \
     --snapshot "$HOME/.forma-workbuddy/state/<run_id>/snapshot.json" \
     --draft "$HOME/.forma-workbuddy/state/<run_id>/draft.json" \
     --dest "<dest_root>" \
     --out "$HOME/.forma-workbuddy/state/<run_id>/plan.json" \
     --summary "$HOME/.forma-workbuddy/state/<run_id>/preview.md"
   ```
3. **默认干跑检查（不写入）**：
   ```sh
   python3 scripts/forma_fs.py apply --plan "$HOME/.forma-workbuddy/state/<run_id>/plan.json" --state-dir "$HOME/.forma-workbuddy/state/<run_id>"
   ```
4. **用户明确批准后执行（必须绑定精确 `plan_hash` 与 `snapshot_hash`）**：
   ```sh
   python3 scripts/forma_fs.py apply \
     --plan "$HOME/.forma-workbuddy/state/<run_id>/plan.json" \
     --state-dir "$HOME/.forma-workbuddy/state/<run_id>" \
     --approve-plan-hash "<plan_hash>" \
     --approve-snapshot-hash "<snapshot_hash>" \
     --execute
   ```
5. **中断检查或安全恢复**：
   ```sh
   python3 scripts/forma_fs.py recover --journal "$HOME/.forma-workbuddy/state/<run_id>/journal.jsonl" --mode inspect
   ```

## 硬性约束
- 禁止使用裸 `mv` / `rm` 绕过 `forma_fs.py` 执行批量归档。
- 禁止在未获得用户对当前 `plan_hash` 的明确同意前传入 `--execute`。
- 若遇到 OneDrive / File Provider 路径（`CloudStorage`），遵循脚本提示：不触发范围外水合，未验证原子保证前不宣称支持无覆盖原子移动。
