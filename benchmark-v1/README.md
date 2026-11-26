# Forma benchmark v1 — Sorty baseline evidence (plain files)

Nine-run evidence bundle (3 arms × 3 repetitions) for the Forma Business Document
Organization Benchmark v1.0, captured 2026-11-26 on macOS 27.2.1 / Apple M1 Pro.
All files are uncompressed so they can be read directly on GitHub.

- `evidence/` — `MANIFEST.json` (per-file hashes), per-arm config, previews, plans,
  final trees, SHA-256 mappings, integrity, safety, metrics, reports; hierarchy and
  GUI-coverage diagnostics; nine-arm comparison; official-eval results.
- `runs/<ARM>/workspace/` — the actual applied workspace tree for each of the nine runs,
  next to that run's `TASK.md` and `inventory.json`.
- `logs/` — raw agent event logs and per-run timestamps for the six CLI runs.
- `SHA256SUMS.txt` — SHA-256 of every file in this directory.

Facts: arms G1 (Sorty GUI 1.3.1), C1 (original Sorty Skill `9c5ad2ed` + Codex CLI),
C0 (same host, empty skills), model `gpt-6-luna`; corpus
`forma-bench-v1-blind.zip`, 359 398 B, SHA-256 `e293155118a83a3f45649899df176998b09a3727700300d10accb0a3e3aa8696`;
all nine runs integrity PASS. The equivalent archive hash is
`7eb5114fef3b41cb8ab42df2728a3d6eca8d00988256d59e6d9184d343780dc2`.

Sanitized: home path → `/Users/bench`, owner example-folder name redacted.
No credentials, no real documents, no evaluator or gold material. Evidence-only branch;
no product source, not merged to `main`/`dev`.
