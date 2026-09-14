#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
OUTPUT="$ROOT/.build/hook-smoke"
mkdir -p "$OUTPUT"

SOURCES=(
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotIdentityRecord.swift"
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotPaths.swift"
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotFileAccess.swift"
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotIdentityVerifier.swift"
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
    # Positive binding is the negative-control proof the compiled runner executed.
    binding.unlink()
    for payload in (b"not-json", b"{}", b'{"sessionID":"unsupported"}', b"x" * 65537):
        invoke("synthetic-hook", args, payload)
        assert not binding.exists()
        assert json.loads((fixture / "integration/hook-status.json").read_text()) == {"status": "invalidInput"}
    for key in ("CMUX_COPILOT_HOOKS_DISABLED", "MAESTRO_NATIVE_DISABLED"):
        invoke("production-hook", [], b"{}", {**environment, key: "1"})
    invoke("production-hook", ["--unsupported"], b"{}")
    # There is no production test-root flag. This must not create a binding.
    invoke("production-hook", args, json.dumps({"sessionId": session}).encode())
    assert not binding.exists()
    print("PASS: compiled hook, foreign cwd, synthetic ownership, bounded malformed input, zero output, production gate")
finally:
    shutil.rmtree(fixture)
PY
