# CI runner placement

Which CI work runs on which runner, the evidence behind it, and what #191
deliberately left alone. Numbers describe the cited runs, not promised savings.
Policy: [merge policy](../agents/merge-policy.md). Entrypoints:
[build and test](build-and-test.md). Test runtime: [test performance](test-performance.md).

## Sources

- **Window:** every Actions job the `jdylanmc` account ran from 2026-10-14 12:41Z to
  2026-10-15 11:40Z: 54 `cmux-maestro` CI runs (77 macOS jobs that started), plus
  46 macOS jobs in `pr-sniper` and one in `homebrew-pr-sniper`.
- **Timings:** `created_at`, `started_at` and `completed_at` per job, and step
  times, from `GET /repos/jdylanmc/<repo>/actions/runs/<id>/jobs` (and `.../attempts/<n>/jobs`
  for re-run runs; a re-run's reused jobs, whose start precedes their creation, are
  excluded). Queueing is job `started_at` minus `created_at`; execution is
  `completed_at` minus `started_at`. Jobs cancelled before a runner picked them up
  are not counted as active.
- **Test counts:** the suites' own summary lines in the job log, e.g. job
  116344761792 (run 38711815326, `validate-contracts`, image `macos-26-arm64`).

## Concurrency and queueing

macOS concurrency is limited per account, not per repository, and
`pr-sniper` shares it.

| Simultaneous account macOS jobs | Minutes in the window |
| --- | --- |
| 0 | 438 |
| 1 | 306 |
| 2 | 143 |
| 3 | 137 |
| 4 | 115 |
| 5 | 240 |

- The maximum was **5**, which is GitHub's macOS limit for this plan. It was
  never exceeded.
- During the 240 minutes at 5, `pr-sniper` held 702 and `cmux-maestro` 500 of
  the macOS slot-minutes.
- Execution in the window: `cmux-maestro` 1,344 macOS minutes, `pr-sniper`
  1,318.

Queue delay of `cmux-maestro` macOS jobs, by the most account macOS jobs active
while the job waited:

| Most active while waiting | Jobs | Median queue | Longest queue |
| --- | --- | --- | --- |
| 0–3 | 41 | 0.1 min | 0.2 min |
| 4 | 2 | 0.7 min | 0.7 min |
| 5 | 34 | 12.7 min | 41.2 min |

- Every queue over one minute coincided with the account at 5 macOS jobs.
  Below the ceiling, a macOS job started within 12 seconds.
- Examples:
  - Run 38662873916's jobs queued 40.6 and 41.2 minutes (00:56Z).
  - Six PR and push runs created at 00:37Z queued 10.6–18.0 minutes.
  - In run 38676895215 (the #196 layout), `guide-ui-consumer-probe` queued
    5m50s. From 03:39:27Z to 03:41:40Z four macOS jobs ran from two runs, and
    the account peaked at five.
  - In run 38695672938, all three macOS jobs started within 2 seconds.
- Linux jobs (`ci-classify`, `ci-gate`) queued 2–3 seconds in every run.
  Linux has its own, larger pool.
- One cancelled job held a macOS slot for 5h06m: run 38680234264 attempt 1,
  `validate`, in "Verify Settings guide and setup process isolation", from
  04:41Z to 09:18Z. #191 does not change that. #190 forbids arbitrary timeout
  cuts, and the hang keeps its existing owner.

## Run timings by layout

macOS execution is the sum over the run's macOS jobs. Wall time runs from
creation to the last job's completion.

| Layout | Runs | macOS execution per run | Wall time per run |
| --- | --- | --- | --- |
| One `validate` job plus probe (before #196) | 17 runs whose `validate` succeeded, 10-14 to 10-15 | 25.5–45.7 min | 23.2–66.1 min |
| `validate-native`, `validate-contracts` and probe (#196) | 38676895215, 38695672938, 38711815326 | 28.6–38.2 min | 16.3–21.9 min |

- The split shortened wall time without adding macOS minutes. It does add a
  third macOS job per run, so a run reaches the 5-job ceiling sooner when other
  runs are active.
- Time to first failure:
  - Run 38680647119 attempt 1 (split): `validate-native` failed 13.3 minutes
    after creation.
  - Old-layout failures surfaced only when `validate` finished: 21.4–47.5
    minutes after creation in the eight failed runs 38648863293 to 38657511033.

## Dependencies between suites

- `validate-native` runs only `./scripts/test.sh`. It fetches the SDK and
  builds in its own derived data. It reads no other job's output (#196).
- Every `validate-contracts` suite writes only under its own `.build`
  subdirectory or a fresh temporary directory. No job reads another job's
  workspace.
- `guide-ui-consumer-probe` fetches its own SDK copy and needs nothing else.
- `validate-portable` reads only tracked files. It writes only temporary Git
  fixtures, which the tests remove, and uploads no artifact.
- Jobs share no cache, artifact or output path. Each artifact uploads from the
  job that produces it.
- No new dependency is added.

## Portability proof

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
- A new test simulates a POSIX-default host, by replacing `localeCompare` and
  the default `Intl.Collator`, and requires en-US order. Reverting to either
  `localeCompare` or a default `Intl.Collator()` fails it.

**Other differences checked:**

| Difference | Result |
| --- | --- |
| Case-sensitive file system | Every configured link and skill folder matches a tracked path exactly. Inbound links are compared as exact path strings on both systems. |
| Unicode path normalization | No tracked path contains non-ASCII characters. |
| Line endings | There is no `.gitattributes`, and both checkouts write the same bytes. |
| Node version | Locally, Node 20.20.2 (`npx node@20`) and Node 24.20.0 both run 13 of 13 tests and verify 9 skill hashes and 119 policy links. |
| `node --test` output | Node 20 prints TAP (`# tests 13`) and newer Node prints spec (`ℹ tests 13`). The counts are the same. |

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

## Not moved

| Command | Why it stays on macOS |
| --- | --- |
| `python3 scripts/test-build-metadata.py` | Runs `/usr/bin/plutil` to read the Xcode project. |
| `python3 scripts/test-pet-kit.py`, `test-beats.py`, `test-joe-role-appearance.py` | These load or run `scripts/cmux-maestro-orchestrator.py`, which hard-codes tool paths, including the macOS-only `/usr/bin/sips`. `test-beats.py` also changes `TZ` through the system time zone database. Not proven. |
| `python3 scripts/test-delivery-proof.py`, `node --test scripts/test-delivery-proof.mjs` | Process, socket and terminal-launch behaviour, not proven on Linux. Moving them would save about 10 seconds of macOS time per run. |
| `python3 scripts/test-local-preview.py` | Compiles Swift fixtures. |
| `python3 scripts/test-cmux-maestro-orchestrator.py` | Process-group and controller behaviour, not proven on Linux. |
| Shell reducer, SDK fetch, hooks, sandbox, unsigned build, setup, `test.sh`, guide probe | Native builds, AppKit, sandbox or hosted UI. |

- Moving more of these would not reduce macOS jobs: `validate-contracts` would
  still run on macOS for every change that reaches it.
- Only whole-suite moves that empty a macOS job for a class of changes free
  capacity. Documentation is that class.

## Effect

- **Documentation-only pull requests** (`docs/**`, `README.md`, `CHANGELOG.md`,
  `CONTEXT.md` or `AGENTS.md`, other than this policy):
  - Before: `validate-contracts` took a macOS slot for 9.7–16.6 minutes of
    execution in the split runs above, plus any queue at the ceiling. Docs-only
    probe PR #248, run 38728899842:
    - `ci-classify` took 7 seconds.
    - `validate-native` and the probe were not applicable.
    - `validate-contracts` held a macOS runner from 11:39:55Z to 11:54:50Z
      (14m55s), only for the two Markdown-reading checks, which took seconds.
    - `ci-gate` passed at 11:55:02Z.
  - Now: no macOS job. `validate-portable` runs on Linux, which queued 2–3
    seconds in every measured run. Its execution is estimated at 10–20 seconds:
    the Linux `ci-classify` and `ci-gate` jobs take 5–7 seconds, and the two
    steps took 1–2 seconds on macOS. A live run must confirm the figure.
- **Merge policy changes:** still run `validate-contracts`, because
  `scripts/test-build-metadata.py` reads the policy.
- **Full runs:** `validate-contracts` loses two steps of 0–2 seconds each.
  Time to green is unchanged, because the macOS jobs bound it.
- **Earlier failures:** a broken skill hash or policy anchor now fails in the
  Linux job, without waiting for a macOS runner.
- **Cost:** no paid capacity. The repository is public, so hosted runners are
  free. The change uses one more Linux job per run, and no more macOS jobs or
  macOS minutes.
- **No further macOS split:** splitting `validate-contracts` would add macOS
  jobs per run. That raises demand at the 5-job ceiling, where all measured
  queueing happened, so the concurrency data does not support it.
