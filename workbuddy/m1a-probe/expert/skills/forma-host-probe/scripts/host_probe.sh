#!/bin/sh
# Strictly read-only M1-A host feasibility probe.
# Zero writes, zero moves, zero network calls, zero DEVONthink calls.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SKILL_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TARGET_DIR=${1:-""}

echo "=== FORMA M1-A HOST PROBE (READ-ONLY) ==="
echo "DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "OS=$(uname -s) ARCH=$(uname -m) OS_VER=$(uname -r)"
echo "PWD=$(pwd)"
echo "SCRIPT_DIR=$SCRIPT_DIR"
echo "SKILL_DIR=$SKILL_DIR"
if [ -f "$SKILL_DIR/references/probe-checklist.md" ]; then
  echo "REF_CHECK=OK ($SKILL_DIR/references/probe-checklist.md)"
else
  echo "REF_CHECK=MISSING"
fi
echo "PATH=$PATH"

echo "=== RUNTIME & TOOL DISCOVERY ==="
for cmd in python3 docvortex mac-ocr swift go node osascript; do
  if command -v "$cmd" >/dev/null 2>&1; then
    loc=$(command -v "$cmd")
    case "$cmd" in
      python3) ver=$("$cmd" --version 2>&1 | head -n 1) ;;
      docvortex) ver=$("$cmd" --version 2>&1 | head -n 1) ;;
      mac-ocr) ver=$("$cmd" --version 2>&1 | head -n 1) ;;
      swift) ver=$("$cmd" --version 2>&1 | head -n 1) ;;
      go) ver=$("$cmd" version 2>&1 | head -n 1) ;;
      node) ver=$("$cmd" --version 2>&1 | head -n 1) ;;
      osascript) ver="available" ;;
      *) ver="available" ;;
    esac
    echo "TOOL_${cmd}=FOUND path=${loc} ver=${ver}"
  else
    echo "TOOL_${cmd}=NOT_FOUND"
  fi
done

echo "=== SYNTHETIC DIRECTORY CHECK (READ-ONLY) ==="
if [ -z "$TARGET_DIR" ]; then
  echo "TARGET_DIR=NOT_PROVIDED"
elif [ -L "$TARGET_DIR" ]; then
  echo "TARGET_DIR_STATUS=REJECTED_SYMLINK ($TARGET_DIR)"
elif [ -d "$TARGET_DIR" ]; then
  echo "TARGET_DIR_STATUS=READABLE_DIR ($TARGET_DIR)"
  ls -la "$TARGET_DIR"
else
  echo "TARGET_DIR_STATUS=NOT_A_DIRECTORY_OR_UNREADABLE ($TARGET_DIR)"
fi
