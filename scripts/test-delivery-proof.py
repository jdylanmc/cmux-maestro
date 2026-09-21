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

    def test_installed_skill_exposes_messaging_without_implicit_permission_grants(self):
        skill = (REPO / "skills/maestro/SKILL.md").read_text()
        frontmatter = skill.split("---", 2)[1]
        self.assertEqual({line.split(":", 1)[0] for line in frontmatter.splitlines() if line}, {"name", "description"})
        self.assertIn("name: maestro", frontmatter)
        for tool in ("maestro_peers", "maestro_send"):
            self.assertIn(f"`{tool}`", skill)
        for constraint in (
            "workspaceId", "sessionId", "generation", "4096 UTF-8 bytes",
            "/cmux-maestro-orchestrate", "messagingInstalled: true",
            "Worker actors cannot request YOLO", "delivery and completion are",
        ):
            self.assertIn(constraint, skill)
        self.assertTrue((REPO / "skills/maestro/intent.md").is_file())
        self.assertFalse((REPO / "skills/maestro/_atoms").exists())
        self.assertFalse((REPO / "skills/maestro/_molecules").exists())

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
        routes = REPO / ".build" / uuid.uuid4().hex[:5]
        routes.mkdir(mode=0o700)
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
            "worker_launch_settings": lambda _: {},
            "resolve_copilot_token": credentials,
            "git_display_metadata": lambda _: CONTROLLER["absent_git_metadata"](),
            "resolve_icon": lambda _: "synthetic-icon",
            "resource_observations": lambda *a: ({}, set()),
            "mutate": reserve_only,
        }):
            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "Pinned"):
                spawn(args, self.root, mock.Mock())
            credentials.assert_not_called()
            with mock.patch.dict(spawn.__globals__, {
                "worker_launch_settings": lambda _: {
                    "version": 1, "copilotAccount": "synthetic", "model": "synthetic",
                },
            }):
                with self.assertRaises(Reserved):
                    spawn(args, self.root, mock.Mock())
        worker = next(node for node in state["nodes"].values() if node["role"] == "worker")
        self.assertEqual(worker["messaging"], config)
        self.assertEqual(worker["workingDirectory"], str(REPO))
        self.assertEqual(worker["permissionMode"], "default")
        self.assertEqual(worker["toolPolicy"], {"allow": [], "deny": ["web"]})
        self.assertNotIn("deliveryProof", worker)

    def test_installed_launcher_wires_ordinary_cwd_and_cleans_only_after_provider_exit(self):
        routes, _ = self.install_synthetic_messaging()
        # No fixture validation/binding should run in installed mode.
        args = self.run_mocked_launcher()
        self.assertIn("--experimental", args)
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


if __name__ == "__main__":
    unittest.main()
