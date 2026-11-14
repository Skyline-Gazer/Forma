#!/bin/sh
# Launch one assembled Forma.app and prove it stays alive.
#
# This is the check that the Batch 2A field run was missing: the previous CI job
# verified the signature of a bundle that crashed on launch. The smoke test is
# deliberately narrow — start, stay alive, exit cleanly — because the hosted
# runner has no one to click anything.
#
# Exit codes:
#   0  launched and stayed alive
#   1  failed (did not start, or exited during the observation window)
#   3  no Aqua session: this machine cannot run a GUI app, so no claim is made
set -eu

APP=${1:-}
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "usage: smoke_app.sh <Forma.app>" >&2
    exit 2
fi

EXE="$APP/Contents/MacOS/Forma"
OBSERVE_SECONDS=${OBSERVE_SECONDS:-5}
CRASH_DIR="${HOME}/Library/Logs/DiagnosticReports"

if [ "$(launchctl managername 2>/dev/null || echo unknown)" != "Aqua" ]; then
    echo "environment: no Aqua session (launchctl managername=$(launchctl managername 2>/dev/null || echo unknown))"
    echo "result: SKIPPED — a GUI app cannot be launched in this session; no startup claim is made."
    exit 3
fi

if pgrep -f "$EXE" >/dev/null 2>&1; then
    echo "error: another Forma instance is already running" >&2
    exit 1
fi

collect_crash() {
    echo "== crash reports"
    found=0
    for report in $(ls -t "$CRASH_DIR"/Forma*.ips 2>/dev/null | head -3); do
        found=1
        echo "--- $report"
        # The header plus the faulting thread is enough to see what aborted.
        sed -n '1,40p' "$report" 2>/dev/null || true
    done
    [ "$found" = 1 ] || echo "none found in $CRASH_DIR"
}

cleanup() {
    pid=$1
    # Children first: the app may have started an MCP helper.
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.2
    done
    kill -9 "$pid" 2>/dev/null || true
}

echo "== launch $APP"
open -n "$APP"

pid=""
for _ in $(seq 1 100); do
    pid=$(pgrep -f "$EXE" | head -1 || true)
    [ -n "$pid" ] && break
    sleep 0.2
done

if [ -z "$pid" ]; then
    echo "error: the app did not start" >&2
    collect_crash
    exit 1
fi
echo "pid: $pid"

steps=$((OBSERVE_SECONDS * 5))
i=0
while [ "$i" -lt "$steps" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "error: the app exited during the first ${OBSERVE_SECONDS}s" >&2
        collect_crash
        exit 1
    fi
    sleep 0.2
    i=$((i + 1))
done

echo "alive after ${OBSERVE_SECONDS}s: yes"
cleanup "$pid"

if pgrep -f "$EXE" >/dev/null 2>&1; then
    echo "error: the app is still running after cleanup" >&2
    exit 1
fi
echo "result: PASS — launched and stayed alive for ${OBSERVE_SECONDS}s"
