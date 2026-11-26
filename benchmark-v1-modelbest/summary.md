# ModelBest API re-parse of the 8 PDFs (supplementary run)

Temporary API key supplied by the owner for this run (revoked next day). The key was read from the
process environment only; it is not written to any file, log, artifact or commit.

## Calls

- Document Parse: 8 jobs, 8 Success, 8 pages, 26.52 s
- OCR Jev: 53 region scores, 12337 tokens, 60.2 s
- Billing: MiniCPM-OCR-1.0 and MiniCPM-OCR-Jev are 限时免费 (free during promotion) per the official price table on 2026-11-12; actual cost **0.0**

## Per-document result

| ID | Source | MB chars | Prev chars | Similarity | Key fields differing | Jev mean | Review items |
|---|---|---|---|---|---|---|---|
| D01 | 旧归档/2024/已完成/医疗/客户资料/其他/批次1/公告.pdf | 110 | 99 | 0.943 | 0 | 0.9978 | 0 |
| D06 | 桌面备份/新建文件夹/批次1/授权函.pdf | 111 | 98 | 0.9319 | 0 | 0.9975 | 0 |
| D09 | 项目/2026/新建/未确认/资料/批次2/公告.pdf | 109 | 96 | 0.9368 | 0 | 0.998 | 0 |
| D14 | 旧归档/2024/已完成/医疗/客户资料/其他/批次2/授权函.pdf | 108 | 94 | 0.9297 | 0 | 0.9978 | 0 |
| D17 | 历史/2025/已完成/参考/技术/批次3/公告.pdf | 109 | 96 | 0.9368 | 0 | 0.9978 | 0 |
| D22 | 项目/2026/新建/未确认/资料/批次3/授权函.pdf | 109 | 100 | 0.9947 | 0 | 0.9972 | 0 |
| D26 | 下载/待处理/产品介绍.pdf | 64 | 61 | 0.9643 | 0 | 0.7488 | 1 |
| D28 | 桌面备份/新建文件夹/扫描件.pdf | 53 | 47 | 0.9778 | 0 | 0.9983 | 0 |

## Findings

- Coverage: **8/8 PDFs parsed successfully**, including the two image-only scans (D22, D28) that DocVortex could not read.
- Agreement with the previous evidence (DocVortex native for 6, Apple Vision for 2): mean normalized similarity **0.9519** (min 0.9297); **0 key-field differences** across all eight documents (project code, buyer, subject, deadline, authorising parties).
- ModelBest output normalises full-width punctuation and separates labels with colons; the previous DocVortex text ran fields together, which is why raw similarity stays ≈0.93–0.95 rather than 1.0.
- Block inventory: only `doc_title` (4), `text` (45), `paragraph_title` (4) — these eight PDFs contain no table or formula regions, so table fidelity is not exercised by this corpus.
- Jev review flag: D26 `paragraph_title` “启岳通用产品目录” scored 8.5e-07 (all other 52 regions ≥0.9944). Field comparison for D26 still shows no content difference, so this is most likely a crop/category artefact of scoring a title block as body text; recorded as a review item, not a correction.
- No block returned a non-`ok` status; no rotation was applied to any page.

## Raw evidence

- `api-responses/<ID>/job.json` — full Document Parse job response (pages, blocks, bbox).
- `api-responses/<ID>/content.md` — Markdown produced by the API.
- `api-responses/<ID>/jev.json` — every Jev request result: category, content, verdict, prob_yes, usage.
- `compare.json` — field-level diff against the frozen DocVortex/Vision extraction.
- `metrics.json` — counts, timings, billing.

These results do **not** replace the frozen perception layer used by the six organisation runs;
the six runs were not repeated.