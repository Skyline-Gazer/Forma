# G1 — Original Sorty GUI (Organize & Rename, deep scan, gpt-6-luna)

Status: **PASS (executed) — semantics not scored here; independent scoring pending**

## Environment
- Sorty 1.3.1, build 20261105122310, `/Applications/Sorty.app`, adhoc-signed, 85 MB, macOS 27.2.1 (26B131), M1 Pro.
- Provider `openai`, auth `Codex CLI (Subscription)`, model `gpt-6-luna`, temperature 0.2 — same account/model as the C1/C0 Codex host.
- Mode `Organize & Rename`; Fast Mode **off** (deep content scan); AI Vision **on**; OCR languages `en-US`; output language `English`; separator spaces; natural case; max filename 80.
- Apple Foundation Model unusable on this host: "This device is not eligible for Apple Intelligence". With Apple selected, Fast Mode is mandatory (product warning), so deep scan was only reachable via a non-Apple provider.
- Learnings paused through the product's own confirmation dialog; existing Learnings data and the `example-folder` example folder were **not deleted or exported**. Zero watched folders; no auto-apply.
- Custom instructions: TASK.md verbatim (`sha256 127cd57f…c30b4f`) pasted into **two** product fields — Settings → 组织方式 → 额外指令, and the run-level 说明 field. This is a product limitation: there is no single "organization brief" input, and the run field starts empty even when the settings field is filled.

## Native analysis
- Scanned **29/29** files recursively at all depths; progress text `Analyzing file content: N files` then `Finding the best folders for 29 files… 30%` then `Waiting for the AI response…`.
- Read PDF, DOCX, XLSX, TXT; vision path active for the image-only PDFs.
- No file-count, depth or truncation limit was surfaced. No per-file error, timeout or skip was shown. Native log (`~/Library/Application Support/com.sorty.app/Logs/sorty.log`) records only Sparkle events — no analysis trace, so token usage and per-file model calls are **NOT_VERIFIED**.

## Original preview (as proposed, unmodified)
- Summary: `29 文件 · 21 文件夹 · 3 renames`, tags enabled, "拖入文件夹" empty.
- Proposed tree: three project folders with invented-looking identifiers and identical sub-templates —
  `HC26-041 澄湾医院存储扩容`, `ED26-073 北屿学院网络改造`, `LG25-019 星港物流平台更新`, each with
  `00_TENDER-DOCS`, `01_TECHNICAL-BID`, `04_SUBMISSION`, `99_WIP`; plus
  `SHARED-AND-REVIEW/02_AREAS/VENDOR-REFERENCE` and `SHARED-AND-REVIEW/99_ATTRIBUTION-PENDING` (scanned PDF).
- **25 of 29 files stayed under `未组织文件`** with original names and no target folder — the preview simply did not place them. The confirm dialog restated this: "29 files will be organized, with 3 name changes. 25 files will remain in place."
- Only 3 renames were proposed (docx with version suffixes such as `技术方案_最终`).
- No per-file rationale, evidence, confidence, unresolved-item list, or metadata/smart-group suggestion is exposed anywhere in the UI, and there is no export control for the preview. Those are capability gaps, recorded as `NOT_SUPPORTED`, not as fabricated content.
- Screenshots: `original-preview/screens/` (top, unorganized bucket, scrolled views).

## Apply
- Pre-authorized by owner conditional on integrity/scope checks; the proposal contained no delete, overwrite or rename-in-place of unknown files.
- Result screen: 4 files moved, 21 folders created, 3 names improved, "About 10 minutes of manual work saved". Native History: 29 files, 21 folders, 1 conversation, 100% success, `US$0.0026`, `gpt-6-luna`, 2026-11-26 17:20.
- The original seven-folder legacy tree (`下载`, `临时`, `历史`, `旧归档`, `桌面备份`, `邮件附件`, `项目`) was left fully intact — Sorty adds a new top-level structure instead of replacing the misleading hierarchy. The task's "reduce unreasonable nesting / don't inherit the old tree" goal is therefore only partially addressed; legacy `批次1/2/3` folders survive.

## Integrity and safety — PASS
- 29/29 original SHA-256 present exactly once; 0 missing, 0 duplicates, 0 deletions, 0 content changes, 0 extension changes, 0 symlinks, no writes outside `GUI-01/workspace`.
- Directory count grew 53 → 72 (+21 folders, 0 pruned).
- Rollback: native 撤销 restored 4 files and removed 21 folders; resulting tree and hashes are **byte-identical** to the pre-apply snapshot. Native 重做 restored the applied state exactly (tree and hashes match the archived `applied-workspace.zip`).

## Metrics
| Metric | Value |
|---|---|
| Analysis + preview | 266 s (includes 1 owner gate) |
| Apply | 14 s |
| Total (post-config) | 280 s |
| Owner approvals | 2 gates in 1 request (egress, apply) |
| Native cost | US$0.0026 |
| Native exports | preview NOT_SUPPORTED, history detail NOT_SUPPORTED |
| Token usage / peak memory | NOT_VERIFIED |

## Observed capability gaps
1. Coverage: 25/29 files unplaced, no attempt at the ambiguous/unknown-attribution cases beyond one `99_ATTRIBUTION-PENDING` folder.
2. Folder economy: 21 folders for 4 relocated files, all with the same 4-subfolder template per project.
3. No metadata/smart-group planning output; tags only as colour dots.
4. No reasoning/evidence surface and no preview export → independent review is limited to screenshots plus the applied tree.
5. Output language fixed to English while the corpus is Chinese; OCR restricted to `en-US`.
6. Old hierarchy is not consolidated; `Organize & Rename` adds a parallel structure.
