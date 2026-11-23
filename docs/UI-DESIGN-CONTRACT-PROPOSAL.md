# Forma macOS UI/UX Design Contract — proposal (2026-11-23)

> **Status: PROPOSED / not merged.** Owner field findings are grounded in supplied screenshots; code causes and behavior must be verified by macOS runtime. This document is a project-local UI contract candidate, **not** an ADS core standard, a SPEC amendment, or new required CI gate. Parent program: [#148](https://github.com/Skyline-Gazer/Forma/issues/148).

## 1. Product and user task

Forma is an **AI-native DEVONthink document review/archival assistant**. No Offline First requirement. The user story is: choose a source → scan/extract → AI understand business purpose and project association (with explicit model/egress consent) → review source-backed proposed fields → archive plan preview → separately authorized execution/readback. The user must not be required to understand `Snapshot`, `Manifest`, `Evidence ID`, `hold`, `eligibility` or `Provider requests` for the normal path.

Manual/no-provider drafts can be offered transparently, but the deterministic Offline Planner is a Core utility/test substitute, not a product-level intelligence mode. A file like `abcd.txt` is categorized by **content and context**, never by filename guessing. Unknown stays Unknown.

## 2. Governing platform sources

- [Apple — Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Apple — Windows](https://developer.apple.com/design/human-interface-guidelines/windows)
- [Apple — Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [Apple — Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Apple — Split Views](https://developer.apple.com/design/human-interface-guidelines/split-views)
- [Apple — Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [Apple — NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview)
- [Apple — Customizing window styles and state restoration in macOS](https://developer.apple.com/documentation/swiftui/customizing-window-styles-and-state-restoration-behavior-in-macos)
- [Apple — Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)
- [Apple — WWDC25 Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/)

Official current documentation and supported SDK/deployment target beat third-party Skill advice. Existing target: macOS 14; pinned CI: Xcode 26.3, Swift 6. Avoid iPhone-only prescriptions.

## 3. App shell: owner/consumer contract

| Owner | Stable responsibility | Feature-provided content |
| --- | --- | --- |
| Main Window / Scene | Window chrome; genuinely user-resizable geometry; restoration; global navigation and selection identity | None |
| Sidebar | Current sources/projects/review queues; scope and selection; consistent show/hide/resize semantics | Optional context-specific sections |
| Main content | Full-height document list / preview and normal workflow; no vertical centering of dense tables | Current file, list, search and review stage |
| Inspector | Contextual evidence, AI proposed fields, source excerpts; hide/show, bounded and resizable | Field details, evidence, confidence with caveats |
| Toolbar | Predictable global command placements, consistent icon/labels/overflow; clear contextual primary action | Per-stage actions in reserved locations |
| Status / feedback | Human-readable scan/analysis progress; error next to failed action; advanced diagnosis on demand | Relevant status and recovery |

**Design not implementation mandate:** investigate whether a single shared `NavigationSplitView` around the review workflow fits runtime constraints; don't force Settings into a document three-column form or synthesize an abstraction that would hide AppKit window behavior. The shell owns outer geometry; switching routes changes content, not the window frame.

## 4. Concrete acceptance contracts from Owner screenshots

### Window and split views

- Switching Workspace / Mapping / review / Exceptions / settings must **not** move/resize the outer `NSWindow.frame` without a user/system initiated window operation.
- Sidebar divider drag reallocates available width, cannot drag the outer window along; honor bounded min/ideal/max width and preserve visible content. Keep the window freely resizable—do not mask a bug with `.windowResizability(.contentSize)`.
- Main document list fills its available vertical area, not squeezed between two empty halves; no giant unpurposed spaces. Import planning is a stage within the review/archival journey, not necessarily a separate top-level tab.

### Toolbar / navigation

- Comparable actions use the same control style, location, tooltip and keyboard/VoiceOver meaning. A Profile selector displays its current value or meaningful placeholder; never a blank unlabeled picker.
- No raw technical sentences such as `Let this run leave the machine` as titlebar controls. Privacy consent must be a deliberate action with understandable explanation and clear off/allow state.
- On narrow windows, use appropriate toolbar overflow instead of clipping or silently losing commands.
- Settings/advanced diagnostics are discoverable without dominating the main workflow. `snapshot_changed` → “来源内容已变化，请重新分析” with expandable diagnostic code, subject to correct fault classification.

### Business review

- User can select source, see files, preview readable evidence, inspect/edit 12 Profile-backed metadata fields with business labels, verify citations, save and proceed, inspect planned target and blocked reason; never infer metadata not grounded in evidence.
- Inference/uncertainty/cross-project conflicts remain reviewable. Failed save keeps selection and shows its cause near the relevant field; **first valid correction must work without duplicate scan** (#145).
- File row, AI proposal, evidence and archive plan are consistent under same snapshot/revision; no fabricated permissions or silent external API calls.

## 5. State matrix (target)

| Scenario | User-visible behavior | Engineering evidence |
| --- | --- | --- |
| Source unselected | Single clear “选择资料目录” action | screenshot |
| Source scanned; no analysis | “开始 AI 分析” with provider/consent status | synthetic test + screenshot |
| Consent/key absent | Setup/privacy explanation; no pretend AI result | mock + request-counter=0 |
| Analysis in progress | Progress/cancel with live context intact | test + UI |
| Evidence supported | Business field and sourced excerpt | evidence link/revision test |
| Unknown / contradiction | Review/hold, no automatic archived target | counterexample fixture |
| Snapshot changed | Explicit recovery; no stale correction | #145 regression |
| Provider error / rate limit | Retry when safe; no loss of review state | provider failure fixture |
| Import preview | Non-destructive target/diff and blocked reasons | dry-run test |
| Execution | Only a separately approved write flow | not authorized by this plan |

## 6. Performance and macOS final verification

- DevBox work: source audit, deterministic state tests, synthetic 6/1k+ file fixture, signposts, acceptance script. SwiftUI GUI cannot be built or exercised natively on Linux.
- macOS CI: **build/package/launch smoke**, not GUI acceptance.
- Owner Mac **last only**: narrow/default/wide windows, light/dark, 100 navigation switches, 20 sidebar drags, frame check, view clipping/scroll/keyboard/VoiceOver, First-capture correction, Instruments latency (median/p95) and trace attribution. Set a *target* warm p95 ≤150ms for six-file navigation, not an unmeasured PASS.
- Status vocabulary: PASS / FAIL / BLOCKED / NOT_VERIFIED; record exact SHA, environment, screenshot and trace. No customer content in a public repository.

## 7. Boundaries

No new runtime UI framework, React/Tailwind, forced OS/toolchain upgrade, AI-regex business classifier, real Provider egress or DEVONthink production writes. Retain existing validation/ledger/privacy mechanics and ADS pin; any SPEC/PLAN product amendment requires explicit separate review. Related work: [#144](https://github.com/Skyline-Gazer/Forma/issues/144), [#145](https://github.com/Skyline-Gazer/Forma/issues/145), [#149–#153](https://github.com/Skyline-Gazer/Forma/issues/149).
