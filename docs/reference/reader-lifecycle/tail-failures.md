# Catch-up and tail failures

[↑ Reader, lifecycle, and retention](../reader-lifecycle-and-retention.md) | [← Routing discovery and caches](routing-discovery.md) | [Oversized assets, rerouting and fast retry →](oversized-and-rerouting.md)

- Capture fixed prefix length and observation time for each catch-up pass.
  Later appends do not extend that lease forever. Verified complete prefix may
  be published with its captured observation time and `loadingHistory` when
  newer bytes remain. This is not a current/complete snapshot. Verified current
  EOF uses verification time, including after multi-batch reconstruction on
  normal polling cadence. Torn or malformed
  prefixes cannot become fabricated complete evidence. Failed observation
  cannot pin every later session indefinitely.
- Tail failures are classified at the evidence boundary, not by error spelling
  (#332, ADR 0002). Once an exact binding and live process/marker evidence pass
  both sides of the read, `events.jsonl` replacement during a read (`changed`),
  a refused no-follow regular-file open (`unsafePath`), and a file permission
  denial belong to that session alone. Publish its issue and unknown state,
  without old work, children or visual status grace; healthy siblings remain
  current. A failed read retains private replay guards, not publication rights.
  A detected rotation, shrink or rewrite discards the previous projection and
  reconstructs only the new file generation. Until a verified complete boundary
  exists, that session carries `identityChanged` and remains unknown. A complete
  reconstruction can be published immediately.
  Session-directory refusal remains exact-session uncertainty under its
  independently revalidated binding; the directory name never establishes an
  owner. Shared session-root or binding-directory refusal/replacement, revoked
  binding/topology evidence, and a foreign or ambiguous source-header owner
  remain global barriers. The shared session root is revalidated before the
  batch escapes, including when a tail failed or only ended observations exist.
  An ended-only missing root must remain absent; recreation or refusal before
  publication invalidates that batch rather than fabricating confirmed death.
  Both live and ended-only cohorts retain the original root descriptor or
  absence witness through decoration and the final binding/owner fence.
  One shared publication check validates that witness after all those phases.
  Unchanged-file stat fast paths still emit the session's invalidated-projection
  issue. Skipping an open never restores publication rights.
  Retained reducer source faults remain global through later tail, marker or
  session-directory unavailability, even if a local failure has the same issue
  value. Under ADR 0002, losing access cannot repair a proven foreign owner.
  Only a verified file-generation rebuild or identity-bound tail retirement
  clears that retained evidence. A local refusal does neither.
  The same error at a shared
  boundary is not downgraded because a session was being read.
  Projected diagnostics may aggregate session permission failures, but names,
  managed-session correlation, placement caching and navigation use only the
  separately retained global access issues as a whole-tree permission barrier.
  This preserves ADR 0010: unavailable files never free active capacity or evict
  private replay evidence. Actual file-generation changes rebuild that evidence.
