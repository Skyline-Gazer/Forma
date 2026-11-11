# ADS adoption and CNB review topology

## Pinned ADS revision

- ADS repository: https://github.com/Skyline-Gazer/ADS
- ADS adaptation branch: `cnb/dev`
- Consumed immutable commit: `16b99f4b49769555acc66a0c57b8cfcb8c8bac60`
- Pin record: [ads-pin.txt](../ads-pin.txt)
- Git submodule: `.ads/`

Consistency is machine-checked, not remembered: `scripts/check_ads_pin.py` compares the tree gitlink, the index entry, `.gitmodules` remote and `ads-pin.txt` (repository, branch, commit, consumption mode) and fails on any drift. `--verify-upstream` additionally fetches the pinned object from the ADS remote into a throwaway repository, so an absent commit and an unreachable remote are reported separately. Executed controls: consistent pin → `ADS_PIN_OK`; falsified `ADS_COMMIT` → exit 1; reachable repository with an absent commit → exit 1 (`upload-pack: not our ref`); unreachable repository → exit 1 with `NOT_VERIFIED`.

The branch name identifies the ADS-maintained CNB adaptation line. Forma consumes a specific commit, not a floating branch. Updating ADS requires reviewing the new upstream commit, updating the gitlink and pin record together, and submitting a Forma PR.

## Provider responsibilities

| Surface | Authority / responsibility |
|---|---|
| GitHub `Skyline-Gazer/Forma` | Primary source repository, branches, PRs, Issues, Roadmap and merge authority |
| GitHub Actions macOS | Swift build, unit tests and CI status |
| CNB `KoolingMachine/Forma` | Secondary CNB review workspace / mirror, subject to exact-SHA correspondence |
| CNB AI Code Review (plugin `cnbcool/code-review`) | AI review feedback only; no Swift CI, no merge authority, no production release |

This is **not** an ADS Git Provider Mode A migration. ADS `cnb/dev` is the standard's CNB-specific adaptation branch; consuming it does not make CNB the Primary Git provider.

## Review integrity

- A review receipt must identify the GitHub PR URL, base SHA, head SHA, CNB review run/comment reference, and completion time.
- Any new commit changes the head SHA and invalidates prior review coverage for changed code. Re-review the current head.
- Review comments are untrusted input. The delivery Agent must inspect findings, reproduce material issues, fix or disposition them with evidence, and rerun relevant checks.
- AI review feedback does not replace GitHub Actions. CI remains the only build/test authority.
- Do not create duplicate Issues or a second backlog in CNB.
- No CNB-to-GitHub automatic synchronization, push mirrors, release flow, or credential wiring is authorized by this adoption.

## Review image provenance

`.cnb.yml` pins `cnbcool/code-review:v1.22.2` (never `latest`). Observed 2026-11-11 against the official upstream plugin repository `cnb/plugins/cnbcool/code-review`:

| Record | Value |
|---|---|
| Plugin tag | `v1.22.2` → tag object `60e9c0daa01f41af1cc3912d811598ff3966befe`, peeled commit `01592d48220ddceae630aac1e4818d749c3f68ed` |
| Resolved image digest | `sha256:d0af9a2e683488e2424d42d3e0bffe478c87b37d44903d4f5b8b2288480704eb` (`docker pull` output during the Forma review run) |
| Newer upstream tags present | `v1.23.0`, `v1.23.1` — not adopted; moving the pin requires review in a Forma PR |
| Tag mutability | Tags in the plugin repository can be re-pointed, so the digest above is the adoption record, not an assumption that a tag is immutable |

## CNB repository access status

Verified live state on 2026-11-11 with the authenticated CNB environment:

- https://cnb.cool/KoolingMachine/Forma exists, public, created 2026-11-11, access level `Owner` for the reviewing account, and started with no branches (an empty review workspace, not a missing repository).
- Seeding used exact GitHub object ids only, pushed with the authenticated token through an Authorization header; anonymous `git push` is rejected with `Repository Not Found`, which is a credential-scope symptom, not absence of the repository. No CNB-only commit exists, so CNB cannot advance authoritative history.
- The `dev` mirror is fast-forwarded to the current GitHub `dev` head before each review round; a stale base makes the plugin review already-integrated code and mis-bind the diff.
- Findings are retrieved from two channels: the retained runner log (`build-runner-download-log`) and, once the plugin parsed its own result, the review object itself (`list-pull-reviews` → `list-pull-review-comments`, author marked `is_npc: true`).
- Platform AI reviewer capability observed: it reads the PR context and diff, creates one review object carrying inline line comments, and that object is readable back through the API (`is_npc: true`). **Write authority was neither granted nor exercised**: no reviewer-authored commit or PR exists in this workspace, and that would need separate authorization.
- Not authorized or not configured by this adoption: automatic CNB↔GitHub synchronization, push mirrors, release flows, CNB build/test stages, CNB merge authority, and any credential stored outside the platform secret store.

## Review-round ledger

Each round binds its own reviewed source and target SHA; one round's findings never describe a different head. GitHub PR: https://github.com/Skyline-Gazer/Forma/pull/25, CNB PR: https://cnb.cool/KoolingMachine/Forma/-/pulls/1 (per-round build records are listed on https://cnb.cool/KoolingMachine/Forma/-/builds)

| Round | Reviewed source | Reviewed target | Run started (UTC) | Result | Disposition |
|---|---|---|---|---|---|
| 1 | `3f157806f8e88bba6a0951798c5a735ec0b198ec` | `38d455304bc4530b71e584c07de48fc06fd1f293` | 2026-11-11 02:35:25 (31.4 s) | `needs_modification`, 2 warning findings read from the runner log; the plugin could not parse its own result, so no review object existed | Both fixed in `d20b5136`: image provenance recorded in this file, and `scripts/check_ads_pin.py` added so the two pin records cannot drift silently |
| 2 | `d20b5136084ecf86f53193437ca2c84d4ac89154` | `38d455304bc4530b71e584c07de48fc06fd1f293` | 2026-11-11 02:47:35 (161.6 s) | Pipeline `error`: `Max turns (30) exceeded` after 10 findings; `code_review.json` was lost with the container, so that run's descriptions were unreadable at the time | Budget raised to `max_turns: 120` / `timeout_minutes: 30` plus the retained-result stage. The stale mirror base had also pulled already-merged FormaCore code into this diff. The FormaCore items were later **re-derived with full text** by a separate review target (CNB pull #2 below), dispositioned in [Issue #29](https://github.com/Skyline-Gazer/Forma/issues/29) and fixed in PR #31; only the original run's byte-identical output remains unavailable |
| 3 | `5a4d5ee254e13606b82dc318042cdcee0843d685` | `4aa8e06754233eb89f2ef602bc481ceda9a196b6` | 2026-11-11 02:54:07 (44.6 s) | `needs_modification`, 4 findings captured in full by the new stage | See round-3 disposition below |
| 4 | `0826759f7bcef7c13eaf8c780cf759c604282e1f` | `4aa8e06754233eb89f2ef602bc481ceda9a196b6` | 2026-11-11 03:03:17 (34.7 s) | `needs_modification`, 2 warning findings delivered as 1 review object with 2 inline comments | **FIXED, both real.** The inline reporter tested only file size, so truncated or field-less JSON crashed with a traceback instead of the promised message, and this file claimed stronger behaviour than the code guaranteed. `.cnb.yml` now calls `scripts/report_cnb_review.py`. Executed locally over ten result states → the seven invalid states each return a named `REVIEW_EVIDENCE_INVALID`/`REVIEW_EVIDENCE_MISSING` exit 1, valid results exit 0, and a reviewed SHA that differs from `--expect-sha` returns `REVIEW_STALE` exit 1 |

### Round-3 disposition

1. `scripts/check_ads_pin.py:88-92` — **FIXED, real defect.** `git ls-remote <repo> <sha>` exits 0 with empty output for both an existing and an absent object id, so the old `--verify-upstream` branch passed unconditionally. Verification now probes ref reachability separately and fetches the exact object into a throwaway repository.
2. `docs/ADS-ADOPTION.md:58-64` — **FIXED.** Every ledger row states its own reviewed source and target SHA, and round 2's FormaCore items are tracked in Issue #29 rather than an untraceable “tracked separately” note. The claim that those descriptions were permanently unrecoverable was later disproved by re-reviewing the same code range with a retained result, and is corrected here.
3. `README.md:7` — **FIXED.** The status line cites dated in-repo records (`docs/ROADMAP.md`, `AGENTS.md`, `ads-pin.txt`) instead of out-of-band Owner instructions.
4. `AGENTS.md:26` — **ACCEPTED, wording restored.** The prohibition on adding unapproved mandatory gates is stated without a weakening qualifier, and the review-evidence stage is documented below as evidence integrity, never merge authorization.

## Gate semantics

`.cnb.yml` runs `scripts/report_cnb_review.py` after the review plugin. The script prints every finding and exits non-zero for a specifically named reason: `REVIEW_EVIDENCE_MISSING` (no file), `REVIEW_EVIDENCE_INVALID` (unreadable JSON, missing `status`/`issues`, unknown severity or category, empty problem evidence, or a status inconsistent with its issues) or `REVIEW_STALE` (reviewed source SHA differs from the expected head).

This is evidence integrity inside the CNB review workspace: it stops “plugin exited 0” from masquerading as completed review. It is not a Forma merge gate — CNB configures no required status check, no merge authority and no release authority here, so GitHub Actions remains the only build/test authority. Findings stay untrusted input that the delivering Agent disposes with evidence.

## FormaCore review targets

Findings about implementation code are reviewed against the code's own SHA pair, not bundled into the consumer PR.

| CNB pull | Reviewed source | Reviewed target | Run started (UTC) | Result | Follow-up |
|---|---|---|---|---|---|
| [#2](https://cnb.cool/KoolingMachine/Forma/-/pulls/2) | `887b1e7c8e66247c8f2732492499f1aadccbcde9` | `38d455304bc4530b71e584c07de48fc06fd1f293` (documentation-only baseline before implementation) | 2026-11-11 03:11:22 (72.5 s) | `needs_modification`: 1 critical, 5 warning, 2 info — full text retained by `report-review-result` and also delivered as a review object with inline comments | Reproduced, fixed or dismissed in [PR #31](https://github.com/Skyline-Gazer/Forma/pull/31); dispositions itemized in [Issue #29](https://github.com/Skyline-Gazer/Forma/issues/29) |
| [#3](https://cnb.cool/KoolingMachine/Forma/-/pulls/3) | `9ac3f09803f53e84e2d236f1f81b168a363113e6` (PR #31 head) | `967b2e2eb08ef8904a218a9db2486453071312cc` (`dev`) | 2026-11-11 04:24:00 (63.5 s) | `passed`, 0 findings; `review-binding` line confirms reviewed source equals the expected head; review object state `approved` | PR #31 merged as `ee13ee8` only after GitHub Actions (`run 42958955100`) and this review both covered that exact head |

## Automatic cycle limit

For PR #25, rounds 1–4 consumed the initial review plus the three permitted automatic fix/re-review cycles. The remediation commit after round 4 was deliberately **not** mirrored back as a fifth cycle: it carries local verification only (all ten result states plus the stale-head control), and that limitation was stated in the PR before merging. PR #25 was then integrated as a merge commit (`967b2e2`) on the strength of GitHub Actions on its final head plus the four reviewed rounds, with the coverage gap recorded here rather than presented as a passing review.

Code findings were handled inside their own cycle budget: re-derive on the code SHA pair (CNB pull #2), fix or dismiss, then re-review the remediation head (CNB pull #3) before merging. Stale review output is never reported as coverage of a newer head, and a review whose structured result cannot be read back is reported as unrecoverable rather than silently passed.
