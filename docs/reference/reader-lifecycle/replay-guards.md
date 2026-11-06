# Reducer budget and replay guards

[↑ Reader, lifecycle, and retention](../reader-lifecycle-and-retention.md) | [← Bounded retention and discovery](bounded-retention.md) | [Routing discovery and caches →](routing-discovery.md)

- The 256-row reducer budget retires the oldest terminal **leaf**, not active,
  idle, blocked, or unknown work. Current-cycle error/abort outcomes protect their
  owners. Retained descendants, pending requests, and
  unresolved active ownership protect their ancestors. Agent row IDs remain stable
  across fresh lifecycles, and retirement does not permanently blacklist an agent
  ID.
  Completed tool ownership is reclaimed separately so the 4,096-relationship
  budget does not become the next long-session bottleneck. Recent completed
  owners still support delayed parent joins, and retired joins remain unresolved.
  Retirement removes only the retired owner's obsolete turn/activity/outcome
  records and joins. Signal dictionaries are bounded by retained owners plus
  primary owner, and tool ordering uses a bounded retained-tool list.
  Request/tool-only unknown owners use event-scoped lifecycles, never permanent
  agent-ID tombstones.
- Spawn replay keys use spawn tool ID. Turn replay keys use owner +
  interaction ID + turn ID when interaction metadata is present, otherwise
  legacy owner + turn ID namespace.
  A new spawn tool or previously unseen scoped turn is fresh activity, even for a
  retained or retired terminal agent. Completions pair with the row's current
  spawn, so a late old completion cannot finish a newer lifecycle. A turn alone recreates an unknown agent without inventing an old
  name/parent/spawn. Enriching an
  unknown row must not silently discard its pending requests.
- Work/lifecycle/tool/request replay keys keep up to 4,096 exact recent tombstones.
  Resolved-request keys include length-qualified owner, request kind and request
  ID. Spilling never collapses root/child or permission/answer namespaces.
  Older identities spill into a deterministic 128-KiB replay filter whose bits
  are never cleared within a transcript generation. The filter has no false
  negatives but can have false positives. A cold match rejects fresh admission
  **and reports `readLimitReached`**. It never claims exact replay knowledge.
  Terminal agent/root state fails open to unknown as described in
  [tool events and missing causal evidence](tool-events.md). An uncertain
  start-identity match, or uncertain tool-activity admission for a terminal
  owner, does not demote live work. Clearing obsolete terminal history does not
  acknowledge retained attention or resolve a pending request. At half occupancy
  the filter fails closed and never forgets history to admit more work. True
  active-capacity exhaustion also reports the limit without fabricating
  completion. Transcript replacement rebuilds this state from the new log.
