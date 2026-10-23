# Reader, lifecycle, and retention

Attention, turn lifecycle, replay guards, reader contract, retention, discovery. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

## Attention and safe activity

Both views split permission requests from questions. Each shows on the session or child
that owns the durable request. Pending question = in-flight `ask_user` call (current Copilot builds emit no `user_input.requested` event).
Show it as slowly pulsing light-blue question-mark badge plus matching row tint. No text label. No error
color. Permission request keeps its **Waiting for permission** line. Pairing uses request kind,
owner and request ID. Completion for another owner or kind cannot clear it.
Hook-resolved permissions do not block. Repeated/late request identities cannot
reopen resolved request. Rejected stale abort/error evidence cannot erase a
newer request. Missing ancestry stays explicitly unresolved.
Independent requests have no clock order between them. Delayed
question stays pending even if a different permission has a newer timestamp.
Hook resolution uses exact kind/owner/request identity. This holds even when it
arrives after another request or a new turn.

Compact **needs attention** count on collapsed branches includes outstanding requests
and nonblocking outcomes. Header and workspace rows add no separate needs-input line. **Acknowledge** records only the latter locally in the
native sidebar. **Acknowledge all** uses current-window projection. It includes
collapsed branches. It excludes off-window or display-capped rows. Owner
with pending request is never eligible, even with an outcome.
Acknowledgement, history dismissal and focus never send approval, answers,
cancellation or any agent-control command. CMUX unread counts stay untouched.

**Turn finished** = matching primary `assistant.turn_end` recorded.
It does not mean session or background children finished. Show it as checkmark
state badge on idle session, no separate text line (accessibility label
stays "Turn finished"). Root errors/aborts
likewise do not end or unblock unrelated children. Process liveness, work state
and attention stay independent. Process presence, idle time, file modification
time and expired history never imply success, progress, or hung agent.

Copilot reuses turn IDs such as `0` and `1` in later interactions. When supplied,
`data.interactionId` scopes accepted starts and replay protection together with
owner and turn ID. It is opaque, nonempty string bounded to 256 UTF-8 bytes.
It is not a counter or inferred user-message epoch. Retired interaction identities
use existing bounded replay guard. New primary interaction does not reset
still-running children or their pending requests.

Copilot also restarts the turn counter within the same interaction. A fresh
`assistant.turn_start` event UUID establishes a new occurrence in the current
interaction, even if its owner/interaction/turn tuple was already seen.
Exact event replays, retired interactions and uncertain replay-filter matches
still refuse. Repeated tuples require occurrence-specific causal proof:
matching interaction tags alone cannot anchor a message or end. Parent links
must reach the current start or causal tip; tool evidence must retain that
start's exact event UUID as its origin. No extra history or unbounded graph is
retained. An accepted end establishes idle without a separate `session.idle`;
trailing hook and usage-checkpoint envelopes do not reopen work. Neither idle
nor those envelopes finish background children or outstanding tools.

End with explicit interaction ID must match current accepted owner
turn (and needs causal proof when the entire tuple repeats).
Ends without that field keep legacy pairing when turn identity is
unambiguous. For reused IDs, they need current causal parent or uniquely
matched tool completion whose start tied to current turn. Across ignored payload-bearing events, use only envelope
IDs/parent links. Never decode prompt,
arguments, results or message content for this. Tracking is
bounded to one causal tip per active owner and one origin per retained tool.
It is not an accumulated transcript graph.
Validate optional interaction/turn tags on `tool.execution_complete` against
its recorded tool origin. If no origin recorded, validate against current accepted owner turn.
Explicit contradictions cannot complete current work or advance its
causal tip. Matching tags do not create missing tool ownership.

All tool-associated events are excluded from generic parent bridging. This includes tool-backed subagent events and unjoined
shell notifications.
Accepted tool starts, completions and partial results advance causal tip only
through known tool whose recorded origin is current accepted owner turn.
Later `parentId` cannot replace old or missing origin, even when tags
are nil or raw turn ID matches. Partial results decode only bounded optional
tool/turn/interaction metadata, never output content. Matching current partial
may advance the single tip. It does not change work state or manufacture an
outcome. Non-tool envelope bridges keep bounded current-parent behavior.

Missing/gapped causal evidence for reused nil-interaction end yields
`ambiguousTurn` and unknown primary state, not fabricated completion. Pending
requests and background work survive. Later proven end can recover the
current outcome. Observed ambiguity keeps that transcript projection partial.
Explicitly mismatched ends and exact old event replays cannot close the new turn.
Contradictory clocks on proven match keep identity with unknown timing.
Legacy-only streams keep existing replay behavior. Missing interaction
metadata cannot silently reinterpret already-used explicit turn identity.
This metadata-only reader cannot tell provider record wrongly labeled or parented as current
from current evidence.

Normal tool failure may coexist with **Turn finished** and idle primary turn.
Accepted primary `session.error` or `abort` keeps its existing failed/cancelled
policy instead. Do not relabel it as normal turn completion. Fresh accepted
interaction can then establish working state.

Outstanding nonblocking evidence is intentionally bounded: only latest
accepted error/abort outcome per owner, plus latest primary-turn completion.
Successful historical child completions are history, not attention. Fresh
owner turn/tool/invocation activity retires that owner's obsolete outcome. New
primary turn begins new outcome cycle for session and its children.
It does **not** resolve their still-pending requests. Resume invalidates prior
activity/attention and demotes nonterminal children to unknown. It never
claims pre-resume background work completed. Accepted terminal child
evidence stays available to history controls. Duplicate/retired lifecycle
identities cannot restart attention or its timing.

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
moves. New outcome reappears. Storage is versioned and bounded to **2,048
acknowledgements / 1 MiB**. It refuses overflowing batches without eviction and
offers **Reset acknowledgements**. Corruption fails open with visible warning:
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
only after successful persistence/read. Corrupt or future-schema files
and legacy data fail open. Ordinary acknowledgement
actions leave them untouched. Only **Reset acknowledgements** replaces them. Failed migration keeps
legacy data for retry. Tests inject both history and acknowledgement files.

Activity uses only allowlisted durable tool-name field: **Executing tool**
(latest still-executing invocation for that owner) or **Last completed tool**.
Latter is a tool-invocation event, not a statement that a detached shell
process exited. Child attribution requires real event ownership. Names must be
bounded symbolic identifiers. Never decode arguments, results, prompts or raw errors
for display. Invalid/missing/future timing is explicitly unknown.
Never replace timestamps with poll time. No token/context counters, guessed
percentages or speculative stall detection implemented.
Lifecycle acceptance never depends on current read clock. Tool and turn
completions pair with their own active invocation/owner identities. Contradictory
start/completion timestamps keep completed evidence with **unknown timing**.
They never resurrect executing work on later replay. Validate observation freshness
and future display timestamps separately in sidebar projection.
Display times and retention deadlines accept timestamps through the snapshot's
post-read `generatedAt`, not the session's read-start `observedAt`, and never
after the current display clock. Session freshness still uses `observedAt`.
Missing tool ownership never creates error or executing activity. Bounded
completion tombstone prevents later start from resurrecting that invocation.
Delayed tool metadata for already-ended spawn cannot reopen its owner.
Tool starts classify their start, completed-tool and shell-row replay aliases
together before mutating owner metadata. Exact match = no-op. Uncertainty
in **any** alias fails terminal history open without changing live owner.
Legacy shell-row alias stays checked even for non-shell tool names. This keeps
global tool-ID replay protection conservative across metadata/name differences.
Both ordinary tool and actual shell starts have selective-alias regressions.

Live `SidebarCopilotPolling.Read` and projection consume existing
`Domain/AgentSessionSnapshot.swift` contract through pure
`CopilotSnapshotAdapter`. `CopilotSessionReader` still owns bounded provider
parsing. Only caller's granted current host topology establishes a binding.
Launch workspace/surface evidence is separate. It cannot create current topology.
Activity and attention reuse `Domain/AgentSignals.swift`. These shared types
compile into app, sidebar and tests, not the hook.

Unchanged polling reuses the structural sidebar projection (#321), not reader
identity checks. The key compares the complete typed content, keeping observation
freshness and envelope-validity classifications separate from the read-start and
post-read timestamps. Every accepted read still replaces the exact timestamps
and reconciles observation-loss memory. Topology, registration generation,
permissions, schema and stale/regressing envelope guards run before reuse.
Content/settings changes, clock rollback and time-dependent transitions rebuild
the projection. One-shot deadlines cover history expiry, future display times,
observation freshness and status grace; no extra timer polls the projection.
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

### File-driven reader wakeups

While visible and connected, the Copilot reader watches only the exact directories
of sessions shown (including retained-status rows) or bound on its current
topology, capped at the reader's 64-session limit. One FSEvents stream covers those
directories; a non-recursive directory-vnode source covers atomic changes in the
bindings directory. The whole session-state and integration roots are never watched.
Other sessions and unmonitored integration changes use the two-second fallback.
The managed reader watches only the exact orchestration `observer` directory.
Recursive session events include nested appends and atomic replacements.
Registration securely validates the roots;
callbacks never inspect event paths or read contents. Events only request the
existing fully fenced reader, never establish identity or freshness themselves.
Shown/bound-set changes replace the registration and request one catch-up read
to cover the registration gap. Events from a retired subscription are discarded.
Ordinary binding-directory `.write` events only wake the reader: they do not
finish the stream, re-register session roots or log watcher retirement. Only
directory `.rename`, `.delete` or `.revoke` ends that lease. The deterministic
registration-count test drives this same callback policy, including combined flags.

A newest-one stream and one pending-change flag bound bursts and changes during
an in-flight read. The first notification opens a cancellable 200 ms coalescing
window, not a trailing debounce that continuous activity could postpone forever.
No reads overlap, including during topology replacement: the obsolete worker and
watcher unwind before a new scope starts. Visibility/connection/scope cancellation
stops the stream, fallback wait and coalescing task; independent deadline timers
retain their existing ownership.

The existing two-second fallback is slower than notification delivery and is
not shortened. Missing, unsafe or unsupported roots log a sanitized warning and
retain polling. Root replacement, unmount or event-loss flags end the old stream,
request a fully fenced read, and securely re-register at the next reader wakeup.
Missing session directories are excluded when registering, with a sanitized
notice, while the bindings directory and healthy session watches stay active.
Those excluded sessions use fallback reads until a later scope/lease registration;
an unchanged healthy lease does not repeatedly attempt to open missing paths.
Unsafe or denied roots still refuse registration rather than being treated as missing.
Failed registration is retried only on the existing read cadence, with no extra
timer or repeated warning while unavailable. Healthy streams do not reopen
roots on each poll. Sandbox entitlements and source read/size bounds do not change.

The three native callback tests are inventoried local opt-in acceptance in
`scripts/local-ui-acceptance.json`, enabled with
`CMUX_MAESTRO_LOCAL_UI_ACCEPTANCE=1 ./scripts/test.sh --focused SidebarFileWatcherAcceptanceTests`.
OS daemon/vnode scheduling is not a deterministic required-CI dependency. Required
tests inject event delivery into the production registration plan, including
30,000 events under 1,000 non-shown directories over a controlled 60-second
schedule: zero event-driven reads, 30 fallback reads (0.5/s after initial discovery).
That is a deterministic work count, not a wall-clock throughput or CPU measurement.
No timing allowlist exception is added or hidden by the opt-in inventory.
Native callback and controlled-clock tests are not installed ExtensionKit proof.
After authorized installation, measure idle CPU with
`python3 scripts/measure-sidebar-cpu.py --pid <exact-extension-pid> --output <new-private-directory>`.
Compare matched workloads before/after (target <=2% idle CPU). For latency, use
only a generic hosted fixture and record durable-change time to the first matching
pixel/accessibility update, including sample count/distribution. The coordinator
owns these acceptance checks; no production install is part of this change.

Schema version stays 1. Optional observation fields preserve process liveness,
observation time, appearance, child kinds/models/outcome-event identities, issues
and completeness. Absent completeness field means unknown, not complete.
Legacy `state: done` keeps its meaning. Idle, failed and cancelled use
explicit `stateDetail` with unknown legacy state. Contradictory combinations
are invalid. Consumers resolve that pair once and keep process liveness separate.
Unavailable/degraded model or activity values cannot become current evidence.

Existing `childWork` property always keeps v1's strictly validated nested
meaning. Adapter derives old-compatible view of representable relations.
Unresolved components are omitted, never reparented. Additional typed
`childWorkObservation.items` preserves complete reader order and literal
edges, including late/missing parents and cycles. Its
`legacyProjectionIsLossless` flag explicitly records whether compatibility
view covers every observation. It does not claim complete provider history.
New consumers use this evidence when present. Never merge it with derived
compatibility view. Actual frozen v1 codec **and validator** are exercised
against original fixtures, ordinary/child-first pairs, missing parents and cycles.

Strict validation and live projection share per-observation structural and
cross-field checks before history filtering. Malformed ancestry stays unresolved.
Contradictory terminal evidence cannot hide work. Valid peer sessions survive.
Each graph assessment visits at most 4,096 nodes and 64 nesting levels. On a
limit, visited evidence stays partial, history actions are disabled for that
session, and omission counts are explicitly lower bounds with unknown totals.
Existing display caps stay 256 nodes and 12 levels. Legacy invalid parent
references still fail validation even when additional observation evidence exists.
Invalid child fields and compatibility disagreements fail history open for
their exact child identities, without degrading unrelated children (#269).
Consistency checks still run when either projection contains invalid peers.
Malformed inherited ancestry protects its descendants; duplicate or empty
identities protect their identifiable ancestor chains before row filtering.
Rejected duplicate, empty or foreign-owner identities also invalidate their
dependent descendants transitively, even when each descendant's own ID is unique.
Malformed parent references seed the same downward protection, even when the
child's own identity remains valid and unique.
A falsely lossless projection degrades unmatched observed children. A legacy
child absent from the observed projection, or a truncated legacy traversal,
cannot be attributed to a displayed row and keeps session-wide history fail-open.
Rejected identities with no identifiable child ancestor chain do the same.
Strict validation and partial-count reporting remain unchanged.

Reader identity, partial-read, corruption, freshness and replay-cap safeguards,
history/attention actions and exact host navigation stay unchanged. No PID,
process-start identity, raw provider payload, capability or control authority
is added. Saved identity still does not imply resume. Observed child has no
independent terminal. This literal #10 integration does not complete broader
#118 lifetime/control foundation. It does not change observation-hook policy.

### Bounded retention and discovery

- Cold start and file-generation replacement start at the newest configured
  window, not byte zero of an unbounded log. **Event tail (MiB)** in sidebar
  settings persists in the existing human `UserDefaults` preferences: default 4,
  integers 1–64. Invalid stored input retains a visible validation notice and
  the default; an invalid edit is rejected without overwriting the saved value.
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
  Terminal agent/root state fails open to unknown as described above. Uncertain
  start-identity match does not demote live work.
  This also applies to uncertain tool-activity admission for terminal owner.
  Clearing obsolete terminal history does not acknowledge retained attention or
  resolve pending request.
  At half occupancy it fails closed. It never forgets history to admit more work.
  True active-capacity exhaustion also reports limit without fabricating
  completion. Transcript replacement reconstructs this state from new log.
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
  descriptor/path verification path; failures discard the cached entry.
  Completed stable discovery prunes unseen entries, and discovery reset clears
  the cache. Cache capacity never limits discovery or grants authority: uncached
  entries take the full read path. Current surface grants, process/marker
  evidence and pre-publication routing/directory fences still run every poll.
- Capture fixed prefix length and observation time for each catch-up pass.
  Later appends do not extend that lease forever. Verified complete prefix may
  be published with its captured observation time and `loadingHistory` when
  newer bytes remain. This is not a current/complete snapshot. Verified current
  EOF uses verification time, including after multi-batch reconstruction on
  normal polling cadence. Torn or malformed
  prefixes cannot become fabricated complete evidence. Failed observation
  cannot pin every later session indefinitely.
- Oversized `session.binary_asset` events keep bounded, validated outer
  envelope. Their opaque `data` object is discarded incrementally. Uploaded
  screenshots therefore cannot permanently invalidate later working/idle state.
  Root identity, type, parent-event metadata, duplicate-key rejection, nesting
  bounds and complete-record boundaries still apply. Other oversized events and
  malformed envelopes stay fail-closed. The 1 MiB retained-line limit is not raised.
- Binding rerouted during read is deliberately omitted, **not** returned
  with its superseded surface/session identity as ambiguous row. Other
  verified granted sessions stay visible. Snapshot reports
  `identityChanged` and is incomplete. Later stable read under new grant
  reconstructs that session, including when both surfaces were already granted.
  By contrast, unstable process/marker evidence with unchanged valid routing
  binding still produces content-free ambiguous row while retaining private replay
  guards for a later fully revalidated read. Timestamp-only hook
  refreshes preserve verified row but require stable discovery cycle
  before completeness. Reader tests cover all three distinct contracts and use
  `#require` before unwrapping expected observations.
- `hasPendingHistory` accelerates productive initial/changed-index discovery and
  admitted-tail deltas. Waiting for session capacity uses normal polling,
  not an endless fast retry loop.
  EOF, torn final lines, and warnings alone never request fast retry. No sandbox
  entitlement or ancestor traversal permission is broadened.

**Further presentation integration:** preserve this combined reducer's
accepted terminal UUID/timestamp, current-spawn/turn pairing, bounded event/start/
owner-qualified resolved-request guards, and `canPublishProjection` distinctions.
Retirement must keep cleaning obsolete turn/activity/outcome state without
discarding pending requests, unknown placeholders or required ancestors.
History presentation limits stay separate from ingestion limits. Prior
terminal dismissal cannot hide fresh lifecycle using same agent ID.
Carry finite reader watermarks, staged-binding revalidation, EOF freshness and
overflow scheduling together. Layout, installer and clarity changes must not
weaken quiet validation scene, backend setup denial, current-tree
acknowledgement guards, or host's 50-point footer clearance.
