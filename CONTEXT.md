# CMUX Maestro

Sidebar for CMUX that shows Copilot agent sessions, their work, and their state. Reads sanitized local evidence. Launches and messages only explicit, owned, interactive sessions.

## Language

### Sessions and identity

**Session**:
One Copilot CLI conversation, identified by its session UUID.
_Avoid_: chat, run, agent (when the identity matters)

**Surface**:
One CMUX terminal pane. A session lives on exactly one surface at a time.
_Avoid_: tab, window, pane (CMUX calls the tab a surface)

**Workspace**:
CMUX container that groups surfaces. Capacity and Taskboard filters apply per workspace.
_Avoid_: project, window

**CMUX window**:
One CMUX app window with its own workspaces, Maestro sidebar view, and host connection. One extension process serves every window (ADR 0023).
_Avoid_: window alone, when a surface or workspace is meant

**Session name**:
Copilot's title for a session, from the `name:` field of its `workspace.yaml`. User-chosen, or generated from the first prompt. Not identity evidence.
_Avoid_: terminal title, tab title (the CMUX surface title Copilot derives from it)

**Binding**:
Sanitized record tying one session to its exact workspace, surface, process, and generation.
_Avoid_: association, mapping

**Observation**:
Bounded, sanitized fact read from Copilot or CMUX. Evidence only; grants no authority.
_Avoid_: event, log, status feed

**Observation loss**:
Reliable current evidence is missing or expired. Display keeps the last status five minutes, then shows `Status unavailable`.
_Avoid_: idle, offline

**Owner**:
The session or child that owns a turn, tool call, request, or outcome.
_Avoid_: process, parent

**Location record**:
Session ID, branch, and worktree flag. No path, no repository name.
_Avoid_: repository record

**Surface directory**:
Directory CMUX reports for one exact surface. Not the agent process CWD.
_Avoid_: working directory, CWD

**Assigned directory**:
Directory the controller gave a managed worker. Only source for Git probes.
_Avoid_: current directory

### Work and attention

**Work state**:
Lifecycle of a session or child: working, idle, blocked, completed, failed, cancelled, unknown.
_Avoid_: status (too vague)

**Attention**:
Outstanding request or nonblocking outcome for a session: permission, answer, error, abort, turn finished.
_Avoid_: notification, unread

**Turn finished**:
Primary turn ended by a matching `assistant.turn_end`. Says nothing about the session or background work.
_Avoid_: done, complete

**Acknowledge**:
Hide a nonblocking notice from presentation. Never answers, approves, or touches CMUX unread counts.
_Avoid_: dismiss, mark read

**Internal task**:
Provider sub-agent observation shown as a compact row under its owning session. Never a tab.
_Avoid_: sub-agent tab, child agent

**Other activity**:
Passive shell, skill, and error history kept out of the outline.
_Avoid_: noise, log

**Dismissal identity**:
Session UUID, child ID, and terminal-event UUID. Names one dismissible outcome.
_Avoid_: label match, timestamp match

**Replay ledger**:
Bounded exact record of seen lifecycle events. Overflow turns into a 128-KiB filter that rejects on doubt.
_Avoid_: event log

### Managed agents

**Managed worker**:
Interactive Copilot session Maestro launched and owns. Accepted only with a matching session UUID, surface, and fresh live observation.
_Avoid_: bot, background job

**Born managed**:
A Copilot session that a human starts in CMUX and that enrolls itself as its own root coordinator through Maestro's extension, once Copilot holds the session (its first prompt): after a start, a resume, or, for a session already running, its next extension join. (ADR 0025)
_Avoid_: adopted, auto-managed (enrollment by the session's own extension only adds tools; it is not adoption)

**Session custody**:
Copilot's own `inuse.<PID>.lock` for a session, written at its first prompt. Enrollment and every later managed operation need it held by the provider alone; its absence decides nothing, and a second live holder suspends authority until the next join.
_Avoid_: session ownership (that is Maestro's node)

**Startup placeholder**:
The never-saved session Copilot's `--resume` opens first, in the same process, before the resumed session replaces it. It has no session-state directory and is never enrolled. (ADR 0025)
_Avoid_: transient session, ghost session

**Coordinator**:
Managed top-level worker that may own nested workers.
_Avoid_: supervisor, orchestrator

**Legacy worker**:
Pre-interactive bounded worker. Kept and labeled, never converted.
_Avoid_: old worker

**Launch lease**:
Pre-runtime ownership record. Canceling it proves the worker never claimed runtime.
_Avoid_: startup timeout

**Recorded launch policy**:
Parent's saved mode, allow rules, and deny rules. History, not proof of live permissions.
_Avoid_: inherited permissions

**Native peer messaging**:
Fire-and-forget message between same-workspace sessions that have the `/maestro` guide. Grants no control.
_Avoid_: follow-up, terminal input

**Route**:
Generation-bound, capability-bound messaging path. Retired when the provider exits or the run is archived.
_Avoid_: channel

**Recorded account**:
`{login, host}` of a managed session's account. Observed from the session when it reports its own, otherwise the launch's pinned login. Never a credential.
_Avoid_: saved account (that is a launch setting)

**Relaunch**:
CMUX quits or crashes, then opens again. Windows, workspaces, and surfaces return. Processes do not.
_Avoid_: restart, reboot

**Ended session**:
Managed session with no live or uncertain process: the recorded process is observed ended and no live `inuse.<PID>.lock` owner exists.
_Avoid_: dead session, stale session

**CMUX Copilot hooks**:
CMUX's own Copilot hook commands (session start, stop, notification, session end), which setup installs in Maestro's owned `~/.copilot/hooks/cmux-maestro-cmux-hooks.json` so CMUX's restore can find sessions you start. Not a resume binding.
_Avoid_: restore hook

**Resume binding**:
CMUX restart command (`<controller> resume <session-id>`) Maestro attaches to a launched session's exact surface. Identifiers only. Cleared when that session ends with `/exit` (a `SessionEnd` with no hangup before it).
_Avoid_: restore hook

**Resume** (managed):
Start an ended Maestro-launched session again in its restored surface through its resume binding, by exact session ID, as a new generation. Never a live session. (ADR 0024)
_Avoid_: restart, reattach, adopt

**Re-enrollment**:
Maestro takes back a human-started root that CMUX's own restore or the human resumed (also after `/exit`), by exact session, workspace and surface, as a new generation of the same node. (ADR 0024, ADR 0025)
_Avoid_: adoption

**Workspace capacity**:
Launch limit (1 to 128, default 32) against current managed usage. Preflight is advisory; reservation rechecks.
_Avoid_: quota

**Launch receipt**:
Private evidence of launch acceptance and ownership. Not a completion signal.
_Avoid_: launch status

### Sidebar

**Hierarchy**:
Outline view of workspaces, surfaces, sessions, and agents.
_Avoid_: tree view

**Taskboard**:
One card per agent session, bucketed by state: Waiting on you, Working, Failed, Idle, Finished, Unknown.
_Avoid_: dashboard

**Beat**:
Recurring prompt for one exact session, scheduled through Copilot's own scheduler.
Enabled (On) or disabled (Off).
_Avoid_: cron job, timer; pause/resume for turning a Beat on or off ("resume" means resuming a Copilot session)

**Active window footer**:
Pinned card for the selected workspace's focused surface. Resizable.
_Avoid_: status bar

**Passive preview**:
Hover or explicit card that shows details. Never focuses, marks read, navigates, or copies.
_Avoid_: inspector

**Details inspector**:
Permission-aware popover with full metadata and copyable values.
_Avoid_: footer

**Session icon**:
Nerd Font glyph plus identity color, scoped to one session or surface.
_Avoid_: avatar

**Tag**:
Short canonical slug on an agent session, assigned by the human, by the agent for itself, or both. Its color belongs to the slug, everywhere; only the human picks it. (ADR 0026)
_Avoid_: label, category

**Pet**:
Animated Codex-format sprite sheet. Maps Maestro states to rows 0, 7, 6, 3, 5.
_Avoid_: mascot

**Host footer clearance**:
Fixed 50-point strip reserved for CMUX's overlaid footer.
_Avoid_: footer inset

**Layout record**:
`sidebar-layout.json`: density and expansion state. Separate from history and acknowledgement records.
_Avoid_: settings blob

**Sidebar order**:
Maestro-only order of workspaces in a window and of surfaces in a workspace, kept in `sidebar-order.json`. Never sent to CMUX; CMUX's order is the base.
_Avoid_: CMUX order, tab order, sort

### Install and trust

**Stable local preview**:
User-owned app at `~/Applications/CMUX Maestro Preview.app`. Not a release.
_Avoid_: release build

**Coordinated install**:
One transaction that publishes the app and its owned Copilot integration, with checkpoints.
_Avoid_: setup

**Owned resource**:
File or registration Maestro tracks by provenance and may safely change.
_Avoid_: user file

**Receipt**:
Durable record of owned app, backups, and recovery intent.
_Avoid_: manifest

**Cached hooks**:
Hooks a running Copilot session already loaded. Updates do not reach them.
_Avoid_: stale hooks

**Validation identity**:
Isolated bundle ID and extension point for test and unsigned builds.
_Avoid_: test identity

**Production identity**:
Exact installed bundle identity required before any setup side effect.
_Avoid_: release identity

**Global guide**:
User-installed `maestro` skill. Installed by a human through `npx skills`, never by the app.
_Avoid_: runtime integration
