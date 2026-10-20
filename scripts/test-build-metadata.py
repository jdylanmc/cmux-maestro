#!/usr/bin/env python3
import importlib.util
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch
import uuid
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("metadata", ROOT / "scripts/verify-build-metadata.py")
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)
scope_spec = importlib.util.spec_from_file_location("integrated_scopes", ROOT / "scripts/run-integrated-test-scopes.py")
scopes = importlib.util.module_from_spec(scope_spec)
scope_spec.loader.exec_module(scopes)
BENCHMARK_TEST = "CopilotReaderTests/coldStartBenchmarkWith230MiBOfIgnoredSyntheticPayloads()"
BENCHMARK_FLAG = "CMUX_MAESTRO_READER_BENCHMARK"


def yaml_workflow(workflow):
    """A real YAML parse: PyYAML if installed, else Ruby's bundled YAML."""
    try:
        import yaml
    except ImportError:
        result = subprocess.run(
            ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.safe_load(STDIN.read))"],
            input=workflow, capture_output=True, text=True, check=True)
        return json.loads(result.stdout)
    return yaml.safe_load(workflow)


def yaml_jobs(workflow):
    return yaml_workflow(workflow)["jobs"]


def yaml_job_ids(workflow):
    return list(yaml_jobs(workflow))


def workflow_jobs(workflow):
    """Map each top-level job id to its block text; refuse any job shape the line parser cannot see."""
    if workflow.count("\njobs:\n") != 1:
        raise ValueError("workflow must have exactly one block-style 'jobs:' key")
    section = workflow.split("\njobs:\n", 1)[1]
    for line in section.splitlines():
        if not line.strip() or line.startswith("   ") or re.fullmatch(r"  #.*", line):
            continue
        # Quoted ids, trailing comments, flow mappings and later top-level keys all fail closed.
        if not re.fullmatch(r"  [A-Za-z0-9_-]+:", line):
            raise ValueError(f"unsupported line under jobs: {line!r}")
    parts = re.split(r"^  ([A-Za-z0-9_-]+):\n", section, flags=re.MULTILINE)
    jobs = dict(zip(parts[1::2], parts[2::2]))
    if list(jobs) != yaml_job_ids(workflow):
        raise ValueError("line-parsed job ids disagree with the YAML parse")
    return jobs


def job_steps(block):
    """Split a job block into its step texts (each starting at `      - `)."""
    return re.findall(r"^      - .*?(?=^      - |\Z)", block.rstrip() + "\n", re.MULTILINE | re.DOTALL)


def job_commands(block):
    return re.findall(r"^        run: (.+)$", block, re.MULTILINE)


# Early failures (#196): every validation command runs at most once, in one of three independent jobs.
# The native job starts the integrated Swift tests right after checkout; the contract job runs its
# fastest suites first. Update docs/agents/merge-policy.md with any change here.
VALIDATION_JOBS = {
    "validate-native": [
        "./scripts/test.sh",
    ],
    "validate-contracts": [
        "python3 scripts/test-joe-role-appearance.py",
        "python3 scripts/test-pet-kit.py",
        "python3 scripts/test-beats.py",
        "python3 scripts/test-delivery-proof.py",
        "node --test scripts/test-delivery-proof.mjs",
        "python3 scripts/test-build-metadata.py",
        "./scripts/test-copilot-shell-reducer.sh",
        "./scripts/test-fetch-sdk-concurrency.sh",
        "./scripts/test-copilot-hook.sh",
        "./scripts/test-copilot-sandbox.sh",
        "./scripts/build-unsigned.sh",
        "./scripts/test-copilot-setup.sh",
        "python3 scripts/test-local-preview.py",
        "python3 scripts/test-cmux-maestro-orchestrator.py",
    ],
    "validate-portable": [
        "node --test scripts/test-skill-overrides.mjs",
        "node scripts/check-skill-overrides.mjs",
    ],
}
# Runner placement (#191): validation stays on macOS unless a command is proven to behave identically
# on Linux (docs/reference/ci-runner-placement.md). Native builds, AppKit, sandbox and hosted-UI checks
# never move; the guide probe is hosted UI. Adding a command here needs that proof.
MACOS, LINUX = "macos-latest", "ubuntu-latest"
JOB_RUNNERS = {"validate-native": MACOS, "validate-contracts": MACOS, "validate-portable": LINUX,
               "guide-ui-consumer-probe": MACOS}
PROVEN_PORTABLE_COMMANDS = {
    "node --test scripts/test-skill-overrides.mjs",
    "node scripts/check-skill-overrides.mjs",
}
# Suite selection (#194): ci-classify publishes a record and one run_<job> flag per suite. Each
# validation job needs only the classifier and has exactly this condition: it is skipped only when its
# flag is 'false' (GitHub compares case-insensitively), so a missing or garbled flag runs the suite.
# ci-gate rejects any flag other than the literal 'false' and verifies every skip.
CLASSIFIER_JOB = "ci-classify"


def selection_condition(job):
    return f"needs.{CLASSIFIER_JOB}.outputs.run_{job.replace('-', '_')} != 'false'"


# Hang ceilings (owner decision 2026-10-15): exactly one job-level timeout-minutes per job, at
# about 3x the observed normal duration. Changing one is a merge-policy change.
JOB_CEILINGS = {
    "ci-classify": 10,
    "validate-native": 60,
    "validate-contracts": 50,
    "validate-portable": 10,
    "guide-ui-consumer-probe": 15,
    "ci-gate": 10,
}

CLASSIFIER_BLOCK = (
    "    timeout-minutes: 10\n"
    "    runs-on: ubuntu-latest\n"
    "    permissions:\n"
    "      contents: read\n"
    "    outputs:\n"
    "      classification: ${{{{ steps.classify.outputs.classification }}}}\n"
    "{flags}"
    "    steps:\n"
    "      - uses: actions/checkout@v4\n"
    "        with:\n"
    "          fetch-depth: 0\n"
    "      - name: Classify changed files\n"
    "        id: classify\n"
    "        env:\n"
    "          CI_CLASSIFY_BASE: ${{{{ github.event.pull_request.base.sha }}}}\n"
    "          CI_CLASSIFY_HEAD: ${{{{ github.event.pull_request.head.sha }}}}\n"
    "        run: python3 scripts/ci-classify.py\n")
# Each required artifact: (job, upload step title, producer commands that must precede it, exact path).
REQUIRED_ARTIFACTS = {
    "sidebar-layout-offscreen": ("validate-native", "Upload synthetic sidebar layout renders",
                                 ["./scripts/test.sh"], ".build/layout-validation/offscreen/*.png"),
    "integrated-test-scope-evidence": (
        "validate-native", "Upload integrated test scope evidence", ["./scripts/test.sh"],
        "|\n            .build/tests/scoped-results/**/*.json\n"
        "            .build/tests/scoped-results/**/*.txt\n"
        "            .build/tests/scoped-results/**/guide-acceptance/*.log\n"
        "            .build/tests/scoped-results/**/guide-acceptance/probe.xcresult\n"
        "            .build/tests/scoped-results/**/guide-acceptance/images/*.png\n"
        "            .build/tests/scoped-results/**/failure-diagnostics/*/*.zip"),
    # Standalone setup tests write their watchdog controls and any metadata stall diagnostics here.
    "copilot-setup-evidence": (
        "validate-contracts", "Upload setup process isolation evidence", ["./scripts/test-copilot-setup.sh"],
        "|\n            .build/setup-tests/metadata-watchdog/\n"
        "            .build/tests/scoped-results/metadata-diagnostics/"),
}
SEVENTEEN_VALIDATION_COMMANDS = {
    "node --test scripts/test-skill-overrides.mjs",
    "node scripts/check-skill-overrides.mjs",
    "python3 scripts/test-joe-role-appearance.py",
    "python3 scripts/test-cmux-maestro-orchestrator.py",
    "python3 scripts/test-pet-kit.py",
    "python3 scripts/test-beats.py",
    "python3 scripts/test-delivery-proof.py",
    "node --test scripts/test-delivery-proof.mjs",
    "python3 scripts/test-build-metadata.py",
    "python3 scripts/test-local-preview.py",
    "./scripts/test-copilot-shell-reducer.sh",
    "./scripts/test-fetch-sdk-concurrency.sh",
    "./scripts/build-unsigned.sh",
    "./scripts/test.sh",
    "./scripts/test-copilot-setup.sh",
    "./scripts/test-copilot-hook.sh",
    "./scripts/test-copilot-sandbox.sh",
}


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

    @staticmethod
    def reported_identities(*reports):
        identities = {scopes.SELECTOR}
        for _, tests in reports:
            try:
                identities.update(case.identity for case in scopes.cases(tests))
            except (ValueError, KeyError, TypeError, AttributeError):
                pass
        return identities

    @staticmethod
    def enumeration(enabled, disabled=()):
        return {"errors": [], "values": [{
            "testPlan": "CMUXMaestroPreview",
            "enabledTests": [{"identifier": identity} for identity in sorted(enabled)],
            "disabledTests": [{"identifier": identity} for identity in sorted(disabled)],
        }]}

    def execute(self, isolated, remaining, *, isolated_exit=0, remaining_exit=0, benchmark_flag=None, guide_exit=0,
                inventory=None, enumeration_exit=0):
        # The default built inventory mirrors the fixture; inventory tests pass an explicit enumeration.
        inventory = (self.enumeration(self.reported_identities(isolated, remaining))
                     if inventory is None else inventory)
        self.enumerations = []

        def runner(command, **kwargs):
            if "-enumerate-tests" in command:
                self.enumerations.append((command, kwargs.get("env")))
                path = Path(command[command.index("-test-enumeration-output-path") + 1])
                if not enumeration_exit:
                    path.write_text(json.dumps(inventory))
                return subprocess.CompletedProcess(command, enumeration_exit)
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

    def test_reported_tests_must_equal_the_built_inventory(self):
        isolated = self.report([(scopes.TEST, "Passed")])
        remaining = self.report([("OtherSuite/first()", "Passed")])
        first = scopes.TARGET + "/OtherSuite/first()"
        for name, inventory, code in (
            ("missing suite", self.enumeration({scopes.SELECTOR, first, scopes.TARGET + "/ReaderSuite/regression()"}), 0),
            ("same name in another suite", self.enumeration({scopes.SELECTOR, scopes.TARGET + "/Other/first()"}), 0),
            ("missing isolated", self.enumeration({first}), 0),
            ("unexpected", self.enumeration({scopes.SELECTOR}), 0),
            ("unexplained disabled", self.enumeration({scopes.SELECTOR, first}, {scopes.TARGET + "/Off/test()"}), 0),
            ("enumeration errors", {"errors": ["synthetic"], "values": []}, 0),
            ("enumeration failed", None, 65),
        ):
            with self.subTest(name), patch.object(scopes, "capture_failure_diagnostics", return_value={}):
                if (self.directory / "results").exists():
                    shutil.rmtree(self.directory / "results")
                result, evidence = self.execute(isolated, remaining, inventory=inventory or {},
                                                enumeration_exit=code)
                self.assertEqual(result, 1)
                self.assertIn("inventoryError", evidence)
                self.assertFalse(evidence["passed"])
        shutil.rmtree(self.directory / "results")
        result, evidence = self.execute(isolated, remaining, inventory=self.enumeration({scopes.SELECTOR, first}))
        self.assertEqual(result, 0)
        self.assertEqual(evidence["inventoryCoverage"], {"expectedTests": 2, "reportedTests": 2})

    def test_conditionally_compiled_out_tests_are_absent_from_inventory_and_pass(self):
        # A test excluded by #if never reaches the built product, so enumeration omits it.
        result, evidence = self.execute(
            self.report([(scopes.TEST, "Passed")]), self.report([("OtherSuite/first()", "Passed")]),
            inventory=self.enumeration({scopes.SELECTOR, scopes.TARGET + "/OtherSuite/first()"}))
        self.assertEqual(result, 0)
        self.assertEqual(evidence["enumeratedTests"], 2)

    def test_inventory_comes_from_the_built_product_under_the_same_settings(self):
        result, _ = self.execute(self.report([(scopes.TEST, "Passed")]),
                                 self.report([("OtherSuite/first()", "Passed")]))
        self.assertEqual(result, 0)
        [(command, environment)] = self.enumerations
        self.assertEqual(command[:3], ["xcodebuild", "-scheme", "CMUXMaestroPreview"])
        self.assertEqual(command[3:7], ["test-without-building", "-enumerate-tests",
                                        "-test-enumeration-format", "json"])
        self.assertIsNotNone(environment)

    def test_allowlisted_disabled_tests_and_skips_have_reasons(self):
        self.assertEqual(set(scopes.INTENTIONAL_SKIPS), {scopes.SELECTOR, scopes.TARGET + "/" + BENCHMARK_TEST})
        self.assertTrue(all(reason.strip() for reason in scopes.INTENTIONAL_SKIPS.values()))
        first = scopes.TARGET + "/OtherSuite/first()"
        benchmark = scopes.TARGET + "/" + BENCHMARK_TEST
        result, evidence = self.execute(
            self.report([(scopes.TEST, "Passed")]),
            self.report([("OtherSuite/first()", "Passed"), (BENCHMARK_TEST, "Skipped")]),
            inventory=self.enumeration({scopes.SELECTOR, first}, {benchmark}))
        self.assertEqual(result, 0)
        [skip] = evidence["remainingCounts"]["skippedTestsByIdentity"]
        self.assertEqual(skip["allowlistReason"], scopes.INTENTIONAL_SKIPS[benchmark])

    def test_failed_isolated_regression_still_runs_complement_and_remains_red(self):
        result, evidence = self.execute(self.report([(scopes.TEST, "Failed")]),
                                        self.report([("OtherSuite/test()", "Passed")]), isolated_exit=65)
        self.assertEqual(result, 1)
        self.assertTrue(evidence["selectorVerifiedByHostedResult"])
        self.assertEqual(evidence["remainingCounts"]["passedTests"], 1)
        self.assertFalse(evidence["passed"])

    def test_failed_scope_has_explicit_diagnostic_retention_receipt(self):
        result, evidence = self.execute(self.report([(scopes.TEST, "Passed")]),
                                        self.report([("OtherSuite/crashed()", "Failed")]), remaining_exit=65)
        self.assertEqual(result, 1)
        retained = evidence.get("failureDiagnostics", [])
        self.assertEqual([item["scope"] for item in retained], ["remaining"])
        self.assertIn(retained[0]["status"], ["captured", "unavailable"])
        self.assertFalse(evidence["passed"], "Diagnostic capture cannot upgrade the original test failure.")

    def test_diagnostics_select_only_failed_executed_scopes(self):
        scenarios = [
            (self.report([(scopes.TEST, "Passed")]), self.report([("Other/test()", "Passed")]), 0, []),
            (self.report([(scopes.TEST, "Passed")]), self.report([("Other/test()", "Failed")]), 0, ["remaining"]),
            (self.report([(scopes.TEST, "Passed")]), self.report([("Other/test()", "Passed")]), 65, ["isolated"]),
            (self.report([("Wrong/test()", "Failed")]),
             self.report([(scopes.TEST, "Failed"), ("Other/test()", "Passed")]), 65, ["isolated", "full-fallback"]),
        ]
        for isolated, remaining, isolated_exit, expected in scenarios:
            with self.subTest(expected=expected), patch.object(
                    scopes, "capture_failure_diagnostics",
                    side_effect=lambda directory, scope, source, runner: {"scope": scope, "status": "captured"}) as capture:
                result, evidence = self.execute(isolated, remaining, isolated_exit=isolated_exit)
                self.assertEqual([call.args[1] for call in capture.call_args_list], expected)
                self.assertEqual(result, int(bool(expected)))
                self.assertEqual([item["scope"] for item in evidence["failureDiagnostics"]], expected)
                self.assertEqual(sum("test-without-building" in command for command in self.commands), 2)
            shutil.rmtree(self.directory / "results")
            self.commands.clear()

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
            "identity": scopes.SELECTOR, "policyReason": "verified-isolated-selector-exclusion",
            "allowlistReason": scopes.INTENTIONAL_SKIPS[scopes.SELECTOR], "reportedDetails": None}])

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


class DiagnosticRetentionTests(unittest.TestCase):
    SOURCE = {"status": "available", "head": "a" * 40, "tree": "b" * 40,
              "parents": ["c" * 40, "d" * 40], "dirty": False}

    def setUp(self):
        self.directory = (ROOT / ".build/metadata-tests" / ("scopes-" + str(uuid.uuid4()))).resolve()
        self.directory.mkdir(parents=True)
        for scope in scopes.DIAGNOSTIC_SCOPES:
            bundle = self.directory / (scope + ".xcresult")
            bundle.mkdir()
            (bundle / "Data").write_bytes(b"synthetic result")
        self.commands = []

    def tearDown(self):
        shutil.rmtree(self.directory)

    def capture(self, scope="remaining", *, payloads=None, exit_code=0, error=None, mutate=None, sources=None):
        def runner(command, **kwargs):
            self.commands.append((command, kwargs))
            if error:
                raise error
            exported = Path(command[command.index("--output-path") + 1])
            self.assertFalse(exported.is_relative_to(self.directory.parent),
                             "Partial raw exports must stay outside existing recursive upload globs.")
            exported.mkdir()
            for name, data in ({"runner.ips": b"synthetic faulting thread"} if payloads is None else payloads).items():
                path = exported / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            if mutate:
                mutate(exported)
            return subprocess.CompletedProcess(command, exit_code)
        with patch.object(scopes, "diagnostic_source", side_effect=sources or [self.SOURCE, self.SOURCE]), \
                patch("builtins.print"):
            return scopes.capture_failure_diagnostics(self.directory, scope, self.SOURCE, runner)

    def test_each_exact_scope_publishes_bounded_hashed_archive_and_provenance(self):
        for scope in scopes.DIAGNOSTIC_SCOPES:
            with self.subTest(scope=scope):
                receipt = self.capture(scope)
                self.assertEqual(receipt["status"], "captured")
                self.assertEqual(receipt["source"], self.SOURCE)
                self.assertEqual(receipt["invocation"], self.directory.name)
                self.assertEqual(receipt["resultBundle"], scope + ".xcresult")
                archive = self.directory / receipt["archive"]
                self.assertEqual(receipt["archiveSHA256"], hashlib.sha256(archive.read_bytes()).hexdigest())
                self.assertEqual(receipt["archiveBytes"], archive.stat().st_size)
                with zipfile.ZipFile(archive) as result:
                    self.assertEqual(result.namelist(), ["runner.ips"])
                    self.assertEqual(result.read("runner.ips"), b"synthetic faulting thread")
                self.assertEqual(receipt["files"], [{
                    "path": "runner.ips", "bytes": 25,
                    "sha256": hashlib.sha256(b"synthetic faulting thread").hexdigest()}])
                command, options = self.commands[-1]
                self.assertEqual(command[:6], ["xcrun", "xcresulttool", "export", "diagnostics", "--path",
                                               str(self.directory / (scope + ".xcresult"))])
                self.assertEqual(options["timeout"], 30)
                self.assertEqual(options["stdout"], subprocess.DEVNULL)
                self.assertEqual(options["stderr"], subprocess.DEVNULL)
        self.assertEqual(len(self.commands), 3, "One export per exact failed scope; no retries.")

    def test_missing_bundle_invalid_scope_and_dirty_or_changed_source_never_export(self):
        (self.directory / "remaining.xcresult/Data").unlink()
        (self.directory / "remaining.xcresult").rmdir()
        for scope in ("remaining", "../guide-acceptance/probe"):
            with self.subTest(scope=scope):
                self.assertEqual(self.capture(scope)["status"], "unavailable")
        for source in ({**self.SOURCE, "dirty": True}, {"status": "unavailable"},
                       {**self.SOURCE, "head": "e" * 40}):
            with self.subTest(source=source):
                self.assertEqual(self.capture("isolated", sources=[source])["reason"], "source-provenance-changed")
        with patch("builtins.print"):
            receipt = scopes.capture_failure_diagnostics(
                self.directory, "isolated", {**self.SOURCE, "dirty": True},
                lambda *args, **kwargs: self.fail("Dirty source must not export."))
        self.assertEqual(receipt["reason"], "clean-source-provenance-unavailable")
        self.assertEqual(self.commands, [])

    def test_export_failures_are_explicit_and_never_publish_partial_data(self):
        cases = [
            ({"exit_code": 65}, "diagnostic-export-failed"),
            ({"error": subprocess.TimeoutExpired("synthetic export", 30)}, "TimeoutExpired"),
            ({"error": OSError("private path must not appear")}, "OSError"),
            ({"payloads": {}}, "empty-diagnostic-data"),
            ({"sources": [self.SOURCE, {**self.SOURCE, "tree": "e" * 40}]}, "source-provenance-changed"),
        ]
        for arguments, reason in cases:
            with self.subTest(reason=reason):
                receipt = self.capture(**arguments)
                self.assertEqual(receipt["status"], "unavailable")
                self.assertEqual(receipt["reason"], reason)
                self.assertFalse(list(self.directory.glob("failure-diagnostics/*/*.zip")))

    def test_exact_byte_and_entry_limits_and_link_rejection(self):
        with patch.object(scopes, "DIAGNOSTIC_MAX_BYTES", 8), patch.object(scopes, "DIAGNOSTIC_MAX_FILES", 2):
            for payloads, reason in (({"a": b"123456789"}, "byte-limit-exceeded"),
                                     ({"a": b"", "b": b"", "c": b""}, "entry-limit-exceeded")):
                with self.subTest(reason=reason):
                    self.assertEqual(self.capture(payloads=payloads)["reason"], reason)
            receipt = self.capture(payloads={"a": b"1234", "b": b"5678"})
            self.assertEqual(receipt["status"], "captured")
            self.assertEqual(sum(item["bytes"] for item in receipt["files"]), 8)
        for mutate in (
            lambda root: (root / "link").symlink_to(self.directory / "isolated.xcresult/Data"),
            lambda root: (root / "link").symlink_to(self.directory, target_is_directory=True),
            lambda root: os.link(root / "runner.ips", root / "hardlink"),
            lambda root: os.mkfifo(root / "fifo"),
        ):
            with self.subTest(mutate=mutate):
                self.assertEqual(self.capture("isolated", mutate=mutate)["reason"], "linked-or-special-file")

    def test_real_publication_limits_accept_boundary_and_reject_one_over(self):
        exported = self.directory / "boundary"
        exported.mkdir()
        for index in range(256):
            (exported / str(index)).touch()
        with (exported / "0").open("wb") as stream:
            stream.truncate(64 * 1024 * 1024)
        files = scopes.diagnostic_files(exported, scopes.DIAGNOSTIC_MAX_BYTES, scopes.DIAGNOSTIC_MAX_FILES)
        self.assertEqual(len(files), 256)
        self.assertEqual(sum(info.st_size for _, info in files), 64 * 1024 * 1024)
        with (exported / "0").open("r+b") as stream:
            stream.truncate(64 * 1024 * 1024 + 1)
        with self.assertRaisesRegex(ValueError, "byte-limit-exceeded"):
            scopes.diagnostic_files(exported, scopes.DIAGNOSTIC_MAX_BYTES, scopes.DIAGNOSTIC_MAX_FILES)
        (exported / "0").write_bytes(b"")
        (exported / "256").touch()
        with self.assertRaisesRegex(ValueError, "entry-limit-exceeded"):
            scopes.diagnostic_files(exported, scopes.DIAGNOSTIC_MAX_BYTES, scopes.DIAGNOSTIC_MAX_FILES)

    def test_linked_input_bundle_and_existing_destination_refuse(self):
        bundle = self.directory / "remaining.xcresult"
        shutil.rmtree(bundle)
        bundle.symlink_to(self.directory / "isolated.xcresult", target_is_directory=True)
        self.assertEqual(self.capture()["reason"], "missing-or-linked-directory")
        self.assertEqual(self.commands, [])
        destination = self.directory / "failure-diagnostics/isolated"
        destination.mkdir(parents=True)
        self.assertEqual(self.capture("isolated")["reason"], "diagnostic-destination-exists")
        self.assertFalse(list(destination.iterdir()))

    def test_archive_copy_failure_does_not_publish_zip(self):
        def fail_copy(source, target):
            target.write_bytes(b"partial")
            raise OSError("synthetic disk error")
        with patch.object(scopes.shutil, "copyfile", side_effect=fail_copy):
            self.assertEqual(self.capture()["reason"], "OSError")
        self.assertFalse(list(self.directory.glob("failure-diagnostics/*/*.zip")))

    def test_source_reads_raw_merge_parents_and_never_records_commit_message_or_dirty_paths(self):
        commands = []
        def runner(command, **kwargs):
            commands.append(command)
            output = (self.SOURCE["head"] + "\n" + self.SOURCE["tree"] + "\n" if "rev-parse" in command else
                      "tree " + self.SOURCE["tree"] + "\nparent " + "c" * 40 + "\nparent " + "d" * 40
                      + "\nauthor Synthetic\n\nprivate message\n" if "cat-file" in command else " M private-path\n")
            self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
            self.assertEqual(kwargs["timeout"], 5)
            return subprocess.CompletedProcess(command, 0, stdout=output)
        source = scopes.diagnostic_source(runner)
        self.assertEqual(source, {**self.SOURCE, "dirty": True})
        self.assertNotIn("private", json.dumps(source))
        self.assertEqual(commands[1], ["git", "--no-replace-objects", "cat-file", "commit", self.SOURCE["head"]])

    def test_unavailable_source_is_not_a_success_shaped_coordinate(self):
        for error in (OSError("private"), subprocess.TimeoutExpired("private", 5)):
            with self.subTest(error=error):
                def runner(*args, **kwargs):
                    raise error
                self.assertEqual(scopes.diagnostic_source(runner),
                                 {"status": "unavailable", "reason": type(error).__name__})
        malformed = lambda command, **kwargs: subprocess.CompletedProcess(command, 0, stdout="invalid")
        self.assertEqual(scopes.diagnostic_source(malformed)["status"], "unavailable")

    def test_replacement_ref_cannot_hide_dirty_raw_source(self):
        root = self.directory / "synthetic-git"
        root.mkdir()
        def git(*arguments):
            return subprocess.run(
                ["git", "-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
                 "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", *arguments],
                cwd=root, check=True, capture_output=True, text=True).stdout.strip()
        git("init", "--quiet")
        (root / "source").write_text("original\n")
        git("add", "source")
        git("commit", "--quiet", "-m", "original")
        head, tree = git("rev-parse", "HEAD", "HEAD^{tree}").splitlines()
        (root / "source").write_text("different\n")
        git("add", "source")
        git("commit", "--quiet", "-m", "different")
        replacement = git("rev-parse", "HEAD")
        git("update-ref", "HEAD", head)
        git("replace", head, replacement)
        def runner(command, **kwargs):
            return subprocess.run(command, **{**kwargs, "cwd": root})
        source = scopes.diagnostic_source(runner)
        self.assertEqual((source["head"], source["tree"]), (head, tree))
        self.assertEqual(git("--no-replace-objects", "status", "--porcelain"), "M  source")
        self.assertTrue(source["dirty"], "Raw coordinates must use raw dirty-state interpretation.")
        with patch("builtins.print"):
            receipt = scopes.capture_failure_diagnostics(
                self.directory, "remaining", source,
                lambda *args, **kwargs: self.fail("Raw dirty source must never export."))
        self.assertEqual(receipt["reason"], "clean-source-provenance-unavailable")

    def test_ancestor_swap_after_inventory_cannot_read_outside_export(self):
        outside = self.directory / "outside-export"
        outside.mkdir()
        (outside / "runner.ips").write_bytes(b"outside")
        original_inventory = scopes.diagnostic_files
        def swapped_inventory(root, *args, **kwargs):
            files = original_inventory(root, *args, **kwargs)
            if root.name == "exported":
                (root / "nested").rename(root / "original-nested")
                (root / "nested").symlink_to(outside, target_is_directory=True)
            return files
        with patch.object(scopes, "diagnostic_files", side_effect=swapped_inventory):
            receipt = self.capture(payloads={"nested/runner.ips": b"allowed"})
        self.assertEqual(receipt["status"], "unavailable")
        self.assertFalse(list(self.directory.glob("failure-diagnostics/*/*.zip")))

    def test_same_size_file_replacement_after_inventory_is_rejected(self):
        original_inventory = scopes.diagnostic_files
        def swapped_inventory(root, *args, **kwargs):
            files = original_inventory(root, *args, **kwargs)
            if root.name == "exported":
                (root / "replacement").write_bytes(b"changed")
                (root / "replacement").replace(root / "runner.ips")
            return files
        with patch.object(scopes, "diagnostic_files", side_effect=swapped_inventory):
            receipt = self.capture(payloads={"runner.ips": b"allowed"})
        self.assertEqual(receipt["status"], "unavailable")
        self.assertFalse(list(self.directory.glob("failure-diagnostics/*/*.zip")))

    def test_queued_directory_swap_cannot_redirect_scanner(self):
        root = self.directory / "scan-root"
        (root / "nested").mkdir(parents=True)
        (root / "nested/runner.ips").write_bytes(b"allowed")
        outside = self.directory / "outside-scan"
        outside.mkdir()
        (outside / "runner.ips").write_bytes(b"outside")
        original_scan = os.scandir
        root_inode = root.stat().st_ino
        @contextmanager
        def swapped_scan(descriptor):
            with original_scan(descriptor) as children:
                yield children
            if os.fstat(descriptor).st_ino == root_inode:
                (root / "nested").rename(root / "original-nested")
                (root / "nested").symlink_to(outside, target_is_directory=True)
        with patch.object(scopes.os, "scandir", side_effect=swapped_scan):
            with self.assertRaises(OSError):
                scopes.diagnostic_files(root, 64, 10)

    def test_pinned_export_root_does_not_follow_replacement_root_path(self):
        outside = self.directory / "outside-root"
        outside.mkdir()
        (outside / "runner.ips").write_bytes(b"outside")
        original_inventory = scopes.diagnostic_files
        def swapped_inventory(root, *args, **kwargs):
            files = original_inventory(root, *args, **kwargs)
            if root.name == "exported":
                root.rename(root.with_name("original-exported"))
                root.symlink_to(outside, target_is_directory=True)
            return files
        with patch.object(scopes, "diagnostic_files", side_effect=swapped_inventory):
            receipt = self.capture(payloads={"runner.ips": b"allowed"})
        self.assertEqual(receipt["status"], "captured")
        with zipfile.ZipFile(self.directory / receipt["archive"]) as archive:
            self.assertEqual(archive.read("runner.ips"), b"allowed")


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

    def assert_validation_jobs(self, workflow):
        """Per-job command lists, complete non-duplicated coverage, independence and early native start."""
        jobs = workflow_jobs(workflow)
        for job, expected in VALIDATION_JOBS.items():
            self.assertEqual(job_commands(jobs[job]), expected, job)
        # Complete, non-duplicated coverage: the split jobs together run each of the 17 exactly once.
        split = [command for job in VALIDATION_JOBS for command in job_commands(jobs[job])]
        self.assertEqual(len(split), 17)
        self.assertEqual(set(split), SEVENTEEN_VALIDATION_COMMANDS)
        for job, block in jobs.items():
            if job not in VALIDATION_JOBS:
                self.assertFalse(set(job_commands(block)) & SEVENTEEN_VALIDATION_COMMANDS,
                                 f"Validation commands belong to the guarded validation jobs only ({job}).")
        for job in VALIDATION_JOBS:
            run_steps = [step for step in job_steps(jobs[job]) if "\n        run:" in step]
            self.assertEqual(len(run_steps), len(VALIDATION_JOBS[job]))
            for step in run_steps:
                self.assertEqual(len(step.splitlines()), 2, "Validation steps must not gain skip/failure overrides.")
            # Independent: each needs only the classifier, so a failure in either job never skips the
            # other's suites; its only condition is the sanctioned selection flag (#194).
            self.assertEqual(re.findall(r"^    needs: (.+)$", jobs[job], re.MULTILINE), [f"[{CLASSIFIER_JOB}]"], job)
            self.assertEqual(re.findall(r"^    if: (.+)$", jobs[job], re.MULTILINE), [selection_condition(job)], job)
        self.assert_runner_placement(workflow)
        steps = job_steps(jobs["validate-native"])
        self.assertEqual(steps[0], "      - uses: actions/checkout@v4\n")
        self.assertEqual(steps[1], "      - name: Run integrated Swift tests\n        run: ./scripts/test.sh\n",
                         "Integrated Swift tests start right after checkout (#196).")
        self.assertNotIn("continue-on-error", workflow)

    def assert_runner_placement(self, workflow):
        """Each suite's runner is the reviewed placement; a Linux job holds only proven-portable commands."""
        jobs = workflow_jobs(workflow)
        self.assertEqual(set(JOB_RUNNERS), set(VALIDATION_JOBS) | {"guide-ui-consumer-probe"})
        for job, runner in JOB_RUNNERS.items():
            self.assertEqual(re.findall(r"^    runs-on: (.+)$", jobs[job], re.MULTILINE), [runner],
                             f"{job}: runner placement is #191's reviewed decision.")
            if runner != MACOS:
                self.assertLessEqual(set(job_commands(jobs[job])), PROVEN_PORTABLE_COMMANDS,
                                     f"{job} runs on {runner}: move only commands proven portable there.")
                self.assertFalse([step for step in job_steps(jobs[job]) if "upload-artifact" in step],
                                 f"{job}: required artifacts stay with their macOS producers.")

    def assert_artifacts_follow_their_producers(self, workflow):
        """Each required artifact uploads always, once, from its producers' job, after every producer."""
        jobs = workflow_jobs(workflow)
        for name, (job, title, producers, path) in REQUIRED_ARTIFACTS.items():
            self.assertEqual(workflow.count(f"          name: {name}\n"), 1, f"{name} has one upload step.")
            steps = job_steps(jobs[job])
            uploads = [index for index, step in enumerate(steps) if f"          name: {name}\n" in step]
            self.assertEqual(len(uploads), 1, f"{name} uploads from {job}, its producers' runner.")
            self.assertEqual(steps[uploads[0]],
                             f"      - name: {title}\n"
                             "        if: always()\n"
                             "        uses: actions/upload-artifact@v4\n"
                             "        with:\n"
                             f"          name: {name}\n"
                             f"          path: {path}\n"
                             "          include-hidden-files: true\n"
                             "          if-no-files-found: error\n"
                             "          retention-days: 14\n")
            for command in producers:
                found = [index for index, step in enumerate(steps) if f"        run: {command}\n" in step]
                self.assertEqual(len(found), 1, f"{command} must run in {name}'s job.")
                self.assertLess(found[0], uploads[0], f"{name} would miss {command}'s later partial diagnostics.")

    def test_ci_preserves_all_seventeen_validation_commands_without_new_conditions(self):
        self.assert_validation_jobs((ROOT / ".github/workflows/ci.yml").read_text())

    def test_ci_native_tests_do_not_read_the_unsigned_build(self):
        # Textual proxy: test.sh and every script it runs or loads, plus the project build phases'
        # scripts, never name build-unsigned or its output. It cannot see dynamic paths or Xcode's
        # implicit state; the live native job, which starts test.sh right after checkout, proves the rest.
        test_sh = (ROOT / "scripts/test.sh").read_text()
        self.assertIn('DERIVED_DATA="$ROOT/.build/tests"', test_sh)
        self.assertEqual(sorted(set(re.findall(r'"\$ROOT/scripts/([^"]+)"', test_sh))),
                         ["build-preference-test-client.sh", "fetch-sdk.sh",
                          "run-integrated-test-scopes.py", "verify-build-metadata.py"],
                         "test.sh runs a new script: add it to this scan.")
        scanned, pending = [], ["test.sh"]
        project = (ROOT / "CMUXMaestroPreview.xcodeproj/project.pbxproj").read_text()
        pending += re.findall(r"scripts/([A-Za-z0-9_.-]+\.(?:py|sh))", project)
        while pending:
            name = pending.pop()
            if name in scanned:
                continue
            scanned.append(name)
            text = (ROOT / "scripts" / name).read_text()
            pending += re.findall(r'"\$ROOT/scripts/([^"/]+\.(?:sh|py))"', text)
            pending += re.findall(r'spec_from_file_location\([^)]*"scripts/([^"]+\.py)"\)', text)
            pending += re.findall(r'with_name\("([^"]+\.py)"\)', text)
        for name in ("fetch-sdk.sh", "build-preference-test-client.sh", "run-integrated-test-scopes.py",
                     "run-guide-ui-validation.py", "guide-acceptance-evidence.py", "write-guide-reference.py"):
            self.assertIn(name, scanned)
        for name in scanned:
            text = (ROOT / "scripts" / name).read_text()
            for prerequisite in ("build-unsigned", ".build/unsigned"):
                with self.subTest(script=name, prerequisite=prerequisite):
                    self.assertNotIn(prerequisite, text)

    def assert_no_cross_run_reuse(self, workflow):
        """#193 measured setup reuse and rejected it: every validation job starts from a clean checkout."""
        actions = re.findall(r"""^\s*(?:-\s+)?uses:\s*["']?([^\s"'#]+)""", workflow, re.MULTILINE)
        self.assertEqual(len(actions), workflow.count("uses:"), "Every uses: must be a parseable step action.")
        self.assertEqual(set(actions), {"actions/checkout@v4", "actions/upload-artifact@v4"},
                         "Any new action, even one without a cache such as actions/setup-python, can carry state "
                         "across runs: it needs a setup-reuse review (#193) and an update to this guard.")
        for token in ("actions/cache", "actions/cache/", "restore-keys", "cache:", "cache-dependency-path",
                      "download-artifact", "gh run download", "gh cache"):
            self.assertNotIn(token, workflow, f"{token}: cross-run reuse needs #193's measured decision.")

    def test_ci_reuses_no_setup_state_across_runs(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assert_no_cross_run_reuse(workflow)
        test_sh = (ROOT / "scripts/test.sh").read_text()
        unsigned = (ROOT / "scripts/build-unsigned.sh").read_text()
        self.assertIn('DERIVED_DATA="$ROOT/.build/tests"', test_sh)
        self.assertIn('DERIVED_DATA="$ROOT/.build/unsigned"', unsigned)
        checkout = "      - uses: actions/checkout@v4\n      - name: Run integrated Swift tests\n"
        self.assertIn(checkout, workflow)
        restore = ("      - uses: actions/checkout@v4\n"
                   "      - uses: actions/cache@v4\n        with:\n          path: .build/tests\n"
                   "          key: tests-${{ hashFiles('**/*.swift') }}\n"
                   "      - name: Run integrated Swift tests\n")
        mutations = {
            "DerivedData cache": workflow.replace(checkout, restore, 1),
            "cached toolchain": workflow.replace(
                "      - uses: actions/checkout@v4\n      - name: Test local skill override validation\n",
                "      - uses: actions/checkout@v4\n      - uses: actions/setup-node@v4\n        with:\n"
                "          cache: npm\n      - name: Test local skill override validation\n", 1),
            "prior run's artifact": workflow.replace(
                checkout, "      - uses: actions/checkout@v4\n      - uses: actions/download-artifact@v4\n"
                "      - name: Run integrated Swift tests\n", 1),
            "comment-suffixed third-party restore": workflow.replace(
                checkout, "      - uses: actions/checkout@v4\n"
                "      - uses: example/restore-derived-data@0123456789abcdef0123456789abcdef01234567 # v1\n"
                "      - name: Run integrated Swift tests\n", 1),
            "quoted action": workflow.replace(
                checkout, "      - uses: actions/checkout@v4\n      - uses: 'actions/setup-python@v5'\n"
                "      - name: Run integrated Swift tests\n", 1),
            "gh run download": workflow.replace(
                checkout, "      - uses: actions/checkout@v4\n      - name: Restore prior build\n"
                "        run: gh run download 1 -n derived-data -D .build/tests\n"
                "      - name: Run integrated Swift tests\n", 1),
            "gh cache": workflow.replace(
                checkout, "      - uses: actions/checkout@v4\n      - name: Restore prior build\n"
                "        run: gh cache list\n      - name: Run integrated Swift tests\n", 1),
        }
        for name, mutated in mutations.items():
            with self.subTest(mutation=name):
                self.assertNotEqual(mutated, workflow)
                with self.assertRaises(AssertionError):
                    self.assert_no_cross_run_reuse(mutated)

    def test_ci_split_job_guards_reject_order_coverage_and_dependency_drift(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        test_sh = "      - name: Run integrated Swift tests\n        run: ./scripts/test.sh\n"
        hook = "      - name: Verify compiled hooks fail open\n        run: ./scripts/test-copilot-hook.sh\n"
        setup = "      - name: Verify Settings guide and setup process isolation\n        run: ./scripts/test-copilot-setup.sh\n"
        beats = "        run: python3 scripts/test-beats.py\n"
        metadata = ("      - name: Verify build and registration metadata contracts\n"
                    "        run: python3 scripts/test-build-metadata.py\n")
        portable_last = ("      - name: Verify local skill overrides and policy links\n"
                         "        run: node scripts/check-skill-overrides.mjs\n")
        portable_steps = ("      - name: Test local skill override validation\n"
                          "        run: node --test scripts/test-skill-overrides.mjs\n" + portable_last)
        setup_upload = workflow[workflow.index("      - name: Upload setup process isolation evidence\n"):]
        setup_upload = setup_upload[:setup_upload.index("retention-days: 14\n") + len("retention-days: 14\n")]
        validation_mutations = {
            "native needs contracts": workflow.replace(
                "  validate-native:\n", "  validate-native:\n    needs: [validate-contracts]\n"),
            "contracts needs native": workflow.replace(
                "  validate-contracts:\n", "  validate-contracts:\n    needs: validate-native\n"),
            # Same command lists; only a non-prerequisite step now runs ahead of test.sh.
            "test.sh not first": workflow.replace(test_sh, "      - uses: actions/setup-node@v4\n" + test_sh, 1),
            "command duplicated across jobs": workflow.replace(test_sh, test_sh + "      - name: dup\n" + beats, 1),
            "dropped command": workflow.replace(hook, ""),
            "command moved to the gate": workflow.replace(hook, "").rstrip("\n") + "\n" + hook,
            # Runner placement (#191).
            "native on Linux": workflow.replace(
                "    if: needs.ci-classify.outputs.run_validate_native != 'false'\n    runs-on: macos-latest\n",
                "    if: needs.ci-classify.outputs.run_validate_native != 'false'\n    runs-on: ubuntu-latest\n"),
            "contracts on Linux": workflow.replace(
                "    if: needs.ci-classify.outputs.run_validate_contracts != 'false'\n    runs-on: macos-latest\n",
                "    if: needs.ci-classify.outputs.run_validate_contracts != 'false'\n    runs-on: ubuntu-latest\n"),
            "probe on Linux": workflow.replace(
                "    if: needs.ci-classify.outputs.run_guide_ui_consumer_probe != 'false'\n    runs-on: macos-latest\n",
                "    if: needs.ci-classify.outputs.run_guide_ui_consumer_probe != 'false'\n    runs-on: ubuntu-latest\n"),
            "portable job on macOS": workflow.replace(
                "    if: needs.ci-classify.outputs.run_validate_portable != 'false'\n    runs-on: ubuntu-latest\n",
                "    if: needs.ci-classify.outputs.run_validate_portable != 'false'\n    runs-on: macos-latest\n"),
            "portable job on a matrix of runners": workflow.replace(
                "    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - name: Test local",
                "    runs-on: [ubuntu-latest, macos-latest]\n    steps:\n      - uses: actions/checkout@v4\n"
                "      - name: Test local"),
            "unproven command moved to Linux": workflow.replace(metadata, "").replace(
                portable_last, portable_last + metadata),
            "skill checks moved back to macOS": workflow.replace(portable_steps, "").replace(
                "      - name: Verify local Joe role", portable_steps + "      - name: Verify local Joe role"),
        }
        artifact_mutations = {
            "setup upload before its producer": workflow.replace(setup_upload, "").replace(setup, setup_upload + setup),
            "layout upload before test.sh": workflow.replace(test_sh, "", 1).replace(
                "      - name: Upload integrated test scope evidence\n",
                test_sh + "      - name: Upload integrated test scope evidence\n", 1),
            "integrated upload before test.sh": workflow.replace(test_sh, "", 1).replace(
                "  validate-contracts:\n", "      - name: late\n" + test_sh[len("      - name: Run integrated Swift tests\n"):]
                + "\n  validate-contracts:\n", 1),
            "setup upload in the other job": workflow.replace(setup_upload, "").replace(
                "          retention-days: 14\n\n  validate-contracts:",
                "          retention-days: 14\n" + setup_upload + "\n  validate-contracts:", 1),
            "upload without always()": workflow.replace(
                "Upload setup process isolation evidence\n        if: always()\n",
                "Upload setup process isolation evidence\n"),
        }
        for name, mutated in validation_mutations.items():
            with self.subTest(mutation=name):
                self.assertNotEqual(mutated, workflow)
                with self.assertRaises(AssertionError):
                    self.assert_validation_jobs(mutated)
        for name, mutated in artifact_mutations.items():
            with self.subTest(mutation=name):
                self.assertNotEqual(mutated, workflow)
                with self.assertRaises((AssertionError, KeyError, ValueError)):
                    self.assert_artifacts_follow_their_producers(mutated)

    def test_ci_runs_one_suite_per_pr_update_and_full_validation_on_main(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        triggers = re.split(r"\n(?=\S)", workflow.split("\non:\n", 1)[1], maxsplit=1)[0]
        # Feature-branch pushes would duplicate the PR suite; only main pushes and PR updates validate.
        self.assertEqual(triggers, "  push:\n    branches: [main]\n  pull_request:\n",
                         "The CI event matrix is merge policy: update docs/agents/merge-policy.md "
                         "('When it runs') together with any trigger change.")
        jobs = workflow_jobs(workflow)
        self.assertEqual(sorted(jobs), sorted([CLASSIFIER_JOB, *VALIDATION_JOBS, "guide-ui-consumer-probe", "ci-gate"]))
        for job in (*VALIDATION_JOBS, "guide-ui-consumer-probe"):
            with self.subTest(job=job):
                # Jobs are never event-filtered; triggers own the matrix. The only job condition is the
                # suite-selection flag, which the classifier always sets to 'true' on a push.
                self.assertEqual(re.findall(r"^    if: (.+)$", jobs[job], re.MULTILINE), [selection_condition(job)])
        self.assertNotRegex(jobs[CLASSIFIER_JOB], r"(?m)^    if:", "The classifier runs for every validated event.")
        # The gate's only job condition is always(), so it exists for every validated event.
        self.assertEqual(re.findall(r"^    if: (.+)$", jobs["ci-gate"], re.MULTILINE), ["always()"])
        policy = (ROOT / "docs/agents/merge-policy.md").read_text()
        section = policy.split("**When it runs (#192):**", 1)[1].split("Its current commands", 1)[0]
        for phrase in ("pushes to `main`", "every pull request update", "is stale too",
                       "draft pull request", "Tags are not validated"):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, section)

    def test_ci_cancels_superseded_pr_runs_without_cancelling_running_main(self):
        workflow = yaml_workflow((ROOT / ".github/workflows/ci.yml").read_text())
        self.assertEqual(workflow["concurrency"], {
            "group": "ci-${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}",
            "cancel-in-progress": "${{ github.event_name == 'pull_request' }}",
        }, "Keep cancellation scoped to one PR and never cancel an in-progress main push.")

    def test_ci_documentation_tracks_the_guarded_validation_commands(self):
        jobs = workflow_jobs((ROOT / ".github/workflows/ci.yml").read_text())
        policy = (ROOT / "docs/agents/merge-policy.md").read_text()
        section = policy.split("## Actual CI and formatting gates", 1)[1].split("Its current commands", 1)[1]
        documented = re.findall(r"^`([a-z-]+)`[^\n]*:\n\n```sh\n(.*?)\n```", section, re.MULTILINE | re.DOTALL)
        self.assertEqual([job for job, _ in documented], list(VALIDATION_JOBS))
        for job, commands in documented:
            with self.subTest(job=job):
                self.assertEqual(commands.splitlines(), job_commands(jobs[job]))

    GATE_BLOCK = (
        "    timeout-minutes: 10\n"
        "    needs: [{needs}]\n"
        "    if: always()\n"
        "    runs-on: ubuntu-latest\n"
        "    permissions:\n"
        "      contents: read\n"
        "    steps:\n"
        "      - uses: actions/checkout@v4\n"
        "        if: always()\n"
        "      - name: Verify final gate evaluator\n"
        "        if: always()\n"
        "        run: python3 scripts/test-ci-gate.py\n"
        "      - name: Verify suite classifier\n"
        "        if: always()\n"
        "        run: python3 scripts/test-ci-classify.py\n"
        "      - name: Evaluate required suites\n"
        "        if: always()\n"
        "        env:\n"
        "          CI_GATE_NEEDS: ${{{{ toJSON(needs) }}}}\n"
        "        run: python3 scripts/ci-gate.py\n")

    def assert_final_gate(self, workflow, contract):
        jobs = workflow_jobs(workflow)
        gate = contract["gate_job"]
        self.assertEqual(gate, "ci-gate", "The gate's job id is the documented check name.")
        self.assertEqual(list(jobs)[-1], gate, "Keep the gate last so its block holds no other job.")
        classifier = contract["classifier_job"]
        self.assertEqual(classifier, CLASSIFIER_JOB)
        validation = sorted(job for job in jobs if job not in (gate, classifier))
        self.assertTrue(validation)
        self.assertEqual(sorted(suite["job"] for suite in contract["suites"]), validation,
                         "Every validation job is a required suite; update scripts/ci-required-suites.json.")
        # Whole block to end of file: every step runs even on cancellation, so the table always prints.
        self.assertEqual(jobs[gate].rstrip("\n") + "\n", self.GATE_BLOCK.format(
            needs=", ".join([classifier, *(suite["job"] for suite in contract["suites"])])))
        self.assert_suite_selection(workflow, contract)
        self.assertNotIn("continue-on-error", workflow)

    def assert_suite_selection(self, workflow, contract):
        """The classifier's exact block, and each suite's only needs/condition: its own selection flag."""
        jobs = workflow_jobs(workflow)
        suites = [suite["job"] for suite in contract["suites"]]
        self.assertEqual(list(jobs)[0], CLASSIFIER_JOB, "The classifier starts first; every suite needs it.")
        flags = "".join(f"      run_{job.replace('-', '_')}: ${{{{ steps.classify.outputs.run_{job.replace('-', '_')} }}}}\n"
                        for job in suites)
        body = re.sub(r"(?m)^    #.*\n", "", jobs[CLASSIFIER_JOB]).rstrip("\n") + "\n"
        self.assertEqual(body, CLASSIFIER_BLOCK.format(flags=flags))
        for job in suites:
            # A job-level condition could skip a suite; only the classifier's flag may, and ci-gate
            # accepts that skip only with the classifier's matching not-applicable record.
            self.assertEqual(re.findall(r"^    (needs|if): (.+)$", jobs[job], re.MULTILINE),
                             [("needs", f"[{CLASSIFIER_JOB}]"), ("if", selection_condition(job))], job)

    def test_ci_final_gate_requires_every_validation_job_through_the_contract(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        contract = json.loads((ROOT / "scripts/ci-required-suites.json").read_text())
        self.assert_final_gate(workflow, contract)
        policy = (ROOT / "docs/agents/merge-policy.md").read_text()
        section = policy.split("**Final coverage gate (#197):**", 1)[1].split("Its current commands", 1)[0]
        for phrase in ("`ci-gate`", "scripts/ci-required-suites.json", "merge signal",
                       "if-no-files-found: error", "branches/main/protection",
                       "required status check", "`enforce_admins: true`", "`strict: false`",
                       "every gate step uses `if: always()`", "fails closed on any job it cannot parse",
                       "candidate's own", "changes to merge policy"):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, section)

    def assert_job_and_step_shapes(self, workflow, gate, classifier=CLASSIFIER_JOB, suites=None):
        policy = ("; see docs/agents/merge-policy.md (#190: no arbitrary timeouts or blanket skips; "
                  "job-level hang ceilings only, owner decision 2026-10-15).")
        if suites is None:
            suites = [suite["job"] for suite in json.loads((ROOT / "scripts/ci-required-suites.json").read_text())["suites"]]
        # Every timeout-minutes is a job-level key (four-space indent), exactly one per job, pinned.
        self.assertEqual(re.findall(r"^( *)timeout-minutes:", workflow, re.MULTILINE),
                         ["    "] * len(JOB_CEILINGS), "Only one job-level timeout-minutes per job" + policy)
        blocks = workflow_jobs(workflow)
        self.assertEqual(sorted(blocks), sorted(JOB_CEILINGS), "Every job needs a pinned hang ceiling" + policy)
        for job, block in blocks.items():
            self.assertEqual(re.findall(r"^    timeout-minutes: (.*)$", block, re.MULTILINE),
                             [str(JOB_CEILINGS[job])], f"Job {job} hang ceiling" + policy)
        for job, body in yaml_jobs(workflow).items():
            self.assertIs(type(body.get("timeout-minutes")), int, f"Job {job} hang ceiling" + policy)
            self.assertEqual(body["timeout-minutes"], JOB_CEILINGS[job], f"Job {job} hang ceiling" + policy)
            allowed = {"runs-on", "steps", "permissions", "timeout-minutes"}
            if job == gate:
                allowed |= {"needs", "if"}
                self.assertEqual(body.get("if"), "always()", "The gate is always created" + policy)
            elif job == classifier:
                allowed |= {"outputs"}
            elif job in suites:
                # Suite selection (#194): exactly the classifier dependency and this job's own flag.
                allowed |= {"needs", "if"}
                self.assertEqual(body.get("needs"), [classifier], f"Job {job} may only need {classifier}" + policy)
                self.assertEqual(body.get("if"), selection_condition(job),
                                 f"Job {job} may only use its sanctioned selection condition" + policy)
            self.assertLessEqual(set(body), allowed, f"Job {job} has keys outside the allow-list" + policy)
            for step in body["steps"]:
                self.assertIn(step.get("if", "always()"), ("always()",),
                              f"Step {step.get('name', step.get('uses'))} in {job} may only use if: always()" + policy)
                self.assertNotIn("timeout-minutes", step, policy)

    def test_ci_jobs_and_steps_use_only_allowed_keys_and_conditions(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assert_job_and_step_shapes(workflow, "ci-gate")
        native_if = "    if: needs.ci-classify.outputs.run_validate_native != 'false'\n"
        probe_if = "    if: needs.ci-classify.outputs.run_guide_ui_consumer_probe != 'false'\n"
        mutations = {
            "duplicate job ceiling": ("  validate-native:\n", "  validate-native:\n    timeout-minutes: 60\n"),
            "missing job ceiling": ("    timeout-minutes: 60\n", ""),
            "shortened job ceiling": ("    timeout-minutes: 60\n", "    timeout-minutes: 30\n"),
            "raised job ceiling": ("    timeout-minutes: 15\n", "    timeout-minutes: 360\n"),
            "expression job ceiling": ("    timeout-minutes: 50\n", "    timeout-minutes: ${{ 50 }}\n"),
            "quoted job ceiling": ("    timeout-minutes: 50\n", "    timeout-minutes: '50'\n"),
            "job strategy": ("  validate-native:\n", "  validate-native:\n    strategy:\n      fail-fast: false\n"),
            "checkout if: false": ("      - uses: actions/checkout@v4\n      - name: Test local",
                                   "      - uses: actions/checkout@v4\n        if: false\n      - name: Test local"),
            "step timeout-minutes": ("        run: ./scripts/test.sh\n",
                                     "        run: ./scripts/test.sh\n        timeout-minutes: 30\n"),
            # Suite selection (#194): only the sanctioned dependency and condition.
            "classifier gains an if": ("  ci-classify:\n    timeout-minutes: 10\n",
                                       "  ci-classify:\n    timeout-minutes: 10\n"
                                       "    if: github.event_name == 'pull_request'\n"),
            "classifier gains needs": ("  ci-classify:\n    timeout-minutes: 10\n",
                                       "  ci-classify:\n    timeout-minutes: 10\n    needs: [validate-native]\n"),
            "suite run on 'true' only": (native_if, native_if.replace("!= 'false'", "== 'true'")),
            "suite condition with always()": (native_if, native_if.replace("if: ", "if: always() && ")),
            "suite condition is always()": (native_if, "    if: always()\n"),
            "suite event filter": (native_if, "    if: github.event_name == 'push'\n"),
            "suite reads another suite's flag": (probe_if, probe_if.replace("run_guide_ui_consumer_probe",
                                                                            "run_validate_native")),
            "suite condition dropped": (probe_if, ""),
            "suite needs another suite": ("    needs: [ci-classify]\n    if: needs.ci-classify.outputs.run_validate_contracts",
                                          "    needs: [ci-classify, validate-native]\n"
                                          "    if: needs.ci-classify.outputs.run_validate_contracts"),
            "gate condition narrowed": ("    if: always()\n    runs-on: ubuntu-latest\n",
                                        "    if: success()\n    runs-on: ubuntu-latest\n"),
        }
        for name, (old, new) in mutations.items():
            with self.subTest(mutation=name):
                self.assertEqual(workflow.count(old), 1)
                with self.assertRaises(AssertionError):
                    self.assert_job_and_step_shapes(workflow.replace(old, new), "ci-gate")

    def test_ci_suite_selection_guard_rejects_classifier_and_condition_drift(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        contract = json.loads((ROOT / "scripts/ci-required-suites.json").read_text())
        self.assert_suite_selection(workflow, contract)
        mutations = {
            "shallow classifier checkout": ("          fetch-depth: 0\n", "          fetch-depth: 1\n"),
            "base inlined into run": ("        run: python3 scripts/ci-classify.py\n",
                                      "        run: python3 scripts/ci-classify.py "
                                      "${{ github.event.pull_request.base.sha }}\n"),
            "head from the wrong ref": ("pull_request.head.sha", "pull_request.head.ref"),
            "flag output dropped": ("      run_validate_contracts: ${{ steps.classify.outputs.run_validate_contracts }}\n",
                                    ""),
            "flag output hard-coded": ("${{ steps.classify.outputs.run_guide_ui_consumer_probe }}", "'false'"),
            "classifier tests before classification": ("      - name: Classify changed files\n",
                                                       "      - name: Pre\n        run: python3 scripts/test-ci-classify.py\n"
                                                       "      - name: Classify changed files\n"),
            "suite condition inverted": ("outputs.run_validate_contracts != 'false'",
                                         "outputs.run_validate_contracts == 'false'"),
            "gate loses the classifier": ("    needs: [ci-classify, validate-native,", "    needs: [validate-native,"),
            "gate skips classifier tests": ("        run: python3 scripts/test-ci-classify.py\n",
                                            "        run: echo skipped\n"),
        }
        for name, (old, new) in mutations.items():
            with self.subTest(mutation=name):
                self.assertEqual(workflow.count(old), 1, name)
                with self.assertRaises((AssertionError, ValueError)):
                    self.assert_final_gate(workflow.replace(old, new), contract)

    def test_ci_hang_ceilings_are_documented_merge_policy(self):
        policy = (ROOT / "docs/agents/merge-policy.md").read_text()
        section = policy.split("**Hang ceilings (owner decision 2026-10-15):**", 1)[1].split("\n**", 1)[0]
        documented = dict(re.findall(r"^  - `([a-z-]+)`: (\d+) min ", section, re.MULTILINE))
        self.assertEqual({job: int(value) for job, value in documented.items()}, JOB_CEILINGS)
        for phrase in ("exactly one job-level `timeout-minutes`", "not a speed target",
                       "step-level `timeout-minutes` stays forbidden", "`ci-gate` (which runs `if: always()`) fails",
                       "merge-policy change"):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, section)

    def test_ci_runner_placement_is_documented_merge_policy(self):
        policy = (ROOT / "docs/agents/merge-policy.md").read_text()
        section = policy.split("**Runner placement (#191):**", 1)[1].split("Its current commands", 1)[0]
        for phrase in ("ci-runner-placement.md", "`validate-portable` (`ubuntu-latest`)", "never move",
                       "Python or Node source alone is not proof", "en-US collation", "/usr/bin/plutil",
                       "not split further", "merge-policy change"):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, section)

    def test_ci_suite_selection_is_documented_merge_policy(self):
        policy = (ROOT / "docs/agents/merge-policy.md").read_text()
        section = policy.split("**Suite selection (#194):**", 1)[1].split("Its current commands", 1)[0]
        for phrase in ("`ci-classify`", "scripts/ci-suite-map.json", "scripts/ci-classify.py",
                       "not applicable", "NOT APPLICABLE", "pushes to `main`", "unmapped", "every suite",
                       "never an empty success", "same run", "later full run on `main`",
                       "changes to merge policy", "(case-insensitively", "other than the literal `false`"):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, section)
        # Merge evidence (review item 4) and the command lists must allow deliberate not-applicable skips.
        gate_item = policy.split("\n4. ", 1)[1].split("\n5. ", 1)[0]
        gate_item = " ".join(gate_item.split())
        for phrase in ("every applicable suite passed", "`NOT APPLICABLE`", "from that run's `ci-classify`",
                       "record's `base` must equal current `main`", "its `head` must equal the candidate",
                       "stacked parent branch, or a stale base, is not merge evidence"):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, gate_item)
        self.assertNotIn("Require all repository CI commands", policy)
        self.assertIn("Each runs at most once; a not-applicable suite runs none of its commands", policy)
        self.assertNotIn("Each runs exactly once", policy)

    def test_ci_final_gate_guard_rejects_hidden_jobs_and_gate_drift(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        contract = json.loads((ROOT / "scripts/ci-required-suites.json").read_text())
        hidden = "\n  {}\n    runs-on: macos-latest\n    steps:\n      - run: echo hidden\n\n  # Final coverage"
        mutations = {
            "quoted job id": workflow.replace("\n\n  # Final coverage", hidden.format('"extra":')),
            "job id with trailing comment": workflow.replace("\n\n  # Final coverage", hidden.format("extra:  # c")),
            "flow-mapping job": workflow.replace(
                "\n\n  # Final coverage", "\n  extra: {runs-on: macos-latest, steps: [{run: echo}]}\n\n  # Final coverage"),
            "key after a blank line in the gate": workflow.rstrip("\n") + "\n\n    timeout-minutes: 1\n",
            "checkout without always()": workflow.replace(
                "      - uses: actions/checkout@v4\n        if: always()\n      - name: Verify final gate",
                "      - uses: actions/checkout@v4\n      - name: Verify final gate"),
            "evaluator tests without always()": workflow.replace(
                "evaluator\n        if: always()\n", "evaluator\n"),
        }
        for name, mutated in mutations.items():
            with self.subTest(mutation=name):
                self.assertNotEqual(mutated, workflow)
                with self.assertRaises((AssertionError, ValueError)):
                    self.assert_final_gate(mutated, contract)

    def test_ci_always_uploads_json_evidence_and_retains_required_png_artifact(self):
        self.assert_artifacts_follow_their_producers((ROOT / ".github/workflows/ci.yml").read_text())

    def test_ci_collects_final_metadata_diagnostics_after_both_producers(self):
        # Both producers write metadata stall diagnostics; each job's upload follows its own producer.
        self.assertEqual(REQUIRED_ARTIFACTS["integrated-test-scope-evidence"][::2],
                         ("validate-native", ["./scripts/test.sh"]))
        self.assertEqual(REQUIRED_ARTIFACTS["copilot-setup-evidence"][::2],
                         ("validate-contracts", ["./scripts/test-copilot-setup.sh"]))
        integrated = REQUIRED_ARTIFACTS["integrated-test-scope-evidence"][3]
        setup_paths = REQUIRED_ARTIFACTS["copilot-setup-evidence"][3]
        self.assertIn(".build/tests/scoped-results/**/*.json", integrated)
        self.assertIn(".build/tests/scoped-results/**/*.txt", integrated)
        self.assertIn(".build/tests/scoped-results/metadata-diagnostics/", setup_paths)
        self.assertIn(".build/setup-tests/metadata-watchdog/", setup_paths)
        setup = (ROOT / "scripts/test-copilot-setup.sh").read_text()
        self.assertIn('OUTPUT="$ROOT/.build/setup-tests"', setup)
        self.assertIn('--results-root "$OUTPUT/metadata-watchdog"', setup)
        self.assertIn('"$ROOT/CMUXMaestroPreviewTests/CopilotObserverRegistrationTests.swift"', setup)
        observer = (ROOT / "CMUXMaestroPreviewTests/CopilotObserverRegistrationTests.swift").read_text()
        # One watchdog-guarded metadata test remains; the cancellation one was removed (#174, 2026-10-15).
        self.assertEqual(observer.count('".build/tests/scoped-results/metadata-diagnostics/'), 1)
        self.assert_artifacts_follow_their_producers((ROOT / ".github/workflows/ci.yml").read_text())

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
        (resources / "processes.mjs").write_text("// synthetic process passes\n")
        (resources / "models.mjs").write_text("// synthetic model projection\n")
        self.save()

    def test_messaging_resources_are_required_for_every_build_profile(self):
        for name in ("adapter.mjs", "extension.mjs", "processes.mjs", "models.mjs"):
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
        good = {metadata.SANDBOX_KEY: True, metadata.READ_KEY: metadata.READ_PATHS, metadata.WRITE_KEY: metadata.WRITE_PATHS}
        metadata.verify_profile(good)
        for invalid in (
            {metadata.READ_KEY: metadata.READ_PATHS},
            {metadata.SANDBOX_KEY: True, metadata.READ_KEY: metadata.READ_PATHS},
            {**good, metadata.WRITE_KEY: ["/Library/Application Support/CMUXMaestroPreview/"]},
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
        good = {metadata.SANDBOX_KEY: True, metadata.READ_KEY: metadata.READ_PATHS, metadata.WRITE_KEY: metadata.WRITE_PATHS}

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
