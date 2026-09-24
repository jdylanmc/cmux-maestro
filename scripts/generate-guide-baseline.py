#!/usr/bin/env python3
"""Generate build-bound guide digests, never distribute the guide bodies."""

import argparse
import hashlib
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    files = {}
    for name in ("SKILL.md", "intent.md"):
        path = args.source / name
        if path.is_symlink() or not path.is_file():
            parser.error(f"Guide source must be a regular file: {path}")
        data = path.read_bytes()
        if not 0 < len(data) <= 262_144:
            parser.error(f"Guide source must be nonempty and at most 256 KiB: {path}")
        files[name] = hashlib.sha256(data).hexdigest()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"version": 1, "files": files}, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
