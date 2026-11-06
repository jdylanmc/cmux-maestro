# Behavioral parity and proof

These pages map each legacy-visible capability to native regression evidence,
an intentional difference or an explicit acceptance limit. They do not claim
every synthetic edge case was reproduced on the desktop.

Unless a runtime link says otherwise, every test listed in this family uses
synthetic fixtures, disposable files, mocked providers or offscreen hosts. None
is installed-host, live CMUX/provider or ExtensionKit runtime acceptance. Each
page lists its tests and links the reference contract; the per-page regression
evidence, test inventories and limits are kept verbatim in the
[behavioral parity evidence archive](evidence/behavioral-parity.md).

The native runtime, history, attention, layout, local installation and icon-led
presentation merged in [PR26][r26], [PR27][r27], [PR28][r28], [PR29][r29],
[PR30][r30] and [PR32][r32], and update preparation in [PR33][r33]. Their
public acceptance records keep local tests, actual CMUX interaction and
operational limits apart. The installed app uses the stable Applications
location.

## Run the behavioral suite

```sh
./scripts/test.sh
```

This runs the Swift behavioral tests and builds their preference fixture
client, with no new test framework. The [CI workflow](../.github/workflows/ci.yml)
also runs build metadata, installer transaction, SDK-fetch concurrency,
compiled-hook and sandbox checks. Validation hosts do not open installation
windows or permit plugin changes.

### Background-shell representation

<a id="background-shell"></a>
The contract is in [Other activity, session history and history settings](reference/history-and-internal-tasks/other-activity-and-session-history.md). These scoped checks do not replace the full hosted test matrix or current-head CI.

- [`test-copilot-shell-reducer.sh`](../scripts/test-copilot-shell-reducer.sh)
- [`CopilotShellReducerTests.swift`](../scripts/CopilotShellReducerTests.swift)

[Evidence, test inventories and limits](evidence/behavioral-parity.md#background-shell-representation).

### Setup fixture readiness

The contract is in [Build and test](reference/build-and-test.md), [Required behavioral coverage](reference/ci-test-determinism/required-behavioral-coverage.md). The probes do not establish MainActor inheritance or measure hosted dispatch latency.

- [`CopilotSetupTests.swift`](../CMUXMaestroPreviewTests/CopilotSetupTests.swift): `queuedStartupDoesNotConsumeChildReadinessBudget`, `lateQueuedStartupRetainsFullChildReadinessBudget`, `concurrentSupervisionDoesNotOccupyCooperativeExecutor`

[Evidence, test inventories and limits](evidence/behavioral-parity.md#setup-fixture-readiness).

<a id="hosted-integrated-runner"></a>
**Hosted integrated runner.** The contract is in [Build and test](reference/build-and-test.md), [Required behavioral coverage](reference/ci-test-determinism/required-behavioral-coverage.md). Earlier hosted concurrency reds and the separate native viewport-settlement failure remain on record. Only a necessary current-head hosted run can establish their state.

- [`run-integrated-test-scopes.py`](../scripts/run-integrated-test-scopes.py)
- [`CopilotSetupTests.swift`](../CMUXMaestroPreviewTests/CopilotSetupTests.swift): `concurrentSupervisionDoesNotOccupyCooperativeExecutor`
- [`CopilotReaderTests.swift`](../CMUXMaestroPreviewTests/CopilotReaderTests.swift): `coldStartBenchmarkWith230MiBOfIgnoredSyntheticPayloads()`

[Evidence, test inventories and limits](evidence/behavioral-parity.md#hosted-integrated-runner).

### Explicit owned-descendant and subtree close (#90, #91, #377)

<a id="owned-descendant-close"></a>
The contract is in [Explicit close](reference/hierarchy-launch-lifecycle/explicit-close.md), [Explicit owned-descendant close](native-messaging/owned-descendant-close.md), [Owned-descendant close: stock host behavior and admission limits](native-messaging/close-host-behavior.md). All three runtime suites remain required.

- [`test-delivery-proof.py`](../scripts/test-delivery-proof.py): `NativeCloseTests`
- [`test-delivery-proof.mjs`](../scripts/test-delivery-proof.mjs)

[Evidence, test inventories and limits](evidence/behavioral-parity.md#explicit-owned-descendant-and-subtree-close-90-91-377).

### Dedicated observer registration (#114)

<a id="observer-registration"></a>
The contract is in [Plugin and observer hook](reference/setup-and-integration/plugin-and-observer-hook.md), [Status, failures and messaging configuration](reference/setup-and-integration/status-failures-and-messaging-configuration.md).

- [`CopilotObserverRegistrationTests.swift`](../CMUXMaestroPreviewTests/CopilotObserverRegistrationTests.swift)
- [`CopilotSetupTests.swift`](../CMUXMaestroPreviewTests/CopilotSetupTests.swift)

[Evidence, test inventories and limits](evidence/behavioral-parity.md#dedicated-observer-registration-114).

<a id="observer-provider-probes"></a>
**Observer registration: provider probe evidence.** The contract is in [Plugin and observer hook](reference/setup-and-integration/plugin-and-observer-hook.md), [Legacy migration and disable preservation](reference/setup-and-integration/legacy-migration-and-disable-preservation.md). Setup does not claim to repair provider-wide enforcement.

- [`CopilotObserverRegistrationTests.swift`](../CMUXMaestroPreviewTests/CopilotObserverRegistrationTests.swift)

[Evidence, test inventories and limits](evidence/behavioral-parity.md#observer-registration-provider-probe-evidence).

<a id="observer-migration"></a>
**Observer registration: migration and restoration.** The contract is in [Legacy migration and disable preservation](reference/setup-and-integration/legacy-migration-and-disable-preservation.md), [Installer process and cancellation](reference/setup-and-integration/installer-process-and-cancellation.md). An unowned plugin may still invoke current or old helpers and cause extra executions or writes. This is neither prevented nor certified harmless.

- [`CopilotObserverRegistrationTests.swift`](../CMUXMaestroPreviewTests/CopilotObserverRegistrationTests.swift)
- [`CopilotSetupTests.swift`](../CMUXMaestroPreviewTests/CopilotSetupTests.swift)

[Evidence, test inventories and limits](evidence/behavioral-parity.md#observer-registration-migration-and-restoration).

### Coordinated alpha installation (#114)

<a id="alpha-installation"></a>
The contract is in [Update, rollback and status](reference/install/update-and-rollback.md), [Transaction and recovery contract: integrity and retained generations](reference/install/retained-generations.md). The hosted stock-host proof must still establish real release/recreation and focus behavior.

- [`test-local-preview.py`](../scripts/test-local-preview.py)

[Evidence, test inventories and limits](evidence/behavioral-parity.md#coordinated-alpha-installation-114).

<a id="install-retired-slots"></a>
**Alpha installation: retired slots and native publication.** The contract is in [Transaction and recovery contract: integrity and retained generations](reference/install/retained-generations.md), [Update, rollback and status](reference/install/update-and-rollback.md). The historical sibling-recovery proposal still needs separate production consent.

- [`test-local-preview.py`](../scripts/test-local-preview.py)

[Evidence, test inventories and limits](evidence/behavioral-parity.md#alpha-installation-retired-slots-and-native-publication).

<a id="install-integration-checkpoint"></a>
**Alpha installation: integration checkpoint.** The contract is in [Transaction and recovery contract: integration checkpoint](reference/install/integration-checkpoint.md), [Transaction and recovery contract: locks and supervision](reference/install/transaction-contract.md).

- [`test-local-preview.py`](../scripts/test-local-preview.py)
- [`CopilotObserverRegistrationTests.swift`](../CMUXMaestroPreviewTests/CopilotObserverRegistrationTests.swift)

[Evidence, test inventories and limits](evidence/behavioral-parity.md#alpha-installation-integration-checkpoint).

<a id="install-plugin-state"></a>
**Alpha installation: plugin identity and disabled state.** The contract is in [Transaction and recovery contract: plugin disabled state and recovery blocks](reference/install/plugin-disabled-state.md), [Transaction and recovery contract: integration checkpoint](reference/install/integration-checkpoint.md).

- [`test-local-preview.py`](../scripts/test-local-preview.py)
- [`CopilotObserverRegistrationTests.swift`](../CMUXMaestroPreviewTests/CopilotObserverRegistrationTests.swift)

[Evidence, test inventories and limits](evidence/behavioral-parity.md#alpha-installation-plugin-identity-and-disabled-state).

<a id="install-plugin-recovery"></a>
**Alpha installation: plugin-state recovery and tests.** The contract is in [Transaction and recovery contract: plugin disabled state and recovery blocks](reference/install/plugin-disabled-state.md), [Recovery commands and diagnostics](reference/install/recovery-commands.md). These tests use a provider double and do not prove real stock-host reload. Current eleven-command hosted CI, source-binding resolution, native lifecycle proof and later installed fresh-session acceptance remain separate gates, as do complete CI, independent review and any later production/live acceptance.

- [`test-local-preview.py`](../scripts/test-local-preview.py)
- [`CopilotObserverRegistrationTests.swift`](../CMUXMaestroPreviewTests/CopilotObserverRegistrationTests.swift)

[Evidence, test inventories and limits](evidence/behavioral-parity.md#alpha-installation-plugin-state-recovery-and-tests).

### Direct interactive launch and legacy startup (#61)

<a id="direct-interactive-launch"></a>
The contract is in [Interactive startup and native bindings](reference/hierarchy-launch-lifecycle/interactive-startup-and-native-bindings.md), [Launch commands and interactive workers](reference/hierarchy-launch-lifecycle/launch-commands-and-interactive-workers.md), [Installed lifecycle and permissions](native-messaging/installed-lifecycle.md). These fixtures do not claim hook delivery or prompt consumption.

- [`test-cmux-maestro-orchestrator.py`](../scripts/test-cmux-maestro-orchestrator.py)
- [`test-delivery-proof.py`](../scripts/test-delivery-proof.py)

[Evidence, test inventories and limits](evidence/behavioral-parity.md#direct-interactive-launch-and-legacy-startup-61).

<a id="launch-legacy-fixtures"></a>
**Launch: legacy fixtures and lock budgets.** The contract is in [Legacy bounded-worker compatibility](reference/messaging-launch-settings/legacy-bounded-worker-compatibility.md), [Workspace launch capacity](reference/messaging-launch-settings/workspace-launch-capacity.md).

- [`test-cmux-maestro-orchestrator.py`](../scripts/test-cmux-maestro-orchestrator.py)

[Evidence, test inventories and limits](evidence/behavioral-parity.md#launch-legacy-fixtures-and-lock-budgets).

<a id="launch-workspace-capacity"></a>
**Launch: workspace capacity.** The contract is in [Workspace launch capacity](reference/messaging-launch-settings/workspace-launch-capacity.md), [Host safety limits](reference/messaging-launch-settings/host-safety-limits.md).

- [`test-cmux-maestro-orchestrator.py`](../scripts/test-cmux-maestro-orchestrator.py)
- [`test-delivery-proof.py`](../scripts/test-delivery-proof.py)

[Evidence, test inventories and limits](evidence/behavioral-parity.md#launch-workspace-capacity).

<a id="launch-child-permissions"></a>
**Launch: native-child permissions.** The contract is in [Native-child launch policy](reference/messaging-launch-settings/native-child-launch-policy.md).

- [`test-cmux-maestro-orchestrator.py`](../scripts/test-cmux-maestro-orchestrator.py)

[Evidence, test inventories and limits](evidence/behavioral-parity.md#launch-native-child-permissions).

<a id="launch-model-selection"></a>
**Launch: model selection.** The contract is in [Preference refusals and launch selection](reference/messaging-launch-settings/preference-refusals-and-launch-selection.md), [Local agent launch settings and per-launch preferences](reference/messaging-launch-settings/local-agent-launch-settings.md). #199's root cause remains unproven, and the controls do not show which stage failed in the reported session. An authorized post-install native attempt is still outstanding. Fixtures are not evidence that the historical host delay is understood. Full delivery CI and independent review remain separate gates, and live host/provider experiments need a separately authorized release.

- [`test-cmux-maestro-orchestrator.py`](../scripts/test-cmux-maestro-orchestrator.py)
- [`test-delivery-proof.py`](../scripts/test-delivery-proof.py)
- [`model-list-1.0.100.json`](../scripts/fixtures/model-list-1.0.100.json)

[Evidence, test inventories and limits](evidence/behavioral-parity.md#launch-model-selection).

### Deep-outline fixture readiness

<a id="deep-outline-fixtures"></a>
The contract is in [Outline grouping and density](reference/layout-and-visual-validation/outline-grouping-and-density.md), [Explicit local-only native acceptance](reference/ci-test-determinism/explicit-local-only-native-acceptance.md). The matching hosted width delta still does not establish its trigger.

- [`SidebarLayoutRenderingTests.swift`](../CMUXMaestroPreviewTests/SidebarLayoutRenderingTests.swift): `deepOutlineFixedViewportSurvivesNativeStyleChanges`, `nativeEightLevelOutlineRetainsMinimumTitleWidthAt280`, `deepOutlineLateNativeStyleChangeInvalidatesSampledBaseline`

[Evidence, test inventories and limits](evidence/behavioral-parity.md#deep-outline-fixture-readiness).

## Managed Git provenance

The contract is in [Outline rows and Git evidence](reference/sidebar/outline-rows.md), [Managed Git context and notices](reference/sidebar/managed-git-context.md). This correction references #119/#59 without completing either. These tests need the unchanged hosted native suite. The cause of an earlier owner-label failure remains inferred, and repair execution and sensitivity evidence still need hosted CI.

- [`SidebarAgentHoverTests.swift`](../CMUXMaestroPreviewTests/SidebarAgentHoverTests.swift): `managedGitConsumersQualifyAssignedDirectoryWithoutChangingFreshness`

[Evidence, test inventories and limits](evidence/behavioral-parity.md#managed-git-provenance).

## Lazy preference observation (#169)

<a id="lazy-preference-observation"></a>
The contract is in [Sidebar order and layout storage](reference/layout-and-visual-validation/sidebar-order-and-layout-storage.md).

- [`SidebarLayoutTests.swift`](../CMUXMaestroPreviewTests/SidebarLayoutTests.swift): `lazyPresenterOwnItemChangesRefreshWithoutCreatingTarget`, `presenterOwnItemChangesRetainCoordinatedReadAndNoticeSemantics`

[Evidence, test inventories and limits](evidence/behavioral-parity.md#lazy-preference-observation-169).

## Capability matrix

[Capability matrix](behavioral-parity/capability-matrix.md): each visible capability with its native proof and runtime evidence.

### Bounded oversized event projection

<a id="oversized-event-projection"></a>
The contract is in [Oversized assets, rerouting and fast retry](reference/reader-lifecycle/oversized-and-rerouting.md), [Bounded retention and discovery](reference/reader-lifecycle/bounded-retention.md).

- [`CopilotAssetEnvelopeTests.swift`](../CMUXMaestroPreviewTests/CopilotAssetEnvelopeTests.swift)

[Evidence, test inventories and limits](evidence/behavioral-parity.md#bounded-oversized-event-projection).

### Multi-turn child identity and completion attribution

<a id="multi-turn-child-identity"></a>
The contract is in [Turn identity and causal bridging](reference/reader-lifecycle/turn-identity.md).

- [`CopilotInteractionTests.swift`](../CMUXMaestroPreviewTests/CopilotInteractionTests.swift): `demonstratedMultiTurnFragmentPreservesIdentityOnlyOnFreshContinuation`, `producerTaggedMessagesProveRepeatedChildFollowUpCompletion`, `readerProjectsTaggedInterleavedParentChildAndGrandchildIdle`

[Evidence, test inventories and limits](evidence/behavioral-parity.md#multi-turn-child-identity-and-completion-attribution).

<a id="multi-turn-unknown-and-capability"></a>
**Multi-turn child identity: unknown turns and capability.** The contract is in [Turn identity and causal bridging](reference/reader-lifecycle/turn-identity.md), [Tool events and missing causal evidence](reference/reader-lifecycle/tool-events.md). This does not complete #118/#119, select a shared runtime architecture, add saved-session resurrection, or grant child control/placement.

- [`CopilotInteractionTests.swift`](../CMUXMaestroPreviewTests/CopilotInteractionTests.swift): `interleavedUntaggedFollowUpNeedsOwnedProofNotGlobalChronology`, `repeatedProducerShapedUntaggedFollowUpsRemainExplicitlyUnknown`

[Evidence, test inventories and limits](evidence/behavioral-parity.md#multi-turn-child-identity-unknown-turns-and-capability).

## Intentional differences and explicit limits

[Intentional differences and explicit limits](behavioral-parity/intentional-differences.md): superseded proposals, deliberate gaps and acceptance boundaries.

[r26]: https://github.com/jdylanmc/cmux-maestro/pull/26
[r27]: https://github.com/jdylanmc/cmux-maestro/pull/27#issuecomment-5658114796
[r28]: https://github.com/jdylanmc/cmux-maestro/pull/28#issuecomment-5659682603
[r29]: https://github.com/jdylanmc/cmux-maestro/pull/29#issuecomment-5660229219
[r30]: https://github.com/jdylanmc/cmux-maestro/pull/30#issuecomment-5661185922
[r32]: https://github.com/jdylanmc/cmux-maestro/pull/32#issuecomment-5662015261
[r33]: https://github.com/jdylanmc/cmux-maestro/pull/33#issuecomment-5661869270
