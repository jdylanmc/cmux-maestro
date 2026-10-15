#!/usr/bin/env python3
"""Final CI coverage gate (#197).

Reads the GitHub Actions `needs` context (JSON in CI_GATE_NEEDS) and the
required-suite contract (scripts/ci-required-suites.json). Exits 0 only when
every required suite's job result is exactly `success`. Failure, cancellation,
an unexpected skip (including one caused by a failed upstream job), a missing
job or result, an unknown result, contract drift, or any not-applicable claim
blocks the gate.

The gate judges job results only. Each job enforces its own evidence: required
artifacts use `if-no-files-found: error`, and the integrated harness enforces
nonzero execution, coverage accounting and candidate/base attribution. A job
that loses that evidence fails, and the gate then fails with it.

Not-applicable suites (#194) are not supported yet. The optional
CI_GATE_CLASSIFICATION input is reserved for that classifier; any value it
carries is rejected, so a missing, failed or ambiguous classification can never
turn a skip green. Supporting it requires changing this evaluator, the contract
schema and their tests together.
"""
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
CONTRACT_PATH = Path(__file__).resolve().parent / "ci-required-suites.json"
KNOWN_RESULTS = {"success", "failure", "cancelled", "skipped"}
SUITE_KEYS = {"job", "purpose"}
CONTRACT_KEYS = {"version", "gate_job", "suites"}


class ContractError(ValueError):
    pass


def load_contract(text):
    try:
        contract = json.loads(text)
    except json.JSONDecodeError as error:
        raise ContractError(f"contract is not valid JSON: {error}") from None
    if not isinstance(contract, dict) or set(contract) != CONTRACT_KEYS:
        raise ContractError(f"contract must have exactly the keys {sorted(CONTRACT_KEYS)}")
    if contract["version"] != 1:
        raise ContractError("unsupported contract version")
    gate = contract["gate_job"]
    if not isinstance(gate, str) or not gate:
        raise ContractError("gate_job must be a nonempty string")
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
        jobs.append(job)
    if len(set(jobs)) != len(jobs):
        raise ContractError("duplicate required suite")
    return contract


def required_jobs(contract):
    return [suite["job"] for suite in contract["suites"]]


def classification_problem(raw):
    """Return why a not-applicable classification blocks the gate, or None if absent."""
    if raw is None or raw == "":
        return None
    try:
        record = json.loads(raw)
    except json.JSONDecodeError:
        return "classification is not valid JSON"
    if not isinstance(record, dict) or record.get("status") != "complete":
        return "classification is missing, failed or incomplete"
    return "not-applicable classification is not supported until #194 defines it"


def evaluate(contract, needs_text, classification=None):
    """Return (passed, rows, problems). rows: (job, result, verdict, detail)."""
    problems = []
    try:
        needs = json.loads(needs_text) if needs_text else None
    except json.JSONDecodeError:
        needs = None
    if not isinstance(needs, dict):
        problems.append("needs context is missing or not a JSON object")
        needs = {}
    jobs = required_jobs(contract)
    results = {}
    for job in jobs:
        entry = needs.get(job)
        results[job] = entry.get("result") if isinstance(entry, dict) else None
    not_succeeded = [job for job in jobs if results[job] != "success"]
    rows = []
    for job in jobs:
        result = results[job]
        if job not in needs:
            detail = "missing from the gate's needs"
        elif result is None:
            detail = "no result reported"
        elif result not in KNOWN_RESULTS:
            detail = f"unknown result {result!r}"
        elif result == "success":
            rows.append((job, result, "PASS", ""))
            continue
        elif result == "skipped":
            upstream = [other for other in not_succeeded if other != job and results[other] != "skipped"]
            detail = "skipped without a not-applicable classification"
            if upstream:
                detail += f"; required jobs that did not succeed: {', '.join(upstream)}"
        else:
            detail = result
        rows.append((job, result or "-", "FAIL", detail))
    for job in sorted(set(needs) - set(jobs)):
        problems.append(f"job {job!r} is in the gate's needs but not in the required-suite contract")
    problem = classification_problem(classification)
    if problem:
        problems.append(problem)
    passed = not problems and all(row[2] == "PASS" for row in rows)
    return passed, rows, problems


def render(passed, rows, problems):
    lines = ["| Required suite | Result | Verdict | Detail |", "| --- | --- | --- | --- |"]
    lines += [f"| {job} | {result} | {verdict} | {detail} |" for job, result, verdict, detail in rows]
    lines += [""] + [f"- Gate problem: {problem}" for problem in problems]
    lines.append(f"Final coverage gate: {'PASS' if passed else 'FAIL'}")
    return "\n".join(lines) + "\n"


def main(environ=os.environ, contract_path=CONTRACT_PATH, out=sys.stdout):
    try:
        contract = load_contract(Path(contract_path).read_text())
    except (OSError, ContractError) as error:
        out.write(f"Final coverage gate: FAIL (contract: {error})\n")
        return 1
    passed, rows, problems = evaluate(contract, environ.get("CI_GATE_NEEDS"),
                                      environ.get("CI_GATE_CLASSIFICATION"))
    report = render(passed, rows, problems)
    out.write(report)
    summary = environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write("## Final coverage gate\n\n" + report)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
