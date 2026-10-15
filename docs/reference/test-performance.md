# Test performance

Where verification time goes, what #195 changed, and what remains. Numbers
describe the cited runs, not promised savings. Terms: [CONTEXT](../../CONTEXT.md).
Entrypoints: [build and test](build-and-test.md).

## Sources

- **CI:** PR run 38662873916 (`validate` job, macOS GitHub-hosted runner).
  Step times come from the jobs API; test times come from the suites' own
  `Ran N tests in` lines and Swift Testing `passed after` lines in the job log.
- **Local:** one 18-core Apple silicon Mac shared with other agents, Xcode's
  `/usr/bin/python3` (3.9). Per-test times come from a scratch `unittest`
  runner with a timing result class; the suites were not changed to measure.
  Load averages are recorded with each run because they move results.

## Separating the costs

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

## Orchestrator suite

### Profile

Baseline local run (load 15–21, 909 s, 144 tests). Five tests that fill or
hold the 32-slot live-resource budget took 328 s: three launched 30–31 real
fixture workers one at a time and waited for each, two held 31 pending
launches.

After #195, the default 32-slot fill is still exercised by pending and completing
workers (`test_pending_launches_hold_all_live_resource_slots`), but no test keeps 31
idle workers writing the shared state file at once. Lock waits sized for that load
(`with_store`, `MAX_LIVE_WORKERS / 8`) are no longer stressed by idle workers.

Per-process costs, measured inside one harness:

- A fixture worker launch costs about 0.8–1 s: one `native-spawn` controller
  process, about ten synthetic `cmux` processes, a runtime and a provider.
- Each fixture controller process (`controller-fixture.py`) started at about
  120 ms (Xcode Python) or 190 ms (Homebrew Python 3.14), against 17–23 ms for
  an empty interpreter. It recompiled the controller from source, then ran the
  whole test suite module, which compiled and executed a second controller copy
  and imported `unittest.mock`. It needs only three fixture-edge functions.
- Real-time sleeps are small and deliberate: synthetic provider turns
  (0.08 s; 0.35–0.8 s for timing-specific prompts), 10–50 ms poll intervals
  under unchanged deadlines. None dominates.
- Each test builds a fresh harness (register plus a synthetic coordinator
  provider, about 0.7 s). Tests mutate its state, so it is not shared.

### Changes

1. **Fixture controller start.** `controller-fixture.py` loads the controller
   and `scripts/test-fixtures/orchestrator-controller-edges.py` as modules
   through a run-scoped `sys.pycache_prefix`, instead of `runpy` on the
   controller and the whole suite. The same fixture edges apply; the shipped
   controller is unchanged. Start-up fell from 127–130 ms to 45 ms (Xcode
   Python) and from 182–195 ms to 58 ms (Homebrew Python), median of 25.
2. **Resource-accounting capacity cases.** Four tests prove what counts
   against the live-resource limit: a retained terminal across archive, a failed
   attachment's surface, completed workers until their exact surface is
   retired, and unobserved direct sessions. They now set a workspace limit of 4
   through the public `capacity --limit` command and fill it, instead of filling
   the default 32. The admission check is the same for any limit, and
   configured limits are already covered end to end by `WorkspaceCapacityCLITests`.
   `test_pending_launches_hold_all_live_resource_slots` still fills the default
   32-slot reference budget with concurrent pending launches.

### Evidence

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

## Local preview suite

### Profile

Local run (load 12–15, 245.7 s, 124 tests):

- The compiled install bridge (`test-copilot-setup.sh --compile-only`) takes
  18–29 s, once per suite. Reusing it across suites belongs to #193.
- The gated-provider bridge-death test (36 s, four subcases) spends about 30 s
  waiting for its child installer to reach the gated provider. That is the real
  install transaction in a child process.
- In-process transaction tests are file-system bound. One registration-restore
  test spent 3.4 s of 13.3 s in 76 receipt `os.replace` calls after `fsync`,
  3.1 s copying fixture app trees and 3.3 s in 2,005 synthetic command calls.
- Poll intervals are already 15–25 ms under unchanged deadlines.

### Changes

None. The dominant costs are durable writes, real child processes and the
bridge compile that the tests exist to exercise. Replacing `fsync`, renames or
processes would mock the transaction under test.

## Swift tests

### Profile

From run 38662873916's `test.sh` log:

- Reported `passed after` times are not work. Most AppKit-scoped tests report
  190–230 s because they include waiting on the shared AppKit gate.
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

### Changes

None. Changing gated Swift fixtures needs a profile of rendering, text
recognition and pixel conversion inside those tests first, and full `test.sh`
before/after runs on a quiet machine.

## Recommended next steps

1. **Gated Swift bodies.** Instrument the six largest gated tests with
   `ContinuousClock` around render, text recognition and pixel conversion, then
   cache repeated bitmap conversions within one case. Keep light/dark, density,
   geometry and negative controls.
2. **Guide acceptance (~104 s in `test.sh`).** Measure its compile and run
   phases separately; reuse with the setup-tests build belongs to #193.
3. **Preview bridge compile (18–29 s).** Share it with
   `test-copilot-setup.sh`'s build in the same job (#193), keeping source
   provenance.
4. **Orchestrator harness setup (~0.7 s × 144).** A cheaper registration
   fixture would need evidence that no test depends on the real `register`
   path; not done.
5. **Preview file-system cost.** Measure `fsync` and `os.replace` cost on the CI
   runner before considering any change; durability is the tested contract.
