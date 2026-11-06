# Turn identity and causal bridging

[↑ Reader, lifecycle, and retention](../reader-lifecycle-and-retention.md) | [← Attention and safe activity](attention.md) | [Tool events and missing causal evidence →](tool-events.md)

Copilot reuses turn IDs such as `0` and `1` in later interactions. When supplied,
`data.interactionId` scopes accepted starts and replay protection together with
owner and turn ID. It is opaque, nonempty string bounded to 256 UTF-8 bytes.
It is not a counter or inferred user-message epoch. Retired interaction identities
use existing bounded replay guard. New primary interaction does not reset
still-running children or their pending requests.

Copilot also restarts the turn counter within the same interaction. A fresh
`assistant.turn_start` event UUID establishes a new occurrence in the current
interaction, even if its owner/interaction/turn tuple was already seen.
Exact event replays, retired interactions and uncertain replay-filter matches
still refuse. Repeated tuples require occurrence-specific causal proof:
matching interaction tags alone cannot anchor a message or end. Parent links
must reach the current start or causal tip; tool evidence must retain that
start's exact event UUID as its origin. A correctly tagged message may also
anchor through continuous session-wide parent links, including interleaved
background-owner events. Each active turn retains one extra envelope tip for
that continuity, not another owner's work evidence. That tip alone cannot
prove a turn end, tool origin or untagged message. Once a matching tagged
message or current-origin tool proves the occurrence, interleaved foreign
envelopes may carry that proven causal tip to its end. No unbounded graph is
retained. An accepted end establishes idle without a separate `session.idle`;
trailing hook and usage-checkpoint envelopes do not reopen work. Neither idle
nor those envelopes finish background children or outstanding tools.

End with explicit interaction ID must match current accepted owner
turn (and needs causal proof when the entire tuple repeats).
Ends without that field keep legacy pairing when turn identity is
unambiguous. For reused IDs, they need current causal parent or uniquely
matched tool completion whose start tied to current turn. Across ignored payload-bearing events, use only envelope
IDs/parent links. Never decode prompt,
arguments, results or message content for this. Tracking is
bounded to one causal tip and one envelope-continuity tip per active owner,
plus one origin per retained tool.
It is not an accumulated transcript graph.
Validate optional interaction/turn tags on `tool.execution_complete` against
its recorded tool origin. If no origin recorded, validate against current accepted owner turn.
Explicit contradictions cannot complete current work or advance its
causal tip. Matching tags do not create missing tool ownership.
