# Hook-owned binding retirement

Issue #336, owner decision: preserve the newest verified-dead binding per
workspace/surface for ended-row presentation. Retire only superseded dead
bindings. This narrows cleanup, not reader correctness (ADR 0010).

## Authority and proof

Only an already successful session-start or prompt identity-binding hook may
run one retirement pass. Tool-use payloads do not run retirement.
Appearance and ownership-proof commands do not clean up. No install, daemon,
timer, process signal, terminal operation or adoption is involved.

A candidate must be a supported, owner-only, single-link regular binding with
an exact filename/session UUID. Its generation is the recorded session,
workspace, surface, owner PID and microsecond start time, not an inferred
orchestration generation. Only a process probe reporting that recorded owner
dead qualifies; PID reuse, unavailable probes and foreign owners survive.
Missing directories, file times and titles never establish death.

Retirement additionally requires the existing session directory and bounded
session-custody inspection to show no live or uncertain holder. Missing,
unsafe, unreadable or over-limit directories preserve the binding. Resume
before inspection therefore preserves the prior binding; resume afterwards
publishes its new binding through the normal session lock.

A strictly newer dead binding for the same workspace and surface must survive
the operation. `recordedAt` orders only already-proven dead bindings; equal
times retain both. Both bindings and their death/custody evidence are checked
again under their session locks. Rewrites, resumes and uncertainty cancel
retirement. The newest dead binding on each surface is never a candidate.

## Coordination and durability

Use the existing permanent per-session binding locks, plus a permanent
nonblocking retirement lock to serialize passes. Never remove any lock,
including binding, session-custody and install locks. Never truncate an install
lock. Retirement skips busy locks without waiting. Binding writers wait on
the existing session lock, bounded externally by Copilot's existing two-second
hook timeout; appearance/proof commands remain nonblocking. The writer
revalidates process, session-directory and custody evidence after acquiring
the lock. A later resume therefore publishes its new record after retirement,
without depending on an unrelated future hook. An externally timed-out hook
does not claim successful publication, and kernel locks release on its exit.
Existing hook versions use the same locks but skip contention: an old helper
already in flight during an update can still require a later hook to publish.
No live-session reload is triggered or required by installation.

All traversal is descriptor-relative, no-follow, same-user and permission
checked. Binding and archive files are mode 0600, directories 0700. Retirement
does not widen sidebar grants. Before unlinking the exact unchanged binding,
durably retain its canonical sanitized identity in `retired-bindings`, outside
reader discovery, under a digest of that record. Existing identical archives
are reused; conflicts or partial archives preserve the active binding.
Synchronize the integration root after creating the archive directory, then
the archive file and directory before unlinking the active binding.
The archive contains only the binding schema's identifiers, PID/start time
and recording time. No payloads, transcripts, credentials or paths.

Appearance, locations, Copilot session state, controller nodes/generation
history, resume commands and all locks remain untouched. Recovery remains
owned by the existing controller; an archive grants no resume/control authority.
An interrupted pass can leave an extra archive, never require guessing a
binding's identity. No archive retention/deletion policy is introduced here.

## Bounds and failure

Each pass enumerates at most 4096 directory entries plus one overflow check,
selects at most 16 binding candidates (16 KiB each), and retains a dead survivor
per surface within that batch. A private filename cursor rotates batches;
it is a scheduling hint, never ownership evidence. Enumeration overflow skips
retirement, not reader discovery. Incomplete batches can leave extra dead
bindings; cleanup is not a completeness guarantee. Permanent locks still
contribute directory entries.

At most two retirements are attempted per pass. Selection checks each candidate's
custody once; each retirement gets two further bounded 512-entry custody
inspections for itself and its survivor. All lock attempts
for retirement are nonblocking. Failures preserve evidence and publish a
bounded generic retirement status, separate from successful binding publication.
If that status write itself fails, the generic hook-status fallback explicitly
identifies `source: bindingRetirement`, not a failed binding write.
Each retirement rereads its candidate and survivor twice to fence concurrent
replacement; those reads use the same 16 KiB record bound.

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
