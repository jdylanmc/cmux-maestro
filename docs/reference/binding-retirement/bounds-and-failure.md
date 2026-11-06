# Bounds and failure

Part of [Hook-owned binding retirement](../binding-retirement.md). Previous page is [Coordination and durability](coordination-and-durability.md).

Each pass enumerates at most 4096 directory entries plus one overflow check,
selects at most 16 binding candidates (16 KiB each), and retains a dead survivor
per surface within that batch. A private filename cursor rotates batches;
it is a scheduling hint, never ownership evidence. Enumeration overflow skips
retirement, not reader discovery. Incomplete batches can leave extra dead
bindings. Cleanup is not a completeness guarantee. Permanent locks still
contribute directory entries.

At most two retirements are attempted per pass. Selection checks each candidate's
custody once; each retirement gets two further bounded 512-entry custody
inspections for itself and its survivor. All lock attempts
for retirement are nonblocking. Failures preserve evidence and publish a
bounded generic retirement status, separate from successful binding publication.
If that status write itself fails, the generic hook-status fallback explicitly
identifies `source: bindingRetirement`, not a failed binding write.
Each retirement rereads its candidate and survivor twice to fence concurrent
replacement. Those reads use the same 16 KiB record bound.

These are operation bounds, not a storage-latency guarantee. The existing
external hook timeout can interrupt a pass; no daemon, timer or retry finishes
it. Missing session directories deliberately remain a cleanup limitation:
reader admission can skip those dead owners, but retirement needs positive
access to inspect possible resumed custody. This change makes no claim to
reclaim every historical binding or restore directory-entry capacity.

Readers independently verify process, binding, routing and
replay evidence, skip dead owners for active capacity and retain content-free
ended presentation. A missing cached ended binding is forgotten without a
global identity-change warning, whether it disappears before the read or during
decoration before the final publication fence. Active binding disappearance and
changed/unsafe/unknown evidence retain existing diagnostics. Cleanup failure or
absence must never admit stale work or prevent a live session's discovery.
