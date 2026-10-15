# Build and test

Requirements, validation entrypoints, test evidence, validation builds. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).
Where suite time goes: [test performance](test-performance.md).

## Requirements

- macOS 14 or newer.
- Xcode 26.6 at `/Applications/Xcode.app` for local builds.
- CMUX with sidebar ExtensionKit support.
- Copilot CLI supporting local plugin installation and the three
  documented command hooks, with canonical session identity in hook input.

CMUX ExtensionKit package pins to CMUX commit
`ae7fbce99f98c98df5ccf915e548dd080d33cfa8`. Fetch goes into ignored
`vendor/CmuxExtensionKit/`. No CMUX source changes required.

**Host footer compatibility:** native view reserves absolute 50 points of
bottom clearance for current CMUX overlaid footer, independent of density.
SDK provides no footer-inset contract. Rendered-strip regression test checks
both sidebar modes and densities leave this area clear. Reverify clearance
when host chrome changes.

Workspace containers use eager layout inside scroll view. Child trees
keep existing projection limits. This avoids lazy root-placement loop
seen during remote accessibility scrolling. Offscreen AppKit regression
exercises repeated scrolling and mode changes in both densities. Live accessibility scrolling and
continued history updates stay part of deployment acceptance.

## Build and test

```sh
./scripts/fetch-sdk.sh
./scripts/build-unsigned.sh
./scripts/test.sh
```

`fetch-sdk.sh` applies the reviewed patches in `scripts/sdk-patches/` to the
pinned SDK, exactly and in name order (ADR 0023).

`test.sh` is the full-coverage entrypoint. It builds once. It runs the unchanged
blocking-observer concurrency regression alone in the integrated host. It verifies
exact identity/count from the hosted xcresult. Then it runs all other tests
from that same build without suite serialization. Both scopes must pass.
Before testing, it enumerates the built test product under the same settings
(`-enumerate-tests`). Reported identities across both scopes must equal that
inventory; a missing, unexpected or repeated test fails. Disabled tests and
skips need a reason in `INTENTIONAL_SKIPS`.
Results and count evidence stay under `.build/tests/scoped-results/`.
This full-coverage entrypoint rejects selection/retry overrides.
Existing `CopilotReaderTests/coldStartBenchmarkWith230MiBOfIgnoredSyntheticPayloads()`
stays opt-in. Attribute its exact skip only when
`CMUX_MAESTRO_READER_BENCHMARK` is not `"1"`. When enabled, a skip fails coverage.
Enabled runs require its exact identity with one nonparameterized passed
execution. Absent benchmark also fails coverage. Infer no other optional-test
exception.

Metadata supervision regression has a test-only, executor-independent
30-second bound for each subcase. A stall records subcase, real deadline
sample count/age and one-second all-thread sample. Then it exits test
host unsuccessfully. The 30 seconds is a diagnostic capture budget, not a new
provider deadline. It exceeds twice the observed 12.002-second passing integrated
test. This leaves contention headroom. Original 2-second and 0.1-second
subcase deadlines still determine results. Progress never renews the
diagnostic budget. Hosted behavior still needs verification.
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
The separate metadata-cancellation test (#174,
`cancellingMetadataStopsItsOwnedProcessBeforeReturning(launchDelay:)`) was
removed on 2026-10-15 by owner decision after intermittent stalls whose cause
was not established. No test now cancels an in-flight metadata exchange.

The watchdog report keeps `runnerMetadataReturned` and
`outerTaskValueReceived` flags, captured at the watchdog deadline. They stay
false unless a caller reports the runner result or task value; no current
integrated test does. False flags do not establish where a continuation is
blocked. Sampler exit/signal/timeout and reap status save independently of a
missing or unreadable sample file. Its error is retained as `sampleReadError`.

`CopilotSetupObservation` remains for diagnosis. Only the
`MetadataWatchdogProbe` `diagnostic-*` controls and `CopilotSetupObservationTests`
inject one; normal runners keep `observation == nil`: no observation storage,
callbacks, queries or logging enable automatically. Optional
`stall.json.supervision` version 1 snapshot contains 14 fixed numeric
boundary slots:

| Index | Boundary | Index | Boundary |
| --- | --- | --- | --- |
| 0 | Test `cancel()` call | 7 | TERM syscall |
| 1 | Cancellation handler | 8 | KILL syscall |
| 2 | Synchronous execute | 9 | Exact-child reap |
| 3 | Exchange poll | 10 | Continuation resume call |
| 4 | Child-state wait | 11 | Async invoke return edge |
| 5 | Group quiescence | 12 | Metadata return edge |
| 6 | Owned-group stop | 13 | Test task-value await |

Each slot retains own `begin`, `end`, `detailSequence` and last numeric
`detail`. Zero means not observed. End greater than begin means the
boundary's end marker was reached. Async invoke/metadata markers run at
their return edges. Existing outer flags separately prove caller receipt.
Sequence numbers order observations, not elapsed time.
Repeated queries replace only own completed slot. Outstanding begin
cannot be overwritten. `overflow` or `invalidTransition` forbids treating the
record as complete. `availability: 1` means snapshot lock contention, with no
boundary data. `0` means available. Failure dump never waits for the
observation lock, cancellation lock or supervisor to finish.

Detail reasons: 0 unknown, 1 cancellation observed, 2 child running,
3 child exited, 4 child unavailable, 5 quiescent, 6 living group member,
7 enumeration unavailable/full, 8 member query unknown and 9 membership changed.
Result/error/PID/status/code/count fields come only from existing supervisor
queries and syscalls. Zero `detailSequence` means even zero-valued fields are
unknown. Snapshot adds no process enumeration or provider data and has a
tested 8 KiB encoded bound. Serialization runs after releasing observation
locks. Snapshot may be unavailable while a tiny record update is in progress.

Slot order is not causality: resume-return and async-caller progress are
distinct, and these diagnostics neither shorten cleanup nor establish a
historical cause.

`test-copilot-setup.sh` also runs disposable Foundation-only controls: successful
disarming, stalled injected clock, continued polling of frozen clock, and
a real stuck sampler that writes partial output before ignoring termination.
Both stalled controls must fail with sampled actual-runner stacks. Unexpected
return, missing stack or outer probe timeout fails validation. Sampler-fault
control must fail after killing and reaping its exact child while preserving
partial output. It does not stand in for real stack-collection acceptance.
Three additional finite fake-sampler controls distinguish exit 17 without output,
exit 17 with output, and timeout without output. Missing-file controls require
both original process outcome and explicit sample-read failure.
Additional finite controls distinguish living, exited-but-unreaped, and returned/reaped
child contexts from outer task completing. Changed-start and truncated-group
controls query only newly owned fixture processes and must retain unknown states.
Every stalled control still exits 124. Successful disarming still exits zero.
Three synthetic no-metadata-child controls exercise cancellation pending,
cancellation returned with execute still pending, and held observation lock.
They require bounded persisted diagnostics and original exit 124, not
successful cancellation or reproduced native hang. Focused non-UI checks:

```sh
./scripts/test-copilot-setup.sh --compile-only
.build/setup-tests/setup-tests --filter CopilotSetupObservationTests
python3 scripts/test-metadata-watchdog.py \
  --probe .build/setup-tests/metadata-watchdog-probe \
  --results-root .build/setup-tests/metadata-watchdog \
  --mode diagnostic-cancel-pending --mode diagnostic-cancel-returned \
  --mode diagnostic-lock-held
```

Navigation response-ordering fixtures inject a cancellation-aware,
non-expiring deadline through connection model's navigation dependency.
Unrelated hosted main-actor delays must not turn those ordering checks into a
wall-clock timeout test. Separate injected-deadline control requires timeout
and rejection of late host success. Existing real-delay timeout test remains.
Default connection construction still uses the unchanged ten-second production
deadline.

Focused history/preference diagnostics after building validation products
(not a full-suite pass):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project CMUXMaestroPreview.xcodeproj -scheme CMUXMaestroPreview \
  -configuration Debug -derivedDataPath .build/tests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CMUX_BUNDLE_ID_SUFFIX=.Validation.Tests \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_VALIDATION' \
  CMUX_SIDEBAR_EXTENSION_POINT_ID=com.jdylanmc.CMUXMaestroPreview.validation.tests.sidebar \
  test-without-building \
  -only-testing:CMUXMaestroPreviewTests/SidebarPreferencesTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarHistoryTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarHistoryPollingTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarPreferenceCoordinationTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarAttentionTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarAttentionCoordinationTests
```

Test runner compiles a fixture-only client from production preference
sources. Tests inject unique defaults suites and files beneath
`.build/preference-coordination/`. They never mutate production preferences.
File-I/O-heavy preference suites serialize independent cases and yield between
fixture phases. This stops synchronous coordination starving unrelated UI timers.
Dedicated coordination tests still exercise simultaneously blocked writers in
separate processes and automatic observation, without manual refresh.

Xcode can register macOS app outputs with LaunchServices even when signing is
disabled. Validation builds therefore use isolated identities **and** isolated
extension points. No supported registration-suppression setting exists:

| Script | App bundle ID suffix | Extension point |
| --- | --- | --- |
| `build-unsigned.sh` | `.Validation.Unsigned` | `com.jdylanmc.CMUXMaestroPreview.validation.unsigned.sidebar` |
| `test.sh` | `.Validation.Tests` | `com.jdylanmc.CMUXMaestroPreview.validation.tests.sidebar` |

Sidebar, helper and test bundle IDs use the same suffix. These copies cannot
replace production identity or appear under CMUX's real sidebar point,
even if Xcode registers them. They are validation artifacts, not installable
CMUX sidebar providers. Do not use their installer UI for integration setup.
Scripts verify resolved settings before building and
resulting app/extension metadata afterward. Run these scripts, not
an unqualified application build, while a native integration is installed.

Validation builds also compile a settings-only app scene: test runs do not open
the Copilot setup window. If opened manually, a validation copy shows only a
read-only explanation. Install and uninstall are rejected before executable
lookup, filesystem access, or CLI invocation unless containing app has the
exact production bundle identity. Use installed production app for setup,
never a window labelled **Test Validation** or **Unsigned Validation**.
Resolved build checks require the no-window compilation condition for validation
and reject it for production. Tests cover both zero-window host and
zero-side-effect install/uninstall denial. Fake production setup tests explicitly
inject production identity.

Focused, isolated setup, hook, and sandbox checks (no SDK fetch or app launch):

```sh
./scripts/test-copilot-hook.sh
./scripts/test-copilot-setup.sh
./scripts/test-copilot-sandbox.sh
python3 ./scripts/test-build-metadata.py
python3 ./scripts/test-local-preview.py
```

Tests use synthetic roots and injected installer/process seams. Standalone
hook smoke compiles production and **separately test-flagged** executables,
invokes them from a foreign working directory, and checks binding creation,
malformed input, disable flags, and zero output. Injected ancestry exists
only in that synthetic binary. App Debug/Release builds have no environment or
command-line switch that forges owner proof. Installer tests invoke fake
executables only, never the live Copilot plugin CLI.

Sandbox check compiles the actual shared file helper and runs it under a
narrow `sandbox-exec` policy over a synthetic deep directory. Ancestors use
search-only descriptors. Final directory still requires read access.
Check denies ancestor contents, sibling reads, and writes. It exercises
owner checks, symlink rejection, and descriptor anchoring during path swaps.
Fixtures are removed afterward. This check creates no App Sandbox container.
`O_SEARCH` is declared in Apple's
[macOS 14-era XNU headers](https://github.com/apple-oss-distributions/xnu/blob/xnu-10002.1.13/bsd/sys/fcntl.h#L184)
and [macOS 15-era headers](https://github.com/apple-oss-distributions/xnu/blob/xnu-11215.1.10/bsd/sys/fcntl.h#L184),
covering this project's macOS 14 deployment target.

These tests do **not** prove actual plugin installation, cached-hook loading,
live owner ancestry, or ExtensionKit-hosted runtime behavior.

## Orchestrator fixture edges

The shipped orchestrator reads no test variables and has no testing mode.
Worker admission's parent-evidence check and identity-helper proof always run.
Fixture launches use `native-spawn` from a coordinator holding managed-session
evidence: a live synthetic provider, a recorded launch policy and its adapter's
private route. Tests about runs from before that admission seed a registered
root explicitly. The Python suites fake only the outside world:

- `HOME` selects the synthetic Orchestration and Beats stores.
- `PATH` supplies synthetic `cmux`, `copilot` and `gh` executables.
- An installed-style `identity-helper.json` beside a copied controller selects
  a synthetic identity helper.
- The synthetic host (`FAKE_ATTACH_BARRIER`, `FAKE_ATTACH_FAILURE`) holds or
  fails the creator's first `identify` of a new surface.
- `controller-fixture.py`, written by `scripts/test-cmux-maestro-orchestrator.py`,
  applies `scripts/test-fixtures/orchestrator-controller-edges.py`, the only
  reader of `FAKE_STARTUP_SECONDS`, `FAKE_HEARTBEAT_SECONDS`,
  `FAKE_ARCHIVE_SECONDS` and `FAKE_GIT`. It also becomes the re-entry point for
  runtimes and terminals. It loads the controller and those edges, not the whole
  suite, through one run-scoped bytecode cache.

Worker Copilot processes receive only the controller's `CMUX_MAESTRO_`
allowlist. Bounded runtimes build the provider environment without any inherited
`CMUX_MAESTRO_` key. A direct launch's sourced script resets each allowlisted
name and the recorded launch `PATH`, then `exec`s the controller's `direct-exec`
bootstrap. It builds the provider environment as a mapping that drops every other
`CMUX_MAESTRO_` key, including names that are not shell identifiers, and
`execve`s the provider in place. Other variables such as `HOME` pass through.
