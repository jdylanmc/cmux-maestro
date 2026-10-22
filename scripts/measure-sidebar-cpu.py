#!/usr/bin/env python3
"""Read-only 60-second CPU observation for one explicitly selected extension PID."""
import argparse
import json
from pathlib import Path
import subprocess
import time


def ps(pid, fields):
    return subprocess.check_output(
        ["ps", "-p", str(pid), "-o", fields], text=True, timeout=10
    ).strip()


def cpu_seconds(value):
    parts = value.split(":")
    if len(parts) not in (2, 3):
        raise ValueError("Unexpected ps CPU TIME format")
    total = 0.0
    for part in parts:
        total = total * 60 + float(part)
    return total


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True, help="Exact production extension PID, selected by the operator")
    parser.add_argument("--output", type=Path, required=True, help="New private local evidence directory; do not upload sample.txt")
    args = parser.parse_args()
    if args.pid <= 1:
        parser.error("--pid must identify the extension, not a system process")
    start = ps(args.pid, "lstart=")
    if not start:
        raise RuntimeError("Selected process is unavailable")
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    began = time.monotonic()
    points = []
    try:
        for index in range(13):
            if index:
                time.sleep(max(0, began + index * 5 - time.monotonic()))
            if ps(args.pid, "lstart=") != start:
                raise RuntimeError("Selected process identity changed; measurement stopped")
            fields = ps(args.pid, "pid=,%cpu=,rss=,time=").split()
            if len(fields) != 4 or int(fields[0]) != args.pid:
                raise RuntimeError("Selected process became unavailable")
            point = {
                "elapsedSeconds": time.monotonic() - began,
                "reportedCPUPercent": float(fields[1]),
                "rssKiB": int(fields[2]),
                "cpuSeconds": cpu_seconds(fields[3]),
            }
            points.append(point)
            print(json.dumps(point), flush=True)
        elapsed = points[-1]["elapsedSeconds"] - points[0]["elapsedSeconds"]
        summary = {
            "pid": args.pid,
            "processStart": start,
            "intervalCPUPercent": 100 * (points[-1]["cpuSeconds"] - points[0]["cpuSeconds"]) / elapsed,
            "elapsedSeconds": elapsed,
            "rssRangeKiB": [min(p["rssKiB"] for p in points), max(p["rssKiB"] for p in points)],
        }
        subprocess.run(
            ["sample", str(args.pid), "5", "-file", str(args.output / "sample.txt")],
            check=True, timeout=20, stdout=subprocess.DEVNULL,
        )
        if ps(args.pid, "lstart=") != start:
            raise RuntimeError("Selected process changed during stack capture")
        (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary, indent=2))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        (args.output / "failure.txt").write_text(type(error).__name__ + ": measurement incomplete\n")
        raise
    finally:
        (args.output / "observations.json").write_text(json.dumps(points, indent=2) + "\n")


if __name__ == "__main__":
    main()
