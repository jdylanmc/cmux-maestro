#!/usr/bin/env python3
"""Bounded Foundation-only controls of the metadata stall diagnostic, not a hang repair proof."""
import argparse
import errno
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

MODES = ("complete", "stalled-clock", "polling-clock", "sampler-timeout",
         "sampler-exit-no-output", "sampler-exit-with-output", "sampler-timeout-no-output",
         "owned-living", "owned-result-before-task", "owned-task-received", "owned-exited",
         "sampling-complete-output", "sampling-complete-no-output", "sampling-forced-backstop",
         "sampling-spawn-failure",
         "diagnostic-cancel-pending", "diagnostic-cancel-returned", "diagnostic-lock-held")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def metadata_readiness(report):
    ready = report.get("metadataReadiness")
    require(report.get("metadataPID") is not None and isinstance(ready, dict),
            f"Metadata watchdog not-ready: {report}")
    return ready


def diagnostic_outcome(report, directory):
    outcome = report.get("diagnosticOutcome")
    require(outcome in ("complete", "diagnostic-incomplete"), f"Unmarked diagnostic report: {report}")
    require(report.get("samplerReaped") is True, f"Sampler cleanup unconfirmed: {report}")
    if report.get("samplerStarted") is False:
        status = report.get("sampleStatus")
        require("samplerPID" not in report and outcome == "complete"
                and isinstance(status, str) and status.startswith("failed:"),
                f"Sampler not-started evidence is contradictory: {report}")
    else:
        require(report.get("samplerStarted") is True
                and type(report.get("samplerPID")) is int and report["samplerPID"] > 1,
                f"Sampler identity unconfirmed: {report}")
    require(not list(directory.glob("stall.json.sb-*")), "Interrupted diagnostic temporary files remain")
    return outcome


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", required=True, type=Path)
    parser.add_argument("--results-root", required=True, type=Path)
    parser.add_argument("--force-diagnostic-backstop", action="store_true",
                        help="Hold sampling at its explicit boundary and request the backstop outcome.")
    parser.add_argument("--mode", action="append", choices=MODES,
                        help="Run only the selected finite controls; default runs every control.")
    args = parser.parse_args()
    directory = args.results_root / ("watchdog-" + uuid.uuid4().hex)
    directory.mkdir(parents=True)
    for mode in args.mode or MODES:
        output = directory / (mode + ".log")
        case = directory / mode
        release = None
        if mode.startswith("owned-") and mode != "owned-exited":
            case.mkdir()
            gate = case / "child-release"
            os.mkfifo(gate, 0o600)
            release = os.open(gate, os.O_RDWR | os.O_NONBLOCK)
        try:
            with output.open("w") as stream:
                command = [str(args.probe.resolve()), mode, str(case.resolve())]
                if args.force_diagnostic_backstop:
                    command.append("--force-diagnostic-backstop")
                result = subprocess.run(command,
                                        stdout=stream, stderr=subprocess.STDOUT,
                                        timeout=80 if mode.startswith("owned-") else 10)
        finally:
            if release is not None:
                os.write(release, b"release\n")
                os.close(release)
            for log in (output, case / "sampler-stderr.txt"):
                if log.exists():
                    print(log.read_text(), end="", flush=True)
        if mode == "complete":
            require(result.returncode == 0, output.read_text())
            require(not (case / "stall.json").exists(), "Finished observation must disarm the deadline.")
        else:
            require(result.returncode == 124, output.read_text())
            report = json.loads((case / "stall.json").read_text())
            outcome = diagnostic_outcome(report, case)
            if mode.startswith("owned-"):
                ready = metadata_readiness(report)
            if "samplerPID" in report:
                try:
                    os.kill(report["samplerPID"], 0)
                except ProcessLookupError:
                    pass
                else:
                    raise RuntimeError(f"Sampler was not reaped: {report}")
            require(report["pid"] > 1, report)
            # Release the owned fixture above, then observe exit without signaling
            # a PID whose unreaped ownership anchor ended with the probe.
            child = None if mode.startswith(("diagnostic-", "sampling-")) else int((case / "child.pid").read_text())
            deadline = time.monotonic() + 60
            while child is not None:
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    break
                require(time.monotonic() < deadline, f"Finite probe child {child} did not exit.")
                time.sleep(0.05)
            child_description = "no metadata child" if child is None else f"finite child {child} absent"
            sampler_description = (f"exact sampler {report['samplerPID']} reaped/absent"
                                   if "samplerPID" in report else "sampler never started")
            print(f"{sampler_description}; {child_description}.", flush=True)
            require(report["test"] == "MetadataWatchdogProbe/" + mode, report)
            require(report["phase"] == "negative-control/" + mode, report)
            minimum_samples = 0 if mode.startswith(("owned-", "diagnostic-", "sampling-")) else (2 if mode == "polling-clock" else 1)
            require(report["deadlineSamples"] >= minimum_samples, report)
            require(report["samplerReaped"] is True, report)
            if mode == "sampling-spawn-failure":
                require(report["samplerStarted"] is False, report)
            if mode == "sampling-forced-backstop" or args.force_diagnostic_backstop:
                require(outcome == "diagnostic-incomplete", report)
            if report["samplerStarted"] is False:
                require(not mode.startswith("sampling-complete-"), report)
                require(report.get("sample") is None and report.get("sampleReadError") is None, report)
                require(not (case / "sample.txt").exists(), report)
            elif outcome == "diagnostic-incomplete":
                require(not mode.startswith("sampling-complete-"), report)
                print(f"Metadata watchdog {mode}: diagnostic-incomplete; core and cleanup still required.", flush=True)
            elif mode.startswith("sampling-"):
                require(outcome == "complete" and report["sampleStatus"] == "exit-17", report)
                if mode == "sampling-complete-output":
                    require(report["sample"] == "synthetic-exit-17-sample\n", report)
                    require((case / "sample.txt").read_text() == report["sample"], report)
                    require(report.get("sampleReadError") is None, report)
                else:
                    require(report.get("sample") is None and "sample.txt" in report["sampleReadError"], report)
                    require(not (case / "sample.txt").exists(), report)
            elif mode.startswith(("sampler-", "owned-", "diagnostic-")):
                timed_out = mode in ("sampler-timeout", "sampler-timeout-no-output")
                require(report["sampleStatus"] == ("timed-out/signal-9" if timed_out else "exit-17"), report)
                require(int((case / "sampler.pid").read_text()) == report["samplerPID"], report)
                if mode.endswith("-no-output") or mode.startswith(("owned-", "diagnostic-")):
                    require(not (case / "sample.txt").exists(), report)
                    require(report.get("sample") is None, report)
                    require("sample.txt" in report.get("sampleReadError", ""), report)
                    require("Metadata stall sample read failed:" in output.read_text(), output.read_text())
                else:
                    expected = ("partial-sample-before-stall\n" if timed_out else "synthetic-exit-17-sample\n")
                    require(report["sample"] == expected, report)
                    require((case / "sample.txt").read_text() == report["sample"], report)
                    require(report.get("sampleReadError") is None, report)
            elif report["sampleStatus"] == "timed-out/signal-9":
                # The real `sample` profiler can exceed its bound on a loaded CI runner (run 38754230158).
                # The synthetic sampler-timeout modes above prove that path deterministically, so here we
                # require consistent watchdog evidence and drop only the stack-content check (owner: no flaky tests).
                print(f"Real sampler timed out in {mode}; stack content not asserted.", flush=True)
                if (case / "sample.txt").exists():
                    require((case / "sample.txt").read_text() == report.get("sample"), report)
                else:
                    require(report.get("sample") is None, report)
                    require("sample.txt" in report.get("sampleReadError", ""), report)
            else:
                require(report["sampleStatus"] == "exit-0", report)
                require("LocalCopilotSetupRunner.execute" in report["sample"], report["sample"])
                if mode == "stalled-clock":
                    require("MetadataWatchdogProbe" in report["sample"], report["sample"])
            if mode.startswith("owned-"):
                current = report["metadataAtStall"]
                require(report["metadataPID"] == child, report)
                require(ready["state"] == "living", report)
                require(ready["process"]["pid"] == ready["process"]["group"] == child, report)
                require(ready["process"]["parent"] == report["pid"], report)
                require(ready["groupState"] == "sequential-observation", report)
                require(ready["process"]["startSeconds"] > 0, report)
                returned = mode in ("owned-result-before-task", "owned-task-received")
                require(report["runnerMetadataReturned"] is returned, report)
                require(report["outerTaskValueReceived"] is (mode == "owned-task-received"), report)
                if returned or mode == "owned-exited":
                    require(current["state"] == "unknown-pid-query", report)
                    require(current["queryBytes"] != ready["queryBytes"], report)
                    require(current["queryError"] == errno.ESRCH, report)
                    require(current.get("members") is None, report)
                    wait = current["childWait"]
                    if mode == "owned-exited":
                        require(wait == {"result": 0, "error": 0, "pid": child, "code": 1, "status": 1}, report)
                    else:
                        require(wait["result"] == -1 and wait["error"] == errno.ECHILD, report)
                else:
                    require(current["state"] == "living", report)
                    require(current["process"]["startSeconds"] == ready["process"]["startSeconds"], report)
                    require(current["process"]["startMicroseconds"] == ready["process"]["startMicroseconds"], report)
                    require(current["groupState"] == "sequential-observation", report)
                if mode != "owned-exited":
                    stale = json.loads((case / "stale-identity.json").read_text())
                    require(stale == {"state": "identity-changed"}, stale)
                    incomplete = json.loads((case / "incomplete-group.json").read_text())
                    require(incomplete["groupState"] == "unknown-enumeration", incomplete)
                    require(incomplete.get("members") is None, incomplete)
            if mode.startswith("diagnostic-"):
                diagnostic = report.get("supervision")
                require(isinstance(diagnostic, dict), "Missing bounded supervision snapshot")
                require(diagnostic["version"] == 1, diagnostic)
                require(len(json.dumps(diagnostic).encode()) <= 8192, diagnostic)
                require(diagnostic["overflow"] is False, diagnostic)
                if mode == "diagnostic-lock-held":
                    require(diagnostic["availability"] == 1 and diagnostic["boundaries"] == [], diagnostic)
                else:
                    require(diagnostic["availability"] == 0, diagnostic)
                    cancel = diagnostic["boundaries"][0]
                    require(cancel["begin"] > 0, diagnostic)
                    require((cancel["end"] > cancel["begin"]) is (mode == "diagnostic-cancel-returned"), diagnostic)
                    # Another active lane must not erase the outstanding cancel call.
                    execute = diagnostic["boundaries"][2]
                    require(execute["begin"] > cancel["begin"] and execute["end"] == 0, diagnostic)
        print(f"Metadata watchdog {mode}: expected exit={result.returncode}; evidence={case}", flush=True)


if __name__ == "__main__":
    main()
