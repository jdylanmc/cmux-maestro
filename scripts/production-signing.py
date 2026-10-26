#!/usr/bin/env python3
"""Explicit profile-backed local publication; no portal or keychain mutations."""

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("provisioning_profile", Path(__file__).with_name("provisioning-profile.py"))
profile_reader = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(profile_reader)
BASE_ID = "com.jdylanmc.CMUXMaestroPreview"
COMMUNICATION = "com.apple.developer.usernotifications.communication"
APP_ID = "com.apple.application-identifier"
TEAM_ID = "com.apple.developer.team-identifier"
DEBUG = "com.apple.security.get-task-allow"
EXTENSION = Path("Contents/Extensions/CMUX Maestro Preview Extension.appex")
MACHO = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
         b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
require = profile_reader.require


def mach_o_architectures(path):
    """Read bounded Mach-O architecture headers; codesign validates the actual code."""
    thin = {b"\xce\xfa\xed\xfe": "<", b"\xcf\xfa\xed\xfe": "<",
            b"\xfe\xed\xfa\xce": ">", b"\xfe\xed\xfa\xcf": ">"}
    fat = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
           b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
    with path.open("rb") as stream:
        header = stream.read(12)
        magic = header[:4]
        if magic in thin:
            require(len(header) == 12, "Truncated native code header.")
            cpu, subtype = struct.unpack(thin[magic] + "II", header[4:])
            return [(cpu, subtype & 0x00ffffff)]
        if magic not in fat:
            return []
        require(len(header) == 12, "Truncated universal code header.")
        endian, wide = fat[magic]
        count = struct.unpack(endian + "I", header[4:8])[0]
        require(0 < count <= 32, "Unsupported universal architecture count.")
        entry_size = 32 if wide else 20
        stream.seek(8)
        table = stream.read(count * entry_size)
        require(len(table) == count * entry_size, "Truncated universal architecture table.")
        total = os.fstat(stream.fileno()).st_size
        architectures, ranges = [], []
        for index in range(count):
            entry = table[index * entry_size:(index + 1) * entry_size]
            cpu, subtype, offset, size = struct.unpack(endian + ("IIQQII" if wide else "IIIII"), entry)[:4]
            require(offset >= 8 + len(table) and size >= 12 and offset + size <= total,
                    "Invalid universal code range.")
            require(all(offset + size <= start or offset >= end for start, end in ranges),
                    "Overlapping universal code ranges.")
            ranges.append((offset, offset + size))
            stream.seek(offset)
            image = stream.read(12)
            require(image[:4] in thin and struct.unpack(thin[image[:4]] + "II", image[4:]) == (cpu, subtype),
                    "Universal architecture does not match its code header.")
            architecture = (cpu, subtype & 0x00ffffff)
            require(architecture not in architectures, "Ambiguous universal architecture.")
            architectures.append(architecture)
        return architectures


def metadata_module():
    spec = importlib.util.spec_from_file_location("signing_metadata", Path(__file__).with_name("verify-build-metadata.py"))
    metadata = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(metadata)
    return metadata


def profile_policy(profile, *, now, device):
    require(isinstance(profile, dict), "Invalid provisioning profile.")
    team = profile.get("TeamIdentifier")
    require(isinstance(team, list) and len(team) == 1 and isinstance(team[0], str)
            and re.fullmatch(r"[A-Z0-9]{10}", team[0]), "Profile must authorize exactly one team.")
    require(profile.get("ApplicationIdentifierPrefix") == team, "Profile application prefix differs from team.")
    require(profile.get("Platform") == ["OSX"], "Profile must target macOS.")
    for key in ("CreationDate", "ExpirationDate"):
        require(isinstance(profile.get(key), datetime), "Profile validity dates are missing.")
    created = profile["CreationDate"].replace(tzinfo=timezone.utc)
    expires = profile["ExpirationDate"].replace(tzinfo=timezone.utc)
    require(created <= now < expires, "Profile is expired or not yet valid.")
    devices = profile.get("ProvisionedDevices")
    require(isinstance(devices, list) and 0 < len(devices) <= 1000
            and all(isinstance(item, str) for item in devices)
            and isinstance(device, str) and device and device in devices
            and not profile.get("ProvisionsAllDevices", False), "Profile does not authorize this Mac.")
    entitlements = profile.get("Entitlements")
    require(isinstance(entitlements, dict), "Profile entitlements are missing.")
    require(entitlements.get(APP_ID) == team[0] + "." + BASE_ID
            and entitlements.get(TEAM_ID) == team[0], "Profile app/team mismatch.")
    require(entitlements.get(COMMUNICATION) is True and entitlements.get(DEBUG) is True,
            "Profile must authorize development communication notifications.")
    require(set(entitlements) <= {APP_ID, TEAM_ID, COMMUNICATION, DEBUG, "keychain-access-groups"},
            "Profile authorizes unexpected capabilities.")
    certificates = profile.get("DeveloperCertificates")
    require(isinstance(certificates, list) and 0 < len(certificates) <= 32
            and all(isinstance(item, bytes) and 0 < len(item) <= 32_768 for item in certificates),
            "Profile developer certificates are missing or invalid.")
    return {APP_ID: team[0] + "." + BASE_ID, TEAM_ID: team[0], COMMUNICATION: True, DEBUG: True}


def select_identity(profile, output):
    available = set(re.findall(r'^\s*\d+\) ([A-Fa-f0-9]{40}) "[^\r\n]*"\s*$', output, re.M))
    available = {item.upper() for item in available}
    allowed = {hashlib.sha1(item).hexdigest().upper() for item in profile["DeveloperCertificates"]}
    matching = available & allowed
    require(len(matching) == 1, "Profile requires exactly one currently usable matching signing identity.")
    return next(iter(matching))


def device_identity(runner):
    result = runner(["/usr/sbin/system_profiler", "SPHardwareDataType", "-json"],
                    check=True, capture_output=True, timeout=30)
    rows = json.loads(result.stdout).get("SPHardwareDataType")
    require(isinstance(rows, list) and len(rows) == 1 and isinstance(rows[0], dict),
            "Cannot verify this Mac's provisioning identity.")
    device = rows[0].get("provisioning_UDID")
    require(isinstance(device, str) and device, "Mac provisioning identity unavailable.")
    return device


def certificate_policy(certificate, team, now, runner):
    result = runner(["/usr/bin/openssl", "x509", "-inform", "DER", "-noout", "-subject",
                     "-startdate", "-enddate", "-nameopt", "RFC2253"], input=certificate,
                    check=True, capture_output=True, timeout=30).stdout.decode("utf-8")
    subject = re.findall(r"^subject=\s*(.+)$", result, re.M)
    require(len(subject) == 1 and re.findall(r"(?:^|,)OU=([A-Z0-9]{10})(?=,|$)", subject[0]) == [team],
            "Signing certificate team differs from profile.")
    dates = []
    for key in ("notBefore", "notAfter"):
        values = re.findall(r"^" + key + r"=(.+)$", result, re.M)
        require(len(values) == 1, "Signing certificate validity unavailable.")
        dates.append(datetime.strptime(values[0], "%b %d %H:%M:%S %Y GMT").replace(tzinfo=timezone.utc))
    require(dates[0] <= now < dates[1], "Signing certificate is expired or not yet valid.")


def load_plan(path, *, runner=subprocess.run, now=None, need_identity=True):
    now = now or datetime.now(timezone.utc)
    raw = profile_reader.read_private(path)
    profile = profile_reader.decode_verified(raw, runner=runner)
    entitlements = profile_policy(profile, now=now, device=device_identity(runner))
    plan = {"raw": raw, "profile": profile, "entitlements": entitlements}
    if need_identity:
        output = runner(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
                        check=True, capture_output=True, timeout=30).stdout.decode("utf-8")
        plan["identity"] = select_identity(profile, output)
        certificate = next(item for item in profile["DeveloperCertificates"]
                           if hashlib.sha1(item).hexdigest().upper() == plan["identity"])
        certificate_policy(certificate, entitlements[TEAM_ID], now, runner)
    return plan


def component_paths(app):
    """Fixed bundle topology; unexpected native code refuses instead of being missed."""
    app = Path(app)
    require(not app.is_symlink(), "Publication bundle is redirected.")
    extension = app / EXTENSION
    helper = app / "Contents/Helpers/CMUXMaestroCopilotHook"
    bundles = [(extension, BASE_ID + ".Extension"), (app, BASE_ID)]
    executables = {helper}
    dylibs = []
    for bundle, _ in bundles:
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        name = info.get("CFBundleExecutable")
        require(isinstance(name, str) and name and "/" not in name and name not in (".", ".."),
                "Invalid native executable name.")
        executables.add(bundle / "Contents/MacOS" / name)
        for name in (name + ".debug.dylib", "__preview.dylib"):
            path = bundle / "Contents/MacOS" / name
            if path.exists():
                dylibs.append(path)
    expected = executables | set(dylibs)
    found = set()
    count = 0
    for root, directories, files in os.walk(app, followlinks=False):
        for name in directories + files:
            count += 1
            require(count <= 16_384, "Publication bundle exceeds entry bound.")
            path = Path(root) / name
            if path.is_symlink():
                require(path.resolve(strict=True).is_relative_to(app.resolve()),
                        "Publication bundle link escapes its root.")
        for name in files:
            path = Path(root) / name
            if path.is_symlink():
                continue
            info = path.stat()
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
                    "Publication bundle contains a non-regular or hard-linked entry.")
            with path.open("rb") as stream:
                if stream.read(4) in MACHO:
                    found.add(path)
    require(found == expected, "Native code inventory differs from supported app/sidebar/helper layout.")
    return bundles, helper, dylibs


def signed_details(target, identifier, team, certificates, runner, now):
    result = runner(["/usr/bin/codesign", "-d", "--verbose=4", str(target)],
                    check=True, capture_output=True, timeout=30)
    text = result.stderr.decode("utf-8")
    require(re.findall(r"^Identifier=(.+)$", text, re.M) == [identifier] if identifier else True,
            "Signed component identifier mismatch.")
    require(re.findall(r"^TeamIdentifier=(.+)$", text, re.M) == [team]
            and "Signature=adhoc" not in text, "Signed component team mismatch or ad-hoc signature.")
    matching = []
    for certificate in set(certificates):
        fingerprint = hashlib.sha1(certificate).hexdigest()
        requirement = f'=certificate leaf = H"{fingerprint}"'
        if identifier:
            requirement += f' and identifier "{identifier}"'
        result = runner(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures",
                         "-R", requirement, str(target)], check=False, capture_output=True, timeout=30)
        if result.returncode == 0:
            certificate_policy(certificate, team, now, runner)
            matching.append(hashlib.sha256(certificate).digest())
    require(len(matching) == 1, "Component signer is not uniquely authorized by the embedded profile.")
    return matching[0]


def verify(app, *, runner=subprocess.run, now=None, current=True):
    app = Path(app)
    now = now or datetime.now(timezone.utc)
    plan = load_plan(app / "Contents/embedded.provisionprofile", runner=runner, now=now, need_identity=False)
    entitlements = plan["entitlements"]
    bundles, helper, dylibs = component_paths(app)
    require(not (app / EXTENSION / "Contents/embedded.provisionprofile").exists(),
            "Containing-app profile must not authorize the sidebar.")
    require(plistlib.loads((app / "Contents/Info.plist").read_bytes()).get("NSUserActivityTypes")
            == ["INSendMessageIntent"], "Communication intent declaration missing or expanded.")
    signers = set()
    metadata = metadata_module()
    for target, identifier in [*bundles, (helper, BASE_ID + ".CopilotHook"),
                               *((path, None) for path in dylibs)]:
        runner(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(target)],
               check=True, capture_output=True, timeout=30)
        signers.add(signed_details(target, identifier, entitlements[TEAM_ID],
                                   plan["profile"]["DeveloperCertificates"], runner, now))
        binary = target
        if target in (app, app / EXTENSION):
            info = plistlib.loads((target / "Contents/Info.plist").read_bytes())
            binary = target / "Contents/MacOS" / info["CFBundleExecutable"]
        architectures = mach_o_architectures(binary)
        require(architectures, "Native component has no verifiable architecture.")
        for cpu, subtype in architectures:
            output = runner(["/usr/bin/codesign", "-d", "--architecture", f"{cpu},{subtype}",
                             "--entitlements", ":-", str(target)],
                            check=True, capture_output=True, timeout=30).stdout
            actual = plistlib.loads(output) if output.strip() else {}
            require(isinstance(actual, dict), "Invalid effective entitlements.")
            if target == app:
                require(actual == entitlements, "Containing-app slice entitlements differ from approved profile.")
            elif target == app / EXTENSION:
                metadata.verify_sidebar_profile(actual, current=current, app=app)
            else:
                require(actual == {}, "Helper/dylib slice unexpectedly carries entitlements.")
    require(len(signers) == 1, "Embedded components have different signing certificates.")
    return plan


def sign(app, path, *, runner=subprocess.run):
    app = Path(app)
    plan = load_plan(path, runner=runner)
    bundles, helper, dylibs = component_paths(app)
    extension = app / EXTENSION
    result = runner(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(extension)],
                    check=True, capture_output=True, timeout=30)
    sidebar = plistlib.loads(result.stdout)
    sidebar.pop(DEBUG, None)
    metadata = metadata_module()
    metadata.verify_metadata(app, "production")
    metadata.verify_profile(sidebar)
    # Snapshot only the approved public profile, never certificates' private keys.
    embedded = app / "Contents/embedded.provisionprofile"
    if embedded.exists() or embedded.is_symlink():
        profile_reader.read_private(embedded)
    with tempfile.NamedTemporaryFile(dir=embedded.parent, prefix=".profile-", delete=False) as stream:
        staging = Path(stream.name)
        try:
            stream.write(plan["raw"])
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(staging, embedded)
        finally:
            staging.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix="maestro-signing-entitlements-") as temporary:
        for target, identifier, entitlements in [
            *((path, None, {}) for path in dylibs),
            (helper, BASE_ID + ".CopilotHook", {}),
            (extension, BASE_ID + ".Extension", sidebar),
            (app, BASE_ID, plan["entitlements"]),
        ]:
            entitlement_file = Path(temporary) / "entitlements.plist"
            entitlement_file.write_bytes(plistlib.dumps(entitlements))
            command = ["/usr/bin/codesign", "--force", "--sign", plan["identity"], "--timestamp=none",
                       "--options", "runtime", "--entitlements", str(entitlement_file)]
            if identifier:
                command += ["--identifier", identifier]
            # A human may need to unlock the existing key; never force-kill a signing writer.
            runner([*command, str(target)], check=True, capture_output=True)
    verified = verify(app, runner=runner)
    require(verified["raw"] == plan["raw"], "Embedded profile changed during signing.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("preflight", "sign"))
    parser.add_argument("--provisioning-profile", type=Path, required=True)
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    try:
        if args.operation == "preflight":
            load_plan(args.provisioning_profile)
        else:
            require(args.app is not None, "Signing requires an app.")
            sign(args.app, args.provisioning_profile)
    except (ValueError, OSError, KeyError, TypeError, plistlib.InvalidFileException,
            subprocess.SubprocessError):
        print("Production signing refused: verify the profile, Mac, existing identity and app policy.", file=sys.stderr)
        return 1
    print("Production signing preflight verified." if args.operation == "preflight" else "Production signing verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
