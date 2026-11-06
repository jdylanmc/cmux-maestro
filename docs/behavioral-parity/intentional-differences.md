# Intentional differences and explicit limits

[↑ Behavioral parity and proof](../behavioral-parity.md)

- **No observer service or loopback transport** (#9 and #12 superseded): [ADR 0001](../adr/0001-sandboxed-sidebar-reads-sanitized-evidence.md), [ADR 0013](../adr/0013-hookless-plugin-and-dedicated-observer-hook.md).
- **Managed control is external and explicit**: [ADR 0004](../adr/0004-interactive-workers-only.md), [managed hierarchy, launch, and close](../reference/hierarchy-launch-lifecycle.md).
- **Neutral contract versus adapter internals** (#10): [snapshot schema and validation](../reference/reader-lifecycle/snapshot-schema.md); tests [`CopilotSnapshotAdapterTests.swift`](../../CMUXMaestroPreviewTests/CopilotSnapshotAdapterTests.swift), [`AgentSnapshotCompatibilityTests.swift`](../../CMUXMaestroPreviewTests/AgentSnapshotCompatibilityTests.swift), [`LegacySnapshotValidationTests.swift`](../../CMUXMaestroPreviewTests/LegacySnapshotValidationTests.swift), [`NeutralObservationValidationTests.swift`](../../CMUXMaestroPreviewTests/NeutralObservationValidationTests.swift).
- **Unsupported telemetry stays unknown**: [ADR 0003](../adr/0003-liveness-work-attention-completion-stay-separate.md).
- **Bounded uncertainty is visible**: [ADR 0010](../adr/0010-history-fails-open-replay-fails-closed.md).
- **Accessibility evidence has boundaries**: no spoken VoiceOver testing or global keyboard/contrast change is claimed.
- **Uninstall and cutover are deliberately limited**: [remove only the owned local preview](../reference/install/remove-local-preview.md); test `test_uninstall_requires_explicit_hook_retirement_keeps_all_user_data`.
- **Update preparation is explicit** ([PR33](https://github.com/jdylanmc/cmux-maestro/pull/33#issuecomment-5661869270)): [update, rollback and status](../reference/install/update-and-rollback.md).

With these dispositions the visible-capability inventory has no unexplained gaps. The full disposition text, its tests and its limits are archived. [Archived evidence](../evidence/behavioral-parity.md#intentional-differences-and-explicit-limits).
