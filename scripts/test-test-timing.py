#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("timing", Path(__file__).with_name("check-test-timing.py"))
timing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(timing)


class TimingPolicyTests(unittest.TestCase):
    def test_changed_delay_and_duplicate_existing_sleep_cannot_use_old_exception(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            name = "ExampleTests/Clock.swift"
            file = root / name
            file.parent.mkdir()
            original = "try await Task." + "sleep(for: .seconds(60))"
            policy = {name: {"reason": "Hang guard only", "statements": {original: 1}}}
            file.write_text(original)
            self.assertEqual(timing.violations(root, [name], policy), [])
            for text in (original + "\n" + original, original.replace("60", "2")):
                file.write_text(text)
                self.assertEqual(len(timing.violations(root, [name], policy)), 1)

    def test_new_files_multiline_spelling_and_other_languages_are_checked(self):
        for name, text in [
            ("NewTests/Test.swift", "try await Task\n .sleep(for: .seconds(1))"),
            ("scripts/test-new.py", "time." + "sleep(0.1)"),
            ("scripts/test-new.mjs", "set" + "Timeout(resolve, 20)"),
            ("scripts/test-new.sh", "sleep " + "0.1"),
            ("scripts/test-new.sh", "echo waiting; " + "sleep 1"),
            ("scripts/test-new.mjs", "import { setTimeout as delay } from 'node:timers/promises';\n"
             + "await de" + "lay(100)"),
            ("NewTests/Window.swift", "#expect(window." + "isKeyWindow)"),
            ("NewTests/Render.swift", "let oracle = VNRecognize" + "TextRequest()"),
        ]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                file = root / name
                file.parent.mkdir(parents=True)
                file.write_text(text)
                self.assertTrue(timing.violations(root, [name], {}))

    def test_barriers_and_virtual_clock_advancement_need_no_exception(self):
        self.assertEqual(timing.statements("await gate.open()\nclock.advance(by: .seconds(60))"), {})
        self.assertFalse(timing.test_path("Production/Clock.swift"))


if __name__ == "__main__":
    unittest.main()
