#!/usr/bin/env python3
"""Minimal deterministic filesystem safety kernel for Forma WorkBuddy Edition.

Stdlib-only Python 3. Implements:
- inspect: read-only inventory, SHA-256, magic-byte check, SF_DATALESS, NFC/case collisions, #136 honest probe-budget reporting
- plan: immutable plan_id/plan_hash bound to snapshot_hash, containment & collision validation, Markdown preview
- apply: dry-run by default, approval-hash bound, single-writer flock, exclusive no-replace rename (RENAME_EXCL / RENAME_NOREPLACE, fail-closed), append-only journal
- cleanup-empty: separately approved empty directory removal (os.rmdir only, never recursive)
- recover: four-state arbitration (exists/missing/conflict/unknown) with conflict-hold protection
"""
from __future__ import annotations

import argparse
import ctypes
import errno
import fcntl
import hashlib
import json
import os
import platform
import shutil
import sys
import time
import unicodedata
from pathlib import Path
from typing import Any, Callable

SCHEMA_VERSION = "forma-workbuddy-plan/1.0"
SF_DATALESS = 0x40000000  # Darwin UF/SF_DATALESS cloud placeholder flag
RENAME_EXCL_MACOS = 0x00000004
RENAME_NOREPLACE_LINUX = 1
AT_FDCWD = -100

MAGIC_SIGNATURES = {
    ".pdf": (b"%PDF-",),
    ".docx": (b"PK\x03\x04",),
    ".xlsx": (b"PK\x03\x04",),
    ".pptx": (b"PK\x03\x04",),
}

_DEFAULT_POLICY_PATH = Path(__file__).resolve().parent.parent / "references" / "eligibility-policy.json"


def _canonical_json(obj: Any) -> str:
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def _is_cloud_storage_path(path: Path) -> bool:
    parts = {p.lower() for p in path.resolve().parts}
    return "cloudstorage" in parts or any(p.startswith("onedrive") for p in parts)


def _is_dataless(st: os.stat_result) -> bool:
    flags = getattr(st, "st_flags", 0)
    return bool(flags & SF_DATALESS)


def _normalize_collision_key(rel_path: str) -> str:
    return unicodedata.normalize("NFC", rel_path).casefold()


def _ensure_within(root: Path, candidate: Path) -> Path:
    real_root = Path(os.path.realpath(root))
    real_cand = Path(os.path.realpath(candidate))
    try:
        real_cand.relative_to(real_root)
    except ValueError as exc:
        raise ValueError(f"Path escapes authorized root: {candidate} -> {real_cand} (root={real_root})") from exc
    return real_cand


def _ensure_dest_target_within(dest_root: Path, rel_path: str) -> Path:
    if not rel_path or os.path.isabs(rel_path):
        raise ValueError(f"Invalid relative destination path: {rel_path!r}")
    parts = Path(rel_path).parts
    if any(p in ("", ".", "..") for p in parts) or "\x00" in rel_path:
        raise ValueError(f"Unsafe path component in {rel_path!r}")
    real_root = Path(os.path.realpath(dest_root))
    target = real_root / Path(*parts)
    # Check existing ancestor symlinks do not escape dest_root
    cur = real_root
    for part in parts[:-1]:
        cur = cur / part
        if cur.exists() and cur.is_symlink():
            raise ValueError(f"Symlink directory in destination path: {cur}")
    if target.exists() and target.is_symlink():
        raise ValueError(f"Destination is a symlink: {target}")
    _ensure_within(real_root, target.parent if not target.exists() else target)
    return target


def _check_magic_mismatch(path: Path, ext: str) -> tuple[bool, str | None]:
    sigs = MAGIC_SIGNATURES.get(ext.lower())
    if not sigs:
        return False, None
    try:
        with path.open("rb") as f:
            head = f.read(16)
    except OSError as exc:
        return False, f"read_error:{exc}"
    if not any(head.startswith(s) for s in sigs):
        return True, f"expected_{ext.lower()}_signature"
    return False, None


def _load_eligibility_rules(policy_path: Path | None) -> dict[str, Any]:
    p = policy_path or _DEFAULT_POLICY_PATH
    if p.exists():
        return json.loads(p.read_text(encoding="utf-8"))
    return {"policy_id": "fallback", "rules": []}


def _facts_match(actual: dict[str, Any] | None, expected: dict[str, Any]) -> bool:
    if not actual:
        return False
    for key, want in expected.items():
        got = actual.get(key)
        if got is None:
            return False
        if isinstance(want, bool):
            if bool(got) != want:
                return False
        elif str(got).casefold() != str(want).casefold():
            return False
    return True


def _classify_entry(
    rel_path: str,
    name: str,
    policy: dict[str, Any] | None = None,
    *,
    facts: dict[str, Any] | None = None,
    entry_state: str = "present",
    hydration_pending: bool = False,
) -> tuple[str, str]:
    parts = Path(rel_path).parts
    if any(part == ".git" for part in parts):
        return "REVIEW", "git_tracked_content"
    for rule in (policy or {}).get("rules", []):
        conds = rule.get("all", [])
        if not conds:
            continue
        matched = True
        for cond in conds:
            if not isinstance(cond, dict):
                matched = False
                break
            for key, expected in cond.items():
                if key == "basenames":
                    if name.casefold() not in {str(item).casefold() for item in expected}:
                        matched = False
                elif key == "basename_prefixes":
                    lowered = name.casefold()
                    if not any(lowered.startswith(str(prefix).casefold()) for prefix in expected):
                        matched = False
                elif key == "dirnames":
                    if not any(part in expected for part in parts[:-1]):
                        matched = False
                elif key == "path_components":
                    wanted = {str(item).casefold() for item in expected}
                    if not any(str(part).casefold() in wanted for part in parts):
                        matched = False
                elif key == "entry_states":
                    if entry_state not in {str(item) for item in expected}:
                        matched = False
                elif key == "hydration_pending":
                    if bool(expected) != hydration_pending:
                        matched = False
                elif key == "facts":
                    if not _facts_match(facts, expected):
                        matched = False
                else:
                    # Unknown condition keys must never match unconditionally.
                    matched = False
                if not matched:
                    break
            if not matched:
                break
        if matched:
            return rule["decision"], rule.get("explanation_code", rule["rule_id"])
    if entry_state != "present":
        return "REVIEW", "unclassified_entry_state"
    return "INCLUDE", "eligible_business_candidate"


def inspect_directory(source: Path, max_entries: int = 5000, policy_path: Path | None = None) -> dict[str, Any]:
    if not source.exists():
        raise FileNotFoundError(f"Source does not exist: {source}")
    if source.is_symlink():
        raise ValueError(f"Source root must not be a symlink: {source}")
    if not source.is_dir():
        raise ValueError(f"Source is not a directory: {source}")

    real_source = Path(os.path.realpath(source))
    policy = _load_eligibility_rules(policy_path)
    entries: list[dict[str, Any]] = []
    skipped_symlinks: list[str] = []
    collision_map: dict[str, list[str]] = {}
    hash_groups: dict[str, list[str]] = {}
    probed_count = 0
    unprobed_budget_exceeded = 0
    budget_hit = False

    for dirpath, dirnames, filenames in os.walk(real_source, topdown=True, followlinks=False):
        dirnames.sort()
        filenames.sort()
        # Do not descend into symlinked subdirectories
        kept_dirs = []
        for d in dirnames:
            dp = Path(dirpath) / d
            if dp.is_symlink():
                skipped_symlinks.append(str(dp.relative_to(real_source)))
            else:
                kept_dirs.append(d)
        dirnames[:] = kept_dirs

        for fn in filenames:
            fp = Path(dirpath) / fn
            rel = str(fp.relative_to(real_source))
            if fp.is_symlink():
                skipped_symlinks.append(rel)
                continue
            if probed_count >= max_entries:
                # #136 honest reporting: never silently fold unprobed items into probed INCLUDE counts
                budget_hit = True
                unprobed_budget_exceeded += 1
                continue

            probed_count += 1
            st = os.lstat(fp)
            dataless = _is_dataless(st)
            ext = fp.suffix.lower()
            sha256 = None
            mismatch = False
            mismatch_reason = None
            state = "ok"

            if dataless:
                state = "dataless_cloud_placeholder"
            else:
                try:
                    sha256 = _sha256_file(fp)
                    mismatch, mismatch_reason = _check_magic_mismatch(fp, ext)
                    hash_groups.setdefault(sha256, []).append(rel)
                except OSError as exc:
                    state = f"unreadable:{exc.errno or exc}"

            # Advanced fact probes (gitTracked, nestedRepository, businessEvidence, ...)
            # are not implemented in the Alpha fast path. Unknown facts never satisfy a
            # policy rule; they fall through to the state-based default.
            entry_state = "present" if state in ("ok", "dataless_cloud_placeholder") else "unreadable"
            decision, reason = _classify_entry(
                rel, fn, policy, entry_state=entry_state, hydration_pending=dataless
            )

            ckey = _normalize_collision_key(rel)
            collision_map.setdefault(ckey, []).append(rel)

            entries.append({
                "source_id": _sha256_bytes(f"{st.st_dev}:{st.st_ino}:{rel}".encode("utf-8"))[:16],
                "rel_path": rel,
                "name": fn,
                "ext": ext,
                "size": st.st_size,
                "mtime_ns": st.st_mtime_ns,
                "inode": st.st_ino,
                "device": st.st_dev,
                "sha256": sha256,
                "dataless": dataless,
                "state": state,
                "eligibility": decision,
                "eligibility_reason": reason,
                "extension_mismatch": mismatch,
                "mismatch_reason": mismatch_reason,
            })

    collisions = {k: v for k, v in collision_map.items() if len(v) > 1}
    duplicate_groups = [paths for paths in hash_groups.values() if len(paths) > 1]

    snapshot_core = {
        "schema_version": SCHEMA_VERSION,
        "source_root": str(real_source),
        "cloud_storage_detected": _is_cloud_storage_path(real_source),
        "policy_id": policy.get("policy_id", "unknown"),
        "counts": {
            "probed_total": probed_count,
            "probed_included": sum(1 for e in entries if e["eligibility"] == "INCLUDE"),
            "probed_excluded": sum(1 for e in entries if e["eligibility"] == "EXCLUDE"),
            "probed_review": sum(1 for e in entries if e["eligibility"] == "REVIEW"),
            "unprobed_budget_exceeded": unprobed_budget_exceeded,
            "budget_truncated": budget_hit,
            "skipped_symlinks": len(skipped_symlinks),
            "collision_groups": len(collisions),
            "duplicate_groups": len(duplicate_groups),
        },
        "skipped_symlinks": skipped_symlinks,
        "collisions": collisions,
        "duplicate_groups": duplicate_groups,
        "entries": entries,
    }
    snapshot_core["snapshot_hash"] = _sha256_bytes(_canonical_json(snapshot_core).encode("utf-8"))
    return snapshot_core


def build_plan(snapshot: dict[str, Any], draft_ops: list[dict[str, Any]], dest_root: Path) -> tuple[dict[str, Any], str]:
    if not dest_root.exists():
        raise FileNotFoundError(f"Destination root does not exist: {dest_root}")
    if dest_root.is_symlink() or not dest_root.is_dir():
        raise ValueError(f"Destination root must be a non-symlink directory: {dest_root}")
    real_dest = Path(os.path.realpath(dest_root))

    by_rel = {e["rel_path"]: e for e in snapshot["entries"]}
    seen_sources: set[str] = set()
    seen_dest_keys: set[str] = set()
    operations: list[dict[str, Any]] = []

    for op in draft_ops:
        src_rel = op["source_rel"]
        if src_rel not in by_rel:
            raise ValueError(f"Draft references unknown source_rel: {src_rel}")
        if src_rel in seen_sources:
            raise ValueError(f"Duplicate source_rel in draft: {src_rel}")
        seen_sources.add(src_rel)
        entry = by_rel[src_rel]

        disposition = op["disposition"]
        if disposition not in ("move", "rename", "keep", "review"):
            raise ValueError(f"Invalid disposition {disposition!r} for {src_rel}")

        dest_rel = op.get("dest_rel") or src_rel
        if disposition in ("move", "rename"):
            target_abs = _ensure_dest_target_within(real_dest, dest_rel)
            if Path(dest_rel).suffix.lower() != entry["ext"]:
                raise ValueError(f"Extension change forbidden for {src_rel} -> {dest_rel}")
            dkey = _normalize_collision_key(dest_rel)
            if dkey in seen_dest_keys:
                raise ValueError(f"Destination collision (NFC/case-folded): {dest_rel}")
            seen_dest_keys.add(dkey)
            if target_abs.exists():
                raise ValueError(f"Destination already exists at plan time: {target_abs}")

        operations.append({
            "op_id": _sha256_bytes(f"{entry['source_id']}:{disposition}:{dest_rel}".encode("utf-8"))[:16],
            "source_id": entry["source_id"],
            "source_rel": src_rel,
            "source_sha256": entry["sha256"],
            "source_size": entry["size"],
            "source_mtime_ns": entry["mtime_ns"],
            "source_inode": entry["inode"],
            "disposition": disposition,
            "dest_rel": dest_rel,
            "reason": op.get("reason", ""),
            "evidence": op.get("evidence", ""),
            "uncertainty": op.get("uncertainty", ""),
            "metadata_changes": op.get("metadata_changes", {}),
        })

    plan_core = {
        "schema_version": SCHEMA_VERSION,
        "snapshot_hash": snapshot["snapshot_hash"],
        "source_root": snapshot["source_root"],
        "dest_root": str(real_dest),
        "dest_cloud_storage": _is_cloud_storage_path(real_dest),
        "operations": operations,
    }
    plan_hash = _sha256_bytes(_canonical_json(plan_core).encode("utf-8"))
    plan_core["plan_id"] = plan_hash[:16]
    plan_core["plan_hash"] = plan_hash

    counts = {d: sum(1 for o in operations if o["disposition"] == d) for d in ("move", "rename", "keep", "review")}
    lines = [
        f"# Forma 整理方案预览 (`plan_id: {plan_core['plan_id']}`)",
        "",
        f"- **Plan Hash**: `{plan_hash}`",
        f"- **Snapshot Hash**: `{snapshot['snapshot_hash']}`",
        f"- **Source**: `{snapshot['source_root']}` → **Dest**: `{real_dest}`",
        f"- **Counts**: move={counts['move']}, rename={counts['rename']}, keep={counts['keep']}, review={counts['review']}",
        "",
        "| 原路径 | 处置 | 目标路径 | 理由 | 证据 | 不确定/异常 |",
        "|---|---|---|---|---|---|",
    ]
    for o in operations:
        lines.append(f"| `{o['source_rel']}` | `{o['disposition']}` | `{o['dest_rel']}` | {o['reason']} | {o['evidence']} | {o['uncertainty']} |")
    return plan_core, "\n".join(lines) + "\n"


def _exclusive_rename_os(src: Path, dst: Path) -> None:
    """Platform exclusive no-replace rename. NEVER falls back to overwriting rename()."""
    sys_name = platform.system()
    src_b = os.fsencode(src)
    dst_b = os.fsencode(dst)
    if sys_name == "Darwin":
        libc = ctypes.CDLL("libc.dylib", use_errno=True)
        rc = libc.renamex_np(ctypes.c_char_p(src_b), ctypes.c_char_p(dst_b), ctypes.c_uint(RENAME_EXCL_MACOS))
        if rc != 0:
            err = ctypes.get_errno()
            raise OSError(err, os.strerror(err), str(src), None, str(dst))
        return
    if sys_name == "Linux":
        machine = platform.machine().lower()
        sys_nr = {"x86_64": 316, "amd64": 316, "aarch64": 276, "arm64": 276}.get(machine)
        if sys_nr is None:
            raise OSError(errno.ENOSYS, f"renameat2 syscall number unmapped for {machine}")
        libc = ctypes.CDLL(None, use_errno=True)
        rc = libc.syscall(
            ctypes.c_long(sys_nr),
            ctypes.c_int(AT_FDCWD),
            ctypes.c_char_p(src_b),
            ctypes.c_int(AT_FDCWD),
            ctypes.c_char_p(dst_b),
            ctypes.c_uint(RENAME_NOREPLACE_LINUX),
        )
        if rc != 0:
            err = ctypes.get_errno()
            raise OSError(err, os.strerror(err), str(src), None, str(dst))
        return
    raise OSError(errno.ENOTSUP, f"Exclusive no-replace rename unsupported on {sys_name}")


def _move_no_replace(
    src: Path,
    dst: Path,
    expected_sha256: str | None,
    rename_fn: Callable[[Path, Path], None] = _exclusive_rename_os,
) -> str:
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        rename_fn(src, dst)
        return "atomic_no_replace"
    except OSError as exc:
        if exc.errno == errno.EXDEV:
            # Cross-volume safe move: copy to temp in dest dir, verify SHA-256, exclusive rename into dst, unlink src
            tmp = dst.parent / f".forma-tmp-{os.getpid()}-{time.time_ns()}"
            try:
                shutil.copy2(src, tmp)
                if expected_sha256 and _sha256_file(tmp) != expected_sha256:
                    raise ValueError(f"Cross-volume copy checksum mismatch for {src}")
                rename_fn(tmp, dst)
            except Exception:
                if tmp.exists():
                    tmp.unlink()
                raise
            os.unlink(src)
            return "cross_volume_verified_no_replace"
        raise


def _append_journal(journal_path: Path, event: dict[str, Any]) -> None:
    journal_path.parent.mkdir(parents=True, exist_ok=True)
    with journal_path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")
        f.flush()
        os.fsync(f.fileno())


def _load_journal(journal_path: Path) -> list[dict[str, Any]]:
    if not journal_path.exists():
        return []
    return [json.loads(line) for line in journal_path.read_text(encoding="utf-8").splitlines() if line.strip()]


def _compute_plan_hash(plan: dict[str, Any]) -> str:
    core = {k: v for k, v in plan.items() if k not in ("plan_id", "plan_hash")}
    return _sha256_bytes(_canonical_json(core).encode("utf-8"))


def execute_plan(
    plan: dict[str, Any],
    state_dir: Path,
    execute: bool = False,
    approve_plan_hash: str | None = None,
    approve_snapshot_hash: str | None = None,
    allow_file_provider: bool = False,
    rename_fn: Callable[[Path, Path], None] = _exclusive_rename_os,
    pre_move_hook: Callable[[Path, Path], None] | None = None,
) -> dict[str, Any]:
    src_root = Path(plan["source_root"])
    dst_root = Path(plan["dest_root"])

    # #1 CRITICAL: always recompute plan_hash over canonical plan content (prevents post-approval tampering)
    recomputed_hash = _compute_plan_hash(plan)
    if recomputed_hash != plan.get("plan_hash"):
        raise PermissionError(f"Plan integrity check failed: tampered plan (stored={plan.get('plan_hash')}, actual={recomputed_hash})")

    if execute and (approve_plan_hash != recomputed_hash or approve_snapshot_hash != plan["snapshot_hash"]):
        raise PermissionError("Approval mismatch: plan_hash or snapshot_hash does not match approved values")

    if execute and (plan.get("dest_cloud_storage") or _is_cloud_storage_path(src_root) or _is_cloud_storage_path(dst_root)) and not allow_file_provider:
        raise PermissionError("CloudStorage/OneDrive path detected: atomic RENAME_EXCL unverified; pass --allow-file-provider only in isolated tests")

    journal_path = state_dir / "journal.jsonl"
    existing_events = _load_journal(journal_path)
    completed_ops = {e["op_id"] for e in existing_events if e.get("phase") == "COMMITTED" and e.get("plan_hash") == recomputed_hash}
    intent_ops = {e["op_id"] for e in existing_events if e.get("phase") == "INTENT" and e.get("plan_hash") == recomputed_hash}

    # Pre-flight validation runs for BOTH dry-run and execute
    total_move_bytes = 0
    preflight_results: list[dict[str, Any]] = []
    resumed_ops: set[str] = set()
    for op in plan["operations"]:
        if op["disposition"] not in ("move", "rename"):
            preflight_results.append({"op_id": op["op_id"], "status": f"NOOP_{op['disposition'].upper()}"})
            continue
        if op["op_id"] in completed_ops:
            preflight_results.append({"op_id": op["op_id"], "status": "SKIP_VERIFIED"})
            continue

        src = _ensure_within(src_root, src_root / op["source_rel"])
        dst = _ensure_dest_target_within(dst_root, op["dest_rel"])

        # Crash-between-rename-and-COMMITTED resume detection
        if op["op_id"] in intent_ops and not src.exists() and dst.exists() and not dst.is_symlink():
            if not op["source_sha256"] or _sha256_file(dst) == op["source_sha256"]:
                resumed_ops.add(op["op_id"])
                preflight_results.append({"op_id": op["op_id"], "status": "WOULD_RESUME_VERIFIED", "src": str(src), "dest": str(dst)})
                continue

        if src.is_symlink() or not src.exists():
            raise ValueError(f"Stale plan: source missing or symlink: {src}")
        st = os.lstat(src)
        if _is_dataless(st):
            raise ValueError(f"Refusing to move dataless placeholder: {src}")
        if not os.access(src, os.R_OK):
            raise PermissionError(f"Source not readable: {src}")
        if op["source_sha256"] and _sha256_file(src) != op["source_sha256"]:
            raise ValueError(f"Stale plan: source content changed since snapshot: {src}")
        if dst.exists():
            raise FileExistsError(f"Destination exists at preflight: {dst}")
        total_move_bytes += st.st_size
        preflight_results.append({"op_id": op["op_id"], "status": "WOULD_APPLY", "src": str(src), "dest": str(dst)})

    # Available disk space check on dest_root
    if hasattr(os, "statvfs") and total_move_bytes > 0:
        vfs = os.statvfs(dst_root)
        free_bytes = vfs.f_bavail * vfs.f_frsize
        if free_bytes < total_move_bytes:
            raise OSError(errno.ENOSPC, f"Insufficient space at {dst_root}: need {total_move_bytes}, free {free_bytes}")

    if not execute:
        return {"status": "DRY_RUN", "plan_id": plan["plan_id"], "plan_hash": recomputed_hash, "results": preflight_results}

    state_dir.mkdir(parents=True, exist_ok=True)
    lock_path = state_dir / "writer.lock"
    results: list[dict[str, Any]] = []

    with lock_path.open("w") as lockf:
        try:
            fcntl.flock(lockf.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError("Single-writer lock held by another process") from exc

        for op in plan["operations"]:
            if op["disposition"] not in ("move", "rename"):
                results.append({"op_id": op["op_id"], "status": f"NOOP_{op['disposition'].upper()}"})
                continue
            if op["op_id"] in completed_ops:
                results.append({"op_id": op["op_id"], "status": "SKIP_VERIFIED"})
                continue

            src = _ensure_within(src_root, src_root / op["source_rel"])
            dst = _ensure_dest_target_within(dst_root, op["dest_rel"])
            if op["op_id"] in resumed_ops:
                _append_journal(journal_path, {
                    "ts": time.time(),
                    "phase": "COMMITTED",
                    "plan_hash": recomputed_hash,
                    "op_id": op["op_id"],
                    "src": str(src),
                    "dst": str(dst),
                    "expected_sha256": op["source_sha256"],
                    "mode": "resumed_after_intent",
                })
                results.append({"op_id": op["op_id"], "status": "RESUMED_VERIFIED", "dest": str(dst)})
                continue

            _append_journal(journal_path, {
                "ts": time.time(),
                "phase": "INTENT",
                "plan_hash": recomputed_hash,
                "op_id": op["op_id"],
                "src": str(src),
                "dst": str(dst),
                "expected_sha256": op["source_sha256"],
            })

            if pre_move_hook is not None:
                pre_move_hook(src, dst)

            try:
                mode = _move_no_replace(src, dst, op["source_sha256"], rename_fn=rename_fn)
                # Post-apply independent verification: src absent, dst present & SHA-256 matches
                verified = (not src.exists()) and dst.exists() and (not dst.is_symlink()) and (
                    not op["source_sha256"] or _sha256_file(dst) == op["source_sha256"]
                )
                if not verified:
                    raise ValueError(f"Post-apply verification failed for {dst}")
                _append_journal(journal_path, {
                    "ts": time.time(),
                    "phase": "COMMITTED",
                    "plan_hash": recomputed_hash,
                    "op_id": op["op_id"],
                    "src": str(src),
                    "dst": str(dst),
                    "expected_sha256": op["source_sha256"],
                    "mode": mode,
                })
                results.append({"op_id": op["op_id"], "status": "APPLIED", "mode": mode, "dest": str(dst), "verified": True})
            except OSError as exc:
                status = "CONFLICT_HOLD" if exc.errno == errno.EEXIST else "FAIL_CLOSED"
                _append_journal(journal_path, {
                    "ts": time.time(),
                    "phase": status,
                    "plan_hash": recomputed_hash,
                    "op_id": op["op_id"],
                    "src": str(src),
                    "dst": str(dst),
                    "errno": exc.errno,
                    "error": str(exc),
                })
                results.append({"op_id": op["op_id"], "status": status, "errno": exc.errno, "error": str(exc)})

    has_failures = any(r["status"] in ("CONFLICT_HOLD", "FAIL_CLOSED") for r in results)
    report = {
        "status": "PARTIAL_OR_FAILED" if has_failures else "APPLIED_VERIFIED",
        "plan_id": plan["plan_id"],
        "plan_hash": recomputed_hash,
        "snapshot_hash": plan["snapshot_hash"],
        "results": results,
    }
    (state_dir / "verify_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return report


def cleanup_empty_dirs(source_root: Path, dirs: list[str], approve_hash: str | None, execute: bool) -> dict[str, Any]:
    real_root = Path(os.path.realpath(source_root))
    payload_hash = _sha256_bytes(_canonical_json({"source_root": str(real_root), "dirs": sorted(dirs)}).encode("utf-8"))
    if not execute:
        return {"status": "DRY_RUN", "cleanup_hash": payload_hash, "dirs": sorted(dirs)}
    if approve_hash != payload_hash:
        raise PermissionError("Cleanup approval hash mismatch")
    removed, skipped = [], []
    for rel in sorted(dirs, key=lambda s: len(Path(s).parts), reverse=True):
        target = _ensure_within(real_root, real_root / rel)
        if target == real_root or target.is_symlink() or not target.is_dir():
            skipped.append({"dir": rel, "reason": "invalid_or_root"})
            continue
        try:
            os.rmdir(target)  # strictly empty only; never recursive
            removed.append(rel)
        except OSError as exc:
            skipped.append({"dir": rel, "reason": str(exc)})
    return {"status": "CLEANUP_COMPLETE", "removed": removed, "skipped": skipped}


def recover_journal(
    journal_path: Path,
    mode: str = "inspect",
    execute: bool = False,
    rename_fn: Callable[[Path, Path], None] = _exclusive_rename_os,
) -> dict[str, Any]:
    events = _load_journal(journal_path)
    by_op: dict[str, dict[str, Any]] = {}
    for ev in events:
        op_id = ev["op_id"]
        by_op.setdefault(op_id, {"op_id": op_id, "phases": []})
        by_op[op_id].update({k: v for k, v in ev.items() if k in ("src", "dst", "expected_sha256", "plan_hash")})
        by_op[op_id]["phases"].append(ev["phase"])

    report = []
    for op_id, info in by_op.items():
        src, dst = Path(info["src"]), Path(info["dst"])
        exp = info.get("expected_sha256")
        src_ok = src.exists() and not src.is_symlink() and (not exp or _sha256_file(src) == exp)
        dst_ok = dst.exists() and not dst.is_symlink() and (not exp or _sha256_file(dst) == exp)

        if dst_ok and not src.exists():
            state = "exists_at_dest"
        elif src_ok and not dst.exists():
            state = "missing_at_dest_src_intact"
        elif dst.exists() and not dst_ok:
            state = "conflict_dest_modified"
        else:
            state = "unknown_manual_check"

        action = "NONE"
        if mode == "rollback" and execute:
            if state == "exists_at_dest":
                try:
                    _move_no_replace(dst, src, exp, rename_fn=rename_fn)
                    _append_journal(journal_path, {"ts": time.time(), "phase": "ROLLED_BACK", "op_id": op_id, "src": str(src), "dst": str(dst)})
                    action = "ROLLED_BACK"
                except OSError as exc:
                    action = f"ROLLBACK_BLOCKED:{exc.errno}"
            elif state == "conflict_dest_modified":
                action = "CONFLICT_HOLD_USER_EDIT"
            else:
                action = "SKIPPED"
        report.append({"op_id": op_id, "state": state, "phases": info["phases"], "action": action})
    return {"status": "RECOVER_REPORT", "mode": mode, "operations": report}


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Forma WorkBuddy deterministic filesystem safety kernel")
    sub = p.add_subparsers(dest="cmd", required=True)

    s_ins = sub.add_parser("inspect")
    s_ins.add_argument("--source", required=True)
    s_ins.add_argument("--out", required=True)
    s_ins.add_argument("--max-entries", type=int, default=5000)

    s_pln = sub.add_parser("plan")
    s_pln.add_argument("--snapshot", required=True)
    s_pln.add_argument("--draft", required=True)
    s_pln.add_argument("--dest", required=True)
    s_pln.add_argument("--out", required=True)
    s_pln.add_argument("--summary")

    s_app = sub.add_parser("apply")
    s_app.add_argument("--plan", required=True)
    s_app.add_argument("--state-dir", required=True)
    s_app.add_argument("--approve-plan-hash")
    s_app.add_argument("--approve-snapshot-hash")
    s_app.add_argument("--execute", action="store_true")
    s_app.add_argument("--allow-file-provider", action="store_true")

    s_cln = sub.add_parser("cleanup-empty")
    s_cln.add_argument("--source", required=True)
    s_cln.add_argument("--dirs-json", required=True)
    s_cln.add_argument("--approve-cleanup-hash")
    s_cln.add_argument("--execute", action="store_true")

    s_rec = sub.add_parser("recover")
    s_rec.add_argument("--journal", required=True)
    s_rec.add_argument("--mode", choices=["inspect", "rollback"], default="inspect")
    s_rec.add_argument("--execute", action="store_true")

    args = p.parse_args(argv)
    if args.cmd == "inspect":
        snap = inspect_directory(Path(args.source), max_entries=args.max_entries)
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(snap, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps({"snapshot_hash": snap["snapshot_hash"], "counts": snap["counts"]}, ensure_ascii=False))
    elif args.cmd == "plan":
        snap = json.loads(Path(args.snapshot).read_text(encoding="utf-8"))
        draft = json.loads(Path(args.draft).read_text(encoding="utf-8"))
        plan_obj, md = build_plan(snap, draft, Path(args.dest))
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(plan_obj, ensure_ascii=False, indent=2), encoding="utf-8")
        if args.summary:
            Path(args.summary).write_text(md, encoding="utf-8")
        print(json.dumps({"plan_id": plan_obj["plan_id"], "plan_hash": plan_obj["plan_hash"]}, ensure_ascii=False))
    elif args.cmd == "apply":
        plan_obj = json.loads(Path(args.plan).read_text(encoding="utf-8"))
        res = execute_plan(
            plan_obj,
            Path(args.state_dir),
            execute=args.execute,
            approve_plan_hash=args.approve_plan_hash,
            approve_snapshot_hash=args.approve_snapshot_hash,
            allow_file_provider=args.allow_file_provider,
        )
        print(json.dumps(res, ensure_ascii=False, indent=2))
    elif args.cmd == "cleanup-empty":
        dirs = json.loads(Path(args.dirs_json).read_text(encoding="utf-8"))
        res = cleanup_empty_dirs(Path(args.source), dirs, args.approve_cleanup_hash, args.execute)
        print(json.dumps(res, ensure_ascii=False, indent=2))
    elif args.cmd == "recover":
        res = recover_journal(Path(args.journal), mode=args.mode, execute=args.execute)
        print(json.dumps(res, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
