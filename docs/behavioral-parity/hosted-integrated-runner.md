# Hosted integrated runner

[↑ Behavioral parity and proof](../behavioral-parity.md) | [← Setup fixture readiness](setup-fixture-readiness.md)

The hosted integrated runner builds once, runs the **one unchanged test**
`concurrentSupervisionDoesNotOccupyCooperativeExecutor` alone in the integrated
test host, then runs every remaining test from the same build in a second
invocation. It does not serialize the remaining suite or alter either detached
driver, any assertion or the three-second bound. `xcresulttool` must report
exactly one executed, correctly identified test before that selector may be
excluded from the loaded invocation. Both scopes must pass with explicit
nonzero, reconciled counts; unrelated skipped tests and a repeated concurrency
test are errors. A selector/count extraction failure runs an unfiltered
coverage fallback but **still fails** the command. The runner never retries
until a pass.

The preexisting opt-in
`CopilotReaderTests/coldStartBenchmarkWith230MiBOfIgnoredSyntheticPayloads()`
is the only optional skipped identity. It stays disabled unless the inherited
`CMUX_MAESTRO_READER_BENCHMARK` is exactly `"1"`; when enabled, its exact
identity must have one nonparameterized passed execution, and absence or a skip
fails. The harness records that flag and exact skip attribution with the
verified isolated-selector exclusion, without enabling the benchmark or
rewriting reported counts/details. A skipped parameter, another identity or an
unverified selector exclusion is not permitted. Full fallback remains red even
when the benchmark skip is correctly attributed.

Result accounting separates logical test cases from recorded executions. The
top-level summary must match the tree's complete logical status vector, and
device/configuration counters must match normalized execution statuses.
Parameterized argument groups are not blindly equated with logical parents, and
parameterized evidence without its execution counters is rejected.
Unrecognized execution shapes, contradictory parent/run results, hidden runs
and repetition nodes cannot certify coverage. The known nonparameterized
isolated method must have exactly one non-repeated execution.

Each hosted invocation keeps separate xcresults, raw summary/test JSON and
`coverage.json` under `.build/tests/scoped-results/`. Raw test trees, summaries
and reconciled counts also go to the job log, so the parent verifies the actual
hosted selector and parameter hierarchy instead of accepting a guessed selector
or local standalone count. The inherited-MainActor negative remains sensitive
because the test body and non-yielding observer are unchanged. Earlier hosted
concurrency reds and the separate native viewport-settlement failure remain on
record. Only a necessary current-head hosted run can establish their state.

CI always uploads every scoped-results JSON file as the separate
`integrated-test-scope-evidence` artifact, kept for 14 days, including after
test failure. Missing JSON fails the upload instead of falling back to success.
Full xcresult bundles are not in this diagnostic artifact. The required
`sidebar-layout-offscreen` PNG artifact and all eleven validation commands are
unchanged and required.
