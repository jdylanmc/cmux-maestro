#!/usr/bin/env python3
"""Hosted-only partition: one blocking-observer regression, then its full complement."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import uuid
from urllib.parse import unquote, urlparse

TARGET = "CMUXMaestroPreviewTests"
TEST = "CopilotSetupTests/concurrentSupervisionDoesNotOccupyCooperativeExecutor()"
SELECTOR = TARGET + "/" + TEST
SCHEMA = "0.1.0"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def cases(document):
    require(isinstance(document, dict), "Invalid xcresult test document.")
    require(isinstance(document.get("testNodes"), list), "Missing xcresult test tree.")
    result = []

    def visit(node, bundle=None):
        require(isinstance(node, dict), "Invalid xcresult test node.")
        if node.get("nodeType") in ("Unit test bundle", "UI test bundle"):
            require(isinstance(node.get("name"), str), "Invalid test bundle name.")
            bundle = node["name"].removesuffix(".xctest")
        if node.get("nodeType") == "Test Case":
            identifier = node.get("nodeIdentifier")
            url = node.get("nodeIdentifierURL")
            if url:
                require(isinstance(url, str), "Invalid test identifier URL.")
                parsed = urlparse(url)
                require(parsed.scheme == "test" and parsed.netloc == "com.apple.xcode",
                        "Unrecognized test identifier URL; preserve the result for inspection.")
                identity = unquote(parsed.path).lstrip("/")
            else:
                require(bundle and isinstance(identifier, str) and identifier,
                        "A test case has no attributable identifier.")
                identity = identifier if identifier.startswith(bundle + "/") else bundle + "/" + identifier
            result.append((identity, node.get("result")))
        children = node.get("children", [])
        require(isinstance(children, list), "Invalid test children.")
        for child in children:
            visit(child, bundle)

    for node in document["testNodes"]:
        visit(node)
    require(result, "No test cases were reported; zero tests is not success.")
    require(len({identity for identity, _ in result}) == len(result), "Repeated/ambiguous test identifiers.")
    return result


def counts(summary):
    require(isinstance(summary, dict), "Invalid xcresult summary.")
    keys = ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")
    require(all(type(summary.get(key)) is int and summary[key] >= 0 for key in keys),
            "Missing or invalid explicit test counts.")
    require(summary["totalTestCount"] > 0, "Zero tests is not success.")
    require(summary["totalTestCount"] == sum(summary[key] for key in keys[1:]),
            "Test counts do not reconcile.")
    return {key: summary[key] for key in keys}


def validate_isolated(summary, tests):
    measured = counts(summary)
    selected = cases(tests)
    require(measured["totalTestCount"] == 1 and measured["skippedTests"] == 0
            and measured["expectedFailures"] == 0 and measured["passedTests"] + measured["failedTests"] == 1,
            "Isolated execution must actually run exactly one test, not skip or retry it.")
    require(len(selected) == 1 and selected[0][0] == SELECTOR
            and selected[0][1] in ("Passed", "Failed"),
            "Hosted selector did not resolve to exactly the unchanged concurrency regression.")
    require((selected[0][1] == "Passed") == (measured["passedTests"] == 1),
            "Isolated case result and counts disagree.")
    return measured


def validate_remaining(summary, tests):
    measured = counts(summary)
    selected = cases(tests)
    excluded = [status for identity, status in selected if identity == SELECTOR]
    require(not excluded or excluded == ["Skipped"],
            "The isolated regression ran again in the loaded scope.")
    remaining = [(identity, status) for identity, status in selected if identity != SELECTOR]
    require(remaining and all(status in ("Passed", "Failed", "Expected Failure") for _, status in remaining),
            "Another integrated test was skipped or did not execute.")
    require(measured["skippedTests"] == len(excluded), "Unattributed skipped integrated tests.")
    require(any(status == "Failed" for _, status in remaining) == (measured["failedTests"] > 0),
            "Remaining case results and failure counts disagree.")
    return measured


def validate_arguments(command):
    require(command and Path(command[0]).name == "xcodebuild", "Expected the existing xcodebuild command.")
    restricted = ("-only-testing", "-skip-testing", "-only-test-configuration", "-skip-test-configuration",
                  "-test-iterations", "-retry-tests-on-failure", "-run-tests-until-failure",
                  "-resultBundlePath", "-testPlan", "-xctestrun")
    require(not any(arg == flag or arg.startswith(flag + ":") or arg.startswith(flag + "=")
                    for arg in command[1:] for flag in restricted),
            "Selection/repetition/result overrides would invalidate full-suite coverage; use a separate diagnostic invocation.")
    require(not any(arg in ("test", "test-without-building", "build-for-testing") for arg in command[1:]),
            "The harness owns the build/test actions.")


def read_result(bundle, directory, scope, runner):
    values = []
    for kind in ("summary", "tests"):
        try:
            result = runner(["xcrun", "xcresulttool", "get", "test-results", kind,
                             "--schema-version", SCHEMA, "--path", str(bundle), "--compact"],
                            check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as error:
            (directory / f"{scope}-{kind}.error").write_text(error.stderr or "")
            print(f"{scope} xcresult extraction failed: {(error.stderr or '')[:4096]}", file=sys.stderr)
            raise
        (directory / f"{scope}-{kind}.json").write_text(result.stdout)
        values.append(json.loads(result.stdout))
    return values


def run(command, directory, runner=subprocess.run):
    validate_arguments(command)
    directory.mkdir(parents=True, exist_ok=False)
    evidence = {"candidateSelector": SELECTOR, "selectorVerifiedByHostedResult": False,
                "testBodyOrDeadlineChanged": False, "wholeSuiteSerialized": False}
    evidence_path = directory / "coverage.json"

    def save():
        evidence_path.write_text(json.dumps(evidence, indent=2) + "\n")

    build = runner([*command, "build-for-testing"], check=False)
    evidence["buildExitCode"] = build.returncode
    save()
    if build.returncode:
        return build.returncode
    isolated_bundle = directory / "isolated.xcresult"
    isolated = runner([*command, "test-without-building", "-only-testing:" + SELECTOR,
                       "-resultBundlePath", str(isolated_bundle)], check=False)
    evidence["isolatedExitCode"] = isolated.returncode
    isolated_summary = None
    try:
        isolated_summary, tests = read_result(isolated_bundle, directory, "isolated", runner)
        print("Isolated hosted summary: " + json.dumps(isolated_summary), flush=True)
        print("Isolated hosted test tree: " + json.dumps(tests)[:16384], flush=True)
        evidence["isolatedCounts"] = validate_isolated(isolated_summary, tests)
        evidence["selectorVerifiedByHostedResult"] = True
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        evidence["isolatedValidationError"] = str(error)
    save()
    # Never exclude an unverified selector. Still run the full suite for coverage,
    # but fail this invocation even if that diagnostic fallback passes.
    scope = "remaining" if evidence["selectorVerifiedByHostedResult"] else "full-fallback"
    remaining_bundle = directory / (scope + ".xcresult")
    selection = ["-skip-testing:" + SELECTOR] if evidence["selectorVerifiedByHostedResult"] else []
    remaining = runner([*command, "test-without-building", *selection,
                        "-resultBundlePath", str(remaining_bundle)], check=False)
    evidence["remainingExitCode"] = remaining.returncode
    remaining_summary = None
    try:
        remaining_summary, tests = read_result(remaining_bundle, directory, scope, runner)
        print("Remaining hosted summary: " + json.dumps(remaining_summary), flush=True)
        evidence["remainingCounts"] = (validate_remaining(remaining_summary, tests)
                                       if selection else counts(remaining_summary))
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        evidence["remainingValidationError"] = str(error)
    success = (evidence["selectorVerifiedByHostedResult"] and not isolated.returncode and not remaining.returncode
               and "remainingValidationError" not in evidence
               and isolated_summary is not None and isolated_summary.get("result") == "Passed"
               and remaining_summary is not None and remaining_summary.get("result") == "Passed"
               and remaining_summary.get("failedTests") == 0)
    evidence["passed"] = success
    if evidence["selectorVerifiedByHostedResult"] and "remainingCounts" in evidence:
        evidence["combinedExecutedTestCount"] = (
            evidence["isolatedCounts"]["totalTestCount"]
            + evidence["remainingCounts"]["totalTestCount"]
            - evidence["remainingCounts"]["skippedTests"]
        )
    save()
    print("Integrated scope counts: " + json.dumps({
        key: evidence[key] for key in ("selectorVerifiedByHostedResult", "isolatedCounts", "remainingCounts",
                                       "combinedExecutedTestCount", "passed") if key in evidence
    }), flush=True)
    print(f"Integrated test coverage: {evidence_path}", flush=True)
    if not success:
        print("Integrated test scopes did not both pass with verified nonzero coverage; preserve both xcresults.", file=sys.stderr)
    return 0 if success else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results-root", required=True, type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    validate_arguments(command)
    args.results_root.mkdir(parents=True, exist_ok=True)
    # The runner owns only this new evidence directory; no stale xcresult can pass.
    directory = args.results_root / ("scopes-" + uuid.uuid4().hex)
    return run(command, directory)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"Integrated test scope validation failed: {error}", file=sys.stderr)
        sys.exit(1)
