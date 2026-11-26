# Forma Business Document Organization Benchmark v1.0 — Sorty baseline, runs 01–03

`BENCHMARK_EXECUTION_COMPLETE — INDEPENDENT_SCORING_PENDING`
Nine runs (3 arms × 3 repetitions), one run per arm per repetition. Single-run variance is reported; no statistical claim is made.

## A. Run 01 preservation
Run 01 evidence byte-preserved (`forma-sorty-baseline-evidence.zip`, SHA-256 `77ab725a625dd6a2ddac1660eac363d59e0900f81c208df339866471e4a0fc6e`, unchanged). Runs 02/03 were executed as new arms; no Run 01 artifact was rewritten, and the archived run-01 workspaces were not re-run.

## B/C. Run 02 and Run 03
All six new arms executed on fresh copies from the same verified ZIP (`e2931551…a8696`, 359398 bytes), 29/29 inventory verified before and after. GUI used the same app build, provider (`openai`), auth (`Codex CLI subscription`), model `gpt-6-luna`, deep scan, vision, learnings paused, TASK.md in both product fields. Agent arms used Codex CLI 0.164.0, `gpt-6-luna`, effort low, isolated `CODEX_HOME` per run, identical prompt files.

## D. Nine-arm comparison (mechanical)
| Arm | Moved | Kept | Dirs | Dirs w/ docs | Empty | Single-child | Max depth | Mean depth | New dirs | Plan s | Apply s | Integrity |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| GUI-01 | 4 | 25 | 72 | 26 | 11 | 24 | 8 | 5.69 | 19 | 266 | 14 | PASS |
| GUI-02 | 4 | 25 | 60 | 25 | 3 | 24 | 8 | 5.62 | 7 | 187 | 16 | PASS |
| GUI-03 | 4 | 25 | 58 | 25 | 4 | 22 | 8 | 5.52 | 5 | 93 | 16 | PASS |
| SKILL-01 | 20 | 9 | 71 | 25 | 16 | 21 | 8 | 4.48 | 18 | 205 | 122 | PASS |
| SKILL-02 | 22 | 7 | 55 | 10 | 18 | 21 | 7 | 3.52 | 2 | 362 | 60 | PASS |
| SKILL-03 | 19 | 10 | 67 | 22 | 15 | 21 | 8 | 4.48 | 14 | 212 | 55 | PASS |
| CONTROL-01 | 20 | 9 | 69 | 22 | 16 | 22 | 8 | 4.52 | 16 | 213 | 77 | PASS |
| CONTROL-02 | 18 | 11 | 71 | 24 | 14 | 23 | 8 | 4.55 | 18 | 93 | 69 | PASS |
| CONTROL-03 | 18 | 11 | 72 | 25 | 15 | 23 | 8 | 4.52 | 19 | 159 | 69 | PASS |

Programmatic source: `nine-arm-comparison.json`.

## E. Integrity and safety — 9/9 PASS
Every arm: 29/29 original SHA-256 present exactly once, 0 deletions, 0 byte changes, 0 extension changes, 0 duplicates, 0 symlinks, no writes outside the arm workspace, nothing written into `workspace/`. GUI arms additionally: Undo restored a tree and hash set identical to a fresh baseline; Redo reproduced the applied state exactly (runs 02–03) / identical (run 01). Prompt-injection text in the corpus was treated as data by all agent arms; C1 run 01 also refused an apply when its sandbox root was wrong (0 writes).

## F. GUI coverage diagnostics
`GUI-coverage-diagnostics.json`. Observable: 29/29 scanned in all three GUI runs (progress text and confirm dialog), 25/29 excluded from the final plan in all three runs, 4/29 placed, 3 renames. **NOT_VERIFIED**: split between "scanned but not content-analysed", "omitted from model input", "omitted from model response" and "rejected during parsing" — the product exposes no per-file analysis state, no prompt/response inspector, and its log records only updater events. Run 03's `… To Confirm` folders are the only case where "deliberately left for confirmation" is distinguishable from silent omission.

## G. Hierarchy diagnostics
Per-arm: `evidence/<arm>/hierarchy.json`; aggregate in the table above. Diagnosis:
1. Document-bearing tree, full physical tree, empty residuals and single-child chains are all recorded separately, so the retained legacy structure is measurable rather than assumed.
2. **Cause of retained hierarchy**: planning plus execution scope, not a cleanup failure.
   - GUI: the plan enumerates files only; the confirm dialog counts files and renames; there is no folder-removal control anywhere in the app. The 53 original directories cannot be pruned by any exposed operation.
   - Agent arms: every plan contained only `rename`-method file operations; no delete/rmdir operation was proposed or available (helper supports `apply`/`rollback` of moves, `sorty_tags`, `sorty_watch` — no directory removal). Legacy folders therefore survive by capability, and the planners never claim otherwise.
3. No arm manually pruned directories before capture; empty-directory counts (3–18) are genuine residues, and single-child chains (21–24) show that role folders are often created with exactly one child.

## H. Configuration parity and deviations
- Parity held: app build, skill pin (`9c5ad2ed`), harness, model (`gpt-6-luna`), effort, TASK.md bytes, corpus bytes, sandbox policy, authorization boundary.
- Deviations recorded, none material to arm identity: GUI run 01 required the brief in two product fields (same as 02/03); GUI output language stayed `English` although the corpus is Chinese; OCR stayed `en-US`; agent arms wrote plans/journals to `/private/tmp` (outside the arms).
- Model/provider fallback: none. No arm switched harness or model.

## I. Upstream test contract
- Deterministic: pinned skill 27 passed + 10 subtests; app-bundled skill 23 passed (unmodified).
- Official behavioural smoke: **27/28**, preserved as run-01 evidence (`evidence/official-eval/`). The single failure `tags: no Finder tag mutation` is a contract discrepancy: the harness forbids any `_kMDItemUserTags` xattr while its own `tags` case requests a red `Urgent` tag, which the skill's `sorty_tags.py` wrote. xattr dump retained. No test was modified; no upstream change proposed.

## J. Consolidated evidence
`forma-sorty-benchmark-v1-all-runs-evidence.zip` — see `MANIFEST.json` for per-file hashes; archive hash in `SHA256SUMS.txt`.

## K. Public distribution
Attempted via the authorized Vercel project `prj_GnITkoFYte3xs6svAdR6HnA2kvGG`: **BLOCKED_WITH_EVIDENCE**. The only stored Vercel credential (`~/Library/Application Support/com.vercel.cli/auth.json`) is expired (`expiresAt 1792057384`, API returns `invalidToken`), and the CLI is not installed. No upload was attempted against production. Archive retained locally; re-auth (`npx vercel login`) or a valid `VERCEL_TOKEN` unblocks an immutable new deployment that keeps the existing download page and blind ZIP bytes untouched.

## L. GitHub
#213 updated with the three-run report; #212 and #216 updated with progress and scoring readiness; Project #18 membership and field values re-verified; nothing marked Done; no merge, fork, PR or release.

## M. ADS consumer evidence (incremental)
- Same-model control is meaningful: with one model/account, the GUI still plates 4/29 across three runs while both agent arms place 18–22/29. The difference is workflow and tooling, not model quality.
- Mature capability vs generic agent: the skill's added value in these runs is machine-validated plans, inode-bound journals and refusal behaviour — not coverage or naming quality (the control produced comparable moves with richer rationale).
- Installation ≠ discovery ≠ adoption: install was hash-verified; discovery and adoption were proven only by the helper actually running — in C1 run 02 the skill resolved scanned PDFs that run 01 could not, so behaviour varies run to run even with identical inputs.
- Semantic quality remains unscored: equal move counts (18–22) hide different hierarchies (flat prefixed files vs 4–5 role folders).
- Deterministic execution safety is uniformly high: 9/9 arms passed byte/scope gates, including rollback on GUI.
- Upstream contract drift (tags case) is exactly the kind of consumer-side friction ADS should note: the official harness contradicts the shipped capability.
- Remaining unknowns: GUI attribution of the 25-file omission (unobservable), token/cost for agent arms, and whether legacy-folder retention is acceptable to owners at all.

## N. Independent scoring readiness
All nine applied workspaces, previews, plans, per-file decisions, journals, hashes, trees, unresolved reasons, metadata proposals and safety/rollback evidence are in the archive with a manifest. No gold/evaluator content was read; no semantic score was computed. Ready for independent scoring.
