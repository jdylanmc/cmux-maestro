# Capability matrix: observation and attention

Part of the [capability matrix](capability-matrix.md) in [behavioral parity and proof](../behavioral-parity.md).

Links point to test files. Named methods identify representative checks,
not the entire coverage of each file. Runtime links identify their actual
acceptance scope.

| Visible capability | Native proof | Runtime evidence or disposition |
|---|---|---|
| Workspace/surface topology, kinds, order and moves | [HierarchySnapshotTests](../../CMUXMaestroPreviewTests/HierarchySnapshotTests.swift): `mapsEverySurfaceKindWithoutFilteringOrProviderData`, `eachSnapshotAuthoritativelyReplacesPlacementAndOrderWhileIDsRemainStable` | Native topology is delivered in [PR26][r26]. Workspace/surface behavior is exercised in [layout acceptance][r29]. |
| Exact session/surface identity despite similar names or directories | [SidebarCopilotTreeTests](../../CMUXMaestroPreviewTests/SidebarCopilotTreeTests.swift): `exactSurfacePlacementIgnoresNamesPathsAndLaunchWorkspace`, `rejectsConflictingSessionIDsAndOffWindowRowsButKeepsValidPositives` | [PR30][r30] verifies two live CLI sessions with the same title/directory on distinct surfaces. Names and paths are not identity. |
| Provider, session and model metadata | [AgentSessionSnapshotTests](../../CMUXMaestroPreviewTests/AgentSessionSnapshotTests.swift): `keepsProviderIdentitySeparateFromCMUXIdentity`; [SidebarCopilotTreeTests](../../CMUXMaestroPreviewTests/SidebarCopilotTreeTests.swift): `partialKnownChildrenRemainVisibleWithoutInventingZeroOrModels`; [SidebarClarityTests](../../CMUXMaestroPreviewTests/SidebarClarityTests.swift): `selectionMetadataShowsOnlyObservedModelAndGrantedPaths`, `managedModelUsesOnlyFreshExactSurfaceAndSessionIdentity` | Live Copilot attribution is covered by [PR30][r30]. Selected managed workers require exact fresh session and surface identity. Coordinators require one fresh unambiguous session on their exact surface. Missing, stale, mismatched and ambiguous model data plus unavailable numeric context capacity/usage are omitted rather than guessed. |
| Nested agents, skills and shell work | [CopilotEventReducerTests](../../CMUXMaestroPreviewTests/CopilotEventReducerTests.swift): `joinsToolOwnerNotChronologicalParentAndPreservesDuplicateNames`, `skillsAndShellUseOnlySupportedMetadataAndExcludePayloads`, `backgroundShellExitUsesStructuredNotificationNotContentOrArguments` | Real child history is verified in [PR27][r27]. Skills and shell distinctions have Swift proof. Tool-invocation completion is not inferred background-process exit. |
| Interaction identity, reused turn numbers, timing and replay | [CopilotInteractionTests](../../CMUXMaestroPreviewTests/CopilotInteractionTests.swift): `providerInteractionsReuseZeroAndOneWithoutLosingPrimaryCompletion`, `oldToolProvenanceCannotBeOverriddenByCurrentParent`, `reusedNilEndRequiresCurrentEvidenceAndContradictoryClocksDoNotInventAge` | [PR28][r28] verifies a fresh interaction reusing turns `0/1`, transitioning Idle → Working → Idle with a new Turn finished outcome. Ambiguous identity/timing remains explicit. |
| Permission and question attention | [CopilotAttentionTests](../../CMUXMaestroPreviewTests/CopilotAttentionTests.swift): `requestPairingIncludesOwnerAndKind`; [SidebarAttentionTests](../../CMUXMaestroPreviewTests/SidebarAttentionTests.swift): `blockersCannotBeAcknowledgedEvenWithForgedStoredKeysOrStaleButtons` | [PR28][r28] verifies permission waiting in both views, disabled acknowledgement and normal denial. Swift tests also cover answer/request pairing. |
| Errors, aborts and primary-turn completion | [CopilotAttentionTests](../../CMUXMaestroPreviewTests/CopilotAttentionTests.swift): `acceptedRootOutcomeDoesNotEndOrUnblockBackgroundWork`, `primaryTurnEndDoesNotSilentlyAcknowledgeAnEarlierToolError` | [PR28][r28] verifies error acknowledgement/reset/reload and new turn completion. Turn finished does not mean session or background-child completion. |
| Honest tool activity | [CopilotAttentionTests](../../CMUXMaestroPreviewTests/CopilotAttentionTests.swift): `activityUsesOwnedToolNamesAndCompletionIdentityNotPayloads`, `multipleExecutingToolsAndDuplicateCompletionKeepHonestActivity` | Owned executing/last-completed tool metadata has Swift proof. No token/context percentage or speculative hung-state parity is claimed. |

[r26]: https://github.com/jdylanmc/cmux-maestro/pull/26
[r27]: https://github.com/jdylanmc/cmux-maestro/pull/27#issuecomment-5658114796
[r28]: https://github.com/jdylanmc/cmux-maestro/pull/28#issuecomment-5659682603
[r29]: https://github.com/jdylanmc/cmux-maestro/pull/29#issuecomment-5660229219
[r30]: https://github.com/jdylanmc/cmux-maestro/pull/30#issuecomment-5661185922
