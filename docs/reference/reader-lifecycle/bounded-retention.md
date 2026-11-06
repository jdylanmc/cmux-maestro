# Bounded retention and discovery

Part of [reader, lifecycle, and retention](../reader-lifecycle-and-retention.md). Previous page is [Snapshot schema and validation](snapshot-schema.md). Next page is [Reducer budget and replay guards](replay-guards.md).

- Cold start and file-generation replacement start at the newest configured
  window, not byte zero of an unbounded log. **Event tail (MiB)** in sidebar
  settings persists in the existing human `UserDefaults` preferences: default 4,
  integers 1 to 64. Invalid stored input retains a visible validation notice and
  the default. An invalid edit is rejected without overwriting the saved value.
  Each poll obtains the current preference, without restarting the reader.
  An already admitted window never rewinds or backfills on growth or shrinkage.
  New/replaced tails and subsequent oversized unseen gaps use the changed value.
  When no window is in progress and unseen appended bytes exceed this bound,
  resume at the newest bounded tail instead of replaying the whole gap. Clear
  unproven projected state while retaining observed replay guards and faults.
- Omitted history remains session-scoped `readLimitReached`, even after reaching
  current EOF. No automatic backfill runs. Recent explicit lifecycle evidence
  establishes state; missing evidence stays unknown, with incomplete child
  history/counts. The initial cut line is discarded through its next newline,
  including when that newline arrives later. A separate first-line source check
  reads at most 4 KiB and requires an exact-session `session.start` as the first
  event; a malformed, foreign, unsupported or unverifiable header
  cannot produce current state. It does not seed model or work from the prefix.
  Process, binding, descriptor/path and rewrite/append witnesses remain checked.
  Payload reads keep the 8 MiB aggregate, 4 MiB per-session and 2,048-line limits;
  larger windows initialize over multiple polls. Fixed header and 128-byte
  prefix/anchor witnesses are separate bounded verification overhead.
- Current EOF revalidation reads zero event bytes. Appends consume only new
  bytes plus fixed witnesses. Already observed replay evidence is retained;
  the unseen prefix is explicitly outside the cold-start replay guarantee.
  See the owner-approved bounded-tail amendment in ADR 0010.
