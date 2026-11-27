#!/usr/bin/env python3
"""Stdlib-only validator for the disposable M1-A WorkBuddy probe."""
import json
import os
import re
import struct
import subprocess
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
EXPERT = ROOT / "expert"
AVATAR = EXPERT / "avatars" / "expert.png"


def make_512x512_png(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    w, h = 512, 512
    # Solid slate-blue RGBA scanlines (filter byte 0 + 512*4 bytes)
    row = b"\x00" + (b"\x2b\x4c\x7e\xff" * w)
    raw = row * h
    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.write_bytes(png)


def main() -> None:
    if not AVATAR.exists():
        make_512x512_png(AVATAR)
    png_bytes = AVATAR.read_bytes()
    assert png_bytes[:8] == b"\x89PNG\r\n\x1a\n", "Not a valid PNG"
    w, h = struct.unpack(">II", png_bytes[16:24])
    assert (w, h) == (512, 512), f"Avatar must be 512x512, got {w}x{h}"
    assert len(png_bytes) <= 500 * 1024, f"Avatar too large: {len(png_bytes)}"

    pj = json.loads((EXPERT / ".codebuddy-plugin" / "plugin.json").read_text(encoding="utf-8"))
    for k in ["name", "version", "description", "author", "expertType", "agentName", "agents", "displayName", "profession", "displayDescription", "avatar", "categoryId", "defaultInitPrompt", "plugin", "tags", "quickPrompts"]:
        assert k in pj, f"Missing plugin.json field: {k}"
    assert re.fullmatch(r"[a-z0-9-]+", pj["name"]), "name must be lowercase hyphenated"
    assert pj["plugin"] == pj["name"], "plugin must match name"
    assert pj["expertType"] == "agent"
    assert pj["categoryId"] == "04-DataAI"
    zh_desc_len = len(pj["displayDescription"]["zh"])
    assert 40 <= zh_desc_len <= 50, f"displayDescription.zh must be 40-50 chars, got {zh_desc_len}"
    assert len(pj["tags"]) == 3
    assert len(pj["quickPrompts"]) == 3
    assert pj["defaultInitPrompt"] == pj["quickPrompts"][0], "defaultInitPrompt must match quickPrompts[0]"

    agent_md = (EXPERT / "agents" / f"{pj['agentName']}.md").read_text(encoding="utf-8")
    fm = agent_md.split("---", 2)[1]
    assert not re.search(r"^\s*tools\s*:", fm, re.M), "Agent frontmatter MUST NOT declare tools"

    skill_md = (EXPERT / "skills" / "forma-host-probe" / "SKILL.md").read_text(encoding="utf-8")
    for k in ["name:", "display_name:", "display_name_en:", "description:", "description_zh:", "description_en:", "version:", "author:"]:
        assert k in skill_md, f"Missing SKILL.md field: {k}"

    script = EXPERT / "skills" / "forma-host-probe" / "scripts" / "host_probe.sh"
    os.chmod(script, 0o755)
    res = subprocess.run(["sh", str(script), str(ROOT / "synthetic-fixture")], capture_output=True, text=True, check=True)
    assert "REF_CHECK=OK" in res.stdout
    assert "TARGET_DIR_STATUS=READABLE_DIR" in res.stdout
    assert "sample-contract.txt" in res.stdout
    print(f"PROBE_VALIDATOR_PASS (zh_desc_len={zh_desc_len}, avatar_bytes={len(png_bytes)})")


if __name__ == "__main__":
    main()
