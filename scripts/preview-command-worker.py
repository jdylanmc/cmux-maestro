#!/usr/bin/env python3
"""Internal, one-command lock guardian for the installer's foreground macOS tools."""

import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
import uuid


def read_marker(fd):
    info = os.fstat(fd)
    if (os.getuid() == 0 or os.geteuid() != os.getuid()
            or not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1 or info.st_size > 4096):
        raise ValueError("Unsafe command-supervisor lock.")
    if info.st_size == 0:
        return None
    record = json.loads(os.pread(fd, info.st_size, 0))
    if (not isinstance(record, dict) or set(record) != {"schema", "state", "token", "supervisor", "group"}
            or type(record["schema"]) is not int or record["schema"] != 1
            or record["state"] not in ("prepared", "running", "finished")
            or not isinstance(record["token"], str) or not re.fullmatch(r"[0-9a-f]{32}", record["token"])
            or any(value is not None and (type(value) is not int or value <= 0)
                   for value in (record["supervisor"], record["group"]))
            or (record["state"] == "prepared" and (record["supervisor"] is not None or record["group"] is not None))
            or (record["state"] != "prepared" and record["supervisor"] is None)):
        raise ValueError("Invalid command-supervisor marker; preserve the lock and transaction.")
    return record


def write_marker(fd, record):
    data = json.dumps(record, sort_keys=True).encode() if record else b""
    if data and os.pwrite(fd, data, 0) != len(data):
        raise OSError("Incomplete command-supervisor marker write.")
    os.ftruncate(fd, len(data))
    os.fsync(fd)


def recover_marker(fd):
    """Called only after independently acquiring the singleton flock."""
    record = read_marker(fd)
    if record and record["state"] == "running" and record["group"] and group_alive(record["group"]):
        raise ValueError(
            f"Command supervisor {record['supervisor']} ended without proving completion of its private "
            f"worker group {record['group']}. Automatic recovery is refused; preserve the lock/receipt "
            "and wait for these specific foreground workers to finish. Never remove the lock to bypass this guard."
        )
    # A surviving guardian would still hold flock. Prepared means no worker was
    # started. An unrecorded group cannot pass the launch gate. For a recorded
    # group, fresh lock ownership plus group absence proves no worker survives.
    if record:
        write_marker(fd, None)


def run(fd, command, *, timeout=120, check=True, capture_output=True, text=False):
    if not capture_output:
        raise ValueError("Supervised commands require captured output.")
    record = read_marker(fd)
    if record and record["state"] != "finished":
        raise ValueError("A prior command has not proved completion; do not overlap mutating workers.")
    token = uuid.uuid4().hex
    write_marker(fd, {"schema": 1, "state": "prepared", "token": token, "supervisor": None, "group": None})
    try:
        guardian = subprocess.Popen(
            [sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), str(fd), token, *command],
            pass_fds=(fd,), start_new_session=True,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=text,
        )
    except OSError:
        # Popen reaps its failed exec child; no guardian could start a worker.
        write_marker(fd, None)
        raise
    try:
        stdout, stderr = guardian.communicate(timeout=timeout)
    except BaseException:
        # Do not terminate the guardian on caller timeout/cancellation. It keeps
        # the lock until its tool AND same-group descendants have finished.
        guardian.stdout.close()
        guardian.stderr.close()
        raise
    record = read_marker(fd)
    if not record or record["token"] != token or record["state"] != "finished":
        raise ValueError(f"Command supervisor {guardian.pid} did not prove worker completion; recovery is blocked.")
    write_marker(fd, None)
    result = subprocess.CompletedProcess(command, guardian.returncode, stdout, stderr)
    if check:
        result.check_returncode()
    return result


def group_alive(group):
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False


def drain_group(group):
    while group_alive(group):
        time.sleep(0.025)


def guard(fd, token, command):
    # Only this controlled Python process inherits the flock descriptor. Tools
    # intentionally get no lock FD; closing their descriptors cannot release it.
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    record = read_marker(fd)
    if not record or record["state"] != "prepared" or record["token"] != token or not command:
        raise ValueError("Missing owned command-supervisor handshake.")
    record.update(state="running", supervisor=os.getpid())
    write_marker(fd, record)
    gate_read, gate_write = os.pipe()
    try:
        try:
            process = subprocess.Popen(
                [sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), "--gate", str(gate_read), *command],
                pass_fds=(gate_read,), close_fds=True, start_new_session=True,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
        except OSError as error:
            record["state"] = "finished"
            write_marker(fd, record)
            return 127, b"", f"Cannot start foreground launcher: {error}\n".encode()
        record["group"] = process.pid
        write_marker(fd, record)
        # The tool cannot execute before its process group is durably recorded.
        # If the guardian dies before this byte, EOF makes the launcher exit.
        os.write(gate_write, b"G")
    finally:
        os.close(gate_read)
        os.close(gate_write)
    stdout, stderr = process.communicate()
    # EOF/direct-child exit alone is insufficient: a child may close all FDs
    # and leave a still-mutating descendant in its dedicated process group.
    drain_group(process.pid)
    record["state"] = "finished"
    write_marker(fd, record)
    return process.returncode if process.returncode >= 0 else 128 - process.returncode, stdout, stderr


def main():
    if sys.argv[1] == "--gate":
        fd = int(sys.argv[2])
        allowed = os.read(fd, 1) == b"G"
        os.close(fd)
        if allowed:
            os.execv(sys.argv[3], sys.argv[3:])
        return 0
    fd, token, *command = sys.argv[1:]
    code, stdout, stderr = guard(int(fd), token, command)
    for output_fd, data in ((1, stdout), (2, stderr)):
        try:
            while data:
                data = data[os.write(output_fd, data):]
        except BrokenPipeError:
            pass
    return code


if __name__ == "__main__":
    sys.exit(main())
