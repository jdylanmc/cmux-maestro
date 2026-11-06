# Effect

[↑ CI runner placement](../ci-runner-placement.md) | [← Not moved](not-moved.md)

- **Documentation-only pull requests** (`docs/**`, `README.md`, `CHANGELOG.md`,
  `CONTEXT.md` or `AGENTS.md`, other than this policy):
  - Before: `validate-contracts` took a macOS slot for 9.7 to 16.6 minutes of
    execution in the split runs in [run timings by layout](run-timings-by-layout.md), plus any queue at the ceiling. Docs-only
    probe PR #248, run 38728899842:
    - `ci-classify` took 7 seconds.
    - `validate-native` and the probe were not applicable.
    - `validate-contracts` held a macOS runner from 11:39:55Z to 11:54:50Z
      (14m55s), only for the two Markdown-reading checks, which took seconds.
    - `ci-gate` passed at 11:55:02Z.
  - Now: no macOS job. `validate-portable` runs on Linux, which queued 2 to 3
    seconds in every measured run. Its execution is estimated at 10 to 20 seconds:
    the Linux `ci-classify` and `ci-gate` jobs take 5 to 7 seconds, and the two
    steps took 1 to 2 seconds on macOS. A live run must confirm the figure.
- **Merge policy changes:** still run `validate-contracts`, because
  `scripts/test-build-metadata.py` reads the policy.
- **Full runs:** `validate-contracts` loses two steps of 0 to 2 seconds each.
  Time to green is unchanged, because the macOS jobs bound it.
- **Earlier failures:** a broken skill hash or policy anchor now fails in the
  Linux job, without waiting for a macOS runner.
- **Cost:** no paid capacity. The repository is public, so hosted runners are
  free. The change uses one more Linux job per run, and no more macOS jobs or
  macOS minutes.
- **No further macOS split:** splitting `validate-contracts` would add macOS
  jobs per run. That raises demand at the 5-job ceiling, where all measured
  queueing happened, so the concurrency data does not support it.
