# Sources

[↑ CI runner placement](../ci-runner-placement.md) | [Concurrency and queueing →](concurrency-and-queueing.md)

- **Window:** every Actions job the `jdylanmc` account ran from 2026-10-14 12:41Z to
  2026-10-15 11:40Z: 54 `cmux-maestro` CI runs (77 macOS jobs that started), plus
  46 macOS jobs in `pr-sniper` and one in `homebrew-pr-sniper`.
- **Timings:** `created_at`, `started_at` and `completed_at` per job, and step
  times, from `GET /repos/jdylanmc/<repo>/actions/runs/<id>/jobs` (and `.../attempts/<n>/jobs`
  for re-run runs; a re-run's reused jobs, whose start precedes their creation, are
  excluded). Queueing is job `started_at` minus `created_at`; execution is
  `completed_at` minus `started_at`. Jobs cancelled before a runner picked them up
  are not counted as active.
- **Reproduce:** the concurrency and queue tables are one-time measurements of
  this window. `scripts/ci-concurrency-report.py` regenerates them read-only
  through `gh api` (about 90 seconds), while GitHub still retains the runs:

  ```sh
  GH_TOKEN="$(gh auth token --user jdylanmc)" python3 scripts/ci-concurrency-report.py \
      --owner jdylanmc --repo cmux-maestro --repo pr-sniper --repo homebrew-pr-sniper \
      --since 2026-10-14 --until 2026-10-15T11:40:46Z
  ```

  On 2026-10-15 it reproduced the tables in
  [concurrency and queueing](concurrency-and-queueing.md) exactly. The layout table and
  the step timings come from the same jobs API, read by hand.
- **Test counts:** the suites' own summary lines in the job log, e.g. job
  116344761792 (run 38711815326, `validate-contracts`, image `macos-26-arm64`).
