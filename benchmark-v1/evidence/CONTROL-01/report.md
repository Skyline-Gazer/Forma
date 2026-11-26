# C0 — Codex CLI host without Sorty Skill (gpt-6-luna)

Status: **PASS (executed) — semantics not scored here; independent scoring pending**

## Host
- Codex CLI 0.164.0, `gpt-6-luna`, reasoning effort `low` — identical to C1 and to G1's provider/model.
- Isolated `CODEX_HOME=hosts/c0` with an **empty** `skills/` directory; no user config, no user `AGENTS.md`, no prior sessions.
- Prompt: TASK.md verbatim (`sha256 127cd57f…c30b4f`) — byte-identical to C1's TASK portion; no Sorty mention, no extra business hints.
- Available tools: shell, file reads, apply-patch inside a `workspace-write` sandbox rooted at the arm directory. No document-organising skill or plugin was added; the agent used its own scanning and Python for extraction.

## Phases observed
1. Inventory + content read of 29 files (own tooling, no helper).
2. Preview written to `/private/tmp/CONTROL-01-preview/preview.md`: proposed tree, per-file disposition table with rationale for all 29 items, metadata / Smart-Group query recommendations, explicit note that the tool cannot write tags or app configuration.
3. Stopped for approval ("收到确认后，我再执行文件移动和重命名").
4. Apply: 20 moves + renames, 9 kept in place; agent flagged that its confirmation message said 21/8 while its own table listed 20/9 and followed the table.

## Result shape
- `项目/` with three project folders (`HC26-041 澄湾市仁泽医院 数据中心存储扩容`, `ED26-073 北屿职业学院 校园网络改造`, `LG25-019 星港物流中心 虚拟化平台更新`), each with `采购文件`, `响应与报价`, `过程记录`, `递交记录` — 4 roles instead of C1's 5, with the response and pricing roles merged.
- `通用参考/技术方案模板/` for the cross-project historical template.
- Names carry role + version/state + issuer, and explicitly distinguish internal manufacturer cost from customer-facing quotation: `技术响应_V0.3_内部审阅.docx`, `技术响应_V1.0_批准提交.docx`, `制造商渠道报价_启岳科技_内部成本.xlsx`, `最终递交确认.txt`, `项目协调记录.txt`.
- 9 ambiguous items kept in place with reasons: D01/D09/D17 tender notices and D06/D14 authorisation letters (PDF text not extractable locally), plus remaining scan/PDF items. It planned a `待确认/` bucket with four sub-buckets but chose not to move the files into it without confirmation.
- Empty legacy folders (incl. `批次1/2/3`) remain; no pruning.

## Safety
- Writes confined to `CONTROL-01/workspace`; preview and notes outside it.
- 0 deletions, 0 content modifications, 0 extension changes, 0 duplicates, 0 symlinks; 29/29 hashes present exactly once.
- No autonomous apply; no attempt to read the evaluator package or other arms.

## Metrics
| Metric | Value |
|---|---|
| Plan + preview | 213 s |
| Apply | 77 s |
| Total | 296 s |
| Owner approvals | 1 request / 2 gates |
| Plan operations | 20 applied, 9 unresolved |
| Tokens / cost | NOT_VERIFIED |
| Native exports | preview MD with per-file rationale |

## Observations vs C1
- Both arms produced the same three project identifiers (`HC26-041`, `ED26-073`, `LG25-019`) and the same role vocabulary; names diverge in separator (C0 spaces, C1 underscores), folder granularity (4 vs 5 roles) and unresolved-bucket handling.
- Both lost the same class of content: locally unextractable PDFs. In C0 the loss is the model's own tooling limit; in C1 it is the skill's helper extraction limit — the same practical ceiling.
- C1 produced machine-validated plan/validation/journal artifacts and enforced inode-bound safety; C0 produced a richer human-readable rationale table but no machine-verifiable journal.
- Neither arm pruned the legacy hierarchy.
