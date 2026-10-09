# Owned agent lifecycle

Owners/workers load this supporting contract before dispatch, return/transfer,
recovery, and retirement. Use caller authority and existing task/session records;
no new skill, controller, permission system, or ledger.
Load the owning contracts without replacing their gates:
[WORKSPACE](../ship/WORKSPACE.md) for Git isolation/Paseo placement when placing agents;
[DELIVERY](../ship/DELIVERY.md) for PR readiness when finishing;
[OBSERVATION](../shepherd/OBSERVATION.md) before PR observation/wakeup changes;
[RECOVERY](../shepherd/RECOVERY.md) for issue-backed Joe continuation.
Keep cadence/episode facts in this custody record.

For CMUX, the [handoff and close contract](#cmux-handoff-and-close) below takes
precedence over generic retirement, archived-state verification, permission
readback and timer mechanics in this file. Use the installed
[Maestro lifecycle guide](../cmux-maestro-orchestrate/SKILL.md); do not substitute
Paseo/Orca operations or infer a close grant from this guidance.

For [Orca-owned work](../joe-mode-orca/RUNTIME.md), use the native Run,
Task/Dispatch, workspace, permission and worker-release contract rather than
Paseo-specific APIs below. Preserve the same acceptance, no-overlap and
preservation gates. Native accepted settlement is not proof of artifact
acceptance; release never substitutes for worktree cleanup.

## Record distinct facts

Record observable facts, evidence pointers, observation times, and explicit
unknowns/capability limits:

- **Identity/role:** repository identity, agent ID, owning parent/return owner,
  assignment bounds, owned PR scopes, authorized actions.
- **Placement:** Git common directory, worktree path, branch/start commit;
  Paseo project/workspace IDs and returned mapping, when used.
- **Delivery:** actual PR state/draft flag, observed source/target refs and
  commits, candidate-specific acceptance/review/check evidence, blockers.
- **Custody:** current scope owner, offered return/transfer, receiver's observed
  state/acknowledgment, remaining duties, next observation when relevant.
- **Runtime:** actual agent status, live child/repair/wakeup ownership, retirement
  result or concrete retention reason, and missing capabilities.

Draft URLs prove progress, not readiness; running/idle/completed/cancelled describes
runtime, not delivery. Sending or sender-authored records cannot prove receiver
observation/acceptance. Receipts alone establish neither truth, human approval,
nor permissions.

## Dispatch, return, and transfer

1. Before launch, reconcile owners/placement. Dispatch stays pending until
   returned agent identity and its first assigned-state observation are confirmed.
   Under Joe, apply [TEAM](../joe-mode-paseo/TEAM.md) developer-slot accounting
   and [permission propagation](../joe-mode-paseo/RUNTIME.md#permission-preserving-dispatch).
   Copy current authorized mode/features before the first prompt and verify
   readback after bootstrap, including for replacements and reviewers.
2. Workers return complete actual diff/artifacts, candidate IDs, validation/
   acceptance evidence, blockers, and live responsibilities. Bounded returns are
   not full delivery: parents retain integration, independent review, publication,
   and Shepherd handoff.
3. Receivers inspect decisive artifacts/live state and explicitly acknowledge
   accepted scope, observed candidate, remaining duties, and custody. Preserve
   their response. Shepherd handoff requires actual initial PR observation and
   accepted custody—not enqueue/send success, self-authored ownership, or idle status.
4. Senders retain responsibility until acknowledgment, without concurrent
   mutation. Outgoing writers stop before receivers write; no duplicate monitor
   or repair loop. Same-session Shepherd entry still records initial observation
   and role acceptance; naming the skill is insufficient.
5. After acceptance, assign concrete follow-up with owner/resumption condition
   or retire terminal workers below. Reuse retained workers for pending fixes
   when supported, never retain indefinitely for hypothetical work.
   If self-retirement risks the report, explicitly assign its acceptance,
   preservation, and agent retirement to the owning parent.

## Recover before replacing

Cancellation, runtime loss, or unconfirmed handoff invalidates live custody.
Record gaps; reconcile known owners/children, provider refs, partial diffs/commits,
pending permissions, and wakeups. Cancelled parents or idle children do not prove
no work. Preserve partial work; verify stopped writers/monitors before resuming
or replacing owners. Uncertain visibility blocks overlap. Explicitly transfer
each remaining scope; failed sending never justifies stale ownership or duplicate
monitors.

One runtime may host several explicitly assigned Shepherd scopes, each with one
owner and its required cadence. Share execution, not scope, intent, or readiness.
One merge ends only that PR's scope. Active repairs, other PRs, heartbeat waits,
human/permission blockers, or recovery duties can justify idle-agent retention.
Under Joe, blocked developers do not stay idle indefinitely: TEAM owns the
self-challenge, delegated second lens, fresh retry and backlog escalation.
Transfer duties and preserve work before retiring them. Keep genuine persistent
roles, not stalled workers with only hypothetical future work.

## Retire finished owned agents

The following archive/active-view procedure applies only to runtimes that
support it under the caller's grant. CMUX uses the separate contract below,
which requests close without waiting for removal.

Owners **must actually archive/retire** clearly terminal owned agents through
supported harness operations after accepting/preserving results and completing/
transferring all duties. Default: action, not cleanup candidates. Read-only
analysis and bounded implementation may end after accepted return; Shepherd ends
only after all owned scopes' actual duties.

Before retirement:
- Verify exact owned agent ID, terminal assignment, preserved evidence, accepted
  return/custody, and no active child, repair, wait, or other PR duty.
- Coordinate run-owned wakeups without disturbing other scopes. Under OBSERVATION,
  cancel/delete and verify only unneeded owned wakeups; terminal fresh-run agents
  do not end future schedule duties.
- Invoke supported retirement; verify archived state or documented active-view
  removal. Uncertain evidence/ownership requires retention, specific reason, and
  next action—not success.

For Paseo, inspect current schemas: `archive_agent` interrupts running agents,
not just visibility. Never archive another owner's agents, all idle agents,
or live monitors for tidiness. When self-archive interrupts reporting, the
acknowledged parent performs/verifies it. Unavailable/denied archival requires
retained ID, capability limit, responsible owner and next action; never guess
APIs, widen permissions, or silently retain forever.

Retirement is **not** project/workspace archival or worktree/branch/evidence
deletion. Paseo workspace archival may delete owned worktrees; never substitute
it. Preserve resources; separately authorized Git cleanup follows WORKSPACE's
preservation checks.
Joe team kickoff includes TEAM's bounded blocked-work cleanup: verify remote
branches and all local evidence before removing exact owned worktrees. Failed
preservation means keep the worktree. Role retirement also needs PM-recorded
heartbeat deletion; an unknown timer remains a concrete unresolved duty.

## CMUX handoff and close

Default delivery, review, test and investigation workers are short-lived: one
concrete bounded assignment, then accepted return and separately authorized
owned close. Later independent work gets a fresh worker within actual admission
and staffing bounds, not a permanent idle pool. This policy adds no automatic
global close authorization, scheduler, daemon, cleanup engine or completion
protocol. No startup handshake, heartbeat or polling loop is required.

Keep these distinct decisions in the existing task/delivery evidence:

1. **Assign:** record the real parent and full launch identity (worker, workspace,
   surface, session and generation), assignment/stop condition, scope and
   return owner. Launch acceptance is not prompt consumption or task completion.
2. **Offer the result:** preserve exact outcome (including blocked/failed), source
   revision/commit SHA when applicable, full accessible evidence, unresolved
   findings with provenance, dirty work and every remaining command, child,
   PR, review, human-decision or other duty. No commit exists for some bounded
   investigations: say so, never invent one. A compact milestone points to the
   full artifact; it cannot replace it.
3. **Accept custody:** the receiver inspects the actual candidate/artifacts and
   explicitly accepts named scope, remaining duties and their owners. Preserve
   that substantive decision, not an automatic messaging acknowledgment.
   Missing/stale evidence or ambiguous ownership leaves transfer pending.
   Outgoing writers stop before incoming writers mutate; no duplicate PR owner.
   Blocked work may be transferred without claiming successful delivery.
4. **Decide retention or close:** the owning parent checks that no active command,
   child, repair or PR duty will be lost and that all other duties are complete
   or accepted by an identified receiver. Unknown activity blocks closing.
   Retain only a concrete current duty or capability/authority gap, with reason,
   responsible owner and exit/resumption condition. Active PM, open Discovery,
   a pending human decision and a genuinely owned PR scope qualify; idle state
   or "might be useful later" does not. Do not cancel work to make it terminal.
5. **Request only authorized close:** after the gates above, the actual owning
   actor makes one serialized native `maestro_close` request for the exact owned
   direct child. A worker cannot close itself, its parent, siblings or peers.
   Do not send shutdown instructions to circumvent that ownership. Only an
   explicit subtree grant permits the existing fixed descendant-first pass;
   reconcile every selected descendant's evidence/duties before dispatch.
   Target-only never settles child duties. Serialize requests rather than
   launching concurrent closes; never impersonate intermediate parents.
6. **Preserve the outcome:** retain every target and accepted/refused/unknown/
   not-attempted result, including partial or lost replies. Request acceptance
   is not terminal/provider removal, task success, review approval, or capacity
   release. No removal wait, automatic retry, `/exit`, terminal typing, force-kill,
   provider shutdown, or input fallback. Refusal/unknown retains unresolved
   custody with the actual limitation and next owner action; absence of a
   supported wake is a gap, not permission to create a timer.

Turn end, process exit, idle UI and a sent result are never accepted task
completion. The parent accepts/preserves the final report before any close that
could interrupt it; sending it does not authorize self-retirement.

Preserve branches, worktrees, dirty patches, review receipts and session
artifacts. Agent retirement never deletes delivery resources, source markers
or node history. Independent resource observation/accounting stays separate;
retained history may still consume node capacity. Never erase records, retry
fan-out, or infer room from a close receipt.

For contract/caller changes, exercise [acceptance scenarios](LIFECYCLE-SCENARIOS.md).
Package/link tests prove reachability, not runtime compliance.
