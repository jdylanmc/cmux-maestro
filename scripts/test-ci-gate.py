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
    "version": 1,
    "gate_job": "ci-gate",
    "suites": [
        {"job": "build", "purpose": "synthetic parent"},
        {"job": "native-tests", "purpose": "synthetic dependent of build"},
        {"job": "probe", "purpose": "synthetic independent suite"},
    ],
}


def needs(**results):
    return json.dumps({job.replace("_", "-"): {"result": result, "outputs": {}} for job, result in results.items()})


def all_success():
    return needs(build="success", native_tests="success", probe="success")


class EvaluatorTests(unittest.TestCase):
    def evaluate(self, needs_text, classification=None):
        return gate.evaluate(gate.load_contract(json.dumps(CONTRACT)), needs_text, classification)

    def verdicts(self, rows):
        return {job: (verdict, detail) for job, _, verdict, detail in rows}

    def test_all_required_suites_succeeding_passes(self):
        passed, rows, problems = self.evaluate(all_success())
        self.assertTrue(passed)
        self.assertEqual(problems, [])
        self.assertEqual([row[2] for row in rows], ["PASS"] * 3)

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
                self.assertTrue(all(row[2] == "FAIL" for row in rows))

    def test_unexpected_skip_blocks(self):
        passed, rows, _ = self.evaluate(needs(build="success", native_tests="success", probe="skipped"))
        self.assertFalse(passed)
        self.assertEqual(self.verdicts(rows)["probe"],
                         ("FAIL", "skipped without a not-applicable classification"))

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

    def test_classifier_failure_blocks(self):
        for record in ("not json", "[]", json.dumps({"status": "failed"}), json.dumps({"status": "partial"}),
                       json.dumps({"not_applicable": ["probe"]})):
            with self.subTest(record=record):
                passed, _, problems = self.evaluate(all_success(), record)
                self.assertFalse(passed)
                self.assertTrue(problems)

    def test_not_applicable_record_is_rejected_until_issue_194(self):
        record = json.dumps({"status": "complete", "not_applicable": {"probe": "docs-only change"}})
        for context in (needs(build="success", native_tests="success", probe="skipped"), all_success()):
            with self.subTest(context=context):
                passed, _, problems = self.evaluate(context, record)
                self.assertFalse(passed)
                self.assertIn("not-applicable classification is not supported until #194 defines it", problems)

    def test_absent_classification_is_not_a_problem(self):
        for record in (None, ""):
            with self.subTest(record=record):
                self.assertTrue(self.evaluate(all_success(), record)[0])


class ContractTests(unittest.TestCase):
    def test_invalid_contracts_refuse(self):
        def variant(**changes):
            return json.dumps({**CONTRACT, **changes})
        for text in ("{", "[]", variant(version=2), variant(suites=[]), variant(gate_job=""),
                     variant(suites=[{"job": "ci-gate", "purpose": "self"}]),
                     variant(suites=[{"job": "a", "purpose": "x"}, {"job": "a", "purpose": "y"}]),
                     variant(suites=[{"job": "a", "purpose": "x", "not_applicable": True}]),
                     variant(suites=[{"job": "a"}]), variant(extra=1)):
            with self.subTest(text=text):
                with self.assertRaises(gate.ContractError):
                    gate.load_contract(text)

    def test_checked_in_contract_loads(self):
        contract = gate.load_contract(gate.CONTRACT_PATH.read_text())
        self.assertEqual(contract["gate_job"], "ci-gate")


class MainTests(unittest.TestCase):
    def run_main(self, environ, contract_path=gate.CONTRACT_PATH):
        out = io.StringIO()
        return gate.main(environ, contract_path, out), out.getvalue()

    def test_main_prints_a_per_suite_table_and_writes_the_step_summary(self):
        context = json.dumps({"validate": {"result": "success"}, "guide-ui-consumer-probe": {"result": "skipped"}})
        summary = Path(__file__).resolve().parent / f".ci-gate-summary-{id(self)}.md"
        try:
            code, output = self.run_main({"CI_GATE_NEEDS": context, "GITHUB_STEP_SUMMARY": str(summary)})
            self.assertEqual(code, 1)
            self.assertIn("| Required suite | Result | Verdict | Detail |", output)
            self.assertIn("| validate | success | PASS |  |", output)
            self.assertIn("| guide-ui-consumer-probe | skipped | FAIL |", output)
            self.assertTrue(output.endswith("Final coverage gate: FAIL\n"))
            self.assertEqual(summary.read_text(), "## Final coverage gate\n\n" + output)
        finally:
            summary.unlink(missing_ok=True)

    def test_main_passes_only_on_complete_success(self):
        context = json.dumps({"validate": {"result": "success"}, "guide-ui-consumer-probe": {"result": "success"}})
        code, output = self.run_main({"CI_GATE_NEEDS": context})
        self.assertEqual(code, 0)
        self.assertTrue(output.endswith("Final coverage gate: PASS\n"))
        self.assertEqual(self.run_main({})[0], 1)

    def test_unreadable_contract_fails_closed(self):
        code, output = self.run_main({"CI_GATE_NEEDS": "{}"}, ROOT / "scripts/does-not-exist.json")
        self.assertEqual(code, 1)
        self.assertIn("Final coverage gate: FAIL (contract:", output)


if __name__ == "__main__":
    unittest.main()
