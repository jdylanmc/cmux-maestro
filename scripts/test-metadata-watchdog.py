#!/usr/bin/env python3
"""Bounded Foundation-only controls of the metadata stall diagnostic, not a hang repair proof."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import uuid


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", required=True, type=Path)
    parser.add_argument("--results-root", required=True, type=Path)
    args = parser.parse_args()
    directory = args.results_root / ("watchdog-" + uuid.uuid4().hex)
    directory.mkdir(parents=True)
    for mode in ("complete", "stalled-clock", "polling-clock", "sampler-timeout"):
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
            require(report["phase"] == "negative-control/" + mode, report)
            require(report["deadlineSamples"] >= (2 if mode == "polling-clock" else 1), report)
            require(report["samplerReaped"] is True, report)
            if mode == "sampler-timeout":
                require(report["sampleStatus"] == "timed-out/signal-9", report)
                require(report["sample"] == "partial-sample-before-stall\n", report)
                require((case / "sample.txt").read_text() == report["sample"], report)
                require(int((case / "sampler.pid").read_text()) == report["samplerPID"], report)
            else:
                require(report["sampleStatus"] == "exit-0", report)
                require("LocalCopilotSetupRunner.execute" in report["sample"], report["sample"])
                if mode == "stalled-clock":
                    require("MetadataWatchdogProbe" in report["sample"], report["sample"])
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
            child = int((case / "child.pid").read_text())
            deadline = time.monotonic() + 12
            while True:
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    break
                require(time.monotonic() < deadline, f"Finite probe child {child} did not exit.")
                time.sleep(0.05)
        print(f"Metadata watchdog {mode}: expected exit={result.returncode}; evidence={case}", flush=True)


if __name__ == "__main__":
    main()
