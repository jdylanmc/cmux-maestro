#!/usr/bin/env python3
"""Check validation namespaces and the explicit native publication boundary."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

BASE_ID = "com.jdylanmc.CMUXMaestroPreview"
APP_BUILD_VERSION = "2"
PRODUCTION_POINT = "com.cmuxterm.app.cmux.sidebar"
PROFILES = {
    "production": ("", PRODUCTION_POINT),
    "unsigned": (".Validation.Unsigned", BASE_ID + ".validation.unsigned.sidebar"),
    "tests": (".Validation.Tests", BASE_ID + ".validation.tests.sidebar"),
}
ROW_INPUT_TARGETS = {
    "CMUXMaestroRowInputFixture": BASE_ID + ".Validation.RowInputFixture",
    "CMUXMaestroRowInputUITests": BASE_ID + ".Validation.RowInputUITests",
}
ORCHESTRATION_READ_PATH = "/Library/Application Support/CMUXMaestroPreview/Orchestration/observer/"
READ_PATHS = [
    "/Library/Application Support/CMUXMaestroPreview/Copilot/",
    ORCHESTRATION_READ_PATH,
    "/.copilot/session-state/",
]
SANDBOX_KEY = "com.apple.security.app-sandbox"
READ_KEY = "com.apple.security.temporary-exception.files.home-relative-path.read-only"
GUIDE_HOST = "CMUXMaestroGuideUIHost"
GUIDE_TESTS = "CMUXMaestroGuideUITests"
GUIDE_RECEIPT_SCHEMA = 2
GUIDE_SHARED_SOURCES = [
    "CMUXMaestroPreview/Integration/CLIIntegrationGuide.swift",
    "CMUXMaestroPreview/Integration/CLIIntegrationSettingsView.swift",
    "CMUXMaestroPreview/Integration/CLIIntegrationGuideModel.swift",
    "CMUXMaestroPreview/Integration/CLIIntegrationGuideReader.swift",
    "CMUXMaestroPreview/CopilotShared/CopilotIdentityRecord.swift",
    "CMUXMaestroPreview/CopilotShared/CopilotFileAccess.swift",
]
GUIDE_HOST_SOURCES = [
    "CMUXMaestroGuideUIHost/GuideValidationApp.swift",
    "CMUXMaestroGuideUIHost/GuideValidationContent.swift",
    "CMUXMaestroGuideUIHost/GuideAcceptanceFixture.swift",
    "CMUXMaestroPreviewTests/GuideAcceptanceEvidence.swift",
] + GUIDE_SHARED_SOURCES
GUIDE_TEST_SOURCES = [
    "CMUXMaestroGuideUITests/GuideConsumerReadinessTests.swift",
    "CMUXMaestroGuideUITests/GuideAcceptanceTests.swift",
    "CMUXMaestroPreviewTests/GuideAcceptanceEvidence.swift",
]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def plist(path):
    with Path(path).open("rb") as stream:
        return plistlib.load(stream)


def verify_profile(profile):
    require(profile.get(SANDBOX_KEY) is True, "Sidebar must have effective App Sandbox.")
    require(profile.get(READ_KEY) == READ_PATHS, "Sidebar read-only grants differ from the approved prefixes.")
    require(set(profile) <= {SANDBOX_KEY, READ_KEY, "com.apple.security.get-task-allow"},
            "Unexpected sidebar entitlement.")


def verify_settings(rows, mode):
    suffix, point = PROFILES[mode]
    targets = {row["target"]: row["buildSettings"] for row in rows}
    for name, ending in [
        ("CMUXMaestroPreview", ""),
        ("CMUXMaestroSidebar", ".Extension"),
        ("CMUXMaestroCopilotHook", ".CopilotHook"),
        ("CMUXMaestroPreviewTests", ".Tests"),
    ]:
        require(name in targets, "Missing resolved target settings.")
        settings = targets[name]
        require(settings.get("PRODUCT_BUNDLE_IDENTIFIER") == BASE_ID + suffix + ending,
                "Resolved target bundle identifier is outside its build namespace.")
        if name == "CMUXMaestroCopilotHook":
            require(settings.get("OTHER_CODE_SIGN_FLAGS") == "--identifier " + BASE_ID + suffix + ending,
                    "Identity helper signing must override its linker-generated identifier.")
        if name in ("CMUXMaestroPreview", "CMUXMaestroSidebar"):
            require(settings.get("CMUX_SIDEBAR_EXTENSION_POINT_ID") == point,
                    "Resolved extension point is outside its build namespace.")
        if name == "CMUXMaestroPreview":
            conditions = settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "")
            require(isinstance(conditions, (str, list)), "Invalid compilation conditions.")
            conditions = conditions.split() if isinstance(conditions, str) else conditions
            require(("CMUX_VALIDATION" in conditions) == (mode != "production"),
                    "Validation must use the no-window app scene; production must retain its setup scene.")
        expected_sandbox = "YES" if name == "CMUXMaestroSidebar" else "NO"
        if name != "CMUXMaestroPreviewTests":
            require(settings.get("ENABLE_APP_SANDBOX") == expected_sandbox,
                    "Resolved App Sandbox setting changed.")
            require(settings.get("CURRENT_PROJECT_VERSION") == APP_BUILD_VERSION,
                    "Resolved native feature build version is stale.")
        if mode == "production":
            require(settings.get("CODE_SIGN_IDENTITY") == "-", "Publication requires the explicit ad-hoc identity.")
            require(settings.get("CODE_SIGNING_ALLOWED") == "YES", "Publication signing is disabled.")
        else:
            require(settings.get("CODE_SIGNING_ALLOWED") == "NO", "Validation unexpectedly enables signing.")


def verify_guide_ui_project(project):
    objects = project["objects"]
    targets = {value["name"]: (key, value) for key, value in objects.items()
               if value.get("isa") == "PBXNativeTarget"}
    host_id, host = targets[GUIDE_HOST]
    tests_id, tests = targets[GUIDE_TESTS]
    inventory = {}
    for name, target, expected, product in (
        (GUIDE_HOST, host, GUIDE_HOST_SOURCES, "application"),
        (GUIDE_TESTS, tests, GUIDE_TEST_SOURCES, "bundle.ui-testing"),
    ):
        require(target["productType"] == "com.apple.product-type." + product, "Wrong guide product type.")
        require(not target.get("fileSystemSynchronizedGroups"), "Guide validation sources must be explicit.")
        require(not target.get("packageProductDependencies"), "Guide validation must not depend on runtime packages.")
        sources = []
        kinds = []
        for phase_id in target["buildPhases"]:
            phase = objects[phase_id]
            kinds.append(phase["isa"])
            require(phase["isa"] in ("PBXSourcesBuildPhase", "PBXFrameworksBuildPhase"),
                    "Guide validation must not embed runtime or execute build scripts.")
            if phase["isa"] == "PBXSourcesBuildPhase":
                for build_id in phase["files"]:
                    reference = objects[objects[build_id]["fileRef"]]
                    require(reference["sourceTree"] == "SOURCE_ROOT", "Guide source must use exact source-root path.")
                    sources.append(reference["path"])
            else:
                require(not phase["files"], "Guide frameworks must use only SDK autolinking.")
        require(sorted(kinds) == ["PBXFrameworksBuildPhase", "PBXSourcesBuildPhase"], "Unexpected guide phases.")
        require(sorted(sources) == sorted(expected), "Guide single-source membership differs.")
        inventory[name] = sorted(sources)
    require(not host["dependencies"], "Guide host must not launch/build production dependencies.")
    require([objects[key]["target"] for key in tests["dependencies"]] == [host_id],
            "UI consumer must depend only on the synthetic host.")
    attributes = objects[project["rootObject"]]["attributes"]["TargetAttributes"]
    require(attributes[tests_id]["TestTargetID"] == host_id, "UI test target association differs.")
    for name, (_, target) in targets.items():
        if name not in (GUIDE_HOST, GUIDE_TESTS):
            require(not any(objects[key]["target"] in (host_id, tests_id) for key in target["dependencies"]),
                    "Production target must not depend on UI validation.")
    app = targets["CMUXMaestroPreview"][1]
    roots = [objects[key] for key in app["fileSystemSynchronizedGroups"]]
    require(len(roots) == 1 and roots[0]["path"] == "CMUXMaestroPreview",
            "Shared guide must remain in the production synchronized source root.")
    excluded = [path for key in roots[0].get("exceptions", [])
                for path in objects[key].get("membershipExceptions", [])]
    require(not any(path.removeprefix("CMUXMaestroPreview/") in excluded for path in GUIDE_SHARED_SOURCES),
            "Shared guide source excluded from production.")
    return inventory


def verify_guide_ui_settings(rows):
    require(len(rows) == 2 and {row["target"] for row in rows} == {GUIDE_HOST, GUIDE_TESTS},
            "Guide scheme must resolve exactly the host and UI consumer.")
    for row in rows:
        name, settings = row["target"], row["buildSettings"]
        ending = ".GuideHost" if name == GUIDE_HOST else ".GuideUITests"
        require(settings.get("PRODUCT_BUNDLE_IDENTIFIER") == BASE_ID + ".Validation.Tests" + ending,
                "Guide product escaped its fixed validation namespace.")
        require(settings.get("PRODUCT_NAME") == name, "Guide product name differs.")
        require(settings.get("PRODUCT_TYPE") == "com.apple.product-type."
                + ("application" if name == GUIDE_HOST else "bundle.ui-testing"), "Wrong resolved guide type.")
        for key, expected in (("CODE_SIGNING_ALLOWED", "NO"), ("CODE_SIGNING_REQUIRED", "NO"),
                              ("ENABLE_APP_SANDBOX", "NO"), ("SKIP_INSTALL", "YES"),
                              ("MACOSX_DEPLOYMENT_TARGET", "14.0")):
            require(settings.get(key) == expected, "Guide validation policy differs: " + key)
        require(not settings.get("CODE_SIGN_ENTITLEMENTS") and not settings.get("DEVELOPMENT_TEAM"),
                "Guide probe must not expand signing or entitlements.")
        conditions = settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "")
        require("CMUX_GUIDE_UI_VALIDATION" in (conditions.split() if isinstance(conditions, str) else conditions),
                "Guide target lacks its validation compilation guard.")
        if name == GUIDE_TESTS:
            require(settings.get("TEST_TARGET_NAME") == GUIDE_HOST, "Wrong UI host association.")
            require(not settings.get("TEST_HOST") and not settings.get("BUNDLE_LOADER"),
                    "Guide consumer must not be an in-process unit test.")
        else:
            require(settings.get("ENABLE_DEBUG_DYLIB") == "YES",
                    "Guide host requires the verified split-debug implementation layout.")


def verify_guide_ui_products(products):
    require(not Path(products).is_symlink(), "Guide products directory must not be redirected.")
    products = Path(products).resolve()
    host = products / (GUIDE_HOST + ".app")
    runner = products / (GUIDE_TESTS + "-Runner.app")
    test = runner / "Contents/PlugIns" / (GUIDE_TESTS + ".xctest")
    records = []
    def required_file(path):
        relative = path.relative_to(products)
        require(all(not (products / parent).is_symlink() for parent in (relative, *relative.parents)),
                "Guide product path must not contain symlinks: " + str(relative))
        require(path.is_file(), "Required guide product file missing: " + str(relative))
        return path

    for bundle, ending, package, executable, code_names in (
        (host, ".GuideHost", "APPL", GUIDE_HOST, (GUIDE_HOST, GUIDE_HOST + ".debug.dylib", "__preview.dylib")),
        (runner, ".GuideUITests.xctrunner", "APPL", GUIDE_TESTS + "-Runner", (GUIDE_TESTS + "-Runner",)),
        (test, ".GuideUITests", "BNDL", GUIDE_TESTS, (GUIDE_TESTS,)),
    ):
        info = plist(required_file(bundle / "Contents/Info.plist"))
        identifier = BASE_ID + ".Validation.Tests" + ending
        require(info.get("CFBundleIdentifier") == identifier, "Built guide bundle identifier differs.")
        require(info.get("CFBundlePackageType") == package, "Built guide package type differs.")
        require(info.get("CFBundleExecutable") == executable, "Built guide executable name differs.")
        code_files = []
        for name in code_names:
            binary = required_file(bundle / "Contents/MacOS" / name)
            require(0 < binary.stat().st_size <= 67_108_864, "Guide code file empty or oversized.")
            if name == executable:
                require(os.access(binary, os.X_OK), "Guide executable is not executable.")
            code_files.append({"path": str(binary.relative_to(bundle)),
                               "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()})
        require({path.name for path in (bundle / "Contents/MacOS").iterdir()} == set(code_names),
                "Guide product has unbound code files.")
        records.append({"product": str(bundle.relative_to(products)), "bundleIdentifier": identifier,
                        "codeFiles": code_files})
    host_info = plist(host / "Contents/Info.plist")
    require(not any(key.startswith("CMUXMaestro") for key in host_info), "Synthetic host has a production bridge.")
    require(not (host / "Contents/Extensions").exists() and not (host / "Contents/Helpers").exists(),
            "Synthetic host embeds production components.")
    resources = host / "Contents/Resources"
    require(not resources.exists() or not list(resources.iterdir()), "Synthetic host has unexpected resources.")
    return records


def verify_row_input_settings(rows):
    targets = {row["target"]: row["buildSettings"] for row in rows}
    for name, identifier in ROW_INPUT_TARGETS.items():
        require(name in targets, f"Missing row input target: {name}.")
        settings = targets[name]
        require(settings.get("PRODUCT_BUNDLE_IDENTIFIER") == identifier,
                "Row input target escaped its fixed validation namespace.")
        require(settings.get("CODE_SIGNING_ALLOWED") == "NO"
                and settings.get("CODE_SIGNING_REQUIRED") == "NO"
                and settings.get("SKIP_INSTALL") == "YES",
                "Row input targets must remain unsigned and non-installable.")
        require(settings.get("ENABLE_APP_SANDBOX") == "NO", "Unexpected row input sandbox profile.")
    fixture = targets["CMUXMaestroRowInputFixture"]
    require(fixture.get("INFOPLIST_KEY_LSUIElement") == "YES",
            "Row fixture must launch as an accessory without changing the Dock.")
    conditions = fixture.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "")
    require("CMUX_VALIDATION" in (conditions.split() if isinstance(conditions, str) else conditions),
            "Row fixture must compile validation-only observations.")
    require(targets["CMUXMaestroRowInputUITests"].get("TEST_TARGET_NAME") == "CMUXMaestroRowInputFixture",
            "UI tests must target only the isolated fixture.")


def verify_row_input_products(products):
    products = Path(products)
    app = products / "CMUXMaestroRowInputFixture.app"
    tests = products / "CMUXMaestroRowInputUITests-Runner.app/Contents/PlugIns/CMUXMaestroRowInputUITests.xctest"
    for name, path, kind in (
        ("CMUXMaestroRowInputFixture", app, "APPL"),
        ("CMUXMaestroRowInputUITests", tests, "BNDL"),
    ):
        info = plist(path / "Contents/Info.plist")
        require(info.get("CFBundleIdentifier") == ROW_INPUT_TARGETS[name]
                and info.get("CFBundlePackageType") == kind, "Invalid built row input product identity.")
        require(info.get("CFBundleExecutable") == name, "Unexpected row input executable.")
        require((path / "Contents/MacOS" / name).is_file(), "Row input binary missing.")
        if name == "CMUXMaestroRowInputFixture":
            require(info.get("LSUIElement") is True, "Built row fixture must be an accessory from launch.")
    require(not (app / "Contents/Extensions").exists() and not (app / "Contents/Helpers").exists(),
            "The row fixture must not embed the production extension or installer helpers.")
    runner = products / "CMUXMaestroRowInputUITests-Runner.app"
    info = plist(runner / "Contents/Info.plist")
    require(info.get("CFBundleIdentifier") == ROW_INPUT_TARGETS["CMUXMaestroRowInputUITests"] + ".xctrunner"
            and info.get("CFBundlePackageType") == "APPL"
            and info.get("CFBundleExecutable") == "CMUXMaestroRowInputUITests-Runner",
            "UI runner escaped its validation namespace.")


def verify_orchestration_resources(app, *, required=True):
    resources = Path(app) / "Contents/Resources"
    controller = resources / "cmux-maestro-orchestrator.py"
    skill = resources / "SKILL.md"
    if not required and not any(path.exists() or path.is_symlink() for path in (controller, skill)):
        return
    require(controller.is_file() and 0 < controller.stat().st_size <= 1_048_576,
            "Bundled orchestration controller is missing or oversized.")
    require(skill.is_file() and 0 < skill.stat().st_size <= 65_536,
            "Bundled orchestration skill is missing or oversized.")


def verify_messaging_resources(app):
    resources = Path(app) / "Contents/Resources"
    for name, maximum in (("adapter.mjs", 65_536), ("extension.mjs", 8192)):
        resource = resources / name
        require(resource.is_file() and not resource.is_symlink() and 0 < resource.stat().st_size <= maximum,
                f"Bundled messaging resource {name} is missing or oversized.")


def verify_guide_reference(app, canonical):
    reference = Path(app) / "Contents/Resources/maestro-guide.sha256"
    require(reference.is_file() and not reference.is_symlink() and reference.stat().st_size == 65,
            "Build guide reference is missing or malformed.")
    with reference.open("rb") as stream:
        actual = stream.read(66)
    with Path(canonical).open("rb") as stream:
        content = stream.read(65_537)
    require(0 < len(content) <= 65_536, "Canonical guide is empty or oversized.")
    expected = (hashlib.sha256(content).hexdigest() + "\n").encode("ascii")
    require(actual == expected, "Build guide reference differs from this source checkout.")


def verify_metadata(app, mode, *, expected_build=APP_BUILD_VERSION, require_orchestration=True, require_bridge=True):
    suffix, point = PROFILES[mode]
    app = Path(app)
    extension = app / "Contents/Extensions/CMUX Maestro Preview Extension.appex"
    parent = plist(app / "Contents/Info.plist")
    child = plist(extension / "Contents/Info.plist")
    require(parent.get("CFBundleIdentifier") == BASE_ID + suffix,
            "App bundle identifier does not match its build namespace.")
    require(child.get("CFBundleIdentifier") == BASE_ID + suffix + ".Extension",
            "Sidebar bundle identifier does not match its build namespace.")
    require(child.get("EXAppExtensionAttributes", {}).get("EXExtensionPointIdentifier") == point,
            "Sidebar extension point does not match its build namespace.")
    require(parent.get("CFBundlePackageType") == "APPL", "Containing product is not an application.")
    require(child.get("CFBundlePackageType") == "XPC!", "Sidebar product is not an extension.")
    if require_bridge:
        require(parent.get("CMUXMaestroInstallBridge") == "copilot-install-v1",
                "Containing app lacks the supported non-UI install bridge.")
        require(parent.get("CMUXMaestroAppLifecycleBridge") == "graceful-lifecycle-v1",
                "Containing app lacks the supported graceful lifecycle bridge.")
    version = parent.get("CFBundleVersion", "")
    require(isinstance(version, str) and re.fullmatch(r"[1-9][0-9]*(?:\.[0-9]+){0,2}", version)
            and child.get("CFBundleVersion") == version,
            "App and sidebar must have the same valid build version.")
    if expected_build is not None:
        require(version == expected_build, "App or sidebar native feature build version is stale.")
    verify_orchestration_resources(app, required=require_orchestration)
    if require_orchestration:
        verify_messaging_resources(app)
    return extension, child


def verify_ad_hoc_identity(target, identifier, runner):
    signed = runner(["/usr/bin/codesign", "-d", "--verbose=4", str(target)],
                    check=True, capture_output=True)
    details = signed.stderr.decode("utf-8", errors="strict")
    require(re.findall(r"^Identifier=(.+)$", details, re.MULTILINE) == [identifier],
            "Signed component identity differs from the production identity.")
    require(re.findall(r"^Signature=(.+)$", details, re.MULTILINE) == ["adhoc"],
            "Local preview requires the existing ad-hoc signing policy.")


def verify_local_preview(app, *, current=True, runner=subprocess.run):
    """Local receipts may restore an older, no-more-privileged signed preview.

    The publication CLI and verify_signed retain their current-build guards.
    This separate API is used only with an owned install/rollback receipt.
    """
    extension, child = verify_metadata(
        app, "production", expected_build=APP_BUILD_VERSION if current else None,
        require_orchestration=current, require_bridge=current,
    )
    app = Path(app)
    helper = app / "Contents/Helpers/CMUXMaestroCopilotHook"
    require(helper.is_file() and os.access(helper, os.X_OK), "Bundled identity helper is missing or not executable.")
    for bundle, info in ((app, plist(app / "Contents/Info.plist")), (extension, child)):
        executable = info.get("CFBundleExecutable", "")
        require(isinstance(executable, str) and executable and "/" not in executable
                and executable not in (".", ".."), "Invalid bundle executable.")
        binary = bundle / "Contents/MacOS" / executable
        require(binary.is_file() and os.access(binary, os.X_OK), "Bundle executable is missing or not executable.")
    for target, identifier in (
        (app, BASE_ID), (extension, BASE_ID + ".Extension"), (helper, BASE_ID + ".CopilotHook")
    ):
        runner(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(target)],
               check=True, capture_output=True)
        verify_ad_hoc_identity(target, identifier, runner)
        result = runner(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(target)],
                        check=True, capture_output=True)
        profile = plistlib.loads(result.stdout) if result.stdout.strip() else {}
        require(isinstance(profile, dict), "Invalid effective entitlements.")
        require("com.apple.security.get-task-allow" not in profile
                or type(profile["com.apple.security.get-task-allow"]) is bool,
                "Invalid debugging entitlement.")
        if target == extension:
            if current:
                verify_profile(profile)
            else:
                require(profile.get(SANDBOX_KEY) is True, "Rollback sidebar must remain sandboxed.")
                paths = profile.get(READ_KEY, [])
                require(isinstance(paths, list) and all(isinstance(path, str) for path in paths)
                        and set(paths) <= set(READ_PATHS), "Rollback expands approved read-only access.")
                if ORCHESTRATION_READ_PATH in paths:
                    verify_orchestration_resources(app)
                require(set(profile) <= {SANDBOX_KEY, READ_KEY, "com.apple.security.get-task-allow"},
                        "Unknown rollback sidebar entitlement.")
        else:
            allowed = {"com.apple.security.get-task-allow"}
            if target == helper and "com.apple.application-identifier" in profile:
                require(profile["com.apple.application-identifier"] == identifier,
                        "Helper application-identifier entitlement does not match its signing identity.")
                allowed.add("com.apple.application-identifier")
            require(set(profile) <= allowed,
                    "Installer/helper entitlements differ from the approved unsandboxed profile.")
    return plist(app / "Contents/Info.plist")["CFBundleVersion"]


def verify_signed(app):
    extension, child = verify_metadata(app, "production")
    helper = Path(app) / "Contents/Helpers/CMUXMaestroCopilotHook"
    require(helper.is_file() and os.access(helper, os.X_OK), "Bundled identity helper is missing or not executable.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(app)],
                   check=True, capture_output=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(helper)],
                   check=True, capture_output=True)
    verify_ad_hoc_identity(helper, BASE_ID + ".CopilotHook", subprocess.run)
    executable = extension / "Contents/MacOS" / child["CFBundleExecutable"]
    for target in (extension, executable):
        result = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(target)],
                                check=True, capture_output=True)
        verify_profile(plistlib.loads(result.stdout))
    result = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)],
                            check=True, capture_output=True)
    require(plistlib.loads(result.stdout).get(SANDBOX_KEY) is not True,
            "The installer unexpectedly has App Sandbox enabled.")


def registration_records(output, *, allow_empty=False, include_election=False):
    """Parse only the supported pluginkit listing; diagnostics are not success."""
    if allow_empty and output.strip() in ("(no matches)", "(0 plug-ins)"):
        return []
    records = []
    count = None
    fields = {"Path", "UUID", "Timestamp", "SDK", "Parent Bundle",
              "Display Name", "Short Name", "Parent Name", "Platform"}
    for raw in output.splitlines():
        line = raw.strip()
        if not line:
            continue
        require(count is None, "Unexpected data after registration summary.")
        summary = re.fullmatch(r"\((\d+) plug-ins?\)", line)
        if summary:
            count = int(summary.group(1))
            continue
        header = re.fullmatch(r"([+\-!=?]?)\s*([A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+)(?:\([^\r\n]*\))?", line)
        if header:
            records.append({"id": header.group(2)})
            if include_election:
                records[-1]["election"] = header.group(1)
            continue
        field = re.fullmatch(r"([A-Za-z][A-Za-z ]*)\s*=\s*(.+)", line)
        require(field is not None and records, "Unsupported registration output.")
        key, value = field.group(1).strip(), field.group(2)
        require(key in fields and key not in records[-1], "Unsupported or duplicate registration field.")
        records[-1][key] = value
    require(count is not None and count == len(records) and records, "Missing registration entries.")
    require(all("Path" in record and Path(record["Path"]).is_absolute() for record in records),
            "Registration entry has no absolute path.")
    return records


def verify_registration_output(output, expected_extension, *, absent=False):
    """Require (or explicitly exclude) the exact production ID/canonical path."""
    expected = Path(expected_extension).resolve()
    records = registration_records(output, allow_empty=absent)
    found = any(record["id"] == BASE_ID + ".Extension"
                and Path(record["Path"]).resolve() == expected for record in records)
    require(found != absent, "Production ID/path registration does not match the requested state.")


def verify_registered_extension(extension):
    require(Path(extension).is_dir(), "Expected extension directory is missing.")
    result = subprocess.run(
        ["/usr/bin/pluginkit", "-m", "-A", "-D", "-vv", "-i", BASE_ID + ".Extension"],
        check=True, capture_output=True, text=True,
    )
    require(not result.stderr.strip(), "Registration query reported a diagnostic.")
    verify_registration_output(result.stdout, extension)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=PROFILES, required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--settings", type=Path)
    source.add_argument("--app", type=Path)
    source.add_argument("--registration", type=Path)
    parser.add_argument("--source-entitlements", type=Path)
    args = parser.parse_args()
    try:
        if args.registration:
            require(args.mode == "production", "Only production registration is supported.")
            verify_registered_extension(args.registration)
        elif args.settings:
            verify_settings(json.loads(args.settings.read_text()), args.mode)
        elif args.mode == "production":
            verify_signed(args.app)
        else:
            verify_metadata(args.app, args.mode)
        if args.app:
            verify_guide_reference(args.app, Path(__file__).resolve().parents[1] / "skills/maestro/SKILL.md")
        if args.source_entitlements:
            verify_profile(plist(args.source_entitlements))
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException, subprocess.CalledProcessError):
        print("Build namespace, signing, sandbox, or registration validation failed.", file=sys.stderr)
        return 1
    if args.registration:
        print(f"Verified production registration entry at {args.registration.resolve()}")
        return 0
    print(f"Verified {args.mode} build namespace" + (" and effective signed sandbox" if args.app and args.mode == "production" else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
