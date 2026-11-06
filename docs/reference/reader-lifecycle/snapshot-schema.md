# Snapshot schema and validation

[↑ Reader, lifecycle, and retention](../reader-lifecycle-and-retention.md) | [← Conversion caches and acceptance](conversion-caches.md) | [Bounded retention and discovery →](bounded-retention.md)

Schema version stays 1. Optional observation fields preserve process liveness,
observation time, appearance, child kinds/models/outcome-event identities, issues
and completeness. Absent completeness field means unknown, not complete.
Legacy `state: done` keeps its meaning. Idle, failed and cancelled use
explicit `stateDetail` with unknown legacy state. Contradictory combinations
are invalid. Consumers resolve that pair once and keep process liveness separate.
Unavailable/degraded model or activity values cannot become current evidence.

Existing `childWork` property always keeps v1's strictly validated nested
meaning. Adapter derives old-compatible view of representable relations.
Unresolved components are omitted, never reparented. Additional typed
`childWorkObservation.items` preserves complete reader order and literal
edges, including late/missing parents and cycles. Its
`legacyProjectionIsLossless` flag explicitly records whether compatibility
view covers every observation. It does not claim complete provider history.
New consumers use this evidence when present. Never merge it with derived
compatibility view. Actual frozen v1 codec **and validator** are exercised
against original fixtures, ordinary/child-first pairs, missing parents and cycles.

Strict validation and live projection share per-observation structural and
cross-field checks before history filtering. Malformed ancestry stays unresolved.
Contradictory terminal evidence cannot hide work. Valid peer sessions survive.
Each graph assessment visits at most 4,096 nodes and 64 nesting levels. On a
limit, visited evidence stays partial, history actions are disabled for that
session, and omission counts are explicitly lower bounds with unknown totals.
Existing display caps stay 256 nodes and 12 levels. Legacy invalid parent
references still fail validation even when additional observation evidence exists.
Invalid child fields and compatibility disagreements fail history open for
their exact child identities, without degrading unrelated children (#269).
Consistency checks still run when either projection contains invalid peers.
Malformed inherited ancestry protects its descendants; duplicate or empty
identities protect their identifiable ancestor chains before row filtering.
Rejected duplicate, empty or foreign-owner identities also invalidate their
dependent descendants transitively, even when each descendant's own ID is unique.
Malformed parent references seed the same downward protection, even when the
child's own identity remains valid and unique.
A falsely lossless projection degrades unmatched observed children. A legacy
child absent from the observed projection, or a truncated legacy traversal,
cannot be attributed to a displayed row and keeps session-wide history fail-open.
Rejected identities with no identifiable child ancestor chain do the same.
Strict validation and partial-count reporting remain unchanged.

Reader identity, partial-read, corruption, freshness and replay-cap safeguards,
history/attention actions and exact host navigation stay unchanged. No PID,
process-start identity, raw provider payload, capability or control authority
is added. Saved identity still does not imply resume. Observed child has no
independent terminal. This literal #10 integration does not complete broader
#118 lifetime/control foundation. It does not change observation-hook policy.
