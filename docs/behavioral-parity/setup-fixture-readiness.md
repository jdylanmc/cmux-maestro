# Setup fixture readiness

Part of [behavioral parity and proof](../behavioral-parity.md). The hosted runner that executes these tests is in [hosted integrated runner](hosted-integrated-runner.md).

Process-cleanup tests wait for the injected clock's first post-`posix_spawn`
sample before arming the unchanged three-second child-readiness watchdog.
The test clock publishes a bounded one-shot signal; a driver that returns
without spawning closes that signal, and a cancelled waiter unwinds. This
separates task/dispatch scheduling from the fixture's readiness requirement
without changing the production runner, its timeout, or executor policy.

`queuedStartupDoesNotConsumeChildReadinessBudget` and
`lateQueuedStartupRetainsFullChildReadinessBudget` hold the test driver before
invoking the runner for four and 2.7 seconds respectively. With the old
watchdog ordering they reproduced both no-launch and started-but-unfinished
delay failures; the corrected ordering preserves all timeout/cancellation,
exact process-group/reaping, unrelated-process and late-write assertions.
The real 0.6-second launcher delay and frozen 0.4-second product deadline
remain unchanged. These controlled probes report a non-actor-isolated driver;
they do not establish MainActor inheritance or measure hosted dispatch latency.

Early unavailable/cancelled runner outcomes, waiter cancellation, and a
started runner without a ready writer are separate controls. The independent
non-yielding `concurrentSupervisionDoesNotOccupyCooperativeExecutor` observer
retains its three-second budget and detached drivers. The change adds no suite
serialization, startup retry or larger readiness timeout. Startup observation
has no added wall-time limit before the first sample; the existing dedicated
concurrency test remains the bounded dispatch-progress regression.
