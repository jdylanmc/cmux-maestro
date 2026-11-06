# Attention and safe activity

[↑ Reader, lifecycle, and retention](../reader-lifecycle-and-retention.md) | [Turn identity and causal bridging →](turn-identity.md)

Both views split permission requests from questions, each shown on the session
or child that owns the durable request. A pending question is an in-flight
`ask_user` call (current Copilot builds emit no `user_input.requested` event).
It shows as a slowly pulsing light-blue question-mark badge with a matching row
tint, without a text label or error color. A permission request keeps its
**Waiting for permission** line. Pairing uses request kind, owner and request
ID, so a completion for another owner or kind cannot clear it. Hook-resolved
permissions do not block. Repeated or late request identities cannot reopen a
resolved request, rejected stale abort/error evidence cannot erase a newer
request, and missing ancestry stays explicitly unresolved. Independent
requests have no clock order: a delayed question remains pending even if a
different permission has a newer timestamp. Hook resolution uses exact
kind/owner/request identity, even when it arrives after another request or a
new turn.

The compact **needs attention** count on collapsed branches includes
outstanding requests and nonblocking outcomes. Header and workspace rows add no
separate needs-input line. **Acknowledge** records only the outcomes, locally in
the native sidebar. **Acknowledge all** uses the current-window projection,
including collapsed branches and excluding off-window or display-capped rows.
An owner with a pending request is never eligible, even with an outcome.
Acknowledgement, history dismissal and focus never send approval, answers,
cancellation or any agent-control command. CMUX unread counts are untouched.

Accepted tool completions never create error attention, even on nonzero shell
outcomes. Completed shell rows leave the sidebar projection, while reader
snapshots keep bounded terminal outcomes and lifecycle/replay evidence. This
does not clear independent permission/answer requests or real agent failures
(ADR 0010).

**Turn finished** means a matching primary `assistant.turn_end` was recorded,
not that the session or background children finished. It shows as a checkmark
state badge on the idle session with no separate text line (the accessibility
label remains "Turn finished"). Root errors/aborts do not end or unblock
unrelated children either. Process liveness, work state and attention are
independent. Process presence, idle time, file modification time and expired
history never imply success, progress or a hung agent.
