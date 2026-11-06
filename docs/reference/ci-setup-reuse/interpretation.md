# Interpretation

Part of [CI setup reuse](../ci-setup-reuse.md). Previous page is [Measured cost and benefit of the realistic candidate](measured-cost-and-benefit-of-the.md). Next page is [Rejected options](rejected-options.md).

- After a checkout, Xcode recompiles every Swift file regardless of the cache.
  Restored DerivedData saves only the explicit-module (PCM) generation and some
  planning: 25 to 35% of the build at 3 jobs, 44 to 48% unthrottled.
- **CI-derived bound.** Planning plus the PCM window is 78s (A), 87s (B) and
  84s (C). The PCM window overlaps other compile tasks, so this is an upper
  bound on what PCM and planning reuse can remove from the CI build.
- **Restore cost is an assumption, not a measurement.** The test build's
  DerivedData, without products or scoped results, is about 550 MB raw and
  173 MB as a `tar` and `zstd` archive (5,302 files). Packing locally took 5s
  and unpacking 7s. The 20 to 40s assumed for a hosted runner is about 10 to 20 MB/s
  effective cache download (9 to 17s) plus 2 to 3 times the local unpack (14 to 21s). A
  miss pays a similar cost to save.
- **Projected net saving: about 10 to 95s.**
  - Low end: 25% of a 191s CI build is 48s, minus a 40s restore.
  - High end: 48% of a 239s CI build is 115s, minus a 20s restore. This is
    above the CI-derived bound, so it is generous.
  - That is about 1 to 9% of `validate-native`.
  - **The decision holds:** even the high end is below the 2-minute threshold
    under "When to revisit".
  - Run-to-run variation of that one step is already about 2 minutes
    (16m05s to 17m59s), and queueing at the macOS concurrency ceiling dominates
    end-to-end time. See [CI runner placement](../ci-runner-placement.md).
