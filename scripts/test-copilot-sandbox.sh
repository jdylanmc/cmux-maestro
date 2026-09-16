#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
OUTPUT="$ROOT/.build/copilot-sandbox"
mkdir -p "$OUTPUT"

xcrun swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotIdentityRecord.swift" \
    "$ROOT/CMUXMaestroPreview/CopilotShared/CopilotFileAccess.swift" \
    "$ROOT/scripts/CopilotSandboxTestMain.swift" \
    -o "$OUTPUT/shared-helper-probe"

python3 - "$OUTPUT" <<'PY'
import json
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time
import uuid

output = Path(sys.argv[1])
fixture = output / ("fixture-" + str(uuid.uuid4()))
allowed = fixture / "ancestor" / "deep" / "allowed"
process = None
timeout = None
race = None
stop_race = threading.Event()
race_started = threading.Event()
race_errors = []
race_swaps = [0]

def sample(directory, text):
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "sample"
    path.write_text(text)
    path.chmod(0o600)

def replace_ancestor():
    (allowed / "anchored").rename(allowed / "anchored-original")
    (allowed / "anchored").symlink_to(allowed / "redirected", target_is_directory=True)

def swap_ancestor():
    active = allowed / "racing"
    parked = allowed / "racing-original"
    try:
        while not stop_race.is_set():
            active.rename(parked)
            active.symlink_to(allowed / "redirected", target_is_directory=True)
            race_swaps[0] += 1
            race_started.set()
            time.sleep(0.0002)
            active.unlink()
            parked.rename(active)
            time.sleep(0.0002)
    except Exception:
        race_errors.append(True)
        race_started.set()

try:
    sample(allowed / "target", "ALLOWED")
    (allowed / "target" / "extra").write_text("listing-bound")
    sample(allowed / "anchored" / "leaf", "ORIGINAL")
    sample(allowed / "racing" / "leaf", "ORIGINAL")
    sample(allowed / "redirected" / "leaf", "REDIRECTED")
    sample(fixture / "ancestor" / "deep" / "sibling", "SIBLING")
    (fixture / "ancestor" / "private").write_text("ANCESTOR")
    (allowed / "ancestor-link").symlink_to(allowed, target_is_directory=True)
    (allowed / "target-link").symlink_to(allowed / "target", target_is_directory=True)
    orchestration = fixture / "Library/Application Support/CMUXMaestroPreview/Orchestration"
    observer = orchestration / "observer"
    observer.mkdir(parents=True)
    (observer / "current.json").write_text('{"version":1}\n')
    for relative, text in [
        ("control/state.json", "PRIVATE STATE"),
        ("bin/controller", "PRIVATE BINARY"),
        ("tasks/prompt", "PRIVATE PROMPT"),
        ("results/raw", "PRIVATE RESULT"),
    ]:
        path = orchestration / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    for path in orchestration.rglob("*"):
        if path.is_file():
            path.chmod(0o600)

    # Deny data access throughout the synthetic ancestors. Runtime startup
    # remains allowed outside the fixture; only the deep leaf is readable
    # inside it. This needs no signing, entitlement changes or OS container.
    ancestors = [path for path in allowed.parents if path == fixture or fixture in path.parents]
    ancestor_rules = " ".join("(literal " + json.dumps(str(path)) + ")" for path in ancestors)
    profile = (
        "(version 1)\n"
        "(allow default)\n"
        f"(deny file-read-data {ancestor_rules})\n"
        f"(deny file-read-data (subpath {json.dumps(str(fixture))}))\n"
        f"(deny file-write* (subpath {json.dumps(str(fixture))}))\n"
        f"(allow file-read-data (subpath {json.dumps(str(allowed))}))\n"
        f"(allow file-read-data (subpath {json.dumps(str(observer))}))\n"
    )
    process = subprocess.Popen(
        ["/usr/bin/sandbox-exec", "-p", profile, str(output / "shared-helper-probe"), str(fixture)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1,
    )
    # Bounded shutdown is checked below; daemon fallback prevents a failed
    # controller stop from hanging the test process after reporting failure.
    timeout = threading.Timer(30, process.kill)
    timeout.daemon = True
    timeout.start()
    lines = []
    for line in process.stdout:
        line = line.rstrip()
        lines.append(line)
        print(line)
        if line == "READY_ANCHOR":
            replace_ancestor()
            process.stdin.write("continue\n")
            process.stdin.flush()
        elif line == "READY_RACE":
            race = threading.Thread(target=swap_ancestor, daemon=True)
            race.start()
            if not race_started.wait(timeout=5):
                raise RuntimeError("ancestor-swap controller did not start")
            process.stdin.write("continue\n")
            process.stdin.flush()
    process.wait(timeout=5)
    stderr = process.stderr.read()
    if stderr:
        print(stderr, file=sys.stderr)
    if process.returncode != 0 or "RESULT failures=0" not in lines:
        raise RuntimeError(f"actual shared-helper sandbox regression failed (exit={process.returncode})")
finally:
    primary_error = sys.exc_info()[1]
    cleanup_errors = []
    if timeout is not None:
        timeout.cancel()
    stop_race.set()
    if race is not None:
        try:
            race.join(timeout=5)
        except Exception as error:
            cleanup_errors.append(f"ancestor-swap controller join failed: {error}")
        if race.is_alive():
            cleanup_errors.append("ancestor-swap controller did not stop within five seconds")
        elif race_errors or race_swaps[0] == 0:
            cleanup_errors.append("ancestor-swap controller did not complete its safety check")
    elif primary_error is None:
        cleanup_errors.append("ancestor-swap controller was not run")
    try:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=5)
    except Exception as error:
        cleanup_errors.append(f"owned helper process cleanup failed: {error}")
    if race is None or not race.is_alive():
        try:
            if fixture.exists() or fixture.is_symlink():
                shutil.rmtree(fixture)
        except Exception as error:
            cleanup_errors.append(f"fixture cleanup failed at {fixture}: {error}")
    else:
        cleanup_errors.append(f"fixture retained at {fixture}: controller still running")
    if cleanup_errors:
        message = "; ".join(cleanup_errors)
        if primary_error is None:
            raise RuntimeError(message)
        print(f"ADDITIONAL CLEANUP FAILURE: {message}", file=sys.stderr)
print("PASS: real shared helper under narrow Seatbelt grants; fixture removed; no App Sandbox container created")
PY
