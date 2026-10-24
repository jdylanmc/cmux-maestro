#!/usr/bin/env python3
"""Reject incomplete or unclean diagnostic publication, regardless of exit code."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "watchdog", Path(__file__).with_name("test-metadata-watchdog.py"))
watchdog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watchdog)


class DiagnosticCompletionTests(unittest.TestCase):
    def test_unmarked_report_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "Unmarked"):
                watchdog.diagnostic_outcome({"samplerReaped": True}, Path(directory))

    def test_incomplete_requires_confirmed_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            for cleaned in (None, False):
                with self.subTest(cleaned=cleaned), self.assertRaisesRegex(RuntimeError, "cleanup"):
                    watchdog.diagnostic_outcome({
                        "diagnosticOutcome": "diagnostic-incomplete", "samplerReaped": cleaned},
                        Path(directory))

    def test_atomic_write_debris_fails_even_with_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "stall.json.sb-interrupted").write_text("partial")
            with self.assertRaisesRegex(RuntimeError, "temporary"):
                watchdog.diagnostic_outcome({
                    "diagnosticOutcome": "diagnostic-incomplete", "samplerReaped": True}, root)

    def test_completed_and_clean_incomplete_outcomes_are_distinct(self):
        with tempfile.TemporaryDirectory() as directory:
            for outcome in ("complete", "diagnostic-incomplete"):
                self.assertEqual(watchdog.diagnostic_outcome({
                    "diagnosticOutcome": outcome, "samplerReaped": True}, Path(directory)), outcome)


if __name__ == "__main__":
    unittest.main()
