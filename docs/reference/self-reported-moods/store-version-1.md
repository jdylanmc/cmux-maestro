# Store version 1

[↑ Self-reported moods](../self-reported-moods.md) | [← Refusals](refusals.md) | [Reader and consumer contract, and local validation →](reader-and-consumer-contract.md)

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
