#!/usr/bin/env python3
"""Print the CNB structured review result and fail when the evidence is absent.

Evidence retention only: this never grants merge approval and never replaces
GitHub Actions. It distinguishes the states that previously collapsed into an
accidental traceback, because "plugin exited 0" is not proof of review coverage.
"""

from __future__ import annotations
import argparse
import json
from pathlib import Path
import sys

STATUSES = {"passed", "needs_modification", "critical"}
SEVERITIES = {"critical", "warning", "info"}
CATEGORIES = {"security", "bug", "perf", "maintainability", "style", "nit", "other"}


def report(path: str, reviewed_sha: str, target_sha: str, expected_sha: str) -> int:
    print(f"reviewed-source-sha={reviewed_sha}")
    print(f"reviewed-target-sha={target_sha}")
    if expected_sha:
        if reviewed_sha.lower() != expected_sha.lower():
            print(f"REVIEW_STALE: reviewed source {reviewed_sha!r} != expected head {expected_sha!r}; "
                  "these findings do not describe the current revision", file=sys.stderr)
            return 1
        print(f"review-binding: reviewed source matches the expected head {expected_sha}")
    result = Path(path)
    if not result.is_file():
        print("REVIEW_EVIDENCE_MISSING: no structured review result file; findings are unverified", file=sys.stderr)
        return 1
    try:
        data = json.loads(result.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeError) as error:
        print(f"REVIEW_EVIDENCE_INVALID: structured result is not readable JSON: {error}", file=sys.stderr)
        return 1
    if not isinstance(data, dict) or not {"status", "issues"} <= set(data):
        print("REVIEW_EVIDENCE_INVALID: result lacks the required status/issues fields", file=sys.stderr)
        return 1
    status, issues = data["status"], data["issues"]
    if status not in STATUSES or not isinstance(issues, list):
        print(f"REVIEW_EVIDENCE_INVALID: unexpected status {status!r} or non-list issues", file=sys.stderr)
        return 1
    counts = {severity: 0 for severity in SEVERITIES}
    for index, item in enumerate(issues):
        if not isinstance(item, dict):
            print(f"REVIEW_EVIDENCE_INVALID: issue {index} is not an object", file=sys.stderr)
            return 1
        severity = item.get("severity")
        if severity not in SEVERITIES:
            print(f"REVIEW_EVIDENCE_INVALID: issue {index} has missing or unknown severity", file=sys.stderr)
            return 1
        if not isinstance(item.get("problem"), str) or not item["problem"].strip():
            print(f"REVIEW_EVIDENCE_INVALID: issue {index} lacks problem evidence", file=sys.stderr)
            return 1
        if item.get("category") not in CATEGORIES:
            print(f"REVIEW_EVIDENCE_INVALID: issue {index} has missing or unknown category", file=sys.stderr)
            return 1
        counts[severity] += 1
        print(json.dumps(item, ensure_ascii=False))
    print(f"status: {status}; findings: {len(issues)}; critical: {counts['critical']}; "
          f"warning: {counts['warning']}; info: {counts['info']}")
    if status == "critical" and not counts["critical"]:
        print("REVIEW_EVIDENCE_INVALID: status is critical with no critical issue", file=sys.stderr)
        return 1
    if status == "needs_modification" and not issues:
        print("REVIEW_EVIDENCE_INVALID: review requires modification but lists no issue", file=sys.stderr)
        return 1
    print("REVIEW_EVIDENCE_RECORDED: findings above are untrusted feedback, not merge authorization")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", default="./code_review.json")
    parser.add_argument("--reviewed-sha", default="")
    parser.add_argument("--target-sha", default="")
    parser.add_argument("--expect-sha", default="",
                        help="fail when the reviewed source SHA is not this revision")
    args = parser.parse_args(argv)
    return report(args.result, args.reviewed_sha, args.target_sha, args.expect_sha)


if __name__ == "__main__":
    sys.exit(main())
