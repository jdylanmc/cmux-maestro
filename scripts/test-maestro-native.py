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
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid


ROOT = Path(__file__).resolve().parents[1]
API = runpy.run_path(str(ROOT / "scripts/cmux-maestro-orchestrator.py"))
Native = runpy.run_path(str(ROOT / "scripts/maestro_native.py"))["NativeMessaging"]


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
        args = SimpleNamespace(native_request=request_id, name="Worker", task="Bounded task")
        timestamp = API["now_date"]()
        request = {
            "version": 1, "requestId": request_id, "actor": self.native.identity(self.actor),
            "parentToolPolicy": self.actor["toolPolicy"], "workerId": identifier(),
            "sessionId": identifier(), "launchSettings": settings,
            "workerGeneration": 1,
            "toolPolicy": {"allow": [], "deny": ["web"]}, "cwd": str(ROOT),
            "name": args.name, "task": args.task, "mode": "interactive-exact-tools",
            "parentPolicy": "unknown-human-fallback", "createdAt": timestamp.isoformat(),
            "expiresAt": (timestamp + datetime.timedelta(minutes=10)).isoformat(),
        }
        raw = json.dumps(request).encode()
        receipt = json.dumps({"request": base64.b64encode(raw).decode(), "signature": "test-double"}).encode()
        files = {
            f"native-request-{request_id}.json": raw,
            f"native-approval-{request_id}.json": receipt,
            "native-setup.json": b'{"version":1,"verifier":"/offline/verifier"}',
        }
        store = SimpleNamespace(root_fd=0, _read_regular=lambda name, *_args, **_kwargs: files.get(name))
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
                                b'{"version":1,"verifier":"/offline/verifier"}')
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
        result = SimpleNamespace(returncode=0, stdout="42\n")
        with patch.dict(check.__globals__, {"process_start": lambda _pid: "exact-start"}):
            with patch.object(subprocess, "run", return_value=result):
                self.assertTrue(check({"providerProcess": {"pid": 42, "start": "exact-start"}}))
                self.assertFalse(check({"providerProcess": {"pid": 43, "start": "exact-start"}}))
                self.assertFalse(check({"providerProcess": {"pid": 42, "start": "different-start"}}))
                self.assertFalse(check({}))

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
                                 consume_authorization=self.native.consume_authorization)
        spawn = API["command_spawn"]
        replacements = {
            "read_state": lambda *_: self.state,
            "worker_launch_settings": lambda *_: settings,
            "resolve_copilot_token": lambda *_: None,
            "native_messaging": lambda: native,
            "resource_observations": lambda *_: ({}, []),
            "git_display_metadata": lambda *_: API["absent_git_metadata"](),
            "mutate": self.mutate,
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


if __name__ == "__main__":
    unittest.main()
