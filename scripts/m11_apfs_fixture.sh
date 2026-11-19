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

# The volume behind a path, via the device `df` reports. `diskutil info <dir>`
# is not dependable across macOS versions ("Could not find disk: /…/_temp" on a
# runner), while `diskutil info <device>` is.
volume_device() {
    df -P "$1" 2>/dev/null | awk 'NR==2 {print $1}'
}

# True when a *canonical* path sits inside a sync root, matched on whole path
# components only.
#
# Component matching replaces substring matching, which was wrong in both
# directions: `…/Library/CloudStorage/OneDrive-Personal` has to be caught, while
# `/tmp/x/MyOneDriveDocs` -- an ordinary local directory -- must not be refused.
# A local directory named exactly `OneDrive` is still refused: a false refusal on
# a name this tool never needs is the safe side of that trade, and the harness
# pins both halves of the behaviour.
#
# Splitting is done with parameter expansion rather than `IFS=/` plus an
# unquoted expansion, so a path containing glob characters is never globbed.
is_cloud_sync_path() {
    local rest=$1 component previous=
    while [ -n "$rest" ]; do
        case "$rest" in
            */*) component=${rest%%/*}
                 rest=${rest#*/} ;;
            *)   component=$rest
                 rest= ;;
        esac
        case "$component" in
            CloudStorage)
                [ "$previous" = "Library" ] && return 0
                ;;
            OneDrive|Dropbox|"Google Drive"|"iCloud Drive"|"Mobile Documents"|"com~apple~CloudDocs")
                return 0
                ;;
        esac
        previous=$component
    done
    return 1
}

# Every path this script touches must be on a writable local APFS volume.
#
# The path handed in must already be canonical (`pwd -P`). A symlink alias into
# CloudStorage only becomes the sync root after resolution, so checking the
# string as given would miss it; every caller canonicalizes first.
#
# Known limitation, stated rather than papered over: this identifies the
# FileProvider layout by name plus "device is /dev/..." plus the APFS
# personality. A cloud client that mounts somewhere without a `CloudStorage`
# component and exports a plain APFS volume would not be recognized. The tool
# never decides to scan business data on its own; the Owner names the parent
# directory, and that instruction is the real boundary.
assert_local_volume() {
    local path=$1 device info probe
    if is_cloud_sync_path "$path"; then
        die "$path is inside a cloud sync root; this fixture must sit on a local APFS volume"
    fi
    device=$(volume_device "$path") || die "df could not describe $path"
    [ -n "${device:-}" ] || die "df reported no device for $path"
    # A network mount reports `//host/share` or `host:/path`, never `/dev/...`;
    # refusing anything that is not a local disk device is a second line of
    # defence that does not depend on how the path is spelled.
    case "$device" in
        /dev/*) : ;;
        *) die "$path is on $device, which is not a local disk device" ;;
    esac
    info=$(diskutil info "$device" 2>/dev/null) || die "diskutil could not describe $device"
    printf '%s\n' "$info" | grep -q 'File System Personality: *APFS' \
        || die "$path ($device) is not on an APFS volume"
    # Writability is proven by an actual write, not by a banner line: a sealed
    # snapshot mount reports differently from the volume beneath it.
    #
    # The probe goes *inside* `$path`, not beside it: requiring the parent of the
    # parent to be writable would refuse a perfectly usable directory, and the
    # fingerprint deliberately excludes the root entry (`find -mindepth 1`), so a
    # transient file at the root cannot move a stamp.
    # `mktemp` rather than a predictable `$$` name: a pre-placed symlink at a
    # guessable path would otherwise turn `: >` into a truncation of any file the
    # invoking user can write. The probe is removed immediately either way.
    probe=$(mktemp "$path/.forma-m11-probe.XXXXXX" 2>/dev/null) || probe=
    if [ -z "$probe" ]; then
        die "$path is not writable"
    fi
    rm -f "$probe"
}

# Refuse to build a fixture inside another fixture or inside a tool-state
# directory: the outer run would then fingerprint (and later delete) a tree it
# did not create.
assert_not_inside_tool_tree() {
    local rest=$1 component
    while [ -n "$rest" ]; do
        case "$rest" in
            */*) component=${rest%%/*}
                 rest=${rest#*/} ;;
            *)   component=$rest
                 rest= ;;
        esac
        case "$component" in
            "$FIXTURE_DIRNAME"|"$STATE_DIRNAME"|"$OUTSIDE_DIRNAME")
                die "$1 is inside a $component directory; refusing to nest fixtures"
                ;;
        esac
    done
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
    find "$root" -mindepth 1 -print0 2>"$err" | LC_ALL=C sort -z >"$list"
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
        # Canonicalize before any path check: `..`, a trailing slash, a relative
        # path and a symlink alias all resolve to the same directory, and a
        # cloud-sync alias only becomes recognizable after resolution.
        parent=$(canonical_dir "$parent") || die "cannot resolve $parent"
        # Cheapest refusal first: nesting is a pure path question and must not
        # touch the tree (the volume guard writes a probe file).
        assert_not_inside_tool_tree "$parent"
        assert_local_volume "$parent"
        fixture=$parent/$FIXTURE_DIRNAME
        outside=$parent/$OUTSIDE_DIRNAME
        state=$(state_dir_for "$fixture")

        # `[ -e ]` alone follows symlinks, so a *dangling* symlink placed at one of
        # these names would pass the check and then have `mkdir -p` / `>` write
        # through it — into a cloud root the volume guard never saw, since it
        # validated only the parent. `[ -L ]` closes that, and the three roots are
        # created with plain `mkdir`, which cannot traverse a link either.
        for guarded in "$fixture" "$outside" "$state"; do
            if [ -e "$guarded" ] || [ -L "$guarded" ]; then
                die "$guarded already exists; this script will not overwrite it"
            fi
        done

        token=$(uuidgen | tr -d '-')
        mkdir "$fixture" || die "could not create $fixture"
        mkdir "$outside" || die "could not create $outside"
        mkdir -m 700 "$state" || die "could not create $state"
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
            "$fixture/10-locked-dir"
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
        # The same tag validation `stamp` enforces: without it, `compare` would
        # read `../../…/anything.tsv` out of the state directory.
        assert_stamp_tag "$left"
        assert_stamp_tag "$right"
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

        manifest=$(manifest_for "$state")
        parent=$(dirname "$state")
        expected_token=$(cat "$state/token")

        # Pass 1: validate every target and delete nothing.
        #
        # The manifest is data, not authority. A manifest that was edited to add
        # a path, duplicate a role, swap in another token or point at an
        # unrelated sibling must not widen what gets deleted, so its *shape* is
        # checked as strictly as its contents: exactly two lines, one `fixture`
        # and one `outside`, both directly inside the state directory's parent,
        # both named the way this script names them, both marker-verified.
        #
        # Nothing is removed until this pass has accepted every entry, so a
        # second bad target cannot be discovered after the first tree is gone.
        manifest_lines=0
        targets=()
        target_roles=()
        while IFS=$'\t' read -r token role path extra; do
            manifest_lines=$((manifest_lines + 1))
            if [ -n "${extra:-}" ]; then
                die "manifest line $manifest_lines has more than three fields"
            fi
            if [ -z "${token:-}" ] || [ -z "${role:-}" ] || [ -z "${path:-}" ]; then
                die "manifest line $manifest_lines is malformed"
            fi
            if [ "$token" != "$expected_token" ]; then
                die "manifest line $manifest_lines carries a foreign token"
            fi
            case "$role" in
                fixture) expected_name=$FIXTURE_DIRNAME ;;
                outside) expected_name=$OUTSIDE_DIRNAME ;;
                *) die "manifest line $manifest_lines has an unexpected role: $role" ;;
            esac
            for seen in ${target_roles[@]+"${target_roles[@]}"}; do
                if [ "$seen" = "$role" ]; then
                    die "manifest repeats role $role; refusing"
                fi
            done
            if [ "$(dirname "$path")" != "$parent" ]; then
                die "manifest target $path is outside $parent; refusing"
            fi
            if [ "$(basename "$path")" != "$expected_name" ]; then
                die "manifest target $path is not a $role directory; refusing"
            fi
            if [ ! -e "$path" ] && [ ! -L "$path" ]; then
                # Already gone: recorded as a role, never a deletion target.
                target_roles+=("$role")
                continue
            fi
            if [ -L "$path" ]; then
                die "$path is a symlink; refusing to delete through it"
            fi
            canon=$(canonical_dir "$path") || die "cannot resolve $path"
            if [ "$canon" != "$path" ]; then
                die "$path resolves to $canon; refusing"
            fi
            assert_deletable_path "$canon"
            if [ ! -f "$canon/$MARKER" ]; then
                die "$canon has no $MARKER; refusing to delete it"
            fi
            if [ "$(cat "$canon/$MARKER")" != "$token" ]; then
                die "$canon marker token mismatch; refusing"
            fi
            targets+=("$canon")
            target_roles+=("$role")
        done <"$manifest"
        if [ "$manifest_lines" -ne 2 ]; then
            die "manifest has $manifest_lines lines; expected exactly 2"
        fi
        if [ "${#target_roles[@]}" -ne 2 ]; then
            die "manifest does not name both a fixture and an outside tree; refusing"
        fi

        # Pass 2: remove the validated targets, re-checking each one as late as
        # possible. Between this re-check and `rm -rf` there is still a window: a
        # shell script cannot make check-and-delete atomic, so the residual race
        # is stated here instead of being claimed away.
        removed=0
        for canon in ${targets[@]+"${targets[@]}"}; do
            if [ -L "$canon" ]; then
                die "$canon became a symlink during cleanup; refusing"
            fi
            if [ ! -d "$canon" ]; then
                die "$canon disappeared during cleanup; refusing"
            fi
            if [ ! -f "$canon/$MARKER" ]; then
                die "$canon lost its marker during cleanup; refusing"
            fi
            if [ "$(cat "$canon/$MARKER")" != "$expected_token" ]; then
                die "$canon marker changed during cleanup; refusing"
            fi
            # Best effort: restoring write permission keeps the removal from
            # failing halfway and leaving debris. A real failure surfaces on the
            # `rm -rf` below instead of being hidden here.
            chmod -R u+rwX "$canon" 2>/dev/null || true
            rm -rf "$canon" || die "could not remove $canon"
            removed=$((removed + 1))
        done
        if [ "$removed" -eq 0 ]; then
            die "manifest listed nothing that exists; nothing was removed"
        fi
        rm -rf "$state"
        printf 'removed %s owned tree(s) and the tool state\n' "$removed"
        ;;

    *)
        usage
        ;;
esac
