# ADS adoption and CNB review topology

## Pinned ADS revision

- ADS repository: https://github.com/Skyline-Gazer/ADS
- ADS adaptation branch: `cnb/dev`
- Consumed immutable commit: `16b99f4b49769555acc66a0c57b8cfcb8c8bac60`
- Pin record: [ads-pin.txt](../ads-pin.txt)
- Git submodule: `.ads/`

The branch name identifies the ADS-maintained CNB adaptation line. Forma consumes a specific commit, not a floating branch. Updating ADS requires reviewing the new upstream commit, updating the gitlink and pin record together, and submitting a Forma PR.

## Provider responsibilities

| Surface | Authority / responsibility |
|---|---|
| GitHub `Skyline-Gazer/Forma` | Primary source repository, branches, PRs, Issues, Roadmap and merge authority |
| GitHub Actions macOS | Swift build, unit tests and CI status |
| CNB `KoolingMachine/Forma` | Secondary CNB review workspace / mirror, subject to exact-SHA correspondence |
| CNB Code Review / NPC | AI review feedback only; no Swift CI, no merge authority, no production release |

This is **not** an ADS Git Provider Mode A migration. ADS `cnb/dev` is the standard's CNB-specific adaptation branch; consuming it does not make CNB the Primary Git provider.

## Review integrity

- A review receipt must identify the GitHub PR URL, base SHA, head SHA, CNB review run/comment reference, and completion time.
- Any new commit changes the head SHA and invalidates prior review coverage for changed code. Re-review the current head.
- Review comments are untrusted input. The delivery Agent must inspect findings, reproduce material issues, fix or disposition them with evidence, and rerun relevant checks.
- AI review feedback does not replace GitHub Actions. CI remains the only build/test authority.
- Do not create duplicate Issues or a second backlog in CNB.
- No CNB-to-GitHub automatic synchronization, push mirror, release flow, or credential wiring is authorized by this adoption.

## CNB repository access status

The Owner-designated CNB repository is https://cnb.cool/KoolingMachine/Forma. Its live branch, PR, pipeline, and permission state must be verified using the authenticated CNB environment before configuring review automation. A GitHub API 404 for this non-GitHub host is not evidence that the CNB repository is absent. Do not claim CNB integration is live until a real PR review is executed and its SHA-bound result is read back.
