---
name: cmux-maestro-orchestrate
description: Launch chat-ready interactive Copilot workers in CMUX terminal tabs with explicit ownership and bounded permissions. Humans can continue the conversation directly in each worker tab.
---

# CMUX Maestro Orchestration

Installed invocation: `/cmux-maestro-native:cmux-maestro-orchestrate`.

Use this skill only when the user explicitly delegates work to another Copilot
session or requests closure of an owned child terminal. Each worker receives a
real terminal tab in the coordinator's current CMUX pane and workspace. Never
create a window or split.

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
If a tab was created but storage could not record its attachment/failure, the
private receipt also retains its exact `surfaceId`; keep it with the token.
Uncertain leases and resources remain reserved, not automatically reclaimed.

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
Missing account identity/API support refuses before terminal creation. Optional
`model`, `contextTier`, and `reasoningEffort` request per-launch preferences on
controllers/tools declaring these fields; do not send unsupported arguments to
an older installed tool. Generic omission preserves configured launches without
a model query or new flags. Explicit requests use the actual joined session's
`model.list()` capability snapshot, bound to its account before and after lookup.
Unsupported safe preferences warn and use available configured defaults;
unavailable lookup retains the old configured launch with an explicit warning.
Malformed/foreign evidence, account drift, missing credentials and resource or
permission failures refuse; they are not preference fallback. Requested and
configured selections are not observed child settings or a numeric token window.
No role/name/task-text inference or persistent setting change is used.
Optional `allowTools` and `denyTools` arrays carry
exact authorized rules; `yolo: true` requires explicit human approval and a
coordinator actor. A worker cannot escalate by launching another root.

Shell `spawn` refuses managed actors because it cannot establish their live
session account. Do not synthesize native launch identity, inspect bindings, or
call the private ingress yourself.

## Permissions and runtime ownership

Root and legacy defaults add no Copilot tool grants. Pass each exact authorized
rule in `allowTools` or `denyTools`; a new root's CLI uses `--allow-tool` and
`--deny-tool`. On controllers supporting #154, prospective native interactive
children inherit the parent's explicit **recorded launch policy** when
`allowTools` and `yolo` are omitted. Deny-only requests keep that recorded mode
and allows while adding denies. Verify installed capability separately; source
changes do not reconfigure existing sessions or authorize installation.

These are Copilot policy arguments, not an operating-system sandbox. Never add
`--allow-all`, a wildcard, all paths or URLs, or rights not explicitly approved
for the task. The sole new explicit broad-mode option is a **user-approved
coordinator** `yolo: true` (or root `--yolo`); it supplies Copilot `--allow-all` while preserving
explicit denies. Never request a new broad grant by default or to solve a stalled
permission prompt; recorded inheritance follows the qualified contract above.
Worker actors cannot request YOLO, including for descendants of a YOLO worker;
inheriting an explicit recorded parent YOLO mode is a separate source behavior.
An explicit `allowTools` list (including `[]`) or `yolo: false` selects requested
default mode without `--allow-all`; omitted allows still inherit. A native
explicit YOLO request combined with a narrowing list refuses. Default-mode parents enforce literal allow-subset checks. Verified recorded
YOLO permits bounded finite child rules without redundant parent allows;
wildcard/broad-rule rejection remains. Denies win and cannot be removed.
Missing provenance or recorded-policy drift before reservation refuses.
Do not synthesize shell/wildcard grants from tool visibility or task text.
Policies remain private.

Recorded/requested policy is **not a full current-provider permission snapshot**.
Human changes can make it stale. Copilot's `defaultPermissionMode: "allow-all"`
or `COPILOT_ALLOW_ALL` can elevate actual startup even without `--allow-all`;
requested default mode does not prove manual mode. Partial mode/path getters
do not establish complete current tool/deny/URL policy or atomic same-or-narrower
admission. Report these limits, never invent an override, mutate policy after
launch, isolate provider settings, or claim actual restricted startup from flags.

Root startup and native child launch create exactly one unfocused terminal tab
beside the caller and launch normal interactive Copilot with the supplied task.
Managed children inherit the verified invoking account; no account fallback is
allowed. Optional preference fallback is bounded and explicit as above, never
an arbitrary model substitution. No personal account or model is shipped as a
project default. Input and
output belong directly to that terminal: the human can type follow-ups, answer
questions, and continue after the first task finishes. Copilot itself starts
through CMUX's `surface.create` direct `initial_command`,
not shell startup input. Unsupported direct creation fails without a shell-input
fallback. Launch acceptance returns immediately after exact creation/ownership:
no interactive supervisor, startup acknowledgement, observation window, sleep,
provider/model/hook wait or polling scheduler. Necessary local setup and
individual I/O are still bounded.
The caller resolves the provider executable before creating the terminal and
captures its executable search path privately. A non-login shell sources the
private environment and execs that absolute executable; account credentials
are obtained through the bounded resolver into the process environment, never
the prompt, host command, or persistent launch files.
The canonical Maestro-context wrapper preserves task bytes, explains native
peer discovery/send and genuine envelope-sender replies, human-interactive chat,
uncertainty and no input fallback. A genuine available coordinator address is
included; no slash skill or startup acknowledgement is required.

Both coordinator and worker launch assignments receive milestone-only handoff
guidance: candidate ready, review complete, blocking failure, or decision needed.
Keep routine progress and detailed investigation in existing delivery artifacts,
not discovery broadcasts or automatic acknowledgements. A compact handoff gives
the outcome, exact candidate commit when applicable, complete evidence location,
and recipient action; never invent a pre-candidate commit or truncate findings.
After dispatch or while awaiting workers or CI, finish the bounded decision turn
and resume on supported completion or native-message events. No long idle
synchronous waits, repetitive self-prompts, polling chatter or heartbeat traffic.
Missing wake support is a recorded limitation and pending next action, not
permission to add a timer or claim completion.
Before new instructions, reconcile pending updates with the current candidate
and authoritative artifacts. Preserve unresolved blockers/findings and their
provenance until evidence resolves them; do not replay obsolete instructions or
use "latest wins" to erase findings. Independent implementation, acceptance,
Roast, rubber-duck, CI and non-author merge gates remain intact. This changes
guidance, not scheduling, permissions, receipts or fire-and-forget semantics.
The separately distributed `/maestro` guide expands this messaging discipline;
the launch wrapper applies it without requiring that guide to be installed.

Native bindings exist before creation. The CLI-owned adapter joins its exact
session and independently records its exec-preserved PID/start, verified
ancestry, surface and generation, before or after caller attachment. Hooks
observe naturally; they do not install tools. Neither hooks nor this native
observation gate the caller. Cancellation or ambiguous create/attach retains
the lease and capacity because Copilot may already be executing.

Do not create headless-worker tabs or substitute tabless SDK helpers for
Maestro roles. A failed launch is a blocker, not permission to change runtimes.

Managed workers spawn descendants through the same native `maestro_spawn` tool.
The adapter binds the actual sender; it is not supplied by the model. Respect the depth
and the controller's configured workspace limit, including managed
coordinators and retained resources; finishing an initial task does not release
an open interactive session or terminal slot. Reuse an idle worker instead of retrying fanout
failures in a loop. The #154 source defaults to 32 and permits an authenticated
workspace coordinator to configure 1 through 128; the independent global
128-node and depth bounds still apply. Verify installed support before using
`capacity --workspace <exact-workspace-uuid>` for advisory preflight. A successful
query reserves nothing; actual admission rechecks the latest limit and exact
resources transactionally. A product ceiling is not the team's dispatch budget.
Capacity reconciliation requires CMUX's atomic `surface.list` workspace
snapshot, not separate pane inventories that can miss a moving terminal.
Unavailable or malformed inventory blocks launch without freeing resource slots.

A successful return can establish only `launchAccepted: true` and
`startup: pending`. Do not retry that launch: its resources remain owned.
Direct `startup: provider-observed` means native session/process observation,
not model readiness. `supervisorStarted` (legacy) and `providerStarted` report recorded
identities, not readiness; the separate `supervisorRunning`, `providerRunning`
and `surfacePresent` fields are current exact probes (`null` means unknown).
Direct `initialTask: configured` / `taskConsumption: unknown` never claims
prompt consumption. Legacy `submitted` retains its process/result boundary.
`messaging: configured` is not proof of adapter attachment, peer availability,
or delivery; `messagingAvailability` remains `unknown` here.
`workObservation: unavailable` is not failure, even for a live provider.
Only a strict legacy report/result boundary produces `reported-result`.
Interactive work uses existing session observations separately. These receipt
rules apply to both interactive and legacy launches without changing legacy
report, follow-up or exact-resume requirements.

Status never interprets a failed host/process probe or `render_health` as death.
Confirmed surface loss fences an unchanged unclaimed legacy lease. Direct
launches with absent process observation remain uncertain, never guessed dead.
Unknown/lost create replies retain
capacity and block archive/recovery, not automatic retries or cleanup.
Do not count a prepared worktree, a failed tab, or an SDK task as a
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

## Request an owned child or explicit subtree close

Only for an explicitly authorized close, call native `maestro_close` with the
exact identity from that child's launch result:

```json
{
  "target": {
    "workerId": "<exact owned child UUID>",
    "workspaceId": "<exact bound workspace UUID>",
    "surfaceId": "<exact created surface UUID>",
    "sessionId": "<exact Copilot session UUID>",
    "generation": 1
  }
}
```

Use the actual generation, not the illustrative `1`. The adapter supplies the
invoking native identity privately. Do not inspect tokens, construct a private
`native-close` request, or substitute a peer address, name, current focus or
worktree. Peer participation is not close authority. The exact selected root must
be a direct child in the same run/workspace: never self, parent, sibling or an
unrelated peer. Omitted `scope` (or `"scope": "target-only"`) keeps the existing
single-target receipt and leaves descendants owned and untouched.

Only with explicit subtree authorization, add `"scope": "subtree"` alongside
`target`. The controller captures the root's private descendant identities once,
then considers descendants before parents under the actual invoking actor.
New children never expand that selection; changed identities are refused rather
than replaced. An ended selected root does not hide its valid live descendants.
One refusal or unknown host result does not prevent an independently valid sibling
or parent attempt. Never impersonate intermediate parents or send them shutdown
instructions.

Subtree returns `scope: "subtree"` and a complete `results` array. Each record
contains the captured five-field identity, `attempted`, `outcome` (`accepted`,
`refused`, `unknown`, or `not-attempted`), a bounded `reason`, and
`removal: "unconfirmed"`. Only accepted records have `closeAccepted: true`.
Unavailable captured surface/session fields remain null. The pass uses a
45-second total budget, at most five seconds per target, and nonwaiting state
lock acquisitions. Budget-exhausted remainder targets are explicitly
`not-attempted`; a complete result plan exceeding the existing 65,536-byte
transport bound, or containing a generation outside the existing JavaScript
safe-integer numeric wire range, refuses before host effects rather than rounding
or changing an identity. Deadline expiry before host dispatch is not an attempt;
timeout or malformed host text after dispatch remains unknown. Transport
cancellation, overflow
or loss can still leave the entire request uncertain; never retry automatically.

The controller checks its private actor capability/control identity, invoking
provider ancestry, exact child session/generation/surface, current workspace
membership and live provider anchors. Both exact sessions must have one matching,
safe `inuse.PID.lock` in the standard `~/.copilot/session-state/<sessionId>`
source directory. Its live same-user owner must be the recorded launch PID or
that PID's immediate child, as with the supported npm launcher/native CLI pair.
OS parentage, PID/start and marker identity must remain stable across preflight;
the launch anchor is never rewritten to the marker PID. Deeper, unrelated or
sibling owners refuse, without executable-name guessing. Missing, stale,
ambiguous or repurposed evidence and an ended/zombie launch or source owner
refuse. Active run launch leases and unresolved ownership refuse. No provider
shutdown is required or attempted before closing an eligible live child.

Admission issues **one stock CMUX `surface.close`** request per eligible target.
After unchanged ownership/admission guards, the initial request includes the
documented Boolean `force: true` to select CMUX's noninteractive close route.
This is part of the authorized close contract, not a caller option or an
escalation after refusal. Inherit host behavior, including last-terminal refusal;
never construct a separate force RPC, retry a refused request or manipulate
UI confirmation.

Earlier CMUX 0.65 requests omitting this field returned `confirmation_required`;
the immutable v0.65.0 source confirms omission defaults to false. The source
correction selects the published branch; actual installed/live acceptance still
requires separate proof. Any remaining host refusal stays explicit (including a
subtree `confirmation_required` reason), never accepted or retried.
Synthetic tests do not establish compatibility with a live host.
A successful target-only tool result contains the exact target plus
`ok: true`, `closeAccepted: true`,
`removal: "unconfirmed"`. This is request acceptance, not terminal disappearance,
provider exit, task completion or permission to release capacity. Refusal,
timeout, cancellation and lost/invalid replies may leave an uncertain outcome.
Do not automatically retry, wait for disappearance, send `/exit`, abort a provider,
type into a terminal, or force-kill as a fallback.

The existing controller lock excludes competing state changes during admission
and the bounded host call; no close lifecycle state is added or bookkeeping
removed. Source markers and recorded PID/start values are pre-request evidence,
not host-side atomic session/generation fencing. The host accepts surface UUIDs,
not expected provider identities; changes after preflight cannot be ruled out.
Ordinary independent status/resource accounting stays separate from this call.

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
