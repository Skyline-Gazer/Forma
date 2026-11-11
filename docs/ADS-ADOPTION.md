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

## FormaCore P2 review targets

P2 was delivered in four code PRs, each mirrored to CNB for review before merge. Findings are untrusted input; each round's disposition is recorded here rather than in the review output alone.

| CNB pull | GitHub PR | Reviewed source | Rounds | Result at merge |
|---|---|---|---|---|
| [#4](https://cnb.cool/KoolingMachine/Forma/-/pulls/4) | [#38](https://github.com/Skyline-Gazer/Forma/pull/38) Profiles, artifact schemas, schema gate | `17929d7` → `ddc9045` → `bda8280` → `1a28bb2` | 3 | merged as `b24463e`; GitHub Actions `run 42988017585` covered the final head |
| [#5](https://cnb.cool/KoolingMachine/Forma/-/pulls/5) | [#39](https://github.com/Skyline-Gazer/Forma/pull/39) Context Builder, Evidence Registry, Manifest Validator, mapping storage | `e86f2ea` → `b78e270` → `e924919` → `5ccf3a0` → `f13b722` → `1253335` → `5c4e932` | 4 | merged as `ee9954c`; GitHub Actions `run 42999561166` covered the final head |
| [#6](https://cnb.cool/KoolingMachine/Forma/-/pulls/6) | [#41](https://github.com/Skyline-Gazer/Forma/pull/41) Mapping Engine, transport reuse, CasePack, redaction | `db96396` → … → `f660f8b` | 11 | merged as `98c956d`; GitHub Actions `run 43020359230` covered the final head |
| [#7](https://cnb.cool/KoolingMachine/Forma/-/pulls/7) | [#42](https://github.com/Skyline-Gazer/Forma/pull/42) Manifest export, offline revalidation, Correction Capture | `f1ce455` → `2fee989` → `99632a4` | 2 builds: build 1 `changes_requested` (1 critical + 6 warning), build 2 `passed` (0 critical) | merged as `09baffe`; GitHub Actions `run 43024661916` covered the final head |
| [#8](https://cnb.cool/KoolingMachine/Forma/-/pulls/8) | [#43](https://github.com/Skyline-Gazer/Forma/pull/43) Native workspace, correction UI, export screens | `386aa0f` → `372f682` → `5ab9184` → `7e1de89` → `a2a1232` → `eb43197` → `f26247b` → `2582495` → `0d96330` → `df1a7c2` → `3885a57`* → `5d7aa43` → `eff5e79` → `e1630dc` → `4b4c1bf` → `ee872e6` → `74c6185` → `409eae8` → `865958b` → `c130895` → `743df66` → `bffed12` → `a5720c9` → `2538113` → `ecc8a30` → `b3084a4` → `7a00f03` → `74ab1d9` → `58f8a97` → `e839a1c` → `98cfdfc` → `4a2bfbd` → `659c490` → `520163e` → `576ce51` → `c9060f3` → `921808b` | 38 builds (37 verdicts), 14 critical | merged as 26a2c3b; GitHub Actions `run 43078381212` covered the final head |
| [#9](https://cnb.cool/KoolingMachine/Forma/-/pulls/9) | [#44](https://github.com/Skyline-Gazer/Forma/pull/44) P2 acceptance report and this ledger | `cdacae5` → `65b9cdb` → follow-up heads | build 1 `changes_requested`: 2 critical + 2 warning, **all in already-merged code**; build 2: 4 documentation-fidelity findings (contradictory critical counts, a wrong section pointer, a row-count claim that did not match the table, README asserting delivery while ROADMAP still recorded P2 as unauthorised) | open; code findings fixed in #45, prose findings in the same branch |
| [#10](https://cnb.cool/KoolingMachine/Forma/-/pulls/10) | [#45](https://github.com/Skyline-Gazer/Forma/pull/45) Post-merge review follow-ups | `4adcb95` → `094edd3` → `7573afe` → `2a29986` → `af147e8` | 4 builds, three findings and then approval: the progress indicator keyed on the shared phase (twice, at two heads) and a notice reading a member the export summary does not have; the reviewer output carried no per-finding severity labels, so none is claimed here | merged as `63618ea`; GitHub Actions run 43090470052 (tests + macOS app build pass) |

### What the round counts mean

PR #41 took eleven review rounds while PR #42 took two. The difference is not effort: #41 introduced the first code that consumed `ContextBuilder` output and `ManifestValidator` rules, and three of its findings exposed defects that had been *latent in already-merged code* — a `candidate_ref` semantics mismatch that would have stripped every real model answer of execution eligibility, a batching key that could attach a candidate not containing the file, and a shared loop in which a rate limit consumed the schema-repair budget. Each was fixed in the PR that surfaced it, with a test that fails if it returns.

Two further classes of defect appeared only under CI and are recorded because they would otherwise be invisible:

- An undeclared SwiftPM resource directory is not a build error. The bundle simply lacks the file, so every test loading the shipped CasePack threw, while a developer whose local scratch had baked an earlier build saw them pass.
- A test double that produced an undecodable answer passed its assertions. `nil` assigned into `[String: Any?]` removes the key rather than storing a null, and the strict metadata decoder requires all twelve slots, so several engine tests had been asserting against "no answer at all" — including the invented-reference refusal and the bounded re-ask.

### Coverage limits of this ledger

Round counts are per CNB pull, and the automatic cycle budget is finite. Where a remediation commit was mirrored after a round limit was reached, GitHub Actions on that exact head is the verification, and the gap is stated rather than presented as a completed review. No P2 round output has been reused as coverage for a newer head.

\* `3885a57` 的评审构建以 `REVIEW_EVIDENCE_INVALID` 结束（该轮输出里有一条发现缺少 `severity`），评审文本仍从 stage 日志中读出并处理；该 head 不计为一次有效判定。

### Why #43 needed thirty-eight review builds

The findings were not the same complaint repeated, and they arrived in four layers. Builds 1-10 fixed what the workspace writes: a persisted scope with two writers, an engine cache whose key and body were maintained apart, a corrections column that meant "produced" on one path and "targeted" on another, publishing and recording split across two transactions, and a correction that could be published on top of a revision it had never seen. Builds 11-21 fixed when a value is allowed to be believed: guards that ran after the writes they protected, read-backs that swallowed a successful write when they failed, tab-shaped `onDisappear` handlers cancelling a task handle shared by every long operation, and two reload passes racing at launch. Builds 22-35 fixed the remediation itself and the migration's contact with real history: the unique index that aborts the upgrade of a version 1 database holding two corrections that name the same revision they read (build 22, critical - every workspace that had been used twice would have failed to open); the same migration crediting a `pending` row with a revision it never published; the next-revision number read twice in one transaction; and an egress-consent preview that paired snapshotted bytes with the settings on screen. Builds 36-38 hit comment bulk only: notes that argued with the reader, narrated a replaced implementation, or duplicated a constraint stated three lines away.

Six defects were found only by CI, and only because the machine cannot type-check the app target locally: an exhaustive `switch` over `Phase` missing a case, a stored property read in `init` before initialisation completed, references to members that do not exist (`SourceEntry.sourceID`, `ManifestEnvelope.profile`), `try?` applied to an already-optional return, an ownership guard naming a variable no enclosing scope bound, and a migration test deleting `grdb_database_migrations` where GRDB keeps `grdb_migrations`. GUI work in this repository is gated on the macOS app build, and that gate is stated as the verification rather than described as a local pass.

### What a later pull found after thirty-eight builds on the earlier one

The documentation pull #9 mirrors `review/p2-docs` against CNB `dev`, so its review diff contained the
workspace code merged in #43. On its first build the reviewer returned two criticals that thirty-eight
builds of that same code had not:

- `applyCorrection` re-read "the current manifest for this scope and profile" after publishing, to detect a
  revision that had moved on in the meantime. The query answers with the newest manifest of that pair, not
  the one the click corrected, so a second manifest for the same scope and profile — mapping run B plus an
  imported bundle manifest A — put B's header and entries on screen under a notice describing the revision
  just written to A. The write already returns the manifest it stored; the second read was removed rather
  than narrowed, because no read of "latest" can be made to mean "the one I wrote".
- `export()` packaged `evidenceBySource`, the rows this session had opened, instead of the rows the manifest
  cites. Exporting after `reload()` without clicking through every file produced a bundle whose
  `evidence.json` was missing cited rows, which only contradicts itself under offline revalidation, on
  another machine, after the success notice has been dismissed.

Both were reproduced against the current source before being fixed (#45 `094edd3`), together with the two
warnings from the same build: the correction verifier scanned a source's whole evidence list once per cited
id — undoing the batch read introduced beside it — and a failed history read after a recorded correction
reported `notRead` while rendering a one-row list, which is a different claim.

The same review read the *prose* of that documentation pull on its second build and returned four more
defects, all of the "two sentences in one document disagree" kind: a sentence scoped in the author's head to
two pulls that read anywhere else as the P2 total, a cross-reference to the wrong section (whose target also
mis-described the round count it pointed at), a defect-table summary whose row arithmetic did not match the
table, and a README that declared P2 delivered while ROADMAP's Owner authorization line still listed only P0
and P1. None of these were code, and all of them would have been inherited as fact by whoever reads the
report next; the report now carries one authoritative count line that every other count defers to.

The lesson recorded for adoption decisions: round counts measure persistence, not coverage. A review that
has spent thirty-eight builds on a state machine can still miss "this read returns a different entity than
the caller means" and "this cache is being used as a source of record". Those two shapes are now explicit
checklist items for P3 review, listed in `docs/P2-ACCEPTANCE.md` §8.
