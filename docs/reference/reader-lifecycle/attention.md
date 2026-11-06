# Attention and safe activity

Part of [reader, lifecycle, and retention](../reader-lifecycle-and-retention.md). Next page is [Turn identity and causal bridging](turn-identity.md).

Both views split permission requests from questions. Each shows on the session or child
that owns the durable request. Pending question = in-flight `ask_user` call (current Copilot builds emit no `user_input.requested` event).
It shows as a slowly pulsing light-blue question-mark badge with a matching row
tint, without a text label or error color. A permission request keeps its **Waiting for permission** line. Pairing uses request kind,
owner and request ID. Completion for another owner or kind cannot clear it.
Hook-resolved permissions do not block. Repeated/late request identities cannot
reopen resolved request. Rejected stale abort/error evidence cannot erase a
newer request. Missing ancestry stays explicitly unresolved.
Independent requests have no clock order between them. Delayed
question stays pending even if a different permission has a newer timestamp.
Hook resolution uses exact kind/owner/request identity. This holds even when it
arrives after another request or a new turn.

Compact **needs attention** count on collapsed branches includes outstanding requests
and nonblocking outcomes. Header and workspace rows add no separate needs-input line. **Acknowledge** records only the latter locally in the
native sidebar. **Acknowledge all** uses current-window projection. It includes
collapsed branches. It excludes off-window or display-capped rows. Owner
with pending request is never eligible, even with an outcome.
Acknowledgement, history dismissal and focus never send approval, answers,
cancellation or any agent-control command. CMUX unread counts stay untouched.

Accepted tool completions never create error attention, even on nonzero shell
outcomes. Completed shell rows leave the sidebar projection, while reader
snapshots retain bounded terminal outcomes and lifecycle/replay evidence. This does not clear independent
permission/answer requests or real agent failures (ADR 0010).

**Turn finished** = matching primary `assistant.turn_end` recorded.
It does not mean session or background children finished. It shows as a checkmark
state badge on the idle session without a separate text line (the accessibility
label stays "Turn finished"). Root errors/aborts
also do not end or unblock unrelated children. Process liveness, work state
and attention stay independent. Process presence, idle time, file modification
time and expired history never imply success, progress, or hung agent.
