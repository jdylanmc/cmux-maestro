# Sources and separating the costs

Part of [test performance](../test-performance.md). Next page is [Orchestrator suite](orchestrator-suite.md).

- **CI:** PR run 38662873916 (`validate` job, macOS GitHub-hosted runner).
  Step times come from the jobs API; test times come from the suites' own
  `Ran N tests in` lines and Swift Testing `passed after` lines in the job log.
- **Local:** one 18-core Apple silicon Mac shared with other agents, Xcode's
  `/usr/bin/python3` (3.9). Per-test times come from a scratch `unittest`
  runner with a timing result class. The suites were not changed to measure.
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
