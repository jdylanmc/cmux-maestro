# Setup fixture readiness

[↑ Behavioral parity and proof](../behavioral-parity.md) | [Hosted integrated runner →](hosted-integrated-runner.md)

Contract: [Build and test](../reference/build-and-test.md), [Required behavioral coverage](../reference/ci-test-determinism/required-behavioral-coverage.md).

Tests:

- [`CopilotSetupTests.swift`](../../CMUXMaestroPreviewTests/CopilotSetupTests.swift): `queuedStartupDoesNotConsumeChildReadinessBudget`, `lateQueuedStartupRetainsFullChildReadinessBudget`, `concurrentSupervisionDoesNotOccupyCooperativeExecutor`

Evidence, test inventories and limits: [archive](../evidence/behavioral-parity.md#setup-fixture-readiness).
