#!/usr/bin/env python3
import importlib.util
import copy
import datetime
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("metadata", ROOT / "scripts/verify-build-metadata.py")
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)
spec = importlib.util.spec_from_file_location("development_signing", ROOT / "scripts/sign-development-helper.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class BuildMetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory = ROOT / ".build/metadata-tests" / str(uuid.uuid4())
        self.app = self.directory / "Fixture.app"
        self.extension = self.app / "Contents/Extensions/CMUX Maestro Preview Extension.appex"
        (self.extension / "Contents").mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.directory)

    def fixture(self, mode):
        suffix, point = metadata.PROFILES[mode]
        self.parent = {"CFBundleIdentifier": metadata.BASE_ID + suffix, "CFBundlePackageType": "APPL",
                       "CFBundleVersion": metadata.APP_BUILD_VERSION}
        self.child = {
            "CFBundleIdentifier": metadata.BASE_ID + suffix + ".Extension",
            "CFBundlePackageType": "XPC!",
            "CFBundleVersion": metadata.APP_BUILD_VERSION,
            "CFBundleExecutable": "Fixture",
            "EXAppExtensionAttributes": {"EXExtensionPointIdentifier": point},
        }
        resources = self.app / "Contents/Resources"
        resources.mkdir(parents=True, exist_ok=True)
        (resources / "cmux-maestro-orchestrator.py").write_text("#!/usr/bin/env python3\n")
        (resources / "SKILL.md").write_text("---\nname: cmux-maestro-orchestrate\n---\n")
        self.save()

    def save(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.parent))
        (self.extension / "Contents/Info.plist").write_bytes(plistlib.dumps(self.child))

    def test_validation_namespaces_remain_distinct_from_publication(self):
        for mode in metadata.PROFILES:
            with self.subTest(mode=mode):
                self.fixture(mode)
                metadata.verify_metadata(self.app, mode)
                for other in metadata.PROFILES:
                    if metadata.PROFILES[other] != metadata.PROFILES[mode]:
                        with self.assertRaises(ValueError):
                            metadata.verify_metadata(self.app, other)

    def test_validation_cannot_keep_production_id_or_point(self):
        for field in ("parent", "child", "point"):
            with self.subTest(field=field):
                self.fixture("tests")
                if field == "parent":
                    self.parent["CFBundleIdentifier"] = metadata.BASE_ID
                elif field == "child":
                    self.child["CFBundleIdentifier"] = metadata.BASE_ID + ".Extension"
                else:
                    self.child["EXAppExtensionAttributes"]["EXExtensionPointIdentifier"] = metadata.PRODUCTION_POINT
                self.save()
                with self.assertRaises(ValueError):
                    metadata.verify_metadata(self.app, "tests")

    def test_effective_sandbox_and_prefixes_are_required(self):
        good = {metadata.SANDBOX_KEY: True, metadata.READ_KEY: metadata.READ_PATHS}
        metadata.verify_profile(good)
        for invalid in (
            {metadata.READ_KEY: metadata.READ_PATHS},
            {**good, metadata.SANDBOX_KEY: False},
            {**good, metadata.READ_KEY: [path.lstrip("/") for path in metadata.READ_PATHS]},
            {**good, "com.apple.security.network.client": True},
        ):
            with self.assertRaises(ValueError):
                metadata.verify_profile(invalid)

    def test_stale_app_or_extension_build_is_rejected(self):
        for member in ("parent", "child"):
            self.fixture("production")
            getattr(self, member)["CFBundleVersion"] = "1"
            self.save()
            with self.assertRaises(ValueError):
                metadata.verify_metadata(self.app, "production")

    def test_signed_publication_checks_actual_profile_not_just_signature_validity(self):
        self.fixture("production")
        helper = self.app / "Contents/Helpers/CMUXMaestroCopilotHook"
        helper.parent.mkdir()
        helper.write_bytes(b"synthetic")
        helper.chmod(0o700)
        good = {metadata.SANDBOX_KEY: True, metadata.READ_KEY: metadata.READ_PATHS}

        def signed(command, **_):
            if "--verbose=4" in command:
                return subprocess.CompletedProcess(command, 0, stdout=b"",
                                                   stderr=f"Identifier={metadata.BASE_ID}.CopilotHook\nSignature=adhoc\n".encode())
            profile = {} if command[-1] == str(self.app) else good
            return subprocess.CompletedProcess(command, 0, stdout=plistlib.dumps(profile))

        with patch.object(metadata.subprocess, "run", side_effect=signed) as runner:
            metadata.verify_signed(self.app)
            self.assertEqual(runner.call_count, 6)
            self.assertIn("--strict", runner.call_args_list[0].args[0])
        def empty_profile(command, **kwargs):
            if "--verbose=4" in command:
                return signed(command, **kwargs)
            return subprocess.CompletedProcess(command, 0, stdout=plistlib.dumps({}), stderr=b"")

        with patch.object(metadata.subprocess, "run", side_effect=empty_profile):
            with self.assertRaises(ValueError):
                metadata.verify_signed(self.app)

    def test_resolved_settings_fail_closed_before_any_build(self):
        for mode, (suffix, point) in metadata.PROFILES.items():
            rows = []
            for target, ending in (
                ("CMUXMaestroPreview", ""), ("CMUXMaestroSidebar", ".Extension"),
                ("CMUXMaestroCopilotHook", ".CopilotHook"), ("CMUXMaestroPreviewTests", ".Tests"),
            ):
                rows.append({"target": target, "buildSettings": {
                    "PRODUCT_BUNDLE_IDENTIFIER": metadata.BASE_ID + suffix + ending,
                    "CMUX_SIDEBAR_EXTENSION_POINT_ID": point,
                    "ENABLE_APP_SANDBOX": "YES" if target == "CMUXMaestroSidebar" else "NO",
                    "CODE_SIGNING_ALLOWED": "YES" if mode in ("production", "development") else "NO",
                    "CODE_SIGNING_REQUIRED": "YES",
                    "CODE_SIGN_IDENTITY": "Apple Development: Synthetic" if mode == "development" else "-",
                    "CODE_SIGN_STYLE": "Manual", "DEVELOPMENT_TEAM": "SYNTHETIC1",
                    "PROVISIONING_PROFILE_SPECIFIER": "synthetic-" + target,
                    "CODE_SIGN_ENTITLEMENTS": str(ROOT / "scripts/native-development.entitlements")
                    if target == "CMUXMaestroPreview" else "CMUXMaestroSidebar/CMUXMaestroSidebar.entitlements",
                    "CURRENT_PROJECT_VERSION": metadata.APP_BUILD_VERSION,
                    "OTHER_CODE_SIGN_FLAGS": "--identifier " + metadata.BASE_ID + suffix + ending
                    if target == "CMUXMaestroCopilotHook" else "",
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG" if mode in ("production", "development") else "DEBUG CMUX_VALIDATION",
                }})
            helper = rows[2]["buildSettings"]
            helper.update({
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
                "CODE_SIGN_ENTITLEMENTS": "",
                "PROVISIONING_PROFILE_SPECIFIER": "",
            })
            metadata.verify_settings(rows, mode)
            flags = rows[2]["buildSettings"].pop("OTHER_CODE_SIGN_FLAGS")
            with self.assertRaises(ValueError):
                metadata.verify_settings(rows, mode)
            rows[2]["buildSettings"]["OTHER_CODE_SIGN_FLAGS"] = flags
            for key, value in (
                ("PRODUCT_BUNDLE_IDENTIFIER", metadata.BASE_ID + ".WrongHelper"),
                ("PRODUCT_BUNDLE_IDENTIFIER", ""),
                ("OTHER_CODE_SIGN_FLAGS", "--identifier " + metadata.BASE_ID + ".WrongHelper"),
                ("CODE_SIGN_INJECT_BASE_ENTITLEMENTS", "YES"),
                ("CODE_SIGN_ENTITLEMENTS", "unexpected.entitlements"),
                ("PROVISIONING_PROFILE_SPECIFIER", "unexpected-profile"),
                ("PROVISIONING_PROFILE", "unexpected-profile"),
            ):
                with self.subTest(mode=mode, key=key, value=value):
                    bad = copy.deepcopy(rows)
                    bad[2]["buildSettings"][key] = value
                    with self.assertRaises(ValueError):
                        metadata.verify_settings(bad, mode)
            valid_conditions = rows[0]["buildSettings"]["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]
            rows[0]["buildSettings"]["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = (
                "DEBUG CMUX_VALIDATION" if mode in ("production", "development") else "DEBUG"
            )
            with self.assertRaises(ValueError):
                metadata.verify_settings(rows, mode)
            rows[0]["buildSettings"]["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = valid_conditions
            rows[1]["buildSettings"]["CMUX_SIDEBAR_EXTENSION_POINT_ID"] = "unexpected.point"
            with self.assertRaises(ValueError):
                metadata.verify_settings(rows, mode)

    def test_development_profile_metadata_is_not_a_boolean_opt_in(self):
        team = "SYNTHETIC1"
        now = datetime.datetime.now(datetime.timezone.utc)
        entitlements = {
            "com.apple.application-identifier": team + "." + metadata.BASE_ID,
            "com.apple.developer.team-identifier": team,
            "keychain-access-groups": [team + "." + metadata.BASE_ID],
        }
        profile = {
            "TeamIdentifier": [team], "ApplicationIdentifierPrefix": [team],
            "CreationDate": now - datetime.timedelta(days=1),
            "ExpirationDate": now + datetime.timedelta(days=1),
            "ProvisionedDevices": ["synthetic-device"], "DeveloperCertificates": [b"synthetic"],
            "Entitlements": {**entitlements, "get-task-allow": True},
        }
        def verify(e=entitlements, p=profile):
            metadata.verify_development_profile(e, p, team, metadata.BASE_ID, keychain=True, now=now)
        verify()
        for e, p in (({}, profile), (entitlements, {}), ({**entitlements, "keychain-access-groups": []}, profile),
                     ({**entitlements, "com.apple.security.network.client": True}, profile)):
            with self.assertRaises(ValueError):
                verify(e, p)
        for key, value in (("TeamIdentifier", ["OTHERTEAM1"]), ("ExpirationDate", now),
                           ("ProvisionedDevices", []), ("DeveloperCertificates", [])):
            with self.assertRaises(ValueError):
                verify(p={**profile, key: value})
        wrong = copy.deepcopy(profile)
        wrong["Entitlements"]["com.apple.application-identifier"] += ".Extension"
        with self.assertRaises(ValueError):
            verify(p=wrong)

    def test_development_is_optional_and_never_auto_provisions_or_registers(self):
        script = (ROOT / "scripts/build-development.sh").read_text()
        self.assertNotIn("-allowProvisioningUpdates", script)
        self.assertNotIn("pluginkit -a", script)
        self.assertNotIn("security find", script)
        self.assertIn("--mode development", script)
        self.assertLess(script.index('--source-entitlements'), script.index('"${SETTINGS[@]}" clean build'))
        self.assertIn('DERIVED_DATA="$ROOT/.build/development"', script)
        self.assertIn('-derivedDataPath "$DERIVED_DATA" "${SETTINGS[@]}" clean build', script)
        self.assertIn("set -euo pipefail", script)
        self.assertLess(script.index('"${SETTINGS[@]}" clean build'),
                        script.index('python3 "$ROOT/scripts/sign-development-helper.py"'))
        self.assertLess(script.index('python3 "$ROOT/scripts/sign-development-helper.py"'),
                        script.index('--mode development --app "$APP"'))
        self.assertLess(script.index('--mode development --app "$APP"'),
                        script.index('echo "Development build verified'))
        self.assertNotIn("||", script[script.index('"${SETTINGS[@]}" clean build'):])
        self.assertIn("CODE_SIGN_IDENTITY=-", (ROOT / "scripts/build-register.sh").read_text())
        entitlements = plistlib.loads((ROOT / "scripts/native-development.entitlements").read_bytes())
        self.assertEqual(set(entitlements), {"com.apple.application-identifier",
                         "com.apple.developer.team-identifier", "keychain-access-groups"})
        self.assertEqual(entitlements["keychain-access-groups"],
                         ["$(AppIdentifierPrefix)com.jdylanmc.CMUXMaestroPreview"])

    def signing_fixture(self):
        self.app = self.directory / "CMUX Maestro Preview.app"
        self.extension = self.app / "Contents/Extensions/CMUX Maestro Preview Extension.appex"
        (self.extension / "Contents").mkdir(parents=True, exist_ok=True)
        self.fixture("development")
        helper = self.directory / signing.HELPER_NAME
        embedded = self.app / "Contents/Helpers" / signing.HELPER_NAME
        embedded.parent.mkdir(exist_ok=True)
        for path in (helper, embedded):
            path.write_bytes(b"xcode-signed-helper")
            path.chmod(0o700)
        profiles = [target / "Contents/embedded.provisionprofile" for target in (self.app, self.extension)]
        for index, path in enumerate(profiles):
            path.write_bytes(b"untouched-profile-" + str(index).encode())
        team, identity = "SYNTHETIC1", "Apple Development: Synthetic (SYNTHETIC1)"
        identifiers = {self.app: metadata.BASE_ID, self.extension: metadata.BASE_ID + ".Extension",
                       helper: metadata.BASE_ID + ".CopilotHook", embedded: metadata.BASE_ID + ".CopilotHook"}
        expected_identifiers = dict(identifiers)
        grants = {
            self.app: {"com.apple.application-identifier": team + "." + metadata.BASE_ID,
                       "com.apple.developer.team-identifier": team,
                       "keychain-access-groups": [team + "." + metadata.BASE_ID]},
            helper: {"com.apple.application-identifier": team + "." + identifiers[helper]},
            embedded: {"com.apple.application-identifier": team + "." + identifiers[helper]},
        }
        calls = []
        state = {"failure": None, "extra-final-grant": False, "bad-parent": False, "bad-profile": False}

        def run(command, **kwargs):
            calls.append(command)
            self.assertEqual(kwargs, {"check": True, "capture_output": True})
            self.assertEqual(command[0], "/usr/bin/codesign")
            if len(calls) == state["failure"]:
                raise subprocess.CalledProcessError(1, command)
            target = Path(command[-1])
            stdout, stderr = b"", b""
            if "--force" in command:
                if target == helper:
                    helper.write_bytes(b"final-signed-helper")
                    grants[helper] = {"unexpected": True} if state["extra-final-grant"] else {}
                else:
                    self.assertEqual(target, self.app)
                    self.assertEqual(embedded.read_bytes(), b"final-signed-helper")
                    self.assertEqual(grants[helper], {})
                    if state["bad-parent"]:
                        grants[self.app] = {}
                    if state["bad-profile"]:
                        profiles[1].write_bytes(b"changed")
            elif "--verbose=4" in command:
                stderr = (f"Identifier={identifiers[target]}\nTeamIdentifier={team}\n"
                          f"Authority={identity}\nAuthority=Synthetic intermediate\n").encode()
            elif "--entitlements" in command:
                value = {} if target == embedded and embedded.read_bytes() == b"final-signed-helper" else grants[target]
                stdout = plistlib.dumps(value)
            else:
                self.assertEqual(command, [
                    "/usr/bin/codesign", "--verify", "--strict", "-R",
                    f'=anchor apple generic and identifier "{expected_identifiers[target]}"', str(target),
                ])
            return subprocess.CompletedProcess(command, 0, stdout=stdout, stderr=stderr)

        return helper, embedded, profiles, team, identity, identifiers, grants, calls, state, run

    def test_development_finalization_signs_empty_helper_then_preserves_parent_metadata(self):
        helper, embedded, profiles, team, identity, _, grants, calls, _, run = self.signing_fixture()
        parent_grants = copy.deepcopy(grants[self.app])
        profile_bytes = [path.read_bytes() for path in profiles]
        signing.finalize_development_signing(self.directory, identity, team, runner=run)
        self.assertEqual(metadata.plist(signing.EMPTY_ENTITLEMENTS), {})
        self.assertEqual([command for command in calls if "--force" in command], [
            ["/usr/bin/codesign", "--force", "--sign", identity, "--identifier",
             metadata.BASE_ID + ".CopilotHook", "--options", "runtime", "--timestamp=none",
             "--entitlements", str(signing.EMPTY_ENTITLEMENTS), str(helper)],
            ["/usr/bin/codesign", "--force", "--sign", identity,
             "--preserve-metadata=identifier,requirements,entitlements,flags,runtime",
             "--timestamp=none", str(self.app)],
        ])
        self.assertEqual(helper.read_bytes(), embedded.read_bytes())
        self.assertEqual(grants[helper], {})
        self.assertEqual(grants[self.app], parent_grants)
        self.assertEqual([path.read_bytes() for path in profiles], profile_bytes)
        parent_sign = next(i for i, command in enumerate(calls) if "--force" in command and command[-1] == str(self.app))
        self.assertEqual(calls[parent_sign - 1], [
            "/usr/bin/codesign", "-d", "--entitlements", ":-", str(embedded),
        ])
        self.assertFalse(any("--deep" in command for command in calls if "--force" in command))

    def test_every_failed_signing_command_stops_finalization(self):
        fixture = self.signing_fixture()
        signing.finalize_development_signing(self.directory, fixture[4], fixture[3], runner=fixture[-1])
        expected = fixture[7]
        for failure in range(1, len(expected) + 1):
            with self.subTest(command=expected[failure - 1]):
                _, _, _, team, identity, _, _, calls, state, run = self.signing_fixture()
                state["failure"] = failure
                with self.assertRaises(subprocess.CalledProcessError):
                    signing.finalize_development_signing(self.directory, identity, team, runner=run)
                self.assertEqual(calls, expected[:failure])

    def test_failed_helper_embedding_never_reseals_parent(self):
        _, _, _, team, identity, _, _, calls, _, run = self.signing_fixture()
        with patch.object(signing.shutil, "copy2", side_effect=OSError("synthetic copy failure")):
            with self.assertRaises(OSError):
                signing.finalize_development_signing(self.directory, identity, team, runner=run)
        self.assertEqual(len([command for command in calls if "--force" in command]), 1)

    def test_finalization_refuses_unexpected_helper_privileges_before_writes(self):
        for role in (0, 1):
            for value in (
                {"com.apple.application-identifier": "SYNTHETIC1."},
                {"com.apple.application-identifier": metadata.BASE_ID + ".CopilotHook"},
                {"com.apple.application-identifier": True},
                {"keychain-access-groups": ["SYNTHETIC1." + metadata.BASE_ID]},
                {"com.apple.developer.team-identifier": "SYNTHETIC1"},
                {"com.apple.security.network.client": True},
                {"com.apple.security.get-task-allow": "true"},
            ):
                with self.subTest(role=role, grants=value):
                    fixture = self.signing_fixture()
                    fixture[6][fixture[role]] = value
                    with self.assertRaisesRegex(ValueError, "Unexpected helper privileges"):
                        signing.finalize_development_signing(self.directory, fixture[4], fixture[3], runner=fixture[-1])
                    self.assertFalse(any("--force" in command for command in fixture[7]))

    def test_finalization_refuses_wrong_namespace_signer_and_redirected_products(self):
        for fault in ("namespace", "signer", "symlink", "hardlink", "source-entitlements"):
            with self.subTest(fault=fault):
                helper, embedded, _, team, identity, identifiers, _, calls, _, run = self.signing_fixture()
                if fault == "namespace":
                    identifiers[helper] = metadata.BASE_ID + ".WrongHelper"
                elif fault == "signer":
                    identity = "Apple Development: Other (SYNTHETIC1)"
                elif fault in ("symlink", "hardlink"):
                    embedded.unlink()
                    embedded.symlink_to(helper) if fault == "symlink" else os.link(helper, embedded)
                empty = self.directory / "not-empty.entitlements"
                empty.write_bytes(plistlib.dumps({"unexpected": True}))
                with patch.object(signing, "EMPTY_ENTITLEMENTS",
                                  empty if fault == "source-entitlements" else signing.EMPTY_ENTITLEMENTS):
                    with self.assertRaises(ValueError):
                        signing.finalize_development_signing(self.directory, identity, team, runner=run)
                self.assertFalse(any("--force" in command for command in calls))
                if fault in ("symlink", "hardlink"):
                    embedded.unlink()

    def test_finalization_checks_effective_empty_helper_and_unchanged_parent_and_profiles(self):
        for fault in ("extra-final-grant", "bad-parent", "bad-profile"):
            with self.subTest(fault=fault):
                _, _, _, team, identity, _, _, calls, state, run = self.signing_fixture()
                state[fault] = True
                with self.assertRaises(ValueError):
                    signing.finalize_development_signing(self.directory, identity, team, runner=run)
                if fault == "extra-final-grant":
                    self.assertEqual(len([command for command in calls if "--force" in command]), 1)

    def test_finalization_cli_returns_failure_without_claiming_success(self):
        with patch.object(signing, "finalize_development_signing", side_effect=ValueError("synthetic")), \
             patch.dict(os.environ, {"CMUX_DEVELOPMENT_IDENTITY": "Apple Development: Synthetic",
                                    "CMUX_DEVELOPMENT_TEAM": "SYNTHETIC1"}), \
             patch("builtins.print") as output:
            self.assertEqual(signing.main(), 1)
            self.assertIn("no verified build produced", output.call_args.args[0])

    def test_keychain_selection_and_verifier_are_noninteractive(self):
        source = (ROOT / "CMUXMaestroPreview/Integration/NativeChildAuthorization.swift").read_text()
        self.assertEqual(source.count("kSecUseDataProtectionKeychain as String: true"), 2)
        self.assertIn("authentication.interactionNotAllowed = !create", source)
        self.assertIn("guard create, status == errSecItemNotFound", source)
        verify = source.split("static func verify", 1)[1].split("static func dismiss", 1)[0]
        self.assertIn("key(create: false)", verify)
        self.assertIn("SecKeyCopyPublicKey", verify)
        self.assertNotIn("SecKeyCreateSignature", verify)
        self.assertIn("[.privateKeyUsage, .userPresence]", source)

    def test_development_packaging_rejects_bad_signatures_teams_and_profiles(self):
        self.fixture("development")
        helper = self.app / "Contents/Helpers/CMUXMaestroCopilotHook"
        helper.parent.mkdir()
        helper.write_bytes(b"synthetic")
        helper.chmod(0o700)
        team = "SYNTHETIC1"
        now = datetime.datetime.now(datetime.timezone.utc)
        fault = None
        verified_targets = []
        identifiers = {
            self.app: metadata.BASE_ID,
            self.extension: metadata.BASE_ID + ".Extension",
            helper: metadata.BASE_ID + ".CopilotHook",
        }

        def signed(command, **kwargs):
            target = Path(command[-1])
            extension = str(self.extension) in str(target)
            identifier = metadata.BASE_ID + (".Extension" if extension else "")
            e = {"com.apple.application-identifier": team + "." + identifier,
                 "com.apple.developer.team-identifier": team}
            e.update({metadata.SANDBOX_KEY: True, metadata.READ_KEY: metadata.READ_PATHS}
                     if extension else {"keychain-access-groups": [team + "." + metadata.BASE_ID]})
            if "--verify" in command:
                self.assertEqual(command, [
                    "/usr/bin/codesign", "--verify", "--strict", "--deep", "-R",
                    f'=anchor apple generic and identifier "{identifiers[target]}"', str(target),
                ])
                self.assertEqual(kwargs, {"check": True, "capture_output": True})
                verified_targets.append(target)
                if fault == "unsigned":
                    raise subprocess.CalledProcessError(1, command)
                return subprocess.CompletedProcess(command, 0, stdout=b"")
            if "--verbose=4" in command:
                actual_team = "OTHERTEAM1" if fault == "team" and extension else team
                details = "TeamIdentifier=" + actual_team + "\n"
                if fault == "adhoc":
                    details += "Signature=adhoc\n"
                return subprocess.CompletedProcess(command, 0, stderr=details.encode())
            if "--entitlements" in command:
                if target == helper and fault in ("helper-app-id", "helper-keychain", "helper-team"):
                    grant = {"com.apple.application-identifier": team + "." + identifiers[helper]} \
                        if fault == "helper-app-id" else {"keychain-access-groups": [team + "." + metadata.BASE_ID]}
                    if fault == "helper-team":
                        grant = {"com.apple.developer.team-identifier": team}
                    return subprocess.CompletedProcess(command, 0, stdout=plistlib.dumps(grant))
                return subprocess.CompletedProcess(command, 0, stdout=plistlib.dumps(
                    {} if target == helper or fault == "unentitled" else e))
            self.assertEqual(command[:3], ["/usr/bin/security", "cms", "-D"])
            if fault == "unprovisioned":
                raise subprocess.CalledProcessError(1, command)
            profile = {
                "TeamIdentifier": [team], "ApplicationIdentifierPrefix": [team],
                "CreationDate": now - datetime.timedelta(days=1), "ExpirationDate": now + datetime.timedelta(days=1),
                "ProvisionedDevices": ["synthetic-device"], "DeveloperCertificates": [b"synthetic"],
                "Entitlements": {**e, "get-task-allow": True},
            }
            if fault == "wrong-profile":
                profile["Entitlements"]["com.apple.application-identifier"] = team + ".unrelated"
            return subprocess.CompletedProcess(command, 0, stdout=plistlib.dumps(profile))

        metadata.verify_development(self.app, runner=signed)
        self.assertEqual(verified_targets, [self.app, self.extension, helper])
        for fault in ("unsigned", "adhoc", "team", "unentitled", "unprovisioned", "wrong-profile"):
            with self.subTest(fault=fault), self.assertRaises((ValueError, subprocess.CalledProcessError)):
                metadata.verify_development(self.app, runner=signed)
        for fault in ("helper-app-id", "helper-keychain", "helper-team"):
            with self.subTest(fault=fault), self.assertRaisesRegex(
                ValueError, "Helper must not gain keychain or application privileges"
            ):
                metadata.verify_development(self.app, runner=signed)

    def test_resolved_development_helper_namespace_and_no_source_grants(self):
        for configuration in ("Debug", "Release"):
            with self.subTest(configuration=configuration):
                result = subprocess.run([
                    "/usr/bin/xcodebuild", "-project", str(ROOT / "CMUXMaestroPreview.xcodeproj"),
                    "-alltargets", "-configuration", configuration, "-showBuildSettings", "-json",
                    "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=Apple Development: Synthetic",
                    "DEVELOPMENT_TEAM=SYNTHETIC1", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES",
                    f"CMUX_NATIVE_APP_ENTITLEMENTS={ROOT / 'scripts/native-development.entitlements'}",
                    "CMUX_NATIVE_APP_PROFILE=synthetic-app", "CMUX_NATIVE_EXTENSION_PROFILE=synthetic-extension",
                ], check=True, capture_output=True, env={
                    **os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                    "TMPDIR": str(self.directory),
                })
                rows = json.loads(result.stdout)
                metadata.verify_settings(rows, "development")
                targets = {row["target"]: row["buildSettings"] for row in rows}
                helper = targets["CMUXMaestroCopilotHook"]
                self.assertEqual(helper["PRODUCT_BUNDLE_IDENTIFIER"],
                                 metadata.BASE_ID + ".CopilotHook")
                self.assertEqual(helper["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"], "NO")
                self.assertFalse(helper.get("CODE_SIGN_ENTITLEMENTS"))
                self.assertFalse(helper.get("PROVISIONING_PROFILE_SPECIFIER"))
                self.assertFalse(helper.get("PROVISIONING_PROFILE"))
                self.assertEqual(helper["OTHER_CODE_SIGN_FLAGS"],
                                 "--identifier " + metadata.BASE_ID + ".CopilotHook")
                for target in ("CMUXMaestroPreview", "CMUXMaestroSidebar"):
                    self.assertEqual(targets[target]["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"], "YES")

    def test_resolved_helper_signing_namespace_in_non_development_modes(self):
        for mode in ("production", "unsigned", "tests"):
            suffix, point = metadata.PROFILES[mode]
            for configuration in ("Debug", "Release"):
                with self.subTest(mode=mode, configuration=configuration):
                    result = subprocess.run([
                        "/usr/bin/xcodebuild", "-project", str(ROOT / "CMUXMaestroPreview.xcodeproj"),
                        "-alltargets", "-configuration", configuration, "-showBuildSettings", "-json",
                        "CODE_SIGN_IDENTITY=-",
                        "CODE_SIGNING_ALLOWED=" + ("YES" if mode == "production" else "NO"),
                        "CMUX_BUNDLE_ID_SUFFIX=" + suffix,
                        "CMUX_SIDEBAR_EXTENSION_POINT_ID=" + point,
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS=" + ("" if mode == "production" else "CMUX_VALIDATION"),
                    ], check=True, capture_output=True, env={
                        **os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                        "TMPDIR": str(self.directory),
                    })
                    metadata.verify_settings(json.loads(result.stdout), mode)

    def test_scripts_pin_validation_namespaces_and_gate_explicit_publication(self):
        for name, mode in (("build-unsigned.sh", "unsigned"), ("test.sh", "tests")):
            script = (ROOT / "scripts" / name).read_text()
            suffix, point = metadata.PROFILES[mode]
            self.assertIn("CMUX_BUNDLE_ID_SUFFIX=" + suffix, script)
            self.assertIn("CMUX_SIDEBAR_EXTENSION_POINT_ID=" + point, script)
            self.assertIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_VALIDATION", script)
            self.assertIn("--settings", script)
            self.assertIn("--app", script)
            self.assertNotIn("REGISTER_APP_WITH_LAUNCH_SERVICES", script)
        script = (ROOT / "scripts/build-register.sh").read_text()
        self.assertLess(script.index('--source-entitlements'), script.index('    build\n'))
        self.assertLess(script.index('--mode production --app "$APP"'), script.index('pluginkit -a "$APPEX"'))
        self.assertLess(script.index('pluginkit -a "$APPEX"'), script.index('--registration "$APPEX"'))

    def registration_listing(self, *entries):
        return "".join(f"+    {identifier}(2)\n    Path = {path}\n" for identifier, path in entries) \
            + f"\n ({len(entries)} plug-{'in' if len(entries) == 1 else 'ins'})\n"

    def test_registration_accepts_expected_id_and_canonical_path(self):
        identifier = metadata.BASE_ID + ".Extension"
        alias = self.directory / "alias.appex"
        alias.symlink_to(self.extension, target_is_directory=True)
        metadata.verify_registration_output(self.registration_listing((identifier, alias)), self.extension)

    def test_documented_election_prefixes_preserve_exact_record_matching(self):
        identifier = metadata.BASE_ID + ".Extension"
        for prefix in ("", "+", "-", "!", "=", "?"):
            with self.subTest(prefix=prefix):
                output = self.registration_listing((identifier, self.extension)).replace("+    ", prefix + "    ")
                metadata.verify_registration_output(output, self.extension)
                with self.assertRaises(ValueError):
                    metadata.verify_registration_output(output, self.directory / "wrong.appex")
                with self.assertRaises(ValueError):
                    metadata.verify_registration_output(output, self.extension, absent=True)
                with self.assertRaises(ValueError):
                    metadata.verify_registration_output(output.replace("(1 plug-in)", "(2 plug-ins)"), self.extension)
                with self.assertRaises(ValueError):
                    metadata.verify_registration_output(output.replace(identifier, "com.example.Other"), self.extension)

    def test_unsupported_or_combined_election_prefixes_remain_invalid(self):
        output = self.registration_listing((metadata.BASE_ID + ".Extension", self.extension))
        for prefix in ("@", "*", "+=", "??", "!?"):
            with self.subTest(prefix=prefix):
                with self.assertRaises(ValueError):
                    metadata.verify_registration_output(output.replace("+    ", prefix + "    "), self.extension)

    def test_registration_rejects_no_matches_wrong_path_and_unsupported_output(self):
        identifier = metadata.BASE_ID + ".Extension"
        for output in (
            "(no matches)\n",
            "",
            self.registration_listing((identifier, self.directory / "wrong.appex")),
            f'{{"id":"{identifier}","Path":"{self.extension}"}}',
            f"+ {identifier}(2)\n    Path = {self.extension}\n",
        ):
            with self.subTest(output=output):
                with self.assertRaises(ValueError):
                    metadata.verify_registration_output(output, self.extension)

    def test_registration_duplicate_ids_require_expected_path_on_matching_record(self):
        identifier = metadata.BASE_ID + ".Extension"
        wrong = self.directory / "old.appex"
        metadata.verify_registration_output(
            self.registration_listing((identifier, wrong), (identifier, self.extension)), self.extension
        )
        with self.assertRaises(ValueError):
            metadata.verify_registration_output(
                self.registration_listing((identifier, wrong), ("com.example.Other.Extension", self.extension)),
                self.extension,
            )

    def test_registration_query_does_not_treat_zero_exit_as_discovery(self):
        with patch.object(metadata.subprocess, "run", return_value=subprocess.CompletedProcess(
            [], 0, stdout="(no matches)\n", stderr=""
        )) as runner:
            with self.assertRaises(ValueError):
                metadata.verify_registered_extension(self.extension)
            self.assertEqual(runner.call_args.args[0][-2:], ["-i", metadata.BASE_ID + ".Extension"])

    def test_project_keeps_production_defaults(self):
        project = json.loads(subprocess.check_output([
            "/usr/bin/plutil", "-convert", "json", "-o", "-",
            str(ROOT / "CMUXMaestroPreview.xcodeproj/project.pbxproj"),
        ]))
        objects = project["objects"]
        for target in objects.values():
            if target.get("isa") != "PBXNativeTarget":
                continue
            for config_id in objects[target["buildConfigurationList"]]["buildConfigurations"]:
                settings = objects[config_id]["buildSettings"]
                self.assertEqual(settings["CMUX_BUNDLE_ID_SUFFIX"], "")
                if target["name"] != "CMUXMaestroPreviewTests":
                    self.assertEqual(settings["CURRENT_PROJECT_VERSION"], metadata.APP_BUILD_VERSION)
                if target["name"] == "CMUXMaestroCopilotHook":
                    self.assertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"],
                                     metadata.BASE_ID + "$(CMUX_BUNDLE_ID_SUFFIX).CopilotHook")
                    self.assertEqual(settings["OTHER_CODE_SIGN_FLAGS"], "--identifier $(PRODUCT_BUNDLE_IDENTIFIER)")
                    self.assertEqual(settings["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"], "NO")
                else:
                    self.assertNotIn("CODE_SIGN_INJECT_BASE_ENTITLEMENTS", settings)
                if target["name"] in ("CMUXMaestroPreview", "CMUXMaestroSidebar"):
                    self.assertEqual(settings["CMUX_SIDEBAR_EXTENSION_POINT_ID"], metadata.PRODUCTION_POINT)
        metadata.verify_profile(metadata.plist(ROOT / "CMUXMaestroSidebar/CMUXMaestroSidebar.entitlements"))


if __name__ == "__main__":
    unittest.main()
