#!/bin/sh
# M0-R2 window-geometry smoke (#153). The physical acceptance proved the
# product could not reproduce this defect in unit tests: under the old window
# policy the OUTER WINDOW's minimum was the mounted content's fitting width,
# and it changed with the area - 1665pt at the Review Desk on a 1512pt
# display, and entering Workspace from Archive snapped 1280pt to 1645pt.
#
# This is the real UI-level regression, on the same runner that builds the
# app: launch Forma, read its window, resize it, and read what the window
# accepted. The assertions are the contract:
#   - first launch lands on the configured default size, not a content-fit;
#   - the window resizes to the declared shell floor (~1012pt with the
#     sidebar and inspector open) on its own terms;
#   - below the floor it clamps AT the floor, never at some area's preferred
#     width (1335/1645/1665 were the observed failures);
#   - navigating all six areas at a stable width does not resize the window.
# The sidebar rows carry accessibility identifiers `area-<raw>` (AppShell),
# so the navigation step does not depend on the label language.
set -eu

APP="${1:?usage: smoke_geometry.sh <path to Forma.app>}"

osascript - "$APP" <<'OSA'
on run argv
    set appPath to item 1 of argv
    do shell script "open " & quoted form of appPath
    delay 8
    tell application "System Events"
        tell process "Forma"
            set win to front window
            -- First launch: the scene's default size (1180x700), not the
            -- content's fitting width (the failing build filled the 1512pt
            -- screen and wanted 1665pt with the desk mounted).
            set {w0, h0} to size of win
            log "launch size: " & w0 & "x" & h0
            if w0 > 1190 or w0 < 1000 then
                error "launch width " & w0 & "pt is not the configured 1180pt default"
            end if
            if h0 > 710 or h0 < 600 then
                error "launch height " & h0 & "pt is not near the configured 700pt default"
            end if
            -- The window must shrink to the shell floor on its own terms.
            set size of win to {1050, 640}
            delay 2
            set {w1, h1} to size of win
            log "after resize to 1050x640: " & w1 & "x" & h1
            if w1 < 1000 or w1 > 1060 then
                error "window did not accept the floor resize; got " & w1 & "pt"
            end if
            -- Below the floor it clamps at the declared minimum (~1012pt),
            -- never at a per-area content ideal.
            set size of win to {760, 500}
            delay 2
            set {w2, h2} to size of win
            log "after resize to 760x500: " & w2 & "x" & h2
            if w2 < 1000 or w2 > 1040 then
                error "minimum width is not the declared shell floor; got " & w2 & "pt"
            end if
            -- Settle at a stable supported width, then navigate every area.
            set size of win to {1100, 620}
            delay 2
            repeat with areaRaw in {"review", "workspace", "mapping", "import", "exceptions", "settings"}
                try
                    set navRow to first row of table 1 of scroll area 1 of splitter group 1 of win whose identifier is "area-" & areaRaw
                    select navRow
                on error
                    -- Fall back to clicking wherever the row lives.
                    try
                        click (first UI element of win whose identifier is "area-" & areaRaw)
                    end try
                end try
                delay 2
                set {wA, hA} to size of win
                log "after navigating to " & areaRaw & ": " & wA & "x" & hA
                if wA < 1090 then
                    error "switching to " & areaRaw & " shrank the window to " & wA & "pt"
                end if
                if wA > 1110 then
                    error "switching to " & areaRaw & " forced the window to " & wA & "pt"
                end if
            end repeat
        end tell
    end tell
    do shell script "osascript -e 'tell application \"Forma\" to quit'"
end run
OSA
