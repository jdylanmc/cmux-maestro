#!/usr/bin/env python3
"""Explicit offline legacy-pet copy upgrade; never edits or selects the source pet.

Requires development-time Pillow. Copies generic fallback poses, not inferred
facial expressions. Output must be a NEW folder in an existing directory.
"""
import argparse
import hashlib
import io
import json
import math
import sys
from pathlib import Path

from PIL import Image

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / ".agents/skills/maestro-pet"))
from pet_kit import EXTENDED_STATES, MOOD_FALLBACKS, PET_ID, STATES

MAX_BYTES = 10 * 1024 * 1024


def read_regular(path, limit):
    if path.is_symlink() or not path.is_file():
        raise ValueError("Source must be a regular file, not a symlink.")
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Source exceeds the byte limit.")
    return data


def upgrade(source, output, pet_id, name):
    source, output = Path(source).absolute(), Path(output).absolute()
    if not PET_ID.fullmatch(pet_id) or len(pet_id) > 48 or pet_id == "maestro":
        raise ValueError("Choose a non-reserved pet ID of 1-48 lowercase letters/digits/hyphens.")
    if not name.strip() or len(name) > 64 or any(ord(c) < 32 or ord(c) == 127 for c in name):
        raise ValueError("Name must contain 1-64 printable characters.")
    if output.exists() or output.is_symlink() or not output.parent.is_dir():
        raise ValueError("Output must be a new folder in an existing directory.")
    if source.is_symlink():
        raise ValueError("Source symlinks are refused.")
    manifest_data = None
    if source.is_dir():
        # A supplied folder is an input, never a discovery root or installation target.
        if output.resolve().is_relative_to(source.resolve()):
            raise ValueError("Output must be outside the source folder.")
        manifest_data = read_regular(source / "pet.json", 64 * 1024)
        manifest = json.loads(manifest_data)
        sheet_name = manifest.get("spritesheetPath") if isinstance(manifest, dict) else None
        if (not isinstance(sheet_name, str) or not sheet_name
                or Path(sheet_name).name != sheet_name or sheet_name in (".", "..")
                or "\\" in sheet_name):
            raise ValueError("spritesheetPath must name a direct child file.")
        source = source / sheet_name
    data = read_regular(source, MAX_BYTES)
    with Image.open(io.BytesIO(data)) as decoded:
        width, height = decoded.size
        legacy_height = math.ceil(9 * 208 * width / 1536)
        if (decoded.format not in ("PNG", "WEBP") or getattr(decoded, "n_frames", 1) != 1
                or width % 8 or not 512 <= width <= 1536
                or not legacy_height <= height <= 2 * width):
            raise ValueError("Expected a static legacy PNG/WebP, width 512-1536 divisible by 8.")
        original = decoded.convert("RGBA")
    cell_width, cell_height = width // 8, 208 * width / 1536
    atlas = Image.new("RGBA", (width, math.ceil(20 * cell_height)))
    atlas.paste(original.crop((0, 0, width, legacy_height)), (0, 0))
    legacy_rows = {state: (row, count) for row, (state, count) in enumerate(STATES)}
    for row, (state, count) in enumerate(EXTENDED_STATES):
        if row < 9 or not count:
            continue
        fallback, fallback_count = legacy_rows[MOOD_FALLBACKS[state]]
        top, bottom = round(row * cell_height), round((row + 1) * cell_height)
        old_top, old_bottom = round(fallback * cell_height), round((fallback + 1) * cell_height)
        # At fractional scales, the row-9 boundary must not overwrite legacy pixels.
        top = max(top, legacy_height)
        for column in range(count):
            old_column = column % fallback_count
            cell = original.crop((old_column * cell_width, old_top,
                                  (old_column + 1) * cell_width, old_bottom))
            if cell.height != bottom - top:
                cell = cell.resize((cell_width, bottom - top), Image.Resampling.NEAREST)
            atlas.paste(cell, (column * cell_width, top))
    if atlas.crop((0, 0, width, legacy_height)).tobytes() != original.crop((0, 0, width, legacy_height)).tobytes():
        raise ValueError("Legacy pixel preservation failed.")
    encoded = io.BytesIO()
    atlas.save(encoded, format="PNG")
    if len(encoded.getvalue()) > MAX_BYTES:
        raise ValueError("Upgraded sheet exceeds the import limit.")
    report = {
        "kind": "generic-fallback-copy", "sourceSHA256": hashlib.sha256(data).hexdigest(),
        "legacyRGBA_SHA256": hashlib.sha256(original.crop((0, 0, width, legacy_height)).tobytes()).hexdigest(),
        "size": list(atlas.size), "sourceUnchanged": True,
        "note": "No facial anatomy inferred. Inspect and author distinct moods before choosing this copy.",
    }
    files = {
        "spritesheet.png": encoded.getvalue(),
        "original-sheet" + (".png" if data.startswith(b"\x89PNG") else ".webp"): data,
        "pet.json": (json.dumps({
            "id": pet_id, "displayName": name,
            "description": "Legacy pet copy with generic mood fallbacks; no inferred expressions.",
            "spritesheetPath": "spritesheet.png",
        }, indent=2) + "\n").encode(),
        "upgrade.json": (json.dumps(report, indent=2) + "\n").encode(),
    }
    if manifest_data is not None:
        files["original-pet.json"] = manifest_data
    # Exclusive directory creation refuses races with an existing destination.
    output.mkdir()
    for filename, contents in files.items():
        with (output / filename).open("xb") as stream:
            stream.write(contents)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Supplied legacy folder or sheet; read-only.")
    parser.add_argument("--output", type=Path, required=True, help="New copy, never an installed pet directory.")
    parser.add_argument("--id", required=True, help="New pet ID.")
    parser.add_argument("--name", required=True)
    args = parser.parse_args()
    try:
        result = upgrade(args.source, args.output, args.id, args.name)
    except (ValueError, OSError) as error:
        parser.exit(1, f"Upgrade refused: {error}\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
