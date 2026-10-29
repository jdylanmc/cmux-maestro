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
`selfReportedMoodSequence: Int?`. `clear` is never exposed as a displayed mood;
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
