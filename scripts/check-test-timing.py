#!/usr/bin/env python3
"""Reject new timing-sensitive test statements; reviewed exceptions are exact, counted statements."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "scripts/test-timing-allowlist.json"
PATTERN = re.compile(
    r"(?:Task|Thread|time)\s*\.\s*sleep\s*\("
    r"|(?:setTimeout|setInterval|delay|usleep|XCTWaiter)\s*\("
    r"|(?:^|[;&|]\s*)\s*sleep\s+[^\n;&|]+"
    r"|DispatchTime\s*\.\s*now\s*\("
    r"|(?:ContinuousClock|Date)\s*\.\s*now\b"
    r"|\.duration\s*\(\s*to\s*:"
    r"|\.timeIntervalSince\s*\("
    r"|#(?:expect|require)\s*\([^\n]*\b(?:elapsed|duration)\b"
    r"|\bassert(?:Less|Greater)(?:Equal)?\s*\([^\n]*(?:elapsed|duration|time\.)"
    r"|\bisKeyWindow\b"
    r"|\bVNRecognizeTextRequest\b"
    r"|\b(?:time\.(?:monotonic|time)|Date\.now)\s*\("
    r"|\b(?:RunLoop\.[\w.]+\.run|Thread\.sleep)\s*\("
    r"|\b(?:asyncAfter|sleep)\s*\(",
    re.MULTILINE,
)


def test_path(path):
    value = Path(path)
    return (value.suffix in {".swift", ".py", ".mjs", ".sh"}
            and (any(part.endswith("Tests") for part in value.parts[:-1])
                 or value.name.startswith("test-") or value.name.endswith("Tests.swift")
                 or ("scripts" in value.parts and "Test" in value.name)))


def statements(text):
    """Retain the complete affected line(s), not only the API name or a mutable line number."""
    result = Counter()
    spans = set()
    for match in PATTERN.finditer(text):
        start = text.rfind("\n", 0, match.start()) + 1
        end = text.find("\n", match.end())
        if end < 0:
            end = len(text)
        spans.add((start, end))
    for start, end in sorted(spans):
        statement = " ".join(text[start:end].split())
        if not statement.startswith(("//", "# ", "#!", "*")):
            result[statement] += 1
    return result


def violations(root, paths, policy):
    errors = []
    for name in paths:
        if not test_path(name):
            continue
        found = statements((root / name).read_text())
        entry = policy.get(name, {})
        allowed = entry.get("statements", {})
        if entry and (not isinstance(entry.get("reason"), str) or not entry["reason"].strip()):
            errors.append(f"{name}: exception needs a review justification")
        for statement, count in found.items():
            if count > allowed.get(statement, 0):
                errors.append(f"{name}: unreviewed timing/venue dependency ({count} occurrences): {statement}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    policy = json.loads(POLICY.read_text())
    errors = violations(ROOT, [name for name in paths if name], policy)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        print("Use a controllable clock/barrier or explicit local acceptance. "
              "Exception changes require a per-statement review; never regenerate to make CI green.", file=sys.stderr)
        return 1
    print("Test timing policy passed: no new unreviewed sleeps, wall clocks, OCR or key-window dependencies.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
