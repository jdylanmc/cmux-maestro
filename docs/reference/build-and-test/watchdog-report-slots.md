# Watchdog report slots

Part of [Build and test](../build-and-test.md). Previous page is [Metadata supervision regression](metadata-supervision-regression.md). Next page is [Setup controls and focused diagnostics](setup-controls-and-focused-diagnostics.md).

`CopilotSetupObservation` remains for diagnosis. Only the
`MetadataWatchdogProbe` `diagnostic-*` controls and `CopilotSetupObservationTests`
inject one; normal runners keep `observation == nil`: no observation storage,
callbacks, queries or logging enable automatically. Optional
`stall.json.supervision` version 1 snapshot contains 14 fixed numeric
boundary slots:

| Index | Boundary | Index | Boundary |
| --- | --- | --- | --- |
| 0 | Test `cancel()` call | 7 | TERM syscall |
| 1 | Cancellation handler | 8 | KILL syscall |
| 2 | Synchronous execute | 9 | Exact-child reap |
| 3 | Exchange poll | 10 | Continuation resume call |
| 4 | Child-state wait | 11 | Async invoke return edge |
| 5 | Group quiescence | 12 | Metadata return edge |
| 6 | Owned-group stop | 13 | Test task-value await |

Each slot retains own `begin`, `end`, `detailSequence` and last numeric
`detail`. Zero means not observed. End greater than begin means the
boundary's end marker was reached. Async invoke/metadata markers run at
their return edges. Existing outer flags separately prove caller receipt.
Sequence numbers order observations, not elapsed time.
Repeated queries replace only own completed slot. Outstanding begin
cannot be overwritten. `overflow` or `invalidTransition` forbids treating the
record as complete. `availability: 1` means snapshot lock contention, with no
boundary data. `0` means available. Failure dump never waits for the
observation lock, cancellation lock or supervisor to finish.

Detail reasons: 0 unknown, 1 cancellation observed, 2 child running,
3 child exited, 4 child unavailable, 5 quiescent, 6 living group member,
7 enumeration unavailable/full, 8 member query unknown and 9 membership changed.
Result/error/PID/status/code/count fields come only from existing supervisor
queries and syscalls. Zero `detailSequence` means even zero-valued fields are
unknown. Snapshot adds no process enumeration or provider data and has a
tested 8 KiB encoded bound. Serialization runs after releasing observation
locks. Snapshot may be unavailable while a tiny record update is in progress.

Slot order is not causality: resume-return and async-caller progress are
distinct, and these diagnostics neither shorten cleanup nor establish a
historical cause.
