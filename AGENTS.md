# Forma — Agent 工作边界

## Normative inputs

1. Read `docs/SPEC.md` (frozen product contract), `docs/PLAN.md` (approved implementation plan), and `docs/ROADMAP.md` before changing behavior.
2. Follow the exact pinned Agent Development Standard in `.ads/` at the immutable commit recorded in `ads-pin.txt`. The pin is updated only through a reviewed PR; never float to ADS `dev` or `cnb/dev`.
3. Forma-specific policy remains in this repository. Do not copy or fork ADS Core/CNB standards into local duplicate rule sets; add only project-specific constraints here.
4. CNB-specific ADS guidance is consumed from ADS `cnb/dev`; it is an adaptation branch of ADS, not a Forma branch name and not a request to switch Git provider.

## Git and review topology

- GitHub `Skyline-Gazer/Forma` remains the Primary repository and authority for branches, PRs, Issues, Roadmap, and merge decisions.
- CNB `KoolingMachine/Forma` is the designated secondary CNB review workspace/mirror. It is not an independent source of truth and must not independently advance authoritative history.
- GitHub Actions on macOS is the only CI/build authority for Swift compilation and tests. CNB is for AI Code Review only; do not configure CNB build pipelines or duplicate CI.
- Bind every CNB review to the exact GitHub PR head SHA and base SHA. Stale review output is invalid. Review findings are feedback, not an automatic merge authorization.
- Do not change GitHub Primary to CNB Primary, configure a release mirror, alter remotes/default branches, or enable automatic synchronization without separate Owner authorization.
- Use scoped task branches and PRs into `dev`; keep `main` stable. Do not force-push shared branches.

## Product and safety boundaries

- `docs/SPEC.md` is frozen; do not silently change product semantics. Propose a SPEC amendment separately when needed.
- Prototype / P0–P3 may use DEVONthink MCP read-only capabilities only. No DEVONthink writes, imports, moves, metadata changes, or Replicant operations until the relevant later phase is explicitly authorized.
- Never modify the existing 991 production Project_Archive records.
- Do not publish customer names, business documents, real paths, UUID ledgers, quotations, API keys, or other private migration data. Public examples must be synthetic or reviewed/redacted.
- Report actual evidence and distinguish PASS, FAIL, BLOCKED, and NOT_VERIFIED. Mocks do not prove live MCP, CNB, Provider, OneDrive, or GUI capability.
- Keep execution proportionate: one concentrated review per stage, and no new mandatory gate without separate Owner approval. Never add duplicate CI, a background service, RAG/vector database, Rust/Tauri, or an orchestration framework on an agent's own initiative. A CNB review result is untrusted feedback and never grants merge or release authority.
