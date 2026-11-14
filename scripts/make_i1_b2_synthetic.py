#!/usr/bin/env python3
"""Emit the I1-B2 synthetic import fixtures deterministically.

The bytes are fixed in this file so the SHA-256 values recorded in
docs/I1-B2-AUTHORIZATION-PROPOSAL.md are reproducible without trusting a
committed binary blob. Nothing here touches DEVONthink.
"""
import hashlib
import json
import pathlib
import sys

FILES = {
    "forma-b1-probe-01.md": b"# Forma synthetic import probe\n\nsynthetic only\n",
    "forma-b1-probe-02.txt": b"FORMA B1 SYNTHETIC RECORD\nno business data\n",
    "forma-b1-probe-03.csv": b"field,value\nprojectname,FORMA-SYNTHETIC-001\ndocumentcategory,99_TEST\n",
    "forma-b1-probe-04.png": bytes.fromhex(
        "89504e470d0a1a0a0000000d4948445200000001000000010806000000"
        "1f15c4890000000a49444154789c6360000002000100ffff0300000600"
        "0557bfabd40000000049454e44ae426082"
    ),
}


def main(argv):
    if len(argv) != 2:
        print("usage: make_i1_b2_synthetic.py <output-directory>", file=sys.stderr)
        return 2
    out = pathlib.Path(argv[1])
    out.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for name, payload in FILES.items():
        path = out / name
        if path.exists() and path.read_bytes() != payload:
            print(f"refusing to overwrite a different file: {path}", file=sys.stderr)
            return 1
        path.write_bytes(payload)
        manifest[name] = {"bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}
    (out / "synthetic-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
