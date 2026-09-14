#!/usr/bin/env python3
"""User-owned local preview transactions. No build, plugin install, or host control."""

import argparse
from contextlib import contextmanager
import ctypes
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("preview_metadata", ROOT / "scripts/verify-build-metadata.py")
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)
spec = importlib.util.spec_from_file_location("preview_command_worker", ROOT / "scripts/preview-command-worker.py")
command_worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(command_worker)
DEFAULT_NAME = "CMUX Maestro Preview.app"
STATE_NAME = ".cmux-maestro-preview-install"
EXTENSION = Path("Contents/Extensions/CMUX Maestro Preview Extension.appex")
DEVELOPMENT_APP = ROOT / ".build/adhoc/Build/Products/Debug" / DEFAULT_NAME
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def safe_path(path, *, owner=False):
    """Never canonicalize away an unsafe component before checking it."""
    require(path.is_absolute() and ".." not in path.parts, "An absolute path without '..' is required.")
    for component in [*reversed(path.parents), path]:
        if not component.exists() and not component.is_symlink():
            continue
        info = component.lstat()
        require(not stat.S_ISLNK(info.st_mode), f"Symlink component refused: {component}")
        require(info.st_uid in (0, os.getuid()) and not info.st_mode & 0o022,
                f"Untrusted owner or writable path component: {component}")
    if owner and path.exists():
        require(path.lstat().st_uid == os.getuid(), f"Path is not owned by this user: {path}")


def safe_tree(app, *, deleting=False):
    safe_path(app, owner=True)
    require(app.is_dir(), "Expected an owned app directory.")
    def failed(error):
        raise error
    for directory, folders, files in os.walk(app, followlinks=False, onerror=failed):
        for name in folders + files:
            path = Path(directory) / name
            info = path.lstat()
            require(info.st_uid == os.getuid(), "Foreign owner in app bundle.")
            if stat.S_ISLNK(info.st_mode):
                if deleting:
                    # rmtree unlinks, never follows these entries. A terminated
                    # ditto/removal may leave legitimate framework links dangling.
                    continue
                target = os.readlink(path)
                require(not os.path.isabs(target), "Absolute bundle symlink refused.")
                resolved = path.resolve(strict=True)
                require(resolved.is_relative_to(app), "Escaping bundle symlink refused.")
            else:
                require(stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode),
                        "Special file in app bundle.")
                require(not info.st_mode & 0o022, "Writable-by-others app component.")
                require(stat.S_ISDIR(info.st_mode) or info.st_nlink == 1, "Hard-linked app file refused.")


def digest(app):
    safe_tree(app)
    result = hashlib.sha256()
    for path in sorted(app.rglob("*")):
        info = path.lstat()
        header = [str(path.relative_to(app)), stat.S_IMODE(info.st_mode),
                  info.st_size if stat.S_ISREG(info.st_mode) else 0,
                  "link" if path.is_symlink() else "dir" if path.is_dir() else "file"]
        result.update(json.dumps(header, separators=(",", ":")).encode() + b"\0")
        if path.is_symlink():
            result.update(os.readlink(path).encode() + b"\0")
        elif path.is_file():
            with path.open("rb") as stream:
                while block := stream.read(1024 * 1024):
                    result.update(block)
            result.update(b"\0")
    return result.hexdigest()


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def directory_identity(path):
    safe_path(path, owner=True)
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode), "Owned slot is not a directory.")
    return [info.st_dev, info.st_ino]


def atomic_rename(source, destination, *, exchange=False):
    """Darwin renamex_np: no missing-destination interval and no unsafe fallback."""
    require(sys.platform == "darwin", "Local preview installation requires macOS.")
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    rename = library.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 2 if exchange else 4):
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))
    sync_directory(source.parent)
    sync_directory(destination.parent)


class MacOperations:
    install_lock_fd = None

    def run(self, command, **kwargs):
        kwargs.setdefault("check", True)
        kwargs.setdefault("capture_output", True)
        mutating = command[0] == "/usr/bin/ditto" or command[:2] in (
            [LSREGISTER, "-f"], [LSREGISTER, "-u"],
            ["/usr/bin/pluginkit", "-a"], ["/usr/bin/pluginkit", "-r"],
        )
        if mutating:
            require(self.install_lock_fd is not None, "Mutating tools require the active install lock.")
            return command_worker.run(self.install_lock_fd, command, timeout=120, **kwargs)
        return subprocess.run(command, timeout=120, **kwargs)

    def verify(self, app, *, current):
        return metadata.verify_local_preview(app, current=current, runner=self.run)

    def copy(self, source, destination):
        self.run(["/usr/bin/ditto", str(source), str(destination)])

    def sync(self, app):
        for directory, _, files in os.walk(app, followlinks=False):
            for name in files:
                path = Path(directory) / name
                if not path.is_symlink():
                    with path.open("rb") as stream:
                        os.fsync(stream.fileno())
            sync_directory(Path(directory))

    def move(self, source, destination, *, exchange=False):
        atomic_rename(source, destination, exchange=exchange)

    def assert_idle(self, *apps):
        """Check same-user executable paths, not process names or command text."""
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        library.proc_pidpath.restype = ctypes.c_int
        listing = self.run(["/bin/ps", "-ax", "-o", "pid=", "-o", "uid="], text=True)
        for line in listing.stdout.splitlines():
            pid, uid = map(int, line.split())
            if uid != os.getuid() or pid == os.getpid():
                continue
            buffer = ctypes.create_string_buffer(4096)
            length = library.proc_pidpath(pid, buffer, len(buffer))
            if length <= 0:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    continue
                raise ValueError(f"Cannot verify executable for live process {pid}; retry when it exits.")
            executable = Path(os.fsdecode(buffer.value)).resolve()
            if any(executable.is_relative_to(app) for app in apps):
                raise ValueError(
                    f"Preview executable is still running (PID {pid}). Close the containing app normally, "
                    "select CMUX's Default sidebar, and wait for helper calls to finish. Retry when this "
                    "specific preview process exits; do not restart CMUX or existing CLI sessions."
                )

    def app_paths(self):
        """Narrow LaunchServices query for this bundle ID, not a registry dump."""
        cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        ls = ctypes.CDLL("/System/Library/Frameworks/CoreServices.framework/CoreServices")
        pointer = ctypes.c_void_p
        cf.CFStringCreateWithCString.argtypes = [pointer, ctypes.c_char_p, ctypes.c_uint32]
        cf.CFStringCreateWithCString.restype = pointer
        cf.CFArrayGetCount.argtypes = [pointer]
        cf.CFArrayGetCount.restype = ctypes.c_long
        cf.CFArrayGetValueAtIndex.argtypes = [pointer, ctypes.c_long]
        cf.CFArrayGetValueAtIndex.restype = pointer
        cf.CFURLGetFileSystemRepresentation.argtypes = [pointer, ctypes.c_bool, pointer, ctypes.c_long]
        cf.CFURLGetFileSystemRepresentation.restype = ctypes.c_bool
        cf.CFRelease.argtypes = [pointer]
        cf.CFRelease.restype = None
        ls.LSCopyApplicationURLsForBundleIdentifier.argtypes = [pointer, ctypes.POINTER(pointer)]
        ls.LSCopyApplicationURLsForBundleIdentifier.restype = pointer
        identifier = cf.CFStringCreateWithCString(None, metadata.BASE_ID.encode(), 0x08000100)
        error = pointer()
        urls = None
        try:
            require(identifier, "Cannot allocate LaunchServices query.")
            urls = ls.LSCopyApplicationURLsForBundleIdentifier(identifier, ctypes.byref(error))
            if error:
                # kLSApplicationNotFoundErr is the only accepted absence.
                cf.CFErrorGetCode.argtypes = [pointer]
                cf.CFErrorGetCode.restype = ctypes.c_long
                require(cf.CFErrorGetCode(error) == -10814, "LaunchServices query failed.")
                return []
            require(urls, "LaunchServices returned no verifiable result.")
            paths = []
            for index in range(cf.CFArrayGetCount(urls)):
                url = cf.CFArrayGetValueAtIndex(urls, index)
                buffer = ctypes.create_string_buffer(4096)
                require(cf.CFURLGetFileSystemRepresentation(url, True, buffer, len(buffer)),
                        "Cannot read registered application path.")
                paths.append(Path(os.fsdecode(buffer.value)).resolve())
            return paths
        finally:
            for value in (urls, error, identifier):
                if value:
                    cf.CFRelease(value)

    def verify_registration(self, app, *, absent=False):
        require((app.resolve() in self.app_paths()) != absent,
                "LaunchServices does not contain the requested exact app ID/path state.")
        result = self.run(
            ["/usr/bin/pluginkit", "-m", "-A", "-D", "-vv", "-i", metadata.BASE_ID + ".Extension"],
            text=True,
        )
        require(not result.stderr.strip(), "Extension registration query reported a diagnostic.")
        metadata.verify_registration_output(result.stdout, app / EXTENSION, absent=absent)

    def register(self, app):
        self.run([LSREGISTER, "-f", str(app)])
        self.run(["/usr/bin/pluginkit", "-a", str(app / EXTENSION)])
        self.verify_registration(app)

    def unregister(self, app):
        result = self.run(
            ["/usr/bin/pluginkit", "-m", "-A", "-D", "-vv", "-i", metadata.BASE_ID + ".Extension"],
            text=True,
        )
        require(not result.stderr.strip(), "Extension registration query reported a diagnostic.")
        records = metadata.registration_records(result.stdout, allow_empty=True)
        if any(record["id"] == metadata.BASE_ID + ".Extension"
               and Path(record["Path"]).resolve() == (app / EXTENSION).resolve() for record in records):
            self.run(["/usr/bin/pluginkit", "-r", str(app / EXTENSION)])
        if app.resolve() in self.app_paths():
            self.run([LSREGISTER, "-u", str(app)])
        self.verify_registration(app, absent=True)


class Installer:
    def __init__(self, home, destination=None, operations=None):
        require(os.getuid() != 0 and os.geteuid() == os.getuid(), "Run as your normal user, never root/sudo.")
        self.home = Path(home)
        safe_path(self.home, owner=True)
        require(self.home.is_dir(), "User home must exist.")
        self.applications = self.home / "Applications"
        self.destination = Path(destination) if destination else self.applications / DEFAULT_NAME
        require(self.destination.parent == self.applications
                and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,100}\.app", self.destination.name),
                "Destination must be a named .app directly inside this user's ~/Applications.")
        safe_path(self.destination, owner=True)
        self.state = self.applications / STATE_NAME
        self.ops = operations if operations is not None else MacOperations()
        self.receipt = None

    @contextmanager
    def locked(self):
        safe_path(self.applications, owner=True)
        self.applications.mkdir(mode=0o700, exist_ok=True)
        safe_path(self.state, owner=True)
        self.state.mkdir(mode=0o700, exist_ok=True)
        require(stat.S_IMODE(self.state.stat().st_mode) == 0o700, "Install state must be private (0700).")
        lock = self.state / "lock"
        safe_path(lock, owner=True)
        fd = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        try:
            info = os.fstat(fd)
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1
                    and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o600,
                    "Foreign install lock refused.")
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError("Another local-preview operation or command supervisor holds the install lock. "
                                 "Retry after its foreground workers finish, even if the original caller has exited.")
            command_worker.recover_marker(fd)
            require(self.ops.install_lock_fd is None, "Nested install locks are not supported.")
            self.ops.install_lock_fd = fd
            self.load()
            yield
        finally:
            if self.ops.install_lock_fd == fd:
                self.ops.install_lock_fd = None
            os.close(fd)

    def slot(self, name):
        require(isinstance(name, str) and re.fullmatch(r"slot-[0-9a-f]{32}\.app", name),
                "Invalid owned app slot.")
        return self.state / name

    def load(self):
        path = self.state / "receipt.json"
        if not path.exists():
            require(set(p.name for p in self.state.iterdir()) <= {"lock", "receipt.next"},
                    "Unrecognized install state; no app or backup will be adopted.")
            require(not self.destination.exists(), "Existing app has no ownership receipt; refusing to overwrite.")
            self.receipt = {"schema": 1, "destination": str(self.destination), "current": None,
                            "previous": None, "transaction": None, "garbage": None}
            self.save()
        else:
            safe_path(path, owner=True)
            info = path.lstat()
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= 32768
                    and stat.S_IMODE(info.st_mode) == 0o600, "Unsafe install receipt.")
            self.receipt = json.loads(path.read_text())
            require(isinstance(self.receipt, dict)
                    and set(self.receipt) == {"schema", "destination", "current", "previous", "transaction", "garbage"}
                    and self.receipt["schema"] == 1 and self.receipt["destination"] == str(self.destination),
                    "Foreign or incompatible install receipt/destination.")
        allowed = {"lock", "receipt.json", "receipt.next"}
        for key in ("previous", "transaction", "garbage"):
            item = self.receipt[key]
            if item:
                allowed.add(self.slot(item["slot"]).name)
        require(set(p.name for p in self.state.iterdir()) <= allowed, "Unrecognized backup or install artifact.")
        for path in self.state.iterdir():
            safe_path(path, owner=True)
        self.validate_receipt()

    def validate_receipt(self):
        def identity(value):
            require(isinstance(value, dict) and set(value) == {"sha256", "version"}
                    and isinstance(value["sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", value["sha256"])
                    and isinstance(value["version"], str)
                    and re.fullmatch(r"[1-9][0-9]*(?:\.[0-9]+){0,2}", value["version"]),
                    "Invalid app identity receipt.")
        if self.receipt["current"]:
            identity(self.receipt["current"])
        for key in ("previous", "garbage"):
            item = self.receipt[key]
            if item:
                require(set(item) == ({"slot", "identity", "deleting", "node"} if key == "garbage" else {"slot", "identity"}),
                        "Invalid backup receipt.")
                identity(item["identity"])
                if key == "garbage":
                    require(type(item["deleting"]) is bool and (not item["deleting"] or item["node"] is not None),
                            "Invalid cleanup receipt.")
        transaction = self.receipt["transaction"]
        if transaction:
            require(set(transaction) == {"kind", "phase", "slot", "before", "after", "source", "node"}
                    and transaction["kind"] in ("install", "update", "rollback", "uninstall")
                    and transaction["phase"] in ("copying", "ready", "removing", "reverting", "discarding"),
                    "Invalid transaction receipt.")
            for key in ("before", "after"):
                if transaction[key]:
                    identity(transaction[key])
            require(transaction["before"] == self.receipt["current"], "Transaction does not match current receipt.")
            require(transaction["source"] in (None, str(DEVELOPMENT_APP)), "Unrecognized source registration.")
            kind, phase = transaction["kind"], transaction["phase"]
            require(bool(transaction["before"]) == (kind != "install")
                    and bool(transaction["after"]) == (kind != "uninstall"),
                    "Invalid transaction identities.")
            require((phase != "copying" or kind in ("install", "update"))
                    and (phase != "discarding" or kind in ("install", "update"))
                    and (phase != "removing" or kind == "uninstall")
                    and (phase != "reverting" or kind in ("update", "rollback")),
                    "Invalid transaction phase.")
            if kind == "rollback":
                require(self.receipt["previous"] == {"slot": transaction["slot"],
                                                    "identity": transaction["after"]},
                        "Rollback does not match previous receipt.")
            elif self.receipt["previous"]:
                require(transaction["slot"] != self.receipt["previous"]["slot"], "Aliased transaction slot.")
        garbage = self.receipt["garbage"]
        if garbage:
            require(not transaction, "Ambiguous cleanup during transaction.")
            require(not self.receipt["previous"] or garbage["slot"] != self.receipt["previous"]["slot"],
                    "Aliased backup/cleanup slot.")
        for entry in (transaction, garbage):
            if entry and entry["node"] is not None:
                require(isinstance(entry["node"], list) and len(entry["node"]) == 2
                        and all(type(value) is int and value >= 0 for value in entry["node"]),
                        "Invalid owned directory identity.")

    def save(self):
        staging = self.state / "receipt.next"
        safe_path(staging, owner=True)
        if staging.exists():
            info = staging.lstat()
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1
                    and stat.S_IMODE(info.st_mode) == 0o600, "Foreign metadata staging file.")
            staging.unlink()
        fd = os.open(staging, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(self.receipt, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(staging, self.state / "receipt.json")
        sync_directory(self.state)

    def inspect(self, app, *, current=False):
        safe_tree(app)
        before = digest(app)
        version = self.ops.verify(app, current=current)
        require(before == digest(app), "App changed during signature verification.")
        return {"sha256": before, "version": version}

    def match(self, app, identity):
        require(identity is not None and self.inspect(app) == identity, f"Owned app integrity mismatch: {app}")

    def check_stable(self):
        safe_path(self.destination, owner=True)
        if self.receipt["current"]:
            self.match(self.destination, self.receipt["current"])
        else:
            require(not self.destination.exists(), "Unowned app at destination.")
        previous = self.receipt["previous"]
        if previous:
            self.match(self.slot(previous["slot"]), previous["identity"])

    def clean_garbage(self):
        garbage = self.receipt["garbage"]
        if not garbage:
            return
        path = self.slot(garbage["slot"])
        require(path.exists() or garbage["deleting"], "Retiring backup disappeared before owned cleanup.")
        if path.exists():
            if not garbage["deleting"]:
                self.match(path, garbage["identity"])
                self.ops.assert_idle(path)
                self.ops.unregister(path)
                garbage["deleting"] = True
                garbage["node"] = directory_identity(path)
                self.save()
            require(directory_identity(path) == garbage["node"], "Cleanup slot was replaced; refusing foreign contents.")
            safe_tree(path, deleting=True)
            shutil.rmtree(path)
            sync_directory(self.state)
        self.receipt["garbage"] = None
        self.save()

    def idle(self):
        apps = [self.destination]
        previous = self.receipt["previous"]
        if previous:
            apps.append(self.slot(previous["slot"]))
        self.ops.assert_idle(*apps)

    def prepare_update(self):
        require(not self.receipt["transaction"] and not self.receipt["garbage"], "Run recover first.")
        require(self.receipt["current"], "No owned preview is installed.")
        self.check_stable()
        # ExtensionKit may retain its idle process after Default is selected.
        # Retiring only this owned registration lets macOS release that process.
        self.ops.unregister(self.destination)
        self.idle()
        self.match(self.destination, self.receipt["current"])
        return ("Preview registration retired; app files, backups and user data unchanged. "
                "Run update or rollback, or recover to restore the current registration. "
                "Keep CMUX on Default until the operation finishes.")

    def install(self, source, *, update=False, retire_source=False):
        require(not self.receipt["transaction"] and not self.receipt["garbage"]
                and not (self.receipt["current"] is None and self.receipt["previous"]),
                "Pending transaction/cleanup: run recover before another operation.")
        self.check_stable()
        require(bool(self.receipt["current"]) == update,
                "Use install for an empty owned destination; use update for an installed preview.")
        source = Path(source)
        safe_path(source, owner=True)
        require(source != self.destination and not source.is_relative_to(self.state),
                "Source must be a separate build, not an installed or backup app.")
        if retire_source:
            require(source == DEVELOPMENT_APP, "Only this checkout's known .build/adhoc app may be deregistered.")
        new = self.inspect(source, current=True)
        old = self.receipt["current"]
        if old:
            version = lambda value: tuple(map(int, value.split("."))) + (0,) * (3 - len(value.split(".")))
            require(version(new["version"]) >= version(old["version"]), "Update cannot downgrade; use explicit rollback.")
            require(new != old, "This exact build is already installed.")
        self.idle()
        transaction = {"kind": "update" if update else "install", "phase": "copying",
                       "slot": "slot-" + uuid.uuid4().hex + ".app", "before": old, "after": new,
                       "source": str(source) if retire_source else None, "node": None}
        self.receipt["transaction"] = transaction
        self.save()
        candidate = self.slot(transaction["slot"])
        require(not candidate.exists(), "Candidate slot already exists.")
        candidate.mkdir(mode=0o700)
        transaction["node"] = directory_identity(candidate)
        self.save()
        self.ops.copy(source, candidate)
        require(self.inspect(candidate, current=True) == new, "Staged app differs from verified source.")
        self.ops.sync(candidate)
        transaction["phase"] = "ready"
        self.save()
        self.commit()

    def rollback(self):
        require(not self.receipt["transaction"] and not self.receipt["garbage"], "Run recover first.")
        self.check_stable()
        previous = self.receipt["previous"]
        require(self.receipt["current"] and previous, "No verified previous preview is available.")
        self.idle()
        self.receipt["transaction"] = {
            "kind": "rollback", "phase": "ready", "slot": previous["slot"],
            "before": self.receipt["current"], "after": previous["identity"], "source": None,
            "node": directory_identity(self.slot(previous["slot"])),
        }
        self.save()
        self.commit()

    def commit(self):
        transaction = self.receipt["transaction"]
        candidate = self.slot(transaction["slot"])
        self.check_stable()
        self.match(candidate, transaction["after"])
        self.idle()
        self.ops.move(candidate, self.destination, exchange=transaction["before"] is not None)
        self.finish_committed()

    def finish_committed(self):
        transaction = self.receipt["transaction"]
        slot = self.slot(transaction["slot"])
        self.match(self.destination, transaction["after"])
        if transaction["before"]:
            self.match(slot, transaction["before"])
            self.ops.unregister(slot)
        else:
            require(not slot.exists(), "Unexpected first-install backup.")
        previous = self.receipt["previous"]
        if previous and transaction["kind"] != "rollback":
            self.match(self.slot(previous["slot"]), previous["identity"])
        if transaction["source"]:
            source = Path(transaction["source"])
            self.match(source, transaction["after"])
            self.ops.unregister(source)
        self.ops.register(self.destination)
        self.match(self.destination, transaction["after"])
        self.receipt["current"] = transaction["after"]
        self.receipt["previous"] = (
            {"slot": transaction["slot"], "identity": transaction["before"]} if transaction["before"] else None
        )
        if previous and transaction["kind"] != "rollback":
            self.receipt["garbage"] = {**previous, "deleting": False, "node": None}
        self.receipt["transaction"] = None
        self.save()
        self.clean_garbage()
        self.ops.verify_registration(self.destination)

    def discard_staging(self):
        transaction = self.receipt["transaction"]
        candidate = self.slot(transaction["slot"])
        if candidate.exists():
            # The pre-copy journal owns this otherwise unverifiable partial tree.
            safe_tree(candidate, deleting=True)
            require((transaction["node"] is not None and directory_identity(candidate) == transaction["node"])
                    or (transaction["node"] is None and not any(candidate.iterdir())),
                    "Staging slot was replaced or has no ownership proof.")
            if transaction["phase"] == "ready":
                self.match(candidate, transaction["after"])
                self.ops.unregister(candidate)
            if transaction["phase"] != "discarding":
                transaction["phase"] = "discarding"
                self.save()
            shutil.rmtree(candidate)
            sync_directory(self.state)
        self.receipt["transaction"] = None
        self.save()

    def refresh_current_registration(self):
        current = self.receipt["current"]
        if current:
            self.match(self.destination, current)
            self.ops.register(self.destination)
            self.match(self.destination, current)

    def recover(self, *, restore_previous=False):
        transaction = self.receipt["transaction"]
        if not transaction:
            require(not restore_previous, "No pending replacement; use rollback for a completed update.")
            self.check_stable()
            self.clean_garbage()
            self.clean_removed_current()
            self.refresh_current_registration()
            return "No pending transaction. Owned apps verified; installed preview registration refreshed if present."
        if transaction["kind"] == "uninstall":
            require(not restore_previous, "Removal is not a replacement to roll back; use recover to resume explicit removal.")
            self.finish_uninstall()
            return "Removal recovered. User data and plugin settings retained."
        slot = self.slot(transaction["slot"])
        if transaction["phase"] in ("copying", "discarding"):
            self.check_stable()
            self.discard_staging()
            self.refresh_current_registration()
            return "Interrupted staging discarded. Installed app and previous version unchanged."
        if transaction["phase"] == "reverting":
            self.revert_committed()
            return "Previous installed app restored and registered; interrupted replacement cancelled."
        require(transaction["phase"] == "ready", "Unknown recovery phase.")
        actual = self.inspect(self.destination) if self.destination.exists() else None
        if actual == transaction["before"]:
            self.check_stable()
            if slot.exists():
                self.match(slot, transaction["after"])
            elif transaction["kind"] == "rollback":
                raise ValueError("Rollback backup is missing.")
            if transaction["kind"] == "rollback":
                self.receipt["transaction"] = None
                self.save()
            else:
                self.discard_staging()
            self.refresh_current_registration()
            return "Pre-commit transaction cancelled; installed app unchanged."
        require(actual == transaction["after"], "Ambiguous destination; recovery refuses to guess.")
        if restore_previous:
            require(transaction["before"], "First install has no previous app. Recover it before explicit uninstall.")
            transaction["phase"] = "reverting"
            self.save()
            self.revert_committed()
            return "Previous installed app restored and registered; interrupted replacement cancelled."
        self.finish_committed()
        return "Committed replacement verified and registered; previous version preserved."

    def revert_committed(self):
        transaction = self.receipt["transaction"]
        candidate = self.slot(transaction["slot"])
        actual = self.inspect(self.destination)
        if actual == transaction["after"]:
            self.match(candidate, transaction["before"])
            self.ops.assert_idle(self.destination, candidate)
            self.ops.move(candidate, self.destination, exchange=True)
        else:
            require(actual == transaction["before"], "Ambiguous destination during recovery rollback.")
        self.match(self.destination, transaction["before"])
        self.match(candidate, transaction["after"])
        previous = self.receipt["previous"]
        if previous:
            self.match(self.slot(previous["slot"]), previous["identity"])
        self.ops.register(self.destination)
        if transaction["kind"] != "rollback":
            self.receipt["garbage"] = {"slot": transaction["slot"], "identity": transaction["after"],
                                       "deleting": False, "node": None}
        self.receipt["transaction"] = None
        self.save()
        self.clean_garbage()
        self.ops.verify_registration(self.destination)

    def uninstall(self, *, hooks_retired):
        require(hooks_retired, "Confirm cached native hooks are retired before removing their helper.")
        require(not self.receipt["transaction"] and not self.receipt["garbage"], "Run recover first.")
        self.check_stable()
        require(self.receipt["current"], "No owned preview is installed.")
        self.idle()
        self.receipt["transaction"] = {
            "kind": "uninstall", "phase": "ready", "slot": "slot-" + uuid.uuid4().hex + ".app",
            "before": self.receipt["current"], "after": None, "source": None, "node": None,
        }
        self.save()
        self.finish_uninstall()

    def finish_uninstall(self):
        transaction = self.receipt["transaction"]
        trash = self.slot(transaction["slot"])
        if transaction["phase"] == "ready":
            self.check_stable()
            self.idle()
            self.ops.unregister(self.destination)
            transaction["phase"] = "removing"
            self.save()
        require(transaction["phase"] == "removing", "Invalid removal phase.")
        if self.destination.exists():
            self.match(self.destination, transaction["before"])
            self.idle()
            self.ops.move(self.destination, trash)
        else:
            self.match(trash, transaction["before"])
        previous = self.receipt["previous"]
        if previous:
            self.match(self.slot(previous["slot"]), previous["identity"])
            self.receipt["garbage"] = {**previous, "deleting": False, "node": None}
        self.receipt["current"] = None
        self.receipt["previous"] = None
        self.receipt["transaction"] = None
        # Keep the removed current app as the next owned cleanup slot until the
        # previous slot is fully retired; a failed deletion remains recoverable.
        self.receipt["previous"] = {"slot": transaction["slot"], "identity": transaction["before"]}
        self.save()
        self.clean_garbage()
        self.clean_removed_current()

    def clean_removed_current(self):
        if self.receipt["current"] is None and self.receipt["previous"]:
            previous = self.receipt["previous"]
            self.match(self.slot(previous["slot"]), previous["identity"])
            self.receipt["garbage"] = {**previous, "deleting": False, "node": None}
            self.receipt["previous"] = None
            self.save()
            self.clean_garbage()

    def status(self):
        if (self.receipt["transaction"] or self.receipt["garbage"]
                or (self.receipt["current"] is None and self.receipt["previous"])):
            return "Pending transaction/cleanup. Run recover; no further update or rollback is allowed yet."
        self.check_stable()
        current = self.receipt["current"]
        if not current:
            return "No installed preview. Ownership metadata retained; user data untouched."
        self.ops.verify_registration(self.destination)
        previous = self.receipt["previous"]
        return (f"Verified installed preview: {self.destination}\n"
                f"Build {current['version']}; previous: {previous['identity']['version'] if previous else 'none'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, help="Alternate .app directly within your ~/Applications")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("install", "update"):
        command = commands.add_parser(name)
        command.add_argument("--source", type=Path, required=True)
        command.add_argument("--retire-development-registration", action="store_true",
                             help="Unregister only this checkout's verified .build/adhoc source, not its files")
    for name in ("rollback", "status"):
        commands.add_parser(name)
    commands.add_parser("prepare-update", help="Retire the owned preview registration before replacing an idle extension")
    recovery = commands.add_parser("recover")
    recovery.add_argument("--restore-previous", action="store_true",
                          help="Restore the old app after a committed replacement failed, instead of retrying the new one")
    remove = commands.add_parser("uninstall")
    remove.add_argument("--cached-hooks-retired", action="store_true",
                        help="Confirm explicit plugin removal and retirement of sessions caching native hooks")
    args = parser.parse_args()
    try:
        home = Path(pwd.getpwuid(os.getuid()).pw_dir)
        installer = Installer(home, args.destination)
        with installer.locked():
            if args.command in ("install", "update"):
                installer.install(args.source, update=args.command == "update",
                                  retire_source=args.retire_development_registration)
                print("Verified local preview installed and registered; transaction complete.")
                print("Open the stable app and explicitly refresh Copilot integration there. Keep development "
                      "builds until old CLI sessions no longer cache their absolute helper paths.")
            elif args.command == "uninstall":
                installer.uninstall(hooks_retired=args.cached_hooks_retired)
                print("Owned preview apps/registrations removed. User data, settings and other plugins retained.")
            elif args.command == "recover":
                print(installer.recover(restore_previous=args.restore_previous))
            elif args.command == "prepare-update":
                print(installer.prepare_update())
            else:
                result = getattr(installer, args.command)()
                print(result or "Verified previous preview restored and registered. Refresh integration explicitly.")
    except (ValueError, OSError, KeyError, TypeError, RuntimeError, KeyboardInterrupt, subprocess.SubprocessError,
            plistlib.InvalidFileException) as error:
        print(f"Local preview operation incomplete: {error}\n"
              "No success or automatic rollback is implied. Run status, then recover for any pending transaction. "
              "Do not delete receipt/lock/backup files or the development source.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
