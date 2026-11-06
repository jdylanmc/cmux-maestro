# Capability matrix: install and orchestration

[↑ Capability matrix](capability-matrix.md) | [↑ Behavioral parity and proof](../behavioral-parity.md)

| Visible capability | Native proof |
|---|---|
| Stable local install, update, rollback and recovery | [test-local-preview.py](../../scripts/test-local-preview.py): `test_first_install_stable_copy_and_exact_registration`, `test_atomic_updates_preserve_one_previous_and_rollback_is_reversible`, `test_ambiguous_recovery_refuses_to_guess` |
| Explicit terminal-backed orchestration | [test-cmux-maestro-orchestrator.py](../../scripts/test-cmux-maestro-orchestrator.py), [SidebarOrchestrationTests](../../CMUXMaestroPreviewTests/SidebarOrchestrationTests.swift), [SidebarLayoutRenderingTests](../../CMUXMaestroPreviewTests/SidebarLayoutRenderingTests.swift), [test-copilot-sandbox.sh](../../scripts/test-copilot-sandbox.sh); `SidebarOrchestrationTests.obsoleteReadCannotEraseCurrentStateOrDuplicatePolling` |

Live validation of explicit terminal-backed orchestration remains operator-gated and unverified.

Runtime evidence and dispositions for each row: [archive](../evidence/behavioral-parity.md#capability-matrix-operations-runtime-evidence).

[Managed polling evidence](../evidence/behavioral-parity.md#capability-matrix-install-and-orchestration).
