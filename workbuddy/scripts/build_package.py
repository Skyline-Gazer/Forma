#!/usr/bin/env python3
"""Validate official WorkBuddy Expert/Skill constraints and build a reproducible versioned .zip + .sha256."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import sys
import zipfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXPERT_DIR = ROOT / "forma-expert"
DIST_DIR = ROOT / "dist"
FIXED_ZIP_TIME = (2026, 11, 27, 0, 0, 0)


def ensure_512x512_png(path: Path) -> bytes:
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        w, h = 512, 512
        row = b"\x00" + (b"\x1f\x4e\x79\xff" * w)
        raw = row * h
        def chunk(tag: bytes, data: bytes) -> bytes:
            return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
        path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "Avatar must be PNG"
    w, h = struct.unpack(">II", data[16:24])
    assert (w, h) == (512, 512), f"Avatar must be 512x512, got {w}x{h}"
    assert len(data) <= 500 * 1024, f"Avatar exceeds 500KB: {len(data)}"
    return data


def validate_expert() -> dict:
    pj_path = EXPERT_DIR / ".codebuddy-plugin" / "plugin.json"
    pj = json.loads(pj_path.read_text(encoding="utf-8"))
    required = [
        "name", "version", "description", "author", "expertType", "agentName",
        "agents", "displayName", "profession", "displayDescription", "avatar",
        "categoryId", "defaultInitPrompt", "plugin", "tags", "quickPrompts",
    ]
    for k in required:
        assert k in pj, f"Missing plugin.json field: {k}"
    assert re.fullmatch(r"[a-z0-9-]+", pj["name"]), "name must be lowercase hyphenated"
    assert pj["plugin"] == pj["name"], "plugin must match name"
    assert pj["expertType"] == "agent"
    assert pj["categoryId"] == "04-DataAI"
    assert isinstance(pj["author"], dict) and pj["author"].get("name") and pj["author"].get("email")
    zh_len = len(pj["displayDescription"]["zh"])
    assert 40 <= zh_len <= 50, f"displayDescription.zh must be 40-50 chars, got {zh_len}"
    assert len(pj["tags"]) == 3
    assert len(pj["quickPrompts"]) == 3
    assert pj["defaultInitPrompt"] == pj["quickPrompts"][0]
    assert "dependencies" not in pj, "DEVONthink must remain optional, not a required dependency"

    ensure_512x512_png(EXPERT_DIR / pj["avatar"])

    agent_path = EXPERT_DIR / "agents" / f"{pj['agentName']}.md"
    assert agent_path.exists(), f"Missing agent file: {agent_path}"
    fm = agent_path.read_text(encoding="utf-8").split("---", 2)[1]
    assert not re.search(r"^\s*tools\s*:", fm, re.M), "Agent frontmatter MUST NOT declare tools"

    for skill_rel in pj.get("skills", []):
        sdir = (EXPERT_DIR / skill_rel).resolve()
        sfile = sdir / "SKILL.md"
        assert sfile.exists(), f"Missing SKILL.md: {sfile}"
        stext = sfile.read_text(encoding="utf-8")
        for req in ["name:", "display_name:", "display_name_en:", "description:", "description_zh:", "description_en:", "version:", "author:"]:
            assert req in stext, f"Missing {req} in {sfile}"
        for ref in re.findall(r"@(references/[^\s`]+)", stext):
            assert (sdir / ref).exists(), f"Missing referenced file {ref} in {sdir}"
        for scr in re.findall(r"(scripts/[A-Za-z0-9_.-]+)", stext):
            assert (sdir / scr).exists(), f"Missing script {scr} in {sdir}"

    assert (EXPERT_DIR / "README.md").exists(), "Missing README.md"
    return pj


def build_reproducible_zip(pj: dict) -> tuple[Path, str]:
    DIST_DIR.mkdir(parents=True, exist_ok=True)
    zip_name = f"{pj['name']}-{pj['version']}.zip"
    zip_path = DIST_DIR / zip_name
    files = sorted(p for p in EXPERT_DIR.rglob("*") if p.is_file() and "__pycache__" not in p.parts)
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for fp in files:
            arcname = str(Path("forma-expert") / fp.relative_to(EXPERT_DIR))
            zi = zipfile.ZipInfo(arcname, date_time=FIXED_ZIP_TIME)
            zi.external_attr = (0o755 if fp.suffix in (".sh", ".py") else 0o644) << 16
            zf.writestr(zi, fp.read_bytes())
    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    (DIST_DIR / f"{zip_name}.sha256").write_text(f"{digest}  {zip_name}\n", encoding="utf-8")
    return zip_path, digest


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="Validate and test reproducibility without keeping dist artifacts")
    args = ap.parse_args()
    pj = validate_expert()
    zip_path, digest1 = build_reproducible_zip(pj)
    if args.check:
        _, digest2 = build_reproducible_zip(pj)
        assert digest1 == digest2, "Non-reproducible zip build"
        print(f"PACKAGE_VALID_AND_REPRODUCIBLE name={pj['name']} version={pj['version']} sha256={digest1}")
    else:
        print(f"BUILT {zip_path} sha256={digest1}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
