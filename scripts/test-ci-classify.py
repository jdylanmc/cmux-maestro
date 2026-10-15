#!/usr/bin/env python3
import importlib.util
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import unittest
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ci_classify", ROOT / "scripts/ci-classify.py")
classify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(classify)
gate_spec = importlib.util.spec_from_file_location("ci_gate", ROOT / "scripts/ci-gate.py")
gate = importlib.util.module_from_spec(gate_spec)
gate_spec.loader.exec_module(gate)

SUITES = classify.load_suites(classify.CONTRACT_PATH.read_text())
MAP_TEXT = classify.MAP_PATH.read_text()
NATIVE, CONTRACTS, PROBE = "validate-native", "validate-contracts", "guide-ui-consumer-probe"
BASE, HEAD, MERGE = "b" * 40, "c" * 40, "a" * 40


def environ(event="pull_request", base=BASE, head=HEAD, sha=MERGE):
    return {"GITHUB_EVENT_NAME": event, "CI_CLASSIFY_BASE": base, "CI_CLASSIFY_HEAD": head,
            "GITHUB_SHA": sha, "GITHUB_RUN_ID": "7"}


def fake_git(paths, parents=None, head_sha=MERGE, fail=None, links=()):
    """A git stand-in for one synthetic merge: HEAD, its parents, the diff and tracked symlinks."""
    blobs = {f"{index:040x}": target for index, (_, target) in enumerate(links)}

    def git(*args):
        if fail and args[0] == fail:
            raise classify.GitError(f"git {fail} failed (128): fatal: bad object")
        if args[0] == "rev-parse":
            return (head_sha + "\n").encode()
        if args[0] == "rev-list":
            return (" ".join(parents or [MERGE, BASE, HEAD]) + "\n").encode()
        if args[0] == "diff":
            return b"".join(path.encode() + b"\0" for path in paths)
        if args[0] == "ls-tree":
            entries = [f"100644 blob {'e' * 40}\tREADME.md"]
            entries += [f"120000 blob {oid}\t{path}" for oid, (path, _) in zip(blobs, links)]
            return "\0".join(entries).encode() + b"\0"
        if args[0] == "cat-file":
            return blobs[args[2]].encode()
        raise AssertionError(args)
    return git


def applicable(record):
    return {job for job, decision in record["suites"].items() if decision["applicable"]}


class GlobTests(unittest.TestCase):
    def test_glob_semantics(self):
        cases = [("docs/**/*.md", "docs/a.md", True), ("docs/**/*.md", "docs/x/y/a.md", True),
                 ("docs/**/*.md", "docs/a.md.swift", False), ("docs/**/*.md", "docsx/a.md", False),
                 ("docs/**/*.md", "docs/a.MD", False), ("README.md", "skills/README.md", False),
                 ("README.md", "README.md", True), ("docs/**", "docs/a/b.png", True),
                 ("docs/**", "docs", False), ("scripts/test-beats.py", "scripts/test-beatsXpy", False),
                 (".github/workflows/**", ".github/workflows/ci.yml", True),
                 ("docs/*.md", "docs/a/b.md", False), ("docs/?.md", "docs/a.md", True)]
        for pattern, path, expected in cases:
            with self.subTest(pattern=pattern, path=path):
                self.assertEqual(classify.matches(pattern, path), expected)


class MapTests(unittest.TestCase):
    def test_checked_in_map_loads_and_names_only_required_suites(self):
        rules = classify.load_map(MAP_TEXT, SUITES)
        self.assertEqual(rules[0]["id"], "ci-selection-and-gate")
        self.assertEqual(rules[0]["suites"], SUITES)
        self.assertEqual(set(rules[0]["paths"]), set(classify.FULL_COVERAGE_FLOOR))

    def test_invalid_maps_refuse(self):
        rule = {"id": "r", "paths": ["docs/**"], "suites": [CONTRACTS], "reason": "x"}
        for data in ("{", [], {"version": 2, "rules": [rule]}, {"version": 1, "rules": []},
                     {"version": 1, "rules": [rule], "default": "none"},
                     {"version": 1, "rules": [dict(rule, suites=["unknown-suite"])]},
                     {"version": 1, "rules": [dict(rule, suites="none")]},
                     {"version": 1, "rules": [dict(rule, suites=[CONTRACTS, CONTRACTS])]},
                     {"version": 1, "rules": [dict(rule, paths=[])]},
                     {"version": 1, "rules": [dict(rule, paths=["/docs/**"])]},
                     {"version": 1, "rules": [dict(rule, reason=" ")]},
                     {"version": 1, "rules": [rule, rule]},
                     {"version": 1, "rules": [dict(rule, extra=1)]}):
            with self.subTest(data=data):
                with self.assertRaises(classify.MapError):
                    classify.load_map(data if isinstance(data, str) else json.dumps(data), SUITES)

    def test_bundled_and_shared_inputs_are_not_mapped_as_documentation(self):
        # Packaged inputs (Xcode resources, the guide fingerprint source, bundled skills and scripts)
        # and shared fixtures must select every suite.
        rules = classify.load_map(MAP_TEXT, SUITES)
        project = (ROOT / "CMUXMaestroPreview.xcodeproj/project.pbxproj").read_text()
        for path in ("skills/maestro/SKILL.md", "skills/maestro/intent.md",
                     ".agents/skills/cmux-maestro-orchestrate/SKILL.md", ".agents/skills/maestro-pet/SKILL.md",
                     ".agents/skills/maestro-icon/SKILL.md", ".agents/THIRD_PARTY_NOTICES.md",
                     "scripts/delivery-proof/adapter.mjs", "scripts/cmux-maestro-orchestrator.py",
                     "scripts/write-guide-reference.py", "scripts/test-fixtures/beats-store-cases.json",
                     "scripts/test-build-metadata.py", "scripts/test-guide-ui-validation.py", "scripts/test.sh",
                     "Resources/NerdFonts/x.ttf", "CMUXMaestroSidebar/UI/SidebarView.swift",
                     "CMUXMaestroPreview.xcodeproj/project.pbxproj", "skills-lock.json", ".gitignore",
                     ".github/extensions/maestro-delivery-proof/extension.mjs", "docs.md", "Docs/a.md"):
            with self.subTest(path=path):
                self.assertEqual(classify.classify_paths([path], rules, SUITES)[0][0][2], SUITES)
        for path in ("skills/maestro/SKILL.md", ".agents/skills/maestro-icon", ".agents/skills/maestro-pet",
                     "scripts/delivery-proof/adapter.mjs", "scripts/cmux-maestro-orchestrator.py"):
            self.assertIn(path, project, "The bundled-input list above is out of date.")

    def test_edited_map_cannot_shrink_coverage_of_selection_files(self):
        loose = json.dumps({"version": 1, "rules": [
            {"id": "everything-is-docs", "paths": ["**"], "suites": [], "reason": "mutated"}]})
        rules = classify.load_map(loose, SUITES)
        for path in classify.FULL_COVERAGE_FLOOR:
            path = path.replace("**", "ci.yml")
            with self.subTest(path=path):
                self.assertEqual(classify.classify_paths([path], rules, SUITES)[0][0][1:],
                                 ("ci-selection-and-gate", SUITES))


PROJECT = ROOT / "CMUXMaestroPreview.xcodeproj/project.pbxproj"
PROBE = ROOT / "scripts/run-guide-ui-validation.py"
# Existing comments and docstrings that cite ADRs or a sibling suite; they are not file reads. Each
# must stay on a comment or docstring line.
COMMENT_PREFIXES = ("//", "#", '"""')
ALLOWED_DOC_REFERENCES = {
    ("CMUXMaestroSidebar/State/SidebarBeatsModel.swift", "docs/adr/0007"),
    ("CMUXMaestroSidebar/State/SidebarBeatsModel.swift", "docs/adr/0020"),
    ("scripts/cmux-maestro-orchestrator.py", "docs/adr/0007"),
    ("scripts/cmux-maestro-orchestrator.py", "docs/adr/0020"),
    ("CMUXMaestroPreviewTests/SidebarBeatsTests.swift", "test-beats.py"),
}


def pbxproj_inputs(text):
    """Every repository path the Xcode project names: path values, input paths and $SRCROOT references."""
    paths = {match.strip('"') for match in re.findall(r'\bpath = ("(?:[^"\\]|\\.)*"|[^;\s]+);', text)}
    for listing in re.findall(r"\binput(?:FileList)?Paths = \((.*?)\);", text, re.DOTALL):
        paths.update(item.strip().strip('"') for item in listing.split(",") if item.strip())
    paths.update(re.findall(r'\$\(?SRCROOT\)?/([^"\s\\;,]+)', text))
    cleaned = set()
    for path in paths:
        path = re.sub(r"^\$\(?SRCROOT\)?/", "", path).removeprefix("./")
        if path and "$" not in path:
            cleaned.add(path)
    return sorted(cleaned)


def probe_inventory(text):
    """The guide probe's explicit hashed source inventory (string literals in its `paths` set)."""
    block = text.split("for path in sources} | {", 1)[1].split("})", 1)[0]
    return re.findall(r'"([^"]+)"', block)


def narrower_inputs(paths, rules):
    """Inputs that, or whose directory contents, the map would send to fewer than every suite."""
    return [candidate for path in paths for candidate in (path, path.rstrip("/") + "/x")
            if classify.classify_paths([candidate], rules, SUITES)[0][0][2] != SUITES]


def narrower_needles(rules):
    """(regex, label) for every literal path or directory a narrower rule names."""
    needles = {}
    for rule in rules:
        if rule["suites"] == SUITES:
            continue
        for pattern in rule["paths"]:
            prefix = re.split(r"[*?]", pattern, 1)[0]
            if prefix != pattern:
                if not prefix.endswith("/"):
                    raise AssertionError(f"unsupported pattern for the source scan: {pattern}")
                directory = prefix.rstrip("/")
                needles[rf"(?<![A-Za-z0-9_.-]){re.escape(prefix)}[A-Za-z0-9_./-]*"] = prefix
                needles[rf"[\"']{re.escape(directory)}[\"']"] = directory
            else:
                for literal in {pattern, pattern.rsplit("/", 1)[-1]}:
                    needles[rf"(?<![A-Za-z0-9_.-]){re.escape(literal)}(?![A-Za-z0-9_-])"] = literal
    return needles


def doc_references(relative, text, rules):
    """Mentions of narrower-mapped paths in a native or probe source, minus the comment allow-list."""
    found = []
    lines = text.splitlines()
    for regex in narrower_needles(rules):
        for match in re.finditer(regex, text):
            token = match.group(0).rstrip(".")
            line = lines[text.count("\n", 0, match.start())].strip()
            if (relative, token) in ALLOWED_DOC_REFERENCES and line.startswith(COMMENT_PREFIXES):
                continue
            found.append((relative, token, line))
    return found


def native_and_probe_sources():
    """Native Swift sources plus every script test.sh, the probe and the Xcode build phases reach."""
    files = {path for directory in ROOT.glob("CMUXMaestro*") if directory.is_dir()
             for path in directory.rglob("*.swift")}
    pending = ["test.sh", "test-guide-ui-validation.sh", "run-guide-ui-validation.py",
               "test-guide-ui-validation.py", "fetch-sdk.sh"]
    pending += re.findall(r"scripts/([A-Za-z0-9_.-]+\.(?:py|sh|mjs|swift))", PROJECT.read_text())
    scanned = set()
    while pending:
        name = pending.pop()
        if name in scanned or not (ROOT / "scripts" / name).is_file():
            continue
        scanned.add(name)
        text = (ROOT / "scripts" / name).read_text()
        pending += re.findall(r'\$ROOT/scripts/([^"/\s]+\.(?:sh|py|mjs|swift))', text)
        pending += re.findall(r'spec_from_file_location\([^)]*"scripts/([^"/]+\.py)"\)', text)
        pending += re.findall(r'ROOT / "scripts" / "([^"/]+\.(?:py|sh|swift))"', text)
        pending += re.findall(r'with_name\("([^"]+\.py)"\)', text)
    files |= {ROOT / "scripts" / name for name in scanned}
    return sorted(files), scanned


class PackagedInputGuardTests(unittest.TestCase):
    """The map may narrow only paths that no build input, bundle resource or native/probe source reads."""

    def setUp(self):
        self.rules = classify.load_map(MAP_TEXT, SUITES)

    def test_every_xcode_project_input_selects_every_suite(self):
        inputs = pbxproj_inputs(PROJECT.read_text())
        for expected in ("skills/maestro/SKILL.md", "scripts/write-guide-reference.py", ".agents/skills/maestro-pet",
                         "scripts/delivery-proof/adapter.mjs", "CMUXMaestroSidebar"):
            self.assertIn(expected, inputs, "The project parser no longer sees a known input.")
        self.assertEqual(narrower_inputs(inputs, self.rules), [])

    def test_probe_hashed_inventory_selects_every_suite(self):
        inventory = probe_inventory(PROBE.read_text())
        for expected in ("skills/maestro/SKILL.md", "scripts/test-build-metadata.py", ".github/workflows/ci.yml"):
            self.assertIn(expected, inventory, "The probe inventory parser no longer sees a known input.")
        self.assertEqual(narrower_inputs(inventory, self.rules), [])

    def test_native_and_probe_sources_name_no_narrower_mapped_path(self):
        files, scanned = native_and_probe_sources()
        for expected in ("test.sh", "run-guide-ui-validation.py", "run-integrated-test-scopes.py",
                         "write-guide-reference.py", "verify-build-metadata.py"):
            self.assertIn(expected, scanned, "The source scan no longer reaches a known script.")
        self.assertGreater(len(files), 50)
        found = [hit for path in files
                 for hit in doc_references(path.relative_to(ROOT).as_posix(), path.read_text(), self.rules)]
        self.assertEqual(found, [])
        # The allow-list stays exact: every entry is still present, on a comment line.
        for relative, token in ALLOWED_DOC_REFERENCES:
            lines = [line.strip() for line in (ROOT / relative).read_text().splitlines() if token in line]
            self.assertTrue(lines and all(line.startswith(COMMENT_PREFIXES) for line in lines), (relative, token))

    def test_guard_mutations_fail(self):
        project = PROJECT.read_text()
        group = "path = CMUXMaestroSidebar;"
        self.assertIn(group, project)
        for name, mutated in {
            "synchronized root group for docs": project.replace(group, "path = docs;", 1),
            "README resource": project.replace(group, "path = README.md;", 1),
            "quoted docs path": project.replace(group, 'path = "docs/reference";', 1),
            "input path into docs": project.replace('"$(SRCROOT)/skills/maestro/SKILL.md",',
                                                    '"$(SRCROOT)/docs/reference/x.md",', 1),
            "build phase reads a leaf test": project.replace("$SRCROOT/scripts/write-guide-reference.py",
                                                             "$SRCROOT/scripts/test-beats.py", 1),
        }.items():
            with self.subTest(mutation=name):
                self.assertNotEqual(mutated, project)
                self.assertTrue(narrower_inputs(pbxproj_inputs(mutated), self.rules))
        probe = PROBE.read_text()
        mutated = probe.replace('"skills/maestro/SKILL.md",', '"skills/maestro/SKILL.md", "docs/reference/x.md",', 1)
        self.assertNotEqual(mutated, probe)
        self.assertTrue(narrower_inputs(probe_inventory(mutated), self.rules))
        swift = "CMUXMaestroPreviewTests/Example.swift"
        for name, text in {
            "Swift literal": 'let path = "docs/reference/x.md"\n',
            "Swift directory literal": 'root.appendingPathComponent("docs")\n',
            "README literal": 'let readme = "README.md"\n',
            "leaf test name": 'run("scripts/test-beats.py")\n',
            "allow-listed token in code": 'let adr = "docs/adr/0007"\n',
        }.items():
            with self.subTest(mutation=name):
                self.assertTrue(doc_references(swift, text, self.rules))
        allowed = "CMUXMaestroSidebar/State/SidebarBeatsModel.swift"
        self.assertEqual(doc_references(allowed, "/// Policy: docs/adr/0007\n", self.rules), [])
        self.assertTrue(doc_references(allowed, 'let adr = "docs/adr/0007"\n', self.rules))


class ClassificationTests(unittest.TestCase):
    def record(self, paths, **kwargs):
        record, rows = classify.build_record(environ(), SUITES, MAP_TEXT, fake_git(paths, **kwargs))
        self.assertTrue(record["complete"])
        self.assertEqual(sorted(record["suites"]), sorted(SUITES))
        return record, rows

    def test_markdown_docs_only_change_skips_native_and_probe(self):
        record, rows = self.record(["docs/reference/build-and-test.md", "README.md", "CHANGELOG.md"])
        self.assertEqual(record["mode"], "selective")
        self.assertEqual(applicable(record), {CONTRACTS})
        self.assertEqual({row[1] for row in rows}, {"markdown-docs"})
        self.assertIn("markdown-docs: 3 file(s)", record["suites"][CONTRACTS]["reason"])
        self.assertEqual(record["suites"][NATIVE]["reason"], "no changed file maps to it; files matched only: markdown-docs")

    def test_docs_images_only_change_runs_no_validation_suite(self):
        record, _ = self.record(["docs/images/sidebar.png", "docs/design/2026-09-25/images/beats.png"])
        self.assertEqual(applicable(record), set())
        self.assertEqual(record["mode"], "selective")

    def test_single_area_contract_test_change(self):
        record, _ = self.record(["scripts/test-beats.py"])
        self.assertEqual(applicable(record), {CONTRACTS})

    def test_cross_area_change_selects_the_union(self):
        record, _ = self.record(["docs/images/sidebar.png", "README.md", "CMUXMaestroSidebar/UI/SidebarView.swift"])
        self.assertEqual(applicable(record), set(SUITES))
        self.assertEqual(record["mode"], "full")
        self.assertIn("unmapped: 1 file(s), e.g. CMUXMaestroSidebar/UI/SidebarView.swift",
                      record["suites"][NATIVE]["reason"])

    def test_unmapped_file_selects_every_suite(self):
        for path in ("NEW-TOP-LEVEL.txt", "scripts/new-helper.py", "docs.md"):
            with self.subTest(path=path):
                record, rows = self.record(["README.md", path])
                self.assertEqual(applicable(record), set(SUITES))
                self.assertIn(("unmapped"), [row[1] for row in rows])

    def test_workflow_or_selection_file_change_selects_every_suite(self):
        for path in (".github/workflows/ci.yml", "scripts/ci-suite-map.json", "scripts/ci-gate.py"):
            with self.subTest(path=path):
                self.assertEqual(applicable(self.record([path, "README.md"])[0]), set(SUITES))

    def test_empty_change_set_selects_every_suite(self):
        record, _ = self.record([])
        self.assertEqual((record["mode"], record["changed_files"]), ("full", 0))
        self.assertIn("empty change set", record["reason"])
        self.assertEqual(applicable(record), set(SUITES))

    def assert_full(self, record, phrase):
        self.assertTrue(record["complete"])
        self.assertEqual(record["mode"], "full")
        self.assertIn(phrase, record["reason"])
        self.assertEqual(applicable(record), set(SUITES))
        for decision in record["suites"].values():
            self.assertEqual(decision["reason"], record["reason"])

    def test_main_push_selects_every_suite_without_reading_git(self):
        def no_git(*args):
            raise AssertionError("push runs never classify")
        record, rows = classify.build_record(environ("push", "", ""), SUITES, MAP_TEXT, no_git)
        self.assert_full(record, "push to main: full validation")
        self.assertEqual((record["base"], record["head"], rows), (None, None, []))

    def test_unsupported_event_selects_every_suite(self):
        record, _ = classify.build_record(environ("workflow_dispatch"), SUITES, MAP_TEXT, fake_git(["README.md"]))
        self.assert_full(record, "unsupported event 'workflow_dispatch'")

    def test_missing_or_malformed_head_or_run_sha_selects_every_suite(self):
        for overrides in ({"head": ""}, {"sha": ""}, {"head": "C" * 40}, {"sha": MERGE + "\n"}):
            with self.subTest(overrides=overrides):
                record, _ = classify.build_record(environ(**overrides), SUITES, MAP_TEXT, fake_git(["README.md"]))
                self.assert_full(record, "missing or malformed")

    def test_git_error_selects_every_suite(self):
        for failing in ("rev-parse", "rev-list", "diff"):
            with self.subTest(failing=failing):
                record, _ = classify.build_record(environ(), SUITES, MAP_TEXT, fake_git(["README.md"], fail=failing))
                self.assert_full(record, f"change set unavailable (git {failing} failed")

    def test_base_is_the_merge_first_parent_and_the_payload_base_is_information_only(self):
        moved = "d" * 40
        for payload in (BASE, "", "main"):
            with self.subTest(payload=payload):
                record, _ = classify.build_record(environ(base=payload), SUITES, MAP_TEXT,
                                                  fake_git(["README.md"], parents=[MERGE, moved, HEAD]))
                self.assertEqual((record["base"], record["payload_base"]), (moved, payload or None))
                self.assertEqual(record["mode"], "selective")

    def test_base_diff_uses_the_first_parent(self):
        calls = []
        git = fake_git(["README.md"], parents=[MERGE, "d" * 40, HEAD])

        def recording(*args):
            calls.append(args)
            return git(*args)
        classify.build_record(environ(), SUITES, MAP_TEXT, recording)
        diffs = [call[4:-1] for call in calls if call[0] == "diff"]
        self.assertEqual(diffs, [("d" * 40, MERGE), (f"{'d' * 40}...{HEAD}",)])

    def test_checkout_that_is_not_a_merge_of_this_head_selects_every_suite(self):
        for kwargs in ({"head_sha": "d" * 40}, {"parents": [MERGE, HEAD, BASE]}, {"parents": [MERGE, BASE]},
                       {"parents": [MERGE, BASE, HEAD, "d" * 40]}, {"parents": ["d" * 40, BASE, HEAD]},
                       {"parents": [MERGE, "main", HEAD]}):
            with self.subTest(kwargs=kwargs):
                record, _ = classify.build_record(environ(), SUITES, MAP_TEXT, fake_git(["README.md"], **kwargs))
                self.assert_full(record, "change set unavailable")

    def test_symlink_into_a_narrower_mapped_path_selects_every_suite(self):
        cases = {
            "into docs markdown": ("Resources/guide.md", "../docs/reference/x.md", "resolves to docs/reference/x.md"),
            "into a docs directory": ("CMUXMaestroPreview/docs", "../docs", "resolves to docs,"),
            "into a leaf test": ("scripts/beats-test.py", "test-beats.py", "resolves to scripts/test-beats.py"),
            "to an image": ("Resources/icon.png", "../docs/images/sidebar.png", "resolves to docs/images/sidebar.png"),
            "outside the repository": ("Resources/out", "../../elsewhere", "points outside the repository"),
            "absolute": ("Resources/abs", "/etc/hosts", "points outside the repository"),
        }
        for name, (path, target, phrase) in cases.items():
            with self.subTest(case=name):
                record, rows = classify.build_record(environ(), SUITES, MAP_TEXT,
                                                     fake_git(["README.md"], links=[(path, target)]))
                self.assert_full(record, phrase)
                self.assertEqual(rows, [])

    def test_symlink_to_an_every_suite_path_keeps_the_selection(self):
        record, _ = self.record(["README.md"], links=[("Resources/hook", "../scripts/test.sh")])
        self.assertEqual(applicable(record), {CONTRACTS})

    def test_checked_in_tree_has_no_symlink_into_a_narrower_mapped_path(self):
        rules = classify.load_map(MAP_TEXT, SUITES)
        links = classify.symlinks(lambda *args: classify.run_git("-C", str(ROOT), *args), "HEAD")
        self.assertIsNone(classify.symlink_problem(links, rules, SUITES))

    def test_invalid_map_selects_every_suite(self):
        record, _ = classify.build_record(environ(), SUITES, "{", fake_git(["README.md"]))
        self.assert_full(record, "suite map invalid")

    def test_every_record_satisfies_the_gate_for_this_run(self):
        # The classifier's record is exactly what ci-gate accepts for the same run, event and commit.
        contract = gate.load_contract(gate.CONTRACT_PATH.read_text())
        run = {"event": "pull_request", "run_id": "7", "sha": MERGE}
        cases = {"docs": (environ(), fake_git(["README.md"])), "code": (environ(), fake_git(["x.swift"])),
                 "git error": (environ(), fake_git([], fail="diff")),
                 "push": (environ("push", "", ""), fake_git([]))}
        for name, (env, git) in cases.items():
            with self.subTest(case=name):
                record, _ = classify.build_record(env, SUITES, MAP_TEXT, git)
                outputs = {"classification": json.dumps(record)} | {
                    classify.flag_name(job): "true" if decision["applicable"] else "false"
                    for job, decision in record["suites"].items()}
                checked, problem = gate.classification(
                    contract, {"result": "success", "outputs": outputs}, dict(run, event=env["GITHUB_EVENT_NAME"]))
                self.assertIsNone(problem)
                self.assertEqual(checked, record)


class GitChangeSetTests(unittest.TestCase):
    """Real repositories: renames, deletions, mixed changes and a moved base."""

    def setUp(self):
        self.repo = ROOT / ".build/ci-classify-tests" / uuid.uuid4().hex
        self.repo.mkdir(parents=True)
        self.addCleanup(shutil.rmtree, self.repo, ignore_errors=True)
        self.git("init", "-q", "-b", "main")
        self.write({"docs/a.md": "a\n", "docs/images/i.png": "png\n", "src/x.swift": "let x = 1\n",
                    "README.md": "readme\n"})
        self.commit("base")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=Test", "-c", "user.email=t@example.com",
                               "-c", "commit.gpgsign=false", *args],
                              check=True, capture_output=True, text=True).stdout.strip()

    def runner(self, *args):
        return classify.run_git("-C", str(self.repo), *args)

    def write(self, files):
        for path, text in files.items():
            (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / path).write_text(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def pull_request(self, change, base_change=None):
        return self.pull_request_named("topic", change, base_change)

    def pull_request_named(self, branch, change, base_change=None):
        """Branch, apply `change`, optionally move main, then build GitHub's synthetic merge."""
        self.git("checkout", "-q", "-b", branch)
        change()
        head = self.commit("topic")
        self.git("checkout", "-q", "main")
        if base_change:
            base_change()
            self.commit("main moved")
        base = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "--detach")
        self.git("merge", "-q", "--no-ff", "-m", "merge", head)
        merge = self.git("rev-parse", "HEAD")
        env = environ(base=base, head=head, sha=merge)
        return classify.build_record(env, SUITES, MAP_TEXT, self.runner)

    def test_docs_rename_and_image_delete_stay_docs_only(self):
        def change():
            self.git("mv", "docs/a.md", "docs/b.md")
            self.git("rm", "-q", "docs/images/i.png")
        record, rows = self.pull_request(change)
        self.assertEqual(sorted(row[0] for row in rows), ["docs/a.md", "docs/b.md", "docs/images/i.png"])
        self.assertEqual(applicable(record), {CONTRACTS})
        self.assertEqual(record["changed_files"], 3)

    def test_rename_of_code_into_docs_keeps_full_coverage(self):
        record, rows = self.pull_request(lambda: self.git("mv", "src/x.swift", "docs/x.md"))
        self.assertIn(("src/x.swift", "unmapped", SUITES), rows)
        self.assertEqual(applicable(record), set(SUITES))

    def test_deleted_code_keeps_full_coverage(self):
        record, _ = self.pull_request(lambda: self.git("rm", "-q", "src/x.swift"))
        self.assertEqual(applicable(record), set(SUITES))

    def test_mixed_change_selects_the_union(self):
        record, _ = self.pull_request(lambda: self.write({"docs/a.md": "b\n", "src/x.swift": "let x = 2\n"}))
        self.assertEqual(applicable(record), set(SUITES))

    def test_moved_base_classifies_the_candidate_against_the_current_base(self):
        # main changed code after the branch point; the candidate only changed docs.
        record, rows = self.pull_request(lambda: self.write({"docs/a.md": "b\n"}),
                                         lambda: self.write({"src/x.swift": "let x = 3\n"}))
        self.assertEqual([row[0] for row in rows], ["docs/a.md"])
        self.assertEqual(applicable(record), {CONTRACTS})

    def test_change_main_already_has_is_still_classified(self):
        # The candidate's own change counts even when the merge's net diff against base is empty.
        same = {"src/x.swift": "let x = 9\n"}
        record, rows = self.pull_request(lambda: self.write(same), lambda: self.write(same))
        self.assertEqual([row[0] for row in rows], ["src/x.swift"])
        self.assertEqual(applicable(record), set(SUITES))

    def test_tracked_symlink_into_docs_selects_every_suite(self):
        def change():
            (self.repo / "src").mkdir(exist_ok=True)
            (self.repo / "src/guide.md").symlink_to("../docs/a.md")
            self.git("add", "src/guide.md")
        self.pull_request(change)
        # A later docs-only candidate on top of that tree.
        self.git("checkout", "-q", "-B", "main")
        record, _ = self.pull_request_named("topic2", lambda: self.write({"docs/a.md": "changed\n"}))
        self.assertEqual(record["mode"], "full")
        self.assertIn("symlink src/guide.md resolves to docs/a.md", record["reason"])

    def test_unknown_revision_is_a_git_error(self):
        env = environ(sha=self.git("rev-parse", "HEAD"))
        record, _ = classify.build_record(env, SUITES, MAP_TEXT, self.runner)
        self.assertEqual(record["mode"], "full")
        self.assertIn("change set unavailable", record["reason"])


class MainTests(unittest.TestCase):
    def run_main(self, env, **kwargs):
        scratch = ROOT / ".build/ci-classify-tests" / uuid.uuid4().hex
        scratch.mkdir(parents=True)
        self.addCleanup(shutil.rmtree, scratch, ignore_errors=True)
        output, summary = scratch / "output", scratch / "summary.md"
        env = dict(env, GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(summary))
        out = io.StringIO()
        code = classify.main(env, out=out, **kwargs)
        return (code, out.getvalue(), output.read_text() if output.exists() else "",
                summary.read_text() if summary.exists() else "")

    def test_main_publishes_record_flags_and_summary(self):
        code, stdout, output, summary = self.run_main(environ(), git=fake_git(["README.md", "docs/images/x.png"]))
        self.assertEqual(code, 0)
        lines = output.splitlines()
        self.assertEqual([line.split("=", 1)[0] for line in lines],
                         ["classification", "run_validate_native", "run_validate_contracts",
                          "run_guide_ui_consumer_probe"])
        flags = dict(line.split("=", 1) for line in lines[1:])
        self.assertEqual(flags, {"run_validate_native": "false", "run_validate_contracts": "true",
                                 "run_guide_ui_consumer_probe": "false"})
        record = json.loads(lines[0].split("=", 1)[1])
        self.assertEqual((record["event"], record["run_id"], record["sha"]), ("pull_request", "7", MERGE))
        self.assertTrue(summary.startswith("## Suite selection\n\n"))
        self.assertEqual(summary, "## Suite selection\n\n" + stdout)
        self.assertIn("| Suite | Selected | Reason |", stdout)
        self.assertIn("| validate-native | no (not applicable) | no changed file maps to it;", stdout)
        self.assertIn("| validate-contracts | yes | markdown-docs: 1 file(s), e.g. README.md |", stdout)
        self.assertIn("| docs/images/x.png | docs-images | none |", stdout)

    def test_main_escapes_paths_in_the_summary(self):
        _, stdout, output, _ = self.run_main(environ(), git=fake_git(["docs/a|b\nc.md"]))
        self.assertIn("| docs/a\\|b c.md | markdown-docs | validate-contracts |", stdout)
        self.assertEqual(len(output.splitlines()), 1 + len(SUITES))

    def test_unreadable_map_publishes_a_full_selection(self):
        code, _, output, _ = self.run_main(environ(), map_path=ROOT / "scripts/does-not-exist.json",
                                           git=fake_git(["README.md"]))
        self.assertEqual(code, 0)
        self.assertNotIn("=false", output)
        self.assertIn("suite map invalid", output)

    def test_unreadable_contract_fails_without_outputs(self):
        code, stdout, output, _ = self.run_main(environ(), contract_path=ROOT / "scripts/does-not-exist.json")
        self.assertEqual(code, 1)
        self.assertEqual(output, "")
        self.assertIn("Suite classification: FAIL", stdout)


if __name__ == "__main__":
    unittest.main()
