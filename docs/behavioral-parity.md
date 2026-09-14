# Behavioral parity and proof

This matrix maps the legacy-visible capability inventory to native regression
evidence, intentional differences, or explicit acceptance limits. It is not a
claim that every synthetic edge case was reproduced on the desktop.

The native runtime, history, attention, layout, local installation and icon-led
presentation are merged in [PR26][r26], [PR27][r27], [PR28][r28], [PR29][r29],
[PR30][r30] and [PR32][r32]. Update preparation in [PR33][r33] is also merged.
Their public acceptance records distinguish local tests, actual CMUX interaction
and operational limits; the installed app uses the stable Applications location.

## Run the behavioral suite

```sh
./scripts/test.sh
```

This runs the Swift behavioral tests and builds their existing preference
fixture client. The [CI workflow](../.github/workflows/ci.yml) also runs build
metadata, installer transactions, SDK-fetch concurrency, compiled-hook and
sandbox checks. Validation hosts do not open installation windows or permit
plugin changes. No new test framework is required.

## Capability matrix

Links below point to test files; named methods identify representative checks,
not the entire coverage of each file. Runtime links identify their actual
acceptance scope.

| Visible capability | Native proof | Runtime evidence or disposition |
|---|---|---|
| Workspace/surface topology, kinds, order and moves | [HierarchySnapshotTests](../CMUXMaestroPreviewTests/HierarchySnapshotTests.swift): `mapsEverySurfaceKindWithoutFilteringOrProviderData`, `eachSnapshotAuthoritativelyReplacesPlacementAndOrderWhileIDsRemainStable` | Native topology is delivered in [PR26][r26]; workspace/surface behavior is exercised in [layout acceptance][r29]. |
| Exact session/surface identity despite similar names or directories | [SidebarCopilotTreeTests](../CMUXMaestroPreviewTests/SidebarCopilotTreeTests.swift): `exactSurfacePlacementIgnoresNamesPathsAndLaunchWorkspace`, `rejectsConflictingSessionIDsAndOffWindowRowsButKeepsValidPositives` | [PR30][r30] verifies two live CLI sessions with the same title/directory on distinct surfaces. Names and paths are not identity. |
| Provider, session and model metadata | [AgentSessionSnapshotTests](../CMUXMaestroPreviewTests/AgentSessionSnapshotTests.swift): `keepsProviderIdentitySeparateFromCMUXIdentity`; [SidebarCopilotTreeTests](../CMUXMaestroPreviewTests/SidebarCopilotTreeTests.swift): `partialKnownChildrenRemainVisibleWithoutInventingZeroOrModels` | Live Copilot attribution is covered by [PR30][r30]. Missing metadata stays unknown; the neutral-envelope distinction below applies. |
| Nested agents, skills and shell work | [CopilotEventReducerTests](../CMUXMaestroPreviewTests/CopilotEventReducerTests.swift): `joinsToolOwnerNotChronologicalParentAndPreservesDuplicateNames`, `skillsAndShellUseOnlySupportedMetadataAndExcludePayloads`, `backgroundShellExitUsesStructuredNotificationNotContentOrArguments` | Real child history is verified in [PR27][r27]. Skills and shell distinctions have Swift proof. Tool-invocation completion is not inferred background-process exit. |
| Interaction identity, reused turn numbers, timing and replay | [CopilotInteractionTests](../CMUXMaestroPreviewTests/CopilotInteractionTests.swift): `providerInteractionsReuseZeroAndOneWithoutLosingPrimaryCompletion`, `oldToolProvenanceCannotBeOverriddenByCurrentParent`, `reusedNilEndRequiresCurrentEvidenceAndContradictoryClocksDoNotInventAge` | [PR28][r28] verifies a fresh interaction reusing turns `0/1`, transitioning Idle → Working → Idle with a new Turn finished outcome. Ambiguous identity/timing remains explicit. |
| Permission and question attention | [CopilotAttentionTests](../CMUXMaestroPreviewTests/CopilotAttentionTests.swift): `requestPairingIncludesOwnerAndKind`; [SidebarAttentionTests](../CMUXMaestroPreviewTests/SidebarAttentionTests.swift): `blockersCannotBeAcknowledgedEvenWithForgedStoredKeysOrStaleButtons` | [PR28][r28] verifies permission waiting in both views, disabled acknowledgement and normal denial. Answer/request pairing is additionally Swift-covered. |
| Errors, aborts and primary-turn completion | [CopilotAttentionTests](../CMUXMaestroPreviewTests/CopilotAttentionTests.swift): `acceptedRootOutcomeDoesNotEndOrUnblockBackgroundWork`, `primaryTurnEndDoesNotSilentlyAcknowledgeAnEarlierToolError` | [PR28][r28] verifies error acknowledgement/reset/reload and new turn completion. Turn finished does not mean session or background-child completion. |
| Honest tool activity | [CopilotAttentionTests](../CMUXMaestroPreviewTests/CopilotAttentionTests.swift): `activityUsesOwnedToolNamesAndCompletionIdentityNotPayloads`, `multipleExecutingToolsAndDuplicateCompletionKeepHonestActivity` | Owned executing/last-completed tool metadata has Swift proof. No token/context percentage or speculative hung-state parity is claimed. |
| Granted workspace/project/working paths | [SidebarNavigationTests](../CMUXMaestroPreviewTests/SidebarNavigationTests.swift): `realSDKGrantedNilPathsRemainDistinctFromUnavailable`, `sessionPathPresentationUsesCurrentSurfacePlacementNotLaunchWorkspace` | SDK/Swift proof distinguishes unavailable from granted-empty paths and follows current surface placement. [PR32][r32] verifies full metadata in independent Details controls, including narrow layouts. |
| Expiry, dismissal and acknowledgement | [SidebarHistoryTests](../CMUXMaestroPreviewTests/SidebarHistoryTests.swift): `preciseExpiryBoundaryAndNever`, `identityIsSessionChildAndOutcomeNotLabelOrTopology`; [SidebarAttentionTests](../CMUXMaestroPreviewTests/SidebarAttentionTests.swift): `attentionSurvivesRetentionDismissalAndCollapseUntilExplicitAcknowledgement` | [PR27][r27] verifies real expiry, dismissal/restoration, reload and active-work protection. [PR28][r28] verifies that history does not erase outstanding attention and old acknowledgement does not hide a new outcome. |
| Mode, density and durable expansion | [SidebarPreferencesTests](../CMUXMaestroPreviewTests/SidebarPreferencesTests.swift): `persistsThroughReconstruction`; [SidebarLayoutTests](../CMUXMaestroPreviewTests/SidebarLayoutTests.swift): `everyIdentityAndDensityRoundTripAcrossStoreReconstruction`, `collapsedAncestorsKeepRunningBlockingAndAttentionSummaryWithoutChangingProjection` | [PR29][r29] verifies eight density/mode/width combinations, workspace/surface/session expansion, summaries, reload and reset. Live child-collapse was unavailable because the controlled children were leaves; it remains synthetically covered. |
| Typed Focus and visible navigation failures | [SidebarNavigationTests](../CMUXMaestroPreviewTests/SidebarNavigationTests.swift): `navigationUsesTypedHostAndCurrentWorkspaceAfterSurfaceMove`, `hostRejectionsCancellationAndDisconnectNeverExposeRawText`, `unresponsiveNavigationTimesOutWithoutWaitingForCancelledHostWork` | Live Focus is verified in [PR27][r27] and [PR28][r28]. Failure/cancellation/timeout cases are Swift-covered. Child Focus selects its owning surface, not an invented child terminal. |
| Privacy, isolation and non-vetoing observation | [CopilotReaderTests](../CMUXMaestroPreviewTests/CopilotReaderTests.swift): `offSurfaceIndexRecordsNeverReachProcessValidationOrPublicSnapshot`; [CopilotSetupTests](../CMUXMaestroPreviewTests/CopilotSetupTests.swift): `wrapperExecutesNegativeControlButAlwaysSilencesMissingAndFailingHelpers` | Direct reading is delivered in [PR26][r26]; live isolation is verified in [PR30][r30]. Narrow sandbox and compiled-hook checks provide separate CI evidence. |
| Unknown/degraded data, freshness and bounded catch-up | [SidebarCopilotTreeTests](../CMUXMaestroPreviewTests/SidebarCopilotTreeTests.swift): `partialKnownChildrenRemainVisibleWithoutInventingZeroOrModels`, `pollingUsesOnlyGrantedVisibleSurfacesAndClearsOnRevocation`, `staleHistoryCannotTriggerCatchUpAndHideCancelsCatchUpPause` | Partial counts, revocation and stale-data handling have Swift proof. Continuing observations and stable scrolling are verified in [PR27][r27]/[PR28][r28]. Missing evidence never implies success or a hung agent. |
| Accessibility semantics and glanceability | [SidebarClarityTests](../CMUXMaestroPreviewTests/SidebarClarityTests.swift): `entityIconsAndStateBadgesDoNotRelyOnColorAlone`, `realDetailsAndFocusHandlersAreIndependentAndKeepTypedNavigationGuards`; [SidebarLayoutRenderingTests](../CMUXMaestroPreviewTests/SidebarLayoutRenderingTests.swift): `syntheticSidebarRendersAtNarrowWidthsInBothDensitiesAndModes` | [PR29][r29] verifies native control geometry. [PR32][r32] verifies eight physical layout combinations, independent Details and final scoped wording. Spoken VoiceOver/global accessibility settings were not changed or claimed tested. |
| Stable local install, update, rollback and recovery | [test-local-preview.py](../scripts/test-local-preview.py): `test_first_install_stable_copy_and_exact_registration`, `test_atomic_updates_preserve_one_previous_and_rollback_is_reversible`, `test_ambiguous_recovery_refuses_to_guess` | [PR30][r30] verifies real stable installation, signed Debug/Release update, exact rollback and recovery. This is local-preview delivery, not public distribution. |
| Explicit terminal-backed orchestration | [test-cmux-maestro-orchestrator.py](../scripts/test-cmux-maestro-orchestrator.py): external create/attach/archive ordering, exact surface retention, background-tab startup, exact ownership/resume, strict permission-free `final_answer` reports, caller-explicit private tool policy and descendant non-escalation, visible JSON permission denial, verified-idle report recovery, successful/nonzero/malformed result boundaries, bounded streaming, in-turn heartbeats, live-resource cap/reclamation, archive/recovery, automatic exit and focus contracts; [SidebarOrchestrationTests](../CMUXMaestroPreviewTests/SidebarOrchestrationTests.swift): exhaustive managed phase titles/symbols, validated ancestry/lifecycle/timestamps, stale qualification and privacy-preserving current-window filtering; [SidebarLayoutRenderingTests](../CMUXMaestroPreviewTests/SidebarLayoutRenderingTests.swift): regenerated mixed-state render and direct density bounds; [test-copilot-sandbox.sh](../scripts/test-copilot-sandbox.sh): observer-readable/private-sibling-denied proof | The controller and skill are bundled and production setup installs them. Actual frozen-controller evidence demonstrated JSON-only provider denial of the old helper report path; this correction removes that required permission. Live validation of the corrected default and explicitly authorized nested paths remains operator-gated and unverified in this worktree. |

Managed polling fences read success, failure, and task cleanup by generation.
`SidebarOrchestrationTests.obsoleteReadCannotEraseCurrentStateOrDuplicatePolling`
covers late success/missing/unsafe reads, current-task cancellation, and hide/show
restart without erasing newer state or creating extra pollers.

Managed report fixtures include the real terminal sequence: `final_answer`,
`assistant.turn_end`, `session.usage_checkpoint`, `assistant.idle`, then `result`.
Only non-content terminal bookkeeping is permitted; later assistant/tool work
and post-result events remain rejected. Policy denial requires a failed tool's
structured error code, not words found inside successful output.

## Intentional differences and explicit limits

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
  [AgentSessionSnapshot](../CMUXMaestroPreview/Domain/AgentSessionSnapshot.swift)
  contract exists and has fixtures. The live `SidebarCopilotPolling.Read` still
  returns the adapter-specific `CopilotSnapshot` from `CopilotSessionReader`,
  sharing neutral activity/attention primitives. This is not completion of the
  literal generic-envelope integration in
  [#10](https://github.com/jdylanmc/cmux-maestro/issues/10).
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
  synthetic tests additionally cover one-call recovery after a prepared update
  fails during copying or before replacement.

There are no unexplained gaps in this visible-capability inventory after these
dispositions. This statement is not a new exhaustive legacy audit, a claim that
all operator-gated work is finished, or permission to weaken future regression
and live-verification gates.

[r26]: https://github.com/jdylanmc/cmux-maestro/pull/26
[r27]: https://github.com/jdylanmc/cmux-maestro/pull/27#issuecomment-5658114796
[r28]: https://github.com/jdylanmc/cmux-maestro/pull/28#issuecomment-5659682603
[r29]: https://github.com/jdylanmc/cmux-maestro/pull/29#issuecomment-5660229219
[r30]: https://github.com/jdylanmc/cmux-maestro/pull/30#issuecomment-5661185922
[r32]: https://github.com/jdylanmc/cmux-maestro/pull/32#issuecomment-5662015261
[r33]: https://github.com/jdylanmc/cmux-maestro/pull/33#issuecomment-5661869270
