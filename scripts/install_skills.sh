#!/bin/sh
# Install the advisory SwiftUI skills recorded in skills.lock.json into
# `.agents/skills/<name>` at exactly the pinned commit (issue #149).
#
# Contract:
#   1. Git only. No npm, no package resolution, no build, and no script shipped
#      inside a skill is ever executed by this installer.
#   2. The pinned commit object is fetched by SHA with `--depth 1` and checked
#      out detached, so the install can never float to a newer upstream head.
#   3. Fail closed. Wrong commit, wrong remote, missing or non-MIT licence text,
#      a missing SKILL.md, or a locally modified install aborts the run. Nothing
#      that was already there is deleted or overwritten — only a partial clone
#      created by this same run is cleaned up — and bumping a pin is a reviewed PR.
#   4. The install directory is git-ignored. Skills stay advisory developer
#      guidance and are never vendored into FormaCore or FormaApp.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOCK=$ROOT/skills.lock.json

CHECK_ONLY=0
WANTED=""

die() {
    echo "SKILL_INSTALL_FAIL: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
usage: scripts/install_skills.sh [--check-only] [--skill NAME]

  --check-only  verify an existing install against skills.lock.json; write nothing
  --skill NAME  restrict to one skill (default: every entry in the lock)
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        --check-only) CHECK_ONLY=1 ;;
        --skill)
            [ $# -ge 2 ] || { usage; >&2 echo "install_skills.sh: --skill needs a name"; exit 2; }
            WANTED=$2
            shift
            ;;
        --skill=*) WANTED=${1#--skill=} ;;
        -h | --help) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
    shift
done

[ -f "$LOCK" ] || die "skills.lock.json not found at $ROOT"

lock_query() {
    # $1 = install_dir | records. Records are TAB-separated and validated here,
    # so a malformed lock aborts before any network access.
    python3 - "$LOCK" "$1" <<'PY'
import json, re, sys

lock, mode = json.load(open(sys.argv[1], encoding="utf-8")), sys.argv[2]
if lock.get("schema") != 1 or not lock.get("skills"):
    sys.exit("skills.lock.json: unexpected schema or empty skills list")
if mode == "install_dir":
    print(lock["install_dir"])
    sys.exit(0)
if mode != "records":
    sys.exit(f"skills.lock.json: unknown query {mode}")
for skill in lock["skills"]:
    try:
        row = [skill["name"], skill["upstream"], skill["commit"],
               skill["license_file"], skill["license_header"], skill["skill_path"]]
    except KeyError as error:
        sys.exit(f"skills.lock.json: skill {skill.get('name')!r} misses {error}")
    if not re.fullmatch(r"[0-9a-f]{40}", row[2]):
        sys.exit(f"skills.lock.json: {row[0]} commit is not a full 40-hex SHA: {row[2]}")
    if not row[1].startswith("https://"):
        sys.exit(f"skills.lock.json: {row[0]} upstream must be an https URL")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", row[0]):
        sys.exit(f"skills.lock.json: unsafe skill name: {row[0]}")
    for field, label in ((row[3], "license_file"), (row[5], "skill_path")):
        if not re.fullmatch(r"[A-Za-z0-9._-](?:[A-Za-z0-9._/-]*[A-Za-z0-9._-])?", field) \
                or ".." in field.split("/"):
            sys.exit(f"skills.lock.json: unsafe {label} for {row[0]}: {field}")
    if any("\t" in field or "\n" in field for field in row):
        sys.exit(f"skills.lock.json: {row[0]} contains a tab or newline")
    print("\t".join(row))
PY
}

INSTALL_DIR=$(lock_query install_dir) || die "cannot read skills.lock.json"

MANIFEST=$(mktemp)
trap 'rm -f "$MANIFEST"' EXIT INT TERM
lock_query records > "$MANIFEST" || die "cannot read skills.lock.json"
[ -s "$MANIFEST" ] || die "skills.lock.json lists no skills"

check_checkout() {
    dest=$1 name=$2 upstream=$3 commit=$4 license_file=$5 license_header=$6 skill_path=$7

    [ -d "$dest/.git" ] || die "$name: $dest exists but is not a git checkout; review it, then remove it and re-run"
    actual=$(git -C "$dest" rev-parse HEAD 2>/dev/null) || die "$name: cannot read HEAD in $dest"
    [ "$actual" = "$commit" ] || die "$name: pinned SHA mismatch — $dest is at $actual but skills.lock.json pins $commit. Either the upstream moved (bump the lock in a reviewed PR after re-verifying licence and content) or the install drifted: rm -rf '$dest' && scripts/install_skills.sh"
    origin=$(git -C "$dest" remote get-url origin 2>/dev/null) || die "$name: $dest has no origin remote"
    [ "$origin" = "$upstream" ] || die "$name: origin $origin != upstream $upstream"
    [ -f "$dest/$license_file" ] || die "$name: $license_file missing at $commit"
    grep -q "$license_header" "$dest/$license_file" || die "$name: $license_file is not a '$license_header' text any more"
    grep -q "Permission is hereby granted, free of charge" "$dest/$license_file" || die "$name: $license_file lost the licence grant sentence"
    [ -f "$dest/$skill_path/SKILL.md" ] || die "$name: SKILL.md not found at $skill_path — upstream layout changed"
    dirty=$(git -C "$dest" status --porcelain)
    [ -z "$dirty" ] || die "$name: the installed copy was modified locally; skills are read-only guidance, restore or remove $dest"
    echo "SKILL_OK: $name @ $commit (licence ${license_header}) -> ${dest#"$ROOT"/}, entry ${dest#"$ROOT"/}/$skill_path/SKILL.md"
}

# A failed fetch must not leave a half-created repository behind: the next run
# would find the directory, refuse it and ask for a manual removal.
create_checkout() {
    dest=$1 name=$2 upstream=$3 commit=$4

    mkdir -p "$(dirname "$dest")" || die "$name: cannot create $(dirname "$dest")"
    if ! git init -q "$dest"; then
        rm -rf -- "$dest"
        die "$name: git init failed"
    fi
    if ! git -C "$dest" remote add origin "$upstream"; then
        rm -rf -- "$dest"
        die "$name: git remote add failed"
    fi
    # Fetching the object by SHA is what makes the pin binding: a branch head
    # would silently move under us.
    if ! git -C "$dest" fetch -q --depth 1 origin "$commit"; then
        rm -rf -- "$dest"
        die "$name: pinned commit $commit is not fetchable from $upstream (partial install removed)"
    fi
    if ! git -C "$dest" checkout -q --detach "$commit"; then
        rm -rf -- "$dest"
        die "$name: cannot checkout out pinned commit $commit (partial install removed)"
    fi
}

TAB=$(printf '\t')
rc=0
while IFS="$TAB" read -r name upstream commit license_file license_header skill_path; do
    [ -n "$name" ] || continue
    if [ -n "$WANTED" ] && [ "$WANTED" != "$name" ]; then
        continue
    fi
    dest=$ROOT/$INSTALL_DIR/$name

    if [ -e "$dest" ]; then
        check_checkout "$dest" "$name" "$upstream" "$commit" "$license_file" "$license_header" "$skill_path"
        continue
    fi
    if [ "$CHECK_ONLY" = 1 ]; then
        echo "SKILL_NOT_INSTALLED: $name (expected at $dest)" >&2
        rc=1
        continue
    fi

    create_checkout "$dest" "$name" "$upstream" "$commit"
    check_checkout "$dest" "$name" "$upstream" "$commit" "$license_file" "$license_header" "$skill_path"
done < "$MANIFEST"

exit "$rc"
