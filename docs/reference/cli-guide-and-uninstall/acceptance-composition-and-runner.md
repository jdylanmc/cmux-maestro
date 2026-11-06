# Acceptance composition and runner

[↑ CLI guide, enable, and uninstall](../cli-guide-and-uninstall.md) | [← Re-check, installed guide status and acceptance evidence](re-check-and-installed-guide-status.md) | [Fresh acceptance provenance →](fresh-acceptance-provenance.md)

Acceptance uses the original 600x414 AppKit composition (600x350 real guide and
600x64 minimal subject), explicit accessibility environment, five statuses in
both appearances, failure/success Copy attempts, and both complete Re-check
transitions per appearance. Public snapshots independently identify exposed
subjects. Fixed synthetic controls dispatch `accessibilityPerformPress()` on
the real node found through bounded unignored accessibility traversal. Require its
actual Boolean return **and** effect. Do not use clicks on the guide, raw-view
AX lookup, direct model-action substitutes, or fallback dispatch.
Exact fittingSize/document/clip measurements and 48 original-named `cacheDisplay`
PNGs remain host observations, not screenshot or frame approximations. Synthetic
Copy/readers never access installed guides or the general pasteboard.

Integrated test runner removes stale `TEST_RUNNER_` aliases for
`GITHUB_ACTIONS` and `RUNNER_ENVIRONMENT` from its copied test environment.
It forwards their original outer values through xcodebuild's documented
`TEST_RUNNER_` mechanism only when both identify the exact GitHub-hosted venue.
Absent/invalid values leave those aliases absent, without excluding unrelated
integrated build/test actions. Calibration's native guard still logs and
checks its compilation, bundle and both environment predicates independently
before AppKit access. It refuses presentation outside the allowed venue.
Their public AppKit presentation calibrates an ordinary SwiftUI button and
the unchanged guide in separate hosting controllers in the same synthetic window.
It preserves an already-regular activation policy, verifies actual policy
before and during readiness, and restores it only when it differs from the
saved original. Required policy changes must succeed. Skipped setters are not
reported as successful calls.
Exact exposed-root readiness and actions share one 180-second budget per active
test case, not per control or appearance. A passing minimal control with a failing
guide narrows investigation to composition. Both failing leaves the host/query
boundary unresolved, not a proven production defect. A changed host passing does
not identify which presentation operation caused it. Native
acceptance still requires the actual hosted results. For local compilation
without opening windows, use `./scripts/test-copilot-setup.sh --compile-only`.
The native wrapper's closed `--acceptance` mode selects exactly the two producers.
Default mode explicitly selects only the unchanged readiness case
(`GuideConsumerReadinessTests`), described in
[guide UI consumer probe](guide-ui-consumer-probe.md).
Each full native case has one shared 180-second budget, including all scenarios,
actions, captures, observations and application teardown. Check successful termination
immediately against that same deadline before final elapsed evidence.
Subsequent validation and attachments retain their final deadline checks.
Evaluate public-consumer predicates immediately before installing a wait.
Already-ready observations do not incur the predicate waiter's initial delay.
Pending observations still use the remaining shared budget. Check both immediate
evaluation and normally returning waits for late completion.
Synchronous public operations are not claimed to be preemptible.
Synthetic exposure control returns unignored children from its public
`accessibilityChildren()` getter and uses that same projection for navigation.
Filtering only inside host's traversal or navigation getter does not remove
ignored objects from the public children attribute. Raw omitted/ignored
controls, their attributes/actions, and leaf buttons remain intact. Complete
public snapshots must still contain exactly one exposed positive control.
Consumer never filters duplicate controls. Local parser checks reject both the
recorded two-node and earlier three-node failures. Only fresh hosted snapshots
can establish that the public projection is repaired.
