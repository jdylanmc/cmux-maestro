# Intentional differences and explicit limits

Part of [behavioral parity and proof](../behavioral-parity.md).

- **No observer service or loopback transport.** The proposals in
  [#9](https://github.com/jdylanmc/cmux-maestro/issues/9) and
  [#12](https://github.com/jdylanmc/cmux-maestro/issues/12) are superseded.
  The optional identity hook is non-vetoing; the sandboxed sidebar reads
  directly. Focus is a CMUX action. Dismissal and acknowledgement cannot approve,
  answer, stop or otherwise control the provider.
- **Managed control is external and explicit.** The sandboxed sidebar remains
  read-only. A separately installed local command creates unfocused terminal
  tabs through supported CMUX CLI UUID operations and launches exact Copilot
  session IDs. It stores private control data outside the sidebar-readable
  projection. It does not inspect or reconstruct Copilot's hidden subagent
  graph, approve tools, delete tabs, stop sessions, or fall back to
  `--continue`, recent sessions, titles, paths, focus, or terminal text.
- **Neutral contract versus adapter internals.** The versioned
  [AgentSessionSnapshot](../../CMUXMaestroPreview/Domain/AgentSessionSnapshot.swift)
  now feeds live polling and projection through the pure
  [CopilotSnapshotAdapter](../../CMUXMaestroPreview/CopilotShared/CopilotSnapshotAdapter.swift).
  `CopilotSnapshot` remains the reader's parsing result, not a sidebar envelope.
  Optional typed evidence preserves idle/failure/cancellation separately from
  legacy `done`, liveness independently from work, and launch placement separately
  from current host binding. The existing `childWork` always remains a valid
  nested v1 hierarchy. An extra `childWorkObservation` carries ordered literal
  edges and explicitly marks lossy legacy projections without fabricated parents.
  [Adapter tests](../../CMUXMaestroPreviewTests/CopilotSnapshotAdapterTests.swift)
  exercise the real polling reader seam and unknown/partial evidence.
  [Compatibility tests](../../CMUXMaestroPreviewTests/AgentSnapshotCompatibilityTests.swift)
  retain the negative unsupported-state control.
  [Actual frozen validation](../../CMUXMaestroPreviewTests/LegacySnapshotValidationTests.swift)
  checks the original codec and validator against fixtures and new graph shapes.
  [Consumer validation](../../CMUXMaestroPreviewTests/NeutralObservationValidationTests.swift)
  exercises malformed neutral projection and polling, safe peers, retained active
  descendants, history protection and bounded traversal with explicit unknown
  omission totals. This delivers the literal
  [#10](https://github.com/jdylanmc/cmux-maestro/issues/10) data path, not all of
  #118's lifetime correspondence, recovery, ownership or control gates. No hook
  policy, independent child focus/resume capability or new runtime is introduced.
- **Unsupported telemetry stays unknown.** No guessed token/context percentage
  or hang diagnosis substitutes for unavailable provider evidence.
- **Bounded uncertainty is visible.** Read/display limits, missing ancestry,
  unresolved turn causality and replay-filter uncertainty must not preserve
  obsolete completion as proof that new work ended.
- **Accessibility evidence has boundaries.** Native accessibility-tree semantics,
  representative layout checks and synthetic contrast coverage do not constitute
  spoken VoiceOver testing or a change to global keyboard/contrast settings.
- **Uninstall and cutover are deliberately limited.** Live uninstall was not
  performed while cached hooks remained active.
  `test_uninstall_requires_explicit_hook_retirement_keeps_all_user_data`
  verifies its guard. Public licensing, notarization and disabling/retiring the
  legacy plugin remain operator decisions. Coexistence is intentional.
- **Update preparation is explicit.** [PR33][r33] exposes guarded registration
  retirement without deleting files or signalling CLI sessions. Its public
  prepare/recover flow restored the exact receipt and verified registration;
  synthetic tests also cover one-call recovery after a prepared update
  fails during copying or before replacement.

After these dispositions, this visible-capability inventory has no
unexplained gaps. This statement is not a new exhaustive legacy audit, a claim that
all operator-gated work is finished, or permission to weaken future regression
and live-verification gates.

[r33]: https://github.com/jdylanmc/cmux-maestro/pull/33#issuecomment-5661869270
