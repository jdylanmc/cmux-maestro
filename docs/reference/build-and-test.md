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
