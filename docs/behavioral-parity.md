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

### Setup fixture readiness

Process-cleanup tests wait for the injected clock's first post-`posix_spawn`
sample before arming the unchanged three-second child-readiness watchdog.
The test clock publishes a bounded one-shot signal; a driver that returns
without spawning closes that signal, and a cancelled waiter unwinds. This
separates task/dispatch scheduling from the fixture's readiness requirement
without changing the production runner, its timeout, or executor policy.

`queuedStartupDoesNotConsumeChildReadinessBudget` and
`lateQueuedStartupRetainsFullChildReadinessBudget` hold the test driver before
invoking the runner for four and 2.7 seconds respectively. With the old
watchdog ordering they reproduced both no-launch and started-but-unfinished
delay failures; the corrected ordering preserves all timeout/cancellation,
exact process-group/reaping, unrelated-process and late-write assertions.
The real 0.6-second launcher delay and frozen 0.4-second product deadline
remain unchanged. These controlled probes report a non-actor-isolated driver;
they do not establish MainActor inheritance or measure hosted dispatch latency.

Early unavailable/cancelled runner outcomes, waiter cancellation, and a
started runner without a ready writer are separate controls. The independent
non-yielding `concurrentSupervisionDoesNotOccupyCooperativeExecutor` observer
retains its three-second budget and detached drivers. There is no suite
serialization, startup retry or larger readiness timeout. Startup observation
has no added wall-time limit before the first sample; the existing dedicated
concurrency test remains the bounded dispatch-progress regression.

### Deep-outline fixture readiness

Focus-layout fixtures bring the deepest title into the viewport and wait for
native scroller/document geometry to settle before capturing their baseline.
A no-focus control reproduced the initial overlay-to-legacy scroller transition
and its 17-point viewport change; the correction does not change global scroller
preferences or production layout. Exact focus-frame equality and width/depth
caps remain unchanged. No-focus and real-width-change controls verify that the
baseline is not refreshed after the effect or used to hide later layout changes.

## Capability matrix

Links below point to test files; named methods identify representative checks,
not the entire coverage of each file. Runtime links identify their actual
acceptance scope.

| Visible capability | Native proof | Runtime evidence or disposition |
|---|---|---|
| Workspace/surface topology, kinds, order and moves | [HierarchySnapshotTests](../CMUXMaestroPreviewTests/HierarchySnapshotTests.swift): `mapsEverySurfaceKindWithoutFilteringOrProviderData`, `eachSnapshotAuthoritativelyReplacesPlacementAndOrderWhileIDsRemainStable` | Native topology is delivered in [PR26][r26]; workspace/surface behavior is exercised in [layout acceptance][r29]. |
| Exact session/surface identity despite similar names or directories | [SidebarCopilotTreeTests](../CMUXMaestroPreviewTests/SidebarCopilotTreeTests.swift): `exactSurfacePlacementIgnoresNamesPathsAndLaunchWorkspace`, `rejectsConflictingSessionIDsAndOffWindowRowsButKeepsValidPositives` | [PR30][r30] verifies two live CLI sessions with the same title/directory on distinct surfaces. Names and paths are not identity. |
| Provider, session and model metadata | [AgentSessionSnapshotTests](../CMUXMaestroPreviewTests/AgentSessionSnapshotTests.swift): `keepsProviderIdentitySeparateFromCMUXIdentity`; [SidebarCopilotTreeTests](../CMUXMaestroPreviewTests/SidebarCopilotTreeTests.swift): `partialKnownChildrenRemainVisibleWithoutInventingZeroOrModels`; [SidebarClarityTests](../CMUXMaestroPreviewTests/SidebarClarityTests.swift): `selectionMetadataShowsOnlyObservedModelAndGrantedPaths`, `managedModelUsesOnlyFreshExactSurfaceAndSessionIdentity` | Live Copilot attribution is covered by [PR30][r30]. Selected managed workers require exact fresh session and surface identity; coordinators require one fresh unambiguous session on their exact surface. Missing, stale, mismatched and ambiguous model data plus unavailable numeric context capacity/usage are omitted rather than guessed. |
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
| Accessibility semantics and glanceability | [SidebarClarityTests](../CMUXMaestroPreviewTests/SidebarClarityTests.swift): `statusGlyphsUseOneFamilyWithoutRelyingOnColorAlone`, `managedAndObservedWorkUseTheSameStatusGlyphs`, `realDetailsAndFocusHandlersAreIndependentAndKeepTypedNavigationGuards`; [SidebarLayoutRenderingTests](../CMUXMaestroPreviewTests/SidebarLayoutRenderingTests.swift): `syntheticSidebarRendersAtNarrowWidthsInBothDensitiesAndModes`, `managedRowsStayWithinCompactHeightBudgetAtThreeHundredWidth` | Deterministic managed and unmanaged renders cover 300–340-point hierarchy-first layouts, shared circular state glyphs, duplicate names, long branches, nested ancestry, selected managed model data and explicit vertical/ordinary-row budgets. Only verified working activity is green; idle, completed and uncertain states are neutral and remain distinguishable by shape and accessible labels. Focus, expansion and selection remain distinct. Spoken VoiceOver/global accessibility settings were not changed or claimed tested. |
| Unified workspace outline and mixed-source density | [SidebarClarityTests](../CMUXMaestroPreviewTests/SidebarClarityTests.swift): `unifiedOutlineClaimsOnlyExactManagedWorkspaceSurfacePairs`, `outlineMovesPassiveToolActivityToDetailsButRetainsWorkAndAncestors`, `staleManagedStateAndRegistrationNeverClaimRunning`; [SidebarLayoutRenderingTests](../CMUXMaestroPreviewTests/SidebarLayoutRenderingTests.swift): mixed incomplete-history fixture in `syntheticSidebarRendersAtNarrowWidthsInBothDensitiesAndModes` | One workspace heading; exact managed ownership removes duplicate terminal rows. Single-session terminal rows absorb session presentation. Passive skill/shell activity remains in details and Taskboard. Pixel-recognized fixture titles and a 400-point document budget catch duplicated/missing content; this offscreen evidence is not installed-host acceptance. Stale status cannot claim running; stale Git labels are explicitly last-verified. |
| Stable local install, update, rollback and recovery | [test-local-preview.py](../scripts/test-local-preview.py): `test_first_install_stable_copy_and_exact_registration`, `test_atomic_updates_preserve_one_previous_and_rollback_is_reversible`, `test_ambiguous_recovery_refuses_to_guess` | [PR30][r30] verifies real stable installation, signed Debug/Release update, exact rollback and recovery. This is local-preview delivery, not public distribution. |
| Explicit terminal-backed orchestration | [test-cmux-maestro-orchestrator.py](../scripts/test-cmux-maestro-orchestrator.py): external create/attach/archive ordering, exact surface retention, background-tab startup, exact ownership/resume, strict permission-free `final_answer` reports, caller-explicit private tool policy and descendant non-escalation, visible JSON permission denial, verified-idle report recovery, successful/nonzero/malformed result boundaries, bounded streaming, in-turn heartbeats, live-resource cap/reclamation, archive/recovery, automatic exit and focus contracts, and bounded timestamped Git evidence refresh from explicit working directories; [SidebarOrchestrationTests](../CMUXMaestroPreviewTests/SidebarOrchestrationTests.swift): exhaustive managed phase titles/symbols, validated ancestry/lifecycle/timestamps, Git evidence status/time, stale qualification and privacy-preserving current-window filtering; [SidebarLayoutRenderingTests](../CMUXMaestroPreviewTests/SidebarLayoutRenderingTests.swift): regenerated mixed-state render and direct density bounds; [test-copilot-sandbox.sh](../scripts/test-copilot-sandbox.sh): observer-readable/private-sibling-denied proof | Observer projection adds only bounded verified worktree/branch labels, Git evidence status/time and the exact controlled worker session UUID. Full working directories remain private control data. Git probes run outside the state mutation lock, are batched per exact assigned directory, have a one-second/4 KiB bound and never run in the sandboxed sidebar. Non-Git, missing, detached, timeout, malformed, overlong and failed-query behavior is covered. Live validation remains operator-gated and unverified in this worktree. |

Managed polling fences read success, failure, and task cleanup by generation.
`SidebarOrchestrationTests.obsoleteReadCannotEraseCurrentStateOrDuplicatePolling`
covers late success/missing/unsafe reads, current-task cancellation, and hide/show
restart without erasing newer state or creating extra pollers.

### Bounded oversized event projection

The reader retains its 1 MiB ordinary-line limit, 4 MiB per-session / 8 MiB
per-read I/O budgets, and 2,048-line per-session budget. When a line exceeds
the ordinary limit, the existing streaming envelope seam validates its full
JSON structure while retaining only the event decoder's metadata keys. Tool
start/completion/partial-result payloads, assistant messages, binary assets and
otherwise opaque events (including model diagnostics) can therefore preserve
their ordinary decoder semantics without retaining arguments, results or
message content. Other known lifecycle events still fail closed when oversized.
Unknown work-lifecycle events still reach the reducer's explicit degradation;
they are not treated as harmless model diagnostics.

The streaming validator rejects malformed tokens, invalid UTF-8/escapes,
unpaired Unicode surrogates, duplicate keys (including escaped equivalents),
and invalid/truncated container structure. Bounds are 64 total container
levels, 1,024 encoded bytes per key and 65,536 encoded key bytes across open
objects. Arbitrary binary-asset `metadata` and tool-result `structuredContent`
maps have no separate per-object key-count ceiling. Even an empty JSON string
key costs two encoded bytes including its quotes, so the aggregate budget
implies at most 32,768 live key entries across the open objects. This is a
conservative cardinality bound, not a 64 KiB heap-allocation limit: Swift
String/Set storage and frame overhead are additional, with their cardinality
bounded by the same budget and depth limit. Wide maps can cost more overhead
than narrow maps within that bound. Retained projection-field cardinality is
separately fixed by the existing decoder's CodingKeys; admitting wider opaque
maps does not add projected fields. Arrays and opaque strings are scanned,
not buffered.
Selected scalar retention is capped at 2,048 encoded bytes per field. A scalar
beyond that cap remains present but unusable to the existing decoder, never
silently omitted or defaulted; irrelevant fields of opaque events stay ignored.
The final projected envelope must fit the unchanged ordinary-line limit.
These resource bounds can conservatively reject otherwise valid pathological
JSON. They are not permission to clear a previous reader error.

Work is linear in consumed bytes with bounded stack/key storage. Crossing the
line limit additionally scans the already-buffered prefix once (at most 1 MiB
with defaults); it does not reread or accumulate the remainder of the payload.
A complete newline and verified file/identity boundary are still required for
publication. Torn appends retain the previous complete observation and report
loading; malformed completed lines retain explicit degradation. No Working or
Idle state is inferred from process liveness, and no persisted tail is repaired
by discarding errors.

`CopilotAssetEnvelopeTests` covers synthetic below/exact/above default and
reduced line limits, ordered/escaped/chunked payloads, malformed and incomplete
JSON, resource boundaries, tool success/failure and wrong-owner/turn/replay
controls, advisory message attribution, and a multi-batch large-history
reader-to-sidebar Working-to-Idle transition. This is source-level recovery
evidence for #121, not installed-app acceptance or proof of every reported
missing/Unknown row.

The wide-map regressions cover 64, 65 and 256 unique keys in asset metadata
and tool structured results, both below and above the ordinary line limit
and across chunk boundaries. Their red/green proof corrects the earlier
unsupported 64-key ceiling rather than waiving a producer-contract failure.
Duplicate keys and malformed values after the 64th entry remain rejected;
the aggregate-key control admits exactly 65,536 encoded bytes across open
objects and rejects 65,537.

### Multi-turn child identity and completion attribution

Copilot 1.0.88 can persist `subagent.configured(multiTurn: true)`, complete the
original spawn task, then start another interaction on the same child without
another `subagent.started`. The reducer retains that child's observed name,
kind and ancestry on the fresh interaction, retiring the old spawn-result join.
Completion remains a terminal task outcome until fresh activity is observed.
Documented `subagent.selected` profile metadata does not replace the spawn
identity or revoke that capability. Other unknown subagent lifecycle events
still invalidate it. Reused turn numbers require the existing causal guards.
`CopilotInteractionTests.demonstratedMultiTurnFragmentPreservesIdentityOnlyOnFreshContinuation`
replays a redacted seven-event producer fragment; its omitted causal envelopes
do not prove an untagged final end.

An approved metadata-only Copilot 1.0.88 probe subsequently established that
`assistant.message` carries both the current `interactionId` and `turnId`, even
across root-owned warning/hook envelopes. Its linked `assistant.turn_end` still
carries only the reused turn number. The reducer reads only those two bounded
message identifiers, verifies the exact owner and current interaction/turn, and
uses the message as that owner's completion anchor. Message content is never
decoded or projected. Messages cannot create a turn, revive ended work, or
replace spawn identity. Their event IDs use the existing bounded replay guard.

`producerTaggedMessagesProveRepeatedChildFollowUpCompletion` and
`readerProjectsTaggedInterleavedParentChildAndGrandchildIdle` cover this
producer-shaped attribution through repeated follow-ups and the reader/tree
seams, retaining identity and ancestry while returning to Idle. The nested
fixture is a synthetic composition of the observed single-child sequence,
not a claim of installed-app or live grandchild acceptance.

**Missing current-turn proof remains Unknown.** The earlier review packet did
not establish message tags; its negative regressions remain intact:
`interleavedUntaggedFollowUpNeedsOwnedProofNotGlobalChronology`,
`repeatedProducerShapedUntaggedFollowUpsRemainExplicitlyUnknown` and the matching
reader/tree regression preserve the child's name/kind/ancestry but report
Unknown / `ambiguousTurn`, including repeated follow-ups. The global chronological
chain is not treated as ownership proof. Partial, malformed, null, conflicting,
wrong-owner and replayed message tags cannot borrow a current parent link.
Unusable advisory message metadata does not suppress the whole session; a
completion lacking another valid anchor reports the explicit ambiguity.
Legacy untagged same-owner envelope linkage and current-tool-origin controls
remain supported. A tool first observed after a gap still cannot attest a turn.

Capability is private, bounded reducer state: strict boolean configuration in a
timestamped initial spawn window, before any child turn, with one admission per
observed child ID. Missing/late configuration, missing spawn evidence,
known old timestamps and reused child IDs cannot grant continuation, even if the
old child became Unknown and was retired before its configuration was observed.
Explicit false revokes it. Failed/cancelled child outcomes, scoped abort/error,
shutdown/resume and uncertain lifecycle boundaries invalidate it; a root-turn
abort/error does not imply independent background children ended. Retired rows
remain retired. Legacy model projection, including lagging configuration
timestamps, is independent of capability admission; public snapshots are unchanged.
This fixes demonstrated continuation identity and tagged-message attribution, not every Unknown agent or a
particular screenshot, and does not complete #118/#119, select a shared runtime
architecture, add saved-session resurrection, or grant child control/placement.

Managed report fixtures include the real terminal sequence: `final_answer`,
`assistant.turn_end`, `session.usage_checkpoint`, `assistant.idle`, then `result`.
Only non-content terminal bookkeeping is permitted; later assistant/tool work
and post-result events remain rejected. Policy denial requires a failed tool's
structured error code, not words found inside successful output.
Resumed-session empty `session.background_tasks_changed` invalidations are also
accepted as notifications, never as proof that background work finished.
The CLI's ephemeral `assistant.reasoning` auxiliary envelope is ignored without
using or publishing its contents; it is not a new reply or a task report.

Owned pre-orchestration installs may lack the newer controller/skill assets when
their signed profile has no orchestration grant. Their exact receipts remain
required for status, preparation, recovery, update and rollback. New sources and
any profile granting orchestration access still require the complete asset pair.

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
  now feeds live polling and projection through the pure
  [CopilotSnapshotAdapter](../CMUXMaestroPreview/CopilotShared/CopilotSnapshotAdapter.swift).
  `CopilotSnapshot` remains the reader's parsing result, not a sidebar envelope.
  Optional typed evidence preserves idle/failure/cancellation separately from
  legacy `done`, liveness independently from work, and launch placement separately
  from current host binding. Ordered flat child observations retain unresolved
  ancestry without fabricated parents; original nested v1 fixtures retain strict
  validation. [Adapter tests](../CMUXMaestroPreviewTests/CopilotSnapshotAdapterTests.swift)
  exercise the real polling reader seam and unknown/partial evidence.
  [Compatibility tests](../CMUXMaestroPreviewTests/AgentSnapshotCompatibilityTests.swift)
  use a frozen v1 decoder, including a negative unsupported-state control.
  Old decoding is preserved; old complete-hierarchy validation is not claimed
  for the additive flat-observation form. This implements the literal
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
