#!/usr/bin/env python3
"""Fixture/launcher contracts only: never authenticates or launches a real provider."""

import os
from pathlib import Path
import runpy
import shutil
import unittest
from unittest import mock
import uuid

REPO = Path(__file__).resolve().parents[1]
PROOF = runpy.run_path(str(REPO / "scripts/delivery-proof/fixture.py"))
CONTROLLER = runpy.run_path(str(REPO / "scripts/cmux-maestro-orchestrator.py"))


class ProofTests(unittest.TestCase):
    def setUp(self):
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

    def run_mocked_launcher(self):
        run = CONTROLLER["run_interactive_session"]
        process = mock.Mock(pid=12345)
        process.poll.return_value = 0
        process.wait.return_value = 0
        popen = mock.Mock(return_value=process)
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


if __name__ == "__main__":
    unittest.main()
