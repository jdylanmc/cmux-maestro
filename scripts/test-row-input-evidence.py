#!/usr/bin/env python3
"""Portable schema controls; no app, window, build, accessibility or input."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("row_evidence", Path(__file__).with_name("row-input-evidence.py"))
schema = importlib.util.module_from_spec(spec)
spec.loader.exec_module(schema)


def fixture(version):
    rect = [[0, 0], [400, 360]]
    row = {
        "id": "owner", "windowNumber": 1, "keyboard": False, "focused": False, "eligible": True,
        "focusedControls": 0, "titleIsResponder": True, "exteriorFocusRing": True, "bordered": False,
        "frame": rect, "titleFrame": rect,
    }
    item = {"window": "row-input-owner", "type": 10, "timestamp": 1.0}
    if version == 4:
        owner = {"kind": "control", "control": "owner-title", "window": "row-input-owner"}
        sibling = {"kind": "control", "control": "sibling-title", "window": "row-input-owner"}
        row["keyView"] = {"canBecomeKeyView": True, "nextValidKeyView": sibling}
        item["keyboard"] = {"keyCode": 48, "modifierFlags": 0}
        item["dispatch"] = {"before": owner, "after": sibling}
    return {
        "version": version, "caseID": "11111111-1111-4111-8111-111111111111",
        "live": True, "lifetime": {
            "invalidated": False, "applicationActive": True, "ownerVisible": True, "foreignVisible": True,
            "ownerReceiverAttached": True, "foreignReceiverAttached": True, "evidenceAttached": True,
            "failedRowIDs": [], "displaysAtSample": {
                "uptime": 1, "screens": [], "ownerBackingScaleFactor": 2, "foreignBackingScaleFactor": 2,
            },
        },
        "rows": [row], "ownerFrame": rect, "foreignFrame": rect,
        "ownerKey": True, "opens": 0, "closes": 0, "tracking": False, "actions": 0,
        "activations": 1, "dismissals": 1, "ownerDown": 0, "ownerUp": 0,
        "foreignDown": 0, "foreignUp": 0, "inputs": [item], "overflow": False,
    }


class EvidenceTests(unittest.TestCase):
    def decode(self, value):
        return schema.decode(json.dumps(value).encode())

    def test_original_v3_fields_round_trip_without_invented_diagnostics(self):
        value = fixture(3)
        self.assertEqual(self.decode(value), value)
        self.assertNotIn("keyView", self.decode(value)["rows"][0])
        self.assertNotIn("keyboard", self.decode(value)["inputs"][0])

    def test_v4_records_exact_key_and_before_after_identities(self):
        value = fixture(4)
        result = self.decode(value)
        self.assertEqual(result["inputs"][0]["keyboard"], {"keyCode": 48, "modifierFlags": 0})
        self.assertEqual(result["inputs"][0]["dispatch"]["before"]["control"], "owner-title")
        self.assertEqual(result["inputs"][0]["dispatch"]["after"]["control"], "sibling-title")

    def test_unknown_version_or_v3_diagnostic_masquerade_is_rejected(self):
        for version in [2, 5, True, "4"]:
            value = fixture(4)
            value["version"] = version
            with self.subTest(version=version), self.assertRaises(ValueError):
                self.decode(value)
        value = fixture(4)
        value["version"] = 3
        with self.assertRaises(ValueError):
            self.decode(value)

    def test_missing_v4_fields_are_not_silent_legacy_fallbacks(self):
        for path in [
            ("rows", 0, "keyView"), ("inputs", 0, "keyboard"), ("inputs", 0, "dispatch"),
            ("inputs", 0, "dispatch", "before"), ("inputs", 0, "keyboard", "keyCode"),
        ]:
            value = fixture(4)
            parent = value
            for key in path[:-1]:
                parent = parent[key]
            del parent[path[-1]]
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.decode(value)

    def test_unknown_nested_fields_are_rejected(self):
        for path in [
            (), ("rows", 0), ("rows", 0, "keyView"), ("inputs", 0),
            ("inputs", 0, "keyboard"), ("inputs", 0, "dispatch"), ("inputs", 0, "dispatch", "after"),
        ]:
            value = fixture(4)
            parent = value
            for key in path:
                parent = parent[key]
            parent["invented"] = True
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.decode(value)

    def test_responder_identity_cannot_cross_windows_or_claim_unknown_controls(self):
        for mutation in [
            {"control": "foreign-title"}, {"window": "row-input-foreign"},
            {"control": "made-up"}, {"kind": "none"}, {"kind": "other"},
        ]:
            value = fixture(4)
            value["inputs"][0]["dispatch"]["before"].update(mutation)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.decode(value)

    def test_none_and_unknown_responders_are_explicit_not_guessed_controls(self):
        value = fixture(4)
        value["inputs"][0]["dispatch"] = {"before": {"kind": "none"}, "after": {"kind": "other"}}
        self.assertEqual(self.decode(value)["inputs"][0]["dispatch"], value["inputs"][0]["dispatch"])

    def test_key_numeric_fields_reject_boolean_negative_and_overflow(self):
        for key, values in [("keyCode", [True, -1, 65_536, "48"]), ("modifierFlags", [False, -1, 2**64, "0"])]:
            for invalid in values:
                value = fixture(4)
                value["inputs"][0]["keyboard"][key] = invalid
                with self.subTest(key=key, invalid=invalid), self.assertRaises(ValueError):
                    self.decode(value)

    def test_mouse_has_point_and_responder_pair_but_no_keyboard(self):
        value = fixture(4)
        item = value["inputs"][0]
        item["type"] = 1
        item["point"] = [10, 20]
        del item["keyboard"]
        self.assertEqual(self.decode(value), value)
        item["keyboard"] = {"keyCode": 48, "modifierFlags": 0}
        with self.assertRaises(ValueError):
            self.decode(value)

    def test_key_coordinates_and_unknown_dispatch_are_rejected(self):
        for mutation in [{"point": [0, 0]}, {"type": 99}, {"window": "guessed-owner"}]:
            value = fixture(4)
            value["inputs"][0].update(mutation)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.decode(value)

    def test_original_record_and_byte_bounds_are_preserved(self):
        value = fixture(4)
        value["inputs"] = [copy.deepcopy(value["inputs"][0]) for _ in range(64)]
        self.assertEqual(len(self.decode(value)["inputs"]), 64)
        value["inputs"].append(copy.deepcopy(value["inputs"][0]))
        with self.assertRaises(ValueError):
            self.decode(value)
        with self.assertRaises(ValueError):
            schema.decode(b" " * 32_769)


if __name__ == "__main__":
    unittest.main()
