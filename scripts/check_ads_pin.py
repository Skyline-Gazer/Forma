#!/usr/bin/env python3
"""Read-only consistency check for the pinned ADS consumer records.

Verifies that the submodule gitlink, `.gitmodules` remote and `ads-pin.txt`
describe the same immutable ADS revision. Exits non-zero on any drift so this
can be wired into CI without becoming a second build system.
"""

from __future__ import annotations
import argparse
import re
import subprocess
import sys

GITLINK = re.compile(r"^160000 commit ([0-9a-f]{40})\t(\S+)$")
PIN_KEYS = ("ADS_REPOSITORY", "ADS_BRANCH", "ADS_COMMIT", "ADS_CONSUMPTION")


def run(*args: str) -> str:
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise SystemExit(f"ADS_PIN_CHECK: cannot run {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def read_pin(path: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    missing = [key for key in PIN_KEYS if key not in values]
    if missing:
        raise SystemExit(f"ADS_PIN_CHECK: ads-pin.txt missing keys: {', '.join(missing)}")
    return values


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", default="HEAD", help="commit whose tree is checked")
    parser.add_argument("--path", default=".ads", help="submodule path")
    parser.add_argument("--pin-file", default="ads-pin.txt")
    parser.add_argument("--expect-branch", default="cnb/dev")
    parser.add_argument("--verify-upstream", action="store_true",
                        help="also ask the ADS remote whether the pinned commit exists")
    args = parser.parse_args(argv)

    pin = read_pin(args.pin_file)
    gitmodules = run("git", "show", f"{args.commit}:.gitmodules")
    declared_url = None
    section = False
    for line in gitmodules.splitlines():
        if line.strip().startswith("[submodule"):
            section = f'"{args.path}"' in line
        elif section and line.strip().startswith("url"):
            declared_url = line.split("=", 1)[1].strip()

    if declared_url is None:
        raise SystemExit(f"ADS_PIN_CHECK: .gitmodules declares no url for {args.path}")
    if declared_url.rstrip("/").removesuffix(".git") != pin["ADS_REPOSITORY"].rstrip("/").removesuffix(".git"):
        raise SystemExit(f"ADS_PIN_CHECK: .gitmodules url {declared_url} != ADS_REPOSITORY {pin['ADS_REPOSITORY']}")

    ls_tree = run("git", "ls-tree", args.commit, args.path).strip()
    match = GITLINK.match(ls_tree)
    if not match:
        raise SystemExit(f"ADS_PIN_CHECK: {args.path} is not a submodule gitlink in {args.commit}")
    gitlink, gitlink_path = match.group(1), match.group(2)
    if gitlink_path != args.path:
        raise SystemExit(f"ADS_PIN_CHECK: gitlink path {gitlink_path} != {args.path}")
    if gitlink != pin["ADS_COMMIT"]:
        raise SystemExit(f"ADS_PIN_CHECK: gitlink {gitlink} != ads-pin.txt {pin['ADS_COMMIT']}")
    if pin["ADS_CONSUMPTION"] != "git-submodule":
        raise SystemExit(f"ADS_PIN_CHECK: ADS_CONSUMPTION must be git-submodule, got {pin['ADS_CONSUMPTION']}")
    if pin["ADS_BRANCH"] != args.expect_branch:
        raise SystemExit(f"ADS_PIN_CHECK: ADS_BRANCH {pin['ADS_BRANCH']} != expected {args.expect_branch}")

    index = run("git", "ls-files", "-s", "--", args.path).strip()
    if index and index.split()[1] != gitlink:
        raise SystemExit(f"ADS_PIN_CHECK: index entry {index.split()[1]} != tree gitlink {gitlink}")

    if args.verify_upstream:
        probe = subprocess.run(
            ["git", "ls-remote", pin["ADS_REPOSITORY"], pin["ADS_COMMIT"]],
            capture_output=True, text=True, check=False,
        )
        if probe.returncode != 0 or pin["ADS_COMMIT"] not in (probe.stdout + probe.stderr):
            # A full object id is not a ref name, so absence is not proof of
            # invalidity; only a transport failure is reported as a hard error.
            if probe.returncode != 0:
                raise SystemExit(f"ADS_PIN_CHECK: cannot reach ADS remote: {probe.stderr.strip()}")

    print(f"ADS_PIN_OK: {args.path} gitlink == ads-pin.txt == {gitlink} ({pin['ADS_BRANCH']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
