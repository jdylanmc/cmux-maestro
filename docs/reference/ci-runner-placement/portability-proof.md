# Portability proof

[↑ CI runner placement](../ci-runner-placement.md) | [← Dependencies between suites](dependencies-between-suites.md) | [Not moved →](not-moved.md)

A check moves only when it can produce the same verdict and the same test count
on Linux. Python or Node source alone is not proof. #191 moved two commands to
`validate-portable` on `ubuntu-latest`:

```sh
node --test scripts/test-skill-overrides.mjs
node scripts/check-skill-overrides.mjs
```

**What they use:**

- `node:fs`, `node:path`, `node:crypto` and `node:test`.
- `git init`, `git add` and `git ls-files`, from `PATH`.
- A temporary directory and one symbolic link.

None of them calls `xcrun`, `swiftc`, `xcodebuild`, `plutil`, `sw_vers`, `sips`,
`ditto`, `codesign`, `xattr`, `defaults`, a `/usr/bin` path or a BSD-only flag.

**Found difference: collation.**

- The skill hash sorts file paths with `localeCompare`, as the skills CLI does.
- On macOS, Node's default collation is en-US. On Linux it comes from `LANG`;
  `ubuntu-latest` sets `C.UTF-8`, which Node maps to `en-US-u-va-posix`.
- POSIX collation puts uppercase paths first (`README.md`, `SKILL.md`,
  `agents/…`). en-US puts `agents/…` first.
- Unchanged, the move would have failed:
  - Seven of the nine locked skills would report hash drift.
  - The `canonical digest` test's pinned hash would no longer match.
- Fix: `check-skill-overrides.mjs` sorts with an explicit `Intl.Collator("en-US")`.
  This matches the macOS hosts that wrote `skills-lock.json` and the macOS CI
  runs that verified it.
- Regenerate lock hashes (`npx skills …`) only on a host with en-US collation.
  POSIX/C collation (for example Linux with `LANG=C.UTF-8`) and some locales,
  such as Lithuanian, order paths differently, so the CLI would write hashes
  this check reports as drift. The drift error says so.
- A new test simulates a POSIX-default host, by replacing `localeCompare` and
  the default `Intl.Collator`, and requires en-US order. Reverting to either
  `localeCompare` or a default `Intl.Collator()` fails it.

**Other differences checked:**

| Difference | Result |
| --- | --- |
| Case-sensitive file system | Every configured link and skill folder matches a tracked path exactly. Inbound links are compared as exact path strings on both systems. |
| Unicode path normalization | No tracked path contains non-ASCII characters. |
| Line endings | The repository has no `.gitattributes`, and both checkouts write the same bytes. |
| Node version | The runner images' defaults are Node 22.23.3 on `ubuntu-latest` (Ubuntu 24.04) and Node 24.20.0 on `macos-latest`. Both versions, and also Node 20.20.2, run 13 of 13 tests and verify 9 skill hashes and 119 policy links locally. The roast confirmed the same on 22.23.3. |
| `node --test` output | It may print TAP (`# tests 13`) or spec (`ℹ tests 13`), depending on the version and terminal. The counts are the same. |

**What a live run must confirm.** In the `validate-portable` job of the first
run, check the following. Compare the counts with a local macOS run at the same
commit (13 tests; 9 hashes and 119 links at this branch's head).

- "Test local skill override validation" reports `tests 13`, `pass 13`, `fail 0`,
  `cancelled 0`, `skipped 0` and `todo 0`. The last macOS baseline, run
  38711815326, had 12 tests before the collation test was added.
- "Verify local skill overrides and policy links" prints
  `Verified 9 local skill hashes and 119 policy links`, the same line as the
  macOS baseline (run 38711815326) and a local macOS run of this commit. The
  count changes only when tracked Markdown changes.
- The job's runner image is `ubuntu-24.04` (or the current `ubuntu-latest`).
- The Node version. Expected: 22.23.3. The job runs no `node --version` step
  (validation jobs hold only their guarded commands), so read it from the
  "Included Software" readme that the job log's "Set up job" > "Runner Image"
  group links for the exact image version. A different version still needs
  the same counts.
