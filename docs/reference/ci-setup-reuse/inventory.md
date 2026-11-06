# Inventory: sources and validate-native

[↑ CI setup reuse](../ci-setup-reuse.md) | [Inventory: other suites and existing reuse →](validate-contracts.md)

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
