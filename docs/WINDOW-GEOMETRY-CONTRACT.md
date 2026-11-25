# Window geometry contract (M0-R2, #153)

The one authority for window and pane sizes is the app shell in
`FormaApp/Sources/Forma/FormaApplication.swift`, over the numeric budget in
`Sources/FormaCore/Presentation/ShellLayout.swift`. Business views fill
their pane and adapt inside it; they never dictate the outer window. This
document states the contract the Owner asked to see in writing.

## Supported sizes

| Quantity | Value | Where declared |
| --- | --- | --- |
| Default first-launch size | 1180 × 700 pt | `.defaultSize` on the `Window` scene |
| Window minimum, sidebar + inspector open | **1012 pt** (132 + 640 + 240) | `ShellLayout.windowMinWidth`, declared once on the root frame |
| Window minimum, inspector closed | **1012 pt** | the constant root frame - column state does not change the window minimum |
| Window minimum, sidebar + inspector closed | **1012 pt** | the same; collapsing columns only frees content width above the floor |
| Height minimum | **620 pt** content; user-resizable above it | `ShellLayout.windowMinHeight` on the root frame |
| Width maximum / height maximum | unlimited by the scene; the macOS 26 hosting layer caps programmatic growth at the content's fitting size (#153 pre-existing; Mac acceptance step 3) | `.windowResizability(.contentMinSize)` + `WindowConfigurator` |

The physical reference display is 1512 × 982 pt (MacBookPro18,3). Every
minimum above fits it with margin; the M0-R1 build demanded 1665 pt and
could not be resized at all.

## Why the numbers hold

Under SwiftUI's default scene resizability the window's floor tracks the
mounted content's *fitting* (ideal) width - per area: 1177 (desk) + 488 of
chrome = 1665, 1157 + 488 = 1645 (workspace), 847 + 488 = 1335 (mapping),
837 + 488 = 1325 (diagnostics), 616 + 488 = 1104 (archive/settings). That is
exactly what the Owner measured, and it changed with every area switch.

M0-R2 changed three things, each pinned by `ShellLayoutTests`:

1. `.windowResizability(.contentMinSize)` - the floor is the content's
   *declared minimum*, never its preferred size; growing is always allowed.
2. One uniform content floor (`ShellLayout.areaContentMinWidth`, 640 pt) is
   declared at the shell's area root, so switching areas cannot resize the
   window.
3. Wide tables (mapping rows, exception rows, the two workspace tables)
   keep their per-column minimums but scroll horizontally *inside their own
   `Table`* below the pane width - `Table` owns that scroller, so a column
   sum (mapping's was 542 pt) never becomes a window demand. Only the floor
   the pane itself declares (`ShellLayout.scrollableTableMinWidth`, 280 pt)
   propagates, and every area's `minimumContentWidth(for:)` stays under the
   uniform 640 pt content floor. Nothing scrolls sideways at the window
   level; the desk's HSplitView panes, sidebar and inspector keep their
   declared min / ideal / max column bounds.
4. The `FormaRoot` launch-state switch (`.starting` / `.ready` /
   `.degraded`) mounts behind one constant `.frame(minWidth: 1012,
   minHeight: 620)`, so the window's content minimum is assigned once and
   never re-assigned mid display cycle - the mechanism of the
   `NSDisplayCycleFlush → NSWindow updateConstraintsIfNeeded` SIGTRAP
   (#172, probe run 45596086983; the same stack the Owner hit physically).
   An earlier theory blamed a `ScrollView(.horizontal)` wrapper around
   `Table`; that was disproven - the wrapper never belonged there, and
   removing it did not stop the trap.

## Narrow widths

Below an area's table's column-minimum sum, the table's least-critical
columns leave the visible viewport sideways (local scroll) rather than the
window growing. The sidebar and inspector collapse via their existing
controls (`Toggle Sidebar`, `toggle-inspector`); no business control is
removed - the desk's stage actions (Scan / Build context / AI understanding
/ Manual draft / Review / Export, pinned in `ReviewDeskFlowTests`) are
offered by workflow stage, never by window width.

## Restoration and first launch

`Window(id: "workspace")` persists its frame through SwiftUI state
restoration. A returning user's real size and position are honored (AppKit
keeps the restored frame on-screen). A first launch - or a stored frame the
system discards - gets 1180 × 700 centered; the default is only clamped up
to 1012 pt minimum, which is below it, so first launch lands exactly on the
default. It is not re-centered on every launch.

## What acceptance must observe (CI cannot fully cover)

`scripts/smoke_geometry.sh` (launch-smoke job) drives the real window on the
macOS runner. The assertions, tightened by the #172 review so that nothing
passes vacuously:

- launch width 1180 ±4 (a content-fit launch like the old 1104 fails here),
  height 700 + title bar (chrome measured from the launch, not hardcoded);
- resize to 760 × 500 clamps to 1012 ±2 × (620 + chrome) ±2 - the uniform
  floor, not any area's ideal;
- every area navigation is *verified*: the sidebar element labelled
  `area-<raw>` (probe AA inventoried them as AXStaticText under an
  AXOutline - the hosting bridge does not surface row-level identifiers,
  so the label is the click target) is clicked, and the run only counts the
  area once `area-<raw>-content` appears in the window's accessibility
  tree - the content subtree carries that identifier on every element it
  contains, which doubles as the proof of which pane is mounted. Fewer than
  6 verified areas fail the run;
- the window must GROW to a requested 1400x900 (the "user-controlled" half
  of #153 - a window pinned to its content proposal fails here);
- the mapping area (the 1104 regression's home) is re-selected and re-clamped
  below the floor, and must still land on 1012.

- growth past the content proposal is LOGGED, not asserted: probes
  R/V/W/Y/Z established that this hosting build re-fits the window to the
  content's fitting size on layout passes (dev carries the same behavior at
  its own fit - 1689pt launches in CI - which is precisely the half of #153
  this contract closes by proving the floor: clamps land on 1012x672
  exactly). Real-display resize behavior is Mac acceptance step 3.

If System Events cannot see the window at all (no Aqua session or no
Accessibility permission) the script exits 3 - no claim is made - which is
distinct from the exit 1 an assertion failure produces.

Physical acceptance repeats the same sequence by hand on the Owner's
1512 pt display, and closes the crash: CI reproduced the Owner's exact
`NSDisplayCycleFlush → NSWindow updateConstraintsIfNeeded →
NSView updateConstraintsForSubtreeIfNeeded` trap stack on HEAD with
`.windowResizability(.contentMinSize)`, and the fix is the constant root
minimum above (item 4), not a layout wrapper change.
