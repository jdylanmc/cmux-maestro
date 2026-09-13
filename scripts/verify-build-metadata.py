#!/usr/bin/env python3
"""Check validation namespaces and the explicit native publication boundary."""

import argparse
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
READ_PATHS = [
    "/Library/Application Support/CMUXMaestroPreview/Copilot/",
    "/.copilot/session-state/",
]
SANDBOX_KEY = "com.apple.security.app-sandbox"
READ_KEY = "com.apple.security.temporary-exception.files.home-relative-path.read-only"


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


def verify_metadata(app, mode, *, expected_build=APP_BUILD_VERSION):
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
    version = parent.get("CFBundleVersion", "")
    require(isinstance(version, str) and re.fullmatch(r"[1-9][0-9]*(?:\.[0-9]+){0,2}", version)
            and child.get("CFBundleVersion") == version,
            "App and sidebar must have the same valid build version.")
    if expected_build is not None:
        require(version == expected_build, "App or sidebar native feature build version is stale.")
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
        app, "production", expected_build=APP_BUILD_VERSION if current else None
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
                require(set(profile) <= {SANDBOX_KEY, READ_KEY, "com.apple.security.get-task-allow"},
                        "Unknown rollback sidebar entitlement.")
        else:
            require(set(profile) <= {"com.apple.security.get-task-allow"},
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


def registration_records(output, *, allow_empty=False):
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
        header = re.fullmatch(r"[+\-!=?]?\s*([A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+)(?:\([^\r\n]*\))?", line)
        if header:
            records.append({"id": header.group(1)})
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
