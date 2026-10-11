#!/usr/bin/env python3
"""Fast, deterministic tests for Beats: cron evaluation, local-time/DST rules, the shared
definition store, and the exact-self agent surface. No real clock, session or network."""
import json
import os
import runpy
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
beats_due = API["beats_due"]
cron_next_times = API["cron_next_times"]
local_minute_key = API["local_minute_key"]
store_mutate = API["beats_store_mutate"]
store_read = API["beats_store_read"]

SESSION_A = str(uuid.uuid4())
SESSION_B = str(uuid.uuid4())


def local_epoch(year, month, day, hour, minute, dst):
    return time.mktime((year, month, day, hour, minute, 0, 0, 0, dst))


def beat(cron, session=SESSION_A, **overrides):
    value = {"id": str(uuid.uuid4()), "sessionId": session, "cron": cron, "prompt": "go",
             "enabled": True, "recoveryGate": False, "targetEnded": False, "lastFiredMinute": None,
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

    def test_store_sample_is_valid_and_round_trips(self):
        raw = (FIXTURES / "beats-store-sample.json").read_text()
        state = json.loads(raw)
        API["validate_beats_state"](state)
        self.assertEqual(json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n", raw)


class DaylightSavingTests(LocalTimeCase):
    def simulate(self, cron, start, end):
        state = {"version": 1, "beats": [beat(cron)]}
        fired, moment = [], start
        while moment < end:
            key, due = beats_due(state, moment)
            for item in due:
                item["lastFiredMinute"] = key
                fired.append(key)
            moment += 60
        return fired

    def test_nonexistent_local_minute_is_skipped(self):
        # 2026-03-08 02:00-02:59 does not exist in New York.
        start = local_epoch(2026, 3, 8, 1, 30, 0)
        end = local_epoch(2026, 3, 8, 4, 0, 1)
        self.assertEqual(self.simulate("30 2 * * *", start, end), [])
        self.assertEqual(self.simulate("30 3 * * *", start, end), ["2026-03-08T03:30"])
        times = cron_next_times(parse_cron("30 2 * * *"), local_epoch(2026, 3, 7, 12, 0, 0), count=2)
        self.assertEqual([time.strftime("%m-%d %H:%M", time.localtime(t)) for t in times], ["03-09 02:30", "03-10 02:30"])

    def test_repeated_local_minute_fires_once(self):
        # 2026-11-01 01:00-01:59 happens twice (EDT then EST).
        start = local_epoch(2026, 11, 1, 0, 30, 1)
        end = local_epoch(2026, 11, 1, 3, 0, 0)
        self.assertEqual(self.simulate("30 1 * * *", start, end), ["2026-11-01T01:30"])
        self.assertEqual(self.simulate("*/30 1 * * *", start, end), ["2026-11-01T01:00", "2026-11-01T01:30"])
        times = cron_next_times(parse_cron("30 1 * * *"), local_epoch(2026, 10, 31, 12, 0, 1), count=1)
        self.assertEqual(len(times), 1)

    def test_missed_minutes_are_never_replayed(self):
        state = {"version": 1, "beats": [beat("* * * * *")]}
        key_one, due_one = beats_due(state, local_epoch(2026, 10, 10, 20, 0, 1))
        self.assertEqual(len(due_one), 1)
        # A stalled clock that resumes ten minutes later sees only the current minute.
        key_two, due_two = beats_due(state, local_epoch(2026, 10, 10, 20, 10, 1))
        self.assertEqual(len(due_two), 1)
        self.assertEqual(key_two, "2026-10-10T20:10")

    def test_due_requires_enabled_ungated_live_and_unfired(self):
        moment = local_epoch(2026, 10, 10, 20, 0, 1)
        key = local_minute_key(moment)
        for override in ({"enabled": False}, {"recoveryGate": True}, {"targetEnded": True}, {"lastFiredMinute": key}):
            state = {"version": 1, "beats": [beat("0 20 * * *", **override)]}
            self.assertEqual(beats_due(state, moment)[1], [], msg=str(override))
        self.assertEqual(len(beats_due({"version": 1, "beats": [beat("0 20 * * *")]}, moment)[1]), 1)


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
        for content in ('{"version": 2, "beats": []}', '{"version": 1}', "not json",
                        json.dumps({"version": 1, "beats": [{"id": "x"}]})):
            path.write_text(content)
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

    def test_invalid_mutation_is_not_persisted(self):
        store_mutate(lambda state: state["beats"].append(beat("0 9 * * *")), root=self.root)
        before = (self.root / "beats.json").read_bytes()

        def corrupt(state):
            state["beats"][0]["cron"] = "bogus"
        with self.assertRaises(OrchestrationError):
            store_mutate(corrupt, root=self.root)
        self.assertEqual((self.root / "beats.json").read_bytes(), before)


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
        self.root = Path(self.directory.name) / "beats"
        self.helper = Path(self.directory.name) / "helper"
        self.helper.write_text(FAKE_HELPER)
        self.helper.chmod(0o700)

    def tearDown(self):
        self.directory.cleanup()

    def run_beats(self, *arguments, session=SESSION_A, deny=False, own=True):
        environment = dict(os.environ, CMUX_MAESTRO_TESTING="1", CMUX_MAESTRO_BEATS_ROOT=str(self.root),
                           CMUX_MAESTRO_IDENTITY_HELPER=str(self.helper))
        if deny:
            environment["FAKE_PROOF"] = "deny"
        command = [sys.executable, str(CONTROLLER), "beats", *arguments]
        if own:
            command += ["--self", "--session-id", session]
        process = subprocess.run(command, capture_output=True, text=True, env=environment, timeout=30)
        body = process.stdout or process.stderr
        return process.returncode, json.loads(body)

    def create(self, cron="0 9 * * 1-5", prompt="check the board", session=SESSION_A):
        code, value = self.run_beats("create", "--cron", cron, "--prompt", prompt, session=session)
        self.assertEqual(code, 0, value)
        return value["beat"]

    def test_create_list_edit_pause_resume_delete(self):
        created = self.create()
        self.assertTrue(created["enabled"] and not created["recoveryGate"])
        self.assertEqual(created["cron"], "0 9 * * 1-5")
        code, listed = self.run_beats("list")
        self.assertEqual([item["id"] for item in listed["beats"]], [created["id"]])
        code, edited = self.run_beats("edit", "--beat-id", created["id"], "--cron", "*/5  * * * *")
        self.assertEqual(edited["beat"]["cron"], "*/5 * * * *")
        self.assertEqual(edited["beat"]["revision"], 2)
        self.assertEqual(edited["beat"]["prompt"], "check the board")
        code, paused = self.run_beats("pause", "--beat-id", created["id"])
        self.assertFalse(paused["beat"]["enabled"])
        code, resumed = self.run_beats("resume", "--beat-id", created["id"])
        self.assertTrue(resumed["beat"]["enabled"])
        code, deleted = self.run_beats("delete", "--beat-id", created["id"])
        self.assertEqual(deleted["deleted"], created["id"])
        self.assertEqual(self.run_beats("list")[1]["beats"], [])

    def test_agent_cannot_touch_another_sessions_beat(self):
        created = self.create(session=SESSION_A)
        for action in ("edit", "pause", "resume", "delete"):
            extra = ("--cron", "1 1 * * *") if action == "edit" else ()
            code, value = self.run_beats(action, "--beat-id", created["id"], *extra, session=SESSION_B)
            self.assertNotEqual(code, 0, action)
            self.assertIn("No such Beat", value["error"])
        self.assertEqual(self.run_beats("list", session=SESSION_B)[1]["beats"], [])
        self.assertEqual(len(self.run_beats("list", session=SESSION_A)[1]["beats"]), 1)

    def test_failed_ownership_proof_changes_nothing(self):
        code, value = self.run_beats("create", "--cron", "0 9 * * *", "--prompt", "x", deny=True)
        self.assertNotEqual(code, 0)
        self.assertIn("could not prove ownership", value["error"])
        self.assertFalse((self.root / "beats.json").exists())

    def test_agent_resume_cannot_clear_a_recovery_gate_or_ended_target(self):
        created = self.create()
        for flag in ("recoveryGate", "targetEnded"):
            def gate(state, flag=flag):
                state["beats"][0][flag] = True
            store_mutate(gate, root=self.root)
            code, value = self.run_beats("resume", "--beat-id", created["id"])
            self.assertNotEqual(code, 0)
            self.assertIn("human", value["error"])
            def clear(state, flag=flag):
                state["beats"][0][flag] = False
            store_mutate(clear, root=self.root)

    def test_pause_edit_and_delete_still_work_while_gated(self):
        created = self.create()
        store_mutate(lambda state: state["beats"][0].update(recoveryGate=True, enabled=False), root=self.root)
        code, edited = self.run_beats("edit", "--beat-id", created["id"], "--prompt", "new words")
        self.assertEqual(code, 0)
        self.assertTrue(edited["beat"]["recoveryGate"] and not edited["beat"]["enabled"])
        self.assertEqual(self.run_beats("delete", "--beat-id", created["id"])[0], 0)

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


class DeliveryTests(LocalTimeCase):
    def setUp(self):
        super().setUp()
        self.base = Path(tempfile.mkdtemp(prefix="bt-", dir="/tmp")).resolve()
        self.store = self.base / "store"
        self.store.mkdir(mode=0o700)
        self.routes = self.base / "routes"
        self.routes.mkdir(mode=0o700)
        self.addCleanup(lambda: __import__("shutil").rmtree(self.base, ignore_errors=True))
        self.sent = []
        self.workspace = str(uuid.uuid4())

    def bind(self, session, peer="0123456789abcdef", generation=1, socket_file=True):
        binding = {"peer": peer, "nodeId": str(uuid.uuid4()), "name": "worker", "workspaceId": self.workspace,
                   "sessionId": session, "generation": generation, "capability": "a" * 64}
        path = self.routes / f"{peer}.json"
        path.write_text(json.dumps(binding))
        path.chmod(0o600)
        if socket_file:
            import socket as socket_module
            listener = socket_module.socket(socket_module.AF_UNIX)
            listener.bind(str(self.routes / f"{peer}.sock"))
            (self.routes / f"{peer}.sock").chmod(0o600)
            self.addCleanup(listener.close)
            return binding, listener
        return binding, None

    def seed(self, *beats):
        store_mutate(lambda state: state["beats"].extend(beats), root=self.store)

    def tick(self, epoch, send=None):
        return API["beats_tick"](epoch, routes=self.routes, store_root=self.store,
                                 send=send or (lambda routes, binding, prompt: self.sent.append((binding, prompt))))

    def test_fires_once_for_its_minute_and_never_retries_or_catches_up(self):
        self.bind(SESSION_A)
        record = beat("*/5 * * * *")
        self.seed(record)
        moment = local_epoch(2026, 1, 15, 10, 5, 0)
        self.assertEqual([item["outcome"] for item in self.tick(moment)], ["sent"])
        self.assertEqual(self.tick(moment + 20), [])
        self.assertEqual(self.tick(moment + 60), [])
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.sent[0][1], "go")

    def test_failed_attempt_is_recorded_and_not_retried(self):
        self.bind(SESSION_A)
        self.seed(beat("* * * * *"))
        moment = local_epoch(2026, 1, 15, 10, 5, 0)

        def refuse(routes, binding, prompt):
            raise OrchestrationError("no")
        self.assertEqual(self.tick(moment, refuse)[0]["outcome"], "failed")
        self.assertEqual(self.tick(moment + 10), [])

    def test_unmanaged_or_unbound_session_reports_without_delivery(self):
        self.seed(beat("* * * * *"))
        self.assertEqual(self.tick(local_epoch(2026, 1, 15, 10, 5, 0))[0]["outcome"], "no-managed-session")
        self.assertEqual(self.sent, [])

    def test_gated_paused_and_ended_beats_do_not_fire(self):
        self.bind(SESSION_A)
        self.seed(beat("* * * * *", recoveryGate=True), beat("* * * * *", enabled=False),
                  beat("* * * * *", targetEnded=True))
        self.assertEqual(self.tick(local_epoch(2026, 1, 15, 10, 5, 0)), [])

    def test_binding_choice_is_exact_session_newest_generation_with_live_socket(self):
        self.bind(SESSION_B, peer="1111111111111111")
        self.bind(SESSION_A, peer="2222222222222222", generation=1)
        newer, _ = self.bind(SESSION_A, peer="3333333333333333", generation=2)
        self.bind(SESSION_A, peer="4444444444444444", generation=3, socket_file=False)
        found = API["beat_binding"](self.routes, SESSION_A)
        self.assertEqual(found["peer"], newer["peer"])
        self.assertIsNone(API["beat_binding"](self.routes, str(uuid.uuid4())))

    def test_real_socket_receives_a_beat_frame_with_target_capability(self):
        binding, listener = self.bind(SESSION_A)
        listener.listen(1)
        API["send_beat"](self.routes, binding, "héllo\nworld")
        connection, _ = listener.accept()
        wire = json.loads(connection.makefile("rb").read())
        self.assertEqual(wire, {"destination": {"workspaceId": self.workspace, "sessionId": SESSION_A, "generation": 1},
                                "kind": "beat", "body": "héllo\nworld", "capability": "a" * 64})

    def test_start_gates_saved_recurrence_for_human_recovery(self):
        self.seed(beat("* * * * *"), beat("* * * * *", enabled=False))
        self.assertEqual(API["beats_gate_on_start"](self.store), 1)
        states = store_read(root=self.store)["beats"]
        self.assertEqual([(item["enabled"], item["recoveryGate"]) for item in states],
                         [(False, True), (False, False)])


if __name__ == "__main__":
    unittest.main()
