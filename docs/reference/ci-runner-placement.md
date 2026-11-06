# CI runner placement

Which CI work runs on which runner, the evidence behind it, and what #191
deliberately left alone. Numbers describe the cited runs, not promised savings.
Policy: [merge policy](../agents/merge-policy.md). Entrypoints:
[build and test](build-and-test.md). Test runtime: [test performance](test-performance.md).

## Sources

The 2026-10-14/15 Actions window, timing method and reproduction command are archived. [Archived evidence](../evidence/ci.md#sources).

## Concurrency and queueing

[Concurrency and queueing](ci-runner-placement/concurrency-and-queueing.md)

## Run timings by layout

Per-layout run timings before and after the #196 split are archived. [Archived evidence](../evidence/ci.md#run-timings-by-layout).

## Dependencies between suites

[Dependencies between suites](ci-runner-placement/dependencies-between-suites.md)

## Portability proof

[Portability proof](ci-runner-placement/portability-proof.md)

## Not moved

[Not moved](ci-runner-placement/not-moved.md)

## Effect

In a pull request, changes only to `docs/**`, `CHANGELOG.md`, `CONTEXT.md` or `AGENTS.md` select only `validate-portable`, which runs on Linux, so they need no macOS job (`docs/**/*.png` images select no suite). Three documentation files are exceptions and also select `validate-contracts`, which runs on macOS: `docs/agents/merge-policy.md`, because `scripts/test-build-metadata.py` reads the policy, and `README.md` and `docs/reference/cli-guide-and-uninstall.md`, because `scripts/test-delivery-proof.py` reads their install commands. Pushes to `main` still run full validation. The measured before/after effect is archived. The Linux execution estimate for `validate-portable` still needs a live run to confirm. [Archived evidence](../evidence/ci.md#effect).
