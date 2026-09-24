#!/usr/bin/env python3
import ast
import json
import os
import pty
import re
import runpy
import shlex
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
CONTROLLER = REPO / "scripts" / "cmux-maestro-orchestrator.py"
CONTROLLER_API = runpy.run_path(str(CONTROLLER))

FAKE_CMUX = r'''#!/usr/bin/env python3
import fcntl, json, os, runpy, shlex, subprocess, sys, tempfile, uuid
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
        "identify", "list-panes", "rpc", "list-pane-surfaces",
        "send", "send-key", "rename-tab", "reorder-surface"
    }), None)
    def value(flag):
        return args[args.index(flag) + 1] if flag in args else None
    creation = json.loads(args[args.index("rpc") + 2]) if command == "rpc" else None
    workspace = creation["workspace_id"] if creation is not None else value("--workspace")
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
    elif command == "rpc" and args[args.index("rpc") + 1] == "surface.list":
        result = {"workspace_id": workspace, "surfaces": [
            {"id": item} for item in state["surfaces"]
        ]}
    elif command == "rpc":
        if args[args.index("rpc") + 1] != "surface.create":
            raise SystemExit("unsupported RPC")
        if (creation["pane_id"] != state["pane"] or creation["type"] != "terminal"
                or creation["focus"] is not False or "initial_input" in creation):
            raise SystemExit("invalid direct surface.create parameters")
        surface = str(uuid.uuid4())
        state["surfaces"].append(surface)
        state["buffers"][surface] = ""
        result = {"surface_id": surface, "pane_id": state["pane"], "workspace_id": workspace}
        bootstrap = creation.get("initial_command")
        if bootstrap:
            command_args = shlex.split(bootstrap)
            worker_id = command_args[command_args.index("--worker-id") + 1]
            control = Path(os.environ["CMUX_MAESTRO_ROOT"]) / "control"
            ticket = json.loads((control / ("launch-" + worker_id + ".json")).read_text())
            state.setdefault("tokens", {})[worker_id] = ticket["token"]
            if os.environ.get("FAKE_SESSION_MODE") == "bounded":
                api = runpy.run_path(os.environ["CMUX_MAESTRO_CONTROLLER"])
                # Simulate a persisted pre-interactive worker, without exposing a production legacy-spawn switch.
                api["mutate"](Path(os.environ["CMUX_MAESTRO_ROOT"]),
                              lambda stored: stored["nodes"][worker_id].pop("executionMode", None))
            env = os.environ.copy()
            env["CMUX_WORKSPACE_ID"] = workspace
            env["CMUX_SURFACE_ID"] = surface
            if env.get("FAKE_DROP_RUNTIME_PATH"):
                env["PATH"] = "/usr/bin:/bin"
                env.pop("CMUX_MAESTRO_COPILOT", None)
            if env.get("FAKE_RUNTIME_COPILOT_MISSING"):
                env["CMUX_MAESTRO_COPILOT"] = env["FAKE_RUNTIME_COPILOT_MISSING"]
            output = open(state_path.parent / ("runtime-" + surface + ".log"), "ab", buffering=0)
            terminal = os.open(env["FAKE_PTY_SLAVE"], os.O_RDWR) if env.get("FAKE_PTY_SLAVE") else None
            process = subprocess.Popen(
                command_args, stdin=terminal if terminal is not None else subprocess.DEVNULL,
                stdout=terminal if terminal is not None else output,
                stderr=terminal if terminal is not None else output,
                env=env, start_new_session=True,
            )
            if terminal is not None:
                os.close(terminal)
            state["pids"].append(process.pid)
            state["buffers"][surface] = bootstrap
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
import json, os, signal, subprocess, sys, time, uuid
from pathlib import Path
args = sys.argv[1:]
def value(flag):
    return args[args.index(flag) + 1] if flag in args else None
session = value("--session-id") or value("--resume")
prompt = value("-p") or value("--interactive") or ""
record = {
    "args": args,
    "generation": os.environ.get("CMUX_MAESTRO_GENERATION"),
    "session": session,
    "tty": [os.isatty(fd) for fd in (0, 1, 2)],
    "pinnedSubscription": os.environ.get("COPILOT_GITHUB_TOKEN") == "synthetic-work-token",
    "gitTokenUnchanged": os.environ.get("GH_TOKEN") == "synthetic-personal-token",
}
with open(os.environ["FAKE_COPILOT_CALLS"], "a") as stream:
    stream.write(json.dumps(record) + "\n")
if "--interactive" in args:
    ready = Path(os.environ["FAKE_INTERACTIVE_READY"])
    received = Path(os.environ["FAKE_INTERACTIVE_INPUT"])
    signal.signal(signal.SIGINT, lambda *_: ready.with_suffix(".interrupted").write_text("yes"))
    ready.write_text("ready")
    print("Interactive ready", flush=True)
    for line in sys.stdin:
        if line.strip() == "exit":
            break
        received.write_text(line)
        print("Human follow-up received", flush=True)
    raise SystemExit(0)
if "[STDERR]" in prompt:
    print("visible permission diagnostic", file=sys.stderr, flush=True)
if "[STDERR_WAIT]" in prompt:
    print("approval prompt before completion", file=sys.stderr, flush=True)
    Path(os.environ["FAKE_STDERR_READY"]).write_text("ready")
    time.sleep(0.8)
if "[SILENT]" in prompt:
    time.sleep(0.35)
if "[MALFORMED]" in prompt:
    print("not-json")
    raise SystemExit(0)
if "[OVERSIZED]" in prompt:
    os.write(sys.stdout.fileno(), b"x" * (1048576 + 4096))
    print()
if "[SCALAR]" in prompt:
    print(json.dumps(["not", "an", "object"]))
outcome = "completed"
if "[BLOCKED]" in prompt:
    outcome = "blocked"
elif "[FAIL]" in prompt:
    outcome = "failed"
summary = "bounded " + outcome
if "[CLI_REPORT]" in prompt or "[DUAL_REPORT]" in prompt:
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
if "[NESTED_SUBSET]" in prompt or "[NESTED_ESCALATE]" in prompt:
    nested = [
        os.environ["CMUX_MAESTRO_ORCHESTRATOR"], "spawn",
        "--actor-id", os.environ["CMUX_MAESTRO_WORKER_ID"],
        "--token", os.environ["CMUX_MAESTRO_CONTROL_TOKEN"],
        "--name", "Nested policy worker", "--cwd", os.getcwd(),
        "--task", "[NO_REPORT]", "--allow-tool",
        "write" if "[NESTED_ESCALATE]" in prompt else "read",
        "--deny-tool", "network",
    ]
    completed = subprocess.run(nested, text=True, capture_output=True)
    with open(os.environ["FAKE_POLICY_RESULTS"], "a") as stream:
        stream.write(json.dumps({
            "kind": "escalate" if "[NESTED_ESCALATE]" in prompt else "subset",
            "returncode": completed.returncode,
            "stdout": completed.stdout,
            "stderr": completed.stderr,
        }) + "\n")
if "[DENIED" in prompt:
    print(json.dumps({
        "type": "tool.execution_complete",
        "data": {
            "toolName": "bash",
            "success": False,
            "error": {
                "code": "denied",
                "message": "Permission denied and could not request permission from user",
            },
        },
    }))
if "[SUCCESS_PERMISSION_TEXT]" in prompt:
    print(json.dumps({
        "type": "tool.execution_complete",
        "data": {
            "success": True,
            "result": {"message": "Documentation says permission denied", "code": "denied"},
        },
    }))
if "[FAILED_OTHER_ERROR]" in prompt:
    print(json.dumps({
        "type": "tool.execution_complete",
        "data": {
            "success": False,
            "error": {"code": "file_error", "message": "File operation: permission denied"},
        },
    }))
if "[NESTED_PERMISSION_TEXT]" in prompt:
    payload = {"code": "denied", "message": "permission denied " * 2048}
    for _ in range(10):
        payload = {"nested": payload}
    print(json.dumps({
        "type": "tool.execution_complete",
        "data": {"success": True, "result": payload},
    }))
time.sleep(0.45 if "[DELAY]" in prompt else 0.08)
worker_id = os.environ["CMUX_MAESTRO_WORKER_ID"]
generation = int(os.environ["CMUX_MAESTRO_GENERATION"])
machine_report = {
    "protocol": "cmux-maestro.worker-report",
    "version": 1,
    "workerId": worker_id,
    "generation": generation,
    "state": outcome,
    "summary": summary,
}
if "[WRONG_REPORT_WORKER]" in prompt:
    machine_report["workerId"] = str(uuid.uuid4())
if "[WRONG_REPORT_GENERATION]" in prompt:
    machine_report["generation"] += 1
if "[WRONG_REPORT_VERSION]" in prompt:
    machine_report["version"] = 2
if "[WRONG_REPORT_STATE]" in prompt:
    machine_report["state"] = "working"
if "[EXTRA_REPORT_FIELD]" in prompt:
    machine_report["unexpected"] = True
content = json.dumps(machine_report, separators=(",", ":"))
if "[DUPLICATE_REPORT_KEY]" in prompt:
    content = content[:-1] + ',"state":"failed"}'
tool_requests = []
if "[FENCED_REPORT]" in prompt:
    content = "```json\n" + content + "\n```"
if "[NORMAL_FINAL]" in prompt or "[NO_REPORT]" in prompt or "[DENIED_NO_REPORT]" in prompt:
    content = "Verified acceptance marker"
if "[REPORT_TOOL_REQUEST]" in prompt:
    tool_requests = [{"toolName": "bash"}]
if "[CLI_REPORT]" not in prompt or "[DUAL_REPORT]" in prompt:
    print(json.dumps({
        "type": "assistant.message",
        "data": {
            "phase": "final_answer",
            "toolRequests": tool_requests,
            "content": content,
        },
    }))
if "[DUPLICATE_FINAL_REPORT]" in prompt:
    print(json.dumps({
        "type": "assistant.message",
        "data": {"phase": "final_answer", "toolRequests": [], "content": content},
    }))
print(json.dumps({
    "type": "assistant.reasoning", "ephemeral": True,
    "data": {"content": "synthetic opaque auxiliary value", "reasoningId": "fixture", "rte": {}},
}))
if "[PERSISTENT_AUXILIARY]" in prompt:
    print(json.dumps({
        "type": "assistant.reasoning", "ephemeral": False,
        "data": {"content": "synthetic opaque value"},
    }))
if "[AUXILIARY_WITH_TOOL]" in prompt:
    print(json.dumps({
        "type": "assistant.reasoning", "ephemeral": True,
        "data": {"toolRequests": [{"toolName": "bash"}]},
    }))
print(json.dumps({"type": "assistant.turn_end", "data": {"turnId": "0"}}))
print(json.dumps({
    "type": "session.usage_checkpoint",
    "data": {"totalNanoAiu": 0, "totalPremiumRequests": 0, "modelCacheState": {},
             "promptCacheBreakState": {}},
}))
print(json.dumps({"type": "assistant.idle", "data": {}}))
for _ in range(3):
    print(json.dumps({"type": "session.background_tasks_changed", "data": {}}))
if "[BACKGROUND_NOTICE_WITH_CONTENT]" in prompt:
    print(json.dumps({"type": "session.background_tasks_changed", "data": {"tasks": ["unverified"]}}))
if "[AFTER_FINAL_TOOL]" in prompt:
    print(json.dumps({"type": "tool.execution_start", "data": {"toolName": "bash"}}))
if "[AFTER_FINAL_CONTENT]" in prompt:
    print(json.dumps({
        "type": "assistant.message",
        "data": {"phase": "commentary", "content": "More work", "toolRequests": []},
    }))
if "[BOOKKEEPING_WITH_CONTENT]" in prompt:
    print(json.dumps({"type": "assistant.idle", "data": {"content": "Not bookkeeping"}}))
if "[AFTER_FINAL_MALFORMED]" in prompt:
    print("{not-json")
final_session = "00000000-0000-4000-8000-000000000099" if "[WRONG_SESSION]" in prompt else session
timestamp = "2099-01-01T00:00:00Z" if "[FUTURE_RESULT]" in prompt else "2026-01-01T00:00:00Z"
exit_code = 7 if "[EXIT7]" in prompt else 0
if "[MISSING_RESULT]" in prompt:
    raise SystemExit(exit_code)
print(json.dumps({
    "type": "result", "timestamp": timestamp,
    "sessionId": final_session,
    "exitCode": True if "[BOOL_EXIT]" in prompt else exit_code,
    "usage": {},
}))
if "[DUPLICATE_RESULT]" in prompt:
    print(json.dumps({
        "type": "result", "timestamp": timestamp,
        "sessionId": final_session, "exitCode": exit_code, "usage": {},
    }))
if "[AFTER_RESULT_BOOKKEEPING]" in prompt:
    print(json.dumps({"type": "assistant.idle", "data": {}}))
raise SystemExit(exit_code)
'''


class Harness:
    def __init__(self, interactive=False):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name).resolve()
        self.root = self.path / "orchestration"
        self.workspace = "00000000-0000-4000-8000-000000000001"
        self.pane = "00000000-0000-4000-8000-000000000002"
        self.surface = "00000000-0000-4000-8000-000000000003"
        self.cmux_state = self.path / "cmux.json"
        self.copilot_calls = self.path / "copilot-calls.jsonl"
        self.stderr_ready = self.path / "stderr-ready"
        self.policy_results = self.path / "policy-results.jsonl"
        self.terminal_master = None
        self.terminal_slave = None
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
            "FAKE_SESSION_MODE": "interactive" if interactive else "bounded",
            "FAKE_CMUX_STATE": str(self.cmux_state),
            "FAKE_COPILOT_CALLS": str(self.copilot_calls),
            "FAKE_STDERR_READY": str(self.stderr_ready),
            "FAKE_POLICY_RESULTS": str(self.policy_results),
            "TEST_WORKSPACE": self.workspace,
            "TEST_PANE": self.pane,
            "TEST_ROOT_SURFACE": self.surface,
            "CMUX_WORKSPACE_ID": self.workspace,
            "CMUX_SURFACE_ID": self.surface,
        })
        if interactive:
            self.terminal_master, self.terminal_slave = pty.openpty()
            self.env["FAKE_PTY_SLAVE"] = os.ttyname(self.terminal_slave)
            self.env["FAKE_INTERACTIVE_READY"] = str(self.path / "interactive-ready")
            self.env["FAKE_INTERACTIVE_INPUT"] = str(self.path / "interactive-input")
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

    def start(self, *args, env=None):
        return subprocess.Popen(
            [sys.executable, str(CONTROLLER), *args],
            env=env or self.env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def finish(self, process, *, timeout=15, check=True):
        stdout, stderr = process.communicate(timeout=timeout)
        if check and process.returncode:
            raise AssertionError(
                f"controller failed {process.returncode}\nstdout={stdout}\nstderr={stderr}"
            )
        return {
            **(json.loads(stdout) if stdout.strip() else {}),
            "returncode": process.returncode,
            "stderr": stderr,
        }

    @property
    def node(self):
        return self.registration["coordinatorId"]

    @property
    def token(self):
        return self.registration["controlToken"]

    def spawn(self, task="Complete the bounded task.", label="Worker", allow=(), deny=()):
        arguments = [
            "spawn", "--actor-id", self.node, "--token", self.token,
            "--name", label, "--cwd", str(REPO), "--task", task,
        ]
        for rule in allow:
            arguments.extend(["--allow-tool", rule])
        for rule in deny:
            arguments.extend(["--deny-tool", rule])
        return self.run(*arguments)

    def state(self):
        return json.loads((self.root / "control" / "state.json").read_text())

    def change_state(self, operation):
        return CONTROLLER_API["mutate"](self.root, operation, wait=2)

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
        for descriptor in (self.terminal_master, self.terminal_slave):
            if descriptor is not None:
                os.close(descriptor)
        self.temp.cleanup()


class OrchestratorTests(unittest.TestCase):
    def setUp(self):
        self.h = Harness()

    def tearDown(self):
        self.h.close()

    def test_read_only_control_checks_share_lock_but_cannot_publish(self):
        store_type = CONTROLLER_API["Store"]
        error_type = CONTROLLER_API["OrchestrationError"]
        with store_type(self.h.root, read_only=True) as first:
            with store_type(self.h.root, read_only=True) as second:
                self.assertEqual(first.read(), second.read())
                with self.assertRaisesRegex(error_type, "Read-only"):
                    second.write(second.read())
                with self.assertRaisesRegex(error_type, "operation is active"):
                    with store_type(self.h.root):
                        self.fail("A writer must not cross active readers.")
        with store_type(self.h.root) as writer:
            writer.write(writer.read())

    def test_local_subscription_and_model_are_pinned_without_leaking_or_changing_git_auth(self):
        h = Harness(interactive=True)
        try:
            gh = h.path / "gh"
            gh.write_text(
                "#!/usr/bin/env python3\nimport os,sys,json\n"
                "assert not any(os.environ.get(k) for k in ['GH_TOKEN','GITHUB_TOKEN','COPILOT_GITHUB_TOKEN'])\n"
                "if sys.argv[1:3]==['auth','status']:\n"
                " print(json.dumps([{'login':'work-user','state':'success'}]));sys.exit(0)\n"
                "assert sys.argv[sys.argv.index('--user')+1]=='work-user'\n"
                "if os.environ.get('FAKE_SUBSCRIPTION_MISSING'):sys.exit(1)\n"
                "print('synthetic-work-token')\n"
            )
            gh.chmod(0o700)
            h.env.update({
                "CMUX_MAESTRO_GH": str(gh),
                "GH_TOKEN": "synthetic-personal-token",
                "COPILOT_GITHUB_TOKEN": "synthetic-other-token",
                "FAKE_SUBSCRIPTION_MISSING": "1",
            })
            settings = h.root / "worker-settings.json"
            settings.write_text(json.dumps({"version": 1, "copilotAccount": "work-user", "model": "example-large-model"}))
            settings.chmod(0o600)
            self.assertEqual(h.run("accounts")["accounts"], [{"login": "work-user", "available": True}])
            self.assertEqual(h.run("launch-settings"), {
                "accountAvailable": False,
                "accountPinned": True,
                "modelPinned": True,
                "ok": True,
                "ready": False,
                "messagingInstalled": False,
                "returncode": 0,
                "stderr": "",
            })
            rejected = h.run("spawn", "--actor-id", h.node, "--token", h.token, "--cwd", str(REPO),
                             "--name", "Must not launch", "--task", "No fallback",
                             "--require-pinned-launch-settings", check=False)
            self.assertNotEqual(rejected["returncode"], 0)
            self.assertFalse(any("surface.create" in call for call in h.cmux_data()["calls"]))
            del h.env["FAKE_SUBSCRIPTION_MISSING"]
            self.assertEqual(h.run("launch-settings"), {
                "accountAvailable": True,
                "accountPinned": True,
                "modelPinned": True,
                "ok": True,
                "ready": True,
                "messagingInstalled": False,
                "returncode": 0,
                "stderr": "",
            })
            worker = h.spawn("Use local launch preferences.")
            h.wait_node(worker["workerId"], lambda node: node.get("providerProcess") is not None)
            deadline = time.monotonic() + 5
            while not h.calls() and time.monotonic() < deadline:
                time.sleep(0.02)
            call = h.calls()[0]
            self.assertTrue(call["pinnedSubscription"])
            self.assertTrue(call["gitTokenUnchanged"])
            self.assertEqual(call["args"][call["args"].index("--model") + 1], "example-large-model")
            self.assertNotIn("synthetic-work-token", json.dumps(h.state()))
            self.assertNotIn("synthetic-work-token", json.dumps(h.cmux_data()))
            os.write(h.terminal_master, b"exit\n")
            h.wait_node(worker["workerId"], lambda node: node["phase"] == "process-disappeared")
        finally:
            h.close()

    def test_required_launch_settings_reject_defaults_before_creating_a_surface(self):
        rejected = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--cwd", str(REPO), "--name", "Must not launch",
            "--task", "Require the dedicated account.",
            "--require-pinned-launch-settings", check=False,
        )
        self.assertNotEqual(rejected["returncode"], 0)
        self.assertIn("Pinned Maestro account and model settings are required", rejected["stderr"])
        self.assertFalse(any("surface.create" in call for call in self.h.cmux_data()["calls"]))

    def test_managed_coordinator_launch_owns_native_session_and_preserves_caller(self):
        h = Harness(interactive=True)
        routes = REPO / ".build" / uuid.uuid4().hex[:5]
        routes.mkdir(mode=0o700, parents=True)
        try:
            extension = h.root / "extension"
            extension.mkdir(mode=0o700)
            for name in ("adapter.mjs", "extension.mjs"):
                shutil.copyfile(REPO / "scripts" / "delivery-proof" / name, extension / name)
                (extension / name).chmod(0o600)
            (h.root / "bin").mkdir(mode=0o700)
            config = h.root / "bin/messaging.json"
            config.write_text(json.dumps({"version": 1, "routes": str(routes), "extension": str(extension)}))
            config.chmod(0o600)
            settings = h.root / "worker-settings.json"
            settings.write_text(json.dumps({"version": 1, "copilotAccount": "saved-other", "model": "pinned-model"}))
            settings.chmod(0o600)
            gh = h.path / "gh"
            gh.write_text(
                "#!/usr/bin/env python3\nimport sys\n"
                "assert sys.argv[sys.argv.index('--user')+1]=='root-account'\n"
                "print('synthetic-work-token')\n"
            )
            gh.chmod(0o700)
            h.env["CMUX_MAESTRO_GH"] = str(gh)
            result = h.run(
                "launch-coordinator", "--workspace", h.workspace, "--surface", h.surface,
                "--cwd", str(REPO), "--name", "Managed coordinator", "--task", "Synthetic root",
                "--account", "root-account", "--deny-tool", "web",
            )
            node = h.wait_node(result["coordinatorId"], lambda item: item.get("providerProcess") is not None)
            self.assertEqual(node["role"], "coordinator")
            self.assertIsNone(node["parentId"])
            self.assertNotEqual(node["runId"], h.registration["runId"])
            self.assertEqual(node["launchSettings"]["copilotAccount"], "root-account")
            self.assertEqual(node["toolPolicy"]["deny"], ["web"])
            self.assertEqual(h.state()["nodes"][h.node]["surfaceId"], h.surface)
            self.assertEqual(h.cmux_data()["selected"], h.surface)
            refused = h.run("archive", "--actor-id", node["id"], "--token", result["controlToken"], check=False)
            self.assertNotEqual(refused["returncode"], 0)
            self.assertIn("Close interactive sessions normally", refused["stderr"])
            os.write(h.terminal_master, b"exit\n")
            h.wait_node(node["id"], lambda item: item["phase"] == "process-disappeared")
        finally:
            h.close()
            shutil.rmtree(routes)

    def test_interactive_prelaunch_error_survives_supervisor_exit_privately(self):
        h = Harness(interactive=True)
        try:
            missing = h.path / "missing-provider"
            h.env["FAKE_RUNTIME_COPILOT_MISSING"] = str(missing)
            h.run(
                "spawn", "--actor-id", h.node, "--token", h.token,
                "--cwd", str(REPO), "--name", "Startup diagnostic",
                "--task", "Synthetic failure before provider creation", check=False,
            )
            identifier = next(
                node["id"] for node in h.state()["nodes"].values() if node["role"] == "worker"
            )
            node = h.wait_node(identifier, lambda item: item["phase"] == "turn-failed")
            self.assertIn("Required executable is unavailable", node["result"])
            self.assertIn("missing-provider", node["result"])
            self.assertIsNone(node.get("providerProcess"))
            self.assertNotIn("missing-provider", (h.root / "observer/current.json").read_text())
        finally:
            h.close()

    def test_provider_is_pinned_before_host_drops_interactive_shell_path(self):
        h = Harness(interactive=True)
        try:
            directory = h.path / "provider-bin"
            directory.mkdir()
            interpreter = directory / "maestro-test-python"
            interpreter.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} \"$@\"\n")
            interpreter.chmod(0o700)
            h.copilot.write_text(FAKE_COPILOT.replace(
                "#!/usr/bin/env python3", "#!/usr/bin/env maestro-test-python", 1
            ))
            h.copilot.chmod(0o700)
            h.env["PATH"] = str(directory) + os.pathsep + h.env["PATH"]
            h.env["FAKE_DROP_RUNTIME_PATH"] = "1"
            worker = h.spawn("Synthetic direct startup without shell configuration.")
            node = h.wait_node(
                worker["workerId"], lambda item: item.get("providerProcess") is not None
                and (h.path / "interactive-ready").exists()
            )
            self.assertEqual(node["copilotExecutable"], str(h.copilot))
            self.assertEqual(node["launchPath"], h.env["PATH"])
            os.write(h.terminal_master, b"exit\n")
            h.wait_node(worker["workerId"], lambda item: item["phase"] == "process-disappeared")
        finally:
            h.close()

    def test_standalone_icon_uses_identity_helper_without_mutating_orchestration(self):
        package = self.h.path / "standalone-bin"
        package.mkdir()
        script = package / "controller"
        shutil.copyfile(CONTROLLER, script)
        fonts = package / "NerdFonts"
        fonts.mkdir()
        for name in ("glyphnames.json", "presets.json"):
            shutil.copyfile(REPO / "Resources" / "NerdFonts" / name, fonts / name)
        helper = package / "identity-helper"
        helper.write_text(
            "#!/usr/bin/env python3\nimport json,sys,os\n"
            "a=sys.argv\n"
            "v=lambda k:a[a.index(k)+1] if k in a else None\n"
            "r={'ok':os.environ.get('FAKE_SELF_DENIED')!='1','sessionId':v('--session-id')}\n"
            "r.update({k:v(f) for k,f in [('iconId','--icon'),('iconColor','--color')] if v(f) is not None})\n"
            "print(json.dumps(r))\n"
        )
        helper.chmod(0o700)
        config = package / "identity-helper.json"
        config.write_text(json.dumps({"helper": str(helper)}))
        config.chmod(0o600)
        session = str(uuid.uuid4())
        before = self.h.state()
        command = [sys.executable, str(script), "icon", "--self", "--session-id", session,
                   "--icon", "nf-md-duck", "--color", "teal"]
        result = subprocess.run(command, env=self.h.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["iconId"], "md-duck")
        self.assertEqual(json.loads(result.stdout)["sessionId"], session)
        self.assertEqual(self.h.state(), before)
        denied_env = {**self.h.env, "FAKE_SELF_DENIED": "1"}
        denied = subprocess.run(command, env=denied_env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(denied.returncode, 0)
        self.assertIn("no icon was changed", denied.stderr)
        self.assertEqual(self.h.state(), before)

    def test_default_worker_is_interactive_and_accepts_human_input_without_turn_reports(self):
        h = Harness(interactive=True)
        try:
            worker = h.spawn("Review this task, then remain available.", allow=("read",))
            identifier = worker["workerId"]
            node = h.wait_node(identifier, lambda item: item["phase"] == "turn-running" and item.get("providerProcess"))
            self.assertEqual(node["executionMode"], "interactive")
            self.assertEqual(node["availability"], "busy")
            deadline = time.monotonic() + 5
            while not (h.path / "interactive-ready").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue((h.path / "interactive-ready").exists())
            call = h.calls()[0]
            self.assertEqual(call["tty"], [True, True, True])
            self.assertIn("--interactive", call["args"])
            self.assertNotIn("--model", call["args"])
            self.assertNotIn("-p", call["args"])
            self.assertNotIn("--output-format", call["args"])
            self.assertNotIn("cmux-maestro.worker-report", " ".join(call["args"]))
            self.assertIn("--allow-tool", call["args"])
            self.assertNotIn("--allow-all", call["args"])
            self.assertFalse((h.root / "control" / f"launch-{identifier}.json").exists())
            rejected = h.run("follow-up", "--actor-id", h.node, "--token", h.token,
                             "--worker-id", identifier, "--task", "Must not be typed", check=False)
            self.assertNotEqual(rejected["returncode"], 0)
            self.assertIn("interactive", rejected["stderr"])
            archived = h.run("archive", "--actor-id", h.node, "--token", h.token, check=False)
            self.assertNotEqual(archived["returncode"], 0)
            self.assertFalse(h.state()["nodes"][identifier]["archiving"])
            os.write(h.terminal_master, b"A direct human follow-up\n")
            deadline = time.monotonic() + 5
            while not (h.path / "interactive-input").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertEqual((h.path / "interactive-input").read_text(), "A direct human follow-up\n")
            self.assertEqual(h.state()["nodes"][identifier]["phase"], "turn-running")
            self.assertFalse(any("send" in call for call in h.cmux_data()["calls"]))
            os.write(h.terminal_master, b"exit\n")
            ended = h.wait_node(identifier, lambda item: item["phase"] == "process-disappeared")
            self.assertEqual(ended["availability"], "unavailable")
            self.assertIsNone(ended["verifiedBoundaryGeneration"])
            self.assertIn("no task outcome", ended["result"])
            h.wait_node(identifier, CONTROLLER_API["worker_processes_exited"])
            archived = h.run("archive", "--actor-id", h.node, "--token", h.token)
            self.assertTrue(archived["archived"])
            self.assertEqual(h.state()["nodes"], {})
            self.assertEqual(
                h.state()["retainedResources"][0]["surfaceId"], worker["surfaceId"],
            )
        finally:
            h.close()

    def test_interactive_ctrl_c_does_not_terminate_the_supervisor(self):
        h = Harness(interactive=True)
        try:
            worker = h.spawn("Remain interactive.")
            node = h.wait_node(worker["workerId"], lambda item: item.get("providerProcess") is not None)
            deadline = time.monotonic() + 5
            while not (h.path / "interactive-ready").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue((h.path / "interactive-ready").exists())
            os.killpg(node["supervisor"]["pid"], signal.SIGINT)
            deadline = time.monotonic() + 5
            while not (h.path / "interactive-ready.interrupted").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue((h.path / "interactive-ready.interrupted").exists())
            self.assertTrue(CONTROLLER_API["process_matches"](h.state()["nodes"][worker["workerId"]]))
            self.assertEqual(h.state()["nodes"][worker["workerId"]]["phase"], "turn-running")
            os.write(h.terminal_master, b"exit\n")
            h.wait_node(worker["workerId"], lambda item: item["phase"] == "process-disappeared")
        finally:
            h.close()

    def test_icon_catalog_is_pinned_searchable_bounded_and_read_only(self):
        env = self.h.env.copy()
        unused = self.h.path / "catalog-must-not-create-state"
        env["CMUX_MAESTRO_ROOT"] = str(unused)
        env.pop("CMUX_WORKSPACE_ID")
        env.pop("CMUX_SURFACE_ID")
        catalog = self.h.run("icons", "--search", "nf-fa-edge", env=env)
        self.assertEqual(catalog["fontVersion"], "3.5.1")
        self.assertEqual(catalog["icons"], [{"id": "fa-edge", "char": "\uf282", "code": "f282"}])
        self.assertNotIn("orange", catalog["colors"])
        self.assertFalse(unused.exists())
        first = self.h.run("icons", "--limit", "3")
        second = self.h.run("icons", "--limit", "3", "--offset", "3")
        self.assertEqual(first["total"], 10994)
        self.assertEqual(len(first["icons"]), 3)
        self.assertFalse({x["id"] for x in first["icons"]} & {x["id"] for x in second["icons"]})
        self.assertNotEqual(self.h.run("icons", "--limit", "101", check=False)["returncode"], 0)

    def test_icon_changes_only_owned_session_appearance_and_preserves_execution_evidence(self):
        before = self.h.state()
        self.assertEqual(before["nodes"][self.h.node]["iconId"], "md-robot")
        result = self.h.run("icon", "--actor-id", self.h.node, "--token", self.h.token,
                            "--icon", "nf-md-duck", "--color", "teal")
        self.assertEqual(result["iconId"], "md-duck")
        self.assertEqual(result["iconColor"], "teal")
        after = self.h.state()
        before["nodes"][self.h.node]["iconId"] = "md-duck"
        before["nodes"][self.h.node]["iconColor"] = "teal"
        self.assertEqual(after, before)
        icons_path = self.h.root / "observer" / "icons.json"
        icons = json.loads(icons_path.read_text())
        self.assertEqual(icons["icons"][0]["nodeId"], self.h.node)
        self.assertEqual(icons["icons"][0]["iconId"], "md-duck")
        self.assertEqual(icons_path.stat().st_mode & 0o777, 0o600)
        projection_path = self.h.root / "observer" / "current.json"
        old_projection = json.loads(projection_path.read_text())
        for node in old_projection["nodes"]:
            node.pop("iconId", None)
            node.pop("iconColor", None)
        projection_path.write_text(json.dumps(old_projection))
        self.assertEqual(json.loads(icons_path.read_text()), icons)
        self.h.run("status", "--actor-id", self.h.node, "--token", self.h.token)
        self.assertEqual(self.h.state()["nodes"][self.h.node]["iconId"], "md-duck")
        color_only = self.h.run("icon", "--actor-id", self.h.node, "--token", self.h.token, "--color", "blue")
        self.assertEqual(color_only["iconId"], "md-duck")
        glyph_only = self.h.run("icon", "--actor-id", self.h.node, "--token", self.h.token, "--icon", "browser")
        self.assertEqual(glyph_only["iconId"], "fa-edge")
        self.assertEqual(glyph_only["iconColor"], "blue")

    def test_icon_rejects_other_callers_invalid_tokens_targets_and_unknown_glyphs(self):
        before = self.h.state()
        bad_env = self.h.env.copy()
        bad_env["CMUX_SURFACE_ID"] = str(uuid.uuid4())
        denied = self.h.run("icon", "--actor-id", self.h.node, "--token", self.h.token,
                            "--icon", "md-duck", check=False, env=bad_env)
        self.assertNotEqual(denied["returncode"], 0)
        for arguments in [
            ["--icon", "nf-mdi-altimeter"],
            ["--icon", "cod-blank"],
            ["--icon", "../../private"],
            ["--color", "orange"],
            ["--icon", "md-duck", "--worker-id", self.h.node],
            [],
        ]:
            result = self.h.run("icon", "--actor-id", self.h.node, "--token", self.h.token,
                                *arguments, check=False)
            self.assertNotEqual(result["returncode"], 0)
        wrong_token = self.h.run("icon", "--actor-id", self.h.node, "--token", "wrong",
                                "--icon", "md-duck", check=False)
        self.assertNotEqual(wrong_token["returncode"], 0)
        self.assertEqual(self.h.state(), before)

    def test_worker_startup_icon_survives_follow_up_and_cannot_be_changed_with_parent_token(self):
        worker = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Icon worker", "--cwd", str(REPO), "--task", "Complete the bounded task.",
            "--icon", "canary", "--color", "purple"
        )
        identifier = worker["workerId"]
        completed = self.h.wait_node(identifier, lambda node: node["phase"] == "reported-completed")
        self.assertEqual(completed["iconId"], "md-bird")
        self.assertEqual(completed["iconColor"], "purple")
        denied = self.h.run("icon", "--actor-id", identifier, "--token", self.h.token,
                            "--icon", "md-duck", check=False)
        self.assertNotEqual(denied["returncode"], 0)
        worker_token = self.h.cmux_data()["tokens"][identifier]
        worker_env = self.h.env.copy()
        worker_env["CMUX_SURFACE_ID"] = worker["surfaceId"]
        chosen = self.h.run("icon", "--actor-id", identifier, "--token", worker_token,
                            "--icon", "md-duck", "--color", "teal", env=worker_env)
        self.assertEqual(chosen["iconId"], "md-duck")
        self.h.run("follow-up", "--actor-id", self.h.node, "--token", self.h.token,
                   "--worker-id", identifier, "--task", "Complete one follow-up.")
        followed = self.h.wait_node(identifier, lambda node: node["generation"] == 2 and node["phase"] == "reported-completed")
        self.assertEqual(followed["iconId"], "md-duck")
        self.assertEqual(followed["iconColor"], "teal")

    def test_git_counts_cover_net_head_changes_untracked_binary_and_refresh(self):
        worktree = self.h.path / "changes"
        worktree.mkdir()

        def git(*arguments):
            return subprocess.run(
                ["/usr/bin/git", "-C", str(worktree), *arguments],
                check=True, capture_output=True,
            )

        git("init", "-q", "-b", "main")
        git("config", "user.email", "test@example.com")
        git("config", "user.name", "Test")
        (worktree / "text").write_text("one\ntwo\n")
        (worktree / "binary").write_bytes(b"\0old")
        git("add", ".")
        git("commit", "-qm", "initial")
        (worktree / "text").write_text("one\nthree\nfour\n")
        git("add", "text")
        (worktree / "text").write_text("one\nthree\nfour\nfive\n")
        (worktree / "binary").write_bytes(b"\0new")
        (worktree / "untracked").write_text("not counted as added lines\n")
        subdirectory = worktree / "subdirectory"
        subdirectory.mkdir()
        observed = self._register_with_cwd(
            subdirectory, "00000000-0000-4000-8000-000000000090"
        )
        expected = {"files": 3, "insertions": 3, "deletions": 1,
                    "untrackedFiles": 1, "binaryFiles": 1}
        self.assertEqual(observed["gitChangesStatus"], "verified")
        self.assertEqual(observed["gitChanges"], expected)
        public = json.loads((self.h.root / "observer" / "current.json").read_text())
        projected = next(node for node in public["nodes"] if node["id"] == observed["id"])
        self.assertEqual(projected["gitChanges"], expected)
        self.assertNotIn("untracked\"", json.dumps(projected))
        git("add", ".")
        git("commit", "-qm", "changes")
        clean = CONTROLLER_API["git_display_metadata"](worktree)
        self.assertEqual(clean["gitChanges"], dict.fromkeys(expected, 0))
        git("mv", "text", "renamed")
        renamed = CONTROLLER_API["git_display_metadata"](worktree)
        self.assertEqual(renamed["gitChanges"]["files"], 1)
        self.assertEqual(renamed["gitChanges"]["insertions"], 0)
        self.assertEqual(renamed["gitChanges"]["deletions"], 0)

    def test_git_count_parser_rejects_partial_invalid_and_excessive_evidence(self):
        parse = CONTROLLER_API["parse_git_change_counts"]
        for numstat, untracked in [
            (b"1\t2\tpath", b""), (b"1\t2\tpath\0", b"partial"),
            (b"-\t2\tpath\0", b""), (b"1\t2\t\0old\0", b""),
            (b"1\t2\tpath\0" + b"1\t2\tpath\0", b""),
            (b"1000000001\t0\tpath\0", b""), (b"bogus\0", b""),
        ]:
            self.assertIsNone(parse(numstat, untracked), (numstat, untracked))
        self.assertEqual(
            parse(b"1\t2\twith\ttab\nand-newline\0", b"other\npath\0"),
            {"files": 2, "insertions": 1, "deletions": 2, "untrackedFiles": 1, "binaryFiles": 0},
        )
        for changes in [
            {"files": True, "insertions": 0, "deletions": 0, "untrackedFiles": 0, "binaryFiles": 0},
            {"files": 0, "insertions": 1, "deletions": 0, "untrackedFiles": 0, "binaryFiles": 0},
        ]:
            self.assertFalse(CONTROLLER_API["valid_git_changes"](changes))

    def test_git_count_probe_bounds_output_and_time(self):
        for name, source in {
            "oversized": "#!/usr/bin/env python3\nimport sys\nsys.stdout.buffer.write(b'x' * 1100000)\n",
            "timeout": "#!/usr/bin/env python3\nimport time\ntime.sleep(2)\n",
            "failure": "#!/bin/sh\nexit 7\n",
        }.items():
            executable = self.h.path / name
            executable.write_text(source)
            executable.chmod(0o755)
            self.assertIsNone(CONTROLLER_API["git_change_query"](str(executable), self.h.path, "diff"))

    def test_explicit_cwd_publishes_only_bounded_verified_git_labels(self):
        worktree = self.h.path / "display-worktree"
        worktree.mkdir()
        subprocess.run(
            ["/usr/bin/git", "init", "-q", "-b", "feature/hierarchy", str(worktree)],
            check=True, capture_output=True, text=True,
        )
        surface = "00000000-0000-4000-8000-000000000099"
        self.h.add_surface(surface)
        env = self.h.env.copy()
        env["CMUX_SURFACE_ID"] = surface
        registration = self.h.run(
            "register", "--workspace", self.h.workspace, "--surface", surface,
            "--cwd", str(worktree), "--name", "Display coordinator",
            env=env,
        )
        private = self.h.state()["nodes"][registration["coordinatorId"]]
        public = json.loads((self.h.root / "observer" / "current.json").read_text())
        observed = next(node for node in public["nodes"] if node["id"] == registration["coordinatorId"])
        self.assertEqual(private["workingDirectory"], str(worktree))
        self.assertEqual(observed["worktreeLabel"], "display-worktree")
        self.assertEqual(observed["branchLabel"], "feature/hierarchy")
        self.assertEqual(observed["gitEvidenceStatus"], "verified")
        self.assertIsNotNone(observed["gitEvidenceAt"])
        self.assertEqual(observed["gitChangesStatus"], "unavailable")
        self.assertIsNone(observed["gitChanges"])
        self.assertIsNone(observed["copilotSessionId"])
        self.assertNotIn("workingDirectory", observed)
        self.assertNotIn(str(worktree), json.dumps(observed))

    def test_git_evidence_refreshes_branch_detachment_and_missing_directory(self):
        worktree = self.h.path / "refresh-worktree"
        worktree.mkdir()
        subprocess.run(
            ["/usr/bin/git", "init", "-q", "-b", "branch-a", str(worktree)],
            check=True, capture_output=True, text=True,
        )
        subprocess.run(
            ["/usr/bin/git", "-C", str(worktree), "config", "user.email", "test@example.com"],
            check=True,
        )
        subprocess.run(
            ["/usr/bin/git", "-C", str(worktree), "config", "user.name", "Test"],
            check=True,
        )
        (worktree / "tracked").write_text("one")
        subprocess.run(
            ["/usr/bin/git", "-C", str(worktree), "add", "tracked"], check=True
        )
        subprocess.run(
            ["/usr/bin/git", "-C", str(worktree), "commit", "-qm", "initial"], check=True
        )
        surface = "00000000-0000-4000-8000-000000000091"
        self.h.add_surface(surface)
        env = self.h.env.copy()
        env["CMUX_SURFACE_ID"] = surface
        registration = self.h.run(
            "register", "--workspace", self.h.workspace, "--surface", surface,
            "--cwd", str(worktree), "--name", "Refresh coordinator", env=env,
        )
        identifier = registration["coordinatorId"]
        token = registration["controlToken"]
        initial = self.h.state()["nodes"][identifier]
        self.assertEqual(initial["branchLabel"], "branch-a")

        subprocess.run(
            ["/usr/bin/git", "-C", str(worktree), "switch", "-qc", "branch-b"],
            check=True,
        )
        self.h.run("status", "--actor-id", identifier, "--token", token, env=env)
        switched = self.h.state()["nodes"][identifier]
        self.assertEqual(switched["branchLabel"], "branch-b")
        self.assertGreaterEqual(switched["gitEvidenceAt"], initial["gitEvidenceAt"])

        subprocess.run(
            ["/usr/bin/git", "-C", str(worktree), "checkout", "-q", "--detach"],
            check=True,
        )
        self.h.run("status", "--actor-id", identifier, "--token", token, env=env)
        detached = self.h.state()["nodes"][identifier]
        self.assertEqual(detached["worktreeLabel"], "refresh-worktree")
        self.assertIsNone(detached["branchLabel"])
        self.assertEqual(detached["gitEvidenceStatus"], "verified")

        moved = self.h.path / "moved-refresh-worktree"
        worktree.rename(moved)
        self.h.run("status", "--actor-id", identifier, "--token", token, env=env)
        missing = self.h.state()["nodes"][identifier]
        self.assertIsNone(missing["worktreeLabel"])
        self.assertIsNone(missing["branchLabel"])
        self.assertEqual(missing["gitEvidenceStatus"], "unavailable")

    def test_only_successful_git_root_produces_worktree_label(self):
        non_git = self.h.path / "ordinary-directory"
        non_git.mkdir()
        observed = self._register_with_cwd(
            non_git, "00000000-0000-4000-8000-000000000092"
        )
        self.assertIsNone(observed["worktreeLabel"])
        self.assertIsNone(observed["branchLabel"])
        self.assertEqual(observed["gitEvidenceStatus"], "unavailable")

        repository = self.h.path / "main-repository"
        repository.mkdir()
        subprocess.run(
            ["/usr/bin/git", "init", "-q", "-b", "main", str(repository)], check=True
        )
        subprocess.run(
            ["/usr/bin/git", "-C", str(repository), "config", "user.email", "test@example.com"],
            check=True,
        )
        subprocess.run(
            ["/usr/bin/git", "-C", str(repository), "config", "user.name", "Test"],
            check=True,
        )
        (repository / "tracked").write_text("one")
        subprocess.run(["/usr/bin/git", "-C", str(repository), "add", "tracked"], check=True)
        subprocess.run(
            ["/usr/bin/git", "-C", str(repository), "commit", "-qm", "initial"], check=True
        )
        linked = self.h.path / "linked-worktree"
        subprocess.run(
            ["/usr/bin/git", "-C", str(repository), "worktree", "add", "-q", "-b",
             "linked-branch", str(linked)],
            check=True,
        )
        observed = self._register_with_cwd(
            linked, "00000000-0000-4000-8000-000000000093"
        )
        self.assertEqual(observed["worktreeLabel"], "linked-worktree")
        self.assertEqual(observed["branchLabel"], "linked-branch")
        self.assertEqual(observed["gitEvidenceStatus"], "verified")

    def test_failed_malformed_overlong_and_timed_out_git_never_publish_labels(self):
        cwd = self.h.path / "probe-directory"
        cwd.mkdir()
        behaviors = {
            "failure": "#!/bin/sh\nexit 7\n",
            "malformed": "#!/bin/sh\nprintf '\\377\\376'\n",
            "overlong-label": "#!/bin/sh\npython3 -c 'print(\"x\" * 121)'\n",
            "overlong": "#!/bin/sh\npython3 -c 'print(\"x\" * 5000)'\n",
            "timeout": "#!/bin/sh\nsleep 2\n",
        }
        for index, (name, source) in enumerate(behaviors.items(), start=94):
            fake_git = self.h.path / f"git-{name}"
            fake_git.write_text(source)
            fake_git.chmod(0o755)
            env = self.h.env.copy()
            env["CMUX_MAESTRO_GIT"] = str(fake_git)
            observed = self._register_with_cwd(
                cwd, f"00000000-0000-4000-8000-0000000000{index}", env=env
            )
            self.assertIsNone(observed["worktreeLabel"], name)
            self.assertIsNone(observed["branchLabel"], name)
            self.assertEqual(observed["gitEvidenceStatus"], "unavailable", name)

    def test_follow_up_refreshes_exact_worker_git_evidence_and_publishes_session_identity(self):
        worktree = self.h.path / "worker-worktree"
        worktree.mkdir()
        subprocess.run(
            ["/usr/bin/git", "init", "-q", "-b", "branch-a", str(worktree)], check=True
        )
        subprocess.run(
            ["/usr/bin/git", "-C", str(worktree), "config", "user.email", "test@example.com"],
            check=True,
        )
        subprocess.run(
            ["/usr/bin/git", "-C", str(worktree), "config", "user.name", "Test"],
            check=True,
        )
        (worktree / "tracked").write_text("one")
        subprocess.run(["/usr/bin/git", "-C", str(worktree), "add", "tracked"], check=True)
        subprocess.run(
            ["/usr/bin/git", "-C", str(worktree), "commit", "-qm", "initial"], check=True
        )
        worker = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Git worker", "--cwd", str(worktree), "--task", "first turn",
        )
        idle = self.h.wait_node(
            worker["workerId"], lambda node: node["availability"] == "idle"
        )
        self.assertEqual(idle["branchLabel"], "branch-a")
        subprocess.run(
            ["/usr/bin/git", "-C", str(worktree), "switch", "-qc", "branch-b"],
            check=True,
        )
        self.h.run(
            "follow-up", "--actor-id", self.h.node, "--token", self.h.token,
            "--worker-id", worker["workerId"], "--task", "second turn",
        )
        refreshed = self.h.wait_node(
            worker["workerId"], lambda node: node["branchLabel"] == "branch-b"
        )
        self.assertGreaterEqual(refreshed["gitEvidenceAt"], idle["gitEvidenceAt"])
        public = json.loads((self.h.root / "observer" / "current.json").read_text())
        observed = next(
            node for node in public["nodes"] if node["id"] == worker["workerId"]
        )
        self.assertEqual(observed["copilotSessionId"], worker["sessionId"])
        self.assertNotIn("workingDirectory", observed)

    def test_git_probe_runs_outside_global_state_mutation_lock(self):
        cwd = self.h.path / "probe-lock-worktree"
        cwd.mkdir()
        ready = self.h.path / "git-probe.ready"
        release = self.h.path / "git-probe.release"
        fake_git = self.h.path / "git-blocking"
        fake_git.write_text(
            "#!/bin/sh\n"
            f"touch '{ready}'\n"
            f"while [ ! -e '{release}' ]; do sleep 0.02; done\n"
            "case \"$*\" in\n"
            f"  *show-toplevel*) printf '%s\\n' '{cwd}' ;;\n"
            "  *symbolic-ref*) printf '%s\\n' 'branch-a' ;;\n"
            "esac\n"
        )
        fake_git.chmod(0o755)
        surface = "00000000-0000-4000-8000-000000000098"
        self.h.add_surface(surface)
        env = self.h.env.copy()
        env["CMUX_SURFACE_ID"] = surface
        env["CMUX_MAESTRO_GIT"] = str(fake_git)
        registration = self.h.start(
            "register", "--workspace", self.h.workspace, "--surface", surface,
            "--cwd", str(cwd), "--name", "Blocking probe", env=env,
        )
        deadline = time.monotonic() + 3
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(ready.exists())
        started = time.monotonic()
        self.h.run("status", "--actor-id", self.h.node, "--token", self.h.token)
        self.assertLess(time.monotonic() - started, 1)
        release.write_text("release")
        completed = self.h.finish(registration, timeout=5)
        self.assertEqual(completed["returncode"], 0)

    def _register_with_cwd(self, cwd, surface, env=None):
        self.h.add_surface(surface)
        caller = (env or self.h.env).copy()
        caller["CMUX_SURFACE_ID"] = surface
        registration = self.h.run(
            "register", "--workspace", self.h.workspace, "--surface", surface,
            "--cwd", str(cwd), "--name", "Metadata coordinator", env=caller,
            timeout=20,
        )
        public = json.loads((self.h.root / "observer" / "current.json").read_text())
        return next(
            node for node in public["nodes"]
            if node["id"] == registration["coordinatorId"]
        )

    def test_concurrent_startup_handshake_and_exact_identity(self):
        worker = self.h.spawn("[DELAY] [STDERR]")
        completed = self.h.wait_node(
            worker["workerId"],
            lambda node: node["phase"] == "reported-completed" and node["availability"] == "idle",
        )
        self.assertGreater(completed["supervisor"]["pid"], 0)
        self.assertEqual(completed["iconId"], "md-robot")
        self.assertEqual(completed["result"], "bounded completed")
        first = self.h.calls()[0]["args"]
        self.assertIn("--session-id", first)
        self.assertNotIn("--resume", first)
        self.assertNotIn("--allow-all", first)
        sends = [call for call in self.h.cmux_data()["calls"] if "send" in call]
        self.assertEqual(len(sends), 0)
        created = next(call for call in self.h.cmux_data()["calls"] if "surface.create" in call)
        parameters = json.loads(created[created.index("surface.create") + 1])
        self.assertNotIn("initial_input", parameters)
        self.assertNotIn("--token", parameters["initial_command"])
        self.assertEqual(parameters["workspace_id"], self.h.workspace)
        self.assertEqual(parameters["pane_id"], self.h.pane)
        self.assertIs(parameters["focus"], False)
        self.assertEqual(set(parameters["startup_environment"]), {"PATH"})
        log = self.h.path / f"runtime-{worker['surfaceId']}.log"
        self.assertIn("visible permission diagnostic", log.read_text())

    def test_direct_surface_creation_does_not_fallback_to_shell_input(self):
        with patch.dict(os.environ, self.h.env):
            cmux = CONTROLLER_API["Cmux"]()
        calls = []

        def unsupported(*arguments):
            calls.append(arguments)
            raise CONTROLLER_API["OrchestrationError"]("surface.create is unavailable")

        cmux.run = unsupported
        with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "unavailable"):
            cmux.create_surface(self.h.workspace, self.h.pane, str(REPO), "/exact/runtime runtime")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:2], ("rpc", "surface.create"))
        self.assertEqual(CONTROLLER_API["STARTUP_SECONDS"], 8)

    def test_archive_refuses_external_create_attach_gap_and_tracks_surface(self):
        barrier = self.h.path / "attach-barrier"
        env = self.h.env.copy()
        env["CMUX_MAESTRO_TEST_ATTACH_BARRIER"] = str(barrier)
        process = self.h.start(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Barrier worker", "--cwd", str(REPO), "--task", "bounded",
            env=env,
        )
        deadline = time.monotonic() + 5
        ready = barrier.with_suffix(".ready")
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(ready.exists())
        created = set(self.h.cmux_data()["surfaces"]) - {self.h.surface}
        self.assertEqual(len(created), 1)
        launch = next(iter(self.h.state()["launches"].values()))
        self.assertEqual(launch["surfaceId"], next(iter(created)))
        refused = self.h.run(
            "archive", "--actor-id", self.h.node, "--token", self.h.token,
            check=False,
        )
        self.assertEqual(refused["returncode"], 2)
        self.assertIn("worker launch is in progress", refused["stderr"])
        barrier.with_suffix(".release").write_text("release")
        worker = self.h.finish(process)
        self.h.wait_node(worker["workerId"], lambda node: node["availability"] == "idle")
        archived = self.h.run(
            "archive", "--actor-id", self.h.node, "--token", self.h.token,
            timeout=12,
        )
        self.assertTrue(archived["archived"])
        state = self.h.state()
        self.assertEqual(state["launches"], {})
        self.assertEqual(
            {item["surfaceId"] for item in state["retainedResources"]}, created
        )

        self.h.registration = self.h.run(
            "register", "--workspace", self.h.workspace, "--surface", self.h.surface,
            "--name", "Replacement coordinator",
        )
        for index in range(7):
            added = self.h.spawn(label=f"Capacity {index}")
            self.h.wait_node(added["workerId"], lambda node: node["availability"] == "idle")
        surfaces_before = set(self.h.cmux_data()["surfaces"])
        ninth = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Over capacity", "--cwd", str(REPO), "--task", "bounded",
            check=False,
        )
        self.assertEqual(ninth["returncode"], 2)
        self.assertEqual(set(self.h.cmux_data()["surfaces"]), surfaces_before)

    def test_archive_winning_before_spawn_creates_no_surface(self):
        self.h.run("archive", "--actor-id", self.h.node, "--token", self.h.token)
        surfaces_before = set(self.h.cmux_data()["surfaces"])
        rejected = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Too late", "--cwd", str(REPO), "--task", "bounded",
            check=False,
        )
        self.assertEqual(rejected["returncode"], 2)
        self.assertEqual(set(self.h.cmux_data()["surfaces"]), surfaces_before)

    def test_failed_attachment_retains_exact_created_surface_in_capacity(self):
        env = self.h.env.copy()
        env["CMUX_MAESTRO_TEST_ATTACH_FAILURE"] = "1"
        failed = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Attachment failure", "--cwd", str(REPO), "--task", "bounded",
            check=False, env=env,
        )
        self.assertEqual(failed["returncode"], 2)
        state = self.h.state()
        failed_node = next(
            node for node in state["nodes"].values()
            if node["role"] == "worker"
        )
        self.assertEqual(failed_node["phase"], "launch-failed")
        self.assertIn(failed_node["surfaceId"], self.h.cmux_data()["surfaces"])
        self.assertEqual(state["launches"], {})
        for index in range(7):
            worker = self.h.spawn(label=f"Capacity {index}")
            self.h.wait_node(worker["workerId"], lambda node: node["availability"] == "idle")
        surfaces_before = set(self.h.cmux_data()["surfaces"])
        rejected = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Ninth", "--cwd", str(REPO), "--task", "bounded",
            check=False,
        )
        self.assertEqual(rejected["returncode"], 2)
        self.assertEqual(set(self.h.cmux_data()["surfaces"]), surfaces_before)

    def test_follow_up_waits_for_verified_boundary_and_uses_exact_resume(self):
        worker = self.h.spawn("[CLI_REPORT] [DELAY]")
        pending = self.h.wait_node(worker["workerId"], lambda node: node["pendingReport"] is not None)
        self.assertEqual(pending["availability"], "busy")
        rejected = self.h.run(
            "follow-up", "--actor-id", self.h.node, "--token", self.h.token,
            "--worker-id", worker["workerId"], "--task", "second turn",
            check=False,
        )
        self.assertEqual(rejected["returncode"], 2)
        self.assertTrue(
            "verified idle boundary" in rejected["stderr"]
            or "state changed before follow-up" in rejected["stderr"],
            rejected["stderr"],
        )
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
        self.assertEqual(len(send_calls), 0, "legacy follow-up must use the private queue, not terminal input")

    def test_missing_report_and_invalid_boundary_transition_automatically(self):
        missing = self.h.spawn("[NO_REPORT]")
        missing_node = self.h.wait_node(missing["workerId"], lambda node: node["phase"] == "report-missing")
        self.assertEqual(missing_node["availability"], "idle")
        self.assertEqual(
            missing_node["verifiedBoundaryGeneration"], missing_node["generation"]
        )
        recovered = self.h.run(
            "follow-up", "--actor-id", self.h.node, "--token", self.h.token,
            "--worker-id", missing["workerId"], "--task", "recover exact session",
        )
        self.h.wait_node(
            missing["workerId"],
            lambda node: (
                node["generation"] == recovered["generation"]
                and node["phase"] == "reported-completed"
            ),
        )
        malformed = self.h.spawn("[MALFORMED]", label="Malformed")
        failed = self.h.wait_node(malformed["workerId"], lambda node: node["phase"] == "turn-failed")
        self.assertEqual(failed["availability"], "idle")
        self.assertIn("valid exact-session", failed["result"])

    def test_nonzero_exact_session_never_finalizes_pending_report(self):
        for task in (
            "[CLI_REPORT] [EXIT7]",
            "[CLI_REPORT] [BLOCKED] [EXIT7]",
            "[CLI_REPORT] [FAIL] [EXIT7]",
        ):
            with self.subTest(task=task):
                worker = self.h.spawn(task, label=f"Exit {task}")
                failed = self.h.wait_node(
                    worker["workerId"], lambda node: node["phase"] == "turn-failed"
                )
                self.assertEqual(failed["availability"], "idle")
                self.assertIn("exited with status 7", failed["result"])
                rejected = self.h.run(
                    "follow-up", "--actor-id", self.h.node, "--token", self.h.token,
                    "--worker-id", worker["workerId"], "--task", "must reject",
                    check=False,
                )
                self.assertEqual(rejected["returncode"], 2)

    def test_older_verified_boundary_cannot_authorize_failed_new_generation(self):
        worker = self.h.spawn()
        self.h.wait_node(
            worker["workerId"], lambda node: node["phase"] == "reported-completed"
        )
        follow = self.h.run(
            "follow-up", "--actor-id", self.h.node, "--token", self.h.token,
            "--worker-id", worker["workerId"], "--task", "[EXIT7]",
        )
        failed = self.h.wait_node(
            worker["workerId"],
            lambda node: (
                node["generation"] == follow["generation"]
                and node["phase"] == "turn-failed"
            ),
        )
        self.assertEqual(failed["verifiedBoundaryGeneration"], 1)
        rejected = self.h.run(
            "follow-up", "--actor-id", self.h.node, "--token", self.h.token,
            "--worker-id", worker["workerId"], "--task", "unsafe retry",
            check=False,
        )
        self.assertEqual(rejected["returncode"], 2)
        self.assertIn("current generation", rejected["stderr"])

    def test_bounded_stream_protocol_rejects_invalid_frames_and_results(self):
        cases = [
            "[NO_REPORT] [OVERSIZED]", "[NO_REPORT] [SCALAR]",
            "[NO_REPORT] [MISSING_RESULT]", "[NO_REPORT] [FUTURE_RESULT]",
            "[NO_REPORT] [DUPLICATE_RESULT]", "[NO_REPORT] [BOOL_EXIT]",
        ]
        for index, task in enumerate(cases):
            with self.subTest(task=task):
                worker = self.h.spawn(task, label=f"Protocol {index}")
                failed = self.h.wait_node(
                    worker["workerId"], lambda node: node["phase"] == "turn-failed"
                )
                self.assertIn("valid exact-session", failed["result"])

    def test_silent_turn_heartbeats_and_short_stderr_is_visible_before_exit(self):
        heartbeat_env = self.h.env.copy()
        heartbeat_env["CMUX_MAESTRO_HEARTBEAT_SECONDS"] = "0.05"
        silent = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Silent", "--cwd", str(REPO), "--task", "[SILENT]",
            env=heartbeat_env,
        )
        running = self.h.wait_node(
            silent["workerId"],
            lambda node: node["phase"] == "turn-running" and node["pendingReport"] is None,
        )
        initial_update = running["updatedAt"]
        heartbeat = self.h.wait_node(
            silent["workerId"],
            lambda node: (
                node["phase"] == "turn-running"
                and node["pendingReport"] is None
                and node["updatedAt"] != initial_update
            ),
        )
        self.assertNotEqual(heartbeat["updatedAt"], initial_update)

        prompt = self.h.spawn("[STDERR_WAIT]", label="Approval")
        deadline = time.monotonic() + 3
        log = self.h.path / f"runtime-{prompt['surfaceId']}.log"
        while (
            (not self.h.stderr_ready.exists() or not log.exists()
             or "approval prompt before completion" not in log.read_text())
            and time.monotonic() < deadline
        ):
            time.sleep(0.02)
        self.assertTrue(self.h.stderr_ready.exists())
        self.assertIn("approval prompt before completion", log.read_text())
        self.assertEqual(self.h.state()["nodes"][prompt["workerId"]]["phase"], "turn-running")

    def test_permission_free_final_report_uses_real_envelope(self):
        worker = self.h.spawn("[DENIED]", label="Read-only contract")
        completed = self.h.wait_node(
            worker["workerId"], lambda node: node["phase"] == "reported-completed"
        )
        self.assertEqual(completed["result"], "bounded completed")
        self.assertIsNone(completed["pendingReport"])
        self.assertEqual(completed["verifiedBoundaryGeneration"], 1)
        call = self.h.calls()[0]
        self.assertNotIn("--allow-tool", call["args"])
        self.assertNotIn("--deny-tool", call["args"])

        skill = (REPO / ".agents/skills/cmux-maestro-orchestrate/SKILL.md").read_text()
        self.assertNotIn("CURRENT_GENERATION", skill)
        self.assertIn("cmux-maestro.worker-report", skill)
        self.assertIn('"phase":"final_answer"', skill)
        self.assertIn("do not call a tool", skill)

    def test_terminal_bookkeeping_does_not_admit_late_work_or_post_result_events(self):
        cases = [
            ("[AFTER_FINAL_TOOL]", "report-missing"),
            ("[AFTER_FINAL_CONTENT]", "report-missing"),
            ("[BOOKKEEPING_WITH_CONTENT]", "report-missing"),
            ("[BACKGROUND_NOTICE_WITH_CONTENT]", "report-missing"),
            ("[PERSISTENT_AUXILIARY]", "report-missing"),
            ("[AUXILIARY_WITH_TOOL]", "report-missing"),
            ("[AFTER_FINAL_MALFORMED]", "turn-failed"),
            ("[AFTER_RESULT_BOOKKEEPING]", "turn-failed"),
        ]
        for index, (task, expected) in enumerate(cases):
            with self.subTest(task=task):
                worker = self.h.spawn(task, label=f"Late event {index}")
                node = self.h.wait_node(
                    worker["workerId"], lambda value: value["phase"] == expected
                )
                self.assertNotEqual(node["phase"], "reported-completed")

    def test_permission_words_in_payload_are_not_provider_policy_denials(self):
        for index, marker in enumerate((
            "[SUCCESS_PERMISSION_TEXT]", "[FAILED_OTHER_ERROR]", "[NESTED_PERMISSION_TEXT]",
        )):
            with self.subTest(marker=marker):
                worker = self.h.spawn(f"[NO_REPORT] {marker}", label=f"Payload {index}")
                node = self.h.wait_node(
                    worker["workerId"], lambda value: value["phase"] == "report-missing"
                )
                self.assertNotIn("Copilot tool permission was denied", node["result"])

    def assert_strict_report_cases(self, cases):
        for index, (task, diagnostic) in enumerate(cases):
            with self.subTest(task=task):
                worker = self.h.spawn(task, label=f"Strict report {index}")
                missing = self.h.wait_node(
                    worker["workerId"], lambda node: node["phase"] == "report-missing"
                )
                self.assertEqual(missing["verifiedBoundaryGeneration"], 1)
                self.assertIn(diagnostic.casefold(), missing["result"].casefold())

    def test_final_answer_report_shape_identity_and_generation_are_strict(self):
        self.assert_strict_report_cases([
            ("[WRONG_REPORT_WORKER]", "invalid"),
            ("[WRONG_REPORT_GENERATION]", "invalid"),
            ("[WRONG_REPORT_VERSION]", "invalid"),
            ("[WRONG_REPORT_STATE]", "invalid"),
            ("[EXTRA_REPORT_FIELD]", "invalid"),
            ("[DUPLICATE_REPORT_KEY]", "invalid"),
        ])

    def test_final_answer_report_framing_and_conflicts_are_strict(self):
        self.assert_strict_report_cases([
            ("[FENCED_REPORT]", "invalid"),
            ("[REPORT_TOOL_REQUEST]", "invalid"),
            ("[DUPLICATE_FINAL_REPORT]", "conflicting"),
            ("[DUAL_REPORT]", "Conflicting lifecycle report channels"),
            ("[NORMAL_FINAL]", "invalid"),
        ])

    def test_permission_denial_without_report_is_visible_and_recoverable(self):
        worker = self.h.spawn("[DENIED_NO_REPORT]", label="Denied")
        denied = self.h.wait_node(
            worker["workerId"], lambda node: node["phase"] == "permission-denied"
        )
        self.assertEqual(denied["availability"], "idle")
        self.assertEqual(denied["verifiedBoundaryGeneration"], 1)
        self.assertNotIn("bash", denied["result"])
        follow = self.h.run(
            "follow-up", "--actor-id", self.h.node, "--token", self.h.token,
            "--worker-id", worker["workerId"], "--task", "return a valid report",
        )
        completed = self.h.wait_node(
            worker["workerId"],
            lambda node: (
                node["generation"] == follow["generation"]
                and node["phase"] == "reported-completed"
            ),
        )
        self.assertEqual(completed["verifiedBoundaryGeneration"], 2)
        calls = self.h.calls()
        self.assertEqual(
            calls[1]["args"][calls[1]["args"].index("--resume") + 1],
            worker["sessionId"],
        )

    def test_explicit_tool_policy_is_private_deny_first_and_non_escalating(self):
        denied = self.h.spawn(
            label="Deny precedence",
            allow=("shell", "read", "read"),
            deny=("read", "network"),
        )
        self.h.wait_node(denied["workerId"], lambda node: node["availability"] == "idle")
        first_args = self.h.calls()[0]["args"]
        self.assertEqual(
            [first_args[index + 1] for index, value in enumerate(first_args) if value == "--allow-tool"],
            ["shell"],
        )
        self.assertEqual(
            [first_args[index + 1] for index, value in enumerate(first_args) if value == "--deny-tool"],
            ["read", "network"],
        )
        observer = json.loads(
            (self.h.root / "observer" / "current.json").read_text()
        )
        self.assertNotIn("toolPolicy", json.dumps(observer))

        surfaces = set(self.h.cmux_data()["surfaces"])
        broad = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Broad", "--cwd", str(REPO), "--task", "bounded",
            "--allow-tool", "*", check=False,
        )
        self.assertEqual(broad["returncode"], 2)
        self.assertIn("Broad Copilot tool grants", broad["stderr"])
        self.assertEqual(set(self.h.cmux_data()["surfaces"]), surfaces)

        parent = self.h.spawn(
            "[NESTED_SUBSET]", label="Subset parent",
            allow=("read",), deny=("shell(exact)",),
        )
        self.h.wait_node(parent["workerId"], lambda node: node["availability"] == "idle")
        results = [
            json.loads(line) for line in self.h.policy_results.read_text().splitlines()
        ]
        self.assertEqual(results[-1]["kind"], "subset")
        self.assertEqual(results[-1]["returncode"], 0)
        state = self.h.state()
        child = next(
            node for node in state["nodes"].values()
            if node["parentId"] == parent["workerId"]
        )
        self.assertEqual(child["toolPolicy"]["allow"], ["read"])
        self.assertEqual(child["toolPolicy"]["deny"], ["shell(exact)", "network"])

        escalation = self.h.spawn(
            "[NESTED_ESCALATE]", label="Escalating parent",
            allow=("read",), deny=("shell(exact)",),
        )
        self.h.wait_node(escalation["workerId"], lambda node: node["availability"] == "idle")
        results = [
            json.loads(line) for line in self.h.policy_results.read_text().splitlines()
        ]
        self.assertEqual(results[-1]["kind"], "escalate")
        self.assertEqual(results[-1]["returncode"], 2)
        self.assertIn("cannot grant a child additional", results[-1]["stderr"])

    def test_python_projection_and_typed_swift_phase_vocabulary_match(self):
        module = ast.parse(CONTROLLER.read_text())
        assignment = next(
            item for item in module.body
            if isinstance(item, ast.Assign)
            and any(
                isinstance(target, ast.Name) and target.id == "PROJECTED_PHASES"
                for target in item.targets
            )
        )
        projected = ast.literal_eval(assignment.value)
        swift = (
            REPO / "CMUXMaestroSidebar/Orchestration/SidebarOrchestration.swift"
        ).read_text()
        phase_block = swift.split(
            "enum SidebarOrchestrationPhase", 1
        )[1].split("\n}", 1)[0]
        typed = {
            raw or name
            for name, raw in re.findall(
                r'case\s+(\w+)(?:\s*=\s*"([^"]+)")?', phase_block
            )
        }
        self.assertEqual(projected, typed)

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

        def expire(state):
            state["nodes"][self.h.node]["lastControlAt"] = "2000-01-01T00:00:00+00:00"
        self.h.change_state(expire)
        recovered = self.h.run(
            "recover", "--workspace", self.h.workspace, "--surface", self.h.surface,
            "--name", "Recovered",
        )
        self.assertNotEqual(recovered["runId"], self.h.registration["runId"])
        self.assertNotEqual(recovered["controlToken"], self.h.token)

    def test_recovery_refuses_live_worker_and_preserves_other_root(self):
        worker = self.h.spawn()
        self.h.wait_node(worker["workerId"], lambda node: node["availability"] == "idle")
        def expire(state):
            state["nodes"][self.h.node]["lastControlAt"] = "2000-01-01T00:00:00+00:00"
        self.h.change_state(expire)
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

    def test_fixture_mutation_preserves_a_concurrent_idle_supervisor(self):
        worker = self.h.spawn()
        before = self.h.wait_node(worker["workerId"], lambda node: node["availability"] == "idle")

        def expire(state):
            state["nodes"][self.h.node]["lastControlAt"] = "2000-01-01T00:00:00+00:00"
            time.sleep(0.3)
        self.h.change_state(expire)
        after = self.h.state()["nodes"][worker["workerId"]]
        self.assertEqual(after["supervisor"], before["supervisor"])
        self.assertEqual(after["phase"], "reported-completed")
        self.assertTrue(CONTROLLER_API["process_matches"](after))

    def test_archive_history_is_bounded(self):
        def populate(state):
            state["archives"] = [
                {
                    "runId": str(uuid.uuid4()),
                    "coordinatorLabel": "Old",
                    "nodeCount": 1,
                    "archivedAt": "2020-01-01T00:00:00Z",
                }
                for _ in range(32)
            ]
        self.h.change_state(populate)
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
