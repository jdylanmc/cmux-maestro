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
