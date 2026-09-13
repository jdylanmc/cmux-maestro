# CMUX Maestro

A compiled macOS CMUX sidebar that displays Copilot sessions and their durable
agent hierarchy. The native sidebar reads locally; no companion daemon,
watcher, loopback server, XPC service, raw CMUX socket, or session-start ritual.
The separate interpreted Maestro project is untouched and is not a dependency.

## One-time setup

1. Use the [local preview install](#install-a-stable-local-preview) below, or
   open an already-installed build. Keep the app at its intended location
   before enabling integration.
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

## Sidebar layout

The sidebar **gear** includes **Compact** (the original spacing) and
**Comfortable** (more room and larger native detail text) density. Both
Hierarchy and Taskboard keep the same data, counts, paths and independent
focus, dismissal and acknowledgement actions. Narrow rows stack actions;
full paths remain available to accessibility and tooltips.

Hierarchy expansion persists by workspace/surface UUID and provider/session/
child identity—not names, paths or the current window. Moves and reloads keep
the setting; new identities start expanded. Reusing the same child ID in a
different session/provider does not inherit a collapse. Returning with the
same full identity intentionally does. Collapsed ancestors retain visible
running, blocked and attention summaries; incomplete counts stay labelled.
Collapse never dismisses or acknowledges work and never changes retention.
Taskboard still shows the full retained projection regardless of tree collapse.

Only density overrides and collapsed identities are stored, in a versioned
`CMUXMaestroPreview/sidebar-layout.json` record in the extension container's
Application Support directory. Coordinated, atomic action-level writes merge
across views/processes rather than replacing a stale window snapshot. Local
views synchronize immediately; native file-presentation notifications refresh
other processes, with reloads on host/observation updates, activation and
appearance as well.
Storage is bounded to **2,048 overrides / 1 MiB**. Oldest collapse overrides
are evicted first, which only **expands** branches. Off-window state is never
pruned based on a current snapshot. Unreadable or unknown-schema settings
expand all branches and show a recoverable notice; only **Reset layout
settings** replaces that record. **Expand all branches** preserves density;
layout reset restores Compact and does not alter history or attention settings.

Layout's file/store types are thin adapters over the same preference coordinator
used by history and acknowledgements; only layout's mutations and safe eviction
policy remain feature-specific. The existing layout path and version-1 schema
are unchanged: no layout migration or rewrite occurs on open. Missing layout
files mean Compact and fully expanded, and reads/refreshes do not create a file.
This lazy mode is explicit; history/acknowledgement migration-on-open is unchanged.
Lazy stores observe the nearest existing container so first-file creation in
another process also reaches already-open views, without writing defaults first.
All three records stay separate. Tests and offscreen renders inject all three
storage paths and never fall back to the production layout singleton.

### Synthetic layout review images

`./scripts/test.sh` writes offscreen SwiftUI/AppKit PNGs to
`.build/layout-validation/offscreen/`. CI uploads only those PNGs as the
**sidebar-layout-offscreen** artifact (14-day retention), including when tests
fail after producing images. Review both densities at 240 pixels in dark mode,
increased contrast, and long synthetic path/model/nested-label scenarios, in
addition to the light-mode expansion matrix at 240 and 320 pixels. Filenames
identify density, scenario, view mode and width.
The renderer checks the actual SwiftUI color-scheme and contrast environment.
Its fixed synthetic clock also owns the injected freshness timer; elapsed CI
wall time cannot expire a fixture whose logical clock has not advanced.
Contrast uses the SDK's writable `_colorSchemeContrast` backing key only in
tests, paired with native high-contrast AppKit appearances; no system display
preferences are changed.

All metadata is synthetic and local preferences are isolated for the render
test. Its AppKit windows are never shown; this is not a desktop capture, live
CMUX-host visual proof, system VoiceOver verification or a pixel-baseline
comparison. No transcripts, real workspace paths or desktop images are uploaded.

## Completed work history

The sidebar's **gear** also opens native history settings, shared by **Hierarchy** and
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
Reducer replay protection is bounded to 65,536 lifecycle event IDs and at most
65,536 start-identity tombstones per session. Exhaustion reports partial data;
uncertain new starts demote affected work to unknown and clear obsolete terminal
evidence, so a prior dismissal cannot hide possibly active work. Unresolved
lifecycle scope is demoted conservatively. Session identity/schema checks run
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

The reusable neutral `AgentActivity` contract lives in `Domain/AgentSignals.swift`
alongside evidence-bearing attention primitives, compiled into app, sidebar and
tests, not the hook. Existing snapshot behavior is unchanged. New live model
fields are optional for backward Codable compatibility. Reader identity,
partial-read, corruption, freshness and replay-cap safeguards still apply;
untrusted or unavailable evidence cannot fabricate an outcome or an action.
Telemetry and the remaining backlog are not claimed by this feature.

## Requirements

- macOS 14 or newer.
- Xcode 26.6 at `/Applications/Xcode.app` for local builds.
- CMUX with sidebar ExtensionKit support.
- A Copilot CLI version supporting local plugin installation and the three
  documented command hooks, with canonical session identity in hook input.

The CMUX ExtensionKit package is pinned to CMUX commit
`ae7fbce99f98c98df5ccf915e548dd080d33cfa8`. It is fetched into ignored
`vendor/CmuxExtensionKit/`; no CMUX source changes are required.

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

Focused, isolated setup, hook, and sandbox checks (no SDK fetch or app launch):

```sh
./scripts/test-copilot-hook.sh
./scripts/test-copilot-setup.sh
./scripts/test-copilot-sandbox.sh
python3 ./scripts/test-build-metadata.py
python3 ./scripts/test-local-preview.py
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

## Install a stable local preview

This is a **local, user-owned preview**, not a public release, auto-updater,
notarized distribution, license decision, or legacy-plugin cutover. The stable
default is **`~/Applications/CMUX Maestro Preview.app`**. Its app, extension and
bundled helper no longer depend on a disposable Git worktree after installation.
The Python 3 command uses the standard library and macOS `ditto`, `codesign`,
LaunchServices and `pluginkit`; it does not install a service or dependency.

From a trusted checkout, explicitly build the current ad-hoc-signed product,
then install it:

```sh
./scripts/build-register.sh
python3 scripts/local-preview.py install \
  --source "$PWD/.build/adhoc/Build/Products/Debug/CMUX Maestro Preview.app" \
  --retire-development-registration
```

These are **two deliberate publication operations**, not validation commands.
`build-register.sh` can register its source app during Xcode's build, and
explicitly registers the source extension. There is no supported
`REGISTER_APP_WITH_LAUNCH_SERVICES=NO` setting. The install command stages and
verifies the signed copy, atomically installs it, then retires **only this
checkout's known `.build/adhoc` registration** before registering the stable
app and extension. The flag is optional for separately supplied signed
artifacts; no other development copies are discovered or deregistered.
Source files are **never removed**.

The helper target explicitly supplies its resolved production/validation
identifier to `codesign`; otherwise a command-line tool can retain its
linker-generated identifier despite `PRODUCT_BUNDLE_IDENTIFIER`. Publication
and installation verify the effective helper identity. Rebuild older products
with linker-generated helper IDs; they are not accepted as install sources.

The command confirms the exact production bundle ID and canonical path in
both LaunchServices and the extension registry—not merely exit status zero.
The extension parser accepts pluginkit's documented election markers, including
`=` (superseded) and `?` (unknown); retained sibling registrations do not prevent
an exact match, and are never removed merely for appearing in the listing.
This does not claim CMUX has selected or loaded the new extension.

Open the **stable** app in Finder, use **Enable Copilot Integration**, and
explicitly confirm **Install Native Plugin**. This consent flow must be
repeated after a move, update or rollback: the native plugin embeds the
helper's **absolute app path**, and Copilot caches plugin contents. The install
script never edits `~/.copilot`, invokes its plugin CLI, or rewrites active
sessions. Restart/resume existing CLI sessions **once, at a time you choose**,
to load the refreshed plugin. Keep the old development app/worktree until
sessions with its cached hooks have retired. Future normal CLI launches need
no manual observer or session-start procedure.

### Update, rollback and status

Close the containing installer app normally before replacing it. In CMUX,
select the **Default** sidebar and allow preview/helper processes to finish;
do not quit CMUX or terminate existing CLI sessions. The command refuses a
replacement while a same-user process is executing from an affected preview
app or backup. It reports the specific process ID when possible; it never signals a
process. Keep these apps closed until the operation finishes.

```sh
# After another explicit ./scripts/build-register.sh:
python3 scripts/local-preview.py update \
  --source "$PWD/.build/adhoc/Build/Products/Debug/CMUX Maestro Preview.app" \
  --retire-development-registration
python3 scripts/local-preview.py status

# Explicitly exchange the current app with its verified previous version:
python3 scripts/local-preview.py rollback
```

Then refresh integration in the stable containing app and select the Preview
sidebar. If the host view loses its connection, select **Default → CMUX Maestro
Preview** again. `cmux sidebar reload` is for interpreted sidebars, not native
extensions. No operation here restarts CMUX or running CLI sessions.

Updates may replace a changed development build with the same build number,
but never silently downgrade. An identical artifact is refused as already
installed. Rollback revalidates the previous app's **own** matching app/extension
version, strict ad-hoc signatures, production identities and compatible
entitlements. A previous preview with fewer approved read-only grants is
allowed; missing sandbox, broader or unknown grants, unsigned components and
test namespaces are refused. Normal publication/install validation still
requires the current build number; this feature does not bump it.

### Transaction and recovery contract

- One kernel-held, nonblocking install lock and a private `0700` ownership
  directory live at `~/Applications/.cmux-maestro-preview-install/`. Receipts
  are `0600`, atomically written and synchronized. The persistent lock file is
  **not a stale lock** just because the caller has exited. A one-command
  Python supervisor retains the lock while a mutating `ditto`, `lsregister`
  or `pluginkit` invocation runs, including after caller timeout or `SIGKILL`.
  Tools do not inherit the lock descriptor: closing their descriptors cannot
  release the supervisor's copy. The supervisor waits for the tool's private
  foreground process group, not just its direct child's exit or pipe EOF.
  There is no installed daemon or persistent background observer.
- A bounded marker in that same lock file records command progress. A gated
  launcher cannot execute the tool until its private process group is durably
  recorded. If the supervisor itself dies, a new lock owner still refuses
  recovery while that recorded group exists—even if the direct child already
  exited. Once the group is gone, normal recovery may resume; a launcher whose
  group was never recorded cannot pass its gate. Corrupt/unverifiable markers
  fail closed. Never delete or truncate the lock to bypass this barrier.
- The 120-second command timeout ends the caller's wait, **not** a surviving
  mutator's lifetime. Wait for the protected workers to finish, then retry
  `recover`. A hung worker continues to block new operations rather than risk
  a delayed deregistration affecting a later installation. This supervision
  is for the fixed foreground macOS tools, not a general-purpose launcher for
  programs that daemonize into independent sessions. It does not control
  unrelated operating-system services or other apps' registry requests.
- Source and staged copy must match an integrity receipt and pass effective
  signed-profile verification. Files and directory metadata are synchronized
  before commit. Darwin `renamex_np(RENAME_SWAP)` exchanges an update/rollback
  with the live destination in one operation: there is no deliberate
  missing-app interval. First install uses exclusive rename. Unsupported
  filesystems fail closed; there is no non-atomic replacement fallback.
- A completed update retains **one verified previous app** in an owned slot.
  During a transaction/cleanup, at most the current, previous and one extra
  candidate/retiring version are retained. Rollback exchanges current and
  previous, so the rollback itself can be undone. Backups are not integration
  setup targets and their owned registrations are retired.
- The receipt journals staging, replacement and removal. A copy, signature,
  disk, registration or cleanup failure is **not success**, and a failure
  after atomic replacement is **not an automatic rollback**. The new app may
  already be at the destination; the old app remains in the journaled slot.
  A later cleanup failure can leave the older retiring slot too. Further
  update/rollback operations refuse until recovery finishes.

```sh
python3 scripts/local-preview.py status
python3 scripts/local-preview.py recover

# If a committed update cannot be registered, explicitly restore its old app:
python3 scripts/local-preview.py recover --restore-previous
```

Recovery cancels pre-commit staging, or infers a committed exchange from the
verified app identities and finishes registration/backup bookkeeping. It can
resume its own interrupted cleanup or rollback. If no transaction is pending,
it verifies owned apps and refreshes the stable registration. First install has
no older app to restore: recover it, then explicitly uninstall if desired.
Ambiguous identities, replaced partial-cleanup directories, foreign backups,
or corrupt receipts are refused rather than guessed or deleted. Preserve the
receipt, apps and original checkout/source while a transaction is pending.
Do not manually shuffle slots or remove metadata to force an update.

Only an existing, normal, non-root user's real home is used; `HOME` overrides
are not install roots. Symlink components, foreign ownership, group/world
writable paths, escaping bundle symlinks and hard-linked files are refused.
Internal relative framework symlinks are allowed. An alternate destination can
be specified **before** the command, but must be a direct `.app` child of the
same `~/Applications`, for example:

```sh
python3 scripts/local-preview.py \
  --destination "$HOME/Applications/My Maestro Preview.app" install \
  --source "$PWD/.build/adhoc/Build/Products/Debug/CMUX Maestro Preview.app"
```

The singleton receipt binds that destination; use the same option thereafter.
There is no automatic adoption, relocation or force-overwrite mode, even for
another apparently matching Maestro app. Ad-hoc signatures establish local
integrity and component identity, **not publisher authenticity**: choose a
trusted source. This is not protection against another process already
controlling your user account or machine.

### Remove only the owned local preview

First, in the stable containing app, explicitly choose **Uninstall Native
Plugin…** and confirm the official CLI action. Restart/resume sessions that
still cache its hooks when convenient, then close the containing app and
deselect the preview sidebar. Only after those hooks no longer need its
helper, explicitly remove the installed preview:

```sh
python3 scripts/local-preview.py uninstall --cached-hooks-retired
```

This deregisters and removes only the receipt-owned stable app and backups.
The option is an operator assertion, not a scan of private CLI state. An
interrupted removal is resumed by `recover`. Ownership metadata and the lock
remain for safe future installs. Observation records, history/attention
preferences, containers, native plugin settings and source builds are retained;
there is no purge option. Neither removal nor update touches `maestro-cmux`,
legacy settings, hooks, sidebars, other apps or CMUX configuration.

The synthetic install tests exercise real macOS atomic renames in
repository-local fixture directories, with injected signing, process and
registration adapters. They never access real Applications, Copilot settings
or user runtime data. Controlled fixture processes deliberately close their
descriptors, leave a delayed mutating descendant, and lose their caller or
supervisor to `SIGKILL`; tests prove recovery/new installation stay blocked
until those synthetic workers finish. No real app/session/tool is killed.
CI retains all existing build/test commands and adds
these transaction regressions. Live signed installation, consent refresh,
host selection and visual verification remain separate operator gates.

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
