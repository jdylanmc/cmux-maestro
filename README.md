# CMUX Maestro

A compiled macOS CMUX sidebar that displays Copilot sessions and their durable
agent hierarchy. The native sidebar reads locally; no companion daemon,
watcher, loopback server, XPC service, raw CMUX socket, or session-start ritual.
The separate interpreted Maestro project is untouched and is not a dependency.

## One-time setup

1. Build/register the native app and extension, or open an installed build.
   Keep the app at its intended location before enabling integration.
2. Open **CMUX Maestro Preview**. Click **Enable Copilot Integration**, then
   explicitly confirm **Install Native Plugin**. If the app's configured `PATH`
   cannot find Copilot, use **Choose Copilot…** to select the trusted executable
   you normally run. No shell startup files or machine-specific cache paths are
   assumed.
3. In CMUX's **Sidebar Extensions** browser, enable **CMUX Maestro Preview** and
   select it as the active sidebar.
4. Restart or resume already-running Copilot CLI sessions **once** to load the
   newly installed plugin. Maestro never restarts them automatically. Launch
   future sessions normally inside CMUX; their hooks record validated identity
   and the sidebar renders the tree directly from durable events.

The containing app is an installer, not an observer. It may be closed after
setup. A successful setup message means the selected CLI exited successfully;
it does not claim a running session has already loaded the plugin or that the
host extension has been enabled.

Installer invocations start in their own process group. **Cancel Setup** and
the 45-second timeout stop that invocation's launcher and descendants, then
wait for cleanup before permitting retry; existing Copilot sessions are never
signalled. CLI output remains suppressed.

Only the distinct **`cmux-maestro-native`** plugin is installed. Existing
`maestro-cmux`, other plugins, provider settings, and sidebar selection are
never replaced automatically. Moving/replacing the native app requires enabling
the integration again: Copilot caches local plugin contents, and generated hooks
contain the **absolute current bundled helper path**.

### Disable or uninstall

Use **Uninstall Native Plugin…**, then explicitly confirm. This runs only
`copilot plugin uninstall cmux-maestro-native`. Restart/resume existing CLI
sessions to unload their cached hooks. Disable this sidebar in CMUX separately
if desired; uninstall does not select or remove any other provider.

For individual future CLI launches, either `CMUX_COPILOT_HOOKS_DISABLED=1` or
`MAESTRO_NATIVE_DISABLED=1` suppresses identity hooks. The legacy
`MAESTRO_DISABLED` flag is not changed or used by this integration.

## Data and trust boundary

- The small native executable lives at
  `CMUX Maestro Preview.app/Contents/Helpers/CMUXMaestroCopilotHook`.
- Only `sessionStart`, `userPromptSubmitted`, and `postToolUse` hooks run it.
  No veto/control, pre-tool, or agent-stop hooks are registered.
- It accepts bounded JSON with canonical `sessionId`/`session_id`, plus its own
  inherited `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID`. It never accepts a
  transcript path or infers identity from a title, current directory, or text.
- Same-user BSD process metadata identifies a matching **ancestor**, not
  blindly the hook's shell parent. A source `inuse.PID.lock` and stable process
  generation must agree before the helper publishes an atomic binding.
  Symlink traversal, stale owner generations, and mismatched live owners fail
  closed. A missing early session-start marker can be retried on a later hook.
  The helper and sidebar share the marker/process verifier: marker contents are
  never read, and no content-size limit is imposed. Birthtime/ctime and the rest
  of the marker stat snapshot must remain stable; unknown or multiple live marker
  owners are ambiguous rather than guessed.
- Bindings live under
  `~/Library/Application Support/CMUXMaestroPreview/Copilot/bindings/`.
  Own directories are `0700`, files `0600`; dates use milliseconds since 1970.
  The last diagnostic is a bounded generic status, never a hook payload, path,
  credential, transcript, or raw CLI error.
- The outer hook shell redirects both output streams and returns zero even
  when the helper is missing, fails, or crashes. Hooks cannot supply prompt
  content, tool decisions, or control commands.
- The sandboxed sidebar first performs a bounded scan of Maestro-owned,
  sanitized routing records in `bindings/<sessionUUID>.json` to find records
  matching the host's granted surfaces. Unrequested records are rejected before
  process or session-file reads; their identifiers, counts, and content are not
  returned. This routing-index discovery is distinct from reading transcripts.
- Only after surface filtering and stable live-identity verification does the
  sidebar read that session's durable events beneath **the real user's**
  `~/.copilot/session-state/`. It displays sanitized, allowlisted metadata,
  never raw transcripts. It does not launch the helper or install anything.
  Tree navigation uses the CMUX extension API and current host snapshot.
  Unavailable evidence is not fabricated as a live session.

The source contract is Copilot CLI's current durable session/event format.
Only the **standard Copilot home** is supported; custom `COPILOT_HOME` and
symlinked state directories are not supported. Missing lifecycle events can
leave completion/status unknown, and agent IDs are not automatically native
child-session IDs. No title/transcript heuristics repair missing identity.

## Completed work history

The sidebar's **gear** opens native history settings, shared by **Hierarchy** and
**Taskboard**. Finished, failed and cancelled child outcomes are retained for
**15 seconds** by default; choose **1 minute**, **5 minutes**, **1 hour**, or
**Never**. Retention starts at the accepted terminal event's RFC 3339 timestamp,
not the poll, first display, or application launch. Missing, malformed, or
future timing is shown as **Completion age unknown** and never automatically
expired while unknown. Source events are not deleted.

Use a row's separate **Dismiss** button, or **Clear completed** for eligible
retained outcomes on current-window surfaces (including collapsed branches,
excluding display-capped/off-window/expired work). These controls never focus,
cancel, approve, prompt, or otherwise control an agent. Working, blocked, idle,
and unknown work stays visible under the existing display limits. A hidden
terminal parent remains as **child context** when descendants still need it.
Running counts and retained/hidden history counts are separate; empty history
is not evidence that a session has finished.

History uses a versioned `CMUXMaestroPreview/sidebar-history.json` record in the
extension container's Application Support directory. Coordinated, atomic
read-modify-write actions preserve other windows' retention and dismissals,
including separate extension processes. Existing windows observe changes through
file presentation (no polling daemon); same-process windows update immediately.
The selected view remains in `UserDefaults` and is not changed by history actions.

On first use, the existing `sidebar.completedHistory.v1` defaults record is
validated within the same coordinated transaction and migrated once. The file
is authoritative thereafter, even if another process has stale legacy defaults.
Only after a successful file write/read is the old key removed. Invalid legacy
or file data stays untouched until an explicit reset; failed migration can be
retried. No settings are mirrored back into the old history key.

Dismissal keys contain only provider-session UUID,
child ID and accepted terminal-event UUID—not labels, paths, or source content.
Reloads, duplicate events and surface/workspace moves preserve identity; new
work or a new terminal outcome does not inherit an old dismissal. Fresh lifecycle
identities—not comparisons against possibly future wall-clock timestamps—reopen
work. Retired invocation and agent-scoped turn identities remain tombstoned,
independent of current tool mappings. Repeated starts cannot reopen old work,
even with a new event UUID.
Records are
bounded to **2,048 dismissals / 1 MiB**; a full store refuses a new batch rather
than evicting old keys silently. **Restore dismissed history** frees that store;
retention still applies, so select **Never** to reveal older work.

Malformed stored settings fail open: history hiding is disabled and a bounded
notice offers **Reset history settings**. Ordinary retention/dismiss/restore
actions never overwrite corrupt data. Reset explicitly restores 15-second retention
and clears dismissals; restore clears only dismissals at its coordinated turn,
preserving the latest retention. Later dismissals remain later actions, not a
resurrected window snapshot. Neither action changes the selected view. Storage
I/O failures also fail open with a notice; capacity rejection keeps the last
valid record and rejects the entire batch. History deadlines use a
single cancellable timer, are not reset by refresh, and stop on hide, disconnect,
or access loss. Existing observation freshness remains an independent limit.
Reducer replay protection keeps up to 65,536 exact recent lifecycle event UUIDs
and 4,096 exact recent start/work/tool/resolved-request keys per session.
Each ledger spills into its own fixed 128-KiB filter rather than rejecting new
events at the exact-window boundary; spilled bits are never cleared within a
transcript generation. Cold matches are uncertain and report partial data.
Actual filter saturation fails closed; it never silently forgets anti-replay
evidence. Cold start-identity matches cannot distinguish old replay from a fresh
start's false positive. A matching agent row that is already terminal is exposed
as unknown, clearing its obsolete terminal outcome and completion pairing so
prior dismissal/expiry cannot hide potentially active work. A terminal root
similarly becomes unknown on an uncertain root turn. Neither case claims fresh
activity or adopts the unprocessed event's model. Live/blocked rows, pending
requests and unrelated root state remain unchanged; exact replay is a no-op.
On unprocessed fresh lifecycle evidence,
uncertain new starts demote affected work to unknown and clear obsolete terminal
evidence, so a prior dismissal cannot hide possibly active work. Unresolved
lifecycle scope is demoted conservatively; uncertainty alone does not resolve
known pending requests. Session identity/schema checks run
before all deduplication and capacity guards.
Complete, identity-verified reads publish conservative semantic degradation as
current partial data, including unknown lifecycle state and replay limits.
Malformed events, incompatible session schemas, identity changes and torn reads
still cannot publish unvalidated replacement state.

## Attention and safe activity

Both views distinguish **Waiting for permission** from **Waiting for answer**,
on the session or child that owns the durable request. Pairing uses request kind,
owner and request ID; a completion for another owner or kind cannot clear it.
Hook-resolved permissions do not block. Repeated/late request identities cannot
reopen a resolved request. Rejected stale abort/error evidence cannot erase a
newer request. Missing ancestry stays explicitly unresolved.
Independent requests are not ordered against one another's clocks: a delayed
question remains pending even if a different permission has a newer timestamp.
Hook resolution uses the exact kind/owner/request identity, including when it
arrives after another request or a new turn.

The compact **Needs attention** affordance includes outstanding requests and
nonblocking outcomes. **Acknowledge** records only the latter locally in the
native sidebar. **Acknowledge all** uses the current-window projection, including
collapsed branches but excluding off-window or display-capped rows. An owner
with a pending request is never eligible, even if it also has an outcome.
Neither acknowledgement, history dismissal nor focus sends approval, answers,
cancellation or any agent-control command. CMUX unread counts are untouched.

**Turn finished** means a matching primary `assistant.turn_end` was recorded,
not that the session or its background children finished. Root errors/aborts
likewise do not end or unblock unrelated children. Process liveness, work state
and attention remain independent. Process presence, idle time, file modification
time and expired history never imply success, progress, or a hung agent.

Outstanding nonblocking evidence is intentionally bounded: only the latest
accepted error/abort outcome per owner, plus the latest primary-turn completion.
Successful historical child completions are history, not attention. Fresh
owner turn/tool/invocation activity retires that owner's obsolete outcome. A
new primary turn begins a new outcome cycle for the session and its children;
it does **not** resolve their still-pending requests. Resume invalidates prior
activity/attention and demotes nonterminal children to unknown, rather than
claiming that pre-resume background work completed. Accepted terminal child
evidence remains available to history controls. Duplicate/retired lifecycle
identities cannot restart attention or its timing.

Outstanding attention protects rows from history retention and dismissal.
Acknowledging an error/abort then allows ordinary history retention to apply;
required parent context and current blocking descendants stay visible. No timer
auto-acknowledges anything. History and acknowledgement resets are independent.
The reader also protects current-cycle outcome owners from terminal-leaf
retirement. Local acknowledgement changes presentation, not the provider's
ingestion state; a verified new primary turn or fresh owner activity establishes
when prior nonblocking signals are obsolete. Genuine active/attention capacity
exhaustion is reported as partial data rather than dropping protected signals.
Unknown lifecycle data or replay-filter saturation can invalidate current
activity, but cannot silently acknowledge already-recorded outcomes or requests.

Acknowledgements persist by provider-session UUID, owner ID (or primary owner),
source and stable accepted event UUID. Labels, paths, tool payloads and topology
are not keys. The same outcome remains acknowledged after reload or surface
moves; a new outcome reappears. Storage is versioned and bounded to **2,048
acknowledgements / 1 MiB**, refuses overflowing batches without eviction, and
offers **Reset acknowledgements**. Corruption fails open with a visible warning:
no attention is hidden by unreadable settings.

Acknowledgements use the same coordinated action store as history, in the
separate extension-container Application Support file
`CMUXMaestroPreview/sidebar-attention.json`. Acknowledge unions only the
current projection's eligible identities into the latest on-disk record;
other windows/processes observe changes automatically without polling. Reset
clears acknowledgements at its coordinated turn, never history or the selected
view. Later acknowledgements remain later actions, not restored stale snapshots.

The old `sidebar.attention.v1` defaults record is validated and imported once
under the same lock. The file is authoritative thereafter; the legacy key is
removed only after successful persistence/read. Corrupt or future-schema files
and legacy data fail open and are left untouched by ordinary acknowledgement
actions. Only **Reset acknowledgements** replaces them. Failed migration retains
legacy data for retry. Tests inject both history and acknowledgement files.

Activity uses only the allowlisted durable tool-name field: **Executing tool**
(the latest still-executing invocation for that owner) or **Last completed tool**.
The latter is a tool-invocation event, not a statement that a detached shell
process exited. Child attribution requires real event ownership. Names must be
bounded symbolic identifiers; arguments, results, prompts and raw errors are
never decoded for display. Invalid/missing/future timing is explicitly unknown;
timestamps are not replaced with poll time. No token/context counters, guessed
percentages or speculative stall detection are implemented.
Lifecycle acceptance never depends on the current read clock. Tool and turn
completions pair with their own active invocation/owner identities; contradictory
start/completion timestamps retain the completed evidence with **unknown timing**,
rather than resurrecting executing work on a later replay. Observation freshness
and future display timestamps are validated separately in sidebar projection.
Missing tool ownership never creates an error or executing activity: a bounded
completion tombstone prevents a later start from resurrecting that invocation.
Delayed tool metadata for an already-ended spawn cannot reopen its owner.
Tool starts classify their start, completed-tool and shell-row replay aliases
together before mutating owner metadata. An exact match is a no-op; uncertainty
in **any** alias fails terminal history open without changing a live owner.
The legacy shell-row alias remains checked even for non-shell tool names, keeping
global tool-ID replay protection conservative across metadata/name differences.
Both ordinary tool and actual shell starts have selective-alias regressions.

The reusable neutral `AgentActivity` contract lives in `Domain/AgentSignals.swift`
alongside evidence-bearing attention primitives, compiled into app, sidebar and
tests, not the hook. Existing snapshot behavior is unchanged. New live model
fields are optional for backward Codable compatibility. Reader identity,
partial-read, corruption, freshness and replay-cap safeguards still apply;
untrusted or unavailable evidence cannot fabricate an outcome or an action.
Broader presentation preferences, telemetry and the remaining backlog are not
claimed by this feature.

### Bounded retention and discovery

- The 256-row reducer budget retires the oldest terminal **leaf**, not active,
  idle, blocked, or unknown work. Current-cycle error/abort outcomes protect their
  owners. Retained descendants, pending requests, and
  unresolved active ownership protect their ancestors. Agent row IDs stay stable
  across fresh lifecycles; retirement does not permanently blacklist an agent ID.
  Completed tool ownership is reclaimed separately so the 4,096-relationship
  budget does not become the next long-session bottleneck. Recent completed
  owners still support delayed parent joins; retired joins remain unresolved.
  Retirement removes only the retired owner's obsolete turn/activity/outcome
  records and joins. Signal dictionaries are bounded by retained owners plus
  the primary owner; tool ordering uses the bounded retained-tool list.
  Request/tool-only unknown owners use event-scoped lifecycles, never permanent
  agent-ID tombstones.
- Spawn replay keys use the spawn tool ID; turn replay keys use owner + turn ID.
  A new spawn tool or previously unseen scoped turn is fresh activity, even for
  a retained or retired terminal agent. Completions pair with the row's current
  spawn, so a late old completion cannot finish a newer lifecycle. A turn alone
  recreates an unknown agent, not an invented old name/parent/spawn. Enriching an
  unknown row must not silently discard its pending requests.
- Work/lifecycle/tool/request replay keys keep up to 4,096 exact recent tombstones.
  Resolved-request keys include length-qualified owner, request kind and request
  ID; spilling never collapses root/child or permission/answer namespaces.
  Older identities spill into a deterministic 128-KiB replay filter; its bits are
  never cleared within a transcript generation. This bounded filter has no false
  negatives, but can have false positives: a cold match rejects fresh admission
  **and reports `readLimitReached`**, rather than claiming exact replay knowledge.
  Terminal agent/root state fails open to unknown as described above; an uncertain
  start-identity match does not demote live work.
  This also applies to uncertain tool-activity admission for a terminal owner.
  Clearing obsolete terminal history does not acknowledge retained attention or
  resolve a pending request.
  At half occupancy it fails closed; it never forgets history to admit more work.
  True active-capacity exhaustion also reports a limit without fabricating
  completion. Transcript replacement reconstructs this state from the new log.
- Routing discovery resumes one descriptor-anchored directory stream across
  batches (up to 1,024 directory entries per batch, plus bounded revalidation of
  at most 64 cached identities and one staged granted binding). Historical locks
  and off-surface records cannot pin discovery to a prefix. At most 64 transcript
  tails are retained. An unfinished initial tail keeps its slot until its finite
  captured byte boundary is verified and published (or explicitly unavailable);
  discovery stages at most one next binding while it waits. Finished slots then
  rotate, retaining an explicit limit warning when granted sessions exceed capacity.
  Only a full, unchanged, non-overflowed cycle without errors can be complete.
  Cached bindings are checked before process/transcript access and publication;
  replaced directories, revoked surfaces, and cancellation discard cached state.
  EOF, errors, cancellation, and destruction close the directory stream.
- Capture a fixed prefix length and observation time for each catch-up pass;
  later appends do not extend that lease forever. A verified complete prefix may
  be published with its captured observation time and `loadingHistory` when
  newer bytes remain; this is not a current/complete snapshot. A verified current
  EOF uses the verification time, including after multi-batch reconstruction on
  normal polling cadence. Torn or malformed
  prefixes cannot become fabricated complete evidence. A failed observation
  cannot pin every later session indefinitely.
- A binding rerouted during a read is deliberately omitted, **not** returned
  with its superseded surface/session identity as an ambiguous row. Other
  verified granted sessions remain visible; the snapshot reports
  `identityChanged` and is incomplete. A later stable read under the new grant
  reconstructs that session, including when both surfaces were already granted.
  By contrast, unstable process/marker evidence with an unchanged valid routing
  binding still produces a content-free ambiguous row. Timestamp-only hook
  refreshes preserve the verified row but require a stable discovery cycle
  before completeness. Reader tests cover all three distinct contracts and use
  `#require` before unwrapping expected observations.
- `hasPendingHistory` accelerates initial/changed-index catch-up and retained-tail
  deltas. After an overflow sweep finishes, revisiting evicted prefixes of the
  unchanged index uses normal polling rather than an endless fast rebuild loop.
  EOF, torn final lines, and warnings alone never request a fast retry. No sandbox
  entitlement or ancestor traversal permission is broadened.

**Further presentation integration:** preserve this combined reducer's
accepted terminal UUID/timestamp, current-spawn/turn pairing, bounded event/start/
owner-qualified resolved-request guards, and `canPublishProjection` distinctions.
Retirement must continue to clean obsolete turn/activity/outcome state without
discarding pending requests, unknown placeholders or required ancestors.
History presentation limits remain separate from ingestion limits; a prior
terminal dismissal cannot hide a fresh lifecycle using the same agent ID.
Carry finite reader watermarks, staged-binding revalidation, EOF freshness and
overflow scheduling together. Layout, installer and clarity changes must not
weaken the quiet validation scene, backend setup denial, current-tree
acknowledgement guards, or the host's 50-point footer clearance.

## Requirements

- macOS 14 or newer.
- Xcode 26.6 at `/Applications/Xcode.app` for local builds.
- CMUX with sidebar ExtensionKit support.
- A Copilot CLI version supporting local plugin installation and the three
  documented command hooks, with canonical session identity in hook input.

The CMUX ExtensionKit package is pinned to CMUX commit
`ae7fbce99f98c98df5ccf915e548dd080d33cfa8`. It is fetched into ignored
`vendor/CmuxExtensionKit/`; no CMUX source changes are required.

**Host footer compatibility:** the native view reserves 50 points of bottom
clearance for the current CMUX overlaid footer. The SDK provides no footer-inset
contract; a rendered-strip regression test checks that both sidebar modes leave
this area clear. Reverify the clearance when host chrome changes.

## Build and test

```sh
./scripts/fetch-sdk.sh
./scripts/build-unsigned.sh
./scripts/test.sh
```

Focused history/preference checks (including two real child processes, coordinated
writer contention, and automatic observation/projection convergence):

```sh
./scripts/test.sh -only-testing:CMUXMaestroPreviewTests/SidebarPreferencesTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarHistoryTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarHistoryPollingTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarPreferenceCoordinationTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarAttentionTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarAttentionCoordinationTests
```

The test runner compiles a fixture-only client from the production preference
sources. Tests inject unique defaults suites and files beneath
`.build/preference-coordination/`; they never mutate production preferences.
File-I/O-heavy preference suites serialize independent cases and yield between
fixture phases so synchronous coordination does not starve unrelated UI timers.
Dedicated coordination tests still exercise simultaneously blocked writers in
separate processes and automatic observation, without manual refresh.

Xcode can register macOS app outputs with LaunchServices even when signing is
disabled. Validation builds therefore use isolated identities **and** isolated
extension points, rather than an unsupported registration-suppression setting:

| Script | App bundle ID suffix | Extension point |
| --- | --- | --- |
| `build-unsigned.sh` | `.Validation.Unsigned` | `com.jdylanmc.CMUXMaestroPreview.validation.unsigned.sidebar` |
| `test.sh` | `.Validation.Tests` | `com.jdylanmc.CMUXMaestroPreview.validation.tests.sidebar` |

The sidebar, helper and test bundle IDs use the same suffix. These copies cannot
replace the production identity or appear under CMUX's real sidebar point,
even if Xcode registers them. They are validation artifacts, not installable
CMUX sidebar providers; do not use their installer UI for integration setup.
The scripts verify resolved settings before building and
the resulting app/extension metadata afterward. Run these scripts rather than
an unqualified application build while a native integration is installed.

Validation builds also compile a settings-only app scene: test runs do not open
the Copilot setup window. If opened manually, a validation copy shows only a
read-only explanation. Install and uninstall are rejected before executable
lookup, filesystem access, or CLI invocation unless the containing app has the
exact production bundle identity. Use the installed production app for setup,
never a window labelled **Test Validation** or **Unsigned Validation**.
Resolved build checks require the no-window compilation condition for validation
and reject it for production. Tests cover both the zero-window host and
zero-side-effect install/uninstall denial; fake production setup tests explicitly
inject the production identity.

Focused, isolated setup, hook, and sandbox checks (no SDK fetch or app launch):

```sh
./scripts/test-copilot-hook.sh
./scripts/test-copilot-setup.sh
./scripts/test-copilot-sandbox.sh
python3 ./scripts/test-build-metadata.py
```

Tests use synthetic roots and injected installer/process seams. The standalone
hook smoke compiles production and **separately test-flagged** executables,
invokes them from a foreign working directory, and checks binding creation,
malformed input, disable flags, and zero output. The injected ancestry exists
only in that synthetic binary; app Debug/Release builds have no environment or
command-line switch that forges owner proof. Installer tests invoke fake
executables only, never the live Copilot plugin CLI.

The sandbox check compiles the actual shared file helper and runs it under a
narrow `sandbox-exec` policy over a synthetic deep directory. Ancestors use
search-only descriptors; the final directory still requires read access.
The check denies ancestor contents, sibling reads, and writes, and exercises
owner checks, symlink rejection, and descriptor anchoring during path swaps.
Fixtures are removed afterward; this check creates no App Sandbox container.
`O_SEARCH` is declared in Apple's
[macOS 14-era XNU headers](https://github.com/apple-oss-distributions/xnu/blob/xnu-10002.1.13/bsd/sys/fcntl.h#L184)
and [macOS 15-era headers](https://github.com/apple-oss-distributions/xnu/blob/xnu-11215.1.10/bsd/sys/fcntl.h#L184),
covering this project's macOS 14 deployment target.

These tests do **not** prove actual plugin installation, cached-hook loading,
live owner ancestry, or ExtensionKit-hosted runtime behavior.

## Build and register locally

```sh
./scripts/build-register.sh
```

This explicit script builds with an ad hoc identity, registers the embedded
extension with `pluginkit`, and verifies discovery of
`com.jdylanmc.CMUXMaestroPreview.Extension`. It **does not install a Copilot
plugin**, enable/select the sidebar, launch an observer, or modify a legacy
integration. Plugin installation is a separate deliberate in-app consent step.
It explicitly pins production IDs and the real CMUX point, verifies resolved
settings and source sandbox grants before the build, and checks built IDs,
point, strict signatures, and the extension's effective sandbox grants before
its explicit `pluginkit` registration. Xcode's own app-registration task can
also run inside this deliberately requested publication build.
The post-registration check requires the production bundle ID and canonical
`.appex` path in the registry listing; it does not prove the hosted UI loaded.

### After replacing a local build

An already-selected preview may retain a lost connection after replacement.
An observed workaround: right-click CMUX's sidebar toggle, select the default
sidebar, then reselect **CMUX Maestro Preview**. This recreated the host view
and loaded the replacement extension without restarting CMUX or Copilot
sessions in the observed case; it is not a universal fix or proof of an OS cause.
`cmux sidebar reload` applies to interpreted Swift sidebars, not native `.appex`
extensions.

## Sandbox and distribution

The extension keeps App Sandbox enabled. Its only additional file grants are
read-only home-relative temporary exceptions, with required leading and trailing
slashes:

```text
/Library/Application Support/CMUXMaestroPreview/Copilot/
/.copilot/session-state/
```

No network client/server or arbitrary process/data access entitlement is added.
The installer app and identity command-line helper are unsandboxed: they must
run the explicitly selected CLI and write their own integration data. This is a
personal native distribution tradeoff, **not a claim of Mac App Store
compatibility**. Temporary file exceptions require distribution/review scrutiny.

A separately signed sandbox probe established that these exact read-only
prefixes permit synthetic nested identity/event reconstruction, while
unrelated reads and writes remain denied. That is **not** an
ExtensionKit-hosted runtime proof. Signed app/host loading and end-to-end
installation remain explicit manual verification gates.

## Identifiers and upstream contracts

| Component | Identifier |
| --- | --- |
| Containing app | `com.jdylanmc.CMUXMaestroPreview` |
| Sidebar extension | `com.jdylanmc.CMUXMaestroPreview.Extension` |
| Identity helper | `com.jdylanmc.CMUXMaestroPreview.CopilotHook` |
| Extension point | `com.cmuxterm.app.cmux.sidebar` |
| Copilot plugin | `cmux-maestro-native` |

Installation follows GitHub's [local plugin
instructions](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/plugins-creating):
`copilot plugin install <absolute-path>`; uninstall uses the manifest name.
Hook manifests follow the [command-hook
reference](https://docs.github.com/en/copilot/reference/hooks-reference), including
`version: 1`, `type: command`, `bash`, and `timeoutSec`.
