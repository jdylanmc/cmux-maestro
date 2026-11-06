# Evidence archive: ci

Archived 2026-11-06. Verbatim text moved out of the living documentation so those pages describe current behavior only. Nothing here is a current contract; follow the links back for that.

## Sources

From [`docs/reference/ci-runner-placement/sources.md`](../reference/ci-runner-placement/sources.md). One-time measurements moved here verbatim; numbers describe the cited runs.

- **Window:** every Actions job the `jdylanmc` account ran from 2026-10-14 12:41Z to
  2026-10-15 11:40Z: 54 `cmux-maestro` CI runs (77 macOS jobs that started), plus
  46 macOS jobs in `pr-sniper` and one in `homebrew-pr-sniper`.
- **Timings:** `created_at`, `started_at` and `completed_at` per job, and step
  times, from `GET /repos/jdylanmc/<repo>/actions/runs/<id>/jobs` (and `.../attempts/<n>/jobs`
  for re-run runs; a re-run's reused jobs, whose start precedes their creation, are
  excluded). Queueing is job `started_at` minus `created_at`; execution is
  `completed_at` minus `started_at`. Jobs cancelled before a runner picked them up
  are not counted as active.
- **Reproduce:** the concurrency and queue tables are one-time measurements of
  this window. `scripts/ci-concurrency-report.py` regenerates them read-only
  through `gh api` (about 90 seconds), while GitHub still retains the runs:

  ```sh
  GH_TOKEN="$(gh auth token --user jdylanmc)" python3 scripts/ci-concurrency-report.py \
      --owner jdylanmc --repo cmux-maestro --repo pr-sniper --repo homebrew-pr-sniper \
      --since 2026-10-14 --until 2026-10-15T11:40:46Z
  ```

  On 2026-10-15 it reproduced the tables in
  [concurrency and queueing](../reference/ci-runner-placement/concurrency-and-queueing.md) exactly. The layout table and
  the step timings come from the same jobs API, read by hand.
- **Test counts:** the suites' own summary lines in the job log, e.g. job
  116344761792 (run 38711815326, `validate-contracts`, image `macos-26-arm64`).

## Run timings by layout

From [`docs/reference/ci-runner-placement/run-timings-by-layout.md`](../reference/ci-runner-placement/run-timings-by-layout.md). One-time measurements moved here verbatim; numbers describe the cited runs.

macOS execution is the sum over the run's macOS jobs. Wall time runs from
creation to the last job's completion.

| Layout | Runs | macOS execution per run | Wall time per run |
| --- | --- | --- | --- |
| One `validate` job plus probe (before #196) | 17 runs whose `validate` succeeded, 10-14 to 10-15 | 25.5 to 45.7 min | 23.2 to 66.1 min |
| `validate-native`, `validate-contracts` and probe (#196) | 38676895215, 38695672938, 38711815326 | 28.6 to 38.2 min | 16.3 to 21.9 min |

- The split shortened wall time without adding macOS minutes. It does add a
  third macOS job per run, so a run reaches the 5-job ceiling sooner when other
  runs are active.
- Time to first failure:
  - Run 38680647119 attempt 1 (split): `validate-native` failed 13.3 minutes
    after creation.
  - Old-layout failures surfaced only when `validate` finished: 21.4 to 47.5
    minutes after creation in the eight failed runs 38648863293 to 38657511033.

## Effect

From [`docs/reference/ci-runner-placement/effect.md`](../reference/ci-runner-placement/effect.md). One-time measurements moved here verbatim; numbers describe the cited runs.

- **Documentation-only pull requests** (`docs/**`, `README.md`, `CHANGELOG.md`,
  `CONTEXT.md` or `AGENTS.md`, other than this policy):
  - Before: `validate-contracts` took a macOS slot for 9.7 to 16.6 minutes of
    execution in the split runs in [run timings by layout](../reference/ci-runner-placement/run-timings-by-layout.md), plus any queue at the ceiling. Docs-only
    probe PR #248, run 38728899842:
    - `ci-classify` took 7 seconds.
    - `validate-native` and the probe were not applicable.
    - `validate-contracts` held a macOS runner from 11:39:55Z to 11:54:50Z
      (14m55s), only for the two Markdown-reading checks, which took seconds.
    - `ci-gate` passed at 11:55:02Z.
  - Now: no macOS job. `validate-portable` runs on Linux, which queued 2 to 3
    seconds in every measured run. Its execution is estimated at 10 to 20 seconds:
    the Linux `ci-classify` and `ci-gate` jobs take 5 to 7 seconds, and the two
    steps took 1 to 2 seconds on macOS. A live run must confirm the figure.
- **Merge policy changes:** still run `validate-contracts`, because
  `scripts/test-build-metadata.py` reads the policy.
- **Full runs:** `validate-contracts` loses two steps of 0 to 2 seconds each.
  Time to green is unchanged, because the macOS jobs bound it.
- **Earlier failures:** a broken skill hash or policy anchor now fails in the
  Linux job, without waiting for a macOS runner.
- **Cost:** no paid capacity. The repository is public, so hosted runners are
  free. The change uses one more Linux job per run, and no more macOS jobs or
  macOS minutes.
- **No further macOS split:** splitting `validate-contracts` would add macOS
  jobs per run. That raises demand at the 5-job ceiling, where all measured
  queueing happened, so the concurrency data does not support it.

## Measured cost and benefit of the realistic candidate

From [`docs/reference/ci-setup-reuse/measured-cost-and-benefit-of-the.md`](../reference/ci-setup-reuse/measured-cost-and-benefit-of-the.md). One-time measurements moved here verbatim; numbers describe the cited runs.

DerivedData reuse is the only candidate on the critical path. The test build
takes 3 to 4 minutes of a 16 to 18 minute job.

#### Method

The measurements were taken locally, so they are **not representative of CI**,
only indicative of ratios:

- Xcode 27.0 (27A266a) on Apple silicon, against Xcode 26.6 (17F113) in CI.
  Locally the build ran 297 `SwiftCompile` and 224 PCM tasks; CI runs 230 and
  213. The toolchain and task graph differ.
- `-jobs 3` approximates the 3-vCPU hosted macOS runner; the unthrottled runs
  used every core.
- The same test-namespace settings as `test.sh`, running `build-for-testing`.
- "Fresh checkout" means touching every tracked file and the SDK. This matches
  `actions/checkout`, which gives every file a new modification time.
- The machine was shared, so absolute times are noisy. Use the ratios, not the
  seconds.

#### Results

| Case | Wall time | Swift compile tasks | PCM tasks |
| --- | --- | --- | --- |
| Cold, empty DerivedData | 81s (other cold runs: 41s, 46s, 59s, 124s) | 297 | 224 |
| Warm, unchanged files (ideal, unrealistic in CI) | 2s | 0 | 0 |
| Warm, fresh checkout times | 61s, 52s with `Build/Products` dropped (unthrottled: 23 to 24s against 41 to 46s cold) | 296 | 0 |
| Warm, one sidebar file edited, original times otherwise | 10s | 6 | 0 |
| Only `SDKExplicitPrecompiledModules` and `ModuleCache.noindex` restored | 48s, the same as cold | 296 | 224 |
| Only `ModuleCache.noindex` restored | no gain | 296 | 224 |
| `COMPILATION_CACHE_ENABLE_CACHING=YES`, only `CompilationCache.noindex` (558 MB) restored into new DerivedData | 57s, against 59 to 66s cold | 297 | 224 |

## Interpretation

From [`docs/reference/ci-setup-reuse/interpretation.md`](../reference/ci-setup-reuse/interpretation.md). One-time measurements moved here verbatim; numbers describe the cited runs.

- After a checkout, Xcode recompiles every Swift file regardless of the cache.
  Restored DerivedData saves only the explicit-module (PCM) generation and some
  planning: 25 to 35% of the build at 3 jobs, 44 to 48% unthrottled.
- **CI-derived bound.** Planning plus the PCM window is 78s (A), 87s (B) and
  84s (C). The PCM window overlaps other compile tasks, so this is an upper
  bound on what PCM and planning reuse can remove from the CI build.
- **Restore cost is an assumption, not a measurement.** The test build's
  DerivedData, without products or scoped results, is about 550 MB raw and
  173 MB as a `tar` and `zstd` archive (5,302 files). Packing locally took 5s
  and unpacking 7s. The 20 to 40s assumed for a hosted runner is about 10 to 20 MB/s
  effective cache download (9 to 17s) plus 2 to 3 times the local unpack (14 to 21s). A
  miss pays a similar cost to save.
- **Projected net saving: about 10 to 95s.**
  - Low end: 25% of a 191s CI build is 48s, minus a 40s restore.
  - High end: 48% of a 239s CI build is 115s, minus a 20s restore. This is
    above the CI-derived bound, so it is generous.
  - That is about 1 to 9% of `validate-native`.
  - **The decision holds:** even the high end is below the 2-minute threshold
    under "When to revisit".
  - Run-to-run variation of that one step is already about 2 minutes
    (16m05s to 17m59s), and queueing at the macOS concurrency ceiling dominates
    end-to-end time. See [CI runner placement](../reference/ci-runner-placement.md).

## Sources and separating the costs

From [`docs/reference/test-performance/sources.md`](../reference/test-performance/sources.md). One-time measurements moved here verbatim; numbers describe the cited runs.

- **CI:** PR run 38662873916 (`validate` job, macOS GitHub-hosted runner).
  Step times come from the jobs API; test times come from the suites' own
  `Ran N tests in` lines and Swift Testing `passed after` lines in the job log.
- **Local:** one 18-core Apple silicon Mac shared with other agents, Xcode's
  `/usr/bin/python3` (3.9). Per-test times come from a scratch `unittest`
  runner with a timing result class. The suites were not changed to measure.
  Load averages are recorded with each run because they move results.

### Separating the costs

CI `validate` step, run 38662873916:

| Step | Step time | Inside it |
| --- | --- | --- |
| Orchestrator suite | 7m44s | 144 tests in 463.7 s |
| Local preview suite | 2m43s | 124 tests in 162.4 s, including one bridge compile |
| `./scripts/test.sh` | 10m17s | see below |
| Setup tests | 2m45s | 167 Swift tests in 77.0 s, plus compiles |

`./scripts/test.sh`, from log timestamps:

| Phase | Time |
| --- | --- |
| `build-for-testing` (compilation) | ~115 s |
| Test enumeration | ~7 s |
| Guide acceptance evidence (`produce_guide_acceptance`) | ~104 s |
| Isolated scope (1 test) | ~3 s |
| Remaining scope `xcodebuild` (956 tests in 352.6 s) | ~365 s |
| Result bundle reading and coverage accounting | ~22 s |

## Orchestrator suite evidence

From [`docs/reference/test-performance/orchestrator-evidence.md`](../reference/test-performance/orchestrator-evidence.md). One-time measurements moved here verbatim; numbers describe the cited runs.

Back-to-back local runs, same machine, same timing runner, 144 tests each, all
passing:

| Order | Before | After | Load (start → end) |
| --- | --- | --- | --- |
| Baseline first | 719.0 s | 363.5 s | 8.3 → 11.0 |
| After first | 621.3 s | 304.2 s | 11.0 → 7.0 |

The second pair's baseline wall clock was 22.5 minutes, but its monotonic test
time was 621.3 s: the host appears to have slept during it (macOS monotonic time
excludes sleep). Its result is consistent with the first pair.

Attribution, baseline-first pair:

- The four capacity cases: 174.3 s → 19.9 s.
- The other 140 tests: 544.7 s → 343.5 s (−37%; median per-test ratio 0.66),
  from fixture controller start-up alone.
- The default-budget pending-launch test: 34.8 s → 32.5 s.

Failure behaviour, by temporary mutation of the controller's
`workspace_capacity` (restored afterwards):

| Mutation | Failing tests among the four |
| --- | --- |
| Retained resources not counted | archive gap |
| `launch-failed` nodes not counted | failed attachment |
| `process-disappeared` nodes not counted | failed attachment, completed resources |
| Nodes without an observed provider not counted | all four |
| Off-by-one usage | all four |

Making the fixture edges a no-op in fixture controller processes failed 8
subtests and errored 1 in two edge-dependent tests, so the edges are still
applied.

## Orchestrator suite: Orchestrator profile

From [`docs/reference/test-performance/orchestrator-suite.md`](../reference/test-performance/orchestrator-suite.md). One-time measurements moved here verbatim; numbers describe the cited runs.

### Orchestrator profile

Baseline local run (load 15 to 21, 909 s, 144 tests). Five tests that fill or
hold the 32-slot live-resource budget took 328 s: three launched 30 to 31 real
fixture workers one at a time and waited for each, two held 31 pending
launches.

After #195, the default 32-slot fill is still exercised by pending and completing
workers (`test_pending_launches_hold_all_live_resource_slots`), but no test keeps 31
idle workers writing the shared state file at once. Lock waits sized for that load
(`with_store`, `MAX_LIVE_WORKERS / 8`) are no longer stressed by idle workers.

Per-process costs, measured inside one harness:

- A fixture worker launch costs about 0.8 to 1 s: one `native-spawn` controller
  process, about ten synthetic `cmux` processes, a runtime and a provider.
- Each fixture controller process (`controller-fixture.py`) started at about
  120 ms (Xcode Python) or 190 ms (Homebrew Python 3.14), against 17 to 23 ms for
  an empty interpreter. It recompiled the controller from source, then ran the
  whole test suite module, which compiled and executed a second controller copy
  and imported `unittest.mock`. It needs only three fixture-edge functions.
- Real-time sleeps are small and deliberate: synthetic provider turns
  (0.08 s; 0.35 to 0.8 s for timing-specific prompts), 10 to 50 ms poll intervals
  under unchanged deadlines. None dominates.
- Each test builds a fresh harness (register plus a synthetic coordinator
  provider, about 0.7 s). Tests mutate its state, so it is not shared.

## Local preview suite, Swift tests and next steps: Local preview profile

From [`docs/reference/test-performance/local-preview-and-swift.md`](../reference/test-performance/local-preview-and-swift.md). One-time measurements moved here verbatim; numbers describe the cited runs.

#### Local preview profile

Local run (load 12 to 15, 245.7 s, 124 tests):

- The compiled install bridge (`test-copilot-setup.sh --compile-only`) takes
  18 to 29 s, once per suite. Reusing it across suites belongs to #193.
- The gated-provider bridge-death test (36 s, four subcases) spends about 30 s
  waiting for its child installer to reach the gated provider. That is the real
  install transaction in a child process.
- In-process transaction tests are file-system bound. One registration-restore
  test spent 3.4 s of 13.3 s in 76 receipt `os.replace` calls after `fsync`,
  3.1 s copying fixture app trees and 3.3 s in 2,005 synthetic command calls.
- Poll intervals are already 15 to 25 ms under unchanged deadlines.

## Local preview suite, Swift tests and next steps: Swift profile

From [`docs/reference/test-performance/local-preview-and-swift.md`](../reference/test-performance/local-preview-and-swift.md). One-time measurements moved here verbatim; numbers describe the cited runs.

#### Swift profile

From run 38662873916's `test.sh` log:

- Reported `passed after` times are not work. Most AppKit-scoped tests report
  190 to 230 s because they include waiting on the shared AppKit gate.
- The gate's `R3 AppKit scope begin/end` markers sum to 325.5 s of gated body
  time across 329 cases in a 345.1 s span, so the gate serializes nearly the
  whole 352.6 s run. 123 markers interleave, so per-test values are diagnostic
  samples.
- Largest gated bodies: `targetLedNativeComposition()` 38.8 s;
  `activeWindowFooterLeavesUsableOutlineAtShortAndNarrowSizes()` 21.0 s;
  `directoryProvenanceRendersInProductionHoverPinnedAndDetails(dark:)` 20.7 s
  (2 cases); `inspectorRenderEvidenceRejectsWrongMissingHiddenAndClippedModels(dark:)`
  20.4 s (2 cases); `titleAndFixedNativeActionGroup(dark:width:)` 14.3 s
  (8 cases); `focusAcknowledgesExactAttentionOnlyAfterNavigationSucceeds(mode:succeeds:)`
  13.5 s (4 cases).

## Inventory: sources and validate-native

From [`docs/reference/ci-setup-reuse/inventory.md`](../reference/ci-setup-reuse/inventory.md). One-time measurements moved here verbatim; numbers describe the cited runs.

#### Sources

All figures come from GitHub step logs (`gh run view --job <id> --log`).
Phase boundaries are the logged `Fetched CmuxExtensionKit`, `Verified … build
namespace`, `Command line invocation`, `** TEST BUILD SUCCEEDED **`,
`** TEST EXECUTE SUCCEEDED **` and `Test run with …` lines. All three runs
were cold: nothing was restored.

| Run | Event | Head |
| --- | --- | --- |
| A: 38695672938 | pull request | `c057972` |
| B: 38728842209 | pull request | `02fa9e0` |
| C: 38731543660 | pull request, `ci/runner-placement` | `79f2ade` |

Each run built at Xcode 26.6 (17F113) and ran all suites. Guide-acceptance
sub-phases come from its uploaded evidence (`integrated-test-scope-evidence`):
the probe `.xcresult` `startTime`/`finishTime` in `result-summary.log`, and task
counts in `build-for-testing.log`. `xcodebuild` output for that build is
captured, not printed to the step log.

#### `validate-native`: `./scripts/test.sh`

This job is the critical path.

| Phase | A | B | C | Kind |
| --- | --- | --- | --- | --- |
| Pinned SDK fetch (curl and untar) | 10s | 12s | 3s | network |
| Preference test client `swiftc`, `-showBuildSettings`, namespace check | 35s | 45s | 47s | compile |
| `build-for-testing` (`.build/tests`) | 3m11s | 3m57s | 3m59s | compile |
| – Of which: planning, `Command line invocation` (log line 113) to the first `CreateBuildDirectory` (line 178) | 14s | 27s | 12s | compile |
| – Of which: PCM window, first to last `SwiftExplicitDependencyGeneratePcm` (lines 550 to 1778 to 1785; overlaps other compiles) | 64s | 60s | 72s | compile |
| – Of which: `CmuxExtensionKit` module, before the sidebar target | 24s | 19s | 15s | compile |
| – Of which: `CMUXMaestroPreviewTests` Swift compile | 1m47s | 2m22s | 2m30s | compile |
| – Task counts: `SwiftCompile` / `SwiftExplicitDependencyGeneratePcm` | 230 / 213 | 230 / 213 | 230 / 213 | |
| Isolated-scope execution | 15s | 13s | 13s | test |
| Guide acceptance, whole | 2m59s | 2m47s | 3m23s | compile and test |
| – Of which: source checks, settings and `build-for-testing` in its own DerivedData, to probe start | 41s | 40s | 51s | compile |
| – Of which: probe `test-without-building` (`.xcresult` start to finish) | 2m11s | 2m03s | 2m24s | test |
| – Of which: result export and recheck | 7s | 5s | 8s | test |
| – Guide build task counts: `SwiftCompile` / PCM | 19 / 65 | 19 / 65 | 19 / 65 | |
| Remaining scopes (956 tests) | 8m27s | 7m36s | 8m46s | test |
| Whole step | 16m14s | 16m05s | 17m59s | |

## Inventory: other suites and existing reuse

From [`docs/reference/ci-setup-reuse/validate-contracts.md`](../reference/ci-setup-reuse/validate-contracts.md). One-time measurements moved here verbatim.

| Step | A | B | C | Notes |
| --- | --- | --- | --- | --- |
| `build-unsigned.sh` | 1m27s | 1m43s | 2m02s | `xcodebuild build`: 58s, 1m09s and 1m30s. |
| `test-copilot-setup.sh` | 3m07s | 3m13s | 3m00s | Its three `swiftc` compiles take about 47 to 53s before the tests start (B, C). The tests take 91 to 99s. |
| `test-copilot-shell-reducer.sh`, `test-copilot-hook.sh`, `test-copilot-sandbox.sh` | 8s, 5s, 3s | 12s, 8s, 5s | 12s, 6s, 4s | Compile and run. |
| `test-local-preview.py` | 3m20s | 3m37s | 3m06s | Its bridge is compiled once per suite already, by `test-copilot-setup.sh --compile-only` (18 to 29s, from `test-performance.md`). |

### `guide-ui-consumer-probe`

- SDK fetch: 10s, 3s and 6s.
- Probe build and run: 1m28s, 57s and 1m17s.
- The probe uses a fresh DerivedData directory per invocation by design.

## Concurrency and queueing

From [`docs/reference/ci-runner-placement/concurrency-and-queueing.md`](../reference/ci-runner-placement/concurrency-and-queueing.md). One-time measurements of the 2026-10-14/15 window moved here verbatim.

macOS concurrency is limited per account, not per repository, and
`pr-sniper` shares it.

| Simultaneous account macOS jobs | Minutes in the window |
| --- | --- |
| 0 | 438 |
| 1 | 305 |
| 2 | 143 |
| 3 | 137 |
| 4 | 114 |
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
| 0 to 3 | 41 | 0.1 min | 0.2 min |
| 4 | 2 | 0.7 min | 0.7 min |
| 5 | 34 | 12.7 min | 41.2 min |

- Every queue over one minute coincided with the account at 5 macOS jobs.
  Below the ceiling, a macOS job started within 12 seconds.
- Examples:
  - Run 38662873916's jobs queued 40.6 and 41.2 minutes (00:56Z).
  - Six PR and push runs created at 00:37Z queued 10.6 to 18.0 minutes.
  - In run 38676895215 (the #196 layout), `guide-ui-consumer-probe` queued
    5m50s. From 03:39:27Z to 03:41:40Z four macOS jobs ran from two runs, and
    the account peaked at five.
  - In run 38695672938, all three macOS jobs started within 2 seconds.
- Linux jobs (`ci-classify`, `ci-gate`) queued 2 to 3 seconds in every run.
  Linux has its own, larger pool.
- One cancelled job held a macOS slot for 5h06m: run 38680234264 attempt 1,
  `validate`, in "Verify Settings guide and setup process isolation", from
  04:41Z to 09:18Z. #191 does not change that. #190 forbids arbitrary timeout
  cuts, and the hang keeps its existing owner.

## Orchestrator suite: Orchestrator changes

From [`docs/reference/test-performance/orchestrator-suite.md`](../reference/test-performance/orchestrator-suite.md). #195 change record moved here verbatim.

### Orchestrator changes

1. **Fixture controller start.** `controller-fixture.py` loads the controller
   and `scripts/test-fixtures/orchestrator-controller-edges.py` as modules
   through a run-scoped `sys.pycache_prefix`, instead of `runpy` on the
   controller and the whole suite. The same fixture edges apply; the shipped
   controller is unchanged. Start-up fell to 45 ms with Xcode Python (from 127 to
   130 ms) and to 58 ms with Homebrew Python (from 182 to 195 ms), median of 25.
2. **Resource-accounting capacity cases.** Four tests prove what counts
   against the live-resource limit: a retained terminal across archive, a failed
   attachment's surface, completed workers until their exact surface is
   retired, and unobserved direct sessions. They now set a workspace limit of 4
   through the public `capacity --limit` command and fill it, instead of filling
   the default 32. The admission check is the same for any limit, and
   configured limits are already covered end to end by `WorkspaceCapacityCLITests`.
   `test_pending_launches_hold_all_live_resource_slots` still fills the default
   32-slot reference budget with concurrent pending launches.

## Local preview suite, Swift tests and next steps: Local preview changes

From [`docs/reference/test-performance/local-preview-and-swift.md`](../reference/test-performance/local-preview-and-swift.md). #195 change record moved here verbatim.

#### Local preview changes

None. The dominant costs are durable writes, real child processes and the
bridge compile that the tests exist to exercise. Replacing `fsync`, renames or
processes would mock the transaction under test.

## Local preview suite, Swift tests and next steps: Swift changes

From [`docs/reference/test-performance/local-preview-and-swift.md`](../reference/test-performance/local-preview-and-swift.md). #195 change record moved here verbatim.

#### Swift changes

None. Changing gated Swift fixtures needs a profile of rendering, text
recognition and pixel conversion inside those tests first, and full `test.sh`
before/after runs on a quiet machine.
