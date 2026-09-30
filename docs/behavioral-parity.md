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

The hosted integrated runner now builds once, executes that **one unchanged
test** alone in the integrated test host, and executes every remaining test
from the same build in a second invocation. It does not serialize the remaining
suite or alter either detached driver, any assertion, or the three-second
bound. `xcresulttool` must report exactly one executed, correctly identified
test before that selector may be excluded from the loaded invocation. Both
scopes must pass with explicit nonzero, reconciled counts; unrelated skipped
tests and a repeated concurrency test are errors. A selector/count extraction
failure runs an unfiltered coverage fallback but **still fails** the command.
There is no retry-until-pass path.

Each hosted invocation retains separate xcresults, raw summary/test JSON and
`coverage.json` under `.build/tests/scoped-results/`. The isolated raw result
and both scope counts also appear in the job log, so the parent verifies the
actual hosted selector rather than accepting a guessed selector or local
standalone count. The inherited-MainActor negative remains sensitive because
the test body and non-yielding observer are unchanged. Previous hosted
concurrency reds and the separate native viewport-settlement failure remain
recorded; only a necessary current-head hosted run can establish their state.
All eleven workflow commands remain required.

### Dedicated observer registration (#114)

Explicit setup now owns a dedicated version-1 user file for exactly
`sessionStart`, `userPromptSubmitted` and `postToolUse`. The bundled helper,
identity checks, session reader and renderer are unchanged. The lifecycle/icon
plugin remains, without observer declarations. Generation/provenance checks,
bounded descriptor-relative reads, conditional writes, a same-setup lock and
phase-specific results distinguish missing, stale, disabled, conflicting,
incomplete and current-on-disk registration.
Persisted incomplete/conflicting plugin state takes precedence over disable
classification. A completed receipt binds opaque provider-returned event keys
to the exact registration generation/version, allowing fresh file-only status
to distinguish all/subset disables. Unknown keys or missing/stale applicability
evidence report unresolved, not ordinary current-on-disk. Check Registration
starts no metadata process. The existing command-line installer treats verified
enabled, all/subset-disabled and unresolved-applicability completions as success
while retaining explicit messages; real errors and usage retain nonzero exits.

The tested setup compatibility boundary is **Copilot CLI 1.0.88 and 1.0.89,
SDK protocol 3**. Other version/protocol pairs refuse before registration changes.
Setup uses only `status.get`, `hooks.discover` and `plugins.list` over a new,
bounded public stdio connection. It sends no agent/session creation or model
request, never attaches to an existing session and shuts the metadata process
down after its three replies. Framing, malformed replies, output limits,
timeout, cancellation and process-group cleanup are independently checked.
No private native module or hash implementation is a product dependency.
Host-only discovery labels this file `hooks/cmux-maestro-observer.json`;
project-scoped discovery uses its absolute path. Only those exact user-origin
labels are recognized, alongside independent file/provenance checks; arbitrary
relative paths and other origins are not normalized into ownership.
Registration file work and the setup UI's read-only status checks use a
concurrent file-worker queue rather than MainActor or the cooperative executor.
Each invocation awaits its own transaction steps; cancellation joins an
already-started writer before returning. This does not serialize the test suite
or widen the original process-cleanup/readiness deadlines.

The 1.0.89 maintenance probe covers public metadata, inactive file staging,
official plugin settings normalization, real-core migration/install/update/
removal, and related/unrelated-key refusal using disposable homes. It makes
zero model calls and does not extend the earlier 1.0.88 event-execution,
running-session reload or global-disable observations to 1.0.89.
That initial conservative unrelated-key refusal is superseded only for the
positively proven unaffected case: complete exact-owned prior keys, all owned
events enabled, and every global disabled key resolved to an unrelated action.
Affected subsets, missing keys and ambiguous metadata still refuse. No settings
migrator, enabled duplicate preview or private key hash is introduced.

The earlier 1.0.88 probes established these separate facts:

| Evidence level | Observed result and limit |
|---|---|
| Source/on-disk format | User version-1 files are accepted independently of plugins. Sources combine; there is no provider deduplication. |
| Public discovery | File-level `disableAllHooks` returns disabled rows but omits their destination disable keys. The actual legacy sorted-key producer and four justified user representations did not preserve legacy keys: normalization changed serialized config order, not inherently source identity. |
| Disable-key mapping | Additive old/new **global** keys preserve all-three and single-event intent in discovery. Repository `disabledHooks` was ineffective even against the unchanged legacy source. These are not event-execution claims. |
| Actual activation | `sessionStart` and `userPromptSubmitted` markers preceded the sole quota-rejected model request. Permission-free public `tools.execute` produced `postToolUse` markers. No successful model turn was available. |
| Concrete session cache | Existing disposable-session `postToolUse` retained A after disk changed to B; a fresh session used B; explicit supported hook reload switched the existing session to B. Other events were not separately re-proved after reload. |
| Global disable limitation | `disableAllHooks:true` did **not** suppress `postToolUse` on the tested `tools.execute` path, including in a fresh runtime. This is not generalized to a successful model loop. |

The implemented fallback is deliberately smaller than a speculative settings
migrator: when a change needs unavailable destination-key mapping, refuse
**before changing the legacy registration**. Never enable a duplicate just to
discover a key, reverse-engineer hashes, drop old keys or approximate a
single-event disable with a new blanket policy. Maestro reads global settings
without writing them. The official CLI can replace `settings.json`; after a
successful command only identical values or an added empty `enabledPlugins`
map are acknowledged, with fresh safe-file checks. Any changed disable or
unrelated value still refuses. An explicit global/file disable preserves a disabled owned
file; setup does not claim it repaired provider-wide enforcement.

Migration stages only the exact owned **disabled** file, confirms disabled
discovery, prepares and officially installs the hookless plugin, verifies its
cached declarations and public metadata, then publishes the intended file.
Foreign/modified owned registrations, wrong selected owned identities, unsafe
owned paths and changing inputs refuse rather than being overwritten.
Exact-source identity is independently bootstrapped by public install into a
disposable provider home, using the same absolute source path, not a copied
path or private hash. The supported-version result must match current real-home
selection and any old receipt before effects. A name-derived receipt is not
authority; forged or foreign source provenance fails that independent check.
Fresh-install authority is recorded before real-home provider mutation.

The false foreign-cache audit has been removed. Public foreign identity/hook
continuity is checked without reading their source/cache directories or
claiming selected-source coverage. Unrelated same-event direct, marketplace,
live, built-in and opaque records are preserved; an unsafe ancestor of the
actual owned cache still refuses. The historical alias counterexamples are
preserved as evidence against the old audit, while owned-name/source alias
cases are mandatory pre-effect rejection tests. An unowned plugin may still
invoke current/old helpers and cause extra executions or writes; this is
neither prevented nor certified harmless. Status concerns owned registration,
not provider-wide uniqueness. Existing directly inspected user-file conflicts,
disable-key refusals and no-follow guards remain.
A failure confined to provenance/disabled staging restores and verifies the
previous owned file/provenance bytes, absence and permissions before returning,
including on cancellation. Concurrent replacement refuses restoration rather
than overwriting foreign bytes. All resource inputs and the unchanged socket
path bound are checked before resource writes begin. The resource fixture uses
an exclusive short disposable directory rather than depending on checkout
path length; it also exercises the overlong-path refusal before effects.
Owned resource preparation now preflights the complete fixed file set and uses
the existing conditional file-state writer. Its failure path verifies and
restores earlier resource writes, including executable modes, absent files,
large bounded font/catalog resources and the obsolete owned guide. A verified
resource restoration also permits restoration of disabled observer staging.
Unchanged resource bytes/modes are no-ops rather than inode replacements.
Real permission-denied late writes exercise reversal, with changed file stamps
proving an earlier write actually occurred. Unsafe later targets refuse before
earlier writes. Preflight/no-write, verified restoration and unverified
restoration are separate outcomes; unrelated files and live routes remain
untouched. Standalone maintenance retains this in-process compensation. The
normal alpha installer adds the durable coordinated boundary below.
A later failed step reports the last completed phase; the next phase may have
partially refreshed setup resources. Retry revalidates recorded generations
and known partial preparation, preserving a retained disabled stage. It never
rolls back blindly or changes existing sessions. Removing integration preserves
global keys, unrelated hooks and live messaging route/session state.

### Coordinated alpha installation (#114)

The focused Python suite covers ordinary `install` upgrades, exact registered
identical no-ops (without app replacement, receipt changes or lost backups),
automatic restoration after copy/exchange/registration failures, first-install
absence, interrupted restoration, exact development-source registration
restoration and refusal to race an unfinished command guardian. Existing
ownership, integrity, process identity and partial-cleanup controls remain.
Changed-app publication withdraws only the owned registration, waits at most
120 seconds for positively identified preview processes to exit, and registers
the replacement. Unknown process evidence still fails immediately. Tests cover
ordered withdrawal/re-registration, unchanged unrelated registrations, bounded
waiting and restoration when release fails; no UI selection, host restart or
script-sidebar reload is used.
The normal containing app is no longer treated as an indefinitely busy
extension. A changed-app update journals the exact running app's owner/start
generation, executable and code identity, then requests only
`NSRunningApplication.terminate()`. Refusal or failure to exit aborts without
force termination. The prior running/hidden choice is restored with an exact
URL `NSWorkspace` launch configured not to activate, hide other apps, substitute
another installation, create a duplicate instance or prompt for optional UI.
Quarantine refuses relaunch rather than bypassing system policy.

Injected AppKit handles cover ownership mismatches, PID-generation changes,
other app copies, helper/extension exclusion, refusal and idempotent restoration.
A separate non-UI process fixture compares the public Security-framework code
identity with the existing kernel-cached code hash. Installer tests cover
quit/launch interruptions, failed restoration and rollback after a replacement
app has started. These tests do not invoke real GUI quit/launch; the hosted
stock-host proof must still establish real release/recreation and focus behavior.

`build-register.sh` now hands its verified artifact to the same `install`
entrypoint; it no longer separately registers the development extension.
The installer calls a production-only, non-UI bridge with a transaction UUID
and stable application path. It prepares an owned integration checkpoint before
the app exchange, applies Copilot, verifies provider discovery and exact app
registration, and only then commits current/previous app retention. An identical
app also checks integration; a fully current repeat skips resource replacement
and official plugin mutation.

The durable integration checkpoint is private `0600` data in
`Orchestration/install-transaction.json`, outside the sidebar's granted
`Copilot/` and `Orchestration/observer/` prefixes. No permission is broadened.
Recovery validates the schema, fixed file paths, original modes/absence,
expected resource bytes and transaction UUID. It keeps observers inactive while
compensating through official install/uninstall at the stable owned source,
restores prior settings only across verified CLI normalization, and verifies
the original public plugin/hook inventory before the app is restored.
The fixed owned installed payload is verified too. If source and installed
copies differed before an interrupted setup, compensation temporarily supplies
the saved installed payload at that same source, verifies official replacement,
then conditionally restores the original source bytes. Provider-private state
and unrelated plugin directories are never rewritten.
Unexpected concurrent content or disable changes refuse compensation rather
than being overwritten. Failed compensation retains the checkpoint.

Receipt publication now has a write-ahead exact-image boundary. Before a
staged/current observer receipt can change, the checkpoint validates its
current image and durably records the complete intended bytes/mode/source
binding. Missing-`after` recovery cannot substitute generation equality for
that authorization. Tests change plugin identity and source path/ID without
changing the generation, and require preserved edited bytes/resources and
journal with no compensating provider mutation. A real compiled-bridge exit
after current-receipt publication but before the final snapshot still recovers.

The existing finite command guardian also covers nested provider groups.
Standalone provider processes retain their independent groups and original
timeout/cancellation cleanup. Coordinated providers use the same grouping but
wait behind a launcher gate until the trusted bridge synchronizes their group
IDs into the inherited install-guard record; providers never inherit that
descriptor or its environment. The guardian re-reads and drains the complete
record after bridge exit. If it also dies, fresh recovery refuses while any
recorded group survives. Actual compiled bridge/provider gates prove this for
forward and compensation paths, with and without guardian death, preserving
unrelated processes. The old observed late-write-after-restoration results
are retained as red evidence, not relabeled as supported behavior.

Plugin mutations use public sessionless RPCs, with the supported status checked
before the mutation request. An install receipt supplies the exact owned
`directSourceId`; later discovery must match. Removal and compensation target
that identity, not just the manifest name. Even a receipt followed by a failing
provider-process exit is retained for recovery. Independent bootstrap records
the same source's identity before real-home mutation, so a lost production
response can still be compensated without adopting a name-only list row.
Recovery bootstraps again and checks current selection before effects; source
files remain until exact-ID removal succeeds. Failed bootstrap and foreign
identity drift do not grant compensation authority.

The pinned [1.0.89 changelog](https://github.com/github/copilot-cli/blob/8dfa6009c4a04b3a22a5ca4a7c36a056edd718dd/changelog.md)
supersedes the SDK comments claiming direct installs are always enabled.
Disposable official-provider probes confirm direct disable/enable, zero
discovered plugin hooks while disabled, and re-enabling on both install and
update. The installer preserves a verified disabled native plugin without
provider mutation for no-ops and compatible external-resource-only updates.
For a required payload replacement it records original state and mutation
intent before the official operation, keeps dedicated staging inactive, and
requires official `plugins.disable` plus exact-source readback before
publication/commit. The disable RPC is version-gated to 1.0.89 and checks the
selected identity before its name-based mutation. Install/update success alone
does not prove preservation. Disabled legacy observer migration also disables
the dedicated file; an existing dedicated file retains its independent choice.

Recovery handles a failed/lost disable response or process exit between the
operations using the durable intent, independently re-established source
authority and official disabled-state restoration. Exact prior cache/source and
settings are verified before the app rollback completes. A prior payload that
is already intact is not needlessly reinstalled. No private enablement key is
guessed or edited. User re-enablement after verified apply and foreign identity
drift refuse rather than being cleared. These are separate provider operations:
the intermediate enabled state is real, not described as atomic suppression.
Local tests cover that boundary without executing hooks or restarting sessions;
actual stock-host and installed-session gates remain separate.

The Python suite executes the compiled Swift bridge in separate processes over
real disposable files, covering success, no-op, upgrade, late failure, first
absence and an actual installer-process exit after apply. A fresh installer
then recovers both generations from disk. These automated tests use a provider
double and synthetic registries; they do not prove real stock-host reload.
Another actual process-exit case stops between integration restoration and
the app exchange: resumed recovery refuses a subsequent foreign edit, then
completes after the fixture restores the verified input. Pending committed
checkpoint cleanup blocks legacy maintenance mutations, and false-shaped
receipt fields cannot bypass coordination.
The Swift checkpoint suite separately covers stable-source compensation,
disabled legacy restoration, repeated recovery, arbitrary-path refusal and
concurrent-write controls. The focused test script's compile-only mode builds
that non-UI fixture; its normal CI command still runs every existing test.
Current eleven-command hosted CI, source-binding resolution, native lifecycle
proof and later installed fresh-session acceptance remain separate gates.

[CopilotObserverRegistrationTests](../CMUXMaestroPreviewTests/CopilotObserverRegistrationTests.swift)
cover isolated registration, migration, exact event/wrapper content, preserved
disables, unavailable-key refusal, unsafe/foreign/modified state, interrupted
phases, retry, concurrent replacement, metadata and owned removal.
The existing setup cleanup tests retain their original deadlines, negative
controls and unrelated-process assertions. Complete CI, independent review and
any later production/live acceptance remain separate candidate gates.
Metadata cancellation fixtures publish the completed PID marker by same-folder
rename, not file existence before `printf` finishes. A gate-controlled negative
control demonstrates the old empty-marker window; the atomic case cannot expose
it. Error/cancellation paths join the owned task before deleting its fixtures.

### Deep-outline fixture readiness

Focus-layout fixtures own **available content width**, not AppKit's preferred
scroller style. A test-host-only modifier applies `scrollIndicators(.never)`
to the unchanged production sidebar/tree and reserves a constant trailing
gutter derived from the public `NSScrollView.contentSize` API, separately for
overlay and legacy budgets. No gutter size is hardcoded and no content width
is frozen: resizing the owned window still changes the viewport and title.
These are **overlay/legacy-equivalent available-width inputs**, not native
indicator appearance or identical row-geometry claims.

The stronger policy is intentional:
[`.hidden` can still show macOS indicators when a mouse is connected](https://developer.apple.com/documentation/swiftui/scrollindicatorvisibility/hidden);
[`.never` overrides that policy](https://developer.apple.com/documentation/swiftui/scrollindicatorvisibility/never).
Before immutable baseline capture, preparation requires absent native scrollers,
no native width gutter, a visible deep title, document/clip width agreement and
matching geometry samples. It does not claim native quiescence or pin style:
[AppKit can subsequently update style and retile](https://developer.apple.com/documentation/appkit/nsscroller/preferredscrollerstyle).
Cold-start evidence observed that update on both fixed-budget fixtures without
changing their title/viewport frames, alongside an unmodified native control
whose width changed. A one-time explicit style assignment alone failed that
stress. The matching hosted width delta still does not establish its trigger.

`deepOutlineFixedViewportSurvivesNativeStyleChanges` compares each budget's
available viewport against a separate, real-native production render, then
requires exact title/viewport equality through both native style-transition
directions. Focus and no-focus tests run both budgets; focus retains both
densities and appearances, the 124-point minimum, height/depth caps and 20 ms
effect interval. The real-window-width negative control also runs both budgets,
requires the full 26-point viewport loss and still rejects changed title frames.

`nativeEightLevelOutlineRetainsMinimumTitleWidthAt280` separately protects the
actual native depth-eight title at a 280-point host: at least 124 points wide,
at most 70 points high, in both densities, light/dark appearances and both
native scroller styles. It verifies the requested style and visible native
geometry before each static measurement, without the fixed-input inset or a
subsequent timed equality check. This absolute guard is necessary because the
equivalent-width fixture's inset changes indentation and gives its legacy
title two extra points; that fixture alone cannot protect the native minimum.
Style assignment is not treated as a pin against later AppKit updates.

`deepOutlineLateNativeStyleChangeInvalidatesSampledBaseline` exercises both
overlay-to-legacy and legacy-to-overlay transitions through the public setter,
in run-owned offscreen fixtures without focus. It requires opposite viewport
width directions, equal title/viewport width deltas and an unchanged title
height; the original exact frame comparison rejects both changes. This control
and all ordinary full production renders remain outside the fixed-input modifier.
Neither layer restores geometry after baseline. Global preferences, production
layout and AppKit test gates remain unchanged. Fixed-input focus coverage and
actual native composition/transition coverage are separate layers; neither
substitutes for the other.

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
| Granted workspace/project/surface paths | [SidebarNavigationTests](../CMUXMaestroPreviewTests/SidebarNavigationTests.swift): `realSDKGrantedNilPathsRemainDistinctFromUnavailable`, `sessionPathPresentationUsesCurrentSurfacePlacementNotLaunchWorkspace`; [SidebarAgentHoverTests](../CMUXMaestroPreviewTests/SidebarAgentHoverTests.swift): `directoryConsumersKeepHostSourceAndPermissionDistinct`, `directoryUpdatesFollowExactMovedSurfaceWithoutReusingCapturedPlacement`, `retainedOriginalNeverBorrowsReplacementDirectoryButNativeContextSurvives`; [HierarchySnapshotTests](../CMUXMaestroPreviewTests/HierarchySnapshotTests.swift): `homeRelativeDisplayUsesComponentsWithoutChangingSourcePaths`; [SidebarPinnedDetailsTests](../CMUXMaestroPreviewTests/SidebarPinnedDetailsTests.swift): `directoryProvenanceRendersInProductionHoverPinnedAndDetails` | The [pinned source contract](../README.md) is a host surface report, not independently verified agent/tool current directory; report time is not supplied. Child labels remain parent-surface context. SDK filtering and synthetic offscreen production-card proof distinguish denied/nil paths, preserve exact subject and home-relative formatting, and retain the field through hover/pinned/details filters. Existing [PR32][r32] acceptance predates this source qualification; installed-CMUX acceptance for this #77 slice remains unperformed. No full #77, worktree-identity or topology closure is claimed. |
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
  from current host binding. The existing `childWork` always remains a valid
  nested v1 hierarchy; additional `childWorkObservation` carries ordered literal
  edges and explicitly marks lossy legacy projections without fabricated parents.
  [Adapter tests](../CMUXMaestroPreviewTests/CopilotSnapshotAdapterTests.swift)
  exercise the real polling reader seam and unknown/partial evidence.
  [Compatibility tests](../CMUXMaestroPreviewTests/AgentSnapshotCompatibilityTests.swift)
  retain the negative unsupported-state control.
  [Actual frozen validation](../CMUXMaestroPreviewTests/LegacySnapshotValidationTests.swift)
  checks the original codec and validator against fixtures and new graph shapes.
  [Consumer validation](../CMUXMaestroPreviewTests/NeutralObservationValidationTests.swift)
  exercises malformed neutral projection and polling, safe peers, retained active
  descendants, history protection and bounded traversal with explicit unknown
  omission totals. This implements the literal
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
