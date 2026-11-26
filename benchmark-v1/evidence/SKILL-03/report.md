# C1 — Original Sorty Skill + Codex host, run 03

Status: **PASS (executed) — semantics not scored; independent scoring pending**

Same host/model/sandbox/skill pin as runs 01–02, fresh corpus copy, isolated `CODEX_HOME=hosts/c1-3`.

## Plan
- Helper plan `version 2`, `mode organizeAndRename`, **19 operations**, validation `valid: true`, 0 errors, 29 files accounted.
- 10 items unresolved and kept in place (scanned PDFs without OCR, ambiguous attribution).
- Structure: `项目/{HC26-041_…, ED26-073_…, LG25-019_…}` with `采购文件 / 投标响应 / 商务 / 项目记录`, plus `通用参考/技术方案模板_旧川市公立医院机房改造_2023.docx`.
- Project folder names drop the separator before the project name suffix (`ED26-073_北屿职业学院校园网络改造`) — a naming variance vs runs 01–02.

## Apply
19/19 applied, 10 kept; journal written; agent reported helper-side integrity but no independent re-hash (orchestrator verified).

## Integrity / safety — PASS
29/29 hashes once, 0 deletions/modifications/duplicates/symlinks/extras, no out-of-scope writes.

## Metrics
| Metric | Value |
|---|---|
| Plan + preview | 212 s |
| Apply | 55 s |
| Total | 272 s |
| Owner approvals | 0 (pre-authorized) |
| Operations | 19 applied / 10 unresolved |
| Tokens / cost | NOT_VERIFIED |

## Variance vs runs 01–02
| Aspect | 01 | 02 | 03 |
|---|---|---|---|
| Operations | 20 | 22 | 19 |
| Role folders | 5 (incl. 过程记录, 投标归档) | flat prefixed files | 4 (`商务`, `投标响应`, `采购文件`, `项目记录`) |
| PDF recovery | none | scanned PDFs read as images | none (OCR unavailable) |
| Unresolved | 9 | 3 | 10 |
Working vocabulary and hierarchy depth are not stable across runs; validation and journal discipline are.
