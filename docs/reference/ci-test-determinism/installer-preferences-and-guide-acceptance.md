# Installer, preferences and guide acceptance

[↑ Required CI and local acceptance](../ci-test-determinism.md) | [← Orchestration, watchers and multiwindow teardown](orchestration-watchers-and-multiwindow-teardown.md) | [Explicit local-only native acceptance →](explicit-local-only-native-acceptance.md)

- A denied installer process-group probe is conservatively treated as present.
  Only proven absence permits recovery; a transient permission refusal cannot
  crash a completion wait or release its retained guard.
- The installer bridge-death fixture publishes one atomic FIFO readiness record
  only after opening its release channel. Its 60-second readiness hang guard
  covers the full upgrade and compensating restore, not a 15-second startup
  budget. Buffered readiness wins over a delayed observer; installer exit before
  readiness reports its synthetic failure. Cleanup buffers release even when
  readiness was not consumed, so an assertion cannot strand the gated provider.
  All four bridge/guardian-death variants still assert the lease and restoration
  ordering. The failure was reproduced under bounded local CPU pressure (#345);
  no CI rerun or elapsed-time assertion is used as evidence of correctness.
- Cross-process preference tests still exercise real locks, writes, file
  presentation, and existing observable projections. Their 60-second bounds only
  detect a missing event. No manual refresh substitutes for notification delivery.
- The replay saturation fixture fixes setup event identities before applying
  pressure. A random false positive in its one-word filter is not a product defect.
- Guide acceptance remains required. The historical missing-evidence failures
  came from producer source-attribution rejection, not lost environment
  forwarding. Raw `git cat-file commit` parents bind the exact workflow commit,
  tree and candidate. The event's base SHA may precede a merge or retarget:
  the actual first parent must equal or descend from that event base, or match
  the current base tip returned by one bounded GitHub lookup for this repository,
  PR and exact candidate. Native CI fetches complete history for ancestry checks.
  The lookup's read-only token is excluded from producer build/test environments
  and consumer forwarding. Expected/actual parents and the selected proof are
  retained even when attribution fails.
- Failed guide production stops the dependent native invocation immediately,
  retains its original diagnostic in `coverage.json`, and fails the job.
  Consumers never run with knowingly absent evidence; this is a failed
  prerequisite, not an accepted skip or reduced coverage on a passing run.
  Real-Git regressions accept an advanced or verified retargeted base and reject
  a wrong candidate or unrelated first parent. A forwarding regression verifies
  both original consumer actions receive only fresh successful-producer evidence.
