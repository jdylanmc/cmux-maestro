# Inventory: other suites and existing reuse

Part of [CI setup reuse](../ci-setup-reuse.md). Previous page is [Inventory: sources and validate-native](inventory.md). Next page is [Measured cost and benefit of the realistic candidate](measured-cost-and-benefit-of-the.md).

| Step | A | B | C | Notes |
| --- | --- | --- | --- | --- |
| `build-unsigned.sh` | 1m27s | 1m43s | 2m02s | `xcodebuild build`: 58s, 1m09s and 1m30s. |
| `test-copilot-setup.sh` | 3m07s | 3m13s | 3m00s | Its three `swiftc` compiles take about 47 to 53s before the tests start (B, C). The tests take 91 to 99s. |
| `test-copilot-shell-reducer.sh`, `test-copilot-hook.sh`, `test-copilot-sandbox.sh` | 8s, 5s, 3s | 12s, 8s, 5s | 12s, 6s, 4s | Compile and run. |
| `test-local-preview.py` | 3m20s | 3m37s | 3m06s | Its bridge is compiled once per suite already, by `test-copilot-setup.sh --compile-only` (18 to 29s, from `test-performance.md`). |

## `guide-ui-consumer-probe`

- SDK fetch: 10s, 3s and 6s.
- Probe build and run: 1m28s, 57s and 1m17s.
- The probe uses a fresh DerivedData directory per invocation by design.

## Existing reuse within a run

- `fetch-sdk.sh` is idempotent within a job. Once the SDK commit stamp
  matches, later calls report `already pinned` and do no work.
- Preview tests compile their bridge once per suite.
- No build output crosses jobs or runs.

## Configurations that are not repetition

The test build (`.build/tests`, `.Validation.Tests`, `CMUX_VALIDATION`), the
unsigned build (`.build/unsigned`, `.Validation.Unsigned`, `CMUX_VALIDATION`)
and the guide acceptance build (scheme `CMUXMaestroGuideUIValidation`,
`DEBUG CMUX_GUIDE_UI_VALIDATION`, `.Validation.Tests.GuideHost`, no namespace
suffix settings, a fresh DerivedData per invocation) use deliberately different
bundle identifiers, compilation conditions, schemes and DerivedData. Each one proves its own namespace. Sharing their outputs would
let one configuration's success stand in for another's, which #193 forbids.
