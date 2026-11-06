# Snapshot schema and validation

[↑ Reader, lifecycle, and retention](../reader-lifecycle-and-retention.md) | [← Conversion caches and acceptance](conversion-caches.md) | [Bounded retention and discovery →](bounded-retention.md)

The schema version stays 1. Optional observation fields carry process liveness,
observation time, appearance, child kinds/models/outcome-event identities,
issues and completeness. An absent completeness field means unknown, not
complete. Legacy `state: done` keeps its meaning. Idle, failed and cancelled
use explicit `stateDetail` with an unknown legacy state, and contradictory
combinations are invalid. Consumers resolve that pair once and keep process
liveness separate. Unavailable or degraded model or activity values cannot
become current evidence.

The `childWork` property always keeps v1's strictly validated nested meaning.
The adapter derives an old-compatible view of representable relations and omits
unresolved components instead of reparenting them. Additional typed
`childWorkObservation.items` keep complete reader order and literal edges,
including late/missing parents and cycles. Its `legacyProjectionIsLossless` flag
records whether the compatibility view covers every observation; it does not
claim complete provider history. New consumers use this evidence when present
and never merge it with the derived compatibility view. The frozen v1 codec
**and validator** are exercised against original fixtures, ordinary/child-first
pairs, missing parents and cycles.

Strict validation and live projection share per-observation structural and
cross-field checks before history filtering. Malformed ancestry remains
unresolved, contradictory terminal evidence cannot hide work, and valid peer
sessions survive. Each graph assessment visits at most 4,096 nodes and 64
nesting levels. At a limit, visited evidence stays partial, history actions are
disabled for that session, and omission counts are explicit lower bounds with
unknown totals. Display caps remain 256 nodes and 12 levels. Legacy invalid
parent references still fail validation even with additional observation
evidence.

Invalid child fields and compatibility disagreements fail history open for
their exact child identities without degrading unrelated children (#269).
Consistency checks still run when either projection contains invalid peers.
Malformed inherited ancestry protects its descendants. Duplicate or empty
identities protect their identifiable ancestor chains before row filtering.
Rejected duplicate, empty or foreign-owner identities also invalidate their
dependent descendants transitively, even when each descendant's own ID is
unique, and malformed parent references seed the same downward protection even
when the child's own identity is valid and unique. A falsely lossless
projection degrades unmatched observed children. A legacy child absent from the
observed projection, or a truncated legacy traversal, cannot be attributed to a
displayed row and keeps session-wide history fail-open, as do rejected
identities with no identifiable child ancestor chain. Strict validation and
partial-count reporting are unchanged.

Reader identity, partial-read, corruption, freshness and replay-cap safeguards,
history/attention actions and exact host navigation are unchanged. No PID,
process-start identity, raw provider payload, capability or control authority
is added. Saved identity still does not imply resume, and an observed child has
no independent terminal. This literal #10 integration does not complete the
broader #118 lifetime/control foundation or change observation-hook policy.
