#!/usr/bin/env python3
"""Non-GUI contracts for the additive guide consumer build and execution boundary."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import hashlib
import struct
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch
import uuid
import zlib
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("guide_probe", ROOT / "scripts/run-guide-ui-validation.py")
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)
metadata = probe.metadata
acceptance = probe.acceptance_evidence


class GuideAcceptanceParserTests(unittest.TestCase):
    """Deliberately fabricated parser inputs, never represented as native observations."""

    @classmethod
    def setUpClass(cls):
        cls.root = ROOT / ".build/guide-parser-contracts" / str(uuid.uuid4())
        cls.root.mkdir(parents=True)
        cls.binary = cls.root / "parser"
        result = subprocess.run([
            "xcrun", "swiftc", "-parse-as-library",
            str(ROOT / "CMUXMaestroPreviewTests/GuideAcceptanceEvidence.swift"),
            str(ROOT / "scripts/GuideAcceptanceParserMain.swift"), "-o", str(cls.binary),
        ], env={**os.environ, "DEVELOPER_DIR": probe.DEVELOPER}, capture_output=True, text=True)
        if result.returncode:
            raise AssertionError("Non-GUI evidence validator compilation failed:\n" + result.stderr)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.root)

    def setUp(self):
        self.directory = self.root / str(uuid.uuid4())
        (self.directory / "images").mkdir(parents=True)
        self.invocation = str(uuid.uuid4())
        self.head, self.tree = "a" * 40, "b" * 40
        self.documents = {case: self.document(case) for case in acceptance.PRODUCERS}
        self.persist()

    def tearDown(self):
        shutil.rmtree(self.directory)

    @staticmethod
    def rect(x=0, y=0, width=600, height=350):
        return dict(x=x, y=y, width=width, height=height)

    @classmethod
    def node(cls, identifier, *, label="", role="AXButton", enabled=True, y=150, value=None, hittable=None):
        return dict(identifier=identifier, label=label, title="", role=role, enabled=enabled, value=value,
                    frame=cls.rect(20, y, 180, 24), hittable=hittable)

    @staticmethod
    def png():
        def chunk(name, data):
            return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data))
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 600, 350, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress((b"\x00" + bytes(1800)) * 350)) + chunk(b"IEND", b""))

    def action(self, identifier, before, after, *, sink=None, pending=False):
        return dict(identifier=identifier, node=self.node(identifier, y=100),
                    viewport=self.rect(), returned=True, before=before, after=after,
                    sinkResult=sink, pendingRead=pending)

    def document(self, case):
        stages, cleanups = [], []
        scenarios = acceptance.SCENARIOS if case == "statuses" else ("recheck",)
        titles = {
            "missing": ("Missing", "No guide found at this location."),
            "unreadable": ("Unreadable", "Permission denied. Check access, then Re-check."),
            "different": ("Different from this build", "Content may be newer or customized; different does not mean outdated."),
            "matching": ("Matches this build", "Guide bytes match this build, not necessarily the latest upstream guide."),
            "reference-unavailable": ("Build reference unavailable.", "Guide content could not be compared. Nothing was changed."),
        }
        png = self.png()
        for scenario in scenarios:
            for appearance in acceptance.APPEARANCES:
                for index, phase in enumerate(acceptance.PHASES[case]):
                    checking = phase.endswith("-checking")
                    completed = phase.endswith("-completed")
                    status = (scenario if case == "statuses" else
                              ("unreadable" if phase.startswith("unreadable") else "matching")
                              if index > 1 else "missing")
                    calls = (2 if phase.startswith("unreadable") else 3) if case == "recheck" and index > 1 else 1
                    copies = (2 if phase == "copy-success" else 1) if phase.startswith("copy-") else 0
                    notice = ("Copied. Run the command in your terminal when ready." if copies == 2 else
                              "Could not copy the command. Select and copy the text above.")
                    nodes = [self.node("cli-integration-recheck", label="Re-check", enabled=not checking, hittable=True),
                             self.node("cli-integration-copy-command", value=notice if copies else "Not copied")]
                    if checking:
                        nodes.append(self.node("cli-integration-checking", role="text", label="Checking guide content..."))
                    elif status == "reference-unavailable":
                        nodes.append(self.node("cli-integration-reference-error", role="text", label=" ".join(titles[status])))
                    else:
                        for path in (".agents/skills/maestro/SKILL.md", ".copilot/skills/maestro/SKILL.md"):
                            nodes.append(self.node("cli-integration-status-" + path, role="text",
                                                   label=" ".join(titles[status]) + " ~/" + path))
                    if copies:
                        nodes.append(self.node("cli-integration-copy-feedback", role="text", label=notice))
                    actions = []
                    if index == 1:
                        actions = [self.action("guide-calibration-minimal-action", 0, 1)]
                    elif phase.startswith("copy-"):
                        actions = [self.action("cli-integration-copy-command", copies - 1, copies, sink=copies == 2)]
                    elif checking:
                        actions = [self.action("cli-integration-recheck", calls - 1, calls, pending=True)]
                    presentation = {
                        **{key: True for key in ("running", "active", "visible", "key", "unoccluded",
                                                "exactContentController", "exactContentView", "exactGuideParent",
                                                "exactMinimalParent", "exactGuideWindow", "exactMinimalWindow",
                                                "guideAppeared", "minimalAppeared")},
                        "policy": 0, "guideFrame": self.rect(), "minimalFrame": self.rect(0, 350, 600, 64),
                        "containerFrame": self.rect(0, 0, 600, 414), "fittingWidth": 600, "fittingHeight": 350,
                        "document": self.rect(0, 0, 600, 1000),
                        "clip": self.rect(0, 650 if case == "statuses" and index >= 2 else 0),
                        "flipped": True, "clipScreen": self.rect(), "minimalScreen": self.rect(0, 350, 600, 64),
                        "screenTop": 414, "windowNumber": len(cleanups) + 1,
                        "modelIdentity": f"parser-only-{scenario}-{appearance}", "appearance": appearance,
                    }
                    elapsed = len(stages) + 0.1
                    name = acceptance.image_name(case, scenario, appearance, phase)
                    image = None
                    if name:
                        (self.directory / "images" / name).write_bytes(png)
                        image = dict(name=name, sha256=hashlib.sha256(png).hexdigest(), bytes=len(png),
                                     pixelsWide=600, pixelsHigh=350, points=self.rect(), backingScale=1,
                                     capturedAt=elapsed)
                    controls = {
                        "omitted": self.node("guide-acceptance-oracle-action"),
                        "ignored": self.node("guide-acceptance-oracle-action"),
                        "omittedIsElement": True, "ignoredIsElement": False, "omittedInRawTree": True,
                        "ignoredInRawTree": True, "omittedReturned": True, "ignoredReturned": True,
                        "omittedPresses": 1, "ignoredPresses": 1, "exposedCountBefore": 0, "exposedCountAfter": 1,
                        "noOp": self.action("guide-acceptance-oracle-action", 0, 0), "noOpPresses": 1,
                        "noOpReaderCalls": 0, "noOpReaderPending": False, "noOpWaitInstalled": True,
                        "noOpWaitRemaining": False,
                    }
                    stages.append({
                        "host": dict(invocation=self.invocation, producer=acceptance.PRODUCERS[case],
                                     sourceHead=self.head, sourceTree=self.tree, scenario=scenario,
                                     appearance=appearance, stage=phase, elapsed=elapsed,
                                     presentation=presentation, copies=copies, minimalPresses=int(index > 0),
                                     readerCalls=calls, pendingRead=checking, checking=checking,
                                     observationInstalled=completed, observationFired=completed, actions=actions,
                                     recheck=self.node("cli-integration-recheck", enabled=not checking),
                                     controls=controls, image=image),
                        "consumer": dict(
                            windowIdentifier="guide-acceptance-window", windowTitle="Synthetic CLI guide host calibration",
                            windowFrame=self.rect(0, 0, 600, 414),
                            guide={**self.node("guide-validation-real-guide-root", role="AXScrollArea"),
                                   "frame": self.rect(0, 64)},
                            minimal=self.node("guide-validation-minimal-root", y=0),
                            guideNodes=nodes,
                            minimalNodes=[self.node("guide-calibration-minimal-action", y=20, hittable=True)],
                            controlNodes=[self.node("guide-acceptance-oracle-action", label="Exposed", y=20)],
                            complete=True, elapsed=elapsed + 0.1),
                    })
                cleanups.append(dict(scenario=scenario, appearance=appearance, originalPolicy=0, restoredPolicy=0,
                                     windowVisible=False, guideHasParent=False, minimalHasParent=False,
                                     readerPending=False, readerWaiting=False, elapsed=len(stages)))
        return dict(schemaVersion=1, invocation=self.invocation, producer=acceptance.PRODUCERS[case],
                    sourceHead=self.head, sourceTree=self.tree, elapsed=len(stages) + 2, stages=stages,
                    completion=dict(invocation=self.invocation, producer=acceptance.PRODUCERS[case],
                                    cleanups=cleanups, elapsed=len(stages) + 1))

    def persist(self):
        for case, document in self.documents.items():
            (self.directory / (case + ".json")).write_text(json.dumps(document))

    def swift(self, case):
        self.persist()
        return subprocess.run([str(self.binary), case, str(self.directory / (case + ".json")), self.invocation,
                               self.head, self.tree, str(self.directory / "images")], capture_output=True, text=True)

    def test_complete_mocked_matrix_passes_both_real_typed_validators_and_exact_48_image_gate(self):
        for case in self.documents:
            result = self.swift(case)
            self.assertEqual(result.returncode, 0, result.stderr)
        records = acceptance.validate_all(self.directory, self.invocation, self.head, self.tree)
        self.assertEqual(len(records), 48)
        self.assertEqual(len({item["sha256"] for item in records}), 1, "Legitimate equal hashes must be accepted.")

    def test_each_missing_or_duplicate_stage_fails_actual_swift_validator(self):
        for case, original in copy.deepcopy(self.documents).items():
            for index in range(len(original["stages"])):
                for operation in ("drop", "duplicate", "wrong"):
                    altered = copy.deepcopy(original)
                    if operation == "drop":
                        altered["stages"].pop(index)
                    elif operation == "duplicate":
                        altered["stages"].insert(index, copy.deepcopy(altered["stages"][index]))
                    else:
                        altered["stages"][index]["host"]["stage"] = "wrong-stage"
                    self.documents[case] = altered
                    with self.subTest(case=case, index=index, operation=operation):
                        self.assertNotEqual(self.swift(case).returncode, 0)
            self.documents[case] = original

    def test_actual_swift_validator_rejects_geometry_identity_action_state_and_lifetime_substitutions(self):
        mutations = [
            ("statuses", ["schemaVersion"], 2),
            ("statuses", ["sourceHead"], "c" * 40),
            ("statuses", ["producer"], acceptance.PRODUCERS["recheck"]),
            ("statuses", ["elapsed"], 180),
            ("statuses", ["stages", 1, "host", "presentation", "fittingWidth"], 599),
            ("statuses", ["stages", 1, "host", "presentation", "document", "width"], 602),
            ("statuses", ["stages", 2, "host", "presentation", "clip", "y"], 0),
            ("statuses", ["stages", 3, "host", "actions", 0, "returned"], False),
            ("statuses", ["stages", 3, "host", "actions", 0, "after"], 0),
            ("statuses", ["stages", 3, "host", "actions", 0, "sinkResult"], True),
            ("statuses", ["stages", 3, "host", "copies"], 0),
            ("statuses", ["stages", 3, "consumer", "guideNodes", 1, "value"], "wrong notice"),
            ("statuses", ["stages", 1, "consumer", "windowIdentifier"], "wrong-window"),
            ("statuses", ["stages", 1, "consumer", "complete"], False),
            ("statuses", ["stages", 1, "consumer", "guideNodes"], []),
            ("statuses", ["stages", 1, "consumer", "minimalNodes", 0, "hittable"], False),
            ("statuses", ["stages", 1, "host", "controls", "noOpWaitRemaining"], True),
            ("statuses", ["stages", 1, "host", "controls", "exposedCountBefore"], 1),
            ("statuses", ["stages", 1, "consumer", "controlNodes", 0, "label"], "Omitted"),
            ("statuses", ["stages", 1, "host", "image", "sha256"], "0" * 64),
            ("statuses", ["stages", 1, "host", "image", "name"], "cli-guide-missing-dark.png"),
            ("statuses", ["stages", 1, "consumer", "elapsed"], 181),
            ("statuses", ["completion", "cleanups", 0, "windowVisible"], True),
            ("recheck", ["stages", 2, "host", "pendingRead"], False),
            ("recheck", ["stages", 2, "host", "readerCalls"], 1),
            ("recheck", ["stages", 2, "consumer", "guideNodes", 0, "enabled"], True),
            ("recheck", ["stages", 3, "host", "observationFired"], False),
            ("recheck", ["stages", 4, "host", "presentation", "modelIdentity"], "replacement-model"),
        ]
        originals = copy.deepcopy(self.documents)
        for case, path, value in mutations:
            self.documents = copy.deepcopy(originals)
            target = self.documents[case]
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            with self.subTest(case=case, path=path):
                self.assertNotEqual(self.swift(case).returncode, 0)
        self.documents = originals
        stale = self.node("cli-integration-status-stale", role="text")
        self.documents["recheck"]["stages"][2]["consumer"]["guideNodes"].append(stale)
        self.assertNotEqual(self.swift("recheck").returncode, 0)

    def test_exact_image_set_rejects_each_missing_image_and_extra_stale_image(self):
        for image in list((self.directory / "images").iterdir()):
            data = image.read_bytes()
            image.unlink()
            with self.subTest(image=image.name), self.assertRaises((ValueError, FileNotFoundError)):
                acceptance.validate_all(self.directory, self.invocation, self.head, self.tree)
            image.write_bytes(data)
        (self.directory / "images/stale.png").write_bytes(self.png())
        with self.assertRaises(ValueError):
            acceptance.validate_all(self.directory, self.invocation, self.head, self.tree)

    def test_original_identity_gate_requires_both_validators_and_all_unchanged_controls(self):
        def tree(entries):
            return {"testNodes": [{"nodeType": "Unit test bundle", "name": "CMUXMaestroPreviewTests",
                                  "children": [{"nodeType": "Test Case", "nodeIdentifier": identity,
                                                "name": identity.rsplit("/", 1)[1], "result": status}
                                               for identity, status in entries]}]}
        entries = [(identity, "Passed") for identity in acceptance.ORIGINALS]
        probe.scopes.validate_original_guide_cases(tree(entries))
        for index in range(5):
            for status in ("Failed", "Skipped", "Expected Failure", None):
                altered = list(entries)
                if status is None:
                    altered.pop(index)
                else:
                    altered[index] = (altered[index][0], status)
                with self.subTest(index=index, status=status), self.assertRaises(ValueError):
                    probe.scopes.validate_original_guide_cases(tree(altered))


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
        self.plan = probe.SCHEME
        self.project_name = "CMUXMaestroPreview"
        self.bundle_name = metadata.GUIDE_TESTS
        self.url_identity = None
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
                bundle_url = "test://com.apple.xcode/" + self.project_name + "/" + self.bundle_name
                output = json.dumps({"testNodes": [{
                    "nodeType": "Test Plan", "name": self.plan, "children": [{
                    "nodeType": "UI test bundle", "name": self.bundle_name,
                    "nodeIdentifierURL": bundle_url, "children": [{
                        "nodeType": "Test Case", "nodeIdentifier": self.identity, "result": self.test_status,
                        "name": self.identity.split("/")[-1],
                        "nodeIdentifierURL": bundle_url + "/" + (self.url_identity or self.identity.removesuffix("()")),
                    }],
                    }],
                }]})
        return subprocess.CompletedProcess(command, code, stdout=output)

    def execute(self, compile_only=False, environment=None, *, acceptance_mode=False, invocation=None):
        if environment is None:
            environment = {"DEVELOPER_DIR": probe.DEVELOPER, "GITHUB_ACTIONS": "true",
                           "RUNNER_ENVIRONMENT": "github-hosted", "TEST_RUNNER_GITHUB_ACTIONS": "stale",
                           "TEST_RUNNER_RUNNER_ENVIRONMENT": "stale",
                           "TEST_RUNNER_CMUX_GUIDE_UI_HOST_PATH": "/not/the/host"}
        with patch("builtins.print"):
            result = probe.run(compile_only, self.directory, runner=self.runner, environment=environment,
                               acceptance=acceptance_mode, invocation=invocation)
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
        self.assertEqual([arg for arg in self.commands[native[0]] if arg.startswith("-only-testing:")],
                         ["-only-testing:" + probe.TEST_IDENTITY.removesuffix("()")])

    def test_acceptance_mocked_result_graph_and_dirty_mutated_source_fail_closed(self):
        base = self.directory
        invocation = str(uuid.uuid4())
        event = base / "event.json"
        base.mkdir(parents=True)
        event.write_text(json.dumps({"after": "a" * 40}))
        environment = {"DEVELOPER_DIR": probe.DEVELOPER, "GITHUB_ACTIONS": "true",
                       "RUNNER_ENVIRONMENT": "github-hosted", "GITHUB_SHA": "a" * 40,
                       "GITHUB_EVENT_NAME": "push", "GITHUB_EVENT_PATH": str(event),
                       "TEST_RUNNER_CMUX_GUIDE_ACCEPTANCE_INVOCATION": "stale"}
        original_runner = self.runner
        for fault in (None, "dirty-before", "dirty-after", "head-after", "missing-stage",
                      "extra-case", "native-exit", "compile-only", "PR-good", "PR-wrong-parent",
                      "attachment-duplicate", "attachment-wrong-url", "attachment-missing-stage",
                      "attachment-payload-drift", "attachment-wrong-config", "attachment-late"):
            self.directory = base / ("scopes-" + invocation) / "guide-acceptance"
            status_reads = 0
            head_reads = 0
            environment["GITHUB_EVENT_NAME"] = "pull_request" if fault in ("PR-good", "PR-wrong-parent") else "push"
            event.write_text(json.dumps({"pull_request": {"head": {"sha": "c" * 40}, "base": {"sha": "d" * 40}}}
                                       if environment["GITHUB_EVENT_NAME"] == "pull_request" else {"after": "a" * 40}))

            def runner(command, **kwargs):
                nonlocal status_reads, head_reads
                if command[:2] == ["git", "show"]:
                    return subprocess.CompletedProcess(command, 0,
                                                       stdout=("e" if fault == "PR-wrong-parent" else "d") * 40 + " " + "c" * 40)
                if command[:2] == ["git", "status"]:
                    status_reads += 1
                    return subprocess.CompletedProcess(command, 0, stdout=(
                        " M changed.swift" if fault == "dirty-before" or fault == "dirty-after" and status_reads > 1 else ""))
                if command == ["git", "rev-parse", "HEAD"]:
                    head_reads += 1
                    return subprocess.CompletedProcess(command, 0,
                                                       stdout=("c" if fault == "head-after" and head_reads > 1 else "a") * 40)
                if command[:4] == ["xcrun", "xcresulttool", "export", "attachments"]:
                    url = command[command.index("--test-id") + 1]
                    case = next(case for case, value in acceptance.PRODUCERS.items()
                                if url == "test://com.apple.xcode/CMUXMaestroPreview/" + value.removesuffix("()"))
                    identity = acceptance.PRODUCERS[case]
                    export = Path(command[command.index("--output-path") + 1])
                    export.mkdir(parents=True)
                    fixture = GuideAcceptanceParserTests()
                    fixture.directory = self.directory
                    fixture.head = fixture.tree = "a" * 40
                    fixture.invocation = invocation
                    value = fixture.document(case)
                    if fault == "missing-stage":
                        value["stages"].pop()
                    (export / "observed.json").write_text(json.dumps(value))
                    def attachment(name, filename, elapsed):
                        return dict(suggestedHumanReadableName=name + "_0_" + str(uuid.uuid4()) + ".json",
                                    exportedFileName=filename, isAssociatedWithFailure=False, timestamp=1000 + elapsed,
                                    configurationName="Test Scheme Action", deviceId="fixture-device", deviceName="Fixture")
                    attachments = [attachment("guide-acceptance-" + case, "observed.json", value["elapsed"])]
                    for ordinal, stage in enumerate(value["stages"]):
                        name = "stage-" + str(ordinal) + ".json"
                        (export / name).write_text(json.dumps(stage))
                        attachments.append(attachment("guide-stage-" + str(ordinal), name, stage["consumer"]["elapsed"]))
                    if fault == "attachment-duplicate":
                        attachments.append(copy.deepcopy(attachments[0]))
                    elif fault == "attachment-missing-stage":
                        attachments.pop()
                    elif fault == "attachment-payload-drift":
                        (export / "stage-0.json").write_text("{}")
                    elif fault == "attachment-wrong-config":
                        attachments[-1]["configurationName"] = "Other configuration"
                    elif fault == "attachment-late":
                        attachments[0]["timestamp"] += 181
                    (export / "manifest.json").write_text(json.dumps([{
                        "testIdentifier": identity.split("/", 1)[1],
                        "testIdentifierURL": "test://com.apple.xcode/CMUXMaestroPreview/"
                                             + ("Wrong/test" if fault == "attachment-wrong-url" else identity.removesuffix("()")),
                        "attachments": attachments
                    }]))
                    return subprocess.CompletedProcess(command, 0, stdout="")
                response = original_runner(command, **kwargs)
                if "test-without-building" in command:
                    response.returncode = 65 if fault == "native-exit" else 0
                if command[:4] == ["xcrun", "xcresulttool", "get", "test-results"]:
                    if command[4] == "summary":
                        response.stdout = json.dumps({"result": "Passed", "totalTestCount": 2, "passedTests": 2,
                                                      "failedTests": 0, "skippedTests": 0, "expectedFailures": 0})
                    else:
                        document = json.loads(response.stdout)
                        bundle = document["testNodes"][0]["children"][0]
                        template = bundle["children"][0]
                        bundle["children"] = []
                        for identity in acceptance.PRODUCERS.values():
                            local = identity.split("/", 1)[1]
                            bundle["children"].append({**template, "name": local.split("/")[-1],
                                                       "nodeIdentifier": local,
                                                       "nodeIdentifierURL": bundle["nodeIdentifierURL"] + "/" + local.removesuffix("()")})
                        if fault == "extra-case":
                            bundle["children"].append(template)
                        response.stdout = json.dumps(document)
                return response

            with self.subTest(fault=fault), patch.object(self, "runner", side_effect=runner):
                result, receipt = self.execute(fault == "compile-only", environment,
                                               acceptance_mode=True, invocation=invocation)
                self.assertEqual(result, 0 if fault in (None, "compile-only", "PR-good") else 1)
                if fault is None:
                    self.assertEqual(receipt["verifiedTestIdentities"], sorted(acceptance.PRODUCERS.values()))
                    native = next(i for i, command in enumerate(self.commands) if "test-without-building" in command)
                    self.assertEqual({arg for arg in self.commands[native] if arg.startswith("-only-testing:")},
                                     {"-only-testing:" + identity.removesuffix("()") for identity in acceptance.PRODUCERS.values()})
                    self.assertEqual(self.environments[native]["TEST_RUNNER_CMUX_GUIDE_ACCEPTANCE_INVOCATION"], invocation)
                if fault == "compile-only":
                    self.assertFalse(any("test-without-building" in command for command in self.commands))
            shutil.rmtree(self.directory)
            self.commands.clear()
            self.environments.clear()
        self.directory = base

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

    def test_plan_project_target_and_method_identity_remain_independent_guards(self):
        for key, value in (
            ("plan", "OtherPlan"), ("project_name", "OtherProject"),
            ("bundle_name", "OtherTarget"), ("url_identity", "OtherSuite/testWrong"),
            ("url_identity", self.identity.removesuffix("()") + "(value:)"),
        ):
            with self.subTest(key=key, value=value):
                original = getattr(self, key)
                setattr(self, key, value)
                result, evidence = self.execute()
                self.assertEqual(result, 1)
                self.assertEqual(evidence["nativeResult"], "failed")
                setattr(self, key, original)
                shutil.rmtree(self.directory)

    def test_explicit_project_requires_attributable_urls_and_exact_plan(self):
        document = json.loads(self.runner(["xcrun", "xcresulttool", "get", "test-results", "tests"],
                                          env={}).stdout)
        selected = probe.scopes.cases(document, expected_plan=probe.SCHEME,
                                      expected_project="CMUXMaestroPreview")
        self.assertEqual([case.identity for case in selected], [probe.TEST_IDENTITY])
        for mutation in ("bundle-url", "case-url", "method-name", "duplicate-plan", "invalid-plan"):
            altered = copy.deepcopy(document)
            bundle = altered["testNodes"][0]["children"][0]
            case = bundle["children"][0]
            if mutation == "bundle-url":
                del bundle["nodeIdentifierURL"]
            elif mutation == "case-url":
                del case["nodeIdentifierURL"]
            elif mutation == "method-name":
                case["name"] = "otherMethod()"
            elif mutation == "duplicate-plan":
                altered["testNodes"].append(copy.deepcopy(altered["testNodes"][0]))
            else:
                altered["testNodes"] = ["invalid"]
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                probe.scopes.cases(altered, expected_plan=probe.SCHEME,
                                   expected_project="CMUXMaestroPreview")

    def test_both_ui_url_spellings_require_matching_method_metadata(self):
        for spelling in (None, self.identity):
            with self.subTest(spelling=spelling):
                self.url_identity = spelling
                result, evidence = self.execute()
                self.assertEqual(result, 0)
                self.assertEqual(evidence["verifiedTestIdentity"], probe.TEST_IDENTITY)
                shutil.rmtree(self.directory)

    def test_strict_ui_wrapper_rejects_missing_or_contradictory_method_metadata(self):
        original_runner = self.runner
        for spelling in (None, self.identity):
            self.url_identity = spelling
            for field in ("nodeIdentifier", "name"):
                for value in (None, "", 123, "Wrong()", "omit-field"):
                    def altered_runner(command, **kwargs):
                        response = original_runner(command, **kwargs)
                        if command[0] == "xcrun" and command[4] == "tests":
                            document = json.loads(response.stdout)
                            case = document["testNodes"][0]["children"][0]["children"][0]
                            if value == "omit-field":
                                del case[field]
                            else:
                                case[field] = value
                            response.stdout = json.dumps(document)
                        return response

                    with self.subTest(spelling=spelling, field=field, value=value):
                        try:
                            with patch.object(self, "runner", side_effect=altered_runner):
                                result, evidence = self.execute()
                            self.assertEqual(result, 1)
                            self.assertEqual(evidence["nativeResult"], "failed")
                            self.assertNotIn("verifiedTestIdentity", evidence)
                        finally:
                            if self.directory.exists():
                                shutil.rmtree(self.directory)

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
