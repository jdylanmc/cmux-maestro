#!/usr/bin/env python3
import ast
import fcntl
import io
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
import threading
import time
import unittest
from unittest.mock import patch
import uuid
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
CONTROLLER = REPO / "scripts" / "cmux-maestro-orchestrator.py"
CONTROLLER_API = runpy.run_path(str(CONTROLLER))
MAX_LIVE_WORKERS = CONTROLLER_API["MAX_LIVE_WORKERS"]

def legacy_fixture_launcher(original, api):
    def launch(root, cmux, identifier, *args):
        if os.environ.get("FAKE_SESSION_MODE") in {"bounded", "legacy-interactive"}:
            def persisted(state):
                node = state["nodes"][identifier]
                if os.environ["FAKE_SESSION_MODE"] == "bounded":
                    node.pop("executionMode", None)
                node.pop("launchMethod", None)
            api["mutate"](root, persisted)
        return original(root, cmux, identifier, *args)
    return launch

FAKE_CMUX = r'''#!/usr/bin/env python3
import fcntl, json, os, runpy, shlex, subprocess, sys, tempfile, time, uuid
from pathlib import Path

state_path = Path(os.environ["FAKE_CMUX_STATE"])
lock_path = state_path.with_suffix(".lock")
lock_path.parent.mkdir(parents=True, exist_ok=True)
lock = open(lock_path, "a+")
fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
def record_process(process):
    start = subprocess.run(
        ["/bin/ps", "-o", "lstart=", "-p", str(process.pid)],
        capture_output=True, text=True, check=False,
    ).stdout.strip()
    if start:
        state.setdefault("processes", []).append({"pid": process.pid, "start": start})
    elif process.poll() is None:
        raise SystemExit("cannot establish fixture process identity")
    state["pids"].append(process.pid)
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
        if state.get("inventoryUnavailable"):
            raise SystemExit("synthetic host inventory unavailable")
        result = {"workspace_id": workspace, "surfaces": [
            {"id": item, "render_health": "not_started"} for item in state["surfaces"]
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
            control = Path(os.environ["CMUX_MAESTRO_ROOT"]) / "control"
            if "--worker-id" in command_args:
                worker_id = command_args[command_args.index("--worker-id") + 1]
                ticket = json.loads((control / ("launch-" + worker_id + ".json")).read_text())
                state.setdefault("tokens", {})[worker_id] = ticket["token"]
            else:
                assert command_args[:2] == ["/bin/sh", "-c"]
                node = next(n for n in json.loads((control / "state.json").read_text())["nodes"].values()
                            if n.get("copilotSessionId") and n["copilotSessionId"] in bootstrap)
                worker_id = node["id"]
                source = (control / ("direct-" + worker_id + "-1.sh")).read_text()
                token_line = next(line for line in source.splitlines()
                                  if line.startswith("export CMUX_MAESTRO_CONTROL_TOKEN="))
                state.setdefault("tokens", {})[worker_id] = shlex.split(token_line)[1].split("=", 1)[1]
            env = os.environ.copy()
            env.update(creation["startup_environment"])
            env["CMUX_WORKSPACE_ID"] = workspace
            env["CMUX_SURFACE_ID"] = surface
            if env.get("FAKE_DROP_RUNTIME_PATH"):
                env["PATH"] = "/usr/bin:/bin"
                env.pop("CMUX_MAESTRO_COPILOT", None)
            if env.get("FAKE_RUNTIME_COPILOT_MISSING"):
                env["CMUX_MAESTRO_COPILOT"] = env["FAKE_RUNTIME_COPILOT_MISSING"]
            output = open(state_path.parent / ("runtime-" + surface + ".log"), "ab", buffering=0)
            terminal = os.open(env["FAKE_PTY_SLAVE"], os.O_RDWR) if env.get("FAKE_PTY_SLAVE") else None
            if env.get("FAKE_RUNTIME_LOCK"):
                command_args = [sys.executable, "-c", """
import fcntl, os, sys
with open(os.environ["FAKE_RUNTIME_LOCK"]) as latch:
    fcntl.flock(latch.fileno(), fcntl.LOCK_SH)
os.execv(sys.argv[1], sys.argv[1:])
""", *command_args]
            elif env.get("FAKE_RUNTIME_BARRIER"):
                command_args = [sys.executable, "-c", """
import os, sys, time
from pathlib import Path
marker = Path(os.environ["FAKE_RUNTIME_BARRIER"])
marker.with_suffix(".ready").write_text("ready")
deadline = time.monotonic() + 10
while not marker.with_suffix(".release").exists():
    if time.monotonic() >= deadline:
        raise SystemExit("synthetic runtime barrier expired")
    time.sleep(0.01)
os.execv(sys.argv[1], sys.argv[1:])
""", *command_args]
            process = subprocess.Popen(
                command_args, stdin=terminal if terminal is not None else subprocess.DEVNULL,
                stdout=terminal if terminal is not None else output,
                stderr=terminal if terminal is not None else output,
                env=env, cwd=creation["working_directory"], start_new_session=True,
            )
            if terminal is not None:
                os.close(terminal)
            record_process(process)
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
        record_process(process)
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
    if creation is not None and "surface.create" in args and os.environ.get("FAKE_LOST_CREATE_REPLY"):
        raise SystemExit("synthetic lost create reply")
    if creation is not None and "surface.create" in args and os.environ.get("FAKE_CREATE_REPLY_BARRIER"):
        marker = Path(os.environ["FAKE_CREATE_REPLY_BARRIER"])
        marker.with_suffix(".ready").write_text("ready")
        deadline = time.monotonic() + 10
        while not marker.with_suffix(".release").exists():
            if time.monotonic() >= deadline:
                raise SystemExit("synthetic create reply barrier expired")
            time.sleep(0.01)
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
    "cwd": os.getcwd(),
    "pinnedSubscription": os.environ.get("COPILOT_GITHUB_TOKEN") == "synthetic-work-token",
    "gitTokenUnchanged": os.environ.get("GH_TOKEN") == "synthetic-personal-token",
    "pid": os.getpid(),
    "start": subprocess.run(
        ["/bin/ps", "-o", "lstart=", "-p", str(os.getpid())],
        capture_output=True, text=True, check=True,
    ).stdout.strip(),
}
with open(os.environ["FAKE_COPILOT_CALLS"], "a") as stream:
    stream.write(json.dumps(record) + "\n")
if os.environ.get("FAKE_WRITER_GATE"):
    subprocess.run(
        [sys.executable, str(Path(os.environ["FAKE_CMUX_STATE"]).parent / "fixture-writer.py")],
        check=True, start_new_session=True,
    )
if os.environ.get("FAKE_PROVIDER_BARRIER"):
    marker = Path(os.environ["FAKE_PROVIDER_BARRIER"])
    marker.with_suffix(".ready").write_text("ready")
    deadline = time.monotonic() + 10
    while not marker.with_suffix(".release").exists():
        if time.monotonic() >= deadline:
            raise SystemExit("synthetic provider barrier expired")
        time.sleep(0.01)
if "--interactive" in args:
    if os.environ.get("CMUX_MAESTRO_DIRECT_LAUNCH") == "1" and not os.environ.get("FAKE_NO_OBSERVATION"):
        environment = {**os.environ, "SESSION_ID": session}
        observation = {
            "nodeId": os.environ["CMUX_MAESTRO_WORKER_ID"], "workspaceId": os.environ["CMUX_WORKSPACE_ID"],
            "sessionId": session, "generation": int(os.environ["CMUX_MAESTRO_GENERATION"]),
            "surfaceId": os.environ["CMUX_SURFACE_ID"], "pid": os.getpid(),
        }
        result = subprocess.run([os.environ["CMUX_MAESTRO_ORCHESTRATOR"], "native-observe"],
                                input=json.dumps(observation), env=environment, text=True, capture_output=True)
        if result.returncode:
            print(result.stderr, file=sys.stderr, flush=True)
            raise SystemExit(2)
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

FAKE_WRITER = r'''
import json, os, subprocess, time
from pathlib import Path

gate = Path(os.environ["FAKE_WRITER_GATE"])
start = subprocess.run(
    ["/bin/ps", "-o", "lstart=", "-p", str(os.getpid())],
    capture_output=True, text=True, check=True,
).stdout.strip()
(gate / "ready").write_text(json.dumps({"pid": os.getpid(), "start": start}))
try:
    deadline = time.monotonic() + 15
    while not (gate / "release").exists():
        if time.monotonic() >= deadline:
            raise SystemExit("fixture writer gate expired")
        time.sleep(0.01)
    (Path(os.environ["FAKE_CMUX_STATE"]).parent / "late-publication").write_text("published")
    (gate / "published").write_text("published")
finally:
    (gate / "exited").write_text("exited")
'''

# Loaded only by Python processes in this disposable fixture. Descendants
# inherit the same open-file description, including across shell exec/fork.
FAKE_PROCESS_LIFETIME = r'''
import fcntl, os, subprocess, sys

try:
    path = os.environ["FAKE_PROCESS_LIFETIME"]
    inherited = os.environ.get("FAKE_PROCESS_LIFETIME_FD")
    if inherited is None:
        descriptor = os.open(path, os.O_RDONLY)
        fcntl.flock(descriptor, fcntl.LOCK_SH)
    else:
        descriptor = int(inherited)
        actual, expected = os.fstat(descriptor), os.stat(path)
        if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
            raise RuntimeError("fixture lifetime descriptor changed")
    if os.pread(descriptor, 1, 0) != b"1":
        raise RuntimeError("fixture is closing")
except (KeyError, OSError, ValueError, RuntimeError) as error:
    print(f"Fixture process admission failed: {error}", file=sys.stderr, flush=True)
    os._exit(70)

os.environ["FAKE_PROCESS_LIFETIME_FD"] = str(descriptor)
original_popen = subprocess.Popen
class FixturePopen(original_popen):
    def __init__(self, *args, **kwargs):
        kwargs["pass_fds"] = tuple(set(kwargs.get("pass_fds", ())) | {descriptor})
        if kwargs.get("env") is not None:
            kwargs["env"] = {
                **kwargs["env"], "FAKE_PROCESS_LIFETIME_FD": str(descriptor),
            }
        super().__init__(*args, **kwargs)
subprocess.Popen = FixturePopen
'''


class Harness:
    def __init__(self, interactive=False, legacy=False):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name).resolve()
        self.closed = False
        self.lifetime = open(self.path / "process-lifetime", "w+b", buffering=0)
        self.lifetime.write(b"1")
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
        self.drain_stop = threading.Event()
        self.drain_thread = None
        self.cmux = self.path / "cmux"
        self.copilot = self.path / "copilot"
        self.driver = self.path / "controller-fixture.py"
        self.driver.write_text(
            "import os, runpy\n"
            f"api = runpy.run_path({str(CONTROLLER)!r})\n"
            f"tests = runpy.run_path({str(Path(__file__).resolve())!r})\n"
            "api['launch_reserved_session'].__globals__['launch_reserved_session'] = "
            "tests['legacy_fixture_launcher'](api['launch_reserved_session'], api)\n"
            "raise SystemExit(api['main']())\n"
        )
        self.cmux.write_text(FAKE_CMUX)
        self.copilot.write_text(FAKE_COPILOT)
        (self.path / "fixture-writer.py").write_text(FAKE_WRITER)
        (self.path / "sitecustomize.py").write_text(FAKE_PROCESS_LIFETIME)
        self.cmux.chmod(0o755)
        self.copilot.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update({
            "CMUX_MAESTRO_CMUX": str(self.cmux),
            "CMUX_MAESTRO_COPILOT": str(self.copilot),
            "CMUX_MAESTRO_CONTROLLER": str(CONTROLLER),
            "CMUX_MAESTRO_ROOT": str(self.root),
            "CMUX_MAESTRO_TESTING": "1",
            "FAKE_SESSION_MODE": ("legacy-interactive" if legacy else "interactive") if interactive else "bounded",
            "FAKE_CMUX_STATE": str(self.cmux_state),
            "FAKE_COPILOT_CALLS": str(self.copilot_calls),
            "FAKE_STDERR_READY": str(self.stderr_ready),
            "FAKE_POLICY_RESULTS": str(self.policy_results),
            "TEST_WORKSPACE": self.workspace,
            "TEST_PANE": self.pane,
            "TEST_ROOT_SURFACE": self.surface,
            "CMUX_WORKSPACE_ID": self.workspace,
            "CMUX_SURFACE_ID": self.surface,
            "FAKE_PROCESS_LIFETIME": str(self.path / "process-lifetime"),
            "PYTHONPATH": str(self.path) + os.pathsep + self.env.get("PYTHONPATH", ""),
        })
        self.env.pop("FAKE_PROCESS_LIFETIME_FD", None)
        if interactive:
            self.terminal_master, self.terminal_slave = pty.openpty()
            self.env["FAKE_PTY_SLAVE"] = os.ttyname(self.terminal_slave)
            self.env["FAKE_INTERACTIVE_READY"] = str(self.path / "interactive-ready")
            self.env["FAKE_INTERACTIVE_INPUT"] = str(self.path / "interactive-input")
            # Like a real terminal host, consume output. Darwin can retain an
            # exiting PTY process until its output has drained.
            os.set_blocking(self.terminal_master, False)
            def drain():
                while not self.drain_stop.wait(0.01):
                    try:
                        os.read(self.terminal_master, 65536)
                    except BlockingIOError:
                        pass
            self.drain_thread = threading.Thread(target=drain)
            self.drain_thread.start()
        try:
            self.registration = self.run(
                "register", "--workspace", self.workspace, "--surface", self.surface,
                "--name", "Coordinator",
            )
        except Exception as error:
            try:
                self.close()
            except Exception as cleanup_error:
                raise error from cleanup_error
            raise

    def run(self, *args, check=True, timeout=15, env=None):
        command = [
            sys.executable, str(self.driver), *args,
        ]
        with open(self.lifetime.name, "rb") as lifetime:
            fcntl.flock(lifetime, fcntl.LOCK_SH)
            completed = subprocess.run(
                command, env={**(env or self.env), "FAKE_PROCESS_LIFETIME_FD": str(lifetime.fileno())},
                pass_fds=(lifetime.fileno(),), text=True, capture_output=True, timeout=timeout,
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
        with open(self.lifetime.name, "rb") as lifetime:
            fcntl.flock(lifetime, fcntl.LOCK_SH)
            return subprocess.Popen(
                [sys.executable, str(self.driver), *args],
                env={**(env or self.env), "FAKE_PROCESS_LIFETIME_FD": str(lifetime.fileno())},
                pass_fds=(lifetime.fileno(),), text=True,
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
        if self.env["FAKE_SESSION_MODE"] != "bounded" or self.env.get("FAKE_PROVIDER_BARRIER"):
            return self.run(*arguments)
        # Report/protocol fixtures exercise the turn after startup acceptance.
        gate = self.path / f"provider-{uuid.uuid4()}"
        try:
            return self.run(*arguments, env={**self.env, "FAKE_PROVIDER_BARRIER": str(gate)})
        finally:
            gate.with_suffix(".release").write_text("release")

    def state(self):
        return json.loads((self.root / "control" / "state.json").read_text())

    def change_state(self, operation):
        return CONTROLLER_API["mutate"](self.root, operation, wait=2)

    def cmux_data(self):
        return json.loads(self.cmux_state.read_text())

    def wait_node(self, node_id, predicate, timeout=6):
        deadline = time.monotonic() + timeout
        node = None
        while time.monotonic() < deadline:
            try:
                node = CONTROLLER_API["read_state"](self.root, wait=0)["nodes"][node_id]
            except CONTROLLER_API["OrchestrationError"] as error:
                if "operation is active" not in str(error):
                    raise
                time.sleep(0.05)
                continue
            if predicate(node):
                return node
            if node.get("launchMethod") == "direct" and node.get("launchAccepted"):
                actor = node
                while actor["parentId"] is not None:
                    actor = self.state()["nodes"][actor["parentId"]]
                token = self.token if actor["id"] == self.node else self.cmux_data()["tokens"][actor["id"]]
                self.run("status", "--actor-id", actor["id"], "--token", token, "--worker-id", node_id)
            time.sleep(0.05)
        runtime_log = "No exact runtime surface observed."
        if node and node.get("surfaceId"):
            try:
                runtime_log = (self.path / f"runtime-{node['surfaceId']}.log").read_text(errors="replace")
            except OSError as error:
                runtime_log = f"Runtime log unavailable: {error}"
        processes = {
            "supervisorRunning": CONTROLLER_API["process_observation"]((node or {}).get("supervisor")),
            "providerRunning": CONTROLLER_API["process_observation"]((node or {}).get("providerProcess")),
        }
        raise AssertionError(
            f"timed out waiting for node {node_id}: {node}\n"
            f"process observations: {json.dumps(processes)}\nruntime stdout/stderr:\n{runtime_log}"
        )

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
        if self.closed:
            return
        # Failure must retain evidence even when this Harness is garbage collected.
        self.temp._finalizer.detach()
        os.pwrite(self.lifetime.fileno(), b"0", 0)
        try:
            processes = []
            if self.cmux_state.exists():
                processes.extend(self.cmux_data().get("processes", []))
            processes.extend({"pid": call["pid"], "start": call["start"]} for call in self.calls())
            stopped = set()
            for process in processes:
                if not process["start"]:
                    raise AssertionError(f"Fixture process identity unavailable; preserved {self.path}")
                identity = (process["pid"], process["start"])
                if identity in stopped:
                    continue
                stopped.add(identity)
                if CONTROLLER_API["process_observation"](process) is True:
                    try:
                        os.kill(process["pid"], signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            deadline = time.monotonic() + 3
            while True:
                try:
                    fcntl.flock(self.lifetime, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise AssertionError(f"Fixture process quiescence unavailable; preserved {self.path}")
                    time.sleep(0.02)
        finally:
            self.drain_stop.set()
            if self.drain_thread is not None:
                self.drain_thread.join()
            for name in ("terminal_master", "terminal_slave"):
                descriptor = getattr(self, name)
                if descriptor is not None:
                    os.close(descriptor)
                    setattr(self, name, None)
        shutil.rmtree(self.path)
        self.lifetime.close()
        self.closed = True


class HarnessTeardownTests(unittest.TestCase):
    def test_constructor_registration_timeout_closes_owned_fixture_and_preserves_original_error(self):
        h = object.__new__(Harness)
        original_close = Harness.close
        injected = subprocess.TimeoutExpired(["synthetic-registration"], 15)
        try:
            with patch("subprocess.run", side_effect=injected) as run, \
                    patch("subprocess.Popen", side_effect=AssertionError("no process may start")) as popen, \
                    patch.dict(CONTROLLER_API, {
                        "process_observation": unittest.mock.Mock(side_effect=AssertionError("no process exists")),
                    }), patch.object(Harness, "close", autospec=True, side_effect=original_close) as close:
                with self.assertRaises(subprocess.TimeoutExpired) as caught:
                    h.__init__()
                self.assertIs(caught.exception, injected)
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.args[0][2], "register")
                self.assertEqual(run.call_args.kwargs["timeout"], 15)
                popen.assert_not_called()
                CONTROLLER_API["process_observation"].assert_not_called()
                close.assert_called_once_with(h)
                self.assertTrue(h.closed)
                self.assertTrue(h.lifetime.closed)
                self.assertFalse(h.temp._finalizer.alive)
                self.assertFalse(h.path.exists())
        finally:
            h.close()

    def test_constructor_retains_unquiesced_fixture_and_chains_cleanup_failure_to_original_error(self):
        h = object.__new__(Harness)
        original_close, original_flock = Harness.close, fcntl.flock
        injected = subprocess.TimeoutExpired(["synthetic-registration"], 15)
        secondary = []

        def close(harness):
            try:
                original_close(harness)
            except AssertionError as error:
                secondary.append(error)
                raise

        def flock(file, operation):
            if operation & fcntl.LOCK_EX:
                raise BlockingIOError("synthetic unquiesced fixture")
            return original_flock(file, operation)

        try:
            with patch("subprocess.run", side_effect=injected) as run, \
                    patch("subprocess.Popen", side_effect=AssertionError("no process may start")) as popen, \
                    patch.dict(CONTROLLER_API, {
                        "process_observation": unittest.mock.Mock(side_effect=AssertionError("no process exists")),
                    }), patch.object(Harness, "close", autospec=True, side_effect=close) as cleanup, \
                    patch.object(Harness, "quiescence_diagnostics", create=True,
                                 return_value={"synthetic": "failure-boundary"}) as diagnostics, \
                    patch("fcntl.flock", side_effect=flock), \
                    patch("time.monotonic", side_effect=[0, 4]), patch("time.sleep") as sleep:
                with self.assertRaises(subprocess.TimeoutExpired) as caught:
                    h.__init__()
                self.assertIs(caught.exception, injected)
                self.assertEqual(run.call_count, 1)
                popen.assert_not_called()
                cleanup.assert_called_once_with(h)
                self.assertEqual(len(secondary), 1)
                self.assertIs(caught.exception.__cause__, secondary[0])
                self.assertIn("quiescence", str(secondary[0]))
                self.assertIn('"synthetic": "failure-boundary"', str(secondary[0]))
                diagnostics.assert_called_once_with([])
                self.assertFalse(h.closed)
                self.assertTrue(h.path.is_dir())
                self.assertFalse(h.temp._finalizer.alive)
                self.assertFalse(h.lifetime.closed)
                self.assertEqual(os.pread(h.lifetime.fileno(), 1, 0), b"0")
                sleep.assert_not_called()
        finally:
            h.close()

    def test_quiescence_diagnostics_reports_only_exact_file_holders_and_process_metadata(self):
        h = object.__new__(Harness)
        h.lifetime = unittest.mock.Mock(name="lifetime")
        h.lifetime.name = "/owned-fixture/process-lifetime"
        known = [{"pid": 41, "start": "Thu Oct  8 17:00:00 2026"}]
        results = [
            subprocess.CompletedProcess(["lsof"], 0, "p41\nf5\np42\nf5\n", ""),
            subprocess.CompletedProcess(
                ["ps"], 0,
                "41 1 Thu Oct  8 17:00:00 2026 Ss\n42 41 Thu Oct  8 17:00:01 2026 S\n", "",
            ),
        ]
        with patch("shutil.which", return_value="/usr/sbin/lsof"), \
                patch("subprocess.run", side_effect=results) as run:
            observed = h.quiescence_diagnostics(known)
        self.assertEqual(observed, {
            "recordedAtClose": known,
            "lifetimeFilePids": [41, 42],
            "processMetadata": results[1].stdout.splitlines(),
        })
        self.assertEqual(run.call_args_list[0].args[0],
                         ["/usr/sbin/lsof", "-Fp", "--", h.lifetime.name])
        self.assertEqual(run.call_args_list[1].args[0],
                         ["/bin/ps", "-o", "pid=,ppid=,lstart=,stat=", "-p", "41,42"])
        self.assertTrue(all(call.kwargs["timeout"] == 1 for call in run.call_args_list))
        self.assertTrue(all(call.kwargs["capture_output"] for call in run.call_args_list))

    def test_quiescence_diagnostics_exposes_unavailable_or_disappeared_observations(self):
        h = object.__new__(Harness)
        h.lifetime = unittest.mock.Mock(name="lifetime")
        h.lifetime.name = "/owned-fixture/process-lifetime"
        with patch("shutil.which", return_value=None), patch("subprocess.run") as run:
            self.assertEqual(h.quiescence_diagnostics([]),
                             {"recordedAtClose": [], "unavailable": "lsof-missing"})
            run.assert_not_called()
        with patch("shutil.which", return_value="/usr/sbin/lsof"), \
                patch("subprocess.run", side_effect=subprocess.TimeoutExpired(["lsof"], 1)):
            self.assertEqual(h.quiescence_diagnostics([]),
                             {"recordedAtClose": [], "unavailable": "TimeoutExpired"})
        with patch("shutil.which", return_value="/usr/sbin/lsof"), \
                patch("subprocess.run", return_value=subprocess.CompletedProcess(
                    ["lsof"], 1, "", "",
                )) as run:
            self.assertEqual(h.quiescence_diagnostics([]),
                             {"recordedAtClose": [], "lifetimeFilePids": []})
            self.assertEqual(run.call_count, 1)

    def test_constructor_success_keeps_fixture_active_without_cleanup(self):
        h = object.__new__(Harness)
        registration = {"coordinatorId": "synthetic", "controlToken": "synthetic"}
        completed = subprocess.CompletedProcess(["synthetic-registration"], 0, json.dumps(registration), "")
        try:
            with patch("subprocess.run", return_value=completed) as run, \
                    patch("subprocess.Popen", side_effect=AssertionError("no process may start")) as popen, \
                    patch.object(Harness, "close", autospec=True) as close:
                h.__init__()
                self.assertEqual(h.registration, {**registration, "returncode": 0, "stderr": ""})
                self.assertEqual(run.call_count, 1)
                close.assert_not_called()
                popen.assert_not_called()
                self.assertFalse(h.closed)
                self.assertTrue(h.path.is_dir())
                self.assertTrue(h.temp._finalizer.alive)
                self.assertFalse(h.lifetime.closed)
                self.assertEqual(os.pread(h.lifetime.fileno(), 1, 0), b"1")
        finally:
            h.close()

    def test_wait_failure_preserves_assertion_and_captures_runtime_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            harness = object.__new__(Harness)
            harness.path = Path(directory)
            harness.root = harness.path / "unused"
            worker_id, surface_id = str(uuid.uuid4()), str(uuid.uuid4())
            node = {
                "id": worker_id, "surfaceId": surface_id, "phase": "process-disappeared",
                "supervisor": {"pid": 12345, "start": "synthetic-start"},
                "providerProcess": None,
            }
            log = harness.path / f"runtime-{surface_id}.log"
            log.write_text("synthetic runtime failure: known discriminator\n")
            with patch.dict(CONTROLLER_API, {
                "read_state": lambda *a, **k: {"nodes": {worker_id: node}},
                "process_observation": lambda process: False if process else None,
            }), patch("time.monotonic", side_effect=[0, 0, 7]), patch("time.sleep"):
                with self.assertRaises(AssertionError) as failure:
                    harness.wait_node(worker_id, lambda current: current["phase"] == "reported-completed")
            message = str(failure.exception)
            self.assertIn(f"timed out waiting for node {worker_id}", message)
            self.assertIn("process-disappeared", message)
            self.assertIn("synthetic runtime failure: known discriminator", message)
            self.assertIn('"supervisorRunning": false', message)
            self.assertIn('"providerRunning": null', message)
            self.assertTrue(log.exists(), "diagnostics must be captured before cleanup")

    def test_successful_wait_does_not_collect_failure_diagnostics(self):
        harness = object.__new__(Harness)
        harness.root = Path("/unused")
        node = {"phase": "reported-completed"}
        with patch.dict(CONTROLLER_API, {
            "read_state": lambda *a, **k: {"nodes": {"synthetic": node}},
        }), patch.object(Path, "read_text") as read_log, patch.dict(CONTROLLER_API, {
            "process_observation": unittest.mock.Mock(),
        }):
            self.assertIs(harness.wait_node("synthetic", lambda _: True), node)
            read_log.assert_not_called()
            CONTROLLER_API["process_observation"].assert_not_called()

    def test_close_preserves_sandbox_when_orphan_writer_cannot_quiesce(self):
        for interactive in (False, True):
            with self.subTest(interactive=interactive):
                self.assert_preserves_sandbox(interactive)

    def assert_preserves_sandbox(self, interactive):
        h = Harness(interactive=interactive)
        with tempfile.TemporaryDirectory() as directory:
            gate = Path(directory)
            h.env["FAKE_WRITER_GATE"] = str(gate)
            writer = None
            try:
                h.spawn()
                deadline = time.monotonic() + 6
                while not (gate / "ready").exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((gate / "ready").exists())
                writer = json.loads((gate / "ready").read_text())
                with self.assertRaisesRegex(AssertionError, "quiescence"):
                    h.close()
                self.assertTrue(h.path.is_dir())
                self.assertTrue(CONTROLLER_API["process_observation"](writer))
                self.assertFalse(h.temp._finalizer.alive)
                if interactive:
                    self.assertFalse(h.drain_thread.is_alive())
                    self.assertIsNone(h.terminal_master)
                    self.assertIsNone(h.terminal_slave)
            finally:
                (gate / "release").write_text("release")
                if writer:
                    deadline = time.monotonic() + 6
                    while (CONTROLLER_API["process_observation"](writer) is not False
                           and time.monotonic() < deadline):
                        time.sleep(0.01)
                    self.assertFalse(CONTROLLER_API["process_observation"](writer))
                h.close()

    def test_close_waits_for_descendant_publication_before_removing_sandbox(self):
        h = Harness()
        with tempfile.TemporaryDirectory() as directory:
            gate = Path(directory)
            h.env["FAKE_WRITER_GATE"] = str(gate)
            closer = None
            errors = []
            cleanup_reached = threading.Event()
            original_cleanup = shutil.rmtree

            def cleanup(path, *args, **kwargs):
                self.assertEqual(Path(path), h.path)
                cleanup_reached.set()
                self.assertTrue((gate / "published").exists())
                original_cleanup(path, *args, **kwargs)

            def close():
                try:
                    h.close()
                except Exception as error:
                    errors.append(error)

            try:
                h.spawn()
                deadline = time.monotonic() + 6
                while not (gate / "ready").exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((gate / "ready").exists())
                roots = h.cmux_data()["processes"]
                providers = h.calls()
                with patch("shutil.rmtree", cleanup):
                    closer = threading.Thread(target=close)
                    closer.start()
                    deadline = time.monotonic() + 2
                    while any(CONTROLLER_API["process_observation"](item) is not False
                              for item in roots + providers) and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(all(CONTROLLER_API["process_observation"](item) is False
                                        for item in roots + providers))
                    self.assertFalse(cleanup_reached.is_set())
                    self.assertTrue(h.path.is_dir())
                    (gate / "release").write_text("release")
                    closer.join(timeout=6)
                    self.assertFalse(closer.is_alive())
                    self.assertEqual(errors, [])
                    self.assertTrue(cleanup_reached.is_set())
                    self.assertFalse(h.path.exists())
            finally:
                (gate / "release").write_text("release")
                if closer is not None:
                    closer.join(timeout=6)
                    self.assertFalse(closer.is_alive())
                h.close()


class WorkspaceCapacityCLITests(unittest.TestCase):
    def setUp(self):
        self.h = Harness()
        self.addCleanup(self.h.close)

    def capacity(self, *arguments, **options):
        return self.h.run("capacity", "--workspace", self.h.workspace, *arguments, **options)

    def configure(self, limit, **options):
        return self.capacity("--limit", str(limit), "--actor-id", self.h.node,
                             "--token", self.h.token, **options)

    def test_default_preflight_does_not_require_provider_or_host(self):
        before = self.h.state()
        environment = {**self.h.env, "CMUX_MAESTRO_CMUX": "/missing/cmux",
                       "CMUX_MAESTRO_COPILOT": "/missing/copilot"}
        summary = self.capacity(env=environment)["capacity"]
        self.assertEqual(summary["limit"], 32)
        self.assertEqual(summary["used"], 0)
        self.assertTrue(summary["advisory"])
        self.assertTrue(summary["admissionAvailable"])
        self.assertEqual(self.h.state(), before)

    def test_limits_persist_across_processes_and_status_agrees(self):
        for limit in (1, 32, 128):
            with self.subTest(limit=limit):
                self.assertEqual(self.configure(limit)["capacity"]["limit"], limit)
                self.assertEqual(self.h.state()["workspaceCapacity"], {self.h.workspace: limit})
                preflight = self.capacity()["capacity"]
                status = self.h.run("status", "--actor-id", self.h.node,
                                    "--token", self.h.token)["capacity"]
                self.assertEqual(status, preflight)
        other = str(uuid.uuid4())
        self.assertEqual(self.h.run("capacity", "--workspace", other)["capacity"]["limit"], 32)

    def test_invalid_limits_or_wrong_authority_preserve_state(self):
        self.configure(64)
        before = self.h.state()
        for arguments in (
            ("--limit", "0", "--actor-id", self.h.node, "--token", self.h.token),
            ("--limit", "129", "--actor-id", self.h.node, "--token", self.h.token),
            ("--limit", "128"),
            ("--limit", "128", "--actor-id", self.h.node, "--token", "wrong"),
        ):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.capacity(*arguments, check=False)["returncode"], 2)
                self.assertEqual(self.h.state(), before)
        denied = self.h.run("capacity", "--workspace", str(uuid.uuid4()), "--limit", "128",
                            "--actor-id", self.h.node, "--token", self.h.token, check=False)
        self.assertEqual(denied["returncode"], 2)
        self.assertEqual(self.h.state(), before)

    def test_worker_cannot_change_its_admission_budget(self):
        receipt = self.h.spawn()
        token = self.h.cmux_data()["tokens"][receipt["workerId"]]
        before = self.h.state().get("workspaceCapacity")
        denied = self.capacity("--limit", "128", "--actor-id", receipt["workerId"],
                               "--token", token, check=False)
        self.assertEqual(denied["returncode"], 2)
        self.assertIn("authenticated coordinator", denied["stderr"])
        self.assertEqual(self.h.state().get("workspaceCapacity"), before)

    def test_updating_full_configuration_map_preserves_other_workspaces(self):
        limits = {str(uuid.uuid4()): 17 for _ in range(127)}
        limits[self.h.workspace] = 32
        self.h.change_state(lambda state: state.update(workspaceCapacity=limits))
        self.assertEqual(self.configure(64)["capacity"]["limit"], 64)
        expected = {**limits, self.h.workspace: 64}
        self.assertEqual(self.h.state()["workspaceCapacity"], expected)
        other = next(workspace for workspace in limits if workspace != self.h.workspace)
        self.assertEqual(self.h.run("capacity", "--workspace", other)["capacity"]["limit"], 17)

    def test_corrupt_persisted_capacity_refuses_without_repair_or_default(self):
        path = self.h.root / "control" / "state.json"
        original = self.h.state()
        for invalid in (None, {self.h.workspace: 129}, {self.h.workspace: True}):
            with self.subTest(invalid=invalid):
                payload = json.dumps({**original, "workspaceCapacity": invalid}).encode()
                path.write_bytes(payload)
                result = self.capacity(check=False)
                self.assertEqual(result["returncode"], 2)
                self.assertIn("capacity", result["stderr"].lower())
                self.assertEqual(path.read_bytes(), payload)

    def test_lowering_below_usage_keeps_exact_resources_and_refuses_new_launch(self):
        receipts = [self.h.spawn(label=f"Existing {index}") for index in range(2)]
        before = self.h.state()
        summary = self.configure(1)["capacity"]
        self.assertEqual(summary["used"], 2)
        self.assertEqual(summary["remaining"], 0)
        self.assertFalse(summary["admissionAvailable"])
        after = self.h.state()
        self.assertEqual(after["nodes"], before["nodes"])
        self.assertEqual(after["retainedResources"], before["retainedResources"])
        self.assertEqual(after["launches"], before["launches"])
        rejected = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token, "--name", "Refused",
            "--cwd", str(REPO), "--task", "bounded", check=False,
        )
        self.assertEqual(rejected["returncode"], 2)
        self.assertIn("resource limit", rejected["stderr"])
        self.assertEqual(len(self.h.cmux_data()["surfaces"]), len(receipts) + 1)

    def test_advisory_preflight_cannot_reserve_last_slot_against_concurrent_spawns(self):
        self.configure(1)
        self.assertTrue(self.capacity()["capacity"]["admissionAvailable"])
        arguments = ["spawn", "--actor-id", self.h.node, "--token", self.h.token,
                     "--name", "Capacity race", "--cwd", str(REPO), "--task", "bounded"]
        processes = [self.h.start(*arguments) for _ in range(2)]
        results = [self.h.finish(process, check=False) for process in processes]
        self.assertEqual(sorted(result["returncode"] for result in results), [0, 2])
        failed = next(result for result in results if result["returncode"] == 2)
        self.assertIn("resource limit", failed["stderr"])
        summary = self.capacity()["capacity"]
        self.assertEqual(summary["used"], 1)
        self.assertFalse(summary["admissionAvailable"])
        self.assertEqual(len(self.h.cmux_data()["surfaces"]), 2)
        self.configure(128)
        self.assertTrue(self.capacity()["capacity"]["admissionAvailable"])
        self.configure(1)
        self.assertEqual(self.capacity()["capacity"]["used"], 1)


class OrchestratorTests(unittest.TestCase):
    def setUp(self):
        self.h = Harness()
        original = CONTROLLER_API["launch_reserved_session"]
        self.legacy = patch.dict(original.__globals__, {
            "launch_reserved_session": legacy_fixture_launcher(original, CONTROLLER_API),
        })
        self.legacy.start()

    def tearDown(self):
        self.legacy.stop()
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

    def test_snapshot_validation_does_not_block_a_new_writer(self):
        validating, release = threading.Event(), threading.Event()
        snapshots, errors = [], []
        validate = CONTROLLER_API["validate_state"]

        def held_validation(state):
            if threading.current_thread() is reader:
                validating.set()
                if not release.wait(5):
                    raise AssertionError("Snapshot validation fixture was not released")
            return validate(state)

        def read_snapshot():
            try:
                snapshots.append(CONTROLLER_API["read_state"](self.h.root))
            except Exception as error:
                errors.append(error)

        reader = threading.Thread(target=read_snapshot)
        with patch.dict(validate.__globals__, {"validate_state": held_validation}):
            try:
                reader.start()
                self.assertTrue(validating.wait(3))
                CONTROLLER_API["mutate"](
                    self.h.root,
                    lambda state: state["nodes"][self.h.node].update(label="New committed label"),
                    wait=0,
                )
            finally:
                release.set()
                reader.join(timeout=6)
        self.assertFalse(reader.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(snapshots[0]["nodes"][self.h.node]["label"], "Coordinator")
        self.assertEqual(self.h.state()["nodes"][self.h.node]["label"], "New committed label")

    def test_read_snapshot_still_rejects_malformed_and_invalid_state(self):
        path = self.h.root / "control" / "state.json"
        original = path.read_bytes()
        try:
            for payload, message in (
                (b"{", "malformed"),
                (b"\xff", "malformed"),
                (b'{"version":1,"nodes":{"not-a-uuid":{}}}', "must be a UUID"),
            ):
                with self.subTest(payload=payload):
                    path.write_bytes(payload)
                    with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], message):
                        CONTROLLER_API["read_state"](self.h.root)
                    self.assertEqual(path.read_bytes(), payload)
        finally:
            path.write_bytes(original)

    def test_attachment_lock_is_private_noninheritable_and_rejects_unsafe_files(self):
        identifier = str(uuid.uuid4())
        ticket = self.h.root / "control" / f"launch-{identifier}.json"
        ticket.write_text('{"synthetic":"attachment"}')
        ticket.chmod(0o600)
        with CONTROLLER_API["Store"](self.h.root, read_only=True) as store:
            descriptor = store.launch_attachment(identifier)
            try:
                self.assertFalse(os.get_inheritable(descriptor))
            finally:
                os.close(descriptor)
            ticket.chmod(0o644)
            with self.assertRaises(CONTROLLER_API["OrchestrationError"]):
                store.launch_attachment(identifier)
            ticket.unlink()
            os.mkfifo(ticket, 0o600)
            with self.assertRaises(CONTROLLER_API["OrchestrationError"]):
                store.launch_attachment(identifier)
            ticket.unlink()
            ticket.symlink_to(self.h.root / "control" / "state.json")
            with self.assertRaises(OSError):
                store.launch_attachment(identifier)

    def test_runtime_ticket_reads_share_lock_until_the_mutation_boundary(self):
        identifier = str(uuid.uuid4())
        ticket = self.h.root / "control" / f"launch-{identifier}.json"
        ticket.write_text(json.dumps({"workerId": identifier, "token": "a" * 64}))
        ticket.chmod(0o600)
        args = CONTROLLER_API["parser"]().parse_args(["runtime", "--worker-id", identifier])
        runtime = CONTROLLER_API["command_runtime"]

        def mutation_boundary(*args, **kwargs):
            raise RuntimeError("Reached exclusive mutation boundary")

        with CONTROLLER_API["Store"](self.h.root, read_only=True), patch.dict(
            runtime.__globals__, {"mutate": mutation_boundary}
        ):
            with self.assertRaisesRegex(RuntimeError, "Reached exclusive mutation boundary"):
                runtime(args, self.h.root)

    def test_wait_node_does_not_accept_an_intermediate_state_publication(self):
        published, release, blocked, done = (threading.Event() for _ in range(4))
        errors, results = [], []
        atomic = CONTROLLER_API["Store"]._atomic
        read = CONTROLLER_API["read_state"]

        def write_state():
            try:
                self.h.change_state(lambda state: state["nodes"][self.h.node].update(label="Committed label"))
            except Exception as error:
                errors.append(error)

        writer = threading.Thread(target=write_state)

        def held_publication(directory, name, data):
            atomic(directory, name, data)
            if threading.current_thread() is writer and name == "state.json":
                published.set()
                if not release.wait(5):
                    raise AssertionError("Publication fixture was not released")

        def observed_read(*args, **kwargs):
            try:
                return read(*args, **kwargs)
            except CONTROLLER_API["OrchestrationError"] as error:
                if "operation is active" in str(error):
                    blocked.set()
                raise

        def await_node():
            try:
                results.append(self.h.wait_node(self.h.node, lambda node: node["label"] == "Committed label"))
            except Exception as error:
                errors.append(error)
            finally:
                done.set()

        waiter = threading.Thread(target=await_node)
        with patch.object(CONTROLLER_API["Store"], "_atomic", side_effect=held_publication), \
                patch.dict(CONTROLLER_API, {"read_state": observed_read}):
            try:
                writer.start()
                self.assertTrue(published.wait(3))
                self.assertEqual(self.h.state()["nodes"][self.h.node]["label"], "Committed label")
                waiter.start()
                self.assertTrue(blocked.wait(3))
                self.assertFalse(done.is_set())
                release.set()
                self.assertTrue(done.wait(6))
            finally:
                release.set()
                writer.join(timeout=6)
                if waiter.ident is not None:
                    waiter.join(timeout=6)
        self.assertFalse(writer.is_alive() or waiter.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(results[0]["label"], "Committed label")

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
            for launch_file in (h.root / "control").glob("direct-*.sh"):
                self.assertNotIn("synthetic-work-token", launch_file.read_text())
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
        routes = Path(tempfile.mkdtemp(prefix="m61-", dir="/tmp")).resolve()
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
        h = Harness(interactive=True, legacy=True)
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
            self.assertEqual(list((h.root / "control").glob("direct-*.sh")), [])
            self.assertEqual(
                h.state()["retainedResources"][0]["surfaceId"], worker["surfaceId"],
            )
        finally:
            h.close()

    def test_direct_interactive_ctrl_c_reaches_provider_without_supervisor(self):
        h = Harness(interactive=True)
        try:
            worker = h.spawn("Remain interactive.")
            node = h.wait_node(worker["workerId"], lambda item: item.get("providerProcess") is not None)
            deadline = time.monotonic() + 5
            while not (h.path / "interactive-ready").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue((h.path / "interactive-ready").exists())
            self.assertIsNone(node["supervisor"])
            os.killpg(node["providerProcess"]["pid"], signal.SIGINT)
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
        entered = self.h.path / "git-probe.entered"
        consumed = self.h.path / "git-probe.consumed"
        fake_git = self.h.path / "git-blocking"
        fake_git.write_text(
            f"#!{sys.executable}\n"
            "import fcntl, json, os, subprocess, sys\n"
            "from pathlib import Path\n"
            "start = subprocess.run(['/bin/ps', '-o', 'lstart=', '-p', str(os.getpid())],\n"
            "                       capture_output=True, text=True, check=True).stdout.strip()\n"
            f"ready = Path({str(ready)!r})\n"
            "ready.with_suffix('.tmp').write_text(json.dumps({\n"
            "    'pid': os.getpid(), 'ppid': os.getppid(), 'start': start,\n"
            "}))\n"
            "ready.with_suffix('.tmp').replace(ready)\n"
            f"with open({str(release)!r}) as gate:\n"
            "    fcntl.flock(gate, fcntl.LOCK_SH)\n"
            f"Path({str(consumed)!r}).write_text('released')\n"
            "if '--show-toplevel' in sys.argv:\n"
            f"    print({str(cwd)!r})\n"
            "elif 'symbolic-ref' in sys.argv:\n"
            "    print('branch-a')\n"
        )
        fake_git.chmod(0o755)
        # Pause only this register's real Popen context entry, before the probe
        # deadline starts. Otherwise its one-second timeout could release a
        # wrongly held state lock before a cold status CLI even starts.
        driver = self.h.driver.read_text()
        self.h.driver.write_text(driver.replace(
            "raise SystemExit(api['main']())",
            "import fcntl, subprocess\n"
            "from pathlib import Path\n"
            "class GatedGit(subprocess.Popen):\n"
            "    def __enter__(self):\n"
            "        process = super().__enter__()\n"
            f"        if self.args[0] == {str(fake_git)!r}:\n"
            f"            entered = Path({str(entered)!r})\n"
            "            entered.with_suffix('.entering').write_text(str(self.pid))\n"
            "            entered.with_suffix('.entering').replace(entered)\n"
            f"            with open({str(release)!r}) as gate:\n"
            "                fcntl.flock(gate, fcntl.LOCK_SH)\n"
            "        return process\n"
            "subprocess.Popen = GatedGit\n"
            "raise SystemExit(api['main']())",
        ))
        surface = "00000000-0000-4000-8000-000000000098"
        self.h.add_surface(surface)
        env = self.h.env.copy()
        env["CMUX_SURFACE_ID"] = surface
        env["CMUX_MAESTRO_GIT"] = str(fake_git)
        with release.open("w") as gate:
            fcntl.flock(gate, fcntl.LOCK_EX)
            registration = self.h.start(
                "register", "--workspace", self.h.workspace, "--surface", surface,
                "--cwd", str(cwd), "--name", "Blocking probe", env=env,
            )
            try:
                deadline = time.monotonic() + 3
                while not (ready.exists() and entered.exists()) and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists())
                self.assertTrue(entered.exists())
                probe = json.loads(ready.read_text())
                self.assertEqual(probe["pid"], int(entered.read_text()))
                self.assertEqual(probe["ppid"], registration.pid)
                self.assertTrue(probe["start"])
                self.assertIs(CONTROLLER_API["process_observation"](probe), True)
                self.assertIsNone(registration.poll())
                self.assertFalse(consumed.exists())
                # Replace the cold-CLI <1s proxy with a nonblocking exclusive
                # acquisition and actual status success before either gate opens.
                with CONTROLLER_API["Store"](self.h.root) as store:
                    self.assertIn(self.h.node, store.read()["nodes"])
                status = self.h.run("status", "--actor-id", self.h.node, "--token", self.h.token)
                self.assertEqual(status["returncode"], 0)
                self.assertFalse(consumed.exists())
                self.assertIs(CONTROLLER_API["process_observation"](probe), True)
                self.assertIsNone(registration.poll())
            finally:
                fcntl.flock(gate, fcntl.LOCK_UN)
                completed = self.h.finish(registration, timeout=5)
        self.assertEqual(completed["returncode"], 0)
        self.assertTrue(consumed.exists())
        registered = self.h.state()["nodes"][completed["coordinatorId"]]
        self.assertEqual(registered["gitEvidenceStatus"], "verified")
        self.assertEqual(registered["worktreeLabel"], cwd.name)
        self.assertEqual(registered["branchLabel"], "branch-a")
        self.assertIs(CONTROLLER_API["process_observation"](probe), False)

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

    def test_delayed_runtime_keeps_exact_lease_after_bounded_caller_return(self):
        barrier = self.h.path / "runtime-barrier"
        self.h.env.update({
            "FAKE_RUNTIME_BARRIER": str(barrier),
            "CMUX_MAESTRO_STARTUP_SECONDS": "0.05",
        })
        result = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Delayed runtime", "--cwd", str(REPO), "--task", "bounded",
            check=False,
        )
        state = self.h.state()
        worker = next(node for node in state["nodes"].values() if node["role"] == "worker")
        try:
            self.assertTrue(barrier.with_suffix(".ready").exists())
            self.assertEqual(result["returncode"], 0, result["stderr"])
            self.assertTrue(result["launchAccepted"])
            self.assertEqual(result["startup"], "pending")
            self.assertEqual(result["phase"], "launching")
            self.assertEqual(result["initialTask"], "configured")
            self.assertFalse(result["supervisorStarted"])
            self.assertIsNone(result["providerRunning"])
            self.assertEqual(result["workObservation"], "unavailable")
            self.assertEqual(state["launches"][worker["id"]]["state"], "starting")
            self.assertTrue((self.h.root / "control" / f"launch-{worker['id']}.json").exists())
        finally:
            barrier.with_suffix(".release").write_text("release")
        completed = self.h.wait_node(worker["id"], lambda node: node["phase"] == "reported-completed")
        self.assertEqual(completed["surfaceId"], result["surfaceId"])
        self.assertEqual(completed["copilotSessionId"], result["sessionId"])
        self.assertNotIn(worker["id"], self.h.state()["launches"])
        self.assertEqual(len(self.h.calls()), 1)
        self.assertEqual(self.h.cmux_data()["selected"], self.h.surface)

    def test_delayed_attachment_does_not_expire_runtime(self):
        barrier = self.h.path / "attach-barrier"
        env = {**self.h.env, "CMUX_MAESTRO_TEST_ATTACH_BARRIER": str(barrier),
               "CMUX_MAESTRO_STARTUP_SECONDS": "0.05"}
        process = self.h.start(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Delayed attachment", "--cwd", str(REPO), "--task", "bounded",
            env=env,
        )
        deadline = time.monotonic() + 5
        while not barrier.with_suffix(".ready").exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        try:
            self.assertTrue(barrier.with_suffix(".ready").exists())
            # The caller is held at the exact attach boundary beyond the child's
            # old observation budget, independently of any provider readiness.
            time.sleep(0.3)
            self.assertEqual(self.h.calls(), [])
        finally:
            barrier.with_suffix(".release").write_text("release")
        result = self.h.finish(process, check=False)
        self.assertEqual(result["returncode"], 0, result["stderr"])
        worker = self.h.wait_node(result["workerId"], lambda node: node["phase"] == "reported-completed")
        self.assertEqual(worker["surfaceId"], result["surfaceId"])
        self.assertEqual(len(self.h.calls()), 1)

    def test_provider_readiness_is_independent_and_render_health_is_not_liveness(self):
        h = Harness(interactive=True)
        barrier = h.path / "provider-barrier"
        h.env["FAKE_PROVIDER_BARRIER"] = str(barrier)
        try:
            receipt = h.spawn("Synthetic initial task")
            node = h.state()["nodes"][receipt["workerId"]]
            ready = Path(h.env["FAKE_INTERACTIVE_READY"])
            self.assertFalse(ready.exists())
            for _ in range(2):
                status = h.run("status", "--actor-id", h.node, "--token", h.token,
                               "--worker-id", node["id"])["workers"][0]
                self.assertTrue(status["launchAccepted"])
                self.assertFalse(status["supervisorStarted"])
                self.assertIsNone(status["providerRunning"])
                self.assertTrue(status["surfacePresent"])
                self.assertEqual(status["initialTask"], "configured")
                self.assertEqual(status["workObservation"], "unavailable")
                self.assertNotIn("ready", status)
                self.assertFalse(ready.exists())
            self.assertEqual(len(h.calls()), 1)
            argv = h.calls()[0]["args"]
            self.assertTrue(argv[argv.index("--interactive") + 1].endswith("\nSynthetic initial task"))
            barrier.with_suffix(".release").write_text("release")
            deadline = time.monotonic() + 3
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists())
            h.wait_node(node["id"], lambda item: item.get("providerProcess"))
            status = h.run("status", "--actor-id", h.node, "--token", h.token,
                           "--worker-id", node["id"])["workers"][0]
            self.assertEqual(status["workObservation"], "unavailable")
            self.assertEqual(h.cmux_data()["selected"], h.surface)
            os.write(h.terminal_master, b"exit\n")
            h.wait_node(node["id"], lambda item: item["phase"] == "process-disappeared")
        finally:
            barrier.with_suffix(".release").write_text("release")
            h.close()

    def test_late_create_reply_keeps_attachment_lease_without_duplicate_launch(self):
        barrier = self.h.path / "create-reply"
        env = {**self.h.env, "FAKE_CREATE_REPLY_BARRIER": str(barrier),
               "CMUX_MAESTRO_STARTUP_SECONDS": "0.05"}
        caller = self.h.start(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Late reply", "--cwd", str(REPO), "--task", "bounded", env=env,
        )
        try:
            deadline = time.monotonic() + 5
            while not barrier.with_suffix(".ready").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(barrier.with_suffix(".ready").exists())
            time.sleep(0.3)
            lease = next(iter(self.h.state()["launches"].values()))
            self.assertEqual(lease["state"], "creating")
            self.assertIsNone(lease["surfaceId"])
            self.assertEqual(self.h.calls(), [])
        finally:
            barrier.with_suffix(".release").write_text("release")
        receipt = self.h.finish(caller)
        self.h.wait_node(receipt["workerId"], lambda node: node["phase"] == "reported-completed")
        self.assertEqual(len(self.h.calls()), 1)
        self.assertEqual(len(self.h.cmux_data()["surfaces"]), 2)

    def test_pending_launch_surface_loss_fences_late_runtime(self):
        barrier = self.h.path / "runtime-barrier"
        self.h.env.update(FAKE_RUNTIME_BARRIER=str(barrier), CMUX_MAESTRO_STARTUP_SECONDS="0")
        receipt = self.h.spawn()
        self.h.remove_surface(receipt["surfaceId"])
        status = self.h.run("status", "--actor-id", self.h.node, "--token", self.h.token,
                            "--worker-id", receipt["workerId"])["workers"][0]
        self.assertEqual(status["phase"], "terminal-disappeared")
        self.assertEqual(status["startup"], "failed")
        state = self.h.state()
        self.assertEqual(state["launches"], {})
        self.assertTrue(state["nodes"][receipt["workerId"]]["runtimeNotStarted"])
        barrier.with_suffix(".release").write_text("release")
        log = self.h.path / f"runtime-{receipt['surfaceId']}.log"
        deadline = time.monotonic() + 3
        while not log.read_text() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertIn("error", log.read_text())
        self.assertEqual(self.h.calls(), [])

    def test_provider_that_never_becomes_ready_does_not_prove_work(self):
        h = Harness(interactive=True)
        barrier = h.path / "provider-barrier"
        h.env["FAKE_PROVIDER_BARRIER"] = str(barrier)
        provider = None
        try:
            receipt = h.spawn()
            node = h.state()["nodes"][receipt["workerId"]]
            provider = h.cmux_data()["pids"][-1]
            status = h.run("status", "--actor-id", h.node, "--token", h.token,
                           "--worker-id", node["id"])["workers"][0]
            self.assertIsNone(status["providerRunning"])
            self.assertEqual(status["workObservation"], "unavailable")
            self.assertFalse(Path(h.env["FAKE_INTERACTIVE_READY"]).exists())
            os.kill(provider, signal.SIGTERM)
            provider = None
            status = h.run("status", "--actor-id", h.node, "--token", h.token,
                           "--worker-id", node["id"])["workers"][0]
            self.assertEqual(status["startup"], "pending")
            self.assertIsNone(status["providerRunning"])
            self.assertFalse(status["providerStarted"])
            self.assertEqual(status["workObservation"], "unavailable")
            self.assertEqual(len(h.calls()), 1)
        finally:
            if provider is not None:
                try:
                    os.kill(provider, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            h.close()

    def test_lost_create_reply_preserves_unknown_resource_and_refuses_retry_reclamation(self):
        env = {**self.h.env, "FAKE_LOST_CREATE_REPLY": "1"}
        failed = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Lost reply", "--cwd", str(REPO), "--task", "bounded",
            env=env, check=False,
        )
        self.assertEqual(failed["returncode"], 2)
        worker = next(node for node in self.h.state()["nodes"].values() if node["role"] == "worker")
        self.assertEqual(worker["phase"], "launch-failed")
        self.assertTrue(worker["surfaceUnknown"])
        self.assertIsNone(worker["surfaceId"])
        self.assertEqual(len(self.h.cmux_data()["surfaces"]), 2)
        self.assertEqual(self.h.state()["launches"], {})
        created = next(surface for surface in self.h.cmux_data()["surfaces"] if surface != self.h.surface)
        log = self.h.path / f"runtime-{created}.log"
        deadline = time.monotonic() + 3
        while not log.read_text() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertIn("error", log.read_text())
        self.assertEqual(self.h.calls(), [])
        other = self.h.spawn()
        self.h.wait_node(other["workerId"], lambda node: node["availability"] == "idle")
        self.assertEqual(self.h.state()["nodes"][worker["id"]]["phase"], "launch-failed")
        archived = self.h.run("archive", "--actor-id", self.h.node, "--token", self.h.token, check=False)
        self.assertEqual(archived["returncode"], 2)
        self.assertIn("unresolved", archived["stderr"])

    def test_unknown_host_inventory_preserves_pending_lease_and_capacity(self):
        barrier = self.h.path / "runtime-barrier"
        self.h.env.update(FAKE_RUNTIME_BARRIER=str(barrier), CMUX_MAESTRO_STARTUP_SECONDS="0")
        receipt = self.h.spawn()
        before = self.h.state()["launches"]
        host = self.h.cmux_data()
        host["inventoryUnavailable"] = True
        self.h.cmux_state.write_text(json.dumps(host))
        status = self.h.run("status", "--actor-id", self.h.node, "--token", self.h.token,
                            "--worker-id", receipt["workerId"])["workers"][0]
        self.assertEqual(status["startup"], "pending")
        self.assertIsNone(status["surfacePresent"])
        self.assertIsNone(status["providerRunning"])
        self.assertEqual(self.h.state()["launches"], before)
        rejected = self.h.run("spawn", "--actor-id", self.h.node, "--token", self.h.token,
                             "--name", "No guessed reclamation", "--cwd", str(REPO),
                             "--task", "bounded", check=False)
        self.assertEqual(rejected["returncode"], 2)
        self.assertEqual(set(self.h.cmux_data()["surfaces"]), set(host["surfaces"]))
        barrier.with_suffix(".release").write_text("release")
        self.h.wait_node(receipt["workerId"], lambda node: node["phase"] == "reported-completed")

    def test_supervisor_claim_at_failed_observation_boundary_is_not_revoked(self):
        barrier = self.h.path / "runtime-barrier"
        self.h.env.update(FAKE_RUNTIME_BARRIER=str(barrier), CMUX_MAESTRO_STARTUP_SECONDS="0")
        args = CONTROLLER_API["parser"]().parse_args([
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Concurrent claim", "--cwd", str(REPO), "--task", "bounded",
        ])
        with patch.dict(os.environ, self.h.env):
            cmux = CONTROLLER_API["Cmux"]()
            probe = cmux.surface_exists

            def claimed_before_mutation(workspace, surface):
                worker = next(node for node in self.h.state()["nodes"].values() if node["role"] == "worker")
                barrier.with_suffix(".release").write_text("release")
                self.h.wait_node(worker["id"], lambda node: node["phase"] == "reported-completed")
                cmux.surface_exists = probe
                return False

            cmux.surface_exists = claimed_before_mutation
            receipt = CONTROLLER_API["command_spawn"](args, self.h.root, cmux)
        self.assertEqual(receipt["phase"], "reported-completed")
        self.assertEqual(receipt["workObservation"], "reported-result")
        self.assertNotIn("runtimeNotStarted", self.h.state()["nodes"][receipt["workerId"]])
        self.assertEqual(len(self.h.calls()), 1)

    def test_conflicting_surface_observation_does_not_extend_caller_budget(self):
        barrier = self.h.path / "runtime-barrier"
        self.h.env.update(FAKE_RUNTIME_BARRIER=str(barrier), CMUX_MAESTRO_STARTUP_SECONDS="0")
        args = CONTROLLER_API["parser"]().parse_args([
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Changed observation", "--cwd", str(REPO), "--task", "bounded",
        ])
        probes = []
        with patch.dict(os.environ, self.h.env):
            cmux = CONTROLLER_API["Cmux"]()

            def stale_observation(workspace, surface):
                probes.append(surface)
                self.assertEqual(len(probes), 1, "Observation conflict must not bypass the caller budget.")
                def change(state):
                    worker = next(node for node in state["nodes"].values() if node["role"] == "worker")
                    worker["result"] = "Synthetic concurrent observation."
                self.h.change_state(change)
                return False

            cmux.surface_exists = stale_observation
            receipt = CONTROLLER_API["command_spawn"](args, self.h.root, cmux)
        self.assertEqual(receipt["startup"], "pending")
        self.assertIn(receipt["workerId"], self.h.state()["launches"])
        barrier.with_suffix(".release").write_text("release")
        self.h.wait_node(receipt["workerId"], lambda node: node["phase"] == "reported-completed")
        self.assertEqual(len(self.h.calls()), 1)

    def assert_slow_status_preserves_supervision(self, status, *, expected_probes=1):
        h = Harness(interactive=True, legacy=True)
        h.env["CMUX_MAESTRO_HEARTBEAT_SECONDS"] = "0.15"
        process_start = status.__globals__["process_start"]
        probes, store_reads, readers = [], [], []
        provider = None
        try:
            receipt = h.spawn()
            node = h.wait_node(receipt["workerId"], lambda item: item.get("providerProcess"))
            provider = node["providerProcess"]
            before = node["updatedAt"]

            def concurrent_read():
                try:
                    CONTROLLER_API["read_state"](h.root, wait=2)
                    store_reads.append("ok")
                except CONTROLLER_API["OrchestrationError"] as error:
                    store_reads.append(str(error))

            def slow_provider(pid):
                if pid == provider["pid"]:
                    probes.append(pid)
                    reader = threading.Thread(target=concurrent_read)
                    readers.append(reader)
                    reader.start()
                    time.sleep(2.7)
                return process_start(pid)

            args = CONTROLLER_API["parser"]().parse_args([
                "status", "--actor-id", h.node, "--token", h.token,
                "--worker-id", node["id"],
            ])
            started = time.monotonic()
            with patch.dict(os.environ, h.env), patch.dict(status.__globals__, {"process_start": slow_provider}):
                status(args, h.root, CONTROLLER_API["Cmux"]())
            elapsed = time.monotonic() - started
            for reader in readers:
                reader.join(timeout=3)
                self.assertFalse(reader.is_alive())
            # Allow the real runtime to finish its existing two-second failed
            # lock attempt/finalizer, or publish another successful heartbeat.
            time.sleep(0.5)
            current = h.state()["nodes"][node["id"]]
            evidence = {
                "providerProbeCount": len(probes), "statusSeconds": round(elapsed, 3),
                "storeReads": store_reads,
                "supervisorAlive": process_start(node["supervisor"]["pid"]) == node["supervisor"]["start"],
                "providerAlive": process_start(provider["pid"]) == provider["start"],
                "heartbeatAdvanced": current["updatedAt"] > before,
                "providerCalls": len(h.calls()), "result": current["result"],
            }
            self.assertTrue(evidence["supervisorAlive"], evidence)
            self.assertTrue(evidence["providerAlive"], evidence)
            self.assertTrue(evidence["heartbeatAdvanced"], evidence)
            self.assertEqual(evidence["providerCalls"], 1, evidence)
            self.assertIsNone(evidence["result"], evidence)
            self.assertEqual(len(probes), expected_probes, evidence)
            self.assertEqual(store_reads, ["ok"] * expected_probes, evidence)
            return evidence
        finally:
            for reader in readers:
                reader.join(timeout=3)
            if provider is not None:
                os.write(h.terminal_master, b"exit\n")
                deadline = time.monotonic() + 3
                while process_start(provider["pid"]) == provider["start"] and time.monotonic() < deadline:
                    time.sleep(0.05)
                if process_start(provider["pid"]) == provider["start"]:
                    os.kill(provider["pid"], signal.SIGTERM)
            h.close()

    def test_status_slow_provider_probe_does_not_end_actual_supervisor(self):
        self.assert_slow_status_preserves_supervision(CONTROLLER_API["command_status"])

    def test_status_multi_node_probes_are_unlocked_and_identity_fenced(self):
        receipts = [self.h.spawn(label=f"Observed {index}") for index in range(2)]
        nodes = [self.h.wait_node(item["workerId"], lambda node: node["availability"] == "idle")
                 for item in receipts]
        replacement_session = str(uuid.uuid4())
        changed, probes = [], []
        status = CONTROLLER_API["command_status"]
        process_start = status.__globals__["process_start"]

        def observed_process(pid):
            # Every status-side ps collaborator must be outside the writer.
            CONTROLLER_API["read_state"](self.h.root, wait=0)
            probes.append(pid)
            if pid == nodes[0]["supervisor"]["pid"] and not changed:
                def replace(state):
                    node = state["nodes"][nodes[0]["id"]]
                    node["copilotSessionId"] = replacement_session
                    node["generation"] += 1
                self.h.change_state(replace)
                changed.append(True)
            return process_start(pid)

        args = CONTROLLER_API["parser"]().parse_args([
            "status", "--actor-id", self.h.node, "--token", self.h.token,
        ])
        with patch.dict(os.environ, self.h.env), patch.dict(status.__globals__, {"process_start": observed_process}):
            result = status(args, self.h.root, CONTROLLER_API["Cmux"]())
        workers = {item["workerId"]: item for item in result["workers"]}
        changed_node, stable = (workers[node["id"]] for node in nodes)
        self.assertEqual(changed_node["sessionId"], replacement_session)
        self.assertEqual(changed_node["generation"], 2)
        self.assertIsNone(changed_node["surfacePresent"])
        self.assertIsNone(changed_node["supervisorRunning"])
        self.assertIsNone(changed_node["providerRunning"])
        self.assertEqual(changed_node["workObservation"], "unavailable")
        self.assertTrue(stable["surfacePresent"])
        self.assertTrue(stable["supervisorRunning"])
        self.assertEqual(stable["workObservation"], "reported-result")
        self.assertEqual(len(self.h.calls()), 2)
        for node in nodes:
            self.assertIn(node["supervisor"]["pid"], probes)
            self.assertEqual(process_start(node["supervisor"]["pid"]), node["supervisor"]["start"])

    def test_status_confirmed_absence_rechecks_host_outside_mutation(self):
        receipt = self.h.spawn()
        node = self.h.wait_node(receipt["workerId"], lambda item: item["availability"] == "idle")
        supervisor = node["supervisor"]
        os.kill(supervisor["pid"], signal.SIGTERM)
        self.h.wait_node(node["id"], lambda item: item["phase"] == "process-disappeared")
        deadline = time.monotonic() + 3
        while CONTROLLER_API["process_start"](supervisor["pid"]) == supervisor["start"] and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertNotEqual(CONTROLLER_API["process_start"](supervisor["pid"]), supervisor["start"])
        self.h.remove_surface(receipt["surfaceId"])
        probes = []
        args = CONTROLLER_API["parser"]().parse_args([
            "status", "--actor-id", self.h.node, "--token", self.h.token, "--worker-id", node["id"],
        ])
        with patch.dict(os.environ, self.h.env):
            cmux = CONTROLLER_API["Cmux"]()
            probe = cmux.surface_exists

            def unlocked_probe(workspace, surface):
                CONTROLLER_API["read_state"](self.h.root, wait=0)
                probes.append(surface)
                return probe(workspace, surface)

            cmux.surface_exists = unlocked_probe
            status = CONTROLLER_API["command_status"](args, self.h.root, cmux)["workers"][0]
        self.assertEqual(probes, [node["surfaceId"], node["surfaceId"]])
        self.assertEqual(status["phase"], "terminal-disappeared")
        self.assertFalse(status["surfacePresent"])
        self.assertFalse(status["supervisorRunning"])
        self.assertEqual(len(self.h.calls()), 1)

    def test_final_launch_receipt_refuses_actual_status_cancellation(self):
        for observation in (True, None):
            with self.subTest(observation=observation):
                barrier = self.h.path / f"runtime-cancel-{observation}"
                self.h.env.update(FAKE_RUNTIME_BARRIER=str(barrier), CMUX_MAESTRO_STARTUP_SECONDS="0")
                args = CONTROLLER_API["parser"]().parse_args([
                    "spawn", "--actor-id", self.h.node, "--token", self.h.token,
                    "--name", "Final receipt cancellation", "--cwd", str(REPO), "--task", "bounded",
                ])
                status_results = []
                receipt, failure = None, None
                with patch.dict(os.environ, self.h.env):
                    cmux = CONTROLLER_API["Cmux"]()
                    probe = cmux.surface_exists

                    def cancelled_after_probe(workspace, surface):
                        self.assertTrue(probe(workspace, surface))
                        self.h.remove_surface(surface)
                        worker = next(node for node in self.h.state()["nodes"].values()
                                      if node.get("surfaceId") == surface)
                        status_results.append(self.h.run(
                            "status", "--actor-id", self.h.node, "--token", self.h.token,
                            "--worker-id", worker["id"],
                        )["workers"][0])
                        return observation

                    cmux.surface_exists = cancelled_after_probe
                    try:
                        receipt = CONTROLLER_API["command_spawn"](args, self.h.root, cmux)
                    except CONTROLLER_API["OrchestrationError"] as error:
                        failure = str(error)
                cancelled = status_results[0]
                state = self.h.state()
                node = state["nodes"][cancelled["workerId"]]
                self.assertEqual(node["phase"], "terminal-disappeared")
                self.assertTrue(node["runtimeNotStarted"])
                self.assertNotIn(node["id"], state["launches"])
                self.assertFalse((self.h.root / "control" / f"launch-{node['id']}.json").exists())
                barrier.with_suffix(".release").write_text("release")
                log = self.h.path / f"runtime-{node['surfaceId']}.log"
                deadline = time.monotonic() + 3
                while not log.read_text() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertIn("error", log.read_text())
                self.assertEqual(self.h.calls(), [])
                self.assertIsNone(receipt, {"receipt": receipt, "currentPhase": node["phase"]})
                self.assertIsNotNone(failure)

    def test_final_launch_receipt_refuses_replaced_or_removed_ownership(self):
        for change in ("token", "session", "generation", "lease", "node"):
            with self.subTest(change=change):
                h = Harness()
                barrier = h.path / "runtime-replacement"
                h.env.update(FAKE_RUNTIME_BARRIER=str(barrier), CMUX_MAESTRO_STARTUP_SECONDS="0")
                affected = []
                try:
                    args = CONTROLLER_API["parser"]().parse_args([
                        "spawn", "--actor-id", h.node, "--token", h.token,
                        "--name", "Replaced launch", "--cwd", str(REPO), "--task", "bounded",
                    ])
                    with patch.dict(os.environ, h.env):
                        cmux = CONTROLLER_API["Cmux"]()
                        probe = cmux.surface_exists

                        def replaced_after_probe(workspace, surface):
                            self.assertTrue(probe(workspace, surface))
                            def replace(state):
                                node = next(item for item in state["nodes"].values()
                                            if item.get("surfaceId") == surface)
                                affected.append(dict(node))
                                if change == "token":
                                    node["tokenHash"] = CONTROLLER_API["token_hash"]("replacement")
                                elif change in {"session", "generation"}:
                                    # A replacement revokes the previous launch;
                                    # it is not permission for its late runtime.
                                    CONTROLLER_API["record_launch_failure"](state, node["id"], surface)
                                    if change == "session":
                                        node["copilotSessionId"] = str(uuid.uuid4())
                                    else:
                                        node["generation"] += 1
                                else:
                                    del state["launches"][node["id"]]
                                    if change == "node":
                                        state["retainedResources"].append({
                                            "runId": node["runId"], "workspaceId": workspace,
                                            "surfaceId": surface, "archivedAt": CONTROLLER_API["now"](),
                                        })
                                        del state["nodes"][node["id"]]
                            h.change_state(replace)
                            return True

                        cmux.surface_exists = replaced_after_probe
                        with self.assertRaises(CONTROLLER_API["OrchestrationError"]):
                            CONTROLLER_API["command_spawn"](args, h.root, cmux)
                    original = affected[0]
                    state = h.state()
                    self.assertEqual(original["id"] in state["launches"], change == "token")
                    if change != "node":
                        current = state["nodes"][original["id"]]
                        self.assertEqual(current["phase"], "launch-failed" if change in {"session", "generation"} else "launching")
                    else:
                        self.assertNotIn(original["id"], state["nodes"])
                        self.assertEqual(state["retainedResources"][0]["surfaceId"], original["surfaceId"])
                    self.assertTrue((h.root / "control" / f"launch-{original['id']}.json").exists())
                    barrier.with_suffix(".release").write_text("release")
                    log = h.path / f"runtime-{original['surfaceId']}.log"
                    deadline = time.monotonic() + 3
                    while not log.read_text() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertIn("error", log.read_text())
                    self.assertEqual(h.calls(), [])
                finally:
                    barrier.with_suffix(".release").write_text("release")
                    h.close()

    def test_final_launch_claim_discards_preclaim_probe_evidence(self):
        for observation in (True, None):
            with self.subTest(observation=observation):
                barrier = self.h.path / f"runtime-claim-{observation}"
                self.h.env.update(FAKE_RUNTIME_BARRIER=str(barrier), CMUX_MAESTRO_STARTUP_SECONDS="0")
                args = CONTROLLER_API["parser"]().parse_args([
                    "spawn", "--actor-id", self.h.node, "--token", self.h.token,
                    "--name", "Claimed before final receipt", "--cwd", str(REPO), "--task", "bounded",
                ])
                with patch.dict(os.environ, self.h.env):
                    cmux = CONTROLLER_API["Cmux"]()

                    def claimed_during_probe(workspace, surface):
                        node = next(item for item in self.h.state()["nodes"].values()
                                    if item.get("surfaceId") == surface)
                        barrier.with_suffix(".release").write_text("release")
                        self.h.wait_node(node["id"], lambda item: item["phase"] == "reported-completed")
                        return observation

                    cmux.surface_exists = claimed_during_probe
                    receipt = CONTROLLER_API["command_spawn"](args, self.h.root, cmux)
                self.assertEqual(receipt["phase"], "reported-completed")
                self.assertEqual(receipt["startup"], "supervisor-started")
                self.assertTrue(receipt["supervisorStarted"])
                self.assertIsNone(receipt["surfacePresent"])
                self.assertIsNone(receipt["supervisorRunning"])
                self.assertIsNone(receipt["providerRunning"])
                self.assertEqual(receipt["workObservation"], "reported-result")
                self.assertNotIn(receipt["workerId"], self.h.state()["launches"])
                self.assertFalse((self.h.root / "control" / f"launch-{receipt['workerId']}.json").exists())
        self.assertEqual(len(self.h.calls()), 2)

    def test_cancelled_expired_and_foreign_launches_refuse_late_execution(self):
        for boundary in ("cancelled", "expired", "token", "surface", "session", "generation"):
            with self.subTest(boundary=boundary):
                barrier = self.h.path / f"runtime-{boundary}"
                self.h.env.update(FAKE_RUNTIME_BARRIER=str(barrier), CMUX_MAESTRO_STARTUP_SECONDS="0")
                receipt = self.h.spawn()
                identifier = receipt["workerId"]

                def invalidate(state):
                    node = state["nodes"][identifier]
                    if boundary in {"cancelled", "expired"}:
                        CONTROLLER_API["record_launch_failure"](
                            state, identifier, receipt["surfaceId"],
                            phase="launch-failed" if boundary == "cancelled" else "startup-failed",
                        )
                    elif boundary == "token":
                        node["tokenHash"] = CONTROLLER_API["token_hash"]("replacement")
                    elif boundary == "surface":
                        replacement = str(uuid.uuid4())
                        node["surfaceId"] = replacement
                        state["launches"][identifier]["surfaceId"] = replacement
                    else:
                        # New leases bind both dimensions; corruption must be
                        # refused by the reader before runtime can claim.
                        node["copilotSessionId" if boundary == "session" else "generation"] = (
                            str(uuid.uuid4()) if boundary == "session" else 2
                        )

                if boundary in {"session", "generation"}:
                    state = self.h.state()
                    invalidate(state)
                    with self.assertRaises(CONTROLLER_API["OrchestrationError"]):
                        CONTROLLER_API["validate_state"](state)
                    self.h.change_state(lambda current: CONTROLLER_API["record_launch_failure"](current, identifier))
                else:
                    self.h.change_state(invalidate)
                barrier.with_suffix(".release").write_text("release")
                log = self.h.path / f"runtime-{receipt['surfaceId']}.log"
                deadline = time.monotonic() + 3
                while not log.read_text() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertIn("error", log.read_text())
                self.assertEqual(self.h.calls(), [])

    def test_pending_launches_hold_all_live_resource_slots(self):
        barrier = self.h.path / "runtime-lock"
        barrier.touch()
        latch = barrier.open()
        self.addCleanup(latch.close)
        fcntl.flock(latch.fileno(), fcntl.LOCK_EX)
        self.h.env.update(FAKE_RUNTIME_LOCK=str(barrier), CMUX_MAESTRO_STARTUP_SECONDS="0")
        receipts = [self.h.spawn(label=f"Pending {index}") for index in range(MAX_LIVE_WORKERS)]
        self.assertTrue(all(item["startup"] == "pending" for item in receipts))
        self.assertEqual(len(self.h.state()["launches"]), MAX_LIVE_WORKERS)
        before = set(self.h.cmux_data()["surfaces"])
        rejected = self.h.run("spawn", "--actor-id", self.h.node, "--token", self.h.token,
                             "--name", "Over capacity", "--cwd", str(REPO), "--task", "bounded",
                             check=False)
        self.assertEqual(rejected["returncode"], 2)
        self.assertIn("resource limit", rejected["stderr"])
        self.assertEqual(set(self.h.cmux_data()["surfaces"]), before)
        archived = self.h.run("archive", "--actor-id", self.h.node, "--token", self.h.token, check=False)
        self.assertEqual(archived["returncode"], 2)
        self.assertEqual(len(self.h.state()["launches"]), MAX_LIVE_WORKERS)
        fcntl.flock(latch.fileno(), fcntl.LOCK_UN)
        for receipt in receipts:
            self.h.wait_node(
                receipt["workerId"], lambda node: node["phase"] == "reported-completed",
                timeout=6 * max(1, MAX_LIVE_WORKERS / 8),
            )
        self.assertEqual(len(self.h.calls()), MAX_LIVE_WORKERS)

    def test_caller_exit_during_attachment_unblocks_child_without_execution(self):
        barrier = self.h.path / "attach-barrier"
        env = {**self.h.env, "CMUX_MAESTRO_TEST_ATTACH_BARRIER": str(barrier)}
        caller = self.h.start(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Caller disappears", "--cwd", str(REPO), "--task", "bounded", env=env,
        )
        try:
            deadline = time.monotonic() + 5
            while not barrier.with_suffix(".ready").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(barrier.with_suffix(".ready").exists())
            lease = next(iter(self.h.state()["launches"].values()))
            caller.terminate()
            self.h.finish(caller, check=False)
            log = self.h.path / f"runtime-{lease['surfaceId']}.log"
            deadline = time.monotonic() + 3
            while not log.read_text() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertIn("not in the launch phase", log.read_text())
            self.assertEqual(self.h.calls(), [])
            self.assertEqual(self.h.state()["launches"][lease["workerId"]], lease)
            self.assertIn(lease["surfaceId"], self.h.cmux_data()["surfaces"])
        finally:
            if caller.poll() is None:
                caller.terminate()
                caller.communicate(timeout=5)

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
        for index in range(MAX_LIVE_WORKERS - 1):
            added = self.h.spawn(label=f"Capacity {index}")
            self.h.wait_node(added["workerId"], lambda node: node["availability"] == "idle")
        surfaces_before = set(self.h.cmux_data()["surfaces"])
        over_capacity = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Over capacity", "--cwd", str(REPO), "--task", "bounded",
            check=False,
        )
        self.assertEqual(over_capacity["returncode"], 2)
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
        for index in range(MAX_LIVE_WORKERS - 1):
            worker = self.h.spawn(label=f"Capacity {index}")
            idle = self.h.wait_node(worker["workerId"], lambda node: node["availability"] == "idle")
            self.assertTrue(CONTROLLER_API["process_matches"](idle))
            # Keep the real terminal resource, without unrelated idle-supervisor publication traffic.
            os.kill(idle["supervisor"]["pid"], signal.SIGTERM)
            self.h.wait_node(worker["workerId"], lambda node: node["phase"] == "process-disappeared")
            self.assertIn(worker["surfaceId"], self.h.cmux_data()["surfaces"])
        surfaces_before = set(self.h.cmux_data()["surfaces"])
        rejected = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Over capacity", "--cwd", str(REPO), "--task", "bounded",
            check=False,
        )
        self.assertEqual(rejected["returncode"], 2)
        self.assertIn("Live worker resource limit", rejected["stderr"])
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

    def test_legacy_startup_still_refuses_an_already_failed_first_boundary(self):
        args = CONTROLLER_API["parser"]().parse_args([
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Early malformed", "--cwd", str(self.h.path), "--task", "[MALFORMED]",
        ])
        with patch.dict(os.environ, self.h.env):
            cmux = CONTROLLER_API["Cmux"]()
            probe = cmux.surface_exists

            def after_invalid_result(workspace, surface):
                identifier = next(node["id"] for node in self.h.state()["nodes"].values()
                                  if node.get("surfaceId") == surface)
                failed = self.h.wait_node(identifier, lambda node: node["phase"] == "turn-failed")
                self.assertTrue(CONTROLLER_API["process_matches"](failed))
                self.assertIsNone(failed["verifiedBoundaryGeneration"])
                return probe(workspace, surface)

            cmux.surface_exists = after_invalid_result
            with self.assertRaises(CONTROLLER_API["SessionLaunchError"]):
                CONTROLLER_API["command_spawn"](args, self.h.root, cmux)

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

    def test_completed_live_resources_reject_over_capacity_until_exact_resource_retired(self):
        workers = []
        for index in range(MAX_LIVE_WORKERS):
            worker = self.h.spawn(label=f"Worker {index}")
            self.h.wait_node(worker["workerId"], lambda node: node["availability"] == "idle")
            workers.append(worker)
        surfaces_before = len(self.h.cmux_data()["surfaces"])
        over_capacity = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Over capacity", "--cwd", str(REPO), "--task", "over capacity",
            check=False,
        )
        self.assertEqual(over_capacity["returncode"], 2)
        self.assertIn("Live worker resource limit", over_capacity["stderr"])
        self.assertEqual(len(self.h.cmux_data()["surfaces"]), surfaces_before)

        first_node = self.h.state()["nodes"][workers[0]["workerId"]]
        os.kill(first_node["supervisor"]["pid"], signal.SIGTERM)
        self.h.wait_node(workers[0]["workerId"], lambda node: node["phase"] == "process-disappeared")
        still_rejected = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Still over capacity", "--cwd", str(REPO), "--task", "over capacity",
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


class DirectLaunchTests(unittest.TestCase):
    def setUp(self):
        self.h = Harness(interactive=True)
        self.h.env["FAKE_NO_OBSERVATION"] = "1"
        self.addCleanup(self.h.close)

    def wait_file(self, path):
        deadline = time.monotonic() + 5
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(path.exists(), path)

    def test_acceptance_has_no_startup_probe_sleep_or_observation_dependency(self):
        args = CONTROLLER_API["parser"]().parse_args([
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Direct", "--cwd", str(self.h.path), "--task", "Run without hooks",
        ])
        application_time = unittest.mock.Mock(wraps=time)
        application_time.sleep.side_effect = AssertionError("startup sleep")
        with patch.dict(os.environ, self.h.env):
            cmux = CONTROLLER_API["Cmux"]()
            cmux.surface_exists = unittest.mock.Mock(side_effect=AssertionError("startup inventory poll"))
            with patch.dict(
                CONTROLLER_API["launch_direct_session"].__globals__, {
                    "time": application_time,
                    "process_observation": unittest.mock.Mock(side_effect=AssertionError("startup process probe")),
                    "command_runtime": unittest.mock.Mock(side_effect=AssertionError("supervisor")),
                },
            ):
                # Exercise the real stdlib timeout wait while the child is held on stdin.
                with subprocess.Popen(
                    [sys.executable, "-c", "import sys; sys.stdin.buffer.read(1)"],
                    stdin=subprocess.PIPE,
                ) as bounded_io:
                    try:
                        with self.assertRaises(subprocess.TimeoutExpired):
                            bounded_io.wait(timeout=0.05)
                    finally:
                        bounded_io.communicate(input=b"x", timeout=5)
                receipt = CONTROLLER_API["command_spawn"](args, self.h.root, cmux)
        self.assertTrue(receipt["launchAccepted"])
        self.assertEqual(receipt["startup"], "pending")
        self.assertFalse(receipt["providerStarted"])
        self.assertFalse(receipt["supervisorStarted"])
        self.assertEqual(receipt["initialTask"], "configured")
        self.assertEqual(receipt["taskConsumption"], "unknown")
        self.assertEqual(self.h.state()["launches"], {})
        self.assertEqual(len([call for call in self.h.cmux_data()["calls"] if "surface.create" in call]), 1)
        self.assertFalse(any("send" in call or "send-key" in call for call in self.h.cmux_data()["calls"]))

    def test_no_startup_wait_oracle_rejects_application_sleep(self):
        launch = CONTROLLER_API["launch_direct_session"]

        def sleep_before_launch(*args, **kwargs):
            launch.__globals__["time"].sleep(0)
            return launch(*args, **kwargs)

        with patch.dict(launch.__globals__, {"launch_direct_session": sleep_before_launch}):
            with self.assertRaisesRegex(AssertionError, "startup sleep"):
                self.test_acceptance_has_no_startup_probe_sleep_or_observation_dependency()

    def test_initial_command_preserves_task_bytes_quotes_path_cwd_and_policy(self):
        cwd = self.h.path / "cwd ' ; $(not-a-command)"
        cwd.mkdir()
        task = " \tTask ' \" ; $(touch SHOULD_NOT_EXIST)\n`echo nope` \\ \u2603\n\n"
        receipt = self.h.run(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Quoted ' worker", "--cwd", str(cwd), "--task", task,
            "--deny-tool", "shell(git push)",
        )
        self.wait_file(self.h.path / "interactive-ready")
        call = self.h.calls()[0]
        prompt = call["args"][call["args"].index("--interactive") + 1]
        self.assertEqual(prompt.split("\nOriginal task (verbatim):\n", 1)[1].encode(), task.encode())
        self.assertEqual(self.h.state()["nodes"][receipt["workerId"]]["task"], task)
        self.assertEqual(call["cwd"], str(cwd))
        self.assertEqual(call["tty"], [True, True, True])
        self.assertEqual(call["args"][call["args"].index("--session-id") + 1], receipt["sessionId"])
        self.assertEqual(call["args"][call["args"].index("--deny-tool") + 1], "shell(git push)")
        self.assertNotIn("--allow-all", call["args"])
        self.assertFalse((cwd / "SHOULD_NOT_EXIST").exists())
        self.assertNotIn("Coordinator return address:", prompt)
        for phrase in ("maestro_peers", "maestro_send", "envelope sender", "fire-and-forget",
                       "human", "without a startup acknowledgement", "Never fall back"):
            self.assertIn(phrase, prompt)
        creation = next(call for call in self.h.cmux_data()["calls"] if "surface.create" in call)
        command = json.loads(creation[-1])["initial_command"]
        self.assertNotIn(" runtime ", command)
        self.assertNotIn("--worker-id", command)
        self.assertNotIn(self.h.token, command)
        self.assertNotIn("--login", command)
        self.assertIn("exec ", command)

    def test_late_native_observation_is_not_a_launch_gate(self):
        self.h.env.pop("FAKE_NO_OBSERVATION")
        barrier = self.h.path / "provider"
        self.h.env["FAKE_PROVIDER_BARRIER"] = str(barrier)
        receipt = self.h.spawn("Observe later, no startup ack.")
        self.wait_file(barrier.with_suffix(".ready"))
        self.assertEqual(receipt["startup"], "pending")
        self.assertIsNone(self.h.state()["nodes"][receipt["workerId"]].get("providerProcess"))
        barrier.with_suffix(".release").write_text("release")
        node = self.h.wait_node(receipt["workerId"], lambda item: item.get("providerProcess"))
        self.assertIsNone(node["supervisor"])
        self.assertEqual(node["copilotSessionId"], receipt["sessionId"])
        self.assertEqual(node["surfaceId"], receipt["surfaceId"])
        self.assertEqual(node["generation"], 1)

    def test_maximum_quote_dense_task_does_not_overflow_host_command_or_change_bytes(self):
        task = "'" * CONTROLLER_API["MAX_TASK"]
        receipt = self.h.spawn(task)
        self.wait_file(self.h.path / "interactive-ready")
        call = self.h.calls()[0]
        prompt = call["args"][call["args"].index("--interactive") + 1]
        self.assertEqual(prompt.split("\nOriginal task (verbatim):\n", 1)[1], task)
        create = next(call for call in self.h.cmux_data()["calls"] if "surface.create" in call)
        self.assertLess(len(create[-1].encode()), 8192)
        self.assertEqual(self.h.state()["nodes"][receipt["workerId"]]["task"], task)

    def test_native_observation_before_attachment_merges_without_readiness_wait(self):
        self.h.env.pop("FAKE_NO_OBSERVATION")
        barrier = self.h.path / "attachment"
        caller = self.h.start(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Early native observation", "--cwd", str(self.h.path), "--task", "Start now",
            env={**self.h.env, "CMUX_MAESTRO_TEST_ATTACH_BARRIER": str(barrier)},
        )
        try:
            self.wait_file(barrier.with_suffix(".ready"))
            worker = next(node for node in self.h.state()["nodes"].values() if node["role"] == "worker")
            observed = self.h.wait_node(worker["id"], lambda item: item.get("providerProcess"))
            self.assertEqual(observed["phase"], "launching")
            self.assertNotIn("launchAccepted", observed)
            self.assertIn(worker["id"], self.h.state()["launches"])
            self.assertEqual(len(self.h.calls()), 1)
            barrier.with_suffix(".release").write_text("release")
            receipt = self.h.finish(caller)
            self.assertTrue(receipt["launchAccepted"])
            self.assertEqual(receipt["startup"], "provider-observed")
            self.assertEqual(receipt["initialTask"], "configured")
            self.assertIsNone(receipt["providerRunning"])
            self.assertEqual(self.h.state()["nodes"][worker["id"]]["providerProcess"], observed["providerProcess"])
        finally:
            barrier.with_suffix(".release").write_text("release")
            if caller.poll() is None:
                caller.terminate()
                caller.communicate(timeout=5)

    def test_caller_cancel_during_attach_preserves_lease_and_running_provider(self):
        self.h.env.pop("FAKE_NO_OBSERVATION")
        barrier = self.h.path / "attachment"
        caller = self.h.start(
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Cancelled caller", "--cwd", str(self.h.path), "--task", "No guessed cleanup",
            env={**self.h.env, "CMUX_MAESTRO_TEST_ATTACH_BARRIER": str(barrier)},
        )
        try:
            self.wait_file(barrier.with_suffix(".ready"))
            identifier = next(iter(self.h.state()["launches"]))
            node = self.h.wait_node(identifier, lambda item: item.get("providerProcess"))
            caller.terminate()
            self.h.finish(caller, check=False)
            self.assertIn(identifier, self.h.state()["launches"])
            self.assertTrue(CONTROLLER_API["process_matches"](node))
            refused = self.h.run("archive", "--actor-id", self.h.node, "--token", self.h.token, check=False)
            self.assertNotEqual(refused["returncode"], 0)
            self.assertIn("launch is in progress", refused["stderr"])
            self.assertTrue((self.h.root / "control" / f"direct-{identifier}-1.sh").exists())
        finally:
            barrier.with_suffix(".release").write_text("release")
            if caller.poll() is None:
                caller.terminate()
                caller.communicate(timeout=5)

    def test_missing_observation_and_close_never_infer_provider_death_or_free_capacity(self):
        receipt = self.h.spawn()
        self.h.remove_surface(receipt["surfaceId"])
        status = self.h.run("status", "--actor-id", self.h.node, "--token", self.h.token,
                            "--worker-id", receipt["workerId"])["workers"][0]
        self.assertEqual(status["phase"], "terminal-disappeared")
        self.assertIsNone(status["providerRunning"])
        node = self.h.state()["nodes"][receipt["workerId"]]
        self.assertNotIn("runtimeNotStarted", node)
        self.assertFalse(CONTROLLER_API["worker_processes_exited"](node))
        refused = self.h.run("archive", "--actor-id", self.h.node, "--token", self.h.token, check=False)
        self.assertNotEqual(refused["returncode"], 0)
        self.assertIn("uncertain", refused["stderr"])

    def test_unobserved_direct_sessions_refuse_over_capacity_without_new_terminal(self):
        receipts = [self.h.spawn(label=f"Unobserved {index}") for index in range(MAX_LIVE_WORKERS)]
        self.assertTrue(all(item["launchAccepted"] and item["startup"] == "pending" for item in receipts))
        before = set(self.h.cmux_data()["surfaces"])
        refused = self.h.run("spawn", "--actor-id", self.h.node, "--token", self.h.token,
                            "--name", "Over capacity", "--cwd", str(self.h.path), "--task", "No",
                            check=False)
        self.assertIn("resource limit", refused["stderr"])
        self.assertNotEqual(refused["returncode"], 0)
        self.assertEqual(set(self.h.cmux_data()["surfaces"]), before)

    def test_direct_lost_create_reply_and_failed_attach_retain_unknown_execution(self):
        for flag in ("FAKE_LOST_CREATE_REPLY", "CMUX_MAESTRO_TEST_ATTACH_FAILURE"):
            with self.subTest(flag=flag):
                result = self.h.run(
                    "spawn", "--actor-id", self.h.node, "--token", self.h.token,
                    "--name", flag, "--cwd", str(self.h.path), "--task", "May already run",
                    env={**self.h.env, flag: "1"}, check=False,
                )
                self.assertNotEqual(result["returncode"], 0)
                node = next(item for item in self.h.state()["nodes"].values() if item["label"] == flag)
                self.assertEqual(node["launchError"], "launch-failed")
                self.assertNotIn("runtimeNotStarted", node)
                self.assertIn(node["id"], self.h.state()["launches"])
                self.assertTrue((self.h.root / "control" / f"direct-{node['id']}-1.sh").exists())
                self.assertFalse(CONTROLLER_API["worker_processes_exited"](node))
                if flag == "FAKE_LOST_CREATE_REPLY":
                    self.assertTrue(node["surfaceUnknown"])
                else:
                    self.assertIn(node["surfaceId"], self.h.cmux_data()["surfaces"])

    def test_native_observation_rejects_stale_identity_and_unrelated_process(self):
        receipt = self.h.spawn()
        node = self.h.state()["nodes"][receipt["workerId"]]
        pid = self.h.cmux_data()["pids"][-1]
        identity = {
            "nodeId": node["id"], "workspaceId": node["workspaceId"],
            "sessionId": node["copilotSessionId"], "generation": 1,
            "surfaceId": node["surfaceId"], "pid": pid,
        }
        environment = {
            **self.h.env, "CMUX_MAESTRO_DIRECT_LAUNCH": "1",
            "CMUX_MAESTRO_LAUNCH_PID": str(pid), "CMUX_MAESTRO_WORKER_ID": node["id"],
            "SESSION_ID": node["copilotSessionId"], "CMUX_SURFACE_ID": node["surfaceId"],
            "CMUX_MAESTRO_CONTROL_TOKEN": self.h.cmux_data()["tokens"][node["id"]],
        }
        observe = CONTROLLER_API["command_native_observe"]
        before = self.h.state()
        for key, value in (("sessionId", str(uuid.uuid4())), ("generation", 2),
                           ("surfaceId", str(uuid.uuid4())), ("workspaceId", str(uuid.uuid4())),
                           ("nodeId", str(uuid.uuid4())), ("pid", pid + 1)):
            with self.subTest(key=key), patch.dict(os.environ, environment), patch(
                "sys.stdin", unittest.mock.Mock(buffer=io.BytesIO(json.dumps({**identity, key: value}).encode())),
            ), patch.dict(observe.__globals__, {
                "direct_process_identity": lambda _: {"pid": pid, "start": "synthetic"},
            }):
                with self.assertRaises(CONTROLLER_API["OrchestrationError"]):
                    observe(self.h.root)
            self.assertEqual(self.h.state(), before)
        # Even correct public fields cannot adopt a process outside the caller's ancestry.
        with patch.dict(os.environ, environment), patch(
            "sys.stdin", unittest.mock.Mock(buffer=io.BytesIO(json.dumps(identity).encode())),
        ), self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "ancestry"):
            observe(self.h.root)
        self.assertEqual(self.h.state(), before)

    def test_final_direct_receipt_revalidates_lease_without_freeing_possible_execution(self):
        args = CONTROLLER_API["parser"]().parse_args([
            "spawn", "--actor-id", self.h.node, "--token", self.h.token,
            "--name", "Cancelled attachment", "--cwd", str(self.h.path), "--task", "No retry",
        ])
        with patch.dict(os.environ, self.h.env):
            cmux = CONTROLLER_API["Cmux"]()
            original = cmux.rename
            def cancel(workspace, surface, label):
                original(workspace, surface, label)
                identifier = next(key for key, lease in self.h.state()["launches"].items()
                                  if lease["surfaceId"] == surface)
                self.h.change_state(lambda state: state["launches"].pop(identifier))
            cmux.rename = cancel
            with self.assertRaisesRegex(CONTROLLER_API["SessionLaunchError"], "lease is no longer active"):
                CONTROLLER_API["command_spawn"](args, self.h.root, cmux)
        node = next(node for node in self.h.state()["nodes"].values() if node["role"] == "worker")
        self.assertNotIn("launchAccepted", node)
        self.assertNotIn("runtimeNotStarted", node)
        self.assertIn(node["surfaceId"], self.h.cmux_data()["surfaces"])
        self.assertEqual(node["launchError"], "launch-failed")
        self.assertFalse(CONTROLLER_API["worker_processes_exited"](node))

    def test_native_parent_can_spawn_before_create_caller_returns_with_genuine_address(self):
        h = self.h
        h.env.pop("FAKE_NO_OBSERVATION")
        routes = Path(tempfile.mkdtemp(prefix="m61-", dir="/tmp")).resolve()
        self.addCleanup(shutil.rmtree, routes)
        extension = h.root / "extension"
        extension.mkdir(mode=0o700)
        for name in ("extension.mjs", "adapter.mjs"):
            shutil.copyfile(REPO / "scripts/delivery-proof" / name, extension / name)
            (extension / name).chmod(0o600)
        (h.root / "bin").mkdir(mode=0o700)
        config = h.root / "bin/messaging.json"
        config.write_text(json.dumps({"version": 1, "routes": str(routes), "extension": str(extension)}))
        config.chmod(0o600)
        settings = h.root / "worker-settings.json"
        settings.write_text(json.dumps({"version": 1, "model": "pinned-model", "copilotAccount": "other"}))
        settings.chmod(0o600)
        gh = h.path / "gh"
        gh.write_text("#!/bin/sh\nprintf '%s\\n' synthetic-work-token\n")
        gh.chmod(0o700)
        h.env["CMUX_MAESTRO_GH"] = str(gh)
        barrier = h.path / "root-attachment"
        caller = h.start(
            "launch-coordinator", "--workspace", h.workspace, "--surface", h.surface,
            "--cwd", str(h.path), "--task", "Create a child", "--account", "root-account",
            env={**h.env, "CMUX_MAESTRO_TEST_ATTACH_BARRIER": str(barrier)},
        )
        try:
            self.wait_file(barrier.with_suffix(".ready"))
            root_id = next(iter(h.state()["launches"]))
            root = h.wait_node(root_id, lambda item: item.get("providerProcess"))
            self.assertNotIn("launchAccepted", root)
            self.assertIn(root_id, h.state()["launches"])
            binding = json.loads((routes / f"{CONTROLLER_API['message_peer'](root)}.json").read_text())
            request = {
                "identity": {key: binding[key] for key in
                             ("nodeId", "workspaceId", "sessionId", "generation", "capability")} |
                            {"login": "root-account", "host": "github.com"},
                "assignment": {"name": "Native child", "cwd": str(h.path), "task": "  Original child task\n"},
            }
            result = subprocess.run(
                [sys.executable, str(CONTROLLER), "native-spawn"], input=json.dumps(request),
                env=h.env, capture_output=True, text=True, timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads(result.stdout)
            self.assertTrue(receipt["launchAccepted"])
            child = h.wait_node(receipt["workerId"], lambda item: item.get("providerProcess"))
            self.assertEqual(child["parentId"], root_id)
            self.assertEqual(child["launchSettings"]["copilotAccount"], "root-account")
            call = next(call for call in h.calls() if call["session"] == child["copilotSessionId"])
            prompt = call["args"][call["args"].index("--interactive") + 1]
            address = json.loads(next(line.split(": ", 1)[1] for line in prompt.splitlines()
                                      if line.startswith("Coordinator return address: ")))
            self.assertEqual(address, {key: binding[key] for key in ("workspaceId", "sessionId", "generation")})
            self.assertNotIn(binding["capability"], prompt)
            self.assertTrue(prompt.endswith("  Original child task\n"))
            self.assertIsNone(caller.poll())
            barrier.with_suffix(".release").write_text("release")
            root_receipt = h.finish(caller)
            self.assertEqual(root_receipt["coordinatorId"], root_id)
            self.assertTrue(root_receipt["launchAccepted"])
        finally:
            barrier.with_suffix(".release").write_text("release")
            if caller.poll() is None:
                caller.terminate()
                caller.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
