# Intentional differences and explicit limits

[↑ Behavioral parity and proof](../behavioral-parity.md)

- **No observer service or loopback transport** (#9 and #12 superseded): [ADR 0001](../adr/0001-sandboxed-sidebar-reads-sanitized-evidence.md), [ADR 0013](../adr/0013-hookless-plugin-and-dedicated-observer-hook.md). Dismissal and acknowledgement cannot approve, answer, stop or otherwise control the provider.
- **Managed control is external and explicit**: [ADR 0004](../adr/0004-interactive-workers-only.md), [managed hierarchy, launch, and close](../reference/hierarchy-launch-lifecycle.md).
- **Neutral contract versus adapter internals** (#10): [snapshot schema and validation](../reference/reader-lifecycle/snapshot-schema.md); tests [`CopilotSnapshotAdapterTests.swift`](../../CMUXMaestroPreviewTests/CopilotSnapshotAdapterTests.swift), [`AgentSnapshotCompatibilityTests.swift`](../../CMUXMaestroPreviewTests/AgentSnapshotCompatibilityTests.swift), [`LegacySnapshotValidationTests.swift`](../../CMUXMaestroPreviewTests/LegacySnapshotValidationTests.swift), [`NeutralObservationValidationTests.swift`](../../CMUXMaestroPreviewTests/NeutralObservationValidationTests.swift). No hook policy, independent child focus/resume capability or new runtime is introduced.
- **Unsupported telemetry stays unknown**: [ADR 0003](../adr/0003-liveness-work-attention-completion-stay-separate.md).
- **Bounded uncertainty is visible**: [ADR 0010](../adr/0010-history-fails-open-replay-fails-closed.md).
- **Accessibility evidence has boundaries**: no spoken VoiceOver testing or global keyboard/contrast change is claimed.
- **Uninstall and cutover are deliberately limited**: [remove only the owned local preview](../reference/install/remove-local-preview.md), with test `test_uninstall_requires_explicit_hook_retirement_keeps_all_user_data`. Public licensing, notarization and disabling/retiring the legacy plugin remain operator decisions.
- **Update preparation is explicit** ([PR33](https://github.com/jdylanmc/cmux-maestro/pull/33#issuecomment-5661869270)): [update, rollback and status](../reference/install/update-and-rollback.md).

With these dispositions the visible-capability inventory has no unexplained gaps. That is not a new exhaustive legacy audit, a claim that all operator-gated work is finished, or permission to weaken future regression and live-verification gates. The full disposition text, its tests and its limits are archived. [Archived evidence](../evidence/behavioral-parity.md#intentional-differences-and-explicit-limits).
