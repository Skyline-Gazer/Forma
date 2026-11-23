# Forma AI-native recovery — DevBox-first implementation plan (2026-11-23)

> **PROPOSED.** Program [#148](https://github.com/Skyline-Gazer/Forma/issues/148). This plan does not change the frozen SPEC, authorize real data/model egress, authorize DEVONthink writing, merge anything, or add mandatory CI gates.

## 0. Verified baseline and constraints

- Forma GitHub `dev`: `006d1ab86b347bff3d6d2aa1eab5bf2916a6d04d` at planning audit. Re-fetch before execution; never overwrite later human commits.
- Repository `main`: `38d455304bc4530b71e584c07de48fc06fd1f293` (stable/release branch; do not push here).
- Existing PRs: [#146](https://github.com/Skyline-Gazer/Forma/pull/146) Review Desk, **DRAFT**; [#147](https://github.com/Skyline-Gazer/Forma/pull/147) first-capture snapshot repair, **DRAFT**. Neither is pre-approved to merge.
- App minimum macOS 14. `FormaApp/Package.swift` Swift language mode 6. GitHub Actions `macos-15` / Xcode 26.3 is compiler authority. The Linux DevBox cannot certify SwiftUI build or native GUI behavior.
- ADS is already consumed on `dev`: `.ads` gitlink + `ads-pin.txt` `16b99f4b49769555acc66a0c57b8cfcb8c8bac60` on `cnb/dev`; `AGENTS.md` refers to it. Historical ADS adoption PASS. Current `.github/workflows/ci.yml` **does not invoke** `scripts/check_ads_pin.py`; this is a distinct integration gap, not “ADS absent”. `main` still predates adoption.
- Existing gate boundary: do not add new required status checks, duplicate macOS CI, branch protections, or ADS pin upgrade without separate reviewed authorization.
- Parent User decision: **no offline requirement**. LLM is the semantic engine. Offline Planner is an internal utility/test fallback, not main product. No real customer data in public repo.

## 1. Work by environment / dependency order

| Sequence | Owner host | Issues | Work | Exit before next stage |
| --- | --- | --- | --- | --- |
| 0 | DevBox | #149 | verify Apple/Skill source and exact SHA/license, project-local rules, ADS pin gap; draft relevant docs; no installed runtime dependency | Reviewable design and adoption PR |
| 1 | DevBox | #145 / PR #147 | evidence binding first-capture regression/fix; preserve content integrity | Core tests, exact-head macOS CI, review; Owner merge **only on authorization** |
| 1 (parallel, independent) | DevBox | #152 | AI-first semantic pipeline/gap, TXT + evidence, fixtures, Provider schema/path; no live cloud request by default | Real bytes→structured proposal mock contract + unknown |
| 2 | DevBox | #150 | one stable App Shell, window geometry/layout, sidebar, toolbar, inspector, language and empty states | Source/tests, macOS CI, readiness to attach review UI |
| 2 (parallel) | DevBox | #151 | os_signpost/test fixtures, detect expensive navigation, state/cancellation regression | reproducible performance test plan; Mac trace reserved for final |
| 3 | DevBox | #144 / PR #146 | reconcile default Review Desk with unified shell and AI-native flow; minimize technical tabs; archive preview as stage | Integrated business journey; macOS CI; not yet “GUI PASS” |
| 4 | DevBox | #148 | integrate all authorized reviewed PRs into candidate dev, generate reproducible build/artifact and checklist | clean exact-HEAD CI (tests/build/package/launch) and no P0 test failure |
| **5** | **Owner MacBook last** | **#153** | foreground app; window drag/navigation/Instruments; GUI screenshots; consented test model if separately authorized; isolated DEVONthink read if authorized | field verdict per item; no production write |

Parallel agents may work in separate branches/worktrees. Parent agent owns interface contract and integrated verification. Do not spawn a new abstraction or independent UI design framework on each feature.

## 2. Skill/HIG adoption strategy

**Authority:** Apple HIG and Apple SwiftUI/AppKit documentation. **One primary engineering Skill:** [AvdLee SwiftUI Expert](https://github.com/AvdLee/SwiftUI-Agent-Skill) @ verified upstream `62bd760f005093d1e2e4de5db156e456a5f96400` (MIT); relevant `macos-scenes`, `macos-window-styling`, `toolbar-patterns`, `state-management`, `view-structure`, `layout-best-practices`, `trace-recording/analysis`. **Optional second independent reviewer:** [Paul Hudson SwiftUI Pro](https://github.com/twostraws/SwiftUI-Agent-Skill) @ `f2920b63995263f57b3e198674e89a602efba6d2` (MIT); invoke only on App Shell/critical correctness PRs with selected reference files.

Before installing a project-scoped skill: confirm the exact commit/commit provenance, license, content tree, supported Agent discovery path, review any scripts (`xctrace` scripts execute only on a Mac with explicit scope). Lock version via recorded commit/reviewed copy or manifest. On Linux use textual guidance only; no npm dependency in Forma runtime, no bundling into app, no Tailwind/React additions. Keep ADS as governance and do not copy third-party Skill rules into ADS Core. Preserve existing deployment target, use `#available` only where needed.

## 3. Existing PR transition rules

**#147:** target shared utility defect; may retain, test and review. No UI/AI semantic creep. Do not merge automatically; Mac proof follows in M0.

**#146:** contains a new `ReviewDeskView` and top-level `整理资料` tab with a default Offline flow. Treat as **experimental code, not final product architecture**. Reuse useful Chinese field/evidence UI, but amend via measured unified-shell plan. Do not merge to dev simply because its current UI builds; avoid six top-level tabs and redundant navigation shell. Rebase/review on latest dev as needed; exact HEAD approval required.

**#138:** retain historical Alpha utility/test route. No further production UI prioritization. **#144** stays the business UX owner, **#145** stays the P0 evidence owner. Do not duplicate issues or close them prematurely.

## 4. AI test corpus (synthetic)

- `abcd.txt` — name opaque, content clearly includes bid project/party/service intent → cite content and propose category.
- `123456.txt` — contents `123456` → Unknown, no invented project.
- `授权函.docx` — misleading title vs actual content; content wins with evidence.
- `报价表.xlsx` — priced tender vs blank template; avoid blind category.
- `solution.pdf` — generic vendor brochure; do not force association.
- Non-extractable/scanned document with unavailable OCR → explicit extraction limitation, not model "low confidence" invented output.

Provider mock fixtures prove schema/validation/error behavior, not model quality. Real quality claims require approved live Provider and a measured gold set.

## 5. Mac-only test pack (deferred)

- 100 navigation switches, 20 sidebar width drags; no unintended `NSWindow.frame` change.
- 6-file and >=1000-file synthetic scenario, median/p95 timings and trace symbol attribution.
- Narrow/normal/wide dimensions; app foreground, window restore, light/dark, toolbar overflow, keyboard/VoiceOver, content bounds.
- First-capture correction succeeds once and survives restart; missing evidence remains rejected.
- Controlled model/provider egress **only after separate Owner approval**, redacted payload and fee budget. Controlled DEVONthink test DB read-only; no production Project_Archive writes.
- Use `PASS / FAIL / BLOCKED / NOT_VERIFIED` for each test with SHA/OS/toolchain, screenshots, traces and evidence location.

## 6. What is not approved

No merging PRs, no pushing main, no new mandatory checks, no ADS version changes, no auto-sending source documents, no DEVONthink write, no touching 991 production records, no new runtime service/RAG/vector infra, no offline-regex classification, no rebranding an untested UI as product acceptance.

## 7. External sources and target
- Apple: [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos), [Split Views](https://developer.apple.com/design/human-interface-guidelines/split-views), [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [SwiftUI Instruments](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance).
- [Forma UI design contract proposal](UI-DESIGN-CONTRACT-PROPOSAL.md)
- [#148 Program](https://github.com/Skyline-Gazer/Forma/issues/148), [#149 D0](https://github.com/Skyline-Gazer/Forma/issues/149), [#150 D1](https://github.com/Skyline-Gazer/Forma/issues/150), [#151 D2](https://github.com/Skyline-Gazer/Forma/issues/151), [#152 D3](https://github.com/Skyline-Gazer/Forma/issues/152), [#153 M0](https://github.com/Skyline-Gazer/Forma/issues/153).
