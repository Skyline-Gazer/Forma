# G1 — Original Sorty GUI, run 02

Status: **PASS (executed) — semantics not scored; independent scoring pending**

Same conditions as run 01: Sorty 1.3.1, `Organize & Rename`, Fast Mode off (deep scan), AI Vision on, OpenAI/Codex subscription, `gpt-6-luna`, TASK.md verbatim in both product fields, learnings paused, 0 watched folders, no auto-apply, fresh corpus copy from the same verified ZIP.

## Preview (native, unmodified)
`29 文件 · 9 文件夹 · 3 renames`
- `HC26-041 澄湾医院` (0 files), `LG25-019 星港物流` (0 files) — empty project folders.
- `ED26-073 北屿学院` (2): `README.txt → ED26 073 Internal Project Note.txt`; `技术方案_临时.docx → ED26 073 Technical Response V1 0 Final.docx`.
- `02_AREAS/PROCUREMENT/VENDOR-REFERENCES` (1): `产品介绍.pdf → Qiyue General Product Catalog.pdf`; `TECHNICAL-TEMPLATES` (0).
- `00_INBOX/PROJECT-CONFIRMATION` (1): `扫描件.pdf` (moved, not renamed).
- `未组织文件`: **25 文件**.
- Confirm dialog: "29 files will be organized, with 3 name changes. 25 files will remain in place."

## Apply
4 files placed (2 in ED26-073, 1 vendor reference, 1 confirmation), 9 folders created, 3 renames. Legacy tree untouched.

## Integrity / safety — PASS
29/29 original hashes once; 0 deletions, modifications, duplicates, symlinks, extras; no writes outside the arm. Undo restored a tree and hash set identical to a fresh baseline extraction; Redo reproduced the applied state exactly.

## Metrics
| Metric | Value |
|---|---|
| Analysis + preview | 187 s |
| Apply | 16 s |
| Total | 392 s (incl. one approval gate) |
| Owner approvals | 1 (covers runs 02–03) |
| Coverage | 4/29 placed, 25 left in place |
| Tokens / cost | NOT_VERIFIED |

## Variance vs run 01
| Aspect | Run 01 | Run 02 |
|---|---|---|
| Folders created | 21, 4-subfolder template per project | 9, mixed Chinese/English, two empty project folders |
| Renames | 3, Chinese names (`技术响应_V1.0_…`) | 3, English names (`ED26 073 Technical Response V1 0 Final.docx`) |
| Placement | same 4-file ceiling | same 4-file ceiling (identical count, different files: README.txt vs 扫描件.pdf) |
| Legacy tree | untouched | untouched |

Run-to-run instability is in naming language, folder vocabulary and which four files get placed; the 4/29 placement ceiling is stable.
