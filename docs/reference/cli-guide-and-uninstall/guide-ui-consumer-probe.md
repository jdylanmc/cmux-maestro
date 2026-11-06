# Guide UI consumer probe

Part of [CLI guide, enable, and uninstall](../cli-guide-and-uninstall.md). Previous page is [Fresh acceptance provenance](fresh-acceptance-provenance.md). Next page is [Obsolete guide cleanup, disable and uninstall](obsolete-guide-cleanup.md).

A separate additive `guide-ui-consumer-probe` CI job builds the validation-only
`CMUXMaestroGuideUIHost` app and public XCTest UI target. It compiles the same
unchanged guide view, command, model and reader sources as production, with a
fixed synthetic Missing read closure and an injected copy sink. It does not
read installed guides, write a pasteboard, or include setup/runtime components.
Synthetic window must uniquely match both its public identifier and title.
One ordinary minimal button must move its separately identified static-text
counter value from 0 to 1 after one exact public click. Only then does the test require the
unique real-guide root, Re-check button and both initial status identifiers/text.
Re-check must also be enabled and hittable with positive geometry intersecting
the initial guide scroll viewport and window. Both status rows must have positive
viewport-intersecting geometry. Partial intersection suffices: probe does
not require all guide content to fit, and never scrolls to find it.
A separate, fully clipped synthetic Re-check button must remain query-visible
with the old accepted type/label/enabled attributes, but be non-hittable and
rejected by the same readiness predicate. Its overlay does not resize the guide.
Its exposed group follows the offscreen child bounds, so the negative control
must miss the positive window viewport, not an empty group/window intersection.
Identified real-guide root must itself be the public scroll view. Its frame
intersected with the window supplies the positive guide viewport.
Missing negative-control exposure fails the probe, not skips it.
Fixture diagnostics never substitute for guide content, and no whole-app
guide fallback exists. This readiness probe does not replace the existing tests,
their failures, the eleven original commands, or the full guide action matrix.

`./scripts/test-guide-ui-validation.sh --compile-only` builds both new targets
without launching an app or test. Without that flag, the wrapper refuses outside
the original `GITHUB_ACTIONS=true` / `RUNNER_ENVIRONMENT=github-hosted` venue,
forwards those values through `TEST_RUNNER_`, verifies exact built namespaces,
then invokes `test-without-building` once. It accepts no extra xcodebuild options.
Builds use full Xcode and the existing unsigned policy. Project still needs
the pinned SDK from `./scripts/fetch-sdk.sh`, though neither new target links it.

Launch, window/root, minimal and guide phases share one 180-second
active-case deadline for explicit waits. That deadline cannot preempt synchronous XCTest launch, query and
click calls. Add no custom watchdog, forced
cleanup, retries, permission changes or prompt responses.
Ordinary XCTest lifecycle handling remains framework-owned. Xcode Helper permission and
unsigned runner readiness stay unproved until hosted execution. Apple documents
that UI testing may itself generate an OS permission prompt. An unanswered prompt
or signing/Helper failure is not a pass. Separate `guide-ui-consumer-probe`
artifacts retain source hashes, phase logs and the complete xcresult with failure
screenshots. Before the exact identifier-and-title window query, one public XCTest
application-hierarchy attachment captures at most 16,384 characters and records
whether it was truncated. It diagnoses missing window exposure without selecting
another window, falling back to another attribute, or extending the deadline. Result validation
checks the exact test plan independently from the project/target URL and
reconciles XCTest's empty-argument method spelling with its reported identifier.
Missing or mismatched identities remain failures.
Text logs redact checkout/home paths. Framework-owned xcresult may
contain the disposable runner's build paths. Neither a screenshot nor a new
probe pass establishes full native guide acceptance.
