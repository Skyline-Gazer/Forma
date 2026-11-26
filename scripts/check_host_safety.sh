#!/bin/sh
# Static host-state safety lint (host-safety issue, #153 physical-run report).
#
# The geometry smoke was written for ephemeral CI VMs and carried destructive
# habits with it: name-based app quit, wholesale `defaults delete`, saved-state
# `rm -rf`. Those are fine ONLY inside the whitelisted ci-mode branch of
# smoke_geometry.sh. This lint keeps them out of every automation file in the
# repo, so a future script cannot re-introduce a physical-host mutation
# without failing CI.
#
# Rules (scanned: scripts/*.sh, .github/workflows/*.yml; this file is exempt):
#   R1  no `defaults write` anywhere - nothing here legitimately writes prefs;
#   R2  `defaults delete` only for the exact Forma domain (literal or
#       "$DOMAIN" where the file pins DOMAIN to that literal);
#   R3  no `rm -rf` targeting a Library path or Saved Application State,
#       except the guarded `rm -rf -- "$SAVED"` whose whitelist `case` is
#       verified to exist in the same file;
#   R4  no name-based control of the user's app: `tell application "Forma"
#       to quit`, `pkill`/`killall` naming Forma - automation acts on pids it
#       launched;
#   R5  `AppleInterfaceStyle` may only be READ (appearance is audited, never
#       set).
set -eu
cd "$(dirname "$0")/.."

fail=0
report() { echo "host-safety: FAIL - $1"; fail=1; }

targets() {
    ls scripts/*.sh .github/workflows/*.yml 2>/dev/null | grep -v '^scripts/check_host_safety.sh$'
}

# R1: defaults write anywhere
if out=$(grep -nE 'defaults[[:space:]]+write' $(targets) 2>/dev/null); then
    report "R1 defaults write (preferences must never be written by automation):"
    echo "$out" >&2
fi

# R2: defaults delete only the pinned Forma domain
if out=$(grep -nE 'defaults[[:space:]]+delete' $(targets) 2>/dev/null); then
    bad=$(printf '%s\n' "$out" | grep -vE 'defaults[[:space:]]+delete[[:space:]]+("io\.github\.skyline-gazer\.forma"|"\$DOMAIN"|io\.github\.skyline-gazer\.forma)' || true)
    if [ -n "$bad" ]; then
        report "R2 defaults delete outside the Forma-domain whitelist:"
        echo "$bad" >&2
    fi
    # "$DOMAIN" is only whitelist-grade when the same file pins it.
    for f in $(printf '%s\n' "$out" | cut -d: -f1 | sort -u); do
        if printf '%s\n' "$out" | grep -q '"\$DOMAIN"' &&
           [ "$f" = "$(printf '%s\n' "$out" | grep '"\$DOMAIN"' | cut -d: -f1 | head -1)" ]; then
            if ! grep -qE 'DOMAIN="io\.github\.skyline-gazer\.forma"' "$f"; then
                report "R2 $f deletes \"\$DOMAIN\" without pinning it to the Forma domain"
            fi
        fi
    done
fi

# R3: rm -rf on host Library paths, except the guarded saved-state target
if out=$(grep -nE 'rm[[:space:]]+-rf' $(targets) 2>/dev/null); then
    bad=$(printf '%s\n' "$out" | grep -E 'Saved Application State|\$HOME/Library|~/Library|\$\{HOME\}/Library' || true)
    if [ -n "$bad" ]; then
        report "R3 rm -rf on a host Library path (use the guarded \$SAVED form):"
        echo "$bad" >&2
    fi
    # Any file deleting "$SAVED" must carry the exact-target whitelist case.
    for f in $(printf '%s\n' "$out" | cut -d: -f1 | sort -u); do
        if grep -qE 'rm[[:space:]]+-rf[[:space:]]+--?[[:space:]]+"\$SAVED"' "$f" 2>/dev/null; then
            if ! grep -qF 'io.github.skyline-gazer.forma.savedState")' "$f"; then
                report "R3 $f removes \"\$SAVED\" without the exact-path whitelist case"
            fi
        fi
    done
fi

# R4: name-based control of the user's running app
if out=$(grep -nE 'tell application "Forma" to quit|pkill[[:space:]].*Forma|killall[[:space:]].*Forma' $(targets) 2>/dev/null); then
    report "R4 name-based app control (act on launched pids only):"
    echo "$out" >&2
fi

# R5: AppleInterfaceStyle is read-only
if out=$(grep -nE 'AppleInterfaceStyle' $(targets) 2>/dev/null); then
    bad=$(printf '%s\n' "$out" | grep -vE 'defaults[[:space:]]+read' || true)
    if [ -n "$bad" ]; then
        report "R5 AppleInterfaceStyle outside a defaults read (appearance is audited, never set):"
        echo "$bad" >&2
    fi
fi

if [ "$fail" = 0 ]; then
    echo "host-safety: PASS - no global appearance writes, no unscoped defaults deletes, no user saved-state removal, no name-based app control"
fi
exit "$fail"
