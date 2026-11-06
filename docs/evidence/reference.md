# Evidence archive: reference

Archived 2026-11-06. Verbatim text moved out of the living documentation so those pages describe current behavior only. Nothing here is a current contract; follow the links back for that.

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
