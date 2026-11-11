# ADS adoption and CNB review topology

## Pinned ADS revision

- ADS repository: https://github.com/Skyline-Gazer/ADS
- ADS adaptation branch: `cnb/dev`
- Consumed immutable commit: `16b99f4b49769555acc66a0c57b8cfcb8c8bac60`
- Pin record: [ads-pin.txt](../ads-pin.txt)
- Git submodule: `.ads/`

Consistency is machine-checked, not remembered: `scripts/check_ads_pin.py` compares the tree gitlink, the index entry, `.gitmodules` remote and `ads-pin.txt` (repository, branch, commit, consumption mode) and fails on any drift. Run it after every ADS update; a negative control with a falsified pin commit exits non-zero.

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

- https://cnb.cool/KoolingMachine/Forma exists, public, created 2026-11-11, access level `Owner` for the reviewing account, and initially had no branches (an empty review workspace, not a missing repository).
- The workspace was seeded with exact GitHub object ids only: `dev` = `38d455304bc4530b71e584c07de48fc06fd1f293`, `chore/ads-cnb-consumer` = the current GitHub PR head. No CNB-only commit exists; CNB cannot advance authoritative history.
- A real review executed for PR #25 head SHA on CNB pull #1 (`event=pull_request`, source `chore/ads-cnb-consumer` → target `dev`). The run succeeded in ~30 s and read the actual diff, including the `160000` gitlink.
- Structured findings were obtained from the retained runner log. In that run the plugin failed to parse its own result and reported `PR 评论发送失败，但评审已完成`, so no PR comment or review object was retrievable; retrieval therefore uses the build log and must be re-checked for comment delivery on each round. Plugin exit code 0 is not treated as review coverage.

Not authorized or not configured by this adoption: automatic CNB↔GitHub synchronization, push mirrors, release flows, CNB build/test stages, CNB merge authority, and any credential stored outside the platform secret store.
