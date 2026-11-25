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
| Window minimum, sidebar + inspector open | **1012 pt** (132 + 640 + 240) | `ShellLayout.areaContentMinWidth` + column mins |
| Window minimum, inspector closed | 772 pt (132 + 640) | `inspectorColumnWidth(min:)` + toggle |
| Window minimum, sidebar + inspector closed | 640 pt | the uniform content floor |
| Height minimum | ~620 pt content chain; user-resizable above it | pane `minHeight`s |
| Width maximum / height maximum | unlimited | `.windowResizability(.contentMinSize)` |

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
   pane* below that width. Nothing scrolls sideways at the window level; the
   desk's HSplitView panes, sidebar and inspector keep their declared min /
   ideal / max column bounds.

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
macOS runner: launch size ≈ 1180 × 700; accept a resize to 1050 × 640;
clamp at ≈ 1012 pt when asked for 760; and no width change while navigating
all six areas at 1100 pt. Physical acceptance repeats it by hand on the
Owner's 1512 pt display, where the constraint phase crash also reproduced
(after plan export plus area navigation, `NSDisplayCycleFlush →
NSWindow … updateConstraints`): with the window floor no longer recomputed
from each area's content, the live constraint-configuration that re-solved
window constraints on every area switch is removed by construction -
recorded as *risk reduced*, since a display-cycle crash can only be closed
out on the physical machine.
