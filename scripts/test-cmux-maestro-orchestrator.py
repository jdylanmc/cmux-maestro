#!/usr/bin/env python3
import ast
import json
import os
import re
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
import json, os, subprocess, sys, time, uuid
from pathlib import Path
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
    def __init__(self):
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
            "FAKE_STDERR_READY": str(self.stderr_ready),
            "FAKE_POLICY_RESULTS": str(self.policy_results),
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
        self.assertEqual(completed["result"], "bounded completed")
        first = self.h.calls()[0]["args"]
        self.assertIn("--session-id", first)
        self.assertNotIn("--resume", first)
        self.assertNotIn("--allow-all", first)
        sends = [call for call in self.h.cmux_data()["calls"] if "send" in call]
        self.assertEqual(len(sends), 1)
        log = self.h.path / f"runtime-{worker['surfaceId']}.log"
        self.assertIn("visible permission diagnostic", log.read_text())

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
        self.assertEqual(len(send_calls), 1, "follow-up must use the private queue, not terminal input")

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
