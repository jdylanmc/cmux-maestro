#!/usr/bin/env python3
"""C7 diagnostic, exclusively on a clean GitHub-hosted macOS runner.

Run with --hosted-only --evidence "$RUNNER_TEMP/stock-host-update-evidence".
Setup seeds a version-bound *preexisting* enabled native selection, not onboarding.
The acts are the frozen native-only local-preview update and rollback commands.
No containing-app launch, Copilot installation, hooks, input, or production claim.
Exit 0 requires both loaded generations and restoration; 1 is failure, 2 unavailable.
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
import pwd
import re
import shlex
import signal
import stat
import subprocess
import sys
import time
import traceback
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
BASE = "6efa5427cfca4f0dfb5af927ec29ba5962e2cd88"
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
        self.baseline = None
        self.worker = None
        self.hashes = {}
        self.last_sample = None
        self.last_registration = None
        self.sequence = 0
        self.report = {
            "status": "unavailable", "phase": "setup", "base": BASE,
            "stock": {"version": "0.64.25", "build": "106", "revision": STOCK_REVISION,
                      "url": DMG_URL, "bytes": 225832896, "sha256": DMG_SHA256},
            "scope": "native hosting only; neither combined installation nor hooks",
            "setupIsNotAcceptance": True,
            "observationContract": {
                "registration": "independent exact pluginkit catalog turnover, not loaded proof",
                "loaded": "mandatory old-process exit and new extension executable PID/UID/start/CDHash",
                "externalExtensionFoundation": "advisory separate-host context, not stock host visibility",
            },
            "checks": {}, "cleanup": [], "events": [],
        }

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

    def registry_sample(self):
        result = subprocess.run(
            ["/usr/bin/pluginkit", "-m", "-A", "-D", "-vv", "-i", EXT_ID],
            capture_output=True, text=True, timeout=5)
        valid = result.returncode == 0 and not result.stderr.strip() and len(result.stdout) <= 65_536
        if not valid:
            self.event("registration-observation-error", returncode=result.returncode,
                       stdout=result.stdout[:4096], stderr=result.stderr[:4096])
        require(valid, "Exact registration observation unavailable")
        records = self.preview.metadata.registration_records(result.stdout, allow_empty=True)
        require(all(r["id"] == EXT_ID for r in records), "Unexpected registration identifier")
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
        return state

    def sample(self):
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
        phases = ("baseline", "update", "rollback")
        require(self.tree_snapshot_count < len(phases), "Unexpected additional tree request")
        phase = phases[self.tree_snapshot_count]
        self.tree_snapshot_count += 1
        self.report["treeObservation"] = {
            "status": "unavailable", "phase": phase, "policy": "cmuxOnly",
            "transport": "three fixed reads from the test-owned initial terminal command",
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

    def installer(self, name, *arguments, monitored=False):
        args = [sys.executable, str(ROOT / "scripts/local-preview.py"), "--destination",
                str(self.destination), name, *map(str, arguments)]
        self.event("installer-start", argv=args)
        with (self.evidence / f"installer-{name}.log").open("wb") as out:
            self.child = subprocess.Popen(args, cwd=ROOT, stdin=subprocess.DEVNULL,
                                          stdout=out, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 420
            defect = None
            while self.child.poll() is None:
                if monitored and defect is None:
                    try:
                        self.sample()
                        self.registry_sample()
                    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
                        defect = str(error)
                        self.event("continuity-failure", error=defect)
                require(time.monotonic() < deadline,
                        "Installer exceeded 420s; retained without signalling, runner teardown required")
                time.sleep(0.5)
            code = self.child.returncode
            self.child = None
        self.event("installer-end", operation=name, returncode=code, continuityError=defect)
        require(code == 0 and defect is None, f"Native {name} failed; see installer-{name}.log")

    def registration(self):
        _, raw = self.run(["/usr/bin/pluginkit", "-m", "-A", "-D", "-vv", "-i", EXT_ID])
        self.preview.metadata.verify_registration_output(
            raw.decode(), self.destination / self.preview.EXTENSION)
        records = self.preview.metadata.registration_records(raw.decode())
        require(len(records) == 1, "Duplicate native extension registrations")

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
        context = self.work / "ui-approval-context.json"
        context.write_text(json.dumps({
            "runID": os.environ["GITHUB_RUN_ID"], "hostPID": self.host["generation"][0],
            "hostPath": str(self.stock), "extensionID": EXT_ID, "labels": sorted(labels),
            "terminalTitle": "/usr/bin/env", "evidence": str(self.evidence),
        }))
        project = ROOT / "scripts/stock-host-approval/StockHostApproval.xcodeproj"
        derived = self.work / "approval-build"
        xcode = ["/usr/bin/env", "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer",
                 "/usr/bin/xcodebuild"]
        code, _ = self.run([
            *xcode, "-project", project, "-scheme", "StockHostApproval", "-configuration", "Debug",
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
        # xcodebuild.xctestrun(5) documents external UI target paths and runner environment.
        target["UITargetAppPath"] = str(self.stock)
        target.setdefault("DependentProductPaths", []).append(str(self.stock))
        target.setdefault("EnvironmentVariables", {}).update({
            "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
            "GITHUB_RUN_ID": os.environ["GITHUB_RUN_ID"], "PROBE_APPROVAL_CONTEXT": str(context),
        })
        target["SystemAttachmentLifetime"] = "keepAlways"
        target["UserAttachmentLifetime"] = "keepAlways"
        configured = runs[0].with_name("StockHostApproval-configured.xctestrun")
        configured.write_bytes(plistlib.dumps(config))
        code, _ = self.run([
            *xcode, "test-without-building", "-xctestrun", configured, "-destination", "platform=macOS",
            "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES",
            "-maximum-test-execution-time-allowance", "90",
            "-only-testing:StockHostApprovalTests/StockHostApprovalTests/testApproveOwnedNativeFixture",
            "-resultBundlePath", self.evidence / "native-approval.xcresult",
        ], timeout=180, check=False)
        result_file = self.evidence / "approval-result.json"
        ui_result = json.loads(result_file.read_text()) if result_file.is_file() else None
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
        self.run([ROOT / "scripts/build-register.sh"], timeout=900)
        self.hashes["A"] = self.executable_hashes(self.source / self.preview.EXTENSION)
        candidate = self.work / "candidate-B.app"
        self.apps_owned.append(candidate)
        self.run(["/usr/bin/ditto", self.source, candidate])
        # A real signed Info.plist variant changes the executable's CodeDirectory,
        # not its permissions or product code. CFBundleVersion remains the checked build.
        for bundle in (candidate / self.preview.EXTENSION, candidate):
            info_path = bundle / "Contents/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info["CFBundleShortVersionString"] = "0.0.1142"
            info_path.write_bytes(plistlib.dumps(info))
            self.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
                      "--preserve-metadata=identifier,entitlements,requirements,flags,runtime", bundle])
        self.ops.verify(candidate, current=True)
        self.hashes["B"] = self.executable_hashes(candidate / self.preview.EXTENSION)
        require(self.hashes["A"].isdisjoint(self.hashes["B"]),
                "Fixture extension signatures are identical; reload would be unproven")
        self.candidate = candidate
        self.installer("install", "--source", self.source, "--retire-development-registration")
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
        self.report["checks"]["setup"] = "pass"
        self.report["phase"] = "acceptance"
        self.save()

    def act(self, operation, previous, variant, *arguments):
        self.registry_sample()
        start = time.time()
        require(self.process(previous["generation"][0]) == previous,
                "Expected old extension generation is not live at act start")
        self.installer(operation, *arguments, monitored=True)
        loaded = self.wait_loaded(variant, previous=previous)
        self.registration()
        self.registry_sample()
        require(self.tree() == self.baseline["tree"], "Window/workspace/pane/surface identity or selection changed")
        _, raw = self.run(["/usr/bin/defaults", "export", DOMAIN, "-"])
        current = plistlib.loads(raw)
        require(all(current.get(k) == v for k, v in SETUP_DEFAULTS.items()), "Selection/config changed during act")
        rows = [r for r in self.report["events"]
                if r["kind"] == "native-registration" and r["time"] >= start]
        missing = next((r["time"] for r in rows if not r["records"]), None)
        require(missing is not None and any(
            r["time"] > missing and r["targetPresent"] and len(r["records"]) == 1 for r in rows
        ), "No independently observed exact registration withdrawal and restoration")
        self.report["checks"][operation] = {
            "status": "pass", "old": previous, "new": loaded, "registrationDisappearance": missing,
            "hostAndShellGenerationsUnchanged": True, "treeUnchanged": True,
            "focusAndVisibleWindowsUnchanged": True,
        }
        self.save()
        self.diagnostics(f"after-{operation}")
        return loaded

    def diagnostics(self, label, *, request_snapshot=False):
        data = {"time": time.time(), "host": self.host,
                "candidateExtensionHashes": {k: sorted(v) for k, v in self.hashes.items()},
                "externalIdentityObservation": self.report.get("externalIdentityObservation")}
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
        if (request_snapshot and self.host and self.tree_snapshot_count == 0
                and (self.evidence / "snapshot-worker.pid").exists()
                and not (self.evidence / "snapshot-worker.exit").exists()):
            collect("diagnosticOnlyTerminalSnapshot", lambda: json.loads(self.terminal_tree_snapshot()))
        host = f"processID == {self.host['generation'][0]}" if self.host else "FALSEPREDICATE"
        predicate = (
            f'(({host}) AND (eventMessage CONTAINS[c] "extension" OR '
            'eventMessage CONTAINS[c] "quit" OR eventMessage CONTAINS[c] "error" OR '
            'eventMessage CONTAINS[c] "fail")) OR '
            '((subsystem BEGINSWITH[c] "com.apple.extension" OR process == "pkd" OR '
            'process == "extensionkitservice") AND '
            f'(eventMessage CONTAINS[c] "{EXT_ID}" OR eventMessage CONTAINS[c] "{POINT_ID}" OR '
            'eventMessage CONTAINS[c] "CMUX Maestro"))'
        )

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
        collect("stockDefaults", lambda: command(
            "defaults", ["/usr/bin/defaults", "export", DOMAIN, "-"]))
        collect("scopedStockExtensionKitLogs", lambda: command(
            "log", ["/usr/bin/log", "show", "--last", "5m", "--style", "json",
                    "--info", "--debug", "--predicate", predicate]))
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
                        apps = installer.protected_apps() + self.apps_owned
                        for key in ("transaction", "garbage"):
                            if installer.receipt[key]:
                                apps.append(installer.slot(installer.receipt[key]["slot"]))
                        for app in dict.fromkeys(apps):
                            if app.exists():
                                self.preview.safe_tree(app)
                                installer.ops.unregister(app)
                        require(not installer.receipt["transaction"] and not installer.receipt["garbage"],
                                "Installer journal still pending; retained for diagnosis, not repaired")
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
        replacement = probe.act("update", probe.initial, "B", "--source", probe.candidate)
        probe.act("rollback", replacement, "A")
        probe.sample()
        probe.report["status"] = "pass"
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        probe.report["status"] = "unavailable" if probe.report["phase"] == "setup" else "failed"
        probe.report["error"] = str(error)
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
