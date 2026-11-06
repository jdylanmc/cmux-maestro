# Retention protection and acknowledgements

[↑ Reader, lifecycle, and retention](../reader-lifecycle-and-retention.md) | [← Tool events and missing causal evidence](tool-events.md) | [Activity and publication →](activity-and-publication.md)

Outstanding attention protects rows from history retention and dismissal.
Acknowledging an error/abort lets ordinary history retention apply again.
Required parent context and current blocking descendants remain visible. No
timer auto-acknowledges anything, and history and acknowledgement resets are
independent. Nonblocking notices are marked read when their tab is focused
successfully or their details open, with no separate acknowledgement button. A
confirmed host focus transition also marks that tab read. Initial mount,
passive polling, hover, expansion and failed/cancelled navigation do not.
Sidebar focus captures the notices present at click and revalidates them after
host acceptance, so a stale click never clears later notices or changed
blockers. The menu keeps **Mark all nonblocking notices as read** as an
explicit fallback.

Explicit child dismissals key on exact session/child/terminal-event identity,
and managed failure dismissals on node/generation/phase. These history fields
share the 2,048-entry / 1 MiB limit, survive reloads, and never hide a new
generation or completion event. **Restore dismissed history** clears these read
dismissals. Marking a notice read never dismisses its failed row. The reader
also protects current-cycle outcome owners from terminal-leaf retirement. Local
acknowledgement changes presentation, not the provider's ingestion state. A
verified new primary turn or fresh owner activity decides when earlier
nonblocking signals are obsolete. Genuine active/attention capacity exhaustion
reports partial data and never drops protected signals. Unknown lifecycle data
or replay-filter saturation can invalidate current activity but cannot silently
acknowledge already-recorded outcomes or requests.

Acknowledgements persist by provider-session UUID, owner ID (or primary owner),
source and stable accepted event UUID. Labels, paths, tool payloads and
topology are not keys. The same outcome remains acknowledged after reload or
surface moves, and a new outcome reappears. The version-2 exact-key archive
groups accepted event UUIDs by session UUID and owner (an empty owner is the
primary owner), and the schema fixes the source to `copilot.events`. It keeps
every key, including absent sessions, with no age, topology or tail-window
eviction. Storage is bounded to **20,480 acknowledgements / 4 MiB**, and long
owner identifiers can reach the byte cap first. Overflowing batches are refused
without eviction, and the warning offers **Reset acknowledgements** directly.
Reset clears every saved acknowledgement, so earlier read notices may reappear,
including after source replay. Corruption fails open with a visible warning:
unreadable settings hide no attention.

Acknowledgements use the same coordinated action store as history, in the
separate extension-container Application Support file
`CMUXMaestroPreview/sidebar-attention.json`. Acknowledge unions only the current
projection's eligible identities into the latest on-disk record. Other windows
and processes see changes automatically without polling. Reset clears
acknowledgements at its coordinated turn and never clears history or the
selected view. Later acknowledgements remain later actions, not restored stale
snapshots.

The old `sidebar.attention.v1` defaults record is validated and imported once
under the same lock, and the file is authoritative after that. The legacy key is
removed only after successful persistence and read. Valid version-1
files/defaults keep their original 2,048-record / 1 MiB validation limits and
migrate losslessly inside the next successful acknowledgement action. Reads
alone do not rewrite them, and a failed action leaves the original bytes
intact. Version 2 uses the same file and coordination, so migration, union and
reset need no cross-file commit. Older app versions cannot read version 2 and
fail open. Do not reset from an older version if the retained acknowledgements
are needed. Corrupt or future-schema files and legacy data fail open, and
ordinary acknowledgement actions leave them untouched; only **Reset
acknowledgements** replaces them. Failed migration keeps legacy data for retry.
Tests inject both history and acknowledgement files.
