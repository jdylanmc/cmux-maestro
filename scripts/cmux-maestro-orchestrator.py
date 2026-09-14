#!/usr/bin/env python3
"""Bounded CMUX terminal-backed Copilot orchestration."""

import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import shlex
import stat
import subprocess
import sys
import threading
import time
import uuid

VERSION = 1
MAX_BYTES = 1_048_576
MAX_NODES = 128
MAX_DEPTH = 8
MAX_LIVE_WORKERS = 8
MAX_ARCHIVES = 32
MAX_LABEL = 100
MAX_TASK = 32_768
MAX_RESULT = 4_096
STALE_SECONDS = 600
HEARTBEAT_SECONDS = 15
STARTUP_SECONDS = 8
ARCHIVE_SECONDS = 5
REPORT_PHASES = {
    "blocked": "reported-blocked",
    "completed": "reported-completed",
    "failed": "reported-failed",
}
PROJECTED_PHASES = {
    "registered", "launching", "turn-queued", "turn-running",
    "reported-blocked", "reported-completed", "reported-failed",
    "report-missing", "turn-failed", "process-disappeared",
    "terminal-disappeared", "launch-failed", "startup-failed",
    "resource-retired",
}


class OrchestrationError(Exception):
    pass


def now_date():
    return datetime.datetime.now(datetime.timezone.utc)


def now():
    return now_date().isoformat().replace("+00:00", "Z")


def parse_date(value, field):
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, TypeError, AttributeError):
        raise OrchestrationError(f"{field} is invalid.")


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


def default_root():
    override = os.environ.get("CMUX_MAESTRO_ROOT")
    if override:
        if os.environ.get("CMUX_MAESTRO_TESTING") != "1":
            raise OrchestrationError("CMUX_MAESTRO_ROOT is test-only.")
        return Path(override)
    return Path.home() / "Library/Application Support/CMUXMaestroPreview/Orchestration"


def timeout(name, production):
    value = os.environ.get(name)
    if value is not None:
        if os.environ.get("CMUX_MAESTRO_TESTING") != "1":
            raise OrchestrationError(f"{name} is test-only.")
        try:
            return float(value)
        except ValueError:
            raise OrchestrationError(f"{name} is invalid.")
    return production


def shutil_which(name):
    for directory in os.environ.get("PATH", "/usr/bin:/bin").split(os.pathsep):
        candidate = Path(directory) / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


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
        resolved = candidate.resolve(strict=True)
        info = resolved.stat()
    except OSError:
        raise OrchestrationError(f"Required executable is unavailable: {candidate}")
    if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o022 or info.st_uid not in (0, os.getuid()):
        raise OrchestrationError(f"Refusing untrusted executable: {candidate}")
    if not os.access(resolved, os.X_OK):
        raise OrchestrationError(f"Required executable is not executable: {candidate}")
    return str(resolved)


def empty_state():
    return {
        "version": VERSION,
        "nodes": {},
        "archives": [],
        "retainedResources": [],
    }


def validate_state(state):
    if state.get("version") != VERSION or not isinstance(state.get("nodes"), dict):
        raise OrchestrationError("Control state version is unsupported.")
    state.setdefault("archives", [])
    state.setdefault("retainedResources", [])
    nodes = state["nodes"]
    if len(nodes) > MAX_NODES or len(state["archives"]) > MAX_ARCHIVES:
        raise OrchestrationError("Control state exceeds its retention limit.")
    if len(state["retainedResources"]) > MAX_NODES:
        raise OrchestrationError("Retained resources exceed their safe limit.")
    surfaces = set()
    roots_by_run = {}
    for identifier, node in nodes.items():
        if canonical_uuid(identifier, "stored node ID") != node.get("id"):
            raise OrchestrationError("Stored node identity is invalid.")
        for field in ("runId", "workspaceId"):
            canonical_uuid(node.get(field), f"stored {field}")
        surface = node.get("surfaceId")
        if surface is not None:
            canonical_uuid(surface, "stored surfaceId")
            if surface in surfaces:
                raise OrchestrationError("Stored active surfaces must be unique.")
            surfaces.add(surface)
        parent = node.get("parentId")
        if parent is not None:
            canonical_uuid(parent, "stored parent ID")
        role = node.get("role")
        if role not in {"coordinator", "worker"}:
            raise OrchestrationError("Stored node role is invalid.")
        if (role == "coordinator") != (parent is None):
            raise OrchestrationError("Stored coordinator ancestry is invalid.")
        if role == "coordinator":
            roots_by_run[node["runId"]] = roots_by_run.get(node["runId"], 0) + 1
        if not isinstance(node.get("generation"), int) or node["generation"] < 0:
            raise OrchestrationError("Stored generation is invalid.")
        if not isinstance(node.get("archiving", False), bool):
            raise OrchestrationError("Stored archive state is invalid.")
        created = parse_date(node.get("createdAt"), "stored creation time")
        updated = parse_date(node.get("updatedAt"), "stored update time")
        if created > updated or updated > now_date() + datetime.timedelta(minutes=5):
            raise OrchestrationError("Stored node timestamps are inconsistent.")
        phase, availability = node.get("phase"), node.get("availability")
        valid_lifecycle = (
            role == "coordinator" and phase == "registered" and availability == "active"
        ) or (
            role == "worker" and (
                (phase in {"launching", "turn-queued", "turn-running"} and availability == "busy")
                or (phase in {
                    "reported-blocked", "reported-completed", "reported-failed",
                    "report-missing", "turn-failed",
                } and availability == "idle")
                or (phase in {
                    "process-disappeared", "terminal-disappeared", "launch-failed",
                    "startup-failed", "resource-retired",
                } and availability == "unavailable")
            )
        )
        if not valid_lifecycle:
            raise OrchestrationError("Stored node lifecycle is invalid.")
    if any(count != 1 for count in roots_by_run.values()):
        raise OrchestrationError("Each stored run must have exactly one coordinator.")
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
    retained_ids = set()
    for resource in state["retainedResources"]:
        identifier = canonical_uuid(resource.get("surfaceId"), "retained surface ID")
        canonical_uuid(resource.get("workspaceId"), "retained workspace ID")
        if identifier in retained_ids or identifier in surfaces:
            raise OrchestrationError("Retained resource ownership is duplicated.")
        retained_ids.add(identifier)


class Store:
    def __init__(self, root, *, blocking=False):
        self.root = root
        self.blocking = blocking
        self.root_fd = None
        self.control_fd = None
        self.observer_fd = None
        self.lock_fd = None

    def __enter__(self):
        try:
            self._private_directory(self.root)
            self.root_fd = self._open_owned_directory(self.root)
            self.control_fd = self._ensure_child("control")
            self.observer_fd = self._ensure_child("observer")
            self.lock_fd = os.open(
                "state.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
                0o600, dir_fd=self.control_fd,
            )
            info = os.fstat(self.lock_fd)
            if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode):
                raise OrchestrationError("Control lock is not a private regular file.")
            operation = fcntl.LOCK_EX | (0 if self.blocking else fcntl.LOCK_NB)
            try:
                fcntl.flock(self.lock_fd, operation)
            except BlockingIOError:
                raise OrchestrationError("Another orchestration operation is active; retry.")
            return self
        except Exception:
            self._close()
            raise

    def __exit__(self, *_):
        if self.lock_fd is not None:
            fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
        self._close()

    def _close(self):
        for name in ("lock_fd", "observer_fd", "control_fd", "root_fd"):
            descriptor = getattr(self, name)
            if descriptor is not None:
                os.close(descriptor)
                setattr(self, name, None)

    @staticmethod
    def _private_directory(path):
        current = Path(path.anchor)
        for component in path.parts[1:]:
            current /= component
            try:
                info = current.lstat()
            except FileNotFoundError:
                current.mkdir(mode=0o700)
                info = current.lstat()
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                raise OrchestrationError(f"Unsafe state path: {current}")
        info = path.lstat()
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise OrchestrationError(f"State directory is not private: {path}")
        os.chmod(path, 0o700)

    @staticmethod
    def _open_owned_directory(path):
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        info = os.fstat(descriptor)
        if info.st_uid != os.getuid() or not stat.S_ISDIR(info.st_mode):
            os.close(descriptor)
            raise OrchestrationError(f"Unsafe state path: {path}")
        return descriptor

    def _ensure_child(self, name):
        try:
            os.mkdir(name, mode=0o700, dir_fd=self.root_fd)
        except FileExistsError:
            pass
        descriptor = os.open(
            name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.root_fd
        )
        info = os.fstat(descriptor)
        if info.st_uid != os.getuid() or not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o077:
            os.close(descriptor)
            raise OrchestrationError(f"State directory is not private: {name}")
        return descriptor

    def read(self):
        try:
            descriptor = os.open(
                "state.json", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self.control_fd
            )
        except FileNotFoundError:
            return empty_state()
        try:
            before = os.fstat(descriptor)
            if (
                not stat.S_ISREG(before.st_mode)
                or before.st_uid != os.getuid()
                or before.st_size <= 0
                or before.st_size > MAX_BYTES
            ):
                raise OrchestrationError("Control state is not a safe owned regular file.")
            payload = os.read(descriptor, MAX_BYTES + 1)
            after = os.fstat(descriptor)
            entry = os.stat(
                "state.json", dir_fd=self.control_fd, follow_symlinks=False
            )
            stamps = lambda value: (
                value.st_dev, value.st_ino, value.st_mtime_ns, value.st_size
            )
            if stamps(before) != stamps(after) or stamps(before) != stamps(entry):
                raise OrchestrationError("Control state changed while reading.")
        finally:
            os.close(descriptor)
        try:
            state = json.loads(payload)
        except (json.JSONDecodeError, UnicodeDecodeError):
            raise OrchestrationError("Control state is malformed.")
        self._normalize_candidate_state(state)
        validate_state(state)
        return state

    @staticmethod
    def _normalize_candidate_state(state):
        if not isinstance(state, dict) or not isinstance(state.get("nodes"), dict):
            return
        state.setdefault("archives", [])
        state.setdefault("retainedResources", [])
        for node in state["nodes"].values():
            candidate = "archiving" not in node and "hasStartedSession" not in node
            node.setdefault("archiving", False)
            node.setdefault("lastControlAt", node.get("updatedAt"))
            node.setdefault("pendingReport", None)
            node.setdefault("supervisor", None)
            node.setdefault("hasStartedSession", False)
            if candidate and node.get("role") == "worker":
                node["phase"] = "process-disappeared"
                node["availability"] = "unavailable"
                node["result"] = "Legacy worker requires explicit archive before reuse."

    def write(self, state):
        validate_state(state)
        encoded = json.dumps(state, sort_keys=True, separators=(",", ":")).encode() + b"\n"
        if len(encoded) > MAX_BYTES:
            raise OrchestrationError("Control state exceeds its safe limit.")
        self._atomic(self.control_fd, "state.json", encoded)
        self._atomic(self.observer_fd, "current.json", self._projection(state))

    def _projection(self, state):
        nodes = sorted(
            (
                node for node in state["nodes"].values()
                if node.get("surfaceId") is not None and node["phase"] in PROJECTED_PHASES
            ),
            key=lambda item: (item["createdAt"], item["id"]),
        )
        projected = [{
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
        } for item in nodes[:MAX_NODES]]
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
    def _atomic(directory, name, data):
        temporary = f".pending-{uuid.uuid4()}"
        descriptor = os.open(
            temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600, dir_fd=directory,
        )
        try:
            view = memoryview(data)
            while view:
                written = os.write(descriptor, view)
                if written <= 0:
                    raise OrchestrationError("Unable to write orchestration state.")
                view = view[written:]
            os.fsync(descriptor)
        except Exception:
            try:
                os.unlink(temporary, dir_fd=directory)
            except OSError:
                pass
            raise
        finally:
            os.close(descriptor)
        os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
        os.fsync(directory)


def mutate(root, operation, *, wait=1):
    deadline = time.monotonic() + wait
    while True:
        try:
            with Store(root) as store:
                state = store.read()
                result = operation(state)
                store.write(state)
                return result
        except OrchestrationError as error:
            if "operation is active" not in str(error) or time.monotonic() >= deadline:
                raise
            time.sleep(0.05)


def read_state(root, *, wait=1):
    deadline = time.monotonic() + wait
    while True:
        try:
            with Store(root) as store:
                return json.loads(json.dumps(store.read()))
        except OrchestrationError as error:
            if "operation is active" not in str(error) or time.monotonic() >= deadline:
                raise
            time.sleep(0.05)


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

    def surface_exists(self, workspace, surface):
        try:
            self.validate_surface(workspace, surface)
            return True
        except OrchestrationError:
            return False

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
            if surface in self.ids(listing, {"id", "surfaceid", "uuid"}):
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

    def start(self, workspace, surface, command):
        self.validate_surface(workspace, surface)
        self.run("send", "--workspace", workspace, "--surface", surface, "--", command)
        self.run("send-key", "--workspace", workspace, "--surface", surface, "enter")

    def rename(self, workspace, surface, label):
        self.run("rename-tab", "--workspace", workspace, "--surface", surface, "--", label)

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
            "--index", str(surfaces.index(surface)), "--focus", "true",
        )


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def authorize(state, actor_id, token, *, allow_archiving=False):
    actor_id = canonical_uuid(actor_id, "actor ID")
    actor = state["nodes"].get(actor_id)
    if not actor or not secrets.compare_digest(actor["tokenHash"], token_hash(token or "")):
        raise OrchestrationError("Actor identity or control token is invalid.")
    if actor.get("archiving") and not allow_archiving:
        raise OrchestrationError("The orchestration run is ending; retry archive instead.")
    return actor


def require_current_surface(workspace, surface):
    expected_workspace = os.environ.get("CMUX_WORKSPACE_ID")
    expected_surface = os.environ.get("CMUX_SURFACE_ID")
    if not expected_workspace or not expected_surface:
        raise OrchestrationError("Current CMUX workspace and surface environment IDs are required.")
    if (
        canonical_uuid(expected_workspace, "current workspace ID") != workspace
        or canonical_uuid(expected_surface, "current surface ID") != surface
    ):
        raise OrchestrationError("Registration must match the current caller CMUX surface.")


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
    allowed = target["parentId"] == actor["id"] if direct else target_id in {
        item["id"] for item in descendants(state, actor)
    }
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
    process = node.get("supervisor")
    return bool(process and process_start(process["pid"]) == process["start"])


def new_root(workspace, surface, pane, label):
    identifier, run_id, token = str(uuid.uuid4()), str(uuid.uuid4()), secrets.token_hex(32)
    timestamp = now()
    node = {
        "id": identifier, "runId": run_id, "parentId": None, "role": "coordinator",
        "label": label, "workspaceId": workspace, "surfaceId": surface, "paneId": pane,
        "copilotSessionId": None, "workingDirectory": None, "generation": 0,
        "phase": "registered", "availability": "active", "createdAt": timestamp,
        "updatedAt": timestamp, "lastControlAt": timestamp, "tokenHash": token_hash(token),
        "task": None, "result": None, "pendingReport": None, "supervisor": None,
        "archiving": False,
    }
    return node, token


def command_register(args, root, cmux):
    workspace = canonical_uuid(args.workspace, "workspace ID")
    surface = canonical_uuid(args.surface, "surface ID")
    require_current_surface(workspace, surface)
    label = sanitize_label(bounded_text(args.name, "name", MAX_LABEL))
    pane = cmux.validate_surface(workspace, surface)

    def register(state):
        if len(state["nodes"]) >= MAX_NODES:
            raise OrchestrationError("Orchestration node limit reached.")
        if any(node.get("surfaceId") == surface for node in state["nodes"].values()):
            raise OrchestrationError("This CMUX surface has a live registered owner.")
        node, token = new_root(workspace, surface, pane, label)
        state["nodes"][node["id"]] = node
        return {
            "coordinatorId": node["id"], "runId": node["runId"], "controlToken": token,
            "workspaceId": workspace, "surfaceId": surface,
        }
    return mutate(root, register)


def resource_observations(state, cmux, workspace):
    active = {}
    for node in state["nodes"].values():
        if node["role"] == "worker" and node["workspaceId"] == workspace:
            active[node["id"]] = {
                "surface": bool(node.get("surfaceId"))
                    and cmux.surface_exists(workspace, node["surfaceId"]),
                "process": process_matches(node),
            }
    retained_gone = {
        resource["surfaceId"] for resource in state["retainedResources"]
        if resource["workspaceId"] == workspace
        and not cmux.surface_exists(workspace, resource["surfaceId"])
    }
    return active, retained_gone


def command_spawn(args, root, cmux):
    task = bounded_text(args.task, "task", MAX_TASK)
    label = sanitize_label(bounded_text(args.name, "name", MAX_LABEL))
    try:
        cwd = Path(args.cwd).expanduser().resolve(strict=True)
    except OSError:
        raise OrchestrationError("Working directory does not exist.")
    if not cwd.is_dir():
        raise OrchestrationError("Working directory must be a directory.")
    snapshot = read_state(root)
    actor = authorize(snapshot, args.actor_id, args.token)
    pane = cmux.validate_surface(actor["workspaceId"], actor["surfaceId"])
    if actor["role"] == "worker" and not process_matches(actor):
        raise OrchestrationError("Actor worker supervisor identity is stale.")
    observations, retained_gone = resource_observations(snapshot, cmux, actor["workspaceId"])
    identifier, session_id, worker_token = (
        str(uuid.uuid4()), str(uuid.uuid4()), secrets.token_hex(32)
    )

    def reserve(state):
        current = authorize(state, args.actor_id, args.token)
        if (
            current["runId"], current["workspaceId"], current.get("surfaceId")
        ) != (actor["runId"], actor["workspaceId"], actor["surfaceId"]):
            raise OrchestrationError("Actor ownership changed during spawn.")
        for worker_id, observed in observations.items():
            node = state["nodes"].get(worker_id)
            if node and not observed["surface"] and not observed["process"]:
                node["phase"], node["availability"] = "resource-retired", "unavailable"
                node["updatedAt"] = now()
        state["retainedResources"] = [
            resource for resource in state["retainedResources"]
            if resource["surfaceId"] not in retained_gone
        ]
        live = sum(
            1 for node in state["nodes"].values()
            if node["role"] == "worker" and node["workspaceId"] == current["workspaceId"]
            and node["phase"] != "resource-retired"
        ) + sum(
            1 for resource in state["retainedResources"]
            if resource["workspaceId"] == current["workspaceId"]
        )
        if live >= MAX_LIVE_WORKERS:
            raise OrchestrationError(
                "Live worker resource limit reached; reuse a reported worker or close a retired tab."
            )
        depth = 0
        cursor = current
        while cursor["parentId"] is not None:
            depth += 1
            cursor = state["nodes"][cursor["parentId"]]
        if depth + 1 > MAX_DEPTH:
            raise OrchestrationError("Maximum worker nesting depth reached.")
        if len(state["nodes"]) >= MAX_NODES:
            raise OrchestrationError("Orchestration node limit reached.")
        timestamp = now()
        state["nodes"][identifier] = {
            "id": identifier, "runId": current["runId"], "parentId": current["id"],
            "role": "worker", "label": label, "workspaceId": current["workspaceId"],
            "surfaceId": None, "paneId": pane, "copilotSessionId": session_id,
            "workingDirectory": str(cwd), "generation": 1, "phase": "launching",
            "availability": "busy", "createdAt": timestamp, "updatedAt": timestamp,
            "lastControlAt": timestamp, "tokenHash": token_hash(worker_token),
            "task": task, "result": None, "pendingReport": None, "supervisor": None,
            "archiving": False, "hasStartedSession": False,
        }
        current["lastControlAt"] = timestamp
    mutate(root, reserve)
    try:
        surface = cmux.create_surface(actor["workspaceId"], pane, str(cwd))
        confirmed_pane = cmux.validate_surface(actor["workspaceId"], surface)

        def attach(state):
            node = state["nodes"].get(identifier)
            if not node or node["phase"] != "launching" or node["surfaceId"] is not None:
                raise OrchestrationError("Launch reservation is no longer current.")
            if any(item.get("surfaceId") == surface for item in state["nodes"].values()):
                raise OrchestrationError("New worker surface already has an owner.")
            node["surfaceId"], node["paneId"], node["updatedAt"] = surface, confirmed_pane, now()
        mutate(root, attach)
        cmux.rename(actor["workspaceId"], surface, label)
        bootstrap = " ".join([
            shlex.quote(str(Path(__file__).resolve())), "runtime",
            "--worker-id", shlex.quote(identifier), "--token", shlex.quote(worker_token),
        ])
        cmux.start(actor["workspaceId"], surface, bootstrap)
    except Exception:
        def failed(state):
            node = state["nodes"].get(identifier)
            if node and node["phase"] == "launching":
                node["phase"], node["availability"], node["updatedAt"] = (
                    "launch-failed", "unavailable", now()
                )
        mutate(root, failed, wait=1)
        raise
    deadline = time.monotonic() + timeout("CMUX_MAESTRO_STARTUP_SECONDS", STARTUP_SECONDS)
    while time.monotonic() < deadline:
        state = read_state(root, wait=1)
        node = state["nodes"].get(identifier)
        if node and node.get("supervisor") and node["phase"] != "launching":
            return {
                "workerId": identifier, "sessionId": session_id, "surfaceId": surface,
                "workspaceId": actor["workspaceId"], "generation": 1,
                "phase": node["phase"],
            }
        time.sleep(0.05)

    def startup_failed(state):
        node = state["nodes"].get(identifier)
        if node and node["phase"] == "launching":
            node["phase"], node["availability"], node["updatedAt"] = (
                "startup-failed", "unavailable", now()
            )
    mutate(root, startup_failed, wait=1)
    raise OrchestrationError("Worker supervisor did not acknowledge startup within the bound.")


def assistant_text(event):
    if event.get("type") != "assistant.message":
        return None
    for container in (event, event.get("data"), event.get("message")):
        if not isinstance(container, dict):
            continue
        for key in ("content", "text", "message"):
            value = container.get(key)
            if isinstance(value, str) and value.strip():
                return value[:MAX_RESULT]
    return None


def report_instruction(node):
    command = shlex.quote(str(Path(__file__).resolve())) + " report"
    return (
        f"\n\nCMUX Maestro worker contract: bounded generation {node['generation']} for "
        f"worker {node['id']}. Do not spawn except through the installed "
        "cmux-maestro-orchestrate skill. Before finishing this turn, run "
        f"`{command} --generation {node['generation']} --state completed "
        "--summary '<brief result>'`; use blocked or failed when accurate. "
        "The report is pending until the supervisor verifies this exact Copilot turn boundary. "
        "A normal answer or zero exit is not task success."
    )


def run_copilot_turn(root, worker_id, token, node):
    copilot = trusted_executable("CMUX_MAESTRO_COPILOT", "copilot")
    prompt = node["task"] + report_instruction(node)
    arguments = [copilot, "--no-auto-update", "-p", prompt, "--output-format", "json"]
    if node.get("hasStartedSession"):
        arguments.extend(["--resume", node["copilotSessionId"]])
    else:
        arguments.extend([
            "--session-id", node["copilotSessionId"], "--name", node["label"],
        ])
    arguments.extend(["-C", node["workingDirectory"]])
    environment = os.environ.copy()
    environment.update({
        "CMUX_MAESTRO_WORKER_ID": worker_id,
        "CMUX_MAESTRO_CONTROL_TOKEN": token,
        "CMUX_MAESTRO_RUN_ID": node["runId"],
        "CMUX_MAESTRO_GENERATION": str(node["generation"]),
        "CMUX_MAESTRO_ORCHESTRATOR": str(Path(__file__).resolve()),
    })
    final = None
    malformed = False
    stderr_chunks = []
    stderr_size = [0]
    try:
        process = subprocess.Popen(
            arguments, cwd=node["workingDirectory"], env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
    except OSError as error:
        return False, f"Copilot launch failed: {error}"
    assert process.stdout is not None and process.stderr is not None
    def drain_stderr():
        for chunk in iter(lambda: process.stderr.read(1024), ""):
            sys.stderr.write(chunk)
            sys.stderr.flush()
            remaining = MAX_RESULT - stderr_size[0]
            if remaining > 0:
                kept = chunk[:remaining]
                stderr_chunks.append(kept)
                stderr_size[0] += len(kept)
    stderr_reader = threading.Thread(target=drain_stderr, daemon=True)
    stderr_reader.start()
    for line in process.stdout:
        if len(line.encode("utf-8")) > MAX_BYTES:
            malformed = True
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            malformed = True
            continue
        if event.get("type") == "result":
            final = event
        text = assistant_text(event)
        if text:
            print(text, flush=True)
    return_code = process.wait()
    stderr_reader.join(timeout=2)
    valid = (
        not malformed
        and isinstance(final, dict)
        and final.get("sessionId") == node["copilotSessionId"]
        and isinstance(final.get("exitCode"), int)
        and final["exitCode"] == return_code
    )
    if not valid:
        diagnostic = " ".join("".join(stderr_chunks).split())
        suffix = f" Copilot error: {diagnostic[:512]}" if diagnostic else ""
        return False, "Copilot did not produce a valid exact-session turn boundary." + suffix
    return True, None


def command_runtime(args, root):
    worker_id = canonical_uuid(args.worker_id, "worker ID")
    pid = os.getpid()
    start = process_start(pid)
    if not start:
        raise OrchestrationError("Cannot establish supervisor process identity.")

    def started(state):
        node = authorize(state, worker_id, args.token)
        if node["role"] != "worker" or node["phase"] != "launching" or not node["surfaceId"]:
            raise OrchestrationError("Worker runtime is not in the launch phase.")
        node["supervisor"] = {"pid": pid, "start": start}
        node["phase"], node["availability"], node["updatedAt"] = "turn-queued", "busy", now()
    mutate(root, started, wait=2)
    def stop_supervisor(_signum, _frame):
        raise SystemExit(143)
    signal.signal(signal.SIGTERM, stop_supervisor)
    signal.signal(signal.SIGHUP, stop_supervisor)
    last_heartbeat = 0.0
    try:
        while True:
            state = read_state(root, wait=2)
            node = state["nodes"].get(worker_id)
            if not node or node.get("archiving"):
                return {"workerId": worker_id, "retired": True}
            if not secrets.compare_digest(node["tokenHash"], token_hash(args.token)):
                raise OrchestrationError("Worker control token was replaced.")
            if node["phase"] == "turn-queued":
                generation = node["generation"]

                def claim(state):
                    current = state["nodes"].get(worker_id)
                    if (
                        not current or current["generation"] != generation
                        or current["phase"] != "turn-queued"
                        or current.get("supervisor") != {"pid": pid, "start": start}
                    ):
                        raise OrchestrationError("Queued worker turn is no longer current.")
                    current["phase"], current["availability"] = "turn-running", "busy"
                    current["pendingReport"], current["updatedAt"] = None, now()
                    return json.loads(json.dumps(current))
                claimed = mutate(root, claim, wait=2)
                valid, diagnostic = run_copilot_turn(root, worker_id, args.token, claimed)

                def finish(state):
                    current = state["nodes"].get(worker_id)
                    if not current or current["generation"] != generation:
                        return
                    report = current.get("pendingReport")
                    if valid and report and report.get("generation") == generation:
                        current["phase"] = REPORT_PHASES[report["state"]]
                        current["result"] = report["summary"]
                        current["availability"] = "idle"
                        current["hasStartedSession"] = True
                    elif valid:
                        current["phase"], current["availability"] = "report-missing", "idle"
                        current["hasStartedSession"] = True
                    else:
                        current["phase"], current["availability"] = "turn-failed", "idle"
                        current["result"] = diagnostic
                    current["pendingReport"] = None
                    current["updatedAt"] = now()
                mutate(root, finish, wait=2)
                last_heartbeat = time.monotonic()
                continue
            if time.monotonic() - last_heartbeat >= HEARTBEAT_SECONDS:
                def heartbeat(state):
                    current = state["nodes"].get(worker_id)
                    if current and current.get("supervisor") == {"pid": pid, "start": start}:
                        current["updatedAt"] = now()
                mutate(root, heartbeat, wait=2)
                last_heartbeat = time.monotonic()
            time.sleep(0.1)
    finally:
        def disappeared(state):
            node = state["nodes"].get(worker_id)
            if (
                node and not node.get("archiving")
                and node.get("supervisor") == {"pid": pid, "start": start}
            ):
                node["phase"], node["availability"], node["updatedAt"] = (
                    "process-disappeared", "unavailable", now()
                )
        try:
            mutate(root, disappeared, wait=2)
        except OrchestrationError as error:
            print(f"CMUX Maestro could not record supervisor exit: {error}", file=sys.stderr)


def command_report(args, root):
    actor_id = args.worker_id or os.environ.get("CMUX_MAESTRO_WORKER_ID")
    token = args.token or os.environ.get("CMUX_MAESTRO_CONTROL_TOKEN")

    def report(state):
        node = authorize(state, actor_id, token, allow_archiving=True)
        if node["role"] != "worker":
            raise OrchestrationError("Only workers can report lifecycle state.")
        if args.generation != node["generation"]:
            raise OrchestrationError("Late or mismatched worker generation report refused.")
        if node["phase"] != "turn-running" or not process_matches(node):
            raise OrchestrationError("Worker turn is not currently supervised.")
        node["pendingReport"] = {
            "generation": args.generation,
            "state": args.state,
            "summary": bounded_text(args.summary, "summary", MAX_RESULT, empty=True),
        }
        node["updatedAt"] = now()
        return {
            "workerId": node["id"], "generation": node["generation"],
            "accepted": True, "availability": "pending-turn-boundary",
        }
    return mutate(root, report, wait=2)


def command_follow_up(args, root, cmux):
    prompt = bounded_text(args.task, "task", MAX_TASK)
    snapshot = read_state(root)
    actor = authorize(snapshot, args.actor_id, args.token)
    target = ensure_owned(snapshot, actor, args.worker_id, direct=True)
    cmux.validate_surface(target["workspaceId"], target["surfaceId"])
    if not process_matches(target):
        raise OrchestrationError("Worker supervisor identity is stale; no task was queued.")
    expected = (target["generation"], target["phase"], target.get("supervisor"))

    def queue(state):
        current_actor = authorize(state, args.actor_id, args.token)
        current = ensure_owned(state, current_actor, args.worker_id, direct=True)
        if (current["generation"], current["phase"], current.get("supervisor")) != expected:
            raise OrchestrationError("Worker state changed before follow-up could be queued.")
        if current["availability"] != "idle" or current["phase"] not in REPORT_PHASES.values():
            raise OrchestrationError(
                "Worker lacks an explicit report at a verified idle turn boundary."
            )
        if not process_matches(current):
            raise OrchestrationError("Worker supervisor identity is stale; no task was queued.")
        current["generation"] += 1
        current["task"], current["result"], current["pendingReport"] = prompt, None, None
        current["phase"], current["availability"], current["updatedAt"] = (
            "turn-queued", "busy", now()
        )
        current_actor["lastControlAt"] = now()
        return {
            "workerId": current["id"], "sessionId": current["copilotSessionId"],
            "surfaceId": current["surfaceId"], "generation": current["generation"],
            "queued": True,
        }
    return mutate(root, queue)


def command_status(args, root, cmux):
    snapshot = read_state(root)
    actor = authorize(snapshot, args.actor_id, args.token)
    targets = descendants(snapshot, actor)
    if args.worker_id:
        targets = [ensure_owned(snapshot, actor, args.worker_id)]
    observations = {
        node["id"]: (
            cmux.surface_exists(node["workspaceId"], node["surfaceId"])
            if node.get("surfaceId") else False,
            process_matches(node) if node["role"] == "worker" else True,
        ) for node in targets
    }

    def refresh(state):
        current_actor = authorize(state, args.actor_id, args.token)
        current_actor["lastControlAt"] = now()
        current_targets = descendants(state, current_actor)
        if args.worker_id:
            current_targets = [ensure_owned(state, current_actor, args.worker_id)]
        for node in current_targets:
            surface, process = observations.get(node["id"], (False, False))
            if node.get("surfaceId") and not surface:
                node["phase"], node["availability"], node["updatedAt"] = (
                    "terminal-disappeared", "unavailable", now()
                )
            elif node["role"] == "worker" and not process:
                node["phase"], node["availability"], node["updatedAt"] = (
                    "process-disappeared", "unavailable", now()
                )
        return {"runId": current_actor["runId"], "workers": [{
            "workerId": node["id"], "parentId": node["parentId"], "name": node["label"],
            "workspaceId": node["workspaceId"], "surfaceId": node["surfaceId"],
            "sessionId": node["copilotSessionId"], "generation": node["generation"],
            "phase": node["phase"], "availability": node["availability"],
            "result": node["result"],
        } for node in current_targets]}
    return mutate(root, refresh)


def command_focus(args, root, cmux):
    snapshot = read_state(root)
    actor = authorize(snapshot, args.actor_id, args.token)
    target = ensure_owned(snapshot, actor, args.worker_id)
    if target["role"] != "worker":
        raise OrchestrationError("Focus requires an owned worker.")
    cmux.focus(target["workspaceId"], target["surfaceId"])

    def touched(state):
        current = authorize(state, args.actor_id, args.token)
        ensure_owned(state, current, args.worker_id)
        current["lastControlAt"] = now()
    mutate(root, touched)
    return {"workerId": target["id"], "surfaceId": target["surfaceId"], "focused": True}


def archive_summary(state, run_id):
    nodes = [node for node in state["nodes"].values() if node["runId"] == run_id]
    root = next(node for node in nodes if node["role"] == "coordinator")
    return {
        "runId": run_id, "coordinatorLabel": root["label"],
        "nodeCount": len(nodes), "archivedAt": now(),
    }


def command_archive(args, root, cmux):
    snapshot = read_state(root)
    actor = authorize(snapshot, args.actor_id, args.token, allow_archiving=True)
    if actor["role"] != "coordinator":
        raise OrchestrationError("Only a coordinator can archive its run.")
    cmux.validate_surface(actor["workspaceId"], actor["surfaceId"])
    run_id = actor["runId"]

    def begin(state):
        current = authorize(state, args.actor_id, args.token, allow_archiving=True)
        for node in state["nodes"].values():
            if node["runId"] == current["runId"]:
                node["archiving"] = True
                node["updatedAt"] = now()
    mutate(root, begin)
    deadline = time.monotonic() + timeout("CMUX_MAESTRO_ARCHIVE_SECONDS", ARCHIVE_SECONDS)
    while time.monotonic() < deadline:
        state = read_state(root, wait=1)
        workers = [
            node for node in state["nodes"].values()
            if node["runId"] == run_id and node["role"] == "worker"
        ]
        if not any(process_matches(node) for node in workers):
            break
        time.sleep(0.05)
    else:
        raise OrchestrationError(
            "Run archive is pending because a worker turn or supervisor remains live; retry."
        )

    def finish(state):
        nodes = [node for node in state["nodes"].values() if node["runId"] == run_id]
        if not nodes or any(node["role"] == "worker" and process_matches(node) for node in nodes):
            raise OrchestrationError("Run archive cannot finish while a supervisor is live.")
        state["archives"].append(archive_summary(state, run_id))
        state["archives"] = state["archives"][-MAX_ARCHIVES:]
        for node in nodes:
            if node["role"] == "worker" and node.get("surfaceId"):
                state["retainedResources"].append({
                    "runId": run_id, "workspaceId": node["workspaceId"],
                    "surfaceId": node["surfaceId"], "archivedAt": now(),
                })
            del state["nodes"][node["id"]]
        if len(state["retainedResources"]) > MAX_NODES:
            raise OrchestrationError(
                "Retained live terminal limit reached; close archived worker tabs first."
            )
        return {"runId": run_id, "archived": True}
    return mutate(root, finish, wait=1)


def command_recover(args, root, cmux):
    workspace = canonical_uuid(args.workspace, "workspace ID")
    surface = canonical_uuid(args.surface, "surface ID")
    require_current_surface(workspace, surface)
    pane = cmux.validate_surface(workspace, surface)
    label = sanitize_label(bounded_text(args.name, "name", MAX_LABEL))
    snapshot = read_state(root)
    roots = [
        node for node in snapshot["nodes"].values()
        if node["role"] == "coordinator" and node["workspaceId"] == workspace
        and node["surfaceId"] == surface
    ]
    if len(roots) != 1:
        raise OrchestrationError("Recovery requires one exact existing coordinator registration.")
    previous = roots[0]
    age = (now_date() - parse_date(previous["lastControlAt"], "last control time")).total_seconds()
    if age <= STALE_SECONDS:
        raise OrchestrationError("The existing coordinator ownership is still current.")
    run_nodes = [
        node for node in snapshot["nodes"].values() if node["runId"] == previous["runId"]
    ]
    for node in run_nodes:
        if node["role"] == "worker" and (
            process_matches(node) or (
                node.get("surfaceId")
                and cmux.surface_exists(node["workspaceId"], node["surfaceId"])
            )
        ):
            raise OrchestrationError("Stale recovery refuses competing live worker ownership.")

    def recover(state):
        current = state["nodes"].get(previous["id"])
        if not current or current["runId"] != previous["runId"]:
            raise OrchestrationError("Coordinator ownership changed during recovery.")
        current_age = (
            now_date() - parse_date(current["lastControlAt"], "last control time")
        ).total_seconds()
        if current_age <= STALE_SECONDS:
            raise OrchestrationError("The existing coordinator ownership became current.")
        state["archives"].append(archive_summary(state, current["runId"]))
        state["archives"] = state["archives"][-MAX_ARCHIVES:]
        for node in list(state["nodes"].values()):
            if node["runId"] == current["runId"]:
                del state["nodes"][node["id"]]
        node, token = new_root(workspace, surface, pane, label)
        state["nodes"][node["id"]] = node
        return {
            "coordinatorId": node["id"], "runId": node["runId"],
            "controlToken": token, "recoveredRunId": previous["runId"],
            "workspaceId": workspace, "surfaceId": surface,
        }
    return mutate(root, recover)


def parser():
    result = argparse.ArgumentParser(prog="cmux-maestro-orchestrator")
    commands = result.add_subparsers(dest="command", required=True)
    for name in ("register", "recover"):
        command = commands.add_parser(name)
        command.add_argument("--workspace", required=True)
        command.add_argument("--surface", required=True)
        command.add_argument("--name", default="Coordinator")
    spawn = commands.add_parser("spawn")
    spawn.add_argument("--actor-id", required=True)
    spawn.add_argument("--token", required=True)
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
    for name in ("status", "focus", "follow-up", "archive"):
        command = commands.add_parser(name)
        command.add_argument("--actor-id", required=True)
        command.add_argument("--token", required=True)
        if name in {"focus", "follow-up"}:
            command.add_argument("--worker-id", required=True)
        elif name == "status":
            command.add_argument("--worker-id")
        if name == "follow-up":
            command.add_argument("--task", required=True)
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        root = default_root()
        cmux = None if args.command in {"runtime", "report"} else Cmux()
        if args.command == "register":
            output = command_register(args, root, cmux)
        elif args.command == "recover":
            output = command_recover(args, root, cmux)
        elif args.command == "spawn":
            output = command_spawn(args, root, cmux)
        elif args.command == "runtime":
            output = command_runtime(args, root)
        elif args.command == "report":
            output = command_report(args, root)
        elif args.command == "follow-up":
            output = command_follow_up(args, root, cmux)
        elif args.command == "focus":
            output = command_focus(args, root, cmux)
        elif args.command == "archive":
            output = command_archive(args, root, cmux)
        else:
            output = command_status(args, root, cmux)
        print(json.dumps({"ok": True, **output}, sort_keys=True))
        return 0
    except OrchestrationError as error:
        print(json.dumps({"ok": False, "error": str(error)}, sort_keys=True), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
