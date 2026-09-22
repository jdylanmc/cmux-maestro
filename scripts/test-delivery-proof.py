#!/usr/bin/env python3
"""Fixture/launcher contracts only: never authenticates or launches a real provider."""

import copy
import json
import os
from pathlib import Path
import runpy
import shutil
import socket
import subprocess
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
            "/cmux-maestro-native:cmux-maestro-orchestrate", "messagingInstalled: true",
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
        if not self.node.get("messaging"):
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

    def install_synthetic_messaging(self, *, with_plugin=True):
        self.root = self.root / "Orchestration"
        self.root.mkdir(mode=0o700)
        routes = REPO / ".build" / uuid.uuid4().hex[:5]
        routes.mkdir(mode=0o700)
        self.addCleanup(shutil.rmtree, routes)
        extension = self.root / "extension"
        extension.mkdir(mode=0o700)
        for name in ("extension.mjs", "adapter.mjs"):
            shutil.copyfile(REPO / "scripts/delivery-proof" / name, extension / name)
            (extension / name).chmod(0o600)
        config = {"version": 1, "routes": str(routes), "extension": str(extension)}
        installed_config = dict(config)
        if with_plugin:
            plugin = self.root.parent / "Copilot/plugin"
            for directory in (plugin.parent, plugin, plugin / "skills", plugin / "skills/maestro"):
                directory.mkdir(mode=0o700)
            PROOF["write_new"](plugin / "plugin.json", {
                "name": "cmux-maestro-native", "version": "1.1.0", "hooks": "hooks.json",
            })
            skill = plugin / "skills/maestro/SKILL.md"
            shutil.copyfile(REPO / "skills/maestro/SKILL.md", skill)
            skill.chmod(0o600)
            installed_config["pluginDirectory"] = str(plugin)
        (self.root / "bin").mkdir(mode=0o700)
        PROOF["write_new"](self.root / "bin/messaging.json", installed_config)
        self.node.update({
            "id": str(uuid.uuid4()), "runId": str(uuid.uuid4()),
            "messaging": config, "executionMode": "interactive",
        })
        return routes, config

    def test_old_config_remains_readable_but_new_managed_launch_requires_setup_upgrade(self):
        routes, config = self.install_synthetic_messaging(with_plugin=False)
        self.assertEqual(CONTROLLER["messaging_configuration"](self.root), config)
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "updated setup"):
            self.run_mocked_launcher()
        self.assertEqual(list(routes.iterdir()), [])
        self.assertEqual(self.node["messaging"], config)

    def test_managed_plugin_configuration_rejects_malformed_and_foreign_paths(self):
        routes, _ = self.install_synthetic_messaging()
        path = self.root / "bin/messaging.json"
        original = PROOF["read_private"](path)
        for candidate in (None, 1, [], {}, "", "relative", "/foreign/plugin", "/bad\0path",
                          "/" + "x" * 1024, original["pluginDirectory"] + "/../plugin"):
            with self.subTest(candidate=candidate):
                path.write_text(json.dumps({**original, "pluginDirectory": candidate}))
                with self.assertRaises(CONTROLLER["OrchestrationError"]):
                    self.run_mocked_launcher()
                self.assertEqual(list(routes.iterdir()), [])
        path.write_text(json.dumps({**original, "unexpected": True}))
        with self.assertRaises(CONTROLLER["OrchestrationError"]):
            CONTROLLER["messaging_configuration"](self.root)

    def test_managed_plugin_rejects_wrong_manifest_and_unreadable_skill(self):
        routes, _ = self.install_synthetic_messaging()
        plugin = self.root.parent / "Copilot/plugin"
        manifest = plugin / "plugin.json"
        original = manifest.read_bytes()
        for value in ({}, [], {"name": "foreign", "version": "1.1.0", "hooks": "hooks.json"},
                      {"name": "cmux-maestro-native", "version": "0.0.0", "hooks": "hooks.json"},
                      {"name": "cmux-maestro-native", "version": "1.1.0", "hooks": "../hooks.json"}):
            with self.subTest(manifest=value):
                manifest.write_text(json.dumps(value))
                with self.assertRaises(CONTROLLER["OrchestrationError"]):
                    self.run_mocked_launcher()
        manifest.write_bytes(original)
        skill = plugin / "skills/maestro/SKILL.md"
        for content in (b"", b"---\nname: foreign\n---\n", b"\xff", b"x" * 65_537):
            with self.subTest(skill=content[:20]):
                skill.write_bytes(content)
                with self.assertRaises(CONTROLLER["OrchestrationError"]):
                    self.run_mocked_launcher()
        skill.unlink()
        with self.assertRaises(CONTROLLER["OrchestrationError"]):
            self.run_mocked_launcher()
        self.assertEqual(list(routes.iterdir()), [])

    def test_managed_plugin_refuses_symlinks_and_unsafe_permissions(self):
        routes, _ = self.install_synthetic_messaging()
        plugin = self.root.parent / "Copilot/plugin"
        for path in (plugin.parent, plugin, plugin / "skills", plugin / "skills/maestro",
                     plugin / "plugin.json", plugin / "skills/maestro/SKILL.md"):
            with self.subTest(path=path):
                permissions = path.stat().st_mode & 0o777
                path.chmod(0o777)
                with self.assertRaises(CONTROLLER["OrchestrationError"]):
                    self.run_mocked_launcher()
                path.chmod(permissions)
                saved = path.with_name(path.name + "-saved")
                path.rename(saved)
                path.symlink_to(saved, target_is_directory=saved.is_dir())
                try:
                    with self.assertRaises(CONTROLLER["OrchestrationError"]):
                        self.run_mocked_launcher()
                finally:
                    path.unlink()
                    saved.rename(path)
        self.assertEqual(list(routes.iterdir()), [])

    def test_managed_plugin_refuses_foreign_owner(self):
        self.install_synthetic_messaging()
        validate = CONTROLLER["managed_plugin_directory"]
        # Accept the configuration owner, then reject the plugin's parent owner.
        uid = os.getuid()
        with mock.patch("os.getuid", side_effect=[uid, uid + 1]):
            with self.assertRaises(CONTROLLER["OrchestrationError"]):
                validate(self.root)

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
        shutil.rmtree(self.root.parent / "Copilot")
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

    def test_missing_managed_plugin_fails_spawn_before_credentials_or_reservation(self):
        self.install_synthetic_messaging()
        plugin = self.root.parent / "Copilot/plugin"
        (plugin / "skills/maestro/SKILL.md").unlink()
        spawn = CONTROLLER["command_spawn"]
        args = CONTROLLER["parser"]().parse_args([
            "spawn", "--actor-id", str(uuid.uuid4()), "--token", "synthetic",
            "--name", "Managed", "--task", "test", "--cwd", self.paths["a"],
        ])
        forbidden = mock.Mock(side_effect=AssertionError("must refuse before launch side effects"))
        cmux = mock.Mock()
        with mock.patch.dict(spawn.__globals__, {
            "read_state": lambda _: {}, "authorize": lambda *a: {"role": "coordinator"},
            "git_display_metadata": lambda _: {},
            "worker_launch_settings": forbidden, "resolve_copilot_token": forbidden, "mutate": forbidden,
        }):
            with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "Managed skills"):
                spawn(args, self.root, cmux)
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
            snapshot["launches"][self.node["id"]] = {"runId": actor["runId"]}
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
        self.assertEqual(worker["messaging"], "participating")
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
            ("surfaceId", str(uuid.uuid4())), ("phase", "launching"),
        ):
            with self.subTest(field=field):
                snapshot = copy.deepcopy(state)
                snapshot["nodes"][self.node["id"]][field] = old
                _, retire = self.status_interleaving(state, actor, snapshot, process_start=lambda _: None)
                retire.assert_not_called()
                self.assertEqual(self.node["phase"], "turn-running")
                self.assertTrue(self.route_path().exists())
        state["launches"][self.node["id"]] = {"runId": actor["runId"]}
        _, retire = self.status_interleaving(
            state, actor, copy.deepcopy(state), process_start=lambda _: None,
        )
        retire.assert_not_called()
        self.assertEqual(self.node["phase"], "turn-running")

    def test_status_rechecks_exit_at_cleanup_boundary(self):
        state, actor = self.lifecycle_state()
        # The first observation misses both processes; the boundary sees the provider live.
        starts = mock.Mock(side_effect=[None, None, None, "provider-start", None, "provider-start"])
        _, retire = self.status_interleaving(state, actor, copy.deepcopy(state), process_start=starts)
        retire.assert_not_called()
        self.assertEqual(self.node["phase"], "turn-running")
        self.assertTrue(self.route_path().exists())

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
        self.assertEqual(args.count("--plugin-dir"), 1)
        self.assertEqual(args[args.index("--plugin-dir") + 1], str(self.root.parent / "Copilot/plugin"))
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


class LifecycleFailureTests(unittest.TestCase):
    """No provider, filesystem routes, credentials, or installed state."""

    def setUp(self):
        self.root = REPO / "unused-mocked-control-root"
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
        with mock.patch.dict(spawn.__globals__, {
            "read_state": lambda *a, **k: copy.deepcopy(self.state),
            "mutate": self.mutate, "messaging_configuration": lambda _: None,
            "worker_launch_settings": lambda _: {"version": 1},
            "resolve_copilot_token": lambda _: None,
            "git_display_metadata": lambda _: CONTROLLER["absent_git_metadata"](),
            "resource_observations": lambda *a: ({}, set()),
            "with_store": lambda *a, **k: None,
            "remove_launch_credential": lambda *a: None,
            "timeout": lambda *a: 1,
        }), mock.patch("time.monotonic", side_effect=[0, 2]):
            with self.assertRaises((RuntimeError, CONTROLLER["OrchestrationError"])):
                spawn(args, self.root, self.cmux)
        self.worker = next(node for node in self.state["nodes"].values() if node["role"] == "worker")
        self.state["nodes"][self.actor["id"]]["lastControlAt"] = "2000-01-01T00:00:00+00:00"
        self.cmux.validate_surface.side_effect = None
        self.assertTrue(self.worker["runtimeNotStarted"])
        self.assertFalse(self.worker["supervisor"])
        self.assertFalse(self.worker.get("providerProcess"))
        self.assertEqual(self.state["launches"], {})
        CONTROLLER["validate_state"](self.state)

    def test_surface_creation_failure_can_recover_without_anchors(self):
        self.failed_spawn("creation")
        self.assertIsNone(self.worker["surfaceId"])
        self.assertEqual(self.worker["phase"], "launch-failed")
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

    def test_startup_failure_cancels_unclaimed_lease_and_requires_surface_closure(self):
        self.failed_spawn("startup")
        self.assertEqual(self.worker["phase"], "startup-failed")
        self.cmux.surface_exists.return_value = True
        with self.assertRaisesRegex(CONTROLLER["OrchestrationError"], "live worker ownership"):
            self.recover()
        self.cmux.surface_exists.return_value = False
        self.assertEqual(self.recover()["recoveredRunId"], self.actor["runId"])

    def test_no_start_evidence_survives_resource_retirement_and_legacy_mode(self):
        self.failed_spawn("creation")
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

    def test_proven_surface_creation_failure_can_archive(self):
        self.failed_spawn("creation")
        self.assertTrue(self.archive()["archived"])
        self.assertEqual(self.state["nodes"], {})
        self.assertEqual(self.state["retainedResources"], [])

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


if __name__ == "__main__":
    unittest.main()
