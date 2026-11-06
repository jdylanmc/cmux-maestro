# Required CI and local acceptance

Required tests assert state and ordering, never that a loaded macOS runner can
schedule work within a few seconds. A real-process readiness/exit bound is a
60-second **hang guard**, not the behavior being asserted. Do not add retries.
Use injected time for expiry, explicit continuations/streams for ordering, and
fixed identities when exercising deliberately tiny probabilistic replay filters.
The shared sidebar hang guard retains **both** the original 300 actor scheduling
opportunities and a 60-second minimum: expiration requires exhausting both.
A wall-only deadline had shortened the old effective bound under full-suite
contention. Injected-clock tests cover both slow and fast actor turns.

## Required behavioral coverage

See [required behavioral coverage](ci-test-determinism/required-behavioral-coverage.md).

### Orchestration, watchers and multiwindow teardown

See [orchestration, watchers and multiwindow teardown](ci-test-determinism/orchestration-watchers-and-multiwindow-teardown.md).

### Installer, preferences and guide acceptance

See [installer, preferences and guide acceptance](ci-test-determinism/installer-preferences-and-guide-acceptance.md).

## Explicit local-only native acceptance

See [explicit local-only native acceptance](ci-test-determinism/explicit-local-only-native-acceptance.md).

## Repeated focused diagnostics

See [repeated focused diagnostics and timing ratchet](ci-test-determinism/repeated-focused-diagnostics.md).

## Timing policy ratchet

See [timing policy ratchet](ci-test-determinism/repeated-focused-diagnostics.md#timing-policy-ratchet).

### Elapsed-time audit (#310)

See [elapsed-time audit (#310)](ci-test-determinism/elapsed-time-audit.md).
