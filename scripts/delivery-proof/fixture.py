#!/usr/bin/env python3
"""Disposable native-extension proof fixtures. Does not launch or authenticate Copilot."""

import argparse
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import uuid

SOURCE = Path(__file__).resolve().parents[2]
BASE = SOURCE / ".build" / "dp"
PEERS = ("a", "b")


def check_directory(path, private=False):
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or info.st_mode & (0o077 if private else 0o022)):
        raise ValueError("Proof directory ownership or permissions are unsafe.")


def check_chain(path):
    relative = path.relative_to(SOURCE)
    current = SOURCE
    check_directory(current)
    for part in relative.parts:
        current /= part
        check_directory(current)


def read_private(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or info.st_size > 8192):
            raise ValueError("Proof file ownership, permissions, or size are unsafe.")
        return json.loads(stream.read(8193))


def write_new(path, value):
    data = json.dumps(value, sort_keys=True).encode()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)


def validate_fixture(fixture, cwd, *, fresh=False):
    path = Path(fixture)
    if not path.is_absolute() or path != Path(os.path.abspath(path)):
        raise ValueError("Proof fixture must be an absolute canonical path.")
    relative = path.relative_to(BASE)
    if (len(relative.parts) != 2 or not re.fullmatch(r"[a-z0-9]{1,8}", relative.parts[0])
            or relative.parts[1] not in PEERS or path != Path(cwd)):
        raise ValueError("Use one prepared proof fixture as the worker working directory.")
    check_chain(path)
    root = path.parent
    check_directory(root, private=True)
    check_directory(path, private=True)
    marker = read_private(root / "proof.json")
    if marker != {"version": 1, "source": str(SOURCE)}:
        raise ValueError("Proof fixture belongs to another source checkout.")
    check_directory(path / ".git")
    if fresh and os.path.lexists(root / f"{path.name}.json"):
        raise ValueError("Proof participant has already been bound; prepare a fresh fixture.")
    return {"fixture": str(path), "experimental": False}


def bind(config, node):
    fixture = Path(config["fixture"])
    validate_fixture(str(fixture), node["workingDirectory"])
    for field in ("workspaceId", "copilotSessionId"):
        value = node[field]
        if str(uuid.UUID(value)) != value:
            raise ValueError("Proof launch identity must be a canonical UUID.")
    root, peer = fixture.parent, fixture.name
    other = root / f"{'b' if peer == 'a' else 'a'}.json"
    if other.exists() and read_private(other)["workspaceId"] != node["workspaceId"]:
        raise ValueError("Proof participants must share one CMUX workspace.")
    # Exclusive creation fences accidental reuse; failed launches need a fresh fixture.
    write_new(root / f"{peer}.json", {
        "peer": peer,
        "workspaceId": node["workspaceId"],
        "sessionId": node["copilotSessionId"],
        "capability": secrets.token_hex(32),
    })


def prepare(name):
    if not re.fullmatch(r"[a-z0-9]{1,8}", name):
        raise ValueError("Fixture name must contain 1–8 lowercase letters/digits.")
    for directory in (SOURCE / ".build", BASE):
        directory.mkdir(mode=0o700, exist_ok=True)
        check_chain(directory)
    root = BASE / name
    if len(os.fsencode(root / "a.sock")) > 100:
        raise ValueError("Checkout path is too long for a portable Unix socket.")
    root.mkdir(mode=0o700)
    write_new(root / "proof.json", {"version": 1, "source": str(SOURCE)})
    for peer in PEERS:
        fixture = root / peer
        fixture.mkdir(mode=0o700)
        subprocess.run(["git", "init", "--quiet", str(fixture)], check=True)
        extension = fixture
        for part in (".github", "extensions", "maestro-delivery-proof"):
            extension /= part
            extension.mkdir(mode=0o700)
        entry = (
            'import { joinSession } from "@github/copilot-sdk/extension";\n'
            f'import {{ start }} from {json.dumps((SOURCE / "scripts/delivery-proof/adapter.mjs").as_uri())};\n'
            f'start({{ root: {json.dumps(str(root))}, peer: "{peer}", joinSession }})'
            '.catch(() => { console.error("Maestro delivery proof failed to start."); process.exit(1); });\n'
        )
        target = extension / "extension.mjs"
        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write(entry)
    return {"root": str(root), "a": str(root / "a"), "b": str(root / "b")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare"])
    parser.add_argument("--name", required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(prepare(args.name), sort_keys=True))
    except (ValueError, OSError, subprocess.CalledProcessError):
        parser.exit(1, "Proof preparation refused; use a new short name and an owned checkout.\n")


if __name__ == "__main__":
    main()
