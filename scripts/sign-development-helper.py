#!/usr/bin/env python3
"""Finalize only this checkout's optional development products, inside out."""

import importlib.util
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("metadata", ROOT / "scripts/verify-build-metadata.py")
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)
EMPTY_ENTITLEMENTS = ROOT / "scripts/helper-development.entitlements"
HELPER_NAME = "CMUXMaestroCopilotHook"


def finalize_development_signing(products, identity, team, runner=subprocess.run):
    require = metadata.require
    require(identity.startswith("Apple Development:") and re.fullmatch(r"[A-Z0-9]{10}", team),
            "An explicit local Apple Development identity and team are required.")
    require(metadata.plist(EMPTY_ENTITLEMENTS) == {}, "Helper signing entitlements must be exactly empty.")
    products = Path(products).absolute()
    app = products / "CMUX Maestro Preview.app"
    helper = products / HELPER_NAME
    embedded = app / "Contents/Helpers" / HELPER_NAME
    extension = app / "Contents/Extensions/CMUX Maestro Preview Extension.appex"
    profiles = [target / "Contents/embedded.provisionprofile" for target in (app, extension)]
    for path in (products, app, helper, embedded, extension, *profiles):
        require(path.exists() and path.resolve() == path, "Missing or redirected development product.")
    for path in (helper, embedded, *profiles):
        require(path.is_file() and path.stat().st_nlink == 1, "Expected an unshared regular product file.")
    require(all(os.access(path, os.X_OK) for path in (helper, embedded)), "Helper must be executable.")
    metadata.verify_metadata(app, "development")

    def codesign(*args):
        return runner(["/usr/bin/codesign", *map(str, args)], check=True, capture_output=True)

    def verify(target, identifier):
        codesign("--verify", "--strict", "-R",
                 f'=anchor apple generic and identifier "{identifier}"', target)
        details = codesign("-d", "--verbose=4", target).stderr.decode("utf-8", errors="strict")
        require(re.findall(r"^Identifier=(.+)$", details, re.MULTILINE) == [identifier]
                and re.findall(r"^TeamIdentifier=(.+)$", details, re.MULTILINE) == [team]
                and re.findall(r"^Authority=(.+)$", details, re.MULTILINE)[:1] == [identity]
                and "Signature=adhoc" not in details, "Unexpected development signer or namespace.")

    def entitlements(target):
        result = codesign("-d", "--entitlements", ":-", target)
        value = plistlib.loads(result.stdout) if result.stdout.strip() else {}
        require(isinstance(value, dict), "Invalid effective entitlements.")
        return value

    helper_id = metadata.BASE_ID + ".CopilotHook"
    # Accept only the known Xcode identity/debugging packaging, never erase new privileges.
    for target, identifier in ((app, metadata.BASE_ID), (extension, metadata.BASE_ID + ".Extension"),
                               (helper, helper_id), (embedded, helper_id)):
        verify(target, identifier)
        if target in (helper, embedded):
            grants = entitlements(target)
            require(set(grants) <= {"com.apple.application-identifier", "com.apple.security.get-task-allow"}
                    and ("com.apple.application-identifier" not in grants
                         or grants["com.apple.application-identifier"] == team + "." + helper_id)
                    and ("com.apple.security.get-task-allow" not in grants
                         or type(grants["com.apple.security.get-task-allow"]) is bool),
                    "Unexpected helper privileges; refusing to replace its entitlements.")

    parent_entitlements = entitlements(app)
    profile_bytes = [path.read_bytes() for path in profiles]
    codesign("--force", "--sign", identity, "--identifier", helper_id, "--options", "runtime",
             "--timestamp=none", "--entitlements", EMPTY_ENTITLEMENTS, helper)
    verify(helper, helper_id)
    require(entitlements(helper) == {}, "Final helper must have zero entitlement keys.")
    shutil.copy2(helper, embedded)
    verify(embedded, helper_id)
    require(embedded.read_bytes() == helper.read_bytes() and entitlements(embedded) == {},
            "Embedded helper differs from the finalized helper.")
    # Seal the parent only after the exact final nested helper has been embedded.
    codesign("--force", "--sign", identity,
             "--preserve-metadata=identifier,requirements,entitlements,flags,runtime",
             "--timestamp=none", app)
    require(entitlements(app) == parent_entitlements, "Parent entitlements changed during signing.")
    require([path.read_bytes() for path in profiles] == profile_bytes, "Development profiles changed.")
    require(embedded.read_bytes() == helper.read_bytes(), "Parent signing changed the nested helper.")


def main():
    try:
        finalize_development_signing(
            ROOT / ".build/development/Build/Products/Debug",
            os.environ["CMUX_DEVELOPMENT_IDENTITY"], os.environ["CMUX_DEVELOPMENT_TEAM"],
        )
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException, subprocess.CalledProcessError):
        print("Development helper signing failed; no verified build produced.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
