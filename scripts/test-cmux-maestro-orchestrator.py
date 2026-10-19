#!/usr/bin/env python3
import fcntl
import io
import json
import os
import pty
import runpy
import secrets
import shlex
import signal
import shutil
import socket
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
# Resource-accounting cases fill a small configured workspace limit; the same
# admission check applies to any limit. test_pending_launches_hold_all_live_resource_slots
# keeps the default reference budget end to end.
ACCOUNTING_CAPACITY = 4

FIXTURE_EDGES = REPO / "scripts" / "test-fixtures" / "orchestrator-controller-edges.py"
_edges = runpy.run_path(str(FIXTURE_EDGES))
fixture_edges = _edges["fixture_edges"]
configure_fixture_controller = _edges["configure_fixture_controller"]
legacy_fixture_launcher = _edges["legacy_fixture_launcher"]
# Fixture controller processes share one compiled-bytecode cache for the run.
FIXTURE_BYTECODE = tempfile.TemporaryDirectory(prefix="cmux-maestro-fixture-bytecode-")


def fixture_root(home):
    return Path(home) / "Library/Application Support/CMUXMaestroPreview/Orchestration"


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
    if "top" in args and "--workspace" in args:
        # Per-surface controlling TTY, as `cmux top` reports it.
        result = {"windows": [{"workspaces": [{"id": args[args.index("--workspace") + 1], "panes": [{"surfaces": [
            {"kind": "surface", "id": item, "tty": state.get("ttys", {}).get(item)} for item in state["surfaces"]
        ]}]}]}]}
        print(json.dumps(result))
        raise SystemExit(0)
    if args[:3] == ["surface", "resume", "clear"]:
        if os.environ.get("FAKE_RESUME_CLEAR_FAILS"):
            raise SystemExit("synthetic clear failure")
        state.setdefault("resumeBindings", {}).pop(args[args.index("--surface") + 1], None)
        temporary = state_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(state))
        os.replace(temporary, state_path)
        print("OK")
        raise SystemExit(0)
    if args[:3] == ["surface", "resume", "set"]:
        # Restart metadata for one exact surface; recorded for inspection only.
        surface = args[args.index("--surface") + 1]
        if args[args.index("--workspace") + 1] != state["workspace"] or surface not in state["surfaces"]:
            raise SystemExit("invalid resume binding target")
        state.setdefault("resumeBindings", {})[surface] = args[3:]
        temporary = state_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(state))
        os.replace(temporary, state_path)
        print("OK")
        raise SystemExit(0)
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
    attach_barrier = attach_failure = None
    if command == "identify":
        surface = value("--surface")
        if surface not in state["surfaces"]:
            print(json.dumps({"error": "surface not found"}))
            raise SystemExit(1)
        # The creator's first identify of a new surface is its attachment check.
        if state.get("attaching", {}).get(surface) == os.getppid():
            del state["attaching"][surface]
            attach_failure = os.environ.get("FAKE_ATTACH_FAILURE")
            attach_barrier = os.environ.get("FAKE_ATTACH_BARRIER")
        result = {"workspace_id": workspace, "surface_id": surface, "pane_id": state["pane"]}
    elif command == "list-panes":
        result = {"panes": [{"pane_id": state["pane"]}]}
    elif command == "rpc" and args[args.index("rpc") + 1] == "surface.list":
        if state.get("inventoryUnavailable"):
            raise SystemExit("synthetic host inventory unavailable")
        result = {"workspace_id": workspace, "surfaces": [
            {"id": item, "render_health": "not_started"} for item in state["surfaces"]
        ]}
    elif command == "rpc" and args[args.index("rpc") + 1] == "surface.close":
        closing = json.loads(args[args.index("rpc") + 2])
        state["surfaces"].remove(closing["surface_id"])
        state.setdefault("closed", []).append(closing)
        result = {"workspace_id": closing["workspace_id"], "surface_id": closing["surface_id"]}
    elif command == "rpc":
        if args[args.index("rpc") + 1] != "surface.create":
            raise SystemExit("unsupported RPC")
        if (creation["pane_id"] != state["pane"] or creation["type"] != "terminal"
                or creation["focus"] is not False or "initial_input" in creation):
            raise SystemExit("invalid direct surface.create parameters")
        surface = str(uuid.uuid4())
        state["surfaces"].append(surface)
        state["buffers"][surface] = ""
        state.setdefault("attaching", {})[surface] = os.getppid()
        result = {"surface_id": surface, "pane_id": state["pane"], "workspace_id": workspace}
        bootstrap = creation.get("initial_command")
        if bootstrap:
            command_args = shlex.split(bootstrap)
            control = Path(os.environ["HOME"]) / "Library/Application Support/CMUXMaestroPreview/Orchestration/control"
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
            if env.get("FAKE_RUNTIME_COPILOT_MISSING"):
                Path(env["FAKE_RUNTIME_COPILOT_MISSING"]).unlink()
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
    if attach_failure:
        raise SystemExit("synthetic attachment failure")
    if attach_barrier:
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        marker = Path(attach_barrier)
        marker.with_suffix(".ready").write_text("ready")
        deadline = time.monotonic() + 10
        while not marker.with_suffix(".release").exists():
            if time.monotonic() >= deadline:
                raise SystemExit("synthetic attachment barrier expired")
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
resumed = next((item[len("--resume="):] for item in args if item.startswith("--resume=")), None)
session = value("--session-id") or value("--resume") or resumed
prompt = value("-p") or value("--interactive") or ""
record = {
    "args": args,
    "generation": os.environ.get("CMUX_MAESTRO_GENERATION"),
    "session": session,
    "tty": [os.isatty(fd) for fd in (0, 1, 2)],
    "cwd": os.getcwd(),
    "pinnedSubscription": os.environ.get("COPILOT_GITHUB_TOKEN") == "synthetic-work-token",
    "gitTokenUnchanged": os.environ.get("GH_TOKEN") == "synthetic-personal-token",
    "maestroKeys": sorted(key for key in os.environ if key.startswith("CMUX_MAESTRO_")),
    "pid": os.getpid(),
    "cmuxHooksDisabled": os.environ.get("CMUX_COPILOT_HOOKS_DISABLED"),
    "start": subprocess.run(
        ["/bin/ps", "-o", "lstart=", "-p", str(os.getpid())],
        capture_output=True, text=True, check=True,
    ).stdout.strip(),
}
if resumed and os.environ.get("FAKE_SURFACE_TTY_AFTER_EXEC"):
    import fcntl
    state_path = os.environ["FAKE_CMUX_STATE"]
    with open(os.path.splitext(state_path)[0] + ".lock", "a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        data = json.load(open(state_path))
        data["ttys"][os.environ["CMUX_SURFACE_ID"]] = os.environ["FAKE_SURFACE_TTY_AFTER_EXEC"]
        with open(state_path + ".tmp", "w") as stream:
            json.dump(data, stream)
        os.replace(state_path + ".tmp", state_path)
if resumed and os.environ.get("CMUX_MAESTRO_DIRECT_LAUNCH") == "1" and not os.environ.get("FAKE_NO_OBSERVATION"):
    # A resumed session's extension observes its provider, like a fresh direct launch.
    observed = subprocess.run([os.environ["CMUX_MAESTRO_ORCHESTRATOR"], "native-observe"], input=json.dumps({
        "nodeId": os.environ["CMUX_MAESTRO_WORKER_ID"], "workspaceId": os.environ["CMUX_WORKSPACE_ID"],
        "sessionId": session, "generation": int(os.environ["CMUX_MAESTRO_GENERATION"]),
        "surfaceId": os.environ["CMUX_SURFACE_ID"], "pid": os.getpid()}),
        env={**os.environ, "SESSION_ID": session}, text=True, capture_output=True)
    record["observed"] = [observed.returncode, observed.stderr]
with open(os.environ["FAKE_COPILOT_CALLS"], "a") as stream:
    stream.write(json.dumps(record) + "\n")
if resumed:
    raise SystemExit(0)
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
        self.home = self.path / "home"
        self.home.mkdir()
        self.root = fixture_root(self.home)
        self.bin = self.path / "bin"
        self.bin.mkdir()
        self.routes = self.path / "coordinator-routes"
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
        # External edges are the outside world: host, provider and GitHub CLI on PATH.
        self.cmux = self.bin / "cmux"
        self.copilot = self.bin / "copilot"
        self.gh = self.bin / "gh"
        self.driver = self.path / "controller-fixture.py"
        self.driver.write_text(
            f"#!{sys.executable}\n"
            "import sys\n"
            f"sys.pycache_prefix = {FIXTURE_BYTECODE.name!r}\n"
            "import importlib.util\n"
            "def load(name, path):\n"
            "    spec = importlib.util.spec_from_file_location(name, path)\n"
            "    module = importlib.util.module_from_spec(spec)\n"
            "    sys.modules[name] = module\n"
            "    spec.loader.exec_module(module)\n"
            "    return vars(module)\n"
            f"api = load('cmux_maestro_orchestrator', {str(CONTROLLER)!r})\n"
            f"edges = load('orchestrator_controller_edges', {str(FIXTURE_EDGES)!r})\n"
            f"edges['configure_fixture_controller'](api, {str(self.driver)!r})\n"
            "raise SystemExit(api['main']())\n"
        )
        self.driver.chmod(0o755)
        self.cmux.write_text(FAKE_CMUX)
        self.copilot.write_text(FAKE_COPILOT)
        self.gh.write_text("#!/bin/sh\nprintf '%s\\n' synthetic-work-token\n")
        self.gh.chmod(0o700)
        (self.path / "fixture-writer.py").write_text(FAKE_WRITER)
        (self.path / "sitecustomize.py").write_text(FAKE_PROCESS_LIFETIME)
        self.cmux.chmod(0o755)
        self.copilot.chmod(0o755)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX_MAESTRO_")}
        self.env.update({
            "HOME": str(self.home),
            "PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"),
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
            self.identity = self.seed_native_parent()
        except Exception as error:
            try:
                self.close()
            except Exception as cleanup_error:
                raise error from cleanup_error
            raise

    def seed_native_parent(self, allow=()):
        """Give the coordinator the evidence of a managed native session: a live provider, a
        recorded launch policy and its adapter's private route. Production admission needs it."""
        self.routes.mkdir(mode=0o700, exist_ok=True)
        self.coordinator_provider = subprocess.Popen(
            [sys.executable, "-c", "import sys; sys.stdin.read()"], stdin=subprocess.PIPE,
            env=self.env, start_new_session=True,
        )
        anchor = {"pid": self.coordinator_provider.pid, "start": None}
        deadline = time.monotonic() + 5
        while anchor["start"] is None and time.monotonic() < deadline:
            anchor["start"] = CONTROLLER_API["process_start"](anchor["pid"])
        if anchor["start"] is None:
            raise AssertionError("Synthetic coordinator provider identity is unavailable.")
        data = self.cmux_data()
        data.setdefault("processes", []).append(anchor)
        self.cmux_state.write_text(json.dumps(data))
        session, capability = str(uuid.uuid4()), secrets.token_hex(32)

        def seed(state):
            node = state["nodes"][self.node]
            self.registered_root = json.loads(json.dumps(node))
            node.update(
                executionMode="interactive", launchMethod="direct", runtimeProtocolVersion=2,
                permissionMode="default", toolPolicy={"allow": list(allow), "deny": []},
                copilotSessionId=session, generation=1, providerProcess=anchor,
                phase="turn-running", availability="busy", task="Synthetic coordinator", launchAccepted=True,
                launchSettings={"version": 1, "copilotAccount": "synthetic-account", "model": "synthetic-model"},
                messaging={"version": 1, "routes": str(self.routes), "extension": str(self.path / "extension")},
            )
            return dict(node)
        node = self.change_state(seed)
        binding = self.routes / f"{CONTROLLER_API['message_peer'](node)}.json"
        binding.write_text(json.dumps({
            "nodeId": node["id"], "workspaceId": node["workspaceId"], "sessionId": session,
            "generation": node["generation"], "capability": capability,
        }))
        binding.chmod(0o600)
        settings = self.root / "worker-settings.json"
        settings.write_text(json.dumps({"version": 1, "model": "synthetic-model"}))
        settings.chmod(0o600)
        return {"nodeId": node["id"], "workspaceId": node["workspaceId"], "sessionId": session,
                "generation": node["generation"], "capability": capability,
                "login": "synthetic-account", "host": "github.com"}

    def limit_capacity(self, limit):
        configured = self.run("capacity", "--workspace", self.workspace, "--limit", str(limit),
                              "--actor-id", self.node, "--token", self.token)
        if configured["capacity"]["limit"] != limit:
            raise AssertionError(f"Workspace capacity was not configured: {configured}")

    def allow_coordinator_tools(self, *rules):
        self.change_state(lambda state: state["nodes"][self.node]["toolPolicy"].update(allow=list(rules)))

    def as_legacy_registered_root(self):
        """A run from before parent-evidence admission: a registered root, possibly owning workers."""
        self.close_coordinator()

        def demote(state):
            current = state["nodes"][self.node]
            state["nodes"][self.node] = {**self.registered_root, "lastControlAt": current["lastControlAt"]}
        self.change_state(demote)

    def close_coordinator(self):
        """The human closes the managed coordinator session; its provider exits."""
        self.coordinator_provider.stdin.close()
        self.coordinator_provider.wait(timeout=5)

    def native_request(self, task="Complete the bounded task.", label="Worker", cwd=REPO,
                       allow=None, deny=(), **assignment):
        assignment = {"name": label, "cwd": str(cwd), "task": task, "denyTools": list(deny), **assignment}
        if allow is not None:
            assignment["allowTools"] = list(allow)
        return json.dumps({"identity": self.identity, "assignment": assignment})

    def spawn_native(self, task="Complete the bounded task.", label="Worker", cwd=REPO, *,
                     check=True, env=None, timeout=15, **assignment):
        return self.run("native-spawn", input=self.native_request(task, label, cwd, **assignment),
                        check=check, env=env, timeout=timeout)

    def start_native_spawn(self, task="Complete the bounded task.", label="Worker", cwd=REPO, *,
                           env=None, **assignment):
        return self.start("native-spawn", input=self.native_request(task, label, cwd, **assignment), env=env)

    def spawn_in_process(self, cmux, task="Complete the bounded task.", label="Worker", cwd=REPO, **assignment):
        request = io.TextIOWrapper(io.BytesIO(self.native_request(task, label, cwd, **assignment).encode()))
        with patch.object(sys, "stdin", request), patch.dict(
                CONTROLLER_API["main"].__globals__, fixture_edges(os.environ, self.driver)):
            return CONTROLLER_API["command_native_spawn"](self.root, cmux)

    def run(self, *args, check=True, timeout=15, env=None, input=None):
        command = [
            sys.executable, str(self.driver), *args,
        ]
        with open(self.lifetime.name, "rb") as lifetime:
            fcntl.flock(lifetime, fcntl.LOCK_SH)
            completed = subprocess.run(
                command, env={**(env or self.env), "FAKE_PROCESS_LIFETIME_FD": str(lifetime.fileno())},
                pass_fds=(lifetime.fileno(),), text=True, capture_output=True, timeout=timeout,
                input=input,
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

    def start(self, *args, env=None, input=None):
        with open(self.lifetime.name, "rb") as lifetime:
            fcntl.flock(lifetime, fcntl.LOCK_SH)
            process = subprocess.Popen(
                [sys.executable, str(self.driver), *args],
                env={**(env or self.env), "FAKE_PROCESS_LIFETIME_FD": str(lifetime.fileno())},
                pass_fds=(lifetime.fileno(),), text=True,
                stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
        if input is not None:
            process.stdin.write(input)
            process.stdin.close()
            process.stdin = None
        return process

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
        if self.env["FAKE_SESSION_MODE"] != "bounded" or self.env.get("FAKE_PROVIDER_BARRIER"):
            return self.spawn_native(task, label, allow=allow or None, deny=deny)
        # Report/protocol fixtures exercise the turn after startup acceptance.
        gate = self.path / f"provider-{uuid.uuid4()}"
        try:
            return self.spawn_native(task, label, allow=allow or None, deny=deny,
                                     env={**self.env, "FAKE_PROVIDER_BARRIER": str(gate)})
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

    def quiescence_diagnostics(self, processes):
        result = {
            "recordedAtClose": [
                {"pid": item["pid"], "start": item["start"]} for item in processes
            ],
        }
        lsof = shutil.which("lsof")
        if lsof is None:
            return {**result, "unavailable": "lsof-missing"}
        try:
            opened = subprocess.run(
                [lsof, "-Fp", "--", self.lifetime.name],
                capture_output=True, text=True, timeout=1,
            )
            if opened.returncode not in (0, 1):
                return {**result, "unavailable": f"lsof-exit-{opened.returncode}"}
            pids = sorted({
                int(line[1:]) for line in opened.stdout.splitlines()
                if line.startswith("p") and line[1:].isdigit()
            })
            result["lifetimeFilePids"] = pids
            if pids:
                metadata = subprocess.run(
                    ["/bin/ps", "-o", "pid=,ppid=,lstart=,stat=", "-p",
                     ",".join(str(pid) for pid in pids)],
                    capture_output=True, text=True, timeout=1,
                )
                if metadata.returncode:
                    result["unavailable"] = f"ps-exit-{metadata.returncode}"
                else:
                    result["processMetadata"] = metadata.stdout.splitlines()
        except (OSError, subprocess.TimeoutExpired) as error:
            result["unavailable"] = type(error).__name__
        return result

    def close(self):
        if self.closed:
            return
        # Failure must retain evidence even when this Harness is garbage collected.
        self.temp._finalizer.detach()
        os.pwrite(self.lifetime.fileno(), b"0", 0)
        try:
            if getattr(self, "coordinator_provider", None) is not None:
                self.close_coordinator()
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
                        # File-open observations are sampled after failure, not
                        # authority to signal a descendant or claim lock ownership.
                        diagnostics = self.quiescence_diagnostics(processes)
                        raise AssertionError(
                            f"Fixture process quiescence unavailable; preserved {self.path}\n"
                            f"Fixture process metadata: {json.dumps(diagnostics)}"
                        )
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
            observed = h.quiescence_diagnostics([{**known[0], "args": "not-for-diagnostics"}])
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
        with patch("shutil.which", return_value="/usr/sbin/lsof"), \
                patch("subprocess.run", return_value=subprocess.CompletedProcess(
                    ["lsof"], 2, "", "raw tool error is not diagnostic metadata",
                )):
            self.assertEqual(h.quiescence_diagnostics([]),
                             {"recordedAtClose": [], "unavailable": "lsof-exit-2"})

    def test_constructor_success_keeps_fixture_active_without_cleanup(self):
        h = object.__new__(Harness)
        registration = {"coordinatorId": "synthetic", "controlToken": "synthetic"}
        completed = subprocess.CompletedProcess(["synthetic-registration"], 0, json.dumps(registration), "")
        try:
            with patch("subprocess.run", return_value=completed) as run, \
                    patch("subprocess.Popen", side_effect=AssertionError("no process may start")) as popen, \
                    patch.object(Harness, "seed_native_parent", autospec=True, return_value={}) as seed, \
                    patch.object(Harness, "close", autospec=True) as close:
                h.__init__()
                self.assertEqual(h.registration, {**registration, "returncode": 0, "stderr": ""})
                self.assertEqual(run.call_count, 1)
                seed.assert_called_once_with(h)
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
        environment = {**self.h.env, "PATH": "/usr/bin:/bin"}
        summary = self.capacity(env=environment)["capacity"]
        self.assertEqual(summary["limit"], 32)
        self.assertEqual(summary["used"], 1)
        self.assertTrue(summary["advisory"])
        self.assertTrue(summary["admissionAvailable"])
        self.assertEqual(self.h.state(), before)

    def seed_workspace_history(self, workspace, count):
        def populate(state):
            for index in range(count):
                node, _ = CONTROLLER_API["new_root"](
                    workspace, str(uuid.uuid4()), self.h.pane, f"History {index}",
                )
                state["nodes"][node["id"]] = node
        self.h.change_state(populate)

    def test_other_workspace_full_history_does_not_block_spawn_or_saved_observer(self):
        other = str(uuid.uuid4())
        self.seed_workspace_history(other, 127)
        available = self.capacity()["capacity"]
        self.assertEqual(available["nodeSlotsRemaining"], 127)
        self.assertTrue(available["admissionAvailable"])
        receipt = self.h.spawn()
        node = self.h.wait_node(receipt["workerId"], lambda item: item["availability"] == "idle")
        self.assertEqual(node["workspaceId"], self.h.workspace)
        saved = CONTROLLER_API["read_state"](self.h.root)
        self.assertEqual(len(saved["nodes"]), 129)
        projected = json.loads((self.h.root / "observer/current.json").read_text())
        self.assertTrue(projected["complete"])
        self.assertEqual(len(projected["nodes"]), 129)
        self.assertEqual({item["id"] for item in projected["nodes"]}, set(saved["nodes"]))
        self.seed_workspace_history(other, 1)
        blocked = self.h.run("capacity", "--workspace", other)["capacity"]
        self.assertEqual(blocked["nodeSlotsRemaining"], 0)
        self.assertFalse(blocked["admissionAvailable"])
        self.assertEqual(self.capacity()["capacity"]["nodeSlotsRemaining"], 126)

    def test_workspace_history_limit_and_host_limit_are_distinct(self):
        self.seed_workspace_history(self.h.workspace, 127)
        before = self.h.state()
        blocked = self.h.spawn_native("bounded", "Refused", check=False)
        self.assertEqual(blocked["returncode"], 2)
        self.assertIn("Workspace stored-node limit", blocked["stderr"])
        self.assertEqual(self.h.state(), before)
        capacity = self.capacity()["capacity"]
        self.assertEqual(capacity["storedNodes"], 128)
        self.assertEqual(capacity["storedNodeLimit"], 128)
        self.assertEqual(capacity["hostNodeLimit"], 1024)
        self.assertEqual(capacity["hostNodeSlotsRemaining"], 896)
        self.assertEqual(capacity["hostStateByteLimit"], 1_048_576)

    def test_multi_workspace_validator_keeps_local_node_and_retained_limits(self):
        self.seed_workspace_history(str(uuid.uuid4()), 128)
        saved = self.h.state()
        CONTROLLER_API["validate_state"](saved)
        invalid = json.loads(json.dumps(saved))
        workspace = next(item["workspaceId"] for item in invalid["nodes"].values()
                         if item["workspaceId"] != self.h.workspace)
        extra, _ = CONTROLLER_API["new_root"](workspace, str(uuid.uuid4()), self.h.pane, "Excess")
        invalid["nodes"][extra["id"]] = extra
        with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "Workspace stored-node"):
            CONTROLLER_API["validate_state"](invalid)
        saved["retainedResources"] = [
            {"workspaceId": group, "surfaceId": str(uuid.uuid4())}
            for group in (self.h.workspace, workspace) for _ in range(128)
        ]
        CONTROLLER_API["validate_state"](saved)
        saved["retainedResources"].append({"workspaceId": workspace, "surfaceId": str(uuid.uuid4())})
        with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "Workspace retained"):
            CONTROLLER_API["validate_state"](saved)

    def test_legacy_workspace_uuid_spellings_share_quota_without_rewriting_ownership(self):
        workspace = "abcdefab-1234-4234-8234-abcdefabcdef"
        self.seed_workspace_history(workspace, 127)
        self.seed_workspace_history(workspace.upper(), 1)
        before = self.h.state()
        summary = self.h.run("capacity", "--workspace", workspace)["capacity"]
        self.assertEqual(summary["storedNodes"], 128)
        self.assertEqual(summary["nodeSlotsRemaining"], 0)
        self.assertFalse(summary["admissionAvailable"])
        self.assertEqual(CONTROLLER_API["workspace_capacity"](before, workspace.upper())["storedNodes"], 128)
        self.assertEqual(self.h.state(), before)
        self.assertEqual(sum(node["workspaceId"] == workspace.upper()
                             for node in before["nodes"].values()), 1)
        with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "Workspace stored-node"):
            CONTROLLER_API["require_node_capacity"](before, workspace.upper())
        extra, _ = CONTROLLER_API["new_root"](
            workspace.upper(), str(uuid.uuid4()), self.h.pane, "Case alias",
        )
        before["nodes"][extra["id"]] = extra
        with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "Workspace stored-node"):
            CONTROLLER_API["validate_state"](before)

    def test_legacy_retained_workspace_spellings_share_the_same_bound(self):
        workspace = "abcdefab-1234-4234-8234-abcdefabcdef"
        saved = self.h.state()
        saved["retainedResources"] = [
            {"workspaceId": workspace, "surfaceId": str(uuid.uuid4())} for _ in range(127)
        ]
        saved["retainedResources"].append({
            "workspaceId": workspace.upper(), "surfaceId": str(uuid.uuid4()),
        })
        CONTROLLER_API["validate_state"](saved)
        summary = CONTROLLER_API["workspace_capacity"](saved, workspace)
        self.assertEqual(summary["retainedResources"], 128)
        self.assertEqual(summary["used"], 128)
        self.assertFalse(summary["admissionAvailable"])
        saved["retainedResources"].append({
            "workspaceId": workspace.upper(), "surfaceId": str(uuid.uuid4()),
        })
        with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "Workspace retained"):
            CONTROLLER_API["validate_state"](saved)

    def test_retired_history_in_a_does_not_consume_b_and_does_not_get_pruned(self):
        other = str(uuid.uuid4())
        def populate(state):
            root, _ = CONTROLLER_API["new_root"](other, str(uuid.uuid4()), self.h.pane, "Other root")
            state["nodes"][root["id"]] = root
            for index in range(127):
                retired, _ = CONTROLLER_API["new_root"](other, str(uuid.uuid4()), self.h.pane, f"Retired {index}")
                retired.update(
                    role="worker", parentId=root["id"], runId=root["runId"],
                    executionMode="bounded", phase="resource-retired", availability="unavailable",
                    generation=1, copilotSessionId=str(uuid.uuid4()),
                )
                state["nodes"][retired["id"]] = retired
        self.h.change_state(populate)
        original = {key: value for key, value in self.h.state()["nodes"].items()
                    if value["workspaceId"] == other}
        preflight = self.h.run("capacity", "--workspace", other)["capacity"]
        self.assertEqual(preflight["used"], 0)
        self.assertEqual(preflight["remaining"], 32)
        self.assertEqual(preflight["nodeSlotsRemaining"], 0)
        self.assertFalse(preflight["admissionAvailable"])
        worker = self.h.spawn()
        self.h.wait_node(worker["workerId"], lambda node: node["availability"] == "idle")
        after = {key: value for key, value in self.h.state()["nodes"].items()
                 if value["workspaceId"] == other}
        self.assertEqual(after, original)

    def test_concurrent_registration_rechecks_each_workspace_last_node_slot(self):
        other = str(uuid.uuid4())
        self.seed_workspace_history(self.h.workspace, 126)
        self.seed_workspace_history(other, 127)
        surfaces = [str(uuid.uuid4()) for _ in range(3)]
        for surface in surfaces[:2]:
            self.h.add_surface(surface)
        processes = []
        for index, surface in enumerate(surfaces):
            workspace = self.h.workspace if index < 2 else other
            env = {**self.h.env, "CMUX_WORKSPACE_ID": workspace, "CMUX_SURFACE_ID": surface}
            if index == 2:
                env.update(FAKE_CMUX_STATE=str(self.h.path / "other-cmux.json"),
                           TEST_WORKSPACE=workspace, TEST_ROOT_SURFACE=surface)
            processes.append(self.h.start(
                "register", "--workspace", workspace, "--surface", surface, "--name", "Concurrent",
                env=env,
            ))
        results = [self.h.finish(process, check=False) for process in processes]
        self.assertEqual(sorted(item["returncode"] for item in results[:2]), [0, 2])
        self.assertEqual(results[2]["returncode"], 0)
        denied = next(item for item in results[:2] if item["returncode"])
        self.assertIn("Workspace stored-node limit", denied["stderr"])
        saved = CONTROLLER_API["read_state"](self.h.root)
        self.assertEqual(len(saved["nodes"]), 256)
        for workspace in (self.h.workspace, other):
            self.assertEqual(sum(node["workspaceId"] == workspace for node in saved["nodes"].values()), 128)

    def test_byte_or_projection_overflow_cannot_commit_a_partial_reservation(self):
        before = self.h.state()
        observer = (self.h.root / "observer/current.json").read_bytes()
        with patch.object(CONTROLLER_API["Store"], "_projection",
                          side_effect=CONTROLLER_API["OrchestrationError"]("Host observer byte safety")):
            with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "Host observer"):
                self.seed_workspace_history(str(uuid.uuid4()), 1)
        self.assertEqual(self.h.state(), before)
        self.assertEqual((self.h.root / "observer/current.json").read_bytes(), observer)
        with CONTROLLER_API["Store"](self.h.root) as store:
            with patch.dict(CONTROLLER_API["Store"].write.__globals__, {"MAX_BYTES": 64}):
                with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "Host control-state byte"):
                    store.write(before)
        self.assertEqual(self.h.state(), before)

    def test_real_byte_overflow_refuses_before_surface_or_partial_state_publication(self):
        other = str(uuid.uuid4())
        def populate(state):
            root, _ = CONTROLLER_API["new_root"](other, str(uuid.uuid4()), self.h.pane, "Other")
            state["nodes"][root["id"]] = root
            for index in range(31):
                retired, _ = CONTROLLER_API["new_root"](other, str(uuid.uuid4()), self.h.pane, f"Retired {index}")
                retired.update(
                    role="worker", parentId=root["id"], runId=root["runId"],
                    executionMode="bounded", phase="resource-retired", availability="unavailable",
                    generation=1, copilotSessionId=str(uuid.uuid4()),
                    task="x" * 32_768 if index < 30 else "",
                )
                state["nodes"][retired["id"]] = retired
            size = len(json.dumps(state, sort_keys=True, separators=(",", ":")).encode()) + 1
            remaining = 1_048_576 - 8192 - size
            self.assertGreaterEqual(remaining, 0)
            self.assertLessEqual(remaining, 32_768)
            retired["task"] = "x" * remaining
        self.h.change_state(populate)
        before = {
            path: path.read_bytes() for path in (
                self.h.root / "control/state.json", self.h.root / "observer/current.json",
                self.h.root / "observer/icons.json",
            )
        }
        summary = self.capacity()["capacity"]
        self.assertEqual(summary["hostStateBytesRemaining"], 8192)
        self.assertEqual(summary["nodeSlotsRemaining"], 127)
        self.assertGreater(summary["hostNodeSlotsRemaining"], 0)
        surfaces = self.h.cmux_data()["surfaces"]
        denied = self.h.spawn_native(task="x" * 32_768, label="Too large", check=False)
        self.assertEqual(denied["returncode"], 2)
        self.assertIn("Host control-state byte safety limit", denied["stderr"])
        self.assertEqual(self.h.cmux_data()["surfaces"], surfaces)
        self.assertEqual(self.h.calls(), [])
        for path, payload in before.items():
            self.assertEqual(path.read_bytes(), payload)

    def test_archive_keeps_other_workspace_retained_resources_without_global_128_refusal(self):
        other = str(uuid.uuid4())
        retained = [
            {"workspaceId": other, "surfaceId": str(uuid.uuid4()),
             "runId": str(uuid.uuid4()), "archivedAt": CONTROLLER_API["now"]()}
            for _ in range(128)
        ]
        self.h.change_state(lambda state: state.update(retainedResources=retained))
        receipt = self.h.spawn()
        self.h.wait_node(receipt["workerId"], lambda node: node["phase"] == "reported-completed")
        self.h.close_coordinator()
        archived = self.h.run("archive", "--actor-id", self.h.node, "--token", self.h.token)
        self.assertTrue(archived["archived"])
        state = CONTROLLER_API["read_state"](self.h.root)
        # Both the worker's and the managed coordinator's terminals stay retained.
        self.assertEqual(len(state["retainedResources"]), 130)
        self.assertEqual([item for item in state["retainedResources"] if item["workspaceId"] == other],
                         retained)
        self.assertEqual(sum(item["workspaceId"] == self.h.workspace
                             for item in state["retainedResources"]), 2)

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
        barrier = self.h.path / "capacity-update-runtime-lock"
        barrier.touch()
        # Hold runtime publication, not a wall-clock delay, while comparing the
        # complete state before/after the capacity-only mutation.
        with barrier.open() as latch:
            fcntl.flock(latch, fcntl.LOCK_EX)
            self.h.env.update(FAKE_RUNTIME_LOCK=str(barrier), FAKE_STARTUP_SECONDS="0")
            try:
                receipts = [self.h.spawn(label=f"Existing {index}") for index in range(2)]
                self.assertTrue(all(item["startup"] == "pending" for item in receipts))
                before = self.h.state()
                summary = self.configure(1)["capacity"]
                self.assertEqual(summary["used"], 3)
                self.assertEqual(summary["remaining"], 0)
                self.assertFalse(summary["admissionAvailable"])
                after = self.h.state()
                self.assertEqual(after["nodes"], before["nodes"])
                self.assertEqual(after["retainedResources"], before["retainedResources"])
                self.assertEqual(after["launches"], before["launches"])
                self.assertEqual(self.h.calls(), [])
                rejected = self.h.spawn_native(task="bounded", label="Refused", check=False)
                self.assertEqual(rejected["returncode"], 2)
                self.assertIn("resource limit", rejected["stderr"])
                self.assertEqual(len(self.h.cmux_data()["surfaces"]), len(receipts) + 1)
            finally:
                fcntl.flock(latch, fcntl.LOCK_UN)
        for receipt in receipts:
            self.h.wait_node(receipt["workerId"], lambda node: node["phase"] == "reported-completed")
        self.assertEqual(len(self.h.calls()), 2)
        self.assertEqual(self.capacity()["capacity"]["used"], 3)

    def test_advisory_preflight_cannot_reserve_last_slot_against_concurrent_spawns(self):
        # The managed coordinator holds one slot; one remains for the race.
        self.configure(2)
        self.assertTrue(self.capacity()["capacity"]["admissionAvailable"])
        processes = [self.h.start_native_spawn("bounded", "Capacity race") for _ in range(2)]
        results = [self.h.finish(process, check=False) for process in processes]
        self.assertEqual(sorted(result["returncode"] for result in results), [0, 2])
        failed = next(result for result in results if result["returncode"] == 2)
        self.assertIn("resource limit", failed["stderr"])
        summary = self.capacity()["capacity"]
        self.assertEqual(summary["used"], 2)
        self.assertFalse(summary["admissionAvailable"])
        self.assertEqual(len(self.h.cmux_data()["surfaces"]), 2)
        self.configure(128)
        self.assertTrue(self.capacity()["capacity"]["admissionAvailable"])
        self.configure(1)
        self.assertEqual(self.capacity()["capacity"]["used"], 2)


class AdmissionGateTests(unittest.TestCase):
    def setUp(self):
        self.h = Harness()
        self.addCleanup(self.h.close)

    def test_token_spawn_without_parent_evidence_refuses_despite_retired_testing_flag(self):
        surface = str(uuid.uuid4())
        self.h.add_surface(surface)
        env = {**self.h.env, "CMUX_SURFACE_ID": surface}
        registered = self.h.run("register", "--workspace", self.h.workspace, "--surface", surface,
                                "--name", "Registered only", env=env)
        before = self.h.state()
        surfaces = list(self.h.cmux_data()["surfaces"])
        # The shipped entrypoint, not the fixture driver, with every retired switch set.
        refused = subprocess.run(
            [sys.executable, str(CONTROLLER), "spawn", "--actor-id", registered["coordinatorId"],
             "--token", registered["controlToken"], "--name", "Must not launch", "--cwd", str(REPO),
             "--task", "No parent evidence"],
            env={**env, "CMUX_MAESTRO_TESTING": "1", "CMUX_MAESTRO_COPILOT": str(self.h.copilot),
                 "CMUX_MAESTRO_CMUX": str(self.h.cmux)},
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(refused.returncode, 2, refused.stdout)
        self.assertIn("parent-account evidence", refused.stderr)
        self.assertEqual(self.h.state(), before)
        self.assertEqual(self.h.cmux_data()["surfaces"], surfaces)
        self.assertEqual(self.h.calls(), [])


class RecordedAccountTests(unittest.TestCase):
    """One recorded account per node: observed when reported, else the launch's pinned login."""

    accessor = staticmethod(CONTROLLER_API["recorded_account"])
    validate = staticmethod(CONTROLLER_API["validate_recorded_account"])

    def test_launched_and_older_nodes_derive_from_launch_settings(self):
        self.assertEqual(self.accessor({"launchSettings": {"version": 1, "copilotAccount": "work-user"}}),
                         {"login": "work-user", "host": "github.com"})
        self.assertIsNone(self.accessor({"launchSettings": {"version": 1}}))
        self.assertIsNone(self.accessor({}))

    def test_an_observed_account_is_the_only_store(self):
        observed = {"launchSettings": {"version": 1}, "copilotAccount": {"login": "seen-user", "host": "github.com"}}
        self.validate(observed)
        self.assertEqual(self.accessor(observed), {"login": "seen-user", "host": "github.com"})
        self.validate({"launchSettings": {"version": 1, "copilotAccount": "work-user"}})

    def test_invalid_or_duplicated_records_refuse(self):
        for node in (
            {"launchSettings": {"version": 1, "copilotAccount": "work-user"},
             "copilotAccount": {"login": "work-user", "host": "github.com"}},
            {"copilotAccount": {"login": "work-user", "host": "example.com"}},
            {"copilotAccount": {"login": "work-user", "host": "github.com", "token": "synthetic"}},
            {"copilotAccount": {"login": "--show-token", "host": "github.com"}},
            {"copilotAccount": {"login": "work-user"}},
            {"copilotAccount": "work-user"},
            {"copilotAccount": None},
        ):
            with self.subTest(node=node), self.assertRaises(CONTROLLER_API["OrchestrationError"]):
                self.validate(node)


class RecordedAccountStateLoadTests(unittest.TestCase):
    """The state loader enforces the account rule, not only the helper."""

    def setUp(self):
        self.h = Harness()
        self.addCleanup(self.h.close)

    def load_with(self, change):
        path = self.h.root / "control" / "state.json"
        state = json.loads(path.read_text())
        change(state["nodes"][self.h.node])
        path.write_text(json.dumps(state))
        return CONTROLLER_API["read_state"](self.h.root)

    def test_state_with_an_invalid_account_record_refuses_to_load(self):
        for record in (
            {"login": "synthetic-account", "host": "example.com"},
            {"login": "synthetic-account", "host": "github.com", "token": "synthetic"},
            {"login": "--show-token", "host": "github.com"},
        ):
            with self.subTest(record=record), self.assertRaisesRegex(
                    CONTROLLER_API["OrchestrationError"], "recorded account"):
                self.load_with(lambda node: node.update(copilotAccount=record))
        with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "recorded account"):
            # Pinned launch login plus an observed record: two stores.
            self.load_with(lambda node: node.update(copilotAccount={"login": "other", "host": "github.com"}))

    def test_state_without_the_field_loads_and_derives_the_account(self):
        state = self.load_with(lambda node: node.pop("copilotAccount", None))
        self.assertEqual(CONTROLLER_API["recorded_account"](state["nodes"][self.h.node]),
                         {"login": "synthetic-account", "host": "github.com"})


BORN_PROVIDER = r"""
import json, os, subprocess, sys
# Stands in for the Copilot provider: the enrolling controller runs as its descendant.
driver, request, overrides = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3])
request.setdefault("pid", os.getpid())
env = {**os.environ, "COPILOT_EXTENSION_PARENT_PID": str(os.getpid()), **overrides}
env = {key: value for key, value in env.items() if value is not None}
# Like a real provider in a CMUX surface: its own session with that surface's controlling TTY.
import fcntl, pty, termios
master, slave = pty.openpty()
os.setsid()
fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
own_tty = os.ttyname(slave)[len("/dev/"):]
claimed = {"match": own_tty, "other": "ttys999", "none": None}[env.pop("FAKE_SURFACE_TTY", "match")]
state_path = env["FAKE_CMUX_STATE"]
with open(os.path.splitext(state_path)[0] + ".lock", "a+") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    data = json.load(open(state_path))
    data.setdefault("ttys", {})[env["CMUX_SURFACE_ID"]] = claimed
    with open(state_path + ".tmp", "w") as stream:
        json.dump(data, stream)
    os.replace(state_path + ".tmp", state_path)
holders = []
# Copilot holds a session with inuse.<PID>.lock from its first prompt; by default this provider
# already does. "none" stands for a session before its first prompt.
holder = env.pop("FAKE_HOLD_SESSION_LOCK", "1")
if holder not in ("none", "1"):
    # Copilot marks the session it holds with inuse.<PID>.lock; the owner may be the provider
    # (below), its direct child, a grandchild, or an orphan started after it (unrelated).
    if True:
        code = {"child": "import sys; sys.stdin.read()",
                "grandchild": "import subprocess, sys; p = subprocess.Popen([sys.executable, '-c', "
                              "'import sys; sys.stdin.read()']); print(p.pid, flush=True); sys.stdin.read()",
                "unrelated": "import subprocess, sys; p = subprocess.Popen([sys.executable, '-c', "
                             "'import sys; sys.stdin.read()'], start_new_session=True); print(p.pid, flush=True)",
                }[holder]
        process = subprocess.Popen([sys.executable, "-c", code], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   text=True)
        holders.append(process)
        owner = process.pid if holder == "child" else int(process.stdout.readline())
    state = os.path.join(env["HOME"], ".copilot", "session-state", env["SESSION_ID"])
    os.makedirs(state, mode=0o700, exist_ok=True)
    open(os.path.join(state, "inuse.%d.lock" % owner), "w").close()
sessions = json.loads(sys.argv[5])
# Copilot persists a real session's state directory when the session starts; a `--resume`
# startup placeholder never gets one.
unpersisted = set(json.loads(env.pop("FAKE_UNPERSISTED", "[]")))
own_locks = []
for session in sessions or [env["SESSION_ID"]]:
    if session not in unpersisted:
        state = os.path.join(env["HOME"], ".copilot", "session-state", session)
        os.makedirs(state, mode=0o700, exist_ok=True)
        if holder == "1":
            own_locks.append(os.path.join(state, "inuse.%d.lock" % os.getpid()))
            open(own_locks[-1], "w").close()
runs = [({**request, "sessionId": session}, {**env, "SESSION_ID": session}) for session in sessions] or \
    [(request, env)] * int(sys.argv[4])
between = env.pop("FAKE_BETWEEN", None)  # test code run inside this provider between enrollments
then = env.pop("FAKE_THEN", None)        # test code run inside this live provider afterwards
concurrent = env.pop("FAKE_CONCURRENT", None)  # every enrollment at once, like racing extension joins
runs = [(body, {key: value for key, value in environment.items()
                if key not in ("FAKE_BETWEEN", "FAKE_THEN", "FAKE_CONCURRENT")})
        for body, environment in runs]
results = []
if concurrent:
    import types
    started = [subprocess.Popen([sys.executable, driver, "native-enroll"], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, text=True)
               for body, environment in runs]
    for process, (body, _) in zip(started, runs):
        process.stdin.write(json.dumps(body))
        process.stdin.close()
    for process in started:
        stdout, stderr = process.stdout.read(), process.stderr.read()  # small JSON replies
        results.append(types.SimpleNamespace(returncode=process.wait(timeout=30), stdout=stdout, stderr=stderr))
for index, (body, environment) in enumerate([] if concurrent else runs):
    if index and between:
        exec(between, {"driver": driver, "subprocess": subprocess, "sys": sys, "os": os, "json": json,
                       "results": results, "env": runs[index - 1][1]})
    results.append(subprocess.run([sys.executable, driver, "native-enroll"], input=json.dumps(body),
                                  env=environment, capture_output=True, text=True, timeout=15))
if then:
    scope = {"driver": driver, "subprocess": subprocess, "sys": sys, "os": os, "json": json,
             "env": runs[0][1], "results": results}
    exec(then, scope)
    results.append(scope["result"])
for process in holders:
    process.stdin.close()  # the lock holders read stdin and end at its EOF
    process.wait(timeout=10)
for lock in own_locks:  # Copilot removes its marker when it exits normally
    try:
        os.unlink(lock)
    except FileNotFoundError:
        pass
print(json.dumps([{"pid": os.getpid(), "returncode": result.returncode,
                   "stdout": result.stdout, "stderr": result.stderr} for result in results]))
"""


class BornFixture:
    """Installed integration plus a synthetic provider whose controller is its descendant."""

    def setUp(self):
        self.h = Harness()
        self.addCleanup(self.h.close)
        self.routes = Path(tempfile.mkdtemp(prefix="m61-", dir="/tmp")).resolve()
        self.addCleanup(shutil.rmtree, self.routes, True)
        self.extension = self.h.path / "installed-extension"
        self.extension.mkdir(mode=0o700)
        for name in ("adapter.mjs", "extension.mjs"):
            shutil.copyfile(REPO / "scripts" / "delivery-proof" / name, self.extension / name)
            (self.extension / name).chmod(0o600)
        self.install(age=10)
        self.provider = self.h.path / "born-provider.py"
        self.provider.write_text(BORN_PROVIDER)

    def install(self, age):
        bin_directory = self.h.root / "bin"
        bin_directory.mkdir(mode=0o700, exist_ok=True)
        config = bin_directory / "messaging.json"
        config.write_text(json.dumps({"version": 1, "routes": str(self.routes), "extension": str(self.extension)}))
        config.chmod(0o600)
        stamp = time.time() - age
        for name in ("adapter.mjs", "extension.mjs"):
            os.utime(self.extension / name, (stamp, stamp))

    def enroll(self, surface=None, session=None, login="human-account", host="github.com",
               env=None, repeat=1, sessions=(), provider_flags=(), **request):
        surface = surface or str(uuid.uuid4())
        if surface not in self.h.cmux_data()["surfaces"]:
            self.h.add_surface(surface)
        session = session or str(uuid.uuid4())
        body = {"workspaceId": self.h.workspace, "surfaceId": surface, "sessionId": session,
                "login": login, "host": host, **request}
        overrides = {"CMUX_SURFACE_ID": surface, "SESSION_ID": session, **(env or {})}
        with open(self.h.lifetime.name, "rb") as lifetime:
            fcntl.flock(lifetime, fcntl.LOCK_SH)
            completed = subprocess.run(
                [sys.executable, str(self.provider), str(self.h.driver), json.dumps(body), json.dumps(overrides),
                 str(repeat), json.dumps(list(sessions)), *provider_flags],
                env={**self.h.env, "FAKE_PROCESS_LIFETIME_FD": str(lifetime.fileno())},
                pass_fds=(lifetime.fileno(),), capture_output=True, text=True, timeout=20,
            )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        outcomes = []
        for result in json.loads(completed.stdout):
            if result["returncode"] == 0:
                outcomes.append({"ok": True, "surface": surface, "session": session, "pid": result["pid"],
                                 **json.loads(result["stdout"])})
            else:
                outcomes.append({"ok": False, "surface": surface, "session": session,
                                 "error": json.loads(result["stderr"] or result["stdout"])["error"]})
        return outcomes[0] if len(outcomes) == 1 else outcomes

    def add_child(self, root_id, *, provider="ended"):
        child_id, surface = str(uuid.uuid4()), str(uuid.uuid4())

        def add(state):
            root = state["nodes"][root_id]
            child = {key: value for key, value in json.loads(json.dumps(root)).items() if key != "enrollment"}
            child.update(id=child_id, role="worker", parentId=root_id, surfaceId=surface,
                         copilotSessionId=str(uuid.uuid4()), launchAccepted=True,
                         providerProcess=root["providerProcess"] if provider == "ended" else provider)
            state["nodes"][child_id] = child
        self.h.change_state(add)
        return child_id, surface

    def unchanged(self, before):
        """Nothing owned changed; a recorded start-attempt refusal is allowed."""
        after = self.h.state()
        for key in ("nodes", "archives", "retainedResources", "launches"):
            self.assertEqual(after[key], before[key], key)

    def refused(self, outcome, reason):
        self.assertFalse(outcome["ok"], outcome)
        self.assertEqual(outcome["error"], f"enrollment refused: {reason}")



class LaunchFlagPermissionsTests(unittest.TestCase):
    def test_only_complete_positive_launch_flags_grant_allow_all(self):
        parse = CONTROLLER_API["launch_flags_allow_all"]
        for flags in (
            ["--yolo"], ["--allow-all"], ["--allow-all=true"], ["--yolo=true"],
            ["--allow-all-tools", "--allow-all-paths", "--allow-all-urls"],
            ["--allow-all-paths=true", "--allow-all-tools=true", "--allow-all-urls=true"],
            ["--resume", "--yolo"], ["-r", "--allow-all"], ["--share-gist", "--yolo"],
            ["--allow-tool", "--yolo"],
        ):
            with self.subTest(flags=flags):
                self.assertTrue(parse(["copilot", *flags]))
        for flags in (
            [], ["--allow-all-tools"], ["--allow-all-paths"], ["--yolo=false"],
            ["--allow-all=0"], ["--allow-all=false"], ["--allow-all-tools=false", "--allow-all-paths"],
            ["--allow-all", "--allow-all=false"], ["--", "--yolo"],
            ["--interactive", "--yolo"], ["--prompt=--allow-all"],
            ["--interactive", "a task mentions --allow-all"], ["--yolo-extra"],
            ["--allow-all-tools", "--allow-all-paths"],
            ["-n", "--yolo"], ["--stream", "--yolo"], ["--attachment", "--allow-all"],
            ["--new-value-option", "--yolo"], ["--yolo", "--assisted-approval"],
            ["--yolo", "--excluded-tools=write"], ["--yolo", "--disallow-temp-dir"],
            ["--yolo", "--disable-mcp-server", "github-mcp-server"],
            ["--yolo", "--disable-builtin-mcps"],
            ["--allow-all", "--agent", "readonly"],
            ["--agent=readonly", "--allow-all"],
            ["--allow-all", "--config-dir", "/synthetic/restricted"],
            ["--config-dir=/synthetic/restricted", "--yolo"],
            ["--allow-all", "--profile", "readonly"],
            ["--profile=readonly", "--allow-all"],
        ):
            with self.subTest(flags=flags):
                self.assertFalse(parse(["copilot", *flags]))

    def test_unrecorded_deny_flags_do_not_widen_the_parent(self):
        parse = CONTROLLER_API["launch_flags_allow_all"]
        self.assertFalse(parse(["copilot", "--yolo", "--deny-tool", "shell(rm)"]))
        self.assertTrue(parse(["copilot", "--yolo", "--deny-tool=shell(rm)"], ["shell(rm)"]))
        self.assertFalse(parse(["copilot", "--yolo", "--deny-tool", "web", "shell(rm)"], ["web"]))
        self.assertFalse(parse(["copilot", "--yolo", "--deny-url=example.test"]))
        self.assertFalse(parse(["copilot", "--yolo", "--resume", "--deny-tool", "shell(rm)"]))
        self.assertFalse(parse(["copilot", "--resume", "--deny-tool=web", "--yolo"]))

    def test_process_arguments_keep_boundaries_and_exclude_environment(self):
        parse = CONTROLLER_API["darwin_process_arguments"]
        raw = (int(3).to_bytes(4, sys.byteorder, signed=True)
               + b"/bin/copilot\0\0copilot\0--interactive\0private text --yolo\0TOKEN=--allow-all\0")
        self.assertEqual(parse(raw), ["copilot", "--interactive", "private text --yolo"])
        for invalid in (b"", b"\0" * 8, raw[:25], raw[:-len(b"TOKEN=--allow-all\0") - 1]):
            with self.subTest(raw=invalid):
                self.assertIsNone(parse(invalid))

    def test_pid_reuse_or_unavailable_argv_never_proves_allow_all(self):
        observe = CONTROLLER_API["observe_launch_permissions"]
        actor = {"providerProcess": {"pid": 123, "start": "original"}, "toolPolicy": {"deny": []}}
        for starts, argv, expected in (
            (["original", "original"], ["copilot", "--yolo"], ("yolo", "launch-flags")),
            (["original", "original"], ["copilot"], ("default", "launch-flags")),
            (["reused"], ["copilot", "--yolo"], ("default", "unverified")),
            (["original", "reused"], ["copilot", "--yolo"], ("default", "unverified")),
            (["original", "original"], None, ("default", "unverified")),
        ):
            with self.subTest(starts=starts, argv=argv):
                read = unittest.mock.Mock(return_value=argv)
                with patch.dict(observe.__globals__, {
                    "process_start": unittest.mock.Mock(side_effect=starts),
                    "process_arguments": read,
                }):
                    self.assertEqual(observe(actor), {"permissionMode": expected[0], "permissionSource": expected[1]})
                self.assertLessEqual(read.call_count, 1)


class BornManagedEnrollmentTests(BornFixture, unittest.TestCase):
    """Copilot sessions started in CMUX enroll as their own root (ADR 0025)."""

    def test_launch_flags_record_allow_all_without_retaining_argv(self):
        outcome = self.enroll(provider_flags=["--allow-all", "--interactive", "private-argv-sentinel"])
        self.assertTrue(outcome["ok"], outcome)
        node = self.h.state()["nodes"][outcome["nodeId"]]
        self.assertEqual(node["permissionMode"], "yolo")
        self.assertEqual(node["permissionSource"], "launch-flags")
        for directory in (self.h.root, self.routes):
            for path in directory.rglob("*.json"):
                self.assertNotIn("private-argv-sentinel", path.read_text(), str(path))

    def test_session_born_in_cmux_becomes_its_own_root_with_recorded_account(self):
        outcome = self.enroll()
        self.assertTrue(outcome["ok"], outcome)
        node = self.h.state()["nodes"][outcome["nodeId"]]
        self.assertEqual((node["role"], node["parentId"], node["enrollment"]), ("coordinator", None, "born"))
        self.assertNotEqual(node["runId"], self.h.registration["runId"])
        self.assertEqual((node["surfaceId"], node["copilotSessionId"], node["generation"]),
                         (outcome["surface"], outcome["session"], 1))
        self.assertEqual(node["copilotAccount"], {"login": "human-account", "host": "github.com"})
        self.assertEqual(node["toolPolicy"], {"allow": [], "deny": []})
        self.assertEqual(node["permissionMode"], "default")
        self.assertEqual(node["providerProcess"]["pid"], outcome["pid"])
        self.assertEqual((outcome["routes"], outcome["peer"]),
                         (str(self.routes), CONTROLLER_API["message_peer"](node)))
        binding = json.loads((self.routes / f"{outcome['peer']}.json").read_text())
        self.assertEqual((binding["nodeId"], binding["sessionId"], binding["generation"]),
                         (node["id"], outcome["session"], 1))
        self.assertNotIn("synthetic-work-token", json.dumps(self.h.state()))
        self.assertEqual(self.h.calls(), [])
        projected = json.loads((self.h.root / "observer" / "current.json").read_text())["nodes"]
        self.assertEqual([item.get("enrollment") for item in projected if item["id"] == node["id"]], ["born"])
        self.assertTrue(all("enrollment" not in item for item in projected if item["id"] != node["id"]))

    def test_extension_reload_in_the_same_provider_reuses_the_node(self):
        first, reload = self.enroll(repeat=2)
        self.assertTrue(first["ok"] and reload["ok"], (first, reload))
        self.assertEqual(reload, first)
        born = [n for n in self.h.state()["nodes"].values() if n.get("enrollment") == "born"]
        self.assertEqual([n["id"] for n in born], [first["nodeId"]])
        # A different provider process on the same session is not a reload: once the first
        # provider has ended, it resumes the node as its next generation.
        again = self.enroll(surface=first["surface"], session=first["session"])
        self.assertTrue(again["ok"], again)
        self.assertEqual((again["nodeId"], again["generation"]), (first["nodeId"], 2))

    def test_a_second_session_in_the_same_provider_is_refused(self):
        # After /clear the same provider process reports a new session in the same surface.
        first, second = self.enroll(sessions=[str(uuid.uuid4()), str(uuid.uuid4())])
        self.assertTrue(first["ok"], first)
        self.refused(second, "provider-already-enrolled")
        self.assertEqual(len([n for n in self.h.state()["nodes"].values() if n.get("enrollment")]), 1)

    END_PREVIOUS_SESSION = (
        "receipt = json.loads(results[-1].stdout)\n"
        "binding = json.load(open(os.path.join(receipt['routes'], receipt['peer'] + '.json')))\n"
        "identity = {k: binding[k] for k in ('nodeId', 'workspaceId', 'sessionId', 'generation', 'capability')}\n"
        "subprocess.run([sys.executable, driver, 'native-session-end'], input=json.dumps({'identity': identity}),"
        " env=env, capture_output=True, text=True, timeout=30, check=True)\n")

    def test_a_new_session_in_the_same_provider_after_its_session_ended_takes_over(self):
        # `/clear` ends the session (its own extension records the end), then the same provider
        # joins extensions to a new session in the same surface.
        cleared, fresh = str(uuid.uuid4()), str(uuid.uuid4())
        first, second = self.enroll(sessions=[cleared, fresh], env={"FAKE_BETWEEN": self.END_PREVIOUS_SESSION})
        self.assertTrue(first["ok"], first)
        self.assertTrue(second["ok"], second)
        state = self.h.state()
        self.assertNotIn(first["nodeId"], state["nodes"])
        node = state["nodes"][second["nodeId"]]
        self.assertEqual((node["copilotSessionId"], node["surfaceId"]), (fresh, first["surface"]))
        self.assertEqual(node["providerProcess"]["pid"], second["pid"])

    def test_concurrent_joins_of_one_session_enroll_once(self):
        marker = str(self.h.path / "pause")

        def release():
            deadline = time.monotonic() + 10
            while not Path(marker + ".ready").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            time.sleep(1)  # the other join runs while the first holds its bound route
            Path(marker + ".release").write_text("")
        releaser = threading.Thread(target=release)
        releaser.start()
        self.addCleanup(releaser.join)
        first, second = self.enroll(repeat=2, env={"FAKE_CONCURRENT": "1", "FAKE_PAUSE_AFTER_BIND": marker})
        self.assertTrue(first["ok"] and second["ok"], (first, second))
        self.assertEqual(first, second)
        born = [n for n in self.h.state()["nodes"].values() if n.get("enrollment") == "born"]
        self.assertEqual([n["id"] for n in born], [first["nodeId"]])
        self.assertEqual({value["outcome"] for value in self.h.state()["enrollmentAttempts"].values()},
                         {"enrolled"})

    def between_changing_state(self, change):
        """FAKE_BETWEEN code that applies `change(state)` (source text) under the state lock."""
        return ("import importlib.util\n"
                f"spec = importlib.util.spec_from_file_location('controller', {str(CONTROLLER)!r})\n"
                "controller = importlib.util.module_from_spec(spec)\n"
                "spec.loader.exec_module(controller)\n"
                f"controller.mutate(controller.default_root(), lambda state: exec({change!r}, {{'state': state}}))\n")

    def test_a_reload_after_the_enrolled_node_left_says_so(self):
        first, reload = self.enroll(repeat=2, env={"FAKE_BETWEEN": self.between_changing_state(
            "[node.update(phase='resource-retired', availability='unavailable') for node in state['nodes'].values()"
            " if node.get('enrollment') == 'born']")})
        self.assertTrue(first["ok"], first)
        self.refused(reload, "enrolled-node-unavailable")
        attempts = self.h.state()["enrollmentAttempts"]
        self.assertEqual([value["outcome"] for value in attempts.values()], ["enrolled"])

    def test_a_busy_enrollment_is_not_recorded(self):
        with open(self.h.root / "control" / "enrollment.lock", "a+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            outcome = self.enroll(env={"FAKE_BORN_ENROLL_LOCK_SECONDS": "0.2"})
        self.refused(outcome, "enrollment-busy")
        self.assertEqual(self.h.state().get("enrollmentAttempts", {}), {})

    def test_before_copilot_holds_the_session_nothing_is_decided(self):
        # Two tabs resume the same saved session; Copilot writes its lock only at a first prompt.
        # Neither may look like the sole owner, and nothing is recorded.
        session = str(uuid.uuid4())
        for _ in range(2):
            self.refused(self.enroll(session=session, env={"FAKE_HOLD_SESSION_LOCK": "none"}),
                         "awaiting-first-prompt")
        state = self.h.state()
        self.assertFalse(any(node.get("enrollment") for node in state["nodes"].values()))
        self.assertEqual(state.get("enrollmentAttempts", {}), {})
        self.assertTrue(self.enroll(session=session)["ok"])

    def test_refusals_this_controller_no_longer_makes_are_decided_again(self):
        decided = CONTROLLER_API["recorded_decision"]
        anchor = {"pid": 4242, "start": "Sun Oct 18 22:12:58 2026"}
        key = f"{uuid.uuid4()}:4242:{anchor['start']}"
        refused = lambda reason: {"outcome": "refused", "reason": reason, "at": "2026-10-19T02:13:03Z"}
        holder = {"enrollment": "born", "providerProcess": anchor, "generation": 1}
        for reason, nodes, kept in (
            ("session-started-before-install", {}, False), ("enrollment-window-passed", {}, False),
            ("session-ended", {}, False),
            ("provider-already-enrolled", {}, False),  # the pre-upgrade placeholder refusal
            ("provider-already-enrolled", {"other": {**holder, "sessionEndedGeneration": 1}}, False),
            ("provider-already-enrolled", {"other": holder}, True),
            ("capacity-unavailable", {}, True),
        ):
            with self.subTest(reason=reason, nodes=nodes):
                state = {"enrollmentAttempts": {key: refused(reason)}, "nodes": nodes}
                self.assertEqual(decided(state, key, anchor) is not None, kept)

    def test_a_recorded_refusal_is_never_replaced_unless_retired(self):
        anchor = {"pid": os.getpid(), "start": CONTROLLER_API["process_start"](os.getpid())}
        key = f"{uuid.uuid4()}:{anchor['pid']}:{anchor['start']}"
        record = CONTROLLER_API["record_refusal"]
        reason = lambda: self.h.state()["enrollmentAttempts"][key]["reason"]
        record(self.h.root, key, anchor, "capacity-unavailable")
        record(self.h.root, key, anchor, "surface-owned")
        self.assertEqual(reason(), "capacity-unavailable")
        self.h.change_state(lambda state: state["enrollmentAttempts"][key].update(reason="session-ended"))
        record(self.h.root, key, anchor, "surface-owned")
        self.assertEqual(reason(), "surface-owned")

    def test_a_second_live_holder_suspends_a_born_roots_authority(self):
        # Tab A enrolled as sole holder; tab B (here: this live test process, not A's child) then
        # holds the same session. Every controller operation of A refuses; nothing changes.
        foreign = os.getpid()
        then = (
            "receipt = json.loads(results[0].stdout)\n"
            "binding = json.load(open(os.path.join(receipt['routes'], receipt['peer'] + '.json')))\n"
            "identity = {k: binding[k] for k in ('nodeId', 'workspaceId', 'sessionId', 'generation', 'capability')}\n"
            "lock = os.path.join(env['HOME'], '.copilot', 'session-state', env['SESSION_ID'],"
            f" 'inuse.{foreign}.lock')\n"
            "def call(command, body):\n"
            "    done = subprocess.run([sys.executable, driver, command], input=json.dumps(body),"
            " capture_output=True, text=True, env=env, timeout=30)\n"
            "    return [done.returncode, done.stderr]\n"
            "out = {'held': call('native-custody', {'identity': identity})}\n"
            "open(lock, 'w').close()\n"
            "out['custody'] = call('native-custody', {'identity': identity})\n"
            "out['spawn'] = call('native-spawn', {'identity': {**identity, 'login': 'human-account',"
            " 'host': 'github.com'}, 'assignment': {'name': 'W', 'cwd': '/tmp', 'task': 'x'}})\n"
            "out['close'] = call('native-close', {'identity': identity, 'target': {"
            "'workerId': '00000000-0000-4000-8000-0000000000aa', 'workspaceId': identity['workspaceId'],"
            " 'surfaceId': '00000000-0000-4000-8000-0000000000ab',"
            " 'sessionId': '00000000-0000-4000-8000-0000000000ac', 'generation': 1}})\n"
            "os.unlink(lock)\n"
            "result = subprocess.CompletedProcess([], 0, json.dumps(out), '')\n")
        enrolled, calls = self.enroll(env={"FAKE_THEN": then})
        self.assertTrue(enrolled["ok"], enrolled)
        self.assertEqual(calls["held"][0], 0, calls["held"])
        before = self.h.state()
        for name in ("custody", "spawn", "close"):
            code, stderr = calls[name]
            self.assertNotEqual(code, 0, name)
            self.assertIn("custody is ambiguous", stderr, name)
        self.assertEqual(self.h.state()["nodes"], before["nodes"])

    def test_a_reload_revalidates_custody(self):
        foreign = os.getpid()
        between = ("open(os.path.join(env['HOME'], '.copilot', 'session-state', env['SESSION_ID'],"
                   f" 'inuse.{foreign}.lock'), 'w').close()\n")
        first, reload = self.enroll(repeat=2, env={"FAKE_BETWEEN": between})
        self.assertTrue(first["ok"], first)
        self.refused(reload, "session-live-or-uncertain")

    def test_a_session_running_before_install_enrolls_in_place_at_its_next_join(self):
        # The integration is newer than the provider: the session was already running, and its
        # extension joins it now (for example after an extension reload).
        self.install(age=-30)
        outcome = self.enroll()
        self.assertTrue(outcome["ok"], outcome)
        node = self.h.state()["nodes"][outcome["nodeId"]]
        self.assertEqual((node["enrollment"], node["generation"]), ("born", 1))

    def test_without_production_integration_the_session_stays_unmanaged(self):
        (self.h.root / "bin" / "messaging.json").unlink()
        before = self.h.state()
        self.refused(self.enroll(), "integration-not-installed")
        self.unchanged(before)

    def test_capacity_refusal_keeps_history_and_writes_nothing(self):
        self.h.limit_capacity(1)
        before = self.h.state()
        self.refused(self.enroll(), "capacity-unavailable")
        self.assertEqual(self.h.state()["nodes"], before["nodes"])
        self.assertEqual(self.h.state()["archives"], before["archives"])
        self.assertEqual(list(self.routes.iterdir()), [])

    def test_an_owned_surface_is_never_taken(self):
        self.refused(self.enroll(surface=self.h.surface), "surface-owned")

    def test_identity_mismatches_refuse_before_any_write(self):
        before = self.h.state()
        other = str(uuid.uuid4())
        self.refused(self.enroll(env={"CMUX_SURFACE_ID": other}), "cmux-identity-unverified")
        self.refused(self.enroll(env={"SESSION_ID": str(uuid.uuid4())}), "cmux-identity-unverified")
        self.refused(self.enroll(env={"CMUX_MAESTRO_WORKER_ID": str(uuid.uuid4())}), "cmux-identity-unverified")
        self.refused(self.enroll(env={"COPILOT_EXTENSION_PARENT_PID": "1"}), "cmux-identity-unverified")
        self.refused(self.enroll(pid=os.getpid()), "cmux-identity-unverified")
        surface = str(uuid.uuid4())
        self.refused(self.enroll(surface=surface, env={"CMUX_SURFACE_ID": surface},
                                 surfaceId=str(uuid.uuid4())), "cmux-identity-unverified")
        self.unchanged(before)

    def test_unverified_account_refuses(self):
        for login, host in (("--show-token", "github.com"), ("human", "example.com"), ("", "github.com")):
            with self.subTest(login=login, host=host):
                self.refused(self.enroll(login=login, host=host), "account-unverified")

    def test_surface_missing_from_cmux_inventory_refuses(self):
        surface = str(uuid.uuid4())
        self.h.add_surface(surface)
        data = self.h.cmux_data()
        data["inventoryUnavailable"] = True
        self.h.cmux_state.write_text(json.dumps(data))
        self.refused(self.enroll(surface=surface), "cmux-identity-unverified")

    def test_new_session_supersedes_a_proven_ended_born_run_in_its_surface(self):
        first = self.enroll()
        child_id, child_surface = self.add_child(first["nodeId"])
        archives = len(self.h.state()["archives"])
        second = self.enroll(surface=first["surface"])
        self.assertTrue(second["ok"], second)
        state = self.h.state()
        self.assertNotIn(first["nodeId"], state["nodes"])
        self.assertNotIn(child_id, state["nodes"])
        self.assertEqual(state["nodes"][second["nodeId"]]["surfaceId"], first["surface"])
        self.assertEqual(len(state["archives"]), archives + 1)
        self.assertEqual(state["archives"][-1]["coordinatorLabel"], "Copilot session")
        # The human's surface is reused, never retained; the Maestro-created child surface stays owned.
        retained = [item["surfaceId"] for item in state["retainedResources"]]
        self.assertEqual(retained, [child_surface])
        self.assertFalse((self.routes / f"{first['peer']}.json").exists())

    def test_an_ended_root_with_a_live_child_releases_its_surface_and_keeps_its_run(self):
        # `/clear` (or a new session) in a root whose child still runs: the child stays in the
        # earlier run, which no row shows any more; the new root has no authority over it.
        first = self.enroll()
        child_id, _ = self.add_child(first["nodeId"], provider=None)
        second = self.enroll(surface=first["surface"])
        self.assertTrue(second["ok"], second)
        state = self.h.state()
        old = state["nodes"][first["nodeId"]]
        self.assertEqual((old["surfaceId"], old.get("surfaceReleased")), (None, True))
        self.assertEqual(state["nodes"][child_id]["parentId"], first["nodeId"])
        new = state["nodes"][second["nodeId"]]
        self.assertEqual(new["surfaceId"], first["surface"])
        self.assertNotEqual(new["runId"], old["runId"])
        self.assertFalse((self.routes / f"{first['peer']}.json").exists())
        projected = json.loads((self.h.root / "observer" / "current.json").read_text())["nodes"]
        self.assertNotIn(old["runId"], [item["runId"] for item in projected])
        self.assertIn(second["nodeId"], [item["id"] for item in projected])
        # The released run is still archived once every node has ended.
        self.h.change_state(lambda state: state["nodes"][child_id].update(providerProcess=old["providerProcess"]))
        self.h.run("archive-ended", "--workspace", self.h.workspace)
        self.assertNotIn(child_id, self.h.state()["nodes"])

    def test_a_live_or_uncertain_root_keeps_the_surface(self):
        live = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.read()"], stdin=subprocess.PIPE)
        self.addCleanup(lambda: (live.stdin.close(), live.wait(timeout=5)))
        anchor = {"pid": live.pid, "start": None}
        while anchor["start"] is None:
            anchor["start"] = CONTROLLER_API["process_start"](live.pid)
        other = self.enroll()
        self.h.change_state(lambda state: state["nodes"][other["nodeId"]].update(providerProcess=anchor))
        before = self.h.state()
        self.refused(self.enroll(surface=other["surface"]), "surface-owned")
        self.unchanged(before)

    def test_archive_ended_archives_only_proven_ended_born_runs(self):
        ended = self.enroll()
        uncertain = self.enroll()
        self.add_child(uncertain["nodeId"], provider=None)
        result = self.h.run("archive-ended", "--workspace", self.h.workspace)
        self.assertEqual((result["archivedRuns"], result["keptRuns"]),
                         ([self.h.state()["archives"][-1]["runId"]], 1))
        state = self.h.state()
        self.assertNotIn(ended["nodeId"], state["nodes"])
        self.assertIn(uncertain["nodeId"], state["nodes"])
        self.assertIn(self.h.node, state["nodes"])
        again = self.h.run("archive-ended", "--workspace", self.h.workspace)
        self.assertEqual((again["archivedRuns"], again["keptRuns"]), ([], 1))

    def test_provider_terminal_must_be_the_claimed_surface(self):
        before = self.h.state()
        # Inherited CMUX_* values name a real surface, but the provider's TTY is another one.
        self.refused(self.enroll(env={"FAKE_SURFACE_TTY": "other"}), "cmux-identity-unverified")
        self.refused(self.enroll(env={"FAKE_SURFACE_TTY": "none"}), "cmux-identity-unverified")
        self.unchanged(before)
        self.assertEqual(list(self.routes.iterdir()), [])

    def test_a_refusal_at_start_stays_refused_on_reload(self):
        self.h.limit_capacity(1)
        token = self.h.token
        raise_limit = (f"subprocess.run([sys.executable, driver, 'capacity', '--workspace', "
                       f"'{self.h.workspace}', '--limit', '8', '--actor-id', '{self.h.node}', "
                       f"'--token', '{token}'], check=True, capture_output=True)")
        first, reload = self.enroll(repeat=2, env={"FAKE_BETWEEN": raise_limit})
        self.refused(first, "capacity-unavailable")
        self.refused(reload, "capacity-unavailable")
        self.assertFalse(any(n.get("enrollment") for n in self.h.state()["nodes"].values()))
        # A new provider for a new session is decided on its own.
        self.assertTrue(self.enroll()["ok"])

    def test_unverified_account_is_recorded_and_never_enrolls_on_reload(self):
        first, reload = self.enroll(repeat=2, login=None, host=None)
        self.refused(first, "account-unverified")
        self.refused(reload, "account-unverified")

    def test_reload_after_an_update_reuses_the_enrolled_node(self):
        touch = ("import time\n"
                 f"for name in ('adapter.mjs', 'extension.mjs'):\n"
                 f"    os.utime(os.path.join({str(self.extension)!r}, name), (time.time() + 5, time.time() + 5))")
        first, reload = self.enroll(repeat=2, env={"FAKE_BETWEEN": touch})
        self.assertTrue(first["ok"], first)
        self.assertEqual(reload, first)

    def test_retained_or_leased_surfaces_are_never_taken(self):
        first = self.enroll()
        child_id, child_surface = self.add_child(first["nodeId"])
        self.assertTrue(self.enroll(surface=first["surface"])["ok"])
        self.assertIn(child_surface, [item["surfaceId"] for item in self.h.state()["retainedResources"]])
        before = self.h.state()
        self.refused(self.enroll(surface=child_surface), "surface-owned")
        self.unchanged(before)
        leased = str(uuid.uuid4())
        holder = self.enroll()

        def lease(state):
            state["launches"][holder["nodeId"]] = {
                "workerId": holder["nodeId"], "runId": state["nodes"][holder["nodeId"]]["runId"],
                "workspaceId": self.h.workspace, "sessionId": holder["session"], "generation": 1,
                "surfaceId": leased, "state": "attaching", "createdAt": CONTROLLER_API["now"](),
                "updatedAt": CONTROLLER_API["now"](),
            }
            state["nodes"][holder["nodeId"]]["phase"] = "launching"
        self.h.change_state(lease)
        before = self.h.state()
        self.refused(self.enroll(surface=leased), "surface-owned")
        self.unchanged(before)

    def test_ended_run_with_a_lease_unresolved_surface_or_archive_is_not_proven_ended(self):
        # The root alone has ended: it releases its surface and keeps its run, unless an archive
        # of that run is in progress.
        for change in ("surfaceUnknown", "archiving", "lease"):
            with self.subTest(change=change):
                first = self.enroll()
                child_id, _ = self.add_child(first["nodeId"])

                def mark(state, change=change, child_id=child_id, first=first):
                    child = state["nodes"][child_id]
                    if change == "surfaceUnknown":
                        child["surfaceUnknown"] = True
                        child["surfaceId"] = None
                        child.pop("launchAccepted", None)
                    elif change == "archiving":
                        child["archiving"] = True
                    else:
                        child["phase"] = "launching"
                        state["launches"][child_id] = {
                            "workerId": child_id, "runId": child["runId"], "workspaceId": self.h.workspace,
                            "sessionId": child["copilotSessionId"], "generation": 1, "surfaceId": None,
                            "state": "creating", "createdAt": CONTROLLER_API["now"](),
                            "updatedAt": CONTROLLER_API["now"](),
                        }
                self.h.change_state(mark)
                if change == "archiving":
                    before = self.h.state()
                    self.refused(self.enroll(surface=first["surface"]), "surface-owned")
                    self.unchanged(before)
                    continue
                outcome = self.enroll(surface=first["surface"])
                self.assertTrue(outcome["ok"], outcome)
                state = self.h.state()
                self.assertTrue(state["nodes"][first["nodeId"]].get("surfaceReleased"))
                self.assertEqual(state["nodes"][child_id]["runId"], state["nodes"][first["nodeId"]]["runId"])

    def test_register_and_launch_coordinator_name_the_born_owner(self):
        first = self.enroll()
        env = {**self.h.env, "CMUX_SURFACE_ID": first["surface"]}
        ended = self.h.run("register", "--workspace", self.h.workspace, "--surface", first["surface"],
                           "--name", "Refused", env=env, check=False)
        self.assertIn("archive-ended", ended["stderr"])
        launched = self.h.run("launch-coordinator", "--workspace", self.h.workspace, "--surface", first["surface"],
                              "--cwd", str(REPO), "--name", "Refused", "--task", "x", "--account", "a",
                              env=env, check=False)
        self.assertIn("born-managed", launched["stderr"])

    def test_stored_enrollment_origin_is_validated_at_load(self):
        outcome = self.enroll()
        path = self.h.root / "control" / "state.json"
        state = json.loads(path.read_text())
        state["nodes"][outcome["nodeId"]]["enrollment"] = "adopted"
        path.write_text(json.dumps(state))
        with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "enrollment origin"):
            CONTROLLER_API["read_state"](self.h.root)

    def test_born_root_passes_the_native_close_actor_gate(self):
        first_then = (
            "binding = json.load(open(os.path.join(json.loads(results[0].stdout)['routes'], "
            "json.loads(results[0].stdout)['peer'] + '.json')))\n"
            "identity = {k: binding[k] for k in ('nodeId', 'workspaceId', 'sessionId', 'generation', 'capability')}\n"
            "target = {'workerId': '00000000-0000-4000-8000-0000000000aa', 'workspaceId': identity['workspaceId'],"
            " 'surfaceId': '00000000-0000-4000-8000-0000000000ab', 'sessionId': '00000000-0000-4000-8000-0000000000ac',"
            " 'generation': 1}\n"
            "result = subprocess.run([sys.executable, driver, 'native-close'], capture_output=True, text=True,"
            " input=json.dumps({'identity': identity, 'target': target}), env=env, timeout=30)\n")
        enrolled, closed = self.enroll(env={"FAKE_THEN": first_then})
        self.assertTrue(enrolled["ok"], enrolled)
        self.assertFalse(closed["ok"])
        self.assertNotIn("does not match the invoking native session", closed["error"])
        self.assertIn("not registered", closed["error"])  # past the actor gate, at target lookup

    def dead_pid(self):
        return int(subprocess.run([sys.executable, "-c", "import os; print(os.getpid())"],
                                  capture_output=True, text=True, check=True).stdout)

    def test_archive_ended_whose_projection_fails_still_reports_and_cleans_up(self):
        first = self.enroll()
        result = self.h.run("archive-ended", "--workspace", self.h.workspace,
                            env={**self.h.env, "FAKE_FAIL_PROJECTION_AT": "1"})
        self.assertEqual((len(result["archivedRuns"]), result.get("projection")), (1, "deferred"))
        self.assertNotIn(first["nodeId"], self.h.state()["nodes"])

    def test_generation_marks_at_the_cap_evict_into_a_floor(self):
        first = self.enroll()
        cap = CONTROLLER_API["MAX_HOST_NODES"]
        oldest = str(uuid.uuid4())
        marks = {oldest: 7, **{str(uuid.uuid4()): 9 for _ in range(cap - 1)}}
        self.h.change_state(lambda state: state.update(bornGenerations=marks))
        result = self.h.run("archive-ended", "--workspace", self.h.workspace)
        self.assertEqual((len(result["archivedRuns"]), result["keptRuns"]), (1, 0))
        state = self.h.state()
        self.assertEqual(len(state["bornGenerations"]), cap)
        self.assertNotIn(oldest, state["bornGenerations"])
        self.assertEqual(state["bornGenerationFloor"], 7)
        self.assertEqual(state["bornGenerations"][first["session"]], 1)
        # A session whose mark was evicted starts above the floor; its address cannot repeat.
        again = self.enroll(session=oldest)
        self.assertTrue(again["ok"], again)
        self.assertEqual(again["generation"], 8)

    def test_generation_is_decided_inside_the_lock_after_a_superseding_archive(self):
        first = self.enroll()
        cap = CONTROLLER_API["MAX_HOST_NODES"]
        self.h.change_state(lambda state: state.update(bornGenerations={str(uuid.uuid4()): 9 for _ in range(cap)}))
        second = self.enroll(surface=first["surface"])
        self.assertTrue(second["ok"], second)
        # Archiving the superseded run evicted a mark into the floor, so the new root starts above it.
        self.assertEqual(second["generation"], 10)
        self.assertEqual(self.h.state()["nodes"][second["nodeId"]]["generation"], 10)
        stale = CONTROLLER_API["message_peer"]({"copilotSessionId": second["session"], "generation": 1})
        self.assertFalse((self.routes / f"{stale}.json").exists())
        self.assertTrue((self.routes / f"{second['peer']}.json").exists())

    def test_attempt_records_of_ended_providers_are_all_swept(self):
        dead = self.dead_pid()
        attempts = {f"{uuid.uuid4()}:{dead}:Thu Jan  1 00:00:00 2026": {
            "outcome": "refused", "reason": "capacity-unavailable", "at": "2026-01-01T00:00:00Z"}
            for _ in range(CONTROLLER_API["MAX_HOST_NODES"] - 1)}
        live = f"{uuid.uuid4()}:{os.getpid()}:{CONTROLLER_API['process_start'](os.getpid())}"
        attempts[live] = {"outcome": "refused", "reason": "surface-owned", "at": "2025-01-01T00:00:00Z"}
        self.h.change_state(lambda state: state.update(enrollmentAttempts=attempts))
        self.assertTrue(self.enroll()["ok"])
        remaining = self.h.state()["enrollmentAttempts"]
        self.assertIn(live, remaining)
        self.assertEqual(len(remaining), 2)

    def test_archived_session_enrolls_again_with_a_later_generation(self):
        first = self.enroll()
        self.h.run("archive-ended", "--workspace", self.h.workspace)
        # The high-water mark survives archive-summary trimming.
        self.h.change_state(lambda state: state.update(archives=[]))
        self.assertEqual(self.h.state()["bornGenerations"], {first["session"]: 1})
        again = self.enroll(session=first["session"])
        self.assertTrue(again["ok"], again)
        self.assertEqual(again["generation"], 2)
        self.assertNotEqual(again["peer"], first["peer"])

    def test_born_root_spawns_children_with_its_own_account_and_no_grants(self):
        h = self.h
        outcome = self.enroll()
        binding = json.loads((self.routes / f"{outcome['peer']}.json").read_text())
        identity = {key: binding[key] for key in ("nodeId", "workspaceId", "sessionId", "generation", "capability")}
        node = h.state()["nodes"][outcome["nodeId"]]
        spawn_identity = {**identity, "login": "human-account", "host": "github.com"}
        # Its provider has exited and holds the session no more: no authority.
        with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "custody is ambiguous"):
            CONTROLLER_API["authorize_native_spawn"](h.state(), spawn_identity)
        with patch.dict(CONTROLLER_API["authorize_native_spawn"].__globals__, require_born_custody=lambda actor: None):
            authorized = CONTROLLER_API["authorize_native_spawn"](h.state(), spawn_identity)
        self.assertEqual(authorized["id"], node["id"])
        self.assertEqual(CONTROLLER_API["recorded_native_permissions"](node),
                         ("default", {"allow": [], "deny": []}))


class BornRootResumeTests(BornFixture, unittest.TestCase):
    """A born root's ended session restarted in its own surface resumes (ADR 0024)."""

    def first(self):
        outcome = self.enroll()
        self.assertTrue(outcome["ok"], outcome)
        return outcome

    def resume(self, first, **options):
        env = {"FAKE_HOLD_SESSION_LOCK": "1", **options.pop("env", {})}
        return self.enroll(surface=first["surface"], session=first["session"], env=env, **options)

    def session_state(self, session):
        path = self.h.home / ".copilot" / "session-state" / session
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        return path

    def test_restarted_session_resumes_same_node_as_next_generation(self):
        first = self.first()
        before = self.h.state()["nodes"][first["nodeId"]]
        resumed = self.resume(first)
        self.assertTrue(resumed["ok"], resumed)
        self.assertEqual(resumed["nodeId"], first["nodeId"])
        self.assertEqual(resumed["generation"], 2)
        node = self.h.state()["nodes"][first["nodeId"]]
        self.assertEqual((node["runId"], node["surfaceId"], node["copilotAccount"], node["createdAt"]),
                         (before["runId"], before["surfaceId"], before["copilotAccount"], before["createdAt"]))
        self.assertEqual(node["providerProcess"]["pid"], resumed["pid"])
        self.assertEqual((node["phase"], node["generation"]), ("turn-running", 2))
        self.assertFalse((self.routes / f"{first['peer']}.json").exists())
        self.assertTrue((self.routes / f"{resumed['peer']}.json").exists())
        self.assertEqual(len([n for n in self.h.state()["nodes"].values() if n.get("enrollment")]), 1)

    def test_reenrollment_uses_new_provider_flags_not_the_previous_mode(self):
        first = self.enroll(provider_flags=["--yolo"])
        self.assertTrue(first["ok"], first)
        self.assertEqual(self.h.state()["nodes"][first["nodeId"]]["permissionMode"], "yolo")
        resumed = self.resume(first)
        self.assertTrue(resumed["ok"], resumed)
        node = self.h.state()["nodes"][resumed["nodeId"]]
        self.assertEqual((node["permissionMode"], node["permissionSource"]), ("default", "launch-flags"))
        self.assertEqual(node["generation"], 2)

    def test_live_or_uncertain_previous_process_refuses(self):
        first = self.first()
        live = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.read()"], stdin=subprocess.PIPE)
        self.addCleanup(lambda: (live.stdin.close(), live.wait(timeout=5)))
        anchor = {"pid": live.pid, "start": None}
        while anchor["start"] is None:
            anchor["start"] = CONTROLLER_API["process_start"](live.pid)
        self.h.change_state(lambda state: state["nodes"][first["nodeId"]].update(providerProcess=anchor))
        before = self.h.state()
        self.refused(self.resume(first), "session-live-or-uncertain")
        self.unchanged(before)

    def test_another_live_session_lock_refuses_and_a_stale_one_does_not(self):
        first = self.first()
        state = self.session_state(first["session"])
        (state / f"inuse.{os.getpid()}.lock").write_text("")
        self.refused(self.resume(first), "session-live-or-uncertain")
        first = self.first()
        state = self.session_state(first["session"])
        # A crashed provider leaves its marker behind; its process is gone, so it holds nothing.
        (state / f"inuse.{self.dead_pid()}.lock").write_text("")
        resumed = self.resume(first)
        self.assertTrue(resumed["ok"], resumed)

    def session_end_then(self, capability=None):
        return (
            "receipt = json.loads(results[0].stdout)\n"
            "binding = json.load(open(os.path.join(receipt['routes'], receipt['peer'] + '.json')))\n"
            "identity = {k: binding[k] for k in ('nodeId', 'workspaceId', 'sessionId', 'generation', 'capability')}\n"
            + (f"identity['capability'] = {capability!r}\n" if capability else "") +
            "result = subprocess.run([sys.executable, driver, 'native-session-end'], capture_output=True, text=True,"
            " input=json.dumps({'identity': identity}), env=env, timeout=30)\n")

    def test_session_end_records_the_generation_for_its_own_live_session_only(self):
        enrolled, forged = self.enroll(env={"FAKE_THEN": self.session_end_then("0" * 64)})
        self.assertFalse(forged["ok"])
        self.assertNotIn("sessionEndedGeneration", self.h.state()["nodes"][enrolled["nodeId"]])
        enrolled, ended = self.enroll(env={"FAKE_THEN": self.session_end_then()})
        self.assertTrue(ended["ok"], ended)
        self.assertEqual(self.h.state()["nodes"][enrolled["nodeId"]]["sessionEndedGeneration"], 1)
        # CMUX's own restore owns a born root's tab; Maestro never clears that surface's record.
        self.assertFalse(any(call[:3] == ["surface", "resume", "clear"] for call in self.h.cmux_data()["calls"]))

    def test_a_resume_startup_placeholder_is_never_enrolled(self):
        # Copilot `--resume=<id>` first joins extensions to a placeholder session it never persists,
        # then replaces it with the resumed session in the same provider. The placeholder must not
        # take the surface, archive the resumed session's run, or claim the provider.
        first = self.first()
        child_id, _ = self.add_child(first["nodeId"])
        archives = len(self.h.state()["archives"])
        placeholder = str(uuid.uuid4())
        early, resumed = self.enroll(surface=first["surface"], sessions=[placeholder, first["session"]],
                                     env={"FAKE_UNPERSISTED": json.dumps([placeholder])})
        self.refused(early, "session-not-persisted")
        self.assertTrue(resumed["ok"], resumed)
        self.assertEqual((resumed["nodeId"], resumed["generation"]), (first["nodeId"], 2))
        state = self.h.state()
        self.assertEqual(state["nodes"][child_id]["parentId"], first["nodeId"])
        self.assertEqual(len(state["archives"]), archives)
        self.assertFalse(any(key.startswith(placeholder) for key in state["enrollmentAttempts"]))

    def test_a_resume_before_its_first_prompt_waits(self):
        first = self.first()
        self.refused(self.resume(first, env={"FAKE_HOLD_SESSION_LOCK": "none"}), "awaiting-first-prompt")
        self.assertEqual(self.h.state()["nodes"][first["nodeId"]]["generation"], 1)

    def test_a_human_resume_after_exit_reenrolls_as_the_next_generation(self):
        first = self.first()
        self.h.change_state(lambda state: state["nodes"][first["nodeId"]].update(sessionEndedGeneration=1))
        resumed = self.resume(first)
        self.assertTrue(resumed["ok"], resumed)
        self.assertEqual((resumed["nodeId"], resumed["generation"]), (first["nodeId"], 2))
        self.assertNotEqual(resumed["peer"], first["peer"])

    def refused_leaving_routes(self, first, reason, change=None, **options):
        if change:
            self.h.change_state(change)
        before, routes = self.h.state(), sorted(self.routes.iterdir())
        self.refused(self.resume(first, **options), reason)
        self.unchanged(before)
        self.assertEqual(sorted(self.routes.iterdir()), routes)

    def lease(self, first, phase="launching"):
        def change(state):
            node = state["nodes"][first["nodeId"]]
            node["phase"] = phase
            state["launches"][node["id"]] = {
                "workerId": node["id"], "runId": node["runId"], "workspaceId": self.h.workspace,
                "sessionId": first["session"], "generation": 1, "surfaceId": first["surface"],
                "state": "attaching", "createdAt": CONTROLLER_API["now"](), "updatedAt": CONTROLLER_API["now"]()}
        return change

    def test_a_launching_leased_or_unresolved_record_refuses_as_uncertain(self):
        for name, change in (
            ("launching", lambda first: lambda state: state["nodes"][first["nodeId"]].update(phase="launching")),
            ("lease", self.lease),
            ("surface-unknown", lambda first: lambda state: state["nodes"][first["nodeId"]].update(
                surfaceUnknown=True, surfaceId=None)),
        ):
            with self.subTest(name=name):
                first = self.first()
                self.refused_leaving_routes(first, "session-live-or-uncertain", change(first))

    def raced(self, first, race, reason):
        """The change lands after the snapshot checks pass and before the commit lock."""
        node, routes = self.h.state()["nodes"][first["nodeId"]], sorted(self.routes.iterdir())
        self.refused(self.resume(first, env={"FAKE_RESUME_RACE": race}), reason)
        # The refused commit changed nothing and retired the next generation's route.
        self.assertEqual(sorted(self.routes.iterdir()), routes)
        return node, self.h.state()["nodes"][first["nodeId"]]

    def test_identity_changed_before_the_commit_lock_refuses(self):
        first = self.first()
        ended = {"pid": self.dead_pid(), "start": "Thu Jan  1 00:00:00 2026"}
        before, after = self.raced(first, f"state['nodes'][{first['nodeId']!r}]['providerProcess'] = {ended!r}",
                                   "session-live-or-uncertain")
        self.assertEqual(after, {**before, "providerProcess": ended})

    def test_eligibility_lost_before_the_commit_lock_refuses_with_its_reason(self):
        # Another record claims the resuming provider after the snapshot checks passed.
        first = self.first()
        other = str(uuid.uuid4())
        before, after = self.raced(first, (
            f"node = state['nodes'][{first['nodeId']!r}]\n"
            "other = json.loads(json.dumps(node))\n"
            f"other.update(id={other!r}, runId={str(uuid.uuid4())!r}, copilotSessionId={str(uuid.uuid4())!r},"
            f" surfaceId={str(uuid.uuid4())!r})\n"
            "other['providerProcess'] = {'pid': os.getppid(), 'start': api['process_start'](os.getppid())}\n"
            "state['nodes'][other['id']] = other\n"), "provider-already-enrolled")
        self.assertEqual(after, before)
        self.assertIn(other, self.h.state()["nodes"])

    def dead_pid(self):
        return int(subprocess.run([sys.executable, "-c", "import os; print(os.getpid())"],
                                  capture_output=True, text=True, check=True).stdout)

    def test_session_lock_owned_by_the_providers_direct_child_is_accepted(self):
        first = self.first()
        resumed = self.resume(first, env={"FAKE_HOLD_SESSION_LOCK": "child"})
        self.assertTrue(resumed["ok"], resumed)
        self.assertEqual(resumed["generation"], 2)

    def test_session_lock_owned_by_a_grandchild_or_unrelated_process_refuses(self):
        for holder in ("grandchild", "unrelated"):
            with self.subTest(holder=holder):
                first = self.first()
                self.refused_leaving_routes(first, "session-live-or-uncertain", env={"FAKE_HOLD_SESSION_LOCK": holder})

    def test_a_provider_started_before_install_resumes_at_its_next_join(self):
        first = self.first()
        self.install(age=-30)  # the integration is newer than the resumed provider
        resumed = self.resume(first)
        self.assertTrue(resumed["ok"], resumed)
        self.assertEqual(resumed["generation"], 2)

    def orphan(self, first):
        node = self.h.state()["nodes"][first["nodeId"]]
        orphan = {**node, "generation": node["generation"] + 1}
        CONTROLLER_API["bind_messaging"](orphan)
        return self.routes / f"{CONTROLLER_API['message_peer'](orphan)}"

    def test_a_route_left_by_a_crash_before_commit_does_not_block_resume(self):
        first = self.first()
        orphan = self.orphan(first)
        stale = json.loads(orphan.with_suffix(".json").read_text())
        resumed = self.resume(first)
        self.assertTrue(resumed["ok"], resumed)
        self.assertEqual(resumed["generation"], 2)
        binding = json.loads(orphan.with_suffix(".json").read_text())
        self.assertEqual(binding["generation"], 2)
        self.assertNotEqual(binding["capability"], stale["capability"])  # rebound by this resume

    def test_a_listening_socket_on_the_next_route_is_never_removed(self):
        first = self.first()
        orphan = self.orphan(first)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(listener.close)
        listener.bind(str(orphan.with_suffix(".sock")))
        before = orphan.with_suffix(".json").read_bytes()
        self.refused(self.resume(first), "session-live-or-uncertain")
        self.assertEqual(orphan.with_suffix(".json").read_bytes(), before)

    def test_account_mismatch_names_the_login_on_every_reload(self):
        first = self.first()
        refusals = self.resume(first, login="other-account", repeat=2)
        for refusal in refusals:
            self.refused(refusal, "account-mismatch: human-account")

    def test_a_commit_that_reports_failure_after_landing_keeps_its_route(self):
        first = self.first()
        resumed, reload = self.resume(first, repeat=2, env={"FAKE_FAIL_STATE_FSYNC_AT": "2"})
        self.assertTrue(resumed["ok"], resumed)
        self.assertEqual((resumed["generation"], resumed.get("projection")), (2, "deferred"))
        self.assertTrue((self.routes / f"{resumed['peer']}.json").exists())
        self.assertTrue(reload["ok"], reload)
        self.assertEqual((reload["nodeId"], reload["generation"], reload["peer"]),
                         (resumed["nodeId"], 2, resumed["peer"]))

    def test_reviving_a_retired_root_needs_a_free_workspace_slot(self):
        first = self.first()
        self.h.change_state(lambda state: (
            state["nodes"][first["nodeId"]].update(phase="resource-retired", availability="unavailable"),
            state.setdefault("workspaceCapacity", {}).update({self.h.workspace: 1})))
        before, routes = self.h.state(), sorted(self.routes.iterdir())
        self.refused(self.resume(first), "capacity-unavailable")
        self.unchanged(before)
        self.assertEqual(sorted(self.routes.iterdir()), routes)
        self.h.change_state(lambda state: state["workspaceCapacity"].update({self.h.workspace: 2}))
        for marker in self.session_state(first["session"]).glob("inuse.*.lock"):
            marker.unlink()  # the refused provider has exited; Copilot removes its marker
        resumed = self.resume(first)
        self.assertTrue(resumed["ok"], resumed)

    def test_session_end_evidence_with_a_malformed_generation_is_a_structured_refusal(self):
        first = self.first()
        path = self.h.root / "control" / "state.json"
        original = path.read_bytes()
        self.addCleanup(path.write_bytes, original)
        for generation in ("1", None):
            state = json.loads(path.read_text())
            state["nodes"][first["nodeId"]].update(sessionEndedGeneration=1, generation=generation)
            path.write_text(json.dumps(state))
            with self.subTest(generation=generation), self.assertRaises(CONTROLLER_API["OrchestrationError"]):
                CONTROLLER_API["read_state"](self.h.root)

    def test_resume_refreshes_the_provider_launch_context(self):
        first = self.first()
        self.h.change_state(lambda state: state["nodes"][first["nodeId"]].update(
            copilotExecutable="/synthetic/old/copilot", launchPath="/synthetic/old"))
        self.assertTrue(self.resume(first)["ok"])
        node = self.h.state()["nodes"][first["nodeId"]]
        self.assertNotEqual(node["copilotExecutable"], "/synthetic/old/copilot")
        self.assertNotEqual(node["launchPath"], "/synthetic/old")

    def test_resumed_root_keeps_its_children_and_only_the_new_generation_has_authority(self):
        first = self.first()
        child_id, _ = self.add_child(first["nodeId"])
        old = json.loads((self.routes / f"{first['peer']}.json").read_text())
        resumed = self.resume(first)
        self.assertTrue(resumed["ok"], resumed)
        state = self.h.state()
        self.assertEqual(state["nodes"][child_id]["parentId"], first["nodeId"])
        identity = lambda binding: {key: binding[key] for key in
                                    ("nodeId", "workspaceId", "sessionId", "generation", "capability")}
        with self.assertRaises(CONTROLLER_API["OrchestrationError"]):
            CONTROLLER_API["authorize_native_actor"](state, identity(old))
        new = json.loads((self.routes / f"{resumed['peer']}.json").read_text())
        self.assertEqual(new["generation"], 2)
        self.assertEqual(CONTROLLER_API["authorize_native_actor"](state, identity(new))["id"], first["nodeId"])

    def test_resumed_root_spawns_and_closes_children_only_as_its_new_generation(self):
        first = self.first()
        # The retained child is live: its own provider holds its session.
        live = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.read()"], stdin=subprocess.PIPE)
        self.addCleanup(lambda: (live.stdin.close(), live.wait(timeout=5)))
        process = {"pid": live.pid, "start": None}
        while process["start"] is None:
            process["start"] = CONTROLLER_API["process_start"](live.pid)
        child_id, child_surface = self.add_child(first["nodeId"], provider=process)
        self.h.add_surface(child_surface)
        child = self.h.state()["nodes"][child_id]
        (self.session_state(child["copilotSessionId"]) / f"inuse.{live.pid}.lock").write_text("")
        fields = ("nodeId", "workspaceId", "sessionId", "generation", "capability")
        old = {key: value for key, value in
               json.loads((self.routes / f"{first['peer']}.json").read_text()).items() if key in fields}
        target = {"workerId": child_id, "workspaceId": child["workspaceId"], "surfaceId": child_surface,
                  "sessionId": child["copilotSessionId"], "generation": child["generation"]}
        assignment = {"name": "Worker", "cwd": str(REPO), "task": "Complete the bounded task.", "denyTools": []}
        then = (
            "receipt = json.loads(results[0].stdout)\n"
            "binding = json.load(open(os.path.join(receipt['routes'], receipt['peer'] + '.json')))\n"
            f"new = {{k: binding[k] for k in {fields!r}}}\n"
            "def call(command, body):\n"
            "    done = subprocess.run([sys.executable, driver, command], input=json.dumps(body),"
            " capture_output=True, text=True, env={**env, 'FAKE_SESSION_MODE': 'interactive'}, timeout=30)\n"
            "    return [done.returncode, done.stdout, done.stderr]\n"
            "out = {}\n"
            f"for name, identity in (('old', {old!r}), ('new', new)):\n"
            "    out[name] = {\n"
            "        'spawn': call('native-spawn', {'identity': {**identity, 'login': 'human-account',"
            f" 'host': 'github.com'}}, 'assignment': {assignment!r}}}),\n"
            f"        'close': call('native-close', {{'identity': identity, 'target': {target!r}}})}}\n"
            "result = subprocess.CompletedProcess([], 0, json.dumps(out), '')\n")
        resumed, calls = self.resume(first, env={"FAKE_THEN": then})
        self.assertTrue(resumed["ok"], resumed)
        for name in ("spawn", "close"):
            code, _, stderr = calls["old"][name]
            self.assertNotEqual(code, 0)
            self.assertRegex(stderr, "Native (session identity changed|capability is unavailable)")
        code, stdout, stderr = calls["new"]["spawn"]
        self.assertEqual(code, 0, stderr)
        spawned = json.loads(stdout)
        state = self.h.state()
        self.assertEqual(state["nodes"][spawned["workerId"]]["parentId"], first["nodeId"])
        code, stdout, stderr = calls["new"]["close"]
        self.assertEqual(code, 0, stderr)
        self.assertTrue(json.loads(stdout)["closeAccepted"])
        self.assertEqual(self.h.cmux_data()["closed"], [
            {"workspace_id": self.h.workspace, "surface_id": child_surface, "force": True}])

    def test_recorded_account_mismatch_refuses_and_names_the_account(self):
        first = self.first()
        before = self.h.state()
        self.refused(self.resume(first, login="other-account"), "account-mismatch: human-account")
        self.unchanged(before)

    def test_unrecorded_account_refuses(self):
        first = self.first()
        self.h.change_state(lambda state: state["nodes"][first["nodeId"]].pop("copilotAccount"))
        self.refused(self.resume(first), "account-unrecorded")

    def test_different_surface_refuses(self):
        first = self.first()
        moved = str(uuid.uuid4())
        self.refused(self.enroll(surface=moved, session=first["session"], env={"FAKE_HOLD_SESSION_LOCK": "1"}),
                     "surface-mismatch")

    def test_launched_session_is_not_resumed_through_this_path(self):
        surface = str(uuid.uuid4())
        self.refused(self.enroll(surface=surface, session=self.h.identity["sessionId"],
                                 env={"FAKE_HOLD_SESSION_LOCK": "1"}), "session-previously-managed")


RESTORED_TERMINAL = r"""
import fcntl, json, os, pty, sys, termios
# CMUX types the binding into the restored surface's login shell: the command runs as that
# terminal's process. The fake CMUX reports the surface's TTY as this one, another, or none.
mode, surface, command = sys.argv[1], sys.argv[2], sys.argv[3:]
master, slave = pty.openpty()
os.setsid()
fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
os.set_inheritable(master, True)
os.set_inheritable(slave, True)
own = os.ttyname(slave)[len("/dev/"):]
state_path = os.environ["FAKE_CMUX_STATE"]
with open(os.path.splitext(state_path)[0] + ".lock", "a+") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    data = json.load(open(state_path))
    data.setdefault("ttys", {})[surface] = {"match": own, "other": "ttys999", "none": None}[mode]
    with open(state_path + ".tmp", "w") as stream:
        json.dump(data, stream)
    os.replace(state_path + ".tmp", state_path)
os.execv(command[0], command)
"""


class ChildResumeTests(unittest.TestCase):
    """Maestro-launched sessions resume through their own surface binding (ADR 0024)."""

    def setUp(self):
        self.h = Harness(interactive=True)
        self.addCleanup(self.h.close)
        self.routes = Path(tempfile.mkdtemp(prefix="m61-", dir="/tmp")).resolve()
        self.addCleanup(shutil.rmtree, self.routes, True)
        extension = self.h.path / "installed-extension"
        extension.mkdir(mode=0o700)
        for name in ("adapter.mjs", "extension.mjs"):
            shutil.copyfile(REPO / "scripts" / "delivery-proof" / name, extension / name)
            (extension / name).chmod(0o600)
        (self.h.root / "bin").mkdir(mode=0o700, exist_ok=True)
        config = self.h.root / "bin" / "messaging.json"
        config.write_text(json.dumps({"version": 1, "routes": str(self.routes), "extension": str(extension)}))
        config.chmod(0o600)

    def ended_child(self, deny=("shell(rm)",)):
        receipt = self.h.spawn_native("Synthetic child task", "Resumable child", deny=deny)
        child = self.h.wait_node(receipt["workerId"], lambda item: item.get("providerProcess") is not None)
        os.write(self.h.terminal_master, b"exit\n")
        child = self.h.wait_node(child["id"], lambda item: item["phase"] == "process-disappeared")
        return receipt, child

    def resume(self, child, *, surface=None, session=None, env=None, terminal="match"):
        surface = surface or child["surfaceId"]
        environment = {**self.h.env, "CMUX_SURFACE_ID": surface, **(env or {})}
        wrapper = self.h.path / "restored-terminal.py"
        wrapper.write_text(RESTORED_TERMINAL)
        with open(self.h.lifetime.name, "rb") as lifetime:
            fcntl.flock(lifetime, fcntl.LOCK_SH)
            return subprocess.run(
                [sys.executable, str(wrapper), terminal, surface,
                 sys.executable, str(self.h.driver), "resume", session or child["copilotSessionId"]],
                env={**environment, "FAKE_PROCESS_LIFETIME_FD": str(lifetime.fileno())},
                pass_fds=(lifetime.fileno(),), stdin=subprocess.DEVNULL,
                capture_output=True, text=True, timeout=20,
            )

    def refused(self, completed, reason):
        self.assertEqual(completed.returncode, 2, completed.stdout + completed.stderr)
        self.assertEqual(completed.stderr, f"Maestro did not resume this session: {reason}.\n")
        self.assertNotIn("synthetic-work-token", completed.stderr + completed.stdout)

    def test_launch_disables_cmux_restore_and_binds_identifiers_only(self):
        receipt = self.h.spawn_native("Synthetic child task", "Bound child")
        self.assertEqual(receipt["resumeBinding"], "set")
        node = self.h.state()["nodes"][receipt["workerId"]]
        binding = self.h.cmux_data()["resumeBindings"][receipt["surfaceId"]]
        # The stable installed entrypoint runs itself; no resolved interpreter path is persisted.
        # One varying trailing session ID: CMUX can approve `<controller> resume` once as a prefix.
        self.assertEqual(binding[binding.index("--") + 1:], [str(self.h.driver), "resume", node["copilotSessionId"]])
        self.assertFalse(any("Cellar" in item or "/python3." in item or item == sys.executable
                             or item == os.path.realpath(sys.executable) for item in binding))
        flags = binding[:binding.index("--")]
        self.assertEqual(flags, ["--workspace", self.h.workspace, "--surface", receipt["surfaceId"],
                                 "--cwd", node["workingDirectory"], "--kind", "agent",
                                 "--checkpoint", node["copilotSessionId"]])
        self.assertNotIn("synthetic-work-token", json.dumps(binding))
        self.assertFalse(any(str(self.h.root) in item for item in binding))
        script = (self.h.root / "control" / f"direct-{node['id']}-1.sh").read_text()
        self.assertIn("export CMUX_COPILOT_HOOKS_DISABLED=1\n", script)
        os.write(self.h.terminal_master, b"exit\n")
        self.h.wait_node(node["id"], lambda item: item["phase"] == "process-disappeared")

    def session_end(self, child, *, capability=None, env=None):
        binding = json.loads((self.routes / f"{CONTROLLER_API['message_peer'](child)}.json").read_text())
        identity = {key: binding[key] for key in ("nodeId", "workspaceId", "sessionId", "generation", "capability")}
        if capability:
            identity["capability"] = capability
        # A Maestro launch carries CMUX's restore switch; Maestro's own SessionEnd path ignores it.
        environment = {**self.h.env, "CMUX_SURFACE_ID": child["surfaceId"], "CMUX_COPILOT_HOOKS_DISABLED": "1",
                       "SESSION_ID": child["copilotSessionId"], **(env or {})}
        return self.h.run("native-session-end", input=json.dumps({"identity": identity}),
                          env=environment, check=False)

    def test_session_end_clears_only_its_exact_binding(self):
        receipt = self.h.spawn_native("Synthetic child task", "Ending child")
        child = self.h.wait_node(receipt["workerId"], lambda item: item.get("providerProcess") is not None)
        other = self.h.spawn_native("Synthetic child task", "Other child")
        self.h.wait_node(other["workerId"], lambda item: item.get("providerProcess") is not None)
        refused = self.session_end(child, capability="0" * 64)
        self.assertNotEqual(refused["returncode"], 0)
        self.assertNotEqual(self.session_end(child, env={"CMUX_SURFACE_ID": other["surfaceId"]})["returncode"], 0)
        self.assertNotEqual(self.session_end(child, env={"SESSION_ID": str(uuid.uuid4())})["returncode"], 0)
        self.assertIn(child["surfaceId"], self.h.cmux_data()["resumeBindings"])
        failed = self.session_end(child, env={"FAKE_RESUME_CLEAR_FAILS": "1"})
        self.assertEqual((failed["returncode"], failed["cleared"]), (0, False))
        self.assertIn(child["surfaceId"], self.h.cmux_data()["resumeBindings"])
        cleared = self.session_end(child)
        self.assertTrue(cleared["cleared"])
        bindings = self.h.cmux_data()["resumeBindings"]
        self.assertNotIn(child["surfaceId"], bindings)
        self.assertIn(other["surfaceId"], bindings)
        for _ in range(2):
            os.write(self.h.terminal_master, b"exit\n")
        for identifier in (child["id"], other["workerId"]):
            self.h.wait_node(identifier, lambda item: item["phase"] == "process-disappeared")
        # Even if a binding survived a failed clear, a user-ended session never resumes.
        ended = self.h.state()["nodes"][child["id"]]
        self.assertEqual(ended["sessionEndedGeneration"], ended["generation"])
        self.refused(self.resume(ended), "the session was ended by its user")

    def test_ended_child_resumes_its_exact_session_with_recorded_policy(self):
        receipt, child = self.ended_child()
        old_peer = CONTROLLER_API["message_peer"](child)
        completed = self.resume(child)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        call = self.h.calls()[-1]
        self.assertEqual(call["args"][:4], ["--no-auto-update", f"--resume={child['copilotSessionId']}",
                                            "-C", child["workingDirectory"]])
        for absent in ("--name", "--session-id", "--interactive", "--allow-all"):
            self.assertNotIn(absent, call["args"])
        self.assertIn("--deny-tool", call["args"])
        self.assertEqual(call["args"][call["args"].index("--deny-tool") + 1], "shell(rm)")
        self.assertTrue(call["pinnedSubscription"])
        self.assertEqual(call["generation"], "2")
        self.assertIn("CMUX_MAESTRO_DIRECT_LAUNCH", call["maestroKeys"])
        node = self.h.state()["nodes"][child["id"]]
        self.assertEqual((node["generation"], node["runId"], node["parentId"], node["surfaceId"]),
                         (2, child["runId"], child["parentId"], child["surfaceId"]))
        self.assertNotEqual(node["tokenHash"], child["tokenHash"])
        self.assertEqual(node["toolPolicy"], child["toolPolicy"])
        # The resumed provider is the process the resume command became; its extension observed it.
        self.assertEqual(call["observed"][0], 0, call["observed"][1])
        self.assertEqual((node["phase"], node["providerProcess"]),
                         ("turn-running", {"pid": call["pid"], "start": call["start"]}))
        self.assertFalse((self.routes / f"{old_peer}.json").exists())
        self.assertTrue((self.routes / f"{CONTROLLER_API['message_peer'](node)}.json").exists())
        self.assertNotIn("synthetic-work-token", json.dumps(self.h.state()))

    def test_live_session_refuses_and_changes_nothing(self):
        receipt = self.h.spawn_native("Synthetic child task", "Live child")
        child = self.h.wait_node(receipt["workerId"], lambda item: item.get("providerProcess") is not None)
        before = self.h.state()
        self.refused(self.resume(child), "the session may still be running")
        self.assertEqual(self.h.state(), before)
        os.write(self.h.terminal_master, b"exit\n")
        self.h.wait_node(child["id"], lambda item: item["phase"] == "process-disappeared")

    def test_live_session_lock_refuses(self):
        _, child = self.ended_child()
        state = self.h.home / ".copilot" / "session-state" / child["copilotSessionId"]
        state.mkdir(parents=True)
        (state / f"inuse.{os.getpid()}.lock").write_text("")
        self.refused(self.resume(child), "the session may still be running")

    def test_identity_mismatch_refuses(self):
        _, child = self.ended_child()
        before = self.h.state()
        other = str(uuid.uuid4())
        self.h.add_surface(other)
        self.refused(self.resume(child, surface=other), "this is not the session's recorded surface")
        self.refused(self.resume(child, session=str(uuid.uuid4())), "Maestro has no record of this session")
        self.refused(self.resume(child, env={"CMUX_MAESTRO_WORKER_ID": child["id"]}),
                     "this terminal already carries Maestro launcher inputs")
        self.assertEqual(self.h.state(), before)

    def credential_spy(self):
        marker = self.h.path / "credential-read"
        self.h.gh.write_text(f"#!/bin/sh\ntouch {marker}\nprintf '%s\\n' synthetic-work-token\n")
        marker.unlink(missing_ok=True)
        return marker

    def route_names(self):
        return sorted(path.name for path in self.routes.iterdir())

    def test_signed_out_recorded_account_refuses_names_it_and_resumes_after_sign_in(self):
        _, child = self.ended_child()
        self.h.gh.write_text("#!/bin/sh\nexit 1\n")
        login = CONTROLLER_API["recorded_account"](child)["login"]
        calls = len(self.h.calls())
        self.refused(self.resume(child), f"recorded account {login} is not signed in to GitHub CLI")
        # The credential is read only after the reservation: that generation is recorded as never run.
        node = self.h.state()["nodes"][child["id"]]
        self.assertEqual((node["generation"], node["phase"], node.get("runtimeNotStarted"), node["providerProcess"]),
                         (2, "launch-failed", True, None))
        self.assertEqual(self.route_names(), [])
        self.assertEqual(len(self.h.calls()), calls)
        self.h.gh.write_text("#!/bin/sh\nprintf '%s\\n' synthetic-work-token\n")
        completed = self.resume(node)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(self.h.state()["nodes"][child["id"]]["generation"], 3)

    def test_resume_runs_only_in_the_recorded_surfaces_own_terminal(self):
        _, child = self.ended_child()
        marker = self.credential_spy()
        before, routes, calls = self.h.state(), self.route_names(), len(self.h.calls())
        for terminal in ("other", "none"):
            with self.subTest(terminal=terminal):
                self.refused(self.resume(child, terminal=terminal),
                             "this terminal is not the session's recorded surface")
                self.assertEqual(self.h.state(), before)
                self.assertEqual(self.route_names(), routes)
                self.assertFalse(marker.exists())
                self.assertEqual(len(self.h.calls()), calls)
        completed = self.resume(child)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(marker.exists())

    def test_resumed_provider_observes_only_from_the_surfaces_terminal(self):
        _, child = self.ended_child()
        completed = self.resume(child, env={"FAKE_SURFACE_TTY_AFTER_EXEC": "ttys999"})
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertNotEqual(self.h.calls()[-1]["observed"][0], 0)
        self.assertIn("terminal is not the recorded surface", self.h.calls()[-1]["observed"][1])

    def test_eligibility_lost_before_the_commit_lock_refuses_without_credentials_or_exec(self):
        for name, reason in (("live-lock", "the session may still be running"),
                             ("user-ended", "the session was ended by its user")):
            with self.subTest(name=name):
                _, child = self.ended_child()
                marker = self.credential_spy()
                lock = self.h.home / ".copilot" / "session-state" / child["copilotSessionId"]
                race = (f"os.makedirs({str(lock)!r}, exist_ok=True); open(os.path.join({str(lock)!r},"
                        f" 'inuse.{os.getpid()}.lock'), 'w').close()" if name == "live-lock" else
                        f"node = state['nodes'][{child['id']!r}]; node['sessionEndedGeneration'] = node['generation']")
                routes, calls = self.route_names(), len(self.h.calls())
                self.refused(self.resume(child, env={"FAKE_RESUME_RACE": race}), reason)
                node = self.h.state()["nodes"][child["id"]]
                self.assertEqual((node["generation"], node["tokenHash"]), (child["generation"], child["tokenHash"]))
                self.assertEqual(self.route_names(), routes)  # the provisional next-generation route was retired
                self.assertFalse(marker.exists())
                self.assertEqual(len(self.h.calls()), calls)
                for item in lock.glob("inuse.*.lock"):
                    item.unlink()

    def test_a_live_owner_appearing_after_the_reservation_stops_the_exec(self):
        _, child = self.ended_child()
        lock = self.h.home / ".copilot" / "session-state" / child["copilotSessionId"]
        # The credential lookup runs between the reservation and the final pre-exec checks.
        self.h.gh.write_text(f"#!/bin/sh\nmkdir -p {lock}\ntouch {lock}/inuse.{os.getpid()}.lock\n"
                             "printf '%s\\n' synthetic-work-token\n")
        calls = len(self.h.calls())
        self.refused(self.resume(child), "the session may still be running")
        node = self.h.state()["nodes"][child["id"]]
        self.assertEqual((node["generation"], node["phase"], node["providerProcess"]), (2, "launch-failed", None))
        self.assertEqual(self.route_names(), [])
        self.assertEqual(len(self.h.calls()), calls)

    def test_copilot_that_exits_before_observing_leaves_an_ended_resumable_node(self):
        _, child = self.ended_child()
        completed = self.resume(child, env={"FAKE_NO_OBSERVATION": "1"})
        self.assertEqual(completed.returncode, 0, completed.stderr)
        call = self.h.calls()[-1]
        node = self.h.state()["nodes"][child["id"]]
        self.assertNotIn("observed", call)
        self.assertEqual(node["providerProcess"], {"pid": call["pid"], "start": call["start"]})
        self.assertFalse(CONTROLLER_API["process_observation"](node["providerProcess"]))
        # Not stuck in launching: the next relaunch decides again.
        again = self.resume(node)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(self.h.state()["nodes"][child["id"]]["generation"], 3)

    def test_upgraded_copilot_resolves_from_the_terminal_path_or_refuses_by_name(self):
        _, child = self.ended_child()
        missing = str(self.h.path / "old-version" / "copilot")
        self.h.change_state(lambda state: state["nodes"][child["id"]].update(copilotExecutable=missing))
        completed = self.resume(child)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(self.h.state()["nodes"][child["id"]]["copilotExecutable"], str(self.h.copilot.resolve()))
        self.h.change_state(lambda state: state["nodes"][child["id"]].update(copilotExecutable=missing))
        removed = self.h.path / "copilot-removed"
        self.h.copilot.rename(removed)
        self.addCleanup(lambda: removed.exists() and removed.rename(self.h.copilot))
        before = self.h.state()
        # Only the fixture's own tools on PATH: no real Copilot can be found or run.
        self.refused(self.resume(before["nodes"][child["id"]], env={"PATH": f"{self.h.bin}:/usr/bin:/bin"}),
                     "Copilot is not installed on this terminal's PATH")
        self.assertEqual(self.h.state(), before)

    def test_copilot_that_cannot_start_retires_its_route_and_stays_resumable(self):
        _, child = self.ended_child()
        original = self.h.copilot.read_text()
        self.h.copilot.write_text("#!/nonexistent/interpreter\n")
        self.refused(self.resume(child), "Copilot could not start")
        node = self.h.state()["nodes"][child["id"]]
        self.assertEqual((node["generation"], node["phase"], node.get("runtimeNotStarted")),
                         (2, "launch-failed", True))
        self.assertEqual(self.route_names(), [])
        self.h.copilot.write_text(original)
        completed = self.resume(node)
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_launch_coordinator_root_resumes_with_its_recorded_policy(self):
        source = str(uuid.uuid4())
        self.h.add_surface(source)
        launched = self.h.run("launch-coordinator", "--workspace", self.h.workspace, "--surface", source,
                              "--cwd", str(REPO), "--task", "Coordinate.", "--account", "synthetic-account",
                              "--deny-tool", "shell(rm)", env={**self.h.env, "CMUX_SURFACE_ID": source})
        root = self.h.wait_node(launched["workerId"], lambda item: item.get("providerProcess") is not None)
        self.assertEqual((root["role"], root["parentId"]), ("coordinator", None))
        self.assertIn(root["surfaceId"], self.h.cmux_data()["resumeBindings"])
        os.write(self.h.terminal_master, b"exit\n")
        root = self.h.wait_node(root["id"], lambda item: item["phase"] == "process-disappeared")
        completed = self.resume(root)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        call = self.h.calls()[-1]
        self.assertEqual(call["args"][1], f"--resume={root['copilotSessionId']}")
        self.assertNotIn("--name", call["args"])
        self.assertEqual(call["args"][call["args"].index("--deny-tool") + 1], "shell(rm)")
        self.assertEqual(self.h.state()["nodes"][root["id"]]["generation"], 2)

    def test_resumed_provider_keeps_cmux_hooks_disabled(self):
        _, child = self.ended_child()
        self.assertEqual(self.resume(child).returncode, 0)
        self.assertEqual(self.h.calls()[-1]["cmuxHooksDisabled"], "1")

    def test_unverified_recorded_policy_refuses(self):
        _, child = self.ended_child()
        self.h.change_state(lambda state: state["nodes"][child["id"]].update(permissionPolicyUnverified=True))
        before = self.h.state()
        self.refused(self.resume(child), "the recorded launch policy is unavailable")
        self.assertEqual(self.h.state(), before)

    def test_surface_cmux_no_longer_lists_refuses(self):
        _, child = self.ended_child()
        data = self.h.cmux_data()
        data["surfaces"].remove(child["surfaceId"])
        self.h.cmux_state.write_text(json.dumps(data))
        before = self.h.state()
        self.refused(self.resume(child), "CMUX did not confirm this surface")
        self.assertEqual(self.h.state(), before)

    def test_sessions_maestro_did_not_launch_are_never_resumed_here(self):
        for name, change in (
            ("not-direct", lambda node: [node.pop("launchMethod"), node.pop("launchAccepted")]),
            ("not-accepted", lambda node: node.pop("launchAccepted")),
            ("launch-error", lambda node: node.update(launchError="launch-failed")),
        ):
            with self.subTest(name=name):
                _, child = self.ended_child()
                self.h.change_state(lambda state: change(state["nodes"][child["id"]]))
                before = self.h.state()
                self.refused(self.resume(child), "this session was not launched by Maestro as a managed session")
                self.assertEqual(self.h.state(), before)

    def test_changed_integration_refuses(self):
        _, child = self.ended_child()
        config = self.h.root / "bin" / "messaging.json"
        other = Path(tempfile.mkdtemp(prefix="m61-", dir="/tmp")).resolve()
        self.addCleanup(shutil.rmtree, other, True)
        config.write_text(json.dumps({**json.loads(config.read_text()), "routes": str(other)}))
        before = self.h.state()
        self.refused(self.resume(child), "Maestro integration changed since launch; start a new session")
        self.assertEqual(self.h.state(), before)

    def test_record_changed_before_the_commit_lock_refuses(self):
        _, child = self.ended_child()
        routes = self.route_names()
        race = f"state['nodes'][{child['id']!r}]['tokenHash'] = '0' * 64"
        self.refused(self.resume(child, env={"FAKE_RESUME_RACE": race}), "the session's record changed")
        node = self.h.state()["nodes"][child["id"]]
        self.assertEqual((node["generation"], node["tokenHash"]), (child["generation"], "0" * 64))
        self.assertEqual(self.route_names(), routes)

    def test_resume_retires_the_previous_generations_route(self):
        _, child = self.ended_child()
        old = self.routes / f"{CONTROLLER_API['message_peer'](child)}.json"
        CONTROLLER_API["bind_messaging"](child)
        self.assertTrue(old.exists())
        self.assertEqual(self.resume(child).returncode, 0)
        self.assertFalse(old.exists())
        node = self.h.state()["nodes"][child["id"]]
        self.assertTrue((self.routes / f"{CONTROLLER_API['message_peer'](node)}.json").exists())

    def test_a_reused_pid_on_a_stale_lock_is_not_a_live_owner(self):
        session = str(uuid.uuid4())
        state = self.h.home / ".copilot" / "session-state" / session
        state.mkdir(parents=True)
        placeholder = state / "placeholder"
        placeholder.write_text("")
        time.sleep(2.1)  # the marker predates the process that now has its PID
        live = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.read()"], stdin=subprocess.PIPE)
        self.addCleanup(lambda: (live.stdin.close(), live.wait(timeout=5)))
        marker = state / f"inuse.{live.pid}.lock"
        placeholder.rename(marker)  # rename keeps the marker's birth time
        with patch.dict(os.environ, {"HOME": str(self.h.home)}):
            self.assertFalse(CONTROLLER_API["session_has_live_owner"](session))
            marker.unlink()
            marker.write_text("")
            self.assertTrue(CONTROLLER_API["session_has_live_owner"](session))
            marker.chmod(0o666)
            self.assertTrue(CONTROLLER_API["session_has_live_owner"](session))  # unowned shape: uncertain

    def test_a_resume_that_lands_but_reports_failure_still_starts_copilot(self):
        for env in ({"FAKE_FAIL_STATE_FSYNC_AT": "1"}, {"FAKE_FAIL_PROJECTION_AT": "1"}):
            with self.subTest(env=env):
                _, child = self.ended_child()
                old = self.routes / f"{CONTROLLER_API['message_peer'](child)}.json"
                CONTROLLER_API["bind_messaging"](child)  # the previous generation's route
                calls = len(self.h.calls())
                completed = self.resume(child, env=env)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(len(self.h.calls()), calls + 1)
                node = self.h.state()["nodes"][child["id"]]
                self.assertEqual((node["generation"], node["phase"]), (2, "turn-running"))
                self.assertTrue((self.routes / f"{CONTROLLER_API['message_peer'](node)}.json").exists())
                self.assertFalse(old.exists())

    def test_resume_removes_the_earlier_generation_launch_script(self):
        _, child = self.ended_child()
        script = self.h.root / "control" / f"direct-{child['id']}-1.sh"
        self.assertTrue(script.exists())
        self.assertEqual(self.resume(child).returncode, 0)
        self.assertFalse(script.exists())

    def test_a_route_left_by_a_killed_resume_does_not_block_the_next(self):
        _, child = self.ended_child()
        orphan = {**child, "generation": child["generation"] + 1}
        CONTROLLER_API["bind_messaging"](orphan)
        completed = self.resume(child)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(self.h.state()["nodes"][child["id"]]["generation"], 2)

    def test_an_exit_recorded_before_the_binding_lands_clears_it(self):
        race = ("for node in state['nodes'].values():\n"
                "    if node.get('launchMethod') == 'direct' and node.get('role') == 'worker':\n"
                "        node['sessionEndedGeneration'] = node['generation']\n")
        receipt = self.h.spawn_native("Synthetic child task", "Fast exit", env={**self.h.env, "FAKE_AFTER_RESUME_SET": race})
        self.assertEqual(receipt["resumeBinding"], "unavailable")
        self.assertNotIn(receipt["surfaceId"], self.h.cmux_data().get("resumeBindings", {}))
        os.write(self.h.terminal_master, b"exit\n")
        self.h.wait_node(receipt["workerId"], lambda item: item["phase"] == "process-disappeared")

    def test_a_resumed_launch_root_keeps_its_receipt_token_for_archive(self):
        source = str(uuid.uuid4())
        self.h.add_surface(source)
        launched = self.h.run("launch-coordinator", "--workspace", self.h.workspace, "--surface", source,
                              "--cwd", str(REPO), "--task", "Coordinate.", "--account", "synthetic-account",
                              env={**self.h.env, "CMUX_SURFACE_ID": source})
        root = self.h.wait_node(launched["coordinatorId"], lambda item: item.get("providerProcess") is not None)
        os.write(self.h.terminal_master, b"exit\n")
        root = self.h.wait_node(root["id"], lambda item: item["phase"] == "process-disappeared")
        self.assertEqual(self.resume(root).returncode, 0)
        resumed = self.h.state()["nodes"][root["id"]]
        self.assertNotEqual(resumed["tokenHash"], root["tokenHash"])
        self.assertEqual(resumed["ownerTokenHash"], root["tokenHash"])
        self.assertFalse(CONTROLLER_API["process_observation"](resumed["providerProcess"]))
        archived = self.h.run("archive", "--actor-id", root["id"], "--token", launched["controlToken"])
        self.assertTrue(archived["archived"])
        # Archive clears the launch's binding and keeps its surface owned; no token reached CMUX.
        data = self.h.cmux_data()
        self.assertNotIn(root["surfaceId"], data.get("resumeBindings", {}))
        self.assertIn(["surface", "resume", "clear", "--workspace", self.h.workspace, "--surface", root["surfaceId"]],
                      data["calls"])
        self.assertTrue(any(item["surfaceId"] == root["surfaceId"] for item in self.h.state()["retainedResources"]))
        self.assertNotIn(launched["controlToken"], json.dumps(data["calls"]))

    def test_only_messaging_launches_get_or_honor_a_binding(self):
        eligible = CONTROLLER_API["resume_binding_eligible"]
        base = {"launchMethod": "direct", "messaging": {"version": 1, "routes": "/r", "extension": "/e"}}
        self.assertTrue(eligible(base))
        for change in ({"messaging": None}, {"deliveryProof": {"fixture": "x"}}, {"enrollment": "born"},
                       {"launchMethod": None}):
            self.assertFalse(eligible({**base, **change}), change)

    def test_session_end_whose_projection_fails_still_clears_the_binding(self):
        receipt = self.h.spawn_native("Synthetic child task", "Projection lag")
        child = self.h.wait_node(receipt["workerId"], lambda item: item.get("providerProcess") is not None)
        result = self.session_end(child, env={"FAKE_FAIL_PROJECTION_AT": "1"})
        self.assertEqual((result["returncode"], result.get("projection"), result["cleared"]), (0, "deferred", True))
        self.assertNotIn(child["surfaceId"], self.h.cmux_data()["resumeBindings"])
        node = self.h.state()["nodes"][child["id"]]
        self.assertEqual(node["sessionEndedGeneration"], node["generation"])
        os.write(self.h.terminal_master, b"exit\n")
        self.h.wait_node(child["id"], lambda item: item["phase"] == "process-disappeared")

    def test_copilot_removed_during_the_credential_lookup_is_abandoned_cleanly(self):
        _, child = self.ended_child()
        removed = self.h.path / "copilot-removed"
        self.h.gh.write_text(f"#!/bin/sh\nmv {self.h.copilot} {removed}\nprintf '%s\\n' synthetic-work-token\n")
        self.addCleanup(lambda: removed.exists() and removed.rename(self.h.copilot))
        self.refused(self.resume(child, env={"PATH": f"{self.h.bin}:/usr/bin:/bin"}), "Copilot could not start")
        node = self.h.state()["nodes"][child["id"]]
        self.assertEqual((node["generation"], node.get("runtimeNotStarted"), node["providerProcess"]), (2, True, None))
        self.assertEqual(self.route_names(), [])

    def test_reviving_a_retired_launch_needs_a_free_workspace_slot(self):
        _, child = self.ended_child()
        self.h.change_state(lambda state: state["nodes"][child["id"]].update(
            phase="resource-retired", availability="unavailable"))
        used = CONTROLLER_API["workspace_capacity"](self.h.state(), self.h.workspace)["used"]
        self.h.change_state(lambda state: state.setdefault("workspaceCapacity", {}).update({self.h.workspace: used}))
        before, routes = self.h.state(), self.route_names()
        self.refused(self.resume(child), "no free workspace slot")
        self.assertEqual(self.h.state(), before)
        self.assertEqual(self.route_names(), routes)
        self.h.change_state(lambda state: state["workspaceCapacity"].update({self.h.workspace: used + 1}))
        completed = self.resume(child)
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_route_publication_and_reservation_are_one_locked_step(self):
        _, child = self.ended_child()
        marker = str(self.h.path / "after-bind")
        wrapper = self.h.path / "restored-terminal.py"
        wrapper.write_text(RESTORED_TERMINAL)
        with open(self.h.lifetime.name, "rb") as lifetime:
            fcntl.flock(lifetime, fcntl.LOCK_SH)
            running = subprocess.Popen(
                [sys.executable, str(wrapper), "match", child["surfaceId"],
                 sys.executable, str(self.h.driver), "resume", child["copilotSessionId"]],
                env={**self.h.env, "CMUX_SURFACE_ID": child["surfaceId"], "FAKE_PAUSE_AFTER_BIND": marker,
                     "FAKE_PROCESS_LIFETIME_FD": str(lifetime.fileno())},
                pass_fds=(lifetime.fileno(),), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 10
            while not Path(marker + ".ready").exists():
                self.assertLess(time.monotonic(), deadline, "resume never published its route")
                time.sleep(0.01)
            # The route exists, and the state lock is still held: no other resume can act on it.
            with self.assertRaises(CONTROLLER_API["OrchestrationError"]):
                CONTROLLER_API["mutate"](self.h.root, lambda state: None, wait=0)
        finally:
            Path(marker + ".release").write_text("go")
            stdout, stderr = running.communicate(timeout=20)
        self.assertEqual(running.returncode, 0, stderr)
        node = self.h.state()["nodes"][child["id"]]
        self.assertEqual(node["generation"], 2)
        self.assertTrue((self.routes / f"{CONTROLLER_API['message_peer'](node)}.json").exists())

    def launched_root(self):
        source = str(uuid.uuid4())
        self.h.add_surface(source)
        launched = self.h.run("launch-coordinator", "--workspace", self.h.workspace, "--surface", source,
                              "--cwd", str(REPO), "--task", "Coordinate.", "--account", "synthetic-account",
                              env={**self.h.env, "CMUX_SURFACE_ID": source})
        root = self.h.wait_node(launched["coordinatorId"], lambda item: item.get("providerProcess") is not None)
        os.write(self.h.terminal_master, b"exit\n")
        return launched, self.h.wait_node(root["id"], lambda item: item["phase"] == "process-disappeared")

    def test_the_receipt_token_is_owner_authority_only(self):
        launched, root = self.launched_root()
        self.assertEqual(self.resume(root).returncode, 0)
        marker = self.credential_spy()
        resumed = self.h.state()["nodes"][root["id"]]
        refused = self.h.run("launch-credential", check=False, env={
            **self.h.env, "CMUX_MAESTRO_WORKER_ID": root["id"], "CMUX_MAESTRO_CONTROL_TOKEN": launched["controlToken"],
            "CMUX_MAESTRO_SESSION_ID": root["copilotSessionId"], "CMUX_MAESTRO_GENERATION": str(resumed["generation"])})
        self.assertNotEqual(refused["returncode"], 0)
        self.assertFalse(marker.exists())
        status = self.h.run("status", "--actor-id", root["id"], "--token", launched["controlToken"])
        self.assertEqual(status.get("returncode", 0), 0)
        # The installed skill pairs status with focus under the same token.
        focused = self.h.run("focus", "--actor-id", root["id"], "--token", launched["controlToken"],
                             "--worker-id", root["id"])
        self.assertEqual((focused["workerId"], focused["focused"]), (root["id"], True))

    def test_archive_whose_projection_fails_still_clears_bindings_and_scripts(self):
        launched, root = self.launched_root()
        self.assertEqual(self.resume(root).returncode, 0)
        script = self.h.root / "control" / f"direct-{root['id']}-2.sh"
        script.write_text("")  # a current-generation launch script
        archived = self.h.run("archive", "--actor-id", root["id"], "--token", launched["controlToken"],
                              env={**self.h.env, "FAKE_FAIL_PROJECTION_AT": "2"})
        self.assertEqual((archived["archived"], archived.get("projection")), (True, "deferred"))
        self.assertNotIn(root["id"], self.h.state()["nodes"])
        self.assertIn(["surface", "resume", "clear", "--workspace", self.h.workspace, "--surface", root["surfaceId"]],
                      self.h.cmux_data()["calls"])
        self.assertFalse(script.exists())

    def test_unrecorded_account_refuses(self):
        _, child = self.ended_child()
        self.h.change_state(lambda state: state["nodes"][child["id"]]["launchSettings"].pop("copilotAccount"))
        self.refused(self.resume(child), "the session has no recorded account")


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
            h.identity["login"] = "work-user"
            gh = h.gh
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
            rejected = h.spawn_native("No fallback", "Must not launch", check=False)
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
        (self.h.root / "worker-settings.json").unlink()
        rejected = self.h.spawn_native("Require the dedicated account.", "Must not launch", check=False)
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
            h.gh.write_text(
                "#!/usr/bin/env python3\nimport sys\n"
                "assert sys.argv[sys.argv.index('--user')+1]=='root-account'\n"
                "print('synthetic-work-token')\n"
            )
            # A new root starts from a plain shell, not from the harness's managed session.
            caller = str(uuid.uuid4())
            h.add_surface(caller)
            h.env["CMUX_SURFACE_ID"] = caller
            result = h.run(
                "launch-coordinator", "--workspace", h.workspace, "--surface", caller,
                "--cwd", str(REPO), "--name", "Managed coordinator", "--task", "Synthetic root",
                "--account", "root-account", "--deny-tool", "web",
            )
            node = h.wait_node(result["coordinatorId"], lambda item: item.get("providerProcess") is not None)
            self.assertEqual(node["role"], "coordinator")
            self.assertIsNone(node["parentId"])
            self.assertNotEqual(node["runId"], h.registration["runId"])
            self.assertEqual(node["launchSettings"]["copilotAccount"], "root-account")
            self.assertEqual(CONTROLLER_API["recorded_account"](node), {"login": "root-account", "host": "github.com"})
            self.assertNotIn("copilotAccount", node)
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
            missing = str(h.copilot)
            h.env["FAKE_RUNTIME_COPILOT_MISSING"] = missing
            h.spawn_native(task="Synthetic failure before provider creation", label="Startup diagnostic", check=False)
            identifier = next(
                node["id"] for node in h.state()["nodes"].values() if node["role"] == "worker"
            )
            node = h.wait_node(identifier, lambda item: item["phase"] == "turn-failed")
            self.assertIn("Required executable is unavailable", node["result"])
            self.assertIn(missing, node["result"])
            self.assertIsNone(node.get("providerProcess"))
            self.assertNotIn(missing, (h.root / "observer/current.json").read_text())
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
            h.allow_coordinator_tools("read")
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
            self.assertEqual(call["args"][call["args"].index("--model") + 1], "synthetic-model")
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
            h.close_coordinator()
            archived = h.run("archive", "--actor-id", h.node, "--token", h.token)
            self.assertTrue(archived["archived"])
            self.assertEqual(h.state()["nodes"], {})
            self.assertEqual(list((h.root / "control").glob("direct-*.sh")), [])
            self.assertEqual({item["surfaceId"] for item in h.state()["retainedResources"]},
                             {worker["surfaceId"], h.surface})
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
        env["HOME"] = str(unused)
        env.pop("CMUX_WORKSPACE_ID")
        env.pop("CMUX_SURFACE_ID")
        catalog = self.h.run("icons", "--search", "nf-fa-edge", env=env)
        self.assertEqual(catalog["fontVersion"], "3.5.1")
        self.assertEqual(catalog["icons"], [{"id": "fa-edge", "char": "\uf282", "code": "f282"}])
        self.assertNotIn("orange", catalog["colors"])
        self.assertFalse(fixture_root(unused).exists())
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

    def test_unwritable_icon_projection_does_not_fail_state_mutation(self):
        icons_path = self.h.root / "observer" / "icons.json"
        icons_path.unlink()
        icons_path.mkdir()
        result = self.h.run("icon", "--actor-id", self.h.node, "--token", self.h.token,
                            "--icon", "nf-md-duck", "--color", "teal")
        self.assertEqual(result["iconId"], "md-duck")
        self.assertEqual(self.h.state()["nodes"][self.h.node]["iconId"], "md-duck")
        current = json.loads((self.h.root / "observer" / "current.json").read_text())
        self.assertTrue(any(node["id"] == self.h.node for node in current["nodes"]))

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
        worker = self.h.spawn_native("Complete the bounded task.", "Icon worker", icon="canary", color="purple")
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
            env["FAKE_GIT"] = str(fake_git)
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
        worker = self.h.spawn_native(task="first turn", label="Git worker", cwd=worktree)
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
        env["FAKE_GIT"] = str(fake_git)
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
            "FAKE_STARTUP_SECONDS": "0.05",
        })
        result = self.h.spawn_native(task="bounded", label="Delayed runtime", check=False)
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
        env = {**self.h.env, "FAKE_ATTACH_BARRIER": str(barrier),
               "FAKE_STARTUP_SECONDS": "0.05"}
        process = self.h.start_native_spawn(task="bounded", label="Delayed attachment", env=env)
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
               "FAKE_STARTUP_SECONDS": "0.05"}
        caller = self.h.start_native_spawn(task="bounded", label="Late reply", env=env)
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
        self.h.env.update(FAKE_RUNTIME_BARRIER=str(barrier), FAKE_STARTUP_SECONDS="0")
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
        failed = self.h.spawn_native(task="bounded", label="Lost reply", env=env, check=False)
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
        self.h.env.update(FAKE_RUNTIME_BARRIER=str(barrier), FAKE_STARTUP_SECONDS="0")
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
        rejected = self.h.spawn_native(task="bounded", label="No guessed reclamation", check=False)
        self.assertEqual(rejected["returncode"], 2)
        self.assertEqual(set(self.h.cmux_data()["surfaces"]), set(host["surfaces"]))
        barrier.with_suffix(".release").write_text("release")
        self.h.wait_node(receipt["workerId"], lambda node: node["phase"] == "reported-completed")

    def test_supervisor_claim_at_failed_observation_boundary_is_not_revoked(self):
        barrier = self.h.path / "runtime-barrier"
        self.h.env.update(FAKE_RUNTIME_BARRIER=str(barrier), FAKE_STARTUP_SECONDS="0")
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
            receipt = self.h.spawn_in_process(cmux, task="bounded", label="Concurrent claim")
        self.assertEqual(receipt["phase"], "reported-completed")
        self.assertEqual(receipt["workObservation"], "reported-result")
        self.assertNotIn("runtimeNotStarted", self.h.state()["nodes"][receipt["workerId"]])
        self.assertEqual(len(self.h.calls()), 1)

    def test_conflicting_surface_observation_does_not_extend_caller_budget(self):
        barrier = self.h.path / "runtime-barrier"
        self.h.env.update(FAKE_RUNTIME_BARRIER=str(barrier), FAKE_STARTUP_SECONDS="0")
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
            receipt = self.h.spawn_in_process(cmux, task="bounded", label="Changed observation")
        self.assertEqual(receipt["startup"], "pending")
        self.assertIn(receipt["workerId"], self.h.state()["launches"])
        barrier.with_suffix(".release").write_text("release")
        self.h.wait_node(receipt["workerId"], lambda node: node["phase"] == "reported-completed")
        self.assertEqual(len(self.h.calls()), 1)

    def assert_slow_status_preserves_supervision(self, status, *, expected_probes=1):
        h = Harness(interactive=True, legacy=True)
        h.env["FAKE_HEARTBEAT_SECONDS"] = "0.15"
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
            # Wait for a heartbeat published after the slow status released the
            # store: the runtime survived its failed lock attempt and resumed.
            released = h.state()["nodes"][node["id"]]["updatedAt"]
            current = h.wait_node(node["id"], lambda item: item["updatedAt"] > released)
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
                self.h.env.update(FAKE_RUNTIME_BARRIER=str(barrier), FAKE_STARTUP_SECONDS="0")
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
                        receipt = self.h.spawn_in_process(cmux, task="bounded", label="Final receipt cancellation")
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
                h.env.update(FAKE_RUNTIME_BARRIER=str(barrier), FAKE_STARTUP_SECONDS="0")
                affected = []
                try:
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
                            h.spawn_in_process(cmux, task="bounded", label="Replaced launch")
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
                self.h.env.update(FAKE_RUNTIME_BARRIER=str(barrier), FAKE_STARTUP_SECONDS="0")
                with patch.dict(os.environ, self.h.env):
                    cmux = CONTROLLER_API["Cmux"]()

                    def claimed_during_probe(workspace, surface):
                        node = next(item for item in self.h.state()["nodes"].values()
                                    if item.get("surfaceId") == surface)
                        barrier.with_suffix(".release").write_text("release")
                        self.h.wait_node(node["id"], lambda item: item["phase"] == "reported-completed")
                        return observation

                    cmux.surface_exists = claimed_during_probe
                    receipt = self.h.spawn_in_process(cmux, task="bounded", label="Claimed before final receipt")
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
                self.h.env.update(FAKE_RUNTIME_BARRIER=str(barrier), FAKE_STARTUP_SECONDS="0")
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
        self.h.env.update(FAKE_RUNTIME_LOCK=str(barrier), FAKE_STARTUP_SECONDS="0")
        # The managed coordinator holds one live resource slot.
        receipts = [self.h.spawn(label=f"Pending {index}") for index in range(MAX_LIVE_WORKERS - 1)]
        self.assertTrue(all(item["startup"] == "pending" for item in receipts))
        self.assertEqual(len(self.h.state()["launches"]), MAX_LIVE_WORKERS - 1)
        before = set(self.h.cmux_data()["surfaces"])
        rejected = self.h.spawn_native(task="bounded", label="Over capacity", check=False)
        self.assertEqual(rejected["returncode"], 2)
        self.assertIn("resource limit", rejected["stderr"])
        self.assertEqual(set(self.h.cmux_data()["surfaces"]), before)
        archived = self.h.run("archive", "--actor-id", self.h.node, "--token", self.h.token, check=False)
        self.assertEqual(archived["returncode"], 2)
        self.assertEqual(len(self.h.state()["launches"]), MAX_LIVE_WORKERS - 1)
        fcntl.flock(latch.fileno(), fcntl.LOCK_UN)
        for receipt in receipts:
            self.h.wait_node(
                receipt["workerId"], lambda node: node["phase"] == "reported-completed",
                timeout=6 * max(1, MAX_LIVE_WORKERS / 8),
            )
        self.assertEqual(len(self.h.calls()), MAX_LIVE_WORKERS - 1)

    def test_caller_exit_during_attachment_unblocks_child_without_execution(self):
        barrier = self.h.path / "attach-barrier"
        env = {**self.h.env, "FAKE_ATTACH_BARRIER": str(barrier)}
        caller = self.h.start_native_spawn(task="bounded", label="Caller disappears", env=env)
        try:
            deadline = time.monotonic() + 5
            while not barrier.with_suffix(".ready").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(barrier.with_suffix(".ready").exists())
            lease = next(iter(self.h.state()["launches"].values()))
            caller.terminate()
            self.h.finish(caller, check=False)
            # The host's late reply reaches no caller.
            barrier.with_suffix(".release").write_text("release")
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
        env["FAKE_ATTACH_BARRIER"] = str(barrier)
        process = self.h.start_native_spawn(task="bounded", label="Barrier worker", env=env)
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
        # A registered root's terminal is reusable after archive; a managed root's stays retained.
        self.h.as_legacy_registered_root()
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
        self.h.identity = self.h.seed_native_parent()
        self.h.limit_capacity(ACCOUNTING_CAPACITY)
        # The retained terminal and the new managed coordinator hold two slots.
        for index in range(ACCOUNTING_CAPACITY - 2):
            added = self.h.spawn(label=f"Capacity {index}")
            self.h.wait_node(added["workerId"], lambda node: node["availability"] == "idle")
        surfaces_before = set(self.h.cmux_data()["surfaces"])
        over_capacity = self.h.spawn_native(task="bounded", label="Over capacity", check=False)
        self.assertEqual(over_capacity["returncode"], 2)
        self.assertEqual(set(self.h.cmux_data()["surfaces"]), surfaces_before)

    def test_archive_winning_before_spawn_creates_no_surface(self):
        self.h.close_coordinator()
        self.h.run("archive", "--actor-id", self.h.node, "--token", self.h.token)
        surfaces_before = set(self.h.cmux_data()["surfaces"])
        rejected = self.h.spawn_native(task="bounded", label="Too late", check=False)
        self.assertEqual(rejected["returncode"], 2)
        self.assertEqual(set(self.h.cmux_data()["surfaces"]), surfaces_before)

    def test_failed_attachment_retains_exact_created_surface_in_capacity(self):
        self.h.limit_capacity(ACCOUNTING_CAPACITY)
        env = self.h.env.copy()
        env["FAKE_ATTACH_FAILURE"] = "1"
        failed = self.h.spawn_native(task="bounded", label="Attachment failure", check=False, env=env)
        self.assertEqual(failed["returncode"], 2)
        state = self.h.state()
        failed_node = next(
            node for node in state["nodes"].values()
            if node["role"] == "worker"
        )
        self.assertEqual(failed_node["phase"], "launch-failed")
        self.assertIn(failed_node["surfaceId"], self.h.cmux_data()["surfaces"])
        self.assertEqual(state["launches"], {})
        for index in range(ACCOUNTING_CAPACITY - 2):
            worker = self.h.spawn(label=f"Capacity {index}")
            idle = self.h.wait_node(worker["workerId"], lambda node: node["availability"] == "idle")
            self.assertTrue(CONTROLLER_API["process_matches"](idle))
            # Keep the real terminal resource, without unrelated idle-supervisor publication traffic.
            os.kill(idle["supervisor"]["pid"], signal.SIGTERM)
            self.h.wait_node(worker["workerId"], lambda node: node["phase"] == "process-disappeared")
            self.assertIn(worker["surfaceId"], self.h.cmux_data()["surfaces"])
        surfaces_before = set(self.h.cmux_data()["surfaces"])
        rejected = self.h.spawn_native(task="bounded", label="Over capacity", check=False)
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
                self.h.spawn_in_process(cmux, task="[MALFORMED]", label="Early malformed", cwd=self.h.path)

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
        heartbeat_env["FAKE_HEARTBEAT_SECONDS"] = "0.05"
        silent = self.h.spawn_native(task="[SILENT]", label="Silent", env=heartbeat_env)
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
        self.h.allow_coordinator_tools("shell", "read")
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
        broad = self.h.spawn_native(task="bounded", label="Broad", allow=["*"], check=False)
        self.assertEqual(broad["returncode"], 2)
        self.assertIn("Broad Copilot tool grants", broad["stderr"])
        self.assertEqual(set(self.h.cmux_data()["surfaces"]), surfaces)

        # A token-authenticated worker has no native parent evidence, so it cannot launch children.
        for task in ("[NESTED_SUBSET]", "[NESTED_ESCALATE]"):
            parent = self.h.spawn(task, label="Nested parent", allow=("read",), deny=("shell(exact)",))
            self.h.wait_node(parent["workerId"], lambda node: node["availability"] == "idle")
            result = json.loads(self.h.policy_results.read_text().splitlines()[-1])
            self.assertEqual(result["returncode"], 2)
            self.assertIn("require maestro_spawn", result["stderr"])
            self.assertFalse(any(node["parentId"] == parent["workerId"]
                                 for node in self.h.state()["nodes"].values()))
        parent_policy = {"allow": ["read"], "deny": ["shell(exact)"]}
        self.assertEqual(CONTROLLER_API["normalize_tool_policy"](["read"], ["network"], parent_policy),
                         {"allow": ["read"], "deny": ["shell(exact)", "network"]})
        with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "cannot grant a child additional"):
            CONTROLLER_API["normalize_tool_policy"](["write"], ["network"], parent_policy)

    def test_completed_live_resources_reject_over_capacity_until_exact_resource_retired(self):
        self.h.limit_capacity(ACCOUNTING_CAPACITY)
        workers = []
        for index in range(ACCOUNTING_CAPACITY - 1):
            worker = self.h.spawn(label=f"Worker {index}")
            self.h.wait_node(worker["workerId"], lambda node: node["availability"] == "idle")
            workers.append(worker)
        surfaces_before = len(self.h.cmux_data()["surfaces"])
        over_capacity = self.h.spawn_native(task="over capacity", label="Over capacity", check=False)
        self.assertEqual(over_capacity["returncode"], 2)
        self.assertIn("Live worker resource limit", over_capacity["stderr"])
        self.assertEqual(len(self.h.cmux_data()["surfaces"]), surfaces_before)

        first_node = self.h.state()["nodes"][workers[0]["workerId"]]
        os.kill(first_node["supervisor"]["pid"], signal.SIGTERM)
        self.h.wait_node(workers[0]["workerId"], lambda node: node["phase"] == "process-disappeared")
        still_rejected = self.h.spawn_native(task="over capacity", label="Still over capacity", check=False)
        self.assertEqual(still_rejected["returncode"], 2)
        self.h.remove_surface(workers[0]["surfaceId"])
        replacement = self.h.spawn(label="Replacement")
        self.assertIn("workerId", replacement)

    def test_archive_reuses_coordinator_but_retains_live_worker_resources(self):
        worker = self.h.spawn()
        self.h.wait_node(worker["workerId"], lambda node: node["availability"] == "idle")
        # A registered root's terminal is reusable after archive; a managed root's stays retained.
        self.h.as_legacy_registered_root()
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
        self.h.as_legacy_registered_root()
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
        self.h.as_legacy_registered_root()
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
        self.h.close_coordinator()
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
                receipt = self.h.spawn_in_process(cmux, task="Run without hooks", label="Direct", cwd=self.h.path)
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

    def test_native_spawn_children_keep_recorded_parent_denies_and_cannot_escalate(self):
        def record(state):
            state["nodes"][self.h.node]["toolPolicy"] = {"allow": ["read", "shell(git status)"], "deny": ["web"]}
        self.h.change_state(record)
        subset = self.h.spawn_native("Subset child.", "Subset", allow=["read"], deny=["network"])
        self.wait_file(self.h.path / "interactive-ready")
        child = self.h.state()["nodes"][subset["workerId"]]
        self.assertEqual(child["toolPolicy"], {"allow": ["read"], "deny": ["web", "network"]})
        self.assertEqual(child["permissionMode"], "default")
        args = self.h.calls()[0]["args"]
        flags = [(flag, args[index + 1]) for index, flag in enumerate(args)
                 if flag in {"--allow-tool", "--deny-tool"}]
        self.assertEqual(flags, [("--allow-tool", "read"), ("--deny-tool", "web"), ("--deny-tool", "network")])
        self.assertNotIn("--allow-all", args)

        before, surfaces = self.h.state(), list(self.h.cmux_data()["surfaces"])
        escalated = self.h.spawn_native("Escalating child.", "Escalating", allow=["write"], check=False)
        self.assertEqual(escalated["returncode"], 2)
        self.assertIn("cannot grant a child additional", escalated["stderr"])
        self.assertEqual(self.h.state()["nodes"].keys(), before["nodes"].keys())
        self.assertEqual(self.h.state()["launches"], before["launches"])
        self.assertEqual(self.h.cmux_data()["surfaces"], surfaces)
        self.assertEqual(len(self.h.calls()), 1)

    def test_direct_provider_sees_only_the_controller_maestro_variables(self):
        # The host shell inherits whatever its creator carried, including retired switches.
        stale = {"CMUX_MAESTRO_TESTING": "1", "CMUX_MAESTRO_TEST_ATTACH_FAILURE": "1",
                 "CMUX_MAESTRO_ROOT": str(self.h.path / "elsewhere"),
                 "CMUX_MAESTRO_IDENTITY_HELPER": str(self.h.path / "forged-helper"),
                 "CMUX_MAESTRO_FUTURE_SWITCH": "unknown value\nCMUX_MAESTRO_INJECTED=1",
                 "CMUX_MAESTRO_MESSAGE_ROOT": "stale-parent", "CMUX_MAESTRO_WORKER_ID": "stale-worker",
                 # Legal environment names that are not shell identifiers.
                 "CMUX_MAESTRO_ODD-NAME": "1", "CMUX_MAESTRO_DOT.NAME": "1", "CMUX_MAESTRO_": "1",
                 "CMUX_MAESTRO_INITIAL_TASK": "stale task"}
        receipt = self.h.spawn_native("Report the environment.", "Scrubbed", env={**self.h.env, **stale})
        self.wait_file(self.h.path / "interactive-ready")
        call = self.h.calls()[0]
        self.assertEqual(call["session"], receipt["sessionId"])
        self.assertEqual(call["maestroKeys"], sorted([
            "CMUX_MAESTRO_CONTROL_TOKEN", "CMUX_MAESTRO_DIRECT_LAUNCH", "CMUX_MAESTRO_EXECUTION_MODE",
            "CMUX_MAESTRO_GENERATION", "CMUX_MAESTRO_LAUNCH_PID", "CMUX_MAESTRO_ORCHESTRATOR",
            "CMUX_MAESTRO_RUN_ID", "CMUX_MAESTRO_SESSION_ID", "CMUX_MAESTRO_WORKER_ID",
        ]))
        self.assertTrue(call["pinnedSubscription"])

    def test_initial_command_preserves_task_bytes_quotes_path_cwd_and_policy(self):
        cwd = self.h.path / "cwd ' ; $(not-a-command)"
        cwd.mkdir()
        task = " \tTask ' \" ; $(touch SHOULD_NOT_EXIST)\n`echo nope` \\ \u2603\n\n"
        receipt = self.h.spawn_native(task=task, label="Quoted ' worker", cwd=cwd, deny=["shell(git push)"])
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
        address = {key: self.h.identity[key] for key in ("workspaceId", "sessionId", "generation")}
        self.assertIn("Coordinator return address: " + json.dumps(address, separators=(",", ":")) + "\n", prompt)
        self.assertNotIn(self.h.identity["capability"], prompt)
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
        caller = self.h.start_native_spawn(task="Start now", label="Early native observation", cwd=self.h.path, env={**self.h.env, "FAKE_ATTACH_BARRIER": str(barrier)})
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
        caller = self.h.start_native_spawn(task="No guessed cleanup", label="Cancelled caller", cwd=self.h.path, env={**self.h.env, "FAKE_ATTACH_BARRIER": str(barrier)})
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
        self.h.limit_capacity(ACCOUNTING_CAPACITY)
        receipts = [self.h.spawn(label=f"Unobserved {index}") for index in range(ACCOUNTING_CAPACITY - 1)]
        self.assertTrue(all(item["launchAccepted"] and item["startup"] == "pending" for item in receipts))
        before = set(self.h.cmux_data()["surfaces"])
        refused = self.h.spawn_native(task="No", label="Over capacity", cwd=self.h.path, check=False)
        self.assertIn("resource limit", refused["stderr"])
        self.assertNotEqual(refused["returncode"], 0)
        self.assertEqual(set(self.h.cmux_data()["surfaces"]), before)

    def test_direct_lost_create_reply_and_failed_attach_retain_unknown_execution(self):
        for flag in ("FAKE_LOST_CREATE_REPLY", "FAKE_ATTACH_FAILURE"):
            with self.subTest(flag=flag):
                result = self.h.spawn_native(task="May already run", label=flag, cwd=self.h.path, env={**self.h.env, flag: "1"}, check=False)
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
                self.h.spawn_in_process(cmux, task="No retry", label="Cancelled attachment", cwd=self.h.path)
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
        barrier = h.path / "root-attachment"
        # A new root starts from a plain shell, not from the harness's managed session.
        source = str(uuid.uuid4())
        h.add_surface(source)
        h.env["CMUX_SURFACE_ID"] = source
        caller = h.start(
            "launch-coordinator", "--workspace", h.workspace, "--surface", source,
            "--cwd", str(h.path), "--task", "Create a child", "--account", "root-account",
            env={**h.env, "FAKE_ATTACH_BARRIER": str(barrier)},
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
            self.assertEqual(CONTROLLER_API["recorded_account"](child), {"login": "root-account", "host": "github.com"})
            self.assertNotIn("synthetic-work-token", json.dumps(h.state()))
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


class ReservationAndLeaseTests(unittest.TestCase):
    def setUp(self):
        self.h = Harness(interactive=True)
        self.h.env["FAKE_NO_OBSERVATION"] = "1"
        self.addCleanup(self.h.close)

    @staticmethod
    def dead_process():
        child = subprocess.Popen(["/usr/bin/true"])
        child.wait()
        return {"pid": child.pid, "start": "Thu Jan  1 00:00:00 1970"}

    def failed_attach(self):
        result = self.h.spawn_native(task="May already run", label="Attach fails", cwd=self.h.path, env={**self.h.env, "FAKE_ATTACH_FAILURE": "1"}, check=False)
        self.assertNotEqual(result["returncode"], 0)
        return next(item for item in self.h.state()["nodes"].values() if item["label"] == "Attach fails")

    def status(self, identifier):
        return self.h.run("status", "--actor-id", self.h.node, "--token", self.h.token,
                          "--worker-id", identifier)["workers"][0]

    def test_projection_failure_after_reservation_cancels_the_unlaunched_lease(self):
        store, original = CONTROLLER_API["Store"], CONTROLLER_API["Store"]._atomic
        failures = []

        def flaky(directory, name, data):
            if name == "current.json" and not failures:
                failures.append(name)
                raise OSError(28, "No space left on device")
            return original(directory, name, data)
        with patch.dict(os.environ, self.h.env), patch.object(store, "_atomic", staticmethod(flaky)):
            with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "reservation was cancelled"):
                self.h.spawn_in_process(CONTROLLER_API["Cmux"](), task="Never launched", label="Reserved", cwd=self.h.path)
        state = self.h.state()
        node = next(item for item in state["nodes"].values() if item["label"] == "Reserved")
        self.assertEqual(state["launches"], {})
        self.assertEqual(node["phase"], "launch-failed")
        self.assertTrue(node["runtimeNotStarted"])
        self.assertFalse([call for call in self.h.cmux_data()["calls"] if "surface.create" in call])
        self.assertTrue(CONTROLLER_API["worker_processes_exited"](node))

    def test_pre_commit_reservation_refusal_leaves_no_node_or_lease(self):
        self.h.identity = {**self.h.identity, "capability": "0" * 64}
        with patch.dict(os.environ, self.h.env):
            with self.assertRaises(CONTROLLER_API["OrchestrationError"]):
                self.h.spawn_in_process(CONTROLLER_API["Cmux"](), task="Never reserved", label="Refused",
                                        cwd=self.h.path)
        self.assertEqual(self.h.state()["launches"], {})
        self.assertEqual(len(self.h.state()["nodes"]), 1)

    def test_failed_attach_lease_releases_once_exit_and_surface_loss_are_proven(self):
        node = self.failed_attach()
        identifier = node["id"]
        self.assertIn(identifier, self.h.state()["launches"])
        self.h.change_state(lambda state: state["nodes"][identifier].update(providerProcess=self.dead_process()))
        self.assertEqual(self.status(identifier)["phase"], "launching")
        self.assertIn(identifier, self.h.state()["launches"])
        self.h.remove_surface(node["surfaceId"])
        self.assertEqual(self.status(identifier)["phase"], "terminal-disappeared")
        self.assertEqual(self.h.state()["launches"], {})
        self.h.close_coordinator()
        archived = self.h.run("archive", "--actor-id", self.h.node, "--token", self.h.token)
        self.assertTrue(archived["archived"])

    def test_prelaunch_preparation_failure_releases_lease_and_retires_its_route(self):
        routes = self.h.path / "pr"
        routes.mkdir(mode=0o700)
        published = []
        prepare = CONTROLLER_API["launch_direct_session"].__globals__["prepare_direct_launch"]

        def bind_then_fail(root, node, token):
            node["messaging"] = {"version": 1, "routes": str(routes), "extension": "/synthetic/extension"}
            self.h.change_state(lambda state: state["nodes"][node["id"]].update(messaging=node["messaging"]))
            CONTROLLER_API["bind_messaging"](node)
            published.extend(routes.iterdir())
            raise CONTROLLER_API["OrchestrationError"]("Delivery proof binding failed; use fresh fixtures.")
        with patch.dict(os.environ, self.h.env), patch.dict(
            CONTROLLER_API["launch_direct_session"].__globals__, {"prepare_direct_launch": bind_then_fail},
        ):
            with self.assertRaises(CONTROLLER_API["SessionLaunchError"]):
                self.h.spawn_in_process(CONTROLLER_API["Cmux"](), task="Never launched", label="Prep fails", cwd=self.h.path)
        self.assertEqual(len(published), 1)
        self.assertEqual(list(routes.iterdir()), [])
        self.assertEqual(self.h.state()["launches"], {})
        self.assertFalse([call for call in self.h.cmux_data()["calls"] if "surface.create" in call])

    def test_failed_attach_keeps_its_route_while_execution_is_uncertain(self):
        routes = self.h.path / "ur"
        routes.mkdir(mode=0o700)

        def bind_then_continue_to_failure(root, node, token):
            node["messaging"] = {"version": 1, "routes": str(routes), "extension": "/synthetic/extension"}
            self.h.change_state(lambda state: state["nodes"][node["id"]].update(messaging=node["messaging"]))
            CONTROLLER_API["bind_messaging"](node)
            return "/usr/bin/true"
        with patch.dict(os.environ, {**self.h.env, "FAKE_ATTACH_FAILURE": "1"}), patch.dict(
            CONTROLLER_API["launch_direct_session"].__globals__, {"prepare_direct_launch": bind_then_continue_to_failure},
        ):
            with self.assertRaises(CONTROLLER_API["SessionLaunchError"]):
                self.h.spawn_in_process(CONTROLLER_API["Cmux"](), task="May already run", label="Uncertain", cwd=self.h.path)
        self.assertEqual(len(list(routes.iterdir())), 1)

    def test_failed_attach_lease_is_kept_without_a_provider_exit_anchor(self):
        node = self.failed_attach()
        self.h.remove_surface(node["surfaceId"])
        self.status(node["id"])
        self.assertIn(node["id"], self.h.state()["launches"])
        refused = self.h.run("archive", "--actor-id", self.h.node, "--token", self.h.token, check=False)
        self.assertNotEqual(refused["returncode"], 0)


class RoutePublicationTests(unittest.TestCase):
    def setUp(self):
        self.h = Harness()
        self.addCleanup(self.h.close)
        self.routes = self.h.path / "routes"
        self.routes.mkdir(mode=0o700)
        self.node = {
            "id": str(uuid.uuid4()), "workspaceId": self.h.workspace, "label": "Peer",
            "copilotSessionId": str(uuid.uuid4()), "generation": 1,
            "messaging": {"routes": str(self.routes)},
        }
        CONTROLLER_API["bind_messaging"](self.node)
        self.route = self.routes / f"{CONTROLLER_API['message_peer'](self.node)}.json"

    def retire(self, operation):
        return CONTROLLER_API["mutate_retiring_routes"](self.h.root, operation)

    def test_aborted_mutation_leaves_routes_intact(self):
        def abort(state, retiring):
            retiring.append(self.node)
            raise CONTROLLER_API["OrchestrationError"]("Workspace retained-resource limit reached.")
        with self.assertRaises(CONTROLLER_API["OrchestrationError"]):
            self.retire(abort)
        self.assertTrue(self.route.exists())

    def test_committed_mutation_retires_routes_after_the_commit(self):
        seen = []

        def commit(state, retiring):
            retiring.append(self.node)
            seen.append(self.route.exists())
            return {"ok": True}
        self.assertEqual(self.retire(commit), {"ok": True})
        self.assertEqual(seen, [True])
        self.assertFalse(self.route.exists())

    def test_committed_state_with_failed_projection_still_retires_and_reports_commit(self):
        store, original = CONTROLLER_API["Store"], CONTROLLER_API["Store"]._atomic

        def flaky(directory, name, data):
            if name == "current.json":
                raise OSError(28, "No space left on device")
            return original(directory, name, data)
        marker = str(uuid.uuid4())

        def commit(state, retiring):
            retiring.append(self.node)
            state["archives"].append({"runId": marker, "coordinatorLabel": "x", "nodeCount": 0, "archivedAt": CONTROLLER_API["now"]()})
        with patch.object(store, "_atomic", staticmethod(flaky)):
            with self.assertRaisesRegex(CONTROLLER_API["CommittedProjectionError"], "was committed"):
                self.retire(commit)
        self.assertEqual(self.h.state()["archives"][-1]["runId"], marker)
        self.assertFalse(self.route.exists())

    def test_committed_projection_failure_reports_routes_left_in_place(self):
        self.route.write_text(json.dumps({"peer": "someone-else"}))
        self.route.chmod(0o600)
        store, original = CONTROLLER_API["Store"], CONTROLLER_API["Store"]._atomic

        def flaky(directory, name, data):
            if name == "current.json":
                raise OSError(28, "No space left on device")
            return original(directory, name, data)

        def commit(state, retiring):
            retiring.append(self.node)
        with patch.object(store, "_atomic", staticmethod(flaky)):
            with self.assertRaisesRegex(CONTROLLER_API["CommittedProjectionError"],
                                        "was committed.*1 message route") as raised:
                self.retire(commit)
        self.assertEqual(raised.exception.routesNotRetired, 1)
        self.assertTrue(self.route.exists())

    def test_unprovable_route_is_left_in_place_and_reported(self):
        self.route.write_text(json.dumps({"peer": "someone-else"}))
        self.route.chmod(0o600)

        def commit(state, retiring):
            retiring.append(self.node)
            return {"ok": True}
        self.assertEqual(self.retire(commit), {"ok": True, "routesNotRetired": 1})
        self.assertTrue(self.route.exists())

    def test_interrupted_binding_never_publishes_a_partial_route(self):
        self.route.unlink()
        real_dump = json.dump

        def torn(value, stream, *args, **kwargs):
            stream.write('{"peer": "torn')
            raise OSError(28, "No space left on device")
        with patch.object(json, "dump", torn):
            with self.assertRaises(OSError):
                CONTROLLER_API["bind_messaging"](self.node)
        self.assertEqual(list(self.routes.iterdir()), [])
        with patch.object(json, "dump", real_dump):
            CONTROLLER_API["bind_messaging"](self.node)
        self.assertEqual(json.loads(self.route.read_text())["nodeId"], self.node["id"])
        self.assertEqual(self.route.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            CONTROLLER_API["bind_messaging"](self.node)
        self.assertEqual(len(list(self.routes.iterdir())), 1)


class OwnPetPublicationTests(unittest.TestCase):
    SESSION = "11111111-2222-4333-8444-555555555555"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        patcher = patch.object(Path, "home", return_value=self.home)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.library = CONTROLLER_API["pet_session_root"](self.SESSION)
        existing = self.library / "duck"
        existing.mkdir(parents=True, mode=0o700)
        (existing / "pet.json").write_text('{"displayName": "Original"}')
        (existing / "spritesheet.png").write_bytes(b"original-sheet")
        self.source = self.home / "incoming"
        self.source.mkdir()
        (self.source / "pet.json").write_text(json.dumps({
            "id": "duck", "displayName": "Replacement", "spritesheetPath": "sheet.png"}))
        (self.source / "sheet.png").write_bytes(PetSheetSizeTests.png(1536, 1872))

    def select(self, ok):
        completed = unittest.mock.Mock(returncode=0 if ok else 1, stdout=json.dumps(
            {"ok": ok, "sessionId": self.SESSION, "petId": "duck"}))
        # Only the identity helper is synthetic; the sheet still decodes through the real decoder.
        def run(command, *args, **kwargs):
            if command[0] == CONTROLLER_API["PET_DECODER"]:
                return subprocess.run(command, *args, **kwargs)
            return completed
        return patch.dict(CONTROLLER_API["select_own_pet"].__globals__, {
            "identity_helper_path": lambda feature: "/synthetic/helper",
            "subprocess": unittest.mock.Mock(run=unittest.mock.Mock(side_effect=run),
                                             TimeoutExpired=subprocess.TimeoutExpired, DEVNULL=subprocess.DEVNULL),
        })

    def add(self):
        args = CONTROLLER_API["parser"]().parse_args([
            "pet", "--self", "--session-id", self.SESSION, "--add", str(self.source)])
        return CONTROLLER_API["command_self_pet"](args)

    def library_names(self):
        return sorted(item.name for item in self.library.iterdir() if not item.name.endswith(".lock"))

    def test_refused_ownership_restores_the_existing_pet(self):
        with self.select(False), self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "prove ownership"):
            self.add()
        self.assertEqual((self.library / "duck/pet.json").read_text(), '{"displayName": "Original"}')
        self.assertEqual((self.library / "duck/spritesheet.png").read_bytes(), b"original-sheet")
        self.assertEqual(self.library_names(), ["duck"])

    def test_refused_first_add_leaves_no_pet_behind(self):
        shutil.rmtree(self.library / "duck")
        with self.select(False), self.assertRaises(CONTROLLER_API["OrchestrationError"]):
            self.add()
        self.assertEqual(self.library_names(), [])

    def test_accepted_add_replaces_the_pet_and_leaves_no_staging(self):
        with self.select(True):
            result = self.add()
        self.assertTrue(result["added"])
        self.assertEqual(json.loads((self.library / "duck/pet.json").read_text())["displayName"], "Replacement")
        self.assertEqual(self.library_names(), ["duck"])

    def test_missing_identity_helper_restores_the_existing_pet(self):
        with patch.dict(CONTROLLER_API["select_own_pet"].__globals__, {
            "identity_helper_path": unittest.mock.Mock(side_effect=CONTROLLER_API["OrchestrationError"]("Refresh Maestro integration.")),
        }), self.assertRaises(CONTROLLER_API["OrchestrationError"]):
            self.add()
        self.assertEqual((self.library / "duck/spritesheet.png").read_bytes(), b"original-sheet")
        self.assertEqual(self.library_names(), ["duck"])

    def staged(self, label):
        return CONTROLLER_API["PetPublication"](self.SESSION, "duck", (
            ("pet.json", json.dumps({"displayName": label}).encode()),
        ))

    def test_restore_never_deletes_a_pet_another_invocation_published(self):
        publication = self.staged("Mine")
        publication.publish()
        shutil.rmtree(self.library / "duck")
        (self.library / "duck").mkdir(mode=0o700)
        (self.library / "duck/pet.json").write_text('{"displayName": "Theirs"}')
        with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "retained"):
            publication.restore()
        self.assertEqual((self.library / "duck/pet.json").read_text(), '{"displayName": "Theirs"}')
        self.assertTrue(any(item.name.startswith(".duck.previous-") for item in self.library.iterdir()))

    def test_folder_replaced_after_the_identity_check_is_never_deleted(self):
        publication = self.staged("Mine")
        publication.publish()
        real_rename = os.rename
        folder = self.library / "duck"

        def rename_then_race(source, destination, *args, **kwargs):
            real_rename(source, destination, *args, **kwargs)
            if Path(source) == folder:  # the instant after the folder was taken out of the namespace
                folder.mkdir(mode=0o700)
                (folder / "pet.json").write_text('{"displayName": "Raced"}')
        with patch.dict(CONTROLLER_API["PetPublication"].restore.__globals__,
                        {"os": unittest.mock.Mock(wraps=os, rename=rename_then_race)}):
            with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "retained"):
                publication.restore()
        self.assertEqual((folder / "pet.json").read_text(), '{"displayName": "Raced"}')
        self.assertTrue(any(item.name.startswith(".duck.previous-") for item in self.library.iterdir()))
        self.assertFalse(any(item.name.startswith(".duck.quarantine-") for item in self.library.iterdir()))

    def test_concurrent_adds_of_one_pet_are_serialized(self):
        first = self.staged("First")
        first.publish()
        second = []
        worker = threading.Thread(target=lambda: second.append(self.staged("Second")))
        worker.start()
        worker.join(0.3)
        self.assertTrue(worker.is_alive())
        first.commit()
        worker.join(5)
        self.assertFalse(worker.is_alive())
        second[0].publish()
        second[0].restore()
        self.assertEqual(json.loads((self.library / "duck/pet.json").read_text())["displayName"], "First")

    def test_non_image_sheet_is_refused_without_a_traceback(self):
        (self.source / "sheet.png").write_bytes(b"not an image")
        with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "readable PNG or WebP"):
            self.add()
        self.assertEqual((self.library / "duck/spritesheet.png").read_bytes(), b"original-sheet")


class PetSheetSizeTests(unittest.TestCase):
    """Pet sheets are flexible: 8 columns of 192:208 cells, any scale, nine or more rows."""

    @staticmethod
    def png(width, height, rows=None, *, color=6, depth=8, method=0, row_filter=0, palette=None):
        """A complete 8-bit RGBA PNG by default; options build specific defects.
        `rows` encodes fewer rows than declared; `palette` is the PLTE entry count."""
        import struct
        import zlib

        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
        channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
        compressor = zlib.compressobj(9)
        row = bytes([row_filter]) + b"\x00" * -(-width * channels * depth // 8)
        pixels = b"".join(compressor.compress(row) for _ in range(height if rows is None else rows))
        pixels += compressor.flush()
        header = chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, depth, color, method, 0, 0))
        plte = chunk(b"PLTE", b"\x00\x00\x00" * palette) if palette else b""
        return b"\x89PNG\r\n\x1a\n" + header + plte + chunk(b"IDAT", pixels) + chunk(b"IEND", b"")

    # 512x624 lossless WebP made with `cwebp -lossless`; decodes with ImageIO.
    WEBP = bytes.fromhex("524946462c000000574542505650384c200000002fffc19b10071011110050a4ffff29a2ffa9"
                         "fffdef7ffffbdffffef7bfff0f00")

    @staticmethod
    def fake_vp8(width, height):
        """RIFF-framed lossy WebP whose VP8 payload is not decodable."""
        import struct
        frame = b"\x00\x00\x00\x9d\x01\x2a" + struct.pack("<HH", width, height) + b"\x00" * 22
        body = b"WEBP" + b"VP8 " + struct.pack("<I", len(frame)) + frame
        return b"RIFF" + struct.pack("<I", len(body)) + body

    def sheet_folder(self, data, extension):
        folder = Path(tempfile.mkdtemp(prefix="pet-", dir="/tmp")) / "duck"
        folder.mkdir(parents=True)
        self.addCleanup(shutil.rmtree, folder.parent, True)
        (folder / "pet.json").write_text(json.dumps({
            "id": "duck", "displayName": "Duck", "spritesheetPath": "sheet" + extension}))
        (folder / ("sheet" + extension)).write_bytes(data)
        return folder

    def test_decodable_png_indexed_png_and_webp_are_accepted(self):
        read = CONTROLLER_API["read_pet_source"]
        for name, data, extension in (("rgba png", self.png(512, 624), ".png"),
                                      ("indexed png", self.png(512, 624, color=3, palette=1), ".png"),
                                      ("lossless webp", self.WEBP, ".webp")):
            with self.subTest(name):
                *_, sheet, actual = read(str(self.sheet_folder(data, extension)), None)
                self.assertEqual((sheet, actual), (data, extension))
                self.assertEqual(CONTROLLER_API["decoded_size"](data, extension), (512, 624))

    def test_undecodable_sheets_with_plausible_framing_are_refused(self):
        read = CONTROLLER_API["read_pet_source"]
        for name, data, extension in (
            ("invalid filter byte", self.png(512, 624, row_filter=5), ".png"),
            ("indexed without palette", self.png(512, 624, color=3), ".png"),
            ("palette larger than depth", self.png(512, 624, color=3, depth=1, palette=3), ".png"),
            ("illegal depth for color", self.png(512, 624, depth=4), ".png"),
            ("nonzero compression method", self.png(512, 624, method=1), ".png"),
            ("framed but invalid vp8", self.fake_vp8(512, 624), ".webp"),
        ):
            with self.subTest(name):
                self.assertEqual(CONTROLLER_API["image_size"](data), (512, 624))
                with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "corrupt or truncated"):
                    read(str(self.sheet_folder(data, extension)), None)
        # The framed VP8 passes preflight, so only the ImageIO decode refuses it.
        self.assertTrue(CONTROLLER_API["webp_complete"](self.fake_vp8(512, 624)))
        self.assertIsNone(CONTROLLER_API["decoded_size"](self.fake_vp8(512, 624), ".webp"))

    def test_decoder_disagreement_or_absence_refuses(self):
        read = CONTROLLER_API["read_pet_source"]
        folder = self.sheet_folder(self.png(512, 624), ".png")
        with patch.dict(read.__globals__, {"decoded_size": lambda data, extension: (512, 625)}), \
                self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "corrupt or truncated"):
            read(str(folder), None)
        with patch.dict(read.__globals__, {"PET_DECODER": "/nonexistent/sips"}), \
                self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "cannot be verified"):
            read(str(folder), None)

    def test_fixture_decodes_with_an_independent_reader(self):
        sips = shutil.which("sips")
        if sips is None:
            self.skipTest("ImageIO's sips is macOS-only")
        folder = self.pet_folder(1536, 1872)
        output = subprocess.run([sips, "-g", "pixelWidth", "-g", "pixelHeight", str(folder / "sheet.png")],
                                capture_output=True, text=True, check=True).stdout
        self.assertIn("pixelWidth: 1536", output)
        self.assertIn("pixelHeight: 1872", output)

    def test_corrupt_or_truncated_sheets_with_valid_headers_are_rejected(self):
        read = CONTROLLER_API["read_pet_source"]
        sheet = self.png(1536, 1872)
        idat = sheet.index(b"IDAT")
        flipped = bytearray(sheet)
        flipped[idat + 8] ^= 0xFF
        header_only = sheet[:33]
        for name, data in (("header only", header_only), ("truncated", sheet[:-20]),
                           ("bad crc", bytes(flipped)), ("trailing bytes", sheet + b"junk"),
                           ("missing rows", self.png(1536, 1872, rows=1871))):
            with self.subTest(name):
                folder = self.pet_folder(1536, 1872)
                (folder / "sheet.png").write_bytes(data)
                self.assertEqual(CONTROLLER_API["image_size"](data), (1536, 1872))
                with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], "corrupt or truncated"):
                    read(str(folder), None)

    def pet_folder(self, width, height, name="duck"):
        folder = Path(tempfile.mkdtemp(prefix="pet-", dir="/tmp")) / name
        folder.mkdir(parents=True)
        self.addCleanup(shutil.rmtree, folder.parent, True)
        (folder / "pet.json").write_text(json.dumps({
            "id": name, "displayName": "Duck", "spritesheetPath": "sheet.png"}))
        (folder / "sheet.png").write_bytes(self.png(width, height))
        return folder

    def test_standard_v2_and_scaled_sheets_are_accepted(self):
        read = CONTROLLER_API["read_pet_source"]
        for width, height in ((1536, 1872), (1536, 2288), (3072, 3744), (768, 936), (1536, 2000)):
            identifier, display, description, data, extension = read(str(self.pet_folder(width, height)), None)
            self.assertEqual((identifier, extension), ("duck", ".png"))
            self.assertEqual(CONTROLLER_API["image_size"](data), (width, height))

    def test_sheets_without_the_grid_are_rejected(self):
        read = CONTROLLER_API["read_pet_source"]
        for width, height in ((1536, 1800), (1537, 1872), (400, 468), (5000, 6000), (1536, 4000), (1536, 800)):
            with self.assertRaisesRegex(CONTROLLER_API["OrchestrationError"], r"8 columns"):
                read(str(self.pet_folder(width, height)), None)



TAG_FAKE_HELPER = """#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:2] != ["prove"] or os.environ.get("FAKE_PROOF") == "deny":
    print(json.dumps({"ok": False}))
    sys.exit(2)
print(json.dumps({"ok": True, "sessionId": sys.argv[sys.argv.index("--session-id") + 1]}))
"""


class AgentTagTests(unittest.TestCase):
    """The agent surface for its own tags: exact-self proof, canonical slugs, no truncation,
    no color control, and other sessions' entries untouched."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        base = Path(self.directory.name).resolve()
        self.home = base / "home"
        self.root = self.home / "Library/Application Support/CMUXMaestroPreview/Copilot/tags"
        helper = base / "helper"
        helper.write_text(TAG_FAKE_HELPER)
        helper.chmod(0o700)
        package = base / "package"
        package.mkdir()
        self.controller = package / CONTROLLER.name
        shutil.copyfile(CONTROLLER, self.controller)
        config = package / "identity-helper.json"
        config.write_text(json.dumps({"helper": str(helper)}))
        config.chmod(0o600)
        self.session, self.other = str(uuid.uuid4()), str(uuid.uuid4())

    def tearDown(self):
        self.directory.cleanup()

    def run_tags(self, action, *tags, session=None, deny=False, extra=()):
        environment = dict(os.environ, HOME=str(self.home))
        if deny:
            environment["FAKE_PROOF"] = "deny"
        command = [sys.executable, str(self.controller), "tags", action, "--self",
                   "--session-id", session or self.session, *extra]
        for tag in tags:
            command += ["--tag", tag]
        process = subprocess.run(command, capture_output=True, text=True, env=environment, timeout=30)
        return process.returncode, json.loads(process.stdout or process.stderr)

    def stored(self):
        return json.loads((self.root / "agent-tags.json").read_text())

    def test_slug_cases_match_the_sidebar_fixture(self):
        cases = json.loads((REPO / "scripts/test-fixtures/tag-slug-cases.json").read_text())
        self.assertEqual(cases["version"], CONTROLLER_API["TAGS_VERSION"])
        for case in cases["cases"]:
            self.assertEqual(CONTROLLER_API["tag_slug"](case["input"]), case["slug"], case["input"])

    def test_add_list_remove_clear_bind_to_the_proven_session_only(self):
        self.assertEqual(self.run_tags("add", "Deploy", session=self.other)[0], 0)
        code, added = self.run_tags("add", "Front End", "front_end", "Deploy")
        self.assertEqual(code, 0, added)
        self.assertEqual(added["agentTags"], ["front-end", "deploy"])
        self.assertEqual(self.run_tags("list")[1]["agentTags"], ["front-end", "deploy"])
        code, removed = self.run_tags("remove", "DEPLOY", "absent")
        self.assertEqual(code, 0, removed)
        self.assertEqual((removed["agentTags"], removed["notAssigned"]), (["front-end"], ["absent"]))
        self.assertEqual(self.run_tags("clear")[1]["agentTags"], [])
        self.assertEqual(self.stored(), {"version": 1, "sessions": {self.other: ["deploy"]}})
        self.assertEqual((self.root / "agent-tags.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.root.parent.stat().st_mode & 0o777, 0o700)

    def test_unproven_caller_changes_nothing(self):
        code, value = self.run_tags("add", "deploy", deny=True)
        self.assertNotEqual(code, 0)
        self.assertIn("no tag was changed", value["error"])
        self.assertFalse(self.root.exists())

    def test_over_limit_or_invalid_tags_are_refused_whole(self):
        self.assertEqual(self.run_tags("add", *[f"t{index}" for index in range(5)])[0], 0)
        before = self.stored()
        for tags in (["t9", "t10"], ["x" * 25], ["ok", "!!!"]):
            code, value = self.run_tags("add", *tags)
            self.assertNotEqual(code, 0, tags)
            self.assertIn("nothing was changed", value["error"])
            self.assertEqual(self.stored(), before)
        self.assertEqual(self.run_tags("add", "t0", "y" * 24)[1]["agentTags"][-1], "y" * 24)

    def test_agents_have_no_color_control_and_need_an_exact_session(self):
        with self.assertRaises(SystemExit):
            with patch("sys.stderr", io.StringIO()):
                CONTROLLER_API["parser"]().parse_args(["tags", "add", "--self", "--session-id", self.session,
                                                       "--tag", "x", "--color", "red"])
        code, value = self.run_tags("add", "x", session="not-a-session")
        self.assertNotEqual(code, 0)
        self.assertFalse(self.root.exists())

    def test_invalid_store_is_refused_and_left_untouched(self):
        self.assertEqual(self.run_tags("add", "keep")[0], 0)
        path = self.root / "agent-tags.json"
        path.write_text('{"version":1,"sessions":{"%s":["Not Canonical"]}}' % self.session)
        code, value = self.run_tags("add", "more")
        self.assertNotEqual(code, 0)
        self.assertIn("Not Canonical", path.read_text())

    def test_store_contract_cases_match_the_sidebar(self):
        cases = json.loads((REPO / "scripts/test-fixtures/tag-store-cases.json").read_text())
        decode = CONTROLLER_API["tags_decode"]
        for case in cases["valid"]:
            decode(case["raw"].encode())
        for case in cases["invalid"]:
            with self.assertRaises(CONTROLLER_API["OrchestrationError"], msg=case["name"]):
                decode(case["raw"].encode())
        with self.assertRaises(CONTROLLER_API["OrchestrationError"]):
            decode(b"\xef\xbb\xbf" + cases["valid"][0]["raw"].encode())

    def test_full_store_drops_only_sessions_copilot_no_longer_keeps(self):
        command = CONTROLLER_API["tags_command"]
        state_root = self.home / ".copilot/session-state"
        kept, ended = str(uuid.uuid4()), str(uuid.uuid4())
        (state_root / kept).mkdir(parents=True)
        (state_root / self.session).mkdir()
        arguments = lambda session, action="add": type("Args", (), {
            "own_session": True, "session_id": session, "tags_action": action, "tag": ["x"]})()
        with patch.dict(command.__globals__, {"TAGS_MAX_SESSIONS": 2, "prove_own_session": lambda *_, **__: None}), \
                patch.dict(os.environ, {"HOME": str(self.home)}):
            command(arguments(kept))
            command(arguments(ended))
            result = command(arguments(self.session))
            self.assertEqual(result["pruned"], [ended])
            self.assertEqual(sorted(self.stored()["sessions"]), sorted([kept, self.session]))
            (state_root / str(uuid.uuid4())).mkdir()
            newcomer = sorted(path.name for path in state_root.iterdir() if path.name not in (kept, self.session))[0]
            with self.assertRaises(CONTROLLER_API["OrchestrationError"]):
                command(arguments(newcomer))
            self.assertEqual(sorted(self.stored()["sessions"]), sorted([kept, self.session]))

    def test_denied_session_lookup_keeps_the_session(self):
        keeps = CONTROLLER_API["copilot_keeps_session"]
        root = self.home / ".copilot/session-state"
        with patch.dict(os.environ, {"HOME": str(self.home)}):
            self.assertTrue(keeps(self.session))
            root.mkdir(parents=True)
            (root / self.session).mkdir()
            self.assertTrue(keeps(self.session))
            self.assertFalse(keeps(self.other))
            root.chmod(0o600)
            try:
                self.assertTrue(keeps(self.other))
            finally:
                root.chmod(0o700)

    def test_concurrent_agents_lose_nothing(self):
        sessions = [str(uuid.uuid4()) for _ in range(6)]
        threads = [threading.Thread(target=self.run_tags, args=("add", "shared"), kwargs={"session": item})
                   for item in sessions]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(self.stored()["sessions"], {item: ["shared"] for item in sessions})


if __name__ == "__main__":
    unittest.main()
