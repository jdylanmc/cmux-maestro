# Coordination and durability

Part of [Hook-owned binding retirement](../binding-retirement.md). Previous page is [Authority and proof](authority-and-proof.md). Next page is [Bounds and failure](bounds-and-failure.md).

Use the existing permanent per-session binding locks, plus a permanent
nonblocking retirement lock to serialize passes. Never remove any lock,
including binding, session-custody and install locks. Never truncate an install
lock. Retirement skips busy locks without waiting. Binding writers wait on
the existing session lock, bounded externally by Copilot's existing two-second
hook timeout. Appearance/proof commands remain nonblocking. The writer
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
reader discovery, under the SHA-256 of that record's exact canonical bytes.
Synchronize the integration root after creating the archive directory. Write
the record to a unique `.pending-archive-<pid>-<start s>-<start µs>-<uuid>`
file, verify the full write and fsync it. Then publish it under the digest
name with an exclusive rename (`RENAME_EXCL`) that never replaces an entry,
and fsync the directory before unlinking the active binding. A writer killed
or failing mid-write therefore never leaves a partial digest file.

An existing digest entry with identical bytes is reused. The name commits to
the content, so an existing owner-only, single-link regular entry whose bytes
do not hash to its name cannot be a complete archive. Such an entry is empty,
truncated or corrupt, for example from an earlier helper's in-place write. The
verified pending file atomically replaces it. Different bytes that do hash to
the name (a SHA-256 collision) refuse. Symlinks, extra links, wrong owner or
mode, and unstable or oversized entries refuse. Refusal preserves the active
binding.

Each retirement pass also removes at most eight pending files whose writer is
proven exited: the probe reports it dead, or the same PID has a different
recorded start time. Live, unavailable or unidentified writers keep theirs.
Pending files never block publication, and published archives are never swept.
The archive contains only the binding schema's identifiers, PID/start time
and recording time. No payloads, transcripts, credentials or paths.

Appearance, locations, Copilot session state, controller nodes/generation
history, resume commands and all locks remain untouched. Recovery remains
owned by the existing controller. An archive grants no resume/control authority.
An interrupted pass can leave an extra archive, never require guessing a
binding's identity. No archive retention/deletion policy is introduced here.
