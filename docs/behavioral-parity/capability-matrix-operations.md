# Capability matrix: install and orchestration

Part of the [capability matrix](capability-matrix.md) in [behavioral parity and proof](../behavioral-parity.md).

Links point to test files. Named methods identify representative checks,
not the entire coverage of each file. Runtime links identify their actual
acceptance scope.

| Visible capability | Native proof | Runtime evidence or disposition |
|---|---|---|
| Stable local install, update, rollback and recovery | [test-local-preview.py](../../scripts/test-local-preview.py): `test_first_install_stable_copy_and_exact_registration`, `test_atomic_updates_preserve_one_previous_and_rollback_is_reversible`, `test_ambiguous_recovery_refuses_to_guess` | [PR30][r30] verifies real stable installation, signed Debug/Release update, exact rollback and recovery. This is local-preview delivery, not public distribution. |
| Explicit terminal-backed orchestration | [test-cmux-maestro-orchestrator.py](../../scripts/test-cmux-maestro-orchestrator.py): external create/attach/archive ordering, exact surface retention, background-tab startup, exact ownership/resume, strict permission-free `final_answer` reports, caller-explicit private tool policy and descendant non-escalation, visible JSON permission denial, verified-idle report recovery, successful/nonzero/malformed result boundaries, bounded streaming, in-turn heartbeats, live-resource cap/reclamation, archive/recovery, automatic exit and focus contracts, and bounded timestamped Git evidence refresh from explicit working directories; [SidebarOrchestrationTests](../../CMUXMaestroPreviewTests/SidebarOrchestrationTests.swift): exhaustive managed phase titles/symbols, validated ancestry/lifecycle/timestamps, Git evidence status/time, stale qualification and privacy-preserving current-window filtering; [SidebarLayoutRenderingTests](../../CMUXMaestroPreviewTests/SidebarLayoutRenderingTests.swift): regenerated mixed-state render and direct density bounds; [test-copilot-sandbox.sh](../../scripts/test-copilot-sandbox.sh): observer-readable/private-sibling-denied proof | Observer projection adds only bounded verified worktree/branch labels, Git evidence status/time and the exact controlled worker session UUID. Full working directories remain private control data. Git probes run outside the state mutation lock, are batched per exact assigned directory, have a one-second/4 KiB bound and never run in the sandboxed sidebar. Non-Git, missing, detached, timeout, malformed, overlong and failed-query behavior is covered. Live validation remains operator-gated and unverified in this worktree. |

Managed polling fences read success, failure, and task cleanup by generation.
`SidebarOrchestrationTests.obsoleteReadCannotEraseCurrentStateOrDuplicatePolling`
covers late success/missing/unsafe reads, current-task cancellation, and hide/show
restart without erasing newer state or creating extra pollers.

[r30]: https://github.com/jdylanmc/cmux-maestro/pull/30#issuecomment-5661185922
