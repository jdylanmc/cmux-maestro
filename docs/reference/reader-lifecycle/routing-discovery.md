# Routing discovery and caches

Part of [reader, lifecycle, and retention](../reader-lifecycle-and-retention.md). Previous page is [Reducer budget and replay guards](replay-guards.md). Next page is [Catch-up and tail failures](tail-failures.md).

- Routing discovery resumes one descriptor-anchored directory stream across
  batches (up to 1,024 directory entries per batch, plus bounded revalidation of
  at most 64 cached identities and one staged granted binding). Historical locks
  and off-surface records cannot pin discovery to a prefix. Retain at most 64 transcript
  tails. Admitted live or uncertain owners keep their slots after publication.
  Current routing revalidation releases a verified-dead owner's slot. Discovery
  checks owner death before admission, without requiring a session directory;
  historical dead bindings therefore never fill active capacity. Missing files
  or unavailable probes alone cannot establish owner death. Discovery
  stages at most one next binding while capacity is full, with an explicit
  limit warning. Additional sessions remain unavailable until an admitted owner
  is verified dead or a selection/binding change frees capacity. Live/uncertain
  replay evidence is never evicted for them.
  A binding whose owner is alive but whose session lock moved to that owner's
  direct child (Copilot `/restart`, `/update`) verifies alive under the child,
  read-only, until the hook rebinds it. Identity evidence names the child, so a
  changed holder fails the post-read stability fence. Any other live owner
  without its own marker remains ambiguous (see
  [in-place restart handoff](../trust-boundary-and-observation/in-place-restart-handoff.md)).
  Content-free ended observations use a separate cache: newest proven-dead
  binding owner per selected surface, at most `maximumBindings` entries. Each
  emitted row revalidates its binding and owner; missing session directories do
  not suppress proven death, while conflicting live markers remain ambiguous.
  This cache holds no transcript/replay state and cannot consume active slots.
  Binding timestamps select among already verified ended candidates only.
  It preserves **Show ended agents**, **Process ended**, Beats ended styling
  and dead-status retention. Cache overflow reports `readLimitReached`.
  Only full, unchanged, non-overflowed cycle without errors can be complete.
  Check cached bindings before process/transcript access and publication.
  Discovery restarts, cancellation and unrelated topology changes retain private
  tails for still-selected bindings, never cached publication. Revoked bindings
  or selections discard their exact tails. Directory replacement requires current
  routing revalidation before any process/transcript access or publication.
  EOF, errors, cancellation, and destruction close the directory stream.
- Decoded routing metadata has a separate cache of at most 1,024 records
  (`maximumBindings`), including off-surface records already read by discovery.
  Every reuse requires a descriptor-relative, no-follow file stat matching
  device, inode, birth time, owner, mode, size, and nanosecond modification/change
  times. Directory timestamps alone never establish unchanged contents.
  Changed files take the full owner/mode, bounded decode and before/after
  descriptor/path verification path. Failures discard the cached entry.
  Completed stable discovery prunes unseen entries, and discovery reset clears
  the cache. Cache capacity never limits discovery or grants authority: uncached
  entries take the full read path. Current surface grants, process/marker
  evidence and pre-publication routing/directory fences still run every poll.
