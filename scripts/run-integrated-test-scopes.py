#!/usr/bin/env python3
"""Hosted-only partition: one blocking-observer regression, then its full complement."""
import argparse
from collections import Counter
from dataclasses import dataclass
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid
from typing import Optional
from urllib.parse import unquote, urlparse

TARGET = "CMUXMaestroPreviewTests"
TEST = "CopilotSetupTests/concurrentSupervisionDoesNotOccupyCooperativeExecutor()"
SELECTOR = TARGET + "/" + TEST
BENCHMARK_SELECTOR = TARGET + "/CopilotReaderTests/coldStartBenchmarkWith230MiBOfIgnoredSyntheticPayloads()"
BENCHMARK_FLAG = "CMUX_MAESTRO_READER_BENCHMARK"
SCHEMA = "0.1.0"
STATUSES = ("Passed", "Failed", "Skipped", "Expected Failure")
STRUCTURE = ("Device", "Test Plan Configuration")
DETAILS = ("Failure Message", "Source Code Reference", "Attachment", "Expression", "Test Value", "Runtime Warning")


@dataclass(frozen=True)
class Case:
    identity: str
    status: str
    executions: tuple
    parameterized: bool
    reported_details: Optional[str] = None


def require(condition, message):
    if not condition:
        raise ValueError(message)


def children(node):
    values = node.get("children", [])
    require(isinstance(values, list) and all(isinstance(child, dict) for child in values),
            "Invalid test children.")
    return values


def aggregate(statuses):
    require(statuses and all(status in STATUSES for status in statuses), "Missing execution status.")
    if "Failed" in statuses:
        return "Failed"
    if all(status == "Skipped" for status in statuses):
        return "Skipped"
    if all(status == "Expected Failure" for status in statuses):
        return "Expected Failure"
    return "Passed"


def execution_records(node):
    """Normalize one logical case without treating its aggregate as every run."""
    runs = []
    arguments = []

    def visit(child, argument=None):
        kind = child.get("nodeType")
        require(kind != "Repetition", "Repetition/retry evidence is not authorized.")
        if kind == "Arguments":
            require(argument is None, "Nested parameter groups have unverified execution semantics.")
            label = child.get("nodeIdentifier") or child.get("name")
            require(isinstance(label, str) and label and label not in arguments,
                    "Missing or repeated parameter identity.")
            arguments.append(label)
            before = len(runs)
            for nested in children(child):
                visit(nested, label)
            if len(runs) == before:
                require(child.get("result") in STATUSES, "Parameter group has no execution result.")
                runs.append((label, child["result"]))
            require(len(runs) == before + 1, "Parameter invocation has repeated or ambiguous runs.")
            if child.get("result") is not None:
                require(child["result"] == runs[-1][1], "Parameter and execution statuses disagree.")
        elif kind == "Test Case Run":
            require(child.get("result") in STATUSES, "Missing test-run result.")
            runs.append((argument, child["result"]))
            for nested in children(child):
                require(nested.get("nodeType") in DETAILS, "Unexpected nested execution inside a test run.")
                validate_details(nested)
        elif kind in STRUCTURE:
            before = len(runs)
            for nested in children(child):
                visit(nested, argument)
            require(len(runs) > before, "Execution container has no run evidence.")
            if child.get("result") is not None:
                require(child["result"] == aggregate([status for _, status in runs[before:]]),
                        "Container and execution statuses disagree.")
        elif kind in DETAILS:
            validate_details(child)
        else:
            raise ValueError(f"Unrecognized execution shape: {kind!r}")

    for child in children(node):
        visit(child)
    if not runs:
        require(not arguments and not any(child.get("nodeType") in STRUCTURE for child in children(node)),
                "Missing execution evidence.")
        runs.append((None, node["result"]))
    if arguments:
        require(all(argument is not None for argument, _ in runs)
                and {argument for argument, _ in runs} == set(arguments),
                "Mixed parameterized and unparameterized execution evidence.")
    else:
        require(len(runs) == 1, "A nonparameterized test has multiple executions.")
    require(node["result"] == aggregate([status for _, status in runs]),
            "Logical test and execution statuses disagree.")
    return tuple(runs), bool(arguments)


def validate_details(node):
    for child in children(node):
        require(child.get("nodeType") in DETAILS, "Execution evidence cannot hide in diagnostic nodes.")
        validate_details(child)


def identifier_path(value):
    require(isinstance(value, str), "Invalid test identifier URL.")
    parsed = urlparse(value)
    require(parsed.scheme == "test" and parsed.netloc == "com.apple.xcode"
            and not parsed.query and not parsed.fragment,
            "Unrecognized test identifier URL; preserve the result for inspection.")
    return unquote(parsed.path).strip("/")


def cases(document):
    require(isinstance(document, dict), "Invalid xcresult test document.")
    require(isinstance(document.get("testNodes"), list), "Missing xcresult test tree.")
    result = []

    def visit(node, bundle=None, plan=None, bundle_path=None):
        require(isinstance(node, dict), "Invalid xcresult test node.")
        if node.get("nodeType") == "Test Plan":
            require(isinstance(node.get("name"), str) and node["name"], "Missing test plan name.")
            plan = node["name"]
        if node.get("nodeType") in ("Unit test bundle", "UI test bundle"):
            require(isinstance(node.get("name"), str), "Invalid test bundle name.")
            bundle = node["name"].removesuffix(".xctest")
            bundle_path = (plan + "/" if plan else "") + bundle
            if node.get("nodeIdentifierURL"):
                require(identifier_path(node["nodeIdentifierURL"]) == bundle_path,
                        "Test bundle URL disagrees with its plan/target ancestry.")
        if node.get("nodeType") == "Test Case":
            identifier = node.get("nodeIdentifier")
            url = node.get("nodeIdentifierURL")
            require(bundle and bundle_path, "A test case has no attributable target.")
            if url:
                path = identifier_path(url)
                require(path.startswith(bundle_path + "/"), "Test URL is outside its plan/target ancestry.")
                local = path[len(bundle_path) + 1:]
                require(identifier is None or identifier in (local, bundle + "/" + local),
                        "Test identifier and URL disagree.")
                identity = bundle + "/" + local
            else:
                require(bundle and isinstance(identifier, str) and identifier,
                        "A test case has no attributable identifier.")
                identity = identifier if identifier.startswith(bundle + "/") else bundle + "/" + identifier
            require(node.get("result") in STATUSES, "Missing logical test result.")
            executions, parameterized = execution_records(node)
            details = node.get("details")
            require(details is None or isinstance(details, str), "Invalid reported test details.")
            result.append(Case(identity, node["result"], executions, parameterized, details))
            return
        require(node.get("nodeType") in ("Test Plan", "Unit test bundle", "UI test bundle", "Test Suite") + STRUCTURE,
                "Execution node appeared outside a logical test.")
        for child in children(node):
            visit(child, bundle, plan, bundle_path)

    for node in document["testNodes"]:
        visit(node)
    require(result, "No test cases were reported; zero tests is not success.")
    require(len({case.identity for case in result}) == len(result), "Repeated/ambiguous test identifiers.")
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


def tally(statuses):
    values = Counter(statuses)
    return {"totalTestCount": sum(values.values()), "passedTests": values["Passed"],
            "failedTests": values["Failed"], "skippedTests": values["Skipped"],
            "expectedFailures": values["Expected Failure"]}


def reconcile(summary, selected):
    measured = counts(summary)
    logical = tally([case.status for case in selected])
    executions = tally([status for case in selected for _, status in case.executions])
    require(measured == logical, "Summary logical counts/statuses disagree with the normalized test tree.")
    require(summary.get("result") == ("Failed" if logical["failedTests"] else "Passed"),
            "Summary overall result disagrees with the normalized test statuses.")
    devices = summary.get("devicesAndConfigurations")
    if devices is not None:
        require(isinstance(devices, list) and devices, "Missing device/configuration execution counts.")
        keys = ("passedTests", "failedTests", "skippedTests", "expectedFailures")
        require(all(isinstance(device, dict) and all(type(device.get(key)) is int and device[key] >= 0 for key in keys)
                    for device in devices), "Invalid device/configuration execution counts.")
        observed = {key: sum(device[key] for device in devices) for key in keys}
        observed["totalTestCount"] = sum(observed.values())
        require(observed == executions, "Device/configuration counts disagree with normalized executions.")
    else:
        require(logical == executions, "Parameterized execution counts require device/configuration evidence.")
    return {**measured, "countBasis": "logical-summary/execution-device-counts",
            "logicalCounts": logical, "executionCounts": executions}


def validate_isolated(summary, tests):
    selected = cases(tests)
    measured = reconcile(summary, selected)
    require(measured["totalTestCount"] == 1 and measured["skippedTests"] == 0
            and measured["expectedFailures"] == 0 and measured["passedTests"] + measured["failedTests"] == 1,
            "Isolated execution must actually run exactly one test, not skip or retry it.")
    require(len(selected) == 1 and selected[0].identity == SELECTOR
            and selected[0].status in ("Passed", "Failed")
            and not selected[0].parameterized and len(selected[0].executions) == 1,
            "Hosted selector did not resolve to exactly the unchanged concurrency regression.")
    require((selected[0].status == "Passed") == (measured["passedTests"] == 1),
            "Isolated case result and counts disagree.")
    return measured


def validate_remaining(summary, tests, *, benchmark_enabled, isolated_excluded=True):
    selected = cases(tests)
    measured = reconcile(summary, selected)
    if isolated_excluded:
        excluded = [case.status for case in selected if case.identity == SELECTOR]
        require(not excluded or excluded == ["Skipped"],
                "The isolated regression ran again in the loaded scope.")
    attributed = []
    for case in selected:
        if not any(status == "Skipped" for _, status in case.executions):
            continue
        require(case.status == "Skipped" and not case.parameterized and len(case.executions) == 1,
                "A skipped parameter or repeated invocation cannot use a whole-test exclusion.")
        if case.identity == SELECTOR and isolated_excluded:
            reason = "verified-isolated-selector-exclusion"
        elif case.identity == BENCHMARK_SELECTOR and not benchmark_enabled:
            reason = "existing-opt-in-benchmark-disabled"
        else:
            raise ValueError(f"Unattributed or enabled skipped integrated test: {case.identity}")
        attributed.append({"identity": case.identity, "policyReason": reason,
                           "reportedDetails": case.reported_details})
    remaining = [case for case in selected if not isolated_excluded or case.identity != SELECTOR]
    require(any(status != "Skipped" for case in remaining for _, status in case.executions),
            "The remaining integrated scope has no executed tests.")
    require(measured["executionCounts"]["skippedTests"] == len(attributed), "Unattributed skipped integrated tests.")
    return {**measured, "skippedTestsByIdentity": attributed}


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
    benchmark_flag = os.environ.get(BENCHMARK_FLAG)
    benchmark_enabled = benchmark_flag == "1"
    evidence = {"candidateSelector": SELECTOR, "selectorVerifiedByHostedResult": False,
                "testBodyOrDeadlineChanged": False, "wholeSuiteSerialized": False,
                "optionalBenchmark": {"identity": BENCHMARK_SELECTOR, "environmentVariable": BENCHMARK_FLAG,
                                      "environmentValue": benchmark_flag, "enabled": benchmark_enabled}}
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
        print("Remaining hosted test tree: " + json.dumps(tests), flush=True)
        evidence["remainingCounts"] = validate_remaining(
            remaining_summary, tests, benchmark_enabled=benchmark_enabled, isolated_excluded=bool(selection))
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
            evidence["isolatedCounts"]["executionCounts"]["totalTestCount"]
            + evidence["remainingCounts"]["executionCounts"]["totalTestCount"]
            - evidence["remainingCounts"]["executionCounts"]["skippedTests"]
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
