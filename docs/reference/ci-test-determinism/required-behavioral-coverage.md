# Required behavioral coverage

[↑ Required CI and local acceptance](../ci-test-determinism.md) | [Orchestration, watchers and multiwindow teardown →](orchestration-watchers-and-multiwindow-teardown.md)

- Metadata watchdog owned-process controls signal the diagnostic only after
  capturing readiness and the selected runner/task/exit boundary. A 70-second
  independent watchdog is a hang backstop, outside the 60-second readiness
  guard. It no longer races a two-second diagnostic against three-second setup.
  A harness-owned FIFO retains the living child until release, including failure
  cleanup, with a separate 90-second orphan guard. Exited-child coverage waits
  for its exact unreaped POSIX exit before capturing the report. Missing readiness
  remains an explicit not-ready failure, never a KeyError or passing fallback.
  Deadline-sample counts remain assertions only in clock-fault controls.
- Diagnostic publication commits the core readiness/process observation to
  `stall.json` before sampling. One terminal publisher owns sampler cleanup,
  atomic final publication and exit; a second thread cannot interrupt its write.
  `diagnosticOutcome` marks `complete` or `diagnostic-incomplete`. Sampling is
  best effort: its five-second budget can select the latter, which a negative
  control accepts only with every core assertion still satisfied, confirmed
  sampler reaping/absence, and no `stall.json.sb-*` files. Unmarked, partial,
  incorrect-core or uncleaned reports fail. Final file I/O must return before
  this publisher exits. The subprocess harness remains the outer hang guard.
  `samplerStarted: true` requires an exact positive `samplerPID` and confirmed
  reaping. A spawn failure instead publishes `samplerStarted: false`, no PID,
  a `failed:` sample status and a `complete` diagnostic outcome. In that state,
  `samplerReaped: true` means cleanup was unnecessary because no child started;
  no PID absence probe is performed. Missing or contradictory identity still
  fails. The controlled `sampling-spawn-failure` case uses a missing executable;
  core assertions and the no-temporary-files check remain unconditional.
  Explicit signals hold sampling and force backstop publication in all four
  owned modes. Separate controlled completion modes disable the sampling timer
  and the sampler's short wait budget, awaiting its actual exit under the outer
  harness hang guard. They verify sample output and sample-read-error semantics.
  A normal sampler exit that wins a deadline's kill request retains its actual
  exit code, not a synthetic `timed-out/exit-0` status. No elapsed
  time or CPU-load deadline determines their correctness verdict (#364).
- Setup supervision starts both gated children before advancing their injected
  deadlines, so neither can finish early. The observer retains the MainActor versus
  detached-driver distinction. Deadline-helper tests release an explicit timeout
  signal instead of measuring elapsed wall time.
  Cleanup fixtures subscribe to unrelated-process termination before launch and
  await the buffered event after closing stdin, including when an assertion throws.
  They never call Foundation's synchronous `Process.waitUntilExit()`: a local
  reproduction of #302 sampled that call stuck in its run loop after the setup
  supervisor had already completed. The mutation-gate negative control uses the
  same bounded exit helper: repeated-suite sampling also caught its old synchronous
  wait stalled. A controlled missing-notification regression
  advances an injected deadline; a second regression delivers termination before
  cleanup starts. No cleanup coverage was removed.
  Each cleanup phase also has an executor-independent watchdog at
  `supervisedWaitLimit + 10 seconds` (currently 70 seconds), with at most five
  additional seconds for stack capture. The inner 60-second bounds retain their
  full budget and report their own diagnostics first; the watchdog is a backstop
  for non-cooperative stalls, not a shorter replacement timeout. A mutation guard
  checks the configured watchdog from the shared cleanup factory against the
  inner limit, so falling back to the metadata watchdog's 30-second default fails.
  Its phase and supervisor
  boundary records use the existing `metadata-diagnostics` artifact path. This
  backstop covers synchronous fixture work and teardown as well as async waits;
  it exits with failure, never retries or converts a stalled assertion into a pass.
