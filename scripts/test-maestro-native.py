#!/usr/bin/env python3
"""Offline native protocol tests: no provider, terminal, keychain or user home."""
import copy
import base64
import datetime
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid


ROOT = Path(__file__).resolve().parents[1]
API = runpy.run_path(str(ROOT / "scripts/cmux-maestro-orchestrator.py"))
NATIVE = runpy.run_path(str(ROOT / "scripts/maestro_native.py"))
Native = NATIVE["NativeMessaging"]


def identifier():
    return str(uuid.uuid4())


class NativeTests(unittest.TestCase):
    def setUp(self):
        self.api = dict(API)
        self.api["process_matches"] = lambda _node: True
        self.api["native_bridge_caller_matches"] = lambda _node: True
        self.actor, self.token = API["new_root"](identifier(), identifier(), identifier(), "Coordinator")
        self.child = copy.deepcopy(self.actor)
        self.child.update(id=identifier(), role="worker", parentId=self.actor["id"],
                          copilotSessionId=identifier(), generation=1,
                          surfaceId=identifier(), executionMode="interactive",
                          providerProcess={"pid": 1, "start": "offline fixture"},
                          phase="turn-running", availability="busy",
                          nativeMessaging={"version": 1, "credentialHash": API["token_hash"]("b" * 64),
                                           "registration": None, "heartbeat": None, "ready": False,
                                           "closed": False})
        self.state = API["empty_state"]()
        self.state["nodes"] = {node["id"]: node for node in (self.actor, self.child)}
        self.api["mutate"] = self.mutate
        self.native = Native(self.api)
        self.registration = identifier()
        self.bridge("register")
        self.bridge("ready")

    def mutate(self, _root, operation):
        candidate = copy.deepcopy(self.state)
        result = operation(candidate)
        API["validate_state"](candidate)
        self.state = candidate
        return copy.deepcopy(result)

    def command(self, operation, **fields):
        return self.native.command(ROOT, {
            "version": 1, "operation": operation, "actorId": self.actor["id"], "token": self.token,
            "receiver": self.native.identity(self.child), **fields,
        })

    def send(self, key="one", body="Bounded follow-up", **fields):
        return self.command("send", key=key, body=body, ttlSeconds=60, **fields)["message"]

    def bridge(self, operation, **fields):
        return self.native.bridge(ROOT, {
            "version": 1, "operation": operation, "identity": self.native.identity(self.child),
            "credential": "b" * 64, "registration": self.registration, **fields,
        })

    def test_explicit_delivery_ack_reply_not_completion(self):
        message = self.send()
        self.assertEqual(self.bridge("poll")["message"]["id"], message["id"])
        delivered = self.bridge("delivered", messageId=message["id"], providerMessageId="provider-1")
        self.assertEqual(delivered["message"]["state"], "delivered")
        ack = self.bridge("acknowledge", messageId=message["id"])
        self.assertEqual(ack["message"]["state"], "acknowledged")
        reply = self.bridge("reply", messageId=message["id"], body="Tests passed; task complete.")
        self.assertEqual(reply["message"]["state"], "replied")
        self.assertEqual(self.state["nodes"][self.child["id"]]["phase"], "turn-running")
        self.assertEqual(self.command("read")["messages"][0]["reply"], "Tests passed; task complete.")

    def test_duplicate_body_and_identity_are_checked(self):
        first = self.send()
        self.assertEqual(self.send()["id"], first["id"])
        with self.assertRaises(API["OrchestrationError"]):
            self.send(body="Different")
        with self.assertRaises(API["OrchestrationError"]):
            self.command("send", key="two", body="body", ttlSeconds=60,
                         receiver={**self.native.identity(self.child), "generation": 2})

    def test_unknown_blocks_pair_without_resend(self):
        first = self.send()
        self.send(key="two")
        self.bridge("poll")
        self.bridge("unknown", messageId=first["id"])
        self.assertIsNone(self.bridge("poll")["message"])
        self.assertEqual(self.send()["state"], "unknown")
        self.bridge("acknowledge", messageId=first["id"])
        self.assertEqual(self.bridge("poll")["message"]["key"], "two")

    def test_expiry_before_claim_and_uncertain_expiry(self):
        first = self.send()
        self.bridge("poll")
        self.send(key="two")
        future = API["now_date"]() + datetime.timedelta(seconds=61)
        self.api["now_date"] = lambda: future
        messages = self.command("read")["messages"]
        self.assertEqual([item["state"] for item in messages], ["unknown", "expired"])
        self.assertEqual(self.send()["id"], first["id"])

    def test_retention_is_bounded_and_declared(self):
        for number in range(64):
            self.send(key=str(number))
        with self.assertRaises(API["OrchestrationError"]):
            self.send(key="overflow")
        self.api["now_date"] = lambda: API["now_date"]() + datetime.timedelta(days=2)
        self.api["mutate"] = lambda _root, operation: operation(self.state)
        retained = self.command("read")["messages"]
        self.assertEqual(len(retained), 64)
        self.assertTrue(all(item["body"] is None for item in retained))
        self.assertEqual(self.send(key="0")["id"], retained[0]["id"])
        self.native.validate(self.state)

    def test_credential_and_registration_do_not_grant_other_identities(self):
        for fields in ({"credential": "c" * 64},
                       {"identity": {**self.native.identity(self.child), "sessionId": identifier()}},
                       {"registration": identifier()}):
            with self.assertRaises(API["OrchestrationError"]):
                self.bridge("poll", **fields)
        with self.assertRaises(API["OrchestrationError"]):
            self.bridge("register", registration=identifier())
        with self.assertRaises(API["OrchestrationError"]):
            self.command("capabilities", token="not-the-token")

    def test_unsupported_legacy_and_wrong_version(self):
        self.state["nodes"][self.child["id"]].pop("nativeMessaging")
        self.assertEqual(self.command("capabilities")["status"], "unsupported")
        with self.assertRaises(API["OrchestrationError"]):
            self.command("capabilities", version=2)
        for fields in ({"version": True}, {"token": {}}, {"receiver": []}):
            with self.assertRaises(API["OrchestrationError"]):
                self.command("capabilities", **fields)
        with self.assertRaises(API["OrchestrationError"]):
            self.command([])
        with self.assertRaises(API["OrchestrationError"]):
            self.bridge("poll", identity={"nodeId": []})

    def test_utf8_bounds_reply_conflict_and_no_observer_leak(self):
        with self.assertRaises(API["OrchestrationError"]):
            self.send(body="🟢" * 1025)
        first = self.send(body="private message marker")
        self.bridge("poll")
        self.bridge("reply", messageId=first["id"], body="private reply marker")
        with self.assertRaises(API["OrchestrationError"]):
            self.bridge("reply", messageId=first["id"], body="changed")
        projection = API["Store"](ROOT)._projection(self.state).decode()
        for private in ("private message marker", "private reply marker", "credentialHash", "nativeMessaging"):
            self.assertNotIn(private, projection)

    def test_one_time_authorization_and_changed_parent(self):
        request = {
            "requestId": identifier(), "actor": self.native.identity(self.actor),
            "parentToolPolicy": self.actor["toolPolicy"],
            "expiresAt": (API["now_date"]() + datetime.timedelta(minutes=10)).isoformat(),
        }
        self.native.consume_authorization(self.state, request, self.actor)
        with self.assertRaises(API["OrchestrationError"]):
            self.native.consume_authorization(self.state, request, self.actor)
        request["requestId"] = identifier()
        changed = {**self.actor, "toolPolicy": {"allow": [], "deny": ["write"]}}
        with self.assertRaises(API["OrchestrationError"]):
            self.native.consume_authorization(self.state, request, changed)

    def test_malformed_records_fail_closed(self):
        self.send()
        for mutate in (lambda record: record.update(state="complete"),
                       lambda record: record.update(state=[]),
                       lambda record: record.update(secret="not allowed"),
                       lambda record: record.update(body=[]),
                       lambda record: record.update(expiresAt="2026-09-20T12:00:00"),
                       lambda record: record.update(bodyHash="0" * 64)):
            state = copy.deepcopy(self.state)
            mutate(state["nativeMessages"][0])
            with self.assertRaises(API["OrchestrationError"]):
                self.native.validate(state)

    def test_peer_and_private_token_alone_do_not_authorize_bridge(self):
        self.api["native_bridge_caller_matches"] = lambda _node: False
        with self.assertRaisesRegex(API["OrchestrationError"], "exact bound provider"):
            self.bridge("poll")
        with self.assertRaises(API["OrchestrationError"]):
            self.command("capabilities", receiver=self.native.identity(self.actor))

    def test_registration_alone_is_not_delivery_capability(self):
        self.state["nodes"][self.child["id"]]["nativeMessaging"]["ready"] = False
        self.assertEqual(self.command("capabilities")["status"], "unsupported")
        with self.assertRaises(API["OrchestrationError"]):
            self.bridge("poll")
        self.bridge("ready")
        self.assertEqual(self.command("capabilities")["status"], "supported")
        self.bridge("close")
        self.assertEqual(self.command("capabilities")["status"], "unsupported")
        for operation in ("ready", "register"):
            with self.assertRaises(API["OrchestrationError"]):
                self.bridge(operation)

    def test_private_store_rejects_symlink_and_public_mode(self):
        parent = ROOT / ".build"
        parent.mkdir(exist_ok=True)
        root = parent / ("native-storage-" + identifier())
        try:
            with API["Store"](root) as store:
                store.write(self.state)
            path = root / "control/state.json"
            path.chmod(0o644)
            with self.assertRaises(API["OrchestrationError"]):
                API["read_state"](root)
            path.chmod(0o600)
            saved = path.with_name("saved-state.json")
            path.rename(saved)
            path.symlink_to(saved)
            with self.assertRaises((OSError, API["OrchestrationError"])):
                API["read_state"](root)
            path.unlink()
            os.mkfifo(path, 0o600)
            with self.assertRaises(API["OrchestrationError"]):
                API["read_state"](root)
        finally:
            if root.exists():
                shutil.rmtree(root)

    def test_signed_request_verification_covers_target_and_policy(self):
        request_id = identifier()
        settings = {"version": 1, "copilotAccount": "example-user", "model": "example-model"}
        args = SimpleNamespace(native_request=request_id, name="Worker", task="Bounded task",
                               actor_id=self.actor["id"], token=self.token)
        setup_id = identifier()
        timestamp = API["now_date"]()
        request = {
            "version": 2, "requestId": request_id, "actor": self.native.identity(self.actor),
            "approvalScope": "run-policy", "disclosure": NATIVE["POLICY_DISCLOSURE"], "policyGrantId": None,
            "parentToolPolicy": self.actor["toolPolicy"], "workerId": identifier(),
            "sessionId": identifier(), "launchSettings": settings,
            "workerGeneration": 1,
            "toolPolicy": {"allow": [], "deny": ["web"]}, "cwd": str(ROOT),
            "name": args.name, "task": args.task, "mode": "interactive-exact-tools",
            "parentPolicy": "unknown-human-fallback", "createdAt": timestamp.isoformat(),
            "expiresAt": (timestamp + datetime.timedelta(minutes=10)).isoformat(),
        }
        request["policyScope"] = self.native.policy_scope(
            self.state, self.actor, settings, request["toolPolicy"], ROOT, setup_id)
        raw = json.dumps(request).encode()
        receipt = json.dumps({"request": base64.b64encode(raw).decode(), "signature": "test-double"}).encode()
        files = {
            f"native-request-{request_id}.json": raw,
            f"native-approval-{request_id}.json": receipt,
            "native-setup.json": json.dumps({"version": 1, "verifier": "/offline/verifier", "setupId": setup_id}).encode(),
            "worker-settings.json": json.dumps(settings).encode(),
        }
        store = SimpleNamespace(root_fd=0, read=lambda: self.state,
                                _read_regular=lambda name, *_args, **_kwargs: files.get(name))
        self.api["with_store"] = lambda _root, operation, **_kwargs: operation(store)
        self.api["trusted_executable"] = lambda variable, fallback: fallback if variable is None else self.fail("override")
        def verify(command, **kwargs):
            return SimpleNamespace(returncode=0, stdout=b'{"supported":true}' if
                                   command[-1] == "--maestro-native-readiness" else b'{"valid":true}')
        with patch.object(subprocess, "run", side_effect=verify) as run:
            accepted = self.native.authorized_launch(args, ROOT, self.actor, settings, request["toolPolicy"], ROOT)
            self.assertEqual(accepted["workerId"], request["workerId"])
            self.assertEqual(run.call_args.kwargs["input"], receipt)
            self.assertNotIn(receipt.decode(), str(run.call_args.args))
            args.task = "Changed target"
            with self.assertRaises(API["OrchestrationError"]):
                self.native.authorized_launch(args, ROOT, self.actor, settings, request["toolPolicy"], ROOT)
        args.task = request["task"]
        def reject(command, **kwargs):
            return verify(command) if command[-1] == "--maestro-native-readiness" else SimpleNamespace(
                returncode=2, stdout=b'{"valid":false}')
        with patch.object(subprocess, "run", side_effect=reject):
            with self.assertRaisesRegex(API["OrchestrationError"], "signature"):
                self.native.authorized_launch(args, ROOT, self.actor, settings, request["toolPolicy"], ROOT)

    def test_unqualified_app_blocks_preparation_and_launch_without_writes(self):
        store = SimpleNamespace(root_fd=0, _read_regular=lambda *_args, **_kwargs:
                                json.dumps({"version": 1, "verifier": "/offline/verifier", "setupId": identifier()}).encode())
        self.api["with_store"] = lambda _root, operation, **_kwargs: operation(store)
        self.api["trusted_executable"] = lambda _variable, fallback: fallback
        for response in (b'{"supported":false}', b'{"supported":true,"override":true}', b''):
            with patch.object(subprocess, "run", return_value=SimpleNamespace(
                returncode=0, stdout=response
            )) as run:
                for operation in (self.native.launch_request, self.native.authorized_launch):
                    with self.assertRaisesRegex(API["OrchestrationError"], "unsupported"):
                        operation(None, ROOT, self.actor, {}, {}, ROOT)
                self.assertEqual(run.call_args.args[0], ["/offline/verifier", "--maestro-native-readiness"])
                self.assertNotIn("input", run.call_args.kwargs)
        store._read_regular = lambda *_args, **_kwargs: None
        with patch.object(subprocess, "run") as run:
            with self.assertRaisesRegex(API["OrchestrationError"], "unsupported"):
                self.native.launch_request(None, ROOT, self.actor, {}, {}, ROOT)
            run.assert_not_called()

    def test_provider_parent_check_is_additional_not_inferred_identity(self):
        check = API["native_bridge_caller_matches"]
        start = "Sun Sep 20 00:00:00 2026"
        processes = {
            42: {"parent": 1, "start": start, "executable": "/usr/bin/node"},
            44: {"parent": 42, "start": start, "executable": "/packaged/copilot"},
            45: {"parent": 44, "start": start, "executable": "/usr/bin/node"},
        }
        node = {"providerProcess": {"pid": 42, "start": start}}
        with patch.dict(check.__globals__, {"native_process_identity": lambda pid: copy.deepcopy(processes.get(pid))}):
            with patch.object(os, "getppid", return_value=45):
                self.assertTrue(check(node))
                processes[45]["parent"] = 42
                self.assertTrue(check(node))
                processes[45]["parent"] = 44
                for changed in ({"parent": 40}, {"executable": "/unrelated/node"},
                                {"start": "Sat Sep 19 00:00:00 2026"}):
                    with patch.dict(processes[44], changed):
                        self.assertFalse(check(node))
                self.assertFalse(check({"providerProcess": {"pid": 42, "start": "stale"}}))
                self.assertFalse(check({"providerProcess": {"pid": 43, "start": start}}))
                self.assertFalse(check({}))
                processes[46] = {**processes[44], "parent": 44}
                processes[45]["parent"] = 46
                self.assertFalse(check(node))  # No third ancestry edge.
                processes[45]["parent"] = 44
                def reparent(pid):
                    value = copy.deepcopy(processes.get(pid))
                    if pid == 42:
                        processes[45]["parent"] = 1
                    return value
                with patch.dict(check.__globals__, {"native_process_identity": reparent}):
                    self.assertFalse(check(node))
                processes[45]["parent"] = 44
                samples = {}
                def reused_pid(pid):
                    value = copy.deepcopy(processes.get(pid))
                    samples[pid] = samples.get(pid, 0) + 1
                    if pid == 42 and samples[pid] > 1:
                        value["start"] = "Sun Sep 20 00:00:01 2026"
                    return value
                with patch.dict(check.__globals__, {"native_process_identity": reused_pid}):
                    self.assertFalse(check(node))
            with patch.object(os, "getppid", side_effect=[45, 1]):
                self.assertFalse(check(node))

    def test_native_process_snapshot_parsing_fails_closed(self):
        read = API["native_process_identity"]
        for result, expected in (
            (SimpleNamespace(returncode=0, stdout="42 Sun Sep 20 00:00:00 2026 /a path/copilot\n"),
             {"parent": 42, "start": "Sun Sep 20 00:00:00 2026", "executable": "/a path/copilot"}),
            (SimpleNamespace(returncode=0, stdout=""), None),
            (SimpleNamespace(returncode=1, stdout="42 Sun Sep 20 00:00:00 2026 /copilot"), None),
            (SimpleNamespace(returncode=0, stdout="invalid Sun Sep 20 00:00:00 2026 /copilot"), None),
        ):
            with patch.object(subprocess, "run", return_value=result):
                self.assertEqual(read(44), expected)
        with patch.object(subprocess, "run", side_effect=subprocess.TimeoutExpired("ps", 2)):
            self.assertIsNone(read(44))

    def test_native_binding_capture_and_every_resample_use_c_locale_and_utc(self):
        run = API["run_interactive_session"]
        check = API["native_bridge_caller_matches"]
        start = "Sun Sep 20 00:00:00 2026"
        process = SimpleNamespace(pid=42, poll=lambda: 0, wait=lambda: 0)
        node = {**self.child, "task": "Bounded", "workingDirectory": str(ROOT)}
        processes = {42: (1, "/usr/bin/node"), 44: (42, "/packaged/copilot"),
                     45: (44, "/usr/bin/node")}
        calls = []
        def ps(command, **kwargs):
            environment = kwargs["env"]
            for key in ("LC_ALL", "LC_TIME", "LANG"):
                self.assertEqual(environment[key], "C")
            self.assertEqual(environment["TZ"], "UTC0")
            pid = int(command[command.index("-p") + 1])
            calls.append(pid)
            parent, executable = processes[pid]
            return SimpleNamespace(returncode=0, stdout=f"{parent} {start} {executable}\n")
        replacements = {
            "trusted_executable": lambda *_: "/offline/copilot",
            "worker_environment": lambda *_: {},
            "mutate": lambda root, operation, **_kwargs: self.mutate(root, operation),
        }
        # No installed French locale is needed: ps's explicit subprocess environment is the protocol.
        for caller in ({"LC_ALL": "fr_FR.UTF-8", "LC_TIME": "fr_FR.UTF-8", "TZ": "Europe/Paris"},
                       {"LC_ALL": "C", "LC_TIME": "C", "TZ": "America/Los_Angeles"}):
            with self.subTest(caller=caller), patch.dict(os.environ, caller):
                with patch.dict(run.__globals__, replacements), patch.object(os, "isatty", return_value=True):
                    with patch.object(subprocess, "Popen", return_value=process), patch.object(subprocess, "run", side_effect=ps):
                        self.state["nodes"][node["id"]].update(phase="turn-running", availability="busy")
                        run(ROOT, node["id"], self.token, node)
                bound = self.state["nodes"][node["id"]]
                self.assertEqual(bound["providerProcess"], {
                    "pid": 42, "start": "2026-09-20T00:00:00Z", "startFormat": "ps-c-utc-v1",
                })
                projection = API["Store"](ROOT)._projection(self.state).decode()
                self.assertNotIn("startFormat", projection)
                self.assertNotIn("2026-09-20T00:00:00Z", projection)
                for bridge_environment in ({"HOME": "/offline", "PATH": "/usr/bin:/bin"},
                                           {"LC_ALL": "fr_FR.UTF-8", "TZ": "Pacific/Auckland"}):
                    calls.clear()
                    with patch.dict(os.environ, bridge_environment, clear=True):
                        with patch.object(subprocess, "run", side_effect=ps), patch.object(os, "getppid", return_value=45):
                            self.assertTrue(check(bound))
                            self.assertEqual(calls, [45, 44, 42, 45, 44, 42])
                            self.assertTrue(API["process_matches"](bound))

    def test_canonical_process_stamps_and_legacy_liveness_are_not_interchangeable(self):
        read = API["native_process_identity"]
        for text in ("dim. sept. 20 00:00:00 2026", "Sun Sep 31 00:00:00 2026",
                     "Mon Sep 20 00:00:00 2026", "unparsed", "Sun Sep 20 25:00:00 2026"):
            with self.subTest(text=text), patch.object(subprocess, "run", return_value=SimpleNamespace(
                returncode=0, stdout=f"1 {text} /copilot",
            )):
                self.assertIsNone(read(42, canonical=True))
        matches = API["process_matches"]
        legacy = "dim. 20 sept. 2026 02:00:00"
        canonical = {"pid": 42, "start": "2026-09-20T00:00:00Z", "startFormat": "ps-c-utc-v1"}
        def ps(command, **kwargs):
            if "env" in kwargs:
                return SimpleNamespace(returncode=0, stdout="1 Sun Sep 20 00:00:00 2026 /copilot")
            return SimpleNamespace(returncode=0, stdout=legacy)
        with patch.object(subprocess, "run", side_effect=ps):
            for field in ("supervisor", "providerProcess"):
                self.assertTrue(matches({field: {"pid": 42, "start": legacy}}))
                self.assertFalse(matches({field: {"pid": 42, "start": "Sun Sep 20 00:00:00 2026"}}))
            self.assertTrue(matches({"providerProcess": canonical}))
            for changed in ({"start": legacy}, {"start": "2026-09-20T00:00:01Z"},
                            {"startFormat": "unknown"}):
                self.assertFalse(matches({"providerProcess": {**canonical, **changed}}))
        for changed in ({"start": legacy}, {"start": "2026-09-31T00:00:00Z"},
                        {"startFormat": "unknown"}):
            state = copy.deepcopy(self.state)
            state["nodes"][self.child["id"]]["providerProcess"] = {**canonical, **changed}
            with self.assertRaises(API["OrchestrationError"]):
                API["validate_state"](state)

    def test_canonical_native_chain_keeps_bounded_topology_and_second_sample_checks(self):
        check = API["native_bridge_caller_matches"]
        start = "2026-09-20T00:00:00Z"
        processes = {
            42: {"parent": 1, "start": start, "executable": "/usr/bin/node"},
            44: {"parent": 42, "start": start, "executable": "/packaged/copilot"},
            45: {"parent": 44, "start": start, "executable": "/usr/bin/node"},
        }
        node = {"providerProcess": {"pid": 42, "start": start, "startFormat": "ps-c-utc-v1"}}
        def sample(pid, *, canonical):
            self.assertTrue(canonical)
            return copy.deepcopy(processes.get(pid))
        with patch.dict(check.__globals__, {"native_process_identity": sample}), patch.object(os, "getppid", return_value=45):
            self.assertTrue(check(node))
            with patch.dict(processes[45], {"parent": 42}):
                self.assertTrue(check(node))
            for pid, changed in (
                (44, {"parent": 1}), (44, {"executable": "/unrelated/node"}),
                (44, {"start": "2026-09-19T23:59:59Z"}), (45, {"start": "not parsed"}),
                (42, {"start": "2026-09-20T00:00:01Z"}), (45, {"parent": 46}),
            ):
                processes[46] = {**processes[44], "parent": 44}
                with self.subTest(pid=pid, changed=changed), patch.dict(processes[pid], changed):
                    self.assertFalse(check(node))
            for pid, changed in ((45, {"parent": 1}), (44, {"parent": 1}),
                                 (42, {"start": "2026-09-20T00:00:01Z"})):
                counts = {}
                def changed_sample(sample_pid, *, canonical):
                    result = sample(sample_pid, canonical=canonical)
                    counts[sample_pid] = counts.get(sample_pid, 0) + 1
                    if sample_pid == pid and counts[sample_pid] > 1:
                        result.update(changed)
                    return result
                with patch.dict(check.__globals__, {"native_process_identity": changed_sample}):
                    self.assertFalse(check(node))
            with patch.object(os, "getppid", side_effect=[45, 1]):
                self.assertFalse(check(node))

    def test_runtime_exit_checks_versioned_provider_without_reinterpreting_legacy_anchors(self):
        runtime = API["command_runtime"]
        legacy = "dim. 20 sept. 2026 02:00:00"
        for canonical in (False, True):
            for live in (False, True):
                with self.subTest(canonical=canonical, live=live):
                    state = copy.deepcopy(self.state)
                    node = state["nodes"][self.child["id"]]
                    node.update(phase="launching", availability="busy", providerProcess=None)
                    state["launches"][node["id"]] = {
                        "workerId": node["id"], "runId": node["runId"], "workspaceId": node["workspaceId"],
                        "surfaceId": node["surfaceId"], "state": "starting",
                        "createdAt": API["now"](), "updatedAt": API["now"](),
                    }
                    self.state = state
                    anchor = {"pid": 42, "start": "2026-09-20T00:00:00Z" if canonical else legacy}
                    if canonical:
                        anchor["startFormat"] = "ps-c-utc-v1"
                    def interrupted(*_args):
                        self.mutate(ROOT, lambda stored: stored["nodes"][node["id"]].update(providerProcess=anchor))
                        raise API["OrchestrationError"]("offline interrupted runtime")
                    replacements = {
                        "process_start": lambda pid: legacy if pid != 42 or live else "stale",
                        "native_process_identity": lambda pid, **kwargs: {
                            "start": "2026-09-20T00:00:00Z" if live else "2026-09-20T00:00:01Z"},
                        "read_state": lambda *_args, **_kwargs: copy.deepcopy(self.state),
                        "mutate": lambda root, operation, **_kwargs: self.mutate(root, operation),
                        "require_current_surface": lambda *_: None,
                        "remove_launch_credential": lambda *_: None,
                        "run_interactive_session": interrupted,
                    }
                    with patch.dict(runtime.__globals__, replacements), patch.object(signal, "signal"):
                        with self.assertRaisesRegex(API["OrchestrationError"], "offline interrupted"):
                            runtime(SimpleNamespace(worker_id=node["id"], token=self.token), ROOT)
                    remaining = self.state["nodes"][node["id"]]
                    self.assertEqual(remaining["phase"], "turn-running" if live else "turn-failed")
                    self.assertEqual(remaining["providerProcess"], anchor)
                    if live:
                        self.assertIn("remains live", remaining["result"])

    def test_native_launch_never_adopts_an_existing_identity(self):
        settings = {"version": 1, "copilotAccount": "example-user", "model": "example-model"}
        args = SimpleNamespace(
            command="spawn", actor_id=self.actor["id"], token=self.token, name="Native",
            task="Bounded task", cwd=str(ROOT), allow_tool=[], deny_tool=[],
            require_pinned_launch_settings=True, native_request=identifier(), icon=None, color=None,
        )
        request = {
            "requestId": args.native_request, "actor": self.native.identity(self.actor),
            "parentToolPolicy": self.actor["toolPolicy"], "workerId": self.child["id"],
            "sessionId": self.child["copilotSessionId"],
            "expiresAt": (API["now_date"]() + datetime.timedelta(minutes=10)).isoformat(),
        }
        native = SimpleNamespace(authorized_launch=lambda *_: request,
                                 consume_authorization=self.native.consume_authorization,
                                 check_launch_snapshot=lambda *_: None)
        spawn = API["command_spawn"]
        replacements = {
            "read_state": lambda *_: self.state,
            "worker_launch_settings": lambda *_: settings,
            "resolve_copilot_token": lambda *_: None,
            "native_messaging": lambda: native,
            "resource_observations": lambda *_: ({}, []),
            "git_display_metadata": lambda *_: API["absent_git_metadata"](),
            "mutate": self.mutate,
            "with_store": lambda _root, operation: operation(SimpleNamespace(read=lambda: copy.deepcopy(self.state))),
        }
        with patch.dict(spawn.__globals__, replacements):
            with patch.object(os.path, "lexists", return_value=True):
                for reuse_worker in (True, False):
                    if not reuse_worker:
                        request["workerId"], request["sessionId"] = identifier(), identifier()
                    with self.assertRaisesRegex(API["OrchestrationError"], "new, unowned"):
                        spawn(args, ROOT, SimpleNamespace(validate_surface=lambda *_: self.actor["paneId"]))
        self.assertEqual(len(self.state["nodes"]), 2)
        self.assertNotIn("nativeAuthorizations", self.state)

    def policy_fixture(self):
        root = ROOT / ".build" / ("native-policy-" + identifier())
        root.parent.mkdir(exist_ok=True)
        self.addCleanup(lambda: shutil.rmtree(root))
        self.settings = {"version": 1, "copilotAccount": "example-user", "model": "example-model"}
        self.policy = {"allow": ["read"], "deny": ["web"]}
        self.setup_value = {"version": 1, "verifier": "/offline/verifier", "setupId": identifier()}
        self.args = SimpleNamespace(actor_id=self.actor["id"], token=self.token,
                                    name="First", task="First bounded task", native_request=None)
        with API["Store"](root) as store:
            store.write(self.state)
            for name, value in (("native-setup.json", self.setup_value), ("worker-settings.json", self.settings)):
                store._atomic(store.root_fd, name, json.dumps(value).encode())
        self.api["with_store"] = API["with_store"]
        self.api["trusted_executable"] = lambda _variable, fallback: fallback
        def verify(command, **_kwargs):
            self.assertEqual(command[0], "/offline/verifier")
            return SimpleNamespace(returncode=0, stdout=b'{"supported":true}' if
                                   command[-1] == "--maestro-native-readiness" else b'{"valid":true}')
        verifier = patch.object(subprocess, "run", side_effect=verify)
        self.verifier = verifier.start()
        self.addCleanup(verifier.stop)
        return root

    def prepare_policy(self, root):
        state = API["read_state"](root)
        actor = state["nodes"][self.args.actor_id]
        result = self.native.launch_request(self.args, root, actor, self.settings, self.policy, ROOT)
        self.args.native_request = result["requestId"]
        return result

    def sign_policy(self, root):
        def write(store):
            raw = store._read_regular(f"native-request-{self.args.native_request}.json", 49152, private=True)
            store._atomic(store.control_fd, f"native-approval-{self.args.native_request}.json",
                          json.dumps({"request": base64.b64encode(raw).decode(), "signature": "offline-double"}).encode())
        API["with_store"](root, write)

    def admit_policy(self, root):
        actor = API["read_state"](root)["nodes"][self.args.actor_id]
        request = self.native.authorized_launch(self.args, root, actor, self.settings, self.policy, ROOT)
        def consume(store):
            state = store.read()
            self.native.check_launch_snapshot(store, request)
            self.native.consume_authorization(state, request, state["nodes"][self.args.actor_id])
            store.write(state)
        API["with_store"](root, consume)
        return request

    def test_run_policy_requires_first_signature_then_distinct_one_time_tickets(self):
        root = self.policy_fixture()
        self.assertEqual(self.prepare_policy(root)["status"], "human-authorization-required")
        with self.assertRaisesRegex(API["OrchestrationError"], "genuine human authorization"):
            self.admit_policy(root)
        self.sign_policy(root)
        first = self.admit_policy(root)
        with self.assertRaisesRegex(API["OrchestrationError"], "already been consumed"):
            self.admit_policy(root)
        self.args.name, self.args.task = "Second", "Different bounded task"
        self.assertEqual(self.prepare_policy(root)["status"], "reuse-ready")
        second = self.admit_policy(root)
        for field in ("requestId", "workerId", "sessionId"):
            self.assertNotEqual(first[field], second[field])
        self.assertEqual(second["policyGrantId"], first["requestId"])
        self.assertEqual(sum(call.args[0][-1] == "--maestro-verify-native-authorization"
                             for call in self.verifier.call_args_list), 1)
        with self.assertRaisesRegex(API["OrchestrationError"], "already been consumed"):
            self.admit_policy(root)
        state = API["read_state"](root)
        self.assertEqual(len(state["nativePolicyGrants"]), 1)
        self.assertEqual(len(state["nativeAuthorizations"]), 2)
        projection = API["Store"](root)._projection(state).decode()
        for private in ("nativePolicyGrants", "policyScope", "example-model", "actorAuthority", "First bounded task"):
            self.assertNotIn(private, projection)

    def test_policy_mismatches_need_new_consent(self):
        root = self.policy_fixture()
        self.prepare_policy(root)
        self.sign_policy(root)
        first = self.admit_policy(root)
        baseline = API["read_state"](root)
        for field in ("account", "model", "cwd", "policy", "owner", "workspace", "run", "parent", "setup"):
            with self.subTest(field=field):
                state = copy.deepcopy(baseline)
                args = copy.copy(self.args)
                settings, policy = copy.deepcopy(self.settings), copy.deepcopy(self.policy)
                setup = copy.deepcopy(self.setup_value)
                cwd = ROOT
                if field == "account":
                    settings["copilotAccount"] = "other-user"
                elif field == "model":
                    settings["model"] = "other-model"
                elif field == "cwd":
                    cwd = ROOT / "scripts"
                elif field == "policy":
                    policy["deny"].append("write")
                elif field == "owner":
                    args.token = "new-owner"
                    state["nodes"][self.actor["id"]]["tokenHash"] = API["token_hash"](args.token)
                elif field in {"workspace", "run"}:
                    key = "workspaceId" if field == "workspace" else "runId"
                    value = identifier()
                    for node in state["nodes"].values():
                        node[key] = value
                elif field == "parent":
                    state["nodes"][self.actor["id"]]["toolPolicy"]["deny"] = ["write"]
                elif field == "setup":
                    setup["setupId"] = identifier()
                with API["Store"](root) as store:
                    store.write(state)
                    store._atomic(store.root_fd, "worker-settings.json", json.dumps(settings).encode())
                    store._atomic(store.root_fd, "native-setup.json", json.dumps(setup).encode())
                actor = state["nodes"][self.actor["id"]]
                result = self.native.launch_request(args, root, actor, settings, policy, cwd)
                self.assertEqual(result["status"], "human-authorization-required")
                self.assertNotEqual(result["requestId"], first["requestId"])

    def test_fresh_activation_supersedes_prepared_scopes_and_refuses_old_reuse_tickets(self):
        for reverse in (False, True):
            with self.subTest(reverse=reverse):
                root = self.policy_fixture()
                other, other_token = self.child, self.token
                self.args.actor_id, self.args.token = other["id"], other_token
                self.prepare_policy(root)
                self.sign_policy(root)
                other_request = self.admit_policy(root)
                other_grant = API["read_state"](root)["nativePolicyGrants"][0]
                self.args.actor_id, self.args.token = self.actor["id"], self.token
                policies = [{"allow": ["read"], "deny": ["web"]},
                            {"allow": ["read"], "deny": ["web", "write"]}]
                tickets = []
                # Both signatures precede either activation.
                for policy in policies:
                    self.policy = policy
                    self.assertEqual(self.prepare_policy(root)["status"], "human-authorization-required")
                    self.sign_policy(root)
                    tickets.append(self.args.native_request)
                order = (1, 0) if reverse else (0, 1)
                self.policy, self.args.native_request = policies[order[0]], tickets[order[0]]
                self.admit_policy(root)
                self.assertEqual(self.prepare_policy(root)["status"], "reuse-ready")
                reuse_ticket = self.args.native_request
                reuse_request = self.native.authorized_launch(
                    self.args, root, self.actor, self.settings, self.policy, ROOT)
                self.policy, self.args.native_request = policies[order[1]], tickets[order[1]]
                self.admit_policy(root)
                state = API["read_state"](root)
                self.assertEqual(state["nativePolicyGrants"], [
                    other_grant, {"id": tickets[order[1]], "scope": self.native.policy_scope(
                        state, self.actor, self.settings, self.policy, ROOT, self.setup_value["setupId"])},
                ])
                self.policy, self.args.native_request = policies[order[0]], reuse_ticket
                with self.assertRaisesRegex(API["OrchestrationError"], "no longer active"):
                    self.admit_policy(root)
                # A reuse ticket which passed preflight before activation also fails at reservation.
                with self.assertRaisesRegex(API["OrchestrationError"], "no longer active"):
                    API["mutate"](root, lambda candidate: self.native.consume_authorization(
                        candidate, reuse_request, candidate["nodes"][self.actor["id"]]))
                self.assertEqual(API["read_state"](root), state)
                self.assertEqual(self.prepare_policy(root)["status"], "human-authorization-required")
                self.args.actor_id, self.args.token = other["id"], other_token
                self.policy = policies[0]
                self.assertEqual(self.prepare_policy(root)["status"], "reuse-ready")
                self.assertEqual(self.admit_policy(root)["policyGrantId"], other_request["requestId"])

    def test_same_scope_pending_signatures_keep_the_active_grant_and_reuse_ticket(self):
        root = self.policy_fixture()
        tickets = []
        for _ in range(2):
            self.prepare_policy(root)
            self.sign_policy(root)
            tickets.append(self.args.native_request)
        self.args.native_request = tickets[0]
        first = self.admit_policy(root)
        self.assertEqual(self.prepare_policy(root)["status"], "reuse-ready")
        reuse_ticket = self.args.native_request
        self.args.native_request = tickets[1]
        second = self.admit_policy(root)
        self.args.native_request = reuse_ticket
        reused = self.admit_policy(root)
        self.assertEqual(reused["policyGrantId"], first["requestId"])
        self.assertEqual(len(API["read_state"](root)["nativePolicyGrants"]), 1)
        for field in ("requestId", "workerId", "sessionId"):
            self.assertEqual(len({request[field] for request in (first, second, reused)}), 3)

    def test_rejected_reservation_does_not_supersede_or_consume(self):
        root = self.policy_fixture()
        tickets = []
        policies = [self.policy, {"allow": ["read"], "deny": ["web", "write"]}]
        for policy in policies:
            self.policy = policy
            self.prepare_policy(root)
            self.sign_policy(root)
            tickets.append(self.args.native_request)
        self.policy, self.args.native_request = policies[0], tickets[0]
        self.admit_policy(root)
        baseline = API["read_state"](root)
        self.policy, self.args.native_request = policies[1], tickets[1]
        args = SimpleNamespace(**vars(self.args), command="spawn", cwd=str(ROOT),
                               allow_tool=self.policy["allow"], deny_tool=self.policy["deny"],
                               require_pinned_launch_settings=True, icon=None, color=None)
        spawn = API["command_spawn"]
        with patch.dict(spawn.__globals__, {
            "native_messaging": lambda: self.native,
            "resolve_copilot_token": lambda *_: None,
            "git_display_metadata": lambda *_: API["absent_git_metadata"](),
            "resource_observations": lambda *_: ({}, []),
        }), patch.object(os.path, "lexists", return_value=True):
            with self.assertRaisesRegex(API["OrchestrationError"], "new, unowned"):
                spawn(args, root, SimpleNamespace(validate_surface=lambda *_: self.actor["paneId"]))
        self.assertEqual(API["read_state"](root), baseline)
        self.admit_policy(root)
        self.assertEqual(API["read_state"](root)["nativePolicyGrants"][0]["id"], tickets[1])

    def test_reuse_rechecks_live_scope_at_admission(self):
        root = self.policy_fixture()
        self.prepare_policy(root)
        self.sign_policy(root)
        self.admit_policy(root)
        self.prepare_policy(root)
        baseline = API["read_state"](root)
        for field in ("archiving", "stale", "owner", "generation", "grant"):
            with self.subTest(field=field):
                state = copy.deepcopy(baseline)
                actor = state["nodes"][self.actor["id"]]
                if field == "archiving":
                    actor["archiving"] = True
                elif field == "stale":
                    actor["lastControlAt"] = (API["now_date"]() - datetime.timedelta(minutes=11)).isoformat()
                elif field == "owner":
                    state["nativePolicyGrants"][0]["scope"]["actorAuthority"] = "0" * 64
                elif field == "generation":
                    state["nativePolicyGrants"][0]["scope"]["actor"]["generation"] += 1
                else:
                    state["nativePolicyGrants"] = []
                with API["Store"](root) as store:
                    store.write(state)
                with self.assertRaises(API["OrchestrationError"]):
                    self.admit_policy(root)

    def test_setup_disable_and_settings_race_block_prepared_ticket(self):
        root = self.policy_fixture()
        self.prepare_policy(root)
        self.sign_policy(root)
        self.admit_policy(root)
        self.prepare_policy(root)
        request = self.native.authorized_launch(self.args, root, self.actor, self.settings, self.policy, ROOT)
        with API["Store"](root) as store:
            store._atomic(store.root_fd, "worker-settings.json", json.dumps({**self.settings, "model": "changed"}).encode())
            with self.assertRaisesRegex(API["OrchestrationError"], "settings changed"):
                self.native.check_launch_snapshot(store, request)
        (root / "native-setup.json").unlink()
        with self.assertRaisesRegex(API["OrchestrationError"], "unsupported"):
            self.prepare_policy(root)
        with API["Store"](root) as store:
            store._atomic(store.root_fd, "worker-settings.json", json.dumps(self.settings).encode())
            store._atomic(store.root_fd, "native-setup.json", json.dumps({
                **self.setup_value, "setupId": identifier(),
            }).encode())
        self.assertEqual(self.prepare_policy(root)["status"], "human-authorization-required")

    def test_expired_pending_never_verified_but_active_grant_outlives_ticket(self):
        root = self.policy_fixture()
        self.prepare_policy(root)
        self.sign_policy(root)
        first = self.admit_policy(root)
        self.prepare_policy(root)
        future = API["now_date"]() + datetime.timedelta(minutes=11)
        self.api["now_date"] = lambda: future
        self.verifier.reset_mock()
        with self.assertRaisesRegex(API["OrchestrationError"], "expired"):
            self.admit_policy(root)
        self.assertFalse(any(call.args[0][-1] == "--maestro-verify-native-authorization"
                             for call in self.verifier.call_args_list))
        API["mutate"](root, lambda state: state["nodes"][self.actor["id"]].update(lastControlAt=future.isoformat()))
        self.assertEqual(self.prepare_policy(root)["status"], "reuse-ready")
        self.assertEqual(self.admit_policy(root)["policyGrantId"], first["requestId"])

    def test_legacy_one_worker_request_is_never_promoted(self):
        root = self.policy_fixture()
        self.prepare_policy(root)
        path = root / "control" / f"native-request-{self.args.native_request}.json"
        request = json.loads(path.read_text())
        for field in ("approvalScope", "disclosure", "policyScope", "policyGrantId"):
            request.pop(field)
        request["version"] = 1
        path.write_text(json.dumps(request))
        self.sign_policy(root)
        self.verifier.reset_mock()
        with self.assertRaisesRegex(API["OrchestrationError"], "unsupported policy fields"):
            self.admit_policy(root)
        self.assertEqual(API["read_state"](root)["nativePolicyGrants"], [])
        self.assertFalse(any(call.args[0][-1] == "--maestro-verify-native-authorization"
                             for call in self.verifier.call_args_list))

    def test_archive_and_recovery_remove_grants_without_changing_other_runs(self):
        root = self.policy_fixture()
        self.prepare_policy(root)
        self.sign_policy(root)
        self.admit_policy(root)
        baseline = API["read_state"](root)
        baseline["nodes"].pop(self.child["id"])
        other, _ = API["new_root"](identifier(), identifier(), identifier(), "Other")
        baseline["nodes"][other["id"]] = other
        baseline["nativePolicyGrants"].append({
            "id": identifier(),
            "scope": self.native.policy_scope(baseline, other, self.settings, self.policy, ROOT,
                                              self.setup_value["setupId"]),
        })
        cmux = SimpleNamespace(validate_surface=lambda *_: self.actor["paneId"])
        for operation in ("command_archive", "command_recover"):
            with self.subTest(operation=operation):
                state = copy.deepcopy(baseline)
                args = SimpleNamespace(actor_id=self.actor["id"], token=self.token,
                                       workspace=self.actor["workspaceId"], surface=self.actor["surfaceId"],
                                       name="Recovered", cwd=str(ROOT), icon=None, color=None)
                if operation == "command_recover":
                    state["nodes"][self.actor["id"]]["lastControlAt"] = (
                        API["now_date"]() - datetime.timedelta(minutes=11)).isoformat()
                with API["Store"](root) as store:
                    store.write(state)
                command = API[operation]
                with patch.dict(command.__globals__, {
                    "require_current_surface": lambda *_: None,
                    "git_display_metadata": lambda *_: API["absent_git_metadata"](),
                }):
                    result = command(args, root, cmux)
                remaining = API["read_state"](root)
                self.assertEqual(len(remaining["nativePolicyGrants"]), 1)
                self.assertEqual(remaining["nativePolicyGrants"][0]["scope"]["actor"]["nodeId"], other["id"])
                self.assertNotIn(self.actor["id"], remaining["nodes"])
                if operation == "command_recover":
                    self.args.actor_id, self.args.token = result["coordinatorId"], result["controlToken"]
                    self.assertEqual(self.prepare_policy(root)["status"], "human-authorization-required")

    def test_actor_specific_grant_does_not_authorize_descendants_or_peers(self):
        root = self.policy_fixture()
        self.prepare_policy(root)
        self.sign_policy(root)
        self.admit_policy(root)
        self.args.actor_id = self.child["id"]
        self.args.token = self.token  # The fixture uses the same token but still requires exact identity.
        self.assertEqual(self.prepare_policy(root)["status"], "human-authorization-required")
        self.assertEqual(API["normalize_tool_policy"](["read"], ["write"],
                         {"allow": ["read"], "deny": ["web"]}),
                         {"allow": ["read"], "deny": ["web", "write"]})
        with self.assertRaises(API["OrchestrationError"]):
            API["normalize_tool_policy"](["write"], [], {"allow": ["read"], "deny": ["web"]})

    def test_native_reservation_caches_consent_atomically_and_timeout_cannot_replay(self):
        root = self.policy_fixture()
        self.prepare_policy(root)
        self.sign_policy(root)
        args = SimpleNamespace(**vars(self.args), command="spawn", cwd=str(ROOT),
                               allow_tool=self.policy["allow"], deny_tool=self.policy["deny"],
                               require_pinned_launch_settings=True, icon=None, color=None)
        spawned = []
        def uncertain_creation(*_args, **_kwargs):
            state = API["read_state"](root)
            admitted = [node for node in state["nodes"].values() if node["phase"] == "launching"]
            self.assertEqual(len(admitted), 1)
            self.assertIn(admitted[0]["id"], state["launches"])
            self.assertEqual(len(state["nativePolicyGrants"]), 1)
            self.assertEqual(len(state["nativeAuthorizations"]), 1)
            spawned.append(admitted[0]["id"])
            raise API["OrchestrationError"]("offline creation timeout")
        cmux = SimpleNamespace(validate_surface=lambda *_: self.actor["paneId"],
                               create_surface=uncertain_creation)
        spawn = API["command_spawn"]
        with patch.dict(spawn.__globals__, {
            "native_messaging": lambda: self.native,
            "resolve_copilot_token": lambda *_: None,
            "git_display_metadata": lambda *_: API["absent_git_metadata"](),
            "resource_observations": lambda *_: ({}, []),
        }), patch.object(os.path, "lexists", return_value=False):
            with self.assertRaisesRegex(API["OrchestrationError"], "offline creation timeout"):
                spawn(args, root, cmux)
            with self.assertRaisesRegex(API["OrchestrationError"], "already been consumed"):
                spawn(args, root, cmux)
        self.assertEqual(len(spawned), 1)
        self.args.name, self.args.task = "New worker", "Separate explicitly prepared objective"
        self.assertEqual(self.prepare_policy(root)["status"], "reuse-ready")

    def test_native_flag_is_launch_only_and_pins_and_denies_are_preserved(self):
        run = API["run_interactive_session"]
        process = SimpleNamespace(pid=42, poll=lambda: 0, wait=lambda: 0)
        node = {**self.child, "task": "Bounded", "workingDirectory": str(ROOT),
                "launchSettings": {"model": "pinned-model", "copilotAccount": "pinned-account"},
                "toolPolicy": {"allow": ["read"], "deny": ["web"]}}
        replacements = {
            "trusted_executable": lambda *_: "/offline/copilot",
            "worker_environment": lambda *_: {"SYNTHETIC_ACCOUNT": "pinned-account"},
            "process_start": lambda *_: "offline", "mutate": lambda *_args, **_kwargs: None,
            "native_process_identity": lambda *_args, **_kwargs: {"start": "2026-09-20T00:00:00Z"},
        }
        with patch.dict(run.__globals__, replacements), patch.object(os, "isatty", return_value=True):
            with patch.object(subprocess, "Popen", return_value=process) as popen:
                for opted_in in (True, False):
                    if not opted_in:
                        node.pop("nativeMessaging")
                    run(ROOT, node["id"], self.token, node)
                    argv = popen.call_args.args[0]
                    self.assertEqual("--experimental" in argv, opted_in)
                    for flag, value in (("--model", "pinned-model"), ("--deny-tool", "web"), ("--allow-tool", "read")):
                        self.assertEqual(argv[argv.index(flag) + 1], value)
                    self.assertNotIn("--allow-all", argv)
                    self.assertNotIn("--yolo", argv)
                    self.assertEqual(popen.call_args.kwargs["env"], {"SYNTHETIC_ACCOUNT": "pinned-account"})


if __name__ == "__main__":
    unittest.main()
