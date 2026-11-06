# Tool events and missing causal evidence

[↑ Reader, lifecycle, and retention](../reader-lifecycle-and-retention.md) | [← Turn identity and causal bridging](turn-identity.md) | [Retention protection and acknowledgements →](acknowledgements.md)

Same-owner tool-associated events are excluded from generic parent bridging. This includes tool-backed subagent events and unjoined
shell notifications.
Accepted tool starts, completions and partial results advance causal tip only
through known tool whose recorded origin is current accepted owner turn.
Later `parentId` cannot replace old or missing origin, even when tags
are nil or raw turn ID matches. Partial results decode only bounded optional
tool/turn/interaction metadata, never output content. Matching current partial
may advance the one tip. It does not change work state or manufacture an
outcome. Non-tool envelope bridges keep bounded current-parent behavior.
Cross-owner continuity does not assign a foreign tool to the primary turn;
it only carries already-proven occurrence evidence along the shared chain.
An unowned tool completion (for example, its start predates the bounded tail)
may advance envelope continuity only after passing the lifecycle event replay
guard. It never creates ownership or applies completion effects. Exact replays,
uncertain replay matches and exhausted admission cannot bridge the chain.

Missing/gapped causal evidence for reused nil-interaction end yields
`ambiguousTurn` and unknown primary state, not fabricated completion. Pending
requests and background work survive. Later proven end can recover the
current outcome. Observed ambiguity keeps that transcript projection partial.
Explicitly mismatched ends and exact old event replays cannot close the new turn.
Contradictory clocks on proven match keep identity with unknown timing.
Legacy-only streams keep existing replay behavior. Missing interaction
metadata cannot silently reinterpret already-used explicit turn identity.
This metadata-only reader cannot tell provider record wrongly labeled or parented as current
from current evidence.

Normal tool failure may coexist with **Turn finished** and idle primary turn.
Accepted primary `session.error` or `abort` keeps its existing failed/cancelled
policy instead. Do not relabel it as normal turn completion. Fresh accepted
interaction can then establish working state.

Outstanding nonblocking evidence is intentionally bounded: only latest
accepted error/abort outcome per owner, plus latest primary-turn completion.
Successful historical child completions are history, not attention. Fresh
owner turn/tool/invocation activity retires that owner's obsolete outcome. New
primary turn begins new outcome cycle for session and its children.
It does **not** resolve their still-pending requests. Resume invalidates prior
activity/attention and demotes nonterminal children to unknown. It never
claims pre-resume background work completed. Accepted terminal child
evidence stays available to history controls. Duplicate/retired lifecycle
identities cannot restart attention or its timing.
