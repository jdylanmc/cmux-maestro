# Concurrency and queueing

Part of [CI runner placement](../ci-runner-placement.md). Previous page is [Sources](sources.md). Next page is [Run timings by layout](run-timings-by-layout.md).

CI now cancels superseded pull request runs using a workflow-level group keyed
by workflow name and PR number. Different PRs do not cancel one another.
Pushes use the ref instead, with in-progress cancellation disabled for `main`;
GitHub can still replace a pending run in the same group. Cancellation frees
obsolete work, not a guarantee that a runner stops immediately. The replacement
head still needs its own green `ci-gate`. Cancelled work never counts as passing.

Suite selection is unchanged: ordinary `docs/**`, `README.md` and
`CHANGELOG.md` changes need no macOS runner; the merge-policy document still
selects contracts. `skills/**` and `.agents/skills/**` intentionally select all
suites because bundled skills and the guide fingerprint are build/test inputs.
They are not documentation-only changes under the reviewed #194 map.

macOS concurrency is limited per account, not per repository, and
`pr-sniper` shares it.

| Simultaneous account macOS jobs | Minutes in the window |
| --- | --- |
| 0 | 438 |
| 1 | 305 |
| 2 | 143 |
| 3 | 137 |
| 4 | 114 |
| 5 | 240 |

- The maximum was **5**, which is GitHub's macOS limit for this plan. It was
  never exceeded.
- During the 240 minutes at 5, `pr-sniper` held 702 and `cmux-maestro` 500 of
  the macOS slot-minutes.
- Execution in the window: `cmux-maestro` 1,344 macOS minutes, `pr-sniper`
  1,318.

Queue delay of `cmux-maestro` macOS jobs, by the most account macOS jobs active
while the job waited:

| Most active while waiting | Jobs | Median queue | Longest queue |
| --- | --- | --- | --- |
| 0 to 3 | 41 | 0.1 min | 0.2 min |
| 4 | 2 | 0.7 min | 0.7 min |
| 5 | 34 | 12.7 min | 41.2 min |

- Every queue over one minute coincided with the account at 5 macOS jobs.
  Below the ceiling, a macOS job started within 12 seconds.
- Examples:
  - Run 38662873916's jobs queued 40.6 and 41.2 minutes (00:56Z).
  - Six PR and push runs created at 00:37Z queued 10.6 to 18.0 minutes.
  - In run 38676895215 (the #196 layout), `guide-ui-consumer-probe` queued
    5m50s. From 03:39:27Z to 03:41:40Z four macOS jobs ran from two runs, and
    the account peaked at five.
  - In run 38695672938, all three macOS jobs started within 2 seconds.
- Linux jobs (`ci-classify`, `ci-gate`) queued 2 to 3 seconds in every run.
  Linux has its own, larger pool.
- One cancelled job held a macOS slot for 5h06m: run 38680234264 attempt 1,
  `validate`, in "Verify Settings guide and setup process isolation", from
  04:41Z to 09:18Z. #191 does not change that. #190 forbids arbitrary timeout
  cuts, and the hang keeps its existing owner.
