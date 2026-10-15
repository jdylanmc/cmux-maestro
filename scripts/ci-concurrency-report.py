#!/usr/bin/env python3
"""Read-only CI concurrency report for runner placement (#191).

Reads Actions runs and jobs for every listed repository through `gh api` (no writes) and prints:
simultaneous macOS jobs across those repositories (GitHub limits macOS concurrency per account), the
time spent at each level, and each macOS job's queue delay against the most macOS jobs active while
it waited. Queue delay is job started_at minus created_at; execution is completed_at minus started_at.
Jobs reused by a re-run (started before they were created) are excluded, and jobs that never got a
runner are not counted as active. Figures change as GitHub ages out old runs.

Example (the window in docs/reference/ci-runner-placement.md):

    GH_TOKEN="$(gh auth token --user jdylanmc)" python3 scripts/ci-concurrency-report.py \\
        --owner jdylanmc --repo cmux-maestro --repo pr-sniper --repo homebrew-pr-sniper \\
        --since 2026-10-14 --until 2026-10-15T11:40:46Z
"""
import argparse
import collections
import datetime
import json
import subprocess
import sys


def gh(path):
    """Every page of a GET, as a list of parsed JSON pages."""
    output = subprocess.run(["gh", "api", "--paginate", "--slurp", path], check=True, capture_output=True, text=True)
    return json.loads(output.stdout)


def when(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def runner_os(labels):
    for label in labels:
        for prefix, name in (("macos", "macOS"), ("ubuntu", "Linux"), ("windows", "Windows")):
            if label.startswith(prefix):
                return name
    return "other"


def collect(owner, repo, since):
    jobs = []
    for page in gh(f"repos/{owner}/{repo}/actions/runs?created=>={since}&per_page=100"):
        for run in page["workflow_runs"]:
            for attempt in range(1, run["run_attempt"] + 1):
                path = f"repos/{owner}/{repo}/actions/runs/{run['id']}/attempts/{attempt}/jobs?per_page=100"
                for job_page in gh(path):
                    for job in job_page["jobs"]:
                        created, started, completed = (when(job.get(key)) for key in
                                                       ("created_at", "started_at", "completed_at"))
                        if started and started < created:
                            continue
                        jobs.append({"repo": repo, "run": run["id"], "attempt": attempt, "name": job["name"],
                                     "os": runner_os(job.get("labels", [])), "created": created,
                                     "started": started, "completed": completed,
                                     "runner": job.get("runner_name"), "conclusion": job.get("conclusion")})
    return jobs


def report(jobs, until, primary):
    executed = [job for job in jobs if job["runner"] and job["started"] and job["completed"]
                and job["completed"] > job["started"] and (until is None or job["completed"] <= until)]
    mac = [job for job in executed if job["os"] == "macOS"]
    if not mac:
        print("No completed macOS jobs in the window.")
        return
    print(f"Window: {min(job['started'] for job in mac):%Y-%m-%d %H:%M}Z to "
          f"{max(job['completed'] for job in mac):%Y-%m-%d %H:%M}Z")
    print("macOS jobs executed:", dict(collections.Counter(job["repo"] for job in mac)))
    print("macOS execution minutes:", {repo: round(sum((job["completed"] - job["started"]).total_seconds()
                                                       for job in mac if job["repo"] == repo) / 60, 1)
                                       for repo in sorted({job["repo"] for job in mac})})

    def active(moment):
        return [job for job in mac if job["started"] <= moment < job["completed"]]

    points = sorted({job["started"] for job in mac} | {job["completed"] for job in mac})
    levels, at_peak = collections.Counter(), collections.Counter()
    peak = max(len(active(moment)) for moment in points)
    for start, end in zip(points, points[1:]):
        running = active(start)
        minutes = (end - start).total_seconds() / 60
        levels[len(running)] += minutes
        if len(running) == peak:
            for job in running:
                at_peak[job["repo"]] += minutes
    print(f"\nMaximum simultaneous macOS jobs: {peak}")
    print("| Simultaneous macOS jobs | Minutes |\n| --- | --- |")
    for level in sorted(levels):
        print(f"| {level} | {levels[level]:.0f} |")
    print("Slot-minutes at the maximum, by repository:", {repo: round(value) for repo, value in at_peak.items()})

    buckets = collections.defaultdict(list)
    print(f"\n{primary} macOS jobs queued over one minute:")
    for job in sorted((job for job in mac if job["repo"] == primary), key=lambda job: job["created"]):
        queue = (job["started"] - job["created"]).total_seconds() / 60
        samples = [job["created"] + datetime.timedelta(seconds=15 * index) for index in range(max(1, int(queue * 4)))]
        most = max(len(active(moment)) for moment in samples)
        buckets[most].append(queue)
        if queue > 1:
            print(f"  run {job['run']} attempt {job['attempt']} {job['name']}: {queue:.1f} min "
                  f"(most active while waiting: {most})")
    print("\n| Most active while waiting | Jobs | Median queue (min) | Longest queue (min) |\n| --- | --- | --- | --- |")
    for most in sorted(buckets):
        values = sorted(buckets[most])
        print(f"| {most} | {len(values)} | {values[len(values) // 2]:.1f} | {values[-1]:.1f} |")
    linux = [job for job in executed if job["os"] == "Linux" and job["repo"] == primary]
    if linux:
        queues = sorted((job["started"] - job["created"]).total_seconds() for job in linux)
        print(f"\n{primary} Linux jobs: {len(linux)}, queue {queues[0]:.0f}-{queues[-1]:.0f} s")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--repo", action="append", required=True,
                        help="Repository sharing the account's runners; the first is reported in detail.")
    parser.add_argument("--since", required=True, help="Runs created on or after this date (YYYY-MM-DD).")
    parser.add_argument("--until", help="Ignore jobs completed after this UTC time (ISO 8601).")
    args = parser.parse_args(argv)
    jobs = [job for repo in args.repo for job in collect(args.owner, repo, args.since)]
    report(jobs, when(args.until), args.repo[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
