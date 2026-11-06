# Projection reuse and publication

Part of [reader, lifecycle, and retention](../reader-lifecycle-and-retention.md). Previous page is [Activity and publication](activity-and-publication.md). Next page is [File-driven reader wakeups](reader-wakeups.md).

Unchanged polling reuses the structural sidebar projection (#321), not reader
identity checks. The key compares the complete typed content, keeping observation
freshness and envelope-validity classifications separate from the read-start and
post-read timestamps. Every accepted read still replaces the exact timestamps
and reconciles observation-loss memory. Topology, registration generation,
permissions, schema and stale/regressing envelope guards run before reuse.
Content/settings changes, clock rollback and time-dependent transitions rebuild
the projection. One-shot deadlines cover history expiry, future display times,
observation freshness and status grace. No extra timer polls the projection.
An over-limit deadline traversal disables reuse rather than ignoring evidence.

Publication compares the exact final reconciled tree, not intermediate trees.
Refreshed evidence timestamps invalidate observation subscribers even when visible
labels are unchanged: outline children retain value snapshots and may redraw
independently against the current clock. Suppressing timestamp-only publication
would leave those copies stale, hiding current status, session names and pets.
Exactly equal output still avoids invalidation. The structural projection cache
remains independent of publication. The fallback reader cadence remains two seconds; file-driven wakeups
are coalesced separately (#325). Installed CPU/change-to-pixel acceptance remains
a separate hosted check.
Beats liveness, born-root naming and external tag refresh consume a separate
bounded latest-evidence stream, independently of SwiftUI rendering.

Managed presentation has its own one-shot deadline, independent of Copilot reads
or notifications. It covers the earliest node/envelope and Git freshness boundary
(including future evidence entering the allowed window), and process observation
staleness/unavailability at 60/300 seconds. At the boundary it invalidates snapshot
presentation without changing evidence; branch summaries and hover actions
therefore recompute even when the snapshot bytes are identical or Copilot has no
sessions. Unchanged polls retain the deadline instead of postponing it, and a poll
that overtakes a due timer preserves its redraw. Visibility, topology, connection
changes and read failures cancel obsolete deadlines. No periodic view timer is
introduced.
