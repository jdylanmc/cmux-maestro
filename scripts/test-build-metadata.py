#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("metadata", ROOT / "scripts/verify-build-metadata.py")
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class BuildMetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory = ROOT / ".build/metadata-tests" / str(uuid.uuid4())
        self.app = self.directory / "Fixture.app"
        self.extension = self.app / "Contents/Extensions/CMUX Maestro Preview Extension.appex"
        (self.extension / "Contents").mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.directory)

    def fixture(self, mode):
        suffix, point = metadata.PROFILES[mode]
        self.parent = {"CFBundleIdentifier": metadata.BASE_ID + suffix, "CFBundlePackageType": "APPL",
                       "CFBundleVersion": metadata.APP_BUILD_VERSION}
        self.child = {
            "CFBundleIdentifier": metadata.BASE_ID + suffix + ".Extension",
            "CFBundlePackageType": "XPC!",
            "CFBundleVersion": metadata.APP_BUILD_VERSION,
            "CFBundleExecutable": "Fixture",
            "EXAppExtensionAttributes": {"EXExtensionPointIdentifier": point},
        }
        resources = self.app / "Contents/Resources"
        resources.mkdir(parents=True, exist_ok=True)
        (resources / "cmux-maestro-orchestrator.py").write_text("#!/usr/bin/env python3\n")
        (resources / "SKILL.md").write_text("---\nname: cmux-maestro-orchestrate\n---\n")
        self.save()

    def save(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.parent))
        (self.extension / "Contents/Info.plist").write_bytes(plistlib.dumps(self.child))

    def test_each_metadata_namespace_is_distinct(self):
        for mode in metadata.PROFILES:
            with self.subTest(mode=mode):
                self.fixture(mode)
                metadata.verify_metadata(self.app, mode)
                for other in metadata.PROFILES:
                    if other != mode:
                        with self.assertRaises(ValueError):
                            metadata.verify_metadata(self.app, other)

    def test_validation_cannot_keep_production_id_or_point(self):
        for field in ("parent", "child", "point"):
            with self.subTest(field=field):
                self.fixture("tests")
                if field == "parent":
                    self.parent["CFBundleIdentifier"] = metadata.BASE_ID
                elif field == "child":
                    self.child["CFBundleIdentifier"] = metadata.BASE_ID + ".Extension"
                else:
                    self.child["EXAppExtensionAttributes"]["EXExtensionPointIdentifier"] = metadata.PRODUCTION_POINT
                self.save()
                with self.assertRaises(ValueError):
                    metadata.verify_metadata(self.app, "tests")

    def test_effective_sandbox_and_prefixes_are_required(self):
        good = {metadata.SANDBOX_KEY: True, metadata.READ_KEY: metadata.READ_PATHS}
        metadata.verify_profile(good)
        for invalid in (
            {metadata.READ_KEY: metadata.READ_PATHS},
            {**good, metadata.SANDBOX_KEY: False},
            {**good, metadata.READ_KEY: [path.lstrip("/") for path in metadata.READ_PATHS]},
            {**good, "com.apple.security.network.client": True},
        ):
            with self.assertRaises(ValueError):
                metadata.verify_profile(invalid)

    def test_stale_app_or_extension_build_is_rejected(self):
        for member in ("parent", "child"):
            self.fixture("production")
            getattr(self, member)["CFBundleVersion"] = "1"
            self.save()
            with self.assertRaises(ValueError):
                metadata.verify_metadata(self.app, "production")

    def test_signed_publication_checks_actual_profile_not_just_signature_validity(self):
        self.fixture("production")
        helper = self.app / "Contents/Helpers/CMUXMaestroCopilotHook"
        helper.parent.mkdir()
        helper.write_bytes(b"synthetic")
        helper.chmod(0o700)
        good = {metadata.SANDBOX_KEY: True, metadata.READ_KEY: metadata.READ_PATHS}

        def signed(command, **_):
            if "--verbose=4" in command:
                return subprocess.CompletedProcess(command, 0, stdout=b"",
                                                   stderr=f"Identifier={metadata.BASE_ID}.CopilotHook\nSignature=adhoc\n".encode())
            profile = {} if command[-1] == str(self.app) else good
            return subprocess.CompletedProcess(command, 0, stdout=plistlib.dumps(profile))

        with patch.object(metadata.subprocess, "run", side_effect=signed) as runner:
            metadata.verify_signed(self.app)
            self.assertEqual(runner.call_count, 6)
            self.assertIn("--strict", runner.call_args_list[0].args[0])
        def empty_profile(command, **kwargs):
            if "--verbose=4" in command:
                return signed(command, **kwargs)
            return subprocess.CompletedProcess(command, 0, stdout=plistlib.dumps({}), stderr=b"")

        with patch.object(metadata.subprocess, "run", side_effect=empty_profile):
            with self.assertRaises(ValueError):
                metadata.verify_signed(self.app)

    def test_resolved_settings_fail_closed_before_any_build(self):
        for mode, (suffix, point) in metadata.PROFILES.items():
            rows = []
            for target, ending in (
                ("CMUXMaestroPreview", ""), ("CMUXMaestroSidebar", ".Extension"),
                ("CMUXMaestroCopilotHook", ".CopilotHook"), ("CMUXMaestroPreviewTests", ".Tests"),
            ):
                rows.append({"target": target, "buildSettings": {
                    "PRODUCT_BUNDLE_IDENTIFIER": metadata.BASE_ID + suffix + ending,
                    "CMUX_SIDEBAR_EXTENSION_POINT_ID": point,
                    "ENABLE_APP_SANDBOX": "YES" if target == "CMUXMaestroSidebar" else "NO",
                    "CODE_SIGNING_ALLOWED": "YES" if mode == "production" else "NO",
                    "CODE_SIGN_IDENTITY": "-",
                    "CURRENT_PROJECT_VERSION": metadata.APP_BUILD_VERSION,
                    "OTHER_CODE_SIGN_FLAGS": "--identifier " + metadata.BASE_ID + suffix + ending
                    if target == "CMUXMaestroCopilotHook" else "",
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if mode == "production" else "DEBUG CMUX_VALIDATION",
                }})
            metadata.verify_settings(rows, mode)
            flags = rows[2]["buildSettings"].pop("OTHER_CODE_SIGN_FLAGS")
            with self.assertRaises(ValueError):
                metadata.verify_settings(rows, mode)
            rows[2]["buildSettings"]["OTHER_CODE_SIGN_FLAGS"] = flags
            valid_conditions = rows[0]["buildSettings"]["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]
            rows[0]["buildSettings"]["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = (
                "DEBUG CMUX_VALIDATION" if mode == "production" else "DEBUG"
            )
            with self.assertRaises(ValueError):
                metadata.verify_settings(rows, mode)
            rows[0]["buildSettings"]["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = valid_conditions
            rows[1]["buildSettings"]["CMUX_SIDEBAR_EXTENSION_POINT_ID"] = "unexpected.point"
            with self.assertRaises(ValueError):
                metadata.verify_settings(rows, mode)

    def test_scripts_pin_validation_namespaces_and_gate_explicit_publication(self):
        for name, mode in (("build-unsigned.sh", "unsigned"), ("test.sh", "tests")):
            script = (ROOT / "scripts" / name).read_text()
            suffix, point = metadata.PROFILES[mode]
            self.assertIn("CMUX_BUNDLE_ID_SUFFIX=" + suffix, script)
            self.assertIn("CMUX_SIDEBAR_EXTENSION_POINT_ID=" + point, script)
            self.assertIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_VALIDATION", script)
            self.assertIn("--settings", script)
            self.assertIn("--app", script)
            self.assertNotIn("REGISTER_APP_WITH_LAUNCH_SERVICES", script)
        script = (ROOT / "scripts/build-register.sh").read_text()
        self.assertLess(script.index('--source-entitlements'), script.index('    build\n'))
        self.assertLess(script.index('--mode production --app "$APP"'), script.index('pluginkit -a "$APPEX"'))
        self.assertLess(script.index('pluginkit -a "$APPEX"'), script.index('--registration "$APPEX"'))

    def registration_listing(self, *entries):
        return "".join(f"+    {identifier}(2)\n    Path = {path}\n" for identifier, path in entries) \
            + f"\n ({len(entries)} plug-{'in' if len(entries) == 1 else 'ins'})\n"

    def test_registration_accepts_expected_id_and_canonical_path(self):
        identifier = metadata.BASE_ID + ".Extension"
        alias = self.directory / "alias.appex"
        alias.symlink_to(self.extension, target_is_directory=True)
        metadata.verify_registration_output(self.registration_listing((identifier, alias)), self.extension)

    def test_documented_election_prefixes_preserve_exact_record_matching(self):
        identifier = metadata.BASE_ID + ".Extension"
        for prefix in ("", "+", "-", "!", "=", "?"):
            with self.subTest(prefix=prefix):
                output = self.registration_listing((identifier, self.extension)).replace("+    ", prefix + "    ")
                metadata.verify_registration_output(output, self.extension)
                with self.assertRaises(ValueError):
                    metadata.verify_registration_output(output, self.directory / "wrong.appex")
                with self.assertRaises(ValueError):
                    metadata.verify_registration_output(output, self.extension, absent=True)
                with self.assertRaises(ValueError):
                    metadata.verify_registration_output(output.replace("(1 plug-in)", "(2 plug-ins)"), self.extension)
                with self.assertRaises(ValueError):
                    metadata.verify_registration_output(output.replace(identifier, "com.example.Other"), self.extension)

    def test_unsupported_or_combined_election_prefixes_remain_invalid(self):
        output = self.registration_listing((metadata.BASE_ID + ".Extension", self.extension))
        for prefix in ("@", "*", "+=", "??", "!?"):
            with self.subTest(prefix=prefix):
                with self.assertRaises(ValueError):
                    metadata.verify_registration_output(output.replace("+    ", prefix + "    "), self.extension)

    def test_registration_rejects_no_matches_wrong_path_and_unsupported_output(self):
        identifier = metadata.BASE_ID + ".Extension"
        for output in (
            "(no matches)\n",
            "",
            self.registration_listing((identifier, self.directory / "wrong.appex")),
            f'{{"id":"{identifier}","Path":"{self.extension}"}}',
            f"+ {identifier}(2)\n    Path = {self.extension}\n",
        ):
            with self.subTest(output=output):
                with self.assertRaises(ValueError):
                    metadata.verify_registration_output(output, self.extension)

    def test_registration_duplicate_ids_require_expected_path_on_matching_record(self):
        identifier = metadata.BASE_ID + ".Extension"
        wrong = self.directory / "old.appex"
        metadata.verify_registration_output(
            self.registration_listing((identifier, wrong), (identifier, self.extension)), self.extension
        )
        with self.assertRaises(ValueError):
            metadata.verify_registration_output(
                self.registration_listing((identifier, wrong), ("com.example.Other.Extension", self.extension)),
                self.extension,
            )

    def test_registration_query_does_not_treat_zero_exit_as_discovery(self):
        with patch.object(metadata.subprocess, "run", return_value=subprocess.CompletedProcess(
            [], 0, stdout="(no matches)\n", stderr=""
        )) as runner:
            with self.assertRaises(ValueError):
                metadata.verify_registered_extension(self.extension)
            self.assertEqual(runner.call_args.args[0][-2:], ["-i", metadata.BASE_ID + ".Extension"])

    def test_project_keeps_production_defaults(self):
        project = json.loads(subprocess.check_output([
            "/usr/bin/plutil", "-convert", "json", "-o", "-",
            str(ROOT / "CMUXMaestroPreview.xcodeproj/project.pbxproj"),
        ]))
        objects = project["objects"]
        for target in objects.values():
            if target.get("isa") != "PBXNativeTarget":
                continue
            for config_id in objects[target["buildConfigurationList"]]["buildConfigurations"]:
                settings = objects[config_id]["buildSettings"]
                self.assertEqual(settings["CMUX_BUNDLE_ID_SUFFIX"], "")
                if target["name"] != "CMUXMaestroPreviewTests":
                    self.assertEqual(settings["CURRENT_PROJECT_VERSION"], metadata.APP_BUILD_VERSION)
                if target["name"] == "CMUXMaestroCopilotHook":
                    self.assertEqual(settings["OTHER_CODE_SIGN_FLAGS"], "--identifier $(PRODUCT_BUNDLE_IDENTIFIER)")
                if target["name"] in ("CMUXMaestroPreview", "CMUXMaestroSidebar"):
                    self.assertEqual(settings["CMUX_SIDEBAR_EXTENSION_POINT_ID"], metadata.PRODUCTION_POINT)
        metadata.verify_profile(metadata.plist(ROOT / "CMUXMaestroSidebar/CMUXMaestroSidebar.entitlements"))


if __name__ == "__main__":
    unittest.main()
