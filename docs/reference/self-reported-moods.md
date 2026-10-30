# Self-reported moods

Optional enum-only authored expressions for managed sessions (#380, part of
#376). Decision: [ADR 0031](../adr/0031-agents-self-report-enum-only-moods.md).
This path supplies data, not pet art. The [pet mood resolver](pet-moods.md)
consumes eligible claims after higher-priority derived facts.

## Agent interface

Native `maestro_mood({ "mood": "happy" })`; supported values are `happy`,
`celebrating`, `confused`, and `clear`. The installed adapter privately binds
the exact invoking session and generation. It accepts no target, text, sequence,
timestamp, or appearance argument. The equivalent controller interface is:

```sh
cmux-maestro-orchestrator mood --self --session-id "<current-session-uuid>" --mood happy
```

The command requires an existing exact managed binding, live provider ancestry,
sole session custody, and the appearance helper's side-effect-free native
`prove`. It checks again inside the existing control lock; no state enrollment,
event read, focus change, terminal input, process control or permission grant.
Lock contention refuses immediately. No queue or automatic retry.

Native/CLI success returns `ok`, `sessionId`, `mood`, `sequence` and `changed`.
It means the claim was stored or already current, never task completion or
display confirmation. Refusals use bounded reason codes; capacity, malformed
store, stale identity and rate limiting preserve the previous file.

## Explicit cosmetic preview

Only when the human requests a preview, call
`maestro_mood({ "mood": "preview" })` once. The equivalent CLI uses
`mood --self --session-id "<current-session-uuid>" --mood preview`.
This previews the existing expressions in order: Idle, Thinking, Working,
Delegating, Question, Needs permission, Confused, Content, Startled, Sad,
Compacting, Sleepy, Gone, Proud, Celebrating. Each slot is five seconds;
the request expires after 75 seconds. Late observations skip elapsed slots,
not replay or extend them. A reader must already have a valid baseline.

`maestro_mood({ "mood": "cancel-preview" })` (CLI `--mood cancel-preview`)
cancels only this exact session's preview and restores ordinary mood resolution,
including an eligible prior self-report. `clear` also cancels the preview and
withdraws the self-report. An ordinary report ends the preview. No other session,
custom duration, mood list, scheduler, heartbeat or repeated write is supported.
Starting an already-active preview is a no-op; explicit cancellation does not
refill the three-second allowance. Acceptance confirms storage, not display.

The pet shows a small corner play glyph that covers no face of the built-in
pets and adds no separate accessibility element. Its accessibility label and tooltip state
**Cosmetic preview; not session state** and its real current mood.
Question, permission, real failure and process death preempt immediately.
Urgent facts, lost observations or changed identity halt
that preview request in every pet view, including hover cards opened later,
rather than resuming it when those facts disappear.
An urgent fact that starts and ends while the sidebar is hidden is not
observed, so the rest of the 75-second window may play when it is shown again.
Cold reader starts, disconnects, mismatches and invalid data suppress playback.
Preview never writes or fabricates lifecycle, attention, history, custody,
acknowledgement or capacity. The existing single cosmetic display deadline
handles the slots and expiry; the controller performs one atomic write.

## Refusals

Both native and CLI paths expose only bounded categories:

| Code | Boundary |
| --- | --- |
| `mood-busy` | The existing control lock is held; no write was attempted. |
| `mood-proof-unavailable` | Native own-session proof could not complete or verify. |
| `mood-identity-unverified` | Exact actor, current route, ancestry or custody could not be verified. |
| `mood-placement-unavailable` | Exact current host workspace/surface placement could not be verified. |
| `mood-store-unavailable` | The private state or mood store could not be read, validated or written; nothing was published. |
| `mood-rate-limited` | A distinct non-clear change arrived inside three seconds. |
| `mood-capacity-unavailable` | A store or sequence bound prevents admission. |
| `mood-input-invalid` | The own-session request has an invalid shape or value. |
| `mood-unavailable` | The operation failed or its outcome remains uncertain, including a failure after the new record was published. |

These categories identify the failing boundary, not the hidden root cause.
They never echo helper output, paths, capabilities or process details. Inspect
the named prerequisite through supported diagnostics; do not automatically
retry, enqueue, widen permissions or fall back to terminal input. A historical
generic refusal cannot be retrospectively attributed to one of these causes.

## Store version 1

Private, atomically replaced `Orchestration/observer/moods.json`, under the
existing observer read grant:

```json
{
  "version": 1,
  "moods": [{
    "nodeId": "00000000-0000-0000-0000-000000000001",
    "runId": "00000000-0000-0000-0000-000000000002",
    "sessionId": "00000000-0000-0000-0000-000000000003",
    "workspaceId": "00000000-0000-0000-0000-000000000004",
    "surfaceId": "00000000-0000-0000-0000-000000000005",
    "generation": 1,
    "sequence": 1,
    "source": "self-report",
    "mood": "happy",
    "lastChangedAt": 1800000000000
  }]
}
```

Exact key sets, canonical lowercase UUIDs, unique nodes, integer version 1,
positive safe integers (at most 2^53-1) for generation/sequence/lastChangedAt.
No duplicate JSON keys, floating-point/exponent integers, nulls, free text or
unknown enum. Bounds: 1 KiB canonical record, 1 MiB input file, 1,024 nodes,
128 per workspace. Readers require stable owned regular files, mode 0600,
and non-symlink directory traversal. They never overwrite rejected data.

One current record per node; changing generations replaces that node's record,
increments its sequence, and requires the same run/session/workspace/surface.
New nodes require capacity; neither archive nor a mood write evicts claims or
tombstones, even when their node is absent from the lifecycle store.
Sequence exhaustion refuses. Same identity + same mood is a true no-op,
including file identity and cooldown. `clear` stores a higher sequence, not
absence. One distinct non-clear change per 3,000 ms; clear is exempt and retains
the previous non-clear timestamp. Initial clear uses sentinel `lastChangedAt=1`
and consumes no cooldown. The clock is controller-owned and injectable in tests.
It is never a presentation clock.

An optional exact-key `preview` object extends the same record:
`{"startedAt":1800000000000,"active":true,"reportSequence":1}`.
`startedAt` is a controller-issued Unix millisecond preview clock, separate
from the rate-limit timestamp; it leaves room for 75,000 ms within the safe
integer bound. `active` is a Boolean, and `reportSequence` is a positive integer
no greater than the record sequence. It preserves the original report's
eligibility without making an old suppressed report fresh. Start/cancel
increase the common record sequence; cancellation keeps an inactive preview
tombstone. An ordinary mood write removes the preview object and has its own
fresh report sequence. New generations never inherit an old preview or report.
Older readers reject this optional extension as unavailable cosmetic data;
they do not lose lifecycle or attention evidence.

## Reader and consumer contract

`SidebarOrchestrationReader.Cached` owns the bounded mood cache. Its first
valid read baselines all existing sequences without displaying their claims.
Verified absence baselines an empty store; invalid input cannot initialize it.
Only a newly observed higher sequence matching all six fields of a current
validated orchestration node becomes eligible. The reader retains high-water
marks for at most 1,024 nodes; exhaustion disables the overlay, never evicts.
Same-sequence mutation, rollback, tombstone, missing record, invalid file or
binding mismatch cannot resurrect a report. A new reader intentionally loses
eligibility, not sequencing safety.

Host disconnects, unpaired windows, and connection rebinds revoke eligibility
in the retained reader and require a new valid baseline before displaying later
reports. The reset runs after any obsolete in-flight read finishes and before
the replacement read. High-water marks and their no-eviction capacity survive
the boundary; unchanged claims and reports written while disconnected cannot
replay. Ordinary topology refreshes and visibility changes do not reset eligibility.

The session node exposes `selfReportedMood: SidebarMoodObservation.Mood?` and
`selfReportedMoodSequence: Int?`, plus optional `moodPreview` playback metadata.
The report sequence remains separate from preview-only changes.
`clear` is never exposed as a displayed mood;
the sequence remains available for withdrawal/cold-start suppression.
`Mood.selfReportLabel` provides localized authored-basis text for the later
accessibility/tooltip consumer. `snapshot.moodsUnavailable` is a bounded
cosmetic diagnostic, not observation loss. These fields are excluded from
`current.json` encoding and never change completeness, work state, attention,
acknowledgement or resource counts.

#382 owns priority/hold integration and must preserve Question, Needs permission,
Sad and Gone over a self-report. #383 owns art. This delivery proves neither
visual priority nor hosted ExtensionKit behavior. Normal explicit production
setup distributes the adapter; existing sessions are not reloaded by this change.

## Local validation paths

The Python orchestrator and Node adapter tests accept `MAESTRO_TEST_ROOT` for
their short socket fixture directories. Use an existing, owned directory with
enough Unix socket path headroom; `TMPDIR` separately controls ordinary fixture
files. Neither setting changes controller limits or redirects production data.
The failed-Git fixture carries an unresolvable `.git` marker so a
repository-local `TMPDIR` cannot turn it into the enclosing delivery repository.
