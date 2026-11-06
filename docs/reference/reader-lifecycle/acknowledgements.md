# Retention protection and acknowledgements

Part of [reader, lifecycle, and retention](../reader-lifecycle-and-retention.md). Previous page is [Tool events and missing causal evidence](tool-events.md). Next page is [Activity and publication](activity-and-publication.md).

Outstanding attention protects rows from history retention and dismissal.
Acknowledging error/abort then lets ordinary history retention apply.
Required parent context and current blocking descendants stay visible. No timer
auto-acknowledges anything. History and acknowledgement resets are independent.
Nonblocking notices are marked read when their tab is successfully focused or
their details are opened. No separate acknowledgement button. Confirmed
host focus transition also marks that tab read. Initial mount, passive polling,
hover, expansion and failed/cancelled navigation do not. Sidebar focus captures
notices present at click and revalidates them after host acceptance. Stale click
never clears later notices or changed blockers.
Menu keeps **Mark all nonblocking notices as read** as explicit fallback.
Explicit child dismissals key on exact session/child/terminal-event identity.
Managed failure dismissals use node/generation/phase. These history fields share
the existing 2,048-entry / 1 MiB limit, survive reloads, and never hide a new
generation or completion event. **Restore dismissed history** clears these read
dismissals. Marking notice read never dismisses its failed row.
Reader also protects current-cycle outcome owners from terminal-leaf
retirement. Local acknowledgement changes presentation, not provider's
ingestion state. Verified new primary turn or fresh owner activity establishes
when prior nonblocking signals are obsolete. Genuine active/attention capacity
exhaustion reports partial data. It never drops protected signals.
Unknown lifecycle data or replay-filter saturation can invalidate current
activity. It cannot silently acknowledge already-recorded outcomes or requests.

Acknowledgements persist by provider-session UUID, owner ID (or primary owner),
source and stable accepted event UUID. Labels, paths, tool payloads and topology
are not keys. Same outcome stays acknowledged after reload or surface
moves. New outcome reappears. The version-2 exact-key archive groups accepted
event UUIDs by session UUID and owner (empty owner denotes the primary owner);
the schema fixes the source to `copilot.events`. It retains every key, including
absent sessions, with no age, topology, or tail-window eviction.
Storage is bounded to **20,480 acknowledgements / 4 MiB**. Long owner identifiers
can reach the byte cap first. It refuses overflowing batches without eviction and
offers **Reset acknowledgements** directly in the warning. Reset clears every
saved acknowledgement; previously read notices may reappear, including after
source replay. Corruption fails open with visible warning:
unreadable settings hide no attention.

Acknowledgements use same coordinated action store as history, in the
separate extension-container Application Support file
`CMUXMaestroPreview/sidebar-attention.json`. Acknowledge unions only the
current projection's eligible identities into latest on-disk record.
Other windows/processes observe changes automatically without polling. Reset
clears acknowledgements at its coordinated turn. It never clears history or selected
view. Later acknowledgements stay later actions, not restored stale snapshots.

Validate old `sidebar.attention.v1` defaults record and import it once
under same lock. File is authoritative after that. Remove legacy key
only after successful persistence/read. Valid version-1 files/defaults retain
their original 2,048-record / 1 MiB validation limits and migrate losslessly
inside the next successful acknowledgement action. Reads alone do not rewrite
them. A failed action leaves the original bytes intact. Version 2 uses the same
file and coordination, so migration, union and reset need no cross-file commit.
Older app versions cannot read version 2 and fail open; do not reset from an older
version if the retained acknowledgements are needed.
Corrupt or future-schema files
and legacy data fail open. Ordinary acknowledgement
actions leave them untouched. Only **Reset acknowledgements** replaces them. Failed migration keeps
legacy data for retry. Tests inject both history and acknowledgement files.
