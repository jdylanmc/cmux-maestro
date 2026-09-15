#!/usr/bin/env python3
"""Synthetic filesystem + injected signatures/registries; no live app or CLI access."""

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("local_preview", ROOT / "scripts/local-preview.py")
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)
metadata = preview.metadata


class Interrupted(BaseException):
    pass


class SyntheticMac(preview.MacOperations):
    """All external commands are fake. Atomic renames/fsync use real synthetic files."""
    def __init__(self):
        self.applications = set()
        self.extensions = set()
        self.commands = []
        self.moves = []
        self.failures = {}
        self.busy = False
        self.wrong_extension = False
        self.wrong_app = False
        self.elections = {}

    def fail(self, point):
        error = self.failures.pop(point, None)
        if error:
            raise error

    def app_paths(self):
        return list(self.applications)

    def assert_idle(self, *apps):
        if self.busy:
            raise ValueError("Synthetic preview process is running; close only that process.")

    def move(self, source, destination, *, exchange=False):
        self.fail("before-move")
        self.moves.append((source, destination, exchange))
        if exchange:
            assert source.is_dir() and destination.is_dir()
        super().move(source, destination, exchange=exchange)
        assert destination.is_dir()
        self.fail("after-move")

    def run(self, command, **kwargs):
        self.commands.append(command)
        stdout, stderr = b"", b""
        if command[0] == "/usr/bin/codesign":
            target = Path(command[-1])
            app = next(path for path in [target, *target.parents] if path.suffix == ".app")
            signatures = json.loads((app / "signatures.json").read_text())
            role = "app" if target == app else "extension" if target.suffix == ".appex" else "helper"
            signature = signatures[role]
            if "--verify" in command:
                if not signature["valid"]:
                    raise subprocess.CalledProcessError(1, command)
            elif "--verbose=4" in command:
                stderr = f"Identifier={signature['id']}\nSignature={signature['signing']}\n".encode()
            else:
                stdout = plistlib.dumps(signature["entitlements"])
        elif command[0] == "/usr/bin/ditto":
            source, destination = map(Path, command[-2:])
            if "copy" in self.failures:
                destination.mkdir(exist_ok=True)
                (destination / "partial").write_bytes(b"copy-incomplete")
                # Like an interrupted framework copy: a dangling internal link.
                (destination / "Current").symlink_to("Versions/A")
                self.fail("copy")
            shutil.copytree(source, destination, symlinks=True, dirs_exist_ok=True)
            self.fail("after-copy")
        elif command[0] == preview.LSREGISTER:
            app = Path(command[-1]).resolve()
            if command[1] == "-f":
                self.fail("register")
                self.applications.add(app.parent / "Other.app" if self.wrong_app else app)
            elif command[1] == "-u":
                self.fail("unregister")
                self.applications.discard(app)
            else:
                raise AssertionError(command)
        elif command[0] == "/usr/bin/pluginkit":
            identifier = metadata.BASE_ID + ".Extension"
            if command[1] == "-a":
                extension = Path(command[-1]).resolve()
                self.extensions.add((identifier, extension.parent / "Wrong.appex" if self.wrong_extension else extension))
                self.fail("after-register")
            elif command[1] == "-r":
                self.extensions.discard((identifier, Path(command[-1]).resolve()))
            elif command[1:] == ["-m", "-A", "-D", "-vv", "-i", identifier]:
                self.fail("query")
                entries = sorted((key, path) for key, path in self.extensions if key == identifier)
                stdout = ("".join(f"{self.elections.get((key, path), '+')} {key}(2)\n    Path = {path}\n"
                                  for key, path in entries)
                          + f"({len(entries)} plug-ins)\n").encode() if entries else b"(no matches)\n"
            else:
                raise AssertionError(command)
        else:
            raise AssertionError(f"Non-injected command refused: {command}")
        if kwargs.get("text"):
            stdout, stderr = stdout.decode(), stderr.decode()
        return subprocess.CompletedProcess(command, 0, stdout, stderr)


class LocalPreviewTests(unittest.TestCase):
    def test_unverifiable_process_is_skipped_only_for_matching_kernel_zombie_state(self):
        pid = os.getpid() + 100_000
        uid = os.getuid()
        cases = [
            (0, f"{pid} {uid} Z\n", "", True),
            (0, f"{pid} {uid} Zs+\n", "", True),
            (0, f"{pid} {uid} Ss\n", "", False),
            (0, f"{pid + 1} {uid} Z\n", "", False),
            (0, f"{pid} {uid + 1} Z\n", "", False),
            (0, f"{pid} {uid} Zunknown\n", "", False),
            (0, f"{pid} {uid} Z\n{pid} {uid} Z\n", "", False),
            (0, "", "", False),
            (1, f"{pid} {uid} Z\n", "", False),
            (0, f"{pid} {uid} Z\n", "unavailable", False),
        ]
        for code, output, diagnostic, skipped in cases:
            with self.subTest(code=code, output=output, diagnostic=diagnostic):
                operations = preview.MacOperations()
                library = SimpleNamespace(proc_pidpath=Mock(return_value=0))
                with patch.object(preview.ctypes, "CDLL", return_value=library), patch.object(
                    operations, "run",
                    side_effect=[
                        SimpleNamespace(stdout=f"{pid} {uid}\n"),
                        SimpleNamespace(returncode=code, stdout=output, stderr=diagnostic),
                    ],
                ) as run, patch.object(preview.os, "kill") as probe:
                    if skipped:
                        operations.assert_idle(self.app)
                    else:
                        with self.assertRaisesRegex(ValueError, "Cannot verify executable"):
                            operations.assert_idle(self.app)
                    probe.assert_called_once_with(pid, 0)
                    self.assertEqual(run.call_args_list[-1].args[0], [
                        "/bin/ps", "-p", str(pid), "-o", "pid=", "-o", "uid=", "-o", "stat=",
                    ])

    def setUp(self):
        self.root = ROOT / ".build/local-preview-tests" / uuid.uuid4().hex
        self.home = self.root / "home"
        self.home.mkdir(parents=True, mode=0o700)
        self.ops = SyntheticMac()
        self.app = self.home / "Applications" / preview.DEFAULT_NAME
        self.old = self.fixture("old")
        self.new = self.fixture("new")
        self.latest = self.fixture("latest")
        self.data = self.home / "Library/Application Support/CMUXMaestroPreview/Copilot/keep.json"
        self.data.parent.mkdir(parents=True)
        self.data.write_text("observation-data")
        self.legacy = self.home / ".copilot/legacy-and-native-settings.json"
        self.legacy.parent.mkdir()
        self.legacy.write_text("not-installer-owned")

    def tearDown(self):
        shutil.rmtree(self.root)

    def fixture(self, name, version="2", profile=None, *, orchestration=True):
        app = self.root / f"{name}.app"
        extension = app / preview.EXTENSION
        (app / "Contents/MacOS").mkdir(parents=True)
        (extension / "Contents/MacOS").mkdir(parents=True)
        helper = app / "Contents/Helpers/CMUXMaestroCopilotHook"
        helper.parent.mkdir()
        resources = app / "Contents/Resources"
        resources.mkdir()
        if orchestration:
            (resources / "cmux-maestro-orchestrator.py").write_text("#!/usr/bin/env python3\n")
            (resources / "SKILL.md").write_text("---\nname: cmux-maestro-orchestrate\n---\n")
        parent = {"CFBundleIdentifier": metadata.BASE_ID, "CFBundlePackageType": "APPL",
                  "CFBundleVersion": version, "CFBundleExecutable": "Preview"}
        child = {"CFBundleIdentifier": metadata.BASE_ID + ".Extension", "CFBundlePackageType": "XPC!",
                 "CFBundleVersion": version, "CFBundleExecutable": "Sidebar",
                 "EXAppExtensionAttributes": {"EXExtensionPointIdentifier": metadata.PRODUCTION_POINT}}
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(parent))
        (extension / "Contents/Info.plist").write_bytes(plistlib.dumps(child))
        for binary in [helper, app / "Contents/MacOS/Preview", extension / "Contents/MacOS/Sidebar"]:
            binary.write_bytes(b"synthetic-executable-" + name.encode())
            binary.chmod(0o755)
        (app / "payload").write_text(name)
        signature = lambda ending, entitlements: {
            "valid": True, "id": metadata.BASE_ID + ending, "signing": "adhoc", "entitlements": entitlements
        }
        (app / "signatures.json").write_text(json.dumps({
            "app": signature("", {}),
            "extension": signature(".Extension", profile if profile is not None else {
                metadata.SANDBOX_KEY: True, metadata.READ_KEY: metadata.READ_PATHS,
            }),
            "helper": signature(".CopilotHook", {
                "com.apple.application-identifier": metadata.BASE_ID + ".CopilotHook",
                "com.apple.security.get-task-allow": True,
            }),
        }))
        return app

    def installer(self, destination=None):
        return preview.Installer(self.home, destination, self.ops)

    def test_helper_identity_entitlement_is_optional_but_must_match_exactly(self):
        for entitlements in ({}, {
            "com.apple.application-identifier": metadata.BASE_ID + ".CopilotHook",
            "com.apple.security.get-task-allow": True,
        }):
            self.change_signature(self.old, "helper", "entitlements", entitlements)
            self.assertEqual(self.ops.verify(self.old, current=True), "2")

    def test_invalid_helper_identity_or_extra_privileges_are_refused_before_staging(self):
        for index, entitlements in enumerate([
            {"com.apple.application-identifier": metadata.BASE_ID},
            {"com.apple.application-identifier": "OTHERTEAM." + metadata.BASE_ID + ".CopilotHook"},
            {"com.apple.application-identifier": ""},
            {"com.apple.application-identifier": True},
            {"com.apple.application-identifier": metadata.BASE_ID + ".CopilotHook",
             "com.apple.security.network.client": True},
        ]):
            with self.subTest(entitlements=entitlements):
                source = self.fixture("invalid-helper-" + str(index))
                self.change_signature(source, "helper", "entitlements", entitlements)
                with self.assertRaises(ValueError):
                    self.operation("install", source)
                self.assertFalse(self.app.exists())
                self.assertIsNone(self.receipt()["transaction"])

    def operation(self, name, *args, **kwargs):
        installer = self.installer()
        with installer.locked():
            result = getattr(installer, name)(*args, **kwargs)
        return result

    def receipt(self):
        return json.loads((self.app.parent / preview.STATE_NAME / "receipt.json").read_text())

    def previous(self):
        receipt = self.receipt()
        return self.app.parent / preview.STATE_NAME / receipt["previous"]["slot"]

    def change_signature(self, app, role, key, value):
        path = app / "signatures.json"
        signatures = json.loads(path.read_text())
        signatures[role][key] = value
        path.write_text(json.dumps(signatures))

    def test_first_install_stable_copy_and_exact_registration(self):
        self.operation("install", self.old)
        self.assertEqual((self.app / "payload").read_text(), "old")
        self.assertTrue(self.old.exists())
        self.assertIsNone(self.receipt()["previous"])
        self.assertIn(self.app, self.ops.applications)
        self.assertIn((metadata.BASE_ID + ".Extension", self.app / preview.EXTENSION), self.ops.extensions)
        self.assertFalse(self.ops.moves[0][2])
        self.assertIn("Verified installed preview", self.operation("status"))
        self.assertEqual(self.data.read_text(), "observation-data")

    def test_prepare_update_retires_only_owned_registration_and_supports_update(self):
        self.operation("install", self.old)
        unrelated = self.fixture("unrelated")
        self.ops.register(unrelated)
        before = self.receipt()
        digest = preview.digest(self.app)
        self.assertIn("registration retired", self.operation("prepare_update"))
        self.assertEqual(self.receipt(), before)
        self.assertEqual(preview.digest(self.app), digest)
        self.assertNotIn(self.app, self.ops.applications)
        self.assertIn(unrelated, self.ops.applications)
        self.assertIn((metadata.BASE_ID + ".Extension", unrelated / preview.EXTENSION), self.ops.extensions)
        self.assertEqual(self.data.read_text(), "observation-data")
        self.assertEqual(self.legacy.read_text(), "not-installer-owned")
        self.operation("prepare_update")
        self.operation("install", self.new, update=True)
        self.assertIn("Verified installed preview", self.operation("status"))

    def test_prepare_update_can_be_undone_by_ordinary_recovery(self):
        self.operation("install", self.old)
        before = self.receipt()
        self.operation("prepare_update")
        self.operation("recover")
        self.assertEqual(self.receipt(), before)
        self.assertIn("Verified installed preview", self.operation("status"))

    def test_one_recovery_restores_registration_after_prepared_update_failure(self):
        self.operation("install", self.old)
        self.operation("install", self.new, update=True)
        unrelated = self.fixture("unrelated")
        self.ops.register(unrelated)
        before = self.receipt()
        for point in ("copy", "before-move"):
            with self.subTest(point=point):
                self.operation("prepare_update")
                self.ops.failures[point] = OSError("synthetic update failure")
                with self.assertRaises(OSError):
                    self.operation("install", self.latest, update=True)
                self.operation("recover")
                self.assertEqual(self.receipt(), before)
                self.assertEqual((self.app / "payload").read_text(), "new")
                self.assertEqual((self.previous() / "payload").read_text(), "old")
                self.assertIn("Verified installed preview", self.operation("status"))
                self.assertIn(unrelated, self.ops.applications)
                self.assertEqual(self.data.read_text(), "observation-data")

    def test_one_recovery_restores_registration_after_prepared_rollback_failure(self):
        self.operation("install", self.old)
        self.operation("install", self.new, update=True)
        before = self.receipt()
        self.operation("prepare_update")
        self.ops.failures["before-move"] = OSError("synthetic rollback failure")
        with self.assertRaises(OSError):
            self.operation("rollback")
        self.operation("recover")
        self.assertEqual(self.receipt(), before)
        self.assertIn("Verified installed preview", self.operation("status"))
        self.assertEqual((self.previous() / "payload").read_text(), "old")

    def test_prepare_update_preserves_files_when_registration_retirement_fails(self):
        self.operation("install", self.old)
        before = self.receipt()
        digest = preview.digest(self.app)
        self.ops.failures["unregister"] = OSError("synthetic registry failure")
        with self.assertRaises(OSError):
            self.operation("prepare_update")
        self.assertEqual(self.receipt(), before)
        self.assertEqual(preview.digest(self.app), digest)
        self.operation("recover")
        self.assertIn("Verified installed preview", self.operation("status"))

    def test_prepare_update_does_not_claim_readiness_while_a_process_remains(self):
        self.operation("install", self.old)
        before = self.receipt()
        self.ops.busy = True
        with self.assertRaisesRegex(ValueError, "running"):
            self.operation("prepare_update")
        self.assertEqual(self.receipt(), before)
        self.ops.busy = False
        self.operation("recover")
        self.assertIn("Verified installed preview", self.operation("status"))

    def test_prepare_update_refuses_unowned_tampered_and_pending_apps(self):
        with self.assertRaisesRegex(ValueError, "No owned"):
            self.operation("prepare_update")
        self.assertEqual(self.ops.commands, [])
        self.operation("install", self.old)
        (self.app / "payload").write_text("tampered")
        before = len(self.ops.commands)
        with self.assertRaises(ValueError):
            self.operation("prepare_update")
        self.assertFalse(any(command[:2] in ([preview.LSREGISTER, "-u"], ["/usr/bin/pluginkit", "-r"])
                             for command in self.ops.commands[before:]))
        (self.app / "payload").write_text("old")
        self.ops.failures["after-move"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("install", self.new, update=True)
        before = len(self.ops.commands)
        with self.assertRaisesRegex(ValueError, "recover"):
            self.operation("prepare_update")
        self.assertEqual(len(self.ops.commands), before)

    def test_atomic_updates_preserve_one_previous_and_rollback_is_reversible(self):
        self.operation("install", self.old)
        self.operation("install", self.new, update=True)
        self.assertEqual((self.previous() / "payload").read_text(), "old")
        self.operation("install", self.latest, update=True)
        self.assertEqual((self.previous() / "payload").read_text(), "new")
        self.assertEqual(len(list((self.app.parent / preview.STATE_NAME).glob("slot-*.app"))), 1)
        self.assertEqual([move[2] for move in self.ops.moves], [False, True, True])
        self.operation("rollback")
        self.assertEqual((self.app / "payload").read_text(), "new")
        self.assertEqual((self.previous() / "payload").read_text(), "latest")
        self.operation("rollback")
        self.assertEqual((self.app / "payload").read_text(), "latest")

    def test_rollback_validates_older_own_version_and_lower_privilege_profile(self):
        older = self.fixture("v1", "1", {metadata.SANDBOX_KEY: True})
        # Simulate an installation made by the previous version of this tool.
        with patch.object(metadata, "APP_BUILD_VERSION", "1"), patch.object(metadata, "READ_PATHS", []):
            signatures = json.loads((older / "signatures.json").read_text())
            signatures["extension"]["entitlements"][metadata.READ_KEY] = []
            (older / "signatures.json").write_text(json.dumps(signatures))
            self.operation("install", older)
        self.operation("install", self.new, update=True)
        self.operation("rollback")
        self.assertEqual(self.receipt()["current"]["version"], "1")
        with self.assertRaises(ValueError):
            metadata.verify_metadata(older, "production")

    def test_owned_pre_orchestration_install_can_prepare_upgrade_recover_and_rollback(self):
        previous_paths = [
            path for path in metadata.READ_PATHS if path != metadata.ORCHESTRATION_READ_PATH
        ]
        legacy = self.fixture(
            "pre-orchestration",
            profile={metadata.SANDBOX_KEY: True, metadata.READ_KEY: previous_paths},
            orchestration=False,
        )
        with self.assertRaisesRegex(ValueError, "orchestration controller"):
            self.operation("install", legacy)

        verify_metadata = metadata.verify_metadata

        def previous_metadata(app, mode, **kwargs):
            kwargs["require_orchestration"] = False
            return verify_metadata(app, mode, **kwargs)

        with patch.object(metadata, "READ_PATHS", previous_paths), patch.object(
            metadata, "verify_metadata", side_effect=previous_metadata
        ):
            self.operation("install", legacy)

        self.assertIn("Verified installed preview", self.operation("status"))
        self.operation("prepare_update")
        self.operation("recover")
        self.assertIn("Verified installed preview", self.operation("status"))
        self.operation("install", self.new, update=True)
        self.assertEqual((self.app / "payload").read_text(), "new")
        self.operation("rollback")
        self.assertEqual((self.app / "payload").read_text(), "pre-orchestration")
        self.assertIn("Verified installed preview", self.operation("status"))
        with self.assertRaisesRegex(ValueError, "orchestration controller"):
            metadata.verify_metadata(legacy, "production")

    def test_owned_modern_profile_cannot_omit_or_partially_drop_orchestration_assets(self):
        missing = self.fixture("missing-modern-assets", orchestration=False)
        partial = self.fixture("partial-modern-assets")
        (partial / "Contents/Resources/SKILL.md").unlink()
        for app in (missing, partial):
            with self.subTest(app=app):
                with self.assertRaisesRegex(ValueError, "orchestration"):
                    metadata.verify_local_preview(app, current=False, runner=self.ops.run)

    def test_update_cannot_force_downgrade_or_adopt_validation_build(self):
        future = self.fixture("future", "3")
        with patch.object(metadata, "APP_BUILD_VERSION", "3"):
            self.operation("install", future)
        with self.assertRaisesRegex(ValueError, "downgrade"):
            self.operation("install", self.new, update=True)
        self.assertEqual(self.receipt()["current"]["version"], "3")

    def test_identical_build_noop_and_wrong_command_are_refused(self):
        with self.assertRaises(ValueError):
            self.operation("install", self.old, update=True)
        self.operation("install", self.old)
        for source, update in [(self.old, True), (self.new, False)]:
            with self.assertRaises(ValueError):
                self.operation("install", source, update=update)
        self.assertIsNone(self.receipt()["transaction"])

    def test_wrong_ids_points_unsigned_and_arbitrary_signers_are_refused(self):
        mutations = [
            ("app-id", lambda app: self.change_plist(app, False, "CFBundleIdentifier", "com.example.Other")),
            ("validation", lambda app: self.change_plist(
                app, False, "CFBundleIdentifier", metadata.BASE_ID + ".Validation.Tests")),
            ("extension-id", lambda app: self.change_plist(app, True, "CFBundleIdentifier", "com.example.Other")),
            ("point", lambda app: self.change_plist(
                app, True, "EXAppExtensionAttributes", {"EXExtensionPointIdentifier": "test.point"})),
            ("unsigned", lambda app: self.change_signature(app, "app", "valid", False)),
            ("helper-id", lambda app: self.change_signature(app, "helper", "id", "com.example.Helper")),
            ("helper-unsigned", lambda app: self.change_signature(app, "helper", "valid", False)),
            ("sidebar-unsigned", lambda app: self.change_signature(app, "extension", "valid", False)),
            ("signer", lambda app: self.change_signature(app, "app", "signing", "Developer ID")),
            ("sandbox", lambda app: self.change_signature(app, "extension", "entitlements", {})),
            ("helper-privileges", lambda app: self.change_signature(
                app, "helper", "entitlements", {"com.apple.security.network.client": True})),
        ]
        for name, mutate in mutations:
            with self.subTest(name=name):
                app = self.fixture(name)
                mutate(app)
                with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    self.operation("install", app)
                self.assertFalse(self.app.exists())
                self.assertFalse(self.ops.applications)

    def change_plist(self, app, extension, key, value):
        path = (app / preview.EXTENSION if extension else app) / "Contents/Info.plist"
        contents = plistlib.loads(path.read_bytes())
        contents[key] = value
        path.write_bytes(plistlib.dumps(contents))

    def test_unknown_or_broader_previous_entitlements_refused_even_with_matching_receipt(self):
        self.operation("install", self.old)
        self.operation("install", self.new, update=True)
        for profile in (
            {metadata.SANDBOX_KEY: False},
            {metadata.SANDBOX_KEY: True, metadata.READ_KEY: ["/"]},
            {metadata.SANDBOX_KEY: True, "com.apple.security.network.client": True},
        ):
            with self.subTest(profile=profile):
                previous = self.previous()
                self.change_signature(previous, "extension", "entitlements", profile)
                path = self.app.parent / preview.STATE_NAME / "receipt.json"
                receipt = self.receipt()
                receipt["previous"]["identity"]["sha256"] = preview.digest(previous)
                path.write_text(json.dumps(receipt))
                with self.assertRaises(ValueError):
                    self.operation("rollback")
        self.assertEqual((self.app / "payload").read_text(), "new")

    def test_unowned_destination_is_never_adopted_even_when_it_is_maestro(self):
        self.app.parent.mkdir()
        shutil.copytree(self.old, self.app)
        with self.assertRaisesRegex(ValueError, "ownership receipt"):
            self.operation("install", self.new)
        self.assertEqual((self.app / "payload").read_text(), "old")

    def test_root_alternate_and_symlink_components_are_refused(self):
        with patch.object(preview.os, "getuid", return_value=0):
            with self.assertRaises(ValueError):
                self.installer()
        for path in (self.root / "Other.app", Path("/Applications/Other.app"), self.app.parent / "../Other.app"):
            with self.assertRaises(ValueError):
                self.installer(path)
        self.app.parent.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "Symlink"):
            self.operation("install", self.old)

    def test_valid_alternate_is_bound_to_singleton_receipt(self):
        alternate = self.app.parent / "My Maestro Preview.app"
        installer = self.installer(alternate)
        with installer.locked():
            installer.install(self.old)
        self.assertTrue(alternate.exists())
        with self.assertRaisesRegex(ValueError, "receipt/destination"):
            self.operation("status")

    def test_symlink_destination_source_state_lock_and_receipt_refused(self):
        self.app.parent.mkdir()
        self.app.symlink_to(self.old)
        with self.assertRaises(ValueError):
            self.operation("install", self.new)
        self.app.unlink()
        source_alias = self.root / "alias.app"
        source_alias.symlink_to(self.old)
        with self.assertRaises(ValueError):
            self.operation("install", source_alias)
        state = self.app.parent / preview.STATE_NAME
        for member in ("lock", "receipt.json"):
            path = state / member
            saved = path.read_bytes()
            path.unlink()
            path.symlink_to(self.legacy)
            with self.assertRaises(ValueError):
                self.operation("install", self.old)
            path.unlink()
            path.write_bytes(saved)
            path.chmod(0o600)
        shutil.rmtree(state)
        state.symlink_to(self.root)
        with self.assertRaises(ValueError):
            self.operation("install", self.old)
        self.assertEqual(self.legacy.read_text(), "not-installer-owned")

    def test_internal_framework_links_allowed_but_escaping_and_hardlinks_refused(self):
        framework = self.old / "Framework"
        (framework / "Versions/A").mkdir(parents=True)
        (framework / "Versions/A/Binary").write_text("framework")
        (framework / "Versions/Current").symlink_to("A")
        (framework / "Binary").symlink_to("Versions/Current/Binary")
        self.operation("install", self.old)
        (self.new / "escape").symlink_to(self.legacy)
        with self.assertRaises(ValueError):
            self.operation("install", self.new, update=True)
        (self.new / "escape").unlink()
        os.link(self.legacy, self.new / "hardlink")
        with self.assertRaises(ValueError):
            self.operation("install", self.new, update=True)

    def test_concurrent_lock_and_stale_kernel_lock_recovery(self):
        first = self.installer()
        with first.locked():
            with self.assertRaisesRegex(ValueError, "holds the install lock"):
                self.operation("install", self.old)
        self.operation("install", self.old)
        self.assertTrue((first.state / "lock").exists())

    def test_all_mutating_tool_forms_route_through_the_lock_guardian(self):
        commands = [
            ["/usr/bin/ditto", str(self.old), str(self.app)],
            [preview.LSREGISTER, "-f", str(self.app)],
            [preview.LSREGISTER, "-u", str(self.app)],
            ["/usr/bin/pluginkit", "-a", str(self.app / preview.EXTENSION)],
            ["/usr/bin/pluginkit", "-r", str(self.app / preview.EXTENSION)],
        ]
        with self.installer().locked():
            with patch.object(preview.command_worker, "run") as guarded, \
                    patch.object(preview.subprocess, "run") as direct:
                for command in commands:
                    preview.MacOperations.run(self.ops, command)
                    self.assertEqual(guarded.call_args.args, (self.ops.install_lock_fd, command))
                self.assertEqual(guarded.call_count, len(commands))
                direct.assert_not_called()
                preview.MacOperations.run(self.ops, ["/usr/bin/pluginkit", "-m"])
                direct.assert_called_once()
        with self.assertRaisesRegex(ValueError, "active install lock"):
            preview.MacOperations.run(self.ops, commands[0])

    def wait_for(self, predicate, description):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.015)
        self.fail("Timed out waiting for synthetic " + description)

    def process_gone(self, pid):
        try:
            os.kill(pid, 0)
            return False
        except ProcessLookupError:
            return True

    def assert_surviving_mutator_blocks_recovery(self, *, descendant=False, timeout=False, guardian_failure=False):
        registry = self.root / "synthetic-registry"
        original_run = self.ops.run

        def tracked_registry(command, **kwargs):
            result = original_run(command, **kwargs)
            if command[:2] == ["/usr/bin/pluginkit", "-a"] and command[-1] == str(self.app / preview.EXTENSION):
                registry.write_text("current-registered")
            if command[:2] == ["/usr/bin/pluginkit", "-r"] and command[-1] == str(self.app / preview.EXTENSION):
                registry.write_text("current-removed")
            return result

        self.ops.run = tracked_registry
        self.operation("install", self.old)
        worker = self.root / "synthetic-mutator.py"
        worker.write_text("""
import os, sys, time
from pathlib import Path
root = Path(sys.argv[1])
if sys.argv[2] == "descendant":
    if os.fork():
        os._exit(0)
# Deliberately retain neither a lock descriptor nor stdout/stderr pipes.
os.closerange(0, 65536)
(root / "worker-ready").write_text(str(os.getpid()))
deadline = time.monotonic() + 20
while not (root / "release-worker").exists():
    if time.monotonic() > deadline:
        (root / "worker-finished").write_text("timed-out")
        os._exit(72)
    time.sleep(0.015)
(root / "synthetic-registry").write_text("old-deregistered")
(root / "worker-finished").write_text("mutated")
os._exit(0)
""")
        caller = self.root / "synthetic-installer.py"
        caller.write_text("""
import importlib.util, subprocess, sys
from pathlib import Path
sys.dont_write_bytecode = True
root, repo = Path(sys.argv[1]), Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("fixtures", repo / "scripts/test-local-preview.py")
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
preview = fixtures.preview
home = root / "home"
app = home / "Applications" / preview.DEFAULT_NAME
class Operations(fixtures.SyntheticMac):
    def run(self, command, **kwargs):
        if command[:2] == ["/usr/bin/pluginkit", "-r"] and command[-1] == str(app / preview.EXTENSION):
            preview.command_worker.run(
                self.install_lock_fd, [sys.executable, str(root / "synthetic-mutator.py"), str(root), sys.argv[3]],
                timeout=0.5 if sys.argv[4] == "timeout" else 120,
            )
        return super().run(command, **kwargs)
ops = Operations()
ops.applications.add(app)
ops.extensions.add((preview.metadata.BASE_ID + ".Extension", app / preview.EXTENSION))
try:
    installer = preview.Installer(home, operations=ops)
    with installer.locked():
        installer.uninstall(hooks_retired=True)
except subprocess.TimeoutExpired:
    (root / "caller-timed-out").write_text("no worker was terminated")
""")
        parent = None
        guardian_pid = worker_pid = None
        with (self.root / "caller.log").open("wb") as log:
            try:
                parent = subprocess.Popen(
                    [sys.executable, str(caller), str(self.root), str(ROOT),
                     "descendant" if descendant else "direct", "timeout" if timeout else "kill"],
                    stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                )
                self.wait_for(lambda: (self.root / "worker-ready").exists(), "mutator handshake")
                worker_pid = int((self.root / "worker-ready").read_text())
                lock_path = self.app.parent / preview.STATE_NAME / "lock"

                def running_marker():
                    try:
                        record = json.loads(lock_path.read_text())
                        return record if record["state"] == "running" and record["group"] else None
                    except (json.JSONDecodeError, KeyError):
                        return None

                marker = self.wait_for(running_marker, "guardian handshake")
                guardian_pid = marker["supervisor"]
                if descendant:
                    self.wait_for(lambda: self.process_gone(marker["group"]), "exited direct child")
                    self.assertFalse(self.process_gone(worker_pid))
                if guardian_failure:
                    # This PID is the controlled guardian for this synthetic worker.
                    os.kill(guardian_pid, signal.SIGKILL)
                    self.assertEqual(parent.wait(timeout=5), 1)
                    self.assertTrue(self.process_gone(guardian_pid))
                elif timeout:
                    parent.wait(timeout=10)
                    self.assertEqual(parent.returncode, 0)
                    self.assertTrue((self.root / "caller-timed-out").exists())
                else:
                    self.assertIsNone(parent.poll())
                    parent.kill()  # Only this test's synthetic installer, never an app/session/tool.
                    self.assertEqual(parent.wait(timeout=5), -9)
                if not guardian_failure:
                    self.assertFalse(self.process_gone(guardian_pid))
                self.assertEqual(registry.read_text(), "current-registered")
                self.assertEqual(self.receipt()["transaction"]["kind"], "uninstall")
                for action, args in (("recover", ()), ("install", (self.latest,))):
                    with self.assertRaisesRegex(ValueError, "without proving completion" if guardian_failure
                                                else "holds the install lock"):
                        self.operation(action, *args)
                (self.root / "release-worker").touch()
                self.wait_for(lambda: (self.root / "worker-finished").exists(), "old mutation completion")
                self.assertEqual((self.root / "worker-finished").read_text(), "mutated")
                self.wait_for(lambda: self.process_gone(guardian_pid), "guardian completion")
                if guardian_failure:
                    self.wait_for(lambda: not preview.command_worker.group_alive(marker["group"]),
                                  "orphaned foreground group completion")
                self.assertEqual(registry.read_text(), "old-deregistered")
                self.operation("recover")
                self.assertFalse(self.app.exists())
                self.operation("install", self.latest)
                self.assertEqual((self.app / "payload").read_text(), "latest")
                self.assertEqual(registry.read_text(), "current-registered")
                self.assertTrue(self.process_gone(worker_pid))
            finally:
                (self.root / "release-worker").touch()
                if parent is not None:
                    if parent.poll() is None:
                        parent.kill()
                    parent.wait(timeout=5)
                for pid in (guardian_pid, worker_pid):
                    if pid:
                        self.wait_for(lambda pid=pid: self.process_gone(pid), "fixture worker cleanup")

    def test_killed_parent_does_not_release_surviving_mutators_lock(self):
        self.assert_surviving_mutator_blocks_recovery()

    def test_killed_parent_waits_for_descriptor_closing_descendant_after_direct_child_exit(self):
        self.assert_surviving_mutator_blocks_recovery(descendant=True)

    def test_caller_timeout_leaves_mutator_guardian_holding_lock(self):
        self.assert_surviving_mutator_blocks_recovery(timeout=True)

    def test_dead_guardian_and_direct_child_cannot_hide_descriptor_closing_mutator(self):
        self.assert_surviving_mutator_blocks_recovery(descendant=True, guardian_failure=True)

    def test_unacknowledged_launch_gate_cannot_start_a_mutator(self):
        read_fd, write_fd = os.pipe()
        sentinel = self.root / "must-not-be-written"
        try:
            process = subprocess.Popen(
                [sys.executable, "-I", "-S", "-B", str(ROOT / "scripts/preview-command-worker.py"),
                 "--gate", str(read_fd), sys.executable, "-c",
                 "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('mutated')", str(sentinel)],
                pass_fds=(read_fd,), start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
        finally:
            os.close(read_fd)
            os.close(write_fd)
        stdout, stderr = process.communicate(timeout=5)
        self.assertEqual((process.returncode, stdout, stderr), (0, b"", b""))
        self.assertFalse(sentinel.exists())

    def test_failed_tool_exec_releases_guard_only_after_worker_exit(self):
        with self.installer().locked():
            with self.assertRaises(subprocess.CalledProcessError):
                preview.command_worker.run(self.ops.install_lock_fd, [str(self.root / "missing-tool")])
            self.assertIsNone(preview.command_worker.read_marker(self.ops.install_lock_fd))
        self.operation("install", self.old)

    def test_unproven_guardian_completion_fails_closed_and_prepared_state_recovers(self):
        self.operation("install", self.old)
        installer = self.installer()
        with installer.locked():
            preview.command_worker.write_marker(self.ops.install_lock_fd, {
                "schema": 1, "state": "running", "token": "a" * 32, "supervisor": 9114, "group": 9115,
            })
        with patch.object(preview.command_worker, "group_alive", return_value=True) as alive:
            for action, args in (("recover", ()), ("install", (self.new,))):
                with self.assertRaisesRegex(ValueError, "without proving completion"):
                    self.operation(action, *args)
            self.assertEqual(alive.call_count, 2)
        with patch.object(preview.command_worker, "group_alive", return_value=False):
            self.operation("recover")
        with installer.locked():
            preview.command_worker.write_marker(self.ops.install_lock_fd, {
                "schema": 1, "state": "running", "token": "c" * 32, "supervisor": 9114, "group": None,
            })
        with patch.object(preview.command_worker, "group_alive", side_effect=AssertionError("Unlaunched group queried")):
            self.operation("recover")
        # Synthetic prepared marker has no launched worker; no guardian FD exists.
        lock = installer.state / "lock"
        fd = os.open(lock, os.O_RDWR)
        try:
            preview.command_worker.write_marker(fd, {
                "schema": 1, "state": "prepared", "token": "b" * 32, "supervisor": None, "group": None,
            })
        finally:
            os.close(fd)
        self.operation("recover")
        self.assertEqual(lock.read_bytes(), b"")
        self.assertEqual((self.app / "payload").read_text(), "old")

    def test_running_preview_refuses_before_replacement_without_signals(self):
        self.operation("install", self.old)
        self.ops.busy = True
        with self.assertRaisesRegex(ValueError, "running"):
            self.operation("install", self.new, update=True)
        self.assertIsNone(self.receipt()["transaction"])
        self.assertEqual((self.app / "payload").read_text(), "old")

    def test_process_adapter_checks_exact_executable_ancestry_not_name_prefix(self):
        def lookup(pid, buffer, length):
            value = os.fsencode(executable) + b"\0"
            preview.ctypes.memmove(buffer, value, len(value))
            return len(value)

        listing = subprocess.CompletedProcess([], 0, f"43210 {os.getuid()}\n", "")
        with patch.object(preview.ctypes, "CDLL", return_value=SimpleNamespace(proc_pidpath=lookup)), \
                patch.object(self.ops, "run", return_value=listing), patch.object(preview.os, "kill") as signal:
            executable = self.app / "Contents/MacOS/Preview"
            with self.assertRaisesRegex(ValueError, "43210"):
                preview.MacOperations.assert_idle(self.ops, self.app)
            executable = self.app.parent / (self.app.name + ".other") / "Contents/MacOS/Preview"
            preview.MacOperations.assert_idle(self.ops, self.app)
            signal.assert_not_called()

    def test_ditto_preserves_verified_tree_in_preallocated_owned_slot(self):
        staged = self.root / "staged.app"
        staged.mkdir(mode=0o700)
        node = preview.directory_identity(staged)

        def copy_only(command, **kwargs):
            self.assertEqual(command, ["/usr/bin/ditto", str(self.old), str(staged)])
            return subprocess.run(command, check=True, capture_output=True)

        with patch.object(self.ops, "run", side_effect=copy_only):
            self.ops.copy(self.old, staged)
        self.assertEqual(preview.directory_identity(staged), node)
        self.assertEqual(preview.digest(staged), preview.digest(self.old))

    def test_copy_and_disk_failure_recover_without_losing_old_or_data(self):
        self.operation("install", self.old)
        self.ops.failures["copy"] = OSError("synthetic ENOSPC")
        with self.assertRaises(OSError):
            self.operation("install", self.new, update=True)
        self.assertEqual(self.receipt()["transaction"]["phase"], "copying")
        self.assertEqual((self.app / "payload").read_text(), "old")
        with self.assertRaisesRegex(ValueError, "Pending"):
            self.operation("install", self.latest, update=True)
        self.operation("recover")
        self.assertIsNone(self.receipt()["transaction"])
        self.assertEqual(self.data.read_text(), "observation-data")
        self.assertEqual(self.legacy.read_text(), "not-installer-owned")

    def test_interrupted_first_install_before_or_after_exchange(self):
        for point in ("after-copy", "before-move", "after-move"):
            with self.subTest(point=point):
                if self.app.exists():
                    self.operation("uninstall", hooks_retired=True)
                self.ops.failures[point] = Interrupted()
                with self.assertRaises(Interrupted):
                    self.operation("install", self.old)
                committed = self.app.exists()
                self.operation("recover")
                self.assertEqual(self.app.exists(), committed)
                self.assertIsNone(self.receipt()["transaction"])

    def test_interrupted_update_before_commit_is_cancelled_after_commit_is_finished(self):
        self.operation("install", self.old)
        for point in ("before-move", "after-move"):
            with self.subTest(point=point):
                self.ops.failures[point] = Interrupted()
                with self.assertRaises(Interrupted):
                    self.operation("install", self.new, update=True)
                self.operation("recover")
                expected = "old" if point == "before-move" else "new"
                self.assertEqual((self.app / "payload").read_text(), expected)
        self.assertEqual((self.previous() / "payload").read_text(), "old")

    def test_interrupted_precommit_discard_is_resumable(self):
        self.operation("install", self.old)
        self.ops.failures["before-move"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("install", self.new, update=True)

        def partially_deleted(path):
            (path / "payload").unlink()
            raise Interrupted()

        with patch.object(preview.shutil, "rmtree", side_effect=partially_deleted):
            with self.assertRaises(Interrupted):
                self.operation("recover")
        self.assertEqual(self.receipt()["transaction"]["phase"], "discarding")
        self.operation("recover")
        self.assertIsNone(self.receipt()["transaction"])
        self.assertEqual((self.app / "payload").read_text(), "old")

    def test_registration_failure_keeps_both_apps_and_explicit_revert_restores_old(self):
        self.operation("install", self.old)
        for point in ("register", "after-register"):
            with self.subTest(point=point):
                self.ops.failures[point] = OSError("synthetic registry failure")
                with self.assertRaises(OSError):
                    self.operation("install", self.new, update=True)
                self.assertEqual((self.app / "payload").read_text(), "new")
                slot = self.app.parent / preview.STATE_NAME / self.receipt()["transaction"]["slot"]
                self.assertEqual((slot / "payload").read_text(), "old")
                self.operation("recover", restore_previous=True)
                self.assertEqual((self.app / "payload").read_text(), "old")
                self.assertIsNone(self.receipt()["transaction"])

    def test_exact_app_and_extension_registry_checks_not_exit_zero(self):
        for attribute in ("wrong_app", "wrong_extension"):
            with self.subTest(attribute=attribute):
                setattr(self.ops, attribute, True)
                with self.assertRaises(ValueError):
                    self.operation("install", self.old)
                self.assertTrue(self.app.exists())
                self.assertIsNotNone(self.receipt()["transaction"])
                setattr(self.ops, attribute, False)
                self.operation("recover")
                self.operation("uninstall", hooks_retired=True)

    def test_superseded_and_unknown_siblings_survive_complete_install_lifecycle(self):
        identifier = metadata.BASE_ID + ".Extension"
        sibling_apps = [self.fixture("superseded-sibling"), self.fixture("unknown-sibling")]
        siblings = {(identifier, app / preview.EXTENSION) for app in sibling_apps}
        unrelated = ("com.example.Unrelated.Extension", self.root / "Unrelated.appex")
        self.ops.applications.update(sibling_apps)
        self.ops.extensions.update(siblings | {unrelated})
        self.ops.elections = {
            (identifier, sibling_apps[0] / preview.EXTENSION): "=",
            (identifier, sibling_apps[1] / preview.EXTENSION): "?",
        }
        self.operation("install", self.old)
        self.ops.failures["after-register"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("install", self.new, update=True)
        self.operation("recover")
        self.operation("rollback")
        self.operation("uninstall", hooks_retired=True)
        self.assertEqual(self.ops.extensions, siblings | {unrelated})
        self.assertEqual(self.ops.applications, set(sibling_apps))
        self.assertTrue(all(app.exists() for app in sibling_apps))
        self.assertEqual(self.data.read_text(), "observation-data")
        self.assertEqual(self.legacy.read_text(), "not-installer-owned")

    def test_unknown_backup_and_tampered_owned_backup_are_refused(self):
        self.operation("install", self.old)
        self.operation("install", self.new, update=True)
        unknown = self.app.parent / preview.STATE_NAME / ("slot-" + "f" * 32 + ".app")
        unknown.mkdir()
        with self.assertRaisesRegex(ValueError, "Unrecognized"):
            self.operation("rollback")
        unknown.rmdir()
        (self.previous() / "payload").write_text("foreign")
        with self.assertRaisesRegex(ValueError, "integrity mismatch"):
            self.operation("rollback")
        with self.assertRaises(ValueError):
            self.operation("uninstall", hooks_retired=True)
        self.assertEqual((self.app / "payload").read_text(), "new")

    def test_ambiguous_recovery_refuses_to_guess(self):
        self.operation("install", self.old)
        self.ops.failures["after-move"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("install", self.new, update=True)
        (self.app / "payload").write_text("unexpected")
        with self.assertRaisesRegex(ValueError, "Ambiguous"):
            self.operation("recover")
        self.assertIsNotNone(self.receipt()["transaction"])

    def test_metadata_failure_after_commit_is_inferred_from_app_fingerprints(self):
        self.operation("install", self.old)
        original = preview.Installer.save

        def fail_after_registration(installer):
            if installer.receipt["current"] and installer.receipt["current"]["sha256"] == preview.digest(self.new):
                raise OSError("metadata disk full after successful registration")
            original(installer)

        with patch.object(preview.Installer, "save", fail_after_registration):
            with self.assertRaises(OSError):
                self.operation("install", self.new, update=True)
        self.assertEqual(self.receipt()["transaction"]["phase"], "ready")
        self.operation("recover")
        self.assertEqual((self.previous() / "payload").read_text(), "old")

    def test_staged_copy_is_reverified_before_exchange(self):
        self.operation("install", self.old)
        copy = self.ops.copy

        def tampered(source, destination):
            copy(source, destination)
            (destination / "payload").write_text("unexpected-copy")

        with patch.object(self.ops, "copy", tampered):
            with self.assertRaisesRegex(ValueError, "differs"):
                self.operation("install", self.new, update=True)
        self.assertEqual((self.app / "payload").read_text(), "old")
        self.operation("recover")
        self.assertIsNone(self.receipt()["transaction"])

    def test_replaced_partial_staging_directory_is_not_deleted(self):
        self.operation("install", self.old)
        self.ops.failures["copy"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("install", self.new, update=True)
        slot = self.app.parent / preview.STATE_NAME / self.receipt()["transaction"]["slot"]
        slot.rename(self.root / "original-staging")
        slot.mkdir()
        (slot / "foreign-data").write_text("leave-me")
        with self.assertRaisesRegex(ValueError, "ownership proof"):
            self.operation("recover")
        self.assertEqual((slot / "foreign-data").read_text(), "leave-me")

    def test_interrupted_rollback_can_finish_or_restore_original(self):
        self.operation("install", self.old)
        self.operation("install", self.new, update=True)
        self.ops.failures["after-move"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("rollback")
        self.operation("recover", restore_previous=True)
        self.assertEqual((self.app / "payload").read_text(), "new")
        self.assertEqual((self.previous() / "payload").read_text(), "old")
        self.ops.failures["before-move"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("rollback")
        self.operation("recover")
        self.assertEqual((self.app / "payload").read_text(), "new")
        self.ops.failures["after-move"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("rollback")
        self.operation("recover")
        self.assertEqual((self.app / "payload").read_text(), "old")

    def test_recovery_rollback_failure_is_itself_resumable_preserving_existing_backup(self):
        self.operation("install", self.old)
        self.operation("install", self.new, update=True)
        self.ops.failures["after-move"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("install", self.latest, update=True)
        self.ops.failures["after-move"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("recover", restore_previous=True)
        self.assertEqual(self.receipt()["transaction"]["phase"], "reverting")
        self.operation("recover")
        self.assertEqual((self.app / "payload").read_text(), "new")
        self.assertEqual((self.previous() / "payload").read_text(), "old")

    def test_garbage_cleanup_interruption_is_owned_and_resumable(self):
        self.operation("install", self.old)
        self.operation("install", self.new, update=True)
        original = preview.shutil.rmtree

        def interrupted(path):
            (path / "payload").unlink()
            raise Interrupted()

        with patch.object(preview.shutil, "rmtree", interrupted):
            with self.assertRaises(Interrupted):
                self.operation("install", self.latest, update=True)
        self.assertTrue(self.receipt()["garbage"]["deleting"])
        self.assertEqual((self.previous() / "payload").read_text(), "new")
        self.assertEqual((self.app / "payload").read_text(), "latest")
        with patch.object(preview.shutil, "rmtree", original):
            self.operation("recover")
        self.assertIsNone(self.receipt()["garbage"])

    def test_replaced_cleanup_slot_is_refused_after_interrupted_deletion(self):
        self.operation("install", self.old)
        self.operation("install", self.new, update=True)
        with patch.object(preview.shutil, "rmtree", side_effect=Interrupted()):
            with self.assertRaises(Interrupted):
                self.operation("install", self.latest, update=True)
        slot = self.app.parent / preview.STATE_NAME / self.receipt()["garbage"]["slot"]
        slot.rename(self.root / "original-garbage")
        shutil.copytree(self.old, slot)
        with self.assertRaisesRegex(ValueError, "replaced"):
            self.operation("recover")
        self.assertTrue(slot.exists())

    def test_uninstall_requires_explicit_hook_retirement_keeps_all_user_data(self):
        self.operation("install", self.old)
        self.operation("install", self.new, update=True)
        with self.assertRaises(ValueError):
            self.operation("uninstall", hooks_retired=False)
        self.operation("uninstall", hooks_retired=True)
        self.assertFalse(self.app.exists())
        self.assertFalse(self.receipt()["previous"])
        self.assertFalse(self.ops.applications)
        self.assertFalse(self.ops.extensions)
        self.assertEqual(self.data.read_text(), "observation-data")
        self.assertEqual(self.legacy.read_text(), "not-installer-owned")
        self.assertTrue(self.old.exists() and self.new.exists())
        self.operation("install", self.latest)

    def test_uninstall_failure_before_and_after_commit_recovers(self):
        self.operation("install", self.old)
        self.operation("install", self.new, update=True)
        self.ops.failures["unregister"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("uninstall", hooks_retired=True)
        self.assertTrue(self.app.exists())
        with self.assertRaisesRegex(ValueError, "not a replacement"):
            self.operation("recover", restore_previous=True)
        self.assertTrue(self.app.exists())
        self.ops.failures["after-move"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("recover")
        self.assertFalse(self.app.exists())
        self.operation("recover")
        self.assertIsNone(self.receipt()["current"])
        self.assertIsNone(self.receipt()["previous"])

    def test_uninstall_interrupted_after_receipt_commit_cleans_both_owned_versions(self):
        self.operation("install", self.old)
        self.operation("install", self.new, update=True)
        with patch.object(preview.shutil, "rmtree", side_effect=Interrupted()):
            with self.assertRaises(Interrupted):
                self.operation("uninstall", hooks_retired=True)
        self.assertIn("Pending", self.operation("status"))
        self.operation("recover")
        self.assertEqual(list((self.app.parent / preview.STATE_NAME).glob("slot-*.app")), [])

    def test_stable_recovery_repairs_missing_registration_without_replacing_app(self):
        self.operation("install", self.old)
        before = preview.directory_identity(self.app)
        self.ops.applications.clear()
        self.ops.extensions.clear()
        with self.assertRaises(ValueError):
            self.operation("status")
        self.operation("recover")
        self.assertEqual(preview.directory_identity(self.app), before)
        self.assertIn("Verified installed preview", self.operation("status"))

    def test_retire_source_is_explicit_and_only_known_checkout_product(self):
        with self.assertRaisesRegex(ValueError, "known"):
            self.operation("install", self.old, retire_source=True)
        with patch.object(preview, "DEVELOPMENT_APP", self.old):
            self.ops.applications.add(self.old)
            self.ops.extensions.add((metadata.BASE_ID + ".Extension", self.old / preview.EXTENSION))
            self.operation("install", self.old, retire_source=True)
        self.assertNotIn(self.old, self.ops.applications)
        self.assertTrue(self.old.exists())
        unregister = next(index for index, command in enumerate(self.ops.commands)
                          if command[:2] == [preview.LSREGISTER, "-u"])
        register = next(index for index, command in enumerate(self.ops.commands)
                        if command[:2] == [preview.LSREGISTER, "-f"])
        self.assertLess(unregister, register)

    def test_no_implicit_source_registration_removal(self):
        self.ops.applications.add(self.old)
        self.ops.extensions.add((metadata.BASE_ID + ".Extension", self.old / preview.EXTENSION))
        self.operation("install", self.old)
        self.assertIn(self.old, self.ops.applications)
        self.assertFalse(any(command[:2] == [preview.LSREGISTER, "-u"] for command in self.ops.commands))

    def test_atomic_primitive_refuses_existing_destination_on_first_install(self):
        source = self.root / "from"
        target = self.root / "to"
        source.mkdir()
        target.mkdir()
        with self.assertRaises(OSError):
            preview.atomic_rename(source, target)
        self.assertTrue(source.is_dir() and target.is_dir())

    def test_production_cli_has_no_verification_bypass_or_test_root(self):
        script = (ROOT / "scripts/local-preview.py").read_text()
        self.assertNotIn('add_argument("--home"', script)
        self.assertNotIn('add_argument("--skip', script)
        self.assertNotIn('add_argument("--force', script)
        self.assertIn("pwd.getpwuid(os.getuid()).pw_dir", script)


if __name__ == "__main__":
    unittest.main()
