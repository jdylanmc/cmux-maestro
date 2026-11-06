# History storage and dismissal keys

[↑ History and internal tasks](../history-and-internal-tasks.md) | [← Other activity, session history and history settings](other-activity-and-session-history.md)

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
