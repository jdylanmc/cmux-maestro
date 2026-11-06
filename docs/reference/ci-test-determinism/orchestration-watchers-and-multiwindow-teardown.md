# Orchestration, watchers and multiwindow teardown

[↑ Required CI and local acceptance](../ci-test-determinism.md) | [← Required behavioral coverage](required-behavioral-coverage.md) | [Installer, preferences and guide acceptance →](installer-preferences-and-guide-acceptance.md)

- Orchestration snapshots and naming use an injected clock. Polling tests await
  publication at the existing pause boundary rather than counting scheduler yields.
  Cadence fixtures suspend until cancellation, never a 60-second accidental tick.
- Watcher invalidation tests hold stream consumption after an ordinary change,
  exposing any read that overtakes lease termination. The registration prerequisite
  throws before awaiting a replacement, and teardown releases controlled reads:
  an invalidation-ordering regression reports a failure instead of stranding the
  native job. Rename, delete, revoke and combined write/rename retain coverage (#368).
- Multiwindow teardown awaits a subscribed scene publication, not host-local
  connection invalidation. The shared-scene test still sends its final snapshot
  during teardown. Synthetic endpoint and publication durations distinguish XPC
  propagation from actor scheduling; these measurements are diagnostics, not
  speed assertions. Each of the two teardown tests writes five small immutable
  phase JSON files as events occur. CI always uploads them separately as
  `multiwindow-teardown-phases`, independent of xcresult export and its size cap.
  The earlier hosted failure's exported diagnostics exceeded
  the artifact cap, so they do not establish which stage stalled.
  In #327 (run `39870017753`), both native invalidation callbacks were still
  missing when the separate-scene test timed out. The retained phase files
  recorded them about 193 seconds after close, after failure cleanup cancelled
  the scene observer. This is load-associated XPC callback latency, not evidence
  that a delivered invalidation failed to clear product scene state; the exact
  underlying scheduler stall was not captured. `observe` already delivers the
  current scene state synchronously.
  All six `SidebarMultiWindowTests` now run in a dedicated **required** native
  invocation, outside the loaded parallel complement. Their bodies, real XPC
  connections, hang guards and phase instrumentation are unchanged. No retry,
  optional venue or coverage removal is introduced. The runner requires the
  exact six method identities and one passed nonparameterized execution each
  before excluding the suite from the complement. A missing, added, failed,
  skipped or repeated method fails closed; additions must update the reviewed
  expected inventory. Whole-product enumeration still reconciles all scopes.
  `ci-gate` downloads that run's native artifact and independently checks its
  clean workflow commit/run identity, dedicated test names, counts and results.
  Missing or ambiguous evidence blocks the gate even if the native job reports
  success. Isolation removes the known cross-suite load; it does not promise
  bounded OS scheduling or prove live ExtensionKit behavior.
