#!/usr/bin/env python3
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
CONTROLLER = REPO / "scripts" / "cmux-maestro-orchestrator.py"

FAKE_CMUX = r'''#!/usr/bin/env python3
import fcntl, json, os, subprocess, sys, tempfile, uuid
from pathlib import Path

state_path = Path(os.environ["FAKE_CMUX_STATE"])
lock_path = state_path.with_suffix(".lock")
lock_path.parent.mkdir(parents=True, exist_ok=True)
lock = open(lock_path, "a+")
fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
try:
    if state_path.exists():
        state = json.loads(state_path.read_text())
    else:
        state = {
            "workspace": os.environ["TEST_WORKSPACE"],
            "pane": os.environ["TEST_PANE"],
            "surfaces": [os.environ["TEST_ROOT_SURFACE"]],
            "buffers": {},
            "pids": [],
            "calls": [],
            "selected": os.environ["TEST_ROOT_SURFACE"],
        }
    args = sys.argv[1:]
    state["calls"].append(args)
    command = next((item for item in args if item in {
        "identify", "list-panes", "new-surface", "list-pane-surfaces",
        "send", "send-key", "rename-tab", "reorder-surface"
    }), None)
    def value(flag):
        return args[args.index(flag) + 1] if flag in args else None
    workspace = value("--workspace")
    if workspace != state["workspace"]:
        raise SystemExit("wrong workspace")
    result = {}
    if command == "identify":
        surface = value("--surface")
        if surface not in state["surfaces"]:
            print(json.dumps({"error": "surface not found"}))
            raise SystemExit(1)
        result = {"workspace_id": workspace, "surface_id": surface, "pane_id": state["pane"]}
    elif command == "list-panes":
        result = {"panes": [{"pane_id": state["pane"]}]}
    elif command == "new-surface":
        if value("--pane") != state["pane"] or value("--type") != "terminal" or value("--focus") != "false":
            raise SystemExit("invalid new-surface grammar")
        surface = str(uuid.uuid4())
        state["surfaces"].append(surface)
        state["buffers"][surface] = ""
        result = {"surface_id": surface, "pane_id": state["pane"], "workspace_id": workspace}
    elif command == "list-pane-surfaces":
        if value("--pane") != state["pane"]:
            raise SystemExit("wrong pane")
        result = {"surfaces": [{"surface_id": item} for item in state["surfaces"]]}
    elif command == "rename-tab":
        if value("--surface") not in state["surfaces"] or "--" not in args:
            raise SystemExit("invalid rename")
        result = {"ok": True}
    elif command == "send":
        surface = value("--surface")
        if surface not in state["surfaces"] or "--" not in args:
            raise SystemExit("invalid send")
        state["buffers"][surface] = args[args.index("--") + 1]
        result = {"ok": True}
    elif command == "send-key":
        surface = value("--surface")
        if surface not in state["surfaces"] or args[-1] != "enter":
            raise SystemExit("invalid key")
        command_text = state["buffers"].get(surface, "")
        if not command_text:
            raise SystemExit("empty terminal buffer")
        log = state_path.parent / ("runtime-" + surface + ".log")
        output = open(log, "ab", buffering=0)
        env = os.environ.copy()
        env["CMUX_WORKSPACE_ID"] = workspace
        env["CMUX_SURFACE_ID"] = surface
        process = subprocess.Popen(
            ["/bin/sh", "-c", command_text],
            stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
            env=env, start_new_session=True,
        )
        state["pids"].append(process.pid)
        result = {"ok": True}
    elif command == "reorder-surface":
        surface = value("--surface")
        if surface not in state["surfaces"] or value("--focus") != "true" or "--pane" in args:
            raise SystemExit("invalid focus grammar")
        state["selected"] = surface
        result = {"ok": True}
    else:
        raise SystemExit("unsupported arguments: " + repr(args))
    temporary = state_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(state))
    os.replace(temporary, state_path)
    print(json.dumps(result))
finally:
    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    lock.close()
'''

FAKE_COPILOT = r'''#!/usr/bin/env python3
import json, os, subprocess, sys, time
args = sys.argv[1:]
def value(flag):
    return args[args.index(flag) + 1] if flag in args else None
session = value("--session-id") or value("--resume")
prompt = value("-p")
record = {
    "args": args,
    "generation": os.environ.get("CMUX_MAESTRO_GENERATION"),
    "session": session,
}
with open(os.environ["FAKE_COPILOT_CALLS"], "a") as stream:
    stream.write(json.dumps(record) + "\n")
if "[STDERR]" in prompt:
    print("visible permission diagnostic", file=sys.stderr, flush=True)
if "[MALFORMED]" in prompt:
    print("not-json")
    raise SystemExit(0)
if "[NO_REPORT]" not in prompt:
    outcome = "completed"
    if "[BLOCKED]" in prompt:
        outcome = "blocked"
    elif "[FAIL]" in prompt:
        outcome = "failed"
    summary = "bounded " + outcome
    report = [
        os.environ["CMUX_MAESTRO_ORCHESTRATOR"], "report",
        "--worker-id", os.environ["CMUX_MAESTRO_WORKER_ID"],
        "--token", os.environ["CMUX_MAESTRO_CONTROL_TOKEN"],
        "--generation", os.environ["CMUX_MAESTRO_GENERATION"],
        "--state", outcome, "--summary", summary,
    ]
    completed = subprocess.run(report, text=True, capture_output=True)
    if completed.returncode:
        print(json.dumps({"type": "assistant.message", "data": {"content": completed.stderr}}))
        raise SystemExit(7)
time.sleep(0.45 if "[DELAY]" in prompt else 0.08)
print(json.dumps({"type": "assistant.message", "data": {"content": "worker output"}}))
final_session = "00000000-0000-4000-8000-000000000099" if "[WRONG_SESSION]" in prompt else session
print(json.dumps({
    "type": "result", "timestamp": "2026-01-01T00:00:00Z",
    "sessionId": final_session, "exitCode": 0, "usage": {},
}))
'''


class Harness:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name).resolve()
        self.root = self.path / "orchestration"
        self.workspace = "00000000-0000-4000-8000-000000000001"
        self.pane = "00000000-0000-4000-8000-000000000002"
        self.surface = "00000000-0000-4000-8000-000000000003"
        self.cmux_state = self.path / "cmux.json"
        self.copilot_calls = self.path / "copilot-calls.jsonl"
        self.cmux = self.path / "cmux"
        self.copilot = self.path / "copilot"
        self.cmux.write_text(FAKE_CMUX)
        self.copilot.write_text(FAKE_COPILOT)
        self.cmux.chmod(0o755)
        self.copilot.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update({
            "CMUX_MAESTRO_CMUX": str(self.cmux),
            "CMUX_MAESTRO_COPILOT": str(self.copilot),
            "CMUX_MAESTRO_CONTROLLER": str(CONTROLLER),
            "CMUX_MAESTRO_ROOT": str(self.root),
            "CMUX_MAESTRO_TESTING": "1",
            "FAKE_CMUX_STATE": str(self.cmux_state),
            "FAKE_COPILOT_CALLS": str(self.copilot_calls),
            "TEST_WORKSPACE": self.workspace,
            "TEST_PANE": self.pane,
            "TEST_ROOT_SURFACE": self.surface,
            "CMUX_WORKSPACE_ID": self.workspace,
            "CMUX_SURFACE_ID": self.surface,
        })
        self.registration = self.run(
            "register", "--workspace", self.workspace, "--surface", self.surface,
            "--name", "Coordinator",
        )

    def run(self, *args, check=True, timeout=15, env=None):
        command = [
            sys.executable, str(CONTROLLER), *args,
        ]
        completed = subprocess.run(
            command, env=env or self.env, text=True, capture_output=True, timeout=timeout,
        )
        if check and completed.returncode:
            runtime_logs = "\n".join(
                f"{path.name}:\n{path.read_text(errors='replace')}"
                for path in self.path.glob("runtime-*.log")
            )
            raise AssertionError(
                f"{' '.join(command)} failed {completed.returncode}\n"
                f"stdout={completed.stdout}\nstderr={completed.stderr}\n{runtime_logs}"
            )
        if not completed.stdout.strip():
            return {"returncode": completed.returncode, "stderr": completed.stderr}
        result = json.loads(completed.stdout)
        result["returncode"] = completed.returncode
        result["stderr"] = completed.stderr
        return result

    @property
    def node(self):
        return self.registration["coordinatorId"]

    @property
    def token(self):
        return self.registration["controlToken"]

    def spawn(self, task="Complete the bounded task.", label="Worker"):
        return self.run(
            "spawn", "--actor-id", self.node, "--token", self.token,
            "--name", label, "--cwd", str(REPO), "--task", task,
        )

    def state(self):
        return json.loads((self.root / "control" / "state.json").read_text())

    def cmux_data(self):
        return json.loads(self.cmux_state.read_text())

    def wait_node(self, node_id, predicate, timeout=6):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            node = self.state()["nodes"][node_id]
            if predicate(node):
                return node
            time.sleep(0.05)
        raise AssertionError(f"timed out waiting for node {node_id}: {node}")

    def calls(self):
        if not self.copilot_calls.exists():
            return []
        return [json.loads(line) for line in self.copilot_calls.read_text().splitlines()]

    def remove_surface(self, surface):
        data = self.cmux_data()
        data["surfaces"].remove(surface)
        self.cmux_state.write_text(json.dumps(data))

    def add_surface(self, surface):
        data = self.cmux_data()
        data["surfaces"].append(surface)
        self.cmux_state.write_text(json.dumps(data))

    def close(self):
        if self.cmux_state.exists():
            pids = self.cmux_data().get("pids", [])
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            deadline = time.monotonic() + 3
            for pid in pids:
                while time.monotonic() < deadline:
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.02)
        self.temp.cleanup()


class OrchestratorTests(unittest.TestCase):
    def setUp(self):
        self.h = Harness()

    def tearDown(self):
        self.h.close()

    def test_concurrent_startup_handshake_and_exact_identity(self):
        worker = self.h.spawn("[DELAY] [STDERR]")
        completed = self.h.wait_node(
            worker["workerId"],
            lambda node: node["phase"] == "reported-completed" and node["availability"] == "idle",
        )
        self.assertGreater(completed["supervisor"]["pid"], 0)
        self.assertEqual(completed["result"], "bounded completed")
        first = self.h.calls()[0]["args"]
        self.assertIn("--session-id", first)
        self.assertNotIn("--resume", first)
        self.assertNotIn("--allow-all", first)
        sends = [call for call in self.h.cmux_data()["calls"] if "send" in call]
        self.assertEqual(len(sends), 1)
        log = self.h.path / f"runtime-{worker['surfaceId']}.log"
        self.assertIn("visible permission diagnostic", log.read_text())

    def test_follow_up_waits_for_verified_boundary_and_uses_exact_resume(self):
        worker = self.h.spawn("[DELAY]")
        pending = self.h.wait_node(worker["workerId"], lambda node: node["pendingReport"] is not None)
        self.assertEqual(pending["availability"], "busy")
        rejected = self.h.run(
            "follow-up", "--actor-id", self.h.node, "--token", self.h.token,
            "--worker-id", worker["workerId"], "--task", "second turn",
            check=False,
        )
        self.assertEqual(rejected["returncode"], 2)
        self.assertIn("verified idle turn boundary", rejected["stderr"])
        idle = self.h.wait_node(worker["workerId"], lambda node: node["availability"] == "idle")
        follow = self.h.run(
            "follow-up", "--actor-id", self.h.node, "--token", self.h.token,
            "--worker-id", worker["workerId"], "--task", "second turn",
        )
        self.assertEqual(follow["generation"], idle["generation"] + 1)
        self.h.wait_node(
            worker["workerId"],
            lambda node: node["generation"] == follow["generation"] and node["availability"] == "idle",
        )
        calls = self.h.calls()
        self.assertEqual(calls[1]["args"][calls[1]["args"].index("--resume") + 1], worker["sessionId"])
        send_calls = [call for call in self.h.cmux_data()["calls"] if "send" in call]
        self.assertEqual(len(send_calls), 1, "follow-up must use the private queue, not terminal input")

    def test_missing_report_and_invalid_boundary_transition_automatically(self):
        missing = self.h.spawn("[NO_REPORT]")
        missing_node = self.h.wait_node(missing["workerId"], lambda node: node["phase"] == "report-missing")
        self.assertEqual(missing_node["availability"], "idle")
        malformed = self.h.spawn("[MALFORMED]", label="Malformed")
        failed = self.h.wait_node(malformed["workerId"], lambda node: node["phase"] == "turn-failed")
        self.assertEqual(failed["availability"], "idle")
        self.assertIn("valid exact-session", failed["result"])

    def test_completed_live_resources_reject_ninth_until_exact_resource_retired(self):
        workers = []
        for index in range(8):
            worker = self.h.spawn(label=f"Worker {index}")
            self.h.wait_node(worker["workerId"], lambda node: node["availability"] == "idle")
            workers.append(worker)
        surfaces_before = len(self.h.cmux_data()["surfaces"])
        ninth = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Ninth", "--cwd", str(REPO), "--task", "ninth",
            check=False,
        )
        self.assertEqual(ninth["returncode"], 2)
        self.assertIn("Live worker resource limit", ninth["stderr"])
        self.assertEqual(len(self.h.cmux_data()["surfaces"]), surfaces_before)

        first_node = self.h.state()["nodes"][workers[0]["workerId"]]
        os.kill(first_node["supervisor"]["pid"], signal.SIGTERM)
        self.h.wait_node(workers[0]["workerId"], lambda node: node["phase"] == "process-disappeared")
        still_rejected = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Still ninth", "--cwd", str(REPO), "--task", "ninth",
            check=False,
        )
        self.assertEqual(still_rejected["returncode"], 2)
        self.h.remove_surface(workers[0]["surfaceId"])
        replacement = self.h.spawn(label="Replacement")
        self.assertIn("workerId", replacement)

    def test_archive_reuses_coordinator_but_retains_live_worker_resources(self):
        worker = self.h.spawn()
        self.h.wait_node(worker["workerId"], lambda node: node["availability"] == "idle")
        archived = self.h.run("archive", "--actor-id", self.h.node, "--token", self.h.token, timeout=12)
        self.assertTrue(archived["archived"])
        state = self.h.state()
        self.assertEqual(state["nodes"], {})
        self.assertEqual(len(state["archives"]), 1)
        self.assertEqual(len(state["retainedResources"]), 1)
        new_registration = self.h.run(
            "register", "--workspace", self.h.workspace, "--surface", self.h.surface,
            "--name", "Coordinator 2",
        )
        self.assertNotEqual(new_registration["runId"], self.h.registration["runId"])
        self.assertEqual(len(self.h.state()["archives"]), 1)

    def test_recovery_requires_stale_exact_surface_without_live_workers(self):
        fresh = self.h.run(
            "recover", "--workspace", self.h.workspace, "--surface", self.h.surface,
            "--name", "Recovered", check=False,
        )
        self.assertEqual(fresh["returncode"], 2)
        self.assertIn("still current", fresh["stderr"])

        state_path = self.h.root / "control" / "state.json"
        state = self.h.state()
        state["nodes"][self.h.node]["lastControlAt"] = "2000-01-01T00:00:00+00:00"
        state_path.write_text(json.dumps(state))
        recovered = self.h.run(
            "recover", "--workspace", self.h.workspace, "--surface", self.h.surface,
            "--name", "Recovered",
        )
        self.assertNotEqual(recovered["runId"], self.h.registration["runId"])
        self.assertNotEqual(recovered["controlToken"], self.h.token)

    def test_recovery_refuses_live_worker_and_preserves_other_root(self):
        worker = self.h.spawn()
        self.h.wait_node(worker["workerId"], lambda node: node["availability"] == "idle")
        state_path = self.h.root / "control" / "state.json"
        state = self.h.state()
        state["nodes"][self.h.node]["lastControlAt"] = "2000-01-01T00:00:00+00:00"
        state_path.write_text(json.dumps(state))
        refused = self.h.run(
            "recover", "--workspace", self.h.workspace, "--surface", self.h.surface,
            "--name", "Recovered", check=False,
        )
        self.assertEqual(refused["returncode"], 2)
        self.assertIn("live worker ownership", refused["stderr"])

        second_surface = "00000000-0000-4000-8000-000000000004"
        self.h.add_surface(second_surface)
        second_env = self.h.env.copy()
        second_env["CMUX_SURFACE_ID"] = second_surface
        second = self.h.run(
            "register", "--workspace", self.h.workspace, "--surface", second_surface,
            "--name", "Other coordinator", env=second_env,
        )
        os.kill(self.h.state()["nodes"][worker["workerId"]]["supervisor"]["pid"], signal.SIGTERM)
        self.h.wait_node(worker["workerId"], lambda node: node["phase"] == "process-disappeared")
        self.h.remove_surface(worker["surfaceId"])
        recovered = self.h.run(
            "recover", "--workspace", self.h.workspace, "--surface", self.h.surface,
            "--name", "Recovered",
        )
        self.assertIn(second["coordinatorId"], self.h.state()["nodes"])
        self.assertIn(recovered["coordinatorId"], self.h.state()["nodes"])

    def test_archive_history_is_bounded(self):
        state_path = self.h.root / "control" / "state.json"
        state = self.h.state()
        state["archives"] = [
            {
                "runId": str(uuid.uuid4()),
                "coordinatorLabel": "Old",
                "nodeCount": 1,
                "archivedAt": "2020-01-01T00:00:00Z",
            }
            for _ in range(32)
        ]
        state_path.write_text(json.dumps(state))
        self.h.run("archive", "--actor-id", self.h.node, "--token", self.h.token)
        archives = self.h.state()["archives"]
        self.assertEqual(len(archives), 32)
        self.assertEqual(archives[-1]["runId"], self.h.registration["runId"])

    def test_focus_targets_verified_surface(self):
        worker = self.h.spawn()
        focused = self.h.run(
            "focus", "--actor-id", self.h.node, "--token", self.h.token,
            "--worker-id", worker["workerId"],
        )
        self.assertEqual(focused["surfaceId"], worker["surfaceId"])
        focus_call = next(call for call in reversed(self.h.cmux_data()["calls"]) if "reorder-surface" in call)
        self.assertNotIn("--pane", focus_call)
        self.assertEqual(focus_call[focus_call.index("--focus") + 1], "true")

    def test_registration_rejects_caller_identity_mismatch(self):
        other = Harness.__new__(Harness)
        # Exercise only the command against this harness; no second temporary tree is created.
        del other
        env = self.h.env.copy()
        env["CMUX_SURFACE_ID"] = "00000000-0000-4000-8000-000000000099"
        result = self.h.run(
            "recover", "--workspace", self.h.workspace, "--surface", self.h.surface,
            "--name", "Wrong", check=False, env=env,
        )
        self.assertEqual(result["returncode"], 2)
        self.assertIn("current caller CMUX surface", result["stderr"])


if __name__ == "__main__":
    unittest.main()
