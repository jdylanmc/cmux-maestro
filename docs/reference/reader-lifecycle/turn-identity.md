# Turn identity and causal bridging

[↑ Reader, lifecycle, and retention](../reader-lifecycle-and-retention.md) | [← Attention and safe activity](attention.md) | [Tool events and missing causal evidence →](tool-events.md)

Copilot reuses turn IDs such as `0` and `1` in later interactions. When
supplied, `data.interactionId` scopes accepted starts and replay protection
together with owner and turn ID. It is an opaque, nonempty string bounded to
256 UTF-8 bytes, not a counter or an inferred user-message epoch. Retired
interaction identities use the bounded replay guard. A new primary interaction
does not reset still-running children or their pending requests.

Copilot also restarts the turn counter within one interaction. A fresh
`assistant.turn_start` event UUID establishes a new occurrence in the current
interaction, even if its owner/interaction/turn tuple was seen before. Exact
event replays, retired interactions and uncertain replay-filter matches still
refuse. Repeated tuples need occurrence-specific causal proof: matching
interaction tags alone cannot anchor a message or end. Parent links must reach
the current start or causal tip, and tool evidence must carry that start's
exact event UUID as its origin. A correctly tagged message may also anchor
through continuous session-wide parent links, including interleaved
background-owner events. Each active turn keeps one extra envelope tip for that
continuity, not another owner's work evidence, and that tip alone cannot prove
a turn end, tool origin or untagged message. Once a matching tagged message or
current-origin tool proves the occurrence, interleaved foreign envelopes may
carry that proven causal tip to its end. No unbounded graph is kept. An
accepted end establishes idle without a separate `session.idle`, and trailing
hook and usage-checkpoint envelopes do not reopen work. Neither idle nor those
envelopes finish background children or outstanding tools.

An end with an explicit interaction ID must match the current accepted owner
turn (and needs causal proof when the whole tuple repeats). Ends without that
field keep legacy pairing when turn identity is unambiguous. For reused IDs,
they need the current causal parent or a uniquely matched tool completion whose
start is tied to the current turn. Across ignored payload-bearing events, only
envelope IDs/parent links are used, and prompt, arguments, results or message
content are never decoded for this. Tracking is bounded to one causal tip and
one envelope-continuity tip per active owner, plus one origin per retained
tool. It is not an accumulated transcript graph. Optional interaction/turn tags
on `tool.execution_complete` are validated against the recorded tool origin,
or against the current accepted owner turn when no origin is recorded.
Explicit contradictions cannot complete current work or advance its causal tip.
Matching tags do not create missing tool ownership.

Copilot can persist `subagent.configured(multiTurn: true)`, complete the
original spawn task, then start another interaction on the same child without
another `subagent.started`. The reducer keeps that child's observed name, kind
and ancestry on the fresh interaction and retires the old spawn-result join.
Completion stays a terminal task outcome until fresh activity is observed.
Documented `subagent.selected` profile metadata neither replaces the spawn
identity nor revokes that capability; other unknown subagent lifecycle events
still invalidate it. `assistant.message` carries both the current
`interactionId` and `turnId`, even across root-owned warning/hook envelopes,
while its linked `assistant.turn_end` carries only the reused turn number. The
reducer reads only those two bounded message identifiers, verifies the exact
owner and current interaction/turn, and uses the message as that owner's
completion anchor. Message content is never decoded or projected. Messages
cannot create a turn, revive ended work or replace spawn identity, and their
event IDs use the bounded replay guard. Missing current-turn proof remains
Unknown (`ambiguousTurn`); see [tool events](tool-events.md). Multi-turn
capability is private, bounded reducer state, admitted once per observed child
ID only from strict boolean configuration in a timestamped initial spawn
window, before any child turn. Explicit false, failed/cancelled child outcomes,
scoped abort/error, shutdown/resume and uncertain lifecycle boundaries
invalidate it.
