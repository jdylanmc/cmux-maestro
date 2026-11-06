# Setup fixture readiness

[↑ Behavioral parity and proof](../behavioral-parity.md) | [Hosted integrated runner →](hosted-integrated-runner.md)

Process-cleanup tests wait for the injected clock's first post-`posix_spawn`
sample before arming the unchanged three-second child-readiness watchdog. The
test clock publishes a bounded one-shot signal; a driver that returns without
spawning closes it, and a cancelled waiter unwinds. This separates
task/dispatch scheduling from the fixture's readiness requirement without
changing the production runner, its timeout or executor policy.

`queuedStartupDoesNotConsumeChildReadinessBudget` and
`lateQueuedStartupRetainsFullChildReadinessBudget` hold the test driver for
four and 2.7 seconds before invoking the runner. Under the old watchdog
ordering they reproduced both the no-launch and the started-but-unfinished
delay failures. The corrected ordering keeps every timeout/cancellation, exact
process-group/reaping, unrelated-process and late-write assertion. The real
0.6-second launcher delay and frozen 0.4-second product deadline are unchanged.
These controlled probes report a non-actor-isolated driver; they do not
establish MainActor inheritance or measure hosted dispatch latency.

Early unavailable/cancelled runner outcomes, waiter cancellation, and a started
runner without a ready writer are separate controls. The independent
non-yielding `concurrentSupervisionDoesNotOccupyCooperativeExecutor` observer
keeps its three-second budget and detached drivers. The change adds no suite
serialization, startup retry or larger readiness timeout. Startup observation
has no added wall-time limit before the first sample; the dedicated concurrency
test remains the bounded dispatch-progress regression.
