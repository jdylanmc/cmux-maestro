# Capability matrix: observation and attention

[↑ Capability matrix](capability-matrix.md) | [↑ Behavioral parity and proof](../behavioral-parity.md)

| Visible capability | Native proof |
|---|---|
| Workspace/surface topology, kinds, order and moves | [HierarchySnapshotTests](../../CMUXMaestroPreviewTests/HierarchySnapshotTests.swift): `mapsEverySurfaceKindWithoutFilteringOrProviderData`, `eachSnapshotAuthoritativelyReplacesPlacementAndOrderWhileIDsRemainStable` |
| Exact session/surface identity despite similar names or directories | [SidebarCopilotTreeTests](../../CMUXMaestroPreviewTests/SidebarCopilotTreeTests.swift): `exactSurfacePlacementIgnoresNamesPathsAndLaunchWorkspace`, `rejectsConflictingSessionIDsAndOffWindowRowsButKeepsValidPositives` |
| Provider, session and model metadata | [AgentSessionSnapshotTests](../../CMUXMaestroPreviewTests/AgentSessionSnapshotTests.swift): `keepsProviderIdentitySeparateFromCMUXIdentity`; [SidebarCopilotTreeTests](../../CMUXMaestroPreviewTests/SidebarCopilotTreeTests.swift): `partialKnownChildrenRemainVisibleWithoutInventingZeroOrModels`; [SidebarClarityTests](../../CMUXMaestroPreviewTests/SidebarClarityTests.swift): `selectionMetadataShowsOnlyObservedModelAndGrantedPaths`, `managedModelUsesOnlyFreshExactSurfaceAndSessionIdentity` |
| Nested agents, skills and shell work | [CopilotEventReducerTests](../../CMUXMaestroPreviewTests/CopilotEventReducerTests.swift): `joinsToolOwnerNotChronologicalParentAndPreservesDuplicateNames`, `skillsAndShellUseOnlySupportedMetadataAndExcludePayloads`, `backgroundShellExitUsesStructuredNotificationNotContentOrArguments` |
| Interaction identity, reused turn numbers, timing and replay | [CopilotInteractionTests](../../CMUXMaestroPreviewTests/CopilotInteractionTests.swift): `providerInteractionsReuseZeroAndOneWithoutLosingPrimaryCompletion`, `oldToolProvenanceCannotBeOverriddenByCurrentParent`, `reusedNilEndRequiresCurrentEvidenceAndContradictoryClocksDoNotInventAge` |
| Permission and question attention | [CopilotAttentionTests](../../CMUXMaestroPreviewTests/CopilotAttentionTests.swift): `requestPairingIncludesOwnerAndKind`; [SidebarAttentionTests](../../CMUXMaestroPreviewTests/SidebarAttentionTests.swift): `blockersCannotBeAcknowledgedEvenWithForgedStoredKeysOrStaleButtons` |
| Errors, aborts and primary-turn completion | [CopilotAttentionTests](../../CMUXMaestroPreviewTests/CopilotAttentionTests.swift): `acceptedRootOutcomeDoesNotEndOrUnblockBackgroundWork`, `primaryTurnEndDoesNotSilentlyAcknowledgeAnEarlierToolError` |
| Honest tool activity | [CopilotAttentionTests](../../CMUXMaestroPreviewTests/CopilotAttentionTests.swift): `activityUsesOwnedToolNamesAndCompletionIdentityNotPayloads`, `multipleExecutingToolsAndDuplicateCompletionKeepHonestActivity` |

Runtime evidence and dispositions for each row: [archive](../evidence/behavioral-parity.md#capability-matrix-observation-runtime-evidence).
