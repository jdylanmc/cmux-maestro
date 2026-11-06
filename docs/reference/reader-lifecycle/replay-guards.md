# Reducer budget and replay guards

Part of [reader, lifecycle, and retention](../reader-lifecycle-and-retention.md). Previous page is [Bounded retention and discovery](bounded-retention.md). Next page is [Routing discovery and caches](routing-discovery.md).

- 256-row reducer budget retires oldest terminal **leaf**, not active,
  idle, blocked, or unknown work. Current-cycle error/abort outcomes protect their
  owners. Retained descendants, pending requests, and
  unresolved active ownership protect their ancestors. Agent row IDs stay stable
  across fresh lifecycles. Retirement does not permanently blacklist an agent ID.
  Completed tool ownership is reclaimed separately so the 4,096-relationship
  budget does not become next long-session bottleneck. Recent completed
  owners still support delayed parent joins. Retired joins stay unresolved.
  Retirement removes only retired owner's obsolete turn/activity/outcome
  records and joins. Signal dictionaries are bounded by retained owners plus
  primary owner. Tool ordering uses bounded retained-tool list.
  Request/tool-only unknown owners use event-scoped lifecycles, never permanent
  agent-ID tombstones.
- Spawn replay keys use spawn tool ID. Turn replay keys use owner +
  interaction ID + turn ID when interaction metadata is present, otherwise
  legacy owner + turn ID namespace.
  New spawn tool or previously unseen scoped turn is fresh activity, even for
  retained or retired terminal agent. Completions pair with row's current
  spawn, so late old completion cannot finish newer lifecycle. Turn alone
  recreates unknown agent, not invented old name/parent/spawn. Enriching an
  unknown row must not silently discard its pending requests.
- Work/lifecycle/tool/request replay keys keep up to 4,096 exact recent tombstones.
  Resolved-request keys include length-qualified owner, request kind and request
  ID. Spilling never collapses root/child or permission/answer namespaces.
  Older identities spill into deterministic 128-KiB replay filter. Its bits are
  never cleared within a transcript generation. This bounded filter has no false
  negatives, but can have false positives. Cold match rejects fresh admission
  **and reports `readLimitReached`**. It never claims exact replay knowledge.
  Terminal agent/root state fails open to unknown as described in
  [tool events and missing causal evidence](tool-events.md). Uncertain
  start-identity match does not demote live work.
  This also applies to uncertain tool-activity admission for terminal owner.
  Clearing obsolete terminal history does not acknowledge retained attention or
  resolve pending request.
  At half occupancy it fails closed. It never forgets history to admit more work.
  True active-capacity exhaustion also reports limit without fabricating
  completion. Transcript replacement reconstructs this state from new log.
