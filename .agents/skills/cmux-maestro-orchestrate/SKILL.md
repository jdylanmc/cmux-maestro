---
name: cmux-maestro-orchestrate
description: Launch chat-ready interactive Copilot workers in CMUX terminal tabs with explicit ownership and bounded permissions. Humans can continue the conversation directly in each worker tab.
---

# CMUX Maestro Orchestration

Installed invocation: `/cmux-maestro-native:cmux-maestro-orchestrate`.

Use this skill only when the user explicitly delegates work to another Copilot
session. Each worker receives a real terminal tab in the coordinator's current
CMUX pane and workspace. Never create a window or split.

Set the command path once:

```sh
CMUX_MAESTRO_ORCHESTRATOR="${CMUX_MAESTRO_ORCHESTRATOR:-$HOME/Library/Application Support/CMUXMaestroPreview/Orchestration/bin/cmux-maestro-orchestrator}"
```

## Start a managed coordinator

For agent-to-agent coordination, start a new Maestro-managed coordinator.
Registration alone does not enable an existing conversation. Never replace,
restart, or adopt that conversation to obtain messaging.

From the human's CMUX terminal, with an explicitly selected initial account:

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" launch-coordinator \
  --workspace "$CMUX_WORKSPACE_ID" --surface "$CMUX_SURFACE_ID" \
  --cwd "/absolute/repository/main" --account "<human-selected-account>" \
  --name "Maestro coordinator" --task "Bounded authorized coordination objective"
```

The placeholder is not an account default. This chooses the account for a new
root session, which has no parent to inherit from. Omitting `--account` requires
an explicit initial coordinator selection in Agent launch settings; it never
selects an ambient CLI account. The model must be configured
or explicitly supplied with `--model`. The command validates credentials and
native messaging before creating an unfocused tab; it never changes saved
account settings. Update controller, adapter and sidebar together. A live or
uncertain old supervisor blocks the new coordinator schema; the launcher
refuses to interrupt it. Provider sessions whose supervisors have already
exited are preserved, not terminated or migrated.
Capture the root command's JSON privately even on a nonzero exit. Once a root
was reserved, a failed startup still returns its custody receipt and control
token so the owner can inspect and reconcile it. Never print that token or
treat `ok: false` as a running coordinator.
Failed receipts include `reservationState: committed` when private ownership
was established, or `uncertain` when storage could not confirm it. Preserve an
uncertain receipt and the original failure; do not relaunch or guess ownership.
A confirmed uncommitted refusal returns no custody token. OS failures and
partial observer publication remain nonzero failures, not startup success.

Inside that managed coordinator, use the injected actor identity for lifecycle
status and native `maestro_spawn` for children. Require current-session
`maestro_peers`, `maestro_send`, and `maestro_spawn`; missing tools block
coordination. There is no invisible SDK-agent fallback.
Call `maestro_identity({})` to verify the actual current session/account before
dispatch. A failed identity query is a blocker, not an invitation to guess.

## Register an existing caller for legacy lifecycle control

Use only the exact CMUX environment identities. Never infer a surface from a
title, directory, screen contents, or current focus:

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" register \
  --workspace "$CMUX_WORKSPACE_ID" \
  --surface "$CMUX_SURFACE_ID" \
  --cwd "$PWD" \
  --name "Coordinator"
```

Retain the returned `coordinatorId` and `controlToken` privately for this
orchestration run. `--cwd` is explicit probe provenance for the coordinator's
verified Git worktree and branch. Non-Git directories produce no Git labels;
omit it rather than guessing when the current directory is not the assigned task
root. The controller refreshes this bounded evidence during lifecycle checks.

## Installation and legacy launch settings

Only with explicit human installation approval, the actual production Maestro
app offers the same setup operation without UI:

```sh
"/absolute/installed/CMUX Maestro Preview.app/Contents/MacOS/CMUX Maestro Preview" \
  --install-copilot-integration --copilot-executable "/absolute/trusted/copilot"
```

Normal app startup remains inert. Validation/test apps cannot use this path.
It reuses the installer and never restarts CLI sessions. Do not use it as an
automatic repair or bypass an OS permission prompt.

Before the first spawn, verify the installed controller supports and reports the
private Agent launch settings:

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" launch-settings
```

Require `ok: true`, `modelPinned: true`, and `messagingInstalled: true`.
The last field verifies installation, not recipient liveness or delivery.
The response intentionally reveals neither the account name nor the model.
Saved-account `accountPinned`, `accountAvailable`, and `ready` are legacy
metadata, not evidence of the current invoking account. Registration-only
callers cannot launch new managed workers.

The native launch path resolves the account verified by the invoking session,
passes its credential privately through `COPILOT_GITHUB_TOKEN`, and supplies the
configured model. An unavailable account fails before terminal creation. Never
replace missing evidence with active GitHub CLI authentication, repository
identity, ambient credentials, Copilot defaults, or a hardcoded model.

## Spawn from a managed session

Call native `maestro_spawn` with a complete first assignment:

```json
{"name":"Focused worker","cwd":"/absolute/owned/worktree","task":"Bounded objective, constraints, validation, and stop condition"}
```

The adapter reads the invoking session's current account through
`session.rpc.gitHubAuth.getStatus()` for each launch. Neither task text, repository
authentication, saved account defaults, nor another session selects that account.
Missing identity/API support refuses before terminal creation. Explicit model
selection remains separate. Optional `allowTools` and `denyTools` arrays carry
exact authorized rules; `yolo: true` requires explicit human approval and a
coordinator actor. A worker cannot escalate by launching another root.

Shell `spawn` refuses managed actors because it cannot establish their live
session account. Do not synthesize native launch identity, inspect bindings, or
call the private ingress yourself.

## Permissions and runtime ownership

The safe default adds no Copilot tool grants. Pass each exact authorized rule
in `allowTools` or `denyTools`; a new root's CLI uses `--allow-tool` and
`--deny-tool`. Do not synthesize full parent-permission inheritance.

These are Copilot policy arguments, not an operating-system sandbox. Never add
`--allow-all`, a wildcard, all paths or URLs, or rights not explicitly approved
for the task. The sole explicit broad-mode option is a **user-approved
coordinator** `yolo: true` (or root `--yolo`); it supplies Copilot `--allow-all` while preserving
explicit denies. Never add it by default or to solve a stalled permission prompt.
Worker actors cannot request YOLO, including for descendants of a YOLO worker.
There is no inferred full parent-permission inheritance. A general shell grant
must also be caller-explicit and task-
justified; it is never a default. Denies win. A descendant receives no additional
grants by default and may request only a subset of its parent's explicit allows;
inherited denies cannot be removed. Policies remain private.

Root startup and native child launch create exactly one unfocused terminal tab
beside the caller and launch normal interactive Copilot with the supplied task.
Managed children inherit the verified invoking account; no account or model
fallback is allowed. No personal account or model is shipped as a project default. Input and
output belong directly to that terminal: the human can type follow-ups, answer
questions, and continue after the first task finishes. A foreground supervisor
maintains ownership and metadata without intercepting terminal input. Launch
uses a private one-time credential, never a token typed into shell history.
The runtime starts through CMUX's `surface.create` direct `initial_command`,
not shell startup input. Unsupported direct creation fails without a shell-input
fallback; the existing bounded launch lease is unchanged.
The caller resolves the provider executable before creating the terminal and
captures its executable search path privately. The runtime revalidates that
absolute executable and restores the path for its child, without depending on
the host's noninteractive PATH or shell startup files.

Do not create headless-worker tabs or substitute tabless SDK helpers for
Maestro roles. A failed launch is a blocker, not permission to change runtimes.

Managed workers spawn descendants through the same native `maestro_spawn` tool.
The adapter binds the actual sender; it is not supplied by the model. Respect the depth
and eight-live-session workspace limit, including managed coordinators;
finishing an initial task does not release
an open interactive session or terminal slot. Reuse an idle worker instead of retrying fanout
failures in a loop.
Capacity reconciliation requires CMUX's atomic `surface.list` workspace
snapshot, not separate pane inventories that can miss a moving terminal.
Unavailable or malformed inventory blocks launch without freeing resource slots.

A launch acknowledgement establishes supervisor startup only. Its
`providerStarted` field reports whether a provider identity has been recorded.
`messaging: configured` is not proof of adapter attachment, peer availability,
or delivery. Do not count a prepared worktree, a failed tab, or an SDK task as a
running Maestro agent. Verify the exact returned surface/session and subsequent
native participation before claiming the team is usable.

## Inspect and focus

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" status \
  --actor-id "$COORDINATOR_ID" --token "$CONTROL_TOKEN"

"$CMUX_MAESTRO_ORCHESTRATOR" focus \
  --actor-id "$COORDINATOR_ID" --token "$CONTROL_TOKEN" \
  --worker-id "$WORKER_ID"
```

Humans send follow-ups directly in the worker's Copilot interface. The controller's
`follow-up` command remains refused for interactive workers. Newly installed
Maestro-managed spawns automatically participate in native peer messaging,
using the pinned launcher and an ordinary working directory; no fixture
preparation is needed. Use the separately installed global **`/maestro`** guide for discovery, one fire-and-forget send,
or a reply to the supplied return address. That skill owns the messaging
workflow; this skill owns lifecycle operations.

Existing/unmanaged sessions and legacy bounded workers are not adopted.
Registering the current coordinator does not make it a native recipient.
Participating same-workspace peers may message one another independently of
visual focus; this does not extend ancestor-only process-control permissions.
Copilot schedules native incoming prompts. Preserve drafts and typing; add no
acknowledgements, retries, receipts, completion tracking or custom busy scheduler.
Source-only disposable proof compatibility remains documented in
`docs/delivery-proof.md`; it is not the installed setup path.
Never use `send`, `send-key`, pasted prompts, or terminal keystrokes to work
around this boundary; a human may be using the same input.

For existing legacy bounded workers only, `follow-up` remains privately queued
and allowed only for a directly owned worker that
has a verified successful exact-session boundary for its current generation.
That includes an explicitly reported blocked, completed, or failed outcome and
a bounded recovery from report-missing or permission-denied without claiming
the earlier task succeeded. The next turn keeps the existing tool policy and
uses that worker's preassigned exact `--resume` session ID. No prompt is typed
into a terminal, and there is no fallback to `--continue`, a display name, the
focused terminal, or a recent session.

## Interactive completion and legacy reporting

Interactive workers converse normally. Do not append a machine-report contract
or turn their final answer into lifecycle JSON. Their observed working, idle,
blocked and ended states come from validated session evidence. An interactive
process exit is not proof that its task succeeded.

Only an existing legacy bounded worker whose injected execution mode is
`bounded` uses the following compatibility protocol. Its report is permission-free.
End the turn with exactly one compact
JSON object as the entire final assistant message, with no code fence, prose,
or tool request:

```json
{"protocol":"cmux-maestro.worker-report","version":1,"workerId":"<exact injected worker ID>","generation":1,"state":"completed","summary":"Brief factual result"}
```

Use the exact worker ID and generation stated in the appended turn contract.
Use `blocked` or `failed` instead of `completed` when accurate. Copilot emits
this content in an envelope shaped as
`{"type":"assistant.message","data":{"phase":"final_answer","toolRequests":[],"content":"..."}}`;
do not call a tool to submit it. The supervisor requires that exact phase,
empty tool requests, exact report fields and identity, and the successful
current-session process/result boundary. A normal answer or zero exit is not
task success.

The authenticated `report` subcommand remains an optional compatibility path
when an already-approved caller can execute it. Do not rely on that path:
noninteractive Copilot may deny a tool without offering the human a prompt.
Dual final-message and helper reports are refused rather than reconciled.
Reports are self-reported operational evidence, not independent review or
artifact acceptance. Keep secrets, raw output and full prompts out of summaries.

## End or recover a run

Archive an owned run before reusing its coordinator surface:

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" archive \
  --actor-id "$COORDINATOR_ID" --token "$CONTROL_TOKEN"
```

Close interactive sessions normally before archiving; archive refuses while an
interactive session or its supervisor is live. Existing sessions are never
automatically converted, restarted or closed by an update.
For a managed coordinator, its exact private receipt also permits archive after
a proven never-started failure or after all owned processes have exited, even
when its root tab never existed or has already closed. An active launch lease,
missing process anchors, or uncertain/live descendants still blocks archive.
Surviving terminals remain retained and counted; archive neither closes them
nor adopts another session. Legacy registered coordinators still require their
exact live root surface.

For legacy bounded workers, archive asks idle supervisors to exit but never kills a process or deletes a
terminal. Still-present worker terminals remain counted as retained resources.
If the coordinator token is lost, `recover` may issue a new run only after the
exact current caller workspace/surface matches, ownership is stale, and no
worker process or surface from that run remains:

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" recover \
  --workspace "$CMUX_WORKSPACE_ID" \
  --surface "$CMUX_SURFACE_ID" \
  --cwd "$PWD" \
  --name "Coordinator"
```

Recovery never guesses from a title, directory, focused tab, or recent session.
