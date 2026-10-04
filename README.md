# CMUX Maestro

A compiled macOS CMUX sidebar that displays Copilot sessions and explicit
terminal-backed orchestration hierarchies. The native sidebar reads locally; no companion daemon,
watcher, loopback server, XPC service, raw CMUX socket, or session-start ritual.
The separate interpreted Maestro project is untouched and is not a dependency.

See the [behavioral parity matrix](docs/behavioral-parity.md) for regression
evidence, live acceptance scope, intentional differences and remaining limits.

Sidebar path labels use the real user's account home (`~` or `~/…`), including
workspace/project paths, surface directories, hover and pinned details.
Formatting normalizes separators and dot components lexically; it neither
probes the filesystem nor resolves symlinks. Outside paths stay absolute,
missing/denied states stay explicit, and ownership/navigation values are
unchanged. If account-home resolution fails, the absolute label explains it.

**Surface directory** means the directory reported by CMUX for that exact
surface, not independently verified agent process or last-tool working
directory. **Parent surface directory** is parent placement only, not a
windowless child's own directory. Help and accessibility retain this source
qualification and the absence of a report timestamp. A fresh session observation
does not establish directory-report age; assigned/last-verified Git worktree
labels are separate evidence, never directory fallbacks. Retained original
sessions do not borrow their replacements' paths.

At the pinned SDK/host revision `ae7fbce99f98c98df5ccf915e548dd080d33cfa8`,
[`CmuxSidebarSurface.workingDirectory`](https://github.com/manaflow-ai/cmux/blob/ae7fbce99f98c98df5ccf915e548dd080d33cfa8/Packages/macOS/CmuxExtensionKit/Sources/CmuxExtensionKit/Sidebar/CMUXSidebarSurface.swift)
is optional and filtered by `workspacePaths`.
The [sidebar producer](https://github.com/manaflow-ai/cmux/blob/ae7fbce99f98c98df5ccf915e548dd080d33cfa8/Sources/ContentView.swift#L12736-L12748)
uses `reportedPanelDirectory(panelId:)`, whose
[implementation](https://github.com/manaflow-ai/cmux/blob/ae7fbce99f98c98df5ccf915e548dd080d33cfa8/Sources/Workspace%2BSidebarDirectories.swift#L48-L70)
normalizes the panel report and applies remote trust gating. It does not use
the separate `effectivePanelDirectory` local/requested-directory fallback.
This is source-level provenance, not installed-host acceptance of #77 or
runtime-directory collection.

## One-time setup

1. Use the [alpha installer](#install-a-stable-local-preview). Normal install
   and update include Copilot automatically; a separate setup action is not
   required. The installer uses its configured `PATH`, or an explicit trusted
   `--copilot-executable /absolute/path/to/copilot`. It does not assume shell
   startup files or machine-specific provider cache paths.
2. The containing app retains **Enable Copilot Integration** and
   **Choose Copilot…** for explicitly requested maintenance. These controls are
   not normal-install prerequisites. The production app also retains the
   equivalent standalone maintenance command:

   ```sh
   "$HOME/Applications/CMUX Maestro Preview.app/Contents/MacOS/CMUX Maestro Preview" \
     --install-copilot-integration --copilot-executable "$(command -v copilot)"
   ```

   This uses the same installer and production-identity checks. It does not
   open setup windows, change accounts, or restart existing conversations.
   Normal app startup still performs no installation.
   Production preview builds disable coverage instrumentation so setup does not
   leave `default.profraw` in the caller's worktree; test coverage remains enabled.
3. If not already enabled, select **CMUX Maestro Preview** in CMUX's **Sidebar
   Extensions** browser. Installation does not change host grants or selection.
4. Leave existing Copilot chats running. New sessions load the installed
   configuration; already-running sessions may retain cached hooks. Installation
   neither restarts nor adopts them. Fresh-session acceptance is separate from
   on-disk installation. Setup also
   installs the bundled `/cmux-maestro-native:cmux-maestro-orchestrate`
   and `/cmux-maestro-native:maestro-icon`
   skills and local controller. Only newly Maestro-spawned managed
   sessions get native messaging bindings automatically.
5. For the optional messaging guide, open Maestro **Settings > CLI Integration**.
   Copy the global install command and run it yourself as described below.
   Runtime setup never installs the global guide.

The containing app is an installer, not a session observer. It may be closed
after setup. **Check Registration** reads only registration files. A successful
setup verifies the dedicated file and hookless installed plugin on disk and
through provider discovery; it does not imply loaded hooks, observed events,
messaging readiness or an enabled host extension.

Installer invocations start in their own process group. **Cancel Setup** and
the 45-second timeout stop that invocation's launcher and descendants, then
wait for cleanup before permitting retry; existing Copilot sessions are never
signalled. This also applies to the bounded, metadata-only `status.get`,
`hooks.discover` and `plugins.list` checks during explicit setup. Each process
has the same deadline; setup starts no agent/model session or persistent
service. Metadata output is capped at 256 KiB and is never displayed as raw
CLI output.
Setup passes `--no-auto-update` so a plugin change does not opt into upgrading
the selected CLI.

Setup installs the distinct, now **hookless `cmux-maestro-native`** plugin and
its bundled skills, private local controller, native loader at
`~/.copilot/extensions/maestro/extension.mjs`, and
**`~/.copilot/hooks/cmux-maestro-observer.json`**. The dedicated version-1 file
declares only `sessionStart`, `userPromptSubmitted` and `postToolUse`, using the
unchanged silenced helper wrapper. Private generation/provenance and an
advisory setup lock live under the existing application `Copilot/` support
directory. Managed tools require matching launcher/session/workspace/generation
bindings. Ordinary CMUX sessions can expose only the nonprivileged
[`maestro_readiness` diagnostic](docs/native-messaging-architecture.md#ordinary-session-readiness-partial-162);
this does not enroll the session or enable Joe activation. Existing
`maestro-cmux`, other plugins, provider settings, and sidebar selection are
never replaced automatically. Normal app updates refresh owned integration
through the coordinated installer. Generated hooks use the **stable installed
helper path**, never a staging or backup location. Manual moves outside the
receipt-owned destination remain unsupported by the app installer.

Observer setup attempts **stable Copilot CLI 1.x releases using protocol 3**.
Other major versions, prereleases and protocols remain unsupported. Compatibility
still requires valid public metadata, exact-source identity and verified operation
readback; the version range alone does not establish runtime compatibility. A
conflicting `HOME` or `COPILOT_HOME` is rejected; this does not broaden the
reader beyond standard `~/.copilot`. Setup rejects unsafe, symlinked,
hard-linked, modified or foreign owned-target registration and ambiguous owned sources.
It does not chmod an existing shared hooks directory.
Historical plugin-hook reformatting also requires review: provider disable-key
identity can depend on serialization, not just semantically equal JSON.

Before changing an existing owned installation, setup submits its exact safe
absolute source path to the public plugin-install RPC in a private disposable
provider home. On the originally tested 1.0.88 and 1.0.89 versions, that source's returned identity
is home-independent. It must match the real provider's selection and any prior
receipt before real-home changes. Legacy/name-derived receipts cannot authorize
their own adoption. The request path, provider version/protocol and returned
identity are recorded together; subsequent install results and discovery must
match. A fresh source is bound and recorded before its first real-home provider
mutation. No private source-ID algorithm or guessed provider directory is used.

Unrelated plugin identities and public hook rows are preserved, not audited
through cache aliases or common event names. Live, built-in and opaque unowned
plugins do not cause blanket refusal. The earlier linked-source/safe-cache-alias
counterexample remains evidence that such an audit was false, not evidence of
safe foreign actions. **An independent unowned plugin can still call the current
or an older helper and cause extra executions/writes.** Setup neither certifies
nor suppresses that behavior. Status describes the **owned registration** only.
Unsafe owned paths, owned-name/source collisions and directly inspected
user-file conflicts remain targeted refusals.

For a recognized direct legacy installation, setup first records provenance
and stages an **owned disabled** dedicated file, confirms disabled discovery,
prepares the hookless plugin, runs the official plugin installer, verifies that
the installed observer declarations are gone, and only then publishes the
intended dedicated state. Old and new owned observer sources are never enabled
by this migration at the same time.
Maestro does not rewrite unrelated hooks or disable keys.
The official CLI does rewrite `settings.json` during plugin install/uninstall,
including when values are unchanged. After a successful command, setup accepts
only an identical settings object or addition of an empty `enabledPlugins` map.
All other values, including disable choices and unrelated preferences, must
remain identical; unsafe or unexpected changes leave setup incomplete.
If setup fails during disabled staging, before resource preparation or any
plugin command starts, it restores and verifies the previous owned observer
file and provenance (including prior absence and permissions). Cancellation
waits for that bounded restoration. A changed owned file is never overwritten
to force rollback. Resource preparation snapshots all named owned resources
before writing. A later resource-file write failure conditionally restores their
previous bytes, absence and permissions, then restores observer staging when
that restoration is verified. Unchanged resources retain their file identity.
Preflight refusal is reported as no resource-file writes, not as a rollback.
Standalone maintenance reports later incomplete phases conservatively. Normal
alpha installation additionally uses a durable coordinated checkpoint: failure
or pre-commit interruption restores the previous owned files and compensates
the provider through official install/uninstall operations at the same stable
owned source path. It then verifies public discovery before restoring the app.
Rollback restores saved settings bytes only after verifying that current values
still match the original settings or the documented empty-plugin-map
normalization. Unexpected user changes block compensation rather than being
overwritten.

**Disable preservation is conservative.** The provider omits destination keys
for a file-disabled source. When a registration change would require mapping
global `disabledHooks`, setup refuses before changing the legacy registration;
it neither guesses hashes nor enables a duplicate to obtain keys. A change may
proceed with unrelated disables only when complete exact-owned prior metadata
supplies every key, every owned event is enabled, and every configured key is
positively identified as unrelated. Missing/ambiguous keys and affected disabled
subsets still refuse; settings stay unchanged apart from the bounded official
CLI normalization described above. Already
current dedicated registrations retain their unchanged hook configuration and
keys. A whole-file/global disable does not bypass the unresolved per-key gate:
later re-enabling must not lose a disabled subset. Otherwise, explicit
global/file `disableAllHooks` leaves the owned file disabled,
including after the global flag is later cleared. Review the owned file and
explicitly change its disable flag before requesting activation again.
There is no general settings editor or additive disable-key migration. The
coordinated installer's guarded restoration is not permission to accept
arbitrary concurrent settings edits.

**Status retains disable detail.** A completed registration records bounded
opaque provider keys tied to its exact generation and tested provider version.
Check Registration remains file-only: it distinguishes all/some configured
observer disables using that receipt, and reports unresolved applicability for
unknown keys or stale/missing provenance. It never guesses that an unrelated key
disables an observer or starts a metadata subprocess. Incomplete transaction or
conflicting/missing plugin state takes precedence over ordinary disabled status.
Verified setup with preserved all/subset disables is a successful CLI completion
(stdout, exit 0), with its explicit disable message; actual failures remain
nonzero and malformed command arguments retain usage exit 2.

Failures identify the last completed phase, not blanket installation success.
An interrupted transaction may retain a disabled owned file while the old
plugin remains installed, or leave a hookless plugin awaiting publication.
Retry revalidates provenance and content; a retained disabled stage stays
disabled conservatively. Foreign edits require manual review, not automatic
rollback. Existing sessions retain their cached hooks; any provider reload,
restart or resume is human-owned. See the
[compatibility limits](docs/behavioral-parity.md#dedicated-observer-registration-114).

Messaging launch configuration and stored nodes retain the three-field
`{version, routes, extension}` contract. The obsolete `pluginDirectory` setup
field is ignored for compatibility, never validated or passed to Copilot.
Managed launches retain `--experimental`, pins, denies, coordinator-only explicit
YOLO and terminal I/O; they do not require a guide or pass `--plugin-dir`.

### CLI Integration: install the global guide

Maestro's native **Settings > CLI Integration** tab explains the guide and
provides read-only guide-content status, **Re-check**, selectable command text
and **Copy install command**. Each global location is reported separately as
missing, unreadable, different, or **Matches this build**. Matching compares
the file's exact bytes with a SHA-256 reference generated from this build's
canonical `skills/maestro/SKILL.md`; the global guide itself is not bundled.
A missing or invalid build reference is an explicit comparison error, not a
local-guide verdict. Different content may be newer or customized, not outdated.
Run this command in your own terminal to install or update:

```sh
npx skills add jdylanmc/cmux-maestro --skill maestro --agent github-copilot --global --copy
```

Review the installer's interactive confirmation; the command deliberately omits
`--yes`. Settings only reads guide content and copies text: it does not execute `npx`, open a terminal,
install a skill, or change global configuration. This is the **single canonical
guide distribution**, from `skills/maestro/{SKILL.md,intent.md}`. Invoke global
**`/maestro`**, or use the skill tool with `{"skill":"maestro"}`. No extra
skill-activation grants are required. The guide never secretly installs runtime;
native messaging works without it. Runtime remains the separate **Enable Copilot
Integration** action, including the existing lifecycle and icon plugin skills.

**Development / PR acceptance before merge:** the repository command above cannot
install the unpublished skill from `main`. From this checkout's root, the human
may instead run the same installer against the local source:

```sh
npx skills add . --skill maestro --agent github-copilot --global --copy
```

No branch refs, automatic refresh, or release machinery are embedded in Settings.
The user already proved this global local-source path with `skills` **1.5.26** at
`2026-09-22T12:03:56.533Z`: it installed to `~/.agents/skills/maestro`, and Copilot
global discovery succeeded. That is an observed location, not an assumption that
all global skills live under `.copilot`. Bare plugin loading and explicit
`--plugin-dir` both failed live; no upstream root cause is claimed. See the
[public findings](docs/delivery-proof.md#guide-distribution-decision-after-live-proof).
Any refresh of the user's existing global copy remains a separate consentful action.

On opening CLI Integration or choosing **Re-check**, Maestro reads only
`~/.agents/skills/maestro/SKILL.md` (the observed shared global installation)
and `~/.copilot/skills/maestro/SKILL.md` (Copilot's agent-specific global location).
Copies and symbolic links are supported; only stable regular files up to 64 KiB
are read, off the main thread. Broken links, unsupported types, access failures
and files changing during a read are reported without changing anything.
No polling, project-skill search, provider configuration or session history is
read. These are file observations, not evidence of which guide a session loaded,
upstream freshness, observer hooks, observation health or messaging readiness.
The isolated non-GUI reader/model checks can run with
`./scripts/test-copilot-setup.sh --guide-only`; the normal setup and hosted test
suites retain their full coverage.

The guide rendering/action tests require the isolated GitHub-hosted validation
venue. The two original `CLIIntegrationGuideRenderingTests` acceptance methods
remain executed Swift Testing tests, now independently validating typed native
observations rather than dispatching actions in the integrated app. Two distinct
`GuideAcceptanceTests` XCTest methods produce those observations in the dedicated
guide host **before** the original validators, within the same fresh integrated
invocation. The three original resource/exposure/no-op controls are unchanged.
This approved producer/validator split does not equate a passing result flag
with behavioral evidence.

Acceptance uses the original 600x414 AppKit composition (600x350 real guide and
600x64 minimal subject), explicit accessibility environment, five statuses in
both appearances, failure/success Copy attempts, and both complete Re-check
transitions per appearance. Public snapshots independently identify the exposed
subjects. Fixed synthetic controls dispatch `accessibilityPerformPress()` on
the real node found through bounded unignored accessibility traversal; its
actual Boolean return **and** effect are required. Clicks on the guide, raw-view
AX lookup, direct model-action substitutes, and fallback dispatch are not used.
Exact fittingSize/document/clip measurements and 48 original-named `cacheDisplay`
PNGs remain host observations, not screenshot or frame approximations. Synthetic
Copy/readers never access installed guides or the general pasteboard.

The integrated test runner removes stale `TEST_RUNNER_` aliases for
`GITHUB_ACTIONS` and `RUNNER_ENVIRONMENT` from its copied test environment.
It forwards their original outer values through xcodebuild's documented
`TEST_RUNNER_` mechanism only when both identify the exact GitHub-hosted venue.
Absent/invalid values leave those aliases absent without excluding unrelated
integrated build/test actions. The calibration's native guard still logs and
checks its compilation, bundle and both environment predicates independently
before AppKit access, refusing presentation outside the allowed venue.
Their public AppKit presentation calibrates an ordinary SwiftUI button and
the unchanged guide in separate hosting controllers in the same synthetic window.
It preserves an already-regular activation policy, verifies the actual policy
before and during readiness, and restores it only when it differs from the
saved original. Required policy changes must succeed; skipped setters are not
reported as successful calls.
Exact exposed-root readiness and actions share one 180-second budget per active
test case, not per control or appearance. A passing minimal control with a failing
guide narrows investigation to composition; both failing leaves the host/query
boundary unresolved, not a proven production defect. A changed host passing does
not identify which presentation operation caused it. Native
acceptance still requires the actual hosted results. For local compilation
without opening windows, use `./scripts/test-copilot-setup.sh --compile-only`.
The native wrapper's closed `--acceptance` mode selects exactly the two producers;
default mode explicitly selects only the unchanged readiness case below.
Each full native case has one shared 180-second budget, including all scenarios,
actions, captures, observations and application teardown. Successful termination
is checked immediately against that same deadline before final elapsed evidence;
subsequent validation and attachments retain their final deadline checks.
Public-consumer predicates are evaluated immediately before installing a wait;
already-ready observations do not incur the predicate waiter's initial delay.
Pending observations still use the remaining shared budget. Both immediate
evaluation and normally returning waits are checked for late completion.
Synchronous public operations are not claimed to be preemptible.
The synthetic exposure control returns unignored children from its public
`accessibilityChildren()` getter and uses that same projection for navigation.
Filtering only inside the host's traversal or navigation getter does not remove
ignored objects from the public children attribute. The raw omitted/ignored
controls, their attributes/actions, and leaf buttons remain intact. Complete
public snapshots must still contain exactly one exposed positive control; the
consumer never filters duplicate controls. Local parser checks reject both the
recorded two-node and earlier three-node failures; only fresh hosted snapshots
can establish that the public projection is repaired.

Fresh acceptance requires clean source before and after execution, exact source
inventory/hashes, built product namespaces/hashes, attributable push or PR
synthetic-merge parents, exact native identities/counts/exits, ordered complete
stages, original validator/control executions and all 48 image provenance/hashes.
Parent provenance comes from the exact checkout commit's raw Git object, with
replacement objects disabled and its tree cross-checked. This works at a
depth-one boundary where revision traversal suppresses parents; PR parent order
must still equal the actual event's base then candidate, never event data alone.
The integrated runner disables Python bytecode writes before importing its guide
producer, so loading validation helpers cannot dirty the source checkout.
Preview-test child processes apply the same policy before importing their test
fixtures, preserving source cleanliness across the preceding CI steps.
The clean-source gate still rejects existing untracked or modified files.
Native attachment timestamps must be nondecreasing in required stage-ordinal
order through the final attachment; equal-resolution timestamps are valid.
Guide receipt schema 2 binds the existing split-debug host layout: the host
executable, its `.debug.dylib` implementation and `__preview.dylib`, plus the
runner and test-bundle executables. The resolved host must have
`ENABLE_DEBUG_DYLIB=YES`; validation does not change that build setting.
Each code file has an exact bundle-relative path and SHA-256, checked before
and after native acceptance and again after integrated validation. Missing,
changed, symlink-redirected or extra code in these `Contents/MacOS` directories
fails closed. This bounded inventory does not hash SDK/system frameworks.
Old executable-only receipts cannot be upgraded or reused for acceptance.
Identical legitimate pixel hashes are allowed. Failed native production still
runs the integrated suite; missing evidence fails the original validators.
Both attachment exports are attempted and retained, but either nonzero exit
rejects acceptance even when the exported files otherwise look complete.
Each exporter uses its supported default schema rather than a version spelling
that differs across Xcode releases. The exact test URL selector and strict
manifest, payload, identity and timestamp checks remain mandatory; an unknown
output shape fails, without a schema retry or fallback.
The existing integrated artifact retains the producer logs, xcresult and images;
the original image artifact receives only the freshly verified guide images.
Compilation and mocked parser negatives do **not** verify native AXPress
capability or the complete matrix. Those remain unverified until reviewed
exact-source hosted execution passes.

A separate additive `guide-ui-consumer-probe` CI job builds the validation-only
`CMUXMaestroGuideUIHost` app and public XCTest UI target. It compiles the same
unchanged guide view, command, model and reader sources as production, with a
fixed synthetic Missing read closure and an injected copy sink; it does not
read installed guides, write a pasteboard, or include setup/runtime components.
The synthetic window must uniquely match both its public identifier and title.
One ordinary minimal button must move its separately identified static-text
counter value from 0 to 1 after one exact public click. Only then does the test require the
unique real-guide root, Re-check button and both initial status identifiers/text.
Re-check must also be enabled and hittable with positive geometry intersecting
the initial guide scroll viewport and window; both status rows must have positive
viewport-intersecting geometry. Partial intersection is sufficient: this does
not require all guide content to fit, and the probe never scrolls to find it.
A separate, fully clipped synthetic Re-check button must remain query-visible
with the old accepted type/label/enabled attributes but be non-hittable and
rejected by the same readiness predicate. Its overlay does not resize the guide.
Its exposed group follows the offscreen child bounds, so the negative control
must miss the positive window viewport, not an empty group/window intersection.
The identified real-guide root must itself be the public scroll view; its frame
intersected with the window supplies the positive guide viewport.
Missing negative-control exposure fails the probe rather than skipping it.
Fixture diagnostics never substitute for guide content; there is no whole-app
guide fallback. This readiness probe does not replace the existing tests,
their failures, the eleven original commands, or the full guide action matrix.

`./scripts/test-guide-ui-validation.sh --compile-only` builds both new targets
without launching an app or test. Without that flag, the wrapper refuses outside
the original `GITHUB_ACTIONS=true` / `RUNNER_ENVIRONMENT=github-hosted` venue,
forwards those values through `TEST_RUNNER_`, verifies exact built namespaces,
then invokes `test-without-building` once. It accepts no extra xcodebuild options.
Builds use full Xcode and the existing unsigned policy; the project still needs
the pinned SDK from `./scripts/fetch-sdk.sh`, though neither new target links it.

Launch, window/root, minimal and guide phases share a single 180-second
active-case deadline for explicit waits. Synchronous XCTest launch, query and
click calls cannot be preempted by that deadline. No custom watchdog, forced
cleanup, retries, permission changes or prompt responses are added; ordinary
XCTest lifecycle handling remains framework-owned. Xcode Helper permission and
unsigned runner readiness are unproved until hosted execution. Apple documents
that UI testing may itself generate an OS permission prompt; an unanswered prompt
or signing/Helper failure is not a pass. Separate `guide-ui-consumer-probe`
artifacts retain source hashes, phase logs and the complete xcresult with failure
screenshots. Before the exact identifier-and-title window query, one public XCTest
application-hierarchy attachment captures at most 16,384 characters and records
whether it was truncated. It diagnoses missing window exposure without selecting
another window, falling back to another attribute, or extending the deadline. Result validation
checks the exact test plan independently from the project/target URL and
reconciles XCTest's empty-argument method spelling with its reported identifier;
missing or mismatched identities remain failures.
Text logs redact checkout/home paths; framework-owned xcresult may
contain the disposable runner's build paths. Neither a screenshot nor a new
probe pass establishes full native guide acceptance.

On the next explicit **Enable Copilot Integration**, setup removes only its old
`Copilot/plugin/skills/maestro/SKILL.md` copy, if present, using owner-checked,
non-symlink traversal. It preserves other skills and files, including lifecycle,
icon and global guides; it never sweeps global paths or cached/live sessions.

### Disable or uninstall

Use **Remove Copilot Integration…**, then explicitly confirm. After ownership
and metadata checks, this disables and removes only the recognized dedicated
file, runs `copilot --no-auto-update plugin uninstall cmux-maestro-native`
when installed, verifies removal, then removes Maestro's native loader entry
point and launch configuration. Foreign or modified observer files are refused.
Global settings and disable keys are not removed. Live route bindings,
sockets and in-memory adapters are not touched; close those sessions normally.
Restart/resume existing CLI
sessions to unload their cached hooks. Disable this sidebar in CMUX separately
if desired; uninstall does not select or remove any other provider.
It also leaves the separately installed global guide untouched.

For individual future CLI launches, either `CMUX_COPILOT_HOOKS_DISABLED=1` or
`MAESTRO_NATIVE_DISABLED=1` suppresses identity hooks. The legacy
`MAESTRO_DISABLED` flag is not changed or used by this integration.

## Data and trust boundary

- The small native executable lives at
  `CMUX Maestro Preview.app/Contents/Helpers/CMUXMaestroCopilotHook`.
- Only `sessionStart`, `userPromptSubmitted`, and `postToolUse` hooks run it.
  No veto/control, pre-tool, or agent-stop hooks are registered.
- It accepts bounded JSON with canonical `sessionId`/`session_id`, plus its own
  inherited `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID`. It never accepts a
  transcript path or infers identity from a title, current directory, or text.
- Same-user BSD process metadata identifies a matching **ancestor**, not
  blindly the hook's shell parent. A source `inuse.PID.lock` and stable process
  generation must agree before the helper publishes an atomic binding.
  Symlink traversal, stale owner generations, and mismatched live owners fail
  closed. A missing early session-start marker can be retried on a later hook.
  The helper and sidebar share the marker/process verifier: marker contents are
  never read, and no content-size limit is imposed. Birthtime/ctime and the rest
  of the marker stat snapshot must remain stable; unknown or multiple live marker
  owners are ambiguous rather than guessed.
- Bindings live under
  `~/Library/Application Support/CMUXMaestroPreview/Copilot/bindings/`.
  Own directories are `0700`, files `0600`; dates use milliseconds since 1970.
  The last diagnostic is a bounded generic status, never a hook payload, path,
  credential, transcript, or raw CLI error.
- Terminal control runs in the installed standard-library Python controller at
  `~/Library/Application Support/CMUXMaestroPreview/Orchestration/bin/`.
  Private prompts, results, control tokens and process identities remain under
  `control/`; the sidebar sandbox grant reaches only the bounded sanitized
  `observer/` directory and cannot read sibling control, binary, task or result data.
  The controller uses exact CMUX workspace, pane and surface UUIDs. It never
  infers ownership from labels, paths, focus, chronology, or terminal text.
- The outer hook shell redirects both output streams and returns zero even
  when the helper is missing, fails, or crashes. Hooks cannot supply prompt
  content, tool decisions, or control commands.
- The sandboxed sidebar first performs a bounded scan of Maestro-owned,
  sanitized routing records in `bindings/<sessionUUID>.json` to find records
  matching the host's granted surfaces. Unrequested records are rejected before
  process or session-file reads; their identifiers, counts, and content are not
  returned. This routing-index discovery is distinct from reading transcripts.
- Only after surface filtering and stable live-identity verification does the
  sidebar read that session's durable events beneath **the real user's**
  `~/.copilot/session-state/`. It displays sanitized, allowlisted metadata,
  never raw transcripts. It does not launch the helper or install anything.
  Tree navigation uses the CMUX extension API and current host snapshot.
  Unavailable evidence is not fabricated as a live session.

The source contract is Copilot CLI's current durable session/event format.
Only the **standard Copilot home** is supported; custom `COPILOT_HOME` and
symlinked state directories are not supported. Missing lifecycle events can
leave completion/status unknown, and agent IDs are not automatically native
child-session IDs. No title/transcript heuristics repair missing identity.

### Temporary status observation loss

The confirmed first status/visibility slice of #119 keeps the existing bounded
reader and two-second polling pause. Ordinary updates should appear in roughly
2-3 seconds; 10 seconds or more is too slow. This is a practical responsiveness
goal, not a new session cap or a reason to increase read bounds.

When an ordinary read fails or reliable observation expires, the sidebar keeps
the exact subject's last known **visual status for five minutes**, then quietly
shows **Status unavailable**. A fresh valid observation restores current status.
Idle chat is not observation loss: a verified unchanged event-file boundary is
still a fresh observation. Replayed or older evidence cannot restart the grace.

Display memory is separate from current session evidence. The eight-second
trust limit is unchanged; retained status grants no identity, focus,
acknowledgement, dismissal, permission or lifecycle authority. Access denial,
invalid/ambiguous identity, confirmed removal/replacement, and changes to
window, placement, grants or managed generation invalidate the retained display.
Recovery after those boundaries requires a new valid observation; an unreadable
cached observation cannot seed display memory for the new scope. Unsupported
child lifecycle events keep their warning and unknown child state without
suppressing independently validated sibling chats.
Partial data can also contain a fresh, valid unknown status; that alone is not
an observation failure and does not remove the observation before reconciliation.
Internal tasks keep their original real open parent, without actionable stale
outcomes. Actual open background tabs remain reachable through current host
metadata; unknown chats without a real open surface are not fabricated.
A browser replacing a terminal cannot inherit the terminal's agent observation.

The regression workload uses 20 synthetic open background tabs with real bounded
file reads, fake-clock idle/failure transitions, and measured reader/projection
cost. Its timings exclude the two-second pause, host delivery and rendering;
they are not a stock-host end-to-end latency claim. A possible 100-chat day
remains a nonblocking goal. This slice does not complete #119 or authorize
installation, broader settings architecture, or lifecycle changes.

## Sidebar layout

When a coordinator explicitly registers a terminal-backed run, its coordinator
→ worker → nested-worker relationships become the primary compact hierarchy.
Every worker is a genuine unfocused terminal tab in the coordinator's current
CMUX pane/workspace. Rows show safe labels and explicit lifecycle state; Details
contains exact run, parent, worker, workspace, surface and generation IDs.
Selecting a current row uses the existing typed CMUX Focus action. Each workspace
appears once: explicit managed agents and remaining terminals share its outline. An exact
managed workspace/surface pair normally replaces its observed terminal row.
If fresh, unique live observation proves a different session ID on that pair,
the observed session keeps its own primary row. Unneeded old registrations and
their exact unprotected observed copies are omitted automatically in both views,
regardless of **Show ended agents**. Unrelated incomplete history does not hide
the current session or keep an otherwise unneeded old registration on screen.
A recorded failed turn qualifies only when its exact original session is freshly
confirmed dead and the current replacement is verified; the failed phase alone
never proves that the old work ended.

Ancestors and original-session content needed by known descendants, unresolved
attention or incomplete own evidence remain as **Work context**. Their actions
inspect that context, not the replacement terminal; each descendant keeps its
own state, attention and supported navigation. Counts distinguish required
context from current agents. Both views put current content before old context.
Captured focus actions stay bound to their original workspace and surface;
after a move, use the newly rendered row.

This is presentation filtering, not deletion, session termination or an inferred
end state. Stored registrations, observations and history preferences stay
unchanged. Missing, stale, denied or ambiguous replacement evidence preserves
the conservative view. Names, paths and guessed relationships never establish
ownership.

The installed skill exposes `launch-coordinator`, `launch-settings`, `status`,
`focus`, and `archive`; `register` and exact stale-surface `recover` remain for
legacy lifecycle ownership. Registration is not messaging adoption.
Start a new managed coordinator with an explicitly selected initial account and
model. Its public `maestro_identity` tool reports the actual session/account
without credentials. Native `maestro_spawn` reads that session's current account
for each child, retaining explicit model selection and permission bounds.
Saved account defaults and unrelated Git authentication never select a child's
subscription. Missing identity/API/credentials fail before terminal creation.
The current credential resolver uses GitHub CLI's keychain-backed account
store. Authenticate the required account there once; a Copilot-only login is
not silently imported or replaced with another GitHub CLI account.
Ordinary shell `spawn` cannot establish that evidence and refuses; source-only
disposable proof compatibility is not a production fallback. **New workers are
interactive Copilot sessions**, launched with `--interactive` and the initial
task. Their terminal is a normal conversation: humans can type follow-ups and
answer permission/questions directly, and completing a task does not close it.
Copilot itself owns terminal I/O, including Ctrl-C; there is no interactive
supervisor or captured JSON stream. An observed process exit never claims task
success. New workers cannot be
launched in headless mode. Invisible SDK tasks must not be substituted for
visible Maestro roles when startup fails.

Native `maestro_close` requests closure of one explicitly authorized, currently
owned direct child using its exact `workerId`, `workspaceId`, `surfaceId`,
`sessionId` and `generation`. It validates private native authority, process and
session-source anchors, current workspace membership and launch fences, then
sends one initial stock CMUX `surface.close` with documented Boolean
`force: true`, selecting its noninteractive route. This is not a public toggle or
an escalation after refusal. No sidebar control or host change is involved.
Inherit stock host refusals, including the last terminal; this is not UI-close
parity. Earlier CMUX 0.65 requests omitting the field returned
`confirmation_required`; tagged source confirms the false default. The source
contract is corrected, but installed/live proof remains separate. No retry,
force-after-refusal or confirmation fallback is used.

Omitted `scope` or `"scope": "target-only"` preserves that single-target contract.
Explicit `"scope": "subtree"` captures the exact child's private descendants
once and attempts safely admitted targets descendants-first, at most once.
Refused or unknown descendants do not block independently valid siblings or
parents. Every selected identity appears in `results`, with `attempted`,
`outcome`, a compact `reason`, and `removal: "unconfirmed"`. New children and
replacement identities never enter the pass. Its 45-second budget and five-second
target windows leave remaining targets explicitly not attempted; an oversized
complete result plan or an unrepresentable numeric generation refuses before host
effects, preserving the existing numeric wire without rounding identities.
Missing captured sessions are refused individually. Loss of the invoking worker's
stored session between targets preserves prior results and refuses remaining
targets without changing shared native authorization. Pre-dispatch expiry is not
an attempt; malformed host text after dispatch remains unknown and does not erase
prior results or stop valid remaining targets. The existing 60-second,
65,536-byte adapter transport remains unchanged. Synthetic source/transport
coverage does not replace separately authorized disposable live-host proof.

`closeAccepted: true` with `removal: "unconfirmed"` means only local request
acceptance. There is no disappearance wait, retry, provider shutdown, typing or
force-kill fallback; timeout/cancellation/lost replies remain uncertain. Records,
unselected descendants and resource accounting stay intact. Missing or changed
provider/source evidence refuses rather than closing a possibly repurposed
shell. Separate preflight and UUID-based host close are **not atomic
session/generation fencing**. See the
[installed lifecycle guide](.agents/skills/cmux-maestro-orchestrate/SKILL.md#request-an-owned-child-or-explicit-subtree-close)
for the exact tool shape and source limits.

Interactive startup uses `surface.create` with `initial_command`, rather than
CLI `new-surface --command`, which queues input behind interactive shell
initialization. Only the caller's executable search path is added to the startup
environment; credentials are not passed through the host creation request.
Because the host may rewrite that environment, the launch record also captures
the validated absolute Copilot executable and caller search path privately.
The one-shot non-login shell sources a private launch environment, restores
that PATH and immediately `exec`s the absolute Copilot executable with a fresh
`--session-id` and `--interactive` prompt. Pinned subscription credentials are
resolved through the existing bounded GitHub CLI lookup directly into the
process environment, never persisted or included in the host command.
Necessary authorization, setup, create/attach and individual I/O remain bounded.
**Return is immediate after exact terminal creation/ownership:** no supervisor
acknowledgement, sleep, startup observation window, hook/model/provider wait or
optional readiness gate. Creation acceptance does not establish provider start.

One reusable prompt wrapper preserves the original task verbatim, explains
human interaction, exact `maestro_peers`/`maestro_send` discovery and genuine
envelope-sender replies, fire-and-forget uncertainty and the prohibition on
terminal-input fallbacks. It supplies a genuine coordinator address only when
available. The agent begins its task without a startup acknowledgement;
`/maestro-minion` and other slash skills are not launch dependencies.

Private native bindings are prepared **before** creation. After joining its
exact CLI-owned conversation, the native adapter independently records the
session/generation/surface and the exec-preserved provider PID/start identity,
verifying process ancestry. This can occur before or after caller attachment;
neither side waits for the other. Hooks remain independent observers, not tool
providers. Missing/late hooks or native observation are unknown, not death.
If the caller disappears or creation/attachment is ambiguous, the lease,
private setup and capacity remain retained: Copilot may already be running.
No failed caller may guess that it prevented execution.

Managed interactive rows and workspace counts use fresh, uniquely exact
session/workspace/surface observations in both `launching` and `turn-running`,
even when controller metadata is older than its 60-second freshness budget.
Native process observation alone never means Working: absent, stale or ambiguous
work evidence remains unknown. Git provenance keeps its own freshness budget;
fresh session activity does not refresh an old branch, worktree or change count.

Launch receipts and private `status` distinguish the evidence below. This
applies to interactive sessions and preserved legacy bounded workers; neither
receipt is a turn-completion boundary.

| Field | Evidence, not inference |
| --- | --- |
| `launchAccepted` | Exact native surface attached to the owned launch; `null` for older records without this fact. |
| `startup` | `pending`, `provider-observed` for direct native observation, legacy `supervisor-started`, or `failed`; none establishes model readiness. |
| `initialTask` / `taskConsumption` | Direct launches remain `configured` / `unknown` even after a native process observation. Legacy `submitted` retains its previous process/result boundary meaning. |
| `supervisorStarted` / `providerStarted` | Corresponding process identity recorded, not necessarily still running. A missing provider anchor is not proof it never started. |
| `supervisorRunning` / `providerRunning` / `surfacePresent` | Current exact process/inventory observation: `true`, confirmed `false`, or unknown `null`. |
| `messaging` / `messagingAvailability` | Wiring is `configured` or `unsupported`; configured availability remains `unknown` here. Native peer observation is separate. |
| `workObservation` | `unavailable` without supported work evidence, or `reported-result` at a strict verified legacy result boundary. Interactive work still uses existing session-event observation, not this launch receipt. |
| `surfaceOwnership` / `observedAt` | Exact, unassigned or unresolved ownership, and the controller observation timestamp. |

`render_health`, quiet periods, terminal output and elapsed time prove none of
these phases. Inventory/probe errors remain unknown, not death. A confirmed
missing surface can cancel an unchanged **legacy** unclaimed lease. Direct
launches cannot infer that Copilot never ran: unresolved leases stay retained,
and a missing process anchor prevents reclamation. Status captures process and host
probes outside the global write lock, then applies only identity/lease-matched
evidence under the lock. Launch receipts revalidate current ownership and the
lease at attachment without startup probes. Changed identities discard status
probe facts to `null`; retained facts keep their capture timestamp. Cancelled
legacy leases refuse late execution; direct native observation refuses
foreign surface/session/generation/token/process identities without adoption.
No duplicate spawn, focus change, terminal input or automatic process cleanup
is attempted. Pending launches retain their credential and capacity slot.
If a create reply is lost, an unidentified possibly-created terminal retains
its slot and blocks archive/recovery; missing surface identity is not proof
that no resource exists. Reconcile the original launch rather than retrying it.
Verify exact surfaces, native tools, and returned evidence separately.
Root callers must retain the private custody receipt even when startup returns
`ok: false`; its control token remains private. The controller preserves bounded
setup/attachment errors in private receipts and lifecycle diagnostics. Provider
exec or extension errors remain visible in the terminal; absent native
observation cannot be converted into a controller success or failure claim.
Managed coordinators have their own controlled sessions and runs; existing
conversations are not converted. A live or uncertain legacy supervisor blocks
the new coordinator schema; the launcher fails rather than interrupting it.
Existing provider sessions do not need to be ended when their old supervisors
have already exited. Resource reconciliation retires only unchanged records
with absent surfaces and proven process exit, never an active launch lease.

The lifecycle `follow-up` command remains refused for interactive workers.
Participating peers instead use native fire-and-forget messaging below; no prompt
is injected into terminal input. Close interactive Copilot normally
before archiving; archive does not interrupt it. Existing legacy workers are
preserved and visibly labeled **Legacy worker** rather than silently converted.

### Native peer messaging

After explicit integration setup, select the initial coordinator account and
model in **Agent launch settings**, then use `launch-coordinator`.
`launch-settings` reports `messagingInstalled` separately from saved-account/
model `ready`; neither field proves a recipient has loaded its native adapter
or identifies the invoking session's account.
New installed-controller spawns automatically bind their exact Copilot session,
generation and CMUX workspace before launch and enable CLI native extensions
with `--experimental`. No per-project fixture preparation is needed. Ordinary
unmanaged sessions, existing workers, and registered coordinators without a
launcher-owned Copilot session remain **unsupported recipients**. Never adopt or
restart them automatically.

Use global `/maestro` for `maestro_peers` discovery, `maestro_send`, and replies
to the supplied sender address. Any participating same-workspace peer can send,
including siblings and peers from another run; messaging grants no lifecycle or
process-control rights. The native adapter joins only its CLI-owned session and
uses `session.send({ prompt, mode: "enqueue" })`. Copilot owns scheduling.
No sidebar, selected workspace, foreground application, terminal keystroke,
composer inspection, acknowledgement, receipt, retry or completion tracker is
involved. A local-write attempt is **not** a delivery or completion guarantee.
The source package and unchanged confirmed purpose live in `skills/maestro/`.
It has no tool-permission grants in frontmatter and reuses the installed
`/cmux-maestro-native:cmux-maestro-orchestrate` skill for lifecycle operations.
For the skill tool, pass `{"skill":"maestro"}`. Only the existing lifecycle/icon
plugin slash commands remain namespaced; the global messaging guide is not.

For prospective native children of an interactive managed parent, omitted
`allowTools` and `yolo` inherit the parent's explicit **recorded launch policy**.
A deny-only request keeps that recorded mode/allows and adds denies. An explicit
`allowTools` list (including `[]`) or `yolo: false` selects requested default mode
without `--allow-all`; omitted allows still inherit, and parent denies survive.
Default-mode parents retain literal allow-subset checks. Recorded YOLO parents
permit bounded finite child allow rules without redundant parent allows, while
retaining all denies and wildcard/broad-rule rejection. A coordinator
may request `yolo: true` **only with explicit human approval**, without a narrowing
allow-list; combining both intents refuses. Workers' explicit YOLO requests still
refuse before credentials/reservation, separately from inheriting parent YOLO.
Missing recorded provenance or policy drift before reservation refuses.

This is **recorded/requested policy, not verified current provider permissions**.
Human `/permissions` changes can make launch records stale. In particular,
Copilot's `defaultPermissionMode: "allow-all"` or `COPILOT_ALLOW_ALL` may elevate
a new session despite omission of `--allow-all`; requested default mode is not
proof of actual manual startup. The inspected SDK exposes current mode/path
getters but no verified complete current tool/deny/URL policy snapshot or atomic
same-or-narrower external-child admission. Full live inheritance/restricted-startup
acceptance remains unverified. No permission callback, persistent setting change,
or launch-then-policy mutation is used.

Each native child has one private Unix socket and a launcher-created binding
under `~/.copilot/extensions/maestro/r/`; account credentials never enter these
files or messaging tools. Addresses contain workspace/session UUIDs and generation,
not secrets. Payloads are limited to 4 KiB UTF-8, frames to 8 KiB, registered
participants to 128, and connections/pending native sends to eight per receiver.
The per-workspace live managed session cap, defined by `MAX_LIVE_WORKERS` in
[`scripts/cmux-maestro-orchestrator.py`](scripts/cmux-maestro-orchestrator.py),
includes managed coordinators and retained resources. Routes use exclusive
creation, are retired after exact provider exit (or closed-run archive), and cannot
be rebound by clearing/resuming a conversation. Restart/clear/replaced-session,
offline, unsupported, invalid or stale routes fail closed; request fresh managed
sessions only with user authorization. Same-user processes are trusted: private
capabilities are not a defense against a malicious process running as your user.

See [native delivery findings](docs/delivery-proof.md) for the observed agent
exchange, human-confirmed draft preservation, separate harness-origin background
check, and outstanding installed-product live acceptance. Mocked contract tests
are not native UI proof.

### Local agent launch settings

The containing app's **Settings > Agent launches** tab provides **Launch agents with
subscription:** and an optional worker-model setting. The dropdown lists
configured GitHub.com accounts from GitHub CLI without displaying credentials;
it does not infer subscription plan names. **Use Copilot default** leaves
authentication and model selection to Copilot.

Preferences live only in the user's private Application Support
`CMUXMaestroPreview/Orchestration/worker-settings.json`, not in this repository.
The project ships no account or model pin. A configured account is resolved from
its stored credential at launch and passed only through `COPILOT_GITHUB_TOKEN`.
Unavailable credentials fail closed before a new terminal is created; there is
no silent fallback to a different account. Tokens are not written to settings,
state, launch tickets, arguments, observer files, or logs. Git identity and the
active `gh` account are not switched. Changes affect only future workers. Direct
controller callers may retain Copilot defaults by omitting the requirement flag;
the bundled orchestration skill deliberately does not and always requires the
pinned Maestro account and model.

### Optional per-launch preferences

Native `maestro_spawn` accepts optional `model`, `contextTier` and
`reasoningEffort` strings. Omission preserves existing configured launches,
without a model query, new warning or context/effort flag. No activity defaults
are inferred from worker names, roles or task text.

For explicit preferences, the existing joined extension reads
`session.rpc.model.list()` using that session's authentication context and
checks the invoking account before and after. Only bounded model IDs,
supported tiers/efforts and advertised default effort enter private launch
evidence; raw model/billing/quota data does not enter state, prompts or host
commands. Provider-native defaults are validated against raw advertised support;
valid defaults outside the current CLI's effort levels are omitted from the
projection, not invented as CLI flags or used to reject unrelated selections.
Malformed, duplicate, oversized or foreign evidence and account drift
refuse before launch. This is a capability snapshot, not atomic account/provider
admission or an observation of the child's running settings.

Supported selections feed the actual `--model`, `--context` and
`--reasoning-effort` arguments. Unsupported safe optional requests **warn**:
an unavailable requested model falls back only to the configured pin when that
pin is available in the session catalog; no available configured fallback
means refusal, never arbitrary model substitution. A valid selected model
survives an unsupported context/effort request: context falls to its default
tier, effort to its advertised default (or no override when unavailable).
Unavailable experimental model lookup warns and preserves the old configured
launch without applying optional overrides. Unsafe input, missing credentials,
ownership, permission and capacity failures are not preference fallback.

The bounded private `launchSelection` record and receipt distinguish requested
preferences, configured arguments, evidence source and warnings; `observed`
remains unknown. `long_context` is a supported tier, not a numeric context-window
claim. Account entitlements and actual provider application remain unverified
until independently observed. On a supporting installed adapter,
`maestro_identity({"includeModel":true})` reads the responding session's
`session.rpc.model.getCurrent()` and returns a bounded `modelObservation`:
`observed` with source, timestamp and the actually reported model/context/effort,
or `unavailable` with a reason. Unreported context/effort is omitted, not replaced
with launch defaults. No catalog, plan-model alternative or raw error is returned.
The account and exact binding are rechecked after the read; drift refuses.
Default identity calls preserve their existing account-only behavior and make
no model query. A parent cannot use this to observe a child; the child must make
its own explicit query. This does not wait for startup, poll, persist observations,
switch models or prove entitlement, token-window size or installed execution.
The timestamp is local collection time, not an atomic provider revision.
A reported virtual `auto` model does not identify the backing model of a turn.

The CLI adds `spawn --model`, `--context-tier` and `--reasoning-effort`. Direct
callers lack joined-session evidence, so new selections warn and retain
configured defaults. `launch-coordinator --model` keeps its pre-existing
explicit-over-configured precedence and syntax validation, without claiming
session-catalog support; its new context/effort options warn and remain omitted.
Neither native Settings nor persistent Copilot configuration is changed.

### Workspace launch capacity

The controller's `capacity --workspace <workspace-uuid>` command returns a
read-only, **advisory** preflight without provider credentials or host RPCs.
Authenticated `status` also includes the same workspace-wide `capacity` summary,
including managed roots, workers, retained resources, pending launches, used
slots, configured limit and workspace stored-node slots. Pending leases are
already counted through their managed nodes, not added twice. Unknown or stale
process/terminal ownership is not free capacity.

To persist a limit, a human-directed workspace coordinator uses:

```sh
python3 scripts/cmux-maestro-orchestrator.py capacity \
  --workspace <workspace-uuid> --limit 64 \
  --actor-id <coordinator-id> --token <private-control-token>
```

Keep the control token private, as with other authenticated controller commands.
Worker actors and coordinators from other workspaces cannot change the limit.
Limits are integers from **1 through 128**, defaulting to **32** when omitted.
They live in the existing private `Orchestration/control/state.json`, separately
from account/model settings; native Settings does not edit them. Lowering a limit
below current usage preserves every session and retained resource and refuses
new admissions until usage permits them. No automatic cleanup or reuse occurs.

A successful preflight reserves nothing. Root and child launch reservations
recheck the latest limit and exact resource usage inside their exclusive
transaction. The separate **128-node per-workspace** and **8-level** bounds still apply, so a
configured limit of 128 is not a guarantee of 128 available nodes or demonstrated
128-provider load. `storedNodes`, `storedNodeLimit` and `nodeSlotsRemaining`
count only the queried workspace, including resource-retired history and
registered coordinators. Another workspace's history does not consume these
slots. Retained terminal records remain separately bounded to 128 per workspace.
Live-workspace `remaining` alone is not an
admission check. History exhaustion is not repaired by increasing live capacity,
closing a tab, or deleting records automatically.

Independent **host safety limits** bound the shared store: 1,024 total nodes
(including leases), 1,024 retained resources, 128 configured workspace-limit
entries, and 1 MiB each for state and observer/icon output. Preflight exposes
`hostStoredNodes`, `hostNodeLimit`, `hostNodeSlotsRemaining`,
`hostRetainedResources`, `hostRetainedResourceLimit`,
`hostRetainedResourceSlotsRemaining`, `hostStateBytes`,
`hostStateByteLimit`, `hostStateBytesRemaining`, `hostCapacitySettings` and
`hostCapacitySettingLimit`. These are distinct from
workspace allowances; a host protection refusal names its host bound.
Current byte room is advisory, not a guarantee that a proposed record fits;
the actual serialized state/projections are checked before external creation.
There is no automatic pruning, quota bypass, state reset or live migration.
Schema-1 saved states remain readable. Older installed readers/controllers
retain their previous bounds until an explicitly authorized upgrade; source
publication alone does not activate the multi-workspace allowance (#167).

The shared managed-message route scan has matching finite host bounds:
1,024 private bindings and 2,048 directory entries (route/socket pairs), with
at most128 participants in the responding workspace. Other-workspace bindings
are validated but omitted from its peer list; send/receive retain exact address,
generation, capability and frame/body checks. Legacy proof transport is unchanged.
Saved schema-1 UUID spellings share a canonical workspace census without
rewriting ownership records or migrating the store; equivalent case spellings
cannot obtain separate node/retained allowances.

Lock acquisition retains the existing 32-session reference
policy: ordinary waits remain bounded to 4 seconds, two-second waits to 8 seconds,
and zero-wait requests remain immediate, regardless of workspace capacity.
Upstream activation ordering and installed-runtime validation are separate.

### Legacy bounded-worker compatibility

Existing bounded workers retain `follow-up` and `report`. Follow-up is privately queued only after a directly owned
worker has a successful exact-session boundary for its current generation, then
uses that worker's preassigned exact `--resume` session ID. Explicitly reported
outcomes are preferred; a report-missing or permission-denied generation may be
re-prompted without claiming that its earlier task succeeded.
The supervisor multiplexes bounded JSON output and promptly forwards provider
diagnostics while continuing current-generation heartbeats during silent turns;
it never answers permission prompts. Noninteractive Copilot can deny a tool in
JSON without offering an interactive prompt, so stderr inheritance is not a
permission mechanism. Terminal existence and a zero CLI exit are
not success: completed, blocked and failed states require both a successful
exact-session process boundary and one strict generation-matched whole-final-
message report. The report is versioned, identity-bound and permission-free;
ordinary prose, fenced or extra JSON, tool-bearing final messages, and dual
helper/final reports are refused. It remains a worker self-reported outcome,
not independent artifact validation or reviewer acceptance. Missing reports,
permission denials, nonzero
or malformed turns, startup failure, process
disappearance and terminal disappearance remain distinct. An explicit launch
lease prevents archive from crossing CMUX surface creation/attachment, and any
exact surface created before a later launch failure remains accounted. Eight
still-live managed worker resources are allowed per workspace;
reported completion does not free a slot. Archive retains bounded history and
never kills processes or deletes tabs, so still-present archived worker tabs
continue to consume the resource bound. Tool permissions are not auto-approved.
Interactive archive checks exact process exit under the lock both before
admission and before deletion; failed process probes remain uncertain, not
proof of exit. Interactive-only runs need no cooperative stop marker, so a
refused archive leaves their records, messaging routes and archive flags intact.
Cancelling an unclaimed launch lease records explicit pre-runtime failure
evidence. Stale recovery can retire that never-started worker after its exact
surface is closed (or when creation produced no surface), even without process
anchors. Missing anchors alone, idle time and startup timeouts are not exit
proof; the no-start evidence requires the lease cancellation before runtime
claimed ownership. Legacy supervisors retain their cooperative archive stop.
Read-only controller snapshots use shared locks; state mutations remain
exclusive. Idle supervisors therefore do not serialize their status reads
behind the mutation lock as a workspace approaches its worker limit.
Spawn accepts bounded caller-explicit `--allow-tool` and `--deny-tool` rules;
registered/legacy defaults add no grants, denies win, and descendants cannot
exceed their parent's explicit allows or remove inherited denies. Prospective
native interactive children inherit recorded parent policy as qualified above;
legacy bounded behavior is unchanged. These Copilot flags are policy controls,
not an operating-system sandbox. No shell or wildcard grant is synthesized from
tool visibility or prompt text; recorded parent YOLO and explicitly approved
coordinator YOLO requests append `--allow-all` while retaining denies.

The default view is a restrained workspace outline. Primary semibold workspace headers
contain explicit coordinator → worker → nested-worker rows, with guide lines and
durable disclosure by stable node identity. Each row leads with its safe name,
then one quiet kind/location line when the external controller verified those
facts from the explicitly assigned working directory. The worktree label is the
verified repository root basename; the branch label comes from `git symbolic-ref`.
Detached `HEAD` omits the branch while retaining the verified worktree. Non-Git
directories, missing directories, timeouts, invalid output, overlong output and
failed root queries publish no Git labels rather than calling a directory a
worktree. The controller refreshes exact assigned-directory evidence at bounded
worker heartbeats, turn boundaries, follow-up queueing and explicit status checks.
Each projection carries a separate Git evidence status and capture time. Stale
verified locations remain useful context, with a static unverified-state cue and
explicit **last verified** hover/details and accessibility qualification; they are not presented as current
Git state. Unavailable evidence is omitted. Probes are batched by assigned directory and run outside the global
state mutation lock. The sandboxed sidebar never runs Git and never receives the
private full assigned path through observer metadata.

Managed rows show concise worktree context beside the exact state cue. Hover,
Details and the existing pinned footer retain Git diagnostics. Fresh Git evidence
carries a changed-file count and **+green / -red** tracked-text line counts
against `HEAD` (staged and unstaged changes combined). File totals include
untracked files and binary changes; line totals exclude them and submodule
contents. Renames count once. Conflicts, unborn `HEAD`, failed or oversized
probes, and stale evidence never become zero counts. Counts are sampled, not an
atomic snapshot of concurrent edits. Missing current counts remain unavailable.
Count freshness uses its own timestamp, independent of branch metadata refreshed
by older supervisors.
Only bounded aggregates cross into the sandbox; paths and file contents do not.
Existing controller versions omit these optional fields. Refresh the native
integration explicitly to install the new controller; existing supervisors and
sessions are not restarted or taken over to populate counts.

Nonblocking notices use a Design 06-inspired green, with a darker light-mode
variant; blocked and failed states are red. Words and symbols distinguish attention from active work or
successful outcomes. Generic Copilot session names and short IDs no longer lead
outline rows: shared-surface titles and state lead instead, while exact session
identity remains in details.

Agent icons are drawn from the bundled **Nerd Fonts Symbols 3.5.1** font and its
pinned glyph-name catalog. No system font installation or uploaded images are
required. The catalog offers **10,994 drawable names**; the intentionally empty
`cod-blank` entry is excluded. Role favorites are presets, not the selection limit.
Ordinary terminal tabs use `md-ghost`; browsers use `fa-edge` (U+F282).
**Sidebar settings → Agent icon** chooses the fallback robot or Copilot glyph for
sessions without an explicit selection.

Click or right-click an **agent, terminal, or browser icon** to open its anchored
picker. Search all bundled glyph names (including role aliases), choose a color,
and use **Done** or Escape to close. Keyboard users can activate the icon button,
use Down from search and arrow keys in the grid, or Tab through the controls.
**Show details** remains a separate action inside the popover. Opening the picker
and changing appearance do not focus a terminal, mark attention as read, or send input.
Provider-child observations and native agent surfaces without an exact session
identity are not customizable; other surface kinds retain their standard icons.

**Your choice** wins over later agent metadata. **Reset to default** explicitly
chooses the standard appearance, while **Reset to agent selection** follows the
agent's current choice (or the default when absent). Human preferences persist
by exact session UUID, or stable native surface UUID for non-agents, across restarts,
view changes and pane moves. They never transfer to a replacement session in the
same pane. Agent metadata remains separate and untouched. The sandbox stores these
bounded, coordinated preferences in its own Application Support
`CMUXMaestroPreview/sidebar-icons.json`; no additional filesystem or network grant
is required. Read/write failures are visible; **Sidebar settings > Reset all icon
preferences** is the explicit recovery action. Pets and favicon fetching are not
part of this picker.

`SidebarIconPicker` is a controlled, reusable SwiftUI view: inject a
`SidebarGlyphCatalog`, `SidebarIconChoice`, source/notice text, and callbacks for
selection, resets and dismissal. `SidebarIconPickerButton` provides the native
primary/secondary-click and keyboard anchor. Neither component reads preferences,
knows session identity, or calls the host. `SidebarItemIcon` is the thin sidebar
adapter that owns the popover and connects those components to persistence.
The picker uses inherited native appearance and semantic colors, with a neutral
catalog grid; only an explicitly selected icon color and the swatches add color.
It does not hardcode themes. Automatic CMUX/Ghostty palette inheritance (for
example, switching between Nord and Tokyo Night) is tracked in
[#67](https://github.com/jdylanmc/cmux-maestro/issues/67): the pinned
sidebar SDK does not expose the host's resolved theme colors. Native light/dark
adaptation is not a claim of custom terminal-palette matching.

Only the workspace **name text** triggers its passive hover preview; disclosure,
blank title fill, and actions do not. Leaving that text cancels or dismisses the
workspace hover immediately. Agent previews retain a 300 ms crossing grace.
The shared native card prefers the right edge, fits the available screen, and
scrolls long metadata. Hover waits 350 ms. Keyboard focus on a title previews it
without pressing it; **Tab** enters its preview controls and continues past the
originating title after the last control. **Escape** or **Shift-Tab** returns to
that title; the next **Tab** continues onward instead of re-entering the preview.
Explicit previews also close on outside
interaction. Workspace previews
show only current granted workspace metadata and shared-surface counts; denied
or ambiguous evidence is labeled unavailable.

`SidebarHoverRegion` and `SidebarHoverCard` accept presentation data, independent
of sessions, navigation, preferences, and the bottom details. Passive panels
cannot become key/main windows. Only an explicit Preview action enables keyboard
interaction; closing that preview restores its original responder when appropriate.
Right-click a row, use its transient overflow, or press **Shift-F10** on its title
for the same native grouped menu. Opening it is passive. **Preview details** is
also passive; **Open details** retains the existing explicit mark-read behavior.
The overflow occupies a stable 24-point slot with a 2-point gap; revealing it
never changes the title's width or truncation, and hidden controls are not keyboard stops.
Managed inspection requests retain the captured node, run, generation, session,
workspace and surface. A changed subject shows **Details no longer available**
without inspecting or marking the replacement read.
Icon-direct right-click still opens the compact icon picker, not the row menu.
Menu icon requests retain their exact identity; a replacement target shows
**Icon target changed** rather than applying the old request to a new session.
Preview Close/Copy controls have an explicit native Tab order, independent of
system-wide keyboard-navigation preferences.
The hosted keyboard regression uses the production sidebar's automatically
constructed row key loop, including any intervening native controls. It requires
an unlocked graphical login so its
test-created windows can actually exchange key focus; it does not substitute
simulated key ownership when WindowServer denies focus.
AppKit rendering/interaction cases and the validation-host no-window assertion
share a test-only asynchronous gate across suites, held through fixture cleanup.
Other tests remain parallel. Motion captures fix and assert the logical viewport
before comparing exact native pixels; static controls retain a zero-change requirement.
Activity-only children offer **Open parent chat**, never an independent surface.
Unsupported pet, tag, backlog, placement and exit actions show disabled reasons;
menus add no capability or lifecycle authority.
Previewing never changes the **Active window** footer. It follows only the
current window's selected workspace and uniquely focused native surface.
Disconnected, redacted, missing or ambiguous focus clears the previous subject.
Ordinary terminals and browsers show native context without agent fields or a pet.
An agent on a terminal requires one fresh, live, exact observed session; managed
labels and Git context additionally require current, uniquely bound managed
evidence. Positively ended observations do not compete with a replacement live
session; unknown or ambiguous owners still prevent a unique current identity.
Reused surfaces, stale membership and matching titles never establish
ownership. Existing observation expiry updates the footer without a new timer.

The flush footer uses native adaptive colors and one small, original
**placeholder pet** silhouette for verified agents only. It is not a functioning
pet integration or a provider asset. Metadata is bounded and scrollable; verified
Git counts use the existing compact badge, full paths remain in Details, and the existing
session-ID copy control stays near identity. No context percentages, elapsed
durations, tags, pet preferences or lifecycle controls are added.
Steady connection success adds no label or row, leaving the footer lower while
preserving the host's 50-point clearance. Waiting, disconnection and navigation
errors or permission summaries remain visible.

The same preview is available on managed agent, observed session, and non-task
activity titles in Hierarchy and Taskboard. Internal tasks instead use passive
single-line names with complete accessibility labels and tooltips, not chat
navigation or identity previews. Each card resolves its own exact
subject and only current or explicitly last-known metadata. Missing/expired
observations are labeled, not replaced with invented model, context, timing or
Git metrics. Windowless children retain parent-session placement context.
Opening a card never invokes the existing inspection/mark-seen action; the icon
picker, title-to-focus action, and history controls retain their explicit semantics.

Agent previews put a **Copy session ID** button beside the exact session GUID.
Observed children label their inherited identity **Parent session ID** and copy
that parent GUID, never the child/worker/run/surface ID. Missing, ambiguous, or
unavailable session identity has no copy action. Open **Preview** for keyboard
access; hovering, opening, and refreshing never write to the clipboard.
A stale managed observation still offers its exact recorded session ID with
the existing last-known notice; copying does not imply the session is live.
Copying shows **Copied** only after the native pasteboard accepts the value;
failure shows **Could not copy. Try again.** Changing the GUID clears feedback.
The small `SidebarCopyableValue` control receives an injected action and knows
nothing about session lookup, persistence, host navigation, or the pasteboard.

Working agents use one 9-point open ring, rotating linearly once per second.
Reduce Motion keeps the ring static; questions and approval requests use a
distinct static exclamation mark. Working rows have no shimmer or moving wash.
Blocked rows retain a subtle static red background. Idle/unknown rows do not
pulse or glow. State cues belong to their exact row, never its descendants.
The selected workspace's uniquely focused surface has a glowing left border,
separate from activity and icon color. Other workspaces' remembered focus does
not light a border, and ambiguous/unavailable focus evidence does not guess.
Identity colors do not change this treatment. Icons have no wand decoration;
choosing an icon or role preset does not imply orchestration ownership.
Both densities use a single-line name and one quiet metadata line: 11/9-point
type in 46-point Compact rows, 12/10-point type in 52-point Comfortable rows.
Routine Unknown, State unavailable and Last verified prose moves to full help,
accessibility and details, not a third row. Unknown/stale states retain a static
dashed cue, never an idle or working claim; incomplete child-history context
shares that row's exact state cue instead of a redundant trailing info icon.
Protected attention and actual errors remain visible. Coordinator
activity comes only from a fresh, unique, live Copilot observation on its exact
workspace/surface; registration or child activity alone cannot start a pulse.
**Sidebar settings → Terminal icon** offers Ghost and plain `>_` styles.
Workspace summaries are action-only: questions/approval requests show **needs
input**, and other explicit blockers show **blocked**. Quiet workspaces show no
summary line. The top alert count uses the same rules; routine turn completions
do not inflate it. Managed and observed representations on the same exact
workspace/surface count once, and collapsed descendants still contribute.
Last-reported managed blockers stay visible with freshness qualified in help.
Agent totals, idle counts and repeated completeness warnings are not primary UI;
source diagnostics remain in details. Glyphs have 2 pt insets in their existing
24 pt slots.
Standalone state keys retain pause/check/error symbols for blocked, finished and
failed states. Workspace headers have a boxed disclosure;
their trailing ellipsis menu offers Focus, Expand/Collapse and Details as separate
actions. The six header shortcuts are directory-plus, Beats, Taskboard, History,
Maestro settings and Fermata, in that order. Settings reuses the existing sidebar
preferences; History opens the same popover at completed-work controls.
Taskboard temporarily toggles the existing sidebar view (its underline and
accessible state indicate selection); activate it again to return to the outline.
Reusable utility hosting is not implemented. Directory, Beats and Fermata explain
their unavailability without creating workspaces, schedules or power assertions.
Settings and the separate Details inspector popover have explicit Close controls.
The keyboard-accessible inspector scrolls independently, preserves full metadata
and Other activity, and revalidates window, placement, session, run and generation
identity against current permissions. Workspace-only details require current
workspace access, not surface access; paths remain independently permission-gated.
Surface and session details still require surface metadata. Replaced or revoked subjects show an
unavailable message instead of silently keeping the old data. Escape or Close
dismisses only the inspector; the footer has no Close or manual-pin override.
Rows use concise state labels rather than diagnostic walls; blocked/failed state, incomplete ancestry,
omitted active work and attention remain concise and visible. Selecting the state
glyph's Details action opens the inspector, not a replacement footer. Managed workers resolve verified
model metadata only when both their controller-issued Copilot session UUID and
surface match one fresh, live observation. Coordinators use one fresh, live,
unambiguous observation on their exact surface. Same names, directories, stale
or ended observations, unconfirmed owners, surface mismatches and ambiguous
coordinator sessions never participate. Context
usage/window size is omitted because the current producer has no documented numeric source;
cumulative API tokens and context tiers are not presented as context occupancy.
Full authorized paths and stable IDs remain in deliberate inspection. Successful
tab focus and opening details mark that scope's nonblocking notices as read.
Passive footer refresh, hover, copying and expansion never mark anything read,
focus a tab, send input, or change lifecycle; no interaction approves or answers
a request. Existing explicit host-focus observation semantics remain unchanged.

For unmanaged terminals with exactly one observed session, its state and children
are presented on the named terminal row instead of adding a duplicate provider/ID
heading. Multiple sessions remain individually inspectable; none is guessed to be
the current owner. Passive skill/shell history moves to the selected session's
**Other activity** disclosure and remains in Taskboard. Agents, structural
ancestors, active/blocked/failed work and outstanding attention stay in the outline.
Ordinary running shell invocations are the exception: verified, unambiguous leaf
commands fold into the quiet metadata line of their exact owning session or
agent, such as "Running a command". Concurrent commands are counted; blocked,
failed, attention-bearing, unresolved and structural shell rows stay visible.
The complete shell records remain available in details and Taskboard. This is
presentation-only: raw activity evidence, lifecycle state and counts are unchanged.
Incomplete-history context and collapsed-branch counts stay with their owning
row, not on standalone diagnostic rows. A chevron needs no "Branch collapsed"
caption. Registration is neutral, not a claim that an agent is running; stale
managed evidence and unconfirmed/ended process ownership cannot show a live state.

With or without a managed graph, the same outline groups real CMUX
surfaces and valid inferred Copilot sessions beneath workspace headers. Working
directory labels are home-relative where applicable, never inferred Git
branches. Uncertain ownership and incomplete evidence remain honest glyphs or
summaries, and incidental diagnostics stay behind selection or settings.
Taskboard remains available from its header button and retains each
primary session's state even when it has no attention or child rows.

A healthy outline has no diagnostic paragraphs. **Maestro** leads the header;
the six existing actions form a right-aligned group of 28-point buttons with
2-point gaps, rather than stretching across the sidebar. Source availability is a header
indicator with full help and accessibility text; incomplete evidence is marked on
its owning row. Blockers, attention and omitted active work remain visible.
Workspaces use primary 12-point semibold names, boxed disclosure and a section rule.
Rows retain the chosen identity glyph in a consistent 24-point column; directory
context uses the observed basename, never a guessed workspace name or Git branch.
Complete home-relative paths remain in hover, accessibility and Details rather than repeating unavailable
workspace/project/path lines on every row.
New grouping selectors, pane headings, tags and utility rows from the design
prototype are deliberately separate scope; no decorative substitutes are shown.
The header gear remains the entry for density and stored preferences. Saved
expansion, retention, acknowledgement, navigation and source records are preserved;
the outline's activity filtering is presentation-only.
When several source warnings apply, the overview keeps the primary warning
and omitted active-work count visible; its Details disclosure lists every reason.
The current host's overlaid footer has 50 points of reserved clearance.

Sidebar **settings** includes **Compact** and
**Comfortable** (more room and larger native detail text) density. Both
Hierarchy and Taskboard keep the same data, counts, paths and independent
focus, dismissal and acknowledgement actions. Narrow rows stack actions;
full paths remain available to accessibility and tooltips.

The outline uses 5-point side gutters (scaled for Comfortable), 8-point shallow
nesting and 4-point increments beyond level three, bounded to 32 points or 12%
of available width. Full Git diagnostics remain in hover/details so titles keep priority.
At eight levels and 280 points, the stable overflow slot leaves at least 124 points
for the name without hover-time reflow. The 50-point host-footer clearance is unchanged.

Hierarchy expansion persists by workspace/surface UUID and provider/session/
child identity—not names, paths or the current window. Moves and reloads keep
the setting; new identities start expanded. Reusing the same child ID in a
different session/provider does not inherit a collapse. Returning with the
same full identity intentionally does. Collapsed ancestors retain visible
running, blocked and attention summaries; incomplete counts stay labelled.
Collapse never dismisses or acknowledges work and never changes retention.
Taskboard still shows retained non-task activity regardless of tree collapse.
Internal-task groups and task-child disclosure share exact provider/session/task
identities across both views and reloads, independently of actual child-agent tabs.
Non-task Taskboard activity remains state-grouped even when a managed owner or
internal-task group is collapsed; coalescing a heading does not remove that activity.

Density overrides, collapsed identities and workspace-local idle-task reveal
choices are stored in a versioned
`CMUXMaestroPreview/sidebar-layout.json` record in the extension container's
Application Support directory. Coordinated, atomic action-level writes merge
across views/processes rather than replacing a stale window snapshot. Local
views synchronize immediately; native file-presentation notifications refresh
other processes, with reloads on host/observation updates, activation and
appearance as well.
Storage is bounded to **2,048 overrides / 1 MiB**. Oldest collapse overrides
are evicted first, which only **expands** branches. Off-window state is never
pruned based on a current snapshot. Unreadable or unknown-schema settings
expand all branches and show a recoverable notice; only **Reset layout
settings** replaces that record. **Expand all branches** preserves density;
layout reset restores Compact and does not alter history or attention settings.

Layout's file/store types are thin adapters over the same preference coordinator
used by history and acknowledgements; only layout's mutations and safe eviction
policy remain feature-specific. The existing layout path and version-1 schema
are unchanged: no layout migration or rewrite occurs on open. Missing layout
files mean Compact and fully expanded, and reads/refreshes do not create a file.
This lazy mode is explicit; history/acknowledgement migration-on-open is unchanged.
Lazy stores observe the nearest existing container so first-file creation in
another process also reaches already-open views, without writing defaults first.
All three records stay separate. Tests and offscreen renders inject all three
storage paths and never fall back to the production layout singleton.

### Synthetic layout review images

`./scripts/test.sh` writes offscreen SwiftUI/AppKit PNGs to
`.build/layout-validation/offscreen/`. CI uploads only those PNGs as the
**sidebar-layout-offscreen** artifact (14-day retention), including when tests
fail after producing images. Review both densities at 240 pixels in dark mode,
increased contrast, and long synthetic path/model/nested-label scenarios, in
addition to the light-mode expansion matrix at 240 and 349 pixels. Dedicated
`managed-*-340x600.png` and `unmanaged-light-340x600.png` fixtures exercise two
workspaces, duplicate names, nested ancestry, long branches and mixed lifecycle
states at the target sidebar density. The broader matrix uses a 941-point
viewport. Filenames identify density, scenario, view mode and width.
The renderer checks the actual SwiftUI color-scheme and contrast environment.
Per-image JSON records measured scroll viewport/document geometry; metadata-only
panels are also rendered at both widths to check horizontal containment. Clarity
validation uses matched before/after fixtures, not screenshots of live work.
Its fixed synthetic clock also owns the injected freshness timer; elapsed CI
wall time cannot expire a fixture whose logical clock has not advanced.
The clarity tests also render light/dark icon and status keys, verify that each
symbol exists, and confirm that the output contains actual color accents.
Contrast uses the SDK's writable `_colorSchemeContrast` backing key only in
tests, paired with native high-contrast AppKit appearances; no system display
preferences are changed.

The active-window footer renders all eight light/dark, 240/340-point width and
144/220-point height combinations at explicit native 2x resolution. Exact model
and copy-feedback text is recognized from those pixels without resampling or
language correction; copy feedback also retains native accessibility and
viewport-containment checks. Wrong, missing, hidden and clipped model controls
must fail the same visibility check. Each text failure reports its image and
recognized lines.
The separate inspector uses native 2x production captures in both appearances.
An independently rendered runtime literal `Model` / `verified-model` pair uses
the same compact font and selectable-text modifiers. Every pixel of both lines,
their borders and trailing column must match exactly, allowing only a one-pixel
translation, not resizing, OCR spelling aliases or an averaged ink score.
Blank references fail explicitly. Wrong, missing, hidden, partially clipped,
wrong-model-with-the-right-value-elsewhere and suffixed values must reject through
the same oracle. PNG references/captures and per-image pixel differences remain
with the render artifacts; revoked-subject clearing, no-copy and passive-focus
checks remain in place. Footer OCR and native copy checks are unchanged.

Retained native-menu tests capture the complete production details popover at
explicit native 2x, including the unavailable state after each identity change.
The unavailable heading and both explanatory lines must match an independent
runtime literal reference, pixel for pixel at their expected locations: no OCR,
translation or pixel tolerance. The reference uses the same native popover shell
for its material/text rendering, not production text or a saved screenshot.
Blank-reference checks and light/dark missing, hidden, wrong, partially clipped
and misplaced warning controls exercise both embedded and native-popover captures.
All 12 retained-menu cases keep their identity, copy, attention, navigation and
pinned-subject assertions. Full captures and references use the existing
`.build/layout-validation/offscreen/*.png` artifact path; geometry and exact
pixel-difference sidecars remain beside them locally.

The full-sidebar warning matrix retains both densities, both appearances,
240x400/340x600-point sizes and both waiting/disconnected states (16 captures),
alongside the connected-footer geometry and zero-painted host-clearance checks.
Only these natural-language warnings normalize OCR whitespace and lettercase:
`Waiting for CMUX` and `CMUX disconnected. Focus and live status unavailable.`
must retain every word and punctuation mark across line wraps. Empty, partial,
wrong-state, navigation-only, substituted-word and missing-punctuation controls
must reject; each render reports its filename and recognized lines. Exact model,
session-ID, copy and inspector-pixel oracles do not use this normalization.

All metadata is synthetic and local preferences are isolated for the render
tests. Embedded render windows stay offscreen; native interaction/popover tests
show only their own synthetic windows. These are view captures, not a desktop capture, live
CMUX-host visual proof, system VoiceOver verification or a checked-in OS/font
golden-image comparison. No transcripts, real workspace paths or desktop images are uploaded.

## Choose your session icon: `/cmux-maestro-native:maestro-icon`

The bundled `/cmux-maestro-native:maestro-icon` skill searches the local Nerd Fonts catalog and saves
a glyph and/or identity color for **the invoking session only**.
Workers use their injected identity/token; coordinators use their own retained
registration credentials. The command checks the caller's exact workspace and
surface and accepts no other-session target. It does not rename, focus, register,
recover, archive, approve, stop, or grant tools to any agent.

```sh
MAESTRO="$HOME/Library/Application Support/CMUXMaestroPreview/Orchestration/bin/cmux-maestro-orchestrator"
"$MAESTRO" icons --search ghost
"$MAESTRO" icons --search bug --limit 20 --offset 0
"$MAESTRO" icon \
  --actor-id "$CMUX_MAESTRO_WORKER_ID" \
  --token "$CMUX_MAESTRO_CONTROL_TOKEN" \
  --icon nf-md-bug_check --color teal

# Standalone session: use the exact UUID from this CLI session's own context.
"$MAESTRO" icon --self --session-id "<current-session-uuid>" \
  --icon md-robot --color teal
```

The [cheat sheet](https://www.nerdfonts.com/cheat-sheet) is a visual reference.
`nf-` prefixes and preset names are accepted and resolve to canonical glyph
names. Removed, empty, or unsupported glyphs are rejected without changing the
previous selection. Searches are paged and capped at 100 results. The palette
is `theme`, `green`, `teal`, `blue`, `purple`, `pink`, `red`, and `gray`; no orange.
Omitting glyph or color preserves that part of the selection.

All new registrations and workers default to `md-robot`.
`register`/`spawn` accept optional `--icon` and `--color` startup choices.
Saved choices survive follow-ups and are cosmetic: they never refresh execution
or Git timestamps. A bounded, private `observer/icons.json` projection matches
node/run/workspace/surface identity and survives older supervisors republishing
`current.json` without cosmetic fields. The sidebar remains read-only over its
existing observer-directory grant.

The glyph font and catalog are pinned to upstream commit
`b894ea7803af6aade63d60a4381e006098ec9c4d`; their hashes, upstream license and
glyph-source notices live under `Resources/NerdFonts/`. Tests check the whole
selectable catalog against actual font outlines. Missing resources or unknown
stored glyphs show explicit unavailable indicators rather than font fallback.

Refresh Copilot integration through the stable app's existing explicit consent
flow to install the new skill, controller and catalog. Cached CLI plugins are not
rewritten or restarted automatically.

Standalone Copilot sessions can use `icon --self --session-id <current-session-uuid>`
instead of orchestration credentials. The native helper verifies the caller's
actual live CLI ancestor, PID/start tuple, in-use marker and existing binding.
It refuses another surface/session, stale or ambiguous proof, and never creates
an orchestration run. Appearance records stay under the existing private
bindings grant, separate from ordinary hook refreshes; malformed appearance
data cannot invalidate lifecycle evidence. No transcript or process arguments
are read for authorization.

## Completed work history

### Internal Copilot tasks

Explicit provider `.subagent` observations with literal session/child parents
are internal tasks, not interactive tabs. Both Hierarchy and Taskboard attach
their shared compact consumer beneath the exact owning session, including
coalesced managed rows and retained original-session context. A task is one
connector-linked text line without an identity icon or navigation/lifecycle
actions. Its full observed name and state remain in accessibility and tooltips.
Working alone animates green; Reduce Motion keeps a static working arc.
Completion, failure, blocked, queued, idle, unknown and cancellation use distinct
state shapes. Bounded left indentation preserves a common status edge.
Managed-owner and provider-task depth share one bounded indentation budget.
Suppressing a duplicate native surface row is not session ownership: unmatched
observations on that surface keep a separately identified session-context heading,
never the current managed chat's task parentage.
Multiple observations of the same agent surface do not add agent or state
counts. This counting rule does not attach their task contents to a managed
chat. Existing retained managed records keep the explicit entries/context legend.

Idle, unknown and cancelled tasks hide by state. A workspace's eye reveals
**idle tasks only**, independently of other workspaces and **Show ended agents**.
Finished and failed task outcomes have **no retention clock**: they remain until
their exact session/task/terminal-event outcome is dismissed. Outstanding
attention, degraded evidence and necessary ancestry stay protected.
New work, a new result or new attention can return. Dismissal revalidates current,
fresh evidence and cannot hide a replacement outcome or bypass active, failed,
uncertain, attention-bearing or relevant internal descendants. Harmless completed
non-task activity does not block reviewing the parent outcome; when legacy history
is shown, the dismissed parent's ancestry can remain without restoring that outcome.
After individual dismissal, keyboard focus returns to a visible local owner,
workspace or Taskboard control without selecting or activating a native tab.
This local restoration does not automatically open a keyboard preview; ordinary
keyboard focus retains its existing preview behavior.
Task quantities count only internal tasks. Branch working, blocked and attention
totals include related non-task descendants; owner summaries preserve uncertainty
from state-filtered unknown tasks. Incomplete/omitted evidence is explicit.

Real terminal-backed child agents keep their real tab identities. Neither task
visibility nor the workspace eye filters real tabs from native Hierarchy,
inflates agent/tab counts, changes ownership or closes a session.

### Other activity and session history

The sidebar's **History** shortcut opens history controls shared by
**Hierarchy** and **Taskboard**. The default active outline hides finished/cancelled
non-task activity and confirmed ended process observations. Native surface rows
remain available. Managed workers leave when a terminal outcome is known; active
descendants, blockers, unknown state and unread errors keep necessary context.
This only filters the sidebar: terminals, sessions and controller ownership are
never closed, stopped or archived.

**Show ended agents** reveals observations still retained by history.
Failed rows remain until explicitly dismissed with their **×** control; focusing
or inspecting them only marks nonblocking notices read. Questions, permissions,
uncertain attention and live descendants protect rows from dismissal. Legacy
automatic "viewed failure" markers no longer hide rows.
Finished and cancelled **non-task activity** outcomes are retained for
**15 seconds** by default; choose **1 minute**, **5 minutes**, **1 hour**, or
**Never**. Retention starts at the accepted terminal event's RFC 3339 timestamp,
not the poll, first display, or application launch. Missing, malformed, or
future timing is shown as **Completion age unknown** and never automatically
expired while unknown. Source events are not deleted.

Use a row's separate **Dismiss** button, or **Clear completed** for eligible
retained outcomes on current-window surfaces (including collapsed branches,
excluding display-capped/off-window/expired work). These controls never focus,
cancel, approve, prompt, or otherwise control an agent. Working, blocked, idle,
and unknown work stays visible under the existing display limits. A hidden
terminal parent remains as **child context** when descendants still need it.
Running counts and retained/hidden history counts are separate; empty history
is not evidence that a session has finished.

History uses a versioned `CMUXMaestroPreview/sidebar-history.json` record in the
extension container's Application Support directory. Coordinated, atomic
read-modify-write actions preserve other windows' retention and dismissals,
including separate extension processes. Existing windows observe changes through
file presentation (no polling daemon); same-process windows update immediately.
The selected view remains in `UserDefaults` and is not changed by history actions.

On first use, the existing `sidebar.completedHistory.v1` defaults record is
validated within the same coordinated transaction and migrated once. The file
is authoritative thereafter, even if another process has stale legacy defaults.
Only after a successful file write/read is the old key removed. Invalid legacy
or file data stays untouched until an explicit reset; failed migration can be
retried. No settings are mirrored back into the old history key.

Dismissal keys contain only provider-session UUID,
child ID and accepted terminal-event UUID—not labels, paths, or source content.
Reloads, duplicate events and surface/workspace moves preserve identity; new
work or a new terminal outcome does not inherit an old dismissal. Fresh lifecycle
identities—not comparisons against possibly future wall-clock timestamps—reopen
work. Retired invocation and agent-scoped turn identities remain tombstoned,
independent of current tool mappings. Repeated starts cannot reopen old work,
even with a new event UUID.
Records are
bounded to **2,048 dismissals / 1 MiB**; a full store refuses a new batch rather
than evicting old keys silently. **Restore dismissed history** frees that store;
retention still applies, so select **Never** to reveal older work.

Malformed stored settings fail open: history hiding is disabled and a bounded
notice offers **Reset history settings**. Ordinary retention/dismiss/restore
actions never overwrite corrupt data. Reset explicitly restores 15-second retention
and clears dismissals; restore clears only dismissals at its coordinated turn,
preserving the latest retention. Later dismissals remain later actions, not a
resurrected window snapshot. Neither action changes the selected view. Storage
I/O failures also fail open with a notice; capacity rejection keeps the last
valid record and rejects the entire batch. History deadlines use a
single cancellable timer, are not reset by refresh, and stop on hide, disconnect,
or access loss. Existing observation freshness remains an independent limit.
Reducer replay protection keeps up to 65,536 exact recent lifecycle event UUIDs
and 4,096 exact recent start/work/tool/resolved-request keys per session.
Each ledger spills into its own fixed 128-KiB filter rather than rejecting new
events at the exact-window boundary; spilled bits are never cleared within a
transcript generation. Cold matches are uncertain and report partial data.
Actual filter saturation fails closed; it never silently forgets anti-replay
evidence. Cold start-identity matches cannot distinguish old replay from a fresh
start's false positive. A matching agent row that is already terminal is exposed
as unknown, clearing its obsolete terminal outcome and completion pairing so
prior dismissal/expiry cannot hide potentially active work. A terminal root
similarly becomes unknown on an uncertain root turn. Neither case claims fresh
activity or adopts the unprocessed event's model. Live/blocked rows, pending
requests and unrelated root state remain unchanged; exact replay is a no-op.
On unprocessed fresh lifecycle evidence,
uncertain new starts demote affected work to unknown and clear obsolete terminal
evidence, so a prior dismissal cannot hide possibly active work. Unresolved
lifecycle scope is demoted conservatively; uncertainty alone does not resolve
known pending requests. Session identity/schema checks run
before all deduplication and capacity guards.
Complete, identity-verified reads publish conservative semantic degradation as
current partial data, including unknown lifecycle state and replay limits.
Malformed events, incompatible session schemas, identity changes and torn reads
still cannot publish unvalidated replacement state.

## Attention and safe activity

Both views distinguish **Waiting for permission** from **Waiting for answer**,
on the session or child that owns the durable request. Pairing uses request kind,
owner and request ID; a completion for another owner or kind cannot clear it.
Hook-resolved permissions do not block. Repeated/late request identities cannot
reopen a resolved request. Rejected stale abort/error evidence cannot erase a
newer request. Missing ancestry stays explicitly unresolved.
Independent requests are not ordered against one another's clocks: a delayed
question remains pending even if a different permission has a newer timestamp.
Hook resolution uses the exact kind/owner/request identity, including when it
arrives after another request or a new turn.

The compact **Needs attention** affordance includes outstanding requests and
nonblocking outcomes. **Acknowledge** records only the latter locally in the
native sidebar. **Acknowledge all** uses the current-window projection, including
collapsed branches but excluding off-window or display-capped rows. An owner
with a pending request is never eligible, even if it also has an outcome.
Neither acknowledgement, history dismissal nor focus sends approval, answers,
cancellation or any agent-control command. CMUX unread counts are untouched.

**Turn finished** means a matching primary `assistant.turn_end` was recorded,
not that the session or its background children finished. Root errors/aborts
likewise do not end or unblock unrelated children. Process liveness, work state
and attention remain independent. Process presence, idle time, file modification
time and expired history never imply success, progress, or a hung agent.

Copilot reuses turn IDs such as `0` and `1` in later interactions. When supplied,
`data.interactionId` scopes accepted starts and replay protection together with
the owner and turn ID. It is an opaque, nonempty string bounded to 256 UTF-8 bytes,
not a counter or an inferred user-message epoch. Retired interaction identities
use the existing bounded replay guard. A new primary interaction does not reset
still-running children or their pending requests.

An end with an explicit interaction ID must match the current accepted owner
turn. Ends without that field retain legacy pairing when the turn identity is
unambiguous. For reused IDs, they require a current causal parent or a uniquely
matched tool completion whose start was tied to the current turn. Only envelope
IDs/parent links are used across ignored payload-bearing events: no prompt,
arguments, results or message content is decoded for this purpose. Tracking is
bounded to one causal tip per active owner and one origin per retained tool,
not an accumulated transcript graph.
Optional interaction/turn tags on `tool.execution_complete` are validated against
its recorded tool origin, or the current accepted owner turn when no origin was
recorded. Explicit contradictions cannot complete current work or advance its
causal tip. Matching tags do not create missing tool ownership.

All tool-associated events, including tool-backed subagent events and unjoined
shell notifications, are excluded from generic parent bridging.
Accepted tool starts, completions and partial results advance a causal tip only
through a known tool whose recorded origin is the current accepted owner turn.
An old or missing origin cannot be replaced by a later `parentId`, even when tags
are nil or the raw turn ID matches. Partial results decode only bounded optional
tool/turn/interaction metadata, never output content. A matching current partial
may advance the single tip, but does not change work state or manufacture an
outcome. Non-tool envelope bridges retain their bounded current-parent behavior.

Missing/gapped causal evidence for a reused nil-interaction end produces
`ambiguousTurn` and unknown primary state, not a fabricated completion. Pending
requests and background work survive, and a later proven end can recover the
current outcome; the observed ambiguity keeps that transcript projection partial.
Explicitly mismatched ends and exact old event replays cannot close the new turn.
Contradictory clocks on a proven match retain identity with unknown timing.
Legacy-only streams keep their existing replay behavior; missing interaction
metadata cannot silently reinterpret an already-used explicit turn identity.
A provider record incorrectly labeled or parented as current is not distinguishable
from current evidence by this metadata-only reader.

Normal tool failure may coexist with **Turn finished** and an idle primary turn.
An accepted primary `session.error` or `abort` retains its existing failed/cancelled
policy instead; it is not relabeled as normal turn completion. A fresh accepted
interaction can subsequently establish working state.

Outstanding nonblocking evidence is intentionally bounded: only the latest
accepted error/abort outcome per owner, plus the latest primary-turn completion.
Successful historical child completions are history, not attention. Fresh
owner turn/tool/invocation activity retires that owner's obsolete outcome. A
new primary turn begins a new outcome cycle for the session and its children;
it does **not** resolve their still-pending requests. Resume invalidates prior
activity/attention and demotes nonterminal children to unknown, rather than
claiming that pre-resume background work completed. Accepted terminal child
evidence remains available to history controls. Duplicate/retired lifecycle
identities cannot restart attention or its timing.

Outstanding attention protects rows from history retention and dismissal.
Acknowledging an error/abort then allows ordinary history retention to apply;
required parent context and current blocking descendants stay visible. No timer
auto-acknowledges anything. History and acknowledgement resets are independent.
Nonblocking notices are marked read when their tab is successfully focused or
their details are opened, without a separate acknowledgement button. A confirmed
host focus transition also marks that tab read; initial mount, passive polling,
hover, expansion and failed/cancelled navigation do not. Sidebar focus captures
the notices present at the click and revalidates them after host acceptance, so
later notices and changed blockers are not cleared by a stale click.
The menu retains **Mark all nonblocking notices as read** as an explicit fallback.
Explicit child dismissals are keyed by exact session/child/terminal-event identity;
managed failure dismissals use node/generation/phase. These history fields share
the existing 2,048-entry / 1 MiB limit, survive reloads, and never hide a new
generation or completion event. **Restore dismissed history** clears these read
dismissals. Marking a notice read never dismisses its failed row.
The reader also protects current-cycle outcome owners from terminal-leaf
retirement. Local acknowledgement changes presentation, not the provider's
ingestion state; a verified new primary turn or fresh owner activity establishes
when prior nonblocking signals are obsolete. Genuine active/attention capacity
exhaustion is reported as partial data rather than dropping protected signals.
Unknown lifecycle data or replay-filter saturation can invalidate current
activity, but cannot silently acknowledge already-recorded outcomes or requests.

Acknowledgements persist by provider-session UUID, owner ID (or primary owner),
source and stable accepted event UUID. Labels, paths, tool payloads and topology
are not keys. The same outcome remains acknowledged after reload or surface
moves; a new outcome reappears. Storage is versioned and bounded to **2,048
acknowledgements / 1 MiB**, refuses overflowing batches without eviction, and
offers **Reset acknowledgements**. Corruption fails open with a visible warning:
no attention is hidden by unreadable settings.

Acknowledgements use the same coordinated action store as history, in the
separate extension-container Application Support file
`CMUXMaestroPreview/sidebar-attention.json`. Acknowledge unions only the
current projection's eligible identities into the latest on-disk record;
other windows/processes observe changes automatically without polling. Reset
clears acknowledgements at its coordinated turn, never history or the selected
view. Later acknowledgements remain later actions, not restored stale snapshots.

The old `sidebar.attention.v1` defaults record is validated and imported once
under the same lock. The file is authoritative thereafter; the legacy key is
removed only after successful persistence/read. Corrupt or future-schema files
and legacy data fail open and are left untouched by ordinary acknowledgement
actions. Only **Reset acknowledgements** replaces them. Failed migration retains
legacy data for retry. Tests inject both history and acknowledgement files.

Activity uses only the allowlisted durable tool-name field: **Executing tool**
(the latest still-executing invocation for that owner) or **Last completed tool**.
The latter is a tool-invocation event, not a statement that a detached shell
process exited. Child attribution requires real event ownership. Names must be
bounded symbolic identifiers; arguments, results, prompts and raw errors are
never decoded for display. Invalid/missing/future timing is explicitly unknown;
timestamps are not replaced with poll time. No token/context counters, guessed
percentages or speculative stall detection are implemented.
Lifecycle acceptance never depends on the current read clock. Tool and turn
completions pair with their own active invocation/owner identities; contradictory
start/completion timestamps retain the completed evidence with **unknown timing**,
rather than resurrecting executing work on a later replay. Observation freshness
and future display timestamps are validated separately in sidebar projection.
Missing tool ownership never creates an error or executing activity: a bounded
completion tombstone prevents a later start from resurrecting that invocation.
Delayed tool metadata for an already-ended spawn cannot reopen its owner.
Tool starts classify their start, completed-tool and shell-row replay aliases
together before mutating owner metadata. An exact match is a no-op; uncertainty
in **any** alias fails terminal history open without changing a live owner.
The legacy shell-row alias remains checked even for non-shell tool names, keeping
global tool-ID replay protection conservative across metadata/name differences.
Both ordinary tool and actual shell starts have selective-alias regressions.

Live `SidebarCopilotPolling.Read` and projection consume the existing
`Domain/AgentSessionSnapshot.swift` contract through the pure
`CopilotSnapshotAdapter`. `CopilotSessionReader` still owns bounded provider
parsing; only the caller's granted current host topology establishes a binding.
Launch workspace/surface evidence is separate and cannot create current topology.
Activity and attention reuse `Domain/AgentSignals.swift`; these shared types
compile into app, sidebar and tests, not the hook.

Schema version remains 1. Optional observation fields preserve process liveness,
observation time, appearance, child kinds/models/outcome-event identities, issues
and completeness. An absent completeness field means unknown, not complete.
Legacy `state: done` retains its meaning. Idle, failed and cancelled use an
explicit `stateDetail` with an unknown legacy state; contradictory combinations
are invalid. Consumers resolve that pair once and keep process liveness separate.
Unavailable/degraded model or activity values cannot become current evidence.

The existing `childWork` property always retains v1's strictly validated nested
meaning. The adapter derives an old-compatible view of representable relations;
unresolved components are omitted, never reparented. Additional typed
`childWorkObservation.items` preserves the complete reader order and literal
edges, including late/missing parents and cycles. Its
`legacyProjectionIsLossless` flag explicitly records whether the compatibility
view covers every observation; it does not claim complete provider history.
New consumers use this evidence when present, never merge it with the derived
compatibility view. The actual frozen v1 codec **and validator** are exercised
against original fixtures, ordinary/child-first pairs, missing parents and cycles.

Strict validation and live projection share per-observation structural and
cross-field checks before history filtering. Malformed ancestry stays unresolved,
contradictory terminal evidence cannot hide work, and valid peer sessions survive.
Each graph assessment visits at most 4,096 nodes and 64 nesting levels. On a
limit, visited evidence remains partial, history actions are disabled for that
session, and omission counts are explicitly lower bounds with unknown totals.
The existing display caps remain 256 nodes and 12 levels. Legacy invalid parent
references still fail validation even when additional observation evidence exists.

Reader identity, partial-read, corruption, freshness and replay-cap safeguards,
history/attention actions and exact host navigation remain unchanged. No PID,
process-start identity, raw provider payload, capability or control authority
is added. Saved identity still does not imply resume; an observed child has no
independent terminal. This literal #10 integration does not complete the broader
#118 lifetime/control foundation or change observation-hook policy.

### Bounded retention and discovery

- The 256-row reducer budget retires the oldest terminal **leaf**, not active,
  idle, blocked, or unknown work. Current-cycle error/abort outcomes protect their
  owners. Retained descendants, pending requests, and
  unresolved active ownership protect their ancestors. Agent row IDs stay stable
  across fresh lifecycles; retirement does not permanently blacklist an agent ID.
  Completed tool ownership is reclaimed separately so the 4,096-relationship
  budget does not become the next long-session bottleneck. Recent completed
  owners still support delayed parent joins; retired joins remain unresolved.
  Retirement removes only the retired owner's obsolete turn/activity/outcome
  records and joins. Signal dictionaries are bounded by retained owners plus
  the primary owner; tool ordering uses the bounded retained-tool list.
  Request/tool-only unknown owners use event-scoped lifecycles, never permanent
  agent-ID tombstones.
- Spawn replay keys use the spawn tool ID; turn replay keys use owner +
  interaction ID + turn ID when interaction metadata is present, otherwise the
  legacy owner + turn ID namespace.
  A new spawn tool or previously unseen scoped turn is fresh activity, even for
  a retained or retired terminal agent. Completions pair with the row's current
  spawn, so a late old completion cannot finish a newer lifecycle. A turn alone
  recreates an unknown agent, not an invented old name/parent/spawn. Enriching an
  unknown row must not silently discard its pending requests.
- Work/lifecycle/tool/request replay keys keep up to 4,096 exact recent tombstones.
  Resolved-request keys include length-qualified owner, request kind and request
  ID; spilling never collapses root/child or permission/answer namespaces.
  Older identities spill into a deterministic 128-KiB replay filter; its bits are
  never cleared within a transcript generation. This bounded filter has no false
  negatives, but can have false positives: a cold match rejects fresh admission
  **and reports `readLimitReached`**, rather than claiming exact replay knowledge.
  Terminal agent/root state fails open to unknown as described above; an uncertain
  start-identity match does not demote live work.
  This also applies to uncertain tool-activity admission for a terminal owner.
  Clearing obsolete terminal history does not acknowledge retained attention or
  resolve a pending request.
  At half occupancy it fails closed; it never forgets history to admit more work.
  True active-capacity exhaustion also reports a limit without fabricating
  completion. Transcript replacement reconstructs this state from the new log.
- Routing discovery resumes one descriptor-anchored directory stream across
  batches (up to 1,024 directory entries per batch, plus bounded revalidation of
  at most 64 cached identities and one staged granted binding). Historical locks
  and off-surface records cannot pin discovery to a prefix. At most 64 transcript
  tails are retained. An unfinished initial tail keeps its slot until its finite
  captured byte boundary is verified and published (or explicitly unavailable);
  discovery stages at most one next binding while it waits. Finished slots then
  rotate, retaining an explicit limit warning when granted sessions exceed capacity.
  Only a full, unchanged, non-overflowed cycle without errors can be complete.
  Cached bindings are checked before process/transcript access and publication;
  replaced directories, revoked surfaces, and cancellation discard cached state.
  EOF, errors, cancellation, and destruction close the directory stream.
- Capture a fixed prefix length and observation time for each catch-up pass;
  later appends do not extend that lease forever. A verified complete prefix may
  be published with its captured observation time and `loadingHistory` when
  newer bytes remain; this is not a current/complete snapshot. A verified current
  EOF uses the verification time, including after multi-batch reconstruction on
  normal polling cadence. Torn or malformed
  prefixes cannot become fabricated complete evidence. A failed observation
  cannot pin every later session indefinitely.
- Oversized `session.binary_asset` events retain a bounded, validated outer
  envelope while their opaque `data` object is discarded incrementally. Uploaded
  screenshots therefore cannot permanently invalidate later working/idle state.
  Root identity, type, parent-event metadata, duplicate-key rejection, nesting
  bounds and complete-record boundaries still apply. Other oversized events and
  malformed envelopes remain fail-closed; the 1 MiB retained-line limit is not raised.
- A binding rerouted during a read is deliberately omitted, **not** returned
  with its superseded surface/session identity as an ambiguous row. Other
  verified granted sessions remain visible; the snapshot reports
  `identityChanged` and is incomplete. A later stable read under the new grant
  reconstructs that session, including when both surfaces were already granted.
  By contrast, unstable process/marker evidence with an unchanged valid routing
  binding still produces a content-free ambiguous row. Timestamp-only hook
  refreshes preserve the verified row but require a stable discovery cycle
  before completeness. Reader tests cover all three distinct contracts and use
  `#require` before unwrapping expected observations.
- `hasPendingHistory` accelerates initial/changed-index catch-up and retained-tail
  deltas. After an overflow sweep finishes, revisiting evicted prefixes of the
  unchanged index uses normal polling rather than an endless fast rebuild loop.
  EOF, torn final lines, and warnings alone never request a fast retry. No sandbox
  entitlement or ancestor traversal permission is broadened.

**Further presentation integration:** preserve this combined reducer's
accepted terminal UUID/timestamp, current-spawn/turn pairing, bounded event/start/
owner-qualified resolved-request guards, and `canPublishProjection` distinctions.
Retirement must continue to clean obsolete turn/activity/outcome state without
discarding pending requests, unknown placeholders or required ancestors.
History presentation limits remain separate from ingestion limits; a prior
terminal dismissal cannot hide a fresh lifecycle using the same agent ID.
Carry finite reader watermarks, staged-binding revalidation, EOF freshness and
overflow scheduling together. Layout, installer and clarity changes must not
weaken the quiet validation scene, backend setup denial, current-tree
acknowledgement guards, or the host's 50-point footer clearance.

## Requirements

- macOS 14 or newer.
- Xcode 26.6 at `/Applications/Xcode.app` for local builds.
- CMUX with sidebar ExtensionKit support.
- A Copilot CLI version supporting local plugin installation and the three
  documented command hooks, with canonical session identity in hook input.

The CMUX ExtensionKit package is pinned to CMUX commit
`ae7fbce99f98c98df5ccf915e548dd080d33cfa8`. It is fetched into ignored
`vendor/CmuxExtensionKit/`; no CMUX source changes are required.

**Host footer compatibility:** the native view reserves an absolute 50 points of
bottom clearance for the current CMUX overlaid footer, independent of density.
The SDK provides no footer-inset contract; a rendered-strip regression test checks
both sidebar modes and densities leave this area clear. Reverify the clearance
when host chrome changes.

Workspace containers use eager layout inside the scroll view; their child trees
retain the existing projection limits. This avoids the lazy root-placement loop
observed during remote accessibility scrolling. An offscreen AppKit regression
exercises repeated scrolling and mode changes in both densities; live accessibility scrolling and
continued history updates remain part of deployment acceptance.

## Build and test

```sh
./scripts/fetch-sdk.sh
./scripts/build-unsigned.sh
./scripts/test.sh
```

`test.sh` is the integrated Swift full-coverage entrypoint. It builds once, runs the unchanged
blocking-observer concurrency regression alone in the integrated host, verifies
its exact identity/count from the hosted xcresult, then runs all other tests
from that same build without suite serialization. Both scopes must pass.
Results and count evidence are retained under `.build/tests/scoped-results/`.
Selection/retry overrides are rejected by this full-coverage entrypoint.
The existing `CopilotReaderTests/coldStartBenchmarkWith230MiBOfIgnoredSyntheticPayloads()`
remains opt-in. Its exact skip is attributed only when
`CMUX_MAESTRO_READER_BENCHMARK` is not `"1"`; when enabled, a skip fails coverage.
Enabled runs require its exact identity with one nonparameterized passed
execution; an absent benchmark also fails coverage. No other optional-test
exception is inferred.

The separate required `row-input` CI job runs `./scripts/test-row-input.sh`.
Its `CMUXMaestroRowInput` scheme builds a validation-only application and an
XCTest UI-test target, separate from the integrated Swift test-count partition.
All six named cases must execute exactly once and pass; missing, skipped,
repeated, or expected-failure cases cannot pass the venue. The original
eleven-command job and its existing native tests remain unchanged and required,
even while their unresolved input experiments are red.

`./scripts/test-row-input.sh --build-only` compiles both actual new targets
locally without launching either. It requires full Xcode and the already fetched
pinned SDK. Without that flag, the script, UI-test setup, and fixture entry point
each refuse non-GitHub-hosted execution; do not spoof the hosted markers locally.
The fixture uses fixed `.Validation.RowInputFixture` and
`.Validation.RowInputUITests` bundle identifiers, embeds no extension or
installer helper, and has no production-app startup path, saved-state loading,
preference writes, session reads, or installation action.

The fixture compiles the existing sidebar sources and shared dependencies without
the extension entry point, rather than copying or replacing the production menu.
It instantiates only `SidebarRowActions`, `SidebarTitleButton`, and their shared
row decoration in two exact, named fixture windows. Complete XCUITest element
clicks, Shift-F10, Escape, native menu traversal/action, title activation and Tab
exercise those controls; there is no `CGEvent` construction/posting, local event
replacement, fitted coordinate, or blanket focus/modality reset. Read-only,
bounded accessibility snapshots inspect the real anchors, responders, window
identity, geometry, menu notifications and action/click counters. Window-level
input observations deliberately do not claim to see events consumed by native
menu tracking. The no-menu complete-click control establishes actual down/up
receipt in each fixture window; menu cancellation does not assume AppKit delivers
both events to that receiver.

Each invocation preserves source hashes, command logs, six-case counts and the
complete xcresult (including snapshot/render attachments) under
`.build/row-input/`, uploaded as `row-input-xcuitest-evidence`. Compilation is not
native acceptance. Hosted results and independent review must establish the new
venue and any future replacement of unsupported older oracles; this addition
does not waive their failures, prove all native invalidation interleavings, or
prove the entire visual-feature contract.

The metadata supervision regression has a test-only, executor-independent
30-second bound for each subcase. A stall records the subcase, real deadline
sample count/age and a one-second all-thread sample before exiting the test
host unsuccessfully. The 30 seconds is a diagnostic capture budget, not a new
provider deadline: it exceeds twice the observed 12.002-second passing integrated
test, leaving contention headroom while the original 2-second and 0.1-second
subcase deadlines still determine their results. Progress never renews the
diagnostic budget; hosted behavior still needs verification.
The sampler gets three seconds, then its exact unreaped child PID is killed and
given one second to reap. A separate five-second hard bound signals any still-owned
sampler and fails the test host even if diagnostic work stalls; unconfirmed
cleanup remains explicit, never a success. Diagnostics
preserve the observed sampler exit/timeout and reap state separately from an
optional `sampleReadError`; a missing sample cannot erase that process outcome.
The host still fails with exit 124. Diagnostics
under `.build/tests/scoped-results/metadata-diagnostics/` are included in the
existing scope-evidence artifact, including partial samples. Its final upload
runs after both integrated and standalone setup tests, and also retains the
complete `.build/setup-tests/metadata-watchdog/` control evidence directory.
The required artifact names and missing-file failure behavior remain unchanged.
This exposes a
blocked boundary; it does not establish or repair the cause of a prior CI hang.
Production timeouts, cleanup and all original assertions remain unchanged.
The separate metadata-cancellation test uses the same per-phase diagnostic bound,
with its test identity and launch-delay argument retained. It distinguishes
startup, PID publication, cancellation/owned-process completion and exit checks
without advancing the fixture's frozen clock or changing its three-second PID
publication deadline. A diagnostic timeout fails the host; it is not a retry or
a cancellation pass. At PID readiness it captures the exact direct child's
PID, parent, process group, start identity and numeric state. At a stall it
revalidates that identity before reading at most 64 members of that exact group.
These are sequential observations, not an atomic snapshot or a quiescence
verdict. Missing identities, failed queries and incomplete enumeration remain
unknown; a changed identity prevents group inspection. If Darwin hides an
exited child from `proc_pidinfo`, a non-consuming `waitid` observation can
distinguish an exited child from `ECHILD`, but cannot revalidate its start
identity or prove group cleanup. The watchdog never signals the metadata group.

`runnerMetadataReturned` records the test task receiving the result of
`await runner.metadata(...)`; it does not observe the private dispatch worker
producing its result. `outerTaskValueReceived` separately records the outer
test receiving `task.value`. Both flags are captured at the watchdog deadline,
before the subsequent OS observations. False flags do not establish where a
continuation is blocked. Observation runs outside locks with the existing
watchdog and five-second diagnostic containment still armed. The prior stalled
runs did not capture this evidence, so their underlying cause remains unproven.
Sampler exit/signal/timeout and reap status are saved independently of a missing
or unreadable sample file, whose error is retained as `sampleReadError`.

For cancellation diagnosis (#174), the test explicitly injects one
`CopilotSetupObservation` into its runner and watchdog. Normal runners retain
`observation == nil`: no observation storage, callbacks, queries or logging
are enabled automatically. The optional `stall.json.supervision` version 1
snapshot contains 14 fixed numeric boundary slots:

| Index | Boundary | Index | Boundary |
| --- | --- | --- | --- |
| 0 | Test `cancel()` call | 7 | TERM syscall |
| 1 | Cancellation handler | 8 | KILL syscall |
| 2 | Synchronous execute | 9 | Exact-child reap |
| 3 | Exchange poll | 10 | Continuation resume call |
| 4 | Child-state wait | 11 | Async invoke return edge |
| 5 | Group quiescence | 12 | Metadata return edge |
| 6 | Owned-group stop | 13 | Test task-value await |

Each slot retains its own `begin`, `end`, `detailSequence` and last numeric
`detail`. Zero means not observed; an end greater than its begin means the
boundary's end marker was reached. The async invoke/metadata markers run at
their return edges; the existing outer flags separately prove caller receipt.
Sequence numbers order observations, not elapsed time.
Repeated queries replace only their own completed slot; an outstanding begin
cannot be overwritten. `overflow` or `invalidTransition` forbids treating the
record as complete. `availability: 1` means snapshot lock contention, with no
boundary data; `0` means available. The failure dump never waits for the
observation lock, cancellation lock or supervisor to finish.

Detail reasons are 0 unknown, 1 cancellation observed, 2 child running,
3 child exited, 4 child unavailable, 5 quiescent, 6 living group member,
7 enumeration unavailable/full, 8 member query unknown and 9 membership changed.
Result/error/PID/status/code/count fields come only from existing supervisor
queries and syscalls; a zero `detailSequence` means even zero-valued fields are
unknown. The snapshot adds no process enumeration or provider data and has a
tested 8 KiB encoded bound. Serialization runs after releasing observation
locks. A snapshot may be unavailable while a tiny record update is in progress.

The cancellation phase still begins **before** `task.cancel()`: only slot 0's
return establishes that it returned, and slot 13's begin establishes the await
was entered. Resume-return and async-caller progress are distinct; the caller
may execute before the dispatch worker records resume-return. Existing return
flags, clock samples and later process queries remain sequential observations.
These diagnostics neither shorten cleanup nor establish the historical cause.

`test-copilot-setup.sh` also runs disposable Foundation-only controls: successful
disarming, a stalled injected clock, continued polling of a frozen clock, and
a real stuck sampler that writes partial output before ignoring termination.
Both stalled controls must fail with sampled actual-runner stacks; an unexpected
return, missing stack or outer probe timeout fails validation. The sampler-fault
control must fail after killing and reaping its exact child while preserving
partial output; it does not stand in for real stack-collection acceptance.
Three additional finite fake-sampler controls distinguish exit 17 without output,
exit 17 with output, and timeout without output. Missing-file controls require
both the original process outcome and an explicit sample-read failure.
Additional finite controls distinguish living, exited-but-unreaped, and returned/reaped
child contexts from the outer task completing. Changed-start and truncated-group
controls query only newly owned fixture processes and must retain unknown states.
Every stalled control still exits 124; successful disarming still exits zero.
Three synthetic no-metadata-child controls exercise cancellation pending,
cancellation returned with execute still pending, and a held observation lock.
They require bounded persisted diagnostics and the original exit 124, not
successful cancellation or a reproduced native hang. Focused non-UI checks:

```sh
./scripts/test-copilot-setup.sh --compile-only
.build/setup-tests/setup-tests --filter CopilotSetupObservationTests
python3 scripts/test-metadata-watchdog.py \
  --probe .build/setup-tests/metadata-watchdog-probe \
  --results-root .build/setup-tests/metadata-watchdog \
  --mode diagnostic-cancel-pending --mode diagnostic-cancel-returned \
  --mode diagnostic-lock-held
```

The navigation response-ordering fixtures inject a cancellation-aware,
non-expiring deadline through the connection model's navigation dependency.
Unrelated hosted main-actor delays must not turn those ordering checks into a
wall-clock timeout test. A separate injected-deadline control requires timeout
and rejection of late host success; the existing real-delay timeout test remains.
Default connection construction still uses the unchanged ten-second production
deadline.

Focused history/preference diagnostics after building the validation products
(not a full-suite pass):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project CMUXMaestroPreview.xcodeproj -scheme CMUXMaestroPreview \
  -configuration Debug -derivedDataPath .build/tests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CMUX_BUNDLE_ID_SUFFIX=.Validation.Tests \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_VALIDATION' \
  CMUX_SIDEBAR_EXTENSION_POINT_ID=com.jdylanmc.CMUXMaestroPreview.validation.tests.sidebar \
  test-without-building \
  -only-testing:CMUXMaestroPreviewTests/SidebarPreferencesTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarHistoryTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarHistoryPollingTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarPreferenceCoordinationTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarAttentionTests \
  -only-testing:CMUXMaestroPreviewTests/SidebarAttentionCoordinationTests
```

The test runner compiles a fixture-only client from the production preference
sources. Tests inject unique defaults suites and files beneath
`.build/preference-coordination/`; they never mutate production preferences.
File-I/O-heavy preference suites serialize independent cases and yield between
fixture phases so synchronous coordination does not starve unrelated UI timers.
Dedicated coordination tests still exercise simultaneously blocked writers in
separate processes and automatic observation, without manual refresh.

Xcode can register macOS app outputs with LaunchServices even when signing is
disabled. Validation builds therefore use isolated identities **and** isolated
extension points, rather than an unsupported registration-suppression setting:

| Script | App bundle ID suffix | Extension point |
| --- | --- | --- |
| `build-unsigned.sh` | `.Validation.Unsigned` | `com.jdylanmc.CMUXMaestroPreview.validation.unsigned.sidebar` |
| `test.sh` | `.Validation.Tests` | `com.jdylanmc.CMUXMaestroPreview.validation.tests.sidebar` |

The sidebar, helper and test bundle IDs use the same suffix. These copies cannot
replace the production identity or appear under CMUX's real sidebar point,
even if Xcode registers them. They are validation artifacts, not installable
CMUX sidebar providers; do not use their installer UI for integration setup.
The scripts verify resolved settings before building and
the resulting app/extension metadata afterward. Run these scripts rather than
an unqualified application build while a native integration is installed.

Validation builds also compile a settings-only app scene: test runs do not open
the Copilot setup window. If opened manually, a validation copy shows only a
read-only explanation. Install and uninstall are rejected before executable
lookup, filesystem access, or CLI invocation unless the containing app has the
exact production bundle identity. Use the installed production app for setup,
never a window labelled **Test Validation** or **Unsigned Validation**.
Resolved build checks require the no-window compilation condition for validation
and reject it for production. Tests cover both the zero-window host and
zero-side-effect install/uninstall denial; fake production setup tests explicitly
inject the production identity.

Focused, isolated setup, hook, and sandbox checks (no SDK fetch or app launch):

```sh
./scripts/test-copilot-hook.sh
./scripts/test-copilot-setup.sh
./scripts/test-copilot-sandbox.sh
python3 ./scripts/test-build-metadata.py
python3 ./scripts/test-local-preview.py
```

Tests use synthetic roots and injected installer/process seams. The standalone
hook smoke compiles production and **separately test-flagged** executables,
invokes them from a foreign working directory, and checks binding creation,
malformed input, disable flags, and zero output. The injected ancestry exists
only in that synthetic binary; app Debug/Release builds have no environment or
command-line switch that forges owner proof. Installer tests invoke fake
executables only, never the live Copilot plugin CLI.

The sandbox check compiles the actual shared file helper and runs it under a
narrow `sandbox-exec` policy over a synthetic deep directory. Ancestors use
search-only descriptors; the final directory still requires read access.
The check denies ancestor contents, sibling reads, and writes, and exercises
owner checks, symlink rejection, and descriptor anchoring during path swaps.
Fixtures are removed afterward; this check creates no App Sandbox container.
`O_SEARCH` is declared in Apple's
[macOS 14-era XNU headers](https://github.com/apple-oss-distributions/xnu/blob/xnu-10002.1.13/bsd/sys/fcntl.h#L184)
and [macOS 15-era headers](https://github.com/apple-oss-distributions/xnu/blob/xnu-11215.1.10/bsd/sys/fcntl.h#L184),
covering this project's macOS 14 deployment target.

These tests do **not** prove actual plugin installation, cached-hook loading,
live owner ancestry, or ExtensionKit-hosted runtime behavior.

## Install a stable local preview

This is a **local, user-owned preview**, not a public release, auto-updater,
notarized distribution, license decision, or legacy-plugin cutover. The stable
default is **`~/Applications/CMUX Maestro Preview.app`**. Its app, extension and
bundled helper no longer depend on a disposable Git worktree after installation.
The Python 3 command uses the standard library and macOS `ditto`, `codesign`,
LaunchServices and `pluginkit`; it does not install a service or dependency.

The alpha installer coordinates the app and its owned Copilot integration as
one journaled operation. The implemented owned-source boundary uses public
exact-source identity for the fixed owned path and rejects foreign or unproven
owned provenance; unrelated plugins are preserved, not certified.
**Issue #114 still requires current-head independent review, full hosted CI,
combined installer/native-host acceptance and guarded live installed-session
acceptance.** Registration withdrawal/re-registration or earlier native-only
proof does not establish the current combined artifact's loaded-generation
behavior or live acceptance.

Before native retirement, the installer queries the exact production extension
identifier and public sidebar extension point. It reports eligible external
same-ID paths instead of changing the app and discovering a blocked native
reload afterward. Receipt-owned paths and this checkout's verified development
source are recognized; the latter can be retired only with the existing explicit
`--retire-development-registration` option. Ignored/superseded records are
preserved; unknown or debugger-only election is reported as ambiguity. Other
identifiers/extension points and unrelated Copilot plugins are outside this check.
Historical external registrations need a separate ownership/consent decision,
not adoption, a namespace sweep or a routine manual-uninstall step.

From a trusted checkout, explicitly build and install the ad-hoc-signed alpha:

```sh
./scripts/build-register.sh
```

To install an already-built, verified production artifact instead:

```sh
python3 scripts/local-preview.py install \
  --source "$PWD/.build/adhoc/Build/Products/Debug/CMUX Maestro Preview.app" \
  --retire-development-registration
```

Both commands are **explicit publication actions**, not validation commands.
`build-register.sh` invokes the same coordinated installer after validating the
built product; it no longer separately publishes the development extension.
Xcode can still register its source app during the build. There is no supported
`REGISTER_APP_WITH_LAUNCH_SERVICES=NO` setting. The install command stages and
verifies the signed copy, atomically installs it, then retires **only this
checkout's known `.build/adhoc` registration** before registering the stable
app and extension. The flag is optional for separately supplied signed
artifacts; no other development copies are discovered or deregistered.
Source files are **never removed**.

The helper target explicitly supplies its resolved production/validation
identifier to `codesign`; otherwise a command-line tool can retain its
linker-generated identifier despite `PRODUCT_BUNDLE_IDENTIFIER`. Publication
and installation verify the effective helper identity. Rebuild older products
with linker-generated helper IDs; they are not accepted as install sources.
The helper's optional `com.apple.application-identifier` entitlement must match
that exact identity. It does not permit additional access entitlements.

The command confirms the exact production bundle ID and canonical path in
both LaunchServices and the extension registry—not merely exit status zero.
The extension parser accepts pluginkit's documented election markers, including
`=` (superseded) and `?` (unknown); retained sibling registrations do not prevent
an exact match, and are never removed merely for appearing in the listing.
This does not claim CMUX has selected or loaded the new extension.

Copilot setup is included. The installer invokes a production-only, non-UI
bridge from its verified candidate, preserving the stable destination helper
path. It checkpoints the prior owned state before replacement and keeps the
app receipt/previous-generation retention pending until setup, public discovery
and exact app registration have succeeded. No setup window, separate Enable
action or chat restart is required. An explicit `--copilot-executable` option
is accepted by both commands when the intended CLI is not on `PATH`.
New source artifacts must advertise the signed `copilot-install-v1` and
`graceful-lifecycle-v1` capabilities in their containing-app metadata.
Both configurations merge these custom markers from
`CMUXMaestroPreview/Info.plist`; Xcode still generates the namespace-specific
bundle identifiers and versions. Arbitrary `INFOPLIST_KEY_*` build settings
alone do not emit these custom keys.
Older installed apps can still be
upgraded or restored; an old source artifact lacking the bridge is rejected
before launch, rather than risking its GUI interpreting an unknown argument.
Completion reports configured all/subset disables or unresolved disable-key
applicability separately from ordinary current-on-disk state.

### Update, rollback and status

Updates journal and verify their candidate before automatically withdrawing
only the receipt-owned app/extension registration. The installer verifies
registration absence, then waits up to 120 seconds for positively identified
preview executables to exit before replacing the app. It re-registers the stable
app afterward. Selecting CMUX's Default sidebar is not an installer prerequisite;
`cmux sidebar reload` is not used.

A running receipt-owned containing app is handled automatically: the installer
journals its process generation, code identity and hidden state, then requests
a normal quit through `NSRunningApplication.terminate()`. Exact bundle and
executable paths, owner/start generation and running code identity must match;
same-name apps, other copies, extensions and helpers are not quit targets.
An accepted quit request is not exit proof: the existing kernel process guard
must still observe release before replacement. Refusal or continued execution
aborts safely, without force termination.

If the containing app was running, successful update or failure recovery
restores a verified instance of the appropriate app through `NSWorkspace` at
the exact path. Launch disables activation, other-app hiding, version
substitution, duplicate-instance creation, recent-item changes and optional
system prompts. An already-running exact instance is reused without activation.
Quarantined apps refuse background relaunch rather than risking Gatekeeper UI
or changing quarantine/permission settings. An app that was previously closed
stays closed, and an identical verified install does not quit or relaunch it.
Relaunch intent/results are journaled for interrupted recovery.

Helpers, extensions and unverifiable processes still block replacement;
they are never force-killed. No operation quits CMUX, restarts a CLI session,
injects terminal input or uses an activation/keystroke fallback.
Registration and process checks do not prove that the stock host
observed the disappearance and loaded the replacement; hosted native acceptance
is still required.

An unrelated application's updater can leave a live process whose old executable
path has been deleted. For that specific missing-path condition, the installer
compares the kernel-cached executable code-directory hash with every Mach-O
architecture in the receipt-verified preview apps and backups. It requires
unchanged bundle contents, process ownership/start time and executable identity.
A matching hash, missing signature, unsupported/partial inventory, changed
evidence or permission denial still blocks the update. No process is exempted
by name or terminated. Mapped-library listings are not used as proof of the
running executable's identity.

The older **`prepare-update`** operation remains an optional explicit
registration-withdrawal diagnostic, not a required step. Update and rollback
perform withdrawal themselves. Preparation does not delete or replace app
files, change plugin settings or signal any process. If preparation is
interrupted or you decide not to update, **`recover`** restores the current
registration. Until update/rollback/recovery completes, `status` can report the
expected missing registration; an identical no-op correctly requires that
registration to be present.

```sh
# For a separately built production artifact:
python3 scripts/local-preview.py update \
  --source "$PWD/.build/adhoc/Build/Products/Debug/CMUX Maestro Preview.app" \
  --retire-development-registration
python3 scripts/local-preview.py status

# Legacy app-only historical rollback (separate integration maintenance):
python3 scripts/local-preview.py rollback

# Cancel preparation without changing the installed build:
python3 scripts/local-preview.py recover
```

Normal install/update refresh Copilot in the same transaction. The historical
explicit `rollback` command retains its app-only compatibility behavior for
older backups, including versions without the new bridge; it is distinct from
automatic combined failure recovery and may require explicit integration
maintenance afterward.
The stock host's identity-disappearance/reappearance behavior motivates the
automatic registration transition, but mocked registry tests do not establish
real loaded-generation or focus-preservation acceptance.

Updates may replace a changed development build with the same build number,
but never silently downgrade. `install` also upgrades an existing receipt-owned
app in place; manual uninstall is not required. An identical artifact verifies
the app, exact registration, owned integration resources and public provider
state. A fully current repeat skips app/resource replacement and plugin mutation.
If only integration needs repair, the same command performs a journaled
integration refresh without exchanging the app. It does not require idleness because no
executable is replaced. Missing registration or altered app contents still
refuse rather than masquerading as a verified no-op. Explicit development-source
retirement still applies when requested.
Rollback revalidates the previous app's **own** matching app/extension
version, strict ad-hoc signatures, production identities and compatible
entitlements. A previous preview with fewer approved read-only grants is
allowed; missing sandbox, broader or unknown grants, unsigned components and
test namespaces are refused. Normal publication/install validation still
requires the current build number; this feature does not bump it.

### Transaction and recovery contract

- One kernel-held, nonblocking install lock and a private `0700` ownership
  directory live at `~/Applications/.cmux-maestro-preview-install/`. Receipts
  are `0600`, atomically written and synchronized. The persistent lock file is
  **not a stale lock** just because the caller has exited. A one-command
  Python supervisor retains the lock while a mutating `ditto`, `lsregister`
  or `pluginkit` invocation, or a non-UI integration bridge, runs, including
  after caller timeout or `SIGKILL`.
  The trusted integration bridge also inherits the descriptor solely to record
  its nested provider groups; other tools and actual provider executables do
  not receive it. Each provider starts behind an EOF-safe gate, and cannot
  execute until its separately owned group is recorded and synchronized.
  The supervisor waits for both the bridge group and every recorded provider
  group, not merely direct-child exit or pipe EOF. Killing the bridge therefore
  cannot permit restoration while its provider can still write.
  There is no installed daemon or persistent background observer.
- A bounded marker in that same lock file records command progress. A gated
  launcher cannot execute the tool until its private process group is durably
  recorded. If the supervisor itself dies, a new lock owner still refuses
  recovery while any recorded bridge/provider group exists—even if their
  original supervisors exited. Once all groups are gone, recovery may resume; a launcher whose
  group was never recorded cannot pass its gate. Corrupt/unverifiable markers
  fail closed. Never delete or truncate the lock to bypass this barrier.
- The 120-second command timeout ends the caller's wait, **not** a surviving
  mutator's lifetime. Wait for the protected workers to finish, then retry
  `recover`. A hung worker continues to block new operations rather than risk
  a delayed deregistration affecting a later installation. This supervision
  is for the fixed foreground macOS tools, not a general-purpose launcher for
  programs that daemonize into independent sessions. It does not control
  unrelated operating-system services or other apps' registry requests.
- Source and staged copy must match an integrity receipt and pass effective
  signed-profile verification. Files and directory metadata are synchronized
  before commit. Darwin `renamex_np(RENAME_SWAP)` exchanges an update/rollback
  with the live destination in one operation: there is no deliberate
  missing-app interval. First install uses exclusive rename. Unsupported
  filesystems fail closed; there is no non-atomic replacement fallback.
- A completed update retains **one verified previous app** in an owned slot.
  It may also retain **one inactive retired app**, separate from that required
  rollback generation. Preparation permits at most **four** managed bundles:
  current, previous, retired and one staging candidate. Completion returns to
  at most **three**: current, previous and retired. These are archival bounds,
  not additional active installations or process permissions.
- A healthy retired slot does not block a verified identical install or trigger
  housekeeping. A changed candidate is staged and verified before reclaiming
  the old retired slot. Reclamation is journaled and occurs only while the
  owned native registration is withdrawn and relevant owned processes are
  idle. Partial staging remains unverified node-owned cleanup, never a trusted
  retired artifact.
- Successful update retains the old previous generation as retired. Failed
  update retains the verified failed candidate after restoring the original
  current/previous generations. Its bridge remains available for compensation,
  checkpoint release and non-activating relaunch even when the older app has
  no bridge. All owned registration retirement precedes final publication;
  no same-ID unregister, deletion or forced refresh follows it. A failed
  release or relaunch remains pending rather than becoming healthy retirement.
- Recovery verifies an already-correct exact registration without forcing
  `lsregister -f` again. An absent exact app/extension pair can be registered;
  during verified transaction-owned publication, an app-present/extension-absent
  pair is completed with only `pluginkit -a` for the exact extension. The app is
  not registered again. The pair is rechecked before completion and read back
  afterward. Extension-present/app-absent remains unsafe to force because the
  extension may already be hosted; partial pairs outside transaction authority
  also refuse. Errors include the exact observed pair rather than hiding it.
  A durable verified commit finishes release/retention; pre-commit failures
  still restore the previous working state. Explicit uninstall includes only
  receipt-owned retired storage under its existing consent and idle guards.
- Before app replacement, a private `0600` checkpoint at
  `~/Library/Application Support/CMUXMaestroPreview/Orchestration/install-transaction.json`
  captures the fixed owned resource set, registration provenance, prior absence,
  modes and public provider identities. It is outside every sidebar-readable
  prefix; no sandbox grant is added. Its schema, exact paths, file bounds and
  transaction identity are validated before recovery. Separate setup refuses
  while the coordinated transaction is pending.
- Every observer-receipt write records its exact permitted bytes, permissions
  and independently established source provenance in the checkpoint before
  publication. Recovery without a final `after` snapshot accepts only the
  known prior image or those bounded exact intents, never desired-generation
  equality alone. Edited plugin/source identities preserve their bytes and
  pending journal. Durable-after and resource-only enrichment checks remain
  strict; ambiguous older interrupted checkpoints are not guessed into authority.
- The app receipt journals the companion transaction ID and its progress.
  Pending failure recovery first verifies/restores integration, using official
  `plugins.install` at the unchanged owned source path or `plugins.uninstall`
  scoped by the returned `directSourceId` for prior absence, then restores the
  old app and registration. The install RPC receipt binds that exact source;
  later discovery must match it. Current settings
  must still match the checkpoint's values or known CLI normalization; unrelated
  changes are not overwritten. A failed first install restores verified absence,
  not a fictitious previous app. New journals also capture and restore the exact
  application/extension registration of an explicitly retired development
  source. Older journals without that evidence refuse to guess.
- Copilot 1.0.89 supports disabling direct plugins, but its install/update
  operations re-enable them. Identical repeats and compatible external-resource
  updates still skip provider mutation. Payload replacement instead records the
  prior disabled state and mutation intent durably, keeps dedicated staging
  inactive, then uses the official `plugins.disable` API and identity-checked
  readback before publication or app commit. Recovery reapplies the same choice
  before claiming restoration, including after an interruption between install
  and disable. A disabled legacy observer migrates to a disabled dedicated file.
  Native-plugin state remains separate from an already-configured dedicated
  file's choice. Direct disable is not effective on 1.0.88 and is never claimed
  as a supported restoration there.
- Install and disable are separate provider operations, **not an atomic
  provider primitive**: the plugin can temporarily report enabled, and a crash
  can retain that state until recovery runs. Dedicated staging remains inactive
  throughout this interval; no success or restored-state claim is emitted
  without verification. New choices after verified apply, wrong source
  identities and unrelated changes are not overwritten. Standalone maintenance
  cannot replace a disabled native payload without the coordinated install
  checkpoint.
- The disposable-home source binding is recorded **before** real-home mutation,
  so loss of the real install response is not a name-only recovery boundary.
  Compensation independently bootstraps that same source again, checks current
  selection and prior provenance, and targets exact identity. First-install
  source files remain available until official removal succeeds, including
  across interrupted compensation. Failed bootstrap or changed foreign
  selection refuses further mutation and retains explicit recovery state.
- A surviving or unconfirmed command supervisor blocks restoration; the
  installer never races a still-running mutator. A failed restoration reports
  both errors and retains recoverable state. The durable commit decision is
  written only after both components are verified. An interruption after that
  decision finishes checkpoint/backup bookkeeping rather than undoing an already
  verified commit; cleanup errors remain explicit. No GUI reload or existing
  chat behavior is inferred from restoring registrations.
- A committed checkpoint awaiting cleanup blocks separate preparation,
  historical rollback and uninstall until `recover` finishes bookkeeping.
  Resuming a pending rollback re-verifies previously restored integration
  before changing the app; a concurrent user change cannot be hidden behind a
  saved `restored` phase. Malformed false-shaped checkpoint identities are
  rejected, not interpreted as legacy app-only state.

```sh
python3 scripts/local-preview.py status
python3 scripts/local-preview.py recover

# Recover interrupted replacement by restoring its previous app (or absence):
python3 scripts/local-preview.py recover --restore-previous
```

For coordinated installs with retained source authority, recovery restores both prior components whenever the
app receipt still records a pending transaction, including after the app has
already been exchanged. Older app-only journals retain their finish-forward
recovery behavior. Recovery can
resume its own interrupted cleanup or rollback. If no transaction is pending,
it verifies owned apps and refreshes the stable registration. A new explicit
`install`/`update` first restores any interrupted install's prior app state
before staging its requested artifact; it does not silently finish that
interrupted combined install.
`recover --restore-previous` restores absence after an interrupted first install.
Ambiguous identities, replaced partial-cleanup directories, foreign backups,
or corrupt receipts are refused rather than guessed or deleted. Preserve the
receipt, apps and original checkout/source while a transaction is pending.
Do not manually shuffle slots or remove metadata to force an update.

When exact LaunchServices verification fails, the error includes a single JSON
diagnostic: the operation (`verify`, `register`, `unregister`, `ensure-existing`
or `ensure-completed`), installer stage, transaction kind/phase, bundle ID, exact
target, and expected/observed presence. A failed query reports `observed: unknown`
and its exception class, never verified absence. The diagnostic uses the same
query result as the guard; it does not requery, dump registry contents or list
other application paths. Target strings are JSON-escaped. Direct adapter checks
without installer context report null stage/transaction/phase.

These diagnostics identify the failing check, not its cause or an installation
repair (#185). They cover the LaunchServices check in `verify_registration`;
earlier mutation/query failures and extension verification retain their existing
errors. Automatic restoration preserves the original diagnostic; if restoration
also fails, both failures remain in the error and the journal remains available.
Preserve the complete failure output. Successful later `status` verification
does not establish why the original installation failed. A new live installation
or recovery still requires its own authorization; diagnostics add no retry.

Only an existing, normal, non-root user's real home is used; `HOME` overrides
are not install roots. Symlink components, foreign ownership, group/world
writable paths, escaping bundle symlinks and hard-linked files are refused.
Internal relative framework symlinks are allowed. An alternate destination can
be specified **before** the command, but must be a direct `.app` child of the
same `~/Applications`, for example:

```sh
python3 scripts/local-preview.py \
  --destination "$HOME/Applications/My Maestro Preview.app" install \
  --source "$PWD/.build/adhoc/Build/Products/Debug/CMUX Maestro Preview.app"
```

The singleton receipt binds that destination; use the same option thereafter.
There is no automatic adoption, relocation or force-overwrite mode, even for
another apparently matching Maestro app. Ad-hoc signatures establish local
integrity and component identity, **not publisher authenticity**: choose a
trusted source. This is not protection against another process already
controlling your user account or machine.

### Remove only the owned local preview

First, in the stable containing app, explicitly choose **Uninstall Native
Plugin…** and confirm the official CLI action. Restart/resume sessions that
still cache its hooks when convenient, then close the containing app and
deselect the preview sidebar. Only after those hooks no longer need its
helper, explicitly remove the installed preview:

```sh
python3 scripts/local-preview.py uninstall --cached-hooks-retired
```

This deregisters and removes only the receipt-owned stable app and backups.
The option is an operator assertion, not a scan of private CLI state. An
interrupted removal is resumed by `recover`. Ownership metadata and the lock
remain for safe future installs. Observation records, history/attention
preferences, containers, native plugin settings and source builds are retained;
there is no purge option. Neither removal nor update touches `maestro-cmux`,
legacy settings, hooks, sidebars, other apps or CMUX configuration.

The synthetic install tests exercise real macOS atomic renames in
repository-local fixture directories, with injected signing, process and
registration adapters. They never access real Applications, Copilot settings
or user runtime data. Controlled fixture processes deliberately close their
descriptors, leave a delayed mutating descendant, and lose their caller or
supervisor to `SIGKILL`; tests prove recovery/new installation stay blocked
until those synthetic workers finish. No real app/session/tool is killed.
CI retains all existing build/test commands and adds these transaction
regressions. Compiled non-UI bridge fixtures also exercise app-plus-integration
publication and recovery across an actual installer-process exit. Live signed
installation, host selection and visual verification remain separate gates.

## Build and register locally

```sh
./scripts/build-register.sh
```

This explicit script builds with an ad hoc identity, verifies the production
namespace and signed profiles, then calls the coordinated alpha installer.
It **does install owned Copilot integration** together with the stable app.
It does not enable/select the sidebar, restart or adopt sessions, or modify
unrelated integrations. Build-only and validation scripts remain separate.
Xcode's own app-registration task can run during the requested production
build; the installer retires only that explicitly identified development
registration. Final registration checks require the production bundle ID and
canonical stable `.appex` path, not merely command success. They do not prove
the hosted UI loaded.

### Historical local-build diagnostic

An already-selected preview has historically retained a lost connection after replacement.
An observed workaround: right-click CMUX's sidebar toggle, select the default
sidebar, then reselect **CMUX Maestro Preview**. This recreated the host view
and loaded the replacement extension without restarting CMUX or Copilot
sessions in the observed case; it is not a universal fix or proof of an OS cause.
This is not a prerequisite or fallback claimed by the coordinated installer;
its automatic registration transition still needs stock-host acceptance.
`cmux sidebar reload` applies to interpreted Swift sidebars, not native `.appex`
extensions.

## Sandbox and distribution

The extension keeps App Sandbox enabled. Its only additional file grants are
read-only home-relative temporary exceptions, with required leading and trailing
slashes:

```text
/Library/Application Support/CMUXMaestroPreview/Copilot/
/.copilot/session-state/
```

No network client/server or arbitrary process/data access entitlement is added.
The installer app and identity command-line helper are unsandboxed: they must
run the explicitly selected CLI and write their own integration data. This is a
personal native distribution tradeoff, **not a claim of Mac App Store
compatibility**. Temporary file exceptions require distribution/review scrutiny.

A separately signed sandbox probe established that these exact read-only
prefixes permit synthetic nested identity/event reconstruction, while
unrelated reads and writes remain denied. That is **not** an
ExtensionKit-hosted runtime proof. Signed app/host loading and end-to-end
installation remain explicit manual verification gates.

## Identifiers and upstream contracts

| Component | Identifier |
| --- | --- |
| Containing app | `com.jdylanmc.CMUXMaestroPreview` |
| Sidebar extension | `com.jdylanmc.CMUXMaestroPreview.Extension` |
| Identity helper | `com.jdylanmc.CMUXMaestroPreview.CopilotHook` |
| Extension point | `com.cmuxterm.app.cmux.sidebar` |
| Copilot plugin | `cmux-maestro-native` |

Installation follows GitHub's [local plugin
instructions](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/plugins-creating):
`copilot plugin install <absolute-path>`; uninstall uses the manifest name.
The installed CLI currently accepts absolute local paths but warns that direct
repository, URL, and local-path installation is deprecated for a future release.
CMUX Maestro intentionally retains the working local-preview path; public
marketplace or release infrastructure remains out of scope.
Hook manifests follow the [command-hook
reference](https://docs.github.com/en/copilot/reference/hooks-reference), including
`version: 1`, `type: command`, `bash`, and `timeoutSec`.
