# Orchestrator suite evidence

Part of [test performance](../test-performance.md). Previous page is [Orchestrator suite](orchestrator-suite.md). Next page is [Local preview suite, Swift tests and next steps](local-preview-and-swift.md).

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
