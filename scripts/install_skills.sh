#!/bin/sh
# Install the advisory SwiftUI skills recorded in skills.lock.json into
# `.agents/skills/<name>/SKILL.md`, the layout the Agent Host discovers.
#
# Contract:
#   1. Git only. No npm, no package resolution, no build, and no script shipped
#      inside a skill is ever executed by this installer.
#   2. The pinned commit object is fetched by SHA with `--depth 1` and checked
#      out detached, so the install can never float to a newer upstream head.
#   3. The installed directory contains the skill subtree at its root, not the
#      upstream repository root. This is what makes `<name>/SKILL.md` and every
#      relative `references/`, `scripts/` and `assets/` path resolvable by the
#      host without symlink chains or duplicate copies.
#   4. Provenance is recorded beside the skill in `.forma-skill.json`; the
#      license is copied to the install root. `--check-only` verifies the root
#      layout, provenance, license and content hash without network access.
#   5. Fail closed. Wrong commit, wrong remote, missing or non-MIT licence text,
#      a missing SKILL.md, a locally modified install, or an unknown directory
#      aborts the run. Installation is staged under `.agents/` and moved into
#      place only after verification; a failed run never leaves a partial
#      host-visible skill.
#   6. The install directory is git-ignored. Skills stay advisory developer
#      guidance and are never vendored into FormaCore or FormaApp.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOCK=$ROOT/skills.lock.json

CHECK_ONLY=0
WANTED=""
WORK=""

cleanup() {
    if [ -n "$WORK" ]; then
        rm -rf -- "$WORK"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
    if lock.get("install_dir") != ".agents/skills":
        sys.exit("skills.lock.json: install_dir must be .agents/skills")
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
BASE=$(dirname "$ROOT/$INSTALL_DIR")

RECORDS=$(lock_query records) || die "cannot read skills.lock.json"
[ -n "$RECORDS" ] || die "skills.lock.json lists no skills"

verify_source() {
    src=$1 name=$2 upstream=$3 commit=$4 license_file=$5 license_header=$6 skill_path=$7

    [ -d "$src/.git" ] || die "$name: source $src is not a git checkout"
    actual=$(git -C "$src" rev-parse HEAD 2>/dev/null) || die "$name: cannot read HEAD in $src"
    [ "$actual" = "$commit" ] || die "$name: pinned SHA mismatch — $src is at $actual but skills.lock.json pins $commit. Re-verify the pin before changing the lock."
    origin=$(git -C "$src" remote get-url origin 2>/dev/null) || die "$name: $src has no origin remote"
    [ "$origin" = "$upstream" ] || die "$name: origin $origin != upstream $upstream"
    [ -f "$src/$license_file" ] || die "$name: $license_file missing at $commit"
    grep -q "$license_header" "$src/$license_file" || die "$name: $license_file is not a '$license_header' text any more"
    grep -q "Permission is hereby granted, free of charge" "$src/$license_file" || die "$name: $license_file lost the licence grant sentence"
    [ -f "$src/$skill_path/SKILL.md" ] || die "$name: SKILL.md not found at $skill_path — upstream layout changed"
    [ ! -L "$src/$skill_path/SKILL.md" ] || die "$name: SKILL.md at $skill_path is a symlink; the host needs a regular file"
    dirty=$(git -C "$src" status --porcelain --untracked-files=all --ignored) || die "$name: cannot verify local changes in $src"
    [ -z "$dirty" ] || die "$name: the source checkout was modified locally; restore or re-clone it"
}

create_source() {
    src=$1 name=$2 upstream=$3 commit=$4

    mkdir -p "$(dirname "$src")" || die "$name: cannot create $(dirname "$src")"
    if ! git init -q "$src"; then
        rm -rf -- "$src"
        die "$name: git init failed"
    fi
    if ! git -C "$src" remote add origin "$upstream"; then
        rm -rf -- "$src"
        die "$name: git remote add failed"
    fi
    if ! git -C "$src" fetch -q --depth 1 origin "$commit"; then
        rm -rf -- "$src"
        die "$name: pinned commit $commit is not fetchable from $upstream (partial source removed)"
    fi
    if ! git -C "$src" checkout -q --detach "$commit"; then
        rm -rf -- "$src"
        die "$name: cannot check out pinned commit $commit (partial source removed)"
    fi
}

hash_tree() {
    python3 - "$1" <<'PY'
import hashlib, os, stat, sys

root = os.path.abspath(sys.argv[1])
digest = hashlib.sha256()
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    links = [name for name in dirnames if os.path.islink(os.path.join(dirpath, name))]
    dirnames[:] = sorted(set(dirnames) - set(links))
    if ".git" in dirnames:
        sys.exit("unexpected .git directory in skill tree")
    for name in sorted(filenames + links):
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        if rel == ".forma-skill.json":
            continue
        st = os.lstat(path)
        mode = stat.S_IMODE(st.st_mode)
        if stat.S_ISLNK(st.st_mode):
            kind, data = b"link", os.readlink(path).encode("utf-8")
        elif stat.S_ISREG(st.st_mode):
            kind, data = b"file", open(path, "rb").read()
        else:
            sys.exit(f"unsupported file type in skill tree: {rel}")
        digest.update(kind + b"\0" + rel.encode("utf-8") + b"\0" +
                      str(mode).encode("ascii") + b"\0" + data + b"\0")
print(digest.hexdigest())
PY
}

write_provenance() {
    python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" <<'PY'
import hashlib, json, os, stat, sys

stage, name, upstream, commit, skill_path, license_file, license_header, content = sys.argv[1:9]
license_path = os.path.join(stage, "LICENSE")
if not os.path.isfile(license_path):
    sys.exit("staged skill has no LICENSE")
license_sha = hashlib.sha256(open(license_path, "rb").read()).hexdigest()
record = {
    "schema": 1,
    "name": name,
    "upstream": upstream,
    "commit": commit,
    "skill_path": skill_path,
    "license_file": license_file,
    "license_header": license_header,
    "license_sha256": license_sha,
    "entry": "SKILL.md",
    "layout": "host-root-v1",
    "content_sha256": content,
}
with open(os.path.join(stage, ".forma-skill.json"), "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

verify_install() {
    root=$1 name=$2 upstream=$3 commit=$4 skill_path=$5 license_file=$6 license_header=$7

    [ -d "$root" ] || { echo "SKILL_NOT_INSTALLED: $name (expected at $root)" >&2; return 1; }
    [ ! -d "$root/.git" ] || { echo "$name: $root is an upstream git checkout, not a host-visible install" >&2; return 1; }
    [ ! -L "$root" ] && [ -f "$root/SKILL.md" ] || { echo "$name: root SKILL.md missing or install root is a symlink; host discovery layout is invalid" >&2; return 1; }
    [ ! -L "$root/SKILL.md" ] || { echo "$name: root SKILL.md is a symlink; use a regular file" >&2; return 1; }
    [ -f "$root/LICENSE" ] && [ ! -L "$root/LICENSE" ] || { echo "$name: root LICENSE is not a regular file" >&2; return 1; }

    python3 - "$root" "$name" "$upstream" "$commit" "$skill_path" "$license_file" "$license_header" <<'PY'
import hashlib, json, os, re, stat, sys

root, name, upstream, commit, skill_path, license_file, license_header = sys.argv[1:8]
record_path = os.path.join(root, ".forma-skill.json")
if not os.path.isfile(record_path) or os.path.islink(record_path):
    sys.exit("installed skill has no regular .forma-skill.json provenance record")
try:
    record = json.load(open(record_path, encoding="utf-8"))
except Exception as error:
    sys.exit(f"cannot read .forma-skill.json: {error}")
expected = {
    "schema": 1, "name": name, "upstream": upstream, "commit": commit,
    "skill_path": skill_path, "license_file": license_file,
    "license_header": license_header, "entry": "SKILL.md", "layout": "host-root-v1",
}
for key, value in expected.items():
    if record.get(key) != value:
        sys.exit(f"provenance mismatch for {key}: {record.get(key)!r} != {value!r}")

skill_md = os.path.join(root, "SKILL.md")
if not os.path.isfile(skill_md) or os.path.islink(skill_md):
    sys.exit("root SKILL.md is not a regular file")
text = open(skill_md, encoding="utf-8").read()
if not text.startswith("---\n"):
    sys.exit("root SKILL.md has no frontmatter")
frontmatter = text.split("---", 2)[1]
match = re.search(r"(?m)^name:\s*([^\s#]+)\s*$", frontmatter)
if not match or match.group(1) != name:
    sys.exit(f"frontmatter name {match.group(1) if match else None!r} != {name!r}")

license_path = os.path.join(root, "LICENSE")
license_bytes = open(license_path, "rb").read()
license_text = license_bytes.decode("utf-8", "replace")
if license_header not in license_text or "Permission is hereby granted, free of charge" not in license_text:
    sys.exit("root LICENSE is not the recorded MIT grant")
if hashlib.sha256(license_bytes).hexdigest() != record.get("license_sha256"):
    sys.exit("root LICENSE hash does not match provenance")

digest = hashlib.sha256()
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    links = [entry for entry in dirnames if os.path.islink(os.path.join(dirpath, entry))]
    dirnames[:] = sorted(set(dirnames) - set(links))
    if ".git" in dirnames:
        sys.exit("unexpected .git directory in installed skill")
    for entry in sorted(filenames + links):
        path = os.path.join(dirpath, entry)
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        if rel == ".forma-skill.json":
            continue
        st = os.lstat(path)
        mode = stat.S_IMODE(st.st_mode)
        if stat.S_ISLNK(st.st_mode):
            target = os.readlink(path)
            resolved = os.path.realpath(path)
            if os.path.commonpath([resolved, os.path.realpath(root)]) != os.path.realpath(root):
                sys.exit(f"symlink escapes the skill root: {rel} -> {target}")
            kind, data = b"link", target.encode("utf-8")
        elif stat.S_ISREG(st.st_mode):
            kind, data = b"file", open(path, "rb").read()
        else:
            sys.exit(f"unsupported file type in installed skill: {rel}")
        digest.update(kind + b"\0" + rel.encode("utf-8") + b"\0" +
                      str(mode).encode("ascii") + b"\0" + data + b"\0")
if digest.hexdigest() != record.get("content_sha256"):
    sys.exit("installed skill content does not match its provenance record")
PY
}

stage_skill() {
    src=$1 stage=$2 license_file=$3 skill_path=$4 name=$5

    mkdir -p "$stage" || die "$name: cannot create staging directory"
    cp -Rp "$src/$skill_path/." "$stage/" || die "$name: cannot copy skill subtree"
    [ -f "$stage/SKILL.md" ] || die "$name: copied skill has no root SKILL.md"
    [ ! -L "$stage/LICENSE" ] && { [ ! -e "$stage/LICENSE" ] || [ -f "$stage/LICENSE" ]; } \
        || die "$name: staged LICENSE is not a regular file"
    cp -p "$src/$license_file" "$stage/LICENSE" || die "$name: cannot copy license"
}

publish_skill() {
    # A fixed transaction directory serializes publication for this skill and
    # leaves an inspectable recovery path after interruption. rename() never
    # nests a directory into an unexpected destination the way mv can.
    python3 - "$@" <<'PY'
import os, shutil, sys

stage, dest, backup, legacy = sys.argv[1:5]
previous = os.path.join(backup, "previous")

def move_to_absent(source, target):
    if os.path.lexists(target):
        raise FileExistsError(f"destination already exists: {target}")
    os.rename(source, target)

try:
    os.mkdir(backup, mode=0o700)
except OSError as error:
    sys.exit(f"cannot start install transaction at {backup}: {error}")

try:
    if legacy == "1":
        if os.path.islink(dest) or not os.path.isdir(os.path.join(dest, ".git")):
            raise OSError(f"legacy installation changed before replacement: {dest}")
        move_to_absent(dest, previous)
    move_to_absent(stage, dest)
except OSError as error:
    try:
        if os.path.lexists(previous):
            move_to_absent(previous, dest)
        os.rmdir(backup)
    except OSError as recovery_error:
        sys.exit(f"replacement failed: {error}; recovery failed: {recovery_error}; inspect {backup}")
    sys.exit(f"replacement failed: {error}")

try:
    if legacy == "1":
        shutil.rmtree(previous)
    os.rmdir(backup)
except OSError as error:
    sys.exit(f"verified install published; cannot finish backup cleanup at {backup}: {error}")
PY
}

install_skill() {
    name=$1 upstream=$2 commit=$3 license_file=$4 license_header=$5 skill_path=$6
    dest=$ROOT/$INSTALL_DIR/$name
    backup=$BASE/.backup-$name
    for recovery in "$backup" "$backup".[0-9]*; do
        if [ -e "$recovery" ] || [ -L "$recovery" ]; then
            die "$name: outstanding install transaction at $recovery; inspect it before retrying"
        fi
    done
    [ ! -L "$BASE" ] && [ ! -L "$ROOT/$INSTALL_DIR" ] && [ ! -L "$dest" ] \
        || die "$name: refusing a symlink in the install path"
    legacy=0

    if [ "$CHECK_ONLY" = 1 ]; then
        if [ ! -e "$dest" ]; then
            echo "SKILL_NOT_INSTALLED: $name (expected at $dest)" >&2
            return 1
        fi
        verify_install "$dest" "$name" "$upstream" "$commit" "$skill_path" "$license_file" "$license_header" \
            || die "$name: installed layout is not host-verifiable"
        echo "SKILL_OK: $name @ $commit (licence ${license_header}) -> ${dest#"$ROOT"/}, entry ${dest#"$ROOT"/}/SKILL.md"
        return 0
    fi

    if [ -e "$dest" ]; then
        if verify_install "$dest" "$name" "$upstream" "$commit" "$skill_path" "$license_file" "$license_header"; then
            echo "SKILL_OK: $name @ $commit (licence ${license_header}) -> ${dest#"$ROOT"/}, entry ${dest#"$ROOT"/}/SKILL.md"
            return 0
        fi
        if [ -d "$dest/.git" ]; then
            # Migrate an old upstream-root checkout only after proving it is a
            # clean checkout of the pinned commit. Unknown or modified
            # directories are never deleted automatically.
            verify_source "$dest" "$name" "$upstream" "$commit" "$license_file" "$license_header" "$skill_path"
            legacy=1
        else
            die "$name: $dest exists but is not a host-visible install; review it, then remove it and re-run"
        fi
    fi

    if [ -z "$WORK" ]; then
        mkdir -p "$ROOT/$INSTALL_DIR" || die "cannot create $ROOT/$INSTALL_DIR"
        WORK=$(mktemp -d "$BASE/.install.XXXXXX") || die "cannot create an installation staging directory"
    fi
    src=$WORK/source-$name
    stage=$WORK/stage-$name

    create_source "$src" "$name" "$upstream" "$commit"
    verify_source "$src" "$name" "$upstream" "$commit" "$license_file" "$license_header" "$skill_path"
    stage_skill "$src" "$stage" "$license_file" "$skill_path" "$name"
    content=$(hash_tree "$stage") || die "$name: cannot hash staged skill"
    write_provenance "$stage" "$name" "$upstream" "$commit" "$skill_path" "$license_file" "$license_header" "$content" \
        || die "$name: cannot write provenance"
    verify_install "$stage" "$name" "$upstream" "$commit" "$skill_path" "$license_file" "$license_header" \
        || die "$name: staged install failed verification"
    if [ "$legacy" = 1 ]; then
        # Fetching and staging can take time. Refuse edits made in that window.
        verify_source "$dest" "$name" "$upstream" "$commit" "$license_file" "$license_header" "$skill_path"
    fi

    publish_skill "$stage" "$dest" "$backup" "$legacy" || die "$name: cannot publish verified install"
    echo "SKILL_OK: $name @ $commit (licence ${license_header}) -> ${dest#"$ROOT"/}, entry ${dest#"$ROOT"/}/SKILL.md"
}

TAB=$(printf '\t')
rc=0
while IFS="$TAB" read -r name upstream commit license_file license_header skill_path; do
    [ -n "$name" ] || continue
    if [ -n "$WANTED" ] && [ "$WANTED" != "$name" ]; then
        continue
    fi
    install_skill "$name" "$upstream" "$commit" "$license_file" "$license_header" "$skill_path" || rc=1
done <<EOF
$RECORDS
EOF

exit "$rc"
