# Skills Host Verification — Forma project-scoped SwiftUI skills

Status: **verification record only; no skill or product code is added by this PR.**
Date: 2026-11-24. Host: `omp/19.1.1` on Linux DevBox. #161 has been merged into
`dev`; the installer layout fix was merged separately in PR #164. This document
records verification of that change.

## 1. Scope

Two advisory project skills:

| Skill | Declared | Pinned commit | Licence |
| --- | --- | --- | --- |
| `swiftui-expert-skill` | 5.3.0 | `62bd760f005093d1e2e4de5db156e456a5f96400` | MIT |
| `swiftui-pro` | 2.0.0 | `f2920b63995263f57b3e198674e89a602efba6d2` | MIT |

Both pins were re-checked against upstream `main` on 2026-11-24 and are still the
latest commits. They are advisory only: no runtime/build dependency, no bundled
code, no change to Apple HIG, ADS, macOS 14 or Swift 6 authority.

## 2. Host search paths (from the host's own documentation)

For the `agents` provider, skills are discovered **non-recursively** as:

```text
<project>/.agents/skills/<skill-name>/SKILL.md
```

The user-global equivalent is `~/.agents/skills/<skill-name>/SKILL.md`. Nested
layouts such as `<skills-root>/<vendor>/<skill>/SKILL.md` are not discovered.
Discovery is project/cwd-scoped; a worktree without `.agents` has no project
skills. The current integration worktree has no `.agents`, and the running agent
therefore exposes only the host-global catalog.

## 3. Observed results

### 3.1 Provenance and install verification

From `wt/d0` (a worktree with the two skills installed):

```text
sh scripts/install_skills.sh --check-only     # exit 0

SKILL_OK: swiftui-expert-skill @ 62bd760f005093d1e2e4de5db156e456a5f96400
  (licence MIT License) -> .agents/skills/swiftui-expert-skill
SKILL_OK: swiftui-pro @ f2920b63995263f57b3e198674e89a602efba6d2
  (licence MIT License) -> .agents/skills/swiftui-pro
```

Installed `SKILL.md` SHA-256 values observed:

```text
6fa1d5188176628a00e7f032298e640f5191185904e305983cc8a2fa6e2c31d5
  .agents/skills/swiftui-expert-skill/skills/swiftui-expert-skill/SKILL.md
fc62139e262bd364cbbcab9b9f97557cd3fd6d2d4f73c4fab039d562fc324643
  .agents/skills/swiftui-pro/swiftui-pro/SKILL.md
```

Both `LICENSE` files contain the MIT grant.

### 3.2 Pre-fix host discovery: FAIL (layout mismatch)

Before the installer fix, `omp read skill://swiftui-expert-skill` and
`omp read skill://swiftui-pro` both returned `Unknown skill`, even though
`--check-only` passed. The installer preserved the upstream repository tree:

```text
.agents/skills/swiftui-expert-skill/skills/swiftui-expert-skill/SKILL.md
.agents/skills/swiftui-pro/swiftui-pro/SKILL.md
```

The host requires `<skill-name>/SKILL.md` directly. This was an install-layout
defect, not a provenance failure.

### 3.3 Installer fix: PASS

The installer fix merged in PR #164 (`fix/skills-host-layout`). It copies
only the locked `skill_path` subtree to the install root, copies the root MIT
license, and writes deterministic `.forma-skill.json` provenance plus a content
hash. It stages the result outside the host-visible directory and moves it into
place only after verification. No symlink workaround is used.

Verified on the fix branch:

```text
SKILL_OK: swiftui-expert-skill @ 62bd760... (licence MIT License)
  -> .agents/skills/swiftui-expert-skill, entry .agents/skills/swiftui-expert-skill/SKILL.md
SKILL_OK: swiftui-pro @ f2920b639... (licence MIT License)
  -> .agents/skills/swiftui-pro, entry .agents/skills/swiftui-pro/SKILL.md
```

Fresh install, legacy nested-install migration, idempotent reinstall, invalid
layout rejection, and preservation of a dirty old install were exercised.

Results after the fix:

```text
omp read skill://swiftui-expert-skill
  -> [Skill file: .../swiftui-expert-skill/SKILL.md] ... # SwiftUI Expert Skill

omp read skill://swiftui-pro
  -> [Skill file: .../swiftui-pro/SKILL.md] ... # SwiftUI Pro

omp read skill://swiftui-expert-skill/references/performance-patterns.md
  -> # SwiftUI Performance Patterns Reference

omp read skill://swiftui-pro/references/design.md
  -> # Design
```

No global host configuration was modified. No model generation was used;
`omp read skill://...` is the host's own resolution path. Earlier temporary
root-level symlinks were diagnostic only and have been removed; they are not
part of the fix.

## 4. Interpretation

| Claim | Status | Evidence |
| --- | --- | --- |
| Exact pins, licences, provenance | PASS | `--check-only`, upstream latest, MIT files |
| Skill files installed in a project worktree | PASS | root layout + provenance |
| Host discovery as installed **before** fix | FAIL | `Unknown skill` for both |
| Host discovery after installer fix | PASS | `omp read` for both |
| Skill content read after fix | PASS | `SKILL.md` and reference files |
| Host discovers skills in a worktree without `.agents` | NOT_APPLICABLE / expected absent | install per worktree |
| Model actually used the skill in a task | NOT_VERIFIED | no task execution claimed |
| Forma runtime/build dependency | NOT_PRESENT | advisory files only; not in Package.swift/app |

## 5. Rollout plan

1. The installer bugfix PR #164 was merged separately from #161. It leaves the
   ADS pin and product code unchanged.
2. In each active worktree, run `sh scripts/install_skills.sh` and
   `sh scripts/install_skills.sh --check-only`.
3. Verify `omp read skill://<name>` and one reference path in that worktree.
4. Only a successful installation, host discovery and content read may be
   called adopted. Behavioral adoption needs a real model task and remains
   NOT_VERIFIED.
5. If a future host does not support project-level discovery, record
   `SKILLS_HOST_VERIFICATION = BLOCKED` and do not modify global host settings
   without Owner authorization.

## 6. Boundaries

- No change to PR #161, `FormaCore`, `FormaApp`, CI, `skills.lock.json`, ADS pin
  or global host configuration.
- No Provider call, no DEVONthink access, no production archive operation.
- macOS GUI, VoiceOver, Light/Dark and Instruments remain Mac-only
  `NOT_VERIFIED`; this document does not claim them.
