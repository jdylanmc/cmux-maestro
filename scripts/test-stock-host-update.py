#!/usr/bin/env python3
"""Current bounded-retention install/compensation/reclaim and sibling-refusal proof.

Run with --hosted-only --evidence "$RUNNER_TEMP/stock-host-update-evidence".
Setup establishes a working selection through genuine first-time public UI approval.
Same-version/fresh-DR A/B/C/D; retain failed C, reclaim it before D publication.
Only after that passes, require exact external siblings to refuse an update before effects.
Real CLI metadata/plugin operations only: no credentials, model calls or chat sessions.
Failed-update compensation is combined recovery; manual rollback remains app-only.
Exit 0 requires combined operations, native continuity and real compensation.
Historical registration rescue is not invoked for this pre-effect-refusal contract.
All runtime evidence, including unsuccessful setup and cleanup, goes to the artifact.
Register the verified stock point before discovery from the signed observer bundle.
The observer declares no extension point and never launches or connects to Maestro.
Tree snapshots originate from a declared runner-only initial terminal command,
not the external controller, preserving stock cmuxOnly ancestry authorization.
Public pluginkit queries observe registration turnover, never loaded code.
External ExtensionFoundation enumeration is advisory for its separate host app.
"""

import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import platform
import pwd
import re
import selectors
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import time
import tarfile
import traceback
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
BASE = "284aea494844fa00cb748545860eb263a7914116"
FROZEN_PASS = {"product": "6efa5427cfca4f0dfb5af927ec29ba5962e2cd88",
               "head": "738e11bcca3aba4239d9dc2c9f253902f51044b1", "run": "36712857606"}
CLEAN_COMBINED_PASS = {"product": "c2b829edb90e2d22eb5582153fb8684853925d4d",
                       "head": "b3de3aa475f7233c5a8d4fcfa2d525634aa2e741",
                       "run": "36723431093",
                       "limit": "version-bumped B/C with preserved requirements; not same-version/fresh-DR proof"}
FIXTURE_MARKER = "CMUXMaestroHostProofGeneration"
CLI_PACKAGES = {
    "arm64": ("arm64", 92437023, "7dc3854cf21190f033d449f77c140bbb78d52018359c5eb05aa781b3c2a1301d"),
    "x86_64": ("x64", 104193258, "f48484b330792861548ab5a47fdd9b485c03a613c563922e29991d700e6de2f4"),
}
STOCK_REVISION = "b685a275c2e411799857155e37264daf84f7e4d6"
DMG_URL = "https://github.com/manaflow-ai/cmux/releases/download/v0.64.25/cmux-macos.dmg"
DMG_SHA256 = "0afb2f8ff9bfef10f03e61ff12e65ce02dbca5c96cb9047118e13483ac5b08ad"
EXT_ID = "com.jdylanmc.CMUXMaestroPreview.Extension"
POINT_ID = "com.cmuxterm.app.cmux.sidebar"
OBSERVER_ID = "com.jdylanmc.CMUXMaestroPreview.HostProofObserver"
DOMAIN = "com.cmuxterm.app"
SETUP_DEFAULTS = {
    "extensions.beta.enabled": True,
    "cmuxExtensionSidebar.providerId": "cmux.sidebar.extensions",
    "cmuxExtensionSidebar.selectedExtensionBundleId": EXT_ID,
    "socketControlMode": "cmuxOnly",
    "SUEnableAutomaticChecks": False,
    "SUAutomaticallyUpdate": False,
    "confirmQuit": "never",
    "warnBeforeQuitShortcut": False,
    "cmuxWelcomeShown": True,
    "cmux.sparkle.automaticChecksMigration.v2": True,
}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def load_preview():
    spec = importlib.util.spec_from_file_location("native_preview", ROOT / "scripts/local-preview.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


class Probe:
    def __init__(self, evidence):
        self.evidence = evidence
        self.work = Path(os.environ["RUNNER_TEMP"]).resolve() / "stock-host-update"
        self.work_owned = False
        self.fixture_profile_verified = False
        self.home = Path(pwd.getpwuid(os.getuid()).pw_dir)
        self.preview = load_preview()
        self.ops = self.preview.MacOperations()
        self.destination = self.home / "Applications/CMUX Maestro Host Proof.app"
        self.source = self.preview.DEVELOPMENT_APP
        self.stock = Path("/Applications/cmux.app")
        self.stock_node = None
        self.mount = self.work / "dmg-mount"
        self.observer_app = self.work / "Stock Host Observer.app"
        self.helper = self.observer_app / "Contents/MacOS/stock-host-observer"
        self.observer = None
        self.child = None
        self.command_incomplete = False
        self.host = None
        self.host_launch_requested = False
        self.defaults_owned = False
        self.terminal_config = self.home / ".config/ghostty/config"
        self.terminal_config_contents = None
        self.tree_snapshot_count = 0
        self.apps_owned = []
        self.sibling_apps = {}
        self.sibling_records = {}
        self.baseline = None
        self.worker = None
        self.hashes = {}
        self.fixture_signing = {}
        self.last_sample = None
        self.last_registration = None
        self.sequence = 0
        self.copilot = None
        self.copilot_real = None
        self.integration_states = {}
        self.retention_states = {}
        self.candidate_identities = {}
        self.reclaim_watch = None
        self.last_managed_sample = None
        self.report = {
            "status": "unavailable", "phase": "setup", "base": BASE,
            "stock": {"version": "0.64.25", "build": "106", "revision": STOCK_REVISION,
                      "url": DMG_URL, "bytes": 225832896, "sha256": DMG_SHA256},
            "scenario": "bounded retention/reclamation, then exact sibling preflight refusal",
            "currentScenario": "boundedRetention",
            "scenarioResults": {"boundedRetention": {"status": "pending"},
                                "siblingRefusal": {"status": "not-run", "reason": "retention/reclaim prerequisite"}},
            "diagnosticRecovery": {"status": "not-applicable", "changesAcceptance": False,
                                   "reason": "Historical rescue unverified; current candidate must refuse before effects"},
            "scope": "current combined A/B/failed-C/retained-C/D-reclaim/repeat-D/sibling-refusal; no model sessions or loaded-hook claim",
            "priorFrozenNativeCapability": FROZEN_PASS,
            "priorCleanCombinedCapability": CLEAN_COMBINED_PASS,
            "stockHostSource": {
                "path": "Sources/CMUXInstalledExtensionSidebarHostView.swift",
                "gitBlob": "fd1f6ee840a7e9195852f6a473e3538f23090fbb",
                "revision": STOCK_REVISION,
                "hypothesis": "Same-ID siblings may prevent the disappearance that recreates stock's native identity.",
            },
            "manualRollback": {"exercised": False, "semantics": "documented app-only; not combined compensation"},
            "setupIsNotAcceptance": True,
            "observationContract": {
                "registration": "stable-path turnover; zero siblings first, then two exact eligible/elected siblings; not loaded proof",
                "loaded": "mandatory old-process exit and new extension executable PID/UID/start/CDHash",
                "externalExtensionFoundation": "advisory separate-host context, not stock host visibility",
            },
            "checks": {}, "cleanup": [], "events": [],
        }

    def prepare_copilot(self):
        found = shutil.which("copilot")
        self.event("copilot-absence-check", configuredPathResult=found)
        require(found is None, "Existing PATH Copilot refused; no CLI package was installed")
        require(not (self.home / ".copilot").exists(), "Existing Copilot profile refused")
        require(platform.machine() in CLI_PACKAGES, "No pinned official CLI package for this architecture")
        arch, size, digest = CLI_PACKAGES[platform.machine()]
        archive = self.work / "copilot-1.0.89.tar.gz"
        url = f"https://github.com/github/copilot-cli/releases/download/v1.0.89/copilot-darwin-{arch}.tar.gz"
        self.run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
                  "--max-time", "300", "--output", archive, url], timeout=310)
        require(archive.stat().st_size == size and sha256(archive) == digest, "Official CLI archive integrity mismatch")
        directory = self.work / "copilot-1.0.89"
        directory.mkdir(mode=0o700)
        with tarfile.open(archive) as package:
            members = package.getmembers()
            require(len(members) <= 4096 and sum(m.size for m in members) <= 1_073_741_824,
                    "CLI package exceeds extraction bounds")
            for member in members:
                path = Path(member.name)
                require(not path.is_absolute() and ".." not in path.parts
                        and (member.isdir() or member.isfile()), "Unsafe CLI archive member")
                target = directory / path
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True, mode=0o700)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    with package.extractfile(member) as source, target.open("xb") as output:
                        shutil.copyfileobj(source, output)
                    target.chmod(member.mode & 0o755)
        self.copilot_real = directory / "copilot"
        self.preview.safe_path(self.copilot_real, owner=True)
        require(self.copilot_real.is_file() and os.access(self.copilot_real, os.X_OK), "Official CLI executable missing")
        for key in ("GITHUB_TOKEN", "GH_TOKEN", "COPILOT_GITHUB_TOKEN"):
            os.environ.pop(key, None)
        gh = self.work / "empty-gh-config"
        gh.mkdir(mode=0o700)
        os.environ["GH_CONFIG_DIR"] = str(gh)
        _, version = self.run([self.copilot_real, "--no-auto-update", "--no-auto-login", "--version"])
        require(version.splitlines()[:1] == [b"GitHub Copilot CLI 1.0.89."],
                "CLI runtime version is not exactly 1.0.89")
        self.report["copilot"] = {"version": version.decode().strip(), "url": url, "bytes": size,
                                  "archiveSHA256": digest, "executableSHA256": sha256(self.copilot_real),
                                  "credentialsSupplied": False, "sessionsCreated": 0, "modelCalls": 0}
        self.save()

    def provider_rpc(self, calls):
        allowed = {"status.get", "hooks.discover", "plugins.list", "plugins.uninstall"}
        require(all(method in allowed for method, _ in calls), "Non-metadata/provider-cleanup RPC refused")
        process = subprocess.Popen([
            str(self.copilot_real), "--no-auto-update", "--no-auto-login", "--headless", "--stdio",
            "--disable-builtin-mcps", "--no-custom-instructions", "--no-remote", "--no-remote-export",
            "--log-level", "error",
        ], cwd=self.work, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.event("official-provider-read", pid=process.pid, methods=[m for m, _ in calls])
        selector = selectors.DefaultSelector()
        stdout, stderr, responses = bytearray(), bytearray(), {}
        try:
            for index, (method, params) in enumerate(calls, 1):
                body = json.dumps({"jsonrpc": "2.0", "id": index, "method": method, "params": params}).encode()
                process.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
            process.stdin.flush()
            selector.register(process.stdout, selectors.EVENT_READ, "out")
            selector.register(process.stderr, selectors.EVENT_READ, "err")
            deadline = time.monotonic() + 40
            received = 0
            while selector.get_map():
                require(time.monotonic() < deadline, "Official metadata completion unavailable")
                for key, _ in selector.select(0.25):
                    chunk = os.read(key.fileobj.fileno(), 8192)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    received += len(chunk)
                    require(received <= 262_144, "Provider metadata exceeds bound")
                    (stdout if key.data == "out" else stderr).extend(chunk)
                while b"\r\n\r\n" in stdout:
                    end = stdout.index(b"\r\n\r\n")
                    match = re.fullmatch(rb"Content-Length: ([0-9]+)", bytes(stdout[:end]))
                    require(end < 1024 and match is not None, "Invalid provider metadata framing")
                    size = int(match[1])
                    require(0 < size <= 262_144, "Invalid provider frame length")
                    if len(stdout) < end + 4 + size:
                        break
                    message = json.loads(stdout[end + 4:end + 4 + size])
                    del stdout[:end + 4 + size]
                    require(isinstance(message, dict) and message.get("jsonrpc") == "2.0"
                            and "error" not in message, "Provider RPC failed")
                    if "id" in message:
                        identity = message["id"]
                        require(type(identity) is int and 1 <= identity <= len(calls)
                                and identity not in responses and "result" in message, "Unexpected provider response")
                        responses[identity] = message["result"]
                    else:
                        require(isinstance(message.get("method"), str), "Invalid provider notification")
                if len(responses) == len(calls) and not process.stdin.closed:
                    process.stdin.close()
            require(len(responses) == len(calls) and not stdout, "Incomplete provider response stream")
            process.wait(timeout=10)
            require(process.returncode == 0 and not stderr.strip(), "Provider metadata process reported failure")
            return [responses[i] for i in range(1, len(calls) + 1)]
        finally:
            (self.evidence / f"provider-read-{process.pid}.stderr").write_bytes(stderr)
            selector.close()
            if process.stdin and not process.stdin.closed:
                process.stdin.close()
            if process.poll() is None:
                process.terminate()  # Exact owned, session-free metadata child only.
                process.wait(timeout=10)
            for stream in (process.stdout, process.stderr):
                stream.close()

    def integration_state(self, label, expected, *, compare_bytes=None, new_retired=None):
        status, hooks, plugins = self.provider_rpc([
            ("status.get", {}), ("hooks.discover", {}), ("plugins.list", {})])
        require(status.get("version") == "1.0.89" and status.get("protocolVersion") == 3,
                "Unexpected official provider metadata version")
        require(not hooks.get("errors") and not hooks.get("warnings"), "Provider discovery reported errors/warnings")
        own = [p for p in plugins["plugins"] if p.get("name") == "cmux-maestro-native"]
        require(len(own) == 1 and own[0].get("enabled") is True and own[0].get("directSourceId")
                and own[0].get("marketplace") == "" and own[0].get("managed") is not True
                and own[0].get("installed") is not False and own[0].get("installedFrom") is None
                and own[0].get("source") is None,
                "Owned real provider registration not uniquely enabled")
        registration_root = self.home / "Library/Application Support/CMUXMaestroPreview/Copilot"
        observer_receipt = json.loads((registration_root / "observer-registration.json").read_text())
        require(observer_receipt.get("phase") == "current"
                and observer_receipt.get("pluginIdentity") == own[0]["directSourceId"]
                and observer_receipt.get("sourceIdentity", {}).get("source") == str(registration_root / "plugin")
                and observer_receipt["sourceIdentity"].get("directSourceId") == own[0]["directSourceId"],
                "Real provider identity is not bound to the owned installed source")
        manifest_path = self.home / ".copilot/hooks/cmux-maestro-observer.json"
        self.preview.safe_path(manifest_path, owner=True)
        manifest = json.loads(manifest_path.read_text())
        helper = self.destination / "Contents/Helpers/CMUXMaestroCopilotHook"
        require(manifest["maestro"]["helper"] == str(helper)
                and manifest["maestro"]["owner"] == "cmux-maestro-native"
                and set(manifest["hooks"]) == {"sessionStart", "userPromptSubmitted", "postToolUse"}
                and manifest.get("disableAllHooks") is False, "Owned hooks do not bind the stable helper")
        quoted_helper = "'" + str(helper).replace("'", "'\\''") + "'"
        command = "{ " + quoted_helper + " >/dev/null 2>&1 || :; } >/dev/null 2>&1; exit 0"
        require(all(items == [{"type": "command", "bash": command, "timeoutSec": 2}]
                    for items in manifest["hooks"].values()), "Owned observer commands differ from the stable helper")
        rows = [h for h in hooks["hooks"] if h.get("origin") == "user"
                and h.get("source") in ("hooks/cmux-maestro-observer.json", str(manifest_path))]
        require(len(rows) == 3 and all(h.get("enabled") is True for h in rows)
                and {h["hookType"] for h in rows} == set(manifest["hooks"])
                and not any(h.get("origin") == "plugin" and h.get("source") == "cmux-maestro-native"
                            for h in hooks["hooks"]), "Duplicate/missing real observer discovery")
        adapter = self.home / ".copilot/extensions/maestro/adapter.mjs"
        resources = {}
        paths = [manifest_path]
        for directory in (registration_root,
                          self.home / "Library/Application Support/CMUXMaestroPreview/Orchestration/bin",
                          self.home / ".copilot/extensions/maestro",
                          self.home / ".copilot/installed-plugins/_direct/plugin"):
            require(directory.is_dir(), f"Owned integration directory missing: {directory}")
            paths += [p for p in directory.rglob("*") if not p.is_dir() or p.is_symlink()]
        settings = self.home / ".copilot/settings.json"
        if settings.exists():
            paths.append(settings)
        require(len(paths) <= 512, "Owned integration inventory exceeds bound")
        for path in sorted(set(paths)):
            self.preview.safe_path(path, owner=True)
            info = path.lstat()
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid(), "Unsafe owned integration resource")
            resources[str(path)] = {"sha256": sha256(path), "mode": stat.S_IMODE(info.st_mode),
                                   "inode": info.st_ino, "mtimeNS": info.st_mtime_ns}
        require(sha256(adapter) == sha256(expected / "Contents/Resources/adapter.mjs"),
                f"{label}: installed integration adapter differs from current app resources")
        receipt_path = self.home / "Applications" / self.preview.STATE_NAME / "receipt.json"
        receipt = json.loads(receipt_path.read_text())
        require(receipt["transaction"] is None and receipt["integration"] is None and receipt["garbage"] is None,
                "Combined installer left pending bookkeeping")
        checkpoint = self.home / "Library/Application Support/CMUXMaestroPreview/Orchestration/install-transaction.json"
        require(not checkpoint.exists(), "Integration checkpoint remains after completed operation")
        sessions = self.home / ".copilot/session-state"
        require(not sessions.exists() or not any(sessions.iterdir()), "Unexpected Copilot session state was created")
        value = {"provider": own[0], "hooks": rows, "resources": resources, "appReceipt": receipt,
                 "installedAppSHA256": self.preview.digest(self.destination)}
        if compare_bytes is not None:
            expected_receipt = dict(compare_bytes["appReceipt"])
            if new_retired is not None:
                require(new_retired == "C" and expected == self.candidates["B"]
                        and expected_receipt.get("retired") is None,
                        "Only this failed-C retirement bookkeeping delta is authorized")
                retained = self.retention_state("compensated-apps", "B", "A", "C")
                require(retained["receipt"] == receipt, "Retirement changed during integration verification")
                expected_receipt["retired"] = retained["receipt"]["retired"]
            require({p: (v["sha256"], v["mode"]) for p, v in resources.items()} ==
                    {p: (v["sha256"], v["mode"]) for p, v in compare_bytes["resources"].items()}
                    and own[0]["directSourceId"] == compare_bytes["provider"]["directSourceId"]
                    and receipt == expected_receipt
                    and value["installedAppSHA256"] == compare_bytes["installedAppSHA256"],
                    "Prior app/integration/provider state was not restored")
        self.integration_states[label] = value
        (self.evidence / f"integration-{label}.json").write_text(json.dumps(value, indent=2) + "\n")
        self.event("combined-state-verified", label=label, providerIdentity=own[0]["directSourceId"])
        return value

    def managed_nodes(self):
        state = self.home / "Applications" / self.preview.STATE_NAME
        paths = [self.destination] if self.destination.exists() else []
        paths += [p for p in state.iterdir() if p.name.endswith(".app")] if state.exists() else []
        nodes, raced = {}, False
        for path in paths:
            require(path == self.destination or re.fullmatch(r"slot-[0-9a-f]{32}\.app", path.name),
                    "Unknown managed app artifact")
            try:
                info = path.lstat()
            except FileNotFoundError:
                raced = True
                continue
            require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid(),
                    "Managed bundle path is not an owned directory")
            nodes[str(path)] = [info.st_dev, info.st_ino, info.st_uid]
        require(len(nodes) <= 4, "Observed managed app count exceeded four")
        return {"nodes": nodes, "concurrentRemoval": raced}

    def atomic_receipt(self):
        path = self.home / "Applications" / self.preview.STATE_NAME / "receipt.json"
        self.preview.safe_path(path, owner=True)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink in (0, 1)
                    and stat.S_IMODE(info.st_mode) == 0o600 and info.st_size <= 32768,
                    "Unsafe atomic receipt observation")
            raw = stream.read(32769)
        receipt = json.loads(raw)
        require(set(receipt) == {"schema", "destination", "current", "previous", "retired",
                                 "transaction", "garbage", "integration"}
                and receipt["schema"] == 1 and receipt["destination"] == str(self.destination),
                "Current-candidate receipt shape differs")
        reader = self.preview.Installer(self.home, self.destination)
        reader.receipt = receipt
        for key in ("previous", "retired", "transaction", "garbage"):
            if receipt[key]:
                reader.slot(receipt[key]["slot"])
        reader.validate_receipt()  # Structure only; load() also checks a concurrently changing directory.
        return receipt

    def observe_managed_slots(self, native, registry):
        receipt = self.atomic_receipt()
        inventory = self.managed_nodes()
        changed = receipt != self.atomic_receipt()
        snapshot = {"time": time.time(), **inventory, "receipt": receipt, "receiptChangedDuringSample": changed,
                    "stableRegistered": registry["targetPresent"], "native": native}
        comparable = {k: v for k, v in snapshot.items() if k != "time"}
        if comparable != self.last_managed_sample:
            self.event("managed-app-inventory", **snapshot)
            self.last_managed_sample = comparable
        watch = self.reclaim_watch
        if watch is None or changed or inventory["concurrentRemoval"]:
            return snapshot
        count = len(inventory["nodes"])
        watch["maxObserved"] = max(watch["maxObserved"], count)
        transaction = receipt["transaction"]
        if watch["retiredPath"] in inventory["nodes"]:
            require(inventory["nodes"][watch["retiredPath"]][:2] == watch["retiredNode"],
                    "Owned retired C directory identity changed before reclamation")
        if count == 4 and watch["retiredPath"] in inventory["nodes"]:
            require(transaction and transaction["after"] == self.candidate_identities["D"],
                    "Four-bundle inventory lacks the exact D staging transaction")
            watch["fourBundleWitness"] = snapshot
        if not registry["targetPresent"]:
            watch["withdrawalObserved"] = True
        if watch["retiredPath"] not in inventory["nodes"] and watch.get("reclaimed") is None:
            require(watch.get("fourBundleWitness") and not registry["targetPresent"] and not native
                    and transaction and transaction["after"] == self.candidate_identities["D"]
                    and transaction["phase"] in ("ready", "reclaiming"),
                    "Retired C disappearance not observed under withdrawn, native-idle D preparation")
            watch["reclaimed"] = snapshot
        if watch.get("withdrawalObserved") and registry["targetPresent"]:
            require(watch.get("reclaimed"), "D publication observed before exact C reclamation")
            if "publishedNodes" not in watch:
                watch["publishedNodes"] = inventory["nodes"]
                watch["publicationObserved"] = snapshot["time"]
            require(inventory["nodes"] == watch["publishedNodes"], "Managed app changed after D publication")
        self.report["reclamationObservation"] = watch
        self.save()
        return snapshot

    def retention_state(self, label, current, previous=None, retired=None):
        reader = self.preview.Installer(self.home, self.destination)
        reader.load()  # Only at completed-command boundaries, never while staging/removal is active.
        receipt = reader.receipt
        require(not receipt["transaction"] and not receipt["integration"] and not receipt["garbage"],
                "Retention boundary has pending transaction/integration/garbage")
        roles = {}
        for role, variant in (("current", current), ("previous", previous), ("retired", retired)):
            item = receipt[role]
            if variant is None:
                require(item is None, f"Unexpected {role} artifact")
                continue
            require(item is not None, f"Missing required {role} artifact")
            identity = item if role == "current" else item["identity"]
            path = self.destination if role == "current" else reader.slot(item["slot"])
            require(identity == self.candidate_identities[variant], f"{role} does not identify signed fixture {variant}")
            reader.match(path, identity)
            self.ops.verify_registration(path, absent=role != "current")
            files = {}
            entries = [path, *path.rglob("*")]
            require(len(entries) <= 16384, "Managed bundle file inventory exceeds bound")
            for entry in entries:
                info = entry.lstat()
                files[str(entry.relative_to(path))] = [info.st_dev, info.st_ino, stat.S_IMODE(info.st_mode),
                                                      info.st_size, info.st_mtime_ns]
            roles[role] = {"variant": variant, "path": str(path), "identity": identity,
                           "node": self.preview.directory_identity(path), "files": files}
        inventory = self.managed_nodes()
        require(not inventory["concurrentRemoval"] and len(inventory["nodes"]) <= 3
                and set(inventory["nodes"]) == {r["path"] for r in roles.values()},
                "Stable managed bundle inventory differs from exact current/previous/retired roles")
        value = {"receipt": receipt, "roles": roles, "inventory": inventory}
        self.retention_states[label] = value
        (self.evidence / f"retention-{label}.json").write_text(json.dumps(value, indent=2) + "\n")
        return value

    def save(self):
        (self.evidence / "result.json").write_text(json.dumps(self.report, indent=2) + "\n")

    def event(self, kind, **details):
        self.report["events"].append({"time": time.time(), "kind": kind, **details})
        self.save()

    def run(self, args, *, timeout=120, check=True):
        args = list(map(str, args))
        self.sequence += 1
        stem = f"{self.sequence:03d}-{Path(args[0]).name}"
        self.event("command", argv=args, log=stem, timeout=timeout)
        with (self.evidence / f"{stem}.stdout").open("wb") as out, (
            self.evidence / f"{stem}.stderr"
        ).open("wb") as err:
            try:
                result = subprocess.run(args, cwd=ROOT, stdin=subprocess.DEVNULL,
                                        stdout=out, stderr=err, timeout=timeout)
            except (subprocess.TimeoutExpired, RuntimeError):
                self.command_incomplete = True
                self.event("command-incomplete", log=stem,
                           reason="Descendant completion unknown; no cleanup mutation may race this command")
                raise
        output = (self.evidence / f"{stem}.stdout").read_bytes()
        self.event("command-result", log=stem, returncode=result.returncode)
        require(not check or result.returncode == 0, f"{args[0]} exited {result.returncode}; see {stem}")
        return result.returncode, output

    def process_path(self, pid):
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        library.proc_pidpath.restype = ctypes.c_int
        buffer = ctypes.create_string_buffer(4096)
        length = library.proc_pidpath(pid, buffer, len(buffer))
        return os.fsdecode(buffer.value) if length > 0 else None

    def process(self, pid):
        before = self.ops.process_generation(pid, os.getuid())
        code = self.ops.executable_code_hash(pid)
        if before is None or code is None:
            return None
        path = self.process_path(pid)
        if self.ops.process_generation(pid, os.getuid()) != before:
            return None
        if self.ops.executable_code_hash(pid) != code:
            return None
        return {"generation": list(before), "cdhash": code,
                "path": path}

    def kernel_info(self, pid):
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        library.proc_pidinfo.argtypes = [
            ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        library.proc_pidinfo.restype = ctypes.c_int
        info = self.preview.ProcBSDInfo()
        ctypes.set_errno(0)
        length = library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
        require(length == ctypes.sizeof(info), f"Kernel PID {pid} info unavailable: errno {ctypes.get_errno()}")
        return info

    def worker_receipt(self):
        path = self.evidence / "snapshot-worker.json"
        self.preview.safe_path(path, owner=True)
        info = path.lstat()
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and 0 < info.st_size <= 4096,
                "Unsafe snapshot worker receipt")
        receipt = json.loads(path.read_text())
        require(isinstance(receipt, dict) and set(receipt) == {"pid", "tty", "workspace", "surface"}
                and type(receipt["pid"]) is int and 1 < receipt["pid"] < 2**31,
                "Invalid snapshot worker receipt")
        for name in ("workspace", "surface"):
            require(isinstance(receipt[name], str)
                    and str(uuid.UUID(receipt[name])) == receipt[name].lower(), "Invalid worker surface identity")
        require(isinstance(receipt["tty"], str)
                and re.fullmatch(r"/dev/tty[a-zA-Z0-9]+", receipt["tty"]), "Worker has no concrete TTY")
        return receipt

    def worker_identity(self):
        receipt = self.worker_receipt()
        pid = receipt["pid"]
        before = self.ops.process_generation(pid, os.getuid())
        require(before is not None, "Worker PID/owner/start generation unavailable")
        info = self.kernel_info(pid)
        path = self.process_path(pid)
        require(path == "/bin/zsh", "Worker executable is not the declared system shell")
        device = Path(receipt["tty"]).lstat()
        require(stat.S_ISCHR(device.st_mode) and info.tdev != 0xffffffff
                and info.tdev == (device.st_rdev & 0xffffffff), "Worker receipt does not match its kernel TTY")
        require(self.ops.process_generation(pid, os.getuid()) == before
                and (info.pid, info.uid, info.start_seconds, info.start_microseconds) == before
                and info.ruid == os.getuid() and self.kernel_info(pid).tdev == info.tdev
                and self.process_path(pid) == path, "Worker changed during kernel identity observation")
        return {**receipt, "generation": list(before), "path": path, "ttyDevice": info.tdev}

    def worker_diagnostics(self):
        receipt = self.worker_receipt()
        pid = receipt["pid"]
        info = self.kernel_info(pid)
        ctypes.set_errno(0)
        code_hash = self.ops.executable_code_hash(pid)
        hash_errno = ctypes.get_errno()
        chain = []
        current = info
        try:
            for _ in range(128):
                chain.append(current.pid)
                if current.ppid <= 1 or (self.host and current.pid == self.host["generation"][0]):
                    break
                current = self.kernel_info(current.ppid)
        except RuntimeError as error:
            ancestry_error = str(error)
        else:
            ancestry_error = None
        return {"receipt": receipt, "path": self.process_path(pid),
                "kernel": {name: getattr(info, name) for name in
                           ("pid", "ppid", "uid", "ruid", "flags", "status", "tdev",
                            "start_seconds", "start_microseconds")},
                "oldGenerationGate": self.ops.process_generation(pid, os.getuid()),
                "codeHash": code_hash, "codeHashErrno": hash_errno,
                "oldCompositeIdentity": self.process(pid), "parentChain": chain,
                "ancestryError": ancestry_error,
                "hostInChain": self.host["generation"][0] in chain if self.host else None,
                "ancestryIsDiagnosticOnly": True}

    def processes(self):
        result = subprocess.run(["/bin/ps", "-ax", "-o", "pid=", "-o", "uid=",
                                 "-o", "ppid=", "-o", "tty="],
                                capture_output=True, text=True, check=True, timeout=10)
        rows = []
        for line in result.stdout.splitlines():
            pid, uid, parent, tty = line.split()
            if int(uid) == os.getuid():
                identity = self.process(int(pid))
                if identity:
                    rows.append({**identity, "ppid": int(parent), "tty": tty})
        return rows

    def executable_hashes(self, bundle):
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        binary = bundle / "Contents/MacOS" / info["CFBundleExecutable"]
        hashes = set()
        for cpu, subtype in self.preview.mach_o_architectures(binary):
            result = subprocess.run(
                ["/usr/bin/codesign", "-d", "--verbose=4", "--architecture",
                 f"{cpu},{subtype}", str(binary)],
                capture_output=True, text=True, check=True, timeout=30)
            hashes.update(re.findall(r"^(?:CDHash|CandidateCDHash [a-z0-9]+)=([0-9a-f]{40})$",
                                     result.stderr, re.MULTILINE))
        require(hashes, f"No executable code-directory hashes: {binary}")
        self.event("executable-identity", binary=str(binary), sha256=sha256(binary),
                   cdhashes=sorted(hashes))
        return hashes

    def record_fixture_signing(self, variant, app):
        identities = {}
        for role, bundle in (("app", app), ("extension", app / self.preview.EXTENSION)):
            info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
            if variant == "A":
                require(FIXTURE_MARKER not in info, "Fixture marker collides with production metadata")
            else:
                require(info.pop(FIXTURE_MARKER, None) == variant, "Missing signed fixture generation marker")
            hashes = self.executable_hashes(bundle)
            binary = bundle / "Contents/MacOS" / info["CFBundleExecutable"]
            requirements = {}
            for cpu, subtype in self.preview.mach_o_architectures(binary):
                architecture = f"{cpu},{subtype}"
                args = ["/usr/bin/codesign", "-d", "--verbose=4", "-r-",
                        "--architecture", architecture, str(bundle)]
                result = subprocess.run(args, capture_output=True, text=True, timeout=30)
                stem = f"signing-{variant}-{role}-{cpu}-{subtype}"
                (self.evidence / f"{stem}.stdout").write_text(result.stdout)
                (self.evidence / f"{stem}.stderr").write_text(result.stderr)
                self.event("fixture-signing-inspection", argv=args, log=stem, returncode=result.returncode)
                raw = result.stdout + "\n" + result.stderr
                require(result.returncode == 0 and len(raw) <= 65_536 and "Signature=adhoc" in raw,
                        "Fixture must have a verifiable ad-hoc signature")
                matches = re.findall(r"^(?:#\s*)?designated => (.+)$", raw, re.MULTILINE)
                require(len(matches) == 1 and re.fullmatch(
                    r'cdhash H"[0-9a-f]{40}"(?: or cdhash H"[0-9a-f]{40}")*', matches[0]),
                    "Expected default ad-hoc CDHash requirement; no identifier-only or custom requirement accepted")
                bound = set(re.findall(r'cdhash H"([0-9a-f]{40})"', matches[0]))
                require(bound and bound <= hashes, "Designated requirement does not bind this fixture executable")
                requirements[architecture] = matches[0]
            for previous in self.fixture_signing.values():
                require(info == previous[role]["infoPlistWithoutFixtureMarker"],
                        "Fixture changed version/build/toolchain or other production plist values")
                require(hashes.isdisjoint(previous[role]["cdhashes"])
                        and set(requirements.values()).isdisjoint(previous[role]["designatedRequirements"].values()),
                        "Fixture did not regenerate a distinct executable CodeDirectory and default requirement")
            identities[role] = {"infoPlistWithoutFixtureMarker": info, "cdhashes": sorted(hashes),
                                "designatedRequirements": requirements, "executableSHA256": sha256(binary)}
        self.fixture_signing[variant] = identities
        self.hashes[variant] = set(identities["extension"]["cdhashes"])
        self.report["fixtureSigning"] = self.fixture_signing
        self.save()

    def observer_rows(self):
        require(self.observer is not None and self.observer.poll() is None, "Observer exited")
        data = (self.evidence / "observer.jsonl").read_bytes()
        # Ignore only a currently incomplete final write, never a malformed complete row.
        rows = [json.loads(line) for line in data.split(b"\n")[:-1]]
        identities = [r for r in rows if r["kind"] == "identities"]
        self.report["externalIdentityObservation"] = {
            "status": "advisory; stock-host visibility not established",
            "observerBundle": OBSERVER_ID,
            "lastEvent": identities[-1] if identities else None,
            "errors": [r for r in rows if r["kind"] == "observer-error"][-8:],
        }
        return rows

    def registration_catalog(self, raw):
        records = self.preview.metadata.registration_records(raw, allow_empty=True)
        elections = re.findall(r"^\s*([+\-!=?]?)\s*" + re.escape(EXT_ID) + r"(?:\([^\r\n]*\))?\s*$",
                               raw, re.MULTILINE)
        require(len(elections) == len(records), "Unexpected registration identifier/election output")
        allowed = {str(self.destination / self.preview.EXTENSION)}
        allowed.update(str(app / self.preview.EXTENSION) for app in self.sibling_apps)
        receipt = self.atomic_receipt()
        for key in ("previous", "retired", "transaction", "garbage"):
            item = receipt[key]
            if item:
                identity = item["after"] if key == "transaction" else item["identity"]
                require(identity in self.candidate_identities.values(), "Unknown candidate in owned registration slot")
                allowed.add(str(self.home / "Applications" / self.preview.STATE_NAME / item["slot"] / self.preview.EXTENSION))
        for record, election in zip(records, elections):
            path = record["Path"]
            require(record["id"] == EXT_ID and path in allowed
                    and str(Path(path).resolve()) == path
                    and record.get("SDK") == POINT_ID and record.get("Platform") == "macOS"
                    and record.get("Parent Bundle") == str(Path(path).parents[2])
                    and str(uuid.UUID(record.get("UUID", ""))) == record["UUID"].lower(),
                    "Unexpected path/point/parent/platform/UUID in eligible registration")
            record["election"] = election
        require(len({r["Path"] for r in records}) == len(records)
                and len({r["UUID"] for r in records}) == len(records), "Duplicate registration path/UUID")
        return sorted(records, key=lambda r: r["Path"])

    def registry_sample(self):
        result = subprocess.run(
            ["/usr/bin/pluginkit", "-m", "-A", "-D", "-vv", "-i", EXT_ID, "-p", POINT_ID],
            capture_output=True, text=True, timeout=5)
        valid = result.returncode == 0 and not result.stderr.strip() and len(result.stdout) <= 65_536
        if not valid:
            self.event("registration-observation-error", returncode=result.returncode,
                       stdout=result.stdout[:4096], stderr=result.stderr[:4096])
        require(valid, "Exact registration observation unavailable")
        records = self.registration_catalog(result.stdout)
        state = {
            "records": records,
            "targetPresent": any(Path(r["Path"]).resolve() ==
                                 (self.destination / self.preview.EXTENSION).resolve() for r in records),
            "electionLines": [line.strip() for line in result.stdout.splitlines()
                              if EXT_ID + "(" in line or line.strip().endswith(EXT_ID)],
        }
        if state != self.last_registration:
            self.event("native-registration", **state, raw=result.stdout)
            self.last_registration = state
        require(all(record in records for record in self.sibling_records.values()),
                "A preserved sibling registration/election changed or disappeared")
        return state

    def sample(self):
        if self.sibling_records:
            self.registry_sample()
        rows = self.processes()
        native_hashes = set().union(*self.hashes.values()) if self.hashes else set()
        extensions = [r for r in rows if r["cdhash"] in native_hashes]
        value = {"time": time.time(), "extensions": extensions}
        if self.baseline:
            require(self.process(self.host["generation"][0]) == self.host,
                    "CMUX process generation or signed executable changed")
            require(self.worker_identity() == self.baseline["worker"],
                    "Fixture worker PID/owner/start/path/kernel TTY or surface identity changed")
            observations = self.observer_rows()
            samples = [r for r in observations if r["kind"] == "sample"]
            require(samples and time.time() - samples[-1]["time"] < 5, "Observer heartbeat stale")
            recent = [r for r in observations if r["time"] >= self.baseline["time"]]
            for row in recent:
                if row["kind"] == "activation":
                    require(row["pid"] == self.baseline["frontmost"], "App activation changed during act")
                elif row["kind"] == "sample":
                    require(row["frontmost"] == self.baseline["frontmost"], "Frontmost app changed")
                    require(row["hostPIDs"] == [self.host["generation"][0]], "Host identity count changed")
                    require(row["visibleWindows"] == self.baseline["visibleWindows"],
                            "CMUX window disappeared or changed")
        if value["extensions"] != self.last_sample:
            self.event("native-processes", **value)
            self.last_sample = value["extensions"]
        return extensions

    def terminal_tree_snapshot(self):
        phases = ("baseline", "repeat", "update", "compensation", "reclaim-update", "repeat-D", "sibling-refusal")
        require(self.tree_snapshot_count < len(phases), "Unexpected additional tree request")
        phase = phases[self.tree_snapshot_count]
        self.tree_snapshot_count += 1
        self.report["treeObservation"] = {
            "status": "unavailable", "phase": phase, "policy": "cmuxOnly",
            "transport": "seven fixed reads from the test-owned initial terminal command",
        }
        (self.evidence / f"snapshot-request-{phase}").touch(exist_ok=False)
        self.event("tree-snapshot-request", phase=phase)
        completed = self.evidence / f"snapshot-{phase}.status"
        deadline = time.monotonic() + 20
        while not completed.exists():
            require(not (self.evidence / "snapshot-worker.exit").exists(),
                    "Initial terminal snapshot observer exited; tree observation unavailable")
            require(time.monotonic() < deadline,
                    "Initial terminal snapshot unavailable; no external socket-policy fallback")
            self.sample()
            time.sleep(0.25)
        require(completed.read_text().strip() == "0",
                f"Read-only terminal snapshot failed; see snapshot-{phase}.stderr")
        output = self.evidence / f"snapshot-{phase}.json"
        require(0 < output.stat().st_size <= 1_048_576, "Invalid tree snapshot size")
        return output.read_bytes()

    def tree(self):
        raw = self.terminal_tree_snapshot()
        value = json.loads(raw)
        require(isinstance(value, dict) and value.get("windows"), "No stock CMUX window tree")
        # Ignore labels/working-directory metadata, not identity, layout, or selection.
        keys = {"id", "type", "focused", "selected", "selected_in_pane", "tty",
                "key", "visible", "selected_workspace_id", "selected_surface_id",
                "surface_ids", "windows", "workspaces", "panes", "surfaces",
                "pane_id", "index", "index_in_pane", "layout", "pane", "direction", "split", "children"}
        def project(item):
            if isinstance(item, dict):
                return {k: project(v) for k, v in item.items() if k in keys}
            if isinstance(item, list):
                return [project(v) for v in item]
            return item
        result = project(value)
        for window in result["windows"]:
            require(isinstance(window.get("id"), str) and str(uuid.UUID(window["id"])) == window["id"].lower()
                    and type(window.get("key")) is bool
                    and type(window.get("visible")) is bool, "Invalid window identity/selection")
            for workspace in window.get("workspaces", []):
                require(isinstance(workspace.get("id"), str) and str(uuid.UUID(workspace["id"])) == workspace["id"].lower()
                        and type(workspace.get("selected")) is bool,
                        "Invalid workspace identity/selection")
                for pane in workspace.get("panes", []):
                    require(isinstance(pane.get("id"), str) and str(uuid.UUID(pane["id"])) == pane["id"].lower()
                            and type(pane.get("focused")) is bool,
                            "Invalid pane identity/selection")
                    for surface in pane.get("surfaces", []):
                        require(isinstance(surface.get("id"), str) and str(uuid.UUID(surface["id"])) == surface["id"].lower()
                                and type(surface.get("focused")) is bool
                                and type(surface.get("selected")) is bool, "Invalid surface identity/selection")
        worker = self.worker_identity()
        caller = value.get("caller", {})
        active = value.get("active", {})
        require(caller.get("workspace_id", "").lower() == worker["workspace"].lower()
                and caller.get("surface_id", "").lower() == worker["surface"].lower(),
                "Read-only snapshot caller is not the verified fixture worker surface")
        require(active.get("workspace_id", "").lower() == worker["workspace"].lower()
                and active.get("surface_id", "").lower() == worker["surface"].lower(),
                "Fixture setup did not return to the declared terminal before acceptance")
        surfaces = [s for w in result["windows"] for ws in w["workspaces"]
                    if ws["id"].lower() == worker["workspace"].lower()
                    for p in ws["panes"] for s in p["surfaces"]
                    if s["id"].lower() == worker["surface"].lower() and s.get("type") == "terminal"]
        require(len(surfaces) == 1 and surfaces[0].get("tty") in (None, worker["tty"]),
                "Fixture terminal UUID absent/duplicated or public TTY contradicts verified kernel TTY")
        self.report["treeObservation"]["status"] = "verified"
        self.save()
        return result

    def wait_loaded(self, variant, *, previous=None, timeout=120):
        deadline = time.monotonic() + timeout
        stable = None
        since = time.monotonic()
        while time.monotonic() < deadline:
            rows = self.sample()
            matches = [r for r in rows if r["cdhash"] in self.hashes[variant]]
            if len(rows) == 1 and len(matches) == 1:
                current = {k: matches[0][k] for k in ("generation", "cdhash", "path")}
                require(current["path"] == str(self.extension_binary),
                        "Loaded extension is not from the owned stable destination")
                if previous:
                    require(current["generation"] != previous["generation"],
                            "Same PID/start generation survived replacement")
                    require(self.ops.process_generation(previous["generation"][0], os.getuid())
                            != tuple(previous["generation"]), "Prior generation is still live")
                if current == stable:
                    if time.monotonic() - since >= 5:
                        self.event("loaded", variant=variant, identity=current)
                        return current
                else:
                    stable, since = current, time.monotonic()
            else:
                stable, since = None, time.monotonic()
            time.sleep(0.5)
        raise RuntimeError(f"No unique, stable, dynamically verified {variant} extension generation")

    def installer(self, name, *arguments, monitored=False, label=None, expect_failure=False):
        label = label or name
        args = [sys.executable, str(ROOT / "scripts/local-preview.py"), "--destination",
                str(self.destination), name, *map(str, arguments)]
        self.report["activeInstaller"] = {"operation": name, "label": label, "started": time.time()}
        self.event("installer-start", argv=args)
        with (self.evidence / f"installer-{label}.log").open("wb") as out:
            self.child = subprocess.Popen(args, cwd=ROOT, stdin=subprocess.DEVNULL,
                                          stdout=out, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 420
            defect = None
            while self.child.poll() is None:
                if monitored and defect is None:
                    try:
                        native = self.sample()
                        registry = self.registry_sample()
                        self.observe_managed_slots(native, registry)
                    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
                        defect = str(error)
                        self.event("continuity-failure", error=defect)
                require(time.monotonic() < deadline,
                        "Installer exceeded 420s; retained without signalling, runner teardown required")
                time.sleep(0.5)
            code = self.child.returncode
            self.child = None
        self.event("installer-end", operation=name, label=label, returncode=code, continuityError=defect)
        self.report["activeInstaller"]["returned"] = time.time()
        require((code != 0 if expect_failure else code == 0) and defect is None,
                f"Installer {label} had unexpected outcome; see installer-{label}.log")
        return code

    def registration(self):
        _, raw = self.run(["/usr/bin/pluginkit", "-m", "-A", "-D", "-vv", "-i", EXT_ID])
        self.preview.metadata.verify_registration_output(
            raw.decode(), self.destination / self.preview.EXTENSION)
        records = self.registration_catalog(raw.decode())
        require(len(records) == 1 + len(self.sibling_apps)
                and all(record in records for record in self.sibling_records.values()),
                "Exact stable/sibling native registration inventory changed")
        require(self.registry_sample()["records"] == records,
                "Registered paths are not all eligible for the public sidebar point")

    def verify_sibling_files(self):
        for app, expected in self.sibling_apps.items():
            self.preview.safe_tree(app)
            info = app.lstat()
            require([info.st_dev, info.st_ino, info.st_uid] == expected["node"]
                    and self.preview.digest(app) == expected["sha256"],
                    "Run-owned signed sibling files changed")

    def setup_legacy_siblings(self, previous, variant="D"):
        self.event("legacy-sibling-setup-start", stable=previous, variant=variant,
                   boundary="After genuine initial approval; no additional UI, defaults or host restart")
        digest = self.preview.digest(self.destination)
        for name in ("hardening", "visual49"):
            app = self.work / "legacy-siblings" / name / ".build/adhoc/Build/Products/Debug/CMUX Maestro Preview.app"
            require(not app.exists() and not app.is_symlink(), "Sibling fixture path already exists")
            app.parent.mkdir(parents=True, mode=0o700)
            app.mkdir(mode=0o700)
            info = app.lstat()
            self.sibling_apps[app] = {"node": [info.st_dev, info.st_ino, info.st_uid], "sha256": digest}
            self.apps_owned.append(app)
            self.run(["/usr/bin/ditto", self.destination, app])
            self.ops.verify(app, current=True)
            require(self.executable_hashes(app / self.preview.EXTENSION) == self.hashes[variant],
                    f"Sibling is not an exact signed {variant} extension")
            self.verify_sibling_files()
            self.run([self.preview.LSREGISTER, "-f", app])
            self.run(["/usr/bin/pluginkit", "-a", app / self.preview.EXTENSION])
            self.ops.verify_registration(app)
        # -D returns all eligible physical instances; '+' is election, not host approval.
        # pluginkit(8) explicitly excludes host-specific restrictions from its match.
        state = self.registry_sample()
        require(len(state["records"]) == 3 and state["targetPresent"]
                and all(r["election"] == "+" for r in state["records"]),
                "Three elected public-point-eligible records unavailable; no approval/election fallback")
        paths = {str(app / self.preview.EXTENSION) for app in self.sibling_apps}
        self.sibling_records = {r["Path"]: r for r in state["records"] if r["Path"] in paths}
        require(len(self.sibling_records) == 2, "Both sibling registrations must actually be eligible")
        self.registration()
        require(self.wait_loaded(variant) == previous,
                "Adding siblings displaced the current native generation; refusal baseline unavailable")
        self.verify_sibling_files()
        self.report["legacySiblingBaseline"] = {
            "loadedStable": previous, "variant": variant, "registrations": state["records"],
            "files": {str(app): identity for app, identity in self.sibling_apps.items()},
            "eligibility": "public pluginkit -m -A -D -i exactID -p exactPoint, all '+'",
            "limit": "Public matching is not stock-host-specific enumeration; only the stable extension is dynamically loaded.",
        }
        self.diagnostics("legacy-sibling-baseline")
        self.event("legacy-sibling-setup-complete")

    def approval_attachment_result(self, directory, nonce):
        require(directory == self.evidence / "approval-attachments", "Unexpected approval export directory")

        def read(name, limit):
            require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,160}", name),
                    "Unsafe exported attachment filename")
            path = directory / name
            self.preview.safe_path(path, owner=True)
            info = path.lstat()
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and 0 < info.st_size <= limit,
                    "Unsafe or oversized approval attachment")
            return path.read_bytes()

        manifest = json.loads(read("manifest.json", 262_144))
        require(isinstance(manifest, list) and len(manifest) == 1 and isinstance(manifest[0], dict)
                and manifest[0].get("testIdentifier") == "StockHostApprovalTests/testApproveOwnedNativeFixture()",
                "Approval export is not the single selected test")
        attachments = manifest[0].get("attachments")
        require(isinstance(attachments, list) and 0 < len(attachments) <= 64,
                "Missing or excessive approval attachments")
        completed, failed, total, approval_count, diagnostic_count = [], [], 0, 0, 0
        for attachment in attachments:
            require(isinstance(attachment, dict), "Invalid approval attachment manifest entry")
            name = attachment.get("exportedFileName")
            title = attachment.get("suggestedHumanReadableName")
            if not isinstance(title, str) or not title.startswith("approval-"):
                diagnostic_count += 1
                self.event("xctest-system-attachment-metadata", diagnosticOnly=True, fileOpened=False,
                           suggestedName=title[:512] if isinstance(title, str) else "(non-string)",
                           exportedFileName=name[:256] if isinstance(name, str) else "(non-string)",
                           associatedWithFailure=attachment.get("isAssociatedWithFailure")
                           if type(attachment.get("isAssociatedWithFailure")) is bool else None)
                continue
            approval_count += 1
            require(len(title) <= 512, "Oversized approval attachment name")
            suffix = Path(name).suffix if isinstance(name, str) else ""
            limits = {".json": 16_384, ".txt": 1_048_576, ".png": 16_777_216}
            require(suffix in limits and title.endswith(suffix), "Unexpected approval attachment type")
            data = read(name, limits[suffix])
            total += len(data)
            require(total <= 33_554_432, "Approval evidence exceeds its aggregate bound")
            if title.startswith("approval-result-") and suffix == ".json":
                result = json.loads(data)
                require(isinstance(result, dict) and result.get("schema") == 1
                        and result.get("runID") == os.environ["GITHUB_RUN_ID"]
                        and result.get("nonce") == nonce and result.get("runnerUID") == os.getuid()
                        and result.get("hostPID") == self.host["generation"][0]
                        and result.get("extensionID") == EXT_ID, "Approval result belongs to another context")
                stage = result.get("stage")
                require(isinstance(stage, str) and re.fullmatch(r"[a-z][a-z-]{0,63}", stage)
                        and title.startswith(f"approval-result-{stage}_"),
                        "Approval result stage does not match its attachment")
                if result.get("stage") == "setup-ui-complete":
                    completed.append(result)
                elif result.get("stage") == "setup-ui-failed":
                    failed.append(result)
        require(len(completed) <= 1 and len(failed) <= 1 and not (completed and failed),
                "Ambiguous/repeated approval result")
        result = completed[0] if completed else failed[0] if failed else None
        if result is not None:
            path = self.evidence / "approval-result.json"
            with path.open("x") as stream:
                json.dump(result, stream, indent=2)
        self.event("approval-attachments-validated", directory=str(directory), approvalCount=approval_count,
                   diagnosticOnlyCount=diagnostic_count)
        return result

    def approve_fixture(self):
        require(self.report["phase"] == "setup" and self.baseline is None,
                "UI approval is forbidden after fixture setup")
        self.report["uiApproval"] = {"status": "unavailable", "scope": "initial hosted fixture only"}
        self.event("ui-approval-setup-start")
        self.worker = self.worker_identity()
        _, raw = self.run(["/usr/bin/pluginkit", "-m", "-A", "-D", "-vv", "-p", POINT_ID])
        records = self.preview.metadata.registration_records(raw.decode())
        require(len(records) == 1 and records[0]["id"] == EXT_ID
                and Path(records[0]["Path"]).resolve() == (self.destination / self.preview.EXTENSION).resolve(),
                "Public UI approval requires exactly the owned fixture at this extension point")
        labels = {records[0][key] for key in ("Display Name", "Short Name", "Parent Name")
                  if key in records[0]}
        nonce = str(uuid.uuid4())
        context = json.dumps({
            "schema": 1, "runID": os.environ["GITHUB_RUN_ID"], "nonce": nonce,
            "runnerUID": os.getuid(), "hostPID": self.host["generation"][0],
            "hostPath": str(self.stock), "extensionID": EXT_ID, "labels": sorted(labels),
            "terminalTitle": "/usr/bin/env",
        }, separators=(",", ":"))
        require(len(context.encode()) <= 8192, "UI context exceeds its small nonsecret transport bound")
        project = ROOT / "scripts/stock-host-approval/StockHostApproval.xcodeproj"
        derived = self.work / "approval-build"
        toolchain = ["/usr/bin/env", "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"]
        code, _ = self.run([
            *toolchain, "/usr/bin/xcodebuild", "-project", project, "-scheme", "StockHostApproval", "-configuration", "Debug",
            "-derivedDataPath", derived, "-destination", "platform=macOS",
            "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=", "build-for-testing",
        ], timeout=240, check=False)
        self.report["uiApproval"]["harnessBuildExit"] = code
        self.save()
        require(code == 0, "Public-approval XCTest harness build failed; not a native reload result")
        runs = list((derived / "Build/Products").glob("*.xctestrun"))
        require(len(runs) == 1, "Missing or ambiguous generated XCTest run configuration")
        config = plistlib.loads(runs[0].read_bytes())
        if "TestConfigurations" in config:
            targets = [target for item in config["TestConfigurations"] for target in item["TestTargets"]]
        else:
            targets = [config["StockHostApprovalTests"]] if "StockHostApprovalTests" in config else []
        require(len(targets) == 1 and "TestBundlePath" in targets[0] and "TestHostPath" in targets[0],
                "Unexpected XCTest UI target configuration")
        target = targets[0]
        # Keep generated testing environment intact; xcodebuild(1) explicitly forwards
        # TEST_RUNNER_<VAR> to runner processes with the prefix stripped.
        target["UITargetAppPath"] = str(self.stock)
        target.setdefault("DependentProductPaths", []).append(str(self.stock))
        runner_context = {
            "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
            "GITHUB_RUN_ID": os.environ["GITHUB_RUN_ID"], "PROBE_APPROVAL_CONTEXT_JSON": context,
        }
        target["SystemAttachmentLifetime"] = "keepAlways"
        target["UserAttachmentLifetime"] = "keepAlways"
        configured = runs[0].with_name("StockHostApproval-configured.xctestrun")
        configured.write_bytes(plistlib.dumps(config))
        code, _ = self.run([
            *toolchain, *[f"TEST_RUNNER_{key}={value}" for key, value in runner_context.items()],
            "/usr/bin/xcodebuild", "test-without-building", "-xctestrun", configured, "-destination", "platform=macOS",
            "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES",
            "-maximum-test-execution-time-allowance", "90",
            "-only-testing:StockHostApprovalTests/StockHostApprovalTests/testApproveOwnedNativeFixture",
            "-resultBundlePath", self.evidence / "native-approval.xcresult",
        ], timeout=180, check=False)
        exported = self.evidence / "approval-attachments"
        exported.mkdir(mode=0o700)
        export_code, _ = self.run([
            *toolchain, "/usr/bin/xcrun", "xcresulttool", "export", "attachments",
            "--test-id", "StockHostApprovalTests/testApproveOwnedNativeFixture()",
            "--filter", "approval-*", "--path", self.evidence / "native-approval.xcresult",
            "--output-path", exported,
        ], timeout=30, check=False)
        require(export_code == 0, "XCTest evidence export unavailable; no approval result may be inferred")
        ui_result = self.approval_attachment_result(exported, nonce)
        self.report["uiApproval"] = {
            "status": "unavailable",
            "xcodebuildExit": code, "result": ui_result,
            "scope": "first-time public UI fixture consent only; never repeated for update/rollback",
        }
        self.save()
        require(code == 0 and ui_result is not None
                and ui_result.get("status") == "enabled-via-public-ui"
                and ui_result.get("runID") == os.environ["GITHUB_RUN_ID"]
                and ui_result.get("hostPID") == self.host["generation"][0]
                and ui_result.get("extensionID") == EXT_ID and ui_result.get("after") == 1,
                "Public native-approval UI setup unavailable/failed; inspect approval result, XCTest logs and xcresult")
        require(self.process(self.host["generation"][0]) == self.host
                and self.worker_identity() == self.worker,
                "UI setup did not preserve the declared stock host and original terminal")
        self.report["uiApproval"]["status"] = "completed; kernel-loaded baseline still required"
        self.report["uiInteractionEnded"] = time.time()
        self.event("ui-approval-setup-complete", result=ui_result)

    def setup(self):
        self.work.mkdir(mode=0o700)
        self.work_owned = True
        self.report["head"] = self.run(["git", "rev-parse", "HEAD"])[1].decode().strip()
        self.run(["git", "merge-base", "--is-ancestor", BASE, "HEAD"])
        self.report["productSourceSHA256"] = {
            name: sha256(ROOT / name) for name in (
                "scripts/local-preview.py", "scripts/build-register.sh",
                "CMUXMaestroPreview/Integration/CopilotSetup.swift",
                "CMUXMaestroPreview/Integration/CopilotSetupMetadata.swift",
                "CMUXMaestroPreview/Integration/CopilotObserverRegistration.swift",
            )
        }
        _, os_version = self.run(["/usr/bin/sw_vers"])
        # Query the exact Xcode path that build-register.sh hardcodes.
        build_tools = ["/usr/bin/env", "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"]
        _, xcode_version = self.run([*build_tools, "/usr/bin/xcodebuild", "-version"])
        _, compiler = self.run([*build_tools, "/usr/bin/xcrun", "swiftc", "--version"])
        self.report["environment"] = {
            "os": os_version.decode().strip(),
            "xcode": xcode_version.decode().strip(),
            "swift": compiler.decode().strip(),
            "developerDirectory": str(Path("/Applications/Xcode.app/Contents/Developer").resolve()),
        }
        self.save()
        swift_version = re.search(r"\bSwift version (\d+)\.(\d+)\b", compiler.decode())
        require(swift_version and tuple(map(int, swift_version.groups())) >= (6, 2),
                "/Applications/Xcode.app must provide Swift 6.2+; native probe toolchain unavailable")
        require(not self.destination.exists() and not self.source.exists(), "Fixture output already exists")
        for path in (self.home / "Applications" / self.preview.STATE_NAME,
                     self.home / ".copilot",
                     self.terminal_config.parent,
                     self.home / ".config/cmux", self.home / "Library/Application Support/cmux",
                     self.home / "Library/Application Support/com.cmuxterm.app",
                     self.home / "Library/Application Support/CMUXMaestroPreview",
                     self.home / "Library/Preferences/com.cmuxterm.app.plist",
                     Path("/Applications/cmux.app"), Path("/tmp/cmux.sock")):
            require(not path.exists() and not path.is_symlink(), f"Profile is not clean: {path}")
        code, domain = self.run(["/usr/bin/defaults", "export", DOMAIN, "-"], check=False)
        require(code != 0 or not plistlib.loads(domain), "Existing CMUX defaults refused")
        _, registrations = self.run(["/usr/bin/pluginkit", "-m", "-A", "-D", "-vv", "-i", EXT_ID])
        require(not self.preview.metadata.registration_records(
            registrations.decode(), allow_empty=True), "Existing Maestro extension refused")
        require(not self.ops.app_paths(), "Existing Maestro app registration refused")
        self.fixture_profile_verified = True
        self.prepare_copilot()
        dmg = self.work / "cmux-macos.dmg"
        self.run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
                  "--max-time", "300", "--output", dmg, DMG_URL], timeout=310)
        require(dmg.stat().st_size == 225832896 and sha256(dmg) == DMG_SHA256,
                "Official stock DMG size/digest mismatch")
        self.run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint",
                  self.mount, dmg])
        self.stock.mkdir(mode=0o755)
        node = self.stock.lstat()
        self.stock_node = (node.st_dev, node.st_ino, node.st_uid)
        self.run(["/usr/bin/ditto", self.mount / "cmux.app", self.stock])
        self.run(["/usr/bin/hdiutil", "detach", self.mount])
        stock_info = plistlib.loads((self.stock / "Contents/Info.plist").read_bytes())
        require(stock_info["CFBundleIdentifier"] == DOMAIN and
                stock_info["CFBundleShortVersionString"] == "0.64.25" and
                stock_info["CFBundleVersion"] == "106", "Stock bundle version mismatch")
        self.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", self.stock])
        _, version = self.run([self.stock / "Contents/Resources/bin/cmux", "--version"])
        require("b685a275c" in version.decode(), "Stock CLI source revision mismatch")
        self.host_hashes = self.executable_hashes(self.stock)
        # Stock owns the public point declaration. Do not redeclare it in the observer.
        # https://github.com/manaflow-ai/cmux/blob/b685a275c2e411799857155e37264daf84f7e4d6/scripts/write-sidebar-extension-point.sh
        point = self.stock / "Contents/Extensions" / f"{POINT_ID}.appextensionpoint"
        declaration = plistlib.loads(point.read_bytes())
        require(set(declaration) == {POINT_ID}
                and declaration[POINT_ID].get("EXExtensionPointIsPublic") is True
                and declaration[POINT_ID].get("EXPresentsUserInterface") is True,
                "Verified stock bundle lacks its expected public native point")
        self.event("stock-point-declaration", path=str(point), sha256=sha256(point),
                   extensionPoint=POINT_ID)
        self.run([self.preview.LSREGISTER, "-f", self.stock])
        # Discovery is a host-app API, not a global registry query from a bare executable.
        # https://developer.apple.com/documentation/extensionfoundation/discovering-app-extensions-from-your-app
        self.helper.parent.mkdir(parents=True, mode=0o700)
        (self.observer_app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": OBSERVER_ID,
            "CFBundleExecutable": self.helper.name,
            "CFBundleName": "Stock Host Observer",
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleVersion": "1",
            "LSBackgroundOnly": True,
        }))
        self.run(["/usr/bin/xcrun", "swiftc", "-parse-as-library",
                  ROOT / "scripts/stock-host-observer.swift", "-o", self.helper], timeout=180)
        self.run(["/usr/bin/codesign", "--sign", "-", "--timestamp=none",
                  "--identifier", OBSERVER_ID, self.observer_app])
        self.run(["/usr/bin/codesign", "--verify", "--strict", self.observer_app])
        self.run([self.preview.LSREGISTER, "-f", self.observer_app])
        with (self.evidence / "observer.jsonl").open("wb") as out, (
            self.evidence / "observer.stderr"
        ).open("wb") as err:
            self.observer = subprocess.Popen([str(self.helper), "watch"], stdin=subprocess.DEVNULL,
                                             stdout=out, stderr=err)
        deadline = time.monotonic() + 15
        while True:
            observations = self.observer_rows()
            require(not any(r.get("hostPIDs") for r in observations), "Preexisting CMUX host")
            contexts = [r for r in observations if r["kind"] == "observer-context"]
            samples = [r for r in observations if r["kind"] == "sample"]
            if contexts and samples:
                require(contexts[-1]["bundleIdentifier"] == OBSERVER_ID
                        and contexts[-1]["bundlePath"] == str(self.observer_app),
                        "Discovery observer is not the exact test-only app")
                self.event("observer-desktop-ready", nativeDiscovery="pending registered fixture")
                break
            require(time.monotonic() < deadline, "Observer context/desktop not ready")
            time.sleep(0.25)
        self.apps_owned.append(self.source)
        self.run(["/bin/bash", ROOT / "scripts/build-stock-host-fixture.sh"], timeout=900)
        self.record_fixture_signing("A", self.source)
        self.candidates = {"A": self.source}
        for variant in ("B", "C", "D"):
            candidate = self.work / f"candidate-{variant}.app"
            self.candidates[variant] = candidate
            self.apps_owned.append(candidate)
            self.run(["/usr/bin/ditto", self.source, candidate])
            adapter = candidate / "Contents/Resources/adapter.mjs"
            with adapter.open("a") as stream:
                stream.write(f"\n// Hosted signed fixture resource generation {variant}; behavior unchanged.\n")
            for bundle in (candidate / self.preview.EXTENSION, candidate):
                info_path = bundle / "Contents/Info.plist"
                info = plistlib.loads(info_path.read_bytes())
                info[FIXTURE_MARKER] = variant
                info_path.write_bytes(plistlib.dumps(info))
                self.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
                          "--preserve-metadata=identifier,entitlements,flags,runtime", bundle])
            self.ops.verify(candidate, current=True)
            self.record_fixture_signing(variant, candidate)
        self.candidate_identities = {
            variant: {"sha256": self.preview.digest(app), "version": self.ops.verify(app, current=True)}
            for variant, app in self.candidates.items()
        }
        self.report["candidateAppIdentities"] = self.candidate_identities
        c_extension = self.candidates["C"] / self.preview.EXTENSION
        executable = plistlib.loads((c_extension / "Contents/Info.plist").read_bytes())["CFBundleExecutable"]
        self.extension_binary = self.destination / self.preview.EXTENSION / "Contents/MacOS" / executable
        self.fault_arm = self.work / "fail-late-provider-verification"
        config = self.work / "provider-proxy.json"
        config.write_text(json.dumps({
            "uid": os.getuid(), "home": str(self.home), "executable": str(self.copilot_real),
            "arm": str(self.fault_arm), "evidence": str(self.evidence / "actual-late-fault.json"),
            "installedExtension": str(self.extension_binary),
            "candidateExtensionSHA256": sha256(c_extension / "Contents/MacOS" / executable),
            "installedAdapter": str(self.home / ".copilot/extensions/maestro/adapter.mjs"),
            "candidateAdapterSHA256": sha256(self.candidates["C"] / "Contents/Resources/adapter.mjs"),
        }))
        node = shutil.which("node")
        require(node is not None, "Node is required for the real-provider fault proxy")
        self.copilot = self.work / "official-copilot"
        self.copilot.write_text("#!/bin/sh\nexec " + shlex.join([
            node, str(ROOT / "scripts/stock-host-provider-proxy.mjs"), str(config)]) + ' "$@"\n')
        self.copilot.chmod(0o700)
        self.installer("install", "--source", self.source, "--retire-development-registration",
                       "--copilot-executable", self.copilot)
        self.integration_state("first-install", self.source)
        self.retention_state("first-install", "A")
        self.registration()
        extension = self.destination / self.preview.EXTENSION
        executable = plistlib.loads((extension / "Contents/Info.plist").read_bytes())["CFBundleExecutable"]
        self.extension_binary = extension / "Contents/MacOS" / executable
        setup_plist = self.work / "setup-defaults.plist"
        setup_plist.write_bytes(plistlib.dumps(SETUP_DEFAULTS))
        self.defaults_owned = True
        self.run(["/usr/bin/defaults", "import", DOMAIN, setup_plist])
        self.event("setup-only-selection", defaults=SETUP_DEFAULTS,
                   meaning="Preexisting enabled selection fixture; not first-time onboarding or production technique")
        self.run(["/usr/bin/pluginkit", "-e", "use", "-i", EXT_ID])
        self.registry_sample()
        # Stock preserves Ghostty's configured command. The CLI must originate in
        # that terminal's process tree; an external CI caller fails cmuxOnly.
        self.preview.safe_path(self.terminal_config, owner=True)
        self.terminal_config.parent.mkdir(parents=True, mode=0o700)
        command = ["/usr/bin/env", "GITHUB_ACTIONS=true", "RUNNER_ENVIRONMENT=github-hosted",
                   f"RUNNER_TEMP={Path(os.environ['RUNNER_TEMP']).resolve()}",
                   "/bin/zsh", "-f", str(ROOT / "scripts/stock-host-snapshots.zsh"),
                   str(self.work), str(self.evidence)]
        contents = "command = direct:" + shlex.join(command) + "\n"
        with self.terminal_config.open("x") as config:
            config.write(contents)
        self.terminal_config_contents = contents
        self.event("setup-only-terminal-command", command=command, config=str(self.terminal_config),
                   purpose="fixed read-only snapshots; no typed input or socket policy change")
        self.host_launch_requested = True
        self.run(["/usr/bin/open", "-g", self.stock])
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            hosts = [r for r in self.processes() if r["cdhash"] in self.host_hashes
                     and r["path"] == str(self.stock / "Contents/MacOS" / stock_info["CFBundleExecutable"])]
            if len(hosts) == 1:
                self.host = {k: hosts[0][k] for k in ("generation", "cdhash", "path")}
                break
            time.sleep(0.5)
        require(self.host, "Stock CMUX did not start")
        self.event("stock-host-started", identity=self.host)
        self.sample()
        deadline = time.monotonic() + 20
        while not (self.evidence / "snapshot-worker.json").exists():
            require(time.monotonic() < deadline, "No original terminal available for public UI setup")
            time.sleep(0.25)
        self.approve_fixture()
        self.initial = self.wait_loaded("A")
        self.registration()
        deadline = time.monotonic() + 20
        while not (self.evidence / "snapshot-worker.json").exists():
            require(time.monotonic() < deadline, "No immutable fixture-worker receipt")
            require(self.process(self.initial["generation"][0]) == self.initial,
                    "Initial A generation exited before terminal baseline")
            time.sleep(0.25)
        self.worker = self.worker_identity()
        self.event("verified-terminal-worker", identity=self.worker)
        observations = self.observer_rows()
        sample = [r for r in observations if r["kind"] == "sample"][-1]
        require(sample["hostPIDs"] == [self.host["generation"][0]] and sample["visibleWindows"]
                and sample["frontmost"] > 0, "Desktop/stock host window unavailable")
        self.baseline = {"time": time.time(), "frontmost": sample["frontmost"],
                         "visibleWindows": sample["visibleWindows"], "worker": self.worker,
                         "tree": self.tree()}
        self.report["baseline"] = {"host": self.host, "extension": self.initial, **self.baseline}
        self.report["checks"]["firstCombinedInstall"] = {"status": "pass", "provider": "official 1.0.89",
                                                        "evidence": "integration-first-install.json"}
        self.report["checks"]["setup"] = "pass"
        self.report["phase"] = "acceptance"
        self.save()

    def act(self, operation, previous, variant, *arguments, label=None):
        label = label or operation
        self.registry_sample()
        start = time.time()
        require(self.process(previous["generation"][0]) == previous,
                "Expected old extension generation is not live at act start")
        self.installer(operation, *arguments, monitored=True, label=label)
        if variant == "D":
            self.observe_compensation_settlement(previous, start, variant="D", label="reclaim-settlement")
        loaded = self.wait_loaded(variant, previous=previous)
        self.registration()
        self.registry_sample()
        require(self.tree() == self.baseline["tree"], "Window/workspace/pane/surface identity or selection changed")
        _, raw = self.run(["/usr/bin/defaults", "export", DOMAIN, "-"])
        current = plistlib.loads(raw)
        require(all(current.get(k) == v for k, v in SETUP_DEFAULTS.items()), "Selection/config changed during act")
        rows = [r for r in self.report["events"]
                if r["kind"] == "native-registration" and r["time"] >= start]
        missing = next((r["time"] for r in rows if not r["targetPresent"]), None)
        require(missing is not None and any(
            r["time"] > missing and r["targetPresent"] and len(r["records"]) == 1 + len(self.sibling_apps) for r in rows
        ), "No independently observed stable-path withdrawal/restoration with expected sibling inventory")
        self.verify_sibling_files()
        self.report["checks"][label] = {
            "status": "pass", "old": previous, "new": loaded, "registrationDisappearance": missing,
            "registrationScope": "stable path only", "preservedSiblingCount": len(self.sibling_apps),
            "hostAndShellGenerationsUnchanged": True, "treeUnchanged": True,
            "focusAndVisibleWindowsUnchanged": True,
        }
        self.save()
        self.diagnostics(f"after-{label}")
        return loaded

    def identical_repeat(self, variant="A", previous=None, label="identical-repeat"):
        previous = previous or self.initial
        app_node = self.destination.stat().st_ino
        app_digest = self.preview.digest(self.destination)
        registration = self.registry_sample()
        before = self.integration_state(f"before-{label}", self.candidates[variant])
        roles = (variant, "B", "A") if variant == "D" else ("A", None, None)
        retained = self.retention_state(f"before-{label}", *roles)
        self.installer("install", "--source", self.candidates[variant], "--copilot-executable", self.copilot,
                       monitored=True, label=label)
        after = self.integration_state(label, self.candidates[variant], compare_bytes=before)
        require(after["resources"] == before["resources"] and self.destination.stat().st_ino == app_node
                and self.preview.digest(self.destination) == app_digest
                and self.process(previous["generation"][0]) == previous
                and self.registry_sample() == registration and self.tree() == self.baseline["tree"],
                "Identical repeat replaced app/resources/native process or changed registration/terminal")
        self.sample()
        self.verify_sibling_files()
        require(self.retention_state(label, *roles) == retained, "Identical repeat changed owned retained files/inodes")
        self.report["checks"][label] = {"status": "pass", "native": previous,
                                                   "appAndOwnedResourcesNotReplaced": True}
        self.save()

    def failed_update_compensation(self, previous):
        before = self.integration_state("before-failed-update", self.candidates["B"])
        protected = self.retention_state("before-failed-update", "B", "A")
        before_digest = self.preview.digest(self.destination)
        self.fault_arm.touch(mode=0o600, exist_ok=False)
        start = time.time()
        require(self.process(previous["generation"][0]) == previous,
                "Preceding B generation must be live before the failing update")
        self.installer("update", "--source", self.candidates["C"], "--copilot-executable", self.copilot,
                       monitored=True, label="late-failure-compensation", expect_failure=True)
        fault = self.evidence / "actual-late-fault.json"
        require(fault.is_file() and Path(str(self.fault_arm) + ".consumed").is_file(),
                "Expected real post-publication provider fault was not observed")
        self.observe_compensation_settlement(previous, start)
        restored = self.wait_loaded("B", previous=previous)
        self.registration()
        self.registry_sample()
        self.integration_state("after-compensation", self.candidates["B"], compare_bytes=before, new_retired="C")
        retained = self.retention_states["compensated-apps"]
        require(all(retained["roles"][role] == protected["roles"][role] for role in ("current", "previous")),
                "Failed update altered required working B or previous A files/inodes")
        require(self.preview.digest(self.destination) == before_digest
                and self.tree() == self.baseline["tree"], "Preceding app/terminal state was not restored")
        _, raw = self.run(["/usr/bin/defaults", "export", DOMAIN, "-"])
        current = plistlib.loads(raw)
        require(all(current.get(k) == v for k, v in SETUP_DEFAULTS.items()), "Host setup changed during compensation")
        registry = [r for r in self.report["events"] if r["kind"] == "native-registration" and r["time"] >= start]
        require(any(not r["targetPresent"] for r in registry)
                and self.registry_sample()["targetPresent"], "Compensation registration transition not observed")
        self.verify_sibling_files()
        self.sample()
        self.report["checks"]["failedUpdateCompensation"] = {
            "status": "pass", "fault": json.loads(fault.read_text()), "old": previous, "restored": restored,
            "registrationScope": "stable path only", "preservedSiblingCount": len(self.sibling_apps),
            "appIntegrationProviderStateRestored": True, "hostWorkerTreeFocusUnchanged": True,
        }
        self.save()
        self.diagnostics("after-compensation")
        return restored

    def reclaim_update(self, previous):
        before = self.retention_state("before-D", "B", "A", "C")
        retired = before["roles"]["retired"]
        self.reclaim_watch = {"retiredPath": retired["path"], "retiredNode": retired["node"],
                              "maxObserved": len(before["inventory"]["nodes"]), "withdrawalObserved": False}
        loaded = self.act("update", previous, "D", "--source", self.candidates["D"],
                          "--copilot-executable", self.copilot, label="reclaim-update")
        require(self.process(loaded["generation"][0]) == loaded, "D changed during post-return settlement")
        after = self.retention_state("after-D", "D", "B", "A")
        require(self.reclaim_watch["maxObserved"] == 4 and self.reclaim_watch.get("reclaimed")
                and self.reclaim_watch.get("publicationObserved") and not Path(retired["path"]).exists(),
                "Bounded old-retired reclamation/publication proof unavailable")
        for old_role, new_role in (("current", "previous"), ("previous", "retired")):
            require(all(before["roles"][old_role][key] == after["roles"][new_role][key]
                        for key in ("identity", "node", "files")), "D update changed required B/A retained contents")
        self.integration_state("after-D", self.candidates["D"])
        self.report["checks"]["retentionReclamation"] = {
            "status": "pass", "maxObserved": 4, "stableCount": len(after["inventory"]["nodes"]),
            "reclaimedC": retired["path"], "current": "D", "previous": "B", "retired": "A",
        }
        self.save()
        return loaded

    def sibling_preflight_refusal(self, previous):
        before = self.integration_state("before-sibling-refusal", self.candidates["D"])
        retained = self.retention_state("before-sibling-refusal", "D", "B", "A")
        registration = self.registry_sample()
        start = time.time()
        self.installer("update", "--source", self.candidates["C"], "--copilot-executable", self.copilot,
                       monitored=True, expect_failure=True, label="sibling-refusal")
        text = (self.evidence / "installer-sibling-refusal.log").read_text()
        prefix = "External same-ID native registrations require a separate ownership/consent decision: "
        suffix = ". Preflight did not change these registrations."
        expected_paths = sorted(str(app / self.preview.EXTENSION) for app in self.sibling_apps)
        message = next((line for line in text.splitlines() if prefix in line and suffix in line), None)
        require(message is not None, "Update did not return the exact native-sibling preflight diagnostic")
        listed = message.split(prefix, 1)[1].split(suffix, 1)[0].split("; ")
        require(sorted(listed) == [path + " (election +)" for path in expected_paths],
                "Preflight diagnostic did not identify exactly both elected sibling paths")
        after = self.integration_state("after-sibling-refusal", self.candidates["D"], compare_bytes=before)
        require(after["resources"] == before["resources"]
                and self.retention_state("after-sibling-refusal", "D", "B", "A") == retained
                and self.registry_sample() == registration
                and self.process(previous["generation"][0]) == previous
                and self.tree() == self.baseline["tree"], "Refused update changed app/retained/integration/native/terminal state")
        events = [e for e in self.report["events"] if e["time"] >= start]
        require(not any(e["kind"] == "native-registration" for e in events)
                and all(e["nodes"] == retained["inventory"]["nodes"] and e["receipt"] == retained["receipt"]
                        for e in events if e["kind"] == "managed-app-inventory"),
                "Preflight refusal had observed app/receipt/registration effects")
        self.verify_sibling_files()
        self.sample()
        self.report["checks"]["siblingPreflightRefusal"] = {
            "status": "pass", "diagnostic": message, "paths": expected_paths,
            "originalNative": previous, "appReceiptRetainedResourcesRegistrationUnchanged": True,
        }
        self.save()

    def observe_compensation_settlement(self, previous, act_start, *, variant="B", label="compensation-settlement"):
        returned = time.time()
        observations = {"actStart": act_start, "installerReturn": self.report["activeInstaller"]["returned"],
                        "observationStart": returned, "samples": [], "losses": [], "status": "observing"}
        self.report["compensationSettlement" if variant == "B" else "reclaimSettlement"] = observations
        recent = [e for e in self.report["events"] if e["time"] >= act_start]
        catalogs = [e for e in recent if e["kind"] == "native-registration"]
        seen_registration = bool(catalogs and catalogs[-1]["targetPresent"])
        seen_native = any(p["generation"] != previous["generation"] and p["cdhash"] in self.hashes[variant]
                          and p["path"] == str(self.extension_binary)
                          for e in recent if e["kind"] == "native-processes" for p in e["extensions"])
        clock = time.monotonic()
        for index, offset in enumerate((0, 1, 2, 5, 10, 15)):
            time.sleep(max(0, clock + offset - time.monotonic()))
            sample = {"time": time.time(), "secondsAfterObservationStart": time.monotonic() - clock}
            for name, extra in (("all", []), ("point", ["-p", POINT_ID])):
                result = subprocess.run(
                    ["/usr/bin/pluginkit", "-m", "-A", "-D", "-vv", "-i", EXT_ID, *extra],
                    capture_output=True, text=True, timeout=5)
                stem = f"{label}-{index}-{name}"
                (self.evidence / f"{stem}.stdout").write_text(result.stdout[:65_536])
                (self.evidence / f"{stem}.stderr").write_text(result.stderr[:4096])
                require(result.returncode == 0 and not result.stderr.strip() and len(result.stdout) <= 65_536,
                        "Compensation settlement registration query unavailable")
                sample[name] = self.registration_catalog(result.stdout)
            sample["native"] = self.sample()
            sample["launchServicesAppPresent"] = self.destination.resolve() in self.ops.app_paths()
            present = any(r["Path"] == str(self.destination / self.preview.EXTENSION) for r in sample["point"])
            loaded = (len(sample["native"]) == 1 and sample["native"][0]["cdhash"] in self.hashes[variant]
                      and sample["native"][0]["path"] == str(self.extension_binary)
                      and sample["native"][0]["generation"] != previous["generation"])
            sample.update(stableRegistrationPresent=present, restoredBLoaded=loaded if variant == "B" else None,
                          expectedVariant=variant, expectedNativeLoaded=loaded)
            if seen_registration and not present:
                observations["losses"].append({"time": sample["time"], "kind": "stable-registration-disappeared"})
            if seen_native and not loaded:
                observations["losses"].append({"time": sample["time"], "kind": f"expected-{variant}-disappeared"})
            seen_registration |= present
            seen_native |= loaded
            observations["samples"].append(sample)
            managed = self.observe_managed_slots(sample["native"], {"targetPresent": present})
            require(not managed["concurrentRemoval"] and not managed["receiptChangedDuringSample"],
                    "Managed artifacts changed during completed-command settlement")
            observations.setdefault("managedNodesAtReturn", managed["nodes"])
            require(managed["nodes"] == observations["managedNodesAtReturn"],
                    "Managed app/retired artifact changed after installer return")
            self.save()
        observations["status"] = "loss-observed" if observations["losses"] else "observed-no-loss-in-15s"
        self.save()
        try:
            observations["logs"] = self.phase_native_logs(label, act_start)
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            observations["logs"] = {"status": "unavailable", "error": str(error)}
        self.save()
        require(not observations["losses"],
                f"Deferred {variant} registration/process loss after installer return; see {label}")

    def phase_native_logs(self, label, start=None):
        end = time.time()
        start = start if start is not None else self.report.get("activeInstaller", {}).get("started", end - 90)
        host = f"processID == {self.host['generation'][0]}" if self.host else "FALSEPREDICATE"
        predicate = (
            f'(({host}) AND (eventMessage CONTAINS[c] "extension process" OR '
            'eventMessage CONTAINS[c] "view service" OR eventMessage CONTAINS[c] "ViewBridge" OR '
            'eventMessage CONTAINS[c] "connection interrupted" OR eventMessage CONTAINS[c] "invalidated")) OR '
            '((subsystem BEGINSWITH[c] "com.apple.extension" OR subsystem BEGINSWITH[c] "com.apple.LaunchServices" OR '
            'process == "pkd" OR process == "lsd" OR process == "extensionkitservice") AND '
            '(eventMessage CONTAINS[c] "com.jdylanmc.CMUXMaestroPreview" OR '
            'eventMessage CONTAINS[c] "CMUX Maestro"))'
        )
        args = ["/usr/bin/log", "show", "--start", f"@{int(start) - 1}", "--end", f"@{int(end) + 1}",
                "--style", "ndjson", "--info", "--debug", "--predicate", predicate]
        try:
            result = subprocess.run(args, capture_output=True, timeout=15)
            stdout, stderr, code = result.stdout, result.stderr, result.returncode
        except subprocess.TimeoutExpired as error:
            stdout, stderr, code = error.stdout or b"", error.stderr or b"", None
        retained = stdout[-1_048_576:]
        if len(stdout) > len(retained):
            retained = retained.partition(b"\n")[2]
        if retained and not retained.endswith(b"\n"):
            retained = retained.rpartition(b"\n")[0]
            if retained:
                retained += b"\n"
        (self.evidence / f"{label}-log.ndjson").write_bytes(retained)
        (self.evidence / f"{label}-log.stderr").write_bytes(stderr[-65_536:])
        metadata = {"argv": args, "startEpoch": start, "endEpoch": end, "returncode": code,
                    "format": "ndjson", "stdoutBytes": len(stdout), "retainedBytes": len(retained),
                    "truncated": len(stdout) != len(retained) or len(stderr) > 65_536,
                    "retention": "newest complete lines only; truncation is not complete phase evidence"}
        (self.evidence / f"{label}-log-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        require(code == 0, "Phase-scoped native log command failed or timed out; bounded evidence retained")
        for line in retained.splitlines():
            if line.strip():
                require(isinstance(json.loads(line), dict), "Unexpected native log record")
        return metadata

    def diagnostic_recovery_eligible(self):
        report = self.report
        if (report["status"] != "failed" or report["currentScenario"] != "legacySibling"
                or report["error"] != "No unique, stable, dynamically verified C extension generation"
                or report["scenarioResults"]["sameVersionFreshDR"].get("status") != "pass"
                or report["diagnosticRecovery"]["status"] != "not-run"):
            return False
        starts = [e for e in report["events"] if e["kind"] == "legacy-sibling-setup-complete"]
        ends = [e for e in report["events"] if e["kind"] == "installer-end"]
        if not starts or not ends:
            return False
        end = ends[-1]
        if (end["label"] != "legacy-sibling-update" or end["operation"] != "update"
                or end["returncode"] != 0 or end["continuityError"] is not None):
            return False
        events = [e for e in report["events"] if e["time"] >= starts[-1]["time"]]
        registry = [e for e in events if e["kind"] == "native-registration"]
        absent = next((e["time"] for e in registry if not e["targetPresent"] and len(e["records"]) == 2), None)
        native = [e for e in events if e["kind"] == "native-processes"]
        old = report["legacySiblingBaseline"]["loadedStableB"]
        return (not any(e["kind"] == "continuity-failure" for e in events)
                and absent is not None and any(e["time"] > absent and e["targetPresent"]
                                               and len(e["records"]) == 3 for e in registry)
                and any(not e["extensions"] for e in native)
                and all(all(all(process[k] == old[k] for k in ("generation", "cdhash", "path"))
                                for process in e["extensions"]) for e in native))

    def diagnostic_recovery(self):
        if not self.diagnostic_recovery_eligible():
            self.report["diagnosticRecovery"] = {
                "status": "not-eligible", "changesAcceptance": False,
                "reason": "Requires successful sibling installer, observed 2->3 transition, old exit/no new native, and no other failure",
            }
            self.save()
            return
        original_end = time.time()
        self.report["originalAcceptanceEnded"] = original_end
        with (self.evidence / "original-failure-result.json").open("x") as output:
            json.dump(self.report, output, indent=2)
        recovery = {"status": "preflight", "changesAcceptance": False, "started": original_end,
                    "removedRegistrations": []}
        self.report["diagnosticRecovery"] = recovery
        try:
            self.diagnostics("original-failure")
            require(not self.command_incomplete and self.child is None
                    and self.tree_snapshot_count == 4, "Incomplete command or unexpected snapshot phase; rescue refused")
            expected = {self.work / "legacy-siblings" / name /
                        ".build/adhoc/Build/Products/Debug/CMUX Maestro Preview.app"
                        for name in ("hardening", "visual49")}
            require(set(self.sibling_apps) == expected and len(self.sibling_records) == 2,
                    "Rescue accepts only the two exact run-created sibling fixtures")
            require(self.sample() == [], "A native generation is now live; rescue refused")
            old = self.report["legacySiblingBaseline"]["loadedStableB"]
            require(self.ops.process_generation(old["generation"][0], os.getuid()) != tuple(old["generation"]),
                    "Old B generation remains live; rescue refused")
            require(self.tree() == self.baseline["tree"], "Original failed-state terminal continuity changed")
            self.verify_sibling_files()
            state = self.registry_sample()
            require(state["targetPresent"] and len(state["records"]) == 3
                    and all(r["election"] == "+" for r in state["records"]),
                    "Stuck-state exact elected catalog changed")
            before = self.integration_state("before-diagnostic-recovery", self.candidates["C"])
            installer = self.preview.Installer(self.home, self.destination)
            with installer.locked():
                require(not installer.receipt["transaction"] and not installer.receipt["integration"]
                        and not installer.receipt["garbage"] and installer.receipt["current"],
                        "Pending journal or missing installed C; rescue refused")
                installer.check_stable()
                require(self.preview.digest(self.destination) == self.preview.digest(self.candidates["C"]),
                        "Installed app is not the verified candidate C")
                protected = {str(app): {"sha256": self.preview.digest(app), "node": self.preview.directory_identity(app)}
                             for app in installer.protected_apps()}
                installer.ops.assert_idle(*installer.protected_apps(), *expected)
                require(self.registry_sample() == state and self.sample() == [], "Stuck state changed before rescue")
                recovery["status"] = "retiring-exact-sibling-registrations"
                recovery["beforeCatalog"] = state
                recovery["protectedApps"] = protected
                self.save()
                for app in sorted(expected):
                    self.verify_sibling_files()
                    self.registry_sample()
                    installer.ops.assert_idle(app)
                    try:
                        installer.ops.unregister(app)
                    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError):
                        self.command_incomplete = True
                        marker = self.preview.command_worker.read_marker(installer.ops.install_lock_fd)
                        self.command_incomplete = marker is not None and marker["state"] != "finished"
                        raise
                    self.sibling_records.pop(str(app / self.preview.EXTENSION))
                    recovery["removedRegistrations"].append(str(app))
                    self.event("diagnostic-sibling-registration-retired", app=str(app), filesPreserved=True)
            state = self.registry_sample()
            require(state["targetPresent"] and len(state["records"]) == 1,
                    "Exact sibling registrations did not remain absent; no retry or filesystem workaround")
            recovery["status"] = "prepare-update"
            self.save()
            self.installer("prepare-update", monitored=True, label="diagnostic-prepare-update")
            require(self.registry_sample()["records"] == [], "Stable registration withdrawal not observed")
            recovery["status"] = "recover"
            self.save()
            self.installer("recover", monitored=True, label="diagnostic-recover")
            loaded = self.wait_loaded("C", previous=old)
            state = self.registry_sample()
            require(state["targetPresent"] and len(state["records"]) == 1
                    and state["records"][0]["election"] == "+", "Recovery lacks one elected stable registration")
            self.ops.verify_registration(self.destination)
            require(self.tree() == self.baseline["tree"], "Recovery changed original terminal state")
            self.verify_sibling_files()
            after = self.integration_state("after-diagnostic-recovery", self.candidates["C"], compare_bytes=before)
            require(after["resources"] == before["resources"], "Registration-only rescue replaced integration resources")
            require(all(self.preview.digest(Path(app)) == identity["sha256"]
                        and self.preview.directory_identity(Path(app)) == identity["node"]
                        for app, identity in protected.items()), "Registration-only rescue changed app/backup files")
            _, raw = self.run(["/usr/bin/defaults", "export", DOMAIN, "-"])
            require(all(plistlib.loads(raw).get(k) == v for k, v in SETUP_DEFAULTS.items()),
                    "Host selection/config changed during diagnostic recovery")
            self.sample()
            recovery.update(status="pass", loadedC=loaded, catalog=state,
                            filesAndIntegrationUnchanged=True, hostWorkerTreeFocusUnchanged=True)
            self.diagnostics("after-diagnostic-recovery")
        except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
            recovery.update(status="failed-or-unavailable", error=str(error))
            (self.evidence / "diagnostic-recovery-failure.txt").write_text(traceback.format_exc())
        finally:
            recovery["ended"] = time.time()
            self.save()

    def diagnostics(self, label, *, request_snapshot=False):
        data = {"time": time.time(), "host": self.host,
                "candidateExtensionHashes": {k: sorted(v) for k, v in self.hashes.items()},
                "externalIdentityObservation": self.report.get("externalIdentityObservation")}
        data["legacySiblings"] = {
            "files": {str(app): identity for app, identity in self.sibling_apps.items()},
            "expectedEligibleRecords": self.sibling_records,
        }
        path = self.evidence / f"diagnostics-{label}.json"
        if not self.fixture_profile_verified:
            data["status"] = "not collected: clean fixture profile was not verified"
            path.write_text(json.dumps(data, indent=2) + "\n")
            return

        def collect(name, action):
            try:
                data[name] = {"status": "captured", "value": action()}
            except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as error:
                data[name] = {"status": "unavailable", "error": str(error)}
            path.write_text(json.dumps(data, indent=2) + "\n")

        def processes():
            rows = self.processes()
            descendants = {self.host["generation"][0]} if self.host else set()
            for _ in range(128):
                added = {r["generation"][0] for r in rows if r["ppid"] in descendants}
                if added <= descendants:
                    break
                descendants |= added
            hashes = set().union(*self.hashes.values()) if self.hashes else set()
            return [r for r in rows if r["cdhash"] in hashes or r["generation"][0] in descendants]

        collect("kernelVerifiedNativeHostAndTerminalProcesses", processes)
        collect("fixtureWorkerRawKernelAndOldFilterEvidence", self.worker_diagnostics)
        collect("verifiedFixtureWorkerPidOwnerStartPathAndKernelTTY", self.worker_identity)
        collect("preservedSiblingFiles", self.verify_sibling_files)

        def process_hints():
            result = subprocess.run(
                ["/bin/ps", "-ax", "-o", "pid=", "-o", "uid=", "-o", "ppid=", "-o", "comm="],
                capture_output=True, text=True, check=True, timeout=10)
            hints = []
            for line in result.stdout.splitlines():
                pid, uid, parent, executable = line.split(None, 3)
                if int(uid) == os.getuid() and "CMUX Maestro" in executable:
                    hints.append({"pid": int(pid), "uid": int(uid), "ppid": int(parent),
                                  "displayedExecutable": executable,
                                  "kernelIdentity": self.process(int(pid))})
            return {"notLoadedProof": True, "hints": hints, "stderr": result.stderr[:4096]}

        collect("diagnosticOnlyProcessHintsIncludingUnverifiableIdentities", process_hints)
        for name in ("snapshot-worker.pid", "snapshot-worker.exit"):
            collect(name, lambda name=name: (self.evidence / name).read_text()[:4096]
                    if (self.evidence / name).exists() else "not present")
        collect("observerTail", lambda: [
            json.loads(line) for line in (self.evidence / "observer.jsonl").read_bytes().split(b"\n")[:-1]
        ][-12:])
        collect("externalIdentityEvents", lambda: [
            row for line in (self.evidence / "observer.jsonl").read_bytes().split(b"\n")[:-1]
            if (row := json.loads(line))["kind"] in ("observer-context", "identities", "observer-error")
        ][-16:])
        if self.copilot_real and self.copilot_real.exists():
            collect("officialProviderMetadataNoSessions", lambda: self.provider_rpc([
                ("status.get", {}), ("hooks.discover", {}), ("plugins.list", {})]))
            checkpoint = self.home / "Library/Application Support/CMUXMaestroPreview/Orchestration/install-transaction.json"
            if checkpoint.is_file():
                collect("integrationCheckpointRetained", lambda: {
                    "path": str(checkpoint), "bytes": checkpoint.stat().st_size, "sha256": sha256(checkpoint)})
        if (request_snapshot and self.host and self.tree_snapshot_count < 7
                and (self.evidence / "snapshot-worker.pid").exists()
                and not (self.evidence / "snapshot-worker.exit").exists()):
            collect("diagnosticOnlyTerminalSnapshot", lambda: json.loads(self.terminal_tree_snapshot()))
        def command(name, argv):
            try:
                result = subprocess.run(argv, capture_output=True, timeout=15)
            except subprocess.TimeoutExpired as error:
                (self.evidence / f"{label}-{name}.stdout").write_bytes((error.stdout or b"")[:1_048_576])
                (self.evidence / f"{label}-{name}.stderr").write_bytes((error.stderr or b"")[:65_536])
                raise
            (self.evidence / f"{label}-{name}.stdout").write_bytes(result.stdout[:1_048_576])
            (self.evidence / f"{label}-{name}.stderr").write_bytes(result.stderr[:65_536])
            require(result.returncode == 0, f"Diagnostic command exited {result.returncode}")
            return {"argv": argv, "stdoutBytes": len(result.stdout), "stderrBytes": len(result.stderr),
                    "truncated": len(result.stdout) > 1_048_576 or len(result.stderr) > 65_536}

        collect("exactPluginElectionAndRegistration", lambda: command(
            "pluginkit", ["/usr/bin/pluginkit", "-m", "-A", "-D", "-vv", "-i", EXT_ID]))
        collect("publicPointEligibleInstancesNotHostSpecific", lambda: command(
            "eligible-pluginkit", ["/usr/bin/pluginkit", "-m", "-A", "-D", "-vv", "-i", EXT_ID, "-p", POINT_ID]))
        collect("stockDefaults", lambda: command(
            "defaults", ["/usr/bin/defaults", "export", DOMAIN, "-"]))
        collect("scopedStockExtensionKitLogs", lambda: self.phase_native_logs(label))
        if self.host and self.process(self.host["generation"][0]) == self.host:
            collect("stockWindowMetadata", lambda: command(
                "stock-ui", [str(self.helper), "inspect", str(self.host["generation"][0]), str(self.stock)]))

            def screenshots():
                ui = json.loads((self.evidence / f"{label}-stock-ui.stdout").read_text())
                require(ui["pid"] == self.host["generation"][0] and ui["bundlePath"] == str(self.stock),
                        "UI metadata is not the exact owned stock host")
                windows = [w for w in ui["windows"] if w["onscreen"] and w["layer"] == 0 and w["id"] > 0]
                require(windows, "No visible owned stock window available for capture")
                captured = []
                for window in windows[:2]:
                    image = self.evidence / f"{label}-window-{window['id']}.png"
                    command(f"capture-{window['id']}",
                            ["/usr/sbin/screencapture", "-x", "-l", str(window["id"]), str(image)])
                    require(image.is_file() and image.stat().st_size > 0, "Window capture unavailable")
                    captured.append(str(image))
                return captured

            collect("stockWindowScreenshotsNoPermissionPromptOrFocusChange", screenshots)
        self.event("diagnostics", label=label, path=str(path))

    def cleanup(self):
        cleanup_worker = self.worker

        def attempt(label, action):
            try:
                action()
                self.report["cleanup"].append({"action": label, "status": "pass"})
            except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
                self.report["cleanup"].append({"action": label, "status": "failed", "error": str(error)})
            self.save()

        if self.command_incomplete or (self.child is not None and self.child.poll() is None):
            self.report["cleanup"].append({
                "status": "failed", "action": "retain after incomplete command/installer",
                "pid": self.child.pid if self.child else None, "reason": "Runner disposal required",
            })
        else:
            if self.copilot_real and self.copilot_real.exists() and self.integration_states:
                def retire_provider():
                    receipt = json.loads((self.home / "Applications" / self.preview.STATE_NAME / "receipt.json").read_text())
                    require(receipt["transaction"] is None and receipt["integration"] is None,
                            "Pending combined transaction retained; provider cleanup must not mask it")
                    _, plugins = self.provider_rpc([("status.get", {}), ("plugins.list", {})])
                    own = [p for p in plugins["plugins"] if p.get("name") == "cmux-maestro-native"]
                    known = {s["provider"]["directSourceId"] for s in self.integration_states.values()}
                    require(len(own) == 1 and own[0].get("directSourceId") in known,
                            "Cleanup refuses unknown provider identity")
                    self.provider_rpc([("status.get", {}), ("plugins.uninstall", {
                        "name": "cmux-maestro-native", "directSourceId": own[0]["directSourceId"]})])
                    _, after = self.provider_rpc([("status.get", {}), ("plugins.list", {})])
                    require(not any(p.get("name") == "cmux-maestro-native" for p in after["plugins"]),
                            "Owned provider plugin still registered")
                attempt("retire exact real provider identity AFTER acceptance", retire_provider)
            if self.terminal_config_contents is not None:
                def stop_snapshots():
                    nonlocal cleanup_worker
                    if cleanup_worker is None and (self.evidence / "snapshot-worker.json").exists():
                        cleanup_worker = self.worker_identity()
                        self.event("cleanup-worker-identity", identity=cleanup_worker)
                    (self.evidence / "snapshot-stop").touch(exist_ok=False)
                    deadline = time.monotonic() + 15
                    while ((self.evidence / "snapshot-worker.pid").exists()
                           and not (self.evidence / "snapshot-worker.parked").exists()
                           and not (self.evidence / "snapshot-worker.exit").exists()):
                        require(time.monotonic() < deadline,
                                "Read-only snapshot command has not parked; no process signalled")
                        time.sleep(0.25)
                attempt("park initial terminal observation AFTER acceptance without spawning a replacement", stop_snapshots)
            if self.host_launch_requested and self.host is None:
                def recover_host_identity():
                    hosts = [r for r in self.processes() if r["cdhash"] in self.host_hashes
                             and r["path"] and Path(r["path"]).is_relative_to(self.stock)]
                    require(len(hosts) <= 1, "Ambiguous stock host identity; no process signalled")
                    if hosts:
                        self.host = {k: hosts[0][k] for k in ("generation", "cdhash", "path")}
                attempt("identify only run-launched stock host for cleanup", recover_host_identity)
            if self.host and self.process(self.host["generation"][0]) == self.host:
                def quit_host():
                    self.run([self.helper, "quit", self.host["generation"][0], self.stock], timeout=15)
                    deadline = time.monotonic() + 30
                    while self.ops.process_generation(self.host["generation"][0], os.getuid()) == tuple(self.host["generation"]):
                        require(time.monotonic() < deadline, "Normal quit not completed; no force termination")
                        time.sleep(0.5)
                attempt("normal exact-host quit AFTER acceptance (never evidence of reload)", quit_host)
            if self.terminal_config_contents is not None:
                def finish_snapshots():
                    require(not self.host or self.ops.process_generation(
                        self.host["generation"][0], os.getuid()) != tuple(self.host["generation"]),
                        "Host still live; keep the original terminal parked for VM disposal")
                    (self.evidence / "snapshot-exit").touch(exist_ok=False)
                    deadline = time.monotonic() + 15
                    while ((self.evidence / "snapshot-worker.pid").exists()
                           and not (self.evidence / "snapshot-worker.exit").exists()):
                        if cleanup_worker and self.ops.process_generation(
                            cleanup_worker["pid"], os.getuid()
                        ) != tuple(cleanup_worker["generation"]):
                            break
                        require(time.monotonic() < deadline, "Snapshot worker exit not observed")
                        time.sleep(0.25)
                attempt("allow snapshot worker exit only after stock host exit", finish_snapshots)
            if self.apps_owned:
                def unregister_owned():
                    installer = self.preview.Installer(self.home, self.destination)
                    with installer.locked():
                        require(not installer.receipt["transaction"] and not installer.receipt["garbage"]
                                and not installer.receipt["integration"],
                                "Pending combined journal retained; native cleanup must not mask it")
                        installer.check_stable()
                        self.verify_sibling_files()
                        apps = installer.protected_apps() + self.apps_owned
                        for app in dict.fromkeys(apps):
                            if app.exists():
                                self.preview.safe_tree(app)
                                installer.ops.unregister(app)
                    _, raw = self.run(["/usr/bin/pluginkit", "-m", "-A", "-D", "-vv", "-i", EXT_ID])
                    require(not self.preview.metadata.registration_records(raw.decode(), allow_empty=True)
                            and not self.ops.app_paths(), "Native registrations remain after cleanup")
                    deadline = time.monotonic() + 30
                    while any(r["cdhash"] in set().union(*self.hashes.values()) for r in self.processes()):
                        require(time.monotonic() < deadline, "Native fixture still live; no extension signalled")
                        time.sleep(0.5)
                attempt("unregister exact receipt-owned slots and run-created sources; verify absence",
                        unregister_owned)
            if self.stock_node is not None and self.stock.exists():
                def unregister_stock():
                    node = self.stock.lstat()
                    require((node.st_dev, node.st_ino, node.st_uid) == self.stock_node
                            and node.st_uid == os.getuid() and stat.S_ISDIR(node.st_mode),
                            "Installed stock bundle ownership changed; do not touch it")
                    self.run([self.preview.LSREGISTER, "-u", self.stock])
                attempt("unregister exact run-created /Applications/cmux.app", unregister_stock)
            if self.defaults_owned:
                def remove_defaults():
                    require(not self.host or self.ops.process_generation(
                        self.host["generation"][0], os.getuid()) != tuple(self.host["generation"]),
                        "Host remains live; defaults retained for runner disposal")
                    self.run(["/usr/bin/defaults", "delete", DOMAIN])
                    code, raw = self.run(["/usr/bin/defaults", "export", DOMAIN, "-"], check=False)
                    require(code != 0 or not plistlib.loads(raw), "Run-created defaults remain")
                attempt("remove only run-created CMUX defaults domain after host exit", remove_defaults)
            if self.terminal_config_contents is not None:
                def remove_terminal_config():
                    require(not self.host or self.ops.process_generation(
                        self.host["generation"][0], os.getuid()) != tuple(self.host["generation"]),
                        "Host remains live; initial terminal config retained for runner disposal")
                    self.preview.safe_path(self.terminal_config, owner=True)
                    require(self.terminal_config.read_text() == self.terminal_config_contents,
                            "Initial terminal config changed; retain instead of deleting")
                    self.terminal_config.unlink()
                    self.terminal_config.parent.rmdir()
                attempt("remove exact run-created initial terminal config", remove_terminal_config)
            if self.work_owned and self.mount.is_mount():
                attempt("detach exact read-only DMG", lambda: self.run(["/usr/bin/hdiutil", "detach", self.mount]))
        if self.observer and self.observer.poll() is None:
            def stop_observer():
                self.observer.terminate()
                self.observer.wait(timeout=10)
            attempt("stop exact owned read-only observer", stop_observer)
        if (self.work_owned and self.observer_app.exists() and not self.command_incomplete
                and (self.observer is None or self.observer.poll() is not None)):
            attempt("unregister exact run-created observer app",
                    lambda: self.run([self.preview.LSREGISTER, "-u", self.observer_app]))
        receipt = self.home / "Applications" / self.preview.STATE_NAME / "receipt.json"
        if self.apps_owned and receipt.is_file():
            (self.evidence / "final-receipt.json").write_bytes(receipt.read_bytes())
        self.report["retainedForRunnerDisposal"] = [
            str(self.work), str(self.source), str(self.destination),
            str(self.home / "Applications" / self.preview.STATE_NAME),
            str(self.home / ".copilot"),
            str(self.home / "Library/Application Support/CMUXMaestroPreview"),
        ] + ([str(self.stock)] if self.stock_node is not None else [])
        self.report["cleanupPolicy"] = (
            "No recursive deletion, process-name kills, extension signals or forced host termination. "
            "Run-created disk fixtures and synthetic profile state are disposed with the hosted VM."
        )
        self.save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hosted-only", action="store_true", required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    guard = (sys.platform == "darwin" and os.getuid() != 0 and os.geteuid() == os.getuid() and
             os.environ.get("GITHUB_ACTIONS") == "true" and
             os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted" and
             os.environ.get("RUNNER_OS") == "macOS" and home == Path("/Users/runner") and
             os.environ.get("GITHUB_RUN_ID", "").isdigit() and
             Path(os.environ.get("GITHUB_WORKSPACE", "/")).resolve() == ROOT)
    if not guard:
        print("UNAVAILABLE: clean GitHub-hosted macOS runner required; no runtime effects.", file=sys.stderr)
        return 2
    temporary = Path(os.environ["RUNNER_TEMP"]).resolve()
    evidence = args.evidence.absolute()
    require(evidence == temporary / "stock-host-update-evidence" and not evidence.is_symlink(),
            "Evidence must be the exact runner-temp artifact directory")
    evidence.mkdir(mode=0o700, exist_ok=True)
    probe = Probe(evidence)
    probe.save()
    def deadline(_signal, _frame):
        raise RuntimeError("Overall 2100-second probe bound exceeded")
    signal.signal(signal.SIGALRM, deadline)
    signal.alarm(2100)
    try:
        probe.setup()
        probe.identical_repeat()
        replacement = probe.act("update", probe.initial, "B", "--source", probe.candidates["B"],
                                "--copilot-executable", probe.copilot)
        probe.integration_state("successful-update", probe.candidates["B"])
        probe.retention_state("successful-update", "B", "A")
        restored = probe.failed_update_compensation(replacement)
        current = probe.reclaim_update(restored)
        probe.identical_repeat("D", current, label="identical-repeat-D")
        probe.report["scenarioResults"]["boundedRetention"] = {"status": "pass", "siblingCount": 0}
        probe.report["currentScenario"] = "siblingRefusal"
        probe.report["scenarioResults"]["siblingRefusal"] = {"status": "setup"}
        probe.save()
        probe.setup_legacy_siblings(current, "D")
        probe.report["scenarioResults"]["siblingRefusal"] = {"status": "preflight-test"}
        probe.save()
        probe.sibling_preflight_refusal(current)
        probe.report["scenarioResults"]["siblingRefusal"] = {"status": "pass", "siblingCount": 2}
        probe.sample()
        probe.report["status"] = "pass"
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        probe.report["status"] = "unavailable" if probe.report["phase"] == "setup" else "failed"
        probe.report["error"] = str(error)
        probe.report["scenarioResults"][probe.report["currentScenario"]] = {
            "status": probe.report["status"], "error": str(error),
            "approval": "No further approval attempted; inspect captured stock UI/logs for approval-required/refusal evidence.",
        }
        (evidence / "failure.txt").write_text(traceback.format_exc())
    finally:
        signal.alarm(0)
        probe.report["acceptanceEnded"] = time.time()
        probe.save()
        if probe.report["status"] != "pass":
            probe.diagnostics("before-cleanup", request_snapshot=True)
        probe.cleanup()
        if any(row["status"] == "failed" for row in probe.report["cleanup"]):
            if probe.report["status"] == "pass":
                probe.report["status"] = "failed"
            probe.report["cleanupIncomplete"] = True
            probe.diagnostics("after-cleanup")
        probe.save()
    print(json.dumps({"status": probe.report["status"], "evidence": str(evidence)}))
    return {"pass": 0, "failed": 1, "unavailable": 2}[probe.report["status"]]


if __name__ == "__main__":
    sys.exit(main())
