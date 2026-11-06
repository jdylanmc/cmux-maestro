# Build and test

Requirements, validation entrypoints, test evidence, validation builds. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).
Where suite time goes: [test performance](test-performance.md).

## Requirements

- macOS 14 or newer.
- Xcode 26.6 at `/Applications/Xcode.app` for local builds.
- CMUX with sidebar ExtensionKit support.
- Copilot CLI supporting local plugin installation and the three
  documented command hooks, with canonical session identity in hook input.

The CMUX ExtensionKit package pins CMUX commit
`ae7fbce99f98c98df5ccf915e548dd080d33cfa8` and is fetched into the ignored
`vendor/CmuxExtensionKit/`. No CMUX source changes are required.

**Host footer compatibility:** the native view reserves an absolute 50 points
of bottom clearance for the current CMUX overlaid footer, independent of
density, because the SDK has no footer-inset contract. A rendered-strip
regression test checks that both sidebar modes and densities leave this area
clear. Reverify clearance when host chrome changes.

Workspace containers use eager layout inside the scroll view, and child trees
keep their projection limits. This avoids the lazy root-placement loop seen
during remote accessibility scrolling. An offscreen AppKit regression repeats
scrolling and mode changes in both densities. Live accessibility scrolling and
continued history updates remain part of deployment acceptance.

## Build and test

```sh
./scripts/fetch-sdk.sh
./scripts/build-unsigned.sh
./scripts/test.sh
```

`fetch-sdk.sh` applies the reviewed patches in `scripts/sdk-patches/` to the
pinned SDK, exactly and in name order (ADR 0023).

`test.sh` is the full-coverage entrypoint. It builds once, runs the unchanged
blocking-observer concurrency regression alone in the integrated host, verifies
its exact identity/count from the hosted xcresult, then runs all other tests
from the same build without suite serialization. Both scopes must pass. Before
testing, it enumerates the built test product under the same settings
(`-enumerate-tests`), and the identities reported across both scopes must equal
that inventory: a missing, unexpected or repeated test fails. Disabled tests and
skips need a reason in `INTENTIONAL_SKIPS`. Results and count evidence live
under `.build/tests/scoped-results/`, and the entrypoint rejects selection/retry
overrides. `CopilotReaderTests/coldStartBenchmarkWith230MiBOfIgnoredSyntheticPayloads()`
remains opt-in: its exact skip is attributed only when
`CMUX_MAESTRO_READER_BENCHMARK` is not `"1"`. When enabled, it needs its exact
identity with one nonparameterized passed execution, and a skip or absence
fails coverage. No other optional-test exception is inferred.

### Metadata supervision regression

[Metadata supervision regression](build-and-test/metadata-supervision-regression.md)

#### Watchdog report slots

[Watchdog report slots](build-and-test/watchdog-report-slots.md)

### Setup controls and focused diagnostics

[Setup controls and focused diagnostics](build-and-test/setup-controls-and-focused-diagnostics.md)

### Validation builds

[Validation builds](build-and-test/validation-builds.md)

### Isolated setup, hook and sandbox checks

[Isolated setup, hook and sandbox checks](build-and-test/isolated-setup-hook-and-sandbox-checks.md)

## Orchestrator fixture edges

[Orchestrator fixture edges](build-and-test/orchestrator-fixture-edges.md)
