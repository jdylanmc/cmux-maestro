#!/usr/bin/env python3
"""Synthetic filesystem/registries and owned test processes; no live app or CLI mutation."""

import importlib.util
import fcntl
import errno
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import select
import subprocess
import struct
import sys
import tempfile
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
        self.extension_points = {}
        self.release_on_withdrawal = False
        self.integration_calls = []
        self.application_calls = []
        self.application_bridges = []
        self.running_application = None
        self.quit_refused = False
        self.quit_stays_running = False
        self.next_application_pid = 42001

    def application_lifecycle(self, bridge, action, app, *, expected=None, hidden=False):
        assert plistlib.loads((bridge / "Contents/Info.plist").read_bytes()).get("CMUXMaestroAppLifecycleBridge") == "graceful-lifecycle-v1"
        self.application_bridges.append(bridge)
        self.application_calls.append((action, app, hidden))
        self.fail("application-" + action)
        if action == "inspect":
            return self.running_application
        if action == "quit":
            if self.running_application is None:
                return None
            if self.running_application["process"] != expected["process"]:
                raise ValueError("Containing-app generation changed")
            if self.quit_refused:
                raise ValueError("Containing app refused graceful quit")
            if not self.quit_stays_running:
                self.running_application = None
            self.fail("application-after-quit")
            return expected
        if action == "launch":
            if self.running_application is None:
                self.next_application_pid += 1
                self.running_application = {
                    "process": {"pid": self.next_application_pid, "uid": os.getuid(),
                                "startSeconds": self.next_application_pid, "startMicroseconds": 1,
                                "codeHash": "a" * 40, "executable": str(self.main_executable(app))},
                    "hidden": hidden,
                }
            self.fail("application-after-launch")
            return self.running_application
        raise AssertionError(action)

    def integration(self, app, action, token, destination, *, selected=None, allow_absent=False):
        self.integration_health = "currentOnDisk"
        self.native_plugin_status = "enabled"
        self.integration_calls.append((action, token, app))
        self.fail("integration-" + action)
        root = destination.parent.parent / ".copilot"
        installed = root / "synthetic-owned-integration.json"
        journal = root / "synthetic-install-checkpoint.json"
        record = json.loads(journal.read_text()) if journal.exists() else None
        if record:
            assert record["id"] == token
        if action == "prepare":
            assert record is None or record["phase"] == "prepared"
            if record is None:
                before = installed.read_text() if installed.exists() else None
                desired = json.dumps({"build": (app / "payload").read_text(), "helper": str(destination / "Contents/Helpers/CMUXMaestroCopilotHook")})
                record = {"id": token, "before": before, "desired": desired,
                          "unchanged": before == desired, "phase": "prepared"}
                journal.write_text(json.dumps(record))
            return record["unchanged"]
        if record is None:
            assert allow_absent and action in ("restore", "release")
            return True
        if action == "apply":
            record["phase"] = "applying"
            journal.write_text(json.dumps(record))
            if not record["unchanged"]:
                installed.write_text(record["desired"])
            self.fail("integration-after-apply")
            record["phase"] = "applied"
        elif action == "verify":
            assert record["phase"] in ("applied", "committed")
            assert installed.read_text() == record["desired"]
        elif action == "restore":
            current = installed.read_text() if installed.exists() else None
            if current not in (record["before"], record["desired"]):
                raise ValueError("Foreign integration changes refused")
            record["phase"] = "restoring"
            journal.write_text(json.dumps(record))
            if record["before"] is None:
                installed.unlink(missing_ok=True)
            else:
                installed.write_text(record["before"])
            self.fail("integration-after-restore")
            record["phase"] = "restored"
        elif action == "finish":
            assert record["phase"] in ("applied", "committed", "restored")
            if record["phase"] != "restored":
                record["phase"] = "committed"
        elif action == "release":
            assert record["phase"] in ("committed", "restored")
            journal.unlink()
            return True
        else:
            raise AssertionError(action)
        journal.write_text(json.dumps(record))
        return record["unchanged"]

    def fail(self, point):
        error = self.failures.pop(point, None)
        if error:
            raise error

    def app_paths(self):
        return list(self.applications)

    def assert_idle(self, *apps):
        if self.busy or (self.running_application is not None and any(
                Path(self.running_application["process"]["executable"]).is_relative_to(app) for app in apps)):
            raise preview.PreviewBusyError("Synthetic preview process is running; close only that process.")

    def wait_idle(self, *apps):
        self.assert_idle(*apps)

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
                if self.release_on_withdrawal:
                    self.busy = False
            elif command[1:] in (["-m", "-A", "-D", "-vv", "-i", identifier],
                                 ["-m", "-A", "-D", "-vv", "-i", identifier, "-p", metadata.PRODUCTION_POINT]):
                self.fail("query")
                entries = sorted((key, path) for key, path in self.extensions if key == identifier
                                 and ("-p" not in command or self.extension_points.get(path, metadata.PRODUCTION_POINT)
                                      == metadata.PRODUCTION_POINT))
                stdout = ("".join(f"{self.elections.get((key, path), '+')} {key}(2)\n    Path = {path}\n"
                                  f"    SDK = {self.extension_points.get(path, metadata.PRODUCTION_POINT)}\n"
                                  for key, path in entries)
                          + f"({len(entries)} plug-ins)\n").encode() if entries else b"(no matches)\n"
            else:
                raise AssertionError(command)
        else:
            raise AssertionError(f"Non-injected command refused: {command}")
        if kwargs.get("text"):
            stdout, stderr = stdout.decode(), stderr.decode()
        return subprocess.CompletedProcess(command, 0, stdout, stderr)


class CompiledBridgeMac(SyntheticMac):
    crash_after_action = None

    def integration(self, app, action, token, destination, *, selected=None, allow_absent=False):
        self.integration_calls.append((action, token, app))
        self.fail("integration-" + action)
        result = preview.MacOperations.integration(
            self, app, action, token, destination, selected=selected, allow_absent=allow_absent)
        self.fail("integration-after-" + action)
        if self.crash_after_action == action:
            os._exit(91)
        return result


class LocalPreviewImportTests(unittest.TestCase):
    def test_child_imports_do_not_write_source_bytecode(self):
        methods = (
            "assert_bridge_death_preserves_provider_lease",
            "test_compiled_bridge_actual_parent_exit_recovers_both_generations_from_disk",
            "test_compiled_bridge_revalidates_after_actual_exit_between_component_restorations",
        )
        for name in methods:
            with self.subTest(method=name), tempfile.TemporaryDirectory(prefix="cmux-preview-import-") as directory:
                root = Path(directory)
                scripts = root / "scripts"
                scripts.mkdir()
                for filename in ("test-local-preview.py", "local-preview.py",
                                 "verify-build-metadata.py", "preview-command-worker.py"):
                    shutil.copyfile(ROOT / "scripts" / filename, scripts / filename)
                code = next(value for value in getattr(LocalPreviewTests, name).__code__.co_consts
                            if isinstance(value, str) and "spec.loader.exec_module(tests)" in value)
                # Execute the actual child import, stopping before its fixture operations.
                prefix = code.split("spec.loader.exec_module(tests)", 1)[0] + "spec.loader.exec_module(tests)"
                result = subprocess.run([
                    sys.executable, "-I", "-c",
                    "import sys; sys.dont_write_bytecode = False\n" + prefix,
                    str(scripts / "test-local-preview.py"),
                ], capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual([str(path.relative_to(root)) for path in root.rglob("*.pyc")], [])


class LocalPreviewTests(unittest.TestCase):
    compiled_bridge_ready = False
    compiled_bridge_failure = None

    def test_bridge_death_cannot_release_a_gated_provider_mutator(self):
        for compensation, guardian_failure in ((False, False), (True, False), (False, True), (True, True)):
            with self.subTest(compensation=compensation, guardian_failure=guardian_failure):
                case = LocalPreviewTests()
                case.setUp()
                try:
                    case.assert_bridge_death_preserves_provider_lease(compensation, guardian_failure)
                finally:
                    case.tearDown()
                    case.doCleanups()

    def use_gated_provider_bridge(self):
        self.use_compiled_bridge()
        marker = self.home / ".bridge-fixture.json"
        configuration = json.loads(marker.read_text())
        configuration["provider"] = "isolated-official"
        marker.write_text(json.dumps(configuration))
        provider = self.home / "gated-provider"
        provider.write_text(f"#!{sys.executable}\n" + (ROOT / "scripts/test-fixtures/gated-copilot-provider.py").read_text().split("\n", 1)[1])
        provider.chmod(0o700)
        return provider

    def assert_bridge_death_preserves_provider_lease(self, compensation, guardian_failure):
        provider = self.use_gated_provider_bridge()
        def operation(name, *args):
            installer = preview.Installer(self.home, operations=self.ops, copilot_executable=provider)
            with installer.locked():
                return getattr(installer, name)(*args)
        if compensation:
            operation("install", self.old)
        before = self.integration_snapshot()
        (self.home / "provider-gate.json").write_text(json.dumps({"install": 3 if compensation else 1}))
        gate = self.home / "provider-release"
        os.mkfifo(gate, 0o600)
        code = """
import importlib.util,json,os,pathlib,sys,time
sys.dont_write_bytecode = True
spec=importlib.util.spec_from_file_location('fixture',sys.argv[1])
tests=importlib.util.module_from_spec(spec); spec.loader.exec_module(tests)
home,source,provider=map(pathlib.Path,sys.argv[2:5])
ops=tests.CompiledBridgeMac()
app=home/'Applications'/tests.preview.DEFAULT_NAME
if app.exists():
    ops.applications.add(app)
    ops.extensions.add((tests.metadata.BASE_ID+'.Extension',app/tests.preview.EXTENSION))
if sys.argv[5]=='compensation': ops.failures['integration-verify']=OSError('injected late failure')
installer=tests.preview.Installer(home,operations=ops,copilot_executable=provider)
try:
    with installer.locked(): installer.install(source)
except Exception as error:
    (home/'installer-return.json').write_text(json.dumps({'lateWriteAlreadyPresent':(home/'provider-late-write.json').exists(),'error':str(error)}))
else:
    raise AssertionError('Bridge death must fail installation')
"""
        unrelated = subprocess.Popen(["/bin/cat"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
        def close_unrelated():
            unrelated.stdin.close()
            unrelated.wait(timeout=10)
        self.addCleanup(close_unrelated)
        child = subprocess.Popen([sys.executable, "-c", code, str(Path(__file__).resolve()), str(self.home),
                                  str(self.new if compensation else self.old), str(provider),
                                  "compensation" if compensation else "forward"],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        selected = None
        blocked = False
        returned_before_release = restored_before_release = False
        try:
            self.wait_for(lambda: (self.home / "provider-ready.json").exists(), "gated provider")
            selected = json.loads((self.home / "provider-ready.json").read_text())
            self.assertNotEqual(selected["bridgeGroup"], selected["providerGroup"])
            self.assertEqual(selected["bridge"], selected["bridgeGroup"])
            self.assertEqual(selected["provider"], selected["providerGroup"])
            lock_path = self.home / "Applications" / preview.STATE_NAME / "lock"
            supervisor = json.loads(lock_path.read_text())["supervisor"]
            os.kill(selected["bridge"], signal.SIGKILL)
            if guardian_failure:
                os.kill(supervisor, signal.SIGKILL)
                self.wait_for(lambda: (self.home / "installer-return.json").exists(), "killed guardian result")
            # A waiting provider is a still-capable mutator, not a completed command.
            raw_marker = lock_path.read_text()
            marker = json.loads(raw_marker) if raw_marker else {}
            if selected["providerGroup"] not in marker.get("providers", []):
                self.wait_for(lambda: (self.home / "installer-return.json").exists(), "unprotected installer return")
            fd = os.open(self.home / "Applications" / preview.STATE_NAME / "lock", os.O_RDWR)
            try:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    blocked = True
                else:
                    try:
                        preview.command_worker.recover_marker(fd)
                    except ValueError:
                        blocked = True
            finally:
                os.close(fd)
            if not blocked and self.receipt()["transaction"]:
                operation("recover")
            returned_before_release = (self.home / "installer-return.json").exists()
            restored_before_release = self.receipt()["transaction"] is None
            self.assertFalse((self.home / "provider-late-write.json").exists())
            print("BRIDGE_DEATH_GUARD", json.dumps({**selected, "compensation": compensation,
                  "guardianKilled": guardian_failure, "blockedWhileProviderAlive": blocked}), flush=True)
            self.assertIsNone(unrelated.poll())
        finally:
            if selected and not self.process_gone(selected["provider"]):
                release = os.open(gate, os.O_WRONLY | os.O_NONBLOCK)
                os.write(release, b"G")
                os.close(release)
            stdout, stderr = child.communicate(timeout=120)
            if selected:
                self.wait_for(lambda: self.process_gone(selected["provider"]), "provider completion")
                self.wait_for(lambda: self.process_gone(selected["bridge"]), "bridge completion")
        self.assertEqual(child.returncode, 0, stdout + stderr)
        self.wait_for(lambda: self.process_gone(selected["provider"]), "provider completion")
        self.wait_for(lambda: self.process_gone(selected["bridge"]), "bridge completion")
        late = json.loads((self.home / "provider-late-write.json").read_text())
        returned = json.loads((self.home / "installer-return.json").read_text())
        print("BRIDGE_DEATH_RESULT", json.dumps({"compensation": compensation, "blocked": blocked,
              "guardianKilled": guardian_failure,
              "returnedBeforeGate": returned_before_release, "restoredBeforeGate": restored_before_release,
              "lateWritePresentAfterGate": bool(late), "returnObservedLateWrite": returned["lateWriteAlreadyPresent"],
              "transactionRetained": self.receipt()["transaction"] is not None}), flush=True)
        self.assertTrue(blocked, "A separately grouped provider must retain the lease or block recovery after bridge death")
        self.assertFalse(restored_before_release)
        if not guardian_failure:
            self.assertFalse(returned_before_release)
            self.assertTrue(returned["lateWriteAlreadyPresent"], "Provider must finish before the command boundary returns")
        if self.receipt()["transaction"]:
            operation("recover")
        self.assertEqual(self.integration_snapshot(), before)
        self.assertIsNone(self.receipt()["transaction"])
        if compensation:
            self.assertEqual((self.app / "payload").read_text(), "old")
        else:
            self.assertFalse(self.app.exists())
        self.assertIsNone(unrelated.poll(), "Restoration must not terminate an unrelated process")

    def test_actual_bridge_exit_after_receipt_write_recovers_without_after_snapshot(self):
        provider = self.use_gated_provider_bridge()
        marker = self.home / ".fixture-crash-after-receipt-publication"
        marker.write_text("waiting")
        before = self.integration_snapshot()
        installer = preview.Installer(self.home, operations=self.ops, copilot_executable=provider)
        with installer.locked():
            with self.assertRaises(subprocess.CalledProcessError) as failure:
                installer.install(self.old)
        self.assertEqual(failure.exception.returncode, 95)
        evidence = json.loads((self.home / "receipt-crash-state.json").read_text())
        self.assertEqual(evidence, {"phase": "applying", "afterMissing": True, "receipt": "current"})
        self.assertEqual(self.integration_snapshot(), before)
        self.assertFalse(self.app.exists())
        self.assertIsNone(self.receipt()["transaction"])

    def test_actual_provider_bridge_requires_inherited_guard(self):
        provider = self.use_gated_provider_bridge()
        before = self.integration_snapshot()
        result = subprocess.run([
            str(self.old / "Contents/MacOS/Preview"), "--coordinate-copilot-install", "prepare",
            "--transaction", str(uuid.uuid4()), "--application", str(self.app),
            "--copilot-executable", str(provider),
        ], capture_output=True, text=True, timeout=30,
            env={key: value for key, value in os.environ.items() if not key.startswith("CMUX_MAESTRO_INSTALL_LEASE_")})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("inherited install guard", result.stderr)
        self.assertFalse((self.home / "provider-installs").exists())
        self.assertEqual(self.integration_snapshot(), before)

    def test_nested_guard_marker_rejects_invalid_provider_groups(self):
        with self.installer().locked():
            fd = self.ops.install_lock_fd
            for groups in ([True], [0], [-1], ["123"], [123, 123], list(range(2, 131))):
                with self.subTest(groups=groups):
                    preview.command_worker.write_marker(fd, {
                        "schema": 2, "state": "running", "token": "a" * 32,
                        "supervisor": 123, "group": 124, "providers": groups,
                    })
                    with self.assertRaisesRegex(ValueError, "provider groups"):
                        preview.command_worker.read_marker(fd)
            preview.command_worker.write_marker(fd, None)

    def use_compiled_bridge(self):
        if not LocalPreviewTests.compiled_bridge_ready:
            if LocalPreviewTests.compiled_bridge_failure is not None:
                self.fail(LocalPreviewTests.compiled_bridge_failure)
            built = subprocess.run([str(ROOT / "scripts/test-copilot-setup.sh"), "--compile-only"],
                                   capture_output=True, text=True, timeout=180)
            if built.returncode:
                LocalPreviewTests.compiled_bridge_failure = built.stdout + built.stderr
                self.fail(LocalPreviewTests.compiled_bridge_failure)
            LocalPreviewTests.compiled_bridge_ready = True
        self.ops = CompiledBridgeMac()
        routes = Path(tempfile.mkdtemp(prefix="maestro-combined-", dir="/private/tmp"))
        self.addCleanup(shutil.rmtree, routes)
        (self.home / ".bridge-fixture.json").write_text(json.dumps({"owner": "local-preview-tests", "routes": str(routes)}))
        for app in (self.old, self.new, self.latest):
            resources = app / "Contents/Resources"
            shutil.copy2(ROOT / ".build/setup-tests/setup-tests", app / "Contents/MacOS/Preview")
            shutil.copytree(ROOT / "Resources/NerdFonts", resources / "NerdFonts")
            (resources / "maestro-icon").mkdir()
            (resources / "maestro-icon/SKILL.md").write_text("---\nname: maestro-icon\n---\n")
            (resources / "cmux-maestro-orchestrator.py").write_text("#!/usr/bin/env python3\n# " + app.stem + "\n")

    def integration_snapshot(self):
        paths = [
            self.home / "Library/Application Support/CMUXMaestroPreview/Copilot",
            self.home / "Library/Application Support/CMUXMaestroPreview/Orchestration/bin",
            self.home / ".copilot/hooks",
            self.home / ".copilot/extensions/maestro",
            self.home / ".copilot/installed-plugins",
        ]
        return {
            str(path.relative_to(self.home)): (path.read_bytes(), path.stat().st_mode & 0o777)
            for root in paths if root.exists() for path in root.rglob("*")
            if path.is_file() and path.name not in (".observer-setup.lock", ".install-setup.lock", "install-transaction.json")
        }

    def test_compiled_bridge_combines_install_noop_and_upgrade_without_separate_setup(self):
        self.use_compiled_bridge()
        self.operation("install", self.old)
        before = self.integration_snapshot()
        app_inode = self.app.stat().st_ino
        receipt = self.receipt()
        self.assertIn("no replacements", self.operation("install", self.old))
        self.assertEqual(self.integration_snapshot(), before)
        self.assertEqual(self.app.stat().st_ino, app_inode)
        self.assertEqual(self.receipt(), receipt)
        installed_info = self.app / "Contents/Info.plist"
        old_info = plistlib.loads(installed_info.read_bytes())
        del old_info["CMUXMaestroInstallBridge"]
        installed_info.write_bytes(plistlib.dumps(old_info))
        historical = self.receipt()
        historical["current"]["sha256"] = preview.digest(self.app)
        (self.app.parent / preview.STATE_NAME / "receipt.json").write_text(json.dumps(historical))
        self.operation("install", self.new)
        self.assertEqual((self.app / "payload").read_text(), "new")
        self.assertEqual((self.previous() / "payload").read_text(), "old")
        self.assertNotEqual(self.integration_snapshot(), before)
        self.assertIsNone(self.receipt()["transaction"])
        self.assertIsNone(self.receipt()["integration"])
        self.assertFalse((self.data.parent.parent / "Orchestration/install-transaction.json").exists())
        self.assertEqual(self.data.read_text(), "observation-data")

    def test_compiled_bridge_late_failure_restores_first_absence_then_previous_generation(self):
        self.use_compiled_bridge()
        before = self.integration_snapshot()
        self.ops.failures["integration-after-apply"] = OSError("failure after real Swift publication")
        with self.assertRaises(OSError):
            self.operation("install", self.old)
        self.assertFalse(self.app.exists())
        self.assertEqual(self.integration_snapshot(), before)
        self.operation("install", self.old)
        before = self.integration_snapshot()
        settings = self.home / ".copilot/settings.json"
        settings.write_text(json.dumps({"disableAllHooks": True, "unrelated": "preserve"}))
        settings.chmod(0o600)
        settings_before = settings.read_bytes()
        self.ops.failures["integration-verify"] = OSError("late combined verification failure")
        with self.assertRaises(OSError):
            self.operation("install", self.new)
        self.assertEqual((self.app / "payload").read_text(), "old")
        self.assertEqual(self.integration_snapshot(), before)
        self.assertEqual(settings.read_bytes(), settings_before)
        self.assertIsNone(self.receipt()["transaction"])

    def test_compiled_bridge_actual_parent_exit_recovers_both_generations_from_disk(self):
        self.use_compiled_bridge()
        self.operation("install", self.old)
        before = self.integration_snapshot()
        code = """
import importlib.util, pathlib, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('install_tests', sys.argv[1])
tests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tests)
home, source = map(pathlib.Path, sys.argv[2:])
ops = tests.CompiledBridgeMac()
app = home / 'Applications' / tests.preview.DEFAULT_NAME
ops.applications.add(app)
ops.extensions.add((tests.metadata.BASE_ID + '.Extension', app / tests.preview.EXTENSION))
ops.crash_after_action = 'apply'
installer = tests.preview.Installer(home, operations=ops)
with installer.locked():
    installer.install(source)
"""
        child = subprocess.run([sys.executable, "-c", code, str(Path(__file__).resolve()), str(self.home), str(self.new)],
                               capture_output=True, text=True, timeout=120)
        self.assertEqual(child.returncode, 91, child.stderr)
        self.assertEqual((self.app / "payload").read_text(), "new")
        self.assertEqual(self.receipt()["transaction"]["integration"]["state"], "applying")
        self.assertEqual(json.loads((self.data.parent.parent / "Orchestration/install-transaction.json").read_text())["phase"], "applied")
        self.operation("recover")
        self.assertEqual((self.app / "payload").read_text(), "old")
        self.assertEqual(self.integration_snapshot(), before)
        self.assertIsNone(self.receipt()["transaction"])
        self.assertFalse((self.data.parent.parent / "Orchestration/install-transaction.json").exists())

    def test_committed_checkpoint_cleanup_blocks_legacy_mutations_until_recovery(self):
        self.operation("install", self.old)
        self.ops.failures["integration-release"] = OSError("checkpoint cleanup unavailable")
        with self.assertRaisesRegex(OSError, "checkpoint cleanup unavailable"):
            self.operation("install", self.new)
        before = self.receipt()
        owned = self.home / ".copilot/synthetic-owned-integration.json"
        integration = owned.read_bytes()
        self.assertEqual(before["transaction"]["phase"], "committed")
        self.assertEqual(before["transaction"]["integration"]["state"], "releasing")
        self.assertIn("checkpoint cleanup", self.operation("status"))
        for action, kwargs in (("rollback", {}), ("prepare_update", {}), ("uninstall", {"hooks_retired": True})):
            with self.subTest(action=action):
                with self.assertRaisesRegex(ValueError, "recover"):
                    self.operation(action, **kwargs)
                self.assertEqual(self.receipt(), before)
                self.assertEqual((self.app / "payload").read_text(), "new")
                self.assertEqual(owned.read_bytes(), integration)
        self.operation("recover")
        self.assertIsNone(self.receipt()["integration"])
        self.assertEqual((self.app / "payload").read_text(), "new")

    def test_resumed_restoration_reverifies_integration_before_reverting_app(self):
        self.operation("install", self.old)
        self.ops.failures["integration-verify"] = OSError("late verification failed")
        original_move = self.ops.move
        moves = 0

        def fail_first_revert(source, destination, *, exchange=False):
            nonlocal moves
            moves += 1
            if moves == 2:
                raise Interrupted()
            return original_move(source, destination, exchange=exchange)

        with patch.object(self.ops, "move", side_effect=fail_first_revert), self.assertRaises(Interrupted):
            self.operation("install", self.new)
        self.assertEqual(self.receipt()["transaction"]["integration"]["state"], "restored")
        self.assertEqual((self.app / "payload").read_text(), "new")
        integration = self.home / ".copilot/synthetic-owned-integration.json"
        integration.write_text("foreign change after restoration")
        before = self.receipt()
        with self.assertRaisesRegex(ValueError, "Foreign integration"):
            self.operation("recover")
        self.assertEqual(self.receipt(), before)
        self.assertEqual((self.app / "payload").read_text(), "new")
        self.assertEqual(integration.read_text(), "foreign change after restoration")

    def test_false_shaped_integration_receipts_do_not_bypass_recovery_guards(self):
        self.operation("install", self.old)
        receipt_path = self.app.parent / preview.STATE_NAME / "receipt.json"
        stable = self.receipt()
        for invalid in ("", False, 0, {}, []):
            with self.subTest(committed=invalid):
                changed = dict(stable, integration=invalid)
                receipt_path.write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    self.operation("status")
        receipt_path.write_text(json.dumps(stable))
        self.ops.failures["after-move"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("install", self.new)
        pending = self.receipt()
        for invalid in (None, "", False, 0, {}, []):
            with self.subTest(pending=invalid):
                changed = json.loads(json.dumps(pending))
                changed["transaction"]["integration"] = invalid
                receipt_path.write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    self.operation("recover")
                self.assertEqual((self.app / "payload").read_text(), "new")
        receipt_path.write_text(json.dumps(pending))
        self.operation("recover")
        self.assertEqual((self.app / "payload").read_text(), "old")

    def test_compiled_bridge_revalidates_after_actual_exit_between_component_restorations(self):
        self.use_compiled_bridge()
        self.operation("install", self.old)
        before = self.integration_snapshot()
        code = """
import importlib.util, os, pathlib, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('install_tests', sys.argv[1])
tests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tests)
home, source = map(pathlib.Path, sys.argv[2:])
ops = tests.CompiledBridgeMac()
app = home / 'Applications' / tests.preview.DEFAULT_NAME
ops.applications.add(app)
ops.extensions.add((tests.metadata.BASE_ID + '.Extension', app / tests.preview.EXTENSION))
ops.failures['integration-verify'] = OSError('injected late failure')
original = ops.move
moves = 0
def move(source, destination, *, exchange=False):
    global moves
    moves += 1
    if moves == 2:
        os._exit(92)
    return original(source, destination, exchange=exchange)
ops.move = move
installer = tests.preview.Installer(home, operations=ops)
with installer.locked():
    installer.install(source)
"""
        child = subprocess.run([sys.executable, "-c", code, str(Path(__file__).resolve()), str(self.home), str(self.new)],
                               capture_output=True, text=True, timeout=120)
        self.assertEqual(child.returncode, 92, child.stderr)
        self.assertEqual(self.receipt()["transaction"]["integration"]["state"], "restored")
        self.assertEqual((self.app / "payload").read_text(), "new")
        self.assertEqual(self.integration_snapshot(), before)
        target = self.data.parent / "plugin/skills/cmux-maestro-orchestrate/SKILL.md"
        original = target.read_bytes()
        target.write_text("concurrent foreign content")
        with self.assertRaises(subprocess.CalledProcessError):
            self.operation("recover")
        self.assertEqual(target.read_text(), "concurrent foreign content")
        self.assertEqual((self.app / "payload").read_text(), "new")
        target.write_bytes(original)
        self.operation("recover")
        self.assertEqual((self.app / "payload").read_text(), "old")
        self.assertEqual(self.integration_snapshot(), before)
        self.assertIsNone(self.receipt()["transaction"])

    def start_containing_app(self, *, hidden=False):
        state = self.ops.application_lifecycle(self.app, "launch", self.app, hidden=hidden)
        self.ops.application_calls.clear()
        return state

    def test_running_containing_app_is_gracefully_replaced_and_relaunched_without_activation(self):
        self.operation("install", self.old)
        before = self.start_containing_app(hidden=True)
        self.operation("install", self.new)
        self.assertEqual((self.app / "payload").read_text(), "new")
        self.assertNotEqual(self.ops.running_application["process"]["pid"], before["process"]["pid"])
        self.assertTrue(self.ops.running_application["hidden"])
        self.assertEqual([row[0] for row in self.ops.application_calls], ["inspect", "quit", "launch"])
        self.assertEqual(self.ops.application_calls[-1], ("launch", self.app, True))
        self.assertIsNone(self.receipt()["transaction"])

    def test_public_running_code_identity_matches_kernel_hash_for_owned_non_ui_fixture(self):
        self.use_compiled_bridge()
        executable = ROOT / ".build/setup-tests/setup-tests"
        process = subprocess.Popen([str(executable), "--maestro-process-proof-fixture"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        try:
            ready, _, _ = select.select([process.stdout], [], [], 10)
            self.assertTrue(ready, "Non-UI process identity fixture did not become ready")
            value = json.loads(process.stdout.readline())
            self.assertIsNone(process.poll())
            operations = preview.MacOperations()
            self.assertEqual(value["pid"], process.pid)
            self.assertEqual(value["executable"], str(executable))
            self.assertEqual(operations.executable_code_hash(process.pid), value["codeHash"])
            self.assertEqual(operations.process_generation(process.pid, os.getuid()),
                             (value["pid"], value["uid"], value["startSeconds"], value["startMicroseconds"]))
            self.assertIn(value["codeHash"], operations.code_hashes(executable))
        finally:
            stdout, stderr = process.communicate(b"G", timeout=10)
        self.assertEqual((process.returncode, stdout, stderr), (0, b"", b""))

    def test_lifecycle_bridge_uses_only_main_executable_hashes_and_guarded_commands(self):
        operations = preview.MacOperations()
        operations.install_lock_fd = 123
        response = {"schema": 1, "action": "inspect", "application": str(self.old), "process": None}
        with patch.object(operations, "code_hashes", return_value={"a" * 40}) as hashes, \
                patch.object(operations, "protected_code_hashes", side_effect=AssertionError("Bundle-wide identity is not app identity")), \
                patch.object(preview.command_worker, "run", return_value=subprocess.CompletedProcess(
                    [], 0, json.dumps(response), "")) as run:
            self.assertIsNone(operations.application_lifecycle(self.new, "inspect", self.old))
        hashes.assert_called_once_with(self.old / "Contents/MacOS/Preview")
        self.assertEqual(run.call_args.args[0], 123)
        self.assertEqual(run.call_args.args[1][:4], [
            str(self.new / "Contents/MacOS/Preview"), "--coordinate-maestro-app", "inspect", "--application",
        ])
        self.assertTrue(run.call_args.kwargs["text"])
        self.assertEqual(run.call_args.kwargs["timeout"], 120)

    def test_identical_install_does_not_quit_or_reopen_running_containing_app(self):
        self.operation("install", self.old)
        before = self.start_containing_app()
        self.operation("install", self.old)
        self.assertEqual(self.ops.running_application, before)
        self.assertEqual(self.ops.application_calls, [])

    def test_quit_refusal_or_non_exit_restores_registration_without_force_or_duplicate_launch(self):
        for refusal in (True, False):
            with self.subTest(refusal=refusal):
                if not self.app.exists():
                    self.operation("install", self.old)
                before = self.start_containing_app()
                self.ops.quit_refused = refusal
                self.ops.quit_stays_running = not refusal
                receipt = self.receipt()
                next_pid = self.ops.next_application_pid
                with self.assertRaises(ValueError):
                    self.operation("install", self.new)
                self.assertEqual((self.app / "payload").read_text(), "old")
                self.assertEqual(self.receipt(), {**receipt, "retired": self.receipt()["retired"]})
                self.assertEqual(self.receipt()["retired"]["identity"]["sha256"], preview.digest(self.new))
                self.assertEqual(self.ops.running_application, before)
                self.assertEqual(self.ops.next_application_pid, next_pid)
                self.assertIn(self.app, self.ops.applications)
                self.ops.quit_refused = False
                self.ops.quit_stays_running = False

    def test_late_update_failure_restores_previous_running_app_and_hidden_choice(self):
        self.operation("install", self.old)
        before = self.start_containing_app(hidden=True)
        self.ops.failures["integration-verify"] = OSError("late update failure")
        with self.assertRaisesRegex(OSError, "late update failure"):
            self.operation("install", self.new)
        self.assertEqual((self.app / "payload").read_text(), "old")
        self.assertIsNotNone(self.ops.running_application)
        self.assertNotEqual(self.ops.running_application["process"]["pid"], before["process"]["pid"])
        self.assertTrue(self.ops.running_application["hidden"])
        self.assertIsNone(self.receipt()["transaction"])

    def test_failure_after_relaunch_gracefully_retires_new_app_before_restoring_old_running_state(self):
        self.operation("install", self.old)
        before = self.start_containing_app()
        self.ops.failures["application-after-launch"] = OSError("launch completion failed")
        with self.assertRaisesRegex(OSError, "launch completion failed"):
            self.operation("install", self.new)
        self.assertEqual((self.app / "payload").read_text(), "old")
        self.assertIsNotNone(self.ops.running_application)
        self.assertNotEqual(self.ops.running_application["process"]["pid"], before["process"]["pid"])
        self.assertEqual([row[0] for row in self.ops.application_calls].count("quit"), 2)
        self.assertIsNone(self.receipt()["transaction"])

    def test_failed_running_state_restoration_remains_journaled_and_recovers(self):
        self.operation("install", self.old)
        self.start_containing_app(hidden=True)
        self.ops.failures["integration-verify"] = OSError("update failed")
        self.ops.failures["application-launch"] = OSError("restore launch refused")
        with self.assertRaisesRegex(preview.InstallRestorationError, "restore launch refused"):
            self.operation("install", self.new)
        self.assertEqual((self.app / "payload").read_text(), "old")
        self.assertEqual(self.receipt()["transaction"]["application"]["phase"], "restoring")
        self.assertIsNone(self.ops.running_application)
        self.operation("recover")
        self.assertTrue(self.ops.running_application["hidden"])
        self.assertEqual((self.app / "payload").read_text(), "old")
        self.assertIsNone(self.receipt()["transaction"])

    def test_interrupted_quit_or_relaunch_recovers_prior_running_state_from_receipt(self):
        for point in ("application-after-quit", "application-after-launch"):
            with self.subTest(point=point):
                if not self.app.exists():
                    self.operation("install", self.old)
                self.start_containing_app(hidden=True)
                self.ops.failures[point] = Interrupted()
                with self.assertRaises(Interrupted):
                    self.operation("install", self.new)
                phase = self.receipt()["transaction"]["application"]["phase"]
                self.assertEqual(phase, "quitting" if point.endswith("quit") else "launching")
                self.operation("recover")
                self.assertEqual((self.app / "payload").read_text(), "old")
                self.assertTrue(self.ops.running_application["hidden"])
                self.assertIsNone(self.receipt()["transaction"])

    def test_deleted_executable_requires_positive_stable_code_identity_and_inventory(self):
        pid, uid = 43210, os.getuid()
        generation = (pid, uid, 100, 123)
        cases = [
            (["aa" * 20] * 2, {"bb" * 20}, [generation] * 2, ["tree"] * 2, True),
            (["aa" * 20] * 2, {"aa" * 20, "bb" * 20}, [generation] * 2, ["tree"] * 2, False),
            ([None], {"bb" * 20}, [generation] * 2, ["tree"] * 2, False),
            (["aa" * 20, None], {"bb" * 20}, [generation] * 2, ["tree"] * 2, False),
            (["aa" * 20, "cc" * 20], {"bb" * 20}, [generation] * 2, ["tree"] * 2, False),
            (["aa" * 20] * 2, set(), [generation] * 2, ["tree"] * 2, False),
            (["aa" * 20] * 2, {"bb" * 20}, [None], ["tree"] * 2, False),
            (["aa" * 20] * 2, {"bb" * 20}, [generation, None], ["tree"] * 2, False),
            (["aa" * 20] * 2, {"bb" * 20}, [generation, (pid, uid, 100, 124)], ["tree"] * 2, False),
            (["aa" * 20] * 2, {"bb" * 20}, [generation] * 2, ["tree", "changed"], False),
        ]
        for hashes, protected, generations, trees, accepted in cases:
            with self.subTest(hashes=hashes, protected=protected, generations=generations, trees=trees):
                operations = preview.MacOperations()
                with patch.object(operations, "process_generation", side_effect=generations), \
                        patch.object(operations, "executable_code_hash", side_effect=hashes), \
                        patch.object(operations, "protected_code_hashes", return_value=protected), \
                        patch.object(preview, "digest", side_effect=trees), \
                        patch.object(operations, "run") as run:
                    self.assertEqual(
                        operations.confirmed_unrelated_executable(pid, uid, (self.app,)), accepted,
                    )
                    run.assert_not_called()

    def test_mach_o_inventory_covers_every_architecture_and_alternate_hash(self):
        binary = self.old / "universal"
        arm = struct.pack("<III", 0xfeedfacf, 0x100000c, 0)
        intel = struct.pack("<III", 0xfeedfacf, 0x1000007, 3)
        binary.write_bytes(
            struct.pack(">II", 0xcafebabe, 2)
            + struct.pack(">IIIII", 0x100000c, 0, 48, len(arm), 0)
            + struct.pack(">IIIII", 0x1000007, 3, 60, len(intel), 0) + arm + intel
        )
        self.assertEqual(preview.mach_o_architectures(binary), [(0x100000c, 0), (0x1000007, 3)])
        operations = preview.MacOperations()
        with patch.object(operations, "run", side_effect=[
            subprocess.CompletedProcess([], 0, b"", f"CDHash={'aa' * 20}\nCandidateCDHash sha1={'bb' * 20}\n".encode()),
            subprocess.CompletedProcess([], 0, b"", f"CDHash={'cc' * 20}\n".encode()),
        ]) as run:
            self.assertEqual(operations.protected_code_hashes((self.old,)), {"aa" * 20, "bb" * 20, "cc" * 20})
            self.assertEqual([call.args[0][-2] for call in run.call_args_list], ["16777228,0", "16777223,3"])
        binary.write_bytes(arm)
        for details in [b"", b"CDHash=short\n", f"CDHash={'aa' * 20}\nCandidateCDHash sha1=short\n".encode()]:
            with self.subTest(details=details), patch.object(
                operations, "run", return_value=subprocess.CompletedProcess([], 0, b"", details)
            ), self.assertRaises(ValueError):
                operations.protected_code_hashes((self.old,))
        for data in [arm[:8], struct.pack(">II", 0xcafebabe, 33) + b"0000",
                     struct.pack(">II", 0xcafebabe, 1) + b"0000",
                     struct.pack(">II", 0xcafebabe, 1) + struct.pack(">IIIII", 0x100000c, 0, 0, 12, 0)]:
            binary.write_bytes(data)
            with self.subTest(data=data), self.assertRaises(ValueError):
                preview.mach_o_architectures(binary)
        with patch.object(preview, "safe_tree"), patch.object(Path, "rglob", return_value=[binary] * 16_385), \
                patch.object(operations, "run") as run, self.assertRaisesRegex(ValueError, "bound"):
            operations.protected_code_hashes((self.old,))
            run.assert_not_called()

    def test_only_enoent_can_use_positive_unrelated_executable_evidence(self):
        pid, uid = os.getpid() + 100_000, os.getuid()
        for error in [errno.ENOENT, errno.EPERM, errno.EACCES, 0]:
            for unrelated in [True, False]:
                with self.subTest(error=error, unrelated=unrelated):
                    def lookup(*args):
                        preview.ctypes.set_errno(error)
                        return 0
                    operations = preview.MacOperations()
                    with patch.object(preview.ctypes, "CDLL", return_value=SimpleNamespace(proc_pidpath=lookup)), \
                            patch.object(operations, "run", return_value=SimpleNamespace(stdout=f"{pid} {uid}\n")), \
                            patch.object(operations, "confirmed_zombie", return_value=False), \
                            patch.object(operations, "confirmed_unrelated_executable", return_value=unrelated) as evidence, \
                            patch.object(preview.os, "kill") as probe:
                        if error == errno.ENOENT and unrelated:
                            operations.assert_idle(self.app)
                        else:
                            with self.assertRaisesRegex(ValueError, "Cannot verify executable"):
                                operations.assert_idle(self.app)
                        self.assertEqual(evidence.call_count, int(error == errno.ENOENT))
                        probe.assert_called_once_with(pid, 0)

    @unittest.skipUnless(sys.platform == "darwin", "Darwin kernel process evidence")
    def test_live_deleted_executable_identity_remains_guarded_without_signalling_other_apps(self):
        operations = preview.MacOperations()
        protected = self.root / "Protected.app"
        protected_binary = protected / "Contents/MacOS/probe"
        unrelated_binary = self.root / "unrelated-probe"
        for location, label in [(protected_binary, "owned"), (unrelated_binary, "other")]:
            location.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                ["/usr/bin/xcrun", "clang", "-x", "c", "-", "-o", str(location)],
                input=f'#include <unistd.h>\nint main(void) {{ write(1, "{label}", 5); sleep(30); return 0; }}\n'.encode(),
                check=True, capture_output=True,
            )
        for location, unrelated, label in [(unrelated_binary, True, b"other"), (protected_binary, False, b"owned")]:
            with self.subTest(location=location):
                child = subprocess.Popen([str(location)], stdin=subprocess.DEVNULL,
                                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                try:
                    self.assertEqual(child.stdout.read(5), label)
                    if unrelated:
                        location.unlink()
                    else:
                        location.rename(location.with_suffix(".retained"))
                    self.assertIsNone(child.poll())
                    self.assertEqual(
                        operations.confirmed_unrelated_executable(child.pid, os.getuid(), (protected,)), unrelated,
                    )
                    self.assertIsNone(child.poll())
                finally:
                    child.terminate()
                    child.wait(timeout=5)
                    child.stdout.close()

    def test_kernel_generation_requires_exact_owner_start_and_complete_bsd_info(self):
        pid, uid = 43210, os.getuid()
        cases = [
            ({}, False, (pid, uid, 100, 123)),
            ({}, True, None),
            ({"pid": pid + 1}, False, None),
            ({"uid": uid + 1}, False, None),
            ({"ruid": uid + 1}, False, None),
            ({"flags": 4}, False, None),
            ({"status": 5}, False, None),
            ({"start_seconds": 0}, False, None),
            ({"start_microseconds": 1_000_000}, False, None),
        ]
        for overrides, truncated, expected in cases:
            with self.subTest(overrides=overrides, truncated=truncated):
                info = preview.ProcBSDInfo(pid=pid, uid=uid, ruid=uid, status=2,
                                           start_seconds=100, start_microseconds=123)
                for key, value in overrides.items():
                    setattr(info, key, value)
                def lookup(actual_pid, flavor, argument, buffer, size):
                    self.assertEqual((actual_pid, flavor, argument, size), (pid, 3, 0, preview.ctypes.sizeof(info)))
                    preview.ctypes.memmove(buffer, preview.ctypes.byref(info), size)
                    return size - int(truncated)
                with patch.object(preview.ctypes, "CDLL", return_value=SimpleNamespace(proc_pidinfo=lookup)):
                    self.assertEqual(preview.MacOperations().process_generation(pid, uid), expected)

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
            (resources / "adapter.mjs").write_text("// synthetic adapter\n")
            (resources / "extension.mjs").write_text("// synthetic loader\n")
        parent = {"CFBundleIdentifier": metadata.BASE_ID, "CFBundlePackageType": "APPL",
                  "CFBundleVersion": version, "CFBundleExecutable": "Preview",
                  "CMUXMaestroInstallBridge": "copilot-install-v1",
                  "CMUXMaestroAppLifecycleBridge": "graceful-lifecycle-v1"}
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

    def retired(self):
        return self.app.parent / preview.STATE_NAME / self.receipt()["retired"]["slot"]

    def test_retained_noop_has_no_housekeeping_and_preparation_is_bounded_to_four(self):
        self.operation("install", self.old)
        self.operation("install", self.new)
        self.operation("install", self.latest)
        retired = self.retired()
        before = self.receipt()
        self.ops.commands.clear()
        with patch.object(preview.shutil, "rmtree", side_effect=AssertionError("No-op deleted an app")):
            self.operation("install", self.latest)
        self.assertEqual(self.receipt(), before)
        self.assertTrue(retired.exists())
        self.assertFalse(any(command[:2] in ([preview.LSREGISTER, "-f"], [preview.LSREGISTER, "-u"],
                                             ["/usr/bin/pluginkit", "-a"], ["/usr/bin/pluginkit", "-r"])
                             for command in self.ops.commands))
        copy, remove = self.ops.copy, preview.shutil.rmtree
        prepared_counts = []

        def stage(source, destination):
            copy(source, destination)
            self.assertTrue(retired.exists())
            prepared_counts.append(1 + len(list(destination.parent.glob("slot-*.app"))))

        def reclaim(path):
            self.assertEqual(path, retired)
            self.assertNotIn(self.app, self.ops.applications)
            self.assertNotIn((metadata.BASE_ID + ".Extension", self.app / preview.EXTENSION), self.ops.extensions)
            self.assertEqual(self.receipt()["transaction"]["phase"], "reclaiming")
            return remove(path)

        with patch.object(self.ops, "copy", side_effect=stage), patch.object(preview.shutil, "rmtree", side_effect=reclaim):
            self.operation("install", self.fixture("fourth"))
        self.assertEqual(prepared_counts, [4])
        self.assertEqual((self.app / "payload").read_text(), "fourth")
        self.assertEqual((self.previous() / "payload").read_text(), "latest")
        self.assertEqual((self.retired() / "payload").read_text(), "new")
        self.assertEqual(len(list((self.app.parent / preview.STATE_NAME).glob("slot-*.app"))), 2)

    def test_owned_update_completes_app_only_registration_without_forcing_launchservices(self):
        self.operation("install", self.old)
        integration = self.ops.integration
        observed = []

        def apply_registers_app(app, action, *args, **kwargs):
            result = integration(app, action, *args, **kwargs)
            if action == "apply":
                self.ops.applications.add(self.app)
                observed.append(self.ops.registration_state(self.app))
                self.ops.commands.clear()
            return result

        with patch.object(self.ops, "integration", side_effect=apply_registers_app):
            self.operation("install", self.new)
        self.assertEqual(observed, [{"application": True, "extension": False}])
        self.assertEqual((self.app / "payload").read_text(), "new")
        self.assertIsNone(self.receipt()["transaction"])
        self.assertEqual([command for command in self.ops.commands if command[:2] == ["/usr/bin/pluginkit", "-a"]],
                         [["/usr/bin/pluginkit", "-a", str(self.app / preview.EXTENSION)]])
        self.assertFalse(any(command[:2] == [preview.LSREGISTER, "-f"] for command in self.ops.commands))

    def test_registration_pair_matrix_keeps_existing_components_and_refuses_unsafe_pairs(self):
        app = self.old
        extension = (metadata.BASE_ID + ".Extension", app / preview.EXTENSION)
        for application, plugin, owned in ((True, True, False), (False, False, False),
                                           (True, False, True), (True, False, False), (False, True, True)):
            with self.subTest(application=application, extension=plugin, transaction=owned):
                self.ops.applications = {app} if application else set()
                self.ops.extensions = {extension} if plugin else set()
                self.ops.commands.clear()
                refused = (application and not plugin and not owned) or (plugin and not application)
                if refused:
                    with self.assertRaisesRegex(ValueError, "Partial") as failure:
                        self.ops.ensure_registration(app, complete_owned_app=owned)
                    self.assertIn(json.dumps({"application": application, "extension": plugin}, sort_keys=True),
                                  str(failure.exception))
                else:
                    self.ops.ensure_registration(app, complete_owned_app=owned)
                    self.ops.verify_registration(app)
                writes = [command for command in self.ops.commands
                          if command[:2] in ([preview.LSREGISTER, "-f"], ["/usr/bin/pluginkit", "-a"])]
                expected = [] if refused or (application and plugin) else (
                    [["/usr/bin/pluginkit", "-a", str(app / preview.EXTENSION)]] if application else
                    [[preview.LSREGISTER, "-f", str(app)],
                     ["/usr/bin/pluginkit", "-a", str(app / preview.EXTENSION)]])
                self.assertEqual(writes, expected)

    def test_owned_app_only_completion_rechecks_pair_before_any_write(self):
        app = self.old
        extension = (metadata.BASE_ID + ".Extension", app / preview.EXTENSION)
        original = self.ops.registration_state
        for application, plugin in ((True, True), (False, True), (False, False)):
            with self.subTest(application=application, extension=plugin):
                self.ops.applications = {app}
                self.ops.extensions = set()
                self.ops.commands.clear()
                reads = 0

                def changed_pair(target):
                    nonlocal reads
                    reads += 1
                    if reads == 2:
                        self.ops.applications = {app} if application else set()
                        self.ops.extensions = {extension} if plugin else set()
                    return original(target)

                with patch.object(self.ops, "registration_state", side_effect=changed_pair):
                    if application and plugin:
                        self.ops.ensure_registration(app, complete_owned_app=True)
                    else:
                        with self.assertRaisesRegex(ValueError, "changed before completion"):
                            self.ops.ensure_registration(app, complete_owned_app=True)
                self.assertFalse(any(command[:2] in ([preview.LSREGISTER, "-f"], ["/usr/bin/pluginkit", "-a"])
                                     for command in self.ops.commands))

    def test_owned_app_only_completion_requires_exact_readback_not_exit_zero(self):
        self.ops.applications.add(self.old)
        original = self.ops.run

        def incomplete_add(command, **kwargs):
            if command[:2] == ["/usr/bin/pluginkit", "-a"]:
                self.ops.commands.append(command)
                return subprocess.CompletedProcess(command, 0, "", "")
            return original(command, **kwargs)

        with patch.object(self.ops, "run", side_effect=incomplete_add), \
                self.assertRaisesRegex(ValueError, '"application": true, "extension": false'):
            self.ops.ensure_registration(self.old, complete_owned_app=True)
        self.assertFalse(any(command[:2] == [preview.LSREGISTER, "-f"] for command in self.ops.commands))

    def test_owned_partial_restoration_adds_only_extension_and_preserves_retired_bridge(self):
        self.operation("install", self.old)
        before = (self.home / ".copilot/synthetic-owned-integration.json").read_bytes()
        integration = self.ops.integration

        def restore_registers_app(app, action, *args, **kwargs):
            result = integration(app, action, *args, **kwargs)
            if action == "restore":
                self.ops.applications.add(self.app)
                self.assertEqual(self.ops.registration_state(self.app), {"application": True, "extension": False})
                self.ops.commands.clear()
            return result

        self.ops.failures["integration-verify"] = OSError("late candidate failure")
        with patch.object(self.ops, "integration", side_effect=restore_registers_app), \
                self.assertRaisesRegex(OSError, "late candidate failure"):
            self.operation("install", self.new)
        self.assertEqual((self.app / "payload").read_text(), "old")
        self.assertEqual((self.retired() / "payload").read_text(), "new")
        self.assertEqual((self.home / ".copilot/synthetic-owned-integration.json").read_bytes(), before)
        self.assertIsNone(self.receipt()["transaction"])
        self.assertFalse(any(command[:2] == [preview.LSREGISTER, "-f"] for command in self.ops.commands))
        self.assertEqual([command for command in self.ops.commands if command[:2] == ["/usr/bin/pluginkit", "-a"]],
                         [["/usr/bin/pluginkit", "-a", str(self.app / preview.EXTENSION)]])

    def test_committed_recovery_completes_app_only_pair_once_without_republishing_app(self):
        self.operation("install", self.old)
        self.ops.failures["integration-release"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("install", self.new)
        self.assertEqual(self.receipt()["transaction"]["phase"], "committed")
        self.ops.extensions.discard((metadata.BASE_ID + ".Extension", self.app / preview.EXTENSION))
        self.ops.commands.clear()
        self.operation("recover")
        self.operation("recover")
        self.assertIsNone(self.receipt()["transaction"])
        self.assertEqual((self.app / "payload").read_text(), "new")
        self.assertEqual([command for command in self.ops.commands if command[:2] == ["/usr/bin/pluginkit", "-a"]],
                         [["/usr/bin/pluginkit", "-a", str(self.app / preview.EXTENSION)]])
        self.assertFalse(any(command[:2] == [preview.LSREGISTER, "-f"] for command in self.ops.commands))

    def test_staging_cleanup_keeps_publication_authority_until_partial_readback_completes(self):
        self.operation("install", self.old)
        self.operation("install", self.new)
        self.operation("install", self.latest)
        before = self.receipt()

        def failed_copy(source, destination):
            (destination / "partial").write_text("not verified")
            self.ops.extensions.discard((metadata.BASE_ID + ".Extension", self.app / preview.EXTENSION))
            self.ops.commands.clear()
            raise OSError("copy failed")

        with patch.object(self.ops, "copy", side_effect=failed_copy), self.assertRaisesRegex(OSError, "copy failed"):
            self.operation("install", self.fixture("fourth"))
        self.assertEqual(self.receipt(), before)
        self.assertEqual((self.retired() / "payload").read_text(), "old")
        self.assertEqual([command for command in self.ops.commands if command[:2] == ["/usr/bin/pluginkit", "-a"]],
                         [["/usr/bin/pluginkit", "-a", str(self.app / preview.EXTENSION)]])
        self.assertFalse(any(command[:2] == [preview.LSREGISTER, "-f"] for command in self.ops.commands))

    def test_publication_rechecks_owned_app_identity_after_apply_before_completing_partial_pair(self):
        self.operation("install", self.old)
        integration = self.ops.integration

        def changed_app(app, action, *args, **kwargs):
            result = integration(app, action, *args, **kwargs)
            if action == "apply":
                self.ops.applications.add(self.app)
                (self.app / "payload").write_text("foreign mutation")
                self.ops.commands.clear()
            return result

        with patch.object(self.ops, "integration", side_effect=changed_app), \
                self.assertRaises(preview.InstallRestorationError):
            self.operation("install", self.new)
        self.assertIsNotNone(self.receipt()["transaction"])
        self.assertEqual((self.app / "payload").read_text(), "foreign mutation")
        self.assertFalse(any(command[:2] in ([preview.LSREGISTER, "-f"], ["/usr/bin/pluginkit", "-a"])
                             for command in self.ops.commands))

    def test_stage_failure_preserves_existing_retired_bridge_and_running_app(self):
        self.operation("install", self.old)
        self.operation("install", self.new)
        self.operation("install", self.latest)
        running = self.start_containing_app(hidden=True)
        retired = self.retired()
        node = preview.directory_identity(retired)
        before = self.receipt()
        self.ops.commands.clear()
        self.ops.application_calls.clear()
        self.ops.failures["copy"] = OSError("stage failed")
        with self.assertRaisesRegex(OSError, "stage failed"):
            self.operation("install", self.fixture("fourth"))
        self.assertEqual(self.receipt(), before)
        self.assertEqual(preview.directory_identity(retired), node)
        self.assertEqual(self.ops.running_application, running)
        self.assertEqual(self.ops.application_calls, [])
        self.assertFalse(any(command[:2] in ([preview.LSREGISTER, "-f"], [preview.LSREGISTER, "-u"],
                                             ["/usr/bin/pluginkit", "-a"], ["/usr/bin/pluginkit", "-r"])
                             for command in self.ops.commands))

    def test_failed_update_retains_new_bridge_for_older_running_app_without_lifecycle_bridge(self):
        self.operation("install", self.old)
        # An older installer owned this app before either bridge was introduced.
        self.change_plist(self.app, False, "CMUXMaestroAppLifecycleBridge", "")
        self.change_plist(self.app, False, "CMUXMaestroInstallBridge", "")
        receipt_path = self.app.parent / preview.STATE_NAME / "receipt.json"
        receipt = self.receipt()
        receipt["current"]["sha256"] = preview.digest(self.app)
        receipt_path.write_text(json.dumps(receipt))
        running = self.ops.application_lifecycle(self.new, "launch", self.app, hidden=True)
        self.ops.application_calls.clear()
        before = (self.home / ".copilot/synthetic-owned-integration.json").read_bytes()
        self.ops.failures["integration-after-apply"] = OSError("candidate failed")
        with self.assertRaisesRegex(OSError, "candidate failed"):
            self.operation("install", self.new)
        self.assertEqual((self.app / "payload").read_text(), "old")
        self.assertEqual((self.retired() / "payload").read_text(), "new")
        self.assertEqual(self.ops.integration_calls[-1][0], "release")
        self.assertEqual(self.ops.integration_calls[-1][2], self.retired())
        self.assertEqual(self.ops.application_bridges[-1], self.retired())
        self.assertTrue(self.ops.running_application["hidden"])
        self.assertNotEqual(self.ops.running_application["process"]["pid"], running["process"]["pid"])
        self.assertEqual((self.home / ".copilot/synthetic-owned-integration.json").read_bytes(), before)
        self.ops.verify_registration(self.retired(), absent=True)

    def test_repeated_failed_updates_keep_one_retired_without_postpublication_mutators(self):
        self.operation("install", self.old)
        self.operation("install", self.new)
        before = (self.home / ".copilot/synthetic-owned-integration.json").read_bytes()
        for index in range(3):
            candidate = self.fixture(f"failed-{index}")
            self.ops.commands.clear()
            self.ops.failures["integration-after-apply"] = OSError("candidate failed")
            with self.assertRaises(OSError):
                self.operation("install", candidate)
            self.assertEqual((self.app / "payload").read_text(), "new")
            self.assertEqual((self.previous() / "payload").read_text(), "old")
            self.assertEqual((self.retired() / "payload").read_text(), f"failed-{index}")
            self.assertEqual((self.home / ".copilot/synthetic-owned-integration.json").read_bytes(), before)
            publications = [i for i, command in enumerate(self.ops.commands)
                            if command[:2] == [preview.LSREGISTER, "-f"]]
            self.assertEqual(len(publications), 1)
            self.assertFalse(any(command[:2] in ([preview.LSREGISTER, "-u"], ["/usr/bin/pluginkit", "-r"])
                                 for command in self.ops.commands[publications[0]:]))
            self.assertEqual(len(list((self.app.parent / preview.STATE_NAME).glob("slot-*.app"))), 2)

    def test_registered_owned_retired_is_preflight_allowed_then_withdrawn_before_reclaim(self):
        self.operation("install", self.old)
        self.operation("install", self.new)
        self.operation("install", self.latest)
        retired = self.retired()
        self.ops.register(retired)
        self.ops.commands.clear()
        with self.assertRaises(ValueError):
            self.operation("install", self.latest)
        self.assertFalse(any(command[:2] in ([preview.LSREGISTER, "-f"], [preview.LSREGISTER, "-u"])
                             for command in self.ops.commands))
        self.operation("install", self.fixture("fourth"))
        self.assertFalse(retired.exists())
        self.assertNotIn(retired, self.ops.applications)
        self.assertEqual((self.retired() / "payload").read_text(), "new")

    def test_refresh_explicit_source_retirement_failure_restores_before_final_publication(self):
        self.operation("install", self.old)
        self.start_containing_app(hidden=True)
        self.ops.register(self.old)
        self.ops.commands.clear()
        self.ops.failures["integration-verify"] = OSError("refresh failed")
        with patch.object(preview, "DEVELOPMENT_APP", self.old), self.assertRaisesRegex(OSError, "refresh failed"):
            self.operation("install", self.old, retire_source=True)
        self.assertIn(self.old, self.ops.applications)
        self.assertTrue(self.ops.running_application["hidden"])
        self.assertIsNone(self.receipt()["transaction"])
        publications = [i for i, command in enumerate(self.ops.commands)
                        if command == [preview.LSREGISTER, "-f", str(self.app)]]
        self.assertEqual(len(publications), 2)  # Failed refresh, then a separately withdrawn restoration.
        self.assertFalse(any(command[:2] in ([preview.LSREGISTER, "-u"], ["/usr/bin/pluginkit", "-r"])
                             for command in self.ops.commands[publications[-1]:]))

    def test_retired_cannot_alias_staging_or_active_deletion(self):
        self.operation("install", self.old)
        self.ops.failures["before-move"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("install", self.new)
        path = self.app.parent / preview.STATE_NAME / "receipt.json"
        before = self.receipt()
        for target in ("transaction", "garbage"):
            with self.subTest(target=target):
                record = json.loads(json.dumps(before))
                slot = record["transaction"]["slot"]
                record["retired"] = {"slot": slot, "identity": record["transaction"]["after"]}
                if target == "garbage":
                    record["transaction"]["phase"] = "reclaiming"
                    record["garbage"] = {**record["retired"], "deleting": False, "node": None}
                path.write_text(json.dumps(record))
                self.ops.commands.clear()
                with self.assertRaisesRegex(ValueError, "Aliased"):
                    self.operation("recover")
                self.assertEqual(self.ops.commands, [])
        path.write_text(json.dumps(before))
        self.operation("recover")

    def test_restoration_crash_after_publication_reuses_registration_and_retains_bridge(self):
        self.operation("install", self.old)
        self.start_containing_app(hidden=True)
        self.ops.failures["integration-after-apply"] = OSError("candidate failed")
        self.ops.failures["after-register"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("install", self.new)
        self.assertEqual((self.app / "payload").read_text(), "old")
        self.assertIsNone(self.receipt()["retired"])
        self.assertIsNotNone(self.receipt()["transaction"])
        self.ops.commands.clear()
        self.operation("recover")
        self.assertFalse(any(command[:2] in ([preview.LSREGISTER, "-f"], [preview.LSREGISTER, "-u"],
                                             ["/usr/bin/pluginkit", "-a"], ["/usr/bin/pluginkit", "-r"])
                             for command in self.ops.commands))
        self.assertEqual((self.retired() / "payload").read_text(), "new")
        self.assertTrue(self.ops.running_application["hidden"])

    def test_committed_release_and_final_receipt_interruptions_do_not_republish(self):
        self.operation("install", self.old)
        self.operation("install", self.new)
        self.ops.failures["integration-release"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("install", self.latest)
        self.assertEqual(self.receipt()["transaction"]["phase"], "committed")
        self.assertIsNone(self.receipt()["retired"])
        self.ops.commands.clear()
        original = preview.Installer.save

        def final_receipt(installer):
            if installer.receipt["transaction"] is None:
                raise Interrupted()
            original(installer)

        with patch.object(preview.Installer, "save", side_effect=final_receipt, autospec=True):
            with self.assertRaises(Interrupted):
                self.operation("recover")
        self.assertEqual(self.receipt()["transaction"]["integration"]["state"], "released")
        self.operation("recover")
        self.assertFalse(any(command[:2] in ([preview.LSREGISTER, "-f"], ["/usr/bin/pluginkit", "-a"])
                             for command in self.ops.commands))
        self.assertEqual((self.retired() / "payload").read_text(), "old")
        self.assertEqual((self.previous() / "payload").read_text(), "new")
        self.assertEqual((self.app / "payload").read_text(), "latest")

    def test_retired_alias_tamper_and_missing_artifacts_refuse_without_mutation(self):
        self.operation("install", self.old)
        self.operation("install", self.new)
        self.operation("install", self.latest)
        path = self.app.parent / preview.STATE_NAME / "receipt.json"
        before = path.read_bytes()
        retired = self.retired()
        for mode in ("alias", "tamper", "missing"):
            with self.subTest(mode=mode):
                if mode == "alias":
                    record = json.loads(before)
                    record["retired"] = record["previous"]
                    path.write_text(json.dumps(record))
                elif mode == "tamper":
                    (retired / "payload").write_text("foreign")
                else:
                    retired.rename(self.root / "saved-retired")
                self.ops.commands.clear()
                with self.assertRaises((ValueError, FileNotFoundError)):
                    self.operation("install", self.latest)
                self.assertFalse(any(command[:2] in ([preview.LSREGISTER, "-f"], [preview.LSREGISTER, "-u"],
                                                     ["/usr/bin/pluginkit", "-a"], ["/usr/bin/pluginkit", "-r"])
                                     for command in self.ops.commands))
                path.write_bytes(before)
                if mode == "tamper":
                    (retired / "payload").write_text("old")
                if mode == "missing":
                    (self.root / "saved-retired").rename(retired)

    def test_external_eligible_or_ambiguous_siblings_refuse_before_staging_or_provider_effects(self):
        self.operation("install", self.old)
        sibling = self.fixture("external")
        self.ops.register(sibling)
        extension = (metadata.BASE_ID + ".Extension", sibling / preview.EXTENSION)
        before = self.receipt()
        for election in ("+", "", "?", "!"):
            with self.subTest(election=election):
                self.ops.elections[extension] = election
                self.ops.commands.clear()
                self.ops.integration_calls.clear()
                with self.assertRaisesRegex(ValueError, "external.app"):
                    self.operation("install", self.new)
                self.assertEqual(self.receipt(), before)
                self.assertEqual(self.ops.integration_calls, [])
                self.assertFalse(any(command[0] == "/usr/bin/ditto" or command[:2] in (
                    [preview.LSREGISTER, "-f"], [preview.LSREGISTER, "-u"], ["/usr/bin/pluginkit", "-a"],
                    ["/usr/bin/pluginkit", "-r"]) for command in self.ops.commands))
                self.assertIn(extension, self.ops.extensions)
        self.ops.elections[extension] = "-"
        self.operation("install", self.new)
        self.assertIn(extension, self.ops.extensions)

    def test_legacy_receipt_without_retired_and_healthy_retired_recovery_are_compatible(self):
        self.operation("install", self.old)
        path = self.app.parent / preview.STATE_NAME / "receipt.json"
        record = self.receipt()
        del record["retired"]
        path.write_text(json.dumps(record))
        self.operation("install", self.new)
        self.operation("install", self.latest)
        before = self.receipt()
        self.ops.commands.clear()
        self.operation("recover")
        self.assertEqual(self.receipt(), before)
        self.assertIn("inactive retired: one", self.operation("status"))
        self.assertFalse(any(command[:2] in ([preview.LSREGISTER, "-f"], [preview.LSREGISTER, "-u"],
                                             ["/usr/bin/pluginkit", "-a"], ["/usr/bin/pluginkit", "-r"])
                             for command in self.ops.commands))

    def test_uninstall_includes_exact_retired_slot_without_sibling_sweep(self):
        self.operation("install", self.old)
        self.operation("install", self.new)
        self.operation("install", self.latest)
        sibling = self.fixture("ignored")
        self.ops.register(sibling)
        self.ops.elections[(metadata.BASE_ID + ".Extension", sibling / preview.EXTENSION)] = "-"
        self.operation("uninstall", hooks_retired=True)
        self.assertFalse(self.app.exists())
        self.assertIsNone(self.receipt()["retired"])
        self.assertEqual(list((self.app.parent / preview.STATE_NAME).glob("slot-*.app")), [])
        self.assertIn(sibling, self.ops.applications)
        self.assertTrue(sibling.exists())

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
        self.ops.extension_points[unrelated / preview.EXTENSION] = "com.example.unrelated.point"
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
        self.ops.extension_points[unrelated / preview.EXTENSION] = "com.example.unrelated.point"
        before = self.receipt()
        for point in ("copy", "before-move"):
            with self.subTest(point=point):
                self.operation("prepare_update")
                self.ops.failures[point] = OSError("synthetic update failure")
                with self.assertRaises(OSError):
                    self.operation("install", self.latest, update=True)
                self.operation("recover")
                self.assertEqual(self.receipt(), {**before, "retired": self.receipt()["retired"]})
                if point == "before-move":
                    self.assertEqual(self.receipt()["retired"]["identity"]["sha256"], preview.digest(self.latest))
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
        with self.assertRaisesRegex(ValueError, "Partial"):
            self.operation("recover")
        self.operation("prepare_update")
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
        self.assertEqual(len(list((self.app.parent / preview.STATE_NAME).glob("slot-*.app"))), 2)
        self.assertEqual((self.retired() / "payload").read_text(), "old")
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

    def test_identical_build_is_verified_noop_and_install_upgrades_in_place(self):
        with self.assertRaises(ValueError):
            self.operation("install", self.old, update=True)
        self.operation("install", self.old)
        before = self.receipt()
        inode = self.app.stat().st_ino
        self.ops.busy = True
        for update in (False, True):
            self.assertIn("Identical app and Copilot integration verified", self.operation("install", self.old, update=update))
            self.assertEqual(self.receipt(), before)
            self.assertEqual(self.app.stat().st_ino, inode)
        self.ops.busy = False
        self.operation("install", self.new)
        self.assertEqual((self.app / "payload").read_text(), "new")
        self.assertEqual((self.previous() / "payload").read_text(), "old")
        self.assertIsNone(self.receipt()["transaction"])

    def test_identical_build_does_not_hide_missing_registration_or_tampered_app(self):
        self.operation("install", self.old)
        before = self.receipt()
        self.ops.unregister(self.app)
        with self.assertRaisesRegex(ValueError, "LaunchServices"):
            self.operation("install", self.old)
        self.assertEqual(self.receipt(), before)
        self.ops.register(self.app)
        (self.app / "payload").write_text("tampered")
        with self.assertRaisesRegex(ValueError, "integrity mismatch"):
            self.operation("install", self.old)
        self.assertEqual(self.receipt(), before)

    def test_pre_bridge_source_is_refused_without_launch_or_staging(self):
        for value in (None, True, "unsupported"):
            with self.subTest(value=value):
                self.change_plist(self.old, False, "CMUXMaestroInstallBridge", value if value is not None else "")
                with self.assertRaisesRegex(ValueError, "non-UI install bridge"):
                    self.operation("install", self.old)
                self.assertFalse(self.app.exists())
                self.assertIsNone(self.receipt()["transaction"])
                self.assertEqual(self.ops.integration_calls, [])

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
        self.assertIn(self.app, self.ops.applications)
        self.assertIn((metadata.BASE_ID + ".Extension", self.app / preview.EXTENSION), self.ops.extensions)

    def test_update_automatically_withdraws_waits_and_registers_only_owned_app(self):
        self.operation("install", self.old)
        unrelated = self.fixture("other-owner")
        self.ops.register(unrelated)
        self.ops.extension_points[unrelated / preview.EXTENSION] = "com.example.unrelated.point"
        self.ops.commands.clear()
        self.ops.busy = True
        self.ops.release_on_withdrawal = True
        with patch.object(self.ops, "wait_idle", wraps=self.ops.wait_idle) as wait:
            self.operation("install", self.new)
        wait.assert_called_once_with(self.app)
        commands = self.ops.commands
        remove = commands.index(["/usr/bin/pluginkit", "-r", str(self.app / preview.EXTENSION)])
        add = commands.index(["/usr/bin/pluginkit", "-a", str(self.app / preview.EXTENSION)])
        self.assertLess(remove, add)
        self.assertEqual((self.app / "payload").read_text(), "new")
        self.assertIn(unrelated, self.ops.applications)
        self.assertIn((metadata.BASE_ID + ".Extension", unrelated / preview.EXTENSION), self.ops.extensions)
        self.assertFalse(any(str(unrelated) in command and command[1] == "-u" for command in commands))
        self.assertIsNone(self.receipt()["transaction"])

    def test_release_wait_is_bounded_and_retries_only_positive_owned_process_evidence(self):
        operations = preview.MacOperations()
        busy = preview.PreviewBusyError("owned process still running")
        with patch.object(operations, "assert_idle", side_effect=[busy, None]) as probe, \
                patch.object(preview.time, "sleep") as sleep, \
                patch.object(preview.time, "monotonic", side_effect=[0, 1]):
            operations.wait_idle(self.app)
            self.assertEqual(probe.call_count, 2)
            sleep.assert_called_once_with(0.1)
        with patch.object(operations, "assert_idle", side_effect=busy), \
                patch.object(preview.time, "sleep") as sleep, \
                patch.object(preview.time, "monotonic", side_effect=[0, 120]), \
                self.assertRaises(preview.PreviewBusyError):
            operations.wait_idle(self.app)
        sleep.assert_not_called()
        with patch.object(operations, "assert_idle", side_effect=ValueError("unverifiable process")), \
                patch.object(preview.time, "sleep") as sleep, self.assertRaisesRegex(ValueError, "unverifiable"):
            operations.wait_idle(self.app)
        sleep.assert_not_called()

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
        self.assertIsNone(self.receipt()["transaction"])
        self.assertEqual((self.app / "payload").read_text(), "old")
        self.assertIn("Verified installed preview", self.operation("status"))
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
                self.operation("recover")
                self.assertFalse(self.app.exists())
                self.assertFalse((self.home / ".copilot/synthetic-owned-integration.json").exists())
                self.assertIsNone(self.receipt()["transaction"])

    def test_interrupted_combined_update_restores_before_and_after_exchange(self):
        self.operation("install", self.old)
        for point in ("before-move", "after-move"):
            with self.subTest(point=point):
                self.ops.failures[point] = Interrupted()
                with self.assertRaises(Interrupted):
                    self.operation("install", self.new, update=True)
                self.operation("recover")
                self.assertEqual((self.app / "payload").read_text(), "old")
                self.assertIsNone(self.receipt()["previous"])
        self.operation("install", self.new, update=True)
        self.assertEqual((self.previous() / "payload").read_text(), "old")

    def test_interrupted_precommit_discard_is_resumable(self):
        self.operation("install", self.old)
        # Partial staging stays unverified and is deleted, never retained as a trusted app.
        self.ops.failures["after-copy"] = Interrupted()
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

    def test_registration_failure_automatically_restores_verified_old_app(self):
        self.operation("install", self.old)
        before = self.receipt()
        for point in ("register", "after-register"):
            with self.subTest(point=point):
                self.ops.failures[point] = OSError("synthetic registry failure")
                with self.assertRaises(OSError):
                    self.operation("install", self.new, update=True)
                self.assertEqual((self.app / "payload").read_text(), "old")
                self.assertEqual(self.receipt(), {**before, "retired": self.receipt()["retired"]})
                self.assertEqual(self.receipt()["retired"]["identity"]["sha256"], preview.digest(self.new))
                self.assertIn("Verified installed preview", self.operation("status"))

    def test_failed_first_install_restores_verified_absence(self):
        for point in ("copy", "before-move", "after-move", "register", "after-register"):
            with self.subTest(point=point):
                self.ops.failures[point] = OSError("synthetic first-install failure")
                with self.assertRaises(OSError):
                    self.operation("install", self.old)
                self.assertFalse(self.app.exists())
                self.assertIsNone(self.receipt()["current"])
                self.assertIsNone(self.receipt()["transaction"])
                self.assertNotIn(self.app, self.ops.applications)
                self.assertNotIn((metadata.BASE_ID + ".Extension", self.app / preview.EXTENSION), self.ops.extensions)
                self.assertEqual(self.data.read_text(), "observation-data")

    def test_failed_restoration_retains_journal_and_reports_both_failures(self):
        self.operation("install", self.old)
        self.ops.failures["register"] = OSError("new registration failed")
        with patch.object(self.ops, "assert_idle", side_effect=[None, OSError("restore is busy")]):
            with self.assertRaisesRegex(preview.InstallRestorationError, "new registration failed.*restore is busy"):
                self.operation("install", self.new)
        self.assertIsNotNone(self.receipt()["transaction"])
        self.ops.failures.clear()
        self.operation("recover", restore_previous=True)
        self.assertEqual((self.app / "payload").read_text(), "old")

    def test_new_install_recovers_interrupted_exchange_before_retrying(self):
        self.operation("install", self.old)
        self.ops.failures["after-move"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("install", self.new)
        self.operation("install", self.latest)
        self.assertEqual((self.app / "payload").read_text(), "latest")
        self.assertEqual((self.previous() / "payload").read_text(), "old")
        self.assertIsNone(self.receipt()["transaction"])

    def test_incomplete_guardian_blocks_automatic_rollback_without_racing_it(self):
        self.operation("install", self.old)
        self.ops.failures["after-move"] = OSError("caller timed out")
        marker = {"schema": 1, "state": "running", "token": "a" * 32, "supervisor": 9911, "group": 9912}
        with patch.object(preview.command_worker, "read_marker", side_effect=[None, marker]):
            with self.assertRaisesRegex(preview.InstallRestorationError, "supervisor has not proved completion"):
                self.operation("install", self.new)
        self.assertEqual((self.app / "payload").read_text(), "new")
        self.assertEqual(self.receipt()["transaction"]["phase"], "ready")
        self.operation("recover", restore_previous=True)
        self.assertEqual((self.app / "payload").read_text(), "old")

    def test_first_install_absence_restoration_resumes_after_its_own_interruption(self):
        self.ops.failures["after-move"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("install", self.old)
        self.ops.failures["after-move"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("recover", restore_previous=True)
        self.assertFalse(self.app.exists())
        self.assertEqual(self.receipt()["transaction"]["phase"], "reverting")
        self.assertIn("prior app absence verified", self.operation("recover"))
        self.assertFalse(self.app.exists())
        self.assertIsNone(self.receipt()["transaction"])

    def test_exact_app_and_extension_registry_checks_not_exit_zero(self):
        for attribute in ("wrong_app", "wrong_extension"):
            with self.subTest(attribute=attribute):
                setattr(self.ops, attribute, True)
                with self.assertRaises((ValueError, preview.InstallRestorationError)):
                    self.operation("install", self.old)
                if self.app.exists():
                    self.assertEqual(attribute, "wrong_extension")
                    self.assertIsNotNone(self.receipt()["transaction"])
                    # Remove only the deliberately injected ambiguous fixture result.
                    self.ops.extensions.discard((metadata.BASE_ID + ".Extension",
                                                  (self.app / preview.EXTENSION).parent / "Wrong.appex"))
                    setattr(self.ops, attribute, False)
                    self.operation("recover")
                self.assertFalse(self.app.exists())
                self.assertIsNone(self.receipt()["transaction"])
                setattr(self.ops, attribute, False)
                self.operation("recover")

    def test_superseded_and_ignored_siblings_survive_complete_install_lifecycle(self):
        identifier = metadata.BASE_ID + ".Extension"
        sibling_apps = [self.fixture("superseded-sibling"), self.fixture("unknown-sibling")]
        siblings = {(identifier, app / preview.EXTENSION) for app in sibling_apps}
        unrelated = ("com.example.Unrelated.Extension", self.root / "Unrelated.appex")
        self.ops.applications.update(sibling_apps)
        self.ops.extensions.update(siblings | {unrelated})
        self.ops.elections = {
            (identifier, sibling_apps[0] / preview.EXTENSION): "=",
            (identifier, sibling_apps[1] / preview.EXTENSION): "-",
        }
        self.operation("install", self.old)
        self.ops.failures["after-register"] = Interrupted()
        with self.assertRaises(Interrupted):
            self.operation("install", self.new, update=True)
        self.operation("recover")
        self.assertEqual((self.app / "payload").read_text(), "old")
        self.operation("install", self.new, update=True)
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
            if (installer.receipt["transaction"] and installer.receipt["transaction"]["phase"] == "committed"
                    and installer.receipt["transaction"]["after"]["sha256"] == preview.digest(self.new)):
                raise OSError("metadata disk full after successful registration")
            original(installer)

        with patch.object(preview.Installer, "save", fail_after_registration):
            with self.assertRaises(OSError):
                self.operation("install", self.new, update=True)
        self.assertIsNone(self.receipt()["transaction"])
        self.assertEqual((self.app / "payload").read_text(), "old")
        self.operation("recover")
        self.assertIsNone(self.receipt()["previous"])

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
        self.operation("install", self.latest, update=True)
        running = self.start_containing_app(hidden=True)
        next_app = self.fixture("fourth")
        original = preview.shutil.rmtree

        def interrupted(path):
            (path / "payload").unlink()
            raise Interrupted()

        with patch.object(preview.shutil, "rmtree", interrupted):
            with self.assertRaises(Interrupted):
                self.operation("install", next_app, update=True)
        self.assertTrue(self.receipt()["garbage"]["deleting"])
        self.assertEqual((self.previous() / "payload").read_text(), "new")
        self.assertEqual((self.app / "payload").read_text(), "latest")
        with patch.object(preview.shutil, "rmtree", original):
            self.operation("recover")
        self.assertIsNone(self.receipt()["garbage"])
        self.assertEqual((self.app / "payload").read_text(), "latest")
        self.assertEqual((self.retired() / "payload").read_text(), "fourth")
        self.assertTrue(self.ops.running_application["hidden"])
        self.assertNotEqual(self.ops.running_application["process"]["pid"], running["process"]["pid"])
        self.assertEqual(self.ops.application_bridges[-1], self.retired())

    def test_replaced_cleanup_slot_is_refused_after_interrupted_deletion(self):
        self.operation("install", self.old)
        self.operation("install", self.new, update=True)
        self.operation("install", self.latest, update=True)
        with patch.object(preview.shutil, "rmtree", side_effect=Interrupted()):
            with self.assertRaises(Interrupted):
                self.operation("install", self.fixture("fourth"), update=True)
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
        with self.assertRaisesRegex(ValueError, "External same-ID"):
            self.operation("install", self.old)
        self.assertIn(self.old, self.ops.applications)
        self.assertFalse(any(command[:2] == [preview.LSREGISTER, "-u"] for command in self.ops.commands))

    def test_failed_install_restores_exact_development_registration_state(self):
        self.operation("install", self.old)
        extension = (metadata.BASE_ID + ".Extension", self.new / preview.EXTENSION)
        for application, plugin in ((False, False), (True, True), (True, False), (False, True)):
            with self.subTest(application=application, extension=plugin), \
                    patch.object(preview, "DEVELOPMENT_APP", self.new):
                if application:
                    self.ops.applications.add(self.new)
                else:
                    self.ops.applications.discard(self.new)
                if plugin:
                    self.ops.extensions.add(extension)
                else:
                    self.ops.extensions.discard(extension)
                self.ops.failures["after-register"] = OSError("stable registration failed")
                with self.assertRaises(OSError):
                    self.operation("install", self.new, retire_source=True)
                self.assertEqual(self.new in self.ops.applications, application)
                self.assertEqual(extension in self.ops.extensions, plugin)
                self.assertEqual((self.app / "payload").read_text(), "old")
                self.assertIsNone(self.receipt()["transaction"])

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
