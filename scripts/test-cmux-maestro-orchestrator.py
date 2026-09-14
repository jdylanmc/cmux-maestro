#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-maestro-orchestrator.py"


class OrchestratorTests(unittest.TestCase):
    def setUp(self):
        build = ROOT / ".build"
        build.mkdir(exist_ok=True)
        self.temp = Path(tempfile.mkdtemp(prefix="cmux-maestro-orchestrator-", dir=build))
        self.state = self.temp / "state"
        self.bin = self.temp / "bin"
        self.bin.mkdir()
        self.workspace = str(uuid.uuid4())
        self.pane = str(uuid.uuid4())
        self.coordinator_surface = str(uuid.uuid4())
        self.worker_surface = str(uuid.uuid4())
        self.log = self.temp / "cmux.jsonl"
        self.fixture = self.temp / "cmux-state.json"
        self.fixture.write_text(json.dumps({
            "workspace": self.workspace,
            "pane": self.pane,
            "surfaces": [self.coordinator_surface],
            "nextSurface": self.worker_surface,
        }))
        self.fake_cmux = self.bin / "cmux"
        self.fake_cmux.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
state_path = Path(os.environ["FAKE_CMUX_STATE"])
log_path = Path(os.environ["FAKE_CMUX_LOG"])
state = json.loads(state_path.read_text())
args = sys.argv[1:]
with log_path.open("a") as log:
    log.write(json.dumps(args) + "\\n")
args = [a for a in args if a not in ("--json", "--id-format", "uuids")]
command = args[0]
if command == "identify":
    workspace = args[args.index("--workspace") + 1]
    surface = args[args.index("--surface") + 1]
    if workspace != state["workspace"] or surface not in state["surfaces"]:
        print(json.dumps({"error": "not found"})); raise SystemExit(3)
    print(json.dumps({"workspace_id": workspace, "surface_id": surface}))
elif command == "list-panes":
    print(json.dumps({"panes": [{"id": state["pane"]}]}))
elif command == "list-pane-surfaces":
    print(json.dumps({"surfaces": [{"id": value} for value in state["surfaces"]]}))
elif command == "new-surface":
    surface = state["nextSurface"]
    state["surfaces"].append(surface)
    state["nextSurface"] = str(__import__("uuid").uuid4())
    state_path.write_text(json.dumps(state))
    print(json.dumps({"surface_id": surface}))
elif command in ("send", "send-key", "rename-tab", "reorder-surface"):
    if command == "send" and os.environ.get("FAKE_CMUX_FAIL_SEND") == "1":
        print(json.dumps({"error": "synthetic send failure"})); raise SystemExit(5)
    print(json.dumps({"ok": True}))
else:
    print(json.dumps({"error": "unsupported"})); raise SystemExit(4)
""")
        self.fake_cmux.chmod(0o700)
        self.fake_copilot = self.bin / "copilot"
        self.fake_copilot.write_text("#!/bin/sh\nexit 0\n")
        self.fake_copilot.chmod(0o700)
        self.env = {
            **os.environ,
            "CMUX_MAESTRO_TESTING": "1",
            "CMUX_MAESTRO_ROOT": str(self.state),
            "CMUX_MAESTRO_CMUX": str(self.fake_cmux),
            "CMUX_MAESTRO_COPILOT": str(self.fake_copilot),
            "FAKE_CMUX_STATE": str(self.fixture),
            "FAKE_CMUX_LOG": str(self.log),
        }

    def tearDown(self):
        shutil.rmtree(self.temp)

    def invoke(self, *args, ok=True, env=None):
        result = subprocess.run(
            [str(SCRIPT), *args], env=env or self.env, capture_output=True, text=True
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        return json.loads(result.stderr)

    def register(self):
        return self.invoke(
            "register", "--workspace", self.workspace,
            "--surface", self.coordinator_surface, "--name", "Root coordinator",
        )

    def spawn(self, coordinator, name="Worker"):
        return self.invoke(
            "spawn", "--actor-id", coordinator["coordinatorId"],
            "--token", coordinator["controlToken"], "--name", name,
            "--task", "Implement the bounded change", "--cwd", str(ROOT),
        )

    def test_register_spawn_project_and_background_tab_contract(self):
        coordinator = self.register()
        worker = self.spawn(coordinator)
        self.assertEqual(worker["surfaceId"], self.worker_surface)
        projection = json.loads((self.state / "observer/current.json").read_text())
        self.assertEqual([node["role"] for node in projection["nodes"]], ["coordinator", "worker"])
        child = projection["nodes"][1]
        self.assertEqual(child["parentId"], coordinator["coordinatorId"])
        serialized = json.dumps(projection)
        self.assertNotIn("Implement the bounded change", serialized)
        self.assertNotIn(coordinator["controlToken"], serialized)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        creation = next(call for call in calls if "new-surface" in call)
        self.assertIn("--type", creation)
        self.assertEqual(creation[creation.index("--type") + 1], "terminal")
        self.assertEqual(creation[creation.index("--focus") + 1], "false")
        self.assertEqual(creation[creation.index("--pane") + 1], self.pane)
        self.assertFalse(any("new-pane" in call or "new-workspace" in call for call in calls))

    def test_bad_token_cross_owner_and_busy_followup_are_refused_without_send(self):
        coordinator = self.register()
        worker = self.spawn(coordinator)
        before = self.log.read_text().count('"send"')
        error = self.invoke(
            "follow-up", "--actor-id", coordinator["coordinatorId"], "--token", "wrong",
            "--worker-id", worker["workerId"], "--task", "unsafe", ok=False,
        )
        self.assertIn("invalid", error["error"])
        error = self.invoke(
            "follow-up", "--actor-id", coordinator["coordinatorId"],
            "--token", coordinator["controlToken"], "--worker-id", worker["workerId"],
            "--task", "too early", ok=False,
        )
        self.assertIn("not explicitly reported idle", error["error"])
        self.assertEqual(self.log.read_text().count('"send"'), before)

    def test_report_generation_and_state_are_explicit(self):
        coordinator = self.register()
        worker = self.spawn(coordinator)
        private = json.loads((self.state / "control/state.json").read_text())
        node = private["nodes"][worker["workerId"]]
        token = None
        # Spawn intentionally returns no worker control token to its parent; it is
        # embedded only in the worker bootstrap. Recover it from the fake send.
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        send = next(call for call in calls if "send" in call)
        command = send[-1]
        token = command.split("--token ", 1)[1].split()[0].strip("'")
        error = self.invoke(
            "report", "--worker-id", worker["workerId"], "--token", token,
            "--generation", "2", "--state", "completed", ok=False,
        )
        self.assertIn("generation", error["error"])
        report = self.invoke(
            "report", "--worker-id", worker["workerId"], "--token", token,
            "--generation", "1", "--state", "blocked", "--summary", "Needs an API decision",
        )
        self.assertEqual(report["phase"], "reported-blocked")
        private = json.loads((self.state / "control/state.json").read_text())
        self.assertEqual(private["nodes"][worker["workerId"]]["result"], "Needs an API decision")
        projection = (self.state / "observer/current.json").read_text()
        self.assertNotIn("Needs an API decision", projection)
        self.assertEqual(stat.S_IMODE((self.state / "control/state.json").stat().st_mode), 0o600)

    def test_duplicate_registration_bad_identifiers_and_symlink_root_fail_closed(self):
        self.register()
        error = self.invoke(
            "register", "--workspace", self.workspace,
            "--surface", self.coordinator_surface, ok=False,
        )
        self.assertIn("already registered", error["error"])
        error = self.invoke(
            "register", "--workspace", "not-a-uuid",
            "--surface", self.coordinator_surface, ok=False,
        )
        self.assertIn("UUID", error["error"])
        other = self.temp / "other"
        other.mkdir()
        symlink = self.temp / "linked"
        symlink.symlink_to(other, target_is_directory=True)
        env = {**self.env, "CMUX_MAESTRO_ROOT": str(symlink)}
        error = self.invoke(
            "register", "--workspace", self.workspace,
            "--surface", self.coordinator_surface, ok=False, env=env,
        )
        self.assertIn("Unsafe state path", error["error"])

    def test_focus_uses_exact_surface_and_preserves_tab_index(self):
        coordinator = self.register()
        worker = self.spawn(coordinator)
        result = self.invoke(
            "focus", "--actor-id", coordinator["coordinatorId"],
            "--token", coordinator["controlToken"], "--worker-id", worker["workerId"],
        )
        self.assertTrue(result["focused"])
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        focus = [call for call in calls if "reorder-surface" in call][-1]
        self.assertEqual(focus[focus.index("--surface") + 1], worker["surfaceId"])
        self.assertEqual(focus[focus.index("--focus") + 1], "true")
        error = self.invoke(
            "focus", "--actor-id", coordinator["coordinatorId"],
            "--token", coordinator["controlToken"],
            "--worker-id", coordinator["coordinatorId"], ok=False,
        )
        self.assertIn("owned worker", error["error"])

    def test_corrupt_cycle_and_disappeared_completed_process_fail_closed(self):
        coordinator = self.register()
        worker = self.spawn(coordinator)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        command = next(call for call in calls if "send" in call)[-1]
        token = command.split("--token ", 1)[1].split()[0].strip("'")
        self.invoke(
            "report", "--worker-id", worker["workerId"], "--token", token,
            "--generation", "1", "--state", "completed", "--summary", "Ready",
        )
        status = self.invoke(
            "status", "--actor-id", coordinator["coordinatorId"],
            "--token", coordinator["controlToken"], "--worker-id", worker["workerId"],
        )
        self.assertEqual(status["workers"][0]["phase"], "process-disappeared")

        state_path = self.state / "control/state.json"
        state = json.loads(state_path.read_text())
        root = state["nodes"][coordinator["coordinatorId"]]
        root["role"] = "worker"
        root["parentId"] = worker["workerId"]
        state_path.write_text(json.dumps(state))
        error = self.invoke(
            "status", "--actor-id", coordinator["coordinatorId"],
            "--token", coordinator["controlToken"], ok=False,
        )
        self.assertIn("cyclic", error["error"])

    def test_failed_followup_delivery_is_explicit_and_not_running(self):
        coordinator = self.register()
        worker = self.spawn(coordinator)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        command = next(call for call in calls if "send" in call)[-1]
        token = command.split("--token ", 1)[1].split()[0].strip("'")
        state_path = self.state / "control/state.json"
        state = json.loads(state_path.read_text())
        start = subprocess.run(
            ["/bin/ps", "-o", "lstart=", "-p", str(os.getpid())],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        state["nodes"][worker["workerId"]]["process"] = {"pid": os.getpid(), "start": start}
        state_path.write_text(json.dumps(state))
        self.invoke(
            "report", "--worker-id", worker["workerId"], "--token", token,
            "--generation", "1", "--state", "completed", "--summary", "Ready",
        )
        error = self.invoke(
            "follow-up", "--actor-id", coordinator["coordinatorId"],
            "--token", coordinator["controlToken"], "--worker-id", worker["workerId"],
            "--task", "Next bounded turn", ok=False,
            env={**self.env, "FAKE_CMUX_FAIL_SEND": "1"},
        )
        self.assertIn("synthetic send failure", error["error"])
        state = json.loads(state_path.read_text())
        node = state["nodes"][worker["workerId"]]
        self.assertEqual(node["generation"], 2)
        self.assertEqual((node["phase"], node["availability"]), ("delivery-failed", "idle"))


if __name__ == "__main__":
    unittest.main()
