#!/usr/bin/env python3
"""Dependency-free kit for drawing a Codex-compatible Maestro pet.

Python 3.9+ standard library only: no Pillow, network, image provider or API key.
Import it from your own drawing script, draw each frame, then save the pet folder:

    import sys; sys.dont_write_bytecode = True; sys.path.insert(0, SKILL_DIR)
    from pet_kit import PetSheet, MAESTRO_STATES

    sheet = PetSheet()
    for state, count in MAESTRO_STATES:
        for index in range(count):
            frame = sheet.frame(state, index)      # 192x208 transparent canvas
            frame.ellipse(96, 120, 50, 56, "#5fb3ff")
    print(sheet.save("<new-folder>", "my-pet", "My Pet"))

The kit never selects a pet, reads session state or touches Maestro's files; add the
saved folder with `cmux-maestro-orchestrator pet --self ... --add <folder>`.
"""
import json
import math
import re
import struct
import sys
import zlib
from pathlib import Path

CELL_WIDTH, CELL_HEIGHT, COLUMNS = 192, 208, 8
# Codex row order and frame counts; Maestro's sidebar uses the same table.
STATES = (
    ("idle", 6), ("running-right", 8), ("running-left", 8), ("waving", 4), ("jumping", 5),
    ("failed", 8), ("waiting", 6), ("running", 6), ("review", 6),
)
# Rows the Maestro sidebar plays: idle, finished (waving), failed, needs input, working.
MAESTRO_STATES = tuple((name, count) for name, count in STATES
                       if name in ("idle", "waving", "failed", "waiting", "running"))
SHEET_WIDTH, SHEET_HEIGHT = COLUMNS * CELL_WIDTH, len(STATES) * CELL_HEIGHT
PET_ID = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
_COUNTS = dict(STATES)
_ROWS = {name: row for row, (name, _) in enumerate(STATES)}


def rgba(color):
    """Accept '#rgb', '#rrggbb', '#rrggbbaa' or an (r, g, b[, a]) tuple."""
    if isinstance(color, str):
        text = color.lstrip("#")
        if len(text) == 3:
            text = "".join(character * 2 for character in text)
        if len(text) not in (6, 8) or not re.fullmatch(r"[0-9a-fA-F]+", text):
            raise ValueError(f"Invalid color {color!r}.")
        values = [int(text[i:i + 2], 16) for i in range(0, len(text), 2)]
    else:
        values = [int(value) for value in color]
    if len(values) == 3:
        values.append(255)
    if len(values) != 4 or any(not 0 <= value <= 255 for value in values):
        raise ValueError(f"Invalid color {color!r}.")
    return tuple(values)


class Canvas:
    """Straight-alpha RGBA pixels with source-over drawing, clipped to its bounds."""

    def __init__(self, width=CELL_WIDTH, height=CELL_HEIGHT, background=None):
        self.width, self.height = width, height
        self.pixels = bytearray(width * height * 4)
        if background is not None:
            self.rect(0, 0, width, height, background)

    def blend(self, x, y, color):
        if not (0 <= x < self.width and 0 <= y < self.height):
            return
        red, green, blue, alpha = color
        if alpha == 0:
            return
        offset = (y * self.width + x) * 4
        if alpha == 255:
            self.pixels[offset:offset + 4] = bytes(color)
            return
        below = self.pixels[offset + 3]
        # Exact integer source-over at 255^2 scale; round only the stored results.
        source, under = alpha * 255, below * (255 - alpha)
        total = source + under
        for channel, value in enumerate((red, green, blue)):
            mixed = (value * source + self.pixels[offset + channel] * under + total // 2) // total
            self.pixels[offset + channel] = min(255, mixed)
        self.pixels[offset + 3] = min(255, (total + 127) // 255)

    def get(self, x, y):
        offset = (y * self.width + x) * 4
        return tuple(self.pixels[offset:offset + 4])

    def rect(self, x0, y0, x1, y1, color):
        """Fill [x0, x1) x [y0, y1)."""
        color = rgba(color)
        for y in range(max(0, round(y0)), min(self.height, round(y1))):
            for x in range(max(0, round(x0)), min(self.width, round(x1))):
                self.blend(x, y, color)

    def ellipse(self, cx, cy, rx, ry, color):
        """Fill an axis-aligned ellipse centred on (cx, cy)."""
        color = rgba(color)
        if rx <= 0 or ry <= 0:
            return
        for y in range(max(0, math.floor(cy - ry)), min(self.height, math.ceil(cy + ry) + 1)):
            dy = (y + 0.5 - cy) / ry
            if abs(dy) > 1:
                continue
            span = rx * math.sqrt(1 - dy * dy)
            for x in range(max(0, round(cx - span)), min(self.width, round(cx + span))):
                self.blend(x, y, color)

    def polygon(self, points, color):
        """Fill a polygon of (x, y) points using the even-odd rule at pixel centres."""
        color = rgba(color)
        points = [(float(x), float(y)) for x, y in points]
        if len(points) < 3:
            return
        top = max(0, math.floor(min(y for _, y in points)))
        bottom = min(self.height, math.ceil(max(y for _, y in points)) + 1)
        for y in range(top, bottom):
            sample = y + 0.5
            crossings = []
            for (ax, ay), (bx, by) in zip(points, points[1:] + points[:1]):
                if (ay <= sample < by) or (by <= sample < ay):
                    crossings.append(ax + (sample - ay) * (bx - ax) / (by - ay))
            crossings.sort()
            for left, right in zip(crossings[::2], crossings[1::2]):
                for x in range(max(0, round(left)), min(self.width, round(right))):
                    self.blend(x, y, color)

    def line(self, x0, y0, x1, y1, color, width=2):
        """Stroke a segment with square ends."""
        length = math.hypot(x1 - x0, y1 - y0)
        if length == 0:
            self.rect(x0 - width / 2, y0 - width / 2, x0 + width / 2, y0 + width / 2, color)
            return
        nx, ny = -(y1 - y0) / length * width / 2, (x1 - x0) / length * width / 2
        self.polygon([(x0 + nx, y0 + ny), (x1 + nx, y1 + ny), (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)], color)

    def paste(self, other, left, top):
        """Composite another canvas onto this one at (left, top)."""
        for y in range(other.height):
            for x in range(other.width):
                pixel = other.get(x, y)
                if pixel[3]:
                    self.blend(left + x, top + y, pixel)

    def copy(self):
        clone = Canvas(self.width, self.height)
        clone.pixels[:] = self.pixels
        return clone

    def is_empty(self):
        return not any(self.pixels[3::4])

    def png(self):
        """Encode as an 8-bit RGBA PNG."""
        stride = self.width * 4
        raw = b"".join(b"\x00" + bytes(self.pixels[row * stride:(row + 1) * stride])
                       for row in range(self.height))

        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

        header = struct.pack(">IIBBBBB", self.width, self.height, 8, 6, 0, 0, 0)
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


class PetSheet:
    """Frames keyed by Codex state; renders the 1536x1872 nine-row atlas."""

    def __init__(self):
        self.frames = {}

    def frame(self, state, index):
        """Return the (lazily created) transparent 192x208 canvas for one frame."""
        if state not in _COUNTS:
            raise ValueError(f"Unknown state {state!r}; use one of {', '.join(_COUNTS)}.")
        if not 0 <= index < _COUNTS[state]:
            raise ValueError(f"{state} has frames 0-{_COUNTS[state] - 1}.")
        return self.frames.setdefault((state, index), Canvas())

    def _row(self, state):
        drawn = [self.frames.get((state, index)) for index in range(_COUNTS[state])]
        drawn = [None if frame is None or frame.is_empty() else frame for frame in drawn]
        return drawn

    def validate(self):
        """Every Maestro-shown frame must be drawn; other rows are all-or-nothing."""
        problems = []
        for state, count in STATES:
            row = self._row(state)
            missing = [index for index, frame in enumerate(row) if frame is None]
            shown = state in dict(MAESTRO_STATES)
            if missing and (shown or len(missing) < count):
                problems.append(f"{state}: frames {missing} are empty")
        if problems:
            raise ValueError("Pet frames are incomplete: " + "; ".join(problems) + ".")

    def render(self):
        """Compose the atlas; undrawn Codex-only rows reuse the idle loop."""
        self.validate()
        idle = self._row("idle")
        atlas = Canvas(SHEET_WIDTH, SHEET_HEIGHT)
        for row, (state, count) in enumerate(STATES):
            frames = self._row(state)
            if all(frame is None for frame in frames):
                frames = [idle[index % len(idle)] for index in range(count)]
            for column, frame in enumerate(frames):
                # Cells never overlap, so an exact byte copy equals compositing onto clear pixels.
                for y in range(CELL_HEIGHT):
                    start = ((row * CELL_HEIGHT + y) * SHEET_WIDTH + column * CELL_WIDTH) * 4
                    atlas.pixels[start:start + CELL_WIDTH * 4] = \
                        frame.pixels[y * CELL_WIDTH * 4:(y + 1) * CELL_WIDTH * 4]
        return atlas

    def preview(self, atlas=None):
        """Opaque contact sheet of the rows Maestro plays, for visual review only."""
        atlas = atlas or self.render()
        sheet = Canvas(SHEET_WIDTH, len(MAESTRO_STATES) * CELL_HEIGHT, background="#202735")
        for out_row, (state, count) in enumerate(MAESTRO_STATES):
            source_top = _ROWS[state] * CELL_HEIGHT
            for x in range(count * CELL_WIDTH):
                for y in range(CELL_HEIGHT):
                    pixel = atlas.get(x, source_top + y)
                    if pixel[3]:
                        sheet.blend(x, out_row * CELL_HEIGHT + y, pixel)
        return sheet

    def save(self, folder, pet_id, name, description=""):
        """Write a new pet folder: pet.json, spritesheet.png and preview.png."""
        folder = Path(folder).expanduser().absolute()
        if not PET_ID.fullmatch(pet_id or "") or len(pet_id) > 48 or pet_id == "maestro":
            raise ValueError("Pet ID must be 1-48 lowercase letters/digits/hyphens; maestro is reserved.")
        for label, value, limit in (("Name", name, 64), ("Description", description, 200)):
            if not isinstance(value, str) or len(value) > limit or any(ord(c) < 32 or ord(c) == 127 for c in value):
                raise ValueError(f"{label} must be at most {limit} printable characters.")
        if not name.strip():
            raise ValueError("Name must not be empty.")
        if folder.exists() or folder.is_symlink():
            raise ValueError(f"{folder} already exists; choose a new folder.")
        atlas = self.render()
        folder.mkdir(parents=True)
        (folder / "spritesheet.png").write_bytes(atlas.png())
        (folder / "preview.png").write_bytes(self.preview(atlas).png())
        manifest = {"id": pet_id, "displayName": name, "description": description,
                    "spritesheetPath": "spritesheet.png"}
        (folder / "pet.json").write_text(json.dumps(manifest, indent=2) + "\n")
        return {"ok": True, "petId": pet_id, "folder": str(folder),
                "preview": str(folder / "preview.png"),
                "size": [SHEET_WIDTH, SHEET_HEIGHT]}


if __name__ == "__main__":
    print(__doc__.strip())
    sys.exit(0)
