# Tool events and missing causal evidence

[↑ Reader, lifecycle, and retention](../reader-lifecycle-and-retention.md) | [← Turn identity and causal bridging](turn-identity.md) | [Retention protection and acknowledgements →](acknowledgements.md)

Same-owner tool-associated events, including tool-backed subagent events and
unjoined shell notifications, are excluded from generic parent bridging.
Accepted tool starts, completions and partial results advance the causal tip
only through a known tool whose recorded origin is the current accepted owner
turn. A later `parentId` cannot replace an old or missing origin, even when
tags are nil or the raw turn ID matches. Partial results decode only bounded
optional tool/turn/interaction metadata, never output content. A matching
current partial may advance the one tip but does not change work state or
manufacture an outcome. Non-tool envelope bridges keep bounded current-parent
behavior. Cross-owner continuity does not assign a foreign tool to the primary
turn; it only carries already-proven occurrence evidence along the shared
chain. An unowned tool completion (for example, one whose start predates the
bounded tail) may advance envelope continuity only after passing the lifecycle
event replay guard, and it never creates ownership or applies completion
effects. Exact replays, uncertain replay matches and exhausted admission cannot
bridge the chain.

Missing or gapped causal evidence for a reused nil-interaction end yields `ambiguousTurn` and an unknown primary state instead of a fabricated
completion.
Pending requests and background work survive, and a later proven end can
recover the current outcome. Observed ambiguity keeps that transcript
projection partial. Explicitly mismatched ends and exact old event replays
cannot close the new turn. Contradictory clocks on a proven match keep identity
with unknown timing. Legacy-only streams keep their replay behavior, and
missing interaction metadata cannot silently reinterpret an already-used
explicit turn identity. This metadata-only reader cannot tell a provider record
wrongly labeled or parented as current from current evidence.

A normal tool failure may coexist with **Turn finished** and an idle primary
turn. An accepted primary `session.error` or `abort` instead keeps its
failed/cancelled policy and is not relabeled as normal turn completion. A fresh
accepted interaction can then establish working state.

Outstanding nonblocking evidence is intentionally bounded to the latest
accepted error/abort outcome per owner plus the latest primary-turn completion.
Successful historical child completions are history, not attention. Fresh
owner turn/tool/invocation activity retires that owner's obsolete outcome. A
new primary turn starts a new outcome cycle for the session and its children
but does **not** resolve their still-pending requests. Resume invalidates prior
activity/attention, demotes nonterminal children to unknown, and never claims
pre-resume background work completed. Accepted terminal child evidence remains
available to history controls. Duplicate or retired lifecycle identities cannot
restart attention or its timing.
