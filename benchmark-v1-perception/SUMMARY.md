# Document Perception Benchmark — evidence summary

`BENCHMARK_EXECUTION_COMPLETE — INDEPENDENT_SCORING_PENDING`

## 1. Perception layer

- Documents: 29; extracted successfully: **29**
- Methods: {"docvortex_native_pdf": 6, "docvortex": 14, "direct_read": 7, "apple_vision_ocr_fallback": 2}
- PDFs: 8 total, 8 with content (includes the 2 image-only scans)
- Extraction time: 47.66 s total (Office 7.49 s, native PDF 3.77 s, Vision OCR 36.4 s)
- ModelBest API: 0 successful, 1 failed (HTTP [401]), cost USD 0.0
- Jev: **NOT_VERIFIED** — same credential block; no score computed or invented

## 2. Six runs (mechanical)

| Arm | Moved | Kept | Dirs (under ws) | Empty | Single-child | Max depth | Mean depth | Wall s | Integrity |
|---|---|---|---|---|---|---|---|---|---|
| B1-C0-01 | 27 | 2 | 23 | 0 | 5 | 5 | 3.97 | 139 | PASS |
| B1-C0-02 | 27 | 2 | 71 | 22 | 22 | 5 | 3.93 | 152 | PASS |
| B1-C0-03 | 27 | 2 | 72 | 22 | 23 | 5 | 3.97 | 136 | PASS |
| B1-C1-01 | 0 | 29 | 52 | 0 | 22 | 8 | 5.69 | 355 | PASS |
| B1-C1-02 | 27 | 2 | 65 | 22 | 22 | 5 | 3.93 | 186 | PASS |
| B1-C1-03 | 27 | 2 | 71 | 22 | 22 | 5 | 3.93 | 233 | PASS |

## 3. Comparison with the previous benchmark (Structure Score, independent reviewer)

| Arm | Previous mean | Perception runs |
|---|---|---|
| Codex only | 31.50 (36.93 / 29.37 / 28.21) | pending independent scoring |
| Codex + Sorty Skill | 39.39 (38.63 / 37.04 / 42.50) | pending independent scoring |

No semantic score is produced here; gains must be computed by the independent reviewer with the same rubric.