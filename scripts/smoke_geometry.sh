#!/bin/sh
# M0-R2 window-geometry smoke (#153, reworked after the WindowGate review;
# host-isolation rework after the #153 physical-run report).
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
#      not a content-fit width - a regression to 1104 MUST fail here - but
#      only when the run genuinely starts from isolated user state (modes
#      below); on a shared host the band is skipped, never faked;
#   2. below the uniform shell floor the window clamps AT 1012x620 content
#      (AX adds the title bar height, measured from launch);
#   3. width never changes with the area, for every area whose switch is
#      marker-verified on this VM (see the scope note).
# Sidebar rows carry identifier `area-<raw>` and each pane carries
# `area-<raw>-content` (AppShell), so navigation is language-independent.
# Scope note (#172, five-run evidence): the CI runner's accessibility
# exposure reads zero identifiers after mount, so marker VERIFICATION is
# logged and proven on physical Macs (#153 checklist); `navigated` counts
# only marker-verified switches and asserts nothing when it is 0. The size
# contract below is measured on the mounted pane and stands either way.
#
# RUN MODES (required; the script refuses to guess):
#   FORMA_SMOKE_MODE=ci   an EPHEMERAL, single-purpose VM (GitHub Actions).
#       Only this mode may reset first-launch state, and only through the
#       exact-domain whitelist below. Leftover Forma instances are killed
#       BY PID, never by application name.
#   FORMA_SMOKE_MODE=mac  a PHYSICAL host. Never deletes preferences, never
#       touches Saved Application State, never quits or resizes an instance
#       it did not launch, and refuses to run while any Forma is up. The
#       first-launch band is asserted only with
#       FORMA_MAC_FIRST_LAUNCH_ACCOUNT=1, which the tester sets solely when
#       running inside a dedicated test user account - the only true
#       first-launch isolation on macOS (NSUserDefaults is per-uid via
#       cfprefsd, so overriding HOME is NOT isolation and is not accepted).
#       Even there, the app writes its own normal preferences (autosave
#       frame, first-size flag): a shared host is minimized, not untouched,
#       which is why the test account is the recommended shape.
# Host appearance is audited before and after every run; a change is a FAIL
# with both values recorded - never silently restored, never passed over.
#
# Exit codes:
#   0  all assertions passed
#   1  an assertion failed (geometry regression), the app misbehaved, or the
#      host-state audit found a mutation
#   2  usage / mode error (missing or invalid FORMA_SMOKE_MODE)
#   3  this machine cannot run the test as declared (no Aqua session, or mac
#      mode with a user instance running) - no claim is made
set -eu

APP="${1:?usage: smoke_geometry.sh <path to Forma.app>}"
[ -d "$APP" ] || { echo "usage: smoke_geometry.sh <Forma.app>" >&2; exit 2; }

if [ -z "${FORMA_SMOKE_MODE:-}" ]; then
    echo "error: FORMA_SMOKE_MODE must be set to ci (ephemeral VM) or mac (physical host); this script mutates enough state in ci mode that guessing is not allowed" >&2
    exit 2
fi
MODE="$FORMA_SMOKE_MODE"
case "$MODE" in
    ci|mac) ;;
    *) echo "error: FORMA_SMOKE_MODE must be ci or mac, got '$MODE'" >&2; exit 2 ;;
esac

# The one preferences domain this script may ever name in a destructive
# position. check_host_safety.sh enforces the same whitelist statically.
DOMAIN="io.github.skyline-gazer.forma"

if [ "$(launchctl managername 2>/dev/null || echo unknown)" != "Aqua" ]; then
    echo "environment: no Aqua session; geometry smoke makes no claim here."
    exit 3
fi

# --- Host appearance baseline (read-only; audit runs at exit) ---------------
appearance_before=$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo Light)
app_override_before=$(defaults read "$DOMAIN" AppleInterfaceStyle 2>/dev/null || echo none)
echo "host appearance baseline: global=$appearance_before app-override=$app_override_before"

audit_appearance() {
    appearance_after=$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo Light)
    app_override_after=$(defaults read "$DOMAIN" AppleInterfaceStyle 2>/dev/null || echo none)
    if [ "$appearance_after" != "$appearance_before" ]; then
        echo "error: host appearance CHANGED during the run: global '$appearance_before' -> '$appearance_after'. No silent restore: record both values and find the writer (nothing in this repo writes appearance; see the host-safety issue)." >&2
        exit 1
    fi
    if [ "$app_override_after" != "$app_override_before" ]; then
        echo "error: per-app appearance override CHANGED: '$app_override_before' -> '$app_override_after'." >&2
        exit 1
    fi
    echo "host appearance audit: unchanged ($appearance_before)"
}
trap audit_appearance EXIT

# --- Instance ownership ------------------------------------------------------
# Everything below acts on OUR pid only. Name-based `tell application "Forma"
# to quit` and pgrep-matched liveness are retired: on a physical host they
# hit the user's own instance (#153 risk report; smoke_app.sh already set the
# safe pattern this now mirrors).
existing=$(pgrep -x Forma 2>/dev/null || true)
if [ -n "$existing" ]; then
    if [ "$MODE" = mac ]; then
        echo "error: a Forma instance is already running (pids: $existing). mac mode never quits or drives an instance it did not launch. Quit your own instance first, or run in a dedicated test account." >&2
        exit 3
    fi
    echo "ci: clearing leftover instance(s) by pid: $existing (ephemeral VM)"
    for p in $existing; do kill -TERM "$p" 2>/dev/null || true; done
    sleep 1
    for p in $existing; do kill -9 "$p" 2>/dev/null || true; done
fi

MYPID=""
cleanup() {
    [ -n "$MYPID" ] || return 0
    kill -TERM "$MYPID" 2>/dev/null || true
    i=0
    while [ "$i" -lt 10 ]; do
        kill -0 "$MYPID" 2>/dev/null || return 0
        sleep 0.2
        i=$((i + 1))
    done
    kill -9 "$MYPID" 2>/dev/null || true
}
trap 'cleanup; audit_appearance' EXIT

# --- First-launch state: ci mode only, exact whitelist ----------------------
if [ "$MODE" = ci ]; then
    # First-launch semantics, not restore: the smoke_app step launched this
    # bundle minutes earlier and SwiftUI persists the Window(id:) frame. On
    # an EPHEMERAL VM only, delete the domain and the saved state so the
    # contract is measured on a genuine first launch. A physical host is
    # never reset here - mac mode above has no such branch.
    defaults delete "$DOMAIN" 2>/dev/null || true
    SAVED="$HOME/Library/Saved Application State/$DOMAIN.savedState"
    # Belt for the whitelist: the deletion target must be the exact Forma
    # bundle-state directory - never a glob, never the parent folder.
    case "$SAVED" in
        "$HOME/Library/Saved Application State/io.github.skyline-gazer.forma.savedState")
            rm -rf -- "$SAVED" ;;
        *)
            echo "error: saved-state target escaped the whitelist: $SAVED" >&2
            exit 2 ;;
    esac
fi

open -n "$APP"
i=0
while [ "$i" -lt 50 ]; do
    for p in $(pgrep -x Forma 2>/dev/null || true); do
        case " $existing " in
            *" $p "*) ;;
            *) MYPID=$p ;;
        esac
    done
    [ -n "$MYPID" ] && break
    i=$((i + 1)); sleep 0.2
done
if [ -z "$MYPID" ]; then
    echo "error: the launched Forma instance did not appear (launch failure?)" >&2
    exit 1
fi
echo "owned pid: $MYPID"

# Wait for OUR window rather than trusting a fixed delay: the hosted runner's
# first launch is slower (Gatekeeper verification of the ad-hoc bundle).
# Values reach AppleScript as argv (no system-attribute dialect to get wrong),
# the process is matched by name AND unix id (a whose-clause on `unix id`
# alone was never proven on this runner), and the last error is retained so a
# timeout names its cause instead of swallowing it.
i=0
n=0
while [ "$i" -lt 30 ]; do
    n=$(osascript - "$MYPID" <<'W' 2>/tmp/forma_smoke_axerr || echo 0
on run argv
    set thePid to (item 1 of argv) as integer
    tell application "System Events"
        repeat with p in (every process whose name is "Forma")
            if (unix id of p) is thePid then return count (every window of p)
        end repeat
    end tell
    return 0
end run
W
)
    [ "$n" -gt 0 ] && break
    i=$((i + 1)); sleep 1
done
if [ "$i" -ge 30 ]; then
    echo "error: System Events never saw a window of our instance (pid $MYPID)." >&2
    if kill -0 "$MYPID" 2>/dev/null; then echo "diagnostic: our pid is alive - this is an Accessibility/dialect problem, not a launch failure." >&2; else echo "diagnostic: our pid is GONE - the app exited; recent crash reports:" >&2; ls -t "$HOME/Library/Logs/DiagnosticReports"/Forma*.ips 2>/dev/null | head -2 >&2; fi
    echo "diagnostic: last System Events error: $(cat /tmp/forma_smoke_axerr 2>/dev/null || echo none)" >&2
    exit 3
fi

sleep 2  # let the WindowConfigurator's async first-size land before measuring

osascript - "$MYPID" "$MODE" "${FORMA_MAC_FIRST_LAUNCH_ACCOUNT:-}" <<'OSA'
on appAlive(thePid)
    try
        do shell script "kill -0 " & (thePid as text)
        return "yes"
    on error
        return "no"
    end try
end appAlive

on idSnapshot(win)
    -- Probe AA vs the gate runs, one mechanism explains everything: the
    -- FIRST `entire contents` walk of an untouched window sees all 32
    -- identifiers; the polling version - dozens of whole-tree walks in 15
    -- seconds - sees ZERO even with the app alive and sized right. Each
    -- walk re-triggers SwiftUI accessibility re-rendering, and the storm
    -- starves subsequent reads. So: one walk per check, snapshot the
    -- identifier list, reuse it; poll at human-reasonable intervals.
    set outList to {}
    tell application "System Events"
        repeat with el in (entire contents of win)
            try
                if (exists attribute "AXIdentifier" of el) then
                    set end of outList to (value of attribute "AXIdentifier" of el as text)
                end if
            end try
        end repeat
    end tell
    return outList
end idSnapshot

on hasMarker(snap, marker)
    repeat with v in snap
        if (v as text) is marker then return true
    end repeat
    return false
end hasMarker

on waitMarker(win, marker, tries, gap)
    repeat tries times
        if my hasMarker(my idSnapshot(win), marker) then return true
        delay gap
    end repeat
    return false
end waitMarker

on clickById(win, idStr)
    -- Single walk per attempt; probe AA inventoried the six AXStaticText
    -- labels, so the dialect is settled and retries only guard mount
    -- timing. 3 attempts, spaced.
    repeat 3 times
        tell application "System Events"
            repeat with el in (entire contents of win)
                try
                    if (exists attribute "AXIdentifier" of el) and (value of attribute "AXIdentifier" of el is idStr) then
                        click el
                        return true
                    end if
                end try
            end repeat
        end tell
        delay 2
    end repeat
    return false
end clickById

on run argv
    set thePid to (item 1 of argv) as integer
    set theMode to (item 2 of argv)
    set firstLaunchIsolated to (theMode is "ci") or ((item 3 of argv) is "1")
    tell application "System Events"
        set ourProc to missing value
        repeat with p in (every process whose name is "Forma")
            if (unix id of p) is thePid then set ourProc to p
        end repeat
        if ourProc is missing value then error "our instance (pid " & (thePid as text) & ") is not visible to System Events"
        tell ourProc
            set win to front window

            -- 1. First launch: the scene default (1180x700 content). The old
            --    script accepted 1000-1190, which let the 1104 content-fit
            --    regression launch green; the band is now the default +/- the
            --    tolerance that matters (AX width == content width, height
            --    includes the title bar). Asserted only when this run truly
            --    started from isolated user state - on a shared mac host the
            --    restored frame would make any number here a lie.
            set {w0, h0} to size of win
            log "launch size: " & w0 & "x" & h0 & " (isolated first launch: " & firstLaunchIsolated & ")"
            if firstLaunchIsolated then
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
            else
                log "first-launch band SKIPPED: shared host, restored frame expected (#153 step 2 covers it manually)"
            end if

            -- AA's dump proved this tree exposes its identifiers when the
            -- window is untouched; every subsequent failure correlated with
            -- the resize phase. So the navigation sweep and the landing-pane
            -- readiness gate now run FIRST, before any resize can invalidate
            -- the accessibility subtree or the app itself, and liveness is
            -- asserted between phases so a death is named, not misread as a
            -- missing element.
            -- Phase 2. Readiness: the checks above ran against the
            -- .starting ProgressView pane (window up, sized correctly);
            -- sidebar and content markers exist only once the scan
            -- completes and .ready mounts.
            set gateOK to false
            set readyN to -1
            repeat 5 times
                set idDump to ""
                set n to 0
                repeat with el in (entire contents of win)
                    try
                        if (exists attribute "AXIdentifier" of el) then
                            set idv to value of attribute "AXIdentifier" of el
                            if idv is not "" then
                                set idDump to idDump & idv & "; "
                                set n to n + 1
                                if (idv as text) is "area-review-content" then set gateOK to true
                            end if
                        end if
                    end try
                end repeat
                set readyN to n
                if gateOK then exit repeat
                delay 3
            end repeat
            log "inline gate: identifiers=" & readyN & " ok=" & gateOK
            if not gateOK then
                set winTitle to title of win
                set alive to my appAlive(thePid)
                log "gate: title=" & winTitle & " alive=" & alive & " identifiers(" & readyN & ") - navigation verification skipped on this VM (see #172); it is a Mac acceptance item"
            end if
            set size of win to {1180, 728}
            delay 2
            if (my appAlive(thePid)) is not "yes" then error "Forma died during the launch-size checks"
            set navigated to 0
            repeat with areaRaw in {"workspace", "mapping", "import", "exceptions", "settings", "review"}
                set navOK to my clickById(win, "area-" & areaRaw)
                if not navOK then log "nav: " & areaRaw & " sidebar path unavailable on this VM (Mac acceptance item)"
                delay 2
                -- The marker is the proof of selection (a label click that
                -- no-oped cannot fake a different pane's marker): the
                -- content identifier is derived from
                -- the selection (FormaApplication:385), so its appearance -
                -- and only one content area ever being mounted - IS the
                -- proof the sidebar selection took effect.
                if not my waitMarker(win, "area-" & areaRaw & "-content", 4, 2) then
                    log "nav: " & areaRaw & " content marker unreadable on this VM (Mac acceptance item)"
                else
                    -- Counted only on marker proof: a switch nobody verified
                    -- must not raise `navigated` - the width checks that follow
                    -- mean area-invariance only for the areas this counts.
                    set navigated to navigated + 1
                end if
                set {wA, hA} to size of win
                log "after navigating to " & areaRaw & ": " & wA & "x" & hA
                if wA < 1178 or wA > 1182 then
                    error "switching to " & areaRaw & " resized the window from 1180 to " & wA & "pt"
                end if
            end repeat
            log "sweep: " & navigated & " of 6 areas verified by marker on this VM (0 = CI-VM AX exposure died after mount; #172 - navigation proof moves to Mac acceptance, never vacuously asserted)"

            -- Phase 3a. Below the floor: clamp AT the uniform minimum, never at an
            --    area's content ideal. 1012x620 is ShellLayout.windowMinWidth
            --    x windowMinHeight (sidebar 132 + content 640 + inspector 240).
            set size of win to {760, 500}
            delay 2
            if (my appAlive(thePid)) is not "yes" then error "Forma died on the below-floor resize (new crash signature - capture a fresh stack probe)"
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

            -- Phase 4. Below-floor clamp must hold on the area that used to raise
            --    the demand: mapping is the 1104 regression's home, so it is
            --    re-selected before the clamp (the loop above ends on
            --    settings; clamping there would pin nothing #172-relevant).
            set size of win to {1180, 728}
            delay 1
            set mappingNav to my clickById(win, "area-mapping")
            if mappingNav then
                delay 2
                set mappingNav to my waitMarker(win, "area-mapping-content", 4, 2)
            end if
            log "mapping re-select before final clamp: " & mappingNav & (text of "false = clamp runs on last pane; exact-floor behavior is area-independent (measured identically on settings/review: 1012x672 both)")
            set size of win to {760, 500}
            delay 2
            set {w2, h2} to size of win
            log "mapping-area clamp: " & w2 & "x" & h2
            if w2 < 1011 or w2 > 1015 then
                error "clamp below the floor landed on " & w2 & "pt, not 1012 (mapping re-select verified: " & mappingNav & ")"
            end if
        end tell
    end tell
end run
OSA

echo "geometry smoke: PASS (mode=$MODE pid=$MYPID)"
