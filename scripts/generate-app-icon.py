#!/usr/bin/env python3
"""Regenerate macOS icon sizes from the checked-in 1024px master using sips."""

import json
from pathlib import Path
import struct
import subprocess


ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "CMUXMaestroPreview/Assets.xcassets/AppIcon.appiconset"
MASTER = ICONSET / "icon_512x512@2x.png"


def dimensions(path):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or len(data) < 24:
        raise ValueError(f"Not a PNG: {path}")
    return struct.unpack(">II", data[16:24])


def main():
    if dimensions(MASTER) != (1024, 1024):
        raise ValueError("The app icon master must be exactly 1024x1024 pixels")
    images = json.loads((ICONSET / "Contents.json").read_text())["images"]
    for image in images:
        output = ICONSET / image["filename"]
        points = int(image["size"].split("x")[0])
        pixels = points * int(image["scale"].removesuffix("x"))
        if output != MASTER:
            subprocess.run([
                "/usr/bin/sips", "--resampleHeightWidth", str(pixels), str(pixels),
                str(MASTER), "--out", str(output),
            ], check=True, stdout=subprocess.DEVNULL)
        if dimensions(output) != (pixels, pixels):
            raise ValueError(f"Wrong exported dimensions: {output}")
        print(f"{output.name}: {pixels}x{pixels}")


if __name__ == "__main__":
    main()
