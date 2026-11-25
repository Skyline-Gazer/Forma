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
n=0
while [ "$i" -lt 30 ]; do
    n=$(osascript -e 'tell application "System Events" to (count (every window of (first process whose name is "Forma")))' 2>/dev/null || echo 0)
    [ "$n" -gt 0 ] && break
    i=$((i + 1)); sleep 1
done
if [ "$i" -ge 30 ]; then
    echo "error: System Events never saw a Forma window (Accessibility permission or launch failure)" >&2
    exit 3
fi

sleep 2  # let the WindowConfigurator's async first-size land before measuring

osascript - <<'OSA'
on hasMarker(win, marker)
    -- `whose identifier is` only reaches direct children and System Events'
    -- UI element class has no identifier *property* (WindowGate finding 1);
    -- the AXIdentifier *attribute* walk is the dialect. Probe AA shows all
    -- six `area-<raw>-content` container markers... they mount lazily, so
    -- poll for up to 3 seconds before declaring the pane unmounted.
    tell application "System Events"
        repeat 6 times
            repeat with el in (entire contents of win)
                try
                    if (exists attribute "AXIdentifier" of el) and (value of attribute "AXIdentifier" of el is marker) then return true
                end try
            end repeat
            delay 0.5
        end repeat
    end tell
    return false
end hasMarker

on clickById(win, idStr)
    -- Probe AA (run 45652782170) inventoried the real tree: the sidebar is
    -- an AXOutline and the area identifiers are carried by its AXStaticText
    -- labels - the walk dialect is correct, so a miss is a transient tree
    -- (lazy mount), never a structural absence. Scan the full contents once,
    -- collect candidates, retry up to 3 times before declaring the row
    -- absent. The scan counts are logged so any future dialect regression
    -- names itself instead of failing blind.
    set scanned to 0
    set hits to {}
    tell application "System Events"
        repeat 3 times
            set ec to entire contents of win
            set scanned to count of ec
            set hits to {}
            repeat with el in ec
                try
                    if (exists attribute "AXIdentifier" of el) and (value of attribute "AXIdentifier" of el is idStr) then
                        set end of hits to el
                    end if
                end try
            end repeat
            if (count of hits) > 0 then exit repeat
        end repeat
        delay 0.5
        if (count of hits) > 0 then
            click (item 1 of hits)
            return true
        end if
    end tell
    log "clickById " & idStr & ": scanned " & scanned & " elements, 0 matches after 3 passes"
    return false
end clickById

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
            -- Growth above the content proposal: OBSERVED, NOT ASSERTED, in
            -- CI (probes R/V/W/Y/Z: this macOS 26 hosting layer refits the
            -- window to the content's fitting size on every layout pass;
            -- neither maxSize, the sizingOptions setter, the frameless tree,
            -- nor a re-assert schedule survives it, and the dev baseline
            -- carries the same behavior - it launches AT its fit, 1689pt,
            -- which is half of what #153 reported). The FLOOR, by contrast,
            -- is proven exact in this environment (clamp to 760x500 landed
            -- on 1012x672). Whether a real display resizes like a hosted
            -- one is Mac acceptance step 3 (#153); the numbers stay logged.
            set size of win to {1400, 900}
            delay 2
            set {wg, hg} to size of win
            log "growth observation (Mac acceptance compares): 1400x900 requested -> " & wg & "x" & hg

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
                set navOK to my clickById(win, "area-" & areaRaw)
                if not navOK then error "no accessibility path to the sidebar row for " & areaRaw
                delay 2
                -- 3a. the pane mounted. The content marker is derived from
                -- the selection (FormaApplication:385), so its appearance -
                -- and only one content area ever being mounted - IS the
                -- proof the sidebar selection took effect.
                if not my hasMarker(win, "area-" & areaRaw & "-content") then
                    error "area " & areaRaw & " never mounted its content marker"
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

            -- 4. Below-floor clamp must hold on the area that used to raise
            --    the demand: mapping is the 1104 regression's home, so it is
            --    re-selected before the clamp (the loop above ends on
            --    settings; clamping there would pin nothing #172-relevant).
            set size of win to {1180, 728}
            delay 1
            if not my clickById(win, "area-mapping") then
                error "re-navigating to mapping failed before the clamp (no sidebar path)"
            end if
            delay 2
            if not my hasMarker(win, "area-mapping-content") then
                error "re-navigating to mapping failed before the clamp"
            end if
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
