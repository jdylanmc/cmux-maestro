#!/usr/bin/env python3
"""Separate required hosted XCUITest venue; --build-only never launches a native binary."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
TARGET = "CMUXMaestroRowInputUITests"
METHODS = {
    "testEscapePreservesOwnerKeyboardModality",
    "testOwnerCompleteClickClearsOwnerAndSiblingModality",
    "testForeignCompleteClickPreservesOwnerModality",
    "testNativeMenuKeyboardTraversalInvokesProductionAction",
    "testNativeTitleActivationAndTabTraversal",
    "testCompleteClicksReachExactFixtureWindowsWithoutMenu",
}


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


metadata = load("row_metadata", "verify-build-metadata.py")
scopes = load("row_scopes", "run-integrated-test-scopes.py")


def require_hosted(environment):
    metadata.require(environment.get("GITHUB_ACTIONS") == "true"
                     and environment.get("RUNNER_ENVIRONMENT") == "github-hosted",
                     "UI execution requires GitHub-hosted macOS; no UI access was attempted.")


def observed_cases(document):
    return scopes.cases(document, expected_project="CMUXMaestroPreview",
                        expected_plan="CMUXMaestroRowInput", strict_suite=True)


def validate_results(summary, document):
    selected = observed_cases(document)
    counts = scopes.reconcile(summary, selected)
    expected = {f"{TARGET}/RowInputUITests/{method}" for method in METHODS}
    metadata.require({case.identity.removesuffix("()") for case in selected} == expected,
                     "The exact six required UI tests were not executed.")
    metadata.require(all(case.status == "Passed" and not case.parameterized
                         and case.executions == ((None, "Passed"),) for case in selected),
                     "Row input UI tests must each pass once; skips, failures and retries are not acceptance.")
    metadata.require(counts["passedTests"] == len(METHODS)
                     and counts["totalTestCount"] == len(METHODS), "Invalid row input UI counts.")
    return counts


def binding():
    def git(*args):
        return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True).strip()
    paths = git("ls-files", "--cached", "--others", "--exclude-standard").splitlines()
    relevant = [path for path in paths if path.endswith((".swift", ".pbxproj", ".xcscheme"))
                or path.startswith("scripts/") or path == ".github/workflows/ci.yml"]
    return {
        "head": git("rev-parse", "HEAD"),
        "tree": git("rev-parse", "HEAD^{tree}"),
        "diffSHA256": hashlib.sha256(git("diff", "HEAD", "--").encode()).hexdigest(),
        "files": {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in relevant
                  if (ROOT / path).is_file()},
    }


def run(build_only):
    if not build_only:
        require_hosted(os.environ)
    metadata.require(Path("/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild").is_file(),
                     "Full Xcode is missing.")
    metadata.require((ROOT / "vendor/CmuxExtensionKit/Package.swift").is_file(),
                     "Pinned SDK is missing; run the checked-in scripts/fetch-sdk.sh before this build.")
    directory = ROOT / ".build/row-input" / ("run-" + uuid.uuid4().hex)
    directory.mkdir(parents=True)
    evidence = {"buildOnly": build_only, "executed": False, "sourceBefore": binding(), "commands": [],
                "requiredTests": sorted(METHODS)}
    receipt = directory / "evidence.json"

    def save():
        receipt.write_text(json.dumps(evidence, indent=2) + "\n")

    def execute(label, command, *, environment=None):
        path = directory / (label + ".log")
        with path.open("w") as stream:
            result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, env=environment)
        evidence["commands"].append({"label": label, "argv": command, "exitCode": result.returncode,
                                     "log": str(path)})
        save()
        if result.returncode:
            print(path.read_text()[-16000:], file=sys.stderr)
        return result.returncode

    settings = [
        "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CMUX_BUNDLE_ID_SUFFIX=.Validation.Tests",
        "CMUX_DISPLAY_NAME_SUFFIX= (Test Validation)",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_VALIDATION",
        "CMUX_SIDEBAR_EXTENSION_POINT_ID=com.jdylanmc.CMUXMaestroPreview.validation.tests.sidebar",
    ]
    project = ["xcodebuild", "-project", str(ROOT / "CMUXMaestroPreview.xcodeproj")]
    command = [*project, "-scheme", "CMUXMaestroRowInput", "-configuration", "Debug",
               "-destination", "platform=macOS", "-derivedDataPath", str(directory / "derived"), *settings]
    try:
        code = execute("namespace-settings", [*project, "-alltargets", "-configuration", "Debug",
                                              "-showBuildSettings", "-json", *settings])
        metadata.require(code == 0, "Could not resolve namespace settings.")
        rows = json.loads((directory / "namespace-settings.log").read_text())
        metadata.verify_settings(rows, "tests")
        metadata.verify_row_input_settings(rows)
        metadata.require(execute("build-for-testing", [*command, "build-for-testing"]) == 0,
                         "Actual fixture/UI test target compilation failed.")
        metadata.verify_row_input_products(directory / "derived/Build/Products/Debug")
        evidence["sourceAfterBuild"] = binding()
        metadata.require(evidence["sourceBefore"] == evidence["sourceAfterBuild"], "Source changed during compilation.")
        evidence["buildPassed"] = True
        save()
        if build_only:
            return 0
        require_hosted(os.environ)
        environment = dict(os.environ)
        environment["TEST_RUNNER_GITHUB_ACTIONS"] = environment["GITHUB_ACTIONS"]
        environment["TEST_RUNNER_RUNNER_ENVIRONMENT"] = environment["RUNNER_ENVIRONMENT"]
        bundle = directory / "row-input.xcresult"
        evidence["executed"] = True
        code = execute("test-without-building", [*command, "test-without-building",
                                                "-resultBundlePath", str(bundle)], environment=environment)
        summary, tests = scopes.read_result(bundle, directory, "row-input", subprocess.run)
        selected = observed_cases(tests)
        evidence["observedCounts"] = scopes.reconcile(summary, selected)
        evidence["observedCases"] = [{"identity": case.identity, "status": case.status,
                                      "executions": case.executions} for case in selected]
        evidence["counts"] = validate_results(summary, tests)
        metadata.require(code == 0, "XCUITest failed despite its reported case counts.")
        evidence["sourceAfterExecution"] = binding()
        metadata.require(evidence["sourceBefore"] == evidence["sourceAfterExecution"], "Source changed during execution.")
        evidence["passed"] = True
        return 0
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        evidence["error"] = str(error)
        print(f"Row input venue failed: {error}", file=sys.stderr)
        return 1
    finally:
        save()
        print(f"Row input evidence: {receipt}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-only", action="store_true", help="Compile both actual targets without UI execution")
    args = parser.parse_args()
    return run(args.build_only)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Row input venue refused: {error}", file=sys.stderr)
        sys.exit(1)
