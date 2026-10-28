#!/usr/bin/env python3
"""Development art/upgrade checks; use scripts/requirements-pet-art.txt."""
import hashlib
import importlib.util
import io
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from PIL import Image

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


generator = load("generator", "generate-maestro-pet.py")
upgrader = load("upgrader", "upgrade-pet-moods.py")
orchestrator = load("orchestrator", "cmux-maestro-orchestrator.py")


class BundledArtTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.atlas, cls.legacy = generator.generate()
        cls.bundled = Image.open(ROOT / "CMUXMaestroSidebar/Pets/maestro-pet.webp").convert("RGBA")

    def test_legacy_rows_match_the_pre_extension_decoded_digest(self):
        expected = "d111b12fe865795fa539e290938747f8d3fb68a303ee066548b0efa29581b2b3"
        self.assertEqual(hashlib.sha256(self.legacy.tobytes()).hexdigest(), expected)
        self.assertEqual(hashlib.sha256(self.bundled.crop((0, 0, 1536, 1872)).tobytes()).hexdigest(), expected)

    def test_reproduces_bundled_asset_and_manifest(self):
        data = io.BytesIO()
        self.atlas.save(data, "WEBP", lossless=True, quality=100, method=6)
        self.assertEqual(data.getvalue(), (ROOT / "CMUXMaestroSidebar/Pets/maestro-pet.webp").read_bytes())
        manifest = json.loads((ROOT / "CMUXMaestroSidebar/Pets/maestro-pet.json").read_text())
        self.assertEqual(manifest["id"], "maestro")
        self.assertEqual(manifest["spritesheetPath"], "maestro-pet.webp")
        self.assertEqual(self.bundled.size, (1536, 4160))
        self.assertLess(len(data.getvalue()), 10 * 1024 * 1024)

    def test_all_authored_mood_frames_are_nonempty_bounded_and_distinct(self):
        from pet_kit import EXTENDED_STATES, MAESTRO_STATES, MOOD_STATES
        rows = {state: row for row, (state, _) in enumerate(EXTENDED_STATES)}
        first = []
        for state, count in MAESTRO_STATES + MOOD_STATES:
            row = rows[state]
            for index in range(count):
                cell = self.bundled.crop((index * 192, row * 208, (index + 1) * 192, (row + 1) * 208))
                box = cell.getbbox()
                self.assertIsNotNone(box, (state, index))
                self.assertTrue(0 < box[0] < box[2] < 192 and 0 < box[1] < box[3] < 208, (state, index, box))
                if index == 0:
                    first.append(cell.tobytes())
            for index in range(count, 8):
                self.assertIsNone(self.bundled.crop((index * 192, row * 208, (index + 1) * 192, (row + 1) * 208)).getbbox())
        self.assertEqual(len(set(first)), 15)
        self.assertIsNone(self.bundled.crop((0, 2080, 1536, 2288)).getbbox())


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / ".build/art-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=scratch)
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def source(self, width=768, rows=9, suffix="png"):
        height = math.ceil(rows * 208 * width / 1536)
        image = Image.new("RGBA", (width, height))
        for y in range(height):
            image.paste((y % 256, (y // 2) % 256, 91, (y % 3) * 127), (0, y, width, y + 1))
        path = self.root / ("source." + suffix)
        image.save(path, lossless=True)
        return path, Image.open(path).convert("RGBA")

    def test_scaled_and_v2_sources_preserve_legacy_pixels_and_original_bytes(self):
        for width, rows, suffix in [(768, 9, "png"), (776, 11, "webp"), (512, 9, "png"), (1536, 9, "webp")]:
            with self.subTest(width=width, rows=rows):
                path, original = self.source(width, rows, suffix)
                before = path.read_bytes()
                out = self.root / f"copy-{width}"
                report = upgrader.upgrade(path, out, "synthetic-copy", "Synthetic Copy")
                identifier, _, _, imported, extension = orchestrator.read_pet_source(str(out), None)
                self.assertEqual((identifier, extension), ("synthetic-copy", ".png"))
                self.assertEqual(imported, (out / "spritesheet.png").read_bytes())
                atlas = Image.open(out / "spritesheet.png").convert("RGBA")
                legacy_height = math.ceil(9 * 208 * width / 1536)
                self.assertEqual(atlas.size, (width, math.ceil(20 * 208 * width / 1536)))
                self.assertEqual(atlas.crop((0, 0, width, legacy_height)).tobytes(),
                                 original.crop((0, 0, width, legacy_height)).tobytes())
                self.assertEqual(path.read_bytes(), before)
                self.assertEqual((out / ("original-sheet." + suffix)).read_bytes(), before)
                self.assertEqual(report["kind"], "generic-fallback-copy")
                cell_height = 208 * width / 1536
                self.assertIsNone(atlas.crop((0, round(10 * cell_height), width, round(11 * cell_height))).getbbox())
                if width == 768:
                    for row, old in [(9, 4), (11, 8), (12, 1), (13, 6), (14, 8), (15, 2), (16, 0), (17, 0), (18, 3), (19, 4)]:
                        self.assertEqual(atlas.crop((0, row * 104, 96, (row + 1) * 104)).tobytes(),
                                         original.crop((0, old * 104, 96, (old + 1) * 104)).tobytes())

    def test_explicit_folder_cli_keeps_manifest_backup_and_refuses_repeat(self):
        path, _ = self.source()
        folder = self.root / "supplied"
        folder.mkdir()
        path.rename(folder / path.name)
        manifest = b'{"id":"original","displayName":"Original","spritesheetPath":"source.png"}\n'
        (folder / "pet.json").write_bytes(manifest)
        output = self.root / "new"
        command = [sys.executable, str(ROOT / "scripts/upgrade-pet-moods.py"),
                   "--source", str(folder), "--output", str(output), "--id", "new-copy", "--name", "New Copy"]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((output / "original-pet.json").read_bytes(), manifest)
        self.assertEqual((folder / "pet.json").read_bytes(), manifest)
        before = {p.name: p.read_bytes() for p in output.iterdir()}
        self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
        self.assertEqual({p.name: p.read_bytes() for p in output.iterdir()}, before)

    def test_refuses_unsafe_destinations_inputs_and_traversal_without_writing(self):
        path, _ = self.source()
        before = path.read_bytes()
        existing = self.root / "existing"
        existing.mkdir()
        link = self.root / "link"
        link.symlink_to(path)
        for source, output, pet_id in [(path, existing, "copy"), (link, self.root / "no-link", "copy"),
                                       (path, self.root / "reserved", "maestro"),
                                       (path, self.root / "bad-id", "../copy")]:
            with self.assertRaises(ValueError):
                upgrader.upgrade(source, output, pet_id, "Copy")
        folder = self.root / "folder"
        folder.mkdir()
        for sheet_name in ["../source.png", str(path), "sub/source.png", "sub\\source.png"]:
            (folder / "pet.json").write_text(json.dumps({"spritesheetPath": sheet_name}))
            with self.assertRaises(ValueError):
                upgrader.upgrade(folder, self.root / "no-output", "copy", "Copy")
            self.assertFalse((self.root / "no-output").exists())
        with self.assertRaises(ValueError):
            upgrader.upgrade(folder, folder / "nested", "copy", "Copy")
        self.assertEqual(path.read_bytes(), before)

    def test_refuses_extended_oversize_and_truncated_images(self):
        for width, rows in [(1536, 20), (1544, 9), (512, 8)]:
            path, _ = self.source(width, rows)
            with self.assertRaises(ValueError):
                upgrader.upgrade(path, self.root / "invalid", "copy", "Copy")
        path.write_bytes(b"not an image")
        with self.assertRaises(OSError):
            upgrader.upgrade(path, self.root / "invalid", "copy", "Copy")
        path.write_bytes(b"x" * (upgrader.MAX_BYTES + 1))
        with self.assertRaises(ValueError):
            upgrader.upgrade(path, self.root / "invalid", "copy", "Copy")
        self.assertFalse((self.root / "invalid").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
