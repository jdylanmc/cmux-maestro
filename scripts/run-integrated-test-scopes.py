#!/usr/bin/env python3
"""Required native scopes: blocking observer, real-XPC multiwindow suite, and their complement."""
import argparse
from collections import Counter
from contextlib import contextmanager
from dataclasses import dataclass
import json
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import stat
import subprocess
import shutil
import sys
import tempfile
import uuid
import zipfile
from typing import Optional
from urllib.parse import unquote, urlparse

sys.dont_write_bytecode = True
TARGET = "CMUXMaestroPreviewTests"
TEST = "CopilotSetupTests/concurrentSupervisionDoesNotOccupyCooperativeExecutor()"
SELECTOR = TARGET + "/" + TEST
MULTIWINDOW_SELECTOR = TARGET + "/SidebarMultiWindowTests"
MULTIWINDOW_TESTS = {
    MULTIWINDOW_SELECTOR + "/" + name for name in (
        "separateScenesKeepEachWindowsOwnHierarchyActionsAndLifetime()",
        "sharedSceneNeverShowsAnotherWindowsDataAndRecoversWhenOneWindowRemains()",
        "secondConnectionUnpairsBeforeItsFirstSnapshot()",
        "viewWithoutSceneShowsNoWindowData()",
        "rebindingToADifferentConnectionDropsThePreviousConnectionsFacts()",
        "beatLivenessIsKeptPerWindowAndPanelOpensOnlyWhereRequested()",
    )
}
BENCHMARK_SELECTOR = TARGET + "/CopilotReaderTests/coldStartBenchmarkWith230MiBOfIgnoredSyntheticPayloads()"
BENCHMARK_FLAG = "CMUX_MAESTRO_READER_BENCHMARK"
LOCAL_UI_FLAG = "CMUX_MAESTRO_LOCAL_UI_ACCEPTANCE"
LOCAL_UI_TESTS = {
    TARGET + "/" + identity: reason
    for identity, reason in json.loads(Path(__file__).with_name("local-ui-acceptance.json").read_text()).items()
}
SCHEMA = "0.1.0"
STATUSES = ("Passed", "Failed", "Skipped", "Expected Failure")
STRUCTURE = ("Device", "Test Plan Configuration")
DETAILS = ("Failure Message", "Source Code Reference", "Attachment", "Expression", "Test Value", "Runtime Warning")
DIAGNOSTIC_SCOPES = ("isolated", "multiwindow", "remaining", "full-fallback")
DIAGNOSTIC_EXPORT_SECONDS = 30
DIAGNOSTIC_MAX_BYTES = 64 * 1024 * 1024
DIAGNOSTIC_MAX_FILES = 256


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


def cases(document, *, expected_plan=None, expected_project=None):
    require(isinstance(document, dict), "Invalid xcresult test document.")
    require(isinstance(document.get("testNodes"), list), "Missing xcresult test tree.")
    if expected_plan is not None:
        require(len(document["testNodes"]) == 1
                and isinstance(document["testNodes"][0], dict)
                and document["testNodes"][0].get("nodeType") == "Test Plan"
                and document["testNodes"][0].get("name") == expected_plan,
                "Unexpected test plan.")
    result = []

    def visit(node, bundle=None, plan=None, bundle_path=None, ui_bundle=False):
        require(isinstance(node, dict), "Invalid xcresult test node.")
        if node.get("nodeType") == "Test Plan":
            require(isinstance(node.get("name"), str) and node["name"], "Missing test plan name.")
            plan = node["name"]
        if node.get("nodeType") in ("Unit test bundle", "UI test bundle"):
            require(isinstance(node.get("name"), str), "Invalid test bundle name.")
            bundle = node["name"].removesuffix(".xctest")
            ui_bundle = node["nodeType"] == "UI test bundle"
            project = expected_project if expected_project is not None else plan
            bundle_path = (project + "/" if project else "") + bundle
            require(expected_project is None or node.get("nodeIdentifierURL"),
                    "Missing test bundle project URL.")
            if node.get("nodeIdentifierURL"):
                require(identifier_path(node["nodeIdentifierURL"]) == bundle_path,
                        "Test bundle URL disagrees with its plan/target ancestry.")
        if node.get("nodeType") == "Test Case":
            identifier = node.get("nodeIdentifier")
            url = node.get("nodeIdentifierURL")
            require(bundle and bundle_path, "A test case has no attributable target.")
            require(expected_project is None or url, "Missing test case project URL.")
            strict_ui = expected_project is not None and ui_bundle
            if strict_ui:
                require(isinstance(identifier, str) and identifier,
                        "Missing UI test method identifier.")
                require(isinstance(node.get("name"), str) and node["name"],
                        "Missing UI test method name.")
            if url:
                path = identifier_path(url)
                require(path.startswith(bundle_path + "/"), "Test URL is outside its plan/target ancestry.")
                local = path[len(bundle_path) + 1:]
                if (ui_bundle and not local.endswith("()")
                        and node.get("name") == local.rsplit("/", 1)[-1] + "()"):
                    local += "()"
                if strict_ui:
                    require(node["name"] == local.rsplit("/", 1)[-1],
                            "UI test method name and URL disagree.")
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
            visit(child, bundle, plan, bundle_path, ui_bundle)

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


def validate_multiwindow(summary, tests):
    selected = cases(tests)
    measured = reconcile(summary, selected)
    require({case.identity for case in selected} == MULTIWINDOW_TESTS
            and all(not case.parameterized and case.executions == ((None, "Passed"),)
                    for case in selected),
            "Multiwindow scope must execute and pass every expected test exactly once, without skips or retries.")
    return measured


def verify_multiwindow_evidence(root, *, head, run_id):
    """Recheck the native job's exact-run artifacts in ci-gate, not just its success result."""
    require(isinstance(head, str) and re.fullmatch(r"[0-9a-f]{40}", head)
            and isinstance(run_id, str) and run_id.isdigit(), "Missing gate run identity.")
    receipts = list(root.glob("scopes-*/coverage.json"))
    require(len(receipts) == 1, "Expected exactly one native coverage invocation.")
    directory = receipts[0].parent
    evidence = json.loads(receipts[0].read_text())
    require(isinstance(evidence, dict), "Invalid native coverage receipt.")
    source = evidence.get("source", {})
    require(isinstance(source, dict) and evidence.get("runID") == run_id and source.get("status") == "available"
            and source.get("head") == head and source.get("dirty") is False,
            "Native coverage evidence does not match this clean run and commit.")
    require(evidence.get("passed") is True and type(evidence.get("multiwindowExitCode")) is int
            and evidence["multiwindowExitCode"] == 0
            and evidence.get("multiwindowVerified") is True,
            "Native multiwindow invocation did not pass.")
    summary = json.loads((directory / "multiwindow-summary.json").read_text())
    tests = json.loads((directory / "multiwindow-tests.json").read_text())
    measured = validate_multiwindow(summary, tests)
    require(measured == evidence.get("multiwindowCounts"), "Multiwindow coverage counts disagree.")
    inventory = enumerated_tests(json.loads((directory / "enumeration.json").read_text()))
    require(MULTIWINDOW_TESTS <= inventory, "Built inventory is missing required multiwindow tests.")
    return measured


def validate_remaining(summary, tests, *, benchmark_enabled, isolated_excluded=True, local_ui_enabled=False,
                       multiwindow_excluded=False):
    selected = cases(tests)
    measured = reconcile(summary, selected)
    excluded_identities = ({SELECTOR} if isolated_excluded else set()) | (
        MULTIWINDOW_TESTS if multiwindow_excluded else set())
    if benchmark_enabled:
        benchmark = [case for case in selected if case.identity == BENCHMARK_SELECTOR]
        require(len(benchmark) == 1 and benchmark[0].status == "Passed" and not benchmark[0].parameterized
                and benchmark[0].executions == ((None, "Passed"),),
                "Enabled reader benchmark must be present as exactly one nonparameterized passed execution.")
    require(all(case.status == "Skipped" for case in selected if case.identity in excluded_identities),
            "An isolated test ran again in the loaded scope.")
    attributed = []
    for case in selected:
        if not any(status == "Skipped" for _, status in case.executions):
            continue
        require(case.status == "Skipped" and not case.parameterized and len(case.executions) == 1,
                "A skipped parameter or repeated invocation cannot use a whole-test exclusion.")
        if case.identity == SELECTOR and isolated_excluded:
            reason = "verified-isolated-selector-exclusion"
        elif case.identity in MULTIWINDOW_TESTS and multiwindow_excluded:
            reason = "verified-multiwindow-scope-exclusion"
        elif case.identity == BENCHMARK_SELECTOR and not benchmark_enabled:
            reason = "existing-opt-in-benchmark-disabled"
        elif case.identity in LOCAL_UI_TESTS and not local_ui_enabled:
            reason = "opt-in-local-ui-acceptance"
        else:
            raise ValueError(f"Unattributed or enabled skipped integrated test: {case.identity}")
        attributed.append({"identity": case.identity, "policyReason": reason,
                           "allowlistReason": INTENTIONAL_SKIPS[case.identity],
                           "reportedDetails": case.reported_details})
    remaining = [case for case in selected if case.identity not in excluded_identities]
    require(any(status != "Skipped" for case in remaining for _, status in case.executions),
            "The remaining integrated scope has no executed tests.")
    require(measured["executionCounts"]["skippedTests"] == len(attributed), "Unattributed skipped integrated tests.")
    return {**measured, "skippedTestsByIdentity": attributed}


# Every test the build may legitimately report as not run, with why. Nothing else may be absent.
INTENTIONAL_SKIPS = {
    SELECTOR: "Runs alone in the isolated scope; skipped from the remaining scope.",
    **{identity: "Runs in the required multiwindow scope; skipped from the remaining scope."
       for identity in MULTIWINDOW_TESTS},
    BENCHMARK_SELECTOR: f"Opt-in reader benchmark; runs only when {BENCHMARK_FLAG}=1.",
    **LOCAL_UI_TESTS,
}


def enumerate_command(command, output):
    return [*command, "test-without-building", "-enumerate-tests", "-test-enumeration-format", "json",
            "-test-enumeration-style", "flat", "-test-enumeration-output-path", str(output)]


def enumerated_tests(document):
    """Enabled test identities the built product declares under the same build settings."""
    require(isinstance(document, dict) and document.get("errors") == [], "Test enumeration reported errors.")
    values = document.get("values")
    require(isinstance(values, list) and len(values) == 1 and isinstance(values[0], dict),
            "Expected one enumerated test plan.")

    def identities(key):
        entries = values[0].get(key)
        require(isinstance(entries, list) and all(isinstance(entry, dict) and isinstance(entry.get("identifier"), str)
                                                   for entry in entries), f"Invalid enumerated {key}.")
        return [entry["identifier"] for entry in entries]
    enabled, disabled = identities("enabledTests"), identities("disabledTests")
    require(enabled, "Test enumeration found no enabled tests.")
    require(len(set(enabled)) == len(enabled), "Repeated enumerated test identities.")
    unexplained = sorted(set(disabled) - set(INTENTIONAL_SKIPS))
    require(not unexplained, f"Disabled tests need an INTENTIONAL_SKIPS reason: {unexplained[:20]}")
    return set(enabled) | set(disabled)


def validate_inventory(expected, isolated, remaining, *, isolated_excluded, multiwindow=()):
    observed = Counter(case.identity for case in isolated)
    observed.update(case.identity for case in multiwindow)
    excluded = ({SELECTOR} if isolated_excluded else set()) | (
        MULTIWINDOW_TESTS if multiwindow else set())
    observed.update(case.identity for case in remaining if case.identity not in excluded)
    missing = sorted(set(expected) - set(observed))
    unexpected = sorted(set(observed) - set(expected))
    repeated = sorted(identity for identity, count in observed.items() if count > 1)
    require(not missing and not unexpected and not repeated,
            f"Reported tests disagree with the built test inventory; missing={missing[:20]} ({len(missing)}), "
            f"unexpected={unexpected[:20]} ({len(unexpected)}), repeated={repeated[:20]}.")
    return {"expectedTests": len(expected), "reportedTests": sum(observed.values())}


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


def diagnostic_source(runner=subprocess.run):
    """Only public Git object coordinates and a dirty Boolean, never environment or path dumps."""
    try:
        root = Path(__file__).resolve().parents[1]
        result = runner(
            ["git", "--no-replace-objects", "rev-parse", "HEAD", "HEAD^{tree}"],
            cwd=root, check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=5)
        head, tree = result.stdout.splitlines()
        commit = runner(["git", "--no-replace-objects", "cat-file", "commit", head], cwd=root, check=True,
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=5)
        headers = commit.stdout.split("\n\n", 1)[0].splitlines()
        parents = [line.removeprefix("parent ") for line in headers if line.startswith("parent ")]
        require(headers and headers[0] == "tree " + tree, "source-tree-mismatch")
        require(all(re.fullmatch(r"[0-9a-f]{40}", value) for value in [head, tree, *parents]),
                "invalid-source-coordinates")
        status = runner(["git", "--no-replace-objects", "status", "--porcelain", "--untracked-files=normal"],
                        cwd=root, check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=5)
        return {"status": "available", "head": head, "tree": tree,
                "parents": parents, "dirty": bool(status.stdout)}
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        return {"status": "unavailable", "reason": type(error).__name__}


@contextmanager
def diagnostic_directory(root, descriptor=None):
    if descriptor is None:
        require(root.is_dir() and not root.is_symlink(), "missing-or-linked-directory")
        descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    else:
        descriptor = os.dup(descriptor)
    try:
        yield descriptor
    finally:
        os.close(descriptor)


def diagnostic_open(root_descriptor, relative, flags):
    """Resolve every component beneath the pinned export root without following links."""
    require(not relative.is_absolute() and ".." not in relative.parts, "invalid-diagnostic-relative-path")
    parent = os.dup(root_descriptor)
    try:
        for component in relative.parts[:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = child
        if not relative.parts:
            return os.dup(parent)
        return os.open(relative.name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    finally:
        os.close(parent)


def diagnostic_identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def diagnostic_files(root, maximum_bytes, maximum_entries, *, root_descriptor=None):
    """Reject links/special files and oversized trees before exporting or publishing."""
    files = []
    total = entries = 0
    with diagnostic_directory(root, root_descriptor) as root_descriptor:
        pending = [(Path(), os.fstat(root_descriptor))]
        while pending:
            relative, expected = pending.pop()
            descriptor = diagnostic_open(root_descriptor, relative, os.O_RDONLY | os.O_DIRECTORY)
            try:
                actual = os.fstat(descriptor)
                require((actual.st_dev, actual.st_ino) == (expected.st_dev, expected.st_ino),
                        "diagnostic-directory-changed")
                with os.scandir(descriptor) as children:
                    for child in children:
                        entries += 1
                        require(entries <= maximum_entries, "entry-limit-exceeded")
                        info = child.stat(follow_symlinks=False)
                        path = relative / child.name
                        if stat.S_ISDIR(info.st_mode):
                            pending.append((path, info))
                        else:
                            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "linked-or-special-file")
                            total += info.st_size
                            require(total <= maximum_bytes, "byte-limit-exceeded")
                            files.append((root / path, info))
            finally:
                os.close(descriptor)
    require(files, "empty-diagnostic-data")
    return sorted(files)


def capture_failure_diagnostics(directory, scope, source, runner=subprocess.run):
    """One bounded export from an exact runner-created result; failure remains failure."""
    receipt = {"scope": scope, "invocation": directory.name, "source": source, "status": "unavailable",
               "limits": {"exportSeconds": DIAGNOSTIC_EXPORT_SECONDS,
                          "uncompressedBytes": DIAGNOSTIC_MAX_BYTES, "entries": DIAGNOSTIC_MAX_FILES}}
    try:
        require(scope in DIAGNOSTIC_SCOPES, "invalid-scope")
        require(not directory.is_symlink() and directory.resolve() == directory, "invalid-invocation-path")
        require(source.get("status") == "available" and source.get("dirty") is False,
                "clean-source-provenance-unavailable")
        require(diagnostic_source() == source, "source-provenance-changed")
        bundle = directory / (scope + ".xcresult")
        receipt["resultBundle"] = bundle.name
        # Raw bundles may include large attachments; only bounded diagnostics are published.
        diagnostic_files(bundle, 1024 * 1024 * 1024, 20_000)
        with tempfile.TemporaryDirectory(prefix="cmux-integrated-diagnostics-") as temporary:
            scratch = Path(temporary)
            exported = scratch / "exported"
            result = runner(
                ["xcrun", "xcresulttool", "export", "diagnostics", "--path", str(bundle),
                 "--output-path", str(exported)],
                check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=DIAGNOSTIC_EXPORT_SECONDS)
            receipt["exportExitCode"] = result.returncode
            require(result.returncode == 0, "diagnostic-export-failed")
            inventory = []
            archive = scratch / "diagnostics.zip"
            with diagnostic_directory(exported) as root_descriptor:
                files = diagnostic_files(exported, DIAGNOSTIC_MAX_BYTES, DIAGNOSTIC_MAX_FILES,
                                         root_descriptor=root_descriptor)
                with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
                    for path, expected in files:
                        relative = path.relative_to(exported)
                        with os.fdopen(diagnostic_open(root_descriptor, relative, os.O_RDONLY), "rb") as stream:
                            require(diagnostic_identity(os.fstat(stream.fileno())) == diagnostic_identity(expected),
                                    "diagnostic-file-changed")
                            data = stream.read(expected.st_size + 1)
                            require(diagnostic_identity(os.fstat(stream.fileno())) == diagnostic_identity(expected)
                                    and len(data) == expected.st_size, "diagnostic-file-changed")
                        name = relative.as_posix()
                        output.writestr(name, data)
                        inventory.append({"path": name, "bytes": expected.st_size,
                                          "sha256": hashlib.sha256(data).hexdigest()})
            require(archive.stat().st_size <= DIAGNOSTIC_MAX_BYTES + 1024 * 1024, "archive-limit-exceeded")
            require(diagnostic_source() == source, "source-provenance-changed")
            parent = directory / "failure-diagnostics"
            require(not parent.is_symlink(), "linked-diagnostic-destination")
            parent.mkdir(exist_ok=True)
            destination = parent / scope
            require(not destination.exists(), "diagnostic-destination-exists")
            # Each scope owns a distinct subdirectory; no pre-existing archive can masquerade as this capture.
            destination.mkdir()
            target = destination / (scope + ".zip")
            partial = destination / "archive.partial"
            shutil.copyfile(archive, partial)
            partial.replace(target)
            receipt.update(status="captured", archive=target.relative_to(directory).as_posix(),
                           archiveBytes=target.stat().st_size,
                           archiveSHA256=hashlib.sha256(target.read_bytes()).hexdigest(), files=inventory)
    except (ValueError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        receipt["status"] = "unavailable"
        receipt["reason"] = str(error) if isinstance(error, ValueError) else type(error).__name__
        print(f"Integrated {scope} diagnostics unavailable: {receipt['reason']}", file=sys.stderr)
    return receipt


def hosted_test_environment(inherited):
    environment = dict(inherited)
    for name in list(environment):
        if name.startswith(("CMUX_GUIDE_ACCEPTANCE_", "TEST_RUNNER_CMUX_GUIDE_ACCEPTANCE_")):
            environment.pop(name)
    for name in ("GITHUB_ACTIONS", "RUNNER_ENVIRONMENT"):
        environment.pop("TEST_RUNNER_" + name, None)
    environment.pop("TEST_RUNNER_" + LOCAL_UI_FLAG, None)
    if environment.get(LOCAL_UI_FLAG) == "1":
        require(environment.get("GITHUB_ACTIONS") != "true", "Local UI acceptance cannot run in required CI.")
        environment["TEST_RUNNER_" + LOCAL_UI_FLAG] = "1"
    if (environment.get("GITHUB_ACTIONS") == "true"
            and environment.get("RUNNER_ENVIRONMENT") == "github-hosted"):
        # xcodebuild(1) forwards these to test runners with TEST_RUNNER_ stripped.
        for name in ("GITHUB_ACTIONS", "RUNNER_ENVIRONMENT"):
            environment["TEST_RUNNER_" + name] = environment[name]
    return environment


def guide_module():
    path = Path(__file__).resolve().with_name("run-guide-ui-validation.py")
    spec = importlib.util.spec_from_file_location("integrated_guide_producer", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def produce_guide_acceptance(directory, runner):
    module = guide_module()
    invocation = directory.name.removeprefix("scopes-")
    output = directory / "guide-acceptance"
    code = module.run(False, output, acceptance=True, invocation=invocation, runner=runner)
    receipt = module.acceptance_evidence.load(output / "evidence.json")
    context = {"exitCode": code, "output": str(output), "invocation": invocation,
               "head": receipt.get("sourceHead"), "tree": receipt.get("sourceTree"),
               "environment": {}}
    if code:
        context["error"] = receipt.get("error") or "Native guide acceptance producer failed without a diagnostic."
    if not code:
        context["environment"] = {
            "CMUX_GUIDE_ACCEPTANCE_DIRECTORY": str(output),
            "CMUX_GUIDE_ACCEPTANCE_INVOCATION": invocation,
            "CMUX_GUIDE_ACCEPTANCE_HEAD": context["head"],
            "CMUX_GUIDE_ACCEPTANCE_TREE": context["tree"],
            **{"CMUX_GUIDE_ACCEPTANCE_" + case.upper() + "_SHA256":
               hashlib.sha256((output / (case + ".json")).read_bytes()).hexdigest()
               for case in module.acceptance_evidence.PRODUCERS},
        }
        # Only newly validated guide images enter the existing mandatory artifact.
        images = module.acceptance_evidence.validate_all(output, invocation, context["head"], context["tree"])
        destination = Path(__file__).resolve().parents[1] / ".build/layout-validation/offscreen"
        destination.mkdir(parents=True, exist_ok=True)
        for image in images:
            shutil.copyfile(output / "images" / image["name"], destination / image["name"])
    return context


def validate_original_guide_cases(tests):
    expected = set(guide_module().acceptance_evidence.ORIGINALS)
    observed = [case for case in cases(tests) if case.identity in expected]
    require({case.identity for case in observed} == expected and len(observed) == len(expected)
            and all(case.status == "Passed" and not case.parameterized
                    and case.executions == ((None, "Passed"),) for case in observed),
            "Both original guide validators and all three original controls must execute and pass once.")


def revalidate_guide_acceptance(context, runner):
    require(context["exitCode"] == 0, "Native guide acceptance producer failed.")
    module = guide_module()
    output = Path(context["output"])
    receipt = module.acceptance_evidence.load(output / "evidence.json")
    require(receipt["schemaVersion"] == module.metadata.GUIDE_RECEIPT_SCHEMA
            and receipt["nativeResult"] == "passed" and receipt["mode"] == "acceptance"
            and receipt["compileOnly"] is False and receipt["sourceDirty"] is False
            and receipt["productsAfter"] == receipt["products"],
            "Full fresh native acceptance receipt required.")
    root = Path(__file__).resolve().parents[1]
    for args, expected in ((["git", "rev-parse", "HEAD"], context["head"]),
                           (["git", "rev-parse", "HEAD^{tree}"], context["tree"]),
                           (["git", "status", "--porcelain"], "")):
        result = runner(args, cwd=root, check=True, capture_output=True, text=True)
        require(result.stdout.strip() == expected, "Integrated source changed after native production.")
    require({path: hashlib.sha256((root / path).read_bytes()).hexdigest()
             for path in receipt["sourceSHA256"]} == receipt["sourceSHA256"],
            "Integrated source inventory mutated.")
    require(module.metadata.verify_guide_ui_products(output / "derived/Build/Products/Debug") == receipt["products"],
            "Native producer products mutated during integrated validation.")
    for case in module.acceptance_evidence.PRODUCERS:
        require(hashlib.sha256((output / (case + ".json")).read_bytes()).hexdigest()
                == context["environment"]["CMUX_GUIDE_ACCEPTANCE_" + case.upper() + "_SHA256"],
                "Acceptance document mutated during original validation.")
    module.acceptance_evidence.validate_all(output, context["invocation"], context["head"], context["tree"])


def run(command, directory, runner=subprocess.run):
    validate_arguments(command)
    test_environment = hosted_test_environment(os.environ)
    directory.mkdir(parents=True, exist_ok=False)
    benchmark_flag = os.environ.get(BENCHMARK_FLAG)
    benchmark_enabled = benchmark_flag == "1"
    local_ui_enabled = test_environment.get(LOCAL_UI_FLAG) == "1"
    evidence = {"candidateSelector": SELECTOR, "selectorVerifiedByHostedResult": False,
                "testBodyOrDeadlineChanged": True, "wholeSuiteSerialized": False,
                "localUIAcceptance": {"enabled": local_ui_enabled, "tests": LOCAL_UI_TESTS},
                "guideCalibrationVenue": {
                    "GITHUB_ACTIONS": test_environment.get("GITHUB_ACTIONS"),
                    "RUNNER_ENVIRONMENT": test_environment.get("RUNNER_ENVIRONMENT"),
                    "forwarding": ("xcodebuild TEST_RUNNER_"
                                   if "TEST_RUNNER_GITHUB_ACTIONS" in test_environment else None),
                },
                "optionalBenchmark": {"identity": BENCHMARK_SELECTOR, "environmentVariable": BENCHMARK_FLAG,
                                      "environmentValue": benchmark_flag, "enabled": benchmark_enabled}}
    evidence_path = directory / "coverage.json"
    source = diagnostic_source()
    evidence.update(source=source, runID=os.environ.get("GITHUB_RUN_ID"))

    def save():
        evidence_path.write_text(json.dumps(evidence, indent=2) + "\n")

    build = runner([*command, "build-for-testing"], check=False)
    evidence["buildExitCode"] = build.returncode
    save()
    if build.returncode:
        return build.returncode
    inventory = None
    enumeration = directory / "enumeration.json"
    listed = runner(enumerate_command(command, enumeration), check=False, env=test_environment)
    try:
        require(listed.returncode == 0, "Test enumeration failed.")
        inventory = enumerated_tests(json.loads(enumeration.read_text()))
        evidence["enumeratedTests"] = len(inventory)
    except (ValueError, KeyError, TypeError, OSError) as error:
        evidence["inventoryError"] = str(error)
    save()
    try:
        guide = produce_guide_acceptance(directory, runner)
        evidence["guideAcceptance"] = guide
        for name, value in guide["environment"].items():
            test_environment["TEST_RUNNER_" + name] = value
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        guide = {"exitCode": 1, "environment": {}}
        evidence["guideAcceptanceError"] = str(error)
    if guide["exitCode"]:
        evidence["guideAcceptanceError"] = evidence.get("guideAcceptanceError") or guide.get("error") or \
            "Native guide acceptance producer failed without a diagnostic."
        evidence["blockedStage"] = "guide-acceptance"
        evidence["passed"] = False
        save()
        print("Native guide acceptance producer failed: " + evidence["guideAcceptanceError"], file=sys.stderr)
        print(f"Integrated test coverage: {evidence_path}", flush=True)
        return 1
    save()
    isolated_bundle = directory / "isolated.xcresult"
    isolated = runner([*command, "test-without-building", "-only-testing:" + SELECTOR,
                       "-resultBundlePath", str(isolated_bundle)], check=False, env=test_environment)
    evidence["isolatedExitCode"] = isolated.returncode
    isolated_summary = None
    isolated_cases = []
    try:
        isolated_summary, tests = read_result(isolated_bundle, directory, "isolated", runner)
        isolated_cases = cases(tests)
        print("Isolated hosted summary: " + json.dumps(isolated_summary), flush=True)
        print("Isolated hosted test tree: " + json.dumps(tests)[:16384], flush=True)
        evidence["isolatedCounts"] = validate_isolated(isolated_summary, tests)
        evidence["selectorVerifiedByHostedResult"] = True
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        evidence["isolatedValidationError"] = str(error)
    save()
    multiwindow_bundle = directory / "multiwindow.xcresult"
    multiwindow = runner([*command, "test-without-building", "-only-testing:" + MULTIWINDOW_SELECTOR,
                          "-resultBundlePath", str(multiwindow_bundle)], check=False, env=test_environment)
    evidence["multiwindowExitCode"] = multiwindow.returncode
    evidence["multiwindowVerified"] = False
    try:
        summary, tests = read_result(multiwindow_bundle, directory, "multiwindow", runner)
        evidence["multiwindowCounts"] = validate_multiwindow(summary, tests)
        multiwindow_cases = cases(tests)
        require(multiwindow.returncode == 0, "Multiwindow invocation failed.")
        evidence["multiwindowVerified"] = True
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        evidence["multiwindowValidationError"] = str(error)
        evidence["blockedStage"] = "multiwindow"
        evidence["passed"] = False
        evidence["failureDiagnostics"] = []
        save()
        failed_scopes = [("multiwindow", multiwindow.returncode)]
        if (isolated.returncode or "isolatedValidationError" in evidence or isolated_summary is None
                or isolated_summary.get("result") != "Passed"):
            failed_scopes.insert(0, ("isolated", isolated.returncode))
        for name, code in failed_scopes:
            receipt = capture_failure_diagnostics(directory, name, source, runner)
            receipt["testExitCode"] = code
            evidence["failureDiagnostics"].append(receipt)
            save()
        print(f"Required multiwindow scope failed: {error}", file=sys.stderr)
        return 1
    save()
    # Never exclude an unverified selector. Still run the full suite for coverage,
    # but fail this invocation even if that diagnostic fallback passes.
    scope = "remaining" if evidence["selectorVerifiedByHostedResult"] else "full-fallback"
    remaining_bundle = directory / (scope + ".xcresult")
    selection = ["-skip-testing:" + SELECTOR] if evidence["selectorVerifiedByHostedResult"] else []
    remaining = runner([*command, "test-without-building", *selection,
                        "-skip-testing:" + MULTIWINDOW_SELECTOR,
                        "-resultBundlePath", str(remaining_bundle)], check=False, env=test_environment)
    evidence["remainingExitCode"] = remaining.returncode
    remaining_summary = None
    try:
        remaining_summary, tests = read_result(remaining_bundle, directory, scope, runner)
        print("Remaining hosted summary: " + json.dumps(remaining_summary), flush=True)
        print("Remaining hosted test tree: " + json.dumps(tests), flush=True)
        evidence["remainingCounts"] = validate_remaining(
            remaining_summary, tests, benchmark_enabled=benchmark_enabled, isolated_excluded=bool(selection),
            local_ui_enabled=local_ui_enabled, multiwindow_excluded=True)
        validate_original_guide_cases(tests)
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        evidence["remainingValidationError"] = str(error)
    if inventory is not None and remaining_summary is not None:
        try:
            evidence["inventoryCoverage"] = validate_inventory(
                inventory, isolated_cases if selection else [], cases(tests), isolated_excluded=bool(selection),
                multiwindow=multiwindow_cases)
        except (ValueError, KeyError, TypeError) as error:
            evidence["inventoryError"] = str(error)
    try:
        revalidate_guide_acceptance(guide, runner)
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        evidence["guideAcceptanceError"] = str(error)
    success = ("guideAcceptanceError" not in evidence and guide["exitCode"] == 0
               and evidence["selectorVerifiedByHostedResult"] and not isolated.returncode and not remaining.returncode
               and "remainingValidationError" not in evidence
               and "inventoryCoverage" in evidence and "inventoryError" not in evidence
               and isolated_summary is not None and isolated_summary.get("result") == "Passed"
               and remaining_summary is not None and remaining_summary.get("result") == "Passed"
               and remaining_summary.get("failedTests") == 0)
    evidence["passed"] = success
    evidence["failureDiagnostics"] = []
    save()
    for name, code, summary, validation_error in (
        ("isolated", isolated.returncode, isolated_summary, "isolatedValidationError"),
        (scope, remaining.returncode, remaining_summary, "remainingValidationError"),
    ):
        if code or validation_error in evidence or summary is None or summary.get("result") != "Passed":
            evidence["failureDiagnostics"].append(
                {"scope": name, "status": "capture-incomplete", "testExitCode": code,
                 "invocation": directory.name, "source": source})
            save()
            receipt = capture_failure_diagnostics(directory, name, source, runner)
            receipt["testExitCode"] = code
            evidence["failureDiagnostics"][-1] = receipt
            save()
    if evidence["selectorVerifiedByHostedResult"] and "remainingCounts" in evidence:
        evidence["combinedExecutedTestCount"] = (
            evidence["isolatedCounts"]["executionCounts"]["totalTestCount"]
            + evidence["multiwindowCounts"]["executionCounts"]["totalTestCount"]
            + evidence["remainingCounts"]["executionCounts"]["totalTestCount"]
            - evidence["remainingCounts"]["executionCounts"]["skippedTests"]
        )
    save()
    print("Integrated scope counts: " + json.dumps({
        key: evidence[key] for key in ("selectorVerifiedByHostedResult", "isolatedCounts", "multiwindowCounts", "remainingCounts",
                                       "combinedExecutedTestCount", "inventoryCoverage", "inventoryError",
                                       "passed") if key in evidence
    }), flush=True)
    print(f"Integrated test coverage: {evidence_path}", flush=True)
    if not success:
        print("Integrated test scopes did not all pass with verified nonzero coverage; preserve their xcresults.", file=sys.stderr)
    return 0 if success else 1


def run_focused(command, directory, selectors, repeats, runner=subprocess.run):
    """Local diagnostic evidence, never the required full-suite coverage receipt."""
    require(os.environ.get("GITHUB_ACTIONS") != "true", "Focused diagnostics cannot replace required CI.")
    require(1 <= repeats <= 100, "Focused repeat count must be between 1 and 100.")
    require(selectors and all(re.fullmatch(r"[A-Za-z0-9_]+(?:/[A-Za-z0-9_():]+)?", item)
                              for item in selectors), "Expected suite or suite/test selectors.")
    directory.mkdir(parents=True, exist_ok=False)
    environment = hosted_test_environment(os.environ)
    source = diagnostic_source()
    build = runner([*command, "build-for-testing"], check=False)
    if build.returncode:
        return build.returncode
    receipts = []
    for index in range(repeats):
        scope = f"focused-{index + 1}"
        bundle = directory / (scope + ".xcresult")
        result = runner([*command, "test-without-building",
                         *["-only-testing:" + TARGET + "/" + item for item in selectors],
                         "-resultBundlePath", str(bundle)], check=False, env=environment)
        summary, tree = read_result(bundle, directory, scope, runner)
        selected = cases(tree)
        measured = reconcile(summary, selected)
        require(all(any(case.identity == TARGET + "/" + item
                        or case.identity.startswith(TARGET + "/" + item + "/") for case in selected)
                    for item in selectors), "Focused selector did not execute.")
        receipts.append({"scope": scope, "exitCode": result.returncode, "counts": measured})
        (directory / "focused.json").write_text(json.dumps({
            "requiredCoverage": False, "source": source, "selectors": selectors,
            "requestedRuns": repeats, "runs": receipts
        }, indent=2) + "\n")
        require(not result.returncode and measured["failedTests"] == 0
                and all(measured["executionCounts"][key] == 0
                        for key in ("failedTests", "skippedTests", "expectedFailures")),
                "Focused diagnostics failed or skipped a test; no retries.")
    print(f"Focused stability evidence: {directory}/focused.json", flush=True)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results-root", type=Path)
    parser.add_argument("--verify-multiwindow-evidence", type=Path, help="Recheck this CI run's downloaded native evidence.")
    parser.add_argument("--focused", help="Comma-separated suite/test selectors; local diagnostics only.")
    parser.add_argument("--repeat", type=int, default=1, help="Independent focused executions; stop on any failure.")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.verify_multiwindow_evidence is not None:
        require(not args.command and args.results_root is None and not args.focused and args.repeat == 1,
                "Evidence verification cannot run build/test actions.")
        measured = verify_multiwindow_evidence(
            args.verify_multiwindow_evidence, head=os.environ.get("GITHUB_SHA"), run_id=os.environ.get("GITHUB_RUN_ID"))
        print("Required multiwindow execution verified: " + json.dumps(measured), flush=True)
        return 0
    require(args.results_root is not None, "--results-root is required for test execution.")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    validate_arguments(command)
    args.results_root.mkdir(parents=True, exist_ok=True)
    # The runner owns only this new evidence directory; no stale xcresult can pass.
    directory = args.results_root.resolve() / ("scopes-" + str(uuid.uuid4()))
    if args.focused:
        return run_focused(command, directory, args.focused.split(","), args.repeat)
    require(args.repeat == 1, "--repeat requires --focused.")
    return run(command, directory)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"Integrated test scope validation failed: {error}", file=sys.stderr)
        sys.exit(1)
