# Unified document evidence — benchmark v1 perception layer

Frozen 2026-11-26 for the Document Perception Benchmark. One directory per document id
(`D01`–`D29`), each containing:

- `content.md` — extracted content, no classification, naming or organisation decisions.
- `meta.json` — source relative path, SHA-256, bytes, method, status, timing, and (PDFs) parser notes.
- `vision.json` — only for the two image-only PDFs: Apple Vision OCR line output with confidences.
- `structured.json` — only for Office files converted with structured content (tables).

Index: `manifest.json` (all 29), `coverage.json` (method split, PDF detail).

## Methods actually used

| Format | Count | Method |
|---|---|---|
| PDF, native text | 6 | DocVortex 0.6.26 native parse (`docvortex convert --format markdown`) |
| PDF, image-only | 2 | Apple Vision `VNRecognizeTextRequest` (zh-Hans + en-US, accurate) |
| DOCX / XLSX | 14 | DocVortex 0.6.26 native parse |
| TXT | 7 | direct read |

Coverage: **29/29 documents have non-empty content**.

## Why the requested ModelBest path was not used

`MODELBEST_API_KEY` was absent from every available scope (process env, login shell,
`launchctl getenv`, `~/.config/modelbest.key`, Keychain service `modelbest`). The one
attempt made returned `HTTP 401 invalid_api_key` (`extraction/D28/parse-raw.json` under
the original run). No successful billable call was made, and MiniCPM-OCR-Jev quality
scoring is therefore `NOT_VERIFIED` — no score was invented.

The image-only PDFs were recovered with the OS Vision framework (no model deployment,
no new service) so that the perception layer still covers 29/29. This is a documented
deviation from the requested MiniCPM-OCR path, not a silent substitution.
