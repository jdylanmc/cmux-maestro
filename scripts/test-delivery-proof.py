#!/usr/bin/env python3
"""Fixture/launcher contracts only: never authenticates or launches a real provider."""

import copy
from contextlib import contextmanager
import io
import hashlib
import json
import os
from pathlib import Path
import runpy
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid

REPO = Path(__file__).resolve().parents[1]
PROOF = runpy.run_path(str(REPO / "scripts/delivery-proof/fixture.py"))
CONTROLLER = runpy.run_path(str(REPO / "scripts/cmux-maestro-orchestrator.py"))
MAX_LIVE_WORKERS = CONTROLLER["MAX_LIVE_WORKERS"]


class StoreBudgetTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.ticks = 0
        self.release_at = None
        self.blocker = None
        self.clock = SimpleNamespace(
            monotonic=lambda: self.ticks * 0.05, sleep=self.advance,
        )

    def advance(self, seconds):
        self.assertEqual(seconds, 0.05)
        self.ticks += 1
        if self.release_at is not None and self.ticks >= self.release_at:
            self.blocker.__exit__(None, None, None)
            self.release_at = None

    def test_capacity_budget_allows_contended_reader_and_writer_to_acquire(self):
        acquire = CONTROLLER["with_store"]
        for read_only in (False, True):
            with self.subTest(read_only=read_only):
                self.ticks, self.release_at = 0, 60
                with CONTROLLER["Store"](self.root) as self.blocker, mock.patch.dict(
                    acquire.__globals__, {"time": self.clock, "MAX_LIVE_WORKERS": 4 * 8}
                ):
                    operation = mock.Mock(side_effect=lambda store: store.read())
                    result = acquire(self.root, operation, wait=2, read_only=read_only)
                self.assertEqual(result["nodes"], {})
                operation.assert_called_once()
                self.assertEqual(operation.call_args.args[0].read_only, read_only)
                self.assertEqual(self.ticks, 60)

    def test_capacity_budget_remains_bounded_and_preserves_zero_wait(self):
        acquire = CONTROLLER["with_store"]
        for capacity, multiplier in ((4, 1), (8, 1), (16, 2), (4 * 8, 4)):
            for wait in (0, 1, 2):
                with self.subTest(capacity=capacity, wait=wait):
                    self.ticks, self.release_at = 0, None
                    with CONTROLLER["Store"](self.root), mock.patch.dict(
                        acquire.__globals__, {"time": self.clock, "MAX_LIVE_WORKERS": capacity}
                    ):
                        operation = mock.Mock()
                        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "operation is active"):
                            acquire(self.root, operation, wait=wait)
                    operation.assert_not_called()
                    self.assertAlmostEqual(self.clock.monotonic(), wait * multiplier)

    def test_non_contention_failure_is_not_retried(self):
        acquire = CONTROLLER["with_store"]
        operation = mock.Mock(side_effect=CONTROLLER["OrchestrationError"]("Invalid synthetic state"))
        with mock.patch.dict(acquire.__globals__, {"time": self.clock}):
            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "Invalid synthetic state"):
                acquire(self.root, operation, wait=2)
        operation.assert_called_once()
        self.assertEqual(self.ticks, 0)

    def test_workspace_limits_do_not_change_reference_wait_budget(self):
        acquire = CONTROLLER["with_store"]
        workspace = str(uuid.uuid4())
        for limit in (1, 128):
            for wait in (0, 1, 2):
                with self.subTest(limit=limit, wait=wait):
                    self.ticks = 0
                    with CONTROLLER["Store"](self.root) as store:
                        state = store.read()
                        state["workspaceCapacity"] = {workspace: limit}
                        store.write(state)
                        with mock.patch.dict(acquire.__globals__, {"time": self.clock}):
                            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "operation is active"):
                                acquire(self.root, lambda _: None, wait=wait)
                    self.assertAlmostEqual(self.clock.monotonic(), wait * 4)


class WorkspaceCapacityTests(unittest.TestCase):
    def test_old_state_defaults_and_invalid_persisted_limits(self):
        state = CONTROLLER["empty_state"]()
        workspace = "abcdef00-0000-4000-8000-000000000001"
        CONTROLLER["validate_state"](state)
        summary = CONTROLLER["workspace_capacity"](state, workspace)
        self.assertEqual(summary["limit"], 32)
        self.assertEqual(summary["used"], 0)
        self.assertEqual(summary["nodeSlotsRemaining"], 128)
        self.assertTrue(summary["admissionAvailable"])
        for value in (0, 129, -1, True, "32", 32.0, None):
            with self.subTest(value=value), self.assertRaises(CONTROLLER["OrchestrationError"]):
                CONTROLLER["validate_state"]({**state, "workspaceCapacity": {workspace: value}})
        for value in ([], {"not-a-workspace": 32}, {workspace.upper(): 32},
                      {str(uuid.uuid4()): 32 for _ in range(129)}):
            with self.subTest(value=value), self.assertRaises(CONTROLLER["OrchestrationError"]):
                CONTROLLER["validate_state"]({**state, "workspaceCapacity": value})

    def test_summary_counts_pending_once_and_preserves_unknown_and_retained(self):
        workspace, other = str(uuid.uuid4()), str(uuid.uuid4())
        state = CONTROLLER["empty_state"]()
        state["workspaceCapacity"] = {workspace: 4}
        for role, phase, owner in (
            ("coordinator", "launching", workspace), ("worker", "launching", workspace),
            ("worker", "process-disappeared", workspace), ("worker", "resource-retired", workspace),
            ("worker", "launching", other), ("coordinator", "registered", workspace),
        ):
            identifier = str(uuid.uuid4())
            node = {"id": identifier, "role": role, "phase": phase, "workspaceId": owner}
            if role == "coordinator" and phase != "registered":
                node["executionMode"] = "interactive"
            state["nodes"][identifier] = node
            if phase == "launching":
                state["launches"][identifier] = {"workspaceId": owner}
        state["retainedResources"] = [{"workspaceId": workspace}, {"workspaceId": other}]
        summary = CONTROLLER["workspace_capacity"](state, workspace)
        self.assertEqual(summary, {
            "workspaceId": workspace, "limit": 4, "ceiling": 128, "managedRoots": 1,
            "workers": 2, "retainedResources": 1, "pendingLaunches": 2, "used": 4,
            "remaining": 0, "nodeSlotsRemaining": 122, "admissionAvailable": False, "advisory": True,
        })
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "resource limit"):
            CONTROLLER["require_workspace_capacity"](state, workspace)

    def test_configured_limit_does_not_hide_global_node_exhaustion(self):
        state = CONTROLLER["empty_state"]()
        workspace = str(uuid.uuid4())
        state["workspaceCapacity"] = {workspace: 128}
        state["nodes"] = {str(index): {"role": "coordinator", "workspaceId": workspace}
                          for index in range(128)}
        summary = CONTROLLER["workspace_capacity"](state, workspace)
        self.assertEqual(summary["remaining"], 128)
        self.assertEqual(summary["nodeSlotsRemaining"], 0)
        self.assertFalse(summary["admissionAvailable"])


class ProofTests(unittest.TestCase):
    def test_bounded_text_preserves_controls_unicode_and_byte_limits(self):
        validate = CONTROLLER["bounded_text"]
        error = CONTROLLER["OrchestrationError"]
        for code in range(256):
            value = "x" + chr(code) + "y"
            with self.subTest(code=code):
                if code < 32 and code not in (9, 10):
                    message = "safe limit" if code == 0 else "control characters"
                    with self.assertRaisesRegex(error, message):
                        validate(value, "Synthetic", 10)
                else:
                    self.assertEqual(validate(value, "Synthetic", 10), value)
        self.assertEqual(validate(" \U0001f600 ", "Synthetic", 6), "\U0001f600")
        with self.assertRaisesRegex(error, "safe limit"):
            validate("\U0001f600", "Synthetic", 3)
        with self.assertRaisesRegex(error, "invalid Unicode"):
            validate("\ud800", "Synthetic", 10)
        with self.assertRaisesRegex(error, "required"):
            validate(" \t\n", "Synthetic", 10)
        self.assertEqual(validate(" \t\n", "Synthetic", 10, empty=True), "")

    def setUp(self):
        source = Path(tempfile.mkdtemp(prefix="m61-", dir="/tmp")).resolve()
        self.addCleanup(shutil.rmtree, source)
        globals_patch = mock.patch.dict(PROOF["prepare"].__globals__, {
            "SOURCE": source, "BASE": source / ".build/dp",
        })
        globals_patch.start()
        self.addCleanup(globals_patch.stop)
        proof_patch = mock.patch.dict(CONTROLLER["delivery_proof_api"].__globals__, {
            "delivery_proof_api": lambda: PROOF,
        })
        proof_patch.start()
        self.addCleanup(proof_patch.stop)
        self.paths = PROOF["prepare"](uuid.uuid4().hex[:8])
        self.root = Path(self.paths["root"])
        self.addCleanup(shutil.rmtree, self.root)
        self.node = {
            "workspaceId": str(uuid.uuid4()), "copilotSessionId": str(uuid.uuid4()),
            "workingDirectory": self.paths["a"], "task": "Synthetic task", "label": "Proof",
            "toolPolicy": {"allow": [], "deny": ["web"]},
            "launchSettings": {"version": 1, "model": "synthetic-pinned-model"},
            "phase": "turn-running", "generation": 1,
        }

    def test_global_skill_exposes_messaging_without_implicit_permission_grants(self):
        skill = (REPO / "skills/maestro/SKILL.md").read_text()
        frontmatter = skill.split("---", 2)[1]
        self.assertEqual({line.split(":", 1)[0] for line in frontmatter.splitlines() if line}, {"name", "description"})
        self.assertIn("name: maestro", frontmatter)
        self.assertIn("`/maestro`", skill)
        self.assertIn('{"skill":"maestro"}', skill)
        self.assertNotIn("cmux-maestro-native:maestro", skill)
        self.assertIn("does not install the runtime", skill)
        for tool in ("maestro_peers", "maestro_send"):
            self.assertIn(f"`{tool}`", skill)
        for constraint in (
            "workspaceId", "sessionId", "generation", "4096 UTF-8 bytes",
            "/cmux-maestro-native:cmux-maestro-orchestrate", "messagingInstalled: true",
            "Worker actors cannot request YOLO", "delivery and completion are",
        ):
            self.assertIn(constraint, skill)
        self.assertTrue((REPO / "skills/maestro/intent.md").is_file())
        self.assertEqual(hashlib.sha256((REPO / "skills/maestro/intent.md").read_bytes()).hexdigest(),
                         "8dd1495be16e27a92b43a038ab7b728b4d6fedcbae1e53f41aac11452fe54d42")
        self.assertFalse((REPO / "skills/maestro/_atoms").exists())
        self.assertFalse((REPO / "skills/maestro/_molecules").exists())

    def test_global_guide_is_not_bundled_or_required_by_runtime_setup(self):
        project = (REPO / "CMUXMaestroPreview.xcodeproj/project.pbxproj").read_text()
        self.assertNotIn('path = "skills/maestro"', project)
        setup = (REPO / "CMUXMaestroPreview/Integration/CopilotSetup.swift").read_text()
        self.assertNotIn('resources.appendingPathComponent("maestro/SKILL.md")', setup)
        self.assertNotIn("npx", setup)
        launcher = (REPO / "scripts/cmux-maestro-orchestrator.py").read_text()
        self.assertNotIn("managed_plugin_directory", launcher)
        self.assertNotIn("--plugin-dir", launcher)

    def test_preparation_is_disposable_private_and_outside_source_discovery(self):
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        for peer in ("a", "b"):
            fixture = Path(self.paths[peer])
            self.assertTrue((fixture / ".git").is_dir())
            entry = fixture / ".github/extensions/maestro-delivery-proof/extension.mjs"
            self.assertIn('from "@github/copilot-sdk/extension"', entry.read_text())
            self.assertIn("adapter.mjs", entry.read_text())
            self.assertEqual(entry.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            PROOF["prepare"](self.root.name)
        with self.assertRaises(ValueError):
            PROOF["prepare"]("../elsewhere")

    def test_launch_binding_is_exact_exclusive_and_cross_workspace_refuses(self):
        config = PROOF["validate_fixture"](self.paths["a"], self.paths["a"])
        PROOF["bind"](config, self.node)
        binding = PROOF["read_private"](self.root / "a.json")
        self.assertEqual(binding["sessionId"], self.node["copilotSessionId"])
        self.assertEqual(binding["workspaceId"], self.node["workspaceId"])
        self.assertEqual(len(binding["capability"]), 64)
        with self.assertRaises(FileExistsError):
            PROOF["bind"](config, self.node)
        with self.assertRaises(ValueError):
            PROOF["validate_fixture"](self.paths["a"], self.paths["a"], fresh=True)
        node_b = {**self.node, "workingDirectory": self.paths["b"], "workspaceId": str(uuid.uuid4())}
        with self.assertRaises(ValueError):
            PROOF["bind"](PROOF["validate_fixture"](self.paths["b"], self.paths["b"]), node_b)

    def test_fixture_validation_refuses_mismatched_cwd_symlink_and_permissions(self):
        with self.assertRaises(ValueError):
            PROOF["validate_fixture"](self.paths["a"], self.paths["b"])
        marker = self.root / "proof.json"
        marker.chmod(0o644)
        with self.assertRaises(ValueError):
            PROOF["validate_fixture"](self.paths["a"], self.paths["a"])
        marker.chmod(0o600)
        original = marker.read_text()
        marker.unlink()
        (self.root / "saved.json").write_text(original)
        marker.symlink_to(self.root / "saved.json")
        with self.assertRaises(OSError):
            PROOF["validate_fixture"](self.paths["a"], self.paths["a"])

    def test_proof_forces_pinned_launch_settings_before_credentials_or_surface_creation(self):
        args = CONTROLLER["parser"]().parse_args([
            "spawn", "--actor-id", str(uuid.uuid4()), "--token", "synthetic",
            "--name", "Proof", "--task", "test", "--cwd", self.paths["a"],
            "--delivery-proof-fixture", self.paths["a"],
        ])
        spawn = CONTROLLER["command_spawn"]
        cmux = mock.Mock()
        with mock.patch.dict(spawn.__globals__, {
            "assigned_directory": lambda _: Path(self.paths["a"]),
            "git_display_metadata": lambda _: {},
            "read_state": lambda _: {},
            "authorize": lambda *a, **k: {},
            "worker_launch_settings": lambda _: {},
            "resolve_copilot_token": mock.Mock(side_effect=AssertionError("must not read credentials")),
        }):
            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "Pinned"):
                spawn(args, self.root, cmux)
        self.assertEqual(cmux.mock_calls, [])

    def run_mocked_launcher(self, *, on_started=None):
        run = CONTROLLER["run_interactive_session"]
        process = mock.Mock(pid=12345)
        process.poll.return_value = 0
        process.wait.return_value = 0
        popen = mock.Mock(return_value=process)
        if on_started is not None:
            def started(*args, **kwargs):
                on_started()
                return process
            popen.side_effect = started
        with mock.patch.dict(run.__globals__, {
            "trusted_executable": lambda *a: "/mock/copilot",
            "worker_environment": lambda *a: {"SYNTHETIC_PINNED_ENV": "preserved"},
            "process_start": lambda _: "synthetic-start",
            "mutate": lambda root, callback, **kw: callback({}),
            "authorize": lambda *a: self.node,
        }), mock.patch("os.isatty", return_value=True), mock.patch("signal.signal"), \
                mock.patch("subprocess.Popen", popen):
            run(self.root, "synthetic-worker", "synthetic-token", self.node)
        args = popen.call_args.args[0]
        self.assertEqual(args[:4], ["/mock/copilot", "--no-auto-update", "--interactive", "Synthetic task"])
        self.assertEqual(args[args.index("--model") + 1], "synthetic-pinned-model")
        self.assertEqual(args[args.index("--session-id") + 1], self.node["copilotSessionId"])
        self.assertNotIn("--allow-tool", args)
        self.assertNotIn("--plugin-dir", args)
        self.assertEqual(args[args.index("--deny-tool") + 1], "web")
        self.assertEqual(popen.call_args.kwargs, {
            "cwd": self.paths["a"], "env": {"SYNTHETIC_PINNED_ENV": "preserved"},
        })
        return args

    def test_opt_in_launcher_keeps_pinned_environment_model_policy_and_interactive_io(self):
        self.node["deliveryProof"] = {
            **PROOF["validate_fixture"](self.paths["a"], self.paths["a"]), "experimental": True,
        }
        self.assertIn("--experimental", self.run_mocked_launcher())

    def test_normal_launcher_does_not_enable_proof_or_experimental(self):
        args = self.run_mocked_launcher()
        self.assertEqual(args, [
            "/mock/copilot", "--no-auto-update", "--interactive", "Synthetic task",
            "--session-id", self.node["copilotSessionId"], "--name", "Proof",
            "-C", self.paths["a"], "--model", "synthetic-pinned-model", "--deny-tool", "web",
        ])
        self.assertFalse((self.root / "a.json").exists())

    def test_proof_does_not_enable_experimental_without_explicit_opt_in(self):
        self.node["deliveryProof"] = PROOF["validate_fixture"](self.paths["a"], self.paths["a"])
        args = self.run_mocked_launcher()
        self.assertNotIn("--experimental", args)
        self.assertNotIn("--allow-all", args)
        self.assertTrue((self.root / "a.json").is_file())

    def test_proof_yolo_is_explicit_and_preserves_denies_and_pins(self):
        self.node["deliveryProof"] = {
            **PROOF["validate_fixture"](self.paths["a"], self.paths["a"]), "yolo": True,
        }
        self.node["toolPolicy"]["deny"] += ["shell(git push)", "write(.env)"]
        args = self.run_mocked_launcher()
        self.assertEqual(args.count("--allow-all"), 1)
        self.assertNotIn("--experimental", args)
        self.assertEqual(
            [args[index + 1] for index, arg in enumerate(args) if arg == "--deny-tool"],
            self.node["toolPolicy"]["deny"],
        )

    def test_proof_explicit_yolo_false_does_not_grant_permissions(self):
        self.node["deliveryProof"] = {
            **PROOF["validate_fixture"](self.paths["a"], self.paths["a"]), "yolo": False,
        }
        self.assertNotIn("--allow-all", self.run_mocked_launcher())

    def test_spawn_serializes_per_proof_yolo_opt_in(self):
        spawn = CONTROLLER["command_spawn"]
        actor = {
            "id": str(uuid.uuid4()), "runId": str(uuid.uuid4()),
            "workspaceId": self.node["workspaceId"], "surfaceId": str(uuid.uuid4()),
            "role": "coordinator", "parentId": None,
        }
        class Reserved(Exception):
            pass

        for opted_in in (False, True):
            with self.subTest(opted_in=opted_in):
                state = {**CONTROLLER["empty_state"](), "nodes": {actor["id"]: dict(actor)}}
                args = CONTROLLER["parser"]().parse_args([
                    "spawn", "--actor-id", actor["id"], "--token", "synthetic",
                    "--name", "Proof", "--task", "test", "--cwd", self.paths["a"],
                    "--delivery-proof-fixture", self.paths["a"], "--deny-tool", "web",
                    *(["--delivery-proof-yolo"] if opted_in else []),
                ])

                def reserve_only(_root, callback):
                    callback(state)
                    raise Reserved()

                with mock.patch.dict(spawn.__globals__, {
                    "read_state": lambda _: state,
                    "provider_launch_context": lambda *_: ("/synthetic/copilot", "/usr/bin:/bin"),
                    "authorize": lambda *a: state["nodes"][actor["id"]],
                    "worker_launch_settings": lambda _: {
                        "version": 1, "copilotAccount": "synthetic-account", "model": "synthetic-pinned-model",
                    },
                    "resolve_copilot_token": mock.Mock(return_value=None),
                    "git_display_metadata": lambda _: CONTROLLER["absent_git_metadata"](),
                    "resolve_icon": lambda _: "synthetic-icon",
                    "resource_observations": lambda *a: ({}, set()),
                    "mutate": reserve_only,
                }):
                    with self.assertRaises(Reserved):
                        spawn(args, self.root, mock.Mock())
                worker = next(node for node in state["nodes"].values() if node["role"] == "worker")
                self.assertEqual(worker["deliveryProof"], {
                    "fixture": self.paths["a"], "experimental": False, "yolo": opted_in,
                })
                self.assertEqual(worker["toolPolicy"]["deny"], ["web"])

    def test_yolo_without_proof_refuses_before_state_credentials_or_surface_access(self):
        args = CONTROLLER["parser"]().parse_args([
            "spawn", "--actor-id", str(uuid.uuid4()), "--token", "synthetic",
            "--name", "Proof", "--task", "test", "--cwd", self.paths["a"],
            "--delivery-proof-yolo",
        ])
        spawn = CONTROLLER["command_spawn"]
        cmux = mock.Mock()
        with mock.patch.dict(spawn.__globals__, {
            "read_state": mock.Mock(side_effect=AssertionError("must not read state")),
            "resolve_copilot_token": mock.Mock(side_effect=AssertionError("must not read credentials")),
        }):
            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "--delivery-proof-fixture"):
                spawn(args, self.root, cmux)
        self.assertEqual(cmux.mock_calls, [])

    def test_worker_cannot_request_any_yolo_before_credentials_or_reservation(self):
        spawn = CONTROLLER["command_spawn"]
        for flags in (
            ["--delivery-proof-fixture", self.paths["a"], "--delivery-proof-yolo"],
            ["--yolo"],
        ):
            args = CONTROLLER["parser"]().parse_args([
                "spawn", "--actor-id", str(uuid.uuid4()), "--token", "synthetic",
                "--name", "No escalation", "--task", "test", "--cwd", self.paths["a"], *flags,
            ])
            cmux = mock.Mock()
            forbidden = mock.Mock(side_effect=AssertionError("must refuse before external effects"))
            with mock.patch.dict(spawn.__globals__, {
                "read_state": lambda _: {},
                "authorize": lambda *a: {"role": "worker", "toolPolicy": {"allow": ["read"], "deny": ["web"]}},
                "worker_launch_settings": forbidden, "resolve_copilot_token": forbidden,
                "messaging_configuration": forbidden, "mutate": forbidden,
            }):
                with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "coordinator"):
                    spawn(args, self.root, cmux)
            self.assertEqual(cmux.mock_calls, [])

    def install_synthetic_messaging(self):
        self.root = self.root / "Orchestration"
        self.root.mkdir(mode=0o700)
        routes = Path(tempfile.mkdtemp(prefix="m61-", dir="/tmp")).resolve()
        self.addCleanup(shutil.rmtree, routes)
        extension = self.root / "extension"
        extension.mkdir(mode=0o700)
        for name in ("extension.mjs", "adapter.mjs"):
            shutil.copyfile(REPO / "scripts/delivery-proof" / name, extension / name)
            (extension / name).chmod(0o600)
        config = {"version": 1, "routes": str(routes), "extension": str(extension)}
        (self.root / "bin").mkdir(mode=0o700)
        PROOF["write_new"](self.root / "bin/messaging.json", config)
        self.node.update({
            "id": str(uuid.uuid4()), "runId": str(uuid.uuid4()),
            "messaging": config, "executionMode": "interactive",
        })
        return routes, config

    def test_three_field_config_launches_without_plugin_or_global_guide(self):
        routes, config = self.install_synthetic_messaging()
        self.assertEqual(CONTROLLER["messaging_configuration"](self.root), config)
        args = self.run_mocked_launcher()
        self.assertIn("--experimental", args)
        self.assertNotIn("--plugin-dir", args)
        self.assertEqual(list(routes.iterdir()), [])
        self.assertEqual(self.node["messaging"], config)

    def test_obsolete_plugin_directory_is_ignored_without_path_access(self):
        routes, config = self.install_synthetic_messaging()
        path = self.root / "bin/messaging.json"
        original = PROOF["read_private"](path)
        for candidate in (None, 1, [], {}, "", "relative", "/foreign/plugin", "/bad\0path",
                          "/" + "x" * 1024, "/missing/../plugin"):
            with self.subTest(candidate=candidate):
                path.write_text(json.dumps({**original, "pluginDirectory": candidate}))
                self.assertEqual(CONTROLLER["messaging_configuration"](self.root), config)
                self.node["phase"] = "turn-running"
                self.assertNotIn("--plugin-dir", self.run_mocked_launcher())
                self.assertEqual(list(routes.iterdir()), [])
                self.assertEqual(set(self.node["messaging"]), {"version", "routes", "extension"})
        path.write_text(json.dumps({**original, "unexpected": True}))
        with self.assertRaises(CONTROLLER["OrchestrationError"]):
            CONTROLLER["messaging_configuration"](self.root)

    def test_old_stored_nodes_survive_config_upgrade_and_retire_without_plugin_source(self):
        state, _ = self.lifecycle_state()
        for node in state["nodes"].values():
            node["createdAt"] = node["updatedAt"] = CONTROLLER["now"]()
            node.setdefault("toolPolicy", {"allow": [], "deny": []})
            node["archiving"] = False
        CONTROLLER["Store"]._normalize_candidate_state(state)
        before = copy.deepcopy(state)
        CONTROLLER["validate_state"](state)
        self.assertEqual(state, before)
        CONTROLLER["with_store"](self.root, lambda store: store.write(state))
        self.assertEqual(CONTROLLER["read_state"](self.root), before)
        self.assertEqual(set(self.node["messaging"]), {"version", "routes", "extension"})
        self.assertEqual(CONTROLLER["messaging_configuration"](self.root), self.node["messaging"])
        # Exit/cleanup of existing nodes must not read the new configuration or
        # source, including after uninstall; only the exact old route is needed.
        (self.root / "bin/messaging.json").unlink()
        CONTROLLER["validate_state"](state)
        self.assertEqual(CONTROLLER["read_state"](self.root), before)
        CONTROLLER["retire_messaging"](self.node)
        self.assertFalse(self.route_path().exists())
        self.assertEqual(state, before)

    def test_running_node_exits_normally_after_setup_configuration_is_removed(self):
        routes, _ = self.install_synthetic_messaging()
        self.run_mocked_launcher(on_started=lambda: (self.root / "bin/messaging.json").unlink())
        self.assertEqual(self.node["phase"], "process-disappeared")
        self.assertEqual(self.node["availability"], "unavailable")
        self.assertEqual(list(routes.iterdir()), [])

    def test_missing_runtime_fails_spawn_before_credentials_or_reservation(self):
        _, config = self.install_synthetic_messaging()
        (Path(config["extension"]) / "extension.mjs").unlink()
        spawn = CONTROLLER["command_spawn"]
        args = CONTROLLER["parser"]().parse_args([
            "spawn", "--actor-id", str(uuid.uuid4()), "--token", "synthetic",
            "--name", "Managed", "--task", "test", "--cwd", self.paths["a"],
        ])
        forbidden = mock.Mock(side_effect=AssertionError("must refuse before launch side effects"))
        cmux = mock.Mock()
        with mock.patch.dict(spawn.__globals__, {
            "read_state": lambda _: {}, "authorize": lambda *a: {"role": "coordinator"},
            "authorize_native_spawn": lambda *a: {"role": "coordinator"},
            "git_display_metadata": lambda _: {},
            "worker_launch_settings": forbidden, "resolve_copilot_token": forbidden, "mutate": forbidden,
        }):
            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "Messaging is not installed"):
                spawn(args, self.root, cmux, native_identity={"login": "synthetic"})
        forbidden.assert_not_called()
        self.assertEqual(cmux.mock_calls, [])

    def test_proof_launcher_ignores_installed_plugin_configuration(self):
        self.install_synthetic_messaging()
        self.node.pop("messaging")
        self.node["deliveryProof"] = PROOF["validate_fixture"](self.paths["a"], self.paths["a"])
        (self.root / "bin/messaging.json").write_text("invalid")
        args = self.run_mocked_launcher()
        self.assertNotIn("--plugin-dir", args)

    def test_unmanaged_launcher_does_not_take_plugin_directory_from_environment(self):
        with mock.patch.dict(os.environ, {"CMUX_MAESTRO_PLUGIN_DIR": "/foreign/plugin"}):
            self.assertNotIn("--plugin-dir", self.run_mocked_launcher())

    def test_installed_binding_generation_exclusivity_cleanup_and_readiness(self):
        routes, config = self.install_synthetic_messaging()
        self.assertEqual(CONTROLLER["messaging_configuration"](self.root), config)
        CONTROLLER["bind_messaging"](self.node)
        peer = CONTROLLER["message_peer"](self.node)
        binding = PROOF["read_private"](routes / f"{peer}.json")
        self.assertEqual(binding["nodeId"], self.node["id"])
        self.assertEqual(binding["generation"], 1)
        self.assertEqual(binding["sessionId"], self.node["copilotSessionId"])
        with self.assertRaises(FileExistsError):
            CONTROLLER["bind_messaging"](self.node)
        # A retired generation cannot delete a later generation's route.
        CONTROLLER["retire_messaging"]({**self.node, "generation": 2})
        self.assertTrue((routes / f"{peer}.json").exists())
        CONTROLLER["retire_messaging"](self.node)
        self.assertEqual(list(routes.iterdir()), [])
        (Path(config["extension"]) / "extension.mjs").unlink()
        with self.assertRaises(CONTROLLER["OrchestrationError"]):
            CONTROLLER["messaging_configuration"](self.root)

    def lifecycle_state(self):
        self.install_synthetic_messaging()
        actor = {
            "id": str(uuid.uuid4()), "runId": self.node["runId"],
            "workspaceId": self.node["workspaceId"], "surfaceId": str(uuid.uuid4()),
            "role": "coordinator", "parentId": None, "label": "Coordinator",
            "lastControlAt": "2000-01-01T00:00:00+00:00",
            "copilotSessionId": None, "generation": 0, "phase": "registered",
            "availability": "active", "result": None,
        }
        self.node.update({
            "role": "worker", "parentId": actor["id"], "surfaceId": str(uuid.uuid4()),
            "availability": "busy", "result": None,
            "supervisor": {"pid": 12345, "start": "supervisor-start"},
            "providerProcess": {"pid": 12346, "start": "provider-start"},
        })
        CONTROLLER["bind_messaging"](self.node)
        state = {**CONTROLLER["empty_state"](), "nodes": {
            actor["id"]: actor, self.node["id"]: self.node,
        }}
        return state, actor

    def route_path(self, node=None):
        node = node or self.node
        return Path(node["messaging"]["routes"]) / f'{CONTROLLER["message_peer"](node)}.json'

    def native_identity(self):
        binding = json.loads(self.route_path().read_text())
        return {
            key: binding[key]
            for key in ("nodeId", "workspaceId", "sessionId", "generation", "capability")
        } | {"login": "parent-account", "host": "https://github.com"}

    def test_native_launch_identity_is_exact_and_capability_bound(self):
        state, _ = self.lifecycle_state()
        identity = self.native_identity()
        authorize = CONTROLLER["authorize_native_spawn"]
        self.assertEqual(authorize(state, identity)["id"], self.node["id"])
        for key, value in (
            ("sessionId", str(uuid.uuid4())), ("generation", 2),
            ("workspaceId", str(uuid.uuid4())), ("capability", "f" * 64),
            ("host", "unrelated.example"), ("login", None),
        ):
            with self.subTest(key=key):
                with self.assertRaises(CONTROLLER["OrchestrationError"]):
                    authorize(state, {**identity, key: value})

    def test_native_spawn_inherits_live_account_not_saved_account(self):
        state, _ = self.lifecycle_state()
        spawn = CONTROLLER["command_spawn"]
        identity = self.native_identity()
        args = CONTROLLER["parser"]().parse_args([
            "spawn", "--actor-id", self.node["id"], "--token", "unused",
            "--name", "Child", "--task", "Synthetic", "--cwd", self.paths["a"],
        ])
        saved = {"version": 1, "copilotAccount": "wrong-saved-account", "model": "pinned-model"}
        class Reserved(Exception):
            pass
        def reserve_only(_root, callback):
            callback(state)
            raise Reserved()
        cmux = mock.Mock()
        cmux.validate_surface.return_value = str(uuid.uuid4())
        credentials = mock.Mock(return_value=None)
        with mock.patch.dict(spawn.__globals__, {
            "read_state": lambda _: state,
            "worker_launch_settings": lambda _: dict(saved),
            "provider_launch_context": lambda *_: ("/synthetic/copilot", "/usr/bin:/bin"),
            "resolve_copilot_token": credentials,
            "process_matches": lambda _: True,
            "git_display_metadata": lambda _: CONTROLLER["absent_git_metadata"](),
            "resolve_icon": lambda _: "synthetic-icon",
            "resource_observations": lambda *a: ({}, set()),
            "mutate": reserve_only,
        }):
            with self.assertRaises(Reserved):
                spawn(args, self.root, cmux, native_identity=identity)
        child = next(node for node in state["nodes"].values() if node["parentId"] == self.node["id"])
        self.assertEqual(child["launchSettings"], {**saved, "copilotAccount": "parent-account"})
        self.assertEqual(child["toolPolicy"]["deny"], ["web"])
        self.assertEqual(saved["copilotAccount"], "wrong-saved-account")
        credentials.assert_called_once_with("parent-account")
        cmux.create_surface.assert_not_called()

    def test_managed_shell_spawn_cannot_bypass_current_account_verification(self):
        state, _ = self.lifecycle_state()
        spawn = CONTROLLER["command_spawn"]
        args = CONTROLLER["parser"]().parse_args([
            "spawn", "--actor-id", self.node["id"], "--token", "synthetic",
            "--name", "Child", "--task", "No fallback", "--cwd", self.paths["a"],
        ])
        forbidden = mock.Mock(side_effect=AssertionError("must refuse before launch effects"))
        with mock.patch.dict(spawn.__globals__, {
            "read_state": lambda _: state,
            "authorize": lambda *a: self.node,
            "worker_launch_settings": forbidden, "resolve_copilot_token": forbidden,
            "mutate": forbidden,
        }):
            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "maestro_spawn"):
                spawn(args, self.root, mock.Mock())

    def test_registered_caller_cannot_launch_using_only_saved_account_in_production(self):
        state, actor = self.lifecycle_state()
        spawn = CONTROLLER["command_spawn"]
        args = CONTROLLER["parser"]().parse_args([
            "spawn", "--actor-id", actor["id"], "--token", "synthetic",
            "--name", "Child", "--task", "No fallback", "--cwd", self.paths["a"],
        ])
        forbidden = mock.Mock(side_effect=AssertionError("must refuse before launch effects"))
        with mock.patch.dict(os.environ, {"CMUX_MAESTRO_TESTING": ""}), \
                mock.patch.dict(spawn.__globals__, {
                    "read_state": lambda _: state,
                    "authorize": lambda *a: actor,
                    "worker_launch_settings": forbidden, "resolve_copilot_token": forbidden,
                    "mutate": forbidden,
                }):
            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "parent-account evidence"):
                spawn(args, self.root, mock.Mock())

    def test_root_launch_refuses_managed_caller_and_live_legacy_runtime_before_credentials(self):
        state, actor = self.lifecycle_state()
        command = CONTROLLER["command_launch_coordinator"]
        forbidden = mock.Mock(side_effect=AssertionError("must refuse before launch effects"))
        for surface in (self.node["surfaceId"], actor["surfaceId"]):
            args = CONTROLLER["parser"]().parse_args([
                "launch-coordinator", "--workspace", actor["workspaceId"], "--surface", surface,
                "--cwd", self.paths["a"], "--task", "No takeover", "--account", "synthetic",
            ])
            with mock.patch.dict(command.__globals__, {
                "require_current_surface": mock.Mock(),
                "read_state": lambda _: state,
                "provider_launch_context": lambda *_: ("/synthetic/copilot", "/usr/bin:/bin"),
                "worker_processes_exited": lambda _: False,
                "worker_launch_settings": forbidden, "resolve_copilot_token": forbidden,
                "mutate": forbidden,
            }):
                with self.assertRaises(CONTROLLER["OrchestrationError"]):
                    command(args, self.root, mock.Mock())
        forbidden.assert_not_called()

    def test_legacy_compatibility_protects_supervisor_writers_without_ending_providers(self):
        state, _ = self.lifecycle_state()
        before = copy.deepcopy(state)
        check = CONTROLLER["legacy_supervisor_blocks"]
        with mock.patch.dict(check.__globals__, {
            "process_start": lambda pid: "provider-start" if pid == 12346 else None,
        }), mock.patch("os.kill", side_effect=ProcessLookupError):
            self.assertFalse(check(state, self.node))
        self.assertEqual(state, before)
        with mock.patch.dict(check.__globals__, {
            "process_start": lambda pid: "supervisor-start" if pid == 12345 else None,
        }):
            self.assertTrue(check(state, self.node))
        with mock.patch.dict(check.__globals__, {"process_start": lambda _: None}), \
                mock.patch("os.kill", side_effect=PermissionError):
            self.assertTrue(check(state, self.node))
        state["launches"][self.node["id"]] = {}
        self.assertTrue(check(state, self.node))

    def test_resource_reconciliation_preserves_active_leases_and_changed_owners(self):
        state, _ = self.lifecycle_state()
        snapshot = copy.deepcopy(state)
        identifier = self.node["id"]
        observations = {identifier: {"surface": False, "process": False, "exited": True}}
        reconcile = CONTROLLER["reconcile_resources"]
        state["launches"][identifier] = {}
        reconcile(state, snapshot, observations, set())
        self.assertEqual(state["nodes"][identifier]["phase"], "turn-running")
        state["launches"].clear()
        state["nodes"][identifier]["surfaceId"] = str(uuid.uuid4())
        reconcile(state, snapshot, observations, set())
        self.assertEqual(state["nodes"][identifier]["phase"], "turn-running")
        state["nodes"][identifier] = copy.deepcopy(snapshot["nodes"][identifier])
        observations[identifier]["exited"] = False
        reconcile(state, snapshot, observations, set())
        self.assertEqual(state["nodes"][identifier]["phase"], "turn-running")
        observations[identifier]["exited"] = True
        reconcile(state, snapshot, observations, set())
        self.assertEqual(state["nodes"][identifier]["phase"], "resource-retired")
        self.assertEqual(state["nodes"][identifier]["providerProcess"], self.node["providerProcess"])

    def test_managed_coordinator_has_its_own_run_and_does_not_adopt_caller(self):
        self.install_synthetic_messaging()
        command = CONTROLLER["command_launch_coordinator"]
        workspace, surface, pane = (str(uuid.uuid4()) for _ in range(3))
        state = CONTROLLER["empty_state"]()
        args = CONTROLLER["parser"]().parse_args([
            "launch-coordinator", "--workspace", workspace, "--surface", surface,
            "--name", "Managed root", "--cwd", self.paths["a"], "--task", "Synthetic",
            "--account", "chosen-root-account", "--deny-tool", "web",
        ])
        cmux = mock.Mock()
        cmux.validate_surface.return_value = pane
        launcher = mock.Mock(return_value={"supervisorStarted": True})
        with mock.patch.dict(command.__globals__, {
            "require_current_surface": mock.Mock(),
            "read_state": lambda _: state,
            "provider_launch_context": lambda *_: ("/synthetic/copilot", "/usr/bin:/bin"),
            "worker_launch_settings": lambda _: {"version": 1, "copilotAccount": "saved-other", "model": "pinned-model"},
            "resolve_copilot_token": mock.Mock(return_value=None),
            "mutate": lambda _root, operation: operation(state),
            "launch_reserved_session": launcher,
        }):
            result = command(args, self.root, cmux)
        node = state["nodes"][result["coordinatorId"]]
        CONTROLLER["validate_state"](state)
        self.assertEqual(node["role"], "coordinator")
        self.assertEqual(node["executionMode"], "interactive")
        self.assertIsNone(node["parentId"])
        self.assertIsNone(node["surfaceId"])
        self.assertEqual(node["generation"], 1)
        self.assertIsNotNone(node["copilotSessionId"])
        self.assertEqual(node["launchSettings"]["copilotAccount"], "chosen-root-account")
        self.assertEqual(node["toolPolicy"]["deny"], ["web"])
        self.assertFalse(any(item.get("surfaceId") == surface for item in state["nodes"].values()))
        launcher.assert_called_once()

    def test_failed_root_preserves_private_owner_receipt_without_claiming_success(self):
        self.install_synthetic_messaging()
        command = CONTROLLER["command_launch_coordinator"]
        state = CONTROLLER["empty_state"]()
        workspace, surface = str(uuid.uuid4()), str(uuid.uuid4())
        argv = [
            "launch-coordinator", "--workspace", workspace, "--surface", surface,
            "--cwd", self.paths["a"], "--task", "Synthetic", "--account", "root-account",
        ]
        args = CONTROLLER["parser"]().parse_args(argv)
        cmux = mock.Mock()
        cmux.validate_surface.return_value = str(uuid.uuid4())
        with mock.patch.dict(command.__globals__, {
            "require_current_surface": mock.Mock(),
            "read_state": lambda _: state,
            "worker_launch_settings": lambda _: {"version": 1, "model": "pinned-model"},
            "resolve_copilot_token": mock.Mock(return_value=None),
            "mutate": lambda _root, operation: operation(state),
            "provider_launch_context": lambda *_: ("/synthetic/copilot", "/usr/bin:/bin"),
            "launch_reserved_session": mock.Mock(side_effect=CONTROLLER["OrchestrationError"]("Synthetic startup failure")),
        }):
            with self.assertRaises(CONTROLLER["CoordinatorLaunchError"]) as caught:
                command(args, self.root, cmux)
        failure = caught.exception
        receipt = failure.receipt
        node = state["nodes"][receipt["coordinatorId"]]
        self.assertEqual(CONTROLLER["token_hash"](receipt["controlToken"]), node["tokenHash"])
        self.assertNotIn(receipt["controlToken"], str(failure))
        output, error = io.StringIO(), io.StringIO()
        main = CONTROLLER["main"]
        with mock.patch.dict(main.__globals__, {
            "default_root": lambda: self.root, "Cmux": mock.Mock,
            "command_launch_coordinator": mock.Mock(side_effect=failure),
        }), mock.patch("sys.stdout", output), mock.patch("sys.stderr", error):
            self.assertEqual(main(argv), 2)
        payload = json.loads(output.getvalue())
        self.assertIs(payload["ok"], False)
        self.assertEqual(payload["controlToken"], receipt["controlToken"])
        self.assertEqual(error.getvalue(), "")

    def assert_tools_available(self):
        # Real adapter/tool handlers, but only synthetic sessions and local routes.
        peer = {**self.node, "id": str(uuid.uuid4()), "copilotSessionId": str(uuid.uuid4())}
        CONTROLLER["bind_messaging"](peer)
        script = """
            import assert from 'node:assert/strict';
            const { start } = await import(process.argv[1]);
            const nodes = JSON.parse(process.argv[2]);
            const adapters = [], tools = [];
            try {
                for (const node of nodes) {
                    adapters.push(await start({
                        root: node.root, peer: node.peer, managed: true, expected: node,
                        joinSession: async options => {
                            tools.push(options.tools);
                            return { sessionId: node.sessionId, send: async () => {} };
                        },
                    }));
                }
                const invocation = { sessionId: nodes[0].sessionId };
                const peers = JSON.parse(await tools[0][0].handler({}, invocation));
                assert.equal(peers.length, 1);
                assert.equal(peers[0].sessionId, nodes[1].sessionId);
                const { workspaceId, sessionId, generation } = peers[0];
                const sent = await tools[0][1].handler({
                    destination: { workspaceId, sessionId, generation }, body: 'Synthetic message',
                }, invocation);
                assert.equal(typeof sent, 'string');
                assert.match(sent, /Local write attempted/);
            } finally {
                for (const adapter of adapters) await adapter.close();
            }
        """
        nodes = [{
            "root": node["messaging"]["routes"], "peer": CONTROLLER["message_peer"](node),
            "nodeId": node["id"], "workspaceId": node["workspaceId"],
            "sessionId": node["copilotSessionId"], "generation": node["generation"],
        } for node in (self.node, peer)]
        result = subprocess.run([
            "node", "--input-type=module", "-e", script,
            (REPO / "scripts/delivery-proof/adapter.mjs").as_uri(), json.dumps(nodes),
        ], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def status_interleaving(self, state, actor, snapshot, *, process_start, kill_error=ProcessLookupError):
        status = CONTROLLER["command_status"]
        args = CONTROLLER["parser"]().parse_args([
            "status", "--actor-id", actor["id"], "--token", "synthetic",
        ])
        cmux = mock.Mock()
        cmux.surface_exists.return_value = True
        with mock.patch.dict(status.__globals__, {
            "read_state": lambda _: snapshot,
            "authorize": lambda state, *a: state["nodes"][actor["id"]],
            "mutate": lambda root, callback: callback(state),
            "collect_git_evidence": lambda *a: {},
            "apply_git_evidence": lambda *a: None,
            "process_start": process_start,
        }), mock.patch("os.kill", side_effect=kill_error), \
                mock.patch.dict(status.__globals__, {
                    "retire_messaging": mock.Mock(wraps=CONTROLLER["retire_messaging"]),
                }):
            retire = status.__globals__["retire_messaging"]
            result = status(args, self.root, cmux)
        return result, retire

    def check_status_spawn_interleaving(self, interleaving):
        state, actor = self.lifecycle_state()
        snapshot = copy.deepcopy(state)
        if interleaving == "new-worker":
            del snapshot["nodes"][self.node["id"]]
        else:
            old = snapshot["nodes"][self.node["id"]]
            old.update(phase="launching", supervisor=None, providerProcess=None)
            snapshot["launches"][self.node["id"]] = {
                "runId": actor["runId"], "workspaceId": actor["workspaceId"],
            }
        before = copy.deepcopy(self.node)
        binding = self.route_path().read_bytes()
        result, retire = self.status_interleaving(
            state, actor, snapshot,
            process_start=lambda pid: {12345: "supervisor-start", 12346: "provider-start"}[pid],
        )
        retire.assert_not_called()
        self.assertEqual(self.node, before)
        self.assertEqual(self.route_path().read_bytes(), binding)
        worker = next(item for item in result["workers"] if item["workerId"] == self.node["id"])
        self.assertEqual(worker["messaging"], "configured")
        self.assert_tools_available()

    def test_status_new_worker_preserves_live_routes_and_tools(self):
        self.check_status_spawn_interleaving("new-worker")

    def test_status_startup_completed_preserves_live_routes_and_tools(self):
        self.check_status_spawn_interleaving("startup-completed")

    def test_status_changed_identity_and_startup_preserve_routes(self):
        state, actor = self.lifecycle_state()
        for field, old in (
            ("generation", 0), ("copilotSessionId", str(uuid.uuid4())),
            ("supervisor", {"pid": 12344, "start": "old-start"}),
            ("providerProcess", {"pid": 12347, "start": "old-start"}),
            ("surfaceId", str(uuid.uuid4())), ("phase", "launching"), ("tokenHash", "old-token"),
        ):
            with self.subTest(field=field):
                snapshot = copy.deepcopy(state)
                snapshot["nodes"][self.node["id"]][field] = old
                result, retire = self.status_interleaving(state, actor, snapshot, process_start=lambda _: None)
                retire.assert_not_called()
                self.assertEqual(self.node["phase"], "turn-running")
                self.assertTrue(self.route_path().exists())
                worker = next(item for item in result["workers"] if item["workerId"] == self.node["id"])
                for key in ("surfacePresent", "supervisorRunning", "providerRunning"):
                    self.assertIsNone(worker[key], (field, key))
        state["launches"][self.node["id"]] = {
            "runId": actor["runId"], "workspaceId": actor["workspaceId"],
        }
        _, retire = self.status_interleaving(
            state, actor, copy.deepcopy(state), process_start=lambda _: None,
        )
        retire.assert_not_called()
        self.assertEqual(self.node["phase"], "turn-running")

    def test_status_rechecks_exit_before_identity_fenced_refresh(self):
        state, actor = self.lifecycle_state()
        # The first observation misses both processes; the boundary sees the provider live.
        starts = mock.Mock(side_effect=[None, None, None, "provider-start", None, "provider-start"])
        _, retire = self.status_interleaving(state, actor, copy.deepcopy(state), process_start=starts)
        retire.assert_not_called()
        self.assertEqual(self.node["phase"], "turn-running")
        self.assertTrue(self.route_path().exists())

    def test_status_latest_unknown_process_probe_preserves_route(self):
        state, actor = self.lifecycle_state()
        result, retire = self.status_interleaving(
            state, actor, copy.deepcopy(state), process_start=lambda _: None,
            kill_error=[ProcessLookupError, ProcessLookupError, None, None],
        )
        retire.assert_not_called()
        self.assertEqual(self.node["phase"], "turn-running")
        self.assertTrue(self.route_path().exists())
        worker = next(item for item in result["workers"] if item["workerId"] == self.node["id"])
        self.assertIsNone(worker["supervisorRunning"])
        self.assertIsNone(worker["providerRunning"])

    def test_status_unknown_exit_preserves_route_and_phase(self):
        state, actor = self.lifecycle_state()
        for uncertainty in ("probe-failed", "probe-denied", "no-provider", "no-supervisor"):
            with self.subTest(uncertainty=uncertainty):
                current = copy.deepcopy(state)
                if uncertainty == "no-provider":
                    current["nodes"][self.node["id"]]["providerProcess"] = None
                elif uncertainty == "no-supervisor":
                    current["nodes"][self.node["id"]]["supervisor"] = None
                before = copy.deepcopy(current["nodes"][self.node["id"]])
                _, retire = self.status_interleaving(
                    current, actor, copy.deepcopy(current), process_start=lambda _: None,
                    kill_error=PermissionError if uncertainty == "probe-denied" else None,
                )
                retire.assert_not_called()
                self.assertEqual(current["nodes"][self.node["id"]], before)
                self.assertTrue(self.route_path().exists())

    def test_status_confirmed_exit_retires_exact_route_and_socket(self):
        state, actor = self.lifecycle_state()
        endpoint = self.route_path().with_suffix(".sock")
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(str(endpoint))
        _, retire = self.status_interleaving(
            state, actor, copy.deepcopy(state), process_start=lambda _: None,
        )
        retire.assert_called_once_with(self.node)
        self.assertFalse(self.route_path().exists())
        self.assertFalse(endpoint.exists())
        self.assertEqual(self.node["phase"], "process-disappeared")

    def recover_interleaving(self, state, actor, snapshot, *, process_start,
                             kill_error=ProcessLookupError, surfaces=None):
        recover = CONTROLLER["command_recover"]
        args = CONTROLLER["parser"]().parse_args([
            "recover", "--workspace", actor["workspaceId"], "--surface", actor["surfaceId"],
            "--name", "Recovered",
        ])
        cmux = mock.Mock()
        cmux.surface_exists.return_value = False
        cmux.surface_exists.side_effect = surfaces
        replacement = {**actor, "id": str(uuid.uuid4()), "runId": str(uuid.uuid4())}
        with mock.patch.dict(recover.__globals__, {
            "read_state": lambda _: snapshot,
            "require_current_surface": lambda *a: None,
            "mutate": lambda root, callback: callback(state),
            "new_root": lambda *a: (replacement, "synthetic"),
            "process_start": process_start,
        }), mock.patch("os.kill", side_effect=kill_error):
            return recover(args, self.root, cmux)

    def test_recovery_retires_only_exact_stopped_run_routes(self):
        state, actor = self.lifecycle_state()
        other = {**self.node, "id": str(uuid.uuid4()), "runId": str(uuid.uuid4()),
                 "copilotSessionId": str(uuid.uuid4())}
        state["nodes"][other["id"]] = other
        CONTROLLER["bind_messaging"](other)
        other_binding = self.route_path(other).read_bytes()
        endpoint = self.route_path().with_suffix(".sock")
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(str(endpoint))
        # Supervisor is gone, but its provider must keep the route until a later recovery.
        before = copy.deepcopy(state)
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "live worker ownership"):
            self.recover_interleaving(
                state, actor, copy.deepcopy(state),
                process_start=lambda pid: "provider-start" if pid == 12346 else None,
            )
        self.assertEqual(state, before)
        self.assertTrue(self.route_path().exists())
        self.assertTrue(endpoint.exists())
        result = self.recover_interleaving(
            state, actor, copy.deepcopy(state), process_start=lambda _: None,
        )
        self.assertEqual(result["recoveredRunId"], actor["runId"])
        self.assertNotIn(self.node["id"], state["nodes"])
        self.assertNotIn(actor["id"], state["nodes"])
        self.assertIn(result["coordinatorId"], state["nodes"])
        self.assertEqual(state["archives"][0]["runId"], actor["runId"])
        self.assertFalse(self.route_path().exists())
        self.assertFalse(endpoint.exists())
        self.assertEqual(state["nodes"][other["id"]], other)
        self.assertEqual(self.route_path(other).read_bytes(), other_binding)

    def test_recovery_revalidates_launch_nodes_and_processes_before_cleanup(self):
        state, actor = self.lifecycle_state()
        for change in ("launch", "new-worker", "generation", "provider-live"):
            with self.subTest(change=change):
                current = copy.deepcopy(state)
                snapshot = copy.deepcopy(state)
                if change == "launch":
                    current["launches"][self.node["id"]] = {"runId": actor["runId"]}
                elif change == "new-worker":
                    new = {**self.node, "id": str(uuid.uuid4())}
                    current["nodes"][new["id"]] = new
                elif change == "generation":
                    current["nodes"][self.node["id"]]["generation"] += 1
                starts = mock.Mock(side_effect=[None, None, None, "provider-start"]) \
                    if change == "provider-live" else lambda _: None
                before = copy.deepcopy(current)
                binding = self.route_path().read_bytes()
                with self.assertRaises(CONTROLLER["OrchestrationError"]):
                    self.recover_interleaving(current, actor, snapshot, process_start=starts)
                self.assertEqual(current, before)
                self.assertEqual(self.route_path().read_bytes(), binding)

    def test_recovery_uncertain_process_or_live_surface_keeps_records_and_routes(self):
        state, actor = self.lifecycle_state()
        for uncertainty in ("probe-failed", "probe-denied", "no-provider", "no-supervisor", "surface"):
            with self.subTest(uncertainty=uncertainty):
                current = copy.deepcopy(state)
                if uncertainty == "no-provider":
                    current["nodes"][self.node["id"]]["providerProcess"] = None
                elif uncertainty == "no-supervisor":
                    current["nodes"][self.node["id"]]["supervisor"] = None
                before = copy.deepcopy(current)
                with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "uncertain"):
                    self.recover_interleaving(
                        current, actor, copy.deepcopy(current), process_start=lambda _: None,
                        kill_error=PermissionError if uncertainty == "probe-denied" else
                            ProcessLookupError if uncertainty == "surface" else None,
                        surfaces=[False, True] if uncertainty == "surface" else None,
                    )
                self.assertEqual(current, before)
                self.assertTrue(self.route_path().exists())

    def test_recovery_mismatched_binding_refuses_record_deletion(self):
        state, actor = self.lifecycle_state()
        route = self.route_path()
        binding = PROOF["read_private"](route)
        binding["nodeId"] = str(uuid.uuid4())
        route.write_text(json.dumps(binding))
        before = copy.deepcopy(state)
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "identity changed"):
            self.recover_interleaving(
                state, actor, copy.deepcopy(state), process_start=lambda _: None,
            )
        self.assertEqual(state, before)
        self.assertEqual(PROOF["read_private"](route), binding)

    def test_installed_spawn_automatically_participates_and_requires_pins(self):
        _, config = self.install_synthetic_messaging()
        actor = {
            "id": str(uuid.uuid4()), "runId": str(uuid.uuid4()),
            "workspaceId": self.node["workspaceId"], "surfaceId": str(uuid.uuid4()),
            "role": "coordinator", "parentId": None,
        }
        args = CONTROLLER["parser"]().parse_args([
            "spawn", "--actor-id", actor["id"], "--token", "synthetic",
            "--name", "Installed participant", "--task", "bounded task", "--cwd", str(REPO),
            "--deny-tool", "web",
        ])
        spawn = CONTROLLER["command_spawn"]
        state = {**CONTROLLER["empty_state"](), "nodes": {actor["id"]: actor}}
        credentials = mock.Mock()
        class Reserved(Exception):
            pass

        def reserve_only(_root, callback):
            callback(state)
            raise Reserved()

        with mock.patch.dict(spawn.__globals__, {
            "read_state": lambda _: state, "authorize": lambda *a: actor,
            "authorize_native_spawn": lambda *a: actor,
            "provider_launch_context": lambda *_: ("/synthetic/copilot", "/usr/bin:/bin"),
            "worker_launch_settings": lambda _: {},
            "resolve_copilot_token": credentials,
            "git_display_metadata": lambda _: CONTROLLER["absent_git_metadata"](),
            "resolve_icon": lambda _: "synthetic-icon",
            "resource_observations": lambda *a: ({}, set()),
            "mutate": reserve_only,
        }):
            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "Pinned"):
                spawn(args, self.root, mock.Mock(), native_identity={"login": "synthetic"})
            credentials.assert_not_called()
            with mock.patch.dict(spawn.__globals__, {
                "worker_launch_settings": lambda _: {
                    "version": 1, "copilotAccount": "synthetic", "model": "synthetic",
                },
            }):
                with self.assertRaises(Reserved):
                    spawn(args, self.root, mock.Mock(), native_identity={"login": "synthetic"})
        worker = next(node for node in state["nodes"].values() if node["role"] == "worker")
        self.assertEqual(worker["messaging"], config)
        self.assertEqual(set(worker["messaging"]), {"version", "routes", "extension"})
        self.assertEqual(worker["workingDirectory"], str(REPO))
        self.assertEqual(worker["permissionMode"], "default")
        self.assertEqual(worker["toolPolicy"], {"allow": [], "deny": ["web"]})
        self.assertNotIn("deliveryProof", worker)

    def test_installed_launcher_wires_ordinary_cwd_and_cleans_only_after_provider_exit(self):
        routes, _ = self.install_synthetic_messaging()
        # No fixture validation/binding should run in installed mode.
        args = self.run_mocked_launcher()
        self.assertIn("--experimental", args)
        self.assertNotIn("--plugin-dir", args)
        self.assertNotIn("--allow-all", args)
        self.assertEqual(list(routes.iterdir()), [])
        self.node["permissionMode"] = "yolo"
        self.node["phase"] = "turn-running"
        args = self.run_mocked_launcher()
        self.assertEqual(args.count("--allow-all"), 1)
        self.assertEqual(list(routes.iterdir()), [])

    def test_managed_environment_is_exact_and_legacy_does_not_inherit_route(self):
        routes, _ = self.install_synthetic_messaging()
        environment = CONTROLLER["worker_environment"]
        with mock.patch.dict(environment.__globals__, {"resolve_copilot_token": lambda _: None}), \
                mock.patch.dict(os.environ, {
                    "CMUX_MAESTRO_MESSAGE_ROOT": "stale-parent", "CMUX_MAESTRO_MESSAGE_PEER": "stale-peer",
                    "CMUX_WORKSPACE_ID": str(uuid.uuid4()),
                }):
            result = environment(self.node["id"], "synthetic", self.node)
            self.assertEqual(result["CMUX_MAESTRO_MESSAGE_ROOT"], str(routes))
            self.assertEqual(result["CMUX_MAESTRO_MESSAGE_PEER"], CONTROLLER["message_peer"](self.node))
            self.assertEqual(result["CMUX_WORKSPACE_ID"], self.node["workspaceId"])
            legacy = dict(self.node)
            legacy.pop("messaging")
            result = environment(legacy["id"], "synthetic", legacy)
            self.assertNotIn("CMUX_MAESTRO_MESSAGE_ROOT", result)
            self.assertNotIn("CMUX_MAESTRO_MESSAGE_PEER", result)

    def test_failed_provider_start_retires_binding_without_retry(self):
        routes, _ = self.install_synthetic_messaging()
        run = CONTROLLER["run_interactive_session"]
        popen = mock.Mock(side_effect=OSError("synthetic start failure"))
        with mock.patch.dict(run.__globals__, {
            "trusted_executable": lambda *a: "/synthetic/copilot",
            "worker_environment": lambda *a: {},
        }), mock.patch("os.isatty", return_value=True), mock.patch("signal.signal"), \
                mock.patch("subprocess.Popen", popen):
            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "launch failed"):
                run(self.root, self.node["id"], "synthetic", self.node)
        self.assertEqual(list(routes.iterdir()), [])
        popen.assert_called_once()

    def test_unsafe_messaging_config_and_binding_permissions_fail_closed(self):
        routes, _ = self.install_synthetic_messaging()
        config = self.root / "bin/messaging.json"
        config.chmod(0o644)
        with self.assertRaises(CONTROLLER["OrchestrationError"]):
            CONTROLLER["messaging_configuration"](self.root)
        config.chmod(0o600)
        routes.chmod(0o755)
        with self.assertRaises(CONTROLLER["OrchestrationError"]):
            CONTROLLER["bind_messaging"](self.node)
        routes.chmod(0o700)

    def test_state_accepts_old_proof_and_boolean_yolo_only(self):
        timestamp = CONTROLLER["now"]()
        parent_id, worker_id, run_id = (str(uuid.uuid4()) for _ in range(3))
        parent = {
            "id": parent_id, "runId": run_id, "workspaceId": self.node["workspaceId"],
            "parentId": None, "role": "coordinator", "generation": 0,
            "createdAt": timestamp, "updatedAt": timestamp, "phase": "registered",
            "availability": "active", "toolPolicy": {"allow": [], "deny": []},
        }
        worker = {
            **self.node, "id": worker_id, "runId": run_id, "parentId": parent_id,
            "role": "worker", "executionMode": "interactive", "availability": "busy",
            "createdAt": timestamp, "updatedAt": timestamp,
            "deliveryProof": PROOF["validate_fixture"](self.paths["a"], self.paths["a"]),
        }
        state = {**CONTROLLER["empty_state"](), "nodes": {parent_id: parent, worker_id: worker}}
        CONTROLLER["validate_state"](state)
        self.assertNotIn("yolo", worker["deliveryProof"])
        for value in (False, True):
            worker["deliveryProof"]["yolo"] = value
            CONTROLLER["validate_state"](state)
        for value in (None, 0, 1, "true", []):
            with self.subTest(value=value):
                worker["deliveryProof"]["yolo"] = value
                with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "delivery proof"):
                    CONTROLLER["validate_state"](state)


class NativeCloseTests(unittest.TestCase):
    """Real private state/routes/markers; synthetic host and explicitly owned process fixtures."""

    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="m90-", dir="/tmp")).resolve()
        self.addCleanup(shutil.rmtree, self.home)
        self.root = self.home / "Orchestration"
        self.routes = self.home / "routes"
        self.routes.mkdir(mode=0o700)
        self.actor, self.token = CONTROLLER["new_root"](
            str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4()), "Coordinator",
        )
        self.actor.update(
            executionMode="interactive", runtimeProtocolVersion=2, launchMethod="direct",
            launchAccepted=True, phase="turn-running", availability="busy", generation=1,
            launchSettings={"version": 1, "model": "synthetic-model", "copilotAccount": "synthetic"},
            copilotSessionId=str(uuid.uuid4()), providerProcess={
                "pid": 12345, "start": "Thu Jan  1 00:00:00 2026",
            },
            messaging={"version": 1, "routes": str(self.routes), "extension": str(self.home / "extension")},
        )
        self.child = {
            **copy.deepcopy(self.actor), "id": str(uuid.uuid4()), "role": "worker",
            "parentId": self.actor["id"], "copilotSessionId": str(uuid.uuid4()),
            "surfaceId": str(uuid.uuid4()), "tokenHash": CONTROLLER["token_hash"]("child-private-token"),
            "providerProcess": {"pid": 12346, "start": "Thu Jan  1 00:00:00 2026"},
        }
        self.sibling = {**copy.deepcopy(self.child), "id": str(uuid.uuid4()),
                        "surfaceId": str(uuid.uuid4()), "copilotSessionId": str(uuid.uuid4())}
        self.grandchild = {**copy.deepcopy(self.sibling), "id": str(uuid.uuid4()),
                           "parentId": self.child["id"], "surfaceId": str(uuid.uuid4()),
                           "copilotSessionId": str(uuid.uuid4())}
        self.state = {**CONTROLLER["empty_state"](), "nodes": {
            node["id"]: node for node in (self.actor, self.child, self.sibling, self.grandchild)
        }}
        self.persist()
        CONTROLLER["bind_messaging"](self.actor)
        binding = json.loads((self.routes / f'{CONTROLLER["message_peer"](self.actor)}.json').read_text())
        self.identity = {key: binding[key] for key in (
            "nodeId", "workspaceId", "sessionId", "generation", "capability",
        )}
        self.target = {
            "workerId": self.child["id"], "workspaceId": self.child["workspaceId"],
            "surfaceId": self.child["surfaceId"], "sessionId": self.child["copilotSessionId"], "generation": 1,
        }
        self.environment = {
            "CMUX_MAESTRO_WORKER_ID": self.actor["id"], "SESSION_ID": self.actor["copilotSessionId"],
            "CMUX_MAESTRO_CONTROL_TOKEN": self.token, "CMUX_MAESTRO_RUN_ID": self.actor["runId"],
            "CMUX_MAESTRO_GENERATION": "1", "CMUX_WORKSPACE_ID": self.actor["workspaceId"],
            "CMUX_SURFACE_ID": self.actor["surfaceId"],
        }
        for node in (self.actor, self.child):
            source = self.source(node)
            source.mkdir(parents=True, mode=0o700)
            (source / f'inuse.{node["providerProcess"]["pid"]}.lock').touch(mode=0o600)
        self.cmux = mock.Mock()
        self.cmux.workspace_surfaces.return_value = {node["surfaceId"] for node in self.state["nodes"].values()}
        self.cmux.run.return_value = {
            "workspace_id": self.child["workspaceId"], "surface_id": self.child["surfaceId"],
        }
        self.starts = {12345: self.actor["providerProcess"]["start"], 12346: self.child["providerProcess"]["start"]}
        self.parents = {12345: 1, 12346: 1}
        self.process_uids = {}
        self.process_states = {}

    def source(self, node):
        return self.home / ".copilot/session-state" / node["copilotSessionId"]

    def persist(self):
        CONTROLLER["with_store"](self.root, lambda store: store.write(self.state))

    @contextmanager
    def owned_source_wrapper(self):
        source = self.source(self.child)
        (source / "inuse.12346.lock").unlink()
        script = """
import signal,subprocess,sys
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
owner = subprocess.Popen([
    sys.executable, "-B", "-c",
    "import os,sys; from pathlib import Path; "
    "(Path(sys.argv[1])/f'inuse.{os.getpid()}.lock').touch(mode=0o644); "
    "print('ready',flush=True); sys.stdin.readline()",
    sys.argv[1],
], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
try:
    assert owner.stdout.readline().strip() == "ready"
    print(owner.pid, flush=True)
    for command in sys.stdin:
        if command.strip() == "exit-owner":
            owner.stdin.write("\\n")
            owner.stdin.flush()
finally:
    owner.stdin.close()
    owner.wait(timeout=5)
    owner.stdout.close()
"""
        wrapper = subprocess.Popen(
            [sys.executable, "-B", "-c", script, str(source)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            self.assertTrue(select.select([wrapper.stdout], [], [], 5)[0], "owned wrapper did not become ready")
            owner_pid = int(wrapper.stdout.readline().strip())
            self.assertNotEqual(wrapper.pid, owner_pid)
            self.child["providerProcess"] = {
                "pid": wrapper.pid, "start": CONTROLLER["process_start"](wrapper.pid),
            }
            self.assertIsNotNone(self.child["providerProcess"]["start"])
            self.persist()
            yield wrapper, owner_pid
        finally:
            wrapper.stdin.close()
            try:
                wrapper.wait(timeout=5)
            except subprocess.TimeoutExpired:
                wrapper.terminate()
                wrapper.wait(timeout=5)
            wrapper.stdout.close()
            wrapper.stderr.close()

    def separate_source_owner(self):
        source = self.source(self.child)
        (source / "inuse.12346.lock").unlink()
        marker = source / "inuse.12347.lock"
        marker.touch(mode=0o644)
        self.starts[12347] = self.starts[12346]
        self.parents[12347] = 12346
        return marker

    def invoke(self, request=None, *, anchor=None, kill_error=ProcessLookupError, real_pids=()):
        close = CONTROLLER["command_native_close"]
        process_start = CONTROLLER["process_start"]
        run = subprocess.run
        def process_probe(arguments, **kwargs):
            if arguments[:2] == ["/bin/ps", "-o"] and int(arguments[-1]) not in real_pids:
                pid = int(arguments[-1])
                start = self.starts.get(pid)
                if arguments[2] == "state=,lstart=":
                    output = f"{self.process_states.get(pid, 'S')} {start}\n" if start else ""
                elif arguments[2] == "ppid=,uid=,lstart=":
                    output = (f"{self.parents.get(pid, 1)} {self.process_uids.get(pid, os.getuid())} {start}\n"
                              if start else "")
                else:
                    raise AssertionError("Unexpected process probe")
                return subprocess.CompletedProcess(arguments, 0, output, "")
            return run(arguments, **kwargs)
        raw = request if isinstance(request, bytes) else json.dumps(
            request if request is not None else {"identity": self.identity, "target": self.target}
        ).encode()
        with mock.patch.dict(os.environ, self.environment), \
                mock.patch("sys.stdin", mock.Mock(buffer=io.BytesIO(raw))), \
                mock.patch.object(Path, "home", return_value=self.home), \
                mock.patch.dict(close.__globals__, {
                    "process_start": lambda pid: process_start(pid) if pid in real_pids else self.starts.get(pid),
                    "direct_process_identity": anchor or (lambda _: dict(self.actor["providerProcess"])),
                    "retire_messaging": mock.Mock(side_effect=AssertionError("close must preserve routes")),
                    "reconcile_resources": mock.Mock(side_effect=AssertionError("close must not reconcile")),
                    "time": mock.Mock(wraps=time, sleep=mock.Mock(side_effect=AssertionError("close must not wait"))),
                }), \
                mock.patch("os.kill", side_effect=kill_error), \
                mock.patch("subprocess.run", side_effect=process_probe):
            return close(self.root, self.cmux)

    def test_close_accepts_one_live_direct_child_and_preserves_every_record_and_route(self):
        before = {file: file.read_bytes() for directory in (self.root, self.routes)
                  for file in directory.rglob("*") if file.is_file()}
        result = self.invoke()
        self.assertEqual(result, {**self.target, "closeAccepted": True, "removal": "unconfirmed"})
        self.assertEqual(self.cmux.mock_calls, [
            mock.call.workspace_surfaces(self.actor["workspaceId"]),
            mock.call.run("rpc", "surface.close", json.dumps({
                "workspace_id": self.target["workspaceId"], "surface_id": self.target["surfaceId"],
            })),
        ])
        self.assertEqual({file: file.read_bytes() for file in before}, before)
        self.assertEqual(CONTROLLER["read_state"](self.root), self.state)
        self.assertNotIn(self.token, json.dumps(result))
        self.assertNotIn(self.identity["capability"], json.dumps(result))

    def test_close_also_accepts_an_unchanged_managed_supervised_interactive_child(self):
        self.child.pop("launchMethod")
        self.child.pop("launchAccepted")
        self.child["supervisor"] = {"pid": 12347, "start": "Thu Jan  1 00:00:00 2026"}
        self.persist()
        self.assertTrue(self.invoke()["closeAccepted"])
        self.cmux.run.assert_called_once()

    def test_close_accepts_real_wrapper_with_separate_direct_source_owner(self):
        with self.owned_source_wrapper() as (wrapper, owner_pid):
            source = self.source(self.child)
            self.assertEqual([item.name for item in source.iterdir()], [f"inuse.{owner_pid}.lock"])
            self.assertFalse((source / f"inuse.{wrapper.pid}.lock").exists())
            before = (self.root / "control/state.json").read_bytes()
            self.assertEqual(self.invoke(real_pids={wrapper.pid, owner_pid}), {
                **self.target, "closeAccepted": True, "removal": "unconfirmed",
            })
            self.cmux.run.assert_called_once()
            self.assertEqual((self.root / "control/state.json").read_bytes(), before)

    def test_close_accepts_real_same_pid_launch_and_source_owner(self):
        with self.owned_source_wrapper() as (wrapper, owner_pid):
            self.child["providerProcess"] = {
                "pid": owner_pid, "start": CONTROLLER["process_start"](owner_pid),
            }
            self.persist()
            self.assertTrue(self.invoke(real_pids={wrapper.pid, owner_pid})["closeAccepted"])
            self.cmux.run.assert_called_once()

    def test_close_refuses_real_zombie_source_owner_under_live_wrapper(self):
        with self.owned_source_wrapper() as (wrapper, owner_pid):
            wrapper.stdin.write("exit-owner\n")
            wrapper.stdin.flush()
            deadline = time.monotonic() + 5
            while True:
                state = subprocess.run(
                    ["/bin/ps", "-o", "state=", "-p", str(owner_pid)],
                    capture_output=True, text=True, timeout=3, check=True,
                ).stdout.strip()
                if state.startswith("Z"):
                    break
                self.assertLess(time.monotonic(), deadline, "owned source process did not exit")
                time.sleep(0.01)
            self.assertTrue(CONTROLLER["close_process_is_live"](self.child["providerProcess"]))
            self.assertTrue((self.source(self.child) / f"inuse.{owner_pid}.lock").exists())
            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "source owner"):
                self.invoke(real_pids={wrapper.pid, owner_pid})
            self.assertEqual(self.cmux.mock_calls, [])

    def test_close_refuses_real_source_owner_beyond_the_supported_direct_child_bound(self):
        with self.owned_source_wrapper() as (wrapper, owner_pid):
            self.child["providerProcess"] = {
                "pid": os.getpid(), "start": CONTROLLER["process_start"](os.getpid()),
            }
            self.persist()
            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "source owner"):
                self.invoke(real_pids={os.getpid(), wrapper.pid, owner_pid})
            self.assertEqual(self.cmux.mock_calls, [])

    def test_close_refuses_sibling_unrelated_foreign_dead_and_unknown_source_owner(self):
        self.separate_source_owner()
        for mapping, pid, value in (
            (self.parents, 12347, 1), (self.parents, 12347, 12345),
            (self.process_uids, 12347, os.getuid() + 1), (self.process_uids, 12347, "unknown"),
            (self.starts, 12347, None), (self.process_states, 12347, "Z"),
            (self.process_states, 12347, "?"), (self.process_states, 12346, "Z"),
            (self.starts, 12346, None), (self.starts, 12346, "replacement-start"),
        ):
            with self.subTest(pid=pid, value=value), mock.patch.dict(mapping, {pid: value}):
                with self.assertRaises(CONTROLLER["OrchestrationError"]):
                    self.invoke()
        self.assertEqual(self.cmux.mock_calls, [])

    def test_close_refuses_changed_owner_lineage_launch_identity_or_marker_during_preflight(self):
        marker = self.separate_source_owner()
        source_owner = CONTROLLER["close_source_owner"]
        def replace_marker():
            replacement = marker.with_name("replacement")
            replacement.touch(mode=0o644)
            replacement.replace(marker)
        for change in (
            lambda: self.parents.update({12347: 1}),
            lambda: self.starts.update({12347: "replacement-start"}),
            lambda: self.starts.update({12346: "replacement-start"}),
            replace_marker,
            lambda: (marker.parent / "inuse.12348.lock").touch(),
        ):
            calls = 0
            def changed(pid, launch):
                nonlocal calls
                result = source_owner(pid, launch)
                if pid == 12347:
                    calls += 1
                    if calls == 1:
                        change()
                return result
            with self.subTest(change=change), mock.patch.dict(CONTROLLER["command_native_close"].__globals__, {
                "close_source_owner": changed,
            }):
                with self.assertRaises(CONTROLLER["OrchestrationError"]):
                    self.invoke()
            self.parents[12347] = 12346
            self.starts[12346] = self.starts[12347] = self.child["providerProcess"]["start"]
            (marker.parent / "inuse.12348.lock").unlink(missing_ok=True)
        self.assertEqual(self.cmux.mock_calls, [])

    def test_close_refuses_invalid_marker_pids_and_owner_predating_launch(self):
        marker = self.separate_source_owner()
        for name in ("inuse.012347.lock", "inuse.1.lock", "inuse.2147483648.lock", "inuse.invalid.lock"):
            invalid = marker.with_name(name)
            marker.rename(invalid)
            try:
                with self.subTest(name=name):
                    with self.assertRaises(CONTROLLER["OrchestrationError"]):
                        self.invoke()
            finally:
                invalid.rename(marker)
        self.starts[12347] = "Wed Dec 31 00:00:00 2025"
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "generation changed"):
            self.invoke()
        self.assertEqual(self.cmux.mock_calls, [])

    def test_close_source_owner_refuses_unavailable_or_malformed_os_metadata(self):
        owner = CONTROLLER["close_source_owner"]
        anchor = self.child["providerProcess"]
        for output in ("", "12346", f"1 {os.getuid()} {anchor['start']}",
                       f"unknown {os.getuid()} {anchor['start']}",
                       f"12346 unknown {anchor['start']}"):
            with self.subTest(output=output), mock.patch("subprocess.run", return_value=
                    subprocess.CompletedProcess([], 0, output, "")) as run:
                self.assertIsNone(owner(12347, anchor))
                run.assert_called_once_with(
                    ["/bin/ps", "-o", "ppid=,uid=,lstart=", "-p", "12347"],
                    capture_output=True, text=True, timeout=3,
                )
        for error in (PermissionError(), subprocess.TimeoutExpired("/bin/ps", 3),
                      UnicodeDecodeError("utf8", b"\xff", 0, 1, "invalid")):
            with self.subTest(error=type(error).__name__), mock.patch("subprocess.run", side_effect=error):
                self.assertIsNone(owner(12347, anchor))
        with mock.patch("subprocess.run", return_value=
                subprocess.CompletedProcess([], 1, f"12346 {os.getuid()} {anchor['start']}", "")):
            self.assertIsNone(owner(12347, anchor))

    def test_close_accepts_stock_host_uuid_casing_without_interpreting_removal(self):
        self.cmux.run.return_value = {
            "workspace_id": self.child["workspaceId"].upper(), "workspace_ref": "workspace:1",
            "surface_id": self.child["surfaceId"].upper(), "surface_ref": "surface:2",
            "window_id": str(uuid.uuid4()).upper(), "window_ref": "window:1",
        }
        self.assertEqual(self.invoke(), {**self.target, "closeAccepted": True, "removal": "unconfirmed"})
        self.cmux.run.assert_called_once()

    def test_close_rejects_stale_target_fields(self):
        for key, value in (
            ("workerId", str(uuid.uuid4())), ("workspaceId", str(uuid.uuid4())),
            ("surfaceId", str(uuid.uuid4())), ("sessionId", str(uuid.uuid4())), ("generation", 2),
        ):
            with self.subTest(key=key):
                with self.assertRaises(CONTROLLER["OrchestrationError"]):
                    self.invoke({"identity": self.identity, "target": {**self.target, key: value}})
        self.cmux.run.assert_not_called()

    def test_close_rejects_self_grandchild_and_unrelated_target(self):
        foreign = {**copy.deepcopy(self.actor), "id": str(uuid.uuid4()), "runId": str(uuid.uuid4()),
                   "surfaceId": str(uuid.uuid4()), "copilotSessionId": str(uuid.uuid4())}
        self.state["nodes"][foreign["id"]] = foreign
        self.persist()
        for node in (self.actor, self.grandchild, foreign):
            with self.subTest(node=node["id"]):
                target = {
                    "workerId": node["id"], "workspaceId": node["workspaceId"],
                    "surfaceId": node["surfaceId"], "sessionId": node["copilotSessionId"], "generation": 1,
                }
                with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "outside"):
                    self.invoke({"identity": self.identity, "target": target})
        self.cmux.run.assert_not_called()

    def test_close_rejects_public_peer_capability_without_actual_invoker_authority(self):
        for key, value in (
            ("CMUX_MAESTRO_CONTROL_TOKEN", ""), ("CMUX_MAESTRO_WORKER_ID", self.child["id"]),
            ("SESSION_ID", self.child["copilotSessionId"]), ("CMUX_MAESTRO_RUN_ID", str(uuid.uuid4())),
            ("CMUX_MAESTRO_GENERATION", "2"), ("CMUX_WORKSPACE_ID", str(uuid.uuid4())),
            ("CMUX_SURFACE_ID", self.child["surfaceId"]),
        ):
            with self.subTest(key=key), mock.patch.dict(self.environment, {key: value}):
                with self.assertRaises(CONTROLLER["OrchestrationError"]):
                    self.invoke()
        self.cmux.run.assert_not_called()

    def test_worker_cannot_close_its_parent_or_sibling_even_with_its_own_native_authority(self):
        CONTROLLER["bind_messaging"](self.child)
        binding = json.loads((self.routes / f'{CONTROLLER["message_peer"](self.child)}.json').read_text())
        self.identity = {key: binding[key] for key in self.identity}
        self.environment.update(
            CMUX_MAESTRO_WORKER_ID=self.child["id"], SESSION_ID=self.child["copilotSessionId"],
            CMUX_MAESTRO_CONTROL_TOKEN="child-private-token", CMUX_SURFACE_ID=self.child["surfaceId"],
        )
        for node in (self.actor, self.sibling):
            with self.subTest(node=node["id"]):
                target = {
                    "workerId": node["id"], "workspaceId": node["workspaceId"], "surfaceId": node["surfaceId"],
                    "sessionId": node["copilotSessionId"], "generation": 1,
                }
                with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "outside"):
                    self.invoke({"identity": self.identity, "target": target})
        self.cmux.run.assert_not_called()

    def test_close_rejects_changed_actor_identity_capability_or_ancestry(self):
        for key, value in (
            ("nodeId", self.child["id"]), ("workspaceId", str(uuid.uuid4())),
            ("sessionId", str(uuid.uuid4())), ("generation", 2), ("capability", "f" * 64),
        ):
            with self.subTest(key=key):
                with self.assertRaises(CONTROLLER["OrchestrationError"]):
                    self.invoke({"identity": {**self.identity, key: value}, "target": self.target})
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "provider identity"):
            self.invoke(anchor=lambda _: {"pid": 12345, "start": "replacement"})
        self.cmux.run.assert_not_called()

    def test_close_refuses_active_launch_and_unresolved_ownership(self):
        for node in (self.actor, self.child):
            for key, value in (
                ("archiving", True), ("launchError", "launch-failed"),
                ("phase", "launching"), ("providerProcess", None),
                ("messaging", None),
            ):
                with self.subTest(node=node["id"], key=key), mock.patch.dict(node, {key: value}):
                    self.persist()
                    with self.assertRaises(CONTROLLER["OrchestrationError"]):
                        self.invoke()
            self.persist()
        self.child.pop("launchAccepted")
        self.persist()
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "unresolved"):
            self.invoke()
        self.child.update(surfaceId=None, surfaceUnknown=True)
        self.persist()
        with self.assertRaises(CONTROLLER["OrchestrationError"]):
            self.invoke()
        self.child.update(surfaceId=self.target["surfaceId"], launchAccepted=True)
        self.child.pop("surfaceUnknown")
        self.state["launches"][self.sibling["id"]] = {
            "workerId": self.sibling["id"], "runId": self.actor["runId"],
            "workspaceId": self.actor["workspaceId"], "sessionId": self.sibling["copilotSessionId"],
            "generation": 1, "surfaceId": self.sibling["surfaceId"], "state": "starting",
            "createdAt": CONTROLLER["now"](), "updatedAt": CONTROLLER["now"](),
        }
        self.sibling["phase"] = "launching"
        self.persist()
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "launch lease"):
            self.invoke()
        self.cmux.run.assert_not_called()

    def test_close_rejects_moved_or_missing_actor_and_child_without_following_them(self):
        for node in (self.actor, self.child):
            self.cmux.workspace_surfaces.return_value = {
                other["surfaceId"] for other in self.state["nodes"].values() if other["id"] != node["id"]
            }
            with self.subTest(node=node["id"]):
                with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "bound workspace"):
                    self.invoke()
        self.cmux.run.assert_not_called()

    def test_close_refuses_provider_exit_pid_reuse_and_unknown_probe(self):
        for pid in (12345, 12346):
            for start in (None, "replacement-start"):
                with self.subTest(pid=pid, start=start), mock.patch.dict(self.starts, {pid: start}):
                    with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "process anchor"):
                        self.invoke()
        with mock.patch.dict(self.starts, {12346: None}):
            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "process anchor"):
                self.invoke(kill_error=PermissionError)
        self.cmux.run.assert_not_called()

    def test_close_refuses_real_unreaped_zombie_before_any_host_call(self):
        source = self.source(self.child)
        (source / "inuse.12346.lock").unlink()
        process = subprocess.Popen([
            sys.executable, "-B", "-c",
            "import os,sys; from pathlib import Path; "
            "(Path(sys.argv[1])/f'inuse.{os.getpid()}.lock').touch(mode=0o600); "
            "print('ready',flush=True); sys.stdin.readline()",
            str(source),
        ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertTrue(select.select([process.stdout], [], [], 5)[0], "owned child did not become ready")
            self.assertEqual(process.stdout.readline().strip(), "ready")
            anchor = {"pid": process.pid, "start": CONTROLLER["process_start"](process.pid)}
            self.assertIsNotNone(anchor["start"])
            self.child["providerProcess"] = anchor
            self.persist()
            with mock.patch.object(Path, "home", return_value=self.home):
                CONTROLLER["require_close_source"](self.child)
            process.stdin.write("exit\n")
            process.stdin.flush()
            deadline = time.monotonic() + 5
            while True:
                state = subprocess.run(
                    ["/bin/ps", "-o", "state=", "-p", str(process.pid)],
                    capture_output=True, text=True, timeout=3, check=True,
                ).stdout.strip()
                if state.startswith("Z"):
                    break
                self.assertLess(time.monotonic(), deadline, "owned child did not exit within test watchdog")
                time.sleep(0.01)
            self.assertEqual(CONTROLLER["process_start"](process.pid), anchor["start"])
            self.assertTrue(CONTROLLER["process_observation"](anchor), "resource retention stays conservative")
            self.assertTrue((source / f"inuse.{process.pid}.lock").is_file())
            before = (self.root / "control/state.json").read_bytes()
            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "current provider process anchor"):
                self.invoke(real_pids={process.pid})
            self.assertEqual(self.cmux.mock_calls, [])
            self.assertEqual((self.root / "control/state.json").read_bytes(), before)
            self.assertEqual(process.wait(timeout=5), 0)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            for pipe in (process.stdin, process.stdout, process.stderr):
                pipe.close()

    def test_close_process_probe_accepts_known_live_states_with_exact_start(self):
        probe = CONTROLLER["close_process_is_live"]
        anchor = self.child["providerProcess"]
        for state in ("I", "R", "S", "T", "U", "S+", "Rs"):
            with self.subTest(state=state), mock.patch("subprocess.run", return_value=
                    subprocess.CompletedProcess([], 0, f" {state}  {anchor['start']}\n", "")) as run:
                self.assertTrue(probe(anchor))
                run.assert_called_once_with(
                    ["/bin/ps", "-o", "state=,lstart=", "-p", str(anchor["pid"])],
                    capture_output=True, text=True, timeout=3,
                )

    def test_close_process_probe_refuses_zombie_unknown_reused_or_failed_evidence(self):
        probe = CONTROLLER["close_process_is_live"]
        anchor = self.child["providerProcess"]
        for output in ("", "S", f"Z {anchor['start']}", f"Z+ {anchor['start']}",
                       f"X {anchor['start']}", f"? {anchor['start']}", "S replacement-start"):
            with self.subTest(output=output), mock.patch("subprocess.run", return_value=
                    subprocess.CompletedProcess([], 0, output, "")):
                self.assertFalse(probe(anchor))
        with mock.patch("subprocess.run", return_value=
                subprocess.CompletedProcess([], 1, f"S {anchor['start']}", "")):
            self.assertFalse(probe(anchor))
        for error in (FileNotFoundError(), PermissionError(), subprocess.TimeoutExpired("/bin/ps", 3),
                      UnicodeDecodeError("utf8", b"\xff", 0, 1, "invalid")):
            with self.subTest(error=type(error).__name__), mock.patch("subprocess.run", side_effect=error):
                self.assertFalse(probe(anchor))
        with mock.patch("subprocess.run") as run:
            self.assertFalse(probe(None))
            run.assert_not_called()

    def test_close_refuses_missing_repurposed_and_ambiguous_source_markers(self):
        source = self.source(self.child)
        marker = source / "inuse.12346.lock"
        marker.unlink()
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "missing or ambiguous"):
            self.invoke()
        marker.touch(mode=0o600)
        extra = source / "inuse.12347.lock"
        extra.touch(mode=0o600)
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "missing or ambiguous"):
            self.invoke()
        extra.unlink()
        marker.unlink()
        marker.symlink_to(self.source(self.actor) / "inuse.12345.lock")
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "source or provider"):
            self.invoke()
        self.cmux.run.assert_not_called()

    def test_close_refuses_symlinked_source_directory_and_source_inspection_overflow(self):
        source = self.source(self.child)
        original = source.with_name("original")
        source.rename(original)
        source.symlink_to(original)
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "source is unavailable"):
            self.invoke()
        source.unlink()
        original.rename(source)
        for index in range(512):
            (source / f"entry-{index}").touch()
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "inspection bound"):
            self.invoke()
        self.cmux.run.assert_not_called()

    def test_close_refuses_unsafe_or_pre_provider_source_marker(self):
        original_stat = os.stat
        for change in ({"st_birthtime": 0}, {"st_uid": os.getuid() + 1}, {"st_nlink": 2}, {"st_mode": 0o100666}):
            def altered(path, *args, **kwargs):
                result = original_stat(path, *args, **kwargs)
                if path == "inuse.12346.lock":
                    return SimpleNamespace(**{
                        key: getattr(result, key) for key in ("st_birthtime", "st_uid", "st_nlink", "st_mode")
                    } | change)
                return result
            with self.subTest(change=change), mock.patch("os.stat", side_effect=altered):
                with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "source or provider"):
                    self.invoke()
        self.cmux.run.assert_not_called()

    def test_close_uses_existing_bounded_rpc_for_stock_refusal_timeout_and_invalid_json(self):
        host = CONTROLLER["Cmux"].__new__(CONTROLLER["Cmux"])
        host.executable = "/synthetic/cmux"
        inventory = subprocess.CompletedProcess([], 0, json.dumps({
            "workspace_id": self.actor["workspaceId"],
            "surfaces": [{"id": node["surfaceId"]} for node in (self.actor, self.child)],
        }), "")
        self.cmux = host
        for failure in (
            subprocess.CompletedProcess([], 1, "", "lastSurface"),
            subprocess.CompletedProcess([], 0, "{", ""),
            subprocess.TimeoutExpired("cmux", 15), FileNotFoundError(),
        ):
            with self.subTest(failure=str(failure)), \
                    mock.patch("subprocess.run", side_effect=[inventory, failure]) as run:
                with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "failed or is uncertain"):
                    self.invoke()
                self.assertEqual(run.call_count, 2)
                self.assertEqual(run.call_args.args[0][:6], [
                    "/synthetic/cmux", "--json", "--id-format", "uuids", "rpc", "surface.close",
                ])
                self.assertEqual(run.call_args.kwargs["timeout"], 15)

    def test_close_rechecks_state_after_preflight_and_holds_lock_through_only_request(self):
        def changed(_):
            self.child["generation"] = 2
            self.persist()
            return self.actor["providerProcess"]
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "target identity"):
            self.invoke(anchor=changed)
        self.cmux.run.assert_not_called()

    def test_close_excludes_concurrent_controller_writes_without_persistent_close_state(self):
        def request(*_):
            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "operation is active"):
                CONTROLLER["mutate"](self.root, lambda _: self.fail("must not acquire"), wait=0)
            return {"workspace_id": self.target["workspaceId"], "surface_id": self.target["surfaceId"]}
        self.cmux.run.side_effect = request
        self.assertTrue(self.invoke()["closeAccepted"])
        self.cmux.run.assert_called_once()
        self.assertEqual(CONTROLLER["read_state"](self.root), self.state)

    def test_close_local_failures_and_unrecognized_replies_never_retry_or_read_after_send(self):
        before = (self.root / "control/state.json").read_bytes()
        for failure in (
            CONTROLLER["OrchestrationError"]("lastSurface"),
            CONTROLLER["OrchestrationError"]("timed out"),
            CONTROLLER["OrchestrationError"]("operation is active"),
            OSError("lost reply"),
        ):
            with self.subTest(failure=str(failure)):
                self.cmux.run.reset_mock()
                self.cmux.run.side_effect = failure
                with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "failed or is uncertain"):
                    self.invoke()
                self.cmux.run.assert_called_once()
        self.cmux.run.side_effect = None
        accepted = dict(self.cmux.run.return_value)
        for reply in (None, {}, {"surface_id": str(uuid.uuid4())},
                      {**accepted, "ok": False}, {**accepted, "closed": False},
                      {**accepted, "error": "refused"}):
            with self.subTest(reply=reply):
                self.cmux.run.reset_mock()
                self.cmux.run.return_value = reply
                with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "reply is unrecognized"):
                    self.invoke()
                self.cmux.run.assert_called_once()
        self.assertEqual((self.root / "control/state.json").read_bytes(), before)

    def test_close_strict_bounded_request_and_private_parser_entry(self):
        self.assertEqual(CONTROLLER["parser"]().parse_args(["native-close"]).command, "native-close")
        for request in (
            b"x" * 8193, b"{", [], {}, {"identity": self.identity, "target": [self.target]},
            {"identity": self.identity, "target": self.target, "subtree": True},
            {"identity": self.identity, "target": {**self.target, "generation": True}},
        ):
            with self.subTest(request=str(request)[:80]):
                with self.assertRaises(CONTROLLER["OrchestrationError"]):
                    self.invoke(request)
        self.cmux.run.assert_not_called()


class LifecycleFailureTests(unittest.TestCase):
    """No provider, filesystem routes, credentials, or installed state."""

    def setUp(self):
        self.root = Path("/unused-mocked-control-root")
        self.actor, self.token = CONTROLLER["new_root"](
            str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4()), "Coordinator",
        )
        self.actor["lastControlAt"] = "2000-01-01T00:00:00+00:00"
        self.worker = {
            **copy.deepcopy(self.actor), "id": str(uuid.uuid4()),
            "parentId": self.actor["id"], "role": "worker", "executionMode": "interactive",
            "copilotSessionId": str(uuid.uuid4()), "surfaceId": str(uuid.uuid4()),
            "generation": 1, "phase": "turn-running", "availability": "busy",
            "supervisor": {"pid": 12345, "start": "supervisor-start"},
            "providerProcess": {"pid": 12346, "start": "provider-start"},
        }
        self.state = {**CONTROLLER["empty_state"](), "nodes": {
            self.actor["id"]: self.actor, self.worker["id"]: self.worker,
        }}
        CONTROLLER["validate_state"](self.state)
        self.routes = {self.worker["id"]: "synthetic exact-generation route"}
        self.retire = mock.Mock(side_effect=lambda node: self.routes.pop(node["id"], None))
        self.cmux = mock.Mock()
        self.cmux.surface_exists.return_value = False
        self.cmux.validate_surface.return_value = self.actor["paneId"]
        self.mutations = 0
        self.before_mutate = lambda _: None

    def mutate(self, _root, callback, **_kwargs):
        self.mutations += 1
        self.before_mutate(self.mutations)
        pending = copy.deepcopy(self.state)
        result = callback(pending)
        CONTROLLER["validate_state"](pending)
        self.state.clear()
        self.state.update(pending)
        return result

    def archive(self, starts=lambda _: None, kill_error=ProcessLookupError):
        archive = CONTROLLER["command_archive"]
        args = CONTROLLER["parser"]().parse_args([
            "archive", "--actor-id", self.actor["id"], "--token", self.token,
        ])
        with mock.patch.dict(archive.__globals__, {
            "read_state": lambda *a, **k: copy.deepcopy(self.state),
            "mutate": self.mutate, "process_start": starts, "retire_messaging": self.retire,
        }), mock.patch("os.kill", side_effect=kill_error):
            return archive(args, self.root, self.cmux)

    def recover(self):
        recover = CONTROLLER["command_recover"]
        args = CONTROLLER["parser"]().parse_args([
            "recover", "--workspace", self.actor["workspaceId"],
            "--surface", self.actor["surfaceId"], "--name", "Recovered",
        ])
        with mock.patch.dict(recover.__globals__, {
            "read_state": lambda *a, **k: copy.deepcopy(self.state),
            "mutate": self.mutate, "require_current_surface": lambda *a: None,
            "process_start": lambda _: None, "retire_messaging": self.retire,
        }), mock.patch("os.kill", side_effect=ProcessLookupError):
            return recover(args, self.root, self.cmux)

    def test_archive_unknown_pid_preserves_records_routes_and_archive_flags(self):
        for kill_error in (None, PermissionError):
            with self.subTest(kill_error=kill_error):
                before, routes = copy.deepcopy(self.state), dict(self.routes)
                with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "uncertain"):
                    self.archive(kill_error=kill_error)
                self.assertEqual(self.state, before)
                self.assertEqual(self.routes, routes)
                self.retire.assert_not_called()

    def test_unavailable_ps_is_unknown_not_absence(self):
        probe = CONTROLLER["process_start"]
        for error in (FileNotFoundError(), subprocess.TimeoutExpired("/bin/ps", 3)):
            with self.subTest(error=error), mock.patch("subprocess.run", side_effect=error):
                self.assertIsNone(probe(12345))
                before = copy.deepcopy(self.state)
                with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "uncertain"):
                    self.archive(starts=probe, kill_error=None)
                self.assertEqual(self.state, before)
                self.retire.assert_not_called()

    def test_archive_rechecks_uncertainty_before_final_deletion_without_marking_run(self):
        before, routes = copy.deepcopy(self.state), dict(self.routes)
        # Admission and waiting establish exit; ps becomes unavailable at the
        # final locked check, where existence is now unknown.
        starts = lambda _: "different-start" if self.mutations == 1 else None
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "uncertain"):
            self.archive(starts=starts, kill_error=None)
        self.assertEqual(self.mutations, 2)
        self.assertEqual(self.state, before)
        self.assertEqual(self.routes, routes)
        self.retire.assert_not_called()

    def test_archive_waits_conservatively_when_probe_becomes_unknown(self):
        starts = mock.Mock(side_effect=["different-start", "different-start", None])
        before = copy.deepcopy(self.state)
        with mock.patch("time.monotonic", side_effect=[0, 0, 100]), mock.patch("time.sleep"):
            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "pending"):
                self.archive(starts=starts, kill_error=None)
        self.assertEqual(self.mutations, 1)
        self.assertEqual(self.state, before)
        self.retire.assert_not_called()

    def test_archive_uses_current_locked_process_identity(self):
        def replace_identity(count):
            if count == 1:
                self.state["nodes"][self.worker["id"]]["providerProcess"]["start"] = "current-start"
        self.before_mutate = replace_identity
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "uncertain"):
            self.archive(starts=lambda pid: "current-start" if pid == 12346 else "different-start")
        self.assertFalse(self.state["nodes"][self.worker["id"]]["archiving"])
        self.retire.assert_not_called()

    def test_archive_revalidates_coordinator_identity_under_lock(self):
        def replace_identity(count):
            if count == 1:
                self.state["nodes"][self.actor["id"]]["surfaceId"] = str(uuid.uuid4())
        self.before_mutate = replace_identity
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "ownership changed"):
            self.archive()
        self.retire.assert_not_called()
        self.assertFalse(self.state["nodes"][self.actor["id"]]["archiving"])

    def test_archive_confirmed_actual_exit_retires_and_retains_surface(self):
        result = self.archive()
        self.assertTrue(result["archived"])
        self.assertEqual(self.state["nodes"], {})
        self.assertEqual(self.routes, {})
        self.assertEqual(self.state["retainedResources"][0]["surfaceId"], self.worker["surfaceId"])

    def test_legacy_archive_keeps_cooperative_stop(self):
        self.worker.pop("executionMode")
        self.worker.pop("providerProcess")
        def starts(_pid):
            stopped = self.state["nodes"][self.worker["id"]]["archiving"]
            return None if stopped else "supervisor-start"
        self.assertTrue(self.archive(starts=starts)["archived"])
        self.assertEqual(self.state["nodes"], {})

    def failed_spawn(self, failure):
        spawn = CONTROLLER["command_spawn"]
        self.state["nodes"].pop(self.worker["id"])
        args = CONTROLLER["parser"]().parse_args([
            "spawn", "--actor-id", self.actor["id"], "--token", self.token,
            "--name", "Never started", "--task", "Synthetic", "--cwd", str(REPO),
        ])
        surface = str(uuid.uuid4())
        self.cmux.create_surface.return_value = surface
        if failure == "creation":
            self.cmux.create_surface.side_effect = RuntimeError("surface creation failed")
        elif failure == "attachment":
            self.cmux.validate_surface.side_effect = [
                self.actor["paneId"], RuntimeError("attachment failed"),
            ]
        legacy_launch = CONTROLLER["launch_legacy_session"]
        def persisted_launch(root, cmux, identifier, *args):
            # Exercise retained legacy tickets, not a fictitious supervisor
            # in the new direct path.
            self.state["nodes"][identifier].pop("launchMethod", None)
            return legacy_launch(root, cmux, identifier, *args)
        with mock.patch.dict(spawn.__globals__, {
            "launch_reserved_session": persisted_launch,
            "read_state": lambda *a, **k: copy.deepcopy(self.state),
            "provider_launch_context": lambda *_: ("/synthetic/copilot", "/usr/bin:/bin"),
            "authorize_native_spawn": lambda state, *_: state["nodes"][self.actor["id"]],
            "mutate": self.mutate, "messaging_configuration": lambda _: None,
            "worker_launch_settings": lambda _: {"version": 1, "model": "synthetic-model"},
            "resolve_copilot_token": lambda _: None,
            "git_display_metadata": lambda _: CONTROLLER["absent_git_metadata"](),
            "resource_observations": lambda *a: ({}, set()),
            "with_store": mock.Mock(side_effect=OSError("ticket unavailable"))
                if failure == "credential" else lambda *a, **k: None,
            "remove_launch_credential": lambda *a: None,
            "timeout": lambda *a: 1,
        }), mock.patch("time.monotonic", side_effect=[0, 2]):
            with self.assertRaises((RuntimeError, OSError, CONTROLLER["OrchestrationError"])):
                spawn(args, self.root, self.cmux, native_identity={"login": "synthetic"})
        self.worker = next(node for node in self.state["nodes"].values() if node["role"] == "worker")
        self.state["nodes"][self.actor["id"]]["lastControlAt"] = "2000-01-01T00:00:00+00:00"
        self.cmux.validate_surface.side_effect = None
        self.assertTrue(self.worker["runtimeNotStarted"])
        self.assertFalse(self.worker["supervisor"])
        self.assertFalse(self.worker.get("providerProcess"))
        self.assertEqual(self.state["launches"], {})
        CONTROLLER["validate_state"](self.state)

    def test_surface_creation_error_is_unknown_and_cannot_recover_without_identity(self):
        self.failed_spawn("creation")
        self.assertIsNone(self.worker["surfaceId"])
        self.assertEqual(self.worker["phase"], "launch-failed")
        self.assertTrue(self.worker["surfaceUnknown"])
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "uncertain"):
            self.recover()
        snapshot = copy.deepcopy(self.state)
        CONTROLLER["reconcile_resources"](
            self.state, snapshot,
            {self.worker["id"]: {"surface": False, "process": False, "exited": True}}, set(),
        )
        self.assertEqual(self.state, snapshot)

    def test_pre_creation_ticket_failure_can_recover_without_anchors(self):
        self.failed_spawn("credential")
        self.assertIsNone(self.worker["surfaceId"])
        self.assertNotIn("surfaceUnknown", self.worker)
        self.cmux.create_surface.assert_not_called()
        self.assertEqual(self.recover()["recoveredRunId"], self.actor["runId"])

    def test_attachment_failure_requires_exact_surface_closure_then_recovers(self):
        self.failed_spawn("attachment")
        self.cmux.surface_exists.return_value = True
        before = copy.deepcopy(self.state)
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "live worker ownership"):
            self.recover()
        self.assertEqual(self.state, before)
        self.cmux.surface_exists.assert_called_with(self.worker["workspaceId"], self.worker["surfaceId"])
        self.cmux.surface_exists.return_value = False
        self.assertEqual(self.recover()["recoveredRunId"], self.actor["runId"])

    def test_confirmed_surface_loss_cancels_unclaimed_lease_and_requires_closure(self):
        self.failed_spawn("startup")
        self.assertEqual(self.worker["phase"], "terminal-disappeared")
        self.assertTrue(self.worker["launchAccepted"])
        self.cmux.surface_exists.return_value = True
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "live worker ownership"):
            self.recover()
        self.cmux.surface_exists.return_value = False
        self.assertEqual(self.recover()["recoveredRunId"], self.actor["runId"])

    def test_no_start_evidence_survives_resource_retirement_and_legacy_mode(self):
        self.failed_spawn("credential")
        self.worker["phase"] = "resource-retired"
        self.worker.pop("executionMode")
        CONTROLLER["validate_state"](self.state)
        self.assertEqual(self.recover()["recoveredRunId"], self.actor["runId"])

    def test_missing_anchors_or_failure_phase_alone_never_prove_no_start(self):
        for phase in ("turn-running", "launch-failed", "startup-failed", "resource-retired"):
            self.worker.update(
                phase=phase, availability="busy" if phase == "turn-running" else "unavailable",
                supervisor=None, providerProcess=None,
            )
            before = copy.deepcopy(self.state)
            with self.subTest(phase=phase), self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "uncertain"):
                self.recover()
            self.assertEqual(self.state, before)
            self.retire.assert_not_called()

    def test_failure_without_unclaimed_lease_cannot_record_no_start(self):
        self.worker.update(phase="launching", supervisor=None, providerProcess=None)
        CONTROLLER["record_launch_failure"](self.state, self.worker["id"])
        self.assertNotIn("runtimeNotStarted", self.worker)
        self.assertFalse(CONTROLLER["worker_processes_exited"](self.worker))

    def test_failure_after_runtime_claim_does_not_record_no_start(self):
        before = copy.deepcopy(self.worker)
        CONTROLLER["record_launch_failure"](self.state, self.worker["id"], self.worker["surfaceId"])
        self.assertEqual(self.worker, before)
        self.assertNotIn("runtimeNotStarted", self.worker)

    def test_proven_pre_creation_failure_can_archive(self):
        self.failed_spawn("credential")
        self.assertTrue(self.archive()["archived"])
        self.assertEqual(self.state["nodes"], {})
        self.assertEqual(self.state["retainedResources"], [])

    def test_unknown_creation_outcome_cannot_archive(self):
        self.failed_spawn("creation")
        before = copy.deepcopy(self.state)
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "unresolved"):
            self.archive()
        self.assertEqual(self.state, before)

    def test_surface_probe_requires_exact_inventory_and_preserves_unknown(self):
        cmux_type = CONTROLLER["Cmux"]
        error = CONTROLLER["OrchestrationError"]
        cmux = object.__new__(cmux_type)
        for response in (
            {"workspace_id": self.worker["workspaceId"], "surfaces": [{"id": self.worker["surfaceId"]}]},
            {"workspace_id": self.worker["workspaceId"], "surfaces": []},
            {"workspace_id": str(uuid.uuid4()), "surfaces": []},
            {"workspace_id": self.worker["workspaceId"]},
            {"workspace_id": self.worker["workspaceId"], "surfaces": [{"id": "not-an-id"}]},
        ):
            cmux.run = mock.Mock(return_value=response)
            observed = cmux.surface_exists(self.worker["workspaceId"], self.worker["surfaceId"])
            expected = True if response.get("surfaces") == [{"id": self.worker["surfaceId"]}] else (
                False if response == {"workspace_id": self.worker["workspaceId"], "surfaces": []} else None
            )
            self.assertIs(observed, expected)
        for failure in (error("timeout"), error("host unavailable"), FileNotFoundError()):
            cmux.run = mock.Mock(side_effect=failure)
            self.assertIsNone(cmux.surface_exists(self.worker["workspaceId"], self.worker["surfaceId"]))

    def test_unknown_surface_blocks_recovery_even_when_process_exit_is_proven(self):
        self.cmux.surface_exists.return_value = None
        before = copy.deepcopy(self.state)
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "live worker ownership"):
            self.recover()
        self.assertEqual(self.state, before)

    def test_passive_process_observation_distinguishes_missing_unknown_and_exit(self):
        observe = CONTROLLER["startup_observation"]
        probe = CONTROLLER["process_observation"]
        for start, error, expected in (
            ("supervisor-start", None, True),
            ("replacement", None, False),
            (None, ProcessLookupError, False),
            (None, PermissionError, None),
            (None, None, None),
        ):
            with self.subTest(start=start, error=error), \
                    mock.patch.dict(observe.__globals__, {"process_start": lambda _: start}), \
                    mock.patch("os.kill", side_effect=error):
                supervisor = probe(self.worker["supervisor"])
                provider = probe(self.worker["providerProcess"])
                with mock.patch.dict(observe.__globals__, {
                    "process_observation": mock.Mock(side_effect=AssertionError("formatter must not probe")),
                }):
                    result = observe(
                        self.worker, supervisor=supervisor, provider=provider,
                        observed_at="2000-01-01T00:00:00+00:00",
                    )
                self.assertEqual(result["observedAt"], "2000-01-01T00:00:00+00:00")
                self.assertIs(result["supervisorRunning"], expected)
                self.assertEqual(result["workObservation"], "unavailable")
                if expected is False:
                    self.assertEqual(result["startup"], "failed")
                elif expected is None:
                    self.assertEqual(result["startup"], "supervisor-started")
        self.worker["supervisor"] = None
        self.worker["providerProcess"] = None
        result = observe(self.worker)
        self.assertIsNone(result["supervisorRunning"])
        self.assertIsNone(result["providerRunning"])
        self.assertFalse(result["providerStarted"])
        self.assertEqual(result["initialTask"], "configured")

    def test_no_start_evidence_rejects_conflicting_process_or_live_lease(self):
        self.failed_spawn("creation")
        for change in ("supervisor", "providerProcess", "launch", "phase", "false"):
            state = copy.deepcopy(self.state)
            node = state["nodes"][self.worker["id"]]
            if change in ("supervisor", "providerProcess"):
                node[change] = {"pid": 12345, "start": "possibly-live"}
            elif change == "launch":
                state["launches"][node["id"]] = {}
            elif change == "phase":
                node.update(phase="turn-running", availability="busy")
            else:
                node["runtimeNotStarted"] = False
            with self.subTest(change=change), self.assertRaisesRegex(
                CONTROLLER["OrchestrationError"], "pre-runtime failure",
            ):
                CONTROLLER["validate_state"](state)

    def census_host(self, surfaces):
        host = object.__new__(CONTROLLER["Cmux"])
        panes = [str(uuid.uuid4()), str(uuid.uuid4())]
        read_panes = []

        def run(command, *arguments):
            if command == "rpc":
                self.assertEqual(arguments, (
                    "surface.list", json.dumps({"workspace_id": self.actor["workspaceId"]}),
                ))
                return {"workspace_id": self.actor["workspaceId"],
                        "surfaces": [{"id": surface} for surface in surfaces]}
            if command == "list-panes":
                return {"panes": [{"pane_id": pane} for pane in panes]}
            if command == "list-pane-surfaces":
                # B's tracked surface moves into already-read A between calls.
                read_panes.append(arguments[-1])
                return {"surfaces": [{"surface_id": surface} for surface in sorted(surfaces)[:-1]]
                        if len(read_panes) == 1 else []}
            raise AssertionError(command)

        host.run = mock.Mock(side_effect=run)
        return host, read_panes

    def test_atomic_census_preserves_cross_pane_moved_terminal_at_root_and_child_limit(self):
        self.state["nodes"].pop(self.worker["id"])
        self.state["retainedResources"] = [{
            "runId": str(uuid.uuid4()), "workspaceId": self.actor["workspaceId"],
            "surfaceId": str(uuid.uuid4()), "archivedAt": CONTROLLER["now"](),
        } for _ in range(MAX_LIVE_WORKERS)]
        host, _ = self.census_host({item["surfaceId"] for item in self.state["retainedResources"]})
        self.cmux.workspace_surfaces.side_effect = host.workspace_surfaces
        before = copy.deepcopy(self.state)
        for command in ("launch-coordinator", "spawn"):
            argv = ([
                command, "--workspace", self.actor["workspaceId"],
                "--surface", self.actor["surfaceId"], "--account", "synthetic",
            ] if command == "launch-coordinator" else [
                command, "--actor-id", self.actor["id"], "--token", self.token,
            ]) + ["--name", "Over capacity", "--task", "Synthetic", "--cwd", str(REPO)]
            function = CONTROLLER["command_" + command.replace("-", "_")]
            forbidden = mock.Mock(side_effect=AssertionError("over-capacity resource launched"))
            with self.subTest(command=command), mock.patch.dict(function.__globals__, {
                "read_state": lambda *a, **k: copy.deepcopy(self.state),
                "mutate": self.mutate, "require_current_surface": lambda *a: None,
                "authorize_native_spawn": lambda state, *_: state["nodes"][self.actor["id"]],
                "provider_launch_context": lambda *_: ("/synthetic/copilot", "/usr/bin:/bin"),
                "resolve_copilot_token": lambda _: None,
                "worker_launch_settings": lambda _: {"version": 1, "model": "synthetic-model"},
                "messaging_configuration": lambda _: {
                    "version": 1, "routes": "/synthetic/routes", "extension": "/synthetic/extension",
                },
                "git_display_metadata": lambda _: CONTROLLER["absent_git_metadata"](),
                "launch_reserved_session": forbidden,
            }):
                with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "resource limit"):
                    if command == "spawn":
                        function(CONTROLLER["parser"]().parse_args(argv), self.root, self.cmux,
                                 native_identity={"login": "synthetic"})
                    else:
                        function(CONTROLLER["parser"]().parse_args(argv), self.root, self.cmux)
            self.assertEqual(self.state, before)
            forbidden.assert_not_called()

    def test_live_capacity_includes_roots_and_retained(self):
        for command in ("launch-coordinator", "spawn"):
            for limit, retained_count in ((2, 0), (32, 0), (32, 15), (32, 30), (64, 31), (128, 126)):
                with self.subTest(command=command, limit=limit, retained=retained_count):
                    actor = copy.deepcopy(self.actor)
                    managed_root = {
                        **copy.deepcopy(self.worker), "id": str(uuid.uuid4()),
                        "parentId": None, "role": "coordinator",
                        "runtimeProtocolVersion": 2, "launchMethod": "direct",
                        "launchSettings": {"version": 1, "copilotAccount": "synthetic",
                                           "model": "synthetic-model"},
                    }
                    managed_root["runId"] = managed_root["id"]
                    nodes = {actor["id"]: actor}
                    for index in range(limit - 1 - retained_count):
                        node = copy.deepcopy(managed_root)
                        if index:
                            node.update(id=str(uuid.uuid4()), runId=str(uuid.uuid4()),
                                        surfaceId=str(uuid.uuid4()), copilotSessionId=str(uuid.uuid4()))
                            node["runId"] = node["id"]
                        nodes[node["id"]] = node
                    retained = [{
                        "runId": str(uuid.uuid4()), "workspaceId": actor["workspaceId"],
                        "surfaceId": str(uuid.uuid4()), "archivedAt": CONTROLLER["now"](),
                    } for _ in range(retained_count)]
                    self.state = {**CONTROLLER["empty_state"](),
                                  "nodes": nodes, "retainedResources": retained,
                                  "workspaceCapacity": {actor["workspaceId"]: limit}}
                    CONTROLLER["validate_state"](self.state)
                    self.cmux.workspace_surfaces.return_value = {
                        node["surfaceId"] for node in nodes.values()
                    } | {item["surfaceId"] for item in retained}
                    argv = ([
                        command, "--workspace", actor["workspaceId"],
                        "--surface", actor["surfaceId"], "--account", "synthetic",
                    ] if command == "launch-coordinator" else [
                        command, "--actor-id", managed_root["id"], "--token", self.token,
                    ]) + ["--name", "Capacity boundary", "--task", "Synthetic", "--cwd", str(REPO)]
                    function = CONTROLLER["command_" + command.replace("-", "_")]
                    launcher = mock.Mock(return_value={"launchAccepted": True, "startup": "pending"})
                    with mock.patch.dict(function.__globals__, {
                        "read_state": lambda *a, **k: copy.deepcopy(self.state),
                        "mutate": self.mutate, "require_current_surface": lambda *a: None,
                        "authorize_native_spawn": lambda state, *_: state["nodes"][managed_root["id"]],
                        "process_matches": lambda _: True,
                        "provider_launch_context": lambda *_: ("/synthetic/copilot", "/usr/bin:/bin"),
                        "resolve_copilot_token": lambda _: None,
                        "worker_launch_settings": lambda _: {"version": 1, "model": "synthetic-model"},
                        "messaging_configuration": lambda _: {
                            "version": 1, "routes": "/synthetic/routes", "extension": "/synthetic/extension",
                        },
                        "git_display_metadata": lambda _: CONTROLLER["absent_git_metadata"](),
                        "launch_reserved_session": launcher,
                    }):
                        args = CONTROLLER["parser"]().parse_args(argv)
                        kwargs = {"native_identity": {"login": "synthetic"}} if command == "spawn" else {}
                        result = function(args, self.root, self.cmux, **kwargs)
                        self.assertTrue(result["launchAccepted"])
                        launcher.assert_called_once()
                        self.assertEqual(sum(CONTROLLER["has_managed_runtime"](node)
                                             for node in self.state["nodes"].values())
                                         + len(self.state["retainedResources"]), limit)
                        self.assertEqual(len(self.state["launches"]), 1)
                        before = copy.deepcopy(self.state)
                        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "resource limit"):
                            function(args, self.root, self.cmux, **kwargs)
                        self.assertEqual(self.state, before)
                        launcher.assert_called_once()

    def test_spawn_rechecks_changed_limit_after_advisory_preflight(self):
        self.state["workspaceCapacity"] = {self.actor["workspaceId"]: 2}
        preflight = CONTROLLER["workspace_capacity"](self.state, self.actor["workspaceId"])
        self.assertTrue(preflight["admissionAvailable"])
        self.before_mutate = lambda _: self.state["workspaceCapacity"].update(
            {self.actor["workspaceId"]: 1}
        )
        spawn = CONTROLLER["command_spawn"]
        launcher = mock.Mock(side_effect=AssertionError("no remaining slot may launch"))
        args = CONTROLLER["parser"]().parse_args([
            "spawn", "--actor-id", self.actor["id"], "--token", self.token,
            "--name", "Capacity changed", "--task", "Synthetic", "--cwd", str(REPO),
        ])
        with mock.patch.dict(spawn.__globals__, {
            "read_state": lambda *a, **k: copy.deepcopy(self.state),
            "mutate": self.mutate,
            "provider_launch_context": lambda *_: ("/synthetic/copilot", "/usr/bin:/bin"),
            "resolve_copilot_token": lambda _: None,
            "worker_launch_settings": lambda _: {"version": 1, "model": "synthetic-model"},
            "messaging_configuration": lambda _: None,
            "resource_observations": lambda *_: ({}, set()),
            "git_display_metadata": lambda _: CONTROLLER["absent_git_metadata"](),
            "launch_reserved_session": launcher,
        }), mock.patch.dict(os.environ, {"CMUX_MAESTRO_TESTING": "1"}):
            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "resource limit"):
                spawn(args, self.root, self.cmux)
        launcher.assert_not_called()
        self.assertEqual(self.state["launches"], {})
        self.assertEqual(len(self.state["nodes"]), 2)

    def test_native_child_inherits_verified_parent_permissions_without_explicit_yolo(self):
        for role in ("coordinator", "worker"):
            for mode in ("default", "yolo"):
                with self.subTest(role=role, mode=mode):
                    parent = copy.deepcopy(self.worker)
                    parent.update(role=role, permissionMode=mode, toolPolicy={
                        "allow": ["read", "shell(git status)"], "deny": ["web"],
                    })
                    if role == "coordinator":
                        parent.update(parentId=None, runId=parent["id"], runtimeProtocolVersion=2,
                                      launchSettings={"version": 1, "model": "synthetic-model"})
                    self.state = {**CONTROLLER["empty_state"](), "nodes": {
                        self.actor["id"]: copy.deepcopy(self.actor), parent["id"]: parent,
                    }}
                    CONTROLLER["validate_state"](self.state)
                    spawn = CONTROLLER["command_spawn"]
                    args = CONTROLLER["parser"]().parse_args([
                        "spawn", "--actor-id", parent["id"], "--token", self.token,
                        "--name", "Inherited permissions", "--task", "Synthetic",
                        "--cwd", str(REPO),
                    ])
                    launcher = mock.Mock(return_value={"launchAccepted": True})
                    with mock.patch.dict(spawn.__globals__, {
                        "read_state": lambda *a, **k: copy.deepcopy(self.state),
                        "mutate": self.mutate,
                        "authorize_native_spawn": lambda state, *_: state["nodes"][parent["id"]],
                        "process_matches": lambda _: True,
                        "provider_launch_context": lambda *_: ("/synthetic/copilot", "/usr/bin:/bin"),
                        "resolve_copilot_token": lambda _: None,
                        "worker_launch_settings": lambda _: {"version": 1, "model": "synthetic-model"},
                        "messaging_configuration": lambda _: None,
                        "resource_observations": lambda *_: ({}, set()),
                        "git_display_metadata": lambda _: CONTROLLER["absent_git_metadata"](),
                        "launch_reserved_session": launcher,
                    }):
                        spawn(args, self.root, self.cmux, native_identity={"login": "synthetic"})
                    child_id = launcher.call_args.args[2]
                    child = self.state["nodes"][child_id]
                    self.assertEqual(child["parentId"], parent["id"])
                    self.assertEqual(child["permissionMode"], mode)
                    self.assertEqual(child["toolPolicy"], parent["toolPolicy"])
                    self.assertEqual(len(self.state["launches"]), 1)
                    del self.state["launches"][child_id]
                    del self.state["nodes"][child_id]

    def test_launch_arguments_preserve_inherited_yolo_denies_and_explicit_allows(self):
        node = {
            **self.worker, "copilotExecutable": "/synthetic/copilot",
            "workingDirectory": str(REPO), "permissionMode": "yolo",
            "toolPolicy": {"allow": ["read"], "deny": ["web", "shell(rm)"]},
        }
        arguments = CONTROLLER["interactive_arguments"]
        with mock.patch.dict(arguments.__globals__, {"trusted_executable": lambda *_: "/synthetic/copilot"}):
            argv = arguments(node, "Synthetic task")
        self.assertEqual(argv.count("--allow-all"), 1)
        self.assertIn("--allow-tool", argv)
        self.assertEqual(argv[argv.index("--allow-tool") + 1], "read")
        self.assertEqual([argv[index + 1] for index, value in enumerate(argv) if value == "--deny-tool"],
                         ["web", "shell(rm)"])

    def test_atomic_census_distinguishes_removed_and_surviving_exited_surface(self):
        observe = CONTROLLER["resource_observations"]
        for present in (True, False):
            host, read_panes = self.census_host({self.worker["surfaceId"]} if present else set())
            state = copy.deepcopy(self.state)
            state["retainedResources"] = [{
                "runId": str(uuid.uuid4()), "workspaceId": self.actor["workspaceId"],
                "surfaceId": str(uuid.uuid4()), "archivedAt": CONTROLLER["now"](),
            }]
            with self.subTest(present=present), mock.patch.dict(observe.__globals__, {
                "process_matches": lambda _: False, "worker_processes_exited": lambda _: True,
            }):
                observations, gone = observe(state, host, self.actor["workspaceId"])
                CONTROLLER["reconcile_resources"](state, copy.deepcopy(state), observations, gone)
            self.assertEqual(state["nodes"][self.worker["id"]]["phase"],
                             "turn-running" if present else "resource-retired")
            self.assertEqual(state["retainedResources"], [])
            self.assertEqual(read_panes, [])

    def test_atomic_census_rejects_unavailable_malformed_or_wrong_workspace_inventory(self):
        host, _ = self.census_host(set())
        before = copy.deepcopy(self.state)
        for response in (
            None, {}, {"workspace_id": self.actor["workspaceId"], "surfaces": None},
            {"workspace_id": str(uuid.uuid4()), "surfaces": []},
            {"workspace_id": self.actor["workspaceId"], "surfaces": [{}]},
            {"workspace_id": self.actor["workspaceId"], "surfaces": [{"id": "not-a-uuid"}]},
            {"workspace_id": self.actor["workspaceId"], "surfaces": [
                {"id": self.worker["surfaceId"]}, {"id": self.worker["surfaceId"]},
            ]},
        ):
            host.run = mock.Mock(return_value=response)
            with self.subTest(response=response), self.assertRaises(CONTROLLER["OrchestrationError"]):
                CONTROLLER["resource_observations"](self.state, host, self.actor["workspaceId"])
            self.assertEqual(self.state, before)
        for failure in (CONTROLLER["OrchestrationError"]("unavailable"), FileNotFoundError()):
            host.run = mock.Mock(side_effect=failure)
            with self.assertRaises((CONTROLLER["OrchestrationError"], OSError)):
                CONTROLLER["resource_observations"](self.state, host, self.actor["workspaceId"])
            self.assertEqual(self.state, before)

    def test_census_never_releases_active_lease_or_new_retained_ownership(self):
        root = self.managed_root()
        root.update(phase="launching", availability="busy", surfaceId=None)
        self.state["launches"][root["id"]] = {
            "workerId": root["id"], "runId": root["runId"],
            "workspaceId": root["workspaceId"], "surfaceId": None,
            "state": "creating", "createdAt": root["createdAt"], "updatedAt": root["updatedAt"],
        }
        snapshot = copy.deepcopy(self.state)
        resource = {
            "runId": root["runId"], "workspaceId": root["workspaceId"],
            "surfaceId": str(uuid.uuid4()), "archivedAt": CONTROLLER["now"](),
        }
        self.state["retainedResources"].append(resource)
        CONTROLLER["reconcile_resources"](
            self.state, snapshot, {root["id"]: {"surface": False, "exited": True}},
            {resource["surfaceId"]},
        )
        self.assertEqual(root["phase"], "launching")
        self.assertEqual(self.state["launches"], snapshot["launches"])
        self.assertEqual(self.state["retainedResources"], [resource])

    def managed_root(self, *, never_started=False):
        root = self.state["nodes"][self.actor["id"]]
        root.update(
            executionMode="interactive", runtimeProtocolVersion=2, generation=1,
            copilotSessionId=str(uuid.uuid4()),
            launchSettings={"version": 1, "model": "synthetic-model"},
            phase="launch-failed" if never_started else "process-disappeared",
            availability="unavailable",
            supervisor=None if never_started else copy.deepcopy(self.worker["supervisor"]),
            providerProcess=None if never_started else copy.deepcopy(self.worker["providerProcess"]),
        )
        if never_started:
            root["runtimeNotStarted"] = True
        return root

    def test_managed_root_archive_does_not_require_surviving_surface(self):
        for failure in ("creation", "attachment", "closed-after-exit"):
            self.setUp()
            root = self.managed_root(never_started=failure != "closed-after-exit")
            if failure == "creation":
                root["surfaceId"] = None
            self.cmux.validate_surface.side_effect = CONTROLLER["OrchestrationError"]("surface absent")
            self.assertTrue(self.archive()["archived"])
            self.assertEqual(self.state["nodes"], {})
            self.assertEqual({item["surfaceId"] for item in self.state["retainedResources"]},
                             {self.worker["surfaceId"]} | (
                                 {root["surfaceId"]} if root["surfaceId"] else set()
                             ))
            self.cmux.validate_surface.assert_not_called()

    def test_managed_root_archive_preserves_missing_or_uncertain_process_anchors(self):
        root = self.managed_root()
        root["surfaceId"] = None
        for missing in (None, "supervisor", "providerProcess"):
            original = copy.deepcopy(root)
            if missing:
                root[missing] = None
            before = copy.deepcopy(self.state)
            with self.subTest(missing=missing), self.assertRaisesRegex(
                CONTROLLER["OrchestrationError"], "uncertain",
            ):
                self.archive(kill_error=PermissionError)
            self.assertEqual(self.state, before)
            self.retire.assert_not_called()
            root.update(original)

    def test_managed_root_archive_refuses_active_lease_and_live_descendant(self):
        root = self.managed_root()
        root.update(phase="launching", availability="busy")
        self.state["launches"][root["id"]] = {
            "workerId": root["id"], "runId": root["runId"],
            "workspaceId": root["workspaceId"], "surfaceId": root["surfaceId"],
            "state": "starting", "createdAt": root["createdAt"], "updatedAt": root["updatedAt"],
        }
        before = copy.deepcopy(self.state)
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "launch is in progress"):
            self.archive()
        self.assertEqual(self.state, before)
        self.state["launches"].clear()
        root.update(phase="launch-failed", availability="unavailable",
                    runtimeNotStarted=True, supervisor=None, providerProcess=None)
        before = copy.deepcopy(self.state)
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "uncertain"):
            self.archive(starts=lambda pid: self.worker["providerProcess"]["start"]
                         if pid == 12346 else None)
        self.assertEqual(self.state, before)
        self.retire.assert_not_called()

    def test_managed_root_archive_requires_exact_token_and_locked_session_identity(self):
        self.managed_root(never_started=True)
        before = copy.deepcopy(self.state)
        self.token = "wrong-token"
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "control token"):
            self.archive()
        self.assertEqual(self.state, before)
        self.setUp()
        self.managed_root(never_started=True)
        def replace_session(count):
            if count == 1:
                self.state["nodes"][self.actor["id"]]["copilotSessionId"] = str(uuid.uuid4())
        self.before_mutate = replace_session
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "ownership changed"):
            self.archive()
        self.assertEqual(len(self.state["nodes"]), 2)
        self.retire.assert_not_called()

    def test_legacy_archive_still_requires_exact_root_surface(self):
        before = copy.deepcopy(self.state)
        self.cmux.validate_surface.side_effect = CONTROLLER["OrchestrationError"]("absent")
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "absent"):
            self.archive()
        self.assertEqual(self.state, before)
        self.assertEqual(self.mutations, 0)


class RootCustodyTests(unittest.TestCase):
    """Real private Store and command entrypoint; synthetic host/provider only."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="root-custody-", dir="/tmp")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        (self.root / "routes").mkdir(mode=0o700)
        self.original, _ = CONTROLLER["new_root"](
            str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4()), "Original session",
        )
        CONTROLLER["mutate"](self.root, lambda state: state["nodes"].update({
            self.original["id"]: copy.deepcopy(self.original),
        }))
        self.cmux = mock.Mock()
        self.cmux.validate_surface.return_value = self.original["paneId"]
        self.cmux.workspace_surfaces.return_value = {self.original["surfaceId"]}
        self.cmux.create_surface.side_effect = FileNotFoundError(2, "synthetic private diagnostic")
        self.argv = [
            "launch-coordinator", "--workspace", self.original["workspaceId"],
            "--surface", self.original["surfaceId"], "--account", "synthetic",
            "--cwd", str(REPO), "--task", "Synthetic root", "--deny-tool", "web",
        ]
        self.patches = mock.patch.dict(CONTROLLER["main"].__globals__, {
            "default_root": lambda: self.root, "Cmux": lambda: self.cmux,
            "require_current_surface": lambda *a: None,
            "provider_launch_context": lambda *_: ("/synthetic/copilot", "/usr/bin:/bin"),
            "trusted_executable": lambda *a: "/synthetic/copilot",
            "resolve_copilot_token": lambda _: None,
            "worker_launch_settings": lambda _: {"version": 1, "model": "synthetic-model"},
            "messaging_configuration": lambda _: {
                "version": 1, "routes": str(self.root / "routes"),
                "extension": str(self.root / "extension"),
            },
            "git_display_metadata": lambda _: CONTROLLER["absent_git_metadata"](),
        })
        self.patches.start()
        self.addCleanup(self.patches.stop)

    def test_root_and_native_child_receive_milestone_contract_with_verbatim_tasks(self):
        """Generated provider argv, not evidence of consuming-agent compliance."""
        root_task = " \tCoordinate 'quoted' work\nOriginal task (verbatim):\nKeep \u2603\n\n"
        child_task = " \tReview $(not-a-command) `literal` \\ \"candidate\"\n\n"
        self.argv[self.argv.index("--task") + 1] = root_task
        surfaces = [str(uuid.uuid4()), str(uuid.uuid4())]
        self.cmux.create_surface.side_effect = surfaces
        arguments = mock.Mock(wraps=CONTROLLER["interactive_arguments"])
        command = CONTROLLER["command_launch_coordinator"]
        with mock.patch.dict(command.__globals__, {
            "interactive_arguments": arguments,
            "process_matches": lambda _: True,
            "resource_observations": lambda *a: ({}, set()),
        }):
            root_receipt = command(CONTROLLER["parser"]().parse_args(self.argv), self.root, self.cmux)
            root_id = root_receipt["coordinatorId"]
            CONTROLLER["mutate"](self.root, lambda state: state["nodes"][root_id].update(
                providerProcess={"pid": 12345, "start": "synthetic-provider-start"},
            ))
            root_node = CONTROLLER["read_state"](self.root)["nodes"][root_id]
            route = Path(root_node["messaging"]["routes"]) / f'{CONTROLLER["message_peer"](root_node)}.json'
            binding = CONTROLLER["message_json"](route)
            identity = {key: binding[key] for key in (
                "nodeId", "workspaceId", "sessionId", "generation", "capability",
            )} | {"login": "synthetic-parent", "host": "https://github.com"}
            request = {
                "identity": identity,
                "assignment": {"name": "Review", "cwd": str(REPO), "task": child_task},
            }
            with mock.patch("sys.stdin", SimpleNamespace(buffer=io.BytesIO(json.dumps(request).encode()))):
                child_receipt = CONTROLLER["command_native_spawn"](self.root, self.cmux)

        self.assertEqual(arguments.call_count, 2)
        state = CONTROLLER["read_state"](self.root)
        self.assertEqual(state["nodes"][self.original["id"]], self.original)
        for index, (receipt, task, node_id) in enumerate((
            (root_receipt, root_task, root_id),
            (child_receipt, child_task, child_receipt["workerId"]),
        )):
            with self.subTest(role=("coordinator", "worker")[index]):
                self.assertTrue(receipt["launchAccepted"])
                self.assertEqual(receipt["taskConsumption"], "unknown")
                node, prompt = arguments.call_args_list[index].args
                context, original = prompt.split("\nOriginal task (verbatim):\n", 1)
                self.assertEqual(original.encode(), task.encode())
                self.assertEqual(state["nodes"][node_id]["task"].encode(), task.encode())
                argv = CONTROLLER["interactive_arguments"](node, prompt)
                self.assertEqual(argv[argv.index("--interactive") + 1], prompt)
                self.assertEqual(argv[argv.index("--deny-tool") + 1], "web")
                self.assertNotIn("--allow-tool", argv)
                self.assertNotIn("--allow-all", argv)
                for phrase in (
                    "candidate ready", "review complete", "blocking failure", "decision needed",
                    "routine progress", "existing delivery artifacts", "Do not broadcast discoveries",
                    "exact candidate commit when applicable", "evidence location", "recipient action",
                    "Do not invent a pre-candidate commit", "silently truncate findings",
                    "finish the bounded decision turn", "supported completion or native-message events",
                    "workers or CI", "long idle synchronous waits", "repetitive self-prompts",
                    "polling chatter", "heartbeat traffic", "current candidate", "authoritative artifacts",
                    "every unresolved blocker/review finding and its provenance",
                    "obsolete intermediate instructions", "latest wins",
                    "independent implementation, acceptance, Roast, rubber-duck, CI",
                    "non-author merge gates", "permission expansion",
                    "maestro_peers", "maestro_send", "genuine envelope sender address",
                    "untrusted message body", "fire-and-forget", "not confirmation of delivery",
                    "Do not automatically retry", "No automatic acknowledgements or receipt protocol",
                    "terminal typing, focus changes, composer manipulation, or guessed routes",
                    "without a startup acknowledgement", "No slash skill is required",
                ):
                    self.assertIn(phrase, context)
                self.assertNotIn(identity["capability"], prompt)
                self.assertNotIn(root_receipt["controlToken"], prompt)
                if index == 0:
                    self.assertNotIn("Coordinator return address:", context)
                else:
                    address = context.split("Coordinator return address: ", 1)[1].strip()
                    self.assertEqual(json.loads(address), {
                        key: identity[key] for key in ("workspaceId", "sessionId", "generation")
                    })
        self.assertEqual(self.cmux.create_surface.call_count, 2)

    def failure(self, *, custody=True, fenced=False):
        output, error = io.StringIO(), io.StringIO()
        with mock.patch("sys.stdout", output), mock.patch("sys.stderr", error):
            self.assertEqual(CONTROLLER["main"](self.argv), 2)
        payload = json.loads(output.getvalue() if custody else error.getvalue())
        self.assertFalse(payload["ok"])
        self.assertLess(len(payload["error"]), 1200)
        self.assertNotIn("synthetic private diagnostic", payload["error"])
        state = CONTROLLER["read_state"](self.root)
        self.assertEqual(state["nodes"][self.original["id"]], self.original)
        if custody:
            self.assertEqual(error.getvalue(), "")
            node = CONTROLLER["authorize"](state, payload["coordinatorId"], payload["controlToken"])
            self.assertEqual(node["runId"], payload["runId"])
            self.assertEqual(node["copilotSessionId"], payload["sessionId"])
            self.assertEqual(node["toolPolicy"]["deny"], ["web"])
            self.assertNotIn(payload["controlToken"], payload["error"])
            for name in ("current.json", "icons.json"):
                self.assertNotIn(payload["controlToken"], (self.root / "observer" / name).read_text())
            if fenced:
                self.assertEqual(node["phase"], "launch-failed")
                self.assertTrue(node["runtimeNotStarted"])
                self.assertEqual(state["launches"], {})
        else:
            self.assertEqual(output.getvalue(), "")
            self.assertNotIn("controlToken", payload)
            self.assertEqual(list(state["nodes"]), [self.original["id"]])
        return payload, state

    def test_missing_host_executable_returns_exact_private_custody(self):
        payload, state = self.failure()
        self.assertEqual(payload["reservationState"], "committed")
        self.cmux.create_surface.assert_called_once()
        self.cmux.rename.assert_not_called()
        self.assertEqual(list((self.root / "control").glob("launch-*.json")), [])
        self.assertTrue(state["nodes"][payload["coordinatorId"]]["surfaceUnknown"])
        self.assertIn(payload["coordinatorId"], state["launches"])

    def test_cmux_subprocess_os_failure_returns_custody(self):
        host = object.__new__(CONTROLLER["Cmux"])
        host.executable = "/synthetic/missing-cmux"
        self.cmux.create_surface.side_effect = host.create_surface
        with mock.patch("subprocess.run", side_effect=FileNotFoundError(2, "synthetic private diagnostic")):
            self.failure()

    def test_ticket_write_and_cleanup_os_errors_preserve_private_custody(self):
        atomic = CONTROLLER["Store"]._atomic
        def fail_ticket(directory, name, data):
            if name.startswith("direct-"):
                raise PermissionError(13, "synthetic private diagnostic")
            return atomic(directory, name, data)
        with mock.patch.object(CONTROLLER["Store"], "_atomic", side_effect=fail_ticket):
            self.failure(fenced=True)
        self.cmux.create_surface.assert_not_called()

    def test_uncertain_creation_retains_private_environment_without_cleanup(self):
        cleanup = mock.Mock(side_effect=PermissionError(13, "synthetic private diagnostic"))
        with mock.patch.dict(CONTROLLER["main"].__globals__, {
            "remove_launch_credential": cleanup,
        }):
            payload, state = self.failure()
        self.assertIn("FileNotFoundError", payload["error"])
        cleanup.assert_not_called()
        self.assertEqual(len(list((self.root / "control").glob("direct-*.sh"))), 1)
        self.assertIn(payload["coordinatorId"], state["launches"])
        self.assertNotIn("runtimeNotStarted", state["nodes"][payload["coordinatorId"]])

    def test_observer_failure_after_reservation_publication_returns_custody_and_fences_start(self):
        atomic = CONTROLLER["Store"]._atomic
        def fail_observer(directory, name, data):
            if name == "current.json":
                raise OSError(28, "synthetic private diagnostic")
            return atomic(directory, name, data)
        with mock.patch.object(CONTROLLER["Store"], "_atomic", side_effect=fail_observer):
            payload, _ = self.failure(fenced=True)
        self.assertEqual(payload["reservationState"], "committed")
        self.cmux.create_surface.assert_not_called()
        args = CONTROLLER["parser"]().parse_args([
            "archive", "--actor-id", payload["coordinatorId"], "--token", payload["controlToken"],
        ])
        self.cmux.validate_surface.side_effect = CONTROLLER["OrchestrationError"]("absent")
        self.assertTrue(CONTROLLER["command_archive"](args, self.root, self.cmux)["archived"])
        self.assertEqual(list(CONTROLLER["read_state"](self.root)["nodes"]), [self.original["id"]])

    def test_state_replace_then_fsync_error_preserves_committed_custody(self):
        atomic = CONTROLLER["Store"]._atomic
        def fail_after_commit(directory, name, data):
            atomic(directory, name, data)
            if name == "state.json":
                raise OSError(5, "synthetic private diagnostic")
        with mock.patch.object(CONTROLLER["Store"], "_atomic", side_effect=fail_after_commit):
            payload, _ = self.failure(fenced=True)
        self.assertEqual(payload["reservationState"], "committed")
        self.cmux.create_surface.assert_not_called()

    def test_unreadable_reservation_returns_uncertain_receipt_without_discarding_lease(self):
        atomic = CONTROLLER["Store"]._atomic
        read = CONTROLLER["Store"].read
        publication_failed = False
        def fail_observer(directory, name, data):
            nonlocal publication_failed
            if name == "current.json":
                publication_failed = True
                raise OSError(28, "synthetic private diagnostic")
            return atomic(directory, name, data)
        def unreadable_once(store):
            nonlocal publication_failed
            if publication_failed:
                publication_failed = False
                raise PermissionError(13, "synthetic private diagnostic")
            return read(store)
        with mock.patch.object(CONTROLLER["Store"], "_atomic", side_effect=fail_observer), \
                mock.patch.object(CONTROLLER["Store"], "read", unreadable_once):
            payload, state = self.failure(fenced=False)
        self.assertEqual(payload["reservationState"], "uncertain")
        node = state["nodes"][payload["coordinatorId"]]
        self.assertEqual(node["phase"], "launching")
        self.assertNotIn("runtimeNotStarted", node)
        self.assertEqual(state["launches"][node["id"]]["state"], "creating")
        self.assertIsNone(state["launches"][node["id"]]["surfaceId"])
        self.cmux.create_surface.assert_not_called()

    def test_attachment_os_error_retains_exact_created_surface_and_private_custody(self):
        surface = str(uuid.uuid4())
        self.cmux.create_surface.side_effect = None
        self.cmux.create_surface.return_value = surface
        self.cmux.validate_surface.side_effect = [
            self.original["paneId"], OSError(5, "synthetic private diagnostic"),
        ]
        payload, state = self.failure()
        self.assertEqual(state["nodes"][payload["coordinatorId"]]["surfaceId"], surface)
        self.assertIn(payload["coordinatorId"], state["launches"])
        self.assertNotIn("runtimeNotStarted", state["nodes"][payload["coordinatorId"]])
        self.assertEqual(state["retainedResources"], [])
        self.cmux.rename.assert_not_called()

    def test_launch_failure_with_unwritable_failure_state_keeps_lease_and_custody(self):
        atomic = CONTROLLER["Store"]._atomic
        def fail_failure_state(directory, name, data):
            if name == "state.json" and b'"launch-failed"' in data:
                raise OSError(28, "synthetic private diagnostic")
            return atomic(directory, name, data)
        with mock.patch.object(CONTROLLER["Store"], "_atomic", side_effect=fail_failure_state):
            payload, state = self.failure(fenced=False)
        self.assertEqual(payload["reservationState"], "committed")
        self.assertIn("FileNotFoundError", payload["error"])
        self.assertIn("OSError", payload["error"])
        self.assertEqual(state["launches"][payload["coordinatorId"]]["state"], "creating")
        self.assertEqual(len(list((self.root / "control").glob("direct-*.sh"))), 1)

    def test_created_surface_is_in_private_receipt_when_attachment_and_failure_writes_fail(self):
        surface = str(uuid.uuid4())
        self.cmux.create_surface.side_effect = None
        self.cmux.create_surface.return_value = surface
        atomic = CONTROLLER["Store"]._atomic
        def fail_after_creation(directory, name, data):
            if name == "state.json" and self.cmux.create_surface.called:
                raise OSError(28, "synthetic private diagnostic")
            return atomic(directory, name, data)
        with mock.patch.object(CONTROLLER["Store"], "_atomic", side_effect=fail_after_creation):
            payload, state = self.failure(fenced=False)
        self.assertEqual(payload["surfaceId"], surface)
        node = state["nodes"][payload["coordinatorId"]]
        self.assertIsNone(node["surfaceId"])
        self.assertEqual(state["launches"][node["id"]]["state"], "creating")
        self.assertEqual(len(list((self.root / "control").glob("direct-*.sh"))), 1)
        self.cmux.rename.assert_not_called()

    def test_uncommitted_state_write_failure_does_not_claim_custody(self):
        atomic = CONTROLLER["Store"]._atomic
        def fail_state(directory, name, data):
            if name == "state.json":
                raise OSError(28, "synthetic private diagnostic")
            return atomic(directory, name, data)
        with mock.patch.object(CONTROLLER["Store"], "_atomic", side_effect=fail_state):
            self.failure(custody=False)
        self.cmux.create_surface.assert_not_called()


if __name__ == "__main__":
    unittest.main()
