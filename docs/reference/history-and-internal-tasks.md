# History and internal tasks

Internal Copilot tasks, Other activity, completed-work history, dismissal, replay. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

## Completed work history

### Internal Copilot tasks

Explicit provider `.subagent` observations with literal session/child parents
are internal tasks. They are not interactive tabs. Hierarchy attaches
its compact consumer under the exact owning session. This includes
coalesced managed rows and retained original-session context. A task is one
connector-linked text line. No identity icon. No navigation/lifecycle
actions. Full observed name and state stay in accessibility and tooltips.
Working alone animates green. Reduce Motion keeps a static working arc.
Completion, failure, blocked, queued, idle, unknown and cancellation use distinct
state shapes. Bounded left indentation keeps a common status edge.
Managed-owner and provider-task depth share one bounded indentation budget.
Suppressing a duplicate native surface row is not session ownership. Unmatched
observations on that surface keep a separately identified session-context heading.
Never use the current managed chat's task parentage.
Multiple observations of the same agent surface add no agent or state
counts. This counting rule does not attach their task contents to a managed
chat. Existing retained managed records keep the explicit entries/context legend.

Idle, unknown and cancelled tasks hide by state. A workspace's eye reveals
**idle and finished tasks**. It works independently of other workspaces and **Show ended
agents**. Failed tasks always show. Finished and failed task outcomes have **no
retention clock**. They remain until their exact session/task/terminal-event outcome is
dismissed. An "N internal tasks" row counts only tasks currently shown. It disappears
when none show. Outstanding
attention, degraded evidence and necessary ancestry stay protected.
New work, a new result or new attention can return. Dismissal revalidates current,
fresh evidence. It cannot hide a replacement outcome. It cannot bypass active, failed,
uncertain, attention-bearing or relevant internal descendants. Harmless completed
non-task activity does not block reviewing the parent outcome. When legacy history
shows, the dismissed parent's ancestry can remain without restoring that outcome.
After individual dismissal, keyboard focus returns to a visible local owner,
workspace or Taskboard control. It never selects or activates a native tab.
This local restoration does not automatically open a keyboard preview. Ordinary
keyboard focus keeps its existing preview behavior.
Task quantities count only internal tasks. Branch working, blocked and attention
totals include related non-task descendants. Owner summaries keep uncertainty
from state-filtered unknown tasks. Incomplete/omitted evidence is explicit.

Real terminal-backed child agents keep their real tab identities. Neither task
visibility nor the workspace eye filters real tabs from native Hierarchy,
inflates agent/tab counts, changes ownership or closes a session.

### Other activity and session history

The completed-work history controls in sidebar **Settings** are shared by
**Hierarchy** and **Taskboard**. The default active outline hides finished/cancelled
non-task activity and confirmed ended process observations. Native surface rows
stay available. Managed workers leave when a terminal outcome is known. Active
descendants, blockers, unknown state and unread errors keep necessary context.
This only filters the sidebar. Terminals, sessions and controller ownership are
never closed, stopped or archived.

**Show ended agents** reveals observations still retained by history.
Failed rows remain until explicit dismissal with their **×** control. Focusing
or inspecting them only marks nonblocking notices read. Questions, permissions,
uncertain attention and live descendants protect rows from dismissal. Legacy
automatic "viewed failure" markers no longer hide rows.
Finished and cancelled **non-task activity** outcomes are retained for
**15 seconds** by default. Choose **1 minute**, **5 minutes**, **1 hour**, or
**Never**. Retention starts at the accepted terminal event's RFC 3339 timestamp.
It does not start at poll, first display, or application launch. Missing, malformed, or
future timing shows as **Completion age unknown**. Never auto-expire while
unknown. Source events are not deleted.

Use a row's separate **Dismiss** button, or **Clear completed** for eligible
retained outcomes on current-window surfaces (including collapsed branches,
excluding display-capped/off-window/expired work). These controls never focus,
cancel, approve, prompt, or otherwise control an agent. Working, blocked, idle,
and unknown work stays visible under the existing display limits. A hidden
terminal parent remains as **child context** when descendants still need it.
Running counts and retained/hidden history counts are separate. Empty history
is not evidence that a session has finished.

History uses a versioned `CMUXMaestroPreview/sidebar-history.json` record in the
extension container's Application Support directory. Coordinated, atomic
read-modify-write actions preserve other windows' retention and dismissals,
including separate extension processes. Existing windows observe changes through
file presentation (no polling daemon). Same-process windows update immediately.
The selected view stays in `UserDefaults`. History actions do not change it.

On first use, the existing `sidebar.completedHistory.v1` defaults record is
validated within the same coordinated transaction and migrated once. The file
is authoritative thereafter, even if another process has stale legacy defaults.
Remove the old key only after a successful file write/read. Invalid legacy
or file data stays untouched until an explicit reset. Failed migration can be
retried. No settings mirror back into the old history key.

Dismissal keys contain only provider-session UUID,
child ID and accepted terminal-event UUID. Never labels, paths, or source content.
Reloads, duplicate events and surface/workspace moves preserve identity. New
work or a new terminal outcome does not inherit an old dismissal. Fresh lifecycle
identities reopen work. Comparisons against possibly future wall-clock timestamps do not.
Retired invocation and agent-scoped turn identities stay tombstoned,
independent of current tool mappings. Repeated starts cannot reopen old work,
even with a new event UUID.
Records are
bounded to **2,048 dismissals / 1 MiB**. A full store refuses a new batch rather
than evicting old keys silently. **Restore dismissed history** frees that store.
Retention still applies, so select **Never** to reveal older work.

Malformed stored settings fail open: history hiding is disabled and a bounded
notice offers **Reset history settings**. Ordinary retention/dismiss/restore
actions never overwrite corrupt data. Reset explicitly restores 15-second retention
and clears dismissals. Restore clears only dismissals at its coordinated turn,
preserving the latest retention. Later dismissals remain later actions, not a
resurrected window snapshot. Neither action changes the selected view. Storage
I/O failures also fail open with a notice. Capacity rejection keeps the last
valid record and rejects the entire batch. History deadlines use a
single cancellable timer. Refresh does not reset it. It stops on hide, disconnect,
or access loss. Existing observation freshness remains an independent limit.
Reducer replay protection keeps up to 65,536 exact recent lifecycle event UUIDs
and 4,096 exact recent start/work/tool/resolved-request keys per session.
Each ledger spills into its own fixed 128-KiB filter rather than rejecting new
events at the exact-window boundary. Spilled bits never clear within a
transcript generation. Cold matches are uncertain and report partial data.
Actual filter saturation fails closed. It never silently forgets anti-replay
evidence. Cold start-identity matches cannot distinguish old replay from a fresh
start's false positive. A matching agent row already terminal becomes unknown.
This clears its obsolete terminal outcome and completion pairing, so
prior dismissal/expiry cannot hide potentially active work. A terminal root
similarly becomes unknown on an uncertain root turn. Neither case claims fresh
activity or adopts the unprocessed event's model. Live/blocked rows, pending
requests and unrelated root state stay unchanged. Exact replay is a no-op.
On unprocessed fresh lifecycle evidence,
uncertain new starts demote affected work to unknown and clear obsolete terminal
evidence, so a prior dismissal cannot hide possibly active work. Unresolved
lifecycle scope demotes conservatively. Uncertainty alone does not resolve
known pending requests. Session identity/schema checks run
before all deduplication and capacity guards.
Complete, identity-verified reads publish conservative semantic degradation as
current partial data, including unknown lifecycle state and replay limits.
Malformed events, incompatible session schemas, identity changes and torn reads
still cannot publish unvalidated replacement state.
