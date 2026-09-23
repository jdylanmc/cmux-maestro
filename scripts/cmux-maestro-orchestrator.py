#!/usr/bin/env python3
"""Bounded CMUX terminal-backed Copilot orchestration."""

import argparse
import codecs
import datetime
import fcntl
import functools
import hashlib
import json
import os
import re
import runpy
from pathlib import Path
import secrets
import selectors
import signal
import shlex
import stat
import subprocess
import sys
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
MAX_POLICY_RULE = 512
MAX_POLICY_RULES = 16
MAX_REPORT_MESSAGE = 8_192
MAX_DISPLAY_METADATA = 120
MAX_LAUNCH_PATH = 16_384
GIT_EVIDENCE_STATUSES = {"verified", "unavailable"}
MAX_GIT_COUNT = 1_000_000_000
GIT_CHANGE_FIELDS = {"files", "insertions", "deletions", "untrackedFiles", "binaryFiles"}
NERD_FONTS_VERSION = "3.5.1"
GLYPH_CATALOG_SHA256 = "d2fa6615a38eb527462cb71ff17aa44b1d6453d437ed263ab8d5b458393669e8"
ICON_COLORS = ("theme", "green", "teal", "blue", "purple", "pink", "red", "gray")
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
    "permission-denied",
    "terminal-disappeared", "launch-failed", "startup-failed",
    "resource-retired",
}
REPORT_PROTOCOL = "cmux-maestro.worker-report"
REPORT_KEYS = {
    "protocol", "version", "workerId", "generation", "state", "summary",
}


class OrchestrationError(Exception):
    pass


class CoordinatorLaunchError(OrchestrationError):
    def __init__(self, message, receipt):
        super().__init__(message)
        self.receipt = receipt


class SessionLaunchError(OrchestrationError):
    def __init__(self, message, surface):
        super().__init__(message)
        self.surface = surface


def launch_failure_message(error):
    if isinstance(error, OSError):
        # OS messages can contain private paths or subprocess inputs.
        return f"{type(error).__name__} during launch storage or execution (errno {error.errno})."
    return str(error)[:512]


def delivery_proof_api():
    path = Path(__file__).resolve().parent / "delivery-proof" / "fixture.py"
    if not path.is_file():
        raise OrchestrationError("Delivery proof is available only from its isolated source checkout.")
    return runpy.run_path(str(path))


def private_message_directory(path):
    if not path.is_absolute() or path.resolve() != path:
        raise OrchestrationError("Messaging requires a canonical private directory.")
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise OrchestrationError("Messaging directory is not private.")


def message_json(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or not 0 < info.st_size <= 8192):
            raise OrchestrationError("Messaging configuration is not a private bounded file.")
        data = stream.read(8193)
        if len(data) > 8192:
            raise OrchestrationError("Messaging configuration exceeds its size bound.")
        return json.loads(data)


def messaging_configuration(root):
    config = root / "bin/messaging.json"
    try:
        value = message_json(config)
        if (not isinstance(value, dict)
                or set(value) not in ({"version", "routes", "extension"},
                                     {"version", "routes", "extension", "pluginDirectory"})
                or type(value["version"]) is not int or value["version"] != 1
                or not isinstance(value["routes"], str) or not isinstance(value["extension"], str)):
            raise OrchestrationError("Messaging configuration is invalid.")
        routes = Path(value["routes"])
        private_message_directory(routes)
        extension = Path(value["extension"])
        private_message_directory(extension)
        if len(os.fsencode(routes / ("0" * 16 + ".sock"))) > 100:
            raise OrchestrationError("Messaging socket path is too long.")
        for name in ("extension.mjs", "adapter.mjs"):
            descriptor = os.open(extension / name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                info = os.fstat(descriptor)
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                        or info.st_mode & 0o077 or not 0 < info.st_size <= 65_536):
                    raise OrchestrationError("Installed messaging adapter is unavailable.")
            finally:
                os.close(descriptor)
        # Ignore the obsolete pluginDirectory field; guide discovery is independent.
        # Keep the three-field node contract compatible with already-running controllers.
        return {key: value[key] for key in ("version", "routes", "extension")}
    except FileNotFoundError:
        # Source/proof and pre-feature controller installs remain usable; an
        # installed current controller must not silently create unwired workers.
        if not config.exists() and Path(__file__).name.endswith(".py"):
            return None
        raise OrchestrationError("Messaging is not installed; enable Maestro integration.")
    except (OSError, ValueError) as error:
        raise OrchestrationError("Messaging is unavailable; enable Maestro integration.") from error


def message_peer(node):
    return hashlib.sha256(
        f'{node["copilotSessionId"]}:{node["generation"]}'.encode()
    ).hexdigest()[:16]


def bind_messaging(node):
    routes = Path(node["messaging"]["routes"])
    private_message_directory(routes)
    peer = message_peer(node)
    if len(os.fsencode(routes / f"{peer}.sock")) > 100:
        raise OrchestrationError("Messaging socket path is too long.")
    binding = {
        "peer": peer, "nodeId": node["id"], "name": node["label"],
        "workspaceId": node["workspaceId"], "sessionId": node["copilotSessionId"],
        "generation": node["generation"], "capability": secrets.token_hex(32),
    }
    descriptor = os.open(routes / f"{peer}.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(binding, stream)


def retire_messaging(node):
    if not node.get("messaging"):
        return
    routes = Path(node["messaging"]["routes"])
    try:
        private_message_directory(routes)
    except FileNotFoundError:
        return
    peer = message_peer(node)
    try:
        binding = message_json(routes / f"{peer}.json")
    except FileNotFoundError:
        return
    expected = (node["id"], node["workspaceId"], node["copilotSessionId"], node["generation"])
    if (not isinstance(binding, dict) or binding.get("peer") != peer
            or tuple(binding.get(key) for key in ("nodeId", "workspaceId", "sessionId", "generation")) != expected):
        raise OrchestrationError("Messaging identity changed; refusing cleanup.")
    (routes / f"{peer}.json").unlink()
    # Only after the exact owned provider has exited. Never unlink a live route
    # to recover a launch; unique session/generation endpoints are single-use.
    endpoint = routes / f"{peer}.sock"
    try:
        info = endpoint.lstat()
        if stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid():
            endpoint.unlink()
    except FileNotFoundError:
        pass


@functools.lru_cache(maxsize=1)
def glyph_catalog():
    directory = Path(__file__).resolve().parent / "NerdFonts"
    if not directory.is_dir():
        directory = Path(__file__).resolve().parents[1] / "Resources" / "NerdFonts"
    try:
        with (directory / "glyphnames.json").open("rb") as stream:
            data = stream.read(2_097_153)
        if len(data) > 2_097_152 or hashlib.sha256(data).hexdigest() != GLYPH_CATALOG_SHA256:
            raise OrchestrationError("The pinned Nerd Fonts catalog is invalid; refresh Maestro integration.")
        raw = json.loads(data)
        if raw.pop("METADATA")["version"] != NERD_FONTS_VERSION:
            raise OrchestrationError("The Nerd Fonts catalog version does not match this controller.")
        raw.pop("cod-blank", None)
        with (directory / "presets.json").open("rb") as stream:
            preset_data = stream.read(32_769)
        if len(preset_data) > 32_768:
            raise OrchestrationError("The icon preset catalog exceeds its size limit.")
        presets = json.loads(preset_data)
        if not isinstance(presets, list) or len(presets) > 64:
            raise OrchestrationError("The icon preset catalog is invalid.")
        seen = set()
        for preset in presets:
            identifier = preset["id"]
            if (
                not isinstance(identifier, str) or not re.fullmatch(r"[a-z0-9_-]{1,128}", identifier)
                or identifier in seen or preset["glyph"] not in raw
                or preset["color"] not in ICON_COLORS
            ):
                raise OrchestrationError("The icon preset catalog is invalid.")
            seen.add(identifier)
        return raw, presets
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise OrchestrationError("Nerd Fonts resources are unavailable; refresh Maestro integration.") from error


def resolve_icon(value):
    if not isinstance(value, str) or len(value) > 128:
        raise OrchestrationError("Choose a Nerd Font glyph name from the catalog.")
    name = value.lower()
    if name.startswith("nf-"):
        name = name[3:]
    glyphs, presets = glyph_catalog()
    aliases = {item["id"]: item["glyph"] for item in presets}
    name = aliases.get(name, name)
    if name not in glyphs:
        raise OrchestrationError("Choose a drawable glyph from bundled Nerd Fonts 3.5.1; use icons --search.")
    return name


def validate_launch_settings(value):
    if (not isinstance(value, dict) or set(value) - {"version", "copilotAccount", "model"}
            or type(value.get("version")) is not int or value["version"] != 1):
        raise OrchestrationError("Worker launch settings are invalid.")
    for key, pattern in (
        ("copilotAccount", r"[A-Za-z0-9][A-Za-z0-9_-]{0,99}"),
        ("model", r"[A-Za-z0-9][A-Za-z0-9_.:/-]{0,127}"),
    ):
        candidate = value.get(key)
        if candidate is not None and (not isinstance(candidate, str) or re.fullmatch(pattern, candidate) is None):
            raise OrchestrationError(f"Worker {key} setting is invalid.")
    return value


def worker_launch_settings(root):
    data = with_store(root, lambda store: store._read_regular(
        "worker-settings.json", 8192, private=True, directory=store.root_fd
    ))
    if data is None:
        return {"version": 1}
    try:
        return validate_launch_settings(json.loads(data))
    except (ValueError, TypeError) as error:
        raise OrchestrationError("Worker launch settings are unreadable; no default account was substituted.") from error


def command_launch_settings(root):
    settings = worker_launch_settings(root)
    account_pinned = settings.get("copilotAccount") is not None
    model_pinned = settings.get("model") is not None
    account_available = False
    if account_pinned:
        try:
            resolve_copilot_token(settings["copilotAccount"])
            account_available = True
        except OrchestrationError:
            account_available = False
    try:
        messaging_installed = messaging_configuration(root) is not None
    except OrchestrationError:
        messaging_installed = False
    return {
        "accountPinned": account_pinned,
        "modelPinned": model_pinned,
        "accountAvailable": account_available,
        "ready": account_pinned and model_pinned and account_available,
        "messagingInstalled": messaging_installed,
    }


def github_cli():
    for candidate in ("gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh"):
        if candidate != "gh" and not Path(candidate).is_file():
            continue
        if candidate == "gh" and not shutil_which(candidate) and not os.environ.get("CMUX_MAESTRO_GH"):
            continue
        return trusted_executable("CMUX_MAESTRO_GH", candidate)
    raise OrchestrationError("GitHub CLI is unavailable; install it to choose a pinned Copilot subscription.")


def github_lookup_environment():
    environment = os.environ.copy()
    for key in ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "COPILOT_GITHUB_TOKEN"):
        environment.pop(key, None)
    environment["GH_HOST"] = "github.com"
    environment["GH_PROMPT_DISABLED"] = "1"
    return environment


def resolve_copilot_token(account):
    if account is None:
        return None
    try:
        response = subprocess.run(
            [github_cli(), "auth", "token", "--hostname", "github.com", "--user", account],
            env=github_lookup_environment(), capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise OrchestrationError("The selected Copilot subscription could not be accessed; no fallback account was used.") from error
    token = response.stdout.strip()
    if response.returncode or not token or len(token) > 4096 or any(character.isspace() for character in token):
        raise OrchestrationError("The selected account credential is unavailable through GitHub CLI; authenticate that exact account with gh auth login. No fallback account was used.")
    return token


def command_accounts():
    try:
        response = subprocess.run(
            [github_cli(), "auth", "status", "--hostname", "github.com", "--json", "hosts",
             "--jq", '.hosts["github.com"] | .[:64] | map({login,state})'],
            env=github_lookup_environment(), capture_output=True, text=True, timeout=10,
        )
        if response.returncode or len(response.stdout) > 65_536:
            raise OrchestrationError("Unable to list configured GitHub accounts.")
        entries = json.loads(response.stdout)
        if not isinstance(entries, list) or len(entries) > 64:
            raise ValueError()
        accounts = []
        for entry in entries:
            login = entry["login"]
            if not isinstance(login, str):
                raise ValueError()
            validate_launch_settings({"version": 1, "copilotAccount": login})
            accounts.append({"login": login, "available": entry.get("state") == "success"})
        return {"accounts": sorted(accounts, key=lambda value: value["login"].lower())}
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        raise OrchestrationError("Unable to list configured GitHub accounts; use gh auth login to add one.") from error


def command_icons(args):
    glyphs, presets = glyph_catalog()
    query = (args.search or "").strip().lower()
    if len(query) > 128 or args.offset < 0 or not 1 <= args.limit <= 100:
        raise OrchestrationError("Use a search of at most 128 characters, a nonnegative offset, and limit 1...100.")
    if query.startswith("nf-"):
        query = query[3:]
    aliases = {item["glyph"] for item in presets if query in item["id"] or query in item["name"].lower()}
    names = sorted(name for name, glyph in glyphs.items()
                   if query in name or query == glyph["code"].lower() or name in aliases)
    return {
        "fontVersion": NERD_FONTS_VERSION, "total": len(names), "offset": args.offset,
        "icons": [{"id": name, **glyphs[name]} for name in names[args.offset:args.offset + args.limit]],
        "presets": presets, "colors": list(ICON_COLORS),
    }


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
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError:
        raise OrchestrationError(f"{field} contains invalid Unicode.")
    if len(encoded) > limit or "\0" in value:
        raise OrchestrationError(f"{field} exceeds its safe limit.")
    if any(ord(character) < 32 and character not in "\n\t" for character in value):
        raise OrchestrationError(f"{field} contains control characters.")
    return value.strip()


def sanitize_label(value):
    cleaned = "".join(character for character in value if character.isprintable())
    return " ".join(cleaned.split())[:MAX_LABEL] or "Unnamed worker"


def git_display_metadata(cwd):
    """Return bounded labels from an explicitly assigned directory."""
    captured_at = now()
    unavailable = {
        "worktreeLabel": None, "branchLabel": None,
        "gitEvidenceStatus": "unavailable", "gitEvidenceAt": captured_at,
        "gitChangesStatus": "unavailable", "gitChanges": None, "gitChangesAt": captured_at,
    }
    try:
        git = trusted_executable("CMUX_MAESTRO_GIT", "/usr/bin/git")
    except OrchestrationError:
        return unavailable

    def label(value):
        if value is None:
            return None
        value = value.strip()
        if (
            not value
            or len(value.encode("utf-8")) > MAX_DISPLAY_METADATA
            or any(ord(character) < 32 for character in value)
        ):
            return None
        return value

    def query(*arguments):
        output = git_change_query(git, cwd, *arguments)
        if output is None or len(output) > 4_096:
            return None
        try:
            value = output.decode("utf-8", errors="strict").strip()
        except UnicodeDecodeError:
            return None
        if not value:
            return None
        if any(character in value for character in ("\0", "\n", "\r")):
            return None
        return value

    root = query("rev-parse", "--show-toplevel")
    if root is None:
        return unavailable
    worktree = label(Path(root).name)
    if worktree is None:
        return unavailable
    branch = label(query("symbolic-ref", "--quiet", "--short", "HEAD"))
    changes = git_change_counts(git, Path(root))
    return {
        "worktreeLabel": worktree,
        "branchLabel": branch,
        "gitEvidenceStatus": "verified",
        "gitEvidenceAt": captured_at,
        "gitChangesStatus": "verified" if changes is not None else "unavailable",
        "gitChanges": changes,
        "gitChangesAt": captured_at,
    }


def git_change_query(git, cwd, *arguments):
    """Read only bounded machine output; never run diff drivers or file watchers."""
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update({"GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"})
    try:
        with subprocess.Popen(
            [git, "--no-optional-locks", "-c", "core.fsmonitor=false",
             "-c", "core.hooksPath=/dev/null", "-C", str(cwd), *arguments],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=environment,
        ) as process:
            try:
                deadline = time.monotonic() + 1
                output = bytearray()
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    while True:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0 or not selector.select(remaining):
                            return None
                        chunk = os.read(process.stdout.fileno(), 65_536)
                        if not chunk:
                            break
                        output.extend(chunk)
                        if len(output) > MAX_BYTES:
                            return None
                if process.wait(timeout=max(0.001, deadline - time.monotonic())) != 0:
                    return None
                return bytes(output)
            finally:
                if process.poll() is None:
                    # Only our short-lived Git probe, never an agent or terminal.
                    process.kill()
                process.wait()
    except (OSError, subprocess.TimeoutExpired):
        return None


def parse_git_change_counts(numstat, untracked):
    if (numstat and not numstat.endswith(b"\0")) or (untracked and not untracked.endswith(b"\0")):
        return None
    records = numstat.split(b"\0")[:-1]
    paths = set()
    totals = dict.fromkeys(GIT_CHANGE_FIELDS, 0)
    index = 0
    while index < len(records):
        fields = records[index].split(b"\t", 2)
        index += 1
        if len(fields) != 3:
            return None
        added, deleted, path = fields
        if not path:
            if index + 1 >= len(records) or not records[index] or not records[index + 1]:
                return None
            path = records[index + 1]
            index += 2
        if path in paths:
            return None
        paths.add(path)
        if added == deleted == b"-":
            totals["binaryFiles"] += 1
        elif added.isdigit() and deleted.isdigit() and len(added) <= 10 and len(deleted) <= 10:
            totals["insertions"] += int(added)
            totals["deletions"] += int(deleted)
        else:
            return None
    other_paths = untracked.split(b"\0")[:-1]
    if any(not path for path in other_paths) or len(set(other_paths)) != len(other_paths):
        return None
    totals["untrackedFiles"] = len(set(other_paths) - paths)
    totals["files"] = len(paths | set(other_paths))
    return totals if valid_git_changes(totals) else None


def valid_git_changes(changes):
    return (
        isinstance(changes, dict) and set(changes) == GIT_CHANGE_FIELDS
        and all(type(value) is int and 0 <= value <= MAX_GIT_COUNT for value in changes.values())
        and changes["untrackedFiles"] + changes["binaryFiles"] <= changes["files"]
        and (changes["files"] > changes["untrackedFiles"] + changes["binaryFiles"]
             or changes["insertions"] == changes["deletions"] == 0)
    )


def git_change_counts(git, cwd):
    head = git_change_query(git, cwd, "rev-parse", "--verify", "HEAD")
    if head is None or not head.strip():
        return None
    if git_change_query(git, cwd, "ls-files", "--unmerged", "-z") != b"":
        return None
    numstat = git_change_query(
        git, cwd, "diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all",
        "--find-renames", "--numstat", "-z", "HEAD", "--",
    )
    untracked = git_change_query(git, cwd, "ls-files", "--others", "--exclude-standard", "-z")
    if numstat is None or untracked is None:
        return None
    if git_change_query(git, cwd, "rev-parse", "--verify", "HEAD") != head:
        return None
    return parse_git_change_counts(numstat, untracked)


def absent_git_metadata():
    return {
        "worktreeLabel": None, "branchLabel": None,
        "gitEvidenceStatus": None, "gitEvidenceAt": None,
        "gitChangesStatus": None, "gitChanges": None, "gitChangesAt": None,
    }


def collect_git_evidence(state, node_ids):
    """Probe each distinct assigned cwd once, without holding the state lock."""
    targets = [
        node for identifier, node in state["nodes"].items()
        if identifier in node_ids and node.get("workingDirectory") is not None
    ]
    by_directory = {}
    for node in targets:
        directory = node["workingDirectory"]
        if directory not in by_directory:
            by_directory[directory] = git_display_metadata(Path(directory))
    return {
        node["id"]: {
            "runId": node["runId"],
            "workingDirectory": node["workingDirectory"],
            "metadata": by_directory[node["workingDirectory"]],
        }
        for node in targets
    }


def apply_git_evidence(state, evidence):
    for identifier, captured in evidence.items():
        node = state["nodes"].get(identifier)
        if (
            node is None
            or node["runId"] != captured["runId"]
            or node.get("workingDirectory") != captured["workingDirectory"]
        ):
            continue
        metadata = captured["metadata"]
        for field in (
            "worktreeLabel", "branchLabel", "gitEvidenceStatus", "gitEvidenceAt",
            "gitChangesStatus", "gitChanges", "gitChangesAt",
        ):
            node[field] = metadata[field]


def assigned_directory(value):
    if value is None:
        return None
    try:
        cwd = Path(value).expanduser().resolve(strict=True)
    except OSError:
        raise OrchestrationError("Working directory does not exist.")
    if not cwd.is_dir():
        raise OrchestrationError("Working directory must be a directory.")
    return cwd


def normalize_tool_policy(allow, deny, parent=None):
    if not isinstance(allow, list) or not isinstance(deny, list):
        raise OrchestrationError("Copilot tool policy must contain rule lists.")
    if len(allow) > MAX_POLICY_RULES or len(deny) > MAX_POLICY_RULES:
        raise OrchestrationError("Copilot tool policy exceeds its rule limit.")

    def rules(values, field):
        result = []
        for value in values:
            rule = bounded_text(value, field, MAX_POLICY_RULE)
            if rule not in result:
                result.append(rule)
        return result

    allowed = rules(allow, "allow-tool rule")
    denied = rules(deny, "deny-tool rule")
    broad = {"*", "all"}
    if any(
        "*" in rule or rule.casefold().replace(" ", "") in broad
        for rule in allowed
    ):
        raise OrchestrationError("Broad Copilot tool grants are not supported.")
    if parent is not None:
        parent_allow = set(parent["allow"])
        if any(rule not in parent_allow for rule in allowed):
            raise OrchestrationError("A worker cannot grant a child additional Copilot tools.")
        denied = list(dict.fromkeys([*parent["deny"], *denied]))
    denied_set = set(denied)
    allowed = [rule for rule in allowed if rule not in denied_set]
    if len(denied) > MAX_POLICY_RULES:
        raise OrchestrationError("Inherited Copilot deny policy exceeds its rule limit.")
    return {"allow": allowed, "deny": denied}


def validate_tool_policy(value):
    if not isinstance(value, dict) or set(value) != {"allow", "deny"}:
        raise OrchestrationError("Stored Copilot tool policy is invalid.")
    normalized = normalize_tool_policy(value["allow"], value["deny"])
    if normalized != value:
        raise OrchestrationError("Stored Copilot tool policy is not canonical.")


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


def test_barrier(name):
    path = os.environ.get(name)
    if path is None:
        return
    if os.environ.get("CMUX_MAESTRO_TESTING") != "1":
        raise OrchestrationError(f"{name} is test-only.")
    marker = Path(path)
    marker.with_suffix(".ready").write_text("ready")
    deadline = time.monotonic() + 10
    while not marker.with_suffix(".release").exists():
        if time.monotonic() >= deadline:
            raise OrchestrationError(f"{name} timed out.")
        time.sleep(0.01)


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


def provider_launch_context(actor=None):
    actor = actor or {}
    executable = trusted_executable(
        "CMUX_MAESTRO_COPILOT", actor.get("copilotExecutable") or "copilot"
    )
    launch_path = actor.get("launchPath") or os.environ.get("PATH", "/usr/bin:/bin")
    bounded_text(launch_path, "provider launch PATH", MAX_LAUNCH_PATH)
    return executable, launch_path


def empty_state():
    return {
        "version": VERSION,
        "nodes": {},
        "archives": [],
        "retainedResources": [],
        "launches": {},
    }


def has_managed_runtime(node):
    return node["role"] == "worker" or node.get("executionMode") == "interactive"


def validate_state(state):
    if state.get("version") != VERSION or not isinstance(state.get("nodes"), dict):
        raise OrchestrationError("Control state version is unsupported.")
    state.setdefault("archives", [])
    state.setdefault("retainedResources", [])
    state.setdefault("launches", {})
    nodes = state["nodes"]
    launches = state["launches"]
    if not isinstance(launches, dict) or len(launches) > MAX_NODES:
        raise OrchestrationError("Launch transactions exceed their safe limit.")
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
        mode = node.get("executionMode", "bounded")
        if mode not in {"bounded", "interactive"}:
            raise OrchestrationError("Stored execution mode is invalid.")
        runtime_version = node.get("runtimeProtocolVersion", 1)
        if type(runtime_version) is not int or runtime_version not in {1, 2}:
            raise OrchestrationError("Stored runtime protocol is unsupported.")
        if node.get("launchSettings") is not None:
            validate_launch_settings(node["launchSettings"])
        if ("copilotExecutable" in node) != ("launchPath" in node):
            raise OrchestrationError("Stored provider executable context is incomplete.")
        if "copilotExecutable" in node:
            executable = bounded_text(node["copilotExecutable"], "stored provider executable", 4096)
            if not Path(executable).is_absolute():
                raise OrchestrationError("Stored provider executable must be absolute.")
            bounded_text(node["launchPath"], "stored provider PATH", MAX_LAUNCH_PATH)
        if (not isinstance(node.get("permissionMode", "default"), str)
                or node.get("permissionMode", "default") not in {"default", "yolo"}):
            raise OrchestrationError("Stored launch permission mode is invalid.")
        if node.get("permissionMode") == "yolo" and mode != "interactive":
            raise OrchestrationError("YOLO requires an explicitly launched interactive session.")
        messaging = node.get("messaging")
        if messaging is not None and (
            not isinstance(messaging, dict) or set(messaging) != {"version", "routes", "extension"}
            or type(messaging["version"]) is not int or messaging["version"] != 1
            or not isinstance(messaging["routes"], str) or len(messaging["routes"]) > 1024
            or not Path(messaging["routes"]).is_absolute()
            or not isinstance(messaging["extension"], str) or len(messaging["extension"]) > 1024
            or not Path(messaging["extension"]).is_absolute()
            or mode != "interactive"
        ):
            raise OrchestrationError("Stored messaging configuration is invalid.")
        proof = node.get("deliveryProof")
        if proof is not None and (
            not isinstance(proof, dict)
            or set(proof) not in ({"fixture", "experimental"}, {"fixture", "experimental", "yolo"})
            or not isinstance(proof["fixture"], str) or len(proof["fixture"]) > 1024
            or type(proof["experimental"]) is not bool
            or type(proof.get("yolo", False)) is not bool
            or role != "worker" or mode != "interactive"
        ):
            raise OrchestrationError("Stored delivery proof configuration is invalid.")
        provider = node.get("providerProcess")
        if provider is not None and (
            not isinstance(provider, dict) or set(provider) != {"pid", "start"}
            or type(provider["pid"]) is not int or provider["pid"] <= 0
            or not isinstance(provider["start"], str) or not 1 <= len(provider["start"]) <= 100
            or mode != "interactive"
        ):
            raise OrchestrationError("Stored interactive process identity is invalid.")
        if node.get("iconId") is not None:
            if not isinstance(node["iconId"], str) or not re.fullmatch(r"[a-z0-9_-]{1,128}", node["iconId"]):
                raise OrchestrationError("Stored session glyph name is invalid.")
        if node.get("iconColor") is not None and (
            not isinstance(node["iconColor"], str) or node["iconColor"] not in ICON_COLORS
        ):
            raise OrchestrationError("Stored session icon color is not in the palette.")
        if (role == "coordinator") != (parent is None):
            raise OrchestrationError("Stored coordinator ancestry is invalid.")
        if role == "coordinator":
            roots_by_run[node["runId"]] = roots_by_run.get(node["runId"], 0) + 1
        if not isinstance(node.get("generation"), int) or node["generation"] < 0:
            raise OrchestrationError("Stored generation is invalid.")
        for field in ("worktreeLabel", "branchLabel"):
            value = node.get(field)
            if value is not None:
                bounded_text(value, f"stored {field}", MAX_DISPLAY_METADATA)
        evidence_status = node.get("gitEvidenceStatus")
        evidence_at = node.get("gitEvidenceAt")
        changes_status = node.get("gitChangesStatus")
        changes = node.get("gitChanges")
        changes_at = node.get("gitChangesAt")
        if changes_status == "verified":
            if not valid_git_changes(changes) or changes_at is None:
                raise OrchestrationError("Stored Git change counts are invalid.")
        elif changes_status not in {None, "unavailable"} or changes is not None:
            raise OrchestrationError("Unavailable Git changes cannot retain counts.")
        if changes_at is not None:
            if changes_status is None or parse_date(changes_at, "stored Git counts time") > now_date() + datetime.timedelta(minutes=5):
                raise OrchestrationError("Stored Git counts timestamp is invalid.")
        if evidence_status is None:
            if evidence_at is not None or node.get("worktreeLabel") is not None or node.get("branchLabel") is not None:
                raise OrchestrationError("Stored Git evidence is incomplete.")
        else:
            if evidence_status not in GIT_EVIDENCE_STATUSES or evidence_at is None:
                raise OrchestrationError("Stored Git evidence status is invalid.")
            captured = parse_date(evidence_at, "stored Git evidence time")
            if captured > now_date() + datetime.timedelta(minutes=5):
                raise OrchestrationError("Stored Git evidence timestamp is invalid.")
            if evidence_status == "verified" and node.get("worktreeLabel") is None:
                raise OrchestrationError("Verified Git evidence requires a worktree label.")
            if evidence_status == "unavailable" and (
                node.get("worktreeLabel") is not None or node.get("branchLabel") is not None
            ):
                raise OrchestrationError("Unavailable Git evidence cannot retain labels.")
        session_id = node.get("copilotSessionId")
        if session_id is not None:
            canonical_uuid(session_id, "stored Copilot session ID")
        if role == "coordinator":
            if mode == "interactive":
                if (session_id is None or node["generation"] != 1
                        or node.get("launchSettings") is None or runtime_version != 2):
                    raise OrchestrationError("Managed coordinator requires an exact launch identity.")
            elif session_id is not None or node["generation"] != 0:
                raise OrchestrationError("Registered coordinator cannot claim a controlled Copilot session.")
        boundary_generation = node.get("verifiedBoundaryGeneration")
        if (
            boundary_generation is not None
            and (
                type(boundary_generation) is not int
                or boundary_generation < 1
                or boundary_generation > node["generation"]
                or role != "worker"
            )
        ):
            raise OrchestrationError("Stored verified boundary generation is invalid.")
        validate_tool_policy(node.get("toolPolicy"))
        if not isinstance(node.get("archiving", False), bool):
            raise OrchestrationError("Stored archive state is invalid.")
        if "runtimeNotStarted" in node and (
            node["runtimeNotStarted"] is not True or not has_managed_runtime(node)
            or node.get("supervisor") or provider or identifier in state["launches"]
            or node["phase"] not in {
                "launch-failed", "startup-failed", "resource-retired",
                "process-disappeared", "terminal-disappeared",
            }
        ):
            raise OrchestrationError("Stored pre-runtime failure evidence is invalid.")
        created = parse_date(node.get("createdAt"), "stored creation time")
        updated = parse_date(node.get("updatedAt"), "stored update time")
        if created > updated or updated > now_date() + datetime.timedelta(minutes=5):
            raise OrchestrationError("Stored node timestamps are inconsistent.")
        phase, availability = node.get("phase"), node.get("availability")
        valid_lifecycle = (
            role == "coordinator" and mode != "interactive"
            and phase == "registered" and availability == "active"
        ) or (
            has_managed_runtime(node) and (
                (phase == "launching" and availability == "busy")
                or (phase == "turn-running" and availability == "busy")
                or (mode == "bounded" and phase == "turn-queued" and availability == "busy")
                or (phase == "turn-failed" and availability == "idle")
                or (mode == "bounded" and phase in {
                    "reported-blocked", "reported-completed", "reported-failed",
                    "report-missing", "permission-denied", "turn-failed",
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
    for identifier, launch in launches.items():
        if canonical_uuid(identifier, "launch worker ID") != launch.get("workerId"):
            raise OrchestrationError("Launch transaction identity is invalid.")
        node = nodes.get(identifier)
        if (
            node is None or not has_managed_runtime(node) or node["phase"] != "launching"
            or launch.get("runId") != node["runId"]
            or launch.get("workspaceId") != node["workspaceId"]
            or launch.get("state") not in {"creating", "attaching", "starting"}
        ):
            raise OrchestrationError("Launch transaction ownership is invalid.")
        parse_date(launch.get("createdAt"), "launch creation time")
        updated = parse_date(launch.get("updatedAt"), "launch update time")
        if updated > now_date() + datetime.timedelta(minutes=5):
            raise OrchestrationError("Launch transaction timestamp is invalid.")
        surface = launch.get("surfaceId")
        if surface is not None:
            canonical_uuid(surface, "launch surface ID")
            owner = next(
                (item["id"] for item in nodes.values() if item.get("surfaceId") == surface),
                None,
            )
            if (owner is not None and owner != identifier) or surface in retained_ids:
                raise OrchestrationError("Launch surface ownership is duplicated.")


class Store:
    def __init__(self, root, *, blocking=False, read_only=False):
        self.root = root
        self.blocking = blocking
        self.read_only = read_only
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
            operation = (fcntl.LOCK_SH if self.read_only else fcntl.LOCK_EX) | (
                0 if self.blocking else fcntl.LOCK_NB
            )
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
        payload = self._read_regular("state.json", MAX_BYTES)
        if payload is None:
            return empty_state()
        try:
            state = json.loads(payload)
        except (json.JSONDecodeError, UnicodeDecodeError):
            raise OrchestrationError("Control state is malformed.")
        self._normalize_candidate_state(state)
        validate_state(state)
        return state

    def _read_regular(self, name, maximum, *, private=False, directory=None):
        directory = self.control_fd if directory is None else directory
        try:
            descriptor = os.open(
                name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory
            )
        except FileNotFoundError:
            return None
        try:
            before = os.fstat(descriptor)
            if (
                not stat.S_ISREG(before.st_mode)
                or before.st_uid != os.getuid()
                or before.st_size <= 0
                or before.st_size > maximum
                or (private and before.st_mode & 0o077)
            ):
                raise OrchestrationError("Control state is not a safe owned regular file.")
            payload = os.read(descriptor, maximum + 1)
            after = os.fstat(descriptor)
            entry = os.stat(
                name, dir_fd=directory, follow_symlinks=False
            )
            stamps = lambda value: (
                value.st_dev, value.st_ino, value.st_mtime_ns, value.st_size
            )
            if stamps(before) != stamps(after) or stamps(before) != stamps(entry):
                raise OrchestrationError("Control state changed while reading.")
        finally:
            os.close(descriptor)
        return payload

    def launch_token(self, worker_id):
        payload = self._read_regular(f"launch-{worker_id}.json", 4096, private=True)
        if payload is None:
            raise OrchestrationError("Private launch credential is unavailable.")
        try:
            value = json.loads(payload)
            token = value["token"]
            if set(value) != {"workerId", "token"} or value["workerId"] != worker_id:
                raise ValueError()
            if not isinstance(token, str) or re.fullmatch(r"[a-f0-9]{64}", token) is None:
                raise ValueError()
            return token
        except (ValueError, KeyError, TypeError):
            raise OrchestrationError("Private launch credential is invalid.")

    @staticmethod
    def _normalize_candidate_state(state):
        if not isinstance(state, dict) or not isinstance(state.get("nodes"), dict):
            return
        state.setdefault("archives", [])
        state.setdefault("retainedResources", [])
        for node in state["nodes"].values():
            candidate = "archiving" not in node
            legacy_git_evidence = "gitEvidenceStatus" not in node
            node.setdefault("archiving", False)
            node.setdefault("lastControlAt", node.get("updatedAt"))
            node.setdefault("pendingReport", None)
            node.setdefault("supervisor", None)
            node.setdefault("verifiedBoundaryGeneration", None)
            node.setdefault("toolPolicy", {"allow": [], "deny": []})
            node.setdefault("worktreeLabel", None)
            node.setdefault("branchLabel", None)
            node.setdefault("gitEvidenceStatus", None)
            node.setdefault("gitEvidenceAt", None)
            node.setdefault("gitChangesStatus", None)
            node.setdefault("gitChanges", None)
            node.setdefault("gitChangesAt", None)
            node.setdefault("iconId", None)
            node.setdefault("iconColor", None)
            if node.get("role") == "worker":
                node.setdefault("executionMode", "bounded")
            if legacy_git_evidence:
                node["worktreeLabel"] = None
                node["branchLabel"] = None
            if candidate and node.get("role") == "worker":
                node["phase"] = "process-disappeared"
                node["availability"] = "unavailable"
                node["result"] = "Legacy worker requires explicit archive before reuse."

    def write(self, state):
        if self.read_only:
            raise OrchestrationError("Read-only orchestration access cannot publish mutations.")
        validate_state(state)
        encoded = json.dumps(state, sort_keys=True, separators=(",", ":")).encode() + b"\n"
        if len(encoded) > MAX_BYTES:
            raise OrchestrationError("Control state exceeds its safe limit.")
        self._atomic(self.control_fd, "state.json", encoded)
        self._atomic(self.observer_fd, "current.json", self._projection(state))
        icons = [{
            "nodeId": node["id"], "runId": node["runId"],
            "workspaceId": node["workspaceId"], "surfaceId": node["surfaceId"],
            "iconId": node.get("iconId"), "iconColor": node.get("iconColor"),
        } for node in state["nodes"].values() if node.get("surfaceId") is not None
            and (node.get("iconId") is not None or node.get("iconColor") is not None)]
        # Older supervisors may republish current.json without cosmetic fields.
        # A separate bounded projection preserves selections without hot-patching them.
        self._atomic(self.observer_fd, "icons.json", json.dumps(
            {"version": 1, "icons": icons}, sort_keys=True, separators=(",", ":")
        ).encode() + b"\n")

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
            "executionMode": item.get("executionMode"),
            "iconId": item.get("iconId"),
            "iconColor": item.get("iconColor"),
            "label": item["label"],
            "workspaceId": item["workspaceId"],
            "surfaceId": item["surfaceId"],
            "generation": item["generation"],
            "phase": item["phase"],
            "availability": item["availability"],
            "copilotSessionId": item.get("copilotSessionId"),
            "worktreeLabel": item.get("worktreeLabel"),
            "branchLabel": item.get("branchLabel"),
            "gitEvidenceStatus": item.get("gitEvidenceStatus"),
            "gitEvidenceAt": item.get("gitEvidenceAt"),
            "gitChangesStatus": item.get("gitChangesStatus"),
            "gitChanges": item.get("gitChanges"),
            "gitChangesAt": item.get("gitChangesAt"),
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


def with_store(root, operation, *, wait=1, read_only=False):
    deadline = time.monotonic() + wait
    while True:
        try:
            with Store(root, read_only=read_only) as store:
                return operation(store)
        except OrchestrationError as error:
            if "operation is active" not in str(error) or time.monotonic() >= deadline:
                raise
            time.sleep(0.05)


def mutate(root, operation, *, wait=1):
    def apply(store):
        state = store.read()
        result = operation(state)
        store.write(state)
        return result
    return with_store(root, apply, wait=wait)


def read_state(root, *, wait=1):
    return with_store(root, lambda store: json.loads(json.dumps(store.read())), wait=wait, read_only=True)


def remove_launch_credential(root, worker_id):
    def remove(store):
        try:
            os.unlink(f"launch-{worker_id}.json", dir_fd=store.control_fd)
        except FileNotFoundError:
            pass
    with_store(root, remove, wait=2)


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

    def workspace_surfaces(self, workspace):
        # surface.list takes one host main-actor snapshot. Separate pane reads
        # can miss a live surface moved into an already-read pane.
        listing = self.run("rpc", "surface.list", json.dumps({"workspace_id": workspace}))
        if (not isinstance(listing, dict) or not isinstance(listing.get("surfaces"), list)
                or canonical_uuid(listing.get("workspace_id"), "inventory workspace") != workspace):
            raise OrchestrationError("CMUX workspace surface inventory is unavailable.")
        surfaces = set()
        for item in listing["surfaces"]:
            if not isinstance(item, dict):
                raise OrchestrationError("CMUX surface inventory has invalid identity.")
            surface = canonical_uuid(item.get("id"), "inventory surface")
            if surface in surfaces:
                raise OrchestrationError("CMUX surface inventory has duplicate identity.")
            surfaces.add(surface)
        return surfaces

    def create_surface(self, workspace, pane, cwd, command=None):
        parameters = {
            "type": "terminal", "pane_id": pane, "workspace_id": workspace,
            "working_directory": cwd, "focus": False,
            "startup_environment": {"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
        }
        if command is not None:
            # CLI --command queues shell input; its startup files can outlive the lease.
            parameters["initial_command"] = command
        response = self.run("rpc", "surface.create", json.dumps(parameters))
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
    except (subprocess.TimeoutExpired, OSError):
        return None
    value = result.stdout.strip()
    return value if result.returncode == 0 and value else None


def process_matches(node):
    return any(process and process_start(process["pid"]) == process["start"]
               for process in (node.get("supervisor"), node.get("providerProcess")))


def worker_processes_exited(node):
    processes = (node.get("supervisor"), node.get("providerProcess"))
    if node.get("runtimeNotStarted") is True and not any(processes):
        return True
    if not processes[0] or (node.get("executionMode") == "interactive" and not processes[1]):
        return False
    for process in processes:
        if not process:
            continue
        start = process_start(process["pid"])
        if start == process["start"]:
            return False
        if start is None:
            # A failed/timed-out ps probe is not proof of exit. Signal zero only
            # checks existence; it neither delivers a signal nor controls a process.
            try:
                os.kill(process["pid"], 0)
            except ProcessLookupError:
                continue
            except PermissionError:
                return False
            return False
    return True


def legacy_supervisor_blocks(state, node):
    if not has_managed_runtime(node) or node.get("runtimeProtocolVersion", 1) >= 2:
        return False
    if node["id"] in state["launches"]:
        return True
    if not node.get("supervisor"):
        return node["phase"] not in {
            "launch-failed", "startup-failed", "resource-retired",
            "process-disappeared", "terminal-disappeared",
        }
    # Providers/adapters do not parse controller state. Preserve them; only an
    # old supervisor writer can be invalidated by the new coordinator schema.
    return not worker_processes_exited({**node, "executionMode": "bounded", "providerProcess": None})


def new_root(workspace, surface, pane, label, cwd=None, metadata=None, icon_id=None, icon_color=None):
    identifier, run_id, token = str(uuid.uuid4()), str(uuid.uuid4()), secrets.token_hex(32)
    timestamp = now()
    metadata = metadata or absent_git_metadata()
    node = {
        "id": identifier, "runId": run_id, "parentId": None, "role": "coordinator",
        "iconId": resolve_icon(icon_id or "maestro"),
        "iconColor": icon_color,
        "label": label, "workspaceId": workspace, "surfaceId": surface, "paneId": pane,
        "copilotSessionId": None, "workingDirectory": str(cwd) if cwd is not None else None,
        "worktreeLabel": metadata["worktreeLabel"], "branchLabel": metadata["branchLabel"],
        "gitEvidenceStatus": metadata["gitEvidenceStatus"],
        "gitEvidenceAt": metadata["gitEvidenceAt"],
        "gitChangesStatus": metadata["gitChangesStatus"],
        "gitChanges": metadata["gitChanges"],
        "gitChangesAt": metadata["gitChangesAt"],
        "generation": 0,
        "phase": "registered", "availability": "active", "createdAt": timestamp,
        "updatedAt": timestamp, "lastControlAt": timestamp, "tokenHash": token_hash(token),
        "task": None, "result": None, "pendingReport": None, "supervisor": None,
        "archiving": False, "verifiedBoundaryGeneration": None,
        "toolPolicy": {"allow": [], "deny": []},
    }
    return node, token


def command_register(args, root, cmux):
    workspace = canonical_uuid(args.workspace, "workspace ID")
    surface = canonical_uuid(args.surface, "surface ID")
    require_current_surface(workspace, surface)
    label = sanitize_label(bounded_text(args.name, "name", MAX_LABEL))
    cwd = assigned_directory(args.cwd)
    metadata = git_display_metadata(cwd) if cwd is not None else absent_git_metadata()
    pane = cmux.validate_surface(workspace, surface)

    def register(state):
        if len(state["nodes"]) >= MAX_NODES:
            raise OrchestrationError("Orchestration node limit reached.")
        if any(node.get("surfaceId") == surface for node in state["nodes"].values()):
            raise OrchestrationError("This CMUX surface has a live registered owner.")
        node, token = new_root(workspace, surface, pane, label, cwd, metadata, args.icon, args.color)
        state["nodes"][node["id"]] = node
        return {
            "coordinatorId": node["id"], "runId": node["runId"], "controlToken": token,
            "workspaceId": workspace, "surfaceId": surface,
        }
    return mutate(root, register)


def command_launch_coordinator(args, root, cmux):
    workspace = canonical_uuid(args.workspace, "workspace ID")
    source_surface = canonical_uuid(args.surface, "surface ID")
    require_current_surface(workspace, source_surface)
    pane = cmux.validate_surface(workspace, source_surface)
    snapshot = read_state(root)
    if any(current.get("surfaceId") == source_surface and has_managed_runtime(current)
           for current in snapshot["nodes"].values()):
        raise OrchestrationError("A managed session cannot launch another root; use its authorized child-launch tool.")
    if any(legacy_supervisor_blocks(snapshot, current) for current in snapshot["nodes"].values()):
        raise OrchestrationError("A live or uncertain legacy supervisor prevents coordinator startup; existing sessions were not changed.")
    observations, retained_gone = resource_observations(snapshot, cmux, workspace)
    cwd = assigned_directory(args.cwd)
    label = sanitize_label(bounded_text(args.name, "name", MAX_LABEL))
    task = bounded_text(args.task, "task", MAX_TASK)
    settings = worker_launch_settings(root)
    settings = validate_launch_settings({
        "version": 1, "copilotAccount": args.account or settings.get("copilotAccount"),
        "model": args.model or settings.get("model"),
    })
    if not settings.get("copilotAccount") or not settings.get("model"):
        raise OrchestrationError("A managed coordinator requires an explicit account and configured model.")
    messaging = messaging_configuration(root)
    if messaging is None:
        raise OrchestrationError("A managed coordinator requires installed native messaging.")
    copilot, launch_path = provider_launch_context()
    resolve_copilot_token(settings["copilotAccount"])
    policy = normalize_tool_policy(args.allow_tool, args.deny_tool)
    node, token = new_root(
        workspace, None, pane, label, cwd, git_display_metadata(cwd), args.icon, args.color
    )
    node.update({
        "runtimeProtocolVersion": 2,
        "copilotExecutable": copilot, "launchPath": launch_path,
        "executionMode": "interactive", "generation": 1,
        "copilotSessionId": str(uuid.uuid4()), "launchSettings": settings,
        "messaging": messaging, "permissionMode": "yolo" if args.yolo else "default",
        "phase": "launching", "availability": "busy", "task": task,
        "toolPolicy": policy,
    })
    receipt = {
        "coordinatorId": node["id"], "runId": node["runId"], "controlToken": token,
        "workspaceId": workspace, "sessionId": node["copilotSessionId"],
    }
    reservation_prepared = False
    reservation_committed = False

    def reserve(state):
        nonlocal reservation_prepared
        if any(current.get("surfaceId") == source_surface and has_managed_runtime(current)
               for current in state["nodes"].values()):
            raise OrchestrationError("Caller ownership changed before coordinator launch.")
        if any(legacy_supervisor_blocks(state, current) for current in state["nodes"].values()):
            raise OrchestrationError("Legacy managed runtime became active before coordinator launch.")
        reconcile_resources(state, snapshot, observations, retained_gone)
        if len(state["nodes"]) >= MAX_NODES:
            raise OrchestrationError("Orchestration node limit reached.")
        live = sum(
            1 for current in state["nodes"].values()
            if has_managed_runtime(current) and current["workspaceId"] == workspace
            and current["phase"] != "resource-retired"
        ) + sum(item["workspaceId"] == workspace for item in state["retainedResources"])
        if live >= MAX_LIVE_WORKERS:
            raise OrchestrationError("Live session resource limit reached.")
        state["nodes"][node["id"]] = node
        state["launches"][node["id"]] = {
            "workerId": node["id"], "runId": node["runId"], "workspaceId": workspace,
            "surfaceId": None, "state": "creating",
            "createdAt": node["createdAt"], "updatedAt": node["updatedAt"],
        }
        reservation_prepared = True
    try:
        mutate(root, reserve)
        reservation_committed = True
        result = launch_reserved_session(
            root, cmux, node["id"], node["copilotSessionId"], token, workspace, pane, cwd, label
        )
    except (OrchestrationError, OSError) as error:
        if not reservation_prepared:
            raise
        message = launch_failure_message(error)
        reservation_state = "committed" if reservation_committed else "uncertain"
        if not reservation_committed:
            # state.json may have committed before observer publication failed.
            # Reconcile under the same lock; no ticket or host launch was attempted.
            def failed_reservation(store):
                nonlocal reservation_state
                state = store.read()
                if node["id"] not in state["nodes"]:
                    reservation_state = "uncommitted"
                    return
                current = authorize(state, node["id"], token)
                if any(current.get(key) != node.get(key) for key in (
                    "runId", "workspaceId", "copilotSessionId", "generation",
                )):
                    raise OrchestrationError("Reserved coordinator ownership changed.")
                reservation_state = "committed"
                record_launch_failure(state, node["id"])
                store.write(state)
            try:
                with_store(root, failed_reservation)
            except (OrchestrationError, OSError) as recovery_error:
                message += f" Failure recording also failed: {launch_failure_message(recovery_error)}"
        if reservation_state == "uncommitted":
            raise OrchestrationError(message) from error
        if isinstance(error, SessionLaunchError) and error.surface is not None:
            receipt["surfaceId"] = error.surface
        raise CoordinatorLaunchError(
            message, {**receipt, "reservationState": reservation_state},
        ) from error
    return {**result, **receipt}


def resource_observations(state, cmux, workspace):
    active = {}
    surfaces = cmux.workspace_surfaces(workspace)
    for node in state["nodes"].values():
        if has_managed_runtime(node) and node["workspaceId"] == workspace:
            process = process_matches(node)
            active[node["id"]] = {
                "surface": node.get("surfaceId") in surfaces,
                "process": process,
                "exited": not process and worker_processes_exited(node),
            }
    retained_gone = {
        resource["surfaceId"] for resource in state["retainedResources"]
        if resource["workspaceId"] == workspace
        and resource["surfaceId"] not in surfaces
    }
    return active, retained_gone


def reconcile_resources(state, snapshot, observations, retained_gone):
    for identifier, observed in observations.items():
        node = state["nodes"].get(identifier)
        previous = snapshot["nodes"].get(identifier)
        if (
            node is None or previous is None
            or identifier in state["launches"] or identifier in snapshot["launches"]
            or node["phase"] == "launching"
            or any(node.get(key) != previous.get(key) for key in (
                "runId", "workspaceId", "surfaceId", "supervisor", "providerProcess", "phase",
            ))
        ):
            continue
        if not observed["surface"] and observed["exited"]:
            node["phase"], node["availability"], node["updatedAt"] = (
                "resource-retired", "unavailable", now()
            )
    state["retainedResources"] = [
        resource for resource in state["retainedResources"]
        if resource["surfaceId"] not in retained_gone
        or resource not in snapshot["retainedResources"]
    ]


def record_launch_failure(state, worker_id, surface=None, *, phase="launch-failed"):
    launch = state["launches"].pop(worker_id, None)
    node = state["nodes"].get(worker_id)
    if surface is not None:
        owner = next(
            (
                item for item in state["nodes"].values()
                if item.get("surfaceId") == surface
            ),
            None,
        )
        retained = any(
            item["surfaceId"] == surface for item in state["retainedResources"]
        )
        if node is not None and (owner is None or owner["id"] == worker_id) and not retained:
            node["surfaceId"] = surface
        elif owner is None and not retained and launch is not None:
            state["retainedResources"].append({
                "runId": launch["runId"],
                "workspaceId": launch["workspaceId"],
                "surfaceId": surface,
                "archivedAt": now(),
            })
    if node is not None and node["phase"] == "launching":
        # Runtime claims the lease and records its supervisor atomically before
        # starting a provider. Cancelling an unclaimed lease fences that startup.
        if launch is not None and not node.get("supervisor") and not node.get("providerProcess"):
            node["runtimeNotStarted"] = True
        node["phase"], node["availability"], node["updatedAt"] = (
            phase, "unavailable", now()
        )


def authorize_native_spawn(state, identity):
    if not isinstance(identity, dict) or set(identity) != {
        "nodeId", "workspaceId", "sessionId", "generation", "capability", "login", "host"
    }:
        raise OrchestrationError("Native launch identity is invalid.")
    node_id = canonical_uuid(identity["nodeId"], "native actor ID")
    actor = state["nodes"].get(node_id)
    if not actor or actor.get("archiving") or not actor.get("messaging"):
        raise OrchestrationError("Native launch actor is unavailable.")
    if (
        (identity["workspaceId"], identity["sessionId"], identity["generation"])
        != (actor["workspaceId"], actor["copilotSessionId"], actor["generation"])
        or type(identity["generation"]) is not int
    ):
        raise OrchestrationError("Native launch session identity changed.")
    routes = Path(actor["messaging"]["routes"])
    private_message_directory(routes)
    binding = message_json(routes / f"{message_peer(actor)}.json")
    if (
        not isinstance(binding, dict)
        or binding.get("nodeId") != actor["id"]
        or binding.get("sessionId") != actor["copilotSessionId"]
        or binding.get("generation") != actor["generation"]
        or binding.get("workspaceId") != actor["workspaceId"]
        or not isinstance(identity["capability"], str)
        or not isinstance(binding.get("capability"), str)
        or not secrets.compare_digest(binding.get("capability", ""), identity["capability"])
    ):
        raise OrchestrationError("Native launch capability is unavailable.")
    if identity["host"] not in {"github.com", "https://github.com"}:
        raise OrchestrationError("Parent account host is unsupported; no account fallback was used.")
    validate_launch_settings({"version": 1, "copilotAccount": identity["login"]})
    if not identity["login"]:
        raise OrchestrationError("Parent account is unavailable; no account fallback was used.")
    return actor


def command_native_spawn(root, cmux):
    try:
        raw = sys.stdin.buffer.read(65_537)
        if len(raw) > 65_536:
            raise OrchestrationError("Native launch request exceeds its size bound.")
        request = json.loads(raw)
    except (UnicodeError, ValueError) as error:
        raise OrchestrationError("Native launch request is invalid.") from error
    if not isinstance(request, dict) or set(request) != {"identity", "assignment"}:
        raise OrchestrationError("Native launch request fields are invalid.")
    assignment = request["assignment"]
    if not isinstance(assignment, dict) or set(assignment) - {
        "name", "cwd", "task", "allowTools", "denyTools", "yolo", "icon", "color"
    } or not {"name", "cwd", "task"}.issubset(assignment):
        raise OrchestrationError("Native assignment fields are invalid.")
    if type(assignment.get("yolo", False)) is not bool:
        raise OrchestrationError("Native launch permission mode is invalid.")
    if any(not isinstance(assignment.get(key, []), list) for key in ("allowTools", "denyTools")):
        raise OrchestrationError("Native tool permissions must be explicit rule lists.")
    if "color" in assignment and (
        not isinstance(assignment["color"], str) or assignment["color"] not in ICON_COLORS
    ):
        raise OrchestrationError("Native launch color is invalid.")
    args = argparse.Namespace(
        actor_id=None, token=None, name=assignment["name"], cwd=assignment["cwd"],
        task=assignment["task"], allow_tool=assignment.get("allowTools", []),
        deny_tool=assignment.get("denyTools", []), yolo=assignment.get("yolo", False),
        require_pinned_launch_settings=True, icon=assignment.get("icon"), color=assignment.get("color"),
        delivery_proof_fixture=None, delivery_proof_experimental=False, delivery_proof_yolo=False,
    )
    return command_spawn(args, root, cmux, native_identity=request["identity"])


def command_spawn(args, root, cmux, *, native_identity=None):
    task = bounded_text(args.task, "task", MAX_TASK)
    label = sanitize_label(bounded_text(args.name, "name", MAX_LABEL))
    cwd = assigned_directory(args.cwd)
    proof = None
    if getattr(args, "delivery_proof_fixture", None):
        try:
            proof = delivery_proof_api()["validate_fixture"](args.delivery_proof_fixture, cwd, fresh=True)
        except (ValueError, OSError) as error:
            raise OrchestrationError("Delivery proof requires a fresh prepared fixture.") from error
        proof["experimental"] = args.delivery_proof_experimental
        proof["yolo"] = getattr(args, "delivery_proof_yolo", False)
    elif getattr(args, "delivery_proof_experimental", False):
        raise OrchestrationError("--delivery-proof-experimental requires --delivery-proof-fixture.")
    elif getattr(args, "delivery_proof_yolo", False):
        raise OrchestrationError("--delivery-proof-yolo requires --delivery-proof-fixture.")
    metadata = git_display_metadata(cwd)
    snapshot = read_state(root)
    actor = (authorize_native_spawn(snapshot, native_identity) if native_identity is not None
             else authorize(snapshot, args.actor_id, args.token))
    yolo = getattr(args, "yolo", False) or bool(proof and proof.get("yolo"))
    if yolo and actor["role"] != "coordinator":
        raise OrchestrationError("Only an explicitly authorized coordinator launch can request YOLO.")
    if actor.get("messaging") and native_identity is None:
        raise OrchestrationError("Managed sessions must use maestro_spawn to verify their current Copilot account.")
    if native_identity is None and proof is None and os.environ.get("CMUX_MAESTRO_TESTING") != "1":
        raise OrchestrationError("New managed workers require maestro_spawn from a managed coordinator; registration and saved accounts are not parent-account evidence.")
    messaging = None if proof is not None else messaging_configuration(root)
    launch_settings = worker_launch_settings(root)
    if native_identity is not None:
        launch_settings = {**launch_settings, "copilotAccount": native_identity["login"]}
    if (args.require_pinned_launch_settings or proof is not None or messaging is not None or yolo) and (
        launch_settings.get("copilotAccount") is None
        or launch_settings.get("model") is None
    ):
        raise OrchestrationError(
            "Pinned Maestro account and model settings are required; configure Agent launch settings before spawning."
        )
    # Check availability before creating a terminal; never persist the credential.
    copilot, launch_path = provider_launch_context(actor)
    resolve_copilot_token(launch_settings.get("copilotAccount"))
    parent_policy = actor["toolPolicy"] if has_managed_runtime(actor) else None
    tool_policy = normalize_tool_policy(args.allow_tool, args.deny_tool, parent_policy)
    pane = cmux.validate_surface(actor["workspaceId"], actor["surfaceId"])
    if has_managed_runtime(actor) and not process_matches(actor):
        raise OrchestrationError("Actor worker supervisor identity is stale.")
    observations, retained_gone = resource_observations(snapshot, cmux, actor["workspaceId"])
    identifier, session_id, worker_token = (
        str(uuid.uuid4()), str(uuid.uuid4()), secrets.token_hex(32)
    )

    def reserve(state):
        current = (authorize_native_spawn(state, native_identity) if native_identity is not None
                   else authorize(state, args.actor_id, args.token))
        if yolo and current["role"] != "coordinator":
            raise OrchestrationError("Only an explicitly authorized coordinator launch can request YOLO.")
        if (
            current["runId"], current["workspaceId"], current.get("surfaceId")
        ) != (actor["runId"], actor["workspaceId"], actor["surfaceId"]):
            raise OrchestrationError("Actor ownership changed during spawn.")
        reconcile_resources(state, snapshot, observations, retained_gone)
        live = sum(
            1 for node in state["nodes"].values()
            if has_managed_runtime(node) and node["workspaceId"] == current["workspaceId"]
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
            "executionMode": "interactive",
            "runtimeProtocolVersion": 2,
            "copilotExecutable": copilot, "launchPath": launch_path,
            "launchSettings": launch_settings,
            "iconId": resolve_icon(args.icon or "maestro"),
            "iconColor": args.color,
            "surfaceId": None, "paneId": pane, "copilotSessionId": session_id,
            "workingDirectory": str(cwd), "generation": 1, "phase": "launching",
            "worktreeLabel": metadata["worktreeLabel"], "branchLabel": metadata["branchLabel"],
            "gitEvidenceStatus": metadata["gitEvidenceStatus"],
            "gitEvidenceAt": metadata["gitEvidenceAt"],
            "gitChangesStatus": metadata["gitChangesStatus"],
            "gitChanges": metadata["gitChanges"],
            "gitChangesAt": metadata["gitChangesAt"],
            "availability": "busy", "createdAt": timestamp, "updatedAt": timestamp,
            "lastControlAt": timestamp, "tokenHash": token_hash(worker_token),
            "task": task, "result": None, "pendingReport": None, "supervisor": None,
            "archiving": False,
            "verifiedBoundaryGeneration": None, "toolPolicy": tool_policy,
        }
        if proof is not None:
            state["nodes"][identifier]["deliveryProof"] = proof
        if messaging is not None:
            state["nodes"][identifier]["messaging"] = messaging
        state["nodes"][identifier]["permissionMode"] = "yolo" if yolo else "default"
        state["launches"][identifier] = {
            "workerId": identifier, "runId": current["runId"],
            "workspaceId": current["workspaceId"], "surfaceId": None,
            "state": "creating", "createdAt": timestamp, "updatedAt": timestamp,
        }
        current["lastControlAt"] = timestamp
    mutate(root, reserve)
    return launch_reserved_session(
        root, cmux, identifier, session_id, worker_token, actor["workspaceId"], pane, cwd, label
    )


def launch_reserved_session(root, cmux, identifier, session_id, worker_token, workspace, pane, cwd, label):
    surface = None
    try:
        def credential(store):
            store._atomic(store.control_fd, f"launch-{identifier}.json", json.dumps(
                {"workerId": identifier, "token": worker_token}
            ).encode())
        with_store(root, credential)
        bootstrap = shlex.join([
            sys.executable, str(Path(__file__).resolve()), "runtime", "--worker-id", identifier
        ])
        surface = cmux.create_surface(workspace, pane, str(cwd), command=bootstrap)

        def created(state):
            launch = state["launches"].get(identifier)
            node = state["nodes"].get(identifier)
            if (
                not launch or not node or launch["state"] != "creating"
                or node["phase"] != "launching"
            ):
                raise OrchestrationError("Launch creation lease is no longer current.")
            launch["surfaceId"], launch["state"], launch["updatedAt"] = (
                surface, "attaching", now()
            )
        mutate(root, created, wait=1)
        test_barrier("CMUX_MAESTRO_TEST_ATTACH_BARRIER")
        confirmed_pane = cmux.validate_surface(workspace, surface)
        if os.environ.get("CMUX_MAESTRO_TEST_ATTACH_FAILURE") == "1":
            if os.environ.get("CMUX_MAESTRO_TESTING") != "1":
                raise OrchestrationError("CMUX_MAESTRO_TEST_ATTACH_FAILURE is test-only.")
            raise OrchestrationError("Injected attachment commit failure.")

        def attach(state):
            node = state["nodes"].get(identifier)
            launch = state["launches"].get(identifier)
            if (
                not node or not launch or launch["state"] != "attaching"
                or launch["surfaceId"] != surface or node["phase"] != "launching"
                or node["surfaceId"] is not None
            ):
                raise OrchestrationError("Launch reservation is no longer current.")
            if any(item.get("surfaceId") == surface for item in state["nodes"].values()):
                raise OrchestrationError("New worker surface already has an owner.")
            node["surfaceId"], node["paneId"], node["updatedAt"] = surface, confirmed_pane, now()
            launch["state"], launch["updatedAt"] = "starting", now()
        mutate(root, attach)
        cmux.rename(workspace, surface, label)
    except Exception as error:
        def failed(state):
            record_launch_failure(state, identifier, surface)
        try:
            mutate(root, failed, wait=1)
            remove_launch_credential(root, identifier)
        except (OrchestrationError, OSError) as recovery_error:
            raise SessionLaunchError(
                f"{launch_failure_message(error)} Failure recording or ticket cleanup also failed: "
                f"{launch_failure_message(recovery_error)}",
                surface,
            ) from error
        raise
    deadline = time.monotonic() + timeout("CMUX_MAESTRO_STARTUP_SECONDS", STARTUP_SECONDS)
    while time.monotonic() < deadline:
        state = read_state(root, wait=1)
        node = state["nodes"].get(identifier)
        if node and node.get("supervisor") and node["phase"] != "launching":
            if node.get("executionMode") == "interactive" and node["phase"] in {
                "turn-failed", "process-disappeared", "terminal-disappeared",
            }:
                raise OrchestrationError(
                    f"Managed session failed during startup ({node['phase']}); reconcile worker {identifier}."
                )
            return {
                "workerId": identifier, "sessionId": session_id, "surfaceId": surface,
                "workspaceId": workspace, "generation": 1,
                "phase": node["phase"],
                "supervisorStarted": True,
                "providerStarted": bool(node.get("providerProcess")),
                "messaging": "configured" if node.get("messaging") else "unsupported",
            }
        time.sleep(0.05)

    def startup_failed(state):
        node = state["nodes"].get(identifier)
        if node and node["phase"] == "launching":
            record_launch_failure(state, identifier, surface, phase="startup-failed")
    mutate(root, startup_failed, wait=1)
    remove_launch_credential(root, identifier)
    raise OrchestrationError(
        f"Worker supervisor did not acknowledge startup within the bound. Reconcile worker {identifier}, surface {surface}."
    )


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
    report = json.dumps({
        "protocol": REPORT_PROTOCOL,
        "version": 1,
        "workerId": node["id"],
        "generation": node["generation"],
        "state": "completed",
        "summary": "<brief factual result>",
    }, separators=(",", ":"))
    return (
        f"\n\nCMUX Maestro worker contract: bounded generation {node['generation']} for "
        f"worker {node['id']}. Do not spawn except through the installed "
        "cmux-maestro-orchestrate skill. Your final assistant message must be only "
        f"this compact JSON object, with no code fence or prose: {report}. "
        "Replace state with blocked or failed when accurate and replace summary with "
        "a brief factual result. Do not call a tool to submit this report. The supervisor "
        "accepts it only at this generation's exact successful Copilot boundary. A normal "
        "answer or zero exit is not task success."
    )


def parse_final_report(event, node):
    if event.get("type") != "assistant.message":
        return "none", None
    data = event.get("data")
    if not isinstance(data, dict) or data.get("phase") != "final_answer":
        return "none", None
    if data.get("toolRequests") != []:
        return "invalid", None
    content = data.get("content")
    if not isinstance(content, str) or not content:
        return "invalid", None
    try:
        if len(content.encode("utf-8")) > MAX_REPORT_MESSAGE:
            return "invalid", None
        def strict_object(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError("duplicate JSON key")
                result[key] = value
            return result
        report = json.loads(content, object_pairs_hook=strict_object)
    except (json.JSONDecodeError, UnicodeEncodeError, ValueError):
        return "invalid", None
    if not isinstance(report, dict) or set(report) != REPORT_KEYS:
        return "invalid", None
    if (
        report.get("protocol") != REPORT_PROTOCOL
        or type(report.get("version")) is not int
        or report["version"] != 1
        or report.get("workerId") != node["id"]
        or type(report.get("generation")) is not int
        or report["generation"] != node["generation"]
        or report.get("state") not in REPORT_PHASES
    ):
        return "invalid", None
    try:
        summary = bounded_text(
            report.get("summary"), "final report summary", MAX_RESULT, empty=True
        )
    except OrchestrationError:
        return "invalid", None
    return "valid", {
        "generation": report["generation"],
        "state": report["state"],
        "summary": summary,
    }


def event_has_permission_denial(event):
    if event.get("type") != "tool.execution_complete":
        return False
    data = event.get("data")
    if not isinstance(data, dict) or data.get("success") is not False:
        return False
    error = data.get("error")
    if not isinstance(error, dict):
        return False
    code = error.get("code")
    return isinstance(code, str) and code.casefold().replace("-", "_") in {
        "denied", "permission_denied", "permissiondenied",
    }


def terminal_bookkeeping(event):
    if event.get("type") == "assistant.reasoning":
        data = event.get("data")
        return (
            event.get("ephemeral") is True
            and isinstance(data, dict)
            and set(data) <= {"content", "reasoningId", "rte"}
        )
    if event.get("type") == "session.background_tasks_changed":
        return isinstance(event.get("data"), dict) and not event["data"]
    if event.get("type") not in {
        "assistant.turn_end", "session.usage_checkpoint", "assistant.idle",
    }:
        return False
    data = event.get("data")
    return isinstance(data, dict) and not {
        "content", "text", "message", "toolRequests", "toolName", "arguments",
    }.intersection(data)


def worker_environment(worker_id, token, node):
    environment = os.environ.copy()
    if "launchPath" in node:
        environment["PATH"] = node["launchPath"]
    for key in ("CMUX_MAESTRO_MESSAGE_ROOT", "CMUX_MAESTRO_MESSAGE_PEER"):
        environment.pop(key, None)
    environment.update({
        "CMUX_MAESTRO_WORKER_ID": worker_id,
        "CMUX_MAESTRO_CONTROL_TOKEN": token,
        "CMUX_MAESTRO_RUN_ID": node["runId"],
        "CMUX_MAESTRO_GENERATION": str(node["generation"]),
        "CMUX_MAESTRO_ORCHESTRATOR": str(Path(__file__).resolve()),
        "CMUX_MAESTRO_EXECUTION_MODE": node.get("executionMode", "bounded"),
    })
    if node.get("messaging"):
        environment.update({
            "CMUX_MAESTRO_MESSAGE_ROOT": node["messaging"]["routes"],
            "CMUX_MAESTRO_MESSAGE_PEER": message_peer(node),
            "CMUX_WORKSPACE_ID": node["workspaceId"],
        })
    account = (node.get("launchSettings") or {}).get("copilotAccount")
    subscription = resolve_copilot_token(account)
    if subscription is not None:
        environment["COPILOT_GITHUB_TOKEN"] = subscription
    return environment


def run_interactive_session(root, worker_id, token, node):
    copilot = trusted_executable(
        "CMUX_MAESTRO_COPILOT", node.get("copilotExecutable") or "copilot"
    )
    arguments = [
        copilot, "--no-auto-update", "--interactive", node["task"],
        "--session-id", node["copilotSessionId"], "--name", node["label"],
        "-C", node["workingDirectory"],
    ]
    model = (node.get("launchSettings") or {}).get("model")
    if model is not None:
        arguments += ["--model", model]
    for rule in node["toolPolicy"]["allow"]:
        arguments.extend(["--allow-tool", rule])
    for rule in node["toolPolicy"]["deny"]:
        arguments.extend(["--deny-tool", rule])
    if not all(os.isatty(fd) for fd in (0, 1, 2)):
        raise OrchestrationError("Interactive workers require a real terminal; no headless fallback is allowed.")
    if node.get("deliveryProof") is not None:
        try:
            delivery_proof_api()["bind"](node["deliveryProof"], node)
        except (ValueError, OSError) as error:
            raise OrchestrationError("Delivery proof binding failed; use fresh fixtures.") from error
        if node["deliveryProof"]["experimental"]:
            arguments.append("--experimental")
    if node.get("permissionMode") == "yolo" or (node.get("deliveryProof") or {}).get("yolo", False):
        arguments.append("--allow-all")
    if node.get("messaging"):
        if messaging_configuration(root) != node["messaging"]:
            raise OrchestrationError("Messaging installation changed before launch.")
        bind_messaging(node)
        arguments.append("--experimental")
    process = None
    previous_interrupt = signal.signal(signal.SIGINT, lambda _signum, _frame: None)
    try:
        try:
            process = subprocess.Popen(
                arguments, cwd=node["workingDirectory"],
                env=worker_environment(worker_id, token, node),
            )
        except OSError as error:
            raise OrchestrationError(f"Interactive Copilot launch failed: {error}") from error
        provider_start = process_start(process.pid)
        if provider_start is None and process.poll() is None:
            raise OrchestrationError("Interactive Copilot process identity is unavailable.")
        anchor = {"pid": process.pid, "start": provider_start} if provider_start else None

        def attach(state):
            current = authorize(state, worker_id, token)
            if current["generation"] != node["generation"] or current["phase"] != "turn-running":
                raise OrchestrationError("Interactive session ownership changed during launch.")
            current["providerProcess"] = anchor
        mutate(root, attach, wait=2)
        interval = timeout("CMUX_MAESTRO_HEARTBEAT_SECONDS", HEARTBEAT_SECONDS)
        if interval <= 0:
            raise OrchestrationError("Interactive heartbeat interval is invalid.")
        next_heartbeat = time.monotonic() + interval
        while process.poll() is None:
            if time.monotonic() >= next_heartbeat:
                snapshot = read_state(root, wait=2)
                evidence = collect_git_evidence(snapshot, {worker_id})
                def heartbeat(state):
                    current = authorize(state, worker_id, token)
                    if current.get("providerProcess") != anchor or current["generation"] != node["generation"]:
                        raise OrchestrationError("Interactive session ownership changed.")
                    current["updatedAt"] = now()
                    apply_git_evidence(state, evidence)
                mutate(root, heartbeat, wait=2)
                next_heartbeat = time.monotonic() + interval
            time.sleep(0.1)
        code = process.wait()
        def ended(state):
            current = authorize(state, worker_id, token)
            if current.get("providerProcess") != anchor:
                raise OrchestrationError("Interactive session ownership changed before exit.")
            current["phase"] = "process-disappeared" if code == 0 else "turn-failed"
            current["availability"] = "unavailable" if code == 0 else "idle"
            current["result"] = f"Interactive Copilot session exited with status {code}; no task outcome is inferred."
            current["updatedAt"] = now()
        mutate(root, ended, wait=2)
        return {"workerId": worker_id, "interactive": True, "exitCode": code}
    finally:
        signal.signal(signal.SIGINT, previous_interrupt)
        if node.get("messaging") and (process is None or process.poll() is not None):
            retire_messaging(node)


def run_copilot_turn(root, worker_id, token, node):
    copilot = trusted_executable(
        "CMUX_MAESTRO_COPILOT", node.get("copilotExecutable") or "copilot"
    )
    prompt = node["task"] + report_instruction(node)
    arguments = [copilot, "--no-auto-update", "-p", prompt, "--output-format", "json"]
    if node["generation"] > 1:
        if node.get("verifiedBoundaryGeneration") != node["generation"] - 1:
            return (
                "protocol-failed",
                "Exact previous-generation boundary is unavailable for resume.",
                None,
                False,
                None,
            )
        arguments.extend(["--resume", node["copilotSessionId"]])
    else:
        arguments.extend([
            "--session-id", node["copilotSessionId"], "--name", node["label"],
        ])
    for rule in node["toolPolicy"]["allow"]:
        arguments.extend(["--allow-tool", rule])
    for rule in node["toolPolicy"]["deny"]:
        arguments.extend(["--deny-tool", rule])
    arguments.extend(["-C", node["workingDirectory"]])
    environment = worker_environment(worker_id, token, node)
    heartbeat_interval = timeout("CMUX_MAESTRO_HEARTBEAT_SECONDS", HEARTBEAT_SECONDS)
    if heartbeat_interval <= 0:
        return (
            "protocol-failed",
            "Supervisor heartbeat interval is invalid.",
            None,
            False,
            None,
        )
    final = None
    malformed = False
    final_answer_count = 0
    final_report = None
    final_report_invalid = False
    permission_denied = False
    stdout_buffer = bytearray()
    discarding_stdout = False
    stderr_capture = bytearray()
    try:
        process = subprocess.Popen(
            arguments, cwd=node["workingDirectory"], env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
        )
    except OSError as error:
        return "protocol-failed", f"Copilot launch failed: {error}", None, False, None
    assert process.stdout is not None and process.stderr is not None

    def parse_event(line):
        nonlocal final, malformed, final_answer_count, final_report
        nonlocal final_report_invalid, permission_denied
        try:
            event = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError):
            malformed = True
            return
        if not isinstance(event, dict):
            malformed = True
            return
        if final is not None:
            malformed = True
            return
        if (
            final_answer_count
            and event.get("type") != "result"
            and not terminal_bookkeeping(event)
        ):
            final_report_invalid = True
        if event.get("type") == "result":
            timestamp = event.get("timestamp")
            try:
                result_time = parse_date(timestamp, "Copilot result timestamp")
                if (
                    result_time.tzinfo is None
                    or result_time > now_date() + datetime.timedelta(minutes=5)
                ):
                    raise OrchestrationError("Copilot result timestamp is invalid.")
            except OrchestrationError:
                malformed = True
                return
            final = event
        report_status, report = parse_final_report(event, node)
        if report_status != "none":
            final_answer_count += 1
            if report_status == "valid" and final_report is None:
                final_report = report
            else:
                final_report_invalid = True
        if event_has_permission_denial(event):
            permission_denied = True
        text = assistant_text(event)
        if text:
            output = (
                f"{report['state'].capitalize()}: {report['summary']}"
                if report_status == "valid" else text
            )
            try:
                os.write(
                    sys.stdout.fileno(),
                    output.encode("utf-8", errors="replace") + b"\n",
                )
            except OSError:
                pass

    def consume_stdout(chunk, *, eof=False):
        nonlocal malformed, discarding_stdout
        remaining = chunk
        while remaining:
            if discarding_stdout:
                newline = remaining.find(b"\n")
                if newline < 0:
                    return
                remaining = remaining[newline + 1:]
                discarding_stdout = False
                continue
            newline = remaining.find(b"\n")
            if newline < 0:
                if len(stdout_buffer) + len(remaining) > MAX_BYTES:
                    malformed = True
                    stdout_buffer.clear()
                    discarding_stdout = True
                else:
                    stdout_buffer.extend(remaining)
                return
            piece = remaining[:newline]
            remaining = remaining[newline + 1:]
            if len(stdout_buffer) + len(piece) > MAX_BYTES:
                malformed = True
                stdout_buffer.clear()
                continue
            stdout_buffer.extend(piece)
            line = bytes(stdout_buffer)
            stdout_buffer.clear()
            if not line:
                malformed = True
            else:
                parse_event(line)
        if eof and (stdout_buffer or discarding_stdout):
            malformed = True
            stdout_buffer.clear()
            discarding_stdout = False

    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    next_heartbeat = time.monotonic() + heartbeat_interval
    try:
        while selector.get_map():
            wait = max(0.0, min(0.25, next_heartbeat - time.monotonic()))
            for key, _ in selector.select(wait):
                try:
                    chunk = os.read(key.fileobj.fileno(), 65_536)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fileobj)
                    if key.data == "stdout":
                        consume_stdout(b"", eof=True)
                    continue
                if key.data == "stdout":
                    consume_stdout(chunk)
                else:
                    try:
                        os.write(sys.stderr.fileno(), chunk)
                    except OSError:
                        pass
                    available = MAX_RESULT - len(stderr_capture)
                    if available > 0:
                        stderr_capture.extend(chunk[:available])
            if process.poll() is None and time.monotonic() >= next_heartbeat:
                generation = node["generation"]
                supervisor = node.get("supervisor")
                git_evidence = collect_git_evidence(
                    {"nodes": {worker_id: node}}, {worker_id}
                )

                def heartbeat(state):
                    current = state["nodes"].get(worker_id)
                    if (
                        current and current["generation"] == generation
                        and current["phase"] == "turn-running"
                        and current.get("supervisor") == supervisor
                    ):
                        current["updatedAt"] = now()
                        apply_git_evidence(state, git_evidence)
                mutate(root, heartbeat, wait=2)
                next_heartbeat = time.monotonic() + heartbeat_interval
    finally:
        selector.close()
    return_code = process.wait()
    exit_code = final.get("exitCode") if isinstance(final, dict) else None
    valid_protocol = (
        not malformed
        and isinstance(final, dict)
        and final.get("sessionId") == node["copilotSessionId"]
        and type(exit_code) is int
        and exit_code == return_code
    )
    diagnostic = " ".join(
        codecs.decode(bytes(stderr_capture), "utf-8", errors="replace").split()
    )
    suffix = f" Copilot error: {diagnostic[:512]}" if diagnostic else ""
    if not valid_protocol:
        suffix = f" Copilot error: {diagnostic[:512]}" if diagnostic else ""
        return (
            "protocol-failed",
            "Copilot did not produce a valid exact-session turn boundary." + suffix,
            None,
            permission_denied,
            None,
        )
    if return_code != 0:
        return (
            "nonzero-exit",
            f"Copilot turn exited with status {return_code}." + suffix,
            None,
            permission_denied,
            None,
        )
    report_diagnostic = None
    if final_answer_count != 1 or final_report_invalid:
        final_report = None
        if final_answer_count:
            report_diagnostic = "Copilot returned an invalid or conflicting final task report."
    return "success", None, final_report, permission_denied, report_diagnostic


def command_runtime(args, root):
    worker_id = canonical_uuid(args.worker_id, "worker ID")
    pid = os.getpid()
    start = process_start(pid)
    if not start:
        raise OrchestrationError("Cannot establish supervisor process identity.")
    deadline = time.monotonic() + timeout("CMUX_MAESTRO_STARTUP_SECONDS", STARTUP_SECONDS)
    while True:
        state = read_state(root, wait=2)
        node = state["nodes"].get(worker_id)
        launch = state["launches"].get(worker_id)
        if not node or node["phase"] != "launching" or not launch:
            raise OrchestrationError("Worker launch lease is no longer active.")
        if launch["state"] == "starting" and node.get("surfaceId"):
            require_current_surface(node["workspaceId"], node["surfaceId"])
            break
        if time.monotonic() >= deadline:
            raise OrchestrationError("Worker attachment did not finish within the startup bound.")
        time.sleep(0.05)
    if args.token is None:
        args.token = with_store(root, lambda store: store.launch_token(worker_id), wait=2)

    def started(state):
        node = authorize(state, worker_id, args.token)
        launch = state["launches"].get(worker_id)
        if (
            not has_managed_runtime(node) or node["phase"] != "launching"
            or not node["surfaceId"] or not launch
            or launch["state"] != "starting"
            or launch["surfaceId"] != node["surfaceId"]
        ):
            raise OrchestrationError("Worker runtime is not in the launch phase.")
        node["supervisor"] = {"pid": pid, "start": start}
        if node.get("executionMode") == "interactive":
            node["phase"], node["availability"] = "turn-running", "busy"
        else:
            node["phase"], node["availability"] = "turn-queued", "busy"
        node["updatedAt"] = now()
        del state["launches"][worker_id]
        return json.loads(json.dumps(node))
    started_node = mutate(root, started, wait=2)
    remove_launch_credential(root, worker_id)
    def stop_supervisor(_signum, _frame):
        raise SystemExit(143)
    signal.signal(signal.SIGTERM, stop_supervisor)
    signal.signal(signal.SIGHUP, stop_supervisor)
    last_heartbeat = 0.0
    runtime_error = None
    try:
        if started_node.get("executionMode") == "interactive":
            return run_interactive_session(root, worker_id, args.token, started_node)
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
                (
                    boundary, diagnostic, final_report,
                    permission_denied, report_diagnostic,
                ) = run_copilot_turn(
                    root, worker_id, args.token, claimed
                )
                git_evidence = collect_git_evidence(
                    {"nodes": {worker_id: claimed}}, {worker_id}
                )

                def finish(state):
                    current = state["nodes"].get(worker_id)
                    if not current or current["generation"] != generation:
                        return
                    report = current.get("pendingReport")
                    if boundary == "success":
                        current["verifiedBoundaryGeneration"] = generation
                    reports = [
                        item for item in (report, final_report)
                        if item and item.get("generation") == generation
                    ]
                    if boundary == "success" and len(reports) == 1:
                        accepted = reports[0]
                        current["phase"] = REPORT_PHASES[accepted["state"]]
                        current["result"] = accepted["summary"]
                        current["availability"] = "idle"
                    elif boundary == "success" and len(reports) > 1:
                        current["phase"], current["availability"] = "report-missing", "idle"
                        current["result"] = "Conflicting lifecycle report channels were refused."
                    elif boundary == "success" and permission_denied:
                        current["phase"], current["availability"] = "permission-denied", "idle"
                        current["result"] = (
                            "Copilot tool permission was denied; no valid task report was returned."
                        )
                    elif boundary == "success":
                        current["phase"], current["availability"] = "report-missing", "idle"
                        current["result"] = report_diagnostic
                    else:
                        current["phase"], current["availability"] = "turn-failed", "idle"
                        current["result"] = diagnostic
                    current["pendingReport"] = None
                    current["updatedAt"] = now()
                    apply_git_evidence(state, git_evidence)
                mutate(root, finish, wait=2)
                last_heartbeat = time.monotonic()
                continue
            if time.monotonic() - last_heartbeat >= HEARTBEAT_SECONDS:
                git_evidence = collect_git_evidence(state, {worker_id})

                def heartbeat(state):
                    current = state["nodes"].get(worker_id)
                    if current and current.get("supervisor") == {"pid": pid, "start": start}:
                        current["updatedAt"] = now()
                        apply_git_evidence(state, git_evidence)
                mutate(root, heartbeat, wait=2)
                last_heartbeat = time.monotonic()
            time.sleep(0.1)
    except (OrchestrationError, OSError) as error:
        runtime_error = f"Interactive runtime failed ({type(error).__name__}): {error}"[:MAX_RESULT]
        raise
    finally:
        def disappeared(state):
            node = state["nodes"].get(worker_id)
            if (
                node and not node.get("archiving")
                and node.get("supervisor") == {"pid": pid, "start": start}
            ):
                if node.get("executionMode") == "interactive":
                    if node["phase"] in {"process-disappeared", "turn-failed"}:
                        return
                    provider = node.get("providerProcess")
                    if provider and process_start(provider["pid"]) == provider["start"]:
                        node["result"] = "Supervisor ended while the interactive Copilot process remains live."
                        return
                    node["phase"], node["availability"], node["updatedAt"] = (
                        "turn-failed", "idle", now()
                    )
                    node["result"] = runtime_error or "Interactive runtime ended before a clean session exit; no task outcome is inferred."
                    return
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
        if node.get("executionMode") == "interactive":
            raise OrchestrationError("Interactive sessions do not accept managed turn reports.")
        if args.generation != node["generation"]:
            raise OrchestrationError("Late or mismatched worker generation report refused.")
        if node["phase"] != "turn-running" or not process_matches(node):
            raise OrchestrationError("Worker turn is not currently supervised.")
        if node.get("pendingReport") is not None:
            raise OrchestrationError("This worker generation already has a pending report.")
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
    if target.get("executionMode") == "interactive":
        raise OrchestrationError("This worker is interactive. Talk to it directly in its tab; programmatic messaging is not supported yet.")
    cmux.validate_surface(target["workspaceId"], target["surfaceId"])
    if not process_matches(target):
        raise OrchestrationError("Worker supervisor identity is stale; no task was queued.")
    expected = (target["generation"], target["phase"], target.get("supervisor"))
    git_evidence = collect_git_evidence(snapshot, {actor["id"], target["id"]})

    def queue(state):
        current_actor = authorize(state, args.actor_id, args.token)
        current = ensure_owned(state, current_actor, args.worker_id, direct=True)
        if (current["generation"], current["phase"], current.get("supervisor")) != expected:
            raise OrchestrationError("Worker state changed before follow-up could be queued.")
        recoverable = {*REPORT_PHASES.values(), "report-missing", "permission-denied"}
        if (
            current["availability"] != "idle"
            or current["phase"] not in recoverable
            or current.get("verifiedBoundaryGeneration") != current["generation"]
        ):
            raise OrchestrationError(
                "Worker lacks a verified idle boundary for its current generation."
            )
        if not process_matches(current):
            raise OrchestrationError("Worker supervisor identity is stale; no task was queued.")
        current["generation"] += 1
        current["task"], current["result"], current["pendingReport"] = prompt, None, None
        current["phase"], current["availability"], current["updatedAt"] = (
            "turn-queued", "busy", now()
        )
        current_actor["lastControlAt"] = now()
        apply_git_evidence(state, git_evidence)
        return {
            "workerId": current["id"], "sessionId": current["copilotSessionId"],
            "surfaceId": current["surfaceId"], "generation": current["generation"],
            "queued": True,
        }
    return mutate(root, queue)


def command_self_icon(args):
    if args.actor_id is not None or args.token is not None:
        raise OrchestrationError("Self-session selection cannot use a managed actor or token.")
    session = canonical_uuid(args.session_id, "current session ID")
    if args.icon is None and args.color is None:
        raise OrchestrationError("Choose a glyph, a color, or both.")
    glyph = resolve_icon(args.icon) if args.icon is not None else None
    config_path = Path(__file__).resolve().parent / "identity-helper.json"
    try:
        descriptor = os.open(config_path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_size > 4096:
                raise OrchestrationError("The installed identity-helper configuration is not private.")
            config = json.loads(os.read(descriptor, 4097))
        finally:
            os.close(descriptor)
        if set(config) != {"helper"} or not isinstance(config["helper"], str) or not Path(config["helper"]).is_absolute():
            raise ValueError()
    except (OSError, ValueError, TypeError) as error:
        raise OrchestrationError("Refresh Maestro integration to enable standalone session icons.") from error
    helper = trusted_executable("CMUX_MAESTRO_IDENTITY_HELPER", config["helper"])
    arguments = [helper, "icon", "--session-id", session]
    if glyph is not None:
        arguments += ["--icon", glyph]
    if args.color is not None:
        arguments += ["--color", args.color]
    try:
        process = subprocess.run(arguments, capture_output=True, text=True, timeout=5)
        value = json.loads(process.stdout)
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        raise OrchestrationError("Own-session identity verification did not complete.") from error
    if process.returncode != 0 or not isinstance(value, dict) or value.get("ok") is not True:
        raise OrchestrationError("This caller could not prove ownership of that session; no icon was changed.")
    if str(value.get("sessionId", "")).lower() != session or (
        glyph is not None and value.get("iconId") != glyph
    ) or (args.color is not None and value.get("iconColor") != args.color):
        raise OrchestrationError("The identity helper returned a mismatched selection.")
    return {key: value[key] for key in ("sessionId", "iconId", "iconColor") if key in value}


def command_icon(args, root, cmux):
    if args.session_id is not None:
        raise OrchestrationError("Use --self for a standalone session, not managed credentials.")
    if args.icon is None and args.color is None:
        raise OrchestrationError("Choose an icon, a color, or both.")
    icon = resolve_icon(args.icon) if args.icon is not None else None
    snapshot = read_state(root)
    actor = authorize(snapshot, args.actor_id, args.token)
    require_current_surface(actor["workspaceId"], actor["surfaceId"])
    cmux.validate_surface(actor["workspaceId"], actor["surfaceId"])

    def select_icon(state):
        current = authorize(state, args.actor_id, args.token)
        if (current["runId"], current["workspaceId"], current["surfaceId"]) != (
            actor["runId"], actor["workspaceId"], actor["surfaceId"]
        ):
            raise OrchestrationError("Session ownership changed during icon selection.")
        if args.color is not None and args.color not in ICON_COLORS:
            raise OrchestrationError("Choose a color from the palette.")
        if icon is not None:
            current["iconId"] = icon
        if args.color is not None:
            current["iconColor"] = args.color
        # Cosmetic edits must not refresh execution state or Git evidence.
        return {"workerId": current["id"], "iconId": current.get("iconId"),
                "iconColor": current.get("iconColor")}

    return mutate(root, select_icon)


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
            process_matches(node) if has_managed_runtime(node) else True,
        ) for node in targets
    }
    git_evidence = collect_git_evidence(
        snapshot, {actor["id"], *(node["id"] for node in targets)}
    )

    def refresh(state):
        current_actor = authorize(state, args.actor_id, args.token)
        current_actor["lastControlAt"] = now()
        current_targets = descendants(state, current_actor)
        if args.worker_id:
            current_targets = [ensure_owned(state, current_actor, args.worker_id)]
        for node in current_targets:
            previous = snapshot["nodes"].get(node["id"])
            if (
                node["id"] not in observations or previous is None
                or any(node.get(key) != previous.get(key) for key in (
                    "runId", "parentId", "role", "workspaceId", "surfaceId",
                    "copilotSessionId", "generation", "executionMode", "phase",
                    "supervisor", "providerProcess", "messaging",
                ))
                or node["id"] in snapshot["launches"] or node["id"] in state["launches"]
                or node["phase"] == "launching"
            ):
                continue
            surface, process = observations[node["id"]]
            exited = has_managed_runtime(node) and not process and worker_processes_exited(node)
            if has_managed_runtime(node) and not process and not exited:
                continue
            if (node.get("surfaceId") and not surface
                    and not cmux.surface_exists(node["workspaceId"], node["surfaceId"])):
                node["phase"], node["availability"], node["updatedAt"] = (
                    "terminal-disappeared", "unavailable", now()
                )
            elif exited:
                node["phase"], node["availability"], node["updatedAt"] = (
                    "process-disappeared", "unavailable", now()
                )
            if exited:
                retire_messaging(node)
        apply_git_evidence(state, git_evidence)
        return {"runId": current_actor["runId"], "workers": [{
            "workerId": node["id"], "parentId": node["parentId"], "name": node["label"],
            "role": node["role"],
            "executionMode": node.get("executionMode"),
            "iconId": node.get("iconId"),
            "iconColor": node.get("iconColor"),
            "workspaceId": node["workspaceId"], "surfaceId": node["surfaceId"],
            "sessionId": node["copilotSessionId"], "generation": node["generation"],
            "messaging": "configured" if node.get("messaging") and process_matches(node)
                else "offline" if node.get("messaging") else "unsupported",
            "permissionMode": node.get(
                "permissionMode", "yolo" if (node.get("deliveryProof") or {}).get("yolo") else "default"
            ),
            "phase": node["phase"], "availability": node["availability"],
            "result": node["result"],
        } for node in current_targets]}
    return mutate(root, refresh)


def command_focus(args, root, cmux):
    snapshot = read_state(root)
    actor = authorize(snapshot, args.actor_id, args.token)
    target = ensure_owned(snapshot, actor, args.worker_id)
    if not has_managed_runtime(target):
        raise OrchestrationError("Focus requires an owned managed session.")
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
    if actor.get("executionMode") != "interactive":
        cmux.validate_surface(actor["workspaceId"], actor["surfaceId"])
    run_id = actor["runId"]
    identity_keys = (
        "role", "runId", "workspaceId", "surfaceId",
        "copilotSessionId", "generation", "executionMode",
    )
    identity = tuple(actor.get(key) for key in identity_keys)

    def begin(state):
        current = authorize(state, args.actor_id, args.token, allow_archiving=True)
        if tuple(current.get(key) for key in identity_keys) != identity:
            raise OrchestrationError("Coordinator ownership changed during archive.")
        if any(
            launch["runId"] == current["runId"]
            for launch in state["launches"].values()
        ):
            raise OrchestrationError(
                "Run archive is pending because a worker launch is in progress; retry."
            )
        if any(node["runId"] == run_id and node.get("executionMode") == "interactive"
               and not worker_processes_exited(node) for node in state["nodes"].values()):
            raise OrchestrationError("Close interactive sessions normally before archiving; live or uncertain processes will not be interrupted.")
        # Only legacy supervisors need the cooperative stop marker. Interactive
        # archive is read-only until final locked validation and deletion.
        if not any(node["runId"] == run_id and node["role"] == "worker"
                   and node.get("executionMode") != "interactive" for node in state["nodes"].values()):
            return
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
            if node["runId"] == run_id and has_managed_runtime(node)
        ]
        if all(
            worker_processes_exited(node) if node.get("executionMode") == "interactive"
            else not process_matches(node) for node in workers
        ):
            break
        time.sleep(0.05)
    else:
        raise OrchestrationError(
            "Run archive is pending because a worker turn or supervisor remains live; retry."
        )

    def finish(state):
        current = authorize(state, args.actor_id, args.token, allow_archiving=True)
        if tuple(current.get(key) for key in identity_keys) != identity:
            raise OrchestrationError("Coordinator ownership changed during archive.")
        nodes = [node for node in state["nodes"].values() if node["runId"] == run_id]
        if (
            not nodes
            or any(launch["runId"] == run_id for launch in state["launches"].values())
            or any(has_managed_runtime(node) and (
                not worker_processes_exited(node) if node.get("executionMode") == "interactive"
                else process_matches(node)
            ) for node in nodes)
        ):
            raise OrchestrationError("Run archive cannot finish while worker processes are live or uncertain.")
        state["archives"].append(archive_summary(state, run_id))
        state["archives"] = state["archives"][-MAX_ARCHIVES:]
        for node in nodes:
            retire_messaging(node)
            if has_managed_runtime(node) and node.get("surfaceId"):
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
    cwd = assigned_directory(args.cwd)
    metadata = git_display_metadata(cwd) if cwd is not None else absent_git_metadata()
    snapshot = read_state(root)
    roots = [
        node for node in snapshot["nodes"].values()
        if node["role"] == "coordinator" and node["workspaceId"] == workspace
        and node["surfaceId"] == surface
    ]
    if len(roots) != 1:
        raise OrchestrationError("Recovery requires one exact existing coordinator registration.")
    previous = roots[0]
    if previous.get("executionMode") == "interactive":
        raise OrchestrationError("Managed coordinators cannot be adopted by recovery; end and archive their run normally.")
    age = (now_date() - parse_date(previous["lastControlAt"], "last control time")).total_seconds()
    if age <= STALE_SECONDS:
        raise OrchestrationError("The existing coordinator ownership is still current.")
    run_nodes = [
        node for node in snapshot["nodes"].values() if node["runId"] == previous["runId"]
    ]
    if any(
        launch["runId"] == previous["runId"]
        for launch in snapshot["launches"].values()
    ):
        raise OrchestrationError("Stale recovery refuses an in-flight worker launch.")
    for node in run_nodes:
        if has_managed_runtime(node) and (
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
        if any(launch["runId"] == current["runId"] for launch in state["launches"].values()):
            raise OrchestrationError("Stale recovery refuses an in-flight worker launch.")
        current_nodes = {
            node["id"]: node for node in state["nodes"].values()
            if node["runId"] == current["runId"]
        }
        if current_nodes != {node["id"]: node for node in run_nodes}:
            raise OrchestrationError("Run ownership changed during recovery.")
        for node in current_nodes.values():
            if has_managed_runtime(node) and (
                node["phase"] == "launching" or not worker_processes_exited(node)
                or (node.get("surfaceId") and cmux.surface_exists(node["workspaceId"], node["surfaceId"]))
            ):
                raise OrchestrationError("Stale recovery refuses live or uncertain worker ownership.")
        for node in current_nodes.values():
            retire_messaging(node)
        state["archives"].append(archive_summary(state, current["runId"]))
        state["archives"] = state["archives"][-MAX_ARCHIVES:]
        for node_id in current_nodes:
            del state["nodes"][node_id]
        node, token = new_root(workspace, surface, pane, label, cwd, metadata, args.icon, args.color)
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
    commands.add_parser("accounts", help="List configured GitHub account names without credentials")
    commands.add_parser("native-spawn", help="Private session-bound launch ingress; use the native maestro_spawn tool")
    commands.add_parser(
        "launch-settings",
        help="Report whether pinned Maestro account and model settings are ready without revealing them",
    )
    icons = commands.add_parser("icons", help="Search pinned Nerd Font glyphs; no registration required")
    icons.add_argument("--search")
    icons.add_argument("--offset", type=int, default=0)
    icons.add_argument("--limit", type=int, default=20)
    for name in ("register", "recover"):
        command = commands.add_parser(name)
        command.add_argument("--workspace", required=True)
        command.add_argument("--surface", required=True)
        command.add_argument("--name", default="Coordinator")
        command.add_argument("--cwd")
        command.add_argument("--icon")
        command.add_argument("--color", choices=ICON_COLORS)
    coordinator = commands.add_parser(
        "launch-coordinator", help="Launch a new managed messaging coordinator; never adopt the invoking session"
    )
    coordinator.add_argument("--workspace", required=True)
    coordinator.add_argument("--surface", required=True)
    coordinator.add_argument("--name", default="Maestro coordinator")
    coordinator.add_argument("--cwd", required=True)
    coordinator.add_argument("--task", required=True)
    coordinator.add_argument("--account", help="Subscription for this new root; otherwise use the explicit coordinator setting")
    coordinator.add_argument("--model")
    coordinator.add_argument("--allow-tool", action="append", default=[])
    coordinator.add_argument("--deny-tool", action="append", default=[])
    coordinator.add_argument("--yolo", action="store_true", help="Explicitly user-approved root permission mode")
    coordinator.add_argument("--icon")
    coordinator.add_argument("--color", choices=ICON_COLORS)
    spawn = commands.add_parser("spawn")
    spawn.add_argument("--actor-id", required=True)
    spawn.add_argument("--token", required=True)
    spawn.add_argument("--name", required=True)
    spawn.add_argument("--task", required=True)
    spawn.add_argument("--cwd", required=True)
    spawn.add_argument("--allow-tool", action="append", default=[])
    spawn.add_argument("--deny-tool", action="append", default=[])
    spawn.add_argument("--require-pinned-launch-settings", action="store_true")
    spawn.add_argument("--yolo", action="store_true",
                       help="Explicit user-approved coordinator launch with --allow-all; preserves denies")
    spawn.add_argument("--delivery-proof-fixture", help="Opt in to one prepared disposable native-extension fixture")
    spawn.add_argument("--delivery-proof-experimental", action="store_true",
                       help="Opt in to Copilot --experimental for this proof worker only")
    spawn.add_argument("--delivery-proof-yolo", action="store_true",
                       help="Opt in to Copilot --allow-all for this disposable proof worker only; explicit denies remain")
    spawn.add_argument("--icon")
    spawn.add_argument("--color", choices=ICON_COLORS)
    icon = commands.add_parser("icon", help="Choose an icon for the authenticated caller's own session")
    icon.add_argument("--actor-id")
    icon.add_argument("--token")
    icon.add_argument("--self", action="store_true", dest="own_session")
    icon.add_argument("--session-id")
    icon.add_argument("--icon")
    icon.add_argument("--color", choices=ICON_COLORS)
    runtime = commands.add_parser("runtime")
    runtime.add_argument("--worker-id", required=True)
    runtime.add_argument("--token")
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
        if args.command == "accounts":
            print(json.dumps({"ok": True, **command_accounts()}, sort_keys=True))
            return 0
        if args.command == "icons":
            print(json.dumps({"ok": True, **command_icons(args)}, sort_keys=True))
            return 0
        if args.command == "icon" and args.own_session:
            print(json.dumps({"ok": True, **command_self_icon(args)}, sort_keys=True))
            return 0
        root = default_root()
        cmux = None if args.command in {"launch-settings", "runtime", "report"} else Cmux()
        if args.command == "launch-settings":
            output = command_launch_settings(root)
        elif args.command == "register":
            output = command_register(args, root, cmux)
        elif args.command == "launch-coordinator":
            output = command_launch_coordinator(args, root, cmux)
        elif args.command == "recover":
            output = command_recover(args, root, cmux)
        elif args.command == "spawn":
            output = command_spawn(args, root, cmux)
        elif args.command == "native-spawn":
            output = command_native_spawn(root, cmux)
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
        elif args.command == "icon":
            output = command_icon(args, root, cmux)
        else:
            output = command_status(args, root, cmux)
        if args.command == "runtime" and output.get("interactive"):
            print(f"Interactive Copilot session ended (exit {output['exitCode']}).")
            return 0 if output["exitCode"] == 0 else 1
        print(json.dumps({"ok": True, **output}, sort_keys=True))
        return 0
    except CoordinatorLaunchError as error:
        # Like successful registration, this is a private custody receipt, not
        # a public log: failed startup must not discard the owner's capability.
        print(json.dumps({"ok": False, "error": str(error), **error.receipt}, sort_keys=True))
        return 2
    except OrchestrationError as error:
        print(json.dumps({"ok": False, "error": str(error)}, sort_keys=True), file=sys.stderr)
        return 2
    except OSError as error:
        print(json.dumps({"ok": False, "error": launch_failure_message(error)}, sort_keys=True), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
