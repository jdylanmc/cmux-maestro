#!/usr/bin/env python3
"""CI suite selection (#194).

Classifies the exact change set of a pull request run and decides, per required
suite in scripts/ci-required-suites.json, whether it applies. The reviewed map
is scripts/ci-suite-map.json: ordered rules of path globs; the first matching
rule decides a file's suites, and a file no rule matches selects every suite.

Every outcome is a complete record (a decision and a reason for every suite).
Anything other than a fully classified pull request selects every suite: a push
(only `main` pushes run CI), an unsupported event, a missing or malformed
base/head SHA, a checkout that is not the synthetic merge of exactly that base
and head, a git error, an empty change set, or an invalid map. A change to the
selection or gate files themselves also selects every suite, whatever the map says.

Outputs (GITHUB_OUTPUT): `classification` (the JSON record that ci-gate
verifies) and one `run_<job>` flag per suite, `true` or `false`. A validation
job is skipped only when its flag is `false` (case-insensitively, because GitHub
compares expression strings that way); the gate rejects any flag other than the
literal `false`. The step summary lists
the selected suites, the reasons and the classified files.

Exits nonzero only when the required-suite contract is unreadable; the job then
fails, the suites are skipped and ci-gate fails.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parent
CONTRACT_PATH = SCRIPTS / "ci-required-suites.json"
MAP_PATH = SCRIPTS / "ci-suite-map.json"
RECORD_VERSION = 1
SHA = re.compile(r"[0-9a-f]{40}")
RULE_KEYS = {"id", "paths", "suites", "reason"}
# Selection and gate files always select every suite, even if an edited map says otherwise.
FULL_COVERAGE_FLOOR = (".github/workflows/**", "scripts/ci-classify.py", "scripts/ci-suite-map.json",
                       "scripts/test-ci-classify.py", "scripts/ci-gate.py", "scripts/ci-required-suites.json",
                       "scripts/test-ci-gate.py")
SUMMARY_FILE_LIMIT = 300


class MapError(ValueError):
    pass


class GitError(RuntimeError):
    pass


def flag_name(job):
    return "run_" + job.replace("-", "_")


def glob_regex(pattern):
    """Git-style path glob: `**/` spans zero or more directories, `**` anything, `*` and `?` stay in one segment."""
    out, index = [], 0
    while index < len(pattern):
        if pattern.startswith("**/", index):
            out.append("(?:.*/)?")
            index += 3
        elif pattern.startswith("**", index):
            out.append(".*")
            index += 2
        elif pattern[index] == "*":
            out.append("[^/]*")
            index += 1
        elif pattern[index] == "?":
            out.append("[^/]")
            index += 1
        else:
            out.append(re.escape(pattern[index]))
            index += 1
    return re.compile("".join(out) + r"\Z", re.DOTALL)


def matches(pattern, path):
    return glob_regex(pattern).match(path) is not None


def load_suites(text):
    contract = json.loads(text)
    jobs = [suite["job"] for suite in contract["suites"]]
    if not jobs or not all(isinstance(job, str) and job for job in jobs) or len(set(jobs)) != len(jobs):
        raise ValueError("contract suites must be unique nonempty job ids")
    return jobs


def load_map(text, suites):
    try:
        data = json.loads(text)
    except json.JSONDecodeError as error:
        raise MapError(f"suite map is not valid JSON: {error}") from None
    if not isinstance(data, dict) or set(data) != {"version", "rules"} or data["version"] != 1:
        raise MapError("suite map must be {version: 1, rules: [...]}")
    rules, ids = [], set()
    if not isinstance(data["rules"], list) or not data["rules"]:
        raise MapError("suite map needs at least one rule")
    for rule in data["rules"]:
        if not isinstance(rule, dict) or set(rule) != RULE_KEYS:
            raise MapError(f"each rule must have exactly the keys {sorted(RULE_KEYS)}")
        if not isinstance(rule["id"], str) or not rule["id"] or rule["id"] in ids:
            raise MapError("rule ids must be unique nonempty strings")
        ids.add(rule["id"])
        if (not isinstance(rule["paths"], list) or not rule["paths"]
                or not all(isinstance(path, str) and path and not path.startswith("/") for path in rule["paths"])):
            raise MapError(f"rule {rule['id']}: paths must be nonempty relative globs")
        if not isinstance(rule["reason"], str) or not rule["reason"].strip():
            raise MapError(f"rule {rule['id']}: reason is required")
        selected = rule["suites"]
        if selected == "all":
            selected = list(suites)
        elif not isinstance(selected, list) or len(set(selected)) != len(selected) or set(selected) - set(suites):
            raise MapError(f"rule {rule['id']}: suites must be 'all' or a list of required suites")
        rules.append({**rule, "suites": [job for job in suites if job in selected]})
    return rules


def classify_paths(paths, rules, suites):
    """Return (per-file rows, per-suite decisions). Unmapped and floor files select every suite."""
    rows = []
    for path in paths:
        if any(matches(pattern, path) for pattern in FULL_COVERAGE_FLOOR):
            rows.append((path, "ci-selection-and-gate", list(suites)))
            continue
        rule = next((rule for rule in rules if any(matches(pattern, path) for pattern in rule["paths"])), None)
        rows.append((path, rule["id"], rule["suites"]) if rule else (path, "unmapped", list(suites)))
    decisions = {}
    for job in suites:
        selecting = {}
        for path, rule_id, selected in rows:
            if job in selected:
                selecting.setdefault(rule_id, []).append(path)
        if selecting:
            reason = "; ".join(f"{rule_id}: {len(files)} file(s), e.g. {files[0]}"
                               for rule_id, files in selecting.items())
            decisions[job] = {"applicable": True, "reason": reason}
        else:
            matched = sorted({rule_id for _, rule_id, _ in rows})
            decisions[job] = {"applicable": False,
                              "reason": "no changed file maps to it; files matched only: " + ", ".join(matched)}
    return rows, decisions


def run_git(*args):
    try:
        result = subprocess.run(["git", *args], capture_output=True, check=False)
    except OSError as error:
        raise GitError(f"git could not run: {error}") from None
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip().splitlines()
        raise GitError(f"git {args[0]} failed ({result.returncode}): {detail[0] if detail else 'no output'}")
    return result.stdout


def changed_files(git, base, head, sha):
    """Every path that differs between base and the tested merge, or that head changed since the merge base."""
    if git("rev-parse", "HEAD").decode().strip() != sha:
        raise GitError("checkout HEAD is not the run's commit")
    parents = git("rev-list", "--parents", "-n", "1", "HEAD").decode().split()
    if parents != [sha, base, head]:
        raise GitError("checkout is not the synthetic merge of exactly this base and head")
    paths = set()
    for revisions in ((base, sha), (f"{base}...{head}",)):
        output = git("diff", "--no-renames", "--name-only", "-z", *revisions, "--")
        paths.update(path.decode("utf-8", "surrogateescape") for path in output.split(b"\0") if path)
    return sorted(paths)


def full_record(context, suites, reason, changed=None):
    return {**context, "mode": "full", "reason": reason, "changed_files": changed,
            "suites": {job: {"applicable": True, "reason": reason} for job in suites}}


def build_record(environ, suites, map_text, git=run_git):
    """Return (record, per-file rows). Always a complete record; any doubt selects every suite."""
    event = environ.get("GITHUB_EVENT_NAME", "")
    base = environ.get("CI_CLASSIFY_BASE", "")
    head = environ.get("CI_CLASSIFY_HEAD", "")
    sha = environ.get("GITHUB_SHA", "")
    context = {"version": RECORD_VERSION, "complete": True, "event": event,
               "run_id": environ.get("GITHUB_RUN_ID", ""), "sha": sha,
               "base": base or None, "head": head or None}
    if event == "push":
        return full_record(context, suites, "push to main: full validation"), []
    if event != "pull_request":
        return full_record(context, suites, f"unsupported event {event!r}: full validation"), []
    if not all(SHA.fullmatch(value) for value in (base, head, sha)):
        return full_record(context, suites, "base, head or run SHA is missing or malformed: full validation"), []
    try:
        rules = load_map(map_text, suites)
    except MapError as error:
        return full_record(context, suites, f"suite map invalid ({error}): full validation"), []
    try:
        paths = changed_files(git, base, head, sha)
    except GitError as error:
        return full_record(context, suites, f"change set unavailable ({error}): full validation"), []
    if not paths:
        return full_record(context, suites, "empty change set: nothing to classify, full validation", 0), []
    rows, decisions = classify_paths(paths, rules, suites)
    selective = not all(decision["applicable"] for decision in decisions.values())
    record = {**context, "mode": "selective" if selective else "full",
              "reason": f"classified {len(paths)} changed file(s) with scripts/ci-suite-map.json",
              "changed_files": len(paths), "suites": decisions}
    return record, rows


def cell(text):
    return str(text).replace("\\", "\\\\").replace("|", "\\|").replace("\n", " ").replace("\r", " ")


def render(record, rows):
    lines = [f"Mode: **{record['mode']}**. {cell(record['reason'])}.", "",
             f"Event `{record['event']}`, run commit `{record['sha']}`, base `{record['base']}`, "
             f"head `{record['head']}`.", "",
             "| Suite | Selected | Reason |", "| --- | --- | --- |"]
    for job, decision in record["suites"].items():
        selected = "yes" if decision["applicable"] else "no (not applicable)"
        lines.append(f"| {job} | {selected} | {cell(decision['reason'])} |")
    if rows:
        lines += ["", "| Changed file | Rule | Suites |", "| --- | --- | --- |"]
        for path, rule_id, selected in rows[:SUMMARY_FILE_LIMIT]:
            lines.append(f"| {cell(path)} | {rule_id} | {', '.join(selected) or 'none'} |")
        if len(rows) > SUMMARY_FILE_LIMIT:
            lines.append(f"\n{len(rows) - SUMMARY_FILE_LIMIT} more file(s) not listed; the record counts all.")
    return "\n".join(lines) + "\n"


def main(environ=os.environ, contract_path=CONTRACT_PATH, map_path=MAP_PATH, git=run_git, out=sys.stdout):
    try:
        suites = load_suites(Path(contract_path).read_text())
    except (OSError, ValueError, KeyError, TypeError) as error:
        out.write(f"Suite classification: FAIL (required-suite contract unreadable: {error})\n")
        return 1
    try:
        map_text = Path(map_path).read_text()
    except OSError as error:
        map_text = f"unreadable: {error}"
    record, rows = build_record(environ, suites, map_text, git)
    report = render(record, rows)
    out.write(report)
    output = environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as handle:
            handle.write("classification=" + json.dumps(record, separators=(",", ":")) + "\n")
            for job, decision in record["suites"].items():
                handle.write(f"{flag_name(job)}={'true' if decision['applicable'] else 'false'}\n")
    summary = environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write("## Suite selection\n\n" + report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
