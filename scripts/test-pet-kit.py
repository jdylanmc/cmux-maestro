#!/usr/bin/env python3
"""Contract tests for the dependency-free maestro-pet drawing kit (standard library only)."""
import ast
import importlib.util
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
SKILL = ROOT / ".agents/skills/maestro-pet"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


kit = load("pet_kit", SKILL / "pet_kit.py")
orchestrator = load("orchestrator", ROOT / "scripts/cmux-maestro-orchestrator.py")


def decode_png(data):
    """Minimal decoder for the kit's own output: 8-bit RGBA, filter type 0 only."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    offset, idat, header = 8, b"", None
    while offset < len(data):
        (length,) = struct.unpack(">I", data[offset:offset + 4])
        kind, body = data[offset + 4:offset + 8], data[offset + 8:offset + 8 + length]
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        offset += 12 + length
    width, height, depth, color = header[:4]
    assert (depth, color) == (8, 6)
    raw, stride = zlib.decompress(idat), width * 4
    rows = [raw[y * (stride + 1):(y + 1) * (stride + 1)] for y in range(height)]
    assert all(row[0] == 0 for row in rows)
    return width, height, b"".join(row[1:] for row in rows)


def draw_complete(sheet, states=kit.MAESTRO_STATES):
    for state, count in states:
        for index in range(count):
            frame = sheet.frame(state, index)
            frame.ellipse(96, 120 + index, 40, 44, (40 + 20 * index, 120, 200))
            frame.rect(10, 10, 14, 14, "#ffffff")


class PetKitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="maestro-pet-kit-test-")
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_saved_pet_passes_native_add_validation_and_lays_out_rows(self):
        sheet = kit.PetSheet()
        draw_complete(sheet)
        result = sheet.save(self.root / "pet", "synthetic-blob", "Synthetic Blob", "Synthetic test shapes.")
        self.assertTrue(result["ok"])
        identifier, display, description, data, extension = orchestrator.read_pet_source(
            str(self.root / "pet"), None)
        self.assertEqual((identifier, display, description, extension),
                         ("synthetic-blob", "Synthetic Blob", "Synthetic test shapes.", ".png"))
        manifest = json.loads((self.root / "pet/pet.json").read_text())
        self.assertEqual(manifest["spritesheetPath"], "spritesheet.png")
        width, height, pixels = decode_png(data)
        self.assertEqual((width, height), (1536, 1872))

        def alpha(x, y):
            return pixels[(y * width + x) * 4 + 3]

        def cell(row, column):
            return b"".join(pixels[((row * 208 + y) * width + column * 192) * 4:
                                ((row * 208 + y) * width + (column + 1) * 192) * 4] for y in range(208))

        counts = dict(kit.STATES)
        for row, (state, count) in enumerate(kit.STATES):
            self.assertEqual(alpha(0, row * 208), 0, state)
            self.assertEqual(alpha(96, row * 208 + 120), 255, state)
            for column in range(count, 8):
                self.assertFalse(any(cell(row, column)[3::4]), f"{state} unused cell {column}")
        # Undrawn Codex-only rows reuse the idle loop rather than staying blank.
        idle = [cell(0, column) for column in range(counts["idle"])]
        for column in range(counts["running-right"]):
            self.assertEqual(cell(1, column), idle[column % len(idle)])
        preview_width, preview_height, preview = decode_png((self.root / "pet/preview.png").read_bytes())
        self.assertEqual((preview_width, preview_height), (1536, 5 * 208))
        self.assertTrue(all(value == 255 for value in preview[3::4]))

    def test_refuses_incomplete_frames_and_unsafe_output(self):
        sheet = kit.PetSheet()
        draw_complete(sheet, [(state, count) for state, count in kit.MAESTRO_STATES if state != "failed"])
        with self.assertRaisesRegex(ValueError, "failed"):
            sheet.save(self.root / "a", "pet", "Pet")
        draw_complete(sheet)
        sheet.frame("jumping", 0).rect(0, 0, 5, 5, "#fff")
        with self.assertRaisesRegex(ValueError, "jumping"):
            sheet.save(self.root / "b", "pet", "Pet")
        sheet.frames.pop(("jumping", 0))
        for pet_id in ("maestro", "Bad_ID", "", "-x", "a" * 49):
            with self.assertRaises(ValueError):
                sheet.save(self.root / "c", pet_id, "Pet")
        with self.assertRaises(ValueError):
            sheet.save(self.root / "c", "pet", "Bad\nName")
        (self.root / "exists").mkdir()
        with self.assertRaisesRegex(ValueError, "already exists"):
            sheet.save(self.root / "exists", "pet", "Pet")
        self.assertFalse((self.root / "c").exists())
        with self.assertRaises(ValueError):
            sheet.frame("running", 6)
        with self.assertRaises(ValueError):
            sheet.frame("sleeping", 0)

    def test_source_over_blending_and_clipping(self):
        canvas = kit.Canvas(4, 4)
        canvas.rect(0, 0, 4, 4, "#0000ff")
        canvas.rect(0, 0, 2, 2, (255, 0, 0, 128))
        red, green, blue, alpha = canvas.get(0, 0)
        self.assertEqual(alpha, 255)
        self.assertAlmostEqual(red, 128, delta=1)
        self.assertAlmostEqual(blue, 127, delta=1)
        self.assertEqual(canvas.get(3, 3), (0, 0, 255, 255))
        clear = kit.Canvas(4, 4)
        clear.rect(0, 0, 1, 1, (255, 0, 0, 128))
        self.assertEqual(clear.get(0, 0), (255, 0, 0, 128))
        clear.ellipse(100, 100, 50, 50, "#fff")
        clear.line(-10, -10, 100, 100, "#fff", 1)
        clear.polygon([(-5, -5), (50, 0), (0, 50)], "#00ff00")
        self.assertEqual(clear.get(0, 1)[1], 255)
        def reference(source, below):
            alpha, under = source[3] / 255, below[3] / 255 * (1 - source[3] / 255)
            total = alpha + under
            return tuple(round((s * alpha + d * under) / total) for s, d in zip(source[:3], below[:3])) \
                + (round(total * 255),)

        for first in ((255, 255, 255, 1), (254, 0, 255, 1), (10, 200, 30, 2), (255, 0, 0, 127)):
            for second in ((255, 255, 255, 1), (0, 0, 255, 2), (0, 255, 0, 128), (9, 9, 9, 254)):
                canvas = kit.Canvas(1, 1)
                canvas.blend(0, 0, first)
                canvas.blend(0, 0, second)
                expected = reference(second, first)
                for actual, wanted in zip(canvas.get(0, 0), expected):
                    self.assertLessEqual(abs(actual - wanted), 1, (first, second, canvas.get(0, 0), expected))
        for bad in ("#12", "zzzzzz", (1, 2), (0, 0, 300)):
            with self.assertRaises(ValueError):
                kit.rgba(bad)

    def test_kit_imports_only_the_standard_library(self):
        tree = ast.parse((SKILL / "pet_kit.py").read_text())
        names = {alias.name.split(".")[0] for node in ast.walk(tree) if isinstance(node, ast.Import)
                 for alias in node.names}
        names |= {node.module.split(".")[0] for node in ast.walk(tree)
                  if isinstance(node, ast.ImportFrom) and node.module}
        self.assertLessEqual(names, {"json", "math", "re", "struct", "sys", "zlib", "pathlib"})

    def test_skill_guides_dependency_free_autonomous_creation(self):
        text = (SKILL / "SKILL.md").read_text()
        self.assertIn("pet_kit.py", text)
        self.assertIn("from pet_kit import PetSheet, MAESTRO_STATES", text)
        self.assertIn("sys.dont_write_bytecode = True", text)
        self.assertIn("preview.png", text)
        for absent in ("hatch-pet", "Pillow", "pip install", "imagegen", ".codex/pets"):
            self.assertNotIn(absent, text)
        self.assertEqual([name for name, _ in kit.STATES], [
            "idle", "running-right", "running-left", "waving", "jumping",
            "failed", "waiting", "running", "review"])
        swift = (ROOT / "CMUXMaestroSidebar/State/SidebarPetStore.swift").read_text()
        self.assertIn("static let frameCounts = [" + ", ".join(str(c) for _, c in kit.STATES) + "]", swift)


if __name__ == "__main__":
    unittest.main(verbosity=2)
