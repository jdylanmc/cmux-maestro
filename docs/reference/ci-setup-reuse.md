# CI setup reuse

Issue #193 asked whether CI can reuse expensive setup without weakening
isolation. **Decision: no cross-run reuse for now.** No setup state is cached
or restored between runs: every job builds from a clean checkout. This page
records the inventory, the measurements, the rejected options and the
conditions for revisiting the decision.

`scripts/test-build-metadata.py`
(`test_ci_reuses_no_setup_state_across_runs`) enforces the boundary. The
workflow may use only `actions/checkout` and `actions/upload-artifact`. It may
not contain `actions/cache`, `restore-keys`, `cache:` or `download-artifact`.
`scripts/test.sh` and `scripts/build-unsigned.sh` keep their separate
DerivedData namespaces (`.build/tests` and `.build/unsigned`). Adding reuse
means re-measuring it, updating this page and changing that guard together.

## Inventory

### Sources

All figures come from GitHub step logs (`gh run view --job <id> --log`).
Phase boundaries are the logged `Fetched CmuxExtensionKit`, `Verified … build
namespace`, `Command line invocation`, `** TEST BUILD SUCCEEDED **`,
`** TEST EXECUTE SUCCEEDED **` and `Test run with …` lines. All three runs
were cold: nothing was restored.

| Run | Event | Head |
| --- | --- | --- |
| A: 38695672938 | pull request | `c057972` |
| B: 38728842209 | pull request | `02fa9e0` |
| C: 38731543660 | full run, #191 branch | `545775c` |

### `validate-native`: `./scripts/test.sh`

This job is the critical path.

| Phase | A | B | C | Kind |
| --- | --- | --- | --- | --- |
| Pinned SDK fetch (curl and untar) | 10s | 12s | 3s | network |
| Preference test client `swiftc`, `-showBuildSettings`, namespace check | 35s | 45s | 47s | compile |
| `build-for-testing` (`.build/tests`) | 3m11s | 3m57s | 3m59s | compile |
| – Of which: planning before the first compile task | 15s | 27s | – | compile |
| – Of which: `CmuxExtensionKit` module, before the sidebar target | 24s | 19s | – | compile |
| – Of which: `CMUXMaestroPreviewTests` Swift compile | 1m47s | 2m22s | – | compile |
| Isolated-scope execution | 15s | 13s | 13s | test |
| Guide acceptance (fresh build in its own DerivedData, then probe) | 2m59s | 2m47s | 3m23s | compile and test |
| Remaining scopes (956 tests) | 8m27s | 7m36s | 8m49s | test |
| Whole step | 16m14s | 16m05s | 17m59s | |

### `validate-contracts`

| Step | A | B | C | Notes |
| --- | --- | --- | --- | --- |
| `build-unsigned.sh` | 1m27s | 1m43s | 2m02s | `xcodebuild build`: 58s, 1m09s and 1m30s. |
| `test-copilot-setup.sh` | 3m07s | 3m13s | 3m00s | Its three `swiftc` compiles take about 47–53s before the tests start (B, C). The tests take 91–99s. |
| `test-copilot-shell-reducer.sh`, `test-copilot-hook.sh`, `test-copilot-sandbox.sh` | 8s, 5s, 3s | 12s, 8s, 5s | 12s, 6s, 4s | Compile and run. |
| `test-local-preview.py` | 3m20s | 3m37s | 3m06s | Its bridge is compiled once per suite already. |

### `guide-ui-consumer-probe`

- SDK fetch: 10s, 3s and 6s.
- Probe build and run: 1m28s, 57s and 1m17s.
- The probe uses a fresh DerivedData directory per invocation by design.

### Existing reuse within a run

- `fetch-sdk.sh` is idempotent within a job. Once the SDK commit stamp
  matches, later calls report `already pinned` and do no work.
- Preview tests compile their bridge once per suite.
- No build output crosses jobs or runs.

### Configurations that are not repetition

The test build (`.build/tests`, `.Validation.Tests`), the unsigned build
(`.build/unsigned`, `.Validation.Unsigned`) and the guide probe build use
deliberately different bundle identifiers, extension points, schemes and
DerivedData. Each one proves its own namespace. Sharing their outputs would
let one configuration's success stand in for another's, which #193 forbids.

## Measured cost and benefit of the realistic candidate

DerivedData reuse is the only candidate on the critical path. The test build
takes 3–4 minutes of a 16–18 minute job.

### Method

The measurements were taken locally:

- Xcode 27.0 on Apple silicon, with `-jobs 3` to approximate the 3-vCPU hosted
  macOS runner.
- The same test-namespace settings as `test.sh`, running `build-for-testing`.
- "Fresh checkout" means touching every tracked file and the SDK. This matches
  `actions/checkout`, which gives every file a new modification time.
- The machine was shared, so absolute times are noisy. Use the ratios, not the
  seconds.

### Results

| Case | Wall time | Swift compile tasks | PCM tasks |
| --- | --- | --- | --- |
| Cold, empty DerivedData | 81s (other cold runs: 41s, 46s, 59s, 124s) | 297 | 224 |
| Warm, unchanged files (ideal, unrealistic in CI) | 2s | 0 | 0 |
| Warm, fresh checkout times | 61s, 52s with `Build/Products` dropped (unthrottled: 23–24s against 41–46s cold) | 296 | 0 |
| Warm, one sidebar file edited, original times otherwise | 10s | 6 | 0 |
| Only `SDKExplicitPrecompiledModules` and `ModuleCache.noindex` restored | 48s, the same as cold | 296 | 224 |
| Only `ModuleCache.noindex` restored | no gain | 296 | 224 |
| `COMPILATION_CACHE_ENABLE_CACHING=YES`, only `CompilationCache.noindex` (558 MB) restored into new DerivedData | 57s, against 59–66s cold | 297 | 224 |

### Interpretation

- After a checkout, Xcode recompiles every Swift file regardless of the cache.
  Restored DerivedData saves only the explicit-module (PCM) generation and some
  planning, about 25–35% of the build at 3 jobs.
- The test build's DerivedData, without products or scoped results, is about
  550 MB raw and 173 MB as a `tar` and `zstd` archive (5,302 files). Packing
  locally took 5s and unpacking 7s. On a hosted runner, download plus unpack of
  that size is estimated at 20–40s. A miss pays a similar cost to save.
- **Projected net saving:**
  - 25–35% of a 191–239s CI build is 48–86s.
  - Subtracting a 20–40s restore leaves about 10–65s.
  - That is about 1–6% of `validate-native`.
  - Run-to-run variation of that one step is already about 2 minutes
    (16m05s–17m59s), and queueing at the macOS concurrency ceiling dominates
    end-to-end time. See [CI runner placement](ci-runner-placement.md).

## Rejected options

| Option | Reason |
| --- | --- |
| Cache the test build's DerivedData | Projected net saving of 10–65s, within noise. Restored `Build/Products` keeps resources and binaries the project no longer produces, so it must be dropped. Correctness then rests on Xcode's incremental state across Xcode or runner-image updates. Hosted macOS images update Xcode builds without notice, so the key must include `xcodebuild -version`, the SDK build, the architecture, the settings and the project file. Saving entries of about 170 MB from every pull request would churn the 10 GB repository cache, so saving would be limited to `main`. |
| Cache only precompiled SDK modules (`SDKExplicitPrecompiledModules`, `ModuleCache.noindex`) | No measured gain. Xcode regenerated every PCM without the matching `Build/Intermediates.noindex`. |
| Xcode compilation cache (`CompilationCache.noindex`) | No measured gain when restored into new DerivedData. It adds 558 MB and changes the test namespace's build settings. |
| Cache the pinned SDK checkout | Fetches take 3–12s, so a cache restore would not be faster. The pin already binds the source. |
| Share one build between `test.sh` and `build-unsigned.sh` | Breaks the distinct namespace guarantee: one configuration's success would prove the other. |
| Reuse the unsigned build or the guide probe build in the native job | Guide acceptance must own fresh, invocation-specific evidence and exact source attribution (`run-guide-ui-validation.py` hashes its inputs). |
| Cache `test-copilot-setup.sh`, preference-client or hook binaries keyed by source hash | These are test executables whose inputs change in most pull requests. They save at most about 50s, all of it in `validate-contracts`, which finishes before `validate-native`. |
| Reuse test results, `.xcresult` bundles, receipts or screenshots | Never acceptable as proof of a new invocation (#193, #190). |

## When to revisit

Reconsider DerivedData or compilation-cache reuse only when a live A/B test on
hosted runners (cold miss against warm hit, same commit) shows a net saving of
at least 2 minutes on the critical path after restore. That is likely only if
one of these is true:

- `build-for-testing` grows beyond about 6 minutes;
- Xcode's compilation cache becomes reusable across DerivedData locations;
- the project moves to persistent or self-hosted runners, where DerivedData
  survives without transfer.

Any adopted reuse must:

- key on the source tree, `xcodebuild -version`, the SDK build, the
  architecture, the build settings and the project file;
- restore before the build, never in place of it;
- delete `Build/Products` before building;
- save only from `main`;
- keep the `.build/tests` and `.build/unsigned` namespaces separate;
- log hit or miss;
- treat a corrupt or incompatible entry as a cold build.
