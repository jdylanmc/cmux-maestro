# CI setup reuse

Issue #193 asked whether CI can reuse expensive setup without weakening
isolation. **Decision: no cross-run reuse for now.** No setup state is cached
or restored between runs: every job builds from a clean checkout. This page
records the inventory, the measurements, the rejected options and the
conditions for revisiting the decision.

`scripts/test-build-metadata.py`
(`test_ci_reuses_no_setup_state_across_runs`) enforces the boundary. The
workflow may use only `actions/checkout` and `actions/upload-artifact`. Any
new action, even one with no cache such as `actions/setup-python`, needs a
setup-reuse review and a guard update. The guard parses every `uses:` line,
including quoted and comment-suffixed ones, and fails if any is unparsed. The
workflow may not contain `actions/cache`, `restore-keys`, `cache:`,
`cache-dependency-path`, `download-artifact`, `gh run download` or `gh cache`.
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
| C: 38731543660 | pull request, `ci/runner-placement` | `79f2ade` |

Each run built at Xcode 26.6 (17F113) and ran all suites. Guide-acceptance
sub-phases come from its uploaded evidence (`integrated-test-scope-evidence`):
the probe `.xcresult` `startTime`/`finishTime` in `result-summary.log`, and task
counts in `build-for-testing.log`. `xcodebuild` output for that build is
captured, not printed to the step log.

### `validate-native`: `./scripts/test.sh`

This job is the critical path.

| Phase | A | B | C | Kind |
| --- | --- | --- | --- | --- |
| Pinned SDK fetch (curl and untar) | 10s | 12s | 3s | network |
| Preference test client `swiftc`, `-showBuildSettings`, namespace check | 35s | 45s | 47s | compile |
| `build-for-testing` (`.build/tests`) | 3m11s | 3m57s | 3m59s | compile |
| – Of which: planning, `Command line invocation` (log line 113) to the first `CreateBuildDirectory` (line 178) | 14s | 27s | 12s | compile |
| – Of which: PCM window, first to last `SwiftExplicitDependencyGeneratePcm` (lines 550 to 1778–1785; overlaps other compiles) | 64s | 60s | 72s | compile |
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

### `validate-contracts`

| Step | A | B | C | Notes |
| --- | --- | --- | --- | --- |
| `build-unsigned.sh` | 1m27s | 1m43s | 2m02s | `xcodebuild build`: 58s, 1m09s and 1m30s. |
| `test-copilot-setup.sh` | 3m07s | 3m13s | 3m00s | Its three `swiftc` compiles take about 47–53s before the tests start (B, C). The tests take 91–99s. |
| `test-copilot-shell-reducer.sh`, `test-copilot-hook.sh`, `test-copilot-sandbox.sh` | 8s, 5s, 3s | 12s, 8s, 5s | 12s, 6s, 4s | Compile and run. |
| `test-local-preview.py` | 3m20s | 3m37s | 3m06s | Its bridge is compiled once per suite already, by `test-copilot-setup.sh --compile-only` (18–29s, from `test-performance.md`). |

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

The test build (`.build/tests`, `.Validation.Tests`, `CMUX_VALIDATION`), the
unsigned build (`.build/unsigned`, `.Validation.Unsigned`, `CMUX_VALIDATION`)
and the guide acceptance build (scheme `CMUXMaestroGuideUIValidation`,
`DEBUG CMUX_GUIDE_UI_VALIDATION`, `.Validation.Tests.GuideHost`, no namespace
suffix settings, a fresh DerivedData per invocation) use deliberately different
bundle identifiers, compilation conditions, schemes and DerivedData. Each one proves its own namespace. Sharing their outputs would
let one configuration's success stand in for another's, which #193 forbids.

## Measured cost and benefit of the realistic candidate

DerivedData reuse is the only candidate on the critical path. The test build
takes 3–4 minutes of a 16–18 minute job.

### Method

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
  planning: 25–35% of the build at 3 jobs, 44–48% unthrottled.
- **CI-derived bound.** Planning plus the PCM window is 78s (A), 87s (B) and
  84s (C). The PCM window overlaps other compile tasks, so this is an upper
  bound on what PCM and planning reuse can remove from the CI build.
- **Restore cost is an assumption, not a measurement.** The test build's
  DerivedData, without products or scoped results, is about 550 MB raw and
  173 MB as a `tar` and `zstd` archive (5,302 files). Packing locally took 5s
  and unpacking 7s. The 20–40s assumed for a hosted runner is about 10–20 MB/s
  effective cache download (9–17s) plus 2–3 times the local unpack (14–21s). A
  miss pays a similar cost to save.
- **Projected net saving: about 10–95s.**
  - Low end: 25% of a 191s CI build is 48s, minus a 40s restore.
  - High end: 48% of a 239s CI build is 115s, minus a 20s restore. This is
    above the CI-derived bound, so it is generous.
  - That is about 1–9% of `validate-native`.
  - **The decision holds:** even the high end is below the 2-minute threshold
    under "When to revisit".
  - Run-to-run variation of that one step is already about 2 minutes
    (16m05s–17m59s), and queueing at the macOS concurrency ceiling dominates
    end-to-end time. See [CI runner placement](ci-runner-placement.md).

## Rejected options

| Option | Reason |
| --- | --- |
| Cache the test build's DerivedData | Projected net saving of about 10–95s, below the 2-minute threshold and within run-to-run noise. Restored `Build/Products` keeps resources and binaries the project no longer produces, so it must be dropped. Correctness then rests on Xcode's incremental state across Xcode or runner-image updates. Hosted macOS images update Xcode builds without notice, so the key must include `xcodebuild -version`, the SDK build, the architecture, the settings and the project file. Saving entries of about 170 MB from every pull request would churn the 10 GB repository cache, so saving would be limited to `main`. |
| Cache only precompiled SDK modules (`SDKExplicitPrecompiledModules`, `ModuleCache.noindex`) | No measured gain. Xcode regenerated every PCM without the matching `Build/Intermediates.noindex`. |
| Xcode compilation cache (`CompilationCache.noindex`) | No measured gain when restored into new DerivedData. It adds 558 MB and changes the test namespace's build settings. |
| Cache the pinned SDK checkout | Fetches take 3–12s, so a cache restore would not be faster. The pin already binds the source. |
| Share one build between `test.sh` and `build-unsigned.sh` | Breaks the distinct namespace guarantee: one configuration's success would prove the other. |
| Reuse the unsigned build or the guide probe build in the native job | Guide acceptance must own fresh, invocation-specific evidence and exact source attribution (`run-guide-ui-validation.py` hashes its inputs). |
| #195 handoff: reuse the test build (`.build/tests`) or the setup-tests build for guide acceptance | **Rejected.** The guide build is a different configuration: its own scheme, `CMUX_GUIDE_UI_VALIDATION` instead of `CMUX_VALIDATION`, its own bundle identifiers and no namespace suffixes. The setup-tests build is a `swiftc` command-line binary, not an Xcode app and UI-test bundle. Only PCMs could be shared, and restoring modules alone gave no gain. Its compile phase is 40–51s; the 2m03s–2m24s probe execution dominates and cannot be reused. A fresh DerivedData is part of its attribution. |
| #195 handoff: share the preview bridge compile with `test-copilot-setup.sh` | **Rejected.** The bridge is `test-copilot-setup.sh --compile-only`, which adds `CLIIntegrationGuideRenderingTests.swift` and `GuideAcceptanceEvidence.swift`. Reusing one build for both would change the setup binary's tested source set or couple two suites through mutable `.build/setup-tests` state. At most 18–29s would be saved in `validate-contracts`, which is not the critical path. |
| Cache `test-copilot-setup.sh`, preference-client or hook binaries keyed by source hash | These are test executables whose inputs change in most pull requests. They save at most about 50s, all of it in `validate-contracts`, which finishes before `validate-native`. |
| Reuse test results, `.xcresult` bundles, receipts or screenshots | Never acceptable as proof of a new invocation (#193, #190). |

## When to revisit

Reconsider DerivedData reuse only when a live A/B test on hosted runners (cold
miss against warm hit, same commit) shows a net saving of at least 2 minutes
on the critical path after restore. That is likely only if one of these is
true:

- `build-for-testing` grows beyond about 6 minutes;
- Xcode's compilation cache becomes reusable across DerivedData locations;
- the project moves to persistent or self-hosted runners, where DerivedData
  survives without transfer.

### A coherent future design

- **Exact key, no fallback.** Hash `xcodebuild -version`, the SDK build, the
  architecture, the `test.sh` settings array, `project.pbxproj` and the scheme.
  Do not key on source: a source key would never hit on pull requests. Do not
  use `restore-keys`: partial matches would cross toolchains or settings.
- **Source is recorded, not keyed.** Write the producing commit and key fields
  into a manifest inside the entry and log them on restore. Xcode's own input
  tracking decides what to rebuild. After checkout every Swift file is newer,
  so only PCMs and planning are reused.
- **Validate before use.** If the manifest is missing or its key fields differ
  from the current values, delete the restored directory and build cold. Log
  hit, miss or rejection.
- **Restore before the build, never in place of it.** Delete `Build/Products`
  before building. Run every test as now.
- **Save only from `main`.** Pull requests restore `main`'s entry for the same
  toolchain and project file. A pull request that changes either misses and
  builds cold.
- **Namespaces stay separate.** Only `.build/tests` is restored; never
  `.build/unsigned`, the guide DerivedData, results or evidence.
- **Guard change required.** The guard in
  `scripts/test-build-metadata.py` currently forbids every part of this. It
  must change in the same commit, together with the merge policy and this page.
