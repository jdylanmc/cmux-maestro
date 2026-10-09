#!/usr/bin/env python3
import json
from pathlib import Path
import re
import runpy
import tempfile
import unittest


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

    def test_other_existing_defaults_and_unknown_role_choices_are_not_replaced(self):
        for role, expected in (
            ("Project Manager", {"icon": "md-meditation", "color": "teal"}),
            ("Discovery", {"icon": "md-compass_outline", "color": "blue"}),
            ("Developer", {"icon": "seti-bicep", "color": "purple"}),
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


if __name__ == "__main__":
    unittest.main()
