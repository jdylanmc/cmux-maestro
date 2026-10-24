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
    def test_incomplete_marker_does_not_supply_missing_readiness(self):
        with self.assertRaisesRegex(RuntimeError, "not-ready"):
            watchdog.metadata_readiness({"diagnosticOutcome": "diagnostic-incomplete", "samplerReaped": True})

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
                    "diagnosticOutcome": "diagnostic-incomplete", "samplerReaped": True,
                    "samplerStarted": True, "samplerPID": 4242}, root)

    def test_completed_and_clean_incomplete_outcomes_are_distinct(self):
        with tempfile.TemporaryDirectory() as directory:
            for outcome in ("complete", "diagnostic-incomplete"):
                self.assertEqual(watchdog.diagnostic_outcome({
                    "diagnosticOutcome": outcome, "samplerReaped": True,
                    "samplerStarted": True, "samplerPID": 4242}, Path(directory)), outcome)

    def test_spawn_failure_is_explicitly_never_started(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(watchdog.diagnostic_outcome({
                "diagnosticOutcome": "complete", "samplerStarted": False, "samplerReaped": True,
                "sampleStatus": "failed: system(2)"}, Path(directory)), "complete")

    def test_missing_or_contradictory_sampler_identity_fails(self):
        cases = (
            {},
            {"samplerStarted": True},
            {"samplerStarted": True, "samplerPID": 0},
            {"samplerStarted": False, "samplerPID": 4242, "sampleStatus": "failed: system(2)"},
            {"samplerStarted": False, "sampleStatus": "exit-0"},
            {"samplerStarted": False, "sampleStatus": "failed: system(2)",
             "diagnosticOutcome": "diagnostic-incomplete"},
        )
        with tempfile.TemporaryDirectory() as directory:
            for fields in cases:
                with self.subTest(fields=fields), self.assertRaisesRegex(RuntimeError, "Sampler"):
                    watchdog.diagnostic_outcome({
                        "diagnosticOutcome": "complete", "samplerReaped": True, **fields},
                        Path(directory))


if __name__ == "__main__":
    unittest.main()
