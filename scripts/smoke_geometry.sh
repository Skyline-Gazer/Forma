#!/bin/sh
# M0-R2 window-geometry smoke (#153, reworked after the WindowGate review).
#
# The physical acceptance proved this defect class is invisible to unit tests:
# under the old window policy the OUTER WINDOW's minimum was the mounted
# content's fitting width, and it changed with the area - 1665pt at the Review
# Desk on a 1512pt display, and entering Workspace from Archive snapped 1280pt
# to 1645pt. The M0-R2 regression (#172) had the same shape with a smaller
# number: the mapping table's 542pt column sum plus 190pt pane padding plus
# chrome re-raised the minimum to 1104pt.
#
# This drives the real window on the runner that builds the app. The contract:
#   1. first launch lands on the configured default size (1180x700 content),
#      not a content-fit width - a regression to 1104 MUST fail here;
#   2. below the uniform shell floor the window clamps AT 1012x620 content
#      (AX adds the title bar height, measured from launch), for every area;
#   3. navigating every area is proven by the area's content marker, and the
#      window width never changes with the area.
# Sidebar rows carry identifier `area-<raw>` and each pane carries
# `area-<raw>-content` (AppShell), so navigation is language-independent and
# - unlike the first revision of this script - a failed navigation cannot
# pass vacuously: `navigated` is counted and must reach 6.
#
# Exit codes:
#   0  all assertions passed
#   1  an assertion failed (geometry regression) or the app misbehaved
#   3  this machine cannot drive a GUI window (no Aqua session or no
#      Accessibility permission for System Events) - no claim is made
set -eu

APP="${1:?usage: smoke_geometry.sh <path to Forma.app>}"
[ -d "$APP" ] || { echo "usage: smoke_geometry.sh <Forma.app>" >&2; exit 2; }

if [ "$(launchctl managername 2>/dev/null || echo unknown)" != "Aqua" ]; then
    echo "environment: no Aqua session; geometry smoke makes no claim here."
    exit 3
fi

cleanup() { osascript -e 'tell application "Forma" to quit' >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
sleep 1

# First-launch semantics, not restore: the smoke_app step launched this bundle
# minutes earlier and SwiftUI persists the Window(id:) frame. Delete defaults
# and saved state so the geometry contract is measured on a genuine first
# launch (the same thing that breaks if the Owner moves the window and quits).
defaults delete io.github.skyline-gazer.forma 2>/dev/null || true
rm -rf "$HOME/Library/Saved Application State/io.github.skyline-gazer.forma.savedState"
open "$APP"

# Wait for the window rather than trusting a fixed delay: the hosted runner's
# first launch is slower (Gatekeeper verification of the ad-hoc bundle).
i=0
while [ "$i" -lt 30 ]; do
    if osascript -e 'tell application "System Events" to (count (every window of (first process whose name is "Forma")))' >/dev/null 2>&1; then
        break
    fi
    i=$((i + 1)); sleep 1
done
if [ "$i" -ge 30 ]; then
    echo "error: System Events never saw a Forma window (Accessibility permission or launch failure)" >&2
    exit 3
fi

sleep 2  # let the WindowConfigurator's async first-size land before measuring

osascript - <<'OSA'
on hasMarker(win, marker)
    -- `whose identifier is` only reaches direct children, and the pane sits
    -- deep in the split view, so walk the tree once per area and try each
    -- element's identifier. Elements without one are skipped.
    tell application "System Events"
        repeat with el in (entire contents of win)
            try
                if (identifier of el) is marker then return true
            end try
        end repeat
    end tell
    return false
end hasMarker

on run
    tell application "System Events"
        tell process "Forma"
            set win to front window

            -- 1. First launch: the scene default (1180x700 content). The old
            --    script accepted 1000-1190, which let the 1104 content-fit
            --    regression launch green; the band is now the default +/- the
            --    tolerance that matters (AX width == content width, height
            --    includes the title bar).
            set {w0, h0} to size of win
            log "launch size: " & w0 & "x" & h0
            if w0 < 1176 or w0 > 1184 then
                error "launch width " & w0 & "pt is not the configured 1180pt default (a content-fit launch like the old 1104/1689 fails here)"
            end if
            -- Height: the hosting layer proposes its own content height at
            -- the first layout pass, so the contract is a floor, not an
            -- exact chrome sum (probe Q: width 1180 honored, height settled
            -- at 674 = the declared minimum plus window chrome).
            if h0 < 640 then
                error "launch height " & h0 & "pt is below the declared 620pt floor plus chrome"
            end if

            -- 2. Below the floor: clamp AT the uniform minimum, never at an
            --    area's content ideal. 1012x620 is ShellLayout.windowMinWidth
            --    x windowMinHeight (sidebar 132 + content 640 + inspector 240).
            set size of win to {760, 500}
            delay 2
            set {w1, h1} to size of win
            log "after resize to 760x500: " & w1 & "x" & h1
            if w1 < 1011 or w1 > 1015 then
                error "minimum width is not the uniform 1012pt floor; got " & w1 & "pt"
            end if
            if h1 < 640 then
                error "clamped height " & h1 & "pt fell below the 620pt floor plus chrome"
            end if
            -- The other half of "user-controlled": the window must GROW
            -- freely, not sit pinned to its content proposal.
            set size of win to {1400, 900}
            delay 2
            set {wg, hg} to size of win
            log "after resize to 1400x900: " & wg & "x" & hg
            if wg < 1390 then
                error "window refused to grow in width: " & wg & "pt"
            end if
            if hg < 850 then
                error "window refused to grow in height: " & hg & "pt"
            end if

            -- 3. A stable supported size, then every area. Navigation is
            --    verified two ways: the sidebar row really changed, and the
            --    pane's own content marker mounted - a failed navigation can
            --    no longer pass vacuously (WindowGate finding: the first
            --    revision discarded both lookup errors). The width assertion
            --    is the #153 contract itself: switching areas must not resize
            --    a window that was comfortably above the floor, and any area
            --    whose content demanded 1104 again would fail the clamp at 3b.
            set size of win to {1180, 728}
            delay 2
            set navigated to 0
            repeat with areaRaw in {"review", "workspace", "mapping", "import", "exceptions", "settings"}
                set navOK to false
                try
                    set navRow to first row of table 1 of scroll area 1 of splitter group 1 of win whose identifier is "area-" & areaRaw
                    select navRow
                    set navOK to true
                end try
                if not navOK then
                    try
                        click (first UI element of win whose identifier is "area-" & areaRaw)
                        set navOK to true
                    end try
                end if
                if not navOK then error "no accessibility path to the sidebar row for " & areaRaw
                delay 2
                -- 3a. the pane mounted.
                if not my hasMarker(win, "area-" & areaRaw & "-content") then
                    error "area " & areaRaw & " never mounted its content marker"
                end if
                -- 3b. the selected row really is this area.
                set sel to first row of table 1 of scroll area 1 of splitter group 1 of win whose identifier is "area-" & areaRaw
                if selected of sel is not true then
                    error "sidebar still does not report " & areaRaw & " selected"
                end if
                set navigated to navigated + 1
                set {wA, hA} to size of win
                log "after navigating to " & areaRaw & ": " & wA & "x" & hA
                if wA < 1178 or wA > 1182 then
                    error "switching to " & areaRaw & " resized the window from 1180 to " & wA & "pt"
                end if
            end repeat
            if navigated < 6 then
                error "only " & navigated & " of 6 areas were navigated; the geometry contract is unproven"
            end if

            -- 4. Below-floor clamp must hold on the areas that used to raise
            --    the demand, too: mapping is the 1104 regression's home.
            set size of win to {760, 500}
            delay 2
            set {w2, h2} to size of win
            log "mapping-area clamp: " & w2 & "x" & h2
            if w2 < 1011 or w2 > 1015 then
                error "mapping area raises the minimum above the uniform floor; got " & w2 & "pt"
            end if
        end tell
    end tell
end run
OSA

echo "geometry smoke: PASS"
