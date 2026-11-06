# Metadata supervision regression

[↑ Build and test](../build-and-test.md) | [Watchdog report slots →](watchdog-report-slots.md)

Metadata supervision regression has a test-only, executor-independent
30-second bound for each subcase. A stall records subcase, real deadline
sample count/age and one-second all-thread sample. Then it exits test
host unsuccessfully. The 30 seconds is a diagnostic capture budget, not a new
provider deadline. Original 2-second and 0.1-second
subcase deadlines still determine results. Progress never renews the
diagnostic budget.
Sampler gets three seconds. Then kill its exact unreaped child PID and
give it one second to reap. A separate five-second hard bound signals any still-owned
sampler and fails test host even if diagnostic work stalls. Unconfirmed
cleanup stays explicit, never a success. Diagnostics
preserve observed sampler exit/timeout and reap state separately from optional
`sampleReadError`. Missing sample cannot erase that process outcome.
Host still fails with exit 124. Diagnostics
under `.build/tests/scoped-results/metadata-diagnostics/` are kept, including
partial samples. CI uploads each producer's copy from its own job, after it
runs: integrated tests' copy in the `integrated-test-scope-evidence` artifact
(`validate-native`), and the standalone setup tests' copy, with the complete
`.build/setup-tests/metadata-watchdog/` control evidence directory, in the
`copilot-setup-evidence` artifact (`validate-contracts`). Every upload keeps
missing-file failure behavior.
This exposes a
blocked boundary. It does not establish or repair the cause of a prior CI hang.
Production timeouts, cleanup and all original assertions stay unchanged.
No test now cancels an in-flight metadata exchange.

The watchdog report keeps `runnerMetadataReturned` and
`outerTaskValueReceived` flags, captured at the watchdog deadline. They stay
false unless a caller reports the runner result or task value; no current
integrated test does. False flags do not establish where a continuation is
blocked. Sampler exit/signal/timeout and reap status save independently of a
missing or unreadable sample file. Its error is retained as `sampleReadError`.

[History and hosted status](../../evidence/reference.md#metadata-supervision-regression).
