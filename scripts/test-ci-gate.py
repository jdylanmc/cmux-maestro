#!/usr/bin/env python3
import importlib.util
import io
import json
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ci_gate", ROOT / "scripts/ci-gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

CONTRACT = {
    "version": 2,
    "gate_job": "ci-gate",
    "classifier_job": "classify",
    "suites": [
        {"job": "build", "purpose": "synthetic parent"},
        {"job": "native-tests", "purpose": "synthetic dependent of build"},
        {"job": "probe", "purpose": "synthetic independent suite"},
    ],
}
JOBS = ["build", "native-tests", "probe"]
BASE, HEAD, MERGE = "b" * 40, "c" * 40, "a" * 40
RUN = {"event": "pull_request", "run_id": "42", "sha": MERGE}


def record(not_applicable=(), **changes):
    decisions = {job: {"applicable": job not in not_applicable,
                       "reason": "docs-only change" if job in not_applicable else "unmapped: Sources/x.swift"}
                 for job in JOBS}
    value = {"version": 1, "complete": True, "event": "pull_request", "run_id": "42", "sha": MERGE,
             "base": BASE, "head": HEAD, "mode": "selective" if not_applicable else "full",
             "reason": "classified 1 changed file(s)", "changed_files": 1, "suites": decisions}
    value.update(changes)
    return value


def classifier_entry(value=None, result="success", flags=None):
    value = record() if value is None else value
    outputs = {"classification": value if isinstance(value, str) else json.dumps(value)}
    if flags is None and isinstance(value, dict) and isinstance(value.get("suites"), dict):
        flags = {gate.flag_name(job): "true" if decision.get("applicable") else "false"
                 for job, decision in value["suites"].items() if isinstance(decision, dict)}
    outputs.update(flags or {})
    return {"result": result, "outputs": outputs}


def needs(classify=None, **results):
    context = {job.replace("_", "-"): {"result": result, "outputs": {}} for job, result in results.items()}
    if classify is not False:
        context["classify"] = classify or classifier_entry()
    return json.dumps(context)


def all_success(classify=None):
    return needs(classify, build="success", native_tests="success", probe="success")


class EvaluatorTests(unittest.TestCase):
    def evaluate(self, needs_text, run=RUN):
        return gate.evaluate(gate.load_contract(json.dumps(CONTRACT)), needs_text, run)

    def verdicts(self, rows):
        return {job: (verdict, detail) for job, _, _, verdict, detail in rows}

    def test_all_required_suites_succeeding_passes(self):
        passed, rows, problems = self.evaluate(all_success())
        self.assertTrue(passed)
        self.assertEqual(problems, [])
        self.assertEqual([row[0] for row in rows], ["classify", *JOBS])
        self.assertEqual([row[3] for row in rows], ["PASS"] * 4)

    def test_failure_blocks(self):
        passed, rows, _ = self.evaluate(needs(build="success", native_tests="failure", probe="success"))
        self.assertFalse(passed)
        self.assertEqual(self.verdicts(rows)["native-tests"], ("FAIL", "failure"))

    def test_cancellation_blocks(self):
        passed, rows, _ = self.evaluate(needs(build="success", native_tests="success", probe="cancelled"))
        self.assertFalse(passed)
        self.assertEqual(self.verdicts(rows)["probe"], ("FAIL", "cancelled"))

    def test_missing_job_blocks(self):
        passed, rows, _ = self.evaluate(needs(build="success", native_tests="success"))
        self.assertFalse(passed)
        self.assertEqual(self.verdicts(rows)["probe"], ("FAIL", "missing from the gate's needs"))

    def test_missing_or_unknown_result_blocks(self):
        for entry, detail in (({"outputs": {}}, "no result reported"), ({"result": None}, "no result reported"),
                              ({"result": "neutral"}, "unknown result 'neutral'"), ("success", "no result reported")):
            with self.subTest(entry=entry):
                context = json.loads(all_success())
                context["probe"] = entry
                passed, rows, _ = self.evaluate(json.dumps(context))
                self.assertFalse(passed)
                self.assertEqual(self.verdicts(rows)["probe"], ("FAIL", detail))

    def test_missing_or_malformed_needs_context_blocks(self):
        for text in (None, "", "not json", "[]", "null"):
            with self.subTest(text=text):
                passed, rows, problems = self.evaluate(text)
                self.assertFalse(passed)
                self.assertIn("needs context is missing or not a JSON object", problems)
                self.assertTrue(all(row[3] == "FAIL" for row in rows))

    def test_skip_the_classification_selected_blocks(self):
        passed, rows, _ = self.evaluate(needs(build="success", native_tests="success", probe="skipped"))
        self.assertFalse(passed)
        self.assertEqual(self.verdicts(rows)["probe"],
                         ("FAIL", "skipped although the classification selected it"))

    def test_skip_caused_by_failed_upstream_dependency_blocks_and_names_it(self):
        # GitHub skips a job whose needs failed and may roll it up as green; the gate must not.
        passed, rows, _ = self.evaluate(needs(build="failure", native_tests="skipped", probe="success"))
        self.assertFalse(passed)
        verdicts = self.verdicts(rows)
        self.assertEqual(verdicts["build"], ("FAIL", "failure"))
        self.assertEqual(verdicts["native-tests"][0], "FAIL")
        self.assertIn("required jobs that did not succeed: build", verdicts["native-tests"][1])

    def test_job_outside_the_contract_is_drift(self):
        context = json.loads(all_success())
        context["unlisted"] = {"result": "success"}
        passed, _, problems = self.evaluate(json.dumps(context))
        self.assertFalse(passed)
        self.assertIn("job 'unlisted' is in the gate's needs but not in the required-suite contract", problems)

    # Suite selection (#194): a skip is accepted only with a valid, complete, same-run record.

    def test_deliberate_not_applicable_skip_passes_and_is_distinguishable(self):
        classify = classifier_entry(record(not_applicable=("native-tests", "probe")))
        passed, rows, problems = self.evaluate(
            needs(classify, build="success", native_tests="skipped", probe="skipped"))
        self.assertTrue(passed, (rows, problems))
        self.assertEqual(problems, [])
        verdicts = self.verdicts(rows)
        self.assertEqual(verdicts["build"], ("PASS", ""))
        for job in ("native-tests", "probe"):
            self.assertEqual(verdicts[job], ("NOT APPLICABLE", "deliberately not run; see the selection reason"))
        selections = {row[0]: row[1] for row in rows}
        self.assertEqual(selections["probe"], "not applicable: docs-only change")
        self.assertEqual(selections["build"], "applicable: unmapped: Sources/x.swift")

    def test_every_suite_not_applicable_passes_only_with_a_record(self):
        classify = classifier_entry(record(not_applicable=JOBS))
        self.assertTrue(self.evaluate(needs(classify, build="skipped", native_tests="skipped", probe="skipped"))[0])

    def test_applicable_failing_suite_still_blocks_a_selective_run(self):
        classify = classifier_entry(record(not_applicable=("probe",)))
        for result in ("failure", "cancelled", "skipped"):
            with self.subTest(result=result):
                passed, rows, _ = self.evaluate(needs(classify, build=result, native_tests="success", probe="skipped"))
                self.assertFalse(passed)
                self.assertEqual(self.verdicts(rows)["build"][0], "FAIL")
                self.assertEqual(self.verdicts(rows)["probe"][0], "NOT APPLICABLE")

    def test_classifier_failure_blocks_even_with_a_not_applicable_record(self):
        value = record(not_applicable=("probe",))
        for result in ("failure", "cancelled", "skipped", None, "neutral"):
            with self.subTest(result=result):
                classify = classifier_entry(value, result=result)
                if result is None:
                    del classify["result"]
                passed, rows, _ = self.evaluate(needs(classify, build="success", native_tests="success",
                                                      probe="skipped"))
                self.assertFalse(passed)
                verdicts = self.verdicts(rows)
                self.assertEqual(verdicts["classify"][0], "FAIL")
                self.assertIn("suite classification did not succeed", verdicts["classify"][1])
                self.assertEqual(verdicts["probe"][0], "FAIL")
                self.assertIn("required jobs that did not succeed: classify", verdicts["probe"][1])

    def test_classifier_failure_blocks_even_when_every_suite_succeeded(self):
        passed, rows, _ = self.evaluate(all_success(classifier_entry(result="failure")))
        self.assertFalse(passed)
        self.assertEqual(self.verdicts(rows)["classify"][0], "FAIL")

    def test_missing_classifier_blocks(self):
        passed, rows, _ = self.evaluate(needs(False, build="success", native_tests="success", probe="success"))
        self.assertFalse(passed)
        self.assertEqual(self.verdicts(rows)["classify"], ("FAIL", "missing from the gate's needs"))

    def invalid_records(self):
        valid = record(not_applicable=("probe",))
        partial = record(not_applicable=("probe",))
        del partial["suites"]["build"]
        extra_suite = record(not_applicable=("probe",))
        extra_suite["suites"]["other"] = {"applicable": False, "reason": "x"}
        no_reason = record(not_applicable=("probe",))
        no_reason["suites"]["probe"]["reason"] = " "
        string_bool = record(not_applicable=("probe",))
        string_bool["suites"]["probe"]["applicable"] = "false"
        extra_key = dict(valid, extra=1)
        missing_key = dict(valid)
        del missing_key["mode"]
        return {
            "missing": ("", "classification record is missing"),
            "not json": ("{", "classification record is not valid JSON"),
            "list": ("[]", "classification record is malformed"),
            "old stub shape": (json.dumps({"status": "complete", "not_applicable": {"probe": "docs"}}),
                               "classification record is malformed"),
            "extra key": (extra_key, "classification record is malformed"),
            "missing key": (missing_key, "classification record is malformed"),
            "wrong version": (dict(valid, version=2), "classification record is malformed"),
            "incomplete": (dict(valid, complete=False), "classification record is not complete"),
            "complete as string": (dict(valid, complete="true"), "classification record is not complete"),
            "other run": (dict(valid, run_id="41"), "classification record is for run_id '41'"),
            "other commit": (dict(valid, sha="d" * 40), "classification record is for sha"),
            "other event": (dict(valid, event="push"), "classification record is for event 'push'"),
            "partial suites": (partial, "does not decide exactly the required suites"),
            "unknown suite": (extra_suite, "does not decide exactly the required suites"),
            "no reason": (no_reason, "classification decision for probe is malformed"),
            "string boolean": (string_bool, "classification decision for probe is malformed"),
            "mode says full": (dict(valid, mode="full"), "classification mode disagrees"),
            "selective without base": (dict(valid, base=None), "must name the exact base and head"),
        }

    def test_invalid_record_blocks_skips_and_the_gate(self):
        for name, (value, problem) in self.invalid_records().items():
            for results in ({"probe": "skipped"}, {"probe": "success"}):
                with self.subTest(record=name, results=results):
                    flags = {gate.flag_name(job): "true" for job in JOBS} | {"run_probe": "false"}
                    classify = classifier_entry(value, flags=flags)
                    passed, rows, problems = self.evaluate(
                        needs(classify, build="success", native_tests="success", **results))
                    self.assertFalse(passed)
                    self.assertTrue(any(problem in item for item in problems), problems)
                    verdicts = self.verdicts(rows)
                    self.assertEqual(verdicts["classify"][0], "FAIL")
                    self.assertIn(problem, verdicts["classify"][1])
                    if results["probe"] == "skipped":
                        self.assertEqual(verdicts["probe"],
                                         ("FAIL", "skipped without a valid not-applicable classification"))

    def test_job_flags_must_match_the_record(self):
        value = record(not_applicable=("probe",))
        for flags in ({"run_probe": "true"}, {"run_probe": ""}, {"run_build": "false"}):
            with self.subTest(flags=flags):
                good = {gate.flag_name(job): "true" for job in JOBS} | {"run_probe": "false"}
                classify = classifier_entry(value, flags=good | flags)
                passed, rows, problems = self.evaluate(needs(classify, build="success", native_tests="success",
                                                             probe="skipped"))
                self.assertFalse(passed)
                self.assertTrue(any("disagrees with the record" in problem for problem in problems))
        classify = classifier_entry(value)
        del classify["outputs"]["run_probe"]
        self.assertFalse(self.evaluate(needs(classify, build="success", native_tests="success", probe="skipped"))[0])

    def test_push_runs_must_run_every_suite(self):
        run = dict(RUN, event="push")
        full = record(event="push", base=None, head=None)
        self.assertTrue(self.evaluate(all_success(classifier_entry(full)), run)[0])
        selective = record(not_applicable=("probe",), event="push", base=None, head=None)
        passed, _, problems = self.evaluate(
            needs(classifier_entry(selective), build="success", native_tests="success", probe="skipped"), run)
        self.assertFalse(passed)
        self.assertIn("a push run must run every suite; not applicable: probe", problems)

    def test_unknown_run_identity_cannot_match_a_record(self):
        for key in ("event", "run_id", "sha"):
            with self.subTest(key=key):
                passed, _, problems = self.evaluate(all_success(), dict(RUN, **{key: ""}))
                self.assertFalse(passed)
                self.assertIn(f"run {key} is unknown, so the record cannot be matched to this run", problems)

    def test_not_applicable_suite_that_ran_anyway_still_passes(self):
        classify = classifier_entry(record(not_applicable=("probe",)))
        passed, rows, _ = self.evaluate(all_success(classify))
        self.assertTrue(passed)
        self.assertEqual(self.verdicts(rows)["probe"], ("PASS", ""))


class ContractTests(unittest.TestCase):
    def test_invalid_contracts_refuse(self):
        def variant(**changes):
            return json.dumps({**CONTRACT, **changes})
        without_classifier = dict(CONTRACT)
        del without_classifier["classifier_job"]
        for text in ("{", "[]", variant(version=1), variant(suites=[]), variant(gate_job=""),
                     variant(classifier_job=""), variant(classifier_job="ci-gate"),
                     json.dumps(without_classifier),
                     variant(suites=[{"job": "ci-gate", "purpose": "self"}]),
                     variant(suites=[{"job": "classify", "purpose": "classifier as a suite"}]),
                     variant(suites=[{"job": "a", "purpose": "x"}, {"job": "a", "purpose": "y"}]),
                     variant(suites=[{"job": "a", "purpose": "x", "not_applicable": True}]),
                     variant(suites=[{"job": "a"}]), variant(extra=1)):
            with self.subTest(text=text):
                with self.assertRaises(gate.ContractError):
                    gate.load_contract(text)

    def test_checked_in_contract_loads(self):
        contract = gate.load_contract(gate.CONTRACT_PATH.read_text())
        self.assertEqual(contract["gate_job"], "ci-gate")
        self.assertEqual(contract["classifier_job"], "ci-classify")


class MainTests(unittest.TestCase):
    def run_main(self, environ, contract_path=gate.CONTRACT_PATH):
        out = io.StringIO()
        return gate.main(environ, contract_path, out), out.getvalue()

    def checked_in(self):
        contract = gate.load_contract(gate.CONTRACT_PATH.read_text())
        return contract["classifier_job"], gate.required_jobs(contract)

    def environ(self, context, event="pull_request"):
        return {"CI_GATE_NEEDS": json.dumps(context), "GITHUB_EVENT_NAME": event,
                "GITHUB_RUN_ID": "42", "GITHUB_SHA": MERGE}

    def classified(self, jobs, not_applicable=(), event="pull_request"):
        value = record(not_applicable=not_applicable, event=event)
        value["suites"] = {job: {"applicable": job not in not_applicable,
                                 "reason": "docs-only change" if job in not_applicable else "unmapped: x"}
                           for job in jobs}
        if event == "push":
            value.update(base=None, head=None)
        return classifier_entry(value)

    def test_main_prints_a_per_suite_table_and_writes_the_step_summary(self):
        classifier, jobs = self.checked_in()
        context = {job: {"result": "success"} for job in jobs[:-1]} | {jobs[-1]: {"result": "skipped"}}
        context[classifier] = self.classified(jobs)
        summary = Path(__file__).resolve().parent / f".ci-gate-summary-{id(self)}.md"
        try:
            environ = self.environ(context) | {"GITHUB_STEP_SUMMARY": str(summary)}
            code, output = self.run_main(environ)
            self.assertEqual(code, 1)
            self.assertIn("| Required job | Selection | Result | Verdict | Detail |", output)
            self.assertIn(f"| {classifier} | - | success | PASS | full:", output)
            for job in jobs[:-1]:
                self.assertIn(f"| {job} | applicable: unmapped: x | success | PASS |  |", output)
            self.assertIn(f"| {jobs[-1]} | applicable: unmapped: x | skipped | FAIL |", output)
            self.assertTrue(output.endswith("Final coverage gate: FAIL\n"))
            self.assertEqual(summary.read_text(), "## Final coverage gate\n\n" + output)
        finally:
            summary.unlink(missing_ok=True)

    def test_main_passes_only_on_complete_success_or_recorded_not_applicable(self):
        classifier, jobs = self.checked_in()
        context = {job: {"result": "success"} for job in jobs} | {classifier: self.classified(jobs)}
        code, output = self.run_main(self.environ(context))
        self.assertEqual(code, 0)
        self.assertTrue(output.endswith("Final coverage gate: PASS\n"))
        context = {jobs[0]: {"result": "success"}} | {job: {"result": "skipped"} for job in jobs[1:]}
        context[classifier] = self.classified(jobs, not_applicable=jobs[1:])
        code, output = self.run_main(self.environ(context))
        self.assertEqual(code, 0, output)
        for job in jobs[1:]:
            self.assertIn(f"| {job} | not applicable: docs-only change | skipped | NOT APPLICABLE |", output)
        self.assertEqual(self.run_main({})[0], 1)

    def test_main_push_run_requires_every_suite(self):
        classifier, jobs = self.checked_in()
        context = {job: {"result": "success"} for job in jobs} | {classifier: self.classified(jobs, event="push")}
        self.assertEqual(self.run_main(self.environ(context, "push"))[0], 0)
        context[jobs[-1]] = {"result": "skipped"}
        context[classifier] = self.classified(jobs, not_applicable=jobs[-1:], event="push")
        code, output = self.run_main(self.environ(context, "push"))
        self.assertEqual(code, 1)
        self.assertIn("a push run must run every suite", output)

    def test_any_one_failed_or_missing_split_suite_fails_the_checked_in_gate(self):
        classifier, jobs = self.checked_in()
        self.assertGreaterEqual(len(jobs), 3)
        for job in jobs:
            for result in ("failure", "cancelled", "skipped", None):
                with self.subTest(job=job, result=result):
                    context = {other: {"result": "success"} for other in jobs if other != job}
                    context[classifier] = self.classified(jobs)
                    if result:
                        context[job] = {"result": result}
                    code, output = self.run_main(self.environ(context))
                    self.assertEqual(code, 1)
                    self.assertRegex(output, rf"(?m)^\| {job} \| [^|]+ \| [^|]+ \| FAIL \|")
                    for other in jobs:
                        if other != job:
                            self.assertIn(f"| {other} | applicable: unmapped: x | success | PASS |  |", output)

    def test_unreadable_contract_fails_closed(self):
        code, output = self.run_main({"CI_GATE_NEEDS": "{}"}, ROOT / "scripts/does-not-exist.json")
        self.assertEqual(code, 1)
        self.assertIn("Final coverage gate: FAIL (contract:", output)


if __name__ == "__main__":
    unittest.main()
