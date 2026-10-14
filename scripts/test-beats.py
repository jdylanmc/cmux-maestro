#!/usr/bin/env python3
"""Fast, deterministic tests for Beats: cron evaluation, local-time/DST rules, the shared
definition store, and the exact-self agent surface. No real clock, session or network."""
import fcntl
import json
import os
import runpy
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CONTROLLER = REPO / "scripts" / "cmux-maestro-orchestrator.py"
API = runpy.run_path(str(CONTROLLER))
OrchestrationError = API["OrchestrationError"]
parse_cron = API["parse_cron"]
cron_next_times = API["cron_next_times"]
store_mutate = API["beats_store_mutate"]

SESSION_A = str(uuid.uuid4())
SESSION_B = str(uuid.uuid4())


def local_epoch(year, month, day, hour, minute, dst):
    return time.mktime((year, month, day, hour, minute, 0, 0, 0, dst))


def beat(cron, session=SESSION_A, **overrides):
    value = {"id": str(uuid.uuid4()), "sessionId": session, "cron": cron, "prompt": "go", "enabled": True,
             "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z", "revision": 1}
    value.update(overrides)
    return value


class LocalTimeCase(unittest.TestCase):
    def setUp(self):
        self.saved = os.environ.get("TZ")
        os.environ["TZ"] = "America/New_York"
        time.tzset()

    def tearDown(self):
        if self.saved is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = self.saved
        time.tzset()


class CronTests(LocalTimeCase):
    def test_valid_and_normalized(self):
        self.assertEqual(parse_cron("  */15   9-17 * *  1-5 ").expression, "*/15 9-17 * * 1-5")
        self.assertEqual(parse_cron("0 0 * * 7").weekdays, frozenset({0}))
        self.assertEqual(parse_cron("0,30 8 1,15 * *").minutes, frozenset({0, 30}))
        self.assertEqual(parse_cron("10-20/5 * * * *").minutes, frozenset({10, 15, 20}))

    def test_rejects_invalid_expressions(self):
        for bad in ("", "* * * *", "* * * * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *",
                    "* * * * 8", "a * * * *", "@daily", "5/2 * * * *", "*/0 * * * *", "1-70 * * * *",
                    "5-1 * * * *", "0 0 31 2 *", "0 0 30 2 *", "* * * * MON", "1 2 3 4 5\n", "x" * 200):
            with self.assertRaises(OrchestrationError, msg=repr(bad)):
                parse_cron(bad)
        parse_cron("0 0 29 2 *")  # leap days are real dates

    def test_day_of_month_and_weekday_are_ored_when_both_restricted(self):
        spec = parse_cron("0 9 13 * 5")  # the 13th OR any Friday
        friday = time.localtime(local_epoch(2026, 10, 9, 9, 0, 1))
        thirteenth = time.localtime(local_epoch(2026, 10, 13, 9, 0, 1))  # a Tuesday
        other = time.localtime(local_epoch(2026, 10, 14, 9, 0, 1))
        self.assertTrue(spec.matches(friday) and spec.matches(thirteenth))
        self.assertFalse(spec.matches(other))
        self.assertTrue(parse_cron("0 9 * * 1-5").matches(friday))
        self.assertFalse(parse_cron("0 9 * * 6,0").matches(friday))

    def test_next_times_are_local_and_ordered(self):
        start = local_epoch(2026, 10, 10, 20, 0, 1)
        times = cron_next_times(parse_cron("30 9 * * 1-5"), start, count=3)
        self.assertEqual([time.strftime("%Y-%m-%d %H:%M", time.localtime(t)) for t in times],
                         ["2026-10-12 09:30", "2026-10-13 09:30", "2026-10-14 09:30"])


FIXTURES = REPO / "scripts" / "test-fixtures"


class SharedFixtureTests(unittest.TestCase):
    """The same fixtures are decoded by the Swift sidebar tests (SidebarBeatsTests)."""

    def test_cron_cases(self):
        cases = json.loads((FIXTURES / "beats-cron-cases.json").read_text())
        for expression, normalized in cases["valid"]:
            self.assertEqual(parse_cron(expression).expression, normalized, repr(expression))
        for expression in cases["invalid"]:
            with self.assertRaises(OrchestrationError, msg=repr(expression)):
                parse_cron(expression)

    def test_previews_match_copilots_recorded_next_runs(self):
        oracle = json.loads((FIXTURES / "beats-cron-cases.json").read_text())["copilotNextRuns"]
        saved = os.environ.get("TZ")
        os.environ["TZ"] = oracle["timeZone"]
        time.tzset()
        try:
            start = time.mktime(time.strptime(oracle["from"], "%Y-%m-%d %H:%M"))
            for case in oracle["cases"]:
                times = cron_next_times(parse_cron(case["cron"]), start, count=len(case["next"]))
                self.assertEqual([time.strftime("%Y-%m-%d %H:%M", time.localtime(t)) for t in times], case["next"],
                                 case["cron"])
        finally:
            if saved is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = saved
            time.tzset()

    def test_store_sample_is_valid_and_canonical(self):
        # The Swift sidebar encodes the same sample to the same bytes (SidebarBeatsTests).
        raw = (FIXTURES / "beats-store-sample.json").read_bytes()
        self.assertEqual(API["beats_encode"](API["beats_decode"](raw)), raw)
        self.assertIn("😀".encode(), raw)

    def test_store_contract_cases(self):
        cases = json.loads((FIXTURES / "beats-store-cases.json").read_text())
        for case in cases["valid"]:
            API["beats_decode"](case["raw"].encode())
        for case in cases["invalid"]:
            with self.assertRaises(OrchestrationError, msg=case["name"]):
                API["beats_decode"](case["raw"].encode())
        for case in cases["legacyEmpty"]:
            self.assertEqual(API["beats_decode"](case["raw"].encode()), {"version": 2, "beats": []}, case["name"])
        with self.assertRaises(OrchestrationError):
            API["beats_decode"](b"\xef\xbb\xbf" + cases["valid"][0]["raw"].encode())
        # UTF-8 only; the Swift suite refuses the same bytes.
        legacy = '{"version":1,"beats":[]}'
        for raw in [legacy.encode(codec) for codec in ("utf-16-le", "utf-16-be", "utf-16", "utf-32-le", "utf-32")] + [
                b'{\x00"\x001\x001\\\x00\\"\x00:\x00[\x00]\x00}\x00', b'{"version":1,"beats":["\xff"]}']:
            with self.assertRaises(OrchestrationError, msg=repr(raw)):
                API["beats_decode"](raw)

    def test_duplicate_keys_are_refused(self):
        # Swift's JSONSerialization keeps the first duplicate and Python the last; refuse instead.
        with self.assertRaises(OrchestrationError):
            API["beats_decode"](b'{"version":1,"version":1,"beats":[]}')

    def test_writers_refuse_prompts_readers_refuse(self):
        for prompt in ("\u200b", " \u200b\n", "\ufeff", "\ufeffHello", "a\ufeffb"):
            with self.assertRaises(OrchestrationError, msg=repr(prompt)):
                API["validate_beat_prompt"](prompt)
        API["validate_beat_prompt"]("a\u200bb")
        API["validate_beat_prompt"]("see \\ufeff here")


class PreviewDaylightSavingTests(LocalTimeCase):
    """cron_next_times only previews; Copilot's scheduler decides when a Beat fires."""

    def test_nonexistent_local_minute_is_skipped(self):
        # 2026-03-08 02:00-02:59 does not exist in New York.
        times = cron_next_times(parse_cron("30 2 * * *"), local_epoch(2026, 3, 7, 12, 0, 0), count=2)
        self.assertEqual([time.strftime("%m-%d %H:%M", time.localtime(t)) for t in times], ["03-09 02:30", "03-10 02:30"])

    def test_repeated_local_minute_appears_once(self):
        # 2026-11-01 01:00-01:59 happens twice (EDT then EST).
        times = cron_next_times(parse_cron("30 1 * * *"), local_epoch(2026, 10, 31, 12, 0, 1), count=2)
        self.assertEqual([time.strftime("%m-%d %H:%M", time.localtime(t)) for t in times], ["11-01 01:30", "11-02 01:30"])


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name) / "beats"

    def tearDown(self):
        self.directory.cleanup()

    def test_missing_store_starts_empty_and_is_private(self):
        self.assertEqual(store_mutate(lambda state: state["beats"], root=self.root), [])
        self.assertEqual((self.root / "beats.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)

    def test_concurrent_writers_lose_nothing(self):
        def add(_):
            store_mutate(lambda state: state["beats"].append(beat("0 9 * * *")), root=self.root)
        threads = [threading.Thread(target=add, args=(index,)) for index in range(24)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(len(store_mutate(lambda state: state["beats"], root=self.root)), 24)

    def test_malformed_or_future_store_is_refused_and_untouched(self):
        self.root.mkdir(mode=0o700)
        path = self.root / "beats.json"
        for content in ('{"version": 3, "beats": []}', '{"version": 2}', "not json",
                        json.dumps({"version": 2, "beats": [{"id": "x"}]})):
            path.write_text(content)
            path.chmod(0o600)
            with self.assertRaises(OrchestrationError):
                store_mutate(lambda state: None, root=self.root)
            self.assertEqual(path.read_text(), content)

    def test_symlinked_store_is_refused(self):
        self.root.mkdir(mode=0o700)
        target = Path(self.directory.name) / "elsewhere.json"
        target.write_text('{"version":1,"beats":[]}')
        (self.root / "beats.json").symlink_to(target)
        with self.assertRaises((OrchestrationError, OSError)):
            store_mutate(lambda state: None, root=self.root)

    def test_shared_store_or_directory_is_refused(self):
        self.root.mkdir(mode=0o700)
        path = self.root / "beats.json"
        path.write_text('{"version":1,"beats":[]}')
        path.chmod(0o640)
        for read in (lambda: store_mutate(lambda state: None, root=self.root),
                     lambda: API["beats_store_snapshot"](root=self.root)):
            with self.assertRaises(OrchestrationError):
                read()
        path.chmod(0o600)
        self.root.chmod(0o750)
        with self.assertRaises(OrchestrationError):
            API["beats_store_snapshot"](root=self.root)
        self.root.chmod(0o700)
        self.assertEqual(API["beats_store_snapshot"](root=self.root)["beats"], [])

    def test_snapshot_is_read_only(self):
        self.assertEqual(API["beats_store_snapshot"](root=self.root)["beats"], [])
        self.assertFalse(self.root.exists())
        store_mutate(lambda state: state["beats"].append(beat("0 9 * * *")), root=self.root)
        before = os.stat(self.root / "beats.json")
        self.assertEqual(len(API["beats_store_snapshot"](root=self.root)["beats"]), 1)
        after = os.stat(self.root / "beats.json")
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_snapshot_leaves_store_bytes_untouched_and_creates_nothing(self):
        self.root.mkdir(mode=0o700)
        self.assertEqual(API["beats_store_snapshot"](root=self.root)["beats"], [])
        self.assertEqual(sorted(os.listdir(self.root)), [])
        store_mutate(lambda state: state["beats"].append(beat("0 9 * * *")), root=self.root)
        path = self.root / "beats.json"
        before, content = os.stat(path), path.read_bytes()
        API["beats_store_snapshot"](root=self.root)
        after = os.stat(path)
        self.assertEqual(path.read_bytes(), content)
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def hold_lock(self, operation):
        store_mutate(lambda state: state["beats"].append(beat("0 9 * * *")), root=self.root)
        descriptor = os.open(self.root / ".lock", os.O_RDONLY)
        fcntl.flock(descriptor, operation)
        self.addCleanup(os.close, descriptor)
        return descriptor

    def snapshot_in_background(self):
        results = []
        thread = threading.Thread(target=lambda: results.append(API["beats_store_snapshot"](root=self.root)))
        thread.start()
        return thread, results

    def test_snapshot_coexists_with_another_reader(self):
        self.hold_lock(fcntl.LOCK_SH)
        thread, results = self.snapshot_in_background()
        thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(len(results[0]["beats"]), 1)

    def test_snapshot_waits_for_a_writer(self):
        descriptor = self.hold_lock(fcntl.LOCK_EX)
        thread, results = self.snapshot_in_background()
        thread.join(0.3)
        self.assertTrue(thread.is_alive())
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(len(results[0]["beats"]), 1)

    def test_snapshot_refuses_fifos_without_blocking(self):
        self.root.mkdir(mode=0o700)
        os.mkfifo(self.root / ".lock", 0o600)
        with self.assertRaises(OrchestrationError):
            API["beats_store_snapshot"](root=self.root)
        (self.root / ".lock").unlink()
        os.mkfifo(self.root / "beats.json", 0o600)
        with self.assertRaises(OrchestrationError):
            API["beats_store_snapshot"](root=self.root)

    def test_invalid_mutation_is_not_persisted(self):
        store_mutate(lambda state: state["beats"].append(beat("0 9 * * *")), root=self.root)
        before = (self.root / "beats.json").read_bytes()

        def corrupt(state):
            state["beats"][0]["cron"] = "bogus"
        with self.assertRaises(OrchestrationError):
            store_mutate(corrupt, root=self.root)
        self.assertEqual((self.root / "beats.json").read_bytes(), before)

    def test_size_limit_counts_utf8_bytes(self):
        # Escaped as \u00e9 this store would be about 1.6 MiB; as UTF-8 it is about 0.6 MiB.
        prompt = "é" * 1360

        def fill(state):
            state["beats"].extend(beat("0 9 * * *", session=str(uuid.uuid4()), prompt=prompt) for _ in range(200))
        store_mutate(fill, root=self.root)
        self.assertLess((self.root / "beats.json").stat().st_size, 1024 * 1024)
        self.assertEqual(len(API["beats_store_snapshot"](root=self.root)["beats"]), 200)
        self.assertEqual(len(store_mutate(lambda state: state["beats"], root=self.root)), 200)
        with self.assertRaises(OrchestrationError):
            API["beats_encode"]({"version": 1, "beats": [{"prompt": "x" * BYTES} for BYTES in (1024 * 1024,)]})


FAKE_HELPER = """#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:2] != ["prove"] or os.environ.get("FAKE_PROOF") == "deny":
    print(json.dumps({"ok": False}))
    sys.exit(2)
print(json.dumps({"ok": True, "sessionId": sys.argv[sys.argv.index("--session-id") + 1]}))
"""


class AgentSurfaceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        base = Path(self.directory.name).resolve()
        self.home = base / "home"
        self.root = self.home / "Library/Application Support/CMUXMaestroPreview/Beats"
        self.helper = base / "helper"
        self.helper.write_text(FAKE_HELPER)
        self.helper.chmod(0o700)
        # An installed controller finds its identity helper through private adjacent configuration.
        package = base / "package"
        package.mkdir()
        self.controller = package / CONTROLLER.name
        shutil.copyfile(CONTROLLER, self.controller)
        config = package / "identity-helper.json"
        config.write_text(json.dumps({"helper": str(self.helper)}))
        config.chmod(0o600)

    def tearDown(self):
        self.directory.cleanup()

    def run_beats(self, *arguments, session=SESSION_A, deny=False, own=True, controller=None, environment=None):
        environment = dict(os.environ, HOME=str(self.home), **(environment or {}))
        if deny:
            environment["FAKE_PROOF"] = "deny"
        command = [sys.executable, str(controller or self.controller), "beats", *arguments]
        if own:
            command += ["--self", "--session-id", session]
        process = subprocess.run(command, capture_output=True, text=True, env=environment, timeout=30)
        body = process.stdout or process.stderr
        return process.returncode, json.loads(body)

    def create(self, cron="0 9 * * 1-5", prompt="check the board", session=SESSION_A):
        code, value = self.run_beats("create", "--cron", cron, "--prompt", prompt, session=session)
        self.assertEqual(code, 0, value)
        return value["beat"]

    def test_create_list_edit_enable_disable_delete(self):
        created = self.create()
        self.assertTrue(created["enabled"])
        self.assertEqual(set(created), API["BEATS_FIELDS"])
        self.assertEqual(created["cron"], "0 9 * * 1-5")
        code, listed = self.run_beats("list")
        self.assertEqual([item["id"] for item in listed["beats"]], [created["id"]])
        code, edited = self.run_beats("edit", "--beat-id", created["id"], "--cron", "*/5  * * * *")
        self.assertEqual(edited["beat"]["cron"], "*/5 * * * *")
        self.assertEqual(edited["beat"]["revision"], 2)
        self.assertEqual(edited["beat"]["prompt"], "check the board")
        code, disabled = self.run_beats("disable", "--beat-id", created["id"])
        self.assertEqual(code, 0, disabled)
        self.assertFalse(disabled["beat"]["enabled"])
        code, enabled = self.run_beats("enable", "--beat-id", created["id"])
        self.assertEqual(code, 0, enabled)
        self.assertTrue(enabled["beat"]["enabled"])
        self.assertEqual(enabled["beat"]["revision"], 4)
        code, deleted = self.run_beats("delete", "--beat-id", created["id"])
        self.assertEqual(deleted["deleted"], created["id"])
        self.assertEqual(self.run_beats("list")[1]["beats"], [])

    def test_pause_and_resume_remain_aliases_for_disable_and_enable(self):
        created = self.create()
        code, paused = self.run_beats("pause", "--beat-id", created["id"])
        self.assertEqual(code, 0, paused)
        self.assertFalse(paused["beat"]["enabled"])
        code, resumed = self.run_beats("resume", "--beat-id", created["id"])
        self.assertEqual(code, 0, resumed)
        self.assertTrue(resumed["beat"]["enabled"])
        self.assertEqual(resumed["beat"]["revision"], 3)

    def test_help_documents_enable_and_disable_with_pause_and_resume_as_aliases(self):
        process = subprocess.run([sys.executable, str(self.controller), "beats", "--help"], capture_output=True,
                                 text=True, env=dict(os.environ, HOME=str(self.home)), timeout=30)
        self.assertEqual(process.returncode, 0, process.stderr)
        text = " ".join(process.stdout.split())
        self.assertIn("{list,create,edit,enable,disable,delete,cron-check}", text)
        self.assertIn("(pause and resume are aliases)", text)

    def test_agent_cannot_touch_another_sessions_beat(self):
        created = self.create(session=SESSION_A)
        for action in ("edit", "enable", "disable", "pause", "resume", "delete"):
            extra = ("--cron", "1 1 * * *") if action == "edit" else ()
            code, value = self.run_beats(action, "--beat-id", created["id"], *extra, session=SESSION_B)
            self.assertNotEqual(code, 0, action)
            self.assertIn("No such Beat", value["error"])
        self.assertEqual(self.run_beats("list", session=SESSION_B)[1]["beats"], [])
        self.assertEqual(len(self.run_beats("list", session=SESSION_A)[1]["beats"]), 1)

    def test_retired_testing_variables_cannot_substitute_the_identity_helper(self):
        code, value = self.run_beats(
            "create", "--cron", "0 9 * * *", "--prompt", "x", controller=CONTROLLER,
            environment={"CMUX_MAESTRO_TESTING": "1", "CMUX_MAESTRO_IDENTITY_HELPER": str(self.helper),
                         "CMUX_MAESTRO_BEATS_ROOT": str(self.root)})
        self.assertNotEqual(code, 0)
        self.assertIn("Refresh Maestro integration", value["error"])
        self.assertFalse(self.root.exists())

    def test_failed_ownership_proof_changes_nothing(self):
        code, value = self.run_beats("create", "--cron", "0 9 * * *", "--prompt", "x", deny=True)
        self.assertNotEqual(code, 0)
        self.assertIn("could not prove ownership", value["error"])
        self.assertFalse((self.root / "beats.json").exists())

    def test_version_one_store_reads_empty_and_is_dropped_on_next_write(self):
        self.root.mkdir(mode=0o700, parents=True)
        path = self.root / "beats.json"
        path.write_text(json.dumps({"version": 1, "beats": [{"id": "legacy", "recoveryGate": True}]}))
        path.chmod(0o600)
        content = path.read_bytes()
        self.assertEqual(self.run_beats("list")[1]["beats"], [])
        self.assertEqual(path.read_bytes(), content)
        created = self.create()
        self.assertEqual([item["id"] for item in json.loads(path.read_text())["beats"]], [created["id"]])

    def test_list_never_writes_or_creates_the_store(self):
        code, value = self.run_beats("list")
        self.assertEqual((code, value["beats"]), (0, []))
        self.assertFalse(self.root.exists())
        self.create()
        path = self.root / "beats.json"
        before, content = os.stat(path), path.read_bytes()
        names = sorted(os.listdir(self.root))
        self.assertEqual(len(self.run_beats("list")[1]["beats"]), 1)
        after = os.stat(path)
        self.assertEqual(path.read_bytes(), content)
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))
        self.assertEqual(sorted(os.listdir(self.root)), names)

    def test_list_shares_the_lock_with_readers_and_waits_for_writers(self):
        self.create()
        descriptor = os.open(self.root / ".lock", os.O_RDONLY)
        self.addCleanup(os.close, descriptor)
        fcntl.flock(descriptor, fcntl.LOCK_SH)
        code, value = self.run_beats("list")
        self.assertEqual((code, len(value["beats"])), (0, 1))
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        environment = dict(os.environ, HOME=str(self.home))
        process = subprocess.Popen([sys.executable, str(self.controller), "beats", "list", "--self", "--session-id",
                                    SESSION_A], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
        try:
            with self.assertRaises(subprocess.TimeoutExpired):
                process.wait(1)
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        output, _ = process.communicate(timeout=30)
        self.assertEqual((process.returncode, len(json.loads(output)["beats"])), (0, 1))

    def test_validation_and_limits(self):
        for arguments in (("--cron", "nope", "--prompt", "x"), ("--cron", "* * * * *", "--prompt", "  "),
                          ("--cron", "* * * * *", "--prompt", "a" * 4097),
                          ("--cron", "* * * * *", "--prompt", "bell\x07")):
            code, value = self.run_beats("create", *arguments)
            self.assertNotEqual(code, 0, arguments)
            self.assertFalse(value["ok"])
        for _ in range(16):
            self.create()
        code, value = self.run_beats("create", "--cron", "* * * * *", "--prompt", "one too many")
        self.assertNotEqual(code, 0)
        self.assertIn("limit", value["error"])

    def test_requires_self_but_cron_check_does_not(self):
        code, value = self.run_beats("list", own=False)
        self.assertNotEqual(code, 0)
        code, value = self.run_beats("cron-check", "--cron", "0 9 * * *", "--count", "2", own=False)
        self.assertEqual(code, 0)
        self.assertEqual(len(value["next"]), 2)

    def snapshot(self, body):
        environment = dict(os.environ, HOME=str(self.home))
        process = subprocess.run([sys.executable, str(self.controller), "beats-snapshot"], input=body,
                                 capture_output=True, text=True, env=environment, timeout=30)
        return process.returncode, json.loads(process.stdout or process.stderr)

    def test_snapshot_returns_only_this_sessions_runnable_beats(self):
        self.assertEqual(self.snapshot(json.dumps({"sessionId": SESSION_A})), (0, {"ok": True, "beats": []}))
        self.assertFalse(self.root.exists())
        live = self.create(prompt="live")
        disabled = self.create(prompt="disabled")
        self.run_beats("disable", "--beat-id", disabled["id"])
        self.create(prompt="other", session=SESSION_B)
        code, value = self.snapshot(json.dumps({"sessionId": SESSION_A}))
        self.assertEqual(code, 0, value)
        self.assertEqual(value["beats"], [{"id": live["id"], "cron": live["cron"], "prompt": "live"}])

    def test_snapshot_refuses_bad_requests_and_invalid_stores(self):
        for body in ("", "nope", json.dumps({"sessionId": "x"}), json.dumps({"sessionId": SESSION_A, "x": 1}),
                     json.dumps({"sessionId": SESSION_A.upper()}), "x" * 2000):
            code, value = self.snapshot(body)
            self.assertNotEqual(code, 0, body[:40])
            self.assertFalse(value["ok"])
        self.create()
        path = self.root / "beats.json"
        path.write_text(path.read_text().replace('"revision":1', '"revision":0'))
        self.assertIn('"revision":0', path.read_text())
        code, value = self.snapshot(json.dumps({"sessionId": SESSION_A}))
        self.assertNotEqual(code, 0)
        self.assertFalse(value["ok"])


if __name__ == "__main__":
    unittest.main()
