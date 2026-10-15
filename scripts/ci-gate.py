#!/usr/bin/env python3
"""Final CI coverage gate (#197) with suite selection (#194).

Reads the GitHub Actions `needs` context (JSON in CI_GATE_NEEDS), the run's
identity (GITHUB_EVENT_NAME, GITHUB_RUN_ID, GITHUB_SHA) and the required-suite
contract (scripts/ci-required-suites.json). Exits 0 only when:

- the classifier job (`classifier_job`) succeeded and published a valid,
  complete classification record for this exact run, event and commit; and
- every required suite either reports exactly `success`, or was skipped and
  the record explicitly marks that suite not applicable, with a reason.

Failure, cancellation, a missing job or result, an unknown result, contract
drift, a skip without a valid not-applicable record (including one caused by a
failed upstream job or a failed classifier), and a malformed, partial or
mismatched record all block the gate. A push run may not mark any suite not
applicable: `main` always runs everything.

The gate judges job results only. Each job enforces its own evidence: required
artifacts use `if-no-files-found: error`, and the integrated harness enforces
nonzero execution, coverage accounting and candidate/base attribution. A job
that loses that evidence fails, and the gate then fails with it.
"""
import json
import os
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
CONTRACT_PATH = Path(__file__).resolve().parent / "ci-required-suites.json"
KNOWN_RESULTS = {"success", "failure", "cancelled", "skipped"}
SUITE_KEYS = {"job", "purpose"}
CONTRACT_KEYS = {"version", "gate_job", "classifier_job", "suites"}
RECORD_KEYS = {"version", "complete", "event", "run_id", "sha", "base", "head", "mode", "reason",
               "changed_files", "suites"}
DECISION_KEYS = {"applicable", "reason"}
SHA = re.compile(r"[0-9a-f]{40}")


class ContractError(ValueError):
    pass


def load_contract(text):
    try:
        contract = json.loads(text)
    except json.JSONDecodeError as error:
        raise ContractError(f"contract is not valid JSON: {error}") from None
    if not isinstance(contract, dict) or set(contract) != CONTRACT_KEYS:
        raise ContractError(f"contract must have exactly the keys {sorted(CONTRACT_KEYS)}")
    if contract["version"] != 2:
        raise ContractError("unsupported contract version")
    gate, classifier = contract["gate_job"], contract["classifier_job"]
    for name, value in (("gate_job", gate), ("classifier_job", classifier)):
        if not isinstance(value, str) or not value:
            raise ContractError(f"{name} must be a nonempty string")
    if gate == classifier:
        raise ContractError("the gate cannot be the classifier")
    suites = contract["suites"]
    if not isinstance(suites, list) or not suites:
        raise ContractError("contract must list at least one required suite")
    jobs = []
    for suite in suites:
        if not isinstance(suite, dict) or set(suite) != SUITE_KEYS:
            raise ContractError(f"each suite must have exactly the keys {sorted(SUITE_KEYS)}")
        job = suite["job"]
        if not isinstance(job, str) or not job or not isinstance(suite["purpose"], str):
            raise ContractError("suite job and purpose must be strings")
        if job == gate:
            raise ContractError("the gate cannot require itself")
        if job == classifier:
            raise ContractError("the classifier is not a selectable suite")
        jobs.append(job)
    if len(set(jobs)) != len(jobs):
        raise ContractError("duplicate required suite")
    return contract


def required_jobs(contract):
    return [suite["job"] for suite in contract["suites"]]


def flag_name(job):
    return "run_" + job.replace("-", "_")


def classification(contract, entry, run):
    """Return (record, problem). A record is returned only when it is valid for this run."""
    outputs = entry.get("outputs") if isinstance(entry, dict) else None
    raw = outputs.get("classification") if isinstance(outputs, dict) else None
    if not raw:
        return None, "classification record is missing"
    try:
        record = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return None, "classification record is not valid JSON"
    if not isinstance(record, dict) or set(record) != RECORD_KEYS or record["version"] != 1:
        return None, "classification record is malformed"
    if record["complete"] is not True:
        return None, "classification record is not complete"
    for key in ("event", "run_id", "sha"):
        if not run.get(key):
            return None, f"run {key} is unknown, so the record cannot be matched to this run"
        if record[key] != run[key]:
            return None, f"classification record is for {key} {record[key]!r}, not this run's {run[key]!r}"
    jobs = required_jobs(contract)
    decisions = record["suites"]
    if not isinstance(decisions, dict) or sorted(decisions) != sorted(jobs):
        return None, "classification record does not decide exactly the required suites"
    for job, decision in decisions.items():
        if (not isinstance(decision, dict) or set(decision) != DECISION_KEYS
                or not isinstance(decision["applicable"], bool)
                or not isinstance(decision["reason"], str) or not decision["reason"].strip()):
            return None, f"classification decision for {job} is malformed"
        flag = outputs.get(flag_name(job))
        if flag != ("true" if decision["applicable"] else "false"):
            return None, f"output {flag_name(job)}={flag!r} disagrees with the record for {job}"
    skipped = [job for job, decision in decisions.items() if not decision["applicable"]]
    if record["mode"] not in ("full", "selective") or (record["mode"] == "full") != (not skipped):
        return None, "classification mode disagrees with its decisions"
    if record["event"] != "pull_request" and skipped:
        return None, f"a {record['event']} run must run every suite; not applicable: {', '.join(skipped)}"
    if record["event"] == "pull_request" and skipped and not (
            SHA.fullmatch(str(record["base"])) and SHA.fullmatch(str(record["head"]))):
        return None, "a selective record must name the exact base and head"
    return record, None


def evaluate(contract, needs_text, run=None):
    """Return (passed, rows, problems). rows: (job, selection, result, verdict, detail)."""
    run = run or {}
    problems = []
    try:
        needs = json.loads(needs_text) if needs_text else None
    except json.JSONDecodeError:
        needs = None
    if not isinstance(needs, dict):
        problems.append("needs context is missing or not a JSON object")
        needs = {}
    classifier = contract["classifier_job"]
    jobs = required_jobs(contract)

    def result_of(job):
        entry = needs.get(job)
        return entry.get("result") if isinstance(entry, dict) else None

    rows = []
    classifier_result = result_of(classifier)
    record, record_problem = classification(contract, needs.get(classifier), run)
    if classifier not in needs:
        rows.append((classifier, "-", "-", "FAIL", "missing from the gate's needs"))
    elif classifier_result != "success":
        rows.append((classifier, "-", classifier_result or "-", "FAIL",
                     f"suite classification did not succeed ({classifier_result or 'no result reported'})"))
    elif record_problem:
        rows.append((classifier, "-", classifier_result, "FAIL", record_problem))
    else:
        rows.append((classifier, "-", classifier_result, "PASS", f"{record['mode']}: {record['reason']}"))
    if record_problem and classifier in needs:
        problems.append(record_problem)
    if classifier_result != "success":
        record = None  # A failed classifier's outputs never justify a skip.

    not_succeeded = [job for job in jobs if result_of(job) != "success"]
    for job in jobs:
        result = result_of(job)
        decision = record["suites"][job] if record else None
        if decision is None:
            selection = "unknown"
        else:
            selection = ("applicable: " if decision["applicable"] else "not applicable: ") + decision["reason"]
        if job not in needs:
            rows.append((job, selection, "-", "FAIL", "missing from the gate's needs"))
        elif result is None:
            rows.append((job, selection, "-", "FAIL", "no result reported"))
        elif result not in KNOWN_RESULTS:
            rows.append((job, selection, result, "FAIL", f"unknown result {result!r}"))
        elif result == "success":
            rows.append((job, selection, result, "PASS", ""))
        elif result == "skipped" and decision is not None and not decision["applicable"]:
            rows.append((job, selection, result, "NOT APPLICABLE", "deliberately not run; see the selection reason"))
        elif result == "skipped":
            detail = ("skipped although the classification selected it" if decision is not None
                      else "skipped without a valid not-applicable classification")
            upstream = [other for other in not_succeeded if other != job and result_of(other) != "skipped"]
            if classifier_result != "success":
                upstream.insert(0, classifier)
            if upstream:
                detail += f"; required jobs that did not succeed: {', '.join(upstream)}"
            rows.append((job, selection, result, "FAIL", detail))
        else:
            rows.append((job, selection, result, "FAIL", result))
    for job in sorted(set(needs) - set(jobs) - {classifier}):
        problems.append(f"job {job!r} is in the gate's needs but not in the required-suite contract")
    passed = not problems and all(row[3] in ("PASS", "NOT APPLICABLE") for row in rows)
    return passed, rows, problems


def cell(text):
    return str(text).replace("|", "\\|").replace("\n", " ")


def render(passed, rows, problems):
    lines = ["| Required job | Selection | Result | Verdict | Detail |", "| --- | --- | --- | --- | --- |"]
    lines += ["| " + " | ".join(cell(value) for value in row) + " |" for row in rows]
    lines += [""] + [f"- Gate problem: {problem}" for problem in problems]
    lines.append(f"Final coverage gate: {'PASS' if passed else 'FAIL'}")
    return "\n".join(lines) + "\n"


def main(environ=os.environ, contract_path=CONTRACT_PATH, out=sys.stdout):
    try:
        contract = load_contract(Path(contract_path).read_text())
    except (OSError, ContractError) as error:
        out.write(f"Final coverage gate: FAIL (contract: {error})\n")
        return 1
    run = {"event": environ.get("GITHUB_EVENT_NAME", ""), "run_id": environ.get("GITHUB_RUN_ID", ""),
           "sha": environ.get("GITHUB_SHA", "")}
    passed, rows, problems = evaluate(contract, environ.get("CI_GATE_NEEDS"), run)
    report = render(passed, rows, problems)
    out.write(report)
    summary = environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write("## Final coverage gate\n\n" + report)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
