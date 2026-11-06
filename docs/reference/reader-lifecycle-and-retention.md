# Reader, lifecycle, and retention

How the Copilot reader turns session logs into attention, turn lifecycle and
retained history, and the bounds that keep it safe. Short version:
[README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

## Attention and safe activity

Requests, questions, outcomes and **Turn finished** stay separate from process
liveness and work state.

- [Attention and safe activity](reader-lifecycle/attention.md): permission
  requests, questions, the needs-attention count and **Turn finished**.
- [Turn identity and causal bridging](reader-lifecycle/turn-identity.md):
  reused turn IDs, interaction IDs and owner matching.
- [Tool events and missing causal evidence](reader-lifecycle/tool-events.md):
  tool-associated events, ambiguous turns and bounded nonblocking evidence.
- [Retention protection and acknowledgements](reader-lifecycle/acknowledgements.md):
  what outstanding attention protects and how acknowledgements persist.
- [Activity and publication](reader-lifecycle/activity-and-publication.md):
  allowlisted tool activity and live polling reads.
- [Projection reuse and publication](reader-lifecycle/projection-reuse.md):
  structural projection reuse, publication and managed deadlines.

### File-driven reader wakeups

- [File-driven reader wakeups](reader-lifecycle/reader-wakeups.md): exact
  watched directories, bounded bursts and the two-second fallback.
- [Conversion caches and acceptance](reader-lifecycle/conversion-caches.md):
  conversion and child-assessment caches, hover-card resolution and the local
  callback acceptance tests.
- [Snapshot schema and validation](reader-lifecycle/snapshot-schema.md):
  schema version 1, optional observation fields and strict validation.

### Bounded retention and discovery

- [Bounded retention and discovery](reader-lifecycle/bounded-retention.md):
  the configurable event tail, omitted history and EOF revalidation.
- [Reducer budget and replay guards](reader-lifecycle/replay-guards.md): the
  256-row budget, replay keys, tombstones and the replay filter.
- [Routing discovery and caches](reader-lifecycle/routing-discovery.md):
  directory-stream discovery, active slots and the routing metadata cache.
- [Catch-up and tail failures](reader-lifecycle/tail-failures.md): catch-up
  leases and how tail failures are classified.
- [Oversized assets, rerouting and fast retry](reader-lifecycle/oversized-and-rerouting.md):
  binary assets, rerouted bindings, `hasPendingHistory` and further
  presentation integration.
