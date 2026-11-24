# Skills Host Verification — Forma project-scoped SwiftUI skills

Status: **verification record only; no skill or product code is added by this PR.**
Date: 2026-11-24. Host: `omp/19.1.1` on Linux DevBox. Candidate under test: PR #155
(`feat/d0-skills-ads-pin`), which is also contained in frozen integration candidate
PR #161. This branch is cut from `dev` and does not modify #161.

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

### 3.2 Host discovery — as installed: FAIL (layout mismatch)

`omp read skill://swiftui-expert-skill` and `omp read skill://swiftui-pro` both
returned `Unknown skill` from `wt/d0`, even though `--check-only` passed. The
installer preserves the upstream repository tree, so the entry file is at:

```text
.agents/skills/swiftui-expert-skill/skills/swiftui-expert-skill/SKILL.md
.agents/skills/swiftui-pro/swiftui-pro/SKILL.md
```

The host requires `<skill-name>/SKILL.md` directly. This is an install-layout
adaptation gap, not a provenance failure.

### 3.3 Minimal host-compatible layout: PASS

Temporary symlinks were added only inside the git-ignored `.agents` tree of
`wt/d0`:

```sh
cd .agents/skills/swiftui-expert-skill
ln -s skills/swiftui-expert-skill/SKILL.md SKILL.md
ln -s skills/swiftui-expert-skill/references references
ln -s skills/swiftui-expert-skill/scripts scripts

cd ../swiftui-pro
ln -s swiftui-pro/SKILL.md SKILL.md
ln -s swiftui-pro/references references
```

Results from `wt/d0`:

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

The symlinks were removed after the test. No host-global configuration was
modified. No model generation was used; `omp read skill://...` is the host's own
skill resolution path.

## 4. Interpretation

| Claim | Status | Evidence |
| --- | --- | --- |
| Exact pins, licences, provenance | PASS | `--check-only`, upstream latest, MIT files |
| Skill files installed in a project worktree | PASS (`wt/d0`) | installed trees + hashes |
| Host discovers project skills **as installed** | FAIL | `Unknown skill` for both |
| Host discovers project skills with minimal layout adaptation | PASS | `omp read` for both skills and references |
| Host discovers skills in a worktree without `.agents` | NOT_APPLICABLE / expected absent | integration worktree has no `.agents` |
| Model actually used the skill in a task | NOT_VERIFIED | no task execution claimed |
| Forma runtime/build dependency | NOT_PRESENT | advisory files only; not in Package.swift/app |

## 5. Minimal adaptation plan (not implemented by this PR)

1. Install per active worktree; `.agents/` is git-ignored and not shared.
2. After installation, expose the entry layout the host expects:
   - `<name>/SKILL.md` at the skill root;
   - `references/`, `scripts/`, `assets/`, `agents/` accessible from that root.
   Either flatten the installed skill directory or add relative symlinks as in
   §3.3. Do not copy the pin into product code.
3. Re-run `install_skills.sh --check-only` and `omp read skill://<name>` in the
   worktree. Only a successful `omp read` plus a task-level use may be called
   adopted. Installation alone is not adoption.
4. If a future host does not support project-level discovery, record
   `SKILLS_HOST_VERIFICATION = BLOCKED` and do not modify global host settings
   without Owner authorization.
5. Implement the installer layout change in a separate reviewed PR after Owner
   approval. This PR only records the evidence.

## 6. Boundaries

- No change to PR #161, `FormaCore`, `FormaApp`, CI, `skills.lock.json`, ADS pin
  or global host configuration.
- No Provider call, no DEVONthink access, no production archive operation.
- macOS GUI, VoiceOver, Light/Dark and Instruments remain Mac-only
  `NOT_VERIFIED`; this document does not claim them.
