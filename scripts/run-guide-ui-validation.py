#!/usr/bin/env python3
"""One additive public UI consumer probe; no local presentation or retry."""

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
SCHEME = "CMUXMaestroGuideUIValidation"
DEVELOPER = "/Applications/Xcode.app/Contents/Developer"
SPEC = importlib.util.spec_from_file_location("metadata", ROOT / "scripts/verify-build-metadata.py")
metadata = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(metadata)
SCOPE_SPEC = importlib.util.spec_from_file_location("integrated_scopes", ROOT / "scripts/run-integrated-test-scopes.py")
scopes = importlib.util.module_from_spec(SCOPE_SPEC)
SCOPE_SPEC.loader.exec_module(scopes)
TEST_IDENTITY = "CMUXMaestroGuideUITests/GuideConsumerReadinessTests/testMinimalEventThenRealGuideIdentifiers()"


def build_environment(environment):
    return {key: environment[key] for key in ("PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "LANG", "LC_ALL")
            if key in environment}


def test_environment(environment, host):
    metadata.require(environment.get("GITHUB_ACTIONS") == "true"
                     and environment.get("RUNNER_ENVIRONMENT") == "github-hosted",
                     "UI execution refused: requires original GitHub-hosted CI venue.")
    result = build_environment(environment)
    for key in ("GITHUB_ACTIONS", "RUNNER_ENVIRONMENT"):
        result[key] = environment[key]
        result["TEST_RUNNER_" + key] = environment[key]
    result["TEST_RUNNER_CMUX_GUIDE_UI_HOST_PATH"] = str(host)
    return result


def run(compile_only, output, *, runner=subprocess.run, environment=None):
    environment = dict(os.environ if environment is None else environment)
    build_env = build_environment(environment)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    evidence = {"schemaVersion": 1, "scheme": SCHEME, "compileOnly": compile_only,
                "phases": [], "nativeResult": "not-run",
                "limits": "180s shared explicit-wait deadline; synchronous XCUI calls are not preemptible. "
                          "No custom watchdog, retries, permission changes or prompt responses."}
    derived = output / "derived"
    products = derived / "Build/Products/Debug"
    host = products / (metadata.GUIDE_HOST + ".app")

    def redact(text):
        for path, replacement in ((str(ROOT), "<checkout>"), (str(output), "<evidence>"),
                                  (environment.get("HOME", ""), "<home>")):
            if path:
                text = text.replace(path, replacement)
        return text

    def command(phase, arguments, env=build_env, *, allow_failure=False):
        evidence["phases"].append({"name": phase, "state": "started"})
        save()
        result = runner(arguments, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE)
        (output / (phase + ".log")).write_text(redact(result.stdout or ""))
        if result.stderr:
            (output / (phase + "-stderr.log")).write_text(redact(result.stderr))
        evidence["phases"][-1].update(state="passed" if result.returncode == 0 else "failed",
                                     exitCode=result.returncode)
        save()
        if result.returncode and not allow_failure:
            raise subprocess.CalledProcessError(result.returncode, arguments)
        return result if allow_failure else result.stdout

    def save():
        (output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")

    def check(phase, function, value):
        evidence["phases"].append({"name": phase, "state": "started"})
        save()
        result = function(value)
        evidence["phases"][-1]["state"] = "passed"
        save()
        return result

    try:
        save()
        metadata.require(environment.get("DEVELOPER_DIR") == DEVELOPER, "Full Xcode environment required.")
        if not compile_only:
            forwarded = test_environment(environment, host)
            evidence["venue"] = {key: environment[key] for key in ("GITHUB_ACTIONS", "RUNNER_ENVIRONMENT")}
        evidence["sourceHead"] = command("source-head", ["git", "rev-parse", "HEAD"]).strip()
        evidence["sourceTree"] = command("source-tree", ["git", "rev-parse", "HEAD^{tree}"]).strip()
        evidence["sourceDirty"] = bool(command("source-status", ["git", "status", "--porcelain"]).strip())
        project = json.loads(command("project-membership", [
            "/usr/bin/plutil", "-convert", "json", "-o", "-",
            str(ROOT / "CMUXMaestroPreview.xcodeproj/project.pbxproj")
        ]))
        inventory = check("source-membership-check", metadata.verify_guide_ui_project, project)
        paths = sorted({path for sources in inventory.values() for path in sources} | {
            "CMUXMaestroPreview.xcodeproj/project.pbxproj",
            "CMUXMaestroPreview.xcodeproj/xcshareddata/xcschemes/" + SCHEME + ".xcscheme",
            "CMUXMaestroGuideUIHost/GuideUIValidation.xcconfig",
            "scripts/run-guide-ui-validation.py", "scripts/test-guide-ui-validation.sh",
            "scripts/verify-build-metadata.py", "scripts/run-integrated-test-scopes.py",
            ".github/workflows/ci.yml",
        })
        evidence["sourceInventory"] = inventory
        evidence["sourceSHA256"] = {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in paths}
        command("xcode-version", ["xcodebuild", "-version"])
        build = ["xcodebuild", "-project", str(ROOT / "CMUXMaestroPreview.xcodeproj"),
                 "-scheme", SCHEME, "-configuration", "Debug", "-destination", "platform=macOS",
                 "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"]
        settings = json.loads(command("resolved-settings", build + ["build-for-testing", "-showBuildSettings", "-json"]))
        check("settings-policy-check", metadata.verify_guide_ui_settings, settings)
        command("build-for-testing", build + ["build-for-testing"])
        evidence["products"] = check("built-product-check", metadata.verify_guide_ui_products, products)
        evidence["productCheck"] = "passed"
        save()
        if compile_only:
            return 0
        evidence["nativeResult"] = "started"
        save()
        execution = command("test-without-building", build + [
            "test-without-building", "-resultBundlePath", str(output / "probe.xcresult"),
            "-parallel-testing-enabled", "NO",
        ], env=forwarded, allow_failure=True)
        documents = {}
        for kind in ("summary", "tests"):
            documents[kind] = json.loads(command("result-" + kind, [
                "xcrun", "xcresulttool", "get", "test-results", kind,
                "--path", str(output / "probe.xcresult"), "--compact",
            ]))
        selected = scopes.cases(documents["tests"], expected_plan=SCHEME,
                                expected_project="CMUXMaestroPreview")
        scopes.reconcile(documents["summary"], selected)
        metadata.require(len(selected) == 1 and selected[0].identity == TEST_IDENTITY
                         and selected[0].status == "Passed" and selected[0].executions == ((None, "Passed"),)
                         and not selected[0].parameterized, "Expected exactly one passing public UI probe execution.")
        metadata.require(execution.returncode == 0, "Public UI test command failed despite reported test result.")
        evidence["verifiedTestIdentity"] = TEST_IDENTITY
        evidence["nativeResult"] = "passed"
        return 0
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        if evidence["phases"] and evidence["phases"][-1]["state"] == "started":
            evidence["phases"][-1]["state"] = "failed"
        evidence["error"] = redact(str(error))
        if evidence["nativeResult"] == "started":
            evidence["nativeResult"] = "failed"
        print("Guide UI validation failed: " + redact(str(error)), file=sys.stderr)
        return 1
    finally:
        save()
        print("Guide UI evidence: " + str(output.relative_to(ROOT) if output.is_relative_to(ROOT) else output))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compile-only", action="store_true", help="Build both targets without launching tests or apps.")
    arguments = parser.parse_args()
    return run(arguments.compile_only, ROOT / ".build/guide-ui-validation" / ("run-" + uuid.uuid4().hex))


if __name__ == "__main__":
    sys.exit(main())
