#!/bin/bash
# Build, fingerprint and clean one local-APFS fixture tree for the Forma M11
# Level 4 acceptance run (Issue #130).
#
# Why this exists: the 2026-11-19 real-directory run happened on OneDrive
# FileProvider, where 3,157 of 3,357 records were dataless. That leaves local
# APFS entity files, permission failures and error-report paths only partially
# covered. This script prepares a synthetic tree that exercises exactly those
# paths, and fingerprints it before and after the scan so "the scan changed
# nothing" is an observation rather than an assertion.
#
# Layout (everything below one parent directory the caller names):
#
#   <parent>/apfs-fixture          the scan source (only real fixture content)
#   <parent>/apfs-outside          the escape target, a sibling on purpose
#   <parent>/.forma-m11-apfs/      tool state: manifest, ownership token, stamps
#
# Three properties this script is built around:
#
#   1. Ownership is proven, not assumed. `build` mints a random token, writes it
#      to `<parent>/.forma-m11-apfs/token`, records each owned tree's canonical
#      path in `manifest`, and writes `.forma-m11-owner` (same token) inside each
#      owned tree. `stamp`, `compare` and `clean` refuse a tree whose canonical
#      path is not in the manifest or whose marker token differs. `clean` never
#      guesses a sibling: it removes exactly the manifest entries that verify.
#
#   2. Fingerprints live outside the scanned tree. Stamps are written to
#      `<parent>/.forma-m11-apfs/stamps/<tag>.tsv`, so a stamp can never be
#      enumerated by the next one and before/after cannot disagree because of the
#      tool's own writes. The only tool artifact inside the fixture is the
#      ownership marker, which is a real file and therefore one honest record.
#
#   3. Failure is reported, never papered over. Enumeration errors, unreadable
#      digests and unreadable directories are recorded explicitly; an enumeration
#      error that cannot be attributed to a directory this script itself made
#      unreadable aborts the stamp.
#
# Usage:
#   m11_apfs_fixture.sh build   <parent-dir>
#   m11_apfs_fixture.sh stamp   <fixture-dir> <tag>
#   m11_apfs_fixture.sh compare <fixture-dir> <tag-a> <tag-b>
#   m11_apfs_fixture.sh clean   <fixture-dir>
#
# Exit codes (unchanged from the first version):
#   0  the requested operation succeeded
#   1  refused, or the two stamps disagree
#   2  usage error
#   3  unsupported platform (this script only claims macOS + APFS)
#
# `#!/bin/bash` rather than `#!/bin/sh` on purpose: the walk reads NUL-delimited
# paths with `read -d ''`, which BSD `sh` does not provide. macOS ships bash 3.2
# and this script is written for it (no associative arrays, no ${x,,}).
set -euo pipefail

MARKER=.forma-m11-owner
STATE_DIRNAME=.forma-m11-apfs
FIXTURE_DIRNAME=apfs-fixture
OUTSIDE_DIRNAME=apfs-outside
STAMP_HEADER='#forma-m11-stamp-v2'

die() {
    printf 'refused: %s\n' "$1" >&2
    exit "${2:-1}"
}

usage() {
    printf 'usage: %s build <parent-dir> | stamp <fixture-dir> <tag> | compare <fixture-dir> <tag-a> <tag-b> | clean <fixture-dir>\n' \
        "$(basename "$0")" >&2
    exit 2
}

# Stamp tags become file names under the tool state directory, so they are
# validated before use rather than trusted as path fragments.
assert_stamp_tag() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*) die "tag must match [A-Za-z0-9._-]+: $1" ;;
    esac
}

[ "$(uname -s)" = "Darwin" ] || die "macOS only" 3

ACTION=${1:-}
TARGET=${2:-}
[ -n "$ACTION" ] && [ -n "$TARGET" ] || usage

# Everything this script touches must be a writable local APFS volume. A path
# under a cloud sync root would measure FileProvider, which is the opposite of
# what the fixture is for.
assert_local_volume() {
    local path=$1 info
    case "$path" in
        */Library/CloudStorage/*|*/OneDrive*|*/Dropbox/*|*/Google\ Drive/*)
            die "$path is inside a cloud sync root; this fixture must sit on a local APFS volume"
            ;;
    esac
    info=$(diskutil info "$path" 2>/dev/null) || die "diskutil could not describe $path"
    printf '%s\n' "$info" | grep -q 'File System Personality: *APFS' \
        || die "$path is not on an APFS volume"
    if printf '%s\n' "$info" | grep -q 'Read-Only: *Yes'; then
        die "$path is on a read-only APFS volume (a snapshot mount); build the fixture on a writable one"
    fi
    [ -w "$path" ] || die "$path is not writable"
}

# Canonical path of an existing directory, with every symlink resolved. `pwd -P`
# is the portable form; `realpath` is not present on every macOS version.
canonical_dir() {
    local path=$1
    [ -d "$path" ] || return 1
    (cd "$path" && pwd -P) || return 1
}

# A canonical path this script is willing to delete: never `/`, never $HOME,
# never a bare top-level directory.
assert_deletable_path() {
    local path=$1 home=${HOME:-/}
    [ -n "$path" ] || die "empty cleanup target"
    [ "$path" != "/" ] || die "refusing to operate on /"
    [ "$path" != "$home" ] || die "refusing to operate on \$HOME"
    case "$path" in
        /*/*/*) : ;;
        *) die "refusing to operate on a shallow path: $path" ;;
    esac
}

state_dir_for() { printf '%s/%s\n' "$(dirname "$1")" "$STATE_DIRNAME"; }

manifest_for() { printf '%s/manifest\n' "$1"; }

# Verify that $1 is a tree this script created: canonical path recorded in the
# manifest, marker token matching the state token, and not a symlink. Prints the
# state directory on success.
require_owned() {
    local path=$1 canon state expected actual
    if [ -L "$path" ]; then
        die "$path is a symlink; refusing to treat it as an owned tree"
    fi
    canon=$(canonical_dir "$path") || die "not a directory: $path"
    state=$(state_dir_for "$canon")
    [ -d "$state" ] || die "no tool state beside $canon; this tree was not built here"
    [ -f "$(manifest_for "$state")" ] || die "missing manifest in $state"
    [ -f "$state/token" ] || die "missing ownership token in $state"
    expected=$(cat "$state/token")
    grep -qxF -e "$(printf '%s\tfixture\t%s' "$expected" "$canon")" \
                  -e "$(printf '%s\toutside\t%s' "$expected" "$canon")" \
        "$(manifest_for "$state")" || die "$canon is not recorded as owned by $state"
    [ -f "$canon/$MARKER" ] || die "$canon has no $MARKER; ownership cannot be proven"
    actual=$(cat "$canon/$MARKER")
    [ "$actual" = "$expected" ] || die "$canon marker token does not match the state token"
    printf '%s\n' "$state"
}

# One canonical line per entry, tab separated, with the path quoted by bash's %q
# so a name containing tabs, newlines or non-ASCII bytes cannot break the format:
#
#   <quoted rel path> <kind> <size|-> <mode> <flags> <mtime> <ctime> <digest|-> <link target|->
#
# Symlinks are never followed (`find` without -L, and the type is read from
# `stat` before anything else is consulted). An unreadable digest is written as
# the literal `UNREADABLE`, never as an empty field that a later comparison would
# read as a content change.
stamp_tree() {
    local root=$1 out=$2 err=$3 list=$4
    local entry rel kind size mode flags mtime ctime digest target htype
    local candidate line path matched
    local -a unreadable_dirs=()

    # `find` exits non-zero when it cannot descend into a directory, and this
    # fixture contains one on purpose. Its status is captured instead of being
    # discarded (`|| die`), because the stderr attribution check below is what
    # decides whether the error was the expected one or a real short walk.
    set +e
    find "$root" -print0 2>"$err" | LC_ALL=C sort -z >"$list"
    find_status=${PIPESTATUS[0]}
    set -e

    # A non-zero `find` with nothing on stderr is a failure this script cannot
    # attribute to its own unreadable directory, so it is never tolerated.
    if [ "$find_status" != 0 ] && [ ! -s "$err" ]; then
        die "enumeration failed under $root with no attributable message"
    fi

    printf '%s\n' "$STAMP_HEADER" >"$out"
    printf '#root\t%s\n' "$(printf '%q' "$root")" >>"$out"

    while IFS= read -r -d '' entry; do
        rel=${entry#"$root"}
        rel=${rel#/}
        size=- mode=- flags=- mtime=- ctime=- digest=- target=-
        htype=$(stat -f '%HT' "$entry" 2>/dev/null) || htype=stat-failed
        case "$htype" in
            'Regular File')
                kind=file
                size=$(stat -f '%z' "$entry" 2>/dev/null) || size=UNREADABLE
                ;;
            'Directory')
                kind=dir
                if [ ! -r "$entry" ] || [ ! -x "$entry" ]; then
                    kind=unreadable-dir
                    unreadable_dirs+=("$entry")
                fi
                ;;
            'Symbolic Link')
                kind=link
                target=$(readlink "$entry" 2>/dev/null) || target=UNREADABLE
                ;;
            stat-failed) kind=stat-failed ;;
            *) kind=other ;;
        esac
        mode=$(stat -f '%Sp' "$entry" 2>/dev/null) || mode=UNREADABLE
        flags=$(stat -f '%Of' "$entry" 2>/dev/null) || flags=UNREADABLE
        mtime=$(stat -f '%m' "$entry" 2>/dev/null) || mtime=UNREADABLE
        ctime=$(stat -f '%c' "$entry" 2>/dev/null) || ctime=UNREADABLE
        if [ "$kind" = file ]; then
            digest=$(shasum -a 256 "$entry" 2>/dev/null | cut -d' ' -f1) || digest=UNREADABLE
            case "$digest" in
                [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) : ;;
                *) digest=UNREADABLE ;;
            esac
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(printf '%q' "$rel")" "$kind" "$size" "$mode" "$flags" "$mtime" "$ctime" \
            "$digest" "$(printf '%q' "$target")" >>"$out"
    done <"$list"

    printf '#count\t%s\n' "$(grep -c -v '^#' "$out" || true)" >>"$out"

    # Enumeration errors are only tolerable when they point at a directory this
    # script made unreadable itself. Anything else aborts: a silent short walk
    # would look exactly like "nothing changed".
    if [ -s "$err" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            path=${line#find: }
            path=${path%%:*}
            matched=0
            for candidate in ${unreadable_dirs[@]+"${unreadable_dirs[@]}"}; do
                case "$path" in
                    "$candidate"|"$candidate"/*) matched=1 ;;
                esac
            done
            if [ "$matched" != 1 ]; then
                die "enumeration failed outside a known-unreadable directory: $line"
            fi
        done <"$err"
    fi
}

write_marker() {
    local dir=$1 token=$2
    printf '%s\n' "$token" >"$dir/$MARKER"
}

case "$ACTION" in
    build)
        parent=$TARGET
        [ -d "$parent" ] || die "$parent does not exist"
        assert_local_volume "$parent"
        parent=$(canonical_dir "$parent") || die "cannot resolve $parent"
        fixture=$parent/$FIXTURE_DIRNAME
        outside=$parent/$OUTSIDE_DIRNAME
        state=$(state_dir_for "$fixture")

        if [ -e "$fixture" ]; then
            die "$fixture already exists; this script will not overwrite it"
        fi
        if [ -e "$outside" ]; then
            die "$outside already exists; this script will not overwrite it"
        fi
        if [ -e "$state" ]; then
            die "$state already exists; a previous fixture left state behind"
        fi

        token=$(uuidgen | tr -d '-')
        mkdir -m 700 "$state"
        mkdir -m 700 "$state/stamps"
        printf '%s\n' "$token" >"$state/token"
        printf '%s\tfixture\t%s\n' "$token" "$fixture" >"$(manifest_for "$state")"
        printf '%s\toutside\t%s\n' "$token" "$outside" >>"$(manifest_for "$state")"

        # Every parent directory is created before the first write into it. The
        # first version wrote into 01-项目/ … 05-应用/ without creating them, so
        # the very first `build` failed on a clean parent.
        mkdir -p \
            "$fixture/01-项目" \
            "$fixture/02-售前/sub" \
            "$fixture/03-项目文件" \
            "$fixture/04-笔记" \
            "$fixture/05-应用" \
            "$fixture/06-cache" \
            "$fixture/06-cache-2" \
            "$fixture/06-cached-docs" \
            "$fixture/07-repo" \
            "$fixture/08-empty/deeper" \
            "$fixture/.hidden" \
            "$fixture/09-locked" \
            "$fixture/10-locked-dir" \
            "$outside"
        write_marker "$fixture" "$token"
        write_marker "$outside" "$token"

        # Business-looking records that must never be excluded.
        printf 'tender\n' >"$fixture/01-项目/投标-说明.pdf"
        printf 'quotation\n' >"$fixture/02-售前/报价-2026.xlsx"
        printf 'minutes\n' >"$fixture/03-项目文件/会议记录.docx"
        printf 'note\n' >"$fixture/04-笔记/随手记.txt"
        printf 'app\n' >"$fixture/05-应用/使用说明.pdf"
        # Deliverables that merely look like logs: an ops record and an
        # acceptance record. These are the ones an extension rule would eat.
        printf 'ops\n' >"$fixture/04-笔记/运维记录.log"
        printf 'acceptance\n' >"$fixture/03-项目文件/验收记录.csv"
        printf 'config\n' >"$fixture/03-项目文件/设备配置.ini"
        # Deterministic technical noise: excluded, and only these.
        printf 'junk\n' >"$fixture/01-项目/.DS_Store"
        printf 'junk\n' >"$fixture/02-售前/sub/.DS_Store"
        printf 'appledouble\n' >"$fixture/01-项目/._投标-说明.pdf"
        # A genuine cache directory with a verifiable marker.
        printf 'Signature: 8a477f597d28d172789f06886806bc55\n' >"$fixture/06-cache/CACHEDIR.TAG"
        printf 'blob\n' >"$fixture/06-cache/artifact.bin"
        # Adjacent names that must not inherit the marker.
        printf 'keep\n' >"$fixture/06-cache-2/keep.pdf"
        printf 'keep\n' >"$fixture/06-cached-docs/manual.pdf"
        # A real git repository: reviewed, never excluded.
        printf 'readme\n' >"$fixture/07-repo/README.md"
        if command -v git >/dev/null 2>&1; then
            GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
            GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
                git init -q "$fixture/07-repo"
            GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
            GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
                git -C "$fixture/07-repo" add -A
            GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
            GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
                git -C "$fixture/07-repo" commit -q -m fixture
        else
            printf 'note: no git on this machine; the repository scenario is not exercised\n' >&2
        fi
        # Symlinks: one to a file inside the root, one out of it, one cycle.
        ln -s "01-项目/投标-说明.pdf" "$fixture/01-项目/别名.pdf"
        printf 'outside\n' >"$outside/secret.pdf"
        ln -s "../$OUTSIDE_DIRNAME" "$fixture/escape"
        ln -s loop-b "$fixture/loop-a"
        ln -s loop-a "$fixture/loop-b"
        # Empty and hidden trees: no records, no invented exclusions.
        printf 'hidden\n' >"$fixture/.hidden/config.txt"
        # Permission failures: one unreadable file, one unreadable directory.
        printf 'locked\n' >"$fixture/09-locked/secret.txt"
        chmod 000 "$fixture/09-locked/secret.txt"
        printf 'blocked\n' >"$fixture/10-locked-dir/inside.txt"
        chmod 000 "$fixture/10-locked-dir"
        # Case-only and normalization pairs, written as bytes so an editor cannot
        # fold them before the filesystem decides: NFC is \303\251, NFD is 'e'
        # plus the combining \314\201.
        printf 'upper\n' >"$fixture/Report.pdf"
        printf 'lower\n' >"$fixture/report.pdf"
        nfc=$(printf 'caf\303\251')
        nfd=$(printf 'caf\145\314\201')
        printf 'nfc\n' >"$fixture/$nfc.txt"
        printf 'nfd\n' >"$fixture/$nfd.txt"
        if [ "$nfc" = "$nfd" ]; then
            printf 'note: this shell folded the NFC/NFD pair; the normalization scenario is not exercised\n' >&2
        fi

        # Prove the tree exists before declaring success.
        for expected in \
            "01-项目/投标-说明.pdf" "02-售前/报价-2026.xlsx" "03-项目文件/会议记录.docx" \
            "04-笔记/随手记.txt" "05-应用/使用说明.pdf" "06-cache/CACHEDIR.TAG" \
            "06-cache-2/keep.pdf" "06-cached-docs/manual.pdf" "07-repo/README.md" \
            ".hidden/config.txt" "09-locked/secret.txt" "10-locked-dir" \
            "Report.pdf" "report.pdf" "$MARKER"; do
            [ -e "$fixture/$expected" ] || die "build did not create $fixture/$expected"
        done

        run_dir="\$HOME/.forma/evidence/m11-real/apfs-$(date -u +%Y%m%dT%H%M%SZ)"
        printf 'fixture built at %s\n' "$fixture"
        printf 'state at %s (stamps stay outside the scanned tree)\n' "$state"
        printf 'next: stamp before, scan, stamp after, compare\n'
        printf '  %s stamp %s before\n' "$0" "$fixture"
        printf '  mkdir -m 700 -p "%s"\n' "$run_dir"
        printf '  swift run FormaAcceptance m11-real --source "%s" --evidence-dir "%s" --dry-run\n' \
            "$fixture" "$run_dir"
        printf '  %s stamp %s after\n' "$0" "$fixture"
        printf '  %s compare %s before after\n' "$0" "$fixture"
        ;;

    stamp)
        fixture=$TARGET
        tag=${3:-}
        [ -n "$tag" ] || usage
        assert_stamp_tag "$tag"
        state=$(require_owned "$fixture")
        fixture=$(canonical_dir "$fixture") || die "cannot resolve $fixture"
        assert_local_volume "$fixture"
        out=$state/stamps/$tag.tsv
        if [ -e "$out" ]; then
            die "$out already exists; use a new tag so a stamp is never silently replaced"
        fi
        stamp_tree "$fixture" "$state/stamps/.$tag.tmp" "$state/stamps/.$tag.err" \
            "$state/stamps/.$tag.list"
        mv "$state/stamps/.$tag.tmp" "$out"
        rm -f "$state/stamps/.$tag.err" "$state/stamps/.$tag.list"
        printf 'stamped %s as %s (%s entries)\n' "$fixture" "$tag" \
            "$(grep -c -v '^#' "$out" || true)"
        ;;

    compare)
        fixture=$TARGET
        left=${3:-}
        right=${4:-}
        [ -n "$left" ] && [ -n "$right" ] || usage
        state=$(require_owned "$fixture")
        fixture=$(canonical_dir "$fixture") || die "cannot resolve $fixture"
        assert_local_volume "$fixture"
        a=$state/stamps/$left.tsv
        b=$state/stamps/$right.tsv
        [ -f "$a" ] || die "no stamp named $left in $state/stamps"
        [ -f "$b" ] || die "no stamp named $right in $state/stamps"
        [ "$(head -1 "$a")" = "$STAMP_HEADER" ] || die "$a is not a $STAMP_HEADER stamp"
        [ "$(head -1 "$b")" = "$STAMP_HEADER" ] || die "$b is not a $STAMP_HEADER stamp"
        if cmp -s "$a" "$b"; then
            printf 'identical: %s entries, no content, size, mode, flags, mtime, ctime or link change\n' \
                "$(grep -c -v '^#' "$a" || true)"
        else
            printf 'DIFFERS: the source tree changed between %s and %s\n' "$left" "$right"
            diff -u "$a" "$b" || true
            exit 1
        fi
        ;;

    clean)
        fixture=$TARGET
        state=$(require_owned "$fixture")
        fixture=$(canonical_dir "$fixture") || die "cannot resolve $fixture"
        assert_local_volume "$fixture"
        # Remove only what the manifest records, each verified on its own. No
        # sibling is guessed from a directory name.
        removed=0
        while IFS=$'\t' read -r token role path; do
            case "${role:-}" in
                fixture|outside) : ;;
                *) die "unexpected manifest role: ${role:-empty}" ;;
            esac
            [ -n "${path:-}" ] || die "unexpected manifest path"
            if [ ! -e "$path" ] && [ ! -L "$path" ]; then
                continue
            fi
            if [ -L "$path" ]; then
                die "$path is a symlink; refusing to delete through it"
            fi
            canon=$(canonical_dir "$path") || die "cannot resolve $path"
            [ "$canon" = "$path" ] || die "$path resolves to $canon; refusing"
            assert_deletable_path "$canon"
            [ -f "$canon/$MARKER" ] || die "$canon has no $MARKER; refusing to delete it"
            [ "$(cat "$canon/$MARKER")" = "$token" ] || die "$canon marker token mismatch; refusing"
            # Best effort: restoring write permission keeps the removal from
            # failing halfway and leaving debris. A real failure surfaces on the
            # `rm -rf` below instead of being hidden here.
            chmod -R u+rwX "$canon" 2>/dev/null || true
            rm -rf "$canon" || die "could not remove $canon"
            removed=$((removed + 1))
        done <"$(manifest_for "$state")"
        [ "$removed" -gt 0 ] || die "manifest listed nothing that exists; nothing was removed"
        rm -rf "$state"
        printf 'removed %s owned tree(s) and the tool state\n' "$removed"
        ;;

    *)
        usage
        ;;
esac
