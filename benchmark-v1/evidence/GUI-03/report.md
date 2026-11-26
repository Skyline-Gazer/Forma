# G1 — Original Sorty GUI, run 03

Status: **PASS (executed) — semantics not scored; independent scoring pending**

Same conditions as runs 01–02 (Sorty 1.3.1, Organize & Rename, deep scan, vision on, `gpt-6-luna`, TASK.md in both fields, learnings paused, fresh corpus copy).

## Preview (native, unmodified)
`29 文件 · 7 文件夹 · 3 renames`
- `HC26-041 Hospital Storage` (0), `ED26-073 Campus Network` (2), `LG25-019 Virtualization Update` (0)
- `ED26-073`: `技术方案_临时.docx → ED26 073 Technical Response Approved V1 0.docx`; `README.txt → ED26 073 Internal Coordination Note.txt`
- `Vendor Reference` (1): `产品介绍.pdf → Qiyue General Switching and Storage Catalog.pdf`
- `Technical Bid Templates` (0), `Tender Workbooks To Confirm` (0), `Document Identity To Confirm` (1: `扫描件.pdf`)
- `未组织文件`: **25 文件**
- Confirm: "29 files will be organized, with 3 name changes. 25 files will remain in place."

This run is the only one of the three that expresses uncertainty as dedicated folders (`… To Confirm`) rather than leaving silent leftovers.

## Apply
4 files placed, 7 folders created, 3 renames. Legacy tree untouched.

## Integrity / safety — PASS
29/29 hashes once, 0 deletions/modifications/duplicates/symlinks/extras, no out-of-scope writes. Undo → byte-identical to the fresh baseline extraction (tree and hashes); Redo → identical to the applied state.

## Metrics
| Metric | Value |
|---|---|
| Analysis + preview | 93 s |
| Apply | 16 s |
| Total | 118 s |
| Owner approvals | 0 (covered by the runs 02–03 pre-authorization) |
| Coverage | 4/29 placed, 25 left |
| Tokens / cost | NOT_VERIFIED |

## Variance vs runs 01–02
| Aspect | 01 | 02 | 03 |
|---|---|---|---|
| Folders | 21, template per project | 9, mixed ZH/EN | 7, EN with "To Confirm" buckets |
| Rename language | Chinese | English | English |
| Placed files | 4 | 4 | 4 |
| Empty project folders | 3 | 2 | 2 |
| Legacy tree | untouched | untouched | untouched |

Stable across three runs: the 4/29 placement ceiling, 3 renames, empty project scaffolding, untouched legacy tree. Unstable: folder vocabulary, rename language, which 4 files are placed, and whether uncertainty is expressed at all.
