# CLI guide, enable, and uninstall

Global /maestro guide, guide acceptance evidence, enable and uninstall rules. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

### CLI Integration: install the global guide

Maestro's native **Settings > CLI Integration** tab explains the guide. It
provides read-only guide-content status, **Re-check**, selectable command text
and **Copy install command**. Each global location reports separately: missing,
unreadable, different, or **Matches this build**. Match compares file's exact
bytes with a SHA-256 reference generated from this build's canonical
`skills/maestro/SKILL.md`. Build does not bundle the global guide itself.
Missing or invalid build reference is an explicit comparison error, not a
local-guide verdict. Different content may be newer or customized, not outdated.
Run this command in your own terminal to install or update:

```sh
npx skills add jdylanmc/cmux-maestro --skill maestro maestro-demo --agent github-copilot --global --copy
```

Review the installer's interactive confirmation. Command deliberately omits
`--yes`. Settings only reads guide content and copies text. It does not execute `npx`, open a terminal,
install a skill, or change global configuration. This is the **single canonical
guide distribution**, from `skills/maestro/{SKILL.md,intent.md}` and
`skills/maestro-demo/SKILL.md`. Invoke global
**`/maestro`**, or use the skill tool with `{"skill":"maestro"}`. No extra
skill-activation grants required. Guide never secretly installs runtime;
native messaging works without it. Runtime stays the separate **Enable Copilot
Integration** action, including the existing lifecycle and icon plugin skills.

**`/maestro-demo`** is an optional, human-requested live demonstration: two visible
interactive workers by default, three on request, distinct icons/colors, their
own tags and original locally drawn pets, and one native-message encore each.
It uses the installed lifecycle and pet skills; it does not install them or add
permissions. Closing is a separate human choice. Its presenter notes describe
sidebar features without driving the UI or restarting CMUX.
Preflight selects an exact launch folder trusted in the child's configuration;
an explicit parent `--config-dir` is not assumed to propagate. Workers reuse it
read-only, with separate temporary artwork/result directories. If trust cannot
be established, the presenter must trust one chosen folder before the demo.
YOLO does not suppress Copilot's configuration-trust prompt.
Initial worker reports target the exact spawning demo parent, not a nested
launch wrapper's root coordinator; replies use the genuine envelope sender.
The Settings status and `maestro-guide.sha256` remain **`/maestro`-only**; they
do not attest to the demo guide's contents or session discovery.

**Development / PR acceptance before merge:** repository command above cannot
install the unpublished skill from `main`. From this checkout's root, human
may run the same installer against local source instead:

```sh
npx skills add . --skill maestro maestro-demo --agent github-copilot --global --copy
```

Settings embeds no branch refs, automatic refresh, or release machinery.
User already proved this global local-source path with `skills` **1.5.26** at
`2026-09-22T12:03:56.533Z`: it installed to `~/.agents/skills/maestro`, and Copilot
global discovery succeeded. That is an observed location. Do not assume
all global skills live under `.copilot`. Bare plugin loading and explicit
`--plugin-dir` both failed live. No upstream root cause is claimed. See the
[public findings](../delivery-proof.md#guide-distribution-decision-after-live-proof).
Refresh of user's existing global copy remains a separate consentful action.

On opening CLI Integration or choosing **Re-check**, Maestro reads only
`~/.agents/skills/maestro/SKILL.md` (the observed shared global installation)
and `~/.copilot/skills/maestro/SKILL.md` (Copilot's agent-specific global location).
Copies and symbolic links work. Maestro reads only stable regular files up to 64 KiB,
off the main thread. Broken links, unsupported types, access failures
and files changing during a read are reported without changing anything.
Maestro reads no polling, project-skill search, provider configuration or session history.
These are file observations, not evidence of which guide a session loaded,
upstream freshness, observer hooks, observation health or messaging readiness.
Run isolated non-GUI reader/model checks with
`./scripts/test-copilot-setup.sh --guide-only`. Normal setup and hosted test
suites retain full coverage.

Guide rendering/action tests require the isolated GitHub-hosted validation
venue. The two original `CLIIntegrationGuideRenderingTests` acceptance methods
remain executed Swift Testing tests. They now independently validate typed native
observations, not dispatch actions in the integrated app. Two distinct
`GuideAcceptanceTests` XCTest methods produce those observations in the dedicated
guide host **before** the original validators, within the same fresh integrated
invocation. The three original resource/exposure/no-op controls are unchanged.
This approved producer/validator split does not equate a passing result flag
with behavioral evidence.

Failed integrated scopes also retain one bounded `xcresulttool export diagnostics`
archive per exact runner-created `isolated`, `remaining`, or `full-fallback`
result bundle. `coverage.json` records invocation, scope, original test exit,
clean checkout head/tree/raw commit parents, export outcome, archive hash, and
file sizes/hashes. Clean source must agree before execution and before/after
capture. All source reads disable Git replacement objects. Missing or changed
provenance refuses capture. Successful scopes do not
export. Capture never changes selectors, test deadlines, coverage, or failure
status. Capture never retries a test or export.

Read only the named bundle: no home-directory, `DiagnosticReports`, environment,
credential, or process-dump collection. Exported diagnostics can contain synthetic
test output, crash stacks, process names, and runner/source paths. They are
diagnostic evidence, not a sanitized support report. Raw export staging stays
outside artifact globs. Inputs reject links/special files and exceed neither
1 GiB nor 20,000 entries. Exported payloads allow at most 256 entries and 64 MiB
uncompressed, with a 65 MiB archive ceiling per scope (at most two scopes).
Export subprocess has a separate 30-second deadline. These are publication
bounds, not an OS disk quota on export tool's temporary writes.
Export traversal and payload reads use a pinned root directory descriptor and
no-follow directory components. File identity/metadata must agree across
inventory, opening, and reading. Input-bundle and destination checks remain
preflight checks, not a filesystem snapshot or hostile same-user sandbox:
external export tool reopens its input path, and final publication uses the
private invocation directory. Concurrent mutation outside the pinned export
boundary is not comprehensively isolated.
Only completed archives enter `failure-diagnostics/<scope>/<scope>.zip` in the
existing 14-day `integrated-test-scope-evidence` artifact. Missing, empty, oversized,
linked, timed-out, or failed exports record an explicit `unavailable` reason.
Interrupted capture remains `capture-incomplete`. Neither outcome establishes
a faulting thread. A later nonreproduction does not erase an earlier crash.

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
Default mode explicitly selects only the unchanged readiness case below.
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

Fresh acceptance requires clean source before and after execution, exact source
inventory/hashes, built product namespaces/hashes, attributable push or PR
synthetic-merge parents, exact native identities/counts/exits, ordered complete
stages, original validator/control executions and all 48 image provenance/hashes.
Parent provenance comes from the exact checkout commit's raw Git object, with
replacement objects disabled and its tree cross-checked. This works at a
depth-one boundary where revision traversal suppresses parents. PR parent order
must still equal the actual event's base then candidate, never event data alone.
Integrated runner disables Python bytecode writes before importing its guide
producer, so loading validation helpers cannot dirty the source checkout.
Preview-test child processes apply the same policy before importing their test
fixtures, preserving source cleanliness across the preceding CI steps.
Clean-source gate still rejects existing untracked or modified files.
Native attachment timestamps must be nondecreasing in required stage-ordinal
order through the final attachment. Equal-resolution timestamps are valid.
Guide receipt schema 2 binds the existing split-debug host layout: the host
executable, its `.debug.dylib` implementation and `__preview.dylib`, plus the
runner and test-bundle executables. Resolved host must have
`ENABLE_DEBUG_DYLIB=YES`. Validation does not change that build setting.
Each code file has an exact bundle-relative path and SHA-256, checked before
and after native acceptance and again after integrated validation. Missing,
changed, symlink-redirected or extra code in these `Contents/MacOS` directories
fails closed. This bounded inventory does not hash SDK/system frameworks.
Old executable-only receipts cannot be upgraded or reused for acceptance.
Identical legitimate pixel hashes are allowed. Failed native production still
runs the integrated suite. Missing evidence fails the original validators.
Both attachment exports are attempted and retained, but either nonzero exit
rejects acceptance even when exported files otherwise look complete.
Each exporter uses its supported default schema, not a version spelling
that differs across Xcode releases. The exact test URL selector and strict
manifest, payload, identity and timestamp checks remain mandatory. An unknown
output shape fails, without a schema retry or fallback.
Existing integrated artifact retains the producer logs, xcresult and images.
Original image artifact receives only the freshly verified guide images.
Compilation and mocked parser negatives do **not** verify native AXPress
capability or the complete matrix. Those remain unverified until reviewed
exact-source hosted execution passes.

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
Fixture diagnostics never substitute for guide content. There is no whole-app
guide fallback. This readiness probe does not replace the existing tests,
their failures, the eleven original commands, or the full guide action matrix.

`./scripts/test-guide-ui-validation.sh --compile-only` builds both new targets
without launching an app or test. Without that flag, the wrapper refuses outside
the original `GITHUB_ACTIONS=true` / `RUNNER_ENVIRONMENT=github-hosted` venue,
forwards those values through `TEST_RUNNER_`, verifies exact built namespaces,
then invokes `test-without-building` once. It accepts no extra xcodebuild options.
Builds use full Xcode and the existing unsigned policy. Project still needs
the pinned SDK from `./scripts/fetch-sdk.sh`, though neither new target links it.

Launch, window/root, minimal and guide phases share a single 180-second
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

On next explicit **Enable Copilot Integration**, setup removes only its old
`Copilot/plugin/skills/maestro/SKILL.md` copy, if present, using owner-checked,
non-symlink traversal. It preserves other skills and files, including lifecycle,
icon and global guides. It never sweeps global paths or cached/live sessions.

### Disable or uninstall

Use **Remove Copilot Integration…**, then explicitly confirm. After ownership
and metadata checks, this disables and removes only the recognized dedicated
file, runs `copilot --no-auto-update plugin uninstall cmux-maestro-native`
when installed, verifies removal, then removes Maestro's native loader entry
point and launch configuration. It removes the owned CMUX Copilot hooks
(`cmux-maestro-cmux-hooks.json`) only when its bytes are a manifest Maestro
shipped, and puts it back if a later removal fails. A file Maestro did not write
stays, and uninstall names it.
Foreign or modified observer files are refused.
Global settings and disable keys are not removed. Do not touch live route bindings,
sockets and in-memory adapters. Close those sessions normally.
Restart/resume existing CLI
sessions to unload their cached hooks. Disable this sidebar in CMUX separately
if desired. Uninstall does not select or remove any other provider.
It also leaves the separately installed global guide untouched.

For individual future CLI launches, `MAESTRO_NATIVE_DISABLED=1` suppresses identity hooks.
`CMUX_COPILOT_HOOKS_DISABLED=1` silences only CMUX's own hooks; Maestro launches set it so CMUX's
restore never claims them (ADR 0024), and Maestro keeps observing them. This integration does not
change or use the legacy `MAESTRO_DISABLED` flag.
