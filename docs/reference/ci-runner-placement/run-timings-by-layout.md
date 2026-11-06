# Run timings by layout

Part of [CI runner placement](../ci-runner-placement.md). Previous page is [Concurrency and queueing](concurrency-and-queueing.md). Next page is [Dependencies between suites](dependencies-between-suites.md).

macOS execution is the sum over the run's macOS jobs. Wall time runs from
creation to the last job's completion.

| Layout | Runs | macOS execution per run | Wall time per run |
| --- | --- | --- | --- |
| One `validate` job plus probe (before #196) | 17 runs whose `validate` succeeded, 10-14 to 10-15 | 25.5 to 45.7 min | 23.2 to 66.1 min |
| `validate-native`, `validate-contracts` and probe (#196) | 38676895215, 38695672938, 38711815326 | 28.6 to 38.2 min | 16.3 to 21.9 min |

- The split shortened wall time without adding macOS minutes. It does add a
  third macOS job per run, so a run reaches the 5-job ceiling sooner when other
  runs are active.
- Time to first failure:
  - Run 38680647119 attempt 1 (split): `validate-native` failed 13.3 minutes
    after creation.
  - Old-layout failures surfaced only when `validate` finished: 21.4 to 47.5
    minutes after creation in the eight failed runs 38648863293 to 38657511033.
