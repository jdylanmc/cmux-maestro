#!/usr/bin/env python3
"""Non-GUI contracts for the additive guide consumer build and execution boundary."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch
import uuid
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("guide_probe", ROOT / "scripts/run-guide-ui-validation.py")
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)
metadata = probe.metadata


class GuideUIValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = json.loads(subprocess.check_output([
            "/usr/bin/plutil", "-convert", "json", "-o", "-",
            str(ROOT / "CMUXMaestroPreview.xcodeproj/project.pbxproj"),
        ]))

    def setUp(self):
        self.directory = ROOT / ".build/guide-ui-contracts" / uuid.uuid4().hex
        self.commands = []
        self.environments = []
        self.native_exit = 0
        self.build_exit = 0
        self.test_status = "Passed"
        self.identity = probe.TEST_IDENTITY.split("/", 1)[1]
        self.product_identifier = metadata.BASE_ID + ".Validation.Tests.GuideHost"

    def tearDown(self):
        if self.directory.exists():
            shutil.rmtree(self.directory)

    @staticmethod
    def settings():
        rows = []
        for name, ending, product in (
            (metadata.GUIDE_HOST, ".GuideHost", "application"),
            (metadata.GUIDE_TESTS, ".GuideUITests", "bundle.ui-testing"),
        ):
            settings = {
                "PRODUCT_BUNDLE_IDENTIFIER": metadata.BASE_ID + ".Validation.Tests" + ending,
                "PRODUCT_NAME": name, "PRODUCT_TYPE": "com.apple.product-type." + product,
                "CODE_SIGNING_ALLOWED": "NO", "CODE_SIGNING_REQUIRED": "NO",
                "ENABLE_APP_SANDBOX": "NO", "SKIP_INSTALL": "YES",
                "MACOSX_DEPLOYMENT_TARGET": "14.0",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG CMUX_GUIDE_UI_VALIDATION",
            }
            if name == metadata.GUIDE_TESTS:
                settings["TEST_TARGET_NAME"] = metadata.GUIDE_HOST
            rows.append({"target": name, "buildSettings": settings})
        return rows

    def build_products(self):
        products = self.directory / "derived/Build/Products/Debug"
        runner = products / (metadata.GUIDE_TESTS + "-Runner.app")
        for bundle, identifier, package in (
            (products / (metadata.GUIDE_HOST + ".app"), self.product_identifier, "APPL"),
            (runner, metadata.BASE_ID + ".Validation.Tests.GuideUITests.xctrunner", "APPL"),
            (runner / "Contents/PlugIns" / (metadata.GUIDE_TESTS + ".xctest"),
             metadata.BASE_ID + ".Validation.Tests.GuideUITests", "BNDL"),
        ):
            binary = bundle / "Contents/MacOS/synthetic"
            binary.parent.mkdir(parents=True)
            binary.write_text("Synthetic non-executable fixture bytes, never launched.")
            binary.chmod(0o700)
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": identifier, "CFBundleExecutable": "synthetic", "CFBundlePackageType": package,
            }))

    def runner(self, command, **kwargs):
        self.commands.append(command)
        self.environments.append(kwargs["env"])
        output, code = "", 0
        if command[:2] == ["git", "rev-parse"]:
            output = "a" * 40
        elif command[0] == "/usr/bin/plutil":
            output = json.dumps(self.project)
        elif "-showBuildSettings" in command:
            output = json.dumps(self.settings())
        elif "build-for-testing" in command:
            code = self.build_exit
            if not code:
                self.build_products()
        elif "test-without-building" in command:
            code = self.native_exit
        elif command[0] == "xcrun":
            if command[4] == "summary":
                passed = self.test_status == "Passed"
                output = json.dumps({
                    "result": "Passed" if passed else "Failed", "totalTestCount": 1,
                    "passedTests": int(passed), "failedTests": int(not passed), "skippedTests": 0,
                    "expectedFailures": 0,
                })
            else:
                output = json.dumps({"testNodes": [{
                    "nodeType": "UI test bundle", "name": metadata.GUIDE_TESTS, "children": [{
                        "nodeType": "Test Case", "nodeIdentifier": self.identity, "result": self.test_status,
                    }],
                }]})
        return subprocess.CompletedProcess(command, code, stdout=output)

    def execute(self, compile_only=False, environment=None):
        if environment is None:
            environment = {"DEVELOPER_DIR": probe.DEVELOPER, "GITHUB_ACTIONS": "true",
                           "RUNNER_ENVIRONMENT": "github-hosted", "TEST_RUNNER_GITHUB_ACTIONS": "stale",
                           "TEST_RUNNER_RUNNER_ENVIRONMENT": "stale",
                           "TEST_RUNNER_CMUX_GUIDE_UI_HOST_PATH": "/not/the/host"}
        with patch("builtins.print"):
            result = probe.run(compile_only, self.directory, runner=self.runner, environment=environment)
        evidence = json.loads((self.directory / "evidence.json").read_text())
        return result, evidence

    def test_original_venue_values_forwarded_and_exact_host_overwrites_stale_alias(self):
        result, evidence = self.execute()
        self.assertEqual(result, 0)
        native = [index for index, command in enumerate(self.commands) if "test-without-building" in command]
        self.assertEqual(len(native), 1)
        environment = self.environments[native[0]]
        for key in ("GITHUB_ACTIONS", "RUNNER_ENVIRONMENT"):
            self.assertEqual(environment["TEST_RUNNER_" + key], environment[key])
        self.assertEqual(environment["TEST_RUNNER_CMUX_GUIDE_UI_HOST_PATH"],
                         str(self.directory / "derived/Build/Products/Debug/CMUXMaestroGuideUIHost.app"))
        self.assertEqual(sum("build-for-testing" in command and "-showBuildSettings" not in command
                             for command in self.commands), 1)
        self.assertEqual(evidence["verifiedTestIdentity"], probe.TEST_IDENTITY)
        self.assertNotIn("-retry-tests-on-failure", sum(self.commands, []))

    def test_refuses_local_and_self_hosted_before_any_command(self):
        for venue in ({}, {"GITHUB_ACTIONS": "true"}, {"RUNNER_ENVIRONMENT": "github-hosted"},
                      {"GITHUB_ACTIONS": "TRUE", "RUNNER_ENVIRONMENT": "github-hosted"},
                      {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"}):
            with self.subTest(venue=venue):
                environment = {"DEVELOPER_DIR": probe.DEVELOPER, "TEST_RUNNER_GITHUB_ACTIONS": "true",
                               "TEST_RUNNER_RUNNER_ENVIRONMENT": "github-hosted", **venue}
                result, evidence = self.execute(environment=environment)
                self.assertEqual(result, 1)
                self.assertEqual(self.commands, [])
                self.assertEqual(evidence["nativeResult"], "not-run")
                shutil.rmtree(self.directory)

    def test_compile_only_never_launches_or_exports_test_results(self):
        result, evidence = self.execute(True, {"DEVELOPER_DIR": probe.DEVELOPER})
        self.assertEqual(result, 0)
        self.assertEqual(evidence["nativeResult"], "not-run")
        self.assertTrue(evidence["compileOnly"])
        self.assertEqual(sum("build-for-testing" in command and "-showBuildSettings" not in command
                             for command in self.commands), 1)
        self.assertFalse(any("test-without-building" in command or command[0] == "xcrun" for command in self.commands))

    def test_build_and_runner_do_not_inherit_credentials_or_unrelated_test_overrides(self):
        environment = {
            "DEVELOPER_DIR": probe.DEVELOPER, "GITHUB_ACTIONS": "true",
            "RUNNER_ENVIRONMENT": "github-hosted", "HOME": "/synthetic/home",
            "GH_TOKEN": "synthetic-secret", "TEST_RUNNER_DYLD_INSERT_LIBRARIES": "/foreign.dylib",
            "TEST_RUNNER_CMUX_GUIDE_UI_HOST_PATH": "/foreign.app",
        }
        original = dict(environment)
        result, _ = self.execute(environment=environment)
        self.assertEqual(result, 0)
        self.assertEqual(environment, original)
        for forwarded in self.environments:
            self.assertNotIn("GH_TOKEN", forwarded)
            self.assertNotIn("TEST_RUNNER_DYLD_INSERT_LIBRARIES", forwarded)
            self.assertEqual(forwarded["HOME"], environment["HOME"])
        self.assertNotIn("synthetic-secret", (self.directory / "evidence.json").read_text())

    def test_native_failure_is_retained_without_retry(self):
        self.native_exit = 65
        self.test_status = "Failed"
        result, evidence = self.execute()
        self.assertEqual(result, 1)
        self.assertEqual(evidence["nativeResult"], "failed")
        self.assertEqual(sum("test-without-building" in command for command in self.commands), 1)
        self.assertTrue((self.directory / "result-tests.log").exists())

    def test_zero_exit_with_wrong_test_identity_is_not_success(self):
        self.identity = "OtherSuite/testWrong()"
        result, evidence = self.execute()
        self.assertEqual(result, 1)
        self.assertEqual(evidence["nativeResult"], "failed")

    def test_wrong_built_namespace_prevents_execution(self):
        self.product_identifier = metadata.BASE_ID
        result, evidence = self.execute()
        self.assertEqual(result, 1)
        self.assertEqual(evidence["nativeResult"], "not-run")
        self.assertFalse(any("test-without-building" in command for command in self.commands))

    def test_failed_build_never_launches_or_retries(self):
        self.build_exit = 65
        result, evidence = self.execute()
        self.assertEqual(result, 1)
        self.assertEqual(evidence["nativeResult"], "not-run")
        self.assertEqual(sum("build-for-testing" in command and "-showBuildSettings" not in command
                             for command in self.commands), 1)
        self.assertFalse(any("test-without-building" in command for command in self.commands))

    def test_exact_single_source_membership_and_no_production_dependencies(self):
        inventory = metadata.verify_guide_ui_project(self.project)
        self.assertEqual(inventory[metadata.GUIDE_HOST], sorted(metadata.GUIDE_HOST_SOURCES))
        for kind in ("source", "dependency", "production-dependency"):
            altered = copy.deepcopy(self.project)
            objects = altered["objects"]
            targets = {value["name"]: value for value in objects.values() if value.get("isa") == "PBXNativeTarget"}
            host = targets[metadata.GUIDE_HOST]
            if kind == "source":
                sources = objects[host["buildPhases"][0]]
                sources["files"].append(sources["files"][0])
            elif kind == "dependency":
                host["dependencies"] = targets["CMUXMaestroPreview"]["dependencies"]
            else:
                targets["CMUXMaestroPreview"]["dependencies"] += targets[metadata.GUIDE_TESTS]["dependencies"]
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                metadata.verify_guide_ui_project(altered)

    def test_settings_refuse_signing_entitlements_wrong_target_and_namespace(self):
        metadata.verify_guide_ui_settings(self.settings())
        for key, value in (("CODE_SIGNING_ALLOWED", "YES"), ("CODE_SIGNING_REQUIRED", "YES"),
                           ("CODE_SIGN_ENTITLEMENTS", "extra.entitlements"), ("TEST_HOST", "/production"),
                           ("TEST_TARGET_NAME", "CMUXMaestroPreview"),
                           ("PRODUCT_BUNDLE_IDENTIFIER", metadata.BASE_ID)):
            rows = self.settings()
            rows[1]["buildSettings"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                metadata.verify_guide_ui_settings(rows)
        with self.assertRaises(ValueError):
            metadata.verify_guide_ui_settings(self.settings() + [self.settings()[0]])

    def test_scheme_is_additive_and_not_archived_or_in_original_test_action(self):
        schemes = ROOT / "CMUXMaestroPreview.xcodeproj/xcshareddata/xcschemes"
        original = ET.parse(schemes / "CMUXMaestroPreview.xcscheme")
        self.assertEqual([item.attrib["BlueprintName"] for item in original.findall(".//TestableReference/BuildableReference")],
                         ["CMUXMaestroPreviewTests"])
        scheme = ET.parse(schemes / (probe.SCHEME + ".xcscheme"))
        self.assertEqual([item.attrib["BlueprintName"] for item in scheme.findall(".//TestableReference/BuildableReference")],
                         [metadata.GUIDE_TESTS])
        for entry in scheme.findall(".//BuildActionEntry"):
            self.assertEqual(entry.attrib["buildForArchiving"], "NO")
            self.assertEqual(entry.attrib["buildForRunning"], "NO")
        self.assertEqual(scheme.find("BuildAction").attrib["buildImplicitDependencies"], "NO")

    def test_probe_ci_job_is_independent_and_preserves_failure_evidence(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        original, additive = workflow.split("\n  guide-ui-consumer-probe:", 1)
        self.assertNotIn("needs:", additive)
        self.assertNotIn("continue-on-error", workflow)
        self.assertIn("if: always()", additive)
        self.assertIn("run-*/probe.xcresult", additive)
        self.assertIn("run-*/evidence.json", additive)
        self.assertIn("run-*/*.log", additive)
        self.assertIn("name: sidebar-layout-offscreen", original)
        self.assertIn("name: integrated-test-scope-evidence", original)
        self.assertEqual(additive.count("run: ./scripts/test-guide-ui-validation.sh"), 1)

    def test_wrapper_rejects_extra_selectors_even_in_compile_only_mode(self):
        result = subprocess.run(["bash", str(ROOT / "scripts/test-guide-ui-validation.sh"),
                                 "--compile-only", "-only-testing:Other"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("unrecognized arguments", result.stderr)


if __name__ == "__main__":
    unittest.main()
