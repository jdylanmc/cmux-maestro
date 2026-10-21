#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("timing", Path(__file__).with_name("check-test-timing.py"))
timing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(timing)


class TimingPolicyTests(unittest.TestCase):
    def test_changed_delay_and_duplicate_existing_sleep_cannot_use_old_exception(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            name = "ExampleTests/Clock.swift"
            file = root / name
            file.parent.mkdir()
            original = "try await Task." + "sleep(for: .seconds(60))"
            policy = {name: {"reason": "Hang guard only", "statements": {original: 1}}}
            file.write_text(original)
            self.assertEqual(timing.violations(root, [name], policy), [])
            for text in (original + "\n" + original, original.replace("60", "2")):
                file.write_text(text)
                self.assertTrue(any("unreviewed" in error for error in timing.violations(root, [name], policy)))

    def test_new_files_multiline_spelling_and_other_languages_are_checked(self):
        for name, text in [
            ("NewTests/Test.swift", "try await Task\n .sleep(for: .seconds(1))"),
            ("scripts/test-new.py", "time." + "sleep(0.1)"),
            ("scripts/test-new.mjs", "set" + "Timeout(resolve, 20)"),
            ("scripts/test-new.sh", "sleep " + "0.1"),
            ("scripts/test-new.sh", "echo waiting; " + "sleep 1"),
            ("scripts/test-new.mjs", "import { setTimeout as delay } from 'node:timers/promises';\n"
             + "await de" + "lay(100)"),
            ("NewTests/Window.swift", "#expect(window." + "isKeyWindow)"),
            ("NewTests/Render.swift", "let oracle = VNRecognize" + "TextRequest()"),
            ("NewTests/Clock.swift", "let now = Da" + "te()"),
            ("NewTests/Clock.swift", "let deadline = Date." + "now.addingTimeInterval(0.1)"),
            ("NewTests/Clock.swift", "let now = Date\n ." + "now"),
            ("NewTests/Clock.swift", "let now = ContinuousClock()." + "now"),
            ("NewTests/Clock.swift", "let now = SuspendingClock." + "now"),
            ("NewTests/Clock.swift", "let now = CFAbsoluteTimeGet" + "Current()"),
            ("NewTests/Clock.swift", "await fulfill" + "ment(of: [done], timeout: 0.1)"),
            ("NewTests/Clock.swift", "wait(" + "for: [done], timeout: 0.1)"),
            ("NewTests/Clock.swift", "waitFor" + "Expectations(timeout: 0.1)"),
            ("NewTests/Clock.swift", "Date(timeInterval" + "SinceNow: 0.1)"),
            ("scripts/test-clock.mjs", "performance." + "now()"),
            ("scripts/test-clock.mjs", "process." + "hrtime.bigint()"),
            ("scripts/test-clock.mjs", "AbortSignal." + "timeout(2000)"),
            ("scripts/test-fixtures/clock.py", "time." + "perf_counter()"),
            ("scripts/test-fixtures/clock.py", "time." + "monotonic_ns()"),
            ("scripts/test-fixtures/clock.py", "datetime." + "now()"),
            ("scripts/test-fixtures/clock.py", "datetime.datetime." + "utcnow()"),
            ("scripts/test-fixtures/clock.py", "time." + "time_ns()"),
            (".agents/skills/example/tests/clock.test.mjs", "await de" + "lay(100)"),
        ]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                file = root / name
                file.parent.mkdir(parents=True)
                file.write_text(text)
                self.assertTrue(timing.violations(root, [name], {}))

    def test_continuation_arguments_are_part_of_the_exception(self):
        for name, original in [
            ("tests/clock.test.mjs", "set" + "Timeout(() => {\n  consume(')'); // misleading )\n},\n  50)"),
            ("Tests/Clock.swift", "try await Task\n .sl" + "eep(\n for: .milliseconds(50)\n)"),
            ("tests/clock.test.mjs", "await de" + "lay(\n /* misleading ) */\n 50\n)"),
            ("Tests/Clock.swift", "waitFor" + "Expectations(\n timeout: 50\n)"),
            ("scripts/test-clock.py", "time.sl" + "eep( #guard )\n    50\n)"),
            ("tests/clock.test.mjs", "set" + "Timeout(() => /[)]/.test(value),\n    50\n)"),
            ("tests/clock.test.mjs", "set" + "Timeout(() => n / f(/x/),\n    50\n)"),
            ("tests/clock.test.mjs", "set" + "Timeout(() => n++ / f(/x/),\n    50\n)"),
            ("tests/clock.test.mjs", "set" + "Timeout(() => ({}) / f(/x/),\n    50\n)"),
            ("tests/clock.test.mjs", "set" + "Timeout(() => { if (check()) /[)]/.test(value); },\n    50\n)"),
            ("Tests/Clock.swift", "await Task.sl" + "eep(/* outer /* inner */ ) */\n for: .seconds(50)\n)"),
        ]:
            with self.subTest(original=original), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                file = root / name
                file.parent.mkdir()
                policy = {name: {"reason": "Reviewed hang guard", "statements": timing.statements(original, name)}}
                file.write_text(original)
                self.assertEqual(timing.violations(root, [name], policy), [])
                file.write_text(original.replace("50", "2"))
                errors = timing.violations(root, [name], policy)
                self.assertTrue(any("unreviewed" in error for error in errors), errors)
                self.assertTrue(any("stale/excess" in error for error in errors), errors)

    def test_shell_command_boundaries_cannot_hide_sleeps(self):
        for form in (
            "PAUSE 0.1",
            "echo ready; PAUSE 0.1",
            "echo ready && PAUSE 0.1",
            "false || PAUSE 0.1",
            "printf x | PAUSE 0.1",
            "for item in 1; do PAUSE 0.1; done",
            "if true; then PAUSE 0.1; fi",
            "if false; then :; else PAUSE 0.1; fi",
            "if PAUSE 0.1; then :; fi",
            "while PAUSE 0.1; do break; done",
            "while PAUSE \\\n  0.1; do break; done",
            "if true; then PAUSE \\\n  \\\n  0.1; fi",
            "until PAUSE 0.1; do break; done",
            "! PAUSE 0.1",
            "(PAUSE 0.1; echo done)",
            "( PAUSE 0.1; echo done)",
            "value=$(PAUSE 0.1; echo done)",
            "value=`PAUSE 0.1; echo done`",
            "{ PAUSE 0.1; }",
        ):
            with self.subTest(form=form), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                name = "test-command.sh"
                file = root / name
                text = form.replace("PAUSE", "sl" + "eep")
                file.write_text(text)
                self.assertTrue(any("unreviewed" in error for error in timing.violations(root, [name], {})))
                policy = {name: {"reason": "Reviewed process watchdog",
                                 "statements": timing.statements(text, name)}}
                self.assertEqual(timing.violations(root, [name], policy), [])
                file.write_text(text.replace("0.1", "0.2"))
                self.assertTrue(any("unreviewed" in error for error in timing.violations(root, [name], policy)))

    def test_barriers_and_virtual_clock_advancement_need_no_exception(self):
        self.assertEqual(timing.statements("await gate.open()\nclock.advance(by: .seconds(60))"), {})
        self.assertFalse(timing.test_path("Production/Clock.swift"))

    def test_removed_occurrences_and_absent_files_must_remove_their_exceptions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            name = "tests/clock.test.mjs"
            file = root / name
            file.parent.mkdir()
            statement = "AbortSignal." + "timeout(60_000)"
            policy = {name: {"reason": "Hang guard", "statements": {statement: 2}}}
            file.write_text(statement)
            self.assertTrue(any("stale/excess" in error for error in timing.violations(root, [name], policy)))
            self.assertTrue(any("absent" in error for error in timing.violations(root, [], policy)))


if __name__ == "__main__":
    unittest.main()
