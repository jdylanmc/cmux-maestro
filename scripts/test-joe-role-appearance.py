#!/usr/bin/env python3
import io
import json
from pathlib import Path
import re
import runpy
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[1]
SKILL = ROOT / ".agents/skills/joe-mode-cmux"
HELPER = SKILL / "role-appearance.py"
CONTROLLER = runpy.run_path(str(ROOT / "scripts/cmux-maestro-orchestrator.py"))


def appearance(role, overrides=None):
    if HELPER.exists():
        return runpy.run_path(str(HELPER))["appearance_for"](role, overrides)
    # Before the selector exists, inspect the actual defaults served to Joe.
    names = {"roast": "Roast", "pr-sniper": "PR Sniper", "shepherd": "Shepherd",
             "project-manager": "Project Manager", "discovery": "Discovery", "developer": "Developer"}
    key = "-".join(role.lower().split())
    defaults = {}
    for line in (SKILL / "LAYOUT.md").read_text().splitlines():
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if len(cells) == 4 and cells[0] == names.get(key):
            glyph = re.search(r"`([^`]+)`", cells[2])
            if glyph:
                defaults["icon"] = glyph.group(1)
            if cells[3]:
                defaults["color"] = cells[3]
    return {**defaults, **(overrides or {})}


class RoleAppearanceTests(unittest.TestCase):
    def test_requested_role_defaults_are_exact(self):
        for role, expected in (
            ("Roast", {"icon": "fa-fire", "color": "red"}),
            ("PR Sniper", {"icon": "md-target_account"}),
            ("Shepherd", {"icon": "fa-cat", "color": "green"}),
            ("Developer", {"icon": "seti-bicep", "color": "gray"}),
        ):
            with self.subTest(role=role):
                self.assertEqual(appearance(role), expected)

    def test_human_overrides_win_per_field_and_unspecified_sniper_color_is_preserved(self):
        self.assertEqual(appearance("Roast", {"color": "blue"}),
                         {"icon": "fa-fire", "color": "blue"})
        self.assertEqual(appearance("Roast", {"icon": "fa-fish"}),
                         {"icon": "fa-fish", "color": "red"})
        self.assertEqual(appearance("Shepherd", {"icon": "fa-code", "color": "pink"}),
                         {"icon": "fa-code", "color": "pink"})
        self.assertEqual(appearance("PR Sniper", {"color": "purple"}),
                         {"icon": "md-target_account", "color": "purple"})
        self.assertEqual(appearance("Developer", {"color": "purple"}),
                         {"icon": "seti-bicep", "color": "purple"})
        self.assertEqual(appearance("Developer", {"icon": "fa-code"}),
                         {"icon": "fa-code", "color": "gray"})

    def test_other_existing_defaults_and_unknown_role_choices_are_not_replaced(self):
        for role, expected in (
            ("Project Manager", {"icon": "md-meditation", "color": "teal"}),
            ("Discovery", {"icon": "md-compass_outline", "color": "blue"}),
            ("Blocker investigator", {}),
            ("Roast extra permissions", {}),
        ):
            with self.subTest(role=role):
                self.assertEqual(appearance(role), expected)
        chosen = {"icon": "fa-fish", "color": "gray"}
        self.assertEqual(appearance("Unknown role", chosen), chosen)
        self.assertEqual(chosen, {"icon": "fa-fish", "color": "gray"})

    def test_real_glyph_resolution_and_sanitized_metadata_preserve_defaults(self):
        for role in ("Roast", "PR Sniper", "Shepherd", "Project Manager", "Discovery", "Developer"):
            with self.subTest(role=role), tempfile.TemporaryDirectory() as directory:
                metadata = appearance(role)
                self.assertIn("icon", metadata, "Every listed role needs its authoritative launch icon")
                self.assertEqual(CONTROLLER["resolve_icon"](metadata["icon"]), metadata["icon"])
                if "color" in metadata:
                    self.assertIn(metadata["color"], CONTROLLER["ICON_COLORS"])
                node, _ = CONTROLLER["new_root"](
                    "00000000-0000-4000-8000-000000000001",
                    "00000000-0000-4000-8000-000000000002",
                    "00000000-0000-4000-8000-000000000003", role,
                    icon_id=metadata["icon"], icon_color=metadata.get("color"),
                )
                state = CONTROLLER["empty_state"]()
                state["nodes"][node["id"]] = node
                with CONTROLLER["Store"](Path(directory).resolve() / "orchestration") as store:
                    store.write(state)
                    snapshot = json.loads(store._projection(state))
                self.assertEqual(snapshot["nodes"][0]["iconId"], metadata["icon"])
                self.assertEqual(snapshot["nodes"][0]["iconColor"], metadata.get("color"))
                self.assertNotIn("tokenHash", snapshot["nodes"][0])

    def test_unsupported_human_glyph_is_not_replaced_with_role_default(self):
        requested = {"icon": "md-not-a-supported-glyph"}
        metadata = appearance("Roast", requested)
        self.assertEqual(metadata["icon"], requested["icon"])
        with self.assertRaises(CONTROLLER["OrchestrationError"]):
            CONTROLLER["resolve_icon"](metadata["icon"])

    def test_actual_native_assignment_forwards_only_requested_appearance(self):
        ingress = CONTROLLER["command_native_spawn"]
        for role in ("Roast", "PR Sniper", "Shepherd", "Developer"):
            metadata = appearance(role)
            request = {"identity": {}, "assignment": {
                "name": role, "cwd": str(ROOT), "task": "Bounded metadata fixture.", **metadata,
            }}
            stream = io.TextIOWrapper(io.BytesIO(json.dumps(request).encode()))
            launch = Mock(return_value={"synthetic": True})
            with self.subTest(role=role), patch.dict(ingress.__globals__, {
                "sys": SimpleNamespace(stdin=stream), "command_spawn": launch,
            }):
                self.assertEqual(ingress(Path("/unused"), None), {"synthetic": True})
            launch.assert_called_once()
            args = launch.call_args.args[0]
            self.assertEqual(args.icon, metadata["icon"])
            self.assertEqual(args.color, metadata.get("color"))
            self.assertIsNone(args.yolo)
            self.assertIsNone(args.allow_tool)
            self.assertEqual(args.deny_tool, [])
            stream.close()

    def test_selector_rejects_invalid_fields_without_policy_or_state_effects(self):
        self.assertTrue(HELPER.exists(), "Canonical selector must be present after the repair")
        choose = runpy.run_path(str(HELPER))["appearance_for"]
        for role, metadata in (
            ("", {}), ("Roast", {"yolo": True}), ("Roast", {"icon": None}),
            ("Roast", {"color": ""}), ("Roast", {"icon": "bad\nvalue"}),
        ):
            with self.subTest(role=role, metadata=metadata), self.assertRaises(ValueError):
                choose(role, metadata)

    def test_mapping_failures_are_explicit_and_do_not_fall_back(self):
        choose = runpy.run_path(str(HELPER))["appearance_for"]
        with tempfile.TemporaryDirectory() as directory:
            mapping = Path(directory) / "mapping.json"
            for payload in (
                b'{"version":1,"roles":{"roast":{"icon":"fa-fire","icon":"fa-cat"}}}',
                b'{"version":true,"roles":{"roast":{"icon":"fa-fire"}}}',
                b'{"version":1,"roles":{"roast":{"color":"red"}}}',
                b"x" * 32_769,
            ):
                mapping.write_bytes(payload)
                with self.subTest(payload=payload[:80]), patch.dict(choose.__globals__, {"ROLE_MAP": mapping}):
                    with self.assertRaises(ValueError):
                        choose("Roast")
            mapping.unlink()
            with patch.dict(choose.__globals__, {"ROLE_MAP": mapping}), self.assertRaises(OSError):
                choose("Roast")

    def test_cli_returns_only_appearance_and_reports_invalid_input_nonzero(self):
        result = subprocess.run(
            [sys.executable, str(HELPER), "--role", "PR Sniper", "--color", "blue"],
            capture_output=True, text=True, check=True,
        )
        self.assertEqual(json.loads(result.stdout), {"icon": "md-target_account", "color": "blue"})
        refused = subprocess.run(
            [sys.executable, str(HELPER), "--role", ""], capture_output=True, text=True,
        )
        self.assertNotEqual(refused.returncode, 0)
        self.assertEqual(refused.stdout, "")
        self.assertIn("explicit operational role", refused.stderr)


if __name__ == "__main__":
    unittest.main()
