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
         "diagnostic-cancel-pending", "diagnostic-cancel-returned", "diagnostic-lock-held")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", required=True, type=Path)
    parser.add_argument("--results-root", required=True, type=Path)
    parser.add_argument("--mode", action="append", choices=MODES,
                        help="Run only the selected finite controls; default runs every control.")
    args = parser.parse_args()
    directory = args.results_root / ("watchdog-" + uuid.uuid4().hex)
    directory.mkdir(parents=True)
    for mode in args.mode or MODES:
        output = directory / (mode + ".log")
        case = directory / mode
        try:
            with output.open("w") as stream:
                result = subprocess.run([str(args.probe.resolve()), mode, str(case.resolve())],
                                        stdout=stream, stderr=subprocess.STDOUT, timeout=10)
        finally:
            for log in (output, case / "sampler-stderr.txt"):
                if log.exists():
                    print(log.read_text(), end="", flush=True)
        if mode == "complete":
            require(result.returncode == 0, output.read_text())
            require(not (case / "stall.json").exists(), "Finished observation must disarm the deadline.")
        else:
            require(result.returncode == 124, output.read_text())
            report = json.loads((case / "stall.json").read_text())
            try:
                os.kill(report["samplerPID"], 0)
            except ProcessLookupError:
                pass
            else:
                raise RuntimeError(f"Sampler was not reaped: {report}")
            require(report["pid"] > 1, report)
            # The failing host cannot perform normal cleanup. Its synthetic child
            # is finite; observe its exit before starting another test, never signal
            # a PID whose unreaped ownership anchor ended with the probe.
            child = None if mode.startswith("diagnostic-") else int((case / "child.pid").read_text())
            deadline = time.monotonic() + 12
            while child is not None:
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    break
                require(time.monotonic() < deadline, f"Finite probe child {child} did not exit.")
                time.sleep(0.05)
            print(f"Exact sampler {report['samplerPID']} reaped/absent; finite child {child} absent.", flush=True)
            require(report["test"] == "MetadataWatchdogProbe/" + mode, report)
            require(report["phase"] == "negative-control/" + mode, report)
            minimum_samples = 0 if mode == "owned-exited" or mode.startswith("diagnostic-") else (2 if mode == "polling-clock" else 1)
            require(report["deadlineSamples"] >= minimum_samples, report)
            require(report["samplerReaped"] is True, report)
            if mode.startswith(("sampler-", "owned-", "diagnostic-")):
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
            else:
                require(report["sampleStatus"] == "exit-0", report)
                require("LocalCopilotSetupRunner.execute" in report["sample"], report["sample"])
                if mode == "stalled-clock":
                    require("MetadataWatchdogProbe" in report["sample"], report["sample"])
            if mode.startswith("owned-"):
                ready = report["metadataReadiness"]
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
