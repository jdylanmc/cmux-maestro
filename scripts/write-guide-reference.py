#!/usr/bin/env python3
"""Write only the canonical guide's digest into the containing app's resources."""

import hashlib
from pathlib import Path
import sys


def write_reference(source, destination):
    with Path(source).open("rb") as stream:
        content = stream.read(65_537)
    if not 0 < len(content) <= 65_536:
        raise ValueError("Canonical Maestro guide is empty or exceeds 64 KiB.")
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(hashlib.sha256(content).hexdigest() + "\n", encoding="ascii")


if __name__ == "__main__":
    write_reference(sys.argv[1], sys.argv[2])
