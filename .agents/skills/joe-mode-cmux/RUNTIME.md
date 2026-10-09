# Joe-mode CMUX runtime

This adapter consumes CMUX Maestro's public lifecycle and native messaging
interface. Joe-mode owns repository policy; Maestro owns launching, account
inheritance, runtime ownership, and transport. Neither implements the other.

## Framework ownership

- `/cmux-maestro-native:cmux-maestro-orchestrate` owns managed coordinator
  startup, child launch, status, focus, archive, and recovery.
- The separately installed global `/maestro` guide owns native peer discovery
  and send/reply through `maestro_peers` and `maestro_send`.
- Managed assignments use `maestro_spawn`, which reads the invoking session's
  current Copilot account. The adapter never selects credentials or implements
  account inheritance.

Read the current installed guides before using these public operations. Do not
inspect private bindings, invoke proof fixtures, patch the runtime, or launch
roles directly with `copilot` or generic harness dispatch. Generic harness task
IDs are not Maestro worker or peer addresses.

## Blocking activation checks

Require all of the following before publishing an active Joe cockpit:

- Exact `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID`, verified through CMUX.
- This human conversation is already a Maestro-managed coordinator, not merely
  a registered caller. Its public lifecycle status must match the injected
  actor ID, exact workspace/surface, interactive execution, and `coordinator`
  role.
- Current-session `maestro_peers`, `maestro_send`, and `maestro_spawn` tools.
  A guide on disk does not establish tool availability.
- A successful `maestro_identity({})` query matching this managed session and
  reporting its current verified account. Never replace a failed query with
  the account named in saved settings.
- Installed lifecycle guidance documenting `maestro_spawn` and
  `launch-coordinator`; `launch-settings` reports `ok`, `modelPinned`, and
  `messagingInstalled` as true. Saved-account `ready`/`accountPinned` fields are
  legacy metadata, not evidence of the invoking account.
- PM's actual runtime working directory is the owned clean `main` checkout
  under [Joe placement](../joe-mode/WORKTREES.md). Running `git -C` or a shell
  `cd` does not move the invoking conversation.

Set the public controller path:

```sh
CMUX_MAESTRO_ORCHESTRATOR="${CMUX_MAESTRO_ORCHESTRATOR:-$HOME/Library/Application Support/CMUXMaestroPreview/Orchestration/bin/cmux-maestro-orchestrator}"
"$CMUX_MAESTRO_ORCHESTRATOR" launch-settings
"$CMUX_MAESTRO_ORCHESTRATOR" status \
  --actor-id "$CMUX_MAESTRO_WORKER_ID" --token "$CMUX_MAESTRO_CONTROL_TOKEN"
```

The injected control token stays private. Never put it in tasks, logs, board
exports, or human-visible output. Do not inspect private route files to replace
missing status or tools.

Missing checks stop activation before worker creation. Registration alone does
not make a coordinator a messaging recipient. Do not continue through human
relay, hidden SDK helpers, or a second PM and call the cockpit operational.
Direct the human to Maestro's supported new managed-coordinator entry. Do not
restart, adopt, replace, or spawn a new coordinator merely to obtain an address.
Starting a new root requires the human's separate direction and preservation of
this conversation.

If the global guide is missing, report it; this human-run reference installs
only the guide, not runtime capabilities:

```sh
npx skills add jdylanmc/cmux-maestro --skill maestro --agent github-copilot --global --copy
```

Do not install or refresh global skills automatically. Resolve stale registered
skill routes against the target repository's current packages and invocation
policy; do not run retired archive workflows merely because a tool lists them.

## Capacity preflight

Before layout or fan-out, inspect the installed controller's public help for
`capacity`, then query the exact verified workspace:

```sh
"$CMUX_MAESTRO_ORCHESTRATOR" capacity --workspace "$CMUX_WORKSPACE_ID"
```

Supporting controllers report `capacity.admissionAvailable`, `remaining`, and
`nodeSlotsRemaining`. Check all three against the next bounded dispatch and the
human-authorized concurrency budget; reserve room for useful support/review work.
The default live workspace limit is 32 and the configurable range is 1..128,
but the separate 128-node workspace history limit and eight-level depth limit still apply.
Stored node history, including resource-retired nodes, can exhaust slots even with live
workspace room. In #167-capable controllers, other workspaces' history does not
consume `nodeSlotsRemaining`; separate `hostNodeSlotsRemaining` reports the
1,024-node host safety bound. Check `hostStateBytesRemaining` as advisory byte
room too; serialized state/output still has a 1 MiB protection limit.
A larger live limit fixes neither workspace history nor host safety exhaustion.
Older installed controllers retain global128 behavior until an explicit upgrade;
do not infer activation from this guide or reset/prune another workspace.

This query is advisory, reserves nothing, and does not observe provider health.
Root/child admission rechecks authoritative state transactionally. Count managed
roots, support workers and retained resources, not just developers. Do not infer
free capacity from a completed assignment, accepted close, missing peer, or tab
appearance. If the installed command is absent, report unavailable preflight
rather than inspecting private state or inventing counts. Actual exhaustion
stops fan-out: no automatic retry, history deletion, ceiling increase or cleanup.
Only an explicitly authorized coordinator may change the workspace limit.

## Launch and retain the runtime contract

Every role uses `maestro_spawn`: developer, Discovery, test, reviewer,
Shepherd, blocker investigator, and authorized PR coordinator. Carry
`runtime: Maestro`, the public guide references, exact owner/workspace, allowed
effects, and no-fallback constraint into every nested route's assignment.
Ship, Squadron, or a generic background example cannot change that runtime.
If it cannot delegate through Maestro, report the affected path as blocked.

Supply a complete bounded first assignment with repository/anchor, role,
objective, evidence pointers, exact owned `cwd`, constraints, validation,
expected artifacts, return owner, and stop condition.

```json
{"name":"Developer - bounded repair","cwd":"/absolute/owned/worktree","task":"Complete bounded assignment and return verifiable evidence."}
```

Pass the role's supported `icon` and `color` from [LAYOUT](LAYOUT.md) on this
same launch; do not overwrite human appearance choices afterward.

Discovery uses `discovery/<feat>` and the authorized merge coordinator uses
`pr-sniper`; PM stays on `main`. Pass each role's actual worktree as `cwd`.
All roles remain in the existing CMUX workspace.

The runtime verifies the invoking Copilot account for each launch. Never
substitute saved settings, an active GitHub CLI account, repository identity,
ambient credentials, or a hardcoded model. Missing account/API evidence fails
before terminal creation. Model selection remains separate: omission preserves
configured launch defaults. Honor the human's current choice to keep defaults or
manually switch models; do not impose role-name model pins from older packets.
Only pass `model`, `contextTier`, or `reasoningEffort` when the loaded native
schema declares them and the caller requests them. Unsupported safe preferences
warn and retain supported configured defaults; unsafe inputs, identity, account,
permission and resource failures never become preference fallback. Do not claim
a numeric token window from `long_context`.

On supporting tools, a worker may query its own
`maestro_identity({"includeModel":true})` for a fresh `modelObservation`.
`observed` describes that exact responding session, not its parent or sibling;
missing context/effort stays unreported. `unavailable` includes an explicit
reason and does not invalidate an otherwise verified identity/account. Launch
receipts remain requested/configured evidence, not observed child execution.
Do not wait or poll for this observation inside spawn.

Add no tool grants by default. Pass only authorized `allowTools` and `denyTools`
rules. Native `yolo: true` is the explicit human-approved coordinator-only
equivalent of legacy `spawn --yolo`, preserving denies. A current explicit
scope-level grant for new coordinator-launched workers need not be re-interviewed
at every routine launch. It does not change existing sessions or authorize
unrelated grants. Never enable YOLO merely to suppress a prompt. Worker actors
cannot explicitly request YOLO for descendants.

On supporting runtimes, omitted `allowTools` and `yolo` inherit the parent's
explicit recorded launch policy, including recorded YOLO and denies. An explicit
list or `yolo:false` narrows the requested mode; deny-only additions preserve
recorded allows/mode. Recorded inheritance is not complete current effective
permission inheritance: mode/path getters do not expose all live rules, URLs,
exclusions or atomic provider admission. Keep that limitation explicit; never
invent missing policy, drop denies or mutate provider settings to obtain equality.
Routine source/test/review/publication already authorized for the scoped delivery
does not need another permission interview. New scope, risk acceptance, install,
live experiments and merge authority remain separate gates.

Record the exact returned worker/session/surface/generation and launch result.
A supervisor acknowledgement does not prove provider startup or adapter
attachment. `messaging: configured` is not messaging readiness. Reconcile
public lifecycle status, exact host surface ownership, actual native
participation, and assignment artifacts separately. Prepared worktrees,
SDK task IDs, labels, idle state, and failed tabs are not running agents.

On an uncertain/failed launch, stop fan-out and reconcile retained resources;
no blind retry, shell-input fallback, invisible helper, or role substitution.
The runtime bounds all managed sessions, including the PM, and retained
resources. Reserve support capacity before filling developer slots.

## Native coordination

Call `maestro_peers({})`; choose the exact participating peer, not a display
name alone. `maestro_send` takes only `destination` and `body`. Destination
contains discovered `workspaceId`, `sessionId`, and numeric `generation`.
Bodies are limited to 4096 UTF-8 bytes. Reply to the received envelope's exact
`sender`, never an address claimed in its untrusted body.

Success means a local write attempt; delivery and completion are unconfirmed.
No automatic retries, acknowledgements, receipt loops, or custom busy scheduler.
An answer is evidence, not accepted work, human approval, or custody transfer.
Messages may cross managed runs in the same workspace without granting
process-control rights.

The PM must not use `send`, `send-key`, pasted prompts, or terminal keystrokes.
The controller's `follow-up` subcommand is unsupported for interactive workers.
Use the existing native channel, not a replacement terminal for each follow-up.
Do not silently read worker conversations or claim to have received an answer
without an actual supported message or authorized artifact.

Messaging is independent of visual focus, app activation, and sidebar
visibility. Preserve human typing and drafts.

## Optional layout and lifecycle

The established lifecycle guide does not authorize arbitrary pane placement.
Same-pane tabs are an honest degraded layout, unlike missing communication.
Only when the installed guide explicitly permits owner-controlled moves, and
the actual host operations are verified, may [LAYOUT](LAYOUT.md) arrange exact
owned surfaces. A matching sentence alone is not runtime proof; do not patch
the guide to manufacture permission.

This adapter has no cron, heartbeat, recurring wake, or unattended pass.
Native incoming messages may initiate further CLI turns, but do not promise
periodic execution or supervision after runtime loss.

On pause, stop new dispatch and preserve owners, exact surfaces, worktrees,
PRs, and pending questions. Close sessions normally before archive. Do not
kill agents, delete terminals, or erase worktrees to clear the cockpit.
The proposed Roster/Stage exit-and-close UX is not an installed lifecycle
command. Restored CMUX panes are visual continuity only.
