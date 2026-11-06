# Oversized assets, rerouting and fast retry

Part of [reader, lifecycle, and retention](../reader-lifecycle-and-retention.md). Previous page is [Catch-up and tail failures](tail-failures.md).

- Oversized `session.binary_asset` events keep bounded, validated outer
  envelope. Their opaque `data` object is discarded incrementally. Uploaded
  screenshots therefore cannot permanently invalidate later working/idle state.
  Root identity, type, parent-event metadata, duplicate-key rejection, nesting
  bounds and complete-record boundaries still apply. Other oversized events and
  malformed envelopes stay fail-closed. The 1 MiB retained-line limit is not raised.
- Binding rerouted during read is deliberately omitted, **not** returned
  with its superseded surface/session identity as ambiguous row. Other
  verified granted sessions stay visible. Snapshot reports
  `identityChanged` and is incomplete. Later stable read under new grant
  reconstructs that session, including when both surfaces were already granted.
  In contrast, unstable process/marker evidence with unchanged valid routing
  binding still produces content-free ambiguous row while retaining private replay
  guards for a later fully revalidated read. Timestamp-only hook
  refreshes preserve verified row but require stable discovery cycle
  before completeness. Reader tests cover all three distinct contracts and use
  `#require` before unwrapping expected observations.
- `hasPendingHistory` accelerates productive initial/changed-index discovery and
  admitted-tail deltas. Waiting for session capacity uses normal polling,
  not an endless fast retry loop.
  EOF, torn final lines, and warnings alone never request fast retry. No sandbox
  entitlement or ancestor traversal permission is broadened.

**Further presentation integration:** preserve this combined reducer's
accepted terminal UUID/timestamp, current-spawn/turn pairing, bounded event/start/
owner-qualified resolved-request guards, and `canPublishProjection` distinctions.
Retirement must keep cleaning obsolete turn/activity/outcome state without
discarding pending requests, unknown placeholders or required ancestors.
History presentation limits stay separate from ingestion limits. Prior
terminal dismissal cannot hide fresh lifecycle using same agent ID.
Carry finite reader watermarks, staged-binding revalidation, EOF freshness and
overflow scheduling together. Layout, installer and clarity changes must not
weaken quiet validation scene, backend setup denial, current-tree
acknowledgement guards, or host's 50-point footer clearance.
