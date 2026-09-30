#!/usr/bin/env python3
"""Synthetic sessionless provider for compiled-bridge process-death tests only."""
import json
import os
from pathlib import Path
import shutil
import sys
import time

provider = Path(os.environ["COPILOT_HOME"])
home = provider.parent
isolated = home.name.startswith("cmux-maestro-source-")
root = home / "Library/Application Support/CMUXMaestroPreview/Copilot"
cache = provider / "installed-plugins/_direct/plugin"
installed = provider / ".fixture-provider-installed"
names = ("plugin.json", "hooks.json", "skills/cmux-maestro-orchestrate/SKILL.md",
         "skills/maestro-icon/SKILL.md", "skills/maestro/SKILL.md")


def plugin():
    return {"name": "cmux-maestro-native", "marketplace": "", "enabled": True,
            "directSourceId": "fixture-stable-source"}


def discover():
    hooks = []
    settings_file = provider / "settings.json"
    settings = json.loads(settings_file.read_text()) if settings_file.exists() else {}
    for path, origin, source in [
        (provider / "hooks/cmux-maestro-observer.json", "user", "hooks/cmux-maestro-observer.json"),
        (cache / "hooks.json", "plugin", "cmux-maestro-native"),
    ]:
        if not path.exists() or (origin == "plugin" and not installed.exists()):
            continue
        document = json.loads(path.read_text())
        disabled = document.get("disableAllHooks", False)
        for event in document.get("hooks", {}):
            key = "fixture-key-" + event
            hooks.append({"hookType": event, "origin": origin, "source": source,
                          "enabled": not disabled and not settings.get("disableAllHooks", False)
                                     and key not in settings.get("disabledHooks", []),
                          "disableKey": None if disabled else key})
    return {"hooks": hooks, "warnings": [], "errors": []}


while True:
    header = sys.stdin.buffer.readline()
    if not header:
        break
    length = int(header.decode().split(": ", 1)[1])
    assert sys.stdin.buffer.readline() == b"\r\n"
    request = json.loads(sys.stdin.buffer.read(length))
    method = request["method"]
    if method == "status.get":
        result = {"version": "1.0.89", "protocolVersion": 3}
    elif method == "plugins.list":
        result = {"plugins": [plugin()] if installed.exists() else []}
    elif method == "hooks.discover":
        result = discover()
    elif method == "plugins.install":
        if not isolated:
            source = Path(request["params"]["source"])
            assert source == root / "plugin"
            payload = {name: (source / name).read_bytes() if (source / name).exists() else None for name in names}
            counter = home / "provider-installs"
            count = int(counter.read_text()) + 1 if counter.exists() else 1
            counter.write_text(str(count))
            gate = home / "provider-gate.json"
            gated = gate.exists() and json.loads(gate.read_text())["install"] == count
            if gated:
                (home / "provider-ready.json").write_text(json.dumps({
                    "provider": os.getpid(), "providerGroup": os.getpgrp(),
                    "bridge": os.getppid(), "bridgeGroup": os.getpgid(os.getppid()),
                }))
                with (home / "provider-release").open("rb", buffering=0) as release:
                    assert release.read(1) == b"G"
            for name, data in payload.items():
                target = cache / name
                if data is not None:
                    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    target.write_bytes(data)
                    target.chmod(0o600)
                else:
                    target.unlink(missing_ok=True)
            installed.write_text("installed")
            if gated:
                (home / "provider-late-write.json").write_text(json.dumps({"time": time.monotonic_ns(), "install": count}))
        result = {"plugin": plugin()}
    elif method == "plugins.uninstall":
        assert request["params"]["directSourceId"] == "fixture-stable-source"
        if cache.exists():
            shutil.rmtree(cache)
        installed.unlink(missing_ok=True)
        result = None
    else:
        raise AssertionError(method)
    body = json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}).encode()
    try:
        sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        os._exit(0)
