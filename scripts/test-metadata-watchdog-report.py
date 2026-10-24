#!/usr/bin/env python3
"""The watchdog can report a fixture stall before it observes a metadata PID."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "metadata_watchdog", Path(__file__).with_name("test-metadata-watchdog.py"))
watchdog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watchdog)


class MetadataReadinessTests(unittest.TestCase):
    def test_premature_report_fails_as_not_ready(self):
        for report in ({}, {"metadataPID": 123}, {"metadataReadiness": {"state": "living"}}):
            with self.subTest(report=report), self.assertRaisesRegex(RuntimeError, "not-ready"):
                watchdog.metadata_readiness(report)

    def test_null_readiness_fails_as_not_ready(self):
        with self.assertRaisesRegex(RuntimeError, "not-ready"):
            watchdog.metadata_readiness({"metadataPID": 123, "metadataReadiness": None})

    def test_observed_readiness_is_preserved(self):
        ready = {"state": "living", "process": {"pid": 123}}
        self.assertEqual(watchdog.metadata_readiness({
            "metadataPID": 123, "metadataReadiness": ready}), ready)


if __name__ == "__main__":
    unittest.main()
