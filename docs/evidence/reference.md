# Evidence archive: reference

Archived 2026-11-06. Dated evidence moved verbatim from the living documentation. Where a statement here is still current, the linked living page restates it.

## Build, sandbox, and identifiers

From [`docs/reference/build-register-sandbox-identifiers.md`](../reference/build-register-sandbox-identifiers.md). Historical observations and per-paragraph limits moved here verbatim.

An already-selected preview used to keep a lost connection after replacement.
The observed workaround was to right-click CMUX's sidebar toggle, select the
default sidebar, then reselect **Maestro Sidebar**. In that case it recreated
the host view and loaded the replacement extension without restarting CMUX or
Copilot sessions. It is not a universal fix or proof of an OS cause, and the
coordinated installer uses it neither as a prerequisite nor as a fallback. Its
automatic registration transition still needs stock-host acceptance.
`cmux sidebar reload` applies to interpreted Swift sidebars, not native `.appex`
extensions.

A separately signed sandbox probe showed that the `Copilot/` and
`/.copilot/session-state/` read-only prefixes permit synthetic nested
identity/event reconstruction, with unrelated reads and writes denied. It did
not cover `Orchestration/observer/` or the `Beats/` write grant, and it is
**not** an ExtensionKit-hosted runtime proof.

## Installer, preferences and guide acceptance

From [`docs/reference/ci-test-determinism/installer-preferences-and-guide-acceptance.md`](../reference/ci-test-determinism/installer-preferences-and-guide-acceptance.md). Historical observations and per-paragraph limits moved here verbatim.

The historical missing-evidence failures
  came from producer source-attribution rejection, not lost environment
  forwarding.

## Orchestration, watchers and multiwindow teardown

From [`docs/reference/ci-test-determinism/orchestration-watchers-and-multiwindow-teardown.md`](../reference/ci-test-determinism/orchestration-watchers-and-multiwindow-teardown.md). Historical observations and per-paragraph limits moved here verbatim.

The earlier hosted failure's exported diagnostics exceeded
  the artifact cap, so they do not establish which stage stalled.
  In #327 (run `39870017753`), both native invalidation callbacks were still
  missing when the separate-scene test timed out. The retained phase files
  recorded them about 193 seconds after close, after failure cleanup cancelled
  the scene observer. This is load-associated XPC callback latency, not evidence
  that a delivered invalidation failed to clear product scene state; the exact
  underlying scheduler stall was not captured.

## Acceptance composition and runner

From [`docs/reference/cli-guide-and-uninstall/acceptance-composition-and-runner.md`](../reference/cli-guide-and-uninstall/acceptance-composition-and-runner.md). Historical observations and per-paragraph limits moved here verbatim.

Local parser checks reject both the
recorded two-node and earlier three-node failures.

## Maestro demo guide and PR acceptance

From [`docs/reference/cli-guide-and-uninstall/maestro-demo-and-pr-acceptance.md`](../reference/cli-guide-and-uninstall/maestro-demo-and-pr-acceptance.md). Historical observations and per-paragraph limits moved here verbatim.

User already proved this global local-source path with `skills` **1.5.26** at
`2026-09-22T12:03:56.533Z`: it installed to `~/.agents/skills/maestro`, and Copilot
global discovery succeeded.

## Sidebar rows

From [`docs/reference/relaunch-restore/sidebar-rows.md`](../reference/relaunch-restore/sidebar-rows.md). Historical observations and per-paragraph limits moved here verbatim.

A restored tab used to show as `Terminal`.

## Plugin and observer hook

From [`docs/reference/setup-and-integration/plugin-and-observer-hook.md`](../reference/setup-and-integration/plugin-and-observer-hook.md). Historical observations and per-paragraph limits moved here verbatim.

Earlier linked-source/safe-cache-alias
counterexample remains evidence that such audit was false.

## Metadata supervision regression

From [`docs/reference/build-and-test/metadata-supervision-regression.md`](../reference/build-and-test/metadata-supervision-regression.md). Historical observations and per-paragraph limits moved here verbatim.

It exceeds twice the observed 12.002-second passing integrated
test.

This leaves contention headroom.

Hosted behavior still needs verification.

The separate metadata-cancellation test (#174,
`cancellingMetadataStopsItsOwnedProcessBeforeReturning(launchDelay:)`) was
removed on 2026-10-15 by owner decision after intermittent stalls whose cause
was not established.

## Explicit local-only native acceptance

From [`docs/reference/ci-test-determinism/explicit-local-only-native-acceptance.md`](../reference/ci-test-determinism/explicit-local-only-native-acceptance.md). Historical observations and per-paragraph limits moved here verbatim.

#127's
runtime mechanism is not declared solved.

#174's cancellation stall was already removed by an
earlier owner decision and remains unresolved.

## Remove only the owned local preview

From [`docs/reference/install/remove-local-preview.md`](../reference/install/remove-local-preview.md). Test inventories and per-paragraph limits moved here verbatim.

The synthetic install tests exercise real macOS atomic renames in
repository-local fixture directories, with injected signing, process and
registration adapters. They never access real Applications, Copilot settings
or user runtime data. Controlled fixture processes deliberately close their
descriptors, leave a delayed mutating descendant, and lose their caller or
supervisor to `SIGKILL`. Tests prove recovery/new installation stay blocked
until those synthetic workers finish. No real app/session/tool is killed.
CI retains all existing build/test commands and adds these transaction
regressions. Compiled non-UI bridge fixtures also exercise app-plus-integration
publication and recovery across an actual installer-process exit. Live signed
installation, host selection and visual verification remain separate gates.

## Temporary status observation loss

From [`docs/reference/trust-boundary-and-observation/temporary-status-observation-loss.md`](../reference/trust-boundary-and-observation/temporary-status-observation-loss.md). Test inventories and per-paragraph limits moved here verbatim.

Regression workload uses 20 synthetic open background tabs with real bounded
file reads, fake-clock idle/failure transitions, and measured reader/projection
cost.

Timings exclude two-second pause, host delivery and rendering.

They are not stock-host end-to-end latency claim.

## Copilot refresh and same-build updates

From [`docs/reference/install/copilot-refresh.md`](../reference/install/copilot-refresh.md). Per-paragraph acceptance limit moved here verbatim; the family states it once on its index.

Mocked registry tests do not establish
real loaded-generation or focus-preservation acceptance.

## Update, rollback and status

From [`docs/reference/install/update-and-rollback.md`](../reference/install/update-and-rollback.md). Per-paragraph acceptance limit moved here verbatim; the family states it once on its index.

Registration and process checks do not prove that the stock host
observed the disappearance and loaded the replacement.

## Install a verified artifact

From [`docs/reference/install/verified-artifact.md`](../reference/install/verified-artifact.md). Per-paragraph acceptance limit moved here verbatim; the family states it once on its index.

This does not claim CMUX has selected or loaded the new extension.

## Conversion caches and acceptance

From [`docs/reference/reader-lifecycle/conversion-caches.md`](../reference/reader-lifecycle/conversion-caches.md). Per-paragraph acceptance limit moved here verbatim; the family states it once on its index.

That deterministic work count does not measure wall-clock throughput or CPU.

Native callback and controlled-clock tests are not installed ExtensionKit proof.

## Projection reuse and publication

From [`docs/reference/reader-lifecycle/projection-reuse.md`](../reference/reader-lifecycle/projection-reuse.md). Per-paragraph acceptance limit moved here verbatim; the family states it once on its index.

Installed CPU/change-to-pixel acceptance is a separate
hosted check.

## Guide UI consumer probe

From [`docs/reference/cli-guide-and-uninstall/guide-ui-consumer-probe.md`](../reference/cli-guide-and-uninstall/guide-ui-consumer-probe.md). Per-paragraph acceptance limit moved here verbatim; the family states it once on its index.

This readiness probe does not replace the existing tests,
their failures, the eleven original commands, or the full guide action matrix.

Neither a screenshot nor a new
probe pass establishes full native guide acceptance.
