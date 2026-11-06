# Hosted integrated runner

[↑ Behavioral parity and proof](../behavioral-parity.md) | [← Setup fixture readiness](setup-fixture-readiness.md)

Contract: [Build and test](../reference/build-and-test.md), [Required behavioral coverage](../reference/ci-test-determinism/required-behavioral-coverage.md).

Tests:

- [`run-integrated-test-scopes.py`](../../scripts/run-integrated-test-scopes.py)
- [`CopilotSetupTests.swift`](../../CMUXMaestroPreviewTests/CopilotSetupTests.swift): `concurrentSupervisionDoesNotOccupyCooperativeExecutor`
- [`CopilotReaderTests.swift`](../../CMUXMaestroPreviewTests/CopilotReaderTests.swift): `coldStartBenchmarkWith230MiBOfIgnoredSyntheticPayloads()`

Evidence, test inventories and limits: [archive](../evidence/behavioral-parity.md#hosted-integrated-runner).
