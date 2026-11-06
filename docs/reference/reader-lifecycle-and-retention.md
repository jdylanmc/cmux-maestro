# Reader, lifecycle, and retention

How the Copilot reader turns session logs into attention, turn lifecycle and
retained history, and the bounds that keep it safe. Short version:
[README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

## Attention and safe activity

- [Attention and safe activity](reader-lifecycle/attention.md)
- [Turn identity and causal bridging](reader-lifecycle/turn-identity.md)
- [Tool events and missing causal evidence](reader-lifecycle/tool-events.md)
- [Retention protection and acknowledgements](reader-lifecycle/acknowledgements.md)
- [Activity and publication](reader-lifecycle/activity-and-publication.md)
- [Projection reuse and publication](reader-lifecycle/projection-reuse.md)

### File-driven reader wakeups

- [File-driven reader wakeups](reader-lifecycle/reader-wakeups.md)
- [Conversion caches and acceptance](reader-lifecycle/conversion-caches.md)
- [Snapshot schema and validation](reader-lifecycle/snapshot-schema.md)

### Bounded retention and discovery

- [Bounded retention and discovery](reader-lifecycle/bounded-retention.md)
- [Reducer budget and replay guards](reader-lifecycle/replay-guards.md)
- [Routing discovery and caches](reader-lifecycle/routing-discovery.md)
- [Catch-up and tail failures](reader-lifecycle/tail-failures.md)
- [Oversized assets, rerouting and fast retry](reader-lifecycle/oversized-and-rerouting.md)
