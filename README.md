# CMUX Maestro

A compiled macOS CMUX sidebar that displays Copilot sessions and explicit
terminal-backed orchestration hierarchies. The native sidebar reads locally; no companion daemon,
watcher, loopback server, XPC service, raw CMUX socket, or session-start ritual.
The separate interpreted Maestro project is untouched and is not a dependency.

See the [behavioral parity matrix](docs/behavioral-parity.md) for regression
evidence, live acceptance scope, intentional differences and remaining limits.

## One-time setup

1. Use the [local preview install](#install-a-stable-local-preview) below, or
   open an already-installed build. Keep the app at its intended location
   before enabling integration.
2. Open **CMUX Maestro Preview**. Click **Enable Copilot Integration**, then
   explicitly confirm **Install Native Plugin**. If the app's configured `PATH`
   cannot find Copilot, use **Choose Copilot…** to select the trusted executable
   you normally run. No shell startup files or machine-specific cache paths are
   assumed.
   For explicitly authorized button-free setup, the actual production app also
   accepts:

   ```sh
   "$HOME/Applications/CMUX Maestro Preview.app/Contents/MacOS/CMUX Maestro Preview" \
     --install-copilot-integration --copilot-executable "$(command -v copilot)"
   ```

   This uses the same installer and production-identity checks. It does not
   open setup windows, change accounts, or restart existing conversations.
   Normal app startup still performs no installation.
   Production preview builds disable coverage instrumentation so setup does not
   leave `default.profraw` in the caller's worktree; test coverage remains enabled.
3. In CMUX's **Sidebar Extensions** browser, enable **CMUX Maestro Preview** and
   select it as the active sidebar.
4. Restart or resume already-running Copilot CLI sessions **once** to load the
   newly installed plugin. Maestro never restarts them automatically. Launch
   future sessions normally inside CMUX; their hooks record validated identity
   and the sidebar renders the tree directly from durable events. Setup also
   installs the bundled `/cmux-maestro-native:cmux-maestro-orchestrate`
   and `/cmux-maestro-native:maestro-icon`
   skills and local controller. This identity-hook restart guidance does **not**
   adopt existing sessions into messaging. Only newly Maestro-spawned managed
   sessions get native messaging bindings automatically.
5. For the optional messaging guide, open Maestro **Settings > CLI Integration**.
   Copy the global install command and run it yourself as described below.
   Runtime setup never installs the global guide.

The containing app is an installer, not an observer. It may be closed after
setup. A successful setup message means the selected CLI exited successfully;
it does not claim a running session has already loaded the plugin or that the
host extension has been enabled.

Installer invocations start in their own process group. **Cancel Setup** and
the 45-second timeout stop that invocation's launcher and descendants, then
wait for cleanup before permitting retry; existing Copilot sessions are never
signalled. CLI output remains suppressed.
Setup passes `--no-auto-update` so a plugin change does not opt into upgrading
the selected CLI.

Only the distinct **`cmux-maestro-native`** plugin, its bundled skills, private
local controller, and native loader at `~/.copilot/extensions/maestro/extension.mjs`
are installed. The loader is inert without matching launcher/session/workspace/
generation bindings. Existing
`maestro-cmux`, other plugins, provider settings, and sidebar selection are
never replaced automatically. Moving/replacing the native app requires enabling
the integration again: Copilot caches local plugin contents, and generated hooks
contain the **absolute current bundled helper path**.

Messaging launch configuration and stored nodes retain the three-field
`{version, routes, extension}` contract. The obsolete `pluginDirectory` setup
field is ignored for compatibility, never validated or passed to Copilot.
Managed launches retain `--experimental`, pins, denies, coordinator-only explicit
YOLO and terminal I/O; they do not require a guide or pass `--plugin-dir`.

### CLI Integration: install the global guide

Maestro's native **Settings > CLI Integration** tab explains the GitHub Copilot
guide, provides selectable command text and **Copy install command**, and offers
a read-only **Re-check**. Results start as **Not checked**. Re-check compares
`SKILL.md` and `intent.md` independently at two recognized locations:
`~/.copilot/skills/maestro` (the current Copilot copy destination) and
`~/.agents/skills/maestro` (the evidenced legacy location).

Each location reports **Not installed here**, **Cannot read content**,
**Different from this build**, or **Matches this build**. Matching requires both
files' exact bytes to match SHA-256 digests generated from this build's canonical
guide sources; the app bundles only digest metadata, not the guide bodies.
Changes to either canonical file regenerate that metadata during the Xcode build.
A partial install is different/incomplete, not missing. Unreadable, unsafe,
changing or oversized files, and unavailable/invalid build metadata, never
produce a match. Reads are limited to 256 KiB per guide file; symlinks are not
followed. Empty files differ from the canonical nonempty guide.

The two locations never collapse into one green result. Results carry a check
time and remain snapshots until **Re-check**; they do not establish upstream
freshness, whether different content is newer, or what a running Copilot session
loaded. No recursive discovery, watcher or automatic re-check is used.
Re-check is also available with **Command-R**. Each status has an explicit
accessibility label containing its location and result; color is supplemental.
Synthetic offscreen tests cover all four results in light/dark mode at narrow and
standard widths. They do not prove live VoiceOver navigation or installed-host
behavior.
Fixture tests exercise missing/partial installs, exact byte mismatches,
unreadable files/directories, unsafe symlinks and file types, size limits,
invalid baselines, and repeated checks that clear stale success. Updating the
synthetic current copy leaves a different legacy copy different. App-bundle
tests verify canonical digests and exclusion of guide bodies; build-metadata
tests verify regeneration when either canonical input changes.

To install or update the current Copilot copy, run this command in your own terminal:

```sh
npx skills add jdylanmc/cmux-maestro --skill maestro --agent github-copilot --global --copy
```

Review the installer's interactive confirmation; the command deliberately omits
`--yes`. The update affordance only copies text: it does not execute `npx`, open a terminal,
install a skill, or change global configuration. This is the **single canonical
guide distribution**, from `skills/maestro/{SKILL.md,intent.md}`. Invoke global
**`/maestro`**, or use the skill tool with `{"skill":"maestro"}`. No extra
skill-activation grants are required. The guide never secretly installs runtime;
native messaging works without it. Runtime remains the separate **Enable Copilot
Integration** action, including the existing lifecycle and icon plugin skills.
The command targets the current Copilot copy location; the installer's output
remains authoritative for the actual destination. It does not update, migrate or
delete the separately reported legacy copy. Re-check both locations after running
it; one matching copy never implies both were updated.

**Development / PR acceptance before merge:** the repository command above cannot
install the unpublished skill from `main`. From this checkout's root, the human
may instead run the same installer against the local source:

```sh
npx skills add . --skill maestro --agent github-copilot --global --copy
```

No branch refs, automatic refresh, or release machinery are embedded in Settings.
The user already proved this global local-source path with `skills` **1.5.26** at
`2026-09-22T12:03:56.533Z`: it installed to `~/.agents/skills/maestro`, and Copilot
global discovery succeeded. That is an observed location, not an assumption that
all global skills live under `.copilot`. Bare plugin loading and explicit
`--plugin-dir` both failed live; no upstream root cause is claimed. See the
[public findings](docs/delivery-proof.md#guide-distribution-decision-after-live-proof).
Any refresh of the user's existing global copy remains a separate consentful action.

On the next explicit **Enable Copilot Integration**, setup removes only its old
`Copilot/plugin/skills/maestro/SKILL.md` copy, if present, using owner-checked,
non-symlink traversal. It preserves other skills and files, including lifecycle,
icon and global guides; it never sweeps global paths or cached/live sessions.

### Disable or uninstall

Use **Uninstall Native Plugin…**, then explicitly confirm. This runs only
`copilot --no-auto-update plugin uninstall cmux-maestro-native`, then removes
Maestro's native loader entry point and launch configuration. Live route bindings,
sockets and in-memory adapters are not touched; close those sessions normally.
Restart/resume existing CLI
sessions to unload their cached hooks. Disable this sidebar in CMUX separately
if desired; uninstall does not select or remove any other provider.
It also leaves the separately installed global guide untouched.

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
- Terminal control runs in the installed standard-library Python controller at
  `~/Library/Application Support/CMUXMaestroPreview/Orchestration/bin/`.
  Private prompts, results, control tokens and process identities remain under
  `control/`; the sidebar sandbox grant reaches only the bounded sanitized
  `observer/` directory and cannot read sibling control, binary, task or result data.
  The controller uses exact CMUX workspace, pane and surface UUIDs. It never
  infers ownership from labels, paths, focus, chronology, or terminal text.
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

When a coordinator explicitly registers a terminal-backed run, its coordinator
→ worker → nested-worker relationships become the primary compact hierarchy.
Every worker is a genuine unfocused terminal tab in the coordinator's current
CMUX pane/workspace. Rows show safe labels and explicit lifecycle state; Details
contains exact run, parent, worker, workspace, surface and generation IDs.
Selecting a row uses the existing typed CMUX Focus action. Each workspace appears
once: explicit managed agents and remaining terminals share its outline. Only an
exact managed workspace/surface pair replaces an unmanaged terminal row; names,
paths and guessed relationships never establish ownership. The Taskboard view
keeps the complete inferred activity projection available independently.

The installed skill exposes `launch-coordinator`, `launch-settings`, `status`,
`focus`, and `archive`; `register` and exact stale-surface `recover` remain for
legacy lifecycle ownership. Registration is not messaging adoption.
Start a new managed coordinator with an explicitly selected initial account and
model. Its public `maestro_identity` tool reports the actual session/account
without credentials. Native `maestro_spawn` reads that session's current account
for each child, retaining explicit model selection and permission bounds.
Saved account defaults and unrelated Git authentication never select a child's
subscription. Missing identity/API/credentials fail before terminal creation.
The current credential resolver uses GitHub CLI's keychain-backed account
store. Authenticate the required account there once; a Copilot-only login is
not silently imported or replaced with another GitHub CLI account.
Ordinary shell `spawn` cannot establish that evidence and refuses; source-only
disposable proof compatibility is not a production fallback. **New workers are
interactive Copilot sessions**, launched with `--interactive` and the initial
task. Their terminal is a normal conversation: humans can type follow-ups and
answer permission/questions directly, and completing a task does not close it.
A foreground supervisor inherits terminal I/O rather than capturing a JSON
stream. Ctrl-C goes to Copilot without terminating the supervisor; normal
session exit is recorded without claiming task success. New workers cannot be
launched in headless mode. Invisible SDK tasks must not be substituted for
visible Maestro roles when startup fails.

Interactive startup uses `surface.create` with `initial_command`, rather than
CLI `new-surface --command`, which queues input behind interactive shell
initialization. Only the caller's executable search path is added to the startup
environment; credentials are not passed through the host creation request.
Because the host may rewrite that environment, the launch record also captures
the validated absolute Copilot executable and caller search path privately.
The supervisor uses those values for provider startup and invokes its own
Python interpreter explicitly; it does not depend on interactive shell setup.
The eight-second supervisor lease remains unchanged. A bounded one-time credential stays in the private control
directory and is consumed only after exact workspace/surface attachment.
The terminal command contains no token. Both supervisor and provider process
anchors retain the existing resource bounds.

Supervisor acknowledgement is not provider readiness or completed work.
`providerStarted` means a provider identity was recorded; lifecycle
`messaging: configured` does not prove adapter attachment or delivery.
Verify exact surfaces, native tools, and returned evidence separately.
Root callers must retain the private custody receipt even when startup returns
`ok: false`; its control token remains private. The controller preserves bounded
startup errors in owned lifecycle diagnostics rather than replacing them with a
generic exit message or publishing them to the sidebar.
Managed coordinators have their own controlled sessions and runs; existing
conversations are not converted. A live or uncertain legacy supervisor blocks
the new coordinator schema; the launcher fails rather than interrupting it.
Existing provider sessions do not need to be ended when their old supervisors
have already exited. Resource reconciliation retires only unchanged records
with absent surfaces and proven process exit, never an active launch lease.

The lifecycle `follow-up` command remains refused for interactive workers.
Participating peers instead use native fire-and-forget messaging below; no prompt
is injected into terminal input. Close interactive Copilot normally
before archiving; archive does not interrupt it. Existing legacy workers are
preserved and visibly labeled **Legacy worker** rather than silently converted.

### Native peer messaging

After explicit integration setup, select the initial coordinator account and
model in **Agent launch settings**, then use `launch-coordinator`.
`launch-settings` reports `messagingInstalled` separately from saved-account/
model `ready`; neither field proves a recipient has loaded its native adapter
or identifies the invoking session's account.
New installed-controller spawns automatically bind their exact Copilot session,
generation and CMUX workspace before launch and enable CLI native extensions
with `--experimental`. No per-project fixture preparation is needed. Ordinary
unmanaged sessions, existing workers, and registered coordinators without a
launcher-owned Copilot session remain **unsupported recipients**. Never adopt or
restart them automatically.

Use global `/maestro` for `maestro_peers` discovery, `maestro_send`, and replies
to the supplied sender address. Any participating same-workspace peer can send,
including siblings and peers from another run; messaging grants no lifecycle or
process-control rights. The native adapter joins only its CLI-owned session and
uses `session.send({ prompt, mode: "enqueue" })`. Copilot owns scheduling.
No sidebar, selected workspace, foreground application, terminal keystroke,
composer inspection, acknowledgement, receipt, retry or completion tracker is
involved. A local-write attempt is **not** a delivery or completion guarantee.
The source package and unchanged confirmed purpose live in `skills/maestro/`.
It has no tool-permission grants in frontmatter and reuses the installed
`/cmux-maestro-native:cmux-maestro-orchestrate` skill for lifecycle operations.
For the skill tool, pass `{"skill":"maestro"}`. Only the existing lifecycle/icon
plugin slash commands remain namespaced; the global messaging guide is not.

Defaults grant nothing. A coordinator may request native `yolo: true` **only with explicit
user approval**; Copilot receives `--allow-all` alongside all explicit denies.
Workers cannot request YOLO, even if the coordinator was allowed it; requests are
rejected before credential lookup/reservation. Descendants keep bounded explicit
allows and inherited denies. There is no speculative full permission inheritance,
permission callback or persistent provider setting change.

Each native child has one private Unix socket and a launcher-created binding
under `~/.copilot/extensions/maestro/r/`; account credentials never enter these
files or messaging tools. Addresses contain workspace/session UUIDs and generation,
not secrets. Payloads are limited to 4 KiB UTF-8, frames to 8 KiB, registered
participants to 128, and connections/pending native sends to eight per receiver.
The eight-live-managed-session workspace limit includes managed coordinators
and retained resources. Routes use exclusive
creation, are retired after exact provider exit (or closed-run archive), and cannot
be rebound by clearing/resuming a conversation. Restart/clear/replaced-session,
offline, unsupported, invalid or stale routes fail closed; request fresh managed
sessions only with user authorization. Same-user processes are trusted: private
capabilities are not a defense against a malicious process running as your user.

See [native delivery findings](docs/delivery-proof.md) for the observed agent
exchange, human-confirmed draft preservation, separate harness-origin background
check, and outstanding installed-product live acceptance. Mocked contract tests
are not native UI proof.

### Local agent launch settings

The containing app's **Settings > Agent launches** tab provides **Launch agents with
subscription:** and an optional worker-model setting. The dropdown lists
configured GitHub.com accounts from GitHub CLI without displaying credentials;
it does not infer subscription plan names. **Use Copilot default** leaves
authentication and model selection to Copilot.

Preferences live only in the user's private Application Support
`CMUXMaestroPreview/Orchestration/worker-settings.json`, not in this repository.
The project ships no account or model pin. A configured account is resolved from
its stored credential at launch and passed only through `COPILOT_GITHUB_TOKEN`.
Unavailable credentials fail closed before a new terminal is created; there is
no silent fallback to a different account. Tokens are not written to settings,
state, launch tickets, arguments, observer files, or logs. Git identity and the
active `gh` account are not switched. Changes affect only future workers. Direct
controller callers may retain Copilot defaults by omitting the requirement flag;
the bundled orchestration skill deliberately does not and always requires the
pinned Maestro account and model.

### Legacy bounded-worker compatibility

Existing bounded workers retain `follow-up` and `report`. Follow-up is privately queued only after a directly owned
worker has a successful exact-session boundary for its current generation, then
uses that worker's preassigned exact `--resume` session ID. Explicitly reported
outcomes are preferred; a report-missing or permission-denied generation may be
re-prompted without claiming that its earlier task succeeded.
The supervisor multiplexes bounded JSON output and promptly forwards provider
diagnostics while continuing current-generation heartbeats during silent turns;
it never answers permission prompts. Noninteractive Copilot can deny a tool in
JSON without offering an interactive prompt, so stderr inheritance is not a
permission mechanism. Terminal existence and a zero CLI exit are
not success: completed, blocked and failed states require both a successful
exact-session process boundary and one strict generation-matched whole-final-
message report. The report is versioned, identity-bound and permission-free;
ordinary prose, fenced or extra JSON, tool-bearing final messages, and dual
helper/final reports are refused. It remains a worker self-reported outcome,
not independent artifact validation or reviewer acceptance. Missing reports,
permission denials, nonzero
or malformed turns, startup failure, process
disappearance and terminal disappearance remain distinct. An explicit launch
lease prevents archive from crossing CMUX surface creation/attachment, and any
exact surface created before a later launch failure remains accounted. Eight
still-live managed worker resources are allowed per workspace;
reported completion does not free a slot. Archive retains bounded history and
never kills processes or deletes tabs, so still-present archived worker tabs
continue to consume the resource bound. Tool permissions are not auto-approved.
Interactive archive checks exact process exit under the lock both before
admission and before deletion; failed process probes remain uncertain, not
proof of exit. Interactive-only runs need no cooperative stop marker, so a
refused archive leaves their records, messaging routes and archive flags intact.
Cancelling an unclaimed launch lease records explicit pre-runtime failure
evidence. Stale recovery can retire that never-started worker after its exact
surface is closed (or when creation produced no surface), even without process
anchors. Missing anchors alone, idle time and startup timeouts are not exit
proof; the no-start evidence requires the lease cancellation before runtime
claimed ownership. Legacy supervisors retain their cooperative archive stop.
Read-only controller snapshots use shared locks; state mutations remain
exclusive. Idle supervisors therefore do not serialize their status reads
behind the mutation lock as a workspace approaches its worker limit.
Spawn accepts bounded caller-explicit `--allow-tool` and `--deny-tool` rules;
the default adds no grants, denies win, and descendants cannot exceed their
parent's explicit allows or remove inherited denies. These Copilot flags are
policy controls, not an operating-system sandbox. Shell access is never a
default and requires an explicit task-level caller decision; wildcard,
all-resource and `--allow-all` grants are never injected.

The default view is a restrained workspace outline. Quiet workspace headers
contain explicit coordinator → worker → nested-worker rows, with guide lines and
durable disclosure by stable node identity. Each row leads with its safe name,
then a muted Git branch/worktree line when the external controller verified those
facts from the explicitly assigned working directory. The worktree label is the
verified repository root basename; the branch label comes from `git symbolic-ref`.
Detached `HEAD` omits the branch while retaining the verified worktree. Non-Git
directories, missing directories, timeouts, invalid output, overlong output and
failed root queries publish no Git labels rather than calling a directory a
worktree. The controller refreshes exact assigned-directory evidence at bounded
worker heartbeats, turn boundaries, follow-up queueing and explicit status checks.
Each projection carries a separate Git evidence status and capture time. Stale
verified locations remain useful as **last verified** labels, with a clock glyph,
explicit help and accessibility qualification; they are not presented as current
Git state. Unavailable evidence is omitted. Probes are batched by assigned directory and run outside the global
state mutation lock. The sandboxed sidebar never runs Git and never receives the
private full assigned path through observer metadata.

Managed rows show the worktree name with a branch-tree icon. Fresh Git evidence
also carries a changed-file count and **+green / -red** tracked-text line counts
against `HEAD` (staged and unstaged changes combined). File totals include
untracked files and binary changes; line totals exclude them and submodule
contents. Renames count once. Conflicts, unborn `HEAD`, failed or oversized
probes, and stale evidence never become zero counts. Counts are sampled, not an
atomic snapshot of concurrent edits. Missing current counts remain unavailable.
Count freshness uses its own timestamp, independent of branch metadata refreshed
by older supervisors.
Only bounded aggregates cross into the sandbox; paths and file contents do not.
Existing controller versions omit these optional fields. Refresh the native
integration explicitly to install the new controller; existing supervisors and
sessions are not restarted or taken over to populate counts.

Nonblocking notices use a Design 06-inspired green, with a darker light-mode
variant; blocked and failed states are red. Words and symbols distinguish attention from active work or
successful outcomes. Generic Copilot session names and short IDs no longer lead
outline rows: shared-surface titles and state lead instead, while exact session
identity remains in details.

Agent icons are drawn from the bundled **Nerd Fonts Symbols 3.5.1** font and its
pinned glyph-name catalog. No system font installation or uploaded images are
required. The catalog offers **10,994 drawable names**; the intentionally empty
`cod-blank` entry is excluded. Role favorites are presets, not the selection limit.
Ordinary terminal tabs use `md-ghost`; browsers use `fa-edge` (U+F282).
**Sidebar settings → Agent icon** chooses the fallback robot or Copilot glyph for
sessions without an explicit selection.

Working agent rows have a pale pastel-green shimmer moving left to right; blocked rows have a
steady subtle red background. Idle/unknown rows do not pulse or glow. Reduce
Motion replaces the working shimmer with a steady subtle tint. The glow stays on
each agent's own row, not its descendants, and never intercepts input.
The selected workspace's uniquely focused surface has a glowing left border,
separate from activity and icon color. Other workspaces' remembered focus does
not light a border, and ambiguous/unavailable focus evidence does not guess.
Identity colors do not change this treatment. Icons have no wand decoration;
choosing an icon or role preset does not imply orchestration ownership.
State remains explicit in row text and accessibility labels. Coordinator
activity comes only from a fresh, unique, live Copilot observation on its exact
workspace/surface; registration or child activity alone cannot start a pulse.
**Sidebar settings → Terminal icon** offers Ghost and plain `>_` styles.
Workspace summaries are action-only: questions/approval requests show **needs
input**, and other explicit blockers show **blocked**. Quiet workspaces show no
summary line. The top alert count uses the same rules; routine turn completions
do not inflate it. Managed and observed representations on the same exact
workspace/surface count once, and collapsed descendants still contribute.
Last-reported managed blockers stay visible with freshness qualified in help.
Agent totals, idle counts and repeated completeness warnings are not primary UI;
source diagnostics remain in details. Glyphs have 2 pt insets in their existing
24 pt slots.
Standalone state keys retain pause/check/error symbols for blocked, finished and
failed states. Workspace headers are text with chevrons;
their trailing ellipsis menu offers Focus, Expand/Collapse and Details as separate
actions. The header menu exposes the two view modes directly, plus settings.
Settings and selected details have explicit Close controls; details are bounded
and scroll independently rather than consuming the outline.
Rows use concise state labels rather than diagnostic walls; blocked/failed state, incomplete ancestry,
omitted active work and attention remain concise and visible. Selecting the state
glyph opens one detail surface below the outline. Managed workers resolve verified
model metadata only when both their controller-issued Copilot session UUID and
surface match one fresh, live observation. Coordinators use one fresh, live,
unambiguous observation on their exact surface. Same names, directories, stale
or ended observations, unconfirmed owners, surface mismatches and ambiguous
coordinator sessions never participate. Context
usage/window size is omitted because the current producer has no documented numeric source;
cumulative API tokens and context tiers are not presented as context occupancy.
Full authorized paths and stable IDs remain in deliberate inspection. Successful
tab focus and opening details mark that scope's nonblocking notices as read.
Expansion never marks anything read; no interaction approves or answers a request.

For unmanaged terminals with exactly one observed session, its state and children
are presented on the named terminal row instead of adding a duplicate provider/ID
heading. Multiple sessions remain individually inspectable; none is guessed to be
the current owner. Passive skill/shell history moves to the selected session's
**Other activity** disclosure and remains in Taskboard. Agents, structural
ancestors, active/blocked/failed work and outstanding attention stay in the outline.
Ordinary running shell invocations are the exception: verified, unambiguous leaf
commands fold into a quiet activity caption beneath their exact owning session or
agent, such as "Running a command". Concurrent commands are counted; blocked,
failed, attention-bearing, unresolved and structural shell rows stay visible.
The complete shell records remain available in details and Taskboard. This is
presentation-only: raw activity evidence, lifecycle state and counts are unchanged.
Incomplete-history indicators and collapsed-branch counts sit beside their owning
row, not on standalone diagnostic rows. A chevron needs no "Branch collapsed"
caption. Registration is neutral, not a claim that an agent is running; stale
managed evidence and unconfirmed/ended process ownership cannot show a live state.

With or without a managed graph, the same outline groups real CMUX
surfaces and valid inferred Copilot sessions beneath workspace headers. Working
directory basenames are explicitly described as directory labels, never Git
branches. Uncertain ownership and incomplete evidence remain honest glyphs or
summaries, and incidental diagnostics stay behind selection or settings.
Taskboard remains available from the compact view/settings menu and retains each
primary session's state even when it has no attention or child rows.

A healthy outline has no diagnostic paragraphs. Source availability is a header
indicator with full help and accessibility text; incomplete evidence is marked on
its owning row. Blockers, attention and omitted active work remain visible.
Workspaces use quiet headings; directory labels sit beneath terminal names.
Complete path metadata remains in Details rather than repeating unavailable
workspace/project/path lines on every row.
The header menu remains the entry for density and stored preferences. Saved
expansion, retention, acknowledgement, navigation and source records are preserved;
the outline's activity filtering is presentation-only.
When several source warnings apply, the overview keeps the primary warning
and omitted active-work count visible; its Details disclosure lists every reason.
The current host's overlaid footer has 50 points of reserved clearance.

The sidebar **menu** includes **Compact** (the original spacing) and
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
addition to the light-mode expansion matrix at 240 and 349 pixels. Dedicated
`managed-*-340x600.png` and `unmanaged-light-340x600.png` fixtures exercise two
workspaces, duplicate names, nested ancestry, long branches and mixed lifecycle
states at the target sidebar density. The broader matrix uses a 941-point
viewport. Filenames identify density, scenario, view mode and width.
The renderer checks the actual SwiftUI color-scheme and contrast environment.
Per-image JSON records measured scroll viewport/document geometry; metadata-only
panels are also rendered at both widths to check horizontal containment. Clarity
validation uses matched before/after fixtures, not screenshots of live work.
Its fixed synthetic clock also owns the injected freshness timer; elapsed CI
wall time cannot expire a fixture whose logical clock has not advanced.
The clarity tests also render light/dark icon and status keys, verify that each
symbol exists, and confirm that the output contains actual color accents.
Contrast uses the SDK's writable `_colorSchemeContrast` backing key only in
tests, paired with native high-contrast AppKit appearances; no system display
preferences are changed.

All metadata is synthetic and local preferences are isolated for the render
test. Its AppKit windows are never shown; this is not a desktop capture, live
CMUX-host visual proof, system VoiceOver verification or a pixel-baseline
comparison. No transcripts, real workspace paths or desktop images are uploaded.

## Choose your session icon: `/cmux-maestro-native:maestro-icon`

The bundled `/cmux-maestro-native:maestro-icon` skill searches the local Nerd Fonts catalog and saves
a glyph and/or identity color for **the invoking session only**.
Workers use their injected identity/token; coordinators use their own retained
registration credentials. The command checks the caller's exact workspace and
surface and accepts no other-session target. It does not rename, focus, register,
recover, archive, approve, stop, or grant tools to any agent.

```sh
MAESTRO="$HOME/Library/Application Support/CMUXMaestroPreview/Orchestration/bin/cmux-maestro-orchestrator"
"$MAESTRO" icons --search ghost
"$MAESTRO" icons --search bug --limit 20 --offset 0
"$MAESTRO" icon \
  --actor-id "$CMUX_MAESTRO_WORKER_ID" \
  --token "$CMUX_MAESTRO_CONTROL_TOKEN" \
  --icon nf-md-bug_check --color teal

# Standalone session: use the exact UUID from this CLI session's own context.
"$MAESTRO" icon --self --session-id "<current-session-uuid>" \
  --icon md-robot --color teal
```

The [cheat sheet](https://www.nerdfonts.com/cheat-sheet) is a visual reference.
`nf-` prefixes and preset names are accepted and resolve to canonical glyph
names. Removed, empty, or unsupported glyphs are rejected without changing the
previous selection. Searches are paged and capped at 100 results. The palette
is `theme`, `green`, `teal`, `blue`, `purple`, `pink`, `red`, and `gray`; no orange.
Omitting glyph or color preserves that part of the selection.

All new registrations and workers default to `md-robot`.
`register`/`spawn` accept optional `--icon` and `--color` startup choices.
Saved choices survive follow-ups and are cosmetic: they never refresh execution
or Git timestamps. A bounded, private `observer/icons.json` projection matches
node/run/workspace/surface identity and survives older supervisors republishing
`current.json` without cosmetic fields. The sidebar remains read-only over its
existing observer-directory grant.

The glyph font and catalog are pinned to upstream commit
`b894ea7803af6aade63d60a4381e006098ec9c4d`; their hashes, upstream license and
glyph-source notices live under `Resources/NerdFonts/`. Tests check the whole
selectable catalog against actual font outlines. Missing resources or unknown
stored glyphs show explicit unavailable indicators rather than font fallback.

Refresh Copilot integration through the stable app's existing explicit consent
flow to install the new skill, controller and catalog. Cached CLI plugins are not
rewritten or restarted automatically.

Standalone Copilot sessions can use `icon --self --session-id <current-session-uuid>`
instead of orchestration credentials. The native helper verifies the caller's
actual live CLI ancestor, PID/start tuple, in-use marker and existing binding.
It refuses another surface/session, stale or ambiguous proof, and never creates
an orchestration run. Appearance records stay under the existing private
bindings grant, separate from ordinary hook refreshes; malformed appearance
data cannot invalidate lifecycle evidence. No transcript or process arguments
are read for authorization.

## Completed work history

The sidebar's **ellipsis menu → Sidebar settings** opens history controls shared by
**Hierarchy** and **Taskboard**. The default active outline hides finished/cancelled
children and confirmed ended processes, including their otherwise redundant
surface rows. Managed workers leave when a terminal outcome is known; active
descendants, blockers, unknown state and unread errors keep necessary context.
This only filters the sidebar: terminals, sessions and controller ownership are
never closed, stopped or archived.

**Show ended agents** reveals observations still retained by history.
Failed rows remain until explicitly dismissed with their **×** control; focusing
or inspecting them only marks nonblocking notices read. Questions, permissions,
uncertain attention and live descendants protect rows from dismissal. Legacy
automatic "viewed failure" markers no longer hide rows.
Finished and cancelled child outcomes are retained for
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

Copilot reuses turn IDs such as `0` and `1` in later interactions. When supplied,
`data.interactionId` scopes accepted starts and replay protection together with
the owner and turn ID. It is an opaque, nonempty string bounded to 256 UTF-8 bytes,
not a counter or an inferred user-message epoch. Retired interaction identities
use the existing bounded replay guard. A new primary interaction does not reset
still-running children or their pending requests.

An end with an explicit interaction ID must match the current accepted owner
turn. Ends without that field retain legacy pairing when the turn identity is
unambiguous. For reused IDs, they require a current causal parent or a uniquely
matched tool completion whose start was tied to the current turn. Only envelope
IDs/parent links are used across ignored payload-bearing events: no prompt,
arguments, results or message content is decoded for this purpose. Tracking is
bounded to one causal tip per active owner and one origin per retained tool,
not an accumulated transcript graph.
Optional interaction/turn tags on `tool.execution_complete` are validated against
its recorded tool origin, or the current accepted owner turn when no origin was
recorded. Explicit contradictions cannot complete current work or advance its
causal tip. Matching tags do not create missing tool ownership.

All tool-associated events, including tool-backed subagent events and unjoined
shell notifications, are excluded from generic parent bridging.
Accepted tool starts, completions and partial results advance a causal tip only
through a known tool whose recorded origin is the current accepted owner turn.
An old or missing origin cannot be replaced by a later `parentId`, even when tags
are nil or the raw turn ID matches. Partial results decode only bounded optional
tool/turn/interaction metadata, never output content. A matching current partial
may advance the single tip, but does not change work state or manufacture an
outcome. Non-tool envelope bridges retain their bounded current-parent behavior.

Missing/gapped causal evidence for a reused nil-interaction end produces
`ambiguousTurn` and unknown primary state, not a fabricated completion. Pending
requests and background work survive, and a later proven end can recover the
current outcome; the observed ambiguity keeps that transcript projection partial.
Explicitly mismatched ends and exact old event replays cannot close the new turn.
Contradictory clocks on a proven match retain identity with unknown timing.
Legacy-only streams keep their existing replay behavior; missing interaction
metadata cannot silently reinterpret an already-used explicit turn identity.
A provider record incorrectly labeled or parented as current is not distinguishable
from current evidence by this metadata-only reader.

Normal tool failure may coexist with **Turn finished** and an idle primary turn.
An accepted primary `session.error` or `abort` retains its existing failed/cancelled
policy instead; it is not relabeled as normal turn completion. A fresh accepted
interaction can subsequently establish working state.

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
Nonblocking notices are marked read when their tab is successfully focused or
their details are opened, without a separate acknowledgement button. A confirmed
host focus transition also marks that tab read; initial mount, passive polling,
hover, expansion and failed/cancelled navigation do not. Sidebar focus captures
the notices present at the click and revalidates them after host acceptance, so
later notices and changed blockers are not cleared by a stale click.
The menu retains **Mark all nonblocking notices as read** as an explicit fallback.
Explicit child dismissals are keyed by exact session/child/terminal-event identity;
managed failure dismissals use node/generation/phase. These history fields share
the existing 2,048-entry / 1 MiB limit, survive reloads, and never hide a new
generation or completion event. **Restore dismissed history** clears these read
dismissals. Marking a notice read never dismisses its failed row.
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
Telemetry and the remaining backlog are not claimed by this feature.

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
- Spawn replay keys use the spawn tool ID; turn replay keys use owner +
  interaction ID + turn ID when interaction metadata is present, otherwise the
  legacy owner + turn ID namespace.
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
- Oversized `session.binary_asset` events retain a bounded, validated outer
  envelope while their opaque `data` object is discarded incrementally. Uploaded
  screenshots therefore cannot permanently invalidate later working/idle state.
  Root identity, type, parent-event metadata, duplicate-key rejection, nesting
  bounds and complete-record boundaries still apply. Other oversized events and
  malformed envelopes remain fail-closed; the 1 MiB retained-line limit is not raised.
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

**Host footer compatibility:** the native view reserves an absolute 50 points of
bottom clearance for the current CMUX overlaid footer, independent of density.
The SDK provides no footer-inset contract; a rendered-strip regression test checks
both sidebar modes and densities leave this area clear. Reverify the clearance
when host chrome changes.

Workspace containers use eager layout inside the scroll view; their child trees
retain the existing projection limits. This avoids the lazy root-placement loop
observed during remote accessibility scrolling. An offscreen AppKit regression
exercises repeated scrolling and mode changes in both densities; live accessibility scrolling and
continued history updates remain part of deployment acceptance.

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
The helper's optional `com.apple.application-identifier` entitlement must match
that exact identity. It does not permit additional access entitlements.

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

The explicit production-app `--install-copilot-integration` command documented
above is the button-free equivalent. It is a separate authorized setup action,
not an automatic side effect of the preview update transaction.

### Update, rollback and status

Close the containing installer app normally before replacing it. In CMUX,
select the **Default** sidebar and allow preview/helper processes to finish;
do not quit CMUX or terminate existing CLI sessions. The command refuses a
replacement while a same-user process is executing from an affected preview
app or backup. It reports the specific process ID when possible; it never signals a
process. Keep these apps closed until the operation finishes.

macOS can retain an idle extension process even after Default is selected.
Use **`prepare-update`** to retire only the receipt-owned preview registration
before an update or rollback. This does not delete or replace app files, change
plugin settings, or signal any process. It verifies the owned app first and
refuses to report readiness if a preview/helper process remains. If preparation
is interrupted or you decide not to update, **`recover`** restores the current
registration. Until update/rollback/recovery completes, `status` can report the
expected missing registration.

```sh
# After another explicit ./scripts/build-register.sh:
python3 scripts/local-preview.py prepare-update
python3 scripts/local-preview.py update \
  --source "$PWD/.build/adhoc/Build/Products/Debug/CMUX Maestro Preview.app" \
  --retire-development-registration
python3 scripts/local-preview.py status

# Explicitly exchange the current app with its verified previous version:
python3 scripts/local-preview.py prepare-update
python3 scripts/local-preview.py rollback

# Cancel preparation without changing the installed build:
python3 scripts/local-preview.py recover
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
The installed CLI currently accepts absolute local paths but warns that direct
repository, URL, and local-path installation is deprecated for a future release.
CMUX Maestro intentionally retains the working local-preview path; public
marketplace or release infrastructure remains out of scope.
Hook manifests follow the [command-hook
reference](https://docs.github.com/en/copilot/reference/hooks-reference), including
`version: 1`, `type: command`, `bash`, and `timeoutSec`.
