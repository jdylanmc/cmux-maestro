#!/usr/bin/env python3
import fnmatch
import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
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
row_spec = importlib.util.spec_from_file_location("row_input", ROOT / "scripts/run-row-input-tests.py")
row_input = importlib.util.module_from_spec(row_spec)
row_spec.loader.exec_module(row_input)
BENCHMARK_TEST = "CopilotReaderTests/coldStartBenchmarkWith230MiBOfIgnoredSyntheticPayloads()"
BENCHMARK_FLAG = "CMUX_MAESTRO_READER_BENCHMARK"


class RowInputVenueTests(unittest.TestCase):
    def report(self, methods=None, status="Passed"):
        methods = row_input.METHODS if methods is None else methods
        entries = [(f"RowInputUITests/{name}()", status) for name in methods]
        summary, tests = IntegratedTestScopeTests.report(entries)
        bundle = tests["testNodes"][0]
        bundle.update(nodeType="UI test bundle", name=row_input.TARGET,
                      nodeIdentifierURL="test://com.apple.xcode/CMUXMaestroPreview/" + row_input.TARGET)
        for node in bundle["children"]:
            node["nodeIdentifierURL"] = bundle["nodeIdentifierURL"] + "/" + node["nodeIdentifier"].removesuffix("()")
        suite = {"nodeType": "Test Suite", "name": "RowInputUITests",
                 "nodeIdentifierURL": bundle["nodeIdentifierURL"] + "/RowInputUITests",
                 "children": bundle["children"]}
        bundle["children"] = [suite]
        tests["testNodes"] = [{"nodeType": "Test Plan", "name": "CMUXMaestroRowInput", "children": [bundle]}]
        return summary, tests

    @staticmethod
    def bundle(tests):
        return tests["testNodes"][0]["children"][0]

    def test_project_plan_target_suite_and_method_remain_independently_bound(self):
        for level in ("plan", "bundle", "suite", "case"):
            for field in ("name", "nodeIdentifierURL"):
                if level == "plan" and field == "nodeIdentifierURL":
                    continue
                summary, tests = self.report()
                bundle = self.bundle(tests)
                suite = bundle["children"][0]
                node = {"plan": tests["testNodes"][0], "bundle": bundle,
                        "suite": suite, "case": suite["children"][0]}[level]
                if level == "case" and field == "name":
                    field = "nodeIdentifier"
                node[field] += "-foreign"
                with self.subTest(level=level, field=field), self.assertRaises(ValueError):
                    row_input.validate_results(summary, tests)
        for level in ("bundle", "suite", "case"):
            summary, tests = self.report()
            bundle = self.bundle(tests)
            suite = bundle["children"][0]
            node = {"bundle": bundle, "suite": suite, "case": suite["children"][0]}[level]
            del node["nodeIdentifierURL"]
            with self.subTest(missingURL=level), self.assertRaises(ValueError):
                row_input.validate_results(summary, tests)

    def settings(self):
        return [{"target": name, "buildSettings": {
            "PRODUCT_BUNDLE_IDENTIFIER": identifier,
            "CODE_SIGNING_ALLOWED": "NO", "CODE_SIGNING_REQUIRED": "NO",
            "SKIP_INSTALL": "YES", "ENABLE_APP_SANDBOX": "NO",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG CMUX_VALIDATION",
            "TEST_TARGET_NAME": "CMUXMaestroRowInputFixture",
            "INFOPLIST_KEY_LSUIElement": "YES",
        }} for name, identifier in metadata.ROW_INPUT_TARGETS.items()]

    def test_row_fixture_must_be_an_accessory_before_launch(self):
        for value in (None, "NO"):
            rows = self.settings()
            fixture = next(row["buildSettings"] for row in rows if row["target"] == "CMUXMaestroRowInputFixture")
            if value is None:
                fixture.pop("INFOPLIST_KEY_LSUIElement")
            else:
                fixture["INFOPLIST_KEY_LSUIElement"] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                metadata.verify_row_input_settings(rows)

    def test_exact_six_ui_cases_pass_once(self):
        counts = row_input.validate_results(*self.report())
        self.assertEqual(counts["passedTests"], 6)

    def test_nested_foreign_or_duplicate_plan_cannot_supply_required_cases(self):
        for name in ("UnapprovedPlan", "CMUXMaestroRowInput"):
            summary, tests = self.report()
            root = tests["testNodes"][0]
            root["children"] = [{"nodeType": "Test Plan", "name": name, "children": root["children"]}]
            with self.subTest(nestedPlan=name), self.assertRaises(ValueError):
                row_input.validate_results(summary, tests)

    def test_failed_hosted_cases_are_observed_but_never_accepted(self):
        summary, tests = self.report(status="Failed")
        selected = row_input.observed_cases(tests)
        self.assertEqual(len(selected), 6)
        self.assertTrue(all(case.status == "Failed" and case.executions == ((None, "Failed"),)
                            for case in selected))
        self.assertEqual(scopes.reconcile(summary, selected)["failedTests"], 6)
        with self.assertRaisesRegex(ValueError, "must each pass once"):
            row_input.validate_results(summary, tests)

    def test_only_empty_xctest_argument_suffix_is_normalized(self):
        summary, tests = self.report()
        case = self.bundle(tests)["children"][0]["children"][0]
        case["nodeIdentifier"] = case["nodeIdentifier"].removesuffix("()") + "(foreign:)"
        with self.assertRaisesRegex(ValueError, "identifier and URL disagree"):
            row_input.validate_results(summary, tests)

    def test_extraction_failure_preserves_full_stderr_in_uploaded_artifacts(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job = workflow.split("\n  row-input:\n", 1)[1].split("\n  validate:\n", 1)[0]
        patterns = [line.strip() for line in job.splitlines()
                    if line.strip().startswith(".build/row-input/")]
        message = "synthetic extractor failure:" + "X" * 5000 + ":TAIL_SENTINEL"
        for failed_kind in ("summary", "tests"):
            def extract(command, **kwargs):
                if command[4] == failed_kind:
                    raise subprocess.CalledProcessError(65, command, stderr=message)
                return subprocess.CompletedProcess(command, 0, stdout="{}")

            with self.subTest(kind=failed_kind), \
                    tempfile.TemporaryDirectory(prefix="row-input-extraction-") as temporary:
                directory = Path(temporary)
                printed = io.StringIO()
                with patch("sys.stderr", printed), self.assertRaises(subprocess.CalledProcessError) as failure:
                    scopes.read_result(directory / "row-input.xcresult", directory, "row-input", extract)
                self.assertEqual(failure.exception.returncode, 65)
                error = directory / f"row-input-{failed_kind}.error"
                self.assertEqual(error.read_text(), message)
                self.assertNotIn("TAIL_SENTINEL", printed.getvalue())
                artifact_path = f".build/row-input/run-fixture/{error.name}"
                self.assertTrue(any(fnmatch.fnmatchcase(artifact_path, pattern) for pattern in patterns),
                                f"Full extractor stderr is excluded from CI artifacts: {artifact_path}")

    def test_zero_missing_extra_and_wrong_target_cannot_pass(self):
        for methods in (set(), set(list(row_input.METHODS)[1:]), row_input.METHODS | {"testUnapproved"}):
            with self.subTest(methods=methods), self.assertRaises(ValueError):
                row_input.validate_results(*self.report(methods))
        summary, tests = self.report()
        self.bundle(tests)["name"] = "CMUXMaestroPreviewTests"
        with self.assertRaises(ValueError):
            row_input.validate_results(summary, tests)

    def test_failed_skipped_expected_failure_and_duplicate_are_not_success(self):
        for status in ("Failed", "Skipped", "Expected Failure"):
            with self.subTest(status=status), self.assertRaises(ValueError):
                row_input.validate_results(*self.report(status=status))
        summary, tests = self.report()
        suite = self.bundle(tests)["children"][0]
        suite["children"].append(suite["children"][0])
        with self.assertRaises(ValueError):
            row_input.validate_results(summary, tests)

    def test_repetition_and_miscount_are_rejected(self):
        summary, tests = self.report()
        self.bundle(tests)["children"][0]["children"][0]["children"] = [
            {"nodeType": "Repetition", "result": "Passed"}]
        with self.assertRaises(ValueError):
            row_input.validate_results(summary, tests)
        summary, tests = self.report()
        summary["passedTests"] -= 1
        with self.assertRaises(ValueError):
            row_input.validate_results(summary, tests)

    def test_nonhosted_refuses_before_any_subprocess_or_ui_access(self):
        for environment in ({}, {"GITHUB_ACTIONS": "true"}, {"RUNNER_ENVIRONMENT": "github-hosted"},
                            {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"}):
            with self.subTest(environment=environment), patch.dict(os.environ, environment, clear=True), \
                    patch.object(row_input.subprocess, "run") as run, \
                    patch.object(row_input.subprocess, "check_output") as output:
                with self.assertRaises(ValueError):
                    row_input.run(False)
                run.assert_not_called()
                output.assert_not_called()
        row_input.require_hosted({"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"})

    def test_fixed_namespace_and_noninstallation_settings(self):
        metadata.verify_row_input_settings(self.settings())
        for index in (0, 1):
            for key, value in (
                ("PRODUCT_BUNDLE_IDENTIFIER", metadata.BASE_ID),
                ("CODE_SIGNING_ALLOWED", "YES"), ("CODE_SIGNING_REQUIRED", "YES"),
                ("SKIP_INSTALL", "NO"), ("ENABLE_APP_SANDBOX", "YES"),
            ):
                rows = self.settings()
                rows[index]["buildSettings"][key] = value
                with self.subTest(index=index, key=key), self.assertRaises(ValueError):
                    metadata.verify_row_input_settings(rows)
        for rows in ([], self.settings()[:1], self.settings()[1:]):
            with self.assertRaises(ValueError):
                metadata.verify_row_input_settings(rows)
        rows = self.settings()
        rows[0]["buildSettings"]["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
        with self.assertRaises(ValueError):
            metadata.verify_row_input_settings(rows)
        rows = self.settings()
        rows[1]["buildSettings"]["TEST_TARGET_NAME"] = "CMUXMaestroPreview"
        with self.assertRaises(ValueError):
            metadata.verify_row_input_settings(rows)

    def test_built_product_namespace_rejects_production_ids_and_embedded_helpers(self):
        with tempfile.TemporaryDirectory(prefix="row-input-metadata-") as temporary:
            products = Path(temporary)
            fixture = products / "CMUXMaestroRowInputFixture.app"
            runner = products / "CMUXMaestroRowInputUITests-Runner.app"
            tests = runner / "Contents/PlugIns/CMUXMaestroRowInputUITests.xctest"
            bundles = [
                (fixture, "CMUXMaestroRowInputFixture", metadata.ROW_INPUT_TARGETS["CMUXMaestroRowInputFixture"], "APPL"),
                (tests, "CMUXMaestroRowInputUITests", metadata.ROW_INPUT_TARGETS["CMUXMaestroRowInputUITests"], "BNDL"),
                (runner, "CMUXMaestroRowInputUITests-Runner",
                 metadata.ROW_INPUT_TARGETS["CMUXMaestroRowInputUITests"] + ".xctrunner", "APPL"),
            ]
            for path, executable, identifier, kind in bundles:
                (path / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
                (path / "Contents/MacOS" / executable).write_text("metadata-only fixture; never executed")
                (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": identifier, "CFBundlePackageType": kind, "CFBundleExecutable": executable,
                    **({"LSUIElement": True} if path == fixture else {}),
                }))
            metadata.verify_row_input_products(products)
            fixture_info = fixture / "Contents/Info.plist"
            original_fixture_info = fixture_info.read_bytes()
            for value in (None, False, "YES"):
                value_info = plistlib.loads(original_fixture_info)
                if value is None:
                    value_info.pop("LSUIElement")
                else:
                    value_info["LSUIElement"] = value
                fixture_info.write_bytes(plistlib.dumps(value_info))
                with self.subTest(accessoryFlag=value), self.assertRaises(ValueError):
                    metadata.verify_row_input_products(products)
            fixture_info.write_bytes(original_fixture_info)
            for path, _, _, _ in bundles:
                info = path / "Contents/Info.plist"
                original = info.read_bytes()
                value = plistlib.loads(original)
                value["CFBundleIdentifier"] = metadata.BASE_ID
                info.write_bytes(plistlib.dumps(value))
                with self.subTest(path=path), self.assertRaises(ValueError):
                    metadata.verify_row_input_products(products)
                info.write_bytes(original)
            for directory in ("Helpers", "Extensions"):
                path = fixture / "Contents" / directory
                path.mkdir()
                with self.subTest(directory=directory), self.assertRaises(ValueError):
                    metadata.verify_row_input_products(products)
                path.rmdir()


class IntegratedTestScopeTests(unittest.TestCase):
    def setUp(self):
        self.directory = ROOT / ".build/metadata-tests" / str(uuid.uuid4())
        self.directory.mkdir(parents=True)
        self.commands = []
        self.build_environments = []

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

    def execute(self, isolated, remaining, *, isolated_exit=0, remaining_exit=0, benchmark_flag=None, guide_exit=0):
        def runner(command, **kwargs):
            self.commands.append(command)
            if command[0] == "xcodebuild":
                self.build_environments.append(kwargs.get("env"))
                code = (isolated_exit if any(arg.startswith("-only-testing:") for arg in command)
                        else remaining_exit if "test-without-building" in command else 0)
                return subprocess.CompletedProcess(command, code)
            scope = Path(command[command.index("--path") + 1]).stem
            values = isolated if scope == "isolated" else remaining
            return subprocess.CompletedProcess(command, 0, stdout=json.dumps(values[0 if command[4] == "summary" else 1]))
        # These fixtures isolate the existing partition/count policy, not native guide execution.
        with patch("builtins.print"), patch.dict(os.environ), \
                patch.object(scopes, "produce_guide_acceptance", return_value={"exitCode": guide_exit, "environment": {}}), \
                patch.object(scopes, "revalidate_guide_acceptance",
                             side_effect=ValueError("Synthetic native producer failed") if guide_exit else None), \
                patch.object(scopes, "validate_original_guide_cases"):
            if benchmark_flag is None:
                os.environ.pop(BENCHMARK_FLAG, None)
            else:
                os.environ[BENCHMARK_FLAG] = benchmark_flag
            result = scopes.run(["xcodebuild", "-scheme", "CMUXMaestroPreview"], self.directory / "results", runner)
        return result, json.loads((self.directory / "results/coverage.json").read_text())

    def test_native_producer_failure_preserves_both_original_integrated_actions(self):
        result, evidence = self.execute(self.report([(scopes.TEST, "Passed")]),
                                        self.report([("OtherSuite/test()", "Passed")]), guide_exit=65)
        self.assertEqual(result, 1)
        self.assertEqual(evidence["guideAcceptance"]["exitCode"], 65)
        self.assertIn("guideAcceptanceError", evidence)
        self.assertEqual(sum("test-without-building" in command for command in self.commands), 2)
        self.assertEqual(evidence["remainingCounts"]["passedTests"], 1)
        for environment in self.build_environments[1:]:
            self.assertFalse(any(key.startswith("TEST_RUNNER_CMUX_GUIDE_ACCEPTANCE_") for key in environment))

    def test_stale_acceptance_aliases_never_reach_original_validators(self):
        original = {
            "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
            "CMUX_GUIDE_ACCEPTANCE_DIRECTORY": "/prior/invocation",
            "TEST_RUNNER_CMUX_GUIDE_ACCEPTANCE_INVOCATION": "stale",
            "TEST_RUNNER_CMUX_GUIDE_ACCEPTANCE_STATUSES_SHA256": "stale",
        }
        actual = scopes.hosted_test_environment(original)
        self.assertFalse(any("GUIDE_ACCEPTANCE" in key for key in actual))
        self.assertIn("TEST_RUNNER_CMUX_GUIDE_ACCEPTANCE_INVOCATION", original)

    def test_hosted_venue_forwarding_uses_original_values_for_both_test_actions(self):
        with patch.dict(os.environ, {
            "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
            "TEST_RUNNER_GITHUB_ACTIONS": "stale",
            "TEST_RUNNER_RUNNER_ENVIRONMENT": "self-hosted",
            "TEST_RUNNER_UNRELATED": "preserved",
        }):
            original = dict(os.environ)
            result, evidence = self.execute(self.report([(scopes.TEST, "Passed")]),
                                            self.report([("OtherSuite/test()", "Passed")]))
            self.assertEqual(dict(os.environ), original)
        self.assertEqual(result, 0)
        self.assertEqual(len(self.build_environments), 3)
        self.assertIsNone(self.build_environments[0])
        for environment in self.build_environments[1:]:
            self.assertIsNotNone(environment)
            self.assertEqual(environment["GITHUB_ACTIONS"], "true")
            self.assertEqual(environment["RUNNER_ENVIRONMENT"], "github-hosted")
            for name in ("GITHUB_ACTIONS", "RUNNER_ENVIRONMENT"):
                self.assertEqual(environment["TEST_RUNNER_" + name], environment[name])
            self.assertEqual(environment["TEST_RUNNER_UNRELATED"], "preserved")
        self.assertEqual(evidence["guideCalibrationVenue"], {
            "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
            "forwarding": "xcodebuild TEST_RUNNER_",
        })

    def test_local_or_nonhosted_venue_strips_aliases_without_excluding_existing_actions(self):
        for outer in (
            {}, {"GITHUB_ACTIONS": "true"}, {"RUNNER_ENVIRONMENT": "github-hosted"},
            {"GITHUB_ACTIONS": "false", "RUNNER_ENVIRONMENT": "github-hosted"},
            {"GITHUB_ACTIONS": "TRUE", "RUNNER_ENVIRONMENT": "github-hosted"},
            {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"},
            {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "__CURRENT_VALUE__"},
        ):
            with self.subTest(outer=outer), patch.dict(os.environ, {
                **outer, "TEST_RUNNER_GITHUB_ACTIONS": "true",
                "TEST_RUNNER_RUNNER_ENVIRONMENT": "github-hosted",
                "TEST_RUNNER_UNRELATED": "preserved",
            }, clear=True):
                original = dict(os.environ)
                result, evidence = self.execute(self.report([(scopes.TEST, "Passed")]),
                                                self.report([("OtherSuite/test()", "Passed")]))
                self.assertEqual(result, 0)
                self.assertEqual(dict(os.environ), original)
                commands = [command for command in self.commands if command[0] == "xcodebuild"]
                self.assertEqual(len(commands), 3)
                self.assertIn("build-for-testing", commands[0])
                self.assertIn("-only-testing:" + scopes.SELECTOR, commands[1])
                self.assertIn("-skip-testing:" + scopes.SELECTOR, commands[2])
                self.assertIsNone(self.build_environments[0])
                for environment in self.build_environments[1:]:
                    self.assertNotIn("TEST_RUNNER_GITHUB_ACTIONS", environment)
                    self.assertNotIn("TEST_RUNNER_RUNNER_ENVIRONMENT", environment)
                    self.assertEqual(environment.get("GITHUB_ACTIONS"), outer.get("GITHUB_ACTIONS"))
                    self.assertEqual(environment.get("RUNNER_ENVIRONMENT"), outer.get("RUNNER_ENVIRONMENT"))
                    self.assertEqual(environment["TEST_RUNNER_UNRELATED"], "preserved")
                self.assertEqual(evidence["guideCalibrationVenue"], {
                    "GITHUB_ACTIONS": outer.get("GITHUB_ACTIONS"),
                    "RUNNER_ENVIRONMENT": outer.get("RUNNER_ENVIRONMENT"),
                    "forwarding": None,
                })
                shutil.rmtree(self.directory / "results")
                self.commands.clear()
                self.build_environments.clear()

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

    def test_existing_optional_benchmark_skip_preserves_counts_and_attribution(self):
        for excluded in (False, True):
            with self.subTest(excluded=excluded):
                if (self.directory / "results").exists():
                    shutil.rmtree(self.directory / "results")
                entries = [(BENCHMARK_TEST, "Skipped"), ("OtherSuite/test()", "Passed")]
                if excluded:
                    entries.append((scopes.TEST, "Skipped"))
                remaining = self.report(entries)
                remaining[1]["testNodes"][0]["children"][0]["details"] = "Synthetic recorded skip detail"
                result, evidence = self.execute(self.report([(scopes.TEST, "Passed")]), remaining)
                self.assertEqual(result, 0)
                counts = evidence["remainingCounts"]
                self.assertEqual(counts["skippedTests"], 1 + int(excluded))
                self.assertEqual(counts["executionCounts"]["skippedTests"], 1 + int(excluded))
                self.assertEqual(counts["logicalCounts"]["totalTestCount"], len(entries))
                self.assertEqual(evidence["combinedExecutedTestCount"], 2)
                attributed = {item["identity"]: item for item in counts["skippedTestsByIdentity"]}
                benchmark = attributed[scopes.TARGET + "/" + BENCHMARK_TEST]
                self.assertEqual(benchmark["policyReason"], "existing-opt-in-benchmark-disabled")
                self.assertEqual(benchmark["reportedDetails"], "Synthetic recorded skip detail")
                if excluded:
                    self.assertEqual(attributed[scopes.SELECTOR]["policyReason"], "verified-isolated-selector-exclusion")
                self.assertEqual(evidence["optionalBenchmark"]["environmentValue"], None)
                self.assertFalse(evidence["optionalBenchmark"]["enabled"])
                shutil.rmtree(self.directory / "results")

    def test_full_fallback_attributes_optional_skip_but_never_turns_green(self):
        result, evidence = self.execute(self.report([("OtherSuite/wrongSelection()", "Passed")]),
                                        self.report([(scopes.TEST, "Passed"), (BENCHMARK_TEST, "Skipped")]))
        self.assertEqual(result, 1)
        self.assertFalse(evidence["selectorVerifiedByHostedResult"])
        self.assertFalse(evidence["passed"])
        self.assertEqual(evidence["remainingCounts"]["skippedTests"], 1)
        self.assertEqual(evidence["remainingCounts"]["skippedTestsByIdentity"][0]["identity"],
                         scopes.TARGET + "/" + BENCHMARK_TEST)
        final = [command for command in self.commands if command[0] == "xcodebuild"][-1]
        self.assertFalse(any(arg.startswith("-skip-testing:") for arg in final))

    def test_benchmark_skip_permission_uses_exact_inherited_flag_without_setting_it(self):
        for flag in (None, "", "0", "true", "1"):
            with self.subTest(flag=flag):
                if (self.directory / "results").exists():
                    shutil.rmtree(self.directory / "results")
                result, evidence = self.execute(self.report([(scopes.TEST, "Passed")]),
                    self.report([(BENCHMARK_TEST, "Skipped"), ("OtherSuite/test()", "Passed")]), benchmark_flag=flag)
                self.assertEqual(result, 1 if flag == "1" else 0)
                self.assertEqual(evidence["optionalBenchmark"]["environmentValue"], flag)
                self.assertEqual(evidence["optionalBenchmark"]["enabled"], flag == "1")
                if flag == "1":
                    self.assertIn("remainingValidationError", evidence)
                    self.assertFalse(evidence["passed"])
                else:
                    self.assertEqual(evidence["remainingCounts"]["skippedTests"], 1)
                self.assertFalse(any(BENCHMARK_FLAG in arg for command in self.commands for arg in command))

    def test_enabled_benchmark_runs_while_only_isolated_exclusion_is_attributed(self):
        result, evidence = self.execute(self.report([(scopes.TEST, "Passed")]),
            self.report([(BENCHMARK_TEST, "Passed"), (scopes.TEST, "Skipped"), ("OtherSuite/test()", "Passed")]),
            benchmark_flag="1")
        self.assertEqual(result, 0)
        self.assertEqual(evidence["combinedExecutedTestCount"], 3)
        self.assertEqual(evidence["remainingCounts"]["skippedTestsByIdentity"], [{
            "identity": scopes.SELECTOR, "policyReason": "verified-isolated-selector-exclusion", "reportedDetails": None}])

    def test_enabled_benchmark_cannot_be_absent_from_otherwise_passing_results(self):
        fixture = json.loads((ROOT / "scripts/test-fixtures/xcresult-isolated-hosted.json").read_text())
        result, evidence = self.execute((fixture["summary"], fixture["tests"]),
                                        self.report([("OtherSuite/test()", "Passed")]), benchmark_flag="1")
        self.assertEqual(result, 1)
        self.assertTrue(evidence["selectorVerifiedByHostedResult"])
        self.assertTrue(evidence["optionalBenchmark"]["enabled"])
        self.assertFalse(evidence["passed"])
        self.assertIn("benchmark", evidence["remainingValidationError"].lower())
        self.assertNotIn("combinedExecutedTestCount", evidence)

    def test_enabled_benchmark_requires_one_nonparameterized_pass(self):
        for status in ("Failed", "Expected Failure"):
            with self.subTest(status=status), self.assertRaises(ValueError):
                scopes.validate_remaining(*self.report([(BENCHMARK_TEST, status), ("OtherSuite/test()", "Passed")]),
                                          benchmark_enabled=True)
        summary, tree = self.report([(BENCHMARK_TEST, "Passed"), ("OtherSuite/test()", "Passed")])
        tree["testNodes"][0]["children"][0]["children"] = [
            {"nodeType": "Arguments", "name": "unexpected", "result": "Passed"}]
        with self.assertRaises(ValueError):
            scopes.validate_remaining(summary, tree, benchmark_enabled=True)
        for isolated_excluded in (False, True):
            with self.subTest(isolated_excluded=isolated_excluded), self.assertRaises(ValueError):
                scopes.validate_remaining(*self.report([("OtherSuite/test()", "Passed")]),
                                          benchmark_enabled=True, isolated_excluded=isolated_excluded)

    def test_benchmark_skip_exception_requires_exact_identity_and_one_nonparameterized_record(self):
        for identity in (BENCHMARK_TEST + "-other", "OtherSuite/" + BENCHMARK_TEST.split("/")[1],
                         "OtherTarget/" + BENCHMARK_TEST):
            with self.subTest(identity=identity), self.assertRaises(ValueError):
                scopes.validate_remaining(*self.report([(identity, "Skipped"), ("OtherSuite/test()", "Passed")]),
                                          benchmark_enabled=False)
        for kind in ("Arguments", "Repetition"):
            with self.subTest(kind=kind):
                summary, tree = self.report([(BENCHMARK_TEST, "Skipped"), ("OtherSuite/test()", "Passed")])
                tree["testNodes"][0]["children"][0]["children"] = [
                    {"nodeType": kind, "name": "unexpected", "result": "Skipped"}]
                with self.assertRaises(ValueError):
                    scopes.validate_remaining(summary, tree, benchmark_enabled=False)
        with self.assertRaises(ValueError):
            scopes.validate_remaining(*self.report([(BENCHMARK_TEST, "Skipped"), (BENCHMARK_TEST, "Skipped"),
                                                    ("OtherSuite/test()", "Passed")]), benchmark_enabled=False)

    def test_optional_skip_does_not_replace_nonzero_executed_complement(self):
        result, evidence = self.execute(self.report([(scopes.TEST, "Passed")]),
                                        self.report([(BENCHMARK_TEST, "Skipped"), (scopes.TEST, "Skipped")]))
        self.assertEqual(result, 1)
        self.assertIn("remainingValidationError", evidence)
        self.assertFalse(evidence["passed"])

    def test_full_fallback_cannot_attribute_an_unverified_selector_or_new_skip(self):
        for identity in (scopes.TEST, "OtherSuite/unexplainedSkip()"):
            with self.subTest(identity=identity):
                if (self.directory / "results").exists():
                    shutil.rmtree(self.directory / "results")
                result, evidence = self.execute(self.report([("OtherSuite/wrongSelection()", "Passed")]),
                    self.report([(identity, "Skipped"), (BENCHMARK_TEST, "Skipped"), ("OtherSuite/test()", "Passed")]))
                self.assertEqual(result, 1)
                self.assertFalse(evidence["selectorVerifiedByHostedResult"])
                self.assertIn("remainingValidationError", evidence)
                self.assertFalse(evidence["passed"])

    def test_hosted_optional_identity_is_still_opt_in_and_summaries_are_not_execution_trees(self):
        fixture = json.loads((ROOT / "scripts/test-fixtures/xcresult-optional-benchmark-hosted.json").read_text())
        benchmark = fixture["benchmark"]
        self.assertEqual(benchmark["identity"], scopes.BENCHMARK_SELECTOR)
        self.assertEqual(scopes.BENCHMARK_FLAG, BENCHMARK_FLAG)
        declaration = benchmark["annotation"] + "\n    func " + BENCHMARK_TEST.split("/")[1] + " async throws"
        self.assertIn(declaration, (ROOT / benchmark["source"]).read_text())
        for run in fixture["runs"]:
            with self.subTest(run=run["runId"]):
                summary = run["summary"]
                counts = scopes.counts(summary)
                self.assertEqual(counts["totalTestCount"], 681)
                self.assertEqual(counts["skippedTests"], 1)
                device = summary["devicesAndConfigurations"][0]
                executions = sum(device[key] for key in ("passedTests", "failedTests", "skippedTests", "expectedFailures"))
                self.assertEqual(executions, 1174)
                self.assertEqual(executions - counts["totalTestCount"], 650 - 157)
                with self.assertRaises(ValueError):
                    scopes.validate_remaining(summary, {"testNodes": []}, benchmark_enabled=False)

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
            scopes.validate_remaining(remaining_summary, remaining_tree, benchmark_enabled=False)

    def test_review_flat_summary_cannot_claim_unrepresented_executions(self):
        remaining = self.report([("OtherSuite/onlyCase()", "Passed")])
        remaining[0].update(totalTestCount=200, passedTests=200)
        result, evidence = self.execute(self.report([(scopes.TEST, "Passed")]), remaining)
        self.assertEqual(result, 1)
        self.assertFalse(evidence["passed"])
        self.assertNotIn("combinedExecutedTestCount", evidence)

    def test_review_isolated_failed_then_passed_repetition_cannot_authorize_exclusion(self):
        isolated = self.report([(scopes.TEST, "Passed")])
        isolated[1]["testNodes"][0]["children"][0]["children"] = [
            {"nodeType": "Repetition", "name": "Attempt 1", "children": [
                {"nodeType": "Test Case Run", "name": "Run 1", "result": "Failed"}]},
            {"nodeType": "Repetition", "name": "Attempt 2", "children": [
                {"nodeType": "Test Case Run", "name": "Run 2", "result": "Passed"}]},
        ]
        result, evidence = self.execute(isolated, self.report([(scopes.TEST, "Passed"), ("OtherSuite/test()", "Passed")]))
        self.assertEqual(result, 1)
        self.assertFalse(evidence["passed"])
        self.assertFalse(evidence["selectorVerifiedByHostedResult"])
        final = [command for command in self.commands if command[0] == "xcodebuild"][-1]
        self.assertFalse(any(arg.startswith("-skip-testing:") for arg in final))
        self.assertTrue((self.directory / "results/full-fallback-summary.json").exists())

    def test_review_status_distribution_must_match_the_tree(self):
        remaining = self.report([("OtherSuite/one()", "Passed"), ("OtherSuite/two()", "Passed")])
        remaining[0].update(passedTests=1, expectedFailures=1)
        result, evidence = self.execute(self.report([(scopes.TEST, "Passed")]), remaining)
        self.assertEqual(result, 1)
        self.assertIn("remainingValidationError", evidence)
        self.assertFalse(evidence["passed"])

    def test_summary_overall_result_cannot_hide_a_failed_isolated_case(self):
        isolated = self.report([(scopes.TEST, "Failed")])
        isolated[0]["result"] = "Passed"
        result, evidence = self.execute(isolated, self.report([(scopes.TEST, "Passed"), ("OtherSuite/test()", "Passed")]))
        self.assertEqual(result, 1)
        self.assertFalse(evidence["passed"])
        self.assertFalse(evidence["selectorVerifiedByHostedResult"])
        final = [command for command in self.commands if command[0] == "xcodebuild"][-1]
        self.assertFalse(any(arg.startswith("-skip-testing:") for arg in final))

    def test_failure_counts_must_reconcile_not_just_failure_presence(self):
        remaining = self.report([("OtherSuite/one()", "Failed"), ("OtherSuite/two()", "Failed")])
        remaining[0].update(failedTests=1, expectedFailures=1)
        with self.assertRaisesRegex(ValueError, "logical counts/statuses"):
            scopes.validate_remaining(*remaining, benchmark_enabled=False)

    def test_actual_hosted_isolated_plan_target_path_is_normalized(self):
        fixture = json.loads((ROOT / "scripts/test-fixtures/xcresult-isolated-hosted.json").read_text())
        measured = scopes.validate_isolated(fixture["summary"], fixture["tests"])
        self.assertEqual(measured["logicalCounts"]["totalTestCount"], 1)
        self.assertEqual(measured["executionCounts"]["totalTestCount"], 1)
        node = fixture["tests"]["testNodes"][0]["children"][0]["children"][0]["children"][0]
        node["nodeIdentifierURL"] = node["nodeIdentifierURL"].replace("CMUXMaestroPreview/", "DifferentPlan/", 1)
        with self.assertRaises(ValueError):
            scopes.validate_isolated(fixture["summary"], fixture["tests"])

    def test_parameterized_logical_and_execution_counts_are_distinct(self):
        # Synthetic shape control, not a claim that this is the hosted parameter tree.
        remaining = self.report([("OtherSuite/parameterized(value:)", "Passed")])
        remaining[0]["devicesAndConfigurations"] = [
            {"passedTests": 2, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]
        remaining[1]["testNodes"][0]["children"][0]["children"] = [
            {"nodeType": "Arguments", "name": name, "result": "Passed", "children": [
                {"nodeType": "Device", "name": "fixture device", "children": [
                    {"nodeType": "Test Case Run", "name": "Run", "result": "Passed"}]}]}
            for name in ("value=one", "value=two")]
        result, evidence = self.execute(self.report([(scopes.TEST, "Passed")]), remaining)
        self.assertEqual(result, 0)
        self.assertEqual(evidence["remainingCounts"]["logicalCounts"]["totalTestCount"], 1)
        self.assertEqual(evidence["remainingCounts"]["executionCounts"]["totalTestCount"], 2)
        self.assertEqual(evidence["combinedExecutedTestCount"], 3)
        remaining[0]["devicesAndConfigurations"][0]["passedTests"] = 200
        with self.assertRaises(ValueError):
            scopes.validate_remaining(*remaining, benchmark_enabled=False)
        remaining[0]["devicesAndConfigurations"][0]["passedTests"] = 2
        remaining[0].update(totalTestCount=2, passedTests=2)
        with self.assertRaises(ValueError):
            scopes.validate_remaining(*remaining, benchmark_enabled=False)

    def test_hidden_or_duplicate_runs_and_parameterized_isolated_method_refuse(self):
        for kind in ("duplicate-runs", "all-passed-repetitions", "hidden-run", "parameterized-isolated",
                     "parent-run-status", "empty-device", "unknown-wrapper"):
            with self.subTest(kind=kind):
                isolated = self.report([(scopes.TEST, "Passed")])
                run = {"nodeType": "Test Case Run", "name": "Run", "result": "Passed"}
                if kind == "duplicate-runs":
                    nested = [run, dict(run)]
                elif kind == "all-passed-repetitions":
                    nested = [{"nodeType": "Repetition", "name": f"Attempt {index}", "children": [dict(run)]}
                              for index in (1, 2)]
                elif kind == "hidden-run":
                    nested = [{"nodeType": "Attachment", "name": "diagnostic", "children": [run]}]
                elif kind == "parameterized-isolated":
                    nested = [{"nodeType": "Arguments", "name": "unexpected=value", "children": [run]}]
                elif kind == "empty-device":
                    nested = [{"nodeType": "Device", "name": "empty", "result": "Passed"}]
                elif kind == "unknown-wrapper":
                    nested = [{"nodeType": "Unverified Wrapper", "name": "unknown", "children": [run]}]
                else:
                    nested = [{**run, "result": "Failed"}]
                isolated[1]["testNodes"][0]["children"][0]["children"] = nested
                with self.assertRaises(ValueError):
                    scopes.validate_isolated(*isolated)

    def test_parameter_execution_evidence_cannot_be_missing_repeated_or_contradictory(self):
        for defect in ("missing-device-counts", "duplicate-argument", "duplicate-run", "status-mismatch",
                       "skipped-argument", "mixed-runs", "invalid-device-count", "nested-arguments"):
            with self.subTest(defect=defect):
                summary, tree = self.report([("OtherSuite/parameterized(value:)", "Passed")])
                summary["devicesAndConfigurations"] = [
                    {"passedTests": 2, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]
                arguments = [
                    {"nodeType": "Arguments", "name": name, "result": "Passed", "children": [
                        {"nodeType": "Test Case Run", "name": "Run", "result": "Passed"}]}
                    for name in ("one", "two")]
                tree["testNodes"][0]["children"][0]["children"] = arguments
                if defect == "missing-device-counts":
                    del summary["devicesAndConfigurations"]
                elif defect == "duplicate-argument":
                    arguments[1]["name"] = "one"
                elif defect == "duplicate-run":
                    arguments[0]["children"].append(dict(arguments[0]["children"][0]))
                elif defect == "status-mismatch":
                    arguments[0]["children"][0]["result"] = "Failed"
                elif defect == "skipped-argument":
                    arguments[0]["result"] = arguments[0]["children"][0]["result"] = "Skipped"
                    summary["devicesAndConfigurations"][0].update(passedTests=1, skippedTests=1)
                elif defect == "mixed-runs":
                    arguments.append({"nodeType": "Test Case Run", "name": "Run", "result": "Passed"})
                elif defect == "invalid-device-count":
                    summary["devicesAndConfigurations"][0]["failedTests"] = False
                else:
                    arguments[0]["children"] = [{"nodeType": "Arguments", "name": "nested", "result": "Passed"}]
                with self.assertRaises(ValueError):
                    scopes.validate_remaining(summary, tree, benchmark_enabled=False)


class BuildMetadataTests(unittest.TestCase):
    def test_generated_guide_reference_is_exact_digest_only_and_fails_on_drift(self):
        self.fixture("tests")
        canonical = self.directory / "SKILL.md"
        canonical.write_bytes(b"---\nname: maestro\n---\nSynthetic build guide.\n")
        destination = self.app / "Contents/Resources/maestro-guide.sha256"
        subprocess.run([sys.executable, str(ROOT / "scripts/write-guide-reference.py"),
                        str(canonical), str(destination)], check=True)
        self.assertEqual(destination.read_bytes(),
                         (hashlib.sha256(canonical.read_bytes()).hexdigest() + "\n").encode("ascii"))
        metadata.verify_guide_reference(self.app, canonical)
        canonical.write_bytes(b"Changed canonical guide.\n")
        with self.assertRaisesRegex(ValueError, "differs"):
            metadata.verify_guide_reference(self.app, canonical)
        for content in (b"", b"invalid\n", b"a" * 64, b"a" * 66):
            destination.write_bytes(content)
            with self.assertRaisesRegex(ValueError, "malformed"):
                metadata.verify_guide_reference(self.app, canonical)
        destination.unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            metadata.verify_guide_reference(self.app, canonical)
        destination.symlink_to(canonical)
        with self.assertRaisesRegex(ValueError, "malformed"):
            metadata.verify_guide_reference(self.app, canonical)

    def test_guide_reference_generation_rejects_missing_empty_and_oversized_source(self):
        source = self.directory / "guide.md"
        destination = self.directory / "reference"
        for content in (None, b"", b"x" * 65_537):
            if content is not None:
                source.write_bytes(content)
            result = subprocess.run([sys.executable, str(ROOT / "scripts/write-guide-reference.py"),
                                     str(source), str(destination)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(destination.exists())

    def _workflow_with_plain_integrated_command(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        workflow = workflow.split("\n  guide-ui-consumer-probe:", 1)[0].rstrip() + "\n"
        hosted_step = (
            "      - name: Run integrated Swift tests\n"
            "        run: |\n"
            "          unset TEST_RUNNER_GITHUB_ACTIONS TEST_RUNNER_RUNNER_ENVIRONMENT\n"
            '          if [ "${GITHUB_ACTIONS-}" = true ] && [ "${RUNNER_ENVIRONMENT-}" = github-hosted ]; then\n'
            '            export TEST_RUNNER_GITHUB_ACTIONS="$GITHUB_ACTIONS"\n'
            '            export TEST_RUNNER_RUNNER_ENVIRONMENT="$RUNNER_ENVIRONMENT"\n'
            "          fi\n"
            "          printf 'row-lift-native-input workflow: GITHUB_ACTIONS=%s; RUNNER_ENVIRONMENT=%s\\n' "
            '"${GITHUB_ACTIONS-<unset>}" "${RUNNER_ENVIRONMENT-<unset>}"\n'
            "          ./scripts/test.sh\n"
        )
        self.assertEqual(workflow.count(hosted_step), 1)
        return workflow.replace(hosted_step, (
            "      - name: Run integrated Swift tests\n"
            "        run: ./scripts/test.sh\n"
        ))

    def test_ci_preserves_all_fourteen_validation_commands_without_new_conditions(self):
        workflow = self._workflow_with_plain_integrated_command()
        self.assertNotIn("continue-on-error", workflow)
        self.assertEqual(workflow.count("\n  validate:\n"), 1)
        self.assertEqual(workflow.count("\n  row-input:\n"), 1)
        row_job, workflow = workflow.split("\n  validate:\n")
        self.assertIn("\n    runs-on: macos-latest\n", row_job)
        self.assertNotIn("\n    if:", row_job)
        self.assertNotIn("\n    needs:", row_job)
        row_steps = re.findall(r"^      - .*?(?=^      - |\Z)", row_job, re.MULTILINE | re.DOTALL)
        row_runs = [step for step in row_steps if "\n        run:" in step]
        self.assertEqual([step.splitlines()[1] for step in row_runs], [
            "        run: ./scripts/fetch-sdk.sh", "        run: ./scripts/test-row-input.sh",
        ])
        self.assertTrue(all(len(step.splitlines()) == 2 for step in row_runs))
        self.assertEqual(re.findall(r"^        run: (.+)$", workflow, re.MULTILINE), [
            "node --test scripts/test-skill-overrides.mjs",
            "node scripts/check-skill-overrides.mjs",
            "python3 scripts/test-joe-role-appearance.py",
            "python3 scripts/test-cmux-maestro-orchestrator.py",
            "python3 scripts/test-delivery-proof.py",
            "node --test scripts/test-delivery-proof.mjs",
            "python3 scripts/test-build-metadata.py",
            "python3 scripts/test-local-preview.py",
            "./scripts/test-fetch-sdk-concurrency.sh",
            "./scripts/build-unsigned.sh",
            "./scripts/test.sh",
            "./scripts/test-copilot-setup.sh",
            "./scripts/test-copilot-hook.sh",
            "./scripts/test-copilot-sandbox.sh",
        ])
        steps = re.findall(r"^      - .*?(?=^      - |\Z)", workflow, re.MULTILINE | re.DOTALL)
        run_steps = [step for step in steps if "\n        run:" in step]
        self.assertEqual(len(run_steps), 14)
        for step in run_steps:
            self.assertEqual(len(step.splitlines()), 2, "Validation steps must not gain skip/failure overrides.")
        self.assertNotIn("continue-on-error", workflow)

    def test_ci_documentation_tracks_the_guarded_validation_commands(self):
        workflow = self._workflow_with_plain_integrated_command()
        commands = re.findall(r"^        run: (.+)$", workflow, re.MULTILINE)
        policy = (ROOT / "docs/agents/merge-policy.md").read_text()
        section = policy.split("## Actual CI and formatting gates", 1)[1]
        documented = section.split("```sh\n", 1)[1].split("\n```", 1)[0].splitlines()
        self.assertEqual(documented, commands)

    def test_ci_marker_wrapper_rejects_command_skip_and_failure_mutations(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        title = "      - name: Run integrated Swift tests\n"
        mutations = [
            ("          ./scripts/test.sh\n", "          ./scripts/build-unsigned.sh\n"),
            (title, title + "        if: false\n"),
            (title, title + "        continue-on-error: true\n"),
            ("          ./scripts/test.sh\n", "          ./scripts/test.sh || true\n"),
        ]
        for original, replacement in mutations:
            with self.subTest(replacement=replacement):
                self.assertEqual(workflow.count(original), 1)
                with patch.object(Path, "read_text", return_value=workflow.replace(original, replacement)):
                    with self.assertRaises(AssertionError):
                        self.test_ci_preserves_all_fourteen_validation_commands_without_new_conditions()

    def test_ci_forwards_only_inherited_hosted_markers_and_preserves_test_exit(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        step = workflow.split("      - name: Run integrated Swift tests\n", 1)[1].split("      - name:", 1)[0]
        self.assertTrue(step.startswith("        run: |\n"))
        script = "\n".join(line[10:] for line in step.splitlines()[1:])
        stub = self.directory / "scripts/test.sh"
        stub.parent.mkdir()
        stub.write_text(
            '#!/bin/bash\nprintf "%s\\n" "${TEST_RUNNER_GITHUB_ACTIONS-<unset>}" '
            '"${TEST_RUNNER_RUNNER_ENVIRONMENT-<unset>}"\nexit "${FIXTURE_EXIT_CODE:?}"\n'
        )
        stub.chmod(0o700)
        cases = [
            {},
            {"GITHUB_ACTIONS": "true"},
            {"RUNNER_ENVIRONMENT": "github-hosted"},
            {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"},
            {"GITHUB_ACTIONS": "false", "RUNNER_ENVIRONMENT": "self-hosted"},
            {"GITHUB_ACTIONS": "false", "RUNNER_ENVIRONMENT": "github-hosted"},
            {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"},
            {"GITHUB_ACTIONS": "", "RUNNER_ENVIRONMENT": ""},
        ]
        for values in cases:
            for exit_code in (0, 7):
                with self.subTest(inherited=values, exit_code=exit_code):
                    environment = dict(os.environ)
                    for key, stale in (("GITHUB_ACTIONS", "true"), ("RUNNER_ENVIRONMENT", "github-hosted")):
                        environment.pop(key, None)
                        environment["TEST_RUNNER_" + key] = stale
                    environment.update(values, FIXTURE_EXIT_CODE=str(exit_code))
                    result = subprocess.run(
                        ["/bin/bash", "-e", "-o", "pipefail", "-c", script],
                        cwd=self.directory, env=environment, capture_output=True, text=True, timeout=5,
                    )
                    self.assertEqual(result.returncode, exit_code, result.stderr)
                    expected = (["true", "github-hosted"] if values == {
                        "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
                    } else ["<unset>", "<unset>"])
                    self.assertEqual(result.stdout.splitlines()[-2:], expected)

    def test_ci_always_uploads_json_evidence_and_retains_required_png_artifact(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        workflow = workflow.split("\n  guide-ui-consumer-probe:", 1)[0].rstrip() + "\n"
        steps = re.findall(r"^      - .*?(?=^      - |\Z)", workflow, re.MULTILINE | re.DOTALL)
        for title, name, path in (
            ("Upload integrated test scope evidence", "integrated-test-scope-evidence",
             "|\n            .build/tests/scoped-results/**/*.json\n"
             "            .build/tests/scoped-results/**/*.txt\n"
             "            .build/tests/scoped-results/**/guide-acceptance/*.log\n"
             "            .build/tests/scoped-results/**/guide-acceptance/probe.xcresult\n"
             "            .build/tests/scoped-results/**/guide-acceptance/images/*.png\n"
             "            .build/setup-tests/metadata-watchdog/"),
            ("Upload synthetic sidebar layout renders", "sidebar-layout-offscreen",
             ".build/layout-validation/offscreen/*.png"),
        ):
            with self.subTest(artifact=name):
                actual = [step for step in steps if f"          name: {name}\n" in step]
                self.assertEqual(actual, [
                    f"      - name: {title}\n"
                    "        if: always()\n"
                    "        uses: actions/upload-artifact@v4\n"
                    "        with:\n"
                    f"          name: {name}\n"
                    f"          path: {path}\n"
                    "          include-hidden-files: true\n"
                    "          if-no-files-found: error\n"
                    "          retention-days: 14\n"
                ])

    def test_ci_collects_final_metadata_diagnostics_after_both_producers(self):
        workflow = self._workflow_with_plain_integrated_command()
        steps = re.findall(r"^      - .*?(?=^      - |\Z)", workflow, re.MULTILINE | re.DOTALL)
        uploads = [(index, step) for index, step in enumerate(steps)
                   if "          name: integrated-test-scope-evidence\n" in step]
        self.assertEqual(len(uploads), 1, "One final upload must collect both diagnostic producers.")
        upload_index, upload = uploads[0]
        for command in ("./scripts/test.sh", "./scripts/test-copilot-setup.sh"):
            producers = [index for index, step in enumerate(steps) if f"        run: {command}\n" in step]
            self.assertEqual(len(producers), 1, f"Expected one diagnostic producer: {command}")
            self.assertLess(producers[0], upload_index, "An earlier upload cannot retain later partial diagnostics.")
        setup = (ROOT / "scripts/test-copilot-setup.sh").read_text()
        self.assertIn('OUTPUT="$ROOT/.build/setup-tests"', setup)
        self.assertIn('--results-root "$OUTPUT/metadata-watchdog"', setup)
        self.assertIn("            .build/setup-tests/metadata-watchdog/\n", upload)

    def test_ci_final_diagnostics_reject_missing_duplicate_and_late_producers(self):
        self.test_ci_collects_final_metadata_diagnostics_after_both_producers()
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        setup = (
            "      - name: Verify Settings guide and setup process isolation\n"
            "        run: ./scripts/test-copilot-setup.sh\n"
        )
        mutations = [
            workflow.replace("          ./scripts/test.sh\n", ""),
            workflow.replace(setup, ""),
            workflow.replace(setup, setup + setup),
            workflow.replace(setup, "") + setup,
            workflow.replace("            .build/setup-tests/metadata-watchdog/\n", ""),
        ]
        original_read = Path.read_text
        for index, altered in enumerate(mutations):
            def read_text(path, *args, **kwargs):
                if path == ROOT / ".github/workflows/ci.yml":
                    return altered
                return original_read(path, *args, **kwargs)

            with self.subTest(mutation=index), patch.object(Path, "read_text", read_text):
                with self.assertRaises(AssertionError):
                    self.test_ci_collects_final_metadata_diagnostics_after_both_producers()

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

    def test_native_preflight_can_retain_election_without_changing_existing_parser_shape(self):
        identifier = metadata.BASE_ID + ".Extension"
        for prefix in ("", "+", "-", "!", "=", "?"):
            output = f"{prefix} {identifier}(2)\n    Path = {self.extension}\n    SDK = {metadata.PRODUCTION_POINT}\n(1 plug-in)\n"
            original = metadata.registration_records(output)[0]
            retained = metadata.registration_records(output, include_election=True)[0]
            self.assertNotIn("election", original)
            self.assertEqual(retained, {**original, "election": prefix})
            self.assertEqual(retained["SDK"], metadata.PRODUCTION_POINT)

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
        metadata.verify_guide_ui_project(project)
        for target in objects.values():
            if target.get("isa") != "PBXNativeTarget":
                continue
            if target["name"] in (metadata.GUIDE_HOST, metadata.GUIDE_TESTS):
                for config_id in objects[target["buildConfigurationList"]]["buildConfigurations"]:
                    settings = objects[config_id]["buildSettings"]
                    ending = ".GuideHost" if target["name"] == metadata.GUIDE_HOST else ".GuideUITests"
                    self.assertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"],
                                     metadata.BASE_ID + ".Validation.Tests" + ending)
                continue
            for config_id in objects[target["buildConfigurationList"]]["buildConfigurations"]:
                settings = objects[config_id]["buildSettings"]
                if target["name"] in metadata.ROW_INPUT_TARGETS:
                    self.assertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"],
                                     metadata.ROW_INPUT_TARGETS[target["name"]])
                    self.assertEqual(settings["CODE_SIGNING_ALLOWED"], "NO")
                    self.assertEqual(settings["CODE_SIGNING_REQUIRED"], "NO")
                    self.assertEqual(settings["SKIP_INSTALL"], "YES")
                    continue
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
