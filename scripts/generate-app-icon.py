#!/usr/bin/env python3
"""Prepare full-bleed SVGs for the Icon Composer raster masters."""

from pathlib import Path
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / ".build/app-icon-source"
NS = "{http://www.w3.org/2000/svg}"
TILE_PATH = "M72 16H184Q240 16 240 72V184Q240 240 184 240H72Q16 240 16 184V72Q16 16 72 16Z"


def main():
    ET.register_namespace("", NS[1:-1])
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for appearance, name in (("light", "AppIcon.svg"), ("dark", "AppIcon-dark.svg")):
        svg = ET.fromstring((ROOT / "Resources" / name).read_text())
        paths = svg.findall(f"{NS}path")
        gradient = svg.find(f"{NS}defs/{NS}linearGradient[@id='tile']")
        if not paths or paths[0].get("d") != TILE_PATH or gradient is None:
            raise ValueError(f"{name}: update the canvas mapping for the changed tile geometry")
        # Preserve the approved composition; Composer supplies the outer mask.
        svg.set("viewBox", "16 16 224 224")
        gradient.attrib.update({
            "gradientUnits": "userSpaceOnUse", "x1": "38.4", "y1": "16",
            "x2": "195.2", "y2": "240",
        })
        index = list(svg).index(paths[0])
        svg.remove(paths[0])
        svg.insert(index, ET.Element(f"{NS}rect", {
            "x": "16", "y": "16", "width": "224", "height": "224",
            "fill": "url(#tile)",
        }))
        output = OUTPUT / f"Glacier-{appearance}.svg"
        output.write_text(ET.tostring(svg, encoding="unicode") + "\n")
        print(output.relative_to(ROOT))


if __name__ == "__main__":
    main()
