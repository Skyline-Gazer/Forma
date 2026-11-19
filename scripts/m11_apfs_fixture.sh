#!/bin/sh
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
# It never touches a real business directory: it writes only inside a directory
# it created itself, marked by `.forma-apfs-fixture`, and it refuses to clean any
# tree without that marker.
#
# Usage:
#   m11_apfs_fixture.sh build  <parent-dir>   # creates <parent-dir>/apfs-fixture
#   m11_apfs_fixture.sh stamp  <fixture-dir> <tag>          # writes .forma-stamp-<tag>
#   m11_apfs_fixture.sh compare <fixture-dir> <tag-a> <tag-b>
#   m11_apfs_fixture.sh clean   <fixture-dir>
#
# Exit codes:
#   0  requested operation succeeded
#   1  refused (wrong volume, missing marker, unreadable state)
#   2  usage error
#   3  unsupported platform (this script only claims macOS + APFS)
set -eu

MARKER=.forma-apfs-fixture
STAMP_PREFIX=.forma-stamp

die() {
    printf 'refused: %s\n' "$1" >&2
    exit "${2:-1}"
}

usage() {
    printf 'usage: m11_apfs_fixture.sh build <parent-dir> | stamp <fixture-dir> <tag> | compare <fixture-dir> <tag-a> <tag-b> | clean <fixture-dir>\n' >&2
    exit 2
}

[ "$(uname -s)" = "Darwin" ] || die "macOS only" 3

ACTION=${1:-}
TARGET=${2:-}
[ -n "$ACTION" ] && [ -n "$TARGET" ] || usage

# The tree must live on a writable local APFS volume, and not inside any cloud
# sync root: a fixture placed under CloudStorage would measure FileProvider
# instead of APFS, which is the opposite of the point.
assert_local_apfs() {
    path=$1
    case "$path" in
        */Library/CloudStorage/*|*/OneDrive*)
            die "$path is inside a cloud sync root; this fixture must sit on a local APFS volume"
            ;;
    esac
    info=$(diskutil info "$path" 2>/dev/null) || die "diskutil could not describe $path"
    printf '%s\n' "$info" | grep -q 'File System Personality: *APFS' \
        || die "$path is not on an APFS volume"
    printf '%s\n' "$info" | grep -q 'Read-Only: *No' \
        || die "$path is on a read-only APFS volume (a snapshot mount); build a fixture on a writable volume"
    printf '%s\n' "$info" | grep -qi 'Disk / Device Identifier' \
        || die "$path has no owning APFS volume record"
}

# One canonical line per entry: name, kind, size, mode, flags, mtime, content
# hash. Symlinks are never followed, so stamping cannot materialize or resolve
# anything, and unreadable entries are recorded as unreadable instead of
# silently dropped.
stamp_tree() {
    root=$1
    out=$2
    find "$root" -mindepth 1 -print0 2>/dev/null | LC_ALL=C sort -z | while IFS= read -r -d '' entry; do
        rel=${entry#"$root"/}
        if [ -L "$entry" ]; then
            printf '%s\tlink\t-\t-\t-\t-\t%s\n' "$rel" "$(readlink "$entry")"
        elif [ -d "$entry" ]; then
            printf '%s\tdir\t-\t%s\t%s\t-\t-\n' "$rel" \
                "$(stat -f '%Sp' "$entry" 2>/dev/null || echo unreadable)" \
                "$(stat -f '%Of' "$entry" 2>/dev/null || echo -)"
        elif [ -f "$entry" ]; then
            size=$(stat -f '%z' "$entry" 2>/dev/null || echo unreadable)
            mode=$(stat -f '%Sp' "$entry" 2>/dev/null || echo -)
            flags=$(stat -f '%Of' "$entry" 2>/dev/null || echo -)
            mtime=$(stat -f '%m' "$entry" 2>/dev/null || echo -)
            digest=$(shasum -a 256 "$entry" 2>/dev/null | cut -d' ' -f1)
            # An empty digest means the read failed, not that the file is empty:
            # record it as unreadable instead of writing a blank field that a
            # later comparison would read as a content change.
            [ -n "$digest" ] || digest=unreadable
            printf '%s\tfile\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$size" "$mode" "$flags" "$mtime" "$digest"
        else
            printf '%s\tother\t-\t-\t-\t-\t-\n' "$rel"
        fi
    done > "$out"
}

case "$ACTION" in
    build)
        parent=$TARGET
        [ -d "$parent" ] || die "$parent does not exist"
        assert_local_apfs "$parent"
        fixture=$parent/apfs-fixture
        if [ -e "$fixture" ]; then
            die "$fixture already exists; remove it first so the tree is known"
        fi
        outside=$(dirname "$fixture")/apfs-outside
        if [ -e "$outside" ]; then
            die "$outside already exists; this script expects to create it"
        fi
        mkdir "$fixture"
        : > "$fixture/$MARKER"

        # Business-looking records that must never be excluded.
        printf 'tender\n' > "$fixture/01-项目/投标-说明.pdf"
        printf 'quotation\n' > "$fixture/02-售前/报价-2026.xlsx"
        printf 'minutes\n' > "$fixture/03-项目文件/会议记录.docx"
        printf 'note\n' > "$fixture/04-笔记/随手记.txt"
        printf 'app\n' > "$fixture/05-应用/使用说明.pdf"
        # Deliverables that merely look like logs: an ops record and an
        # acceptance record. These are the ones an extension rule would eat.
        printf 'ops\n' > "$fixture/04-笔记/运维记录.log"
        printf 'acceptance\n' > "$fixture/03-项目文件/验收记录.csv"
        printf 'config\n' > "$fixture/03-项目文件/设备配置.ini"
        # Deterministic technical noise: excluded, and only these.
        printf 'junk\n' > "$fixture/01-项目/.DS_Store"
        printf 'junk\n' > "$fixture/02-售前/sub/.DS_Store"
        printf 'appledouble\n' > "$fixture/01-项目/._投标-说明.pdf"
        # A genuine cache directory with a verifiable marker.
        mkdir "$fixture/06-cache"
        printf 'Signature: 8a477f597d28d172789f06886806bc55\n' > "$fixture/06-cache/CACHEDIR.TAG"
        printf 'blob\n' > "$fixture/06-cache/artifact.bin"
        # Adjacent names that must not inherit the marker.
        mkdir "$fixture/06-cache-2" "$fixture/06-cached-docs"
        printf 'keep\n' > "$fixture/06-cache-2/keep.pdf"
        printf 'keep\n' > "$fixture/06-cached-docs/manual.pdf"
        # A real git repository: reviewed, never excluded.
        mkdir "$fixture/07-repo"
        printf 'readme\n' > "$fixture/07-repo/README.md"
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
            printf 'no git on this machine: the repository scenario will be reported as not exercised\n' >&2
        fi
        # Symlinks: one to a file inside the root, one out of it, one cycle.
        ln -s "01-项目/投标-说明.pdf" "$fixture/01-项目/别名.pdf"
        mkdir "$outside"
        printf 'outside\n' > "$outside/secret.pdf"
        ln -s "../apfs-outside" "$fixture/escape"
        ln -s loop-b "$fixture/loop-a"
        ln -s loop-a "$fixture/loop-b"
        # Empty directories and hidden trees: no records, no invented exclusions.
        mkdir "$fixture/08-empty" "$fixture/08-empty/deeper"
        mkdir "$fixture/.hidden"
        printf 'hidden\n' > "$fixture/.hidden/config.txt"
        # Permission failures: one unreadable directory, one unreadable file.
        mkdir "$fixture/09-locked"
        printf 'locked\n' > "$fixture/09-locked/secret.txt"
        chmod 000 "$fixture/09-locked/secret.txt"
        mkdir "$fixture/10-locked-dir"
        printf 'blocked\n' > "$fixture/10-locked-dir/inside.txt"
        chmod 000 "$fixture/10-locked-dir"
        # Case-only and normalization pairs. The two spellings of "café" are
        # written as bytes, not as two literals that an editor may have already
        # folded: NFC is \303\251, NFD is 'e' plus the combining \314\201. On a
        # case- and normalization-insensitive APFS volume these collapse to one
        # file, which is the behaviour the scan has to report honestly.
        printf 'upper\n' > "$fixture/Report.pdf"
        printf 'lower\n' > "$fixture/report.pdf"
        nfc=$(printf 'caf\303\251')
        nfd=$(printf 'caf\145\314\201')
        printf 'nfc\n' > "$fixture/$nfc.txt"
        printf 'nfd\n' > "$fixture/$nfd.txt"
        if [ "$nfc" = "$nfd" ]; then
            printf 'note: this shell folded the NFC/NFD pair; the normalization scenario is not exercised here\n' >&2
        fi

        stamp_tree "$fixture" "$fixture/$STAMP_PREFIX-build"
        entries=$(wc -l < "$fixture/$STAMP_PREFIX-build" | tr -d ' ')
        printf 'fixture built at %s (%s entries stamped)\n' "$fixture" "$entries"
        printf 'next: stamp before the scan, then again after it\n'
        printf '  %s stamp %s before\n' "$0" "$fixture"
        printf '  swift run FormaAcceptance m11-real --source "%s" --evidence-dir "<new empty run dir>" --dry-run\n' "$fixture"
        printf '  %s stamp %s after\n' "$0" "$fixture"
        printf '  %s compare %s before after\n' "$0" "$fixture"
        ;;

    stamp)
        fixture=$TARGET
        tag=${3:-}
        [ -n "$tag" ] || usage
        [ -f "$fixture/$MARKER" ] || die "$fixture was not built by this script (no $MARKER)"
        stamp_tree "$fixture" "$fixture/$STAMP_PREFIX-$tag"
        printf 'stamped %s as %s (%s entries)\n' "$fixture" "$tag" \
            "$(wc -l < "$fixture/$STAMP_PREFIX-$tag" | tr -d ' ')"
        ;;

    compare)
        fixture=$TARGET
        left=${3:-}
        right=${4:-}
        [ -n "$left" ] && [ -n "$right" ] || usage
        a=$fixture/$STAMP_PREFIX-$left
        b=$fixture/$STAMP_PREFIX-$right
        [ -f "$a" ] && [ -f "$b" ] || die "missing stamp file: $a or $b"
        if cmp -s "$a" "$b"; then
            printf 'identical: the scan changed no content, size, mode, flags or mtime\n'
        else
            printf 'DIFFERS — the source tree was modified. Findings:\n'
            diff "$a" "$b" || true
            exit 1
        fi
        ;;

    clean)
        fixture=$TARGET
        [ -f "$fixture/$MARKER" ] || die "refusing to remove $fixture: it has no $MARKER, so this script did not build it"
        # Reopen the permission-restricted fixtures before deleting them.
        [ -d "$fixture/10-locked-dir" ] && chmod 700 "$fixture/10-locked-dir" 2>/dev/null || true
        [ -f "$fixture/09-locked/secret.txt" ] && chmod 600 "$fixture/09-locked/secret.txt" 2>/dev/null || true
        rm -rf "$fixture"
        outside=$(dirname "$fixture")/apfs-outside
        if [ -d "$outside" ]; then
            rm -rf "$outside"
        fi
        printf 'removed the fixture tree and its outside directory\n'
        ;;

    *)
        usage
        ;;
esac
