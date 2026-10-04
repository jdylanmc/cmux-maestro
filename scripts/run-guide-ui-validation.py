#!/usr/bin/env python3
"""Closed readiness/full-acceptance public UI consumers; no local presentation or retry."""

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
ACCEPTANCE_SPEC = importlib.util.spec_from_file_location("guide_acceptance", ROOT / "scripts/guide-acceptance-evidence.py")
acceptance_evidence = importlib.util.module_from_spec(ACCEPTANCE_SPEC)
ACCEPTANCE_SPEC.loader.exec_module(acceptance_evidence)


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


def run(compile_only, output, *, acceptance=False, invocation=None, runner=subprocess.run, environment=None):
    environment = dict(os.environ if environment is None else environment)
    build_env = build_environment(environment)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    evidence = {"schemaVersion": 1, "scheme": SCHEME, "compileOnly": compile_only,
                "mode": "acceptance" if acceptance else "readiness",
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
        if acceptance and not compile_only:
            metadata.require(not evidence["sourceDirty"], "Acceptance requires clean source, not a dirty-source receipt.")
            metadata.require(invocation is not None and str(uuid.UUID(invocation)) == invocation
                             and output.name == "guide-acceptance"
                             and output.parent.name == "scopes-" + invocation,
                             "Acceptance must belong to this fresh integrated invocation.")
            metadata.require(environment.get("GITHUB_SHA") == evidence["sourceHead"],
                             "Checkout differs from the actual workflow commit.")
            event = acceptance_evidence.load(Path(environment["GITHUB_EVENT_PATH"]))
            event_name = environment.get("GITHUB_EVENT_NAME")
            parents = command("source-parents", ["git", "show", "-s", "--format=%P", "HEAD"]).strip().split()
            if event_name == "push":
                metadata.require(event["after"] == evidence["sourceHead"], "Push candidate differs.")
                candidate = evidence["sourceHead"]
            elif event_name == "pull_request":
                request = event["pull_request"]
                candidate = request["head"]["sha"]
                metadata.require(parents == [request["base"]["sha"], candidate],
                                 "PR checkout is not the exact current base/candidate synthetic merge.")
            else:
                raise ValueError("Acceptance requires attributable push or pull_request source.")
            evidence["sourceAttribution"] = {"event": event_name, "workflowHead": environment["GITHUB_SHA"],
                                             "candidate": candidate, "checkoutParents": parents}
            evidence["invocation"] = invocation
            (output / "images").mkdir()
            for key, value in {
                "CMUX_GUIDE_ACCEPTANCE_DIRECTORY": str(output),
                "CMUX_GUIDE_ACCEPTANCE_INVOCATION": invocation,
                "CMUX_GUIDE_ACCEPTANCE_HEAD": evidence["sourceHead"],
                "CMUX_GUIDE_ACCEPTANCE_TREE": evidence["sourceTree"],
            }.items():
                forwarded["TEST_RUNNER_" + key] = value
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
            "scripts/guide-acceptance-evidence.py", "scripts/test-guide-ui-validation.py",
            "scripts/GuideAcceptanceParserMain.swift",
            "scripts/test-copilot-setup.sh", "scripts/test-build-metadata.py",
            "CMUXMaestroPreviewTests/CLIIntegrationGuideRenderingTests.swift",
            "CMUXMaestroPreviewTests/SidebarAppKitTestScope.swift",
            "scripts/test.sh", "scripts/write-guide-reference.py", "skills/maestro/SKILL.md",
            "CMUXMaestroPreview.xcodeproj/xcshareddata/xcschemes/CMUXMaestroPreview.xcscheme",
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
            *["-only-testing:" + identity.removesuffix("()") for identity in
              (acceptance_evidence.PRODUCERS.values() if acceptance else [TEST_IDENTITY])],
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
        expected = set(acceptance_evidence.PRODUCERS.values()) if acceptance else {TEST_IDENTITY}
        if acceptance:
            export_exits = {}
            for case, identity in acceptance_evidence.PRODUCERS.items():
                export = output / ("attachments-" + case)
                result = command("export-" + case, ["xcrun", "xcresulttool", "export", "attachments",
                                          "--schema-version", "0.4.0", "--path", str(output / "probe.xcresult"),
                                          "--output-path", str(export), "--test-id",
                                          acceptance_evidence.case_url(documents["tests"], identity,
                                                                       identifier_path=scopes.identifier_path)],
                        allow_failure=True)
                export_exits[case] = result.returncode
            metadata.require(all(code == 0 for code in export_exits.values()),
                             "Native attachment export failed: " + str(export_exits))
            for case in acceptance_evidence.PRODUCERS:
                acceptance_evidence.extract(output / ("attachments-" + case), case, output,
                                            identifier_path=scopes.identifier_path)
        metadata.require({case.identity for case in selected} == expected and len(selected) == len(expected)
                         and all(case.status == "Passed" and case.executions == ((None, "Passed"),)
                                 and not case.parameterized for case in selected),
                         "Expected exactly the selected native producer executions, all passed once.")
        metadata.require(execution.returncode == 0, "Public UI test command failed despite reported test result.")
        if acceptance:
            images = acceptance_evidence.validate_all(output, invocation, evidence["sourceHead"], evidence["sourceTree"])
            (output / "image-manifest.json").write_text(json.dumps(images, indent=2) + "\n")
            evidence["verifiedTestIdentities"] = sorted(expected)
        else:
            evidence["verifiedTestIdentity"] = TEST_IDENTITY
        evidence["nativeResult"] = "passed"
        return 0
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        if evidence["phases"] and evidence["phases"][-1]["state"] == "started":
            evidence["phases"][-1]["state"] = "failed"
        evidence["error"] = redact(str(error))
        if evidence["nativeResult"] == "started":
            evidence["nativeResult"] = "failed"
        print("Guide UI validation failed: " + redact(str(error)), file=sys.stderr)
        return 1
    finally:
        if "sourceSHA256" in evidence:
            try:
                after = {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
                         for path in evidence["sourceSHA256"]}
                evidence["sourceAfter"] = {
                    "head": command("source-head-after", ["git", "rev-parse", "HEAD"]).strip(),
                    "tree": command("source-tree-after", ["git", "rev-parse", "HEAD^{tree}"]).strip(),
                    "dirty": bool(command("source-status-after", ["git", "status", "--porcelain"]).strip()),
                    "sha256": after,
                }
                if acceptance and not compile_only:
                    products_after = metadata.verify_guide_ui_products(products)
                    evidence["productsAfter"] = products_after
                    metadata.require(evidence["sourceAfter"]["head"] == evidence["sourceHead"]
                                     and evidence["sourceAfter"]["tree"] == evidence["sourceTree"]
                                     and not evidence["sourceAfter"]["dirty"] and after == evidence["sourceSHA256"]
                                     and products_after == evidence["products"],
                                     "Acceptance source changed during execution.")
            except (ValueError, OSError, subprocess.CalledProcessError) as error:
                evidence["error"] = redact(str(error))
                evidence["nativeResult"] = "failed"
                save()
                return 1
        save()
        print("Guide UI evidence: " + str(output.relative_to(ROOT) if output.is_relative_to(ROOT) else output))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compile-only", action="store_true", help="Build both targets without launching tests or apps.")
    parser.add_argument("--acceptance", action="store_true", help="Select only the two full native acceptance producers.")
    arguments = parser.parse_args()
    invocation = str(uuid.uuid4())
    output = (ROOT / ".build/tests/scoped-results" / ("scopes-" + invocation) / "guide-acceptance"
              if arguments.acceptance else ROOT / ".build/guide-ui-validation" / ("run-" + uuid.uuid4().hex))
    return run(arguments.compile_only, output, acceptance=arguments.acceptance, invocation=invocation)


if __name__ == "__main__":
    sys.exit(main())
