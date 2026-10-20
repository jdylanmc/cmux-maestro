#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
OUTPUT="$ROOT/.build/hook-smoke"
mkdir -p "$OUTPUT"

SOURCES=(
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotIdentityRecord.swift"
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotWorktree.swift"
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotLocationRecord.swift"
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotPaths.swift"
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotFileAccess.swift"
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotIdentityVerifier.swift"
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotSessionNameParser.swift"
    "$ROOT/CMUXMaestroCopilotHook/CopilotHookRecorder.swift"
    "$ROOT/CMUXMaestroCopilotHook/main.swift"
)
xcrun swiftc -swift-version 5 -strict-concurrency=complete -enable-upcoming-feature InferSendableFromCaptures \
    "${SOURCES[@]}" -o "$OUTPUT/production-hook"
xcrun swiftc -swift-version 5 -strict-concurrency=complete -enable-upcoming-feature InferSendableFromCaptures \
    -D MAESTRO_HOOK_TESTING \
    "${SOURCES[@]}" -o "$OUTPUT/synthetic-hook"

python3 - "$OUTPUT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

output = Path(sys.argv[1])
fixture = output / str(uuid.uuid4())
foreign = fixture / "foreign"
foreign.mkdir(parents=True)
session = "11111111-1111-4111-8111-111111111111"
source = fixture / "state" / session
source.mkdir(parents=True)
(source / "inuse.9001.lock").write_bytes(b"")
environment = {
    "PATH": "/usr/bin:/bin",
    "CMUX_SURFACE_ID": "22222222-2222-4222-8222-222222222222",
    "CMUX_WORKSPACE_ID": "33333333-3333-4333-8333-333333333333",
}

def invoke(binary, arguments, payload, env=environment):
    result = subprocess.run(
        [str(output / binary), *arguments], input=payload, cwd=foreign,
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5,
    )
    assert result.returncode == 0 and not result.stdout and not result.stderr, result

try:
    args = ["--fixture-root", str(fixture)]
    invoke("synthetic-hook", args, json.dumps({"sessionId": session}).encode())
    binding = fixture / "integration" / "bindings" / (session + ".json")
    record = json.loads(binding.read_text())
    assert record["ownerPID"] == 9001 and record["ownerStartSeconds"] == 1
    assert record["sessionID"].lower() == session
    assert abs(record["recordedAt"] - 1000.002) < 0.001
    assert binding.stat().st_mode & 0o777 == 0o600
    # A session launched outside Git follows a file it actually touches.
    repository = fixture / "project"
    (repository / ".git/objects").mkdir(parents=True)
    (repository / ".git/refs").mkdir()
    (repository / ".git/HEAD").write_text("ref: refs/heads/topic\n")
    (repository / "source.swift").write_text("")
    (source / "workspace.yaml").write_text("cwd: /\n")
    invoke("synthetic-hook", args, json.dumps({
        "sessionId": session, "toolName": "view",
        "toolArgs": {"path": str(repository / "source.swift")},
    }).encode())
    location_file = fixture / "integration/locations" / (session + ".json")
    location = json.loads(location_file.read_text())
    assert location["active"]["worktree"]["repository"] == "project", location
    assert location["active"]["current"] is True
    assert str(repository) not in location_file.read_text()
    touched = location["active"]["touchedAt"]
    invoke("synthetic-hook", args, json.dumps({"sessionId": session, "prompt": "DO_NOT_PERSIST_PROMPT"}).encode())
    location = json.loads(location_file.read_text())
    assert location["active"]["current"] is False, location
    assert location["active"]["touchedAt"] == touched
    other = fixture / "second"
    (other / ".git/objects").mkdir(parents=True)
    (other / ".git/refs").mkdir()
    (other / ".git/HEAD").write_text("ref: refs/heads/other\n")
    invoke("synthetic-hook", args, json.dumps({
        "sessionId": session, "toolName": "bash",
        "toolArgs": {"command": f"cd '{other}' && echo DO_NOT_PERSIST_COMMAND"},
    }).encode())
    location = json.loads(location_file.read_text())
    assert location["active"]["worktree"]["repository"] == "second", location
    assert location["active"]["current"] is True
    assert "DO_NOT_PERSIST_COMMAND" not in location_file.read_text()
    # Supplied path hints take precedence over opaque shell content. Last verified hint wins.
    invoke("synthetic-hook", args, json.dumps({
        "sessionId": session, "toolName": "bash", "arguments": {"command": "DO_NOT_PARSE"},
        "shellToolInfo": {"possiblePaths": [str(other), str(repository)]},
    }).encode())
    location = json.loads(location_file.read_text())
    assert location["active"]["worktree"]["repository"] == "project"
    assert location["active"]["current"] is True
    # Unknown/non-repository tool paths cannot erase the last verified touch.
    for hints in [["/maestro-missing-" + str(uuid.uuid4())], ["/"], [str(other)] * 9]:
        invoke("synthetic-hook", args, json.dumps({
            "sessionId": session, "toolName": "bash", "toolArgs": {},
            "shellToolInfo": {"possiblePaths": hints},
        }).encode())
        assert json.loads(location_file.read_text())["active"] == location["active"]
    # A poisoned Git entry is unknown, never the enclosing repository.
    nested = repository / "unsafe"
    nested.mkdir()
    (nested / ".git").symlink_to(other / ".git", target_is_directory=True)
    invoke("synthetic-hook", args, json.dumps({
        "sessionId": session, "toolName": "glob", "toolArgs": {"path": str(nested)},
    }).encode())
    assert json.loads(location_file.read_text())["active"] == location["active"]
    # New files resolve through their nearest existing directory, and array paths stay bounded.
    invoke("synthetic-hook", args, json.dumps({
        "sessionId": session, "toolName": "create", "toolArgs": {"path": str(other / "new/deep/file.swift")},
    }).encode())
    assert json.loads(location_file.read_text())["active"]["worktree"]["repository"] == "second"
    assert location_file.stat().st_size <= 2048
    assert location_file.stat().st_mode & 0o777 == 0o600
    for forbidden in [str(fixture), "source.swift", "DO_NOT_PERSIST", "command", "toolArgs", "argv"]:
        assert forbidden not in location_file.read_text(), forbidden
    # Lexically removing '..' across a symlink must not manufacture a touch in project.
    (other / "subdir").mkdir()
    (other / "source.swift").write_text("")
    (repository / "link").symlink_to(other / "subdir", target_is_directory=True)
    ambiguous = str(repository / "link/../source.swift")
    assert Path(ambiguous).resolve() == other.resolve() / "source.swift"
    for tool in [
        {"toolName": "view", "toolArgs": {"path": ambiguous}},
        {"toolName": "bash", "toolArgs": {"command": f"cd -P '{repository}/link/..' && pwd"}},
    ]:
        invoke("synthetic-hook", args, json.dumps({"sessionId": session, **tool}).encode())
        assert json.loads(location_file.read_text())["active"]["worktree"]["repository"] == "second"
    # Shell words can continue after a closing quote; never publish just the quoted prefix.
    child = repository / "child"
    (child / ".git/objects").mkdir(parents=True)
    (child / ".git/refs").mkdir()
    (child / ".git/HEAD").write_text("ref: refs/heads/nested\n")
    actual = subprocess.check_output(
        ["/bin/sh", "-c", f'cd "{repository}"/child && /bin/pwd'], text=True, timeout=5,
    ).strip()
    assert Path(actual).resolve() == child.resolve()
    prior_touch = json.loads(location_file.read_text())["active"]
    for command in [
        f'cd "{repository}"/child && git status',
        f"cd '{repository}'/child && git status",
        f'cd "{repository}" extra && git status',
        f"cd {repository} || git status",
    ]:
        invoke("synthetic-hook", args, json.dumps({
            "sessionId": session, "toolName": "bash", "toolArgs": {"command": command},
        }).encode())
        assert json.loads(location_file.read_text())["active"] == prior_touch
    # A placement change cannot keep a previous binding's touch current.
    changed = {**environment, "CMUX_SURFACE_ID": "44444444-4444-4444-8444-444444444444"}
    invoke("synthetic-hook", args, json.dumps({
        "sessionId": session, "toolName": "view", "toolArgs": {"path": "/"},
    }).encode(), changed)
    assert json.loads(location_file.read_text())["active"]["current"] is False
    # Wrong session binding cannot modify or manufacture another session's evidence.
    prior = location_file.read_bytes()
    stranger = str(uuid.uuid4())
    invoke("synthetic-hook", args, json.dumps({
        "sessionId": stranger, "toolName": "view", "toolArgs": {"path": str(repository)},
    }).encode())
    assert location_file.read_bytes() == prior
    assert not (location_file.parent / (stranger + ".json")).exists()
    # Positive binding is the negative-control proof the compiled runner executed.
    binding.unlink()
    for payload in (b"not-json", b"{}", b'{"sessionID":"unsupported"}', b"x" * 65537):
        invoke("synthetic-hook", args, payload)
        assert not binding.exists()
        assert json.loads((fixture / "integration/hook-status.json").read_text()) == {"status": "invalidInput"}
    for key in ("MAESTRO_NATIVE_DISABLED",):
        invoke("production-hook", [], b"{}", {**environment, key: "1"})
    invoke("production-hook", ["--unsupported"], b"{}")
    # There is no production test-root flag. This must not create a binding.
    invoke("production-hook", args, json.dumps({"sessionId": session}).encode())
    assert not binding.exists()
    print("PASS: compiled hook, exact binding, active paths/cd, turn reset, bounded storage, privacy, zero output, production gate")
finally:
    shutil.rmtree(fixture)
PY
