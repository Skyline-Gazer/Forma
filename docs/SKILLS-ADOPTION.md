# SwiftUI Skill adoption and ADS pin integration (issue #149, D0)

Scope record for the governance slice of program [#148](https://github.com/Skyline-Gazer/Forma/issues/148).
Product behaviour stays in `docs/SPEC.md` (frozen); the UI/layout contract and the DevBox-first
execution plan live in draft PR [#154](https://github.com/Skyline-Gazer/Forma/pull/154)
(`docs/UI-DESIGN-CONTRACT-PROPOSAL.md`, `docs/AI-NATIVE-DEVBOX-FIRST-EXECUTION.md`). This file adds
only third-party guidance provenance and the rule→owner→validation mapping; it deliberately restates
neither document.

## 1. What the layer is, and what it is not

- Machine-readable manifest: [`skills.lock.json`](../skills.lock.json) (pinned commit, licence, scope).
- Installer/verifier: [`scripts/install_skills.sh`](../scripts/install_skills.sh) → `.agents/skills/<name>`,
  which is git-ignored. Nothing is vendored into `FormaCore`, `FormaApp`, `Package.swift` or the app bundle.
- Advisory only. Non-goals, restated from the manifest: no runtime or build dependency, no npm, no
  execution of any helper script shipped inside a skill; a skill never overrides Apple HIG, the pinned
  ADS revision, the macOS 14 minimum or Swift language mode 6; blanket iOS 27 / Swift 6.4 / newer-Xcode
  rules are rejected in review (`#available` only where an API actually needs it); the secondary skill is
  a per-PR reviewer, not a permanent duplicated instruction dump.

## 2. Rule-source hierarchy

1. **Apple** — HIG and Apple framework documentation/Instruments. Highest authority for behaviour.
2. **ADS** — the immutable revision recorded in `ads-pin.txt` and the `.ads` gitlink, consumed by `AGENTS.md`.
   Project-specific SwiftUI exceptions stay here in Forma, never in ADS Core.
3. **Forma project docs** — `docs/SPEC.md`, and the proposed UI contract in PR #154 once accepted.
4. **The two advisory skills below** — guidance for implementation and review only.

Apple sources used in this slice (all six returned HTTP 200 from the DevBox on 2026-11-23; they are the
same set cited in issue #149):
[Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos),
[Windows](https://developer.apple.com/design/human-interface-guidelines/windows),
[Split Views](https://developer.apple.com/design/human-interface-guidelines/split-views),
[Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars),
[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars),
[Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance).
Additional Apple pages referenced in the adoption table (also verified 200 on the same date):
[Layout](https://developer.apple.com/design/human-interface-guidelines/layout),
[Menus](https://developer.apple.com/design/human-interface-guidelines/menus),
[Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback),
[Loading](https://developer.apple.com/design/human-interface-guidelines/loading),
[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility),
[`Picker`](https://developer.apple.com/documentation/swiftui/picker),
[`NavigationSplitView`](https://developer.apple.com/documentation/swiftui/navigationsplitview),
[`toolbar(content:)`](https://developer.apple.com/documentation/swiftui/view/toolbar(content:)).

## 3. Provenance (verified 2026-11-23 on the DevBox, unauthenticated GitHub REST)

| Skill | Upstream | Pinned commit | Licence | Verified how | Use scope |
| --- | --- | --- | --- | --- | --- |
| `swiftui-expert-skill` (declared 5.3.0) | [AvdLee/SwiftUI-Agent-Skill](https://github.com/AvdLee/SwiftUI-Agent-Skill) | [`62bd760f005093d1e2e4de5db156e456a5f96400`](https://github.com/AvdLee/SwiftUI-Agent-Skill/commit/62bd760f005093d1e2e4de5db156e456a5f96400) | MIT (`LICENSE`) | `gh api …/commits/<sha>` object exists ("Bump version to 5.3.0", 2026-11-06); `gh api …/license?ref=<sha>` → SPDX MIT; `git/trees` structure recorded below; `install_skills.sh` re-checks SHA + licence text on install | Primary implementation assistant: macOS scenes/windows, toolbar and inspector placement, state/layout, accessibility, reading xctrace output |
| `swiftui-pro` (declared 2.0.0) | [twostraws/SwiftUI-Agent-Skill](https://github.com/twostraws/SwiftUI-Agent-Skill) | [`f2920b63995263f57b3e198674e89a602efba6d2`](https://github.com/twostraws/SwiftUI-Agent-Skill/commit/f2920b63995263f57b3e198674e89a602efba6d2) | MIT (`LICENSE`) | Same three checks; commit subject "Merge pull request #27 … flatten-plugin-layout" (2026-10-26) | Independent review of key SwiftUI PRs only, restricted to `design`, `data`, `views`, `navigation`, `performance` reference files |

Top-level structure at the pinned commits (recorded, not copied):

- AvdLee: `.agents/ .claude-plugin/ .codex-plugin/ .cursor-plugin/ .github/ AGENTS.md CONTRIBUTING.md
  INSTALLATION.md LICENSE README.md agents/ assets/ llms.txt package.json plugin.json skills/ tests/`, plus a
  root symlink `swiftui-expert-skill → skills/swiftui-expert-skill`. The skill holds `SKILL.md`,
  `agents/`, `assets/`, `scripts/` (`record_trace.py`, `analyze_trace.py`, `instruments_parser/` — xctrace
  helpers, macOS-only, never executed by this installer) and 33 `references/*.md`, of which the macOS-relevant
  subset (`macos-scenes`, `macos-views`, `macos-window-styling`, `toolbar-patterns`, `view-structure`,
  `layout-best-practices`, `state-management`, `environment-patterns`, `focus-patterns`,
  `accessibility-patterns`, `list-patterns`, `scroll-patterns`, `localization`, `performance-patterns`,
  `trace-recording`, `trace-analysis`) is listed in the manifest.
- twostraws: `.claude-plugin/ assets/ CODE_OF_CONDUCT.md LICENSE README.md swiftui-pro/`; `swiftui-pro/` holds
  `SKILL.md` (`metadata.version "2.0.0"`), `agents/`, `assets/`, and 12 `references/*.md`.

**Compatibility finding.** The primary skill's own `SKILL.md` declares itself for "iOS **or** macOS" and ships
iOS-oriented references (`iphone-duo.md`, `liquid-glass.md`, `latest-apis.md`, charts). Forma consumes only the
macOS subset listed above; anything that would raise the baseline above macOS 14 or assume Swift 6.4 / Xcode 27
is out of scope by rule, not by omission. The upstream also ships `.agents/skills/update-swiftui-apis`, a
meta-skill for maintaining that repository — not a Forma rule source.

## 4. Install, verify, bump

```sh
sh scripts/install_skills.sh              # install both skills at the pinned SHA
sh scripts/install_skills.sh --check-only # verify an existing install; writes nothing
sh scripts/install_skills.sh --skill swiftui-pro
```

Executed on the DevBox (Linux) against real GitHub on 2026-11-23, exit 0:

```
SKILL_OK: swiftui-expert-skill @ 62bd760f005093d1e2e4de5db156e456a5f96400 (licence MIT License) -> .agents/skills/swiftui-expert-skill, entry .agents/skills/swiftui-expert-skill/skills/swiftui-expert-skill/SKILL.md
SKILL_OK: swiftui-pro @ f2920b63995263f57b3e198674e89a602efba6d2 (licence MIT License) -> .agents/skills/swiftui-pro, entry .agents/skills/swiftui-pro/swiftui-pro/SKILL.md
```

The installer fetches the pinned object by SHA (`git fetch --depth 1 origin <sha>`, detached) so it cannot
float; it verifies HEAD == pinned, origin == upstream, `LICENSE` present and still carrying the MIT header and
grant sentence, `SKILL.md` present at the recorded `skill_path`, and that the installed copy is unmodified.
Observed fail-closed behaviour (exit 1, nothing pre-existing deleted): a lock whose SHA differs from the install →
`pinned SHA mismatch …`; a well-formed but nonexistent upstream SHA → `upload-pack: not our ref` →
`pinned commit … is not fetchable … (partial install removed)`, and the next run with a corrected lock
reinstalls cleanly; a locally edited skill → `the installed copy was modified locally`.

To change a pin: re-run the three provenance checks above against the new commit, edit `skills.lock.json`,
`rm -rf .agents/skills/<name> && sh scripts/install_skills.sh`, and land it as its own reviewed PR. Never
`git pull` a floating head inside an installed skill.

**Host recognition: NOT_VERIFIED.** Upstream ships its own discovery pointers (`package.json` `pi.skills`,
`.claude-plugin`), so `.agents/skills/<name>/…` is a conventional layout, but no agent host in this
environment was observed loading it. Confirming that Forma's development host actually reads
`.agents/skills` is an Owner-side check, not a CI gate.

## 5. Adoption table: rule → Apple source → implementing owner → validation

"Validation" is split between what a DevBox PR can prove and what only the Owner Mac can prove (M0, #153);
a green CI never proves GUI behaviour.

| Rule (Forma) | Apple source | Implementing owner | Validation |
| --- | --- | --- | --- |
| Window is genuinely user-resizable; switching Workspace/Mapping/Import/Exceptions never changes window or content geometry | Designing for macOS; Windows; Layout; `NavigationSplitView` | D1 #150 (App Shell: `FormaApplication.swift`, scene/`.frame`/minimum sizes, restoration) | DevBox: none (no Swift toolchain). macOS CI: build + package + launch smoke proves it starts only. Field proof: Owner Mac window-drag measurement, M0 #153 |
| One shared sidebar survives every tab; dragging it resizes content, not the whole window | Sidebars; Split Views; `NavigationSplitView` | D1 #150 (single shell; per-tab content only — no private sidebar per view) | macOS CI build/launch; screenshot of the same window across tabs at M0 #153 |
| Toolbar command set is stable across tabs — no empty items, no length drift | Toolbars; `toolbar(content:)` | D1 #150 (toolbar/command placement); #144 desk supplies stage actions | Code review of `ToolbarItem` sets per tab against the #150 contract; macOS CI build; M0 screenshot |
| No blank pickers (Workspace Profile picker) | Menus; `Picker`; Toolbars | D1 #150 (picker presentation/labels); P0 #145 owns `WorkspaceModel.swift` that feeds it — cross-slice, agreed in the program contract | macOS CI build; synthetic-data unit coverage where the label source is in FormaCore; visual confirmation at M0 #153 |
| Errors and status in business language; no raw error codes, internal diagnostics or English egress sentences leaking into toolbar/page | Feedback; Designing for macOS; `AGENTS.md` clarity rules via ADS | #144 (review desk copy), D3 #152 (provider/semantic error taxonomy), D1 #150 (shell chrome) | FormaCore tests on the message/error mapping with synthetic fixtures; review of visible strings; M0 read-through |
| Inspector is contextual, bounded, resizable; evidence and confidence live there, not in the toolbar | Windows; Sidebars; Layout | D1 #150 (inspector container); D3 #152 supplies evidence/confidence payloads | FormaCore evidence-provenance tests (unchanged invariants, #145); macOS CI build; M0 screenshot |
| Keyboard and VoiceOver work on every primary workflow | Accessibility | D1 #150 (shell focus order) + each view owner (#144, D3 #152) | DevBox: none. macOS CI build only. VoiceOver pass on Owner Mac, M0 #153 |
| Empty / error / loading states defined for each stage, no large blank regions | Loading; Feedback; Designing for macOS | D1 #150 (state presentation) against the state matrix in PR #154 §5; #144 desk states; D3 #152 provider-failure states | Synthetic fixtures + FormaCore tests for state selection; macOS CI build; M0 screenshot per state |
| Navigation performance is traceable (tab switch stall visible in 6-file case) | Understanding and improving SwiftUI performance | D2 #151 (os_signpost + deterministic regressions); skill's `trace-recording`/`trace-analysis` read as guidance only | Core/CI tests for the instrumentation path; xctrace traces are macOS-only, never run by the installer; actual Instruments measurement at M0 #153 |

## 6. ADS pin enforcement in CI

`.github/workflows/ci.yml` now runs `python3 scripts/check_ads_pin.py --verify-upstream` as one step of the
existing `test` job (no new job, no new required status check, no pin upgrade), and the stale comment in the
`app` job claiming the check is unwired has been corrected. `--verify-upstream` is used because
`Skyline-Gazer/ADS` is **PUBLIC** (`gh repo view Skyline-Gazer/ADS --json visibility`), so the no-token runner can reach
it — an unauthenticated `git fetch --depth 1 <repo> <sha>` from the DevBox succeeded.

Executed on the DevBox, 2026-11-23, exit 0 for both modes:

```
ADS_PIN_OK: .ads gitlink == ads-pin.txt == 16b99f4b49769555acc66a0c57b8cfcb8c8bac60 (cnb/dev)
```

The same line was observed in the macOS-15 `FormaCore tests` job log of this PR's CI run, i.e. the anonymous
upstream verification also works from the runner, and the `test` job stayed green with the step added.

Semantics: this step fails on gitlink/pin/`.gitmodules`/branch drift, on an absent upstream object, and
distinguishes an unreachable ADS remote (`NOT_VERIFIED`) from a genuine mismatch. A red step is a finding to
fix in a reviewed PR; it must not be silenced by deleting the step or by bumping the pin without review.
Historical ADS adoption (PASS) and recurring CI enforcement are separate claims: the former was already
recorded in `docs/ADS-ADOPTION.md`, the latter is what this change establishes.
This closes readiness item **R-14** in `docs/R1-READINESS.md` ("CI 未接入 ADS pin 检查"); that report is a
point-in-time record and is deliberately left unchanged. Branch protection was checked through the API and
`dev` is not protected, so no required status check was added or altered by this change.

## 7. Deferred and not verified here

- No Swift compile/test evidence from the DevBox (no toolchain, `FormaCore` uses `import Darwin`): macOS CI on
  the PR is the only build authority; its per-job status is recorded in the PR.
- Real Provider calls and DEVONthink read/write: BLOCKED by the program decision in #148; not attempted.
- GUI geometry, VoiceOver, Instruments and screenshot-level acceptance: deferred to M0 (#153).
- `ads-pin.txt`, the `.ads` submodule, `docs/SPEC.md`, `docs/PLAN.md`, `AGENTS.md`: unchanged by this slice.
