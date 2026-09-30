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
scope_spec = importlib.util.spec_from_file_location("integrated_scopes", ROOT / "scripts/run-integrated-test-scopes.py")
scopes = importlib.util.module_from_spec(scope_spec)
scope_spec.loader.exec_module(scopes)


class IntegratedTestScopeTests(unittest.TestCase):
    def setUp(self):
        self.directory = ROOT / ".build/metadata-tests" / str(uuid.uuid4())
        self.directory.mkdir(parents=True)
        self.commands = []

    def tearDown(self):
        shutil.rmtree(self.directory)

    @staticmethod
    def report(entries):
        statuses = [status for _, status in entries]
        summary = {"result": "Failed" if "Failed" in statuses else "Passed", "totalTestCount": len(entries),
                   "passedTests": statuses.count("Passed"), "failedTests": statuses.count("Failed"),
                   "skippedTests": statuses.count("Skipped"), "expectedFailures": statuses.count("Expected Failure")}
        tests = {"testNodes": [{"nodeType": "Unit test bundle", "name": scopes.TARGET, "children": [
            {"nodeType": "Test Case", "name": name.rsplit("/", 1)[-1],
             "nodeIdentifier": name, "result": status} for name, status in entries
        ]}]}
        return summary, tests

    def execute(self, isolated, remaining, *, isolated_exit=0, remaining_exit=0):
        def runner(command, **kwargs):
            self.commands.append(command)
            if command[0] == "xcodebuild":
                code = (isolated_exit if any(arg.startswith("-only-testing:") for arg in command)
                        else remaining_exit if "test-without-building" in command else 0)
                return subprocess.CompletedProcess(command, code)
            scope = Path(command[command.index("--path") + 1]).stem
            values = isolated if scope == "isolated" else remaining
            return subprocess.CompletedProcess(command, 0, stdout=json.dumps(values[0 if command[4] == "summary" else 1]))
        with patch("builtins.print"):
            result = scopes.run(["xcodebuild", "-scheme", "CMUXMaestroPreview"], self.directory / "results", runner)
        return result, json.loads((self.directory / "results/coverage.json").read_text())

    def test_verified_one_test_then_full_complement_without_serialization(self):
        result, evidence = self.execute(self.report([(scopes.TEST, "Passed")]),
                                        self.report([("OtherSuite/first()", "Passed"), ("OtherSuite/second()", "Passed")]))
        self.assertEqual(result, 0)
        self.assertTrue(evidence["selectorVerifiedByHostedResult"])
        self.assertEqual(evidence["isolatedCounts"]["totalTestCount"], 1)
        self.assertEqual(evidence["remainingCounts"]["totalTestCount"], 2)
        commands = [command for command in self.commands if command[0] == "xcodebuild"]
        self.assertEqual(len(commands), 3)
        self.assertIn("build-for-testing", commands[0])
        self.assertIn("-only-testing:" + scopes.SELECTOR, commands[1])
        self.assertIn("-skip-testing:" + scopes.SELECTOR, commands[2])
        self.assertFalse(any("-parallel-testing-enabled" in command for command in commands))

    def test_failed_isolated_regression_still_runs_complement_and_remains_red(self):
        result, evidence = self.execute(self.report([(scopes.TEST, "Failed")]),
                                        self.report([("OtherSuite/test()", "Passed")]), isolated_exit=65)
        self.assertEqual(result, 1)
        self.assertTrue(evidence["selectorVerifiedByHostedResult"])
        self.assertEqual(evidence["remainingCounts"]["passedTests"], 1)
        self.assertFalse(evidence["passed"])

    def test_zero_or_wrong_selection_never_excludes_or_counts_as_success(self):
        for entries in ([], [("OtherSuite/notTheRegression()", "Passed")]):
            with self.subTest(entries=entries):
                result, evidence = self.execute(self.report(entries),
                                                self.report([(scopes.TEST, "Passed"), ("OtherSuite/test()", "Passed")]))
                self.assertEqual(result, 1)
                self.assertFalse(evidence["selectorVerifiedByHostedResult"])
                last = [command for command in self.commands if command[0] == "xcodebuild"][-1]
                self.assertFalse(any(arg.startswith("-skip-testing") for arg in last))
                self.assertTrue((self.directory / "results/full-fallback-summary.json").exists())
                shutil.rmtree(self.directory / "results")

    def test_unrelated_failure_is_not_hidden_by_isolated_success(self):
        result, evidence = self.execute(self.report([(scopes.TEST, "Passed")]),
                                        self.report([("ViewportSuite/staticFixture()", "Failed")]), remaining_exit=65)
        self.assertEqual(result, 1)
        self.assertEqual(evidence["remainingCounts"]["failedTests"], 1)
        self.assertFalse(evidence["passed"])

    def test_skipping_other_tests_or_repeating_the_regression_is_rejected(self):
        for entries in ([("OtherSuite/test()", "Skipped")],
                        [(scopes.TEST, "Passed"), ("OtherSuite/test()", "Passed")]):
            with self.subTest(entries=entries):
                result, evidence = self.execute(self.report([(scopes.TEST, "Passed")]), self.report(entries))
                self.assertEqual(result, 1)
                self.assertIn("remainingValidationError", evidence)
                shutil.rmtree(self.directory / "results")

    def test_only_the_already_executed_regression_may_be_reported_as_excluded(self):
        result, evidence = self.execute(self.report([(scopes.TEST, "Passed")]),
                                        self.report([(scopes.TEST, "Skipped"), ("OtherSuite/test()", "Passed")]))
        self.assertEqual(result, 0)
        self.assertEqual(evidence["remainingCounts"]["skippedTests"], 1)
        self.assertEqual(evidence["remainingCounts"]["passedTests"], 1)

    def test_selection_and_retry_overrides_cannot_reduce_full_coverage(self):
        for option in ("-only-testing:Other", "-skip-testing:Other", "-retry-tests-on-failure",
                       "-test-iterations", "-only-test-configuration", "-resultBundlePath", "-xctestrun"):
            with self.subTest(option=option), self.assertRaises(ValueError):
                scopes.validate_arguments(["xcodebuild", option])

    def test_actual_xcresult_identifier_url_is_bound_to_expected_method(self):
        summary, tree = self.report([(scopes.TEST, "Passed")])
        node = tree["testNodes"][0]["children"][0]
        node["nodeIdentifierURL"] = "test://com.apple.xcode/" + scopes.SELECTOR
        self.assertEqual(scopes.validate_isolated(summary, tree)["totalTestCount"], 1)
        node["nodeIdentifierURL"] += "-other"
        with self.assertRaises(ValueError):
            scopes.validate_isolated(summary, tree)

    def test_malformed_or_contradictory_result_evidence_cannot_pass(self):
        summary, tree = self.report([(scopes.TEST, "Passed")])
        for invalid in ([], {}, {**summary, "totalTestCount": True}, {**summary, "totalTestCount": 0}):
            with self.subTest(summary=invalid), self.assertRaises(ValueError):
                scopes.validate_isolated(invalid, tree)
        tree["testNodes"][0]["children"][0]["result"] = "Failed"
        with self.assertRaises(ValueError):
            scopes.validate_isolated(summary, tree)
        remaining_summary, remaining_tree = self.report([("OtherSuite/test()", "Passed")])
        remaining_tree["testNodes"][0]["children"][0]["result"] = "Failed"
        with self.assertRaises(ValueError):
            scopes.validate_remaining(remaining_summary, remaining_tree)


class BuildMetadataTests(unittest.TestCase):
    def test_app_bridge_markers_are_wired_as_input_plist_in_both_configurations(self):
        project = json.loads(subprocess.check_output([
            "/usr/bin/plutil", "-convert", "json", "-o", "-",
            str(ROOT / "CMUXMaestroPreview.xcodeproj/project.pbxproj"),
        ]))
        objects = project["objects"]
        target_id, target = next((key, value) for key, value in objects.items()
                                 if value.get("isa") == "PBXNativeTarget" and value.get("name") == "CMUXMaestroPreview")
        configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
        self.assertEqual({objects[key]["name"] for key in configurations}, {"Debug", "Release"})
        for key in configurations:
            with self.subTest(configuration=objects[key]["name"]):
                settings = objects[key]["buildSettings"]
                self.assertEqual(settings["GENERATE_INFOPLIST_FILE"], "YES")
                self.assertEqual(settings["INFOPLIST_FILE"], "CMUXMaestroPreview/Info.plist")
                source = metadata.plist(ROOT / settings["INFOPLIST_FILE"])
                self.assertEqual(source["CMUXMaestroInstallBridge"], "copilot-install-v1")
                self.assertEqual(source["CMUXMaestroAppLifecycleBridge"], "graceful-lifecycle-v1")
                self.assertNotIn("CFBundleIdentifier", source)
                self.assertNotIn("INFOPLIST_KEY_CMUXMaestroInstallBridge", settings)
                self.assertNotIn("INFOPLIST_KEY_CMUXMaestroAppLifecycleBridge", settings)
        group = next(objects[key] for key in target["fileSystemSynchronizedGroups"]
                     if objects[key]["path"] == "CMUXMaestroPreview")
        exclusions = [objects[key] for key in group["exceptions"] if objects[key]["target"] == target_id]
        self.assertTrue(any("Info.plist" in item["membershipExceptions"] for item in exclusions))

    def test_production_preview_disables_profile_output_without_disabling_test_coverage(self):
        production = (ROOT / "scripts/build-register.sh").read_text()
        validation = (ROOT / "scripts/test.sh").read_text()
        self.assertIn("ENABLE_CODE_COVERAGE=NO", production)
        self.assertNotIn("ENABLE_CODE_COVERAGE=NO", validation)

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
                       "CFBundleVersion": metadata.APP_BUILD_VERSION, "CMUXMaestroInstallBridge": "copilot-install-v1",
                       "CMUXMaestroAppLifecycleBridge": "graceful-lifecycle-v1"}
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
        (resources / "adapter.mjs").write_text("// synthetic adapter\n")
        (resources / "extension.mjs").write_text("// synthetic loader\n")
        self.save()

    def test_messaging_resources_are_required_for_every_build_profile(self):
        for name in ("adapter.mjs", "extension.mjs"):
            with self.subTest(name=name):
                self.fixture("tests")
                (self.app / "Contents/Resources" / name).unlink()
                with self.assertRaisesRegex(ValueError, "messaging resource"):
                    metadata.verify_metadata(self.app, "tests")

    def test_non_ui_bridge_is_required_for_new_artifacts_not_historical_receipts(self):
        for mode in metadata.PROFILES:
            for key in ("CMUXMaestroInstallBridge", "CMUXMaestroAppLifecycleBridge"):
                with self.subTest(mode=mode, capability=key):
                    self.fixture(mode)
                    del self.parent[key]
                    self.save()
                    with self.assertRaisesRegex(ValueError, "bridge"):
                        metadata.verify_metadata(self.app, mode)
                    if mode == "production":
                        metadata.verify_metadata(self.app, mode, require_bridge=False)

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
        self.assertLess(script.index('--mode production --app "$APP"'), script.index('local-preview.py" install'))
        self.assertIn('--retire-development-registration "$@"', script)
        self.assertNotIn('pluginkit -a "$APPEX"', script)

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
