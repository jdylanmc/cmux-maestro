#!/usr/bin/env python3
"""Bounded CMUX terminal-backed Copilot orchestration.

Control state contains prompts, results, tokens, and process details. The
sidebar-readable projection contains only bounded identity and lifecycle
metadata.
"""

import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import stat
import subprocess
import sys
import uuid

VERSION = 1
MAX_BYTES = 1_048_576
MAX_NODES = 128
MAX_DEPTH = 8
MAX_ACTIVE_CHILDREN = 8
MAX_LABEL = 100
MAX_TASK = 32_768
MAX_RESULT = 4_096
STALE_SECONDS = 600
TERMINAL_PHASES = {"reported-completed", "reported-failed"}
REPORT_PHASES = {
    "running": "process-running",
    "blocked": "reported-blocked",
    "completed": "reported-completed",
    "failed": "reported-failed",
}


class OrchestrationError(Exception):
    pass


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def canonical_uuid(value, field):
    try:
        parsed = uuid.UUID(value)
    except (ValueError, TypeError, AttributeError):
        raise OrchestrationError(f"{field} must be a UUID.")
    if str(parsed) != value.lower():
        raise OrchestrationError(f"{field} must be a canonical UUID.")
    return str(parsed)


def bounded_text(value, field, limit, *, empty=False):
    if not isinstance(value, str) or (not empty and not value.strip()):
        raise OrchestrationError(f"{field} is required.")
    if len(value.encode("utf-8")) > limit or "\0" in value:
        raise OrchestrationError(f"{field} exceeds its safe limit.")
    if any(ord(character) < 32 and character not in "\n\t" for character in value):
        raise OrchestrationError(f"{field} contains control characters.")
    return value.strip()


def sanitize_label(value):
    cleaned = "".join(character for character in value if character.isprintable())
    return " ".join(cleaned.split())[:MAX_LABEL] or "Unnamed worker"


def validate_state(state):
    nodes = state["nodes"]
    if len(nodes) > MAX_NODES:
        raise OrchestrationError("Control state exceeds the node limit.")
    surfaces = set()
    for identifier, node in nodes.items():
        if canonical_uuid(identifier, "stored node ID") != node.get("id"):
            raise OrchestrationError("Stored node identity is invalid.")
        for field in ("runId", "workspaceId", "surfaceId"):
            canonical_uuid(node.get(field), f"stored {field}")
        if node["surfaceId"] in surfaces:
            raise OrchestrationError("Stored surfaces must be unique.")
        surfaces.add(node["surfaceId"])
        parent = node.get("parentId")
        if parent is not None:
            canonical_uuid(parent, "stored parent ID")
        role = node.get("role")
        if role not in {"coordinator", "worker"}:
            raise OrchestrationError("Stored node role is invalid.")
        if (role == "coordinator") != (parent is None):
            raise OrchestrationError("Stored coordinator ancestry is invalid.")
        if not isinstance(node.get("generation"), int) or node["generation"] < 0:
            raise OrchestrationError("Stored generation is invalid.")
    for node in nodes.values():
        seen = {node["id"]}
        current = node
        depth = 0
        while current["parentId"] is not None:
            parent = nodes.get(current["parentId"])
            if parent is None or parent["id"] in seen:
                raise OrchestrationError("Stored ancestry is invalid or cyclic.")
            if (parent["runId"], parent["workspaceId"]) != (
                node["runId"], node["workspaceId"]
            ):
                raise OrchestrationError("Stored ancestry crosses a run or workspace.")
            seen.add(parent["id"])
            current = parent
            depth += 1
            if depth > MAX_DEPTH:
                raise OrchestrationError("Stored ancestry exceeds the depth limit.")


def default_root():
    override = os.environ.get("CMUX_MAESTRO_ROOT")
    if override:
        if os.environ.get("CMUX_MAESTRO_TESTING") != "1":
            raise OrchestrationError("CMUX_MAESTRO_ROOT is test-only.")
        return Path(override)
    return Path.home() / "Library/Application Support/CMUXMaestroPreview/Orchestration"


def trusted_executable(variable, fallback):
    value = os.environ.get(variable)
    if value and os.environ.get("CMUX_MAESTRO_TESTING") != "1":
        raise OrchestrationError(f"{variable} is test-only.")
    candidate = Path(value or fallback)
    if not candidate.is_absolute():
        resolved = shutil_which(str(candidate))
        if resolved is None:
            raise OrchestrationError(f"Required executable is unavailable: {fallback}")
        candidate = Path(resolved)
    try:
        info = candidate.resolve(strict=True).stat()
    except OSError:
        raise OrchestrationError(f"Required executable is unavailable: {candidate}")
    if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o022 or info.st_uid not in (0, os.getuid()):
        raise OrchestrationError(f"Refusing untrusted executable: {candidate}")
    if not os.access(candidate, os.X_OK):
        raise OrchestrationError(f"Required executable is not executable: {candidate}")
    return str(candidate.resolve())


def shutil_which(name):
    for directory in os.environ.get("PATH", "/usr/bin:/bin").split(os.pathsep):
        candidate = Path(directory) / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


class Store:
    def __init__(self, root):
        self.root = root
        self.control = root / "control"
        self.observer = root / "observer"
        self.state_path = self.control / "state.json"
        self.projection_path = self.observer / "current.json"
        self.lock_fd = None

    def __enter__(self):
        self._private_directory(self.root)
        self._private_directory(self.control)
        self._private_directory(self.observer)
        lock = self.control / "state.lock"
        self.lock_fd = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        info = os.fstat(self.lock_fd)
        if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode):
            raise OrchestrationError("Control lock is not a private regular file.")
        try:
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise OrchestrationError("Another orchestration operation is active; retry.")
        return self

    def __exit__(self, *_):
        if self.lock_fd is not None:
            fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
            os.close(self.lock_fd)

    @staticmethod
    def _private_directory(path):
        current = Path(path.anchor)
        for component in path.parts[1:]:
            current /= component
            if current.exists() or current.is_symlink():
                info = current.lstat()
                if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                    raise OrchestrationError(f"Unsafe state path: {current}")
                if current == path and (info.st_uid != os.getuid() or info.st_mode & 0o077):
                    raise OrchestrationError(f"State directory is not private: {current}")
            else:
                current.mkdir(mode=0o700)
        os.chmod(path, 0o700)

    def read(self):
        if not self.state_path.exists():
            return {"version": VERSION, "nodes": {}}
        info = self.state_path.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise OrchestrationError("Control state is not an owned regular file.")
        if info.st_size <= 0 or info.st_size > MAX_BYTES:
            raise OrchestrationError("Control state has an invalid size.")
        before = (info.st_dev, info.st_ino, info.st_mtime_ns, info.st_size)
        with self.state_path.open("rb") as stream:
            payload = stream.read(MAX_BYTES + 1)
        after_info = self.state_path.lstat()
        after = (after_info.st_dev, after_info.st_ino, after_info.st_mtime_ns, after_info.st_size)
        if before != after or len(payload) > MAX_BYTES:
            raise OrchestrationError("Control state changed while reading.")
        try:
            state = json.loads(payload)
        except (json.JSONDecodeError, UnicodeDecodeError):
            raise OrchestrationError("Control state is malformed.")
        if state.get("version") != VERSION or not isinstance(state.get("nodes"), dict):
            raise OrchestrationError("Control state version is unsupported.")
        validate_state(state)
        return state

    def write(self, state):
        encoded = json.dumps(state, sort_keys=True, separators=(",", ":")).encode() + b"\n"
        if len(encoded) > MAX_BYTES:
            raise OrchestrationError("Control state exceeds its safe limit.")
        self._atomic(self.state_path, encoded)
        self._atomic(self.projection_path, self._projection(state))

    def _projection(self, state):
        nodes = sorted(state["nodes"].values(), key=lambda item: (item["createdAt"], item["id"]))
        projected = []
        for item in nodes[:MAX_NODES]:
            projected.append({
                "id": item["id"],
                "runId": item["runId"],
                "parentId": item["parentId"],
                "role": item["role"],
                "label": item["label"],
                "workspaceId": item["workspaceId"],
                "surfaceId": item["surfaceId"],
                "generation": item["generation"],
                "phase": item["phase"],
                "availability": item["availability"],
                "createdAt": item["createdAt"],
                "updatedAt": item["updatedAt"],
            })
        payload = {
            "version": VERSION,
            "generatedAt": now(),
            "complete": len(nodes) <= MAX_NODES,
            "omittedCount": max(0, len(nodes) - MAX_NODES),
            "nodes": projected,
        }
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode() + b"\n"
        if len(encoded) > MAX_BYTES:
            raise OrchestrationError("Observer projection exceeds its safe limit.")
        return encoded

    @staticmethod
    def _atomic(path, data):
        temporary = path.parent / f".pending-{uuid.uuid4()}"
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                if written <= 0:
                    raise OrchestrationError("Unable to write orchestration state.")
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)


class Cmux:
    def __init__(self):
        self.executable = trusted_executable("CMUX_MAESTRO_CMUX", "cmux")

    def run(self, command, *arguments):
        invocation = [self.executable, "--json", "--id-format", "uuids", command, *arguments]
        try:
            result = subprocess.run(invocation, capture_output=True, text=True, timeout=15)
        except subprocess.TimeoutExpired:
            raise OrchestrationError(f"CMUX {command} timed out.")
        if result.returncode:
            diagnostic = " ".join((result.stderr or result.stdout).split())[:240]
            raise OrchestrationError(f"CMUX {command} failed: {diagnostic or 'no diagnostic'}")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            raise OrchestrationError(f"CMUX {command} returned invalid JSON.")

    @staticmethod
    def ids(value, keys=None):
        result = []
        if isinstance(value, dict):
            for key, child in value.items():
                normalized = key.replace("_", "").lower()
                if isinstance(child, str) and (keys is None or normalized in keys):
                    try:
                        result.append(str(uuid.UUID(child)))
                    except ValueError:
                        pass
                result.extend(Cmux.ids(child, keys))
        elif isinstance(value, list):
            for child in value:
                result.extend(Cmux.ids(child, keys))
        return result

    def validate_surface(self, workspace, surface):
        identified = self.run("identify", "--workspace", workspace, "--surface", surface)
        all_ids = set(self.ids(identified))
        if workspace not in all_ids or surface not in all_ids:
            raise OrchestrationError("CMUX did not confirm the exact workspace and surface.")
        return self.find_pane(workspace, surface)

    def find_pane(self, workspace, surface):
        panes = self.run("list-panes", "--workspace", workspace)
        candidates = []
        for candidate in self.ids(panes, {"id", "paneid", "uuid"}):
            if candidate not in candidates and candidate != workspace:
                candidates.append(candidate)
        for pane in candidates:
            try:
                listing = self.run(
                    "list-pane-surfaces", "--workspace", workspace, "--pane", pane
                )
            except OrchestrationError:
                continue
            surfaces = self.ids(listing, {"id", "surfaceid", "uuid"})
            if surface in surfaces:
                return pane
        raise OrchestrationError("The exact surface is not in a current pane of that workspace.")

    def create_surface(self, workspace, pane, cwd):
        response = self.run(
            "new-surface", "--type", "terminal", "--pane", pane,
            "--workspace", workspace, "--working-directory", cwd, "--focus", "false",
        )
        candidates = [
            value for value in self.ids(response, {"id", "surfaceid", "uuid"})
            if value not in {workspace, pane}
        ]
        if len(set(candidates)) != 1:
            raise OrchestrationError("CMUX did not return one exact new surface ID.")
        return candidates[0]

    def send_bootstrap(self, workspace, surface, command):
        self.validate_surface(workspace, surface)
        self.run("send", "--workspace", workspace, "--surface", surface, "--", command)
        self.run("send-key", "--workspace", workspace, "--surface", surface, "enter")

    def follow_up(self, workspace, surface, prompt):
        self.validate_surface(workspace, surface)
        self.run("send", "--workspace", workspace, "--surface", surface, "--", prompt)
        self.run("send-key", "--workspace", workspace, "--surface", surface, "enter")

    def focus(self, workspace, surface):
        pane = self.validate_surface(workspace, surface)
        listing = self.run("list-pane-surfaces", "--workspace", workspace, "--pane", pane)
        surfaces = []
        for candidate in self.ids(listing, {"id", "surfaceid", "uuid"}):
            if candidate not in surfaces and candidate not in {workspace, pane}:
                surfaces.append(candidate)
        if surface not in surfaces:
            raise OrchestrationError("Worker surface disappeared before focus.")
        self.run(
            "reorder-surface", "--surface", surface, "--workspace", workspace,
            "--pane", pane, "--index", str(surfaces.index(surface)), "--focus", "true",
        )


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def authorize(state, actor_id, token):
    actor_id = canonical_uuid(actor_id, "actor ID")
    actor = state["nodes"].get(actor_id)
    if not actor or not secrets.compare_digest(actor["tokenHash"], token_hash(token or "")):
        raise OrchestrationError("Actor identity or control token is invalid.")
    return actor


def descendants(state, actor):
    children = {}
    for node in state["nodes"].values():
        children.setdefault(node["parentId"], []).append(node)
    result = []
    pending = [actor]
    while pending:
        current = pending.pop()
        result.append(current)
        pending.extend(children.get(current["id"], []))
    return result


def ensure_owned(state, actor, target_id, *, direct=False):
    target_id = canonical_uuid(target_id, "worker ID")
    target = state["nodes"].get(target_id)
    if not target:
        raise OrchestrationError("Worker ID is not registered.")
    if direct:
        allowed = target["parentId"] == actor["id"]
    else:
        allowed = target_id in {item["id"] for item in descendants(state, actor)}
    if not allowed:
        raise OrchestrationError("Target is outside the actor's owned orchestration tree.")
    if target["runId"] != actor["runId"] or target["workspaceId"] != actor["workspaceId"]:
        raise OrchestrationError("Cross-run or cross-workspace control is forbidden.")
    return target


def process_start(pid):
    try:
        result = subprocess.run(
            ["/bin/ps", "-o", "lstart=", "-p", str(pid)],
            capture_output=True, text=True, timeout=3,
        )
    except subprocess.TimeoutExpired:
        return None
    value = result.stdout.strip()
    return value if result.returncode == 0 and value else None


def process_matches(node):
    process = node.get("process")
    if not process:
        return False
    return process_start(process["pid"]) == process["start"]


def refresh_node(cmux, node):
    try:
        pane = cmux.validate_surface(node["workspaceId"], node["surfaceId"])
        node["paneId"] = pane
    except OrchestrationError:
        node["phase"] = "terminal-disappeared"
        node["availability"] = "unavailable"
        node["updatedAt"] = now()
        return
    if (
        node["role"] == "worker"
        and node["phase"] not in {"launching", "launch-failed", "terminal-disappeared"}
        and not process_matches(node)
    ):
        node["phase"] = "process-disappeared"
        node["availability"] = "unavailable"
        node["updatedAt"] = now()


def report_instruction(node):
    command = shlex.quote(str(Path(__file__).resolve())) + " report"
    return (
        f"\n\nCMUX Maestro worker contract: this is bounded turn {node['generation']} for "
        f"worker {node['id']}. Do not spawn workers except through the installed "
        f"cmux-maestro-orchestrate skill. Before becoming idle, run `{command} "
        f"--generation {node['generation']} --state completed --summary '<brief result>'`; "
        "use state blocked or failed when appropriate. A normal answer or zero command exit "
        "does not report task success."
    )


def command_register(args, store, cmux):
    workspace = canonical_uuid(args.workspace, "workspace ID")
    surface = canonical_uuid(args.surface, "surface ID")
    label = sanitize_label(bounded_text(args.name, "name", MAX_LABEL))
    pane = cmux.validate_surface(workspace, surface)
    state = store.read()
    if len(state["nodes"]) >= MAX_NODES:
        raise OrchestrationError("Orchestration node limit reached.")
    if any(node["surfaceId"] == surface for node in state["nodes"].values()):
        raise OrchestrationError("This CMUX surface is already registered.")
    identifier, run_id, token = str(uuid.uuid4()), str(uuid.uuid4()), secrets.token_hex(32)
    timestamp = now()
    state["nodes"][identifier] = {
        "id": identifier, "runId": run_id, "parentId": None, "role": "coordinator",
        "label": label, "workspaceId": workspace, "surfaceId": surface, "paneId": pane,
        "copilotSessionId": None, "workingDirectory": None, "generation": 0,
        "phase": "registered", "availability": "active", "createdAt": timestamp,
        "updatedAt": timestamp, "tokenHash": token_hash(token), "task": None,
        "result": None, "process": None,
    }
    store.write(state)
    return {"coordinatorId": identifier, "runId": run_id, "controlToken": token,
            "workspaceId": workspace, "surfaceId": surface}


def command_spawn(args, store, cmux):
    state = store.read()
    actor = authorize(state, args.actor_id, args.token)
    refresh_node(cmux, actor)
    if actor["phase"] in {"terminal-disappeared", "process-disappeared"}:
        store.write(state)
        raise OrchestrationError("Actor surface or process is no longer valid.")
    if actor["role"] == "worker" and not process_matches(actor):
        actor["phase"], actor["availability"], actor["updatedAt"] = (
            "process-disappeared", "unavailable", now()
        )
        store.write(state)
        raise OrchestrationError("Actor worker process identity is stale.")
    task = bounded_text(args.task, "task", MAX_TASK)
    cwd = Path(args.cwd).expanduser()
    try:
        cwd = cwd.resolve(strict=True)
    except OSError:
        raise OrchestrationError("Working directory does not exist.")
    if not cwd.is_dir():
        raise OrchestrationError("Working directory must be a directory.")
    owned = descendants(state, actor)
    depth = 0
    current = actor
    while current["parentId"] is not None:
        depth += 1
        current = state["nodes"].get(current["parentId"])
        if current is None or depth > MAX_DEPTH:
            raise OrchestrationError("Stored ancestry is invalid.")
    if depth + 1 > MAX_DEPTH:
        raise OrchestrationError("Maximum worker nesting depth reached.")
    active_children = [
        node for node in state["nodes"].values()
        if node["parentId"] == actor["id"] and node["availability"] != "unavailable"
        and node["phase"] not in TERMINAL_PHASES
    ]
    if len(active_children) >= MAX_ACTIVE_CHILDREN:
        raise OrchestrationError("Active child limit reached; wait for or reuse an existing worker.")
    if len(state["nodes"]) >= MAX_NODES:
        raise OrchestrationError("Orchestration node limit reached.")
    label = sanitize_label(bounded_text(args.name, "name", MAX_LABEL))
    identifier, session_id, token = str(uuid.uuid4()), str(uuid.uuid4()), secrets.token_hex(32)
    surface = cmux.create_surface(actor["workspaceId"], actor["paneId"], str(cwd))
    pane = cmux.validate_surface(actor["workspaceId"], surface)
    timestamp = now()
    node = {
        "id": identifier, "runId": actor["runId"], "parentId": actor["id"], "role": "worker",
        "label": label, "workspaceId": actor["workspaceId"], "surfaceId": surface, "paneId": pane,
        "copilotSessionId": session_id, "workingDirectory": str(cwd), "generation": 1,
        "phase": "launching", "availability": "busy", "createdAt": timestamp,
        "updatedAt": timestamp, "tokenHash": token_hash(token), "task": task,
        "result": None, "process": None,
    }
    state["nodes"][identifier] = node
    store.write(state)
    launcher = Path(__file__).resolve()
    bootstrap = " ".join([
        shlex.quote(str(launcher)), "runtime", "--worker-id", shlex.quote(identifier),
        "--token", shlex.quote(token),
    ])
    try:
        cmux.send_bootstrap(actor["workspaceId"], surface, bootstrap)
        cmux.run("rename-tab", "--workspace", actor["workspaceId"], "--surface", surface, "--", label)
    except Exception:
        node["phase"] = "launch-failed"
        node["availability"] = "unavailable"
        node["updatedAt"] = now()
        store.write(state)
        raise
    return {"workerId": identifier, "sessionId": session_id, "surfaceId": surface,
            "workspaceId": actor["workspaceId"], "generation": 1}


def command_runtime(args, store):
    state = store.read()
    node = authorize(state, args.worker_id, args.token)
    if node["role"] != "worker" or node["phase"] != "launching":
        raise OrchestrationError("Worker runtime is not in the launch phase.")
    pid = os.getpid()
    start = process_start(pid)
    if not start:
        raise OrchestrationError("Cannot establish worker process identity.")
    node["process"] = {"pid": pid, "start": start}
    node["phase"] = "process-running"
    node["availability"] = "busy"
    node["updatedAt"] = now()
    store.write(state)
    copilot = trusted_executable("CMUX_MAESTRO_COPILOT", "copilot")
    environment = os.environ.copy()
    environment.update({
        "CMUX_MAESTRO_WORKER_ID": node["id"],
        "CMUX_MAESTRO_CONTROL_TOKEN": args.token,
        "CMUX_MAESTRO_RUN_ID": node["runId"],
        "CMUX_MAESTRO_ORCHESTRATOR": str(Path(__file__).resolve()),
    })
    prompt = node["task"] + report_instruction(node)
    os.chdir(node["workingDirectory"])
    os.execve(copilot, [
        copilot, "--no-auto-update", "--interactive", prompt,
        "--name", node["label"], "--session-id", node["copilotSessionId"],
        "-C", node["workingDirectory"],
    ], environment)


def command_report(args, store):
    actor_id = args.worker_id or os.environ.get("CMUX_MAESTRO_WORKER_ID")
    token = args.token or os.environ.get("CMUX_MAESTRO_CONTROL_TOKEN")
    state = store.read()
    node = authorize(state, actor_id, token)
    if node["role"] != "worker":
        raise OrchestrationError("Only workers can report lifecycle state.")
    if args.generation != node["generation"]:
        raise OrchestrationError("Late or mismatched worker generation report refused.")
    if node["phase"] in {"terminal-disappeared", "process-disappeared", "launch-failed"}:
        raise OrchestrationError("Worker runtime is no longer current.")
    node["phase"] = REPORT_PHASES[args.state]
    node["availability"] = "busy" if args.state == "running" else "idle"
    node["result"] = bounded_text(args.summary, "summary", MAX_RESULT, empty=True)
    node["updatedAt"] = now()
    store.write(state)
    return {"workerId": node["id"], "generation": node["generation"],
            "phase": node["phase"], "availability": node["availability"]}


def command_follow_up(args, store, cmux):
    state = store.read()
    actor = authorize(state, args.actor_id, args.token)
    target = ensure_owned(state, actor, args.worker_id, direct=True)
    refresh_node(cmux, actor)
    refresh_node(cmux, target)
    if actor["phase"] in {"terminal-disappeared", "process-disappeared"}:
        store.write(state)
        raise OrchestrationError("Actor surface or process is no longer valid.")
    if target["availability"] != "idle" or target["phase"] not in {
        "reported-blocked", "reported-completed", "reported-failed"
    }:
        store.write(state)
        raise OrchestrationError("Worker is not explicitly reported idle and available for follow-up.")
    if not process_matches(target):
        target["phase"], target["availability"], target["updatedAt"] = "process-disappeared", "unavailable", now()
        store.write(state)
        raise OrchestrationError("Worker process identity is stale; no input was sent.")
    prompt = bounded_text(args.task, "task", MAX_TASK)
    target["generation"] += 1
    target["task"], target["result"] = prompt, None
    target["phase"], target["availability"], target["updatedAt"] = "process-running", "busy", now()
    store.write(state)
    try:
        cmux.follow_up(
            target["workspaceId"], target["surfaceId"], prompt + report_instruction(target)
        )
    except Exception:
        target["phase"], target["availability"], target["updatedAt"] = (
            "delivery-failed", "idle", now()
        )
        store.write(state)
        raise
    return {"workerId": target["id"], "sessionId": target["copilotSessionId"],
            "surfaceId": target["surfaceId"], "generation": target["generation"]}


def command_status(args, store, cmux):
    state = store.read()
    actor = authorize(state, args.actor_id, args.token)
    targets = descendants(state, actor)
    if args.worker_id:
        targets = [ensure_owned(state, actor, args.worker_id)]
    for node in targets:
        refresh_node(cmux, node)
        if node["phase"] == "process-running":
            try:
                updated = datetime.datetime.fromisoformat(node["updatedAt"].replace("Z", "+00:00"))
                if (datetime.datetime.now(datetime.timezone.utc) - updated).total_seconds() > STALE_SECONDS:
                    node["phase"] = "report-missing"
            except ValueError:
                node["phase"] = "report-missing"
    store.write(state)
    return {"runId": actor["runId"], "workers": [{
        "workerId": node["id"], "parentId": node["parentId"], "name": node["label"],
        "workspaceId": node["workspaceId"], "surfaceId": node["surfaceId"],
        "sessionId": node["copilotSessionId"], "generation": node["generation"],
        "phase": node["phase"], "availability": node["availability"],
        "result": node["result"],
    } for node in targets]}


def command_focus(args, store, cmux):
    state = store.read()
    actor = authorize(state, args.actor_id, args.token)
    target = ensure_owned(state, actor, args.worker_id)
    if target["role"] != "worker":
        raise OrchestrationError("Focus requires an owned worker.")
    refresh_node(cmux, actor)
    refresh_node(cmux, target)
    if target["phase"] == "terminal-disappeared":
        store.write(state)
        raise OrchestrationError("Worker surface is no longer current.")
    store.write(state)
    cmux.focus(target["workspaceId"], target["surfaceId"])
    return {"workerId": target["id"], "surfaceId": target["surfaceId"], "focused": True}


def parser():
    result = argparse.ArgumentParser(prog="cmux-maestro-orchestrator")
    commands = result.add_subparsers(dest="command", required=True)
    register = commands.add_parser("register")
    register.add_argument("--workspace", required=True)
    register.add_argument("--surface", required=True)
    register.add_argument("--name", default="Coordinator")
    spawn = commands.add_parser("spawn")
    for command in (spawn,):
        command.add_argument("--actor-id", required=True)
        command.add_argument("--token", required=True)
    spawn.add_argument("--name", required=True)
    spawn.add_argument("--task", required=True)
    spawn.add_argument("--cwd", required=True)
    runtime = commands.add_parser("runtime")
    runtime.add_argument("--worker-id", required=True)
    runtime.add_argument("--token", required=True)
    report = commands.add_parser("report")
    report.add_argument("--worker-id")
    report.add_argument("--token")
    report.add_argument("--generation", required=True, type=int)
    report.add_argument("--state", required=True, choices=sorted(REPORT_PHASES))
    report.add_argument("--summary", default="")
    for name in ("status", "focus", "follow-up"):
        command = commands.add_parser(name)
        command.add_argument("--actor-id", required=True)
        command.add_argument("--token", required=True)
        if name != "status":
            command.add_argument("--worker-id", required=True)
        else:
            command.add_argument("--worker-id")
        if name == "follow-up":
            command.add_argument("--task", required=True)
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        root = default_root()
        cmux = None if args.command in {"runtime", "report"} else Cmux()
        with Store(root) as store:
            if args.command == "register":
                output = command_register(args, store, cmux)
            elif args.command == "spawn":
                output = command_spawn(args, store, cmux)
            elif args.command == "runtime":
                output = command_runtime(args, store)
            elif args.command == "report":
                output = command_report(args, store)
            elif args.command == "follow-up":
                output = command_follow_up(args, store, cmux)
            elif args.command == "focus":
                output = command_focus(args, store, cmux)
            else:
                output = command_status(args, store, cmux)
        print(json.dumps({"ok": True, **output}, sort_keys=True))
        return 0
    except OrchestrationError as error:
        print(json.dumps({"ok": False, "error": str(error)}, sort_keys=True), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
