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
    r"|(?:^|[;&|({`!]|\b(?:do|then|else|if|while|until)\b)\s*sleep\s+[^\n;&|]+"
    r"|DispatchTime\s*\.\s*now\s*\("
    r"|(?:ContinuousClock|SuspendingClock)(?:\s*\(\s*\))?\s*\.\s*now\b"
    r"|Date\s*\.\s*now\b"
    r"|(?<!\w)\.now\b|Date\s*\(\s*(?:\)|timeIntervalSinceNow\s*:)"
    r"|CFAbsoluteTimeGetCurrent\s*\("
    r"|\b(?:fulfillment|wait)\s*\(\s*(?:of|for)\s*:"
    r"|\bwaitForExpectations\s*\(\s*timeout\s*:"
    r"|\b(?:performance\s*\.\s*now|process\s*\.\s*hrtime(?:\s*\.\s*bigint)?"
    r"|AbortSignal\s*\.\s*timeout)\s*\("
    r"|\bdatetime(?:\s*\.\s*datetime)?\s*\.\s*(?:now|utcnow)\s*\("
    r"|\.duration\s*\(\s*to\s*:"
    r"|\.timeIntervalSince\s*\("
    r"|#(?:expect|require)\s*\([^\n]*\b(?:elapsed|duration)\b"
    r"|\bassert(?:Less|Greater)(?:Equal)?\s*\([^\n]*(?:elapsed|duration|time\.)"
    r"|\bisKeyWindow\b"
    r"|\bVNRecognizeTextRequest\b"
    r"|\b(?:time\s*\.\s*(?:monotonic(?:_ns)?|perf_counter(?:_ns)?|time(?:_ns)?)|Date\.now)\s*\("
    r"|\b(?:RunLoop\.[\w.]+\.run|Thread\.sleep)\s*\("
    r"|\b(?:asyncAfter|sleep)\s*\(",
    re.MULTILINE,
)


def test_path(path):
    value = Path(path)
    return (value.suffix in {".swift", ".py", ".mjs", ".js", ".cjs", ".ts", ".tsx", ".sh"}
            and (any(part.lower().endswith("tests") or part == "test-fixtures" for part in value.parts[:-1])
                 or value.name.startswith(("test-", "test_"))
                 or value.stem.endswith(("Tests", ".test", ".spec"))
                 or ("scripts" in value.parts and "Test" in value.name)))


def regex_end(text, start):
    """Read regex bodies without counting escaped or character-class parentheses."""
    bracket = False
    index = start + 1
    while index < len(text) and text[index] != "\n":
        char = text[index]
        if char == "\\":
            index += 2
            continue
        if char == "[":
            bracket = True
        elif char == "]":
            bracket = False
        elif char == "/" and not bracket:
            return index + 1
        index += 1
    return None


def statement_end(text, start, minimum, path):
    """Continue past newlines inside call arguments, including nested callbacks."""
    depth = 0
    quote = None
    block_comment = 0
    suffix = Path(path).suffix
    hash_comments = suffix in {"", ".py", ".sh"}
    slash_comments = suffix not in {".py", ".sh"}
    regex_literals = suffix in {"", ".js", ".mjs", ".cjs", ".ts", ".tsx"}
    regex_allowed = True
    pending_control = False
    paren_controls = []
    brace_blocks = []
    last_token = ""
    index = start
    while index < len(text):
        char = text[index]
        if quote:
            if char == "\\":
                index += 2
                continue
            if text.startswith(quote, index):
                index += len(quote)
                quote = None
                regex_allowed = False
                last_token = "value"
                continue
        elif block_comment:
            if text.startswith("/*", index):
                block_comment += 1
                index += 2
                continue
            elif text.startswith("*/", index):
                block_comment -= 1
                index += 2
                continue
        elif (slash_comments and text.startswith("//", index)) or (hash_comments and char == "#"):
            newline = text.find("\n", index)
            index = len(text) if newline < 0 else newline
            if index >= minimum and depth == 0:
                return index
            continue
        elif slash_comments and text.startswith("/*", index):
            block_comment = 1
            index += 2
            continue
        elif regex_literals and regex_allowed and char == "/" and (end := regex_end(text, index)) is not None:
            index = end
            regex_allowed = False
            last_token = "value"
            continue
        elif char in "\"'`":
            quote = char * 3 if text.startswith(char * 3, index) else char
            index += len(quote)
            continue
        elif regex_literals and (char.isalnum() or char in "_$"):
            end = index + 1
            while end < len(text) and (text[end].isalnum() or text[end] in "_$"):
                end += 1
            word = text[index:end]
            keyword = last_token not in {".", "?."}
            pending_control = keyword and (
                word in {"if", "while", "for", "with", "switch", "catch"}
                or (pending_control and word == "await")
            )
            regex_allowed = keyword and word in {
                "return", "throw", "case", "delete", "void", "typeof", "instanceof",
                "in", "of", "yield", "await", "else", "do",
            }
            last_token = word
            index = end
            continue
        elif regex_literals and text.startswith("=>", index):
            regex_allowed = True
            last_token = "=>"
            index += 2
            continue
        elif regex_literals and text[index:index + 2] in {"++", "--"}:
            last_token = text[index:index + 2]
            index += 2
            continue
        elif char == "(":
            depth += 1
            paren_controls.append(pending_control)
            pending_control = False
            regex_allowed = True
            last_token = char
        elif char == ")":
            depth = max(0, depth - 1)
            regex_allowed = paren_controls.pop() if paren_controls else False
            last_token = char
        elif regex_literals and char == "{":
            brace_blocks.append(last_token not in {"=", "(", ",", "[", ":", "return", "yield"})
            regex_allowed = True
            last_token = char
        elif regex_literals and char == "}":
            regex_allowed = brace_blocks.pop() if brace_blocks else True
            last_token = char
        elif char == "\n" and index >= minimum and depth == 0:
            return index
        elif regex_literals and not char.isspace():
            regex_allowed = char in "=,;:!?&|+*-/%^~<>["
            last_token = char
        index += 1
    return len(text)


def statements(text, path=""):
    """Fingerprint whole affected statements, not just the first line of a call."""
    result = Counter()
    spans = set()
    for match in PATTERN.finditer(text):
        start = text.rfind("\n", 0, match.start()) + 1
        end = statement_end(text, start, match.end(), path)
        spans.add((start, end))
    for start, end in sorted(spans):
        statement = " ".join(text[start:end].split())
        if not statement.startswith(("//", "# ", "#!", "*")):
            result[statement] += 1
    return result


def violations(root, paths, policy):
    errors = []
    selected = {name for name in paths if test_path(name)}
    for name in sorted(set(policy) - selected):
        errors.append(f"{name}: stale exception for an absent or unscanned test source")
    for name in sorted(selected):
        found = statements((root / name).read_text(), name)
        entry = policy.get(name, {})
        allowed = entry.get("statements", {})
        if entry and (not isinstance(entry.get("reason"), str) or not entry["reason"].strip()):
            errors.append(f"{name}: exception needs a review justification")
        for statement, count in found.items():
            if count > allowed.get(statement, 0):
                errors.append(f"{name}: unreviewed timing/venue dependency ({count} occurrences): {statement}")
        for statement, count in allowed.items():
            if type(count) is not int or count <= 0:
                errors.append(f"{name}: exception count must be a positive integer: {statement}")
            elif count > found.get(statement, 0):
                errors.append(f"{name}: stale/excess exception ({count} allowed, "
                              f"{found.get(statement, 0)} present): {statement}")
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
