#!/bin/bash
# Exercise scripts/m11_apfs_fixture.sh on a real macOS APFS volume.
#
# This is the test that a green CI never proved: a shell tool that is only
# syntax-checked can still fail on its first real `build` (the first version
# wrote into directories it had never created) or pollute the data it
# fingerprints (the first version wrote its stamps inside the scanned tree).
# Every case below runs the real commands against a temporary fixture and
# asserts the documented behaviour. Nothing here touches a business directory.
#
# Exit codes:
#   0  every case passed
#   1  at least one case failed, or the environment cannot support the test
#
# On a non-macOS platform the cases are not run and the script says so instead
# of claiming a pass.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TOOL="$SCRIPT_DIR/m11_apfs_fixture.sh"
MARKER=.forma-m11-owner

PASSED=0
FAILED=0
declare -a FAILURES=()

pass() { PASSED=$((PASSED + 1)); printf 'PASS  %s\n' "$1"; }

fail() {
    FAILED=$((FAILED + 1))
    FAILURES+=("$1")
    printf 'FAIL  %s\n' "$1"
    if [ -n "${2:-}" ]; then printf '      %s\n' "$2"; fi
}

# `expect_exit <code> <label> <command…>` runs the command, requires that exact
# exit status, and prints the captured output when it differs.
expect_exit() {
    local want=$1 label=$2 out rc
    shift 2
    out=$("$@" 2>&1)
    rc=$?
    if [ "$rc" = "$want" ]; then
        pass "$label"
    else
        fail "$label" "expected exit $want, got $rc: $out"
    fi
}

if [ "$(uname -s)" != "Darwin" ]; then
    printf 'SKIPPED: this harness needs macOS (real APFS volume + BSD stat/diskutil)\n'
    exit 0
fi

# `diskutil info <dir>` fails on some macOS versions ("Could not find disk"), so
# the device is resolved through `df` first, exactly as the tool itself does.
probe_device=$(df -P "${RUNNER_TEMP:-/tmp}" 2>/dev/null | awk 'NR==2 {print $1}')
if [ -z "${probe_device:-}" ] || ! diskutil info "$probe_device" >/dev/null 2>&1; then
    printf 'ENVIRONMENT: cannot describe the temp volume (%s); cannot claim an APFS run\n' \
        "${probe_device:-no-device}"
    exit 1
fi

PARENT=$(mktemp -d "${RUNNER_TEMP:-/tmp}/m11-apfs-harness.XXXXXX") || {
    printf 'ENVIRONMENT: mktemp failed\n'
    exit 1
}
cleanup() {
    chmod -R u+rwX "$PARENT" 2>/dev/null || true
    rm -rf "$PARENT"
}
trap cleanup EXIT

FIXTURE=$PARENT/apfs-fixture
STATE=$PARENT/.forma-m11-apfs

printf 'parent=%s\n' "$PARENT"
df -P "$PARENT"
diskutil info "$probe_device" | grep -E 'File System Personality|Read-Only' || true

# --- 1. first build ---------------------------------------------------------
expect_exit 0 "build creates the fixture on the first run" bash "$TOOL" build "$PARENT"
ok_parents=1
for p in "01-项目/投标-说明.pdf" "02-售前/报价-2026.xlsx" "02-售前/sub/.DS_Store" \
    "03-项目文件/会议记录.docx" "04-笔记/随手记.txt" "05-应用/使用说明.pdf" \
    "06-cache/CACHEDIR.TAG" "06-cache-2/keep.pdf" "06-cached-docs/manual.pdf" \
    "07-repo/README.md" ".hidden/config.txt" "09-locked/secret.txt" "10-locked-dir"; do
    [ -e "$FIXTURE/$p" ] || { ok_parents=0; printf '      missing %s\n' "$p"; }
done
if [ "$ok_parents" = 1 ]; then
    pass "every documented parent directory and nested path exists"
else
    fail "every documented parent directory and nested path exists"
fi
if [ ! -e "$FIXTURE/.forma-stamp-build" ] && [ ! -e "$FIXTURE/.forma-stamp-before" ] \
    && [ ! -e "$FIXTURE/.forma-stamp-after" ]; then
    pass "no stamp file is written inside the scanned tree"
else
    fail "no stamp file is written inside the scanned tree"
fi
if [ -f "$STATE/manifest" ] && [ -f "$STATE/token" ] && [ -d "$STATE/stamps" ]; then
    pass "tool state (manifest, token, stamps) lives beside the fixture"
else
    fail "tool state (manifest, token, stamps) lives beside the fixture"
fi
if [ -f "$FIXTURE/$MARKER" ] && [ "$(cat "$FIXTURE/$MARKER")" = "$(cat "$STATE/token")" ]; then
    pass "ownership marker carries the state token"
else
    fail "ownership marker carries the state token"
fi

# --- 2. build twice ---------------------------------------------------------
sentinel=$(cat "$FIXTURE/01-项目/投标-说明.pdf")
expect_exit 1 "second build is refused" bash "$TOOL" build "$PARENT"
if [ "$(cat "$FIXTURE/01-项目/投标-说明.pdf")" = "$sentinel" ]; then
    pass "second build did not overwrite the existing tree"
else
    fail "second build did not overwrite the existing tree"
fi

# --- 3. unchanged before/after ---------------------------------------------
expect_exit 0 "stamp before" bash "$TOOL" stamp "$FIXTURE" before
expect_exit 0 "stamp after (unchanged)" bash "$TOOL" stamp "$FIXTURE" after
expect_exit 0 "compare unchanged stamps is identical" bash "$TOOL" compare "$FIXTURE" before after
expect_exit 1 "stamp refuses to replace an existing tag" bash "$TOOL" stamp "$FIXTURE" before
expect_exit 1 "stamp refuses an unsafe tag" bash "$TOOL" stamp "$FIXTURE" '../escape'
expect_exit 1 "compare refuses an unknown tag" bash "$TOOL" compare "$FIXTURE" before nowhere

if [ "$(head -1 "$STATE/stamps/before.tsv")" = '#forma-m11-stamp-v2' ]; then
    pass "stamp carries a versioned header"
else
    fail "stamp carries a versioned header"
fi

# --- 4. modification, deletion, addition, metadata --------------------------
printf 'changed\n' >"$FIXTURE/01-项目/投标-说明.pdf"
expect_exit 0 "stamp after content edit" bash "$TOOL" stamp "$FIXTURE" edited
expect_exit 1 "compare detects a content change" bash "$TOOL" compare "$FIXTURE" before edited

rm -f "$FIXTURE/04-笔记/随手记.txt"
expect_exit 0 "stamp after deletion" bash "$TOOL" stamp "$FIXTURE" deleted
expect_exit 1 "compare detects a deletion" bash "$TOOL" compare "$FIXTURE" before deleted

printf 'new\n' >"$FIXTURE/05-应用/新增.pdf"
expect_exit 0 "stamp after addition" bash "$TOOL" stamp "$FIXTURE" added
expect_exit 1 "compare detects an addition" bash "$TOOL" compare "$FIXTURE" before added

chmod 600 "$FIXTURE/06-cache-2/keep.pdf"
expect_exit 0 "stamp after mode change" bash "$TOOL" stamp "$FIXTURE" mode
expect_exit 1 "compare detects a mode change" bash "$TOOL" compare "$FIXTURE" before mode

touch -t 202001010000 "$FIXTURE/06-cached-docs/manual.pdf"
expect_exit 0 "stamp after mtime change" bash "$TOOL" stamp "$FIXTURE" mtime
expect_exit 1 "compare detects an mtime change" bash "$TOOL" compare "$FIXTURE" before mtime

# --- 5. symlinks and unreadable entries ------------------------------------
if grep -q "$(printf '^escape\tlink\t')" "$STATE/stamps/before.tsv" \
    && ! grep -q 'escape/secret.pdf' "$STATE/stamps/before.tsv"; then
    pass "symlink is recorded as a link and its target is not walked"
else
    fail "symlink is recorded as a link and its target is not walked"
fi
if grep -q "$(printf '^loop-a\tlink\t')" "$STATE/stamps/before.tsv"; then
    pass "a symlink cycle is fingerprinted as two links, not as a walk"
else
    fail "a symlink cycle is fingerprinted as two links, not as a walk"
fi
if [ -f "$PARENT/apfs-outside/secret.pdf" ] \
    && [ "$(cat "$PARENT/apfs-outside/secret.pdf")" = "outside" ]; then
    pass "the escape target is untouched by stamping"
else
    fail "the escape target is untouched by stamping"
fi
if grep -q 'UNREADABLE' "$STATE/stamps/before.tsv" \
    && grep -q "$(printf 'unreadable-dir')" "$STATE/stamps/before.tsv"; then
    pass "unreadable file and unreadable directory are recorded explicitly"
else
    fail "unreadable file and unreadable directory are recorded explicitly"
fi

# --- 6. ownership and path refusals ---------------------------------------
mkdir -p "$PARENT/foreign"
expect_exit 1 "stamp refuses a tree with no ownership state" bash "$TOOL" stamp "$PARENT/foreign" before
expect_exit 1 "clean refuses a tree with no ownership state" bash "$TOOL" clean "$PARENT/foreign"

mkdir -p "$PARENT/Library/CloudStorage/fake"
expect_exit 1 "build refuses a CloudStorage path" bash "$TOOL" build "$PARENT/Library/CloudStorage/fake"
mkdir -p "$PARENT/OneDrive/fake"
expect_exit 1 "build refuses an OneDrive path" bash "$TOOL" build "$PARENT/OneDrive/fake"

cp "$FIXTURE/$MARKER" "$PARENT/marker.bak"
printf 'forged\n' >"$FIXTURE/$MARKER"
expect_exit 1 "clean refuses a forged ownership marker" bash "$TOOL" clean "$FIXTURE"
cp "$PARENT/marker.bak" "$FIXTURE/$MARKER"

rm -f "$FIXTURE/$MARKER"
expect_exit 1 "clean refuses a fixture whose marker is missing" bash "$TOOL" clean "$FIXTURE"
cp "$PARENT/marker.bak" "$FIXTURE/$MARKER"

ln -s "$FIXTURE" "$PARENT/fixture-link"
expect_exit 1 "stamp refuses a symlinked fixture path" bash "$TOOL" stamp "$PARENT/fixture-link" before
expect_exit 1 "clean refuses a symlinked fixture path" bash "$TOOL" clean "$PARENT/fixture-link"
rm -f "$PARENT/fixture-link"

# --- 7. clean ---------------------------------------------------------------
mkdir -p "$PARENT/unrelated-data"
expect_exit 0 "clean removes the owned trees" bash "$TOOL" clean "$FIXTURE"
if [ ! -e "$FIXTURE" ] && [ ! -e "$PARENT/apfs-outside" ] && [ ! -e "$STATE" ]; then
    pass "clean removed the fixture, the outside directory and the tool state"
else
    fail "clean removed the fixture, the outside directory and the tool state"
fi
if [ -d "$PARENT/unrelated-data" ] && [ -d "$PARENT/foreign" ]; then
    pass "clean left unrelated siblings untouched"
else
    fail "clean left unrelated siblings untouched"
fi
expect_exit 1 "clean refuses to run twice" bash "$TOOL" clean "$FIXTURE"

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
    printf 'failures:\n'
    for name in "${FAILURES[@]}"; do printf '  - %s\n' "$name"; done
    exit 1
fi
exit 0
