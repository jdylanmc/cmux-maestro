# Inventory: other suites and existing reuse

[↑ CI setup reuse](../ci-setup-reuse.md)

Per-step timings of the other suites and the guide probe are [archived](../../evidence/ci.md#inventory-other-suites-and-existing-reuse).

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
