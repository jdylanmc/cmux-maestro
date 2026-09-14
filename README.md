# CMUX Maestro

A compiled macOS CMUX sidebar that displays Copilot sessions and their durable
agent hierarchy. The native sidebar reads locally; no companion daemon,
watcher, loopback server, XPC service, raw CMUX socket, or session-start ritual.
The separate interpreted Maestro project is untouched and is not a dependency.

## One-time setup

1. Build/register the native app and extension, or open an installed build.
   Keep the app at its intended location before enabling integration.
2. Open **CMUX Maestro Preview**. Click **Enable Copilot Integration**, then
   explicitly confirm **Install Native Plugin**. If the app's configured `PATH`
   cannot find Copilot, use **Choose Copilot…** to select the trusted executable
   you normally run. No shell startup files or machine-specific cache paths are
   assumed.
3. In CMUX's **Sidebar Extensions** browser, enable **CMUX Maestro Preview** and
   select it as the active sidebar.
4. Restart or resume already-running Copilot CLI sessions **once** to load the
   newly installed plugin. Maestro never restarts them automatically. Launch
   future sessions normally inside CMUX; their hooks record validated identity
   and the sidebar renders the tree directly from durable events.

The containing app is an installer, not an observer. It may be closed after
setup. A successful setup message means the selected CLI exited successfully;
it does not claim a running session has already loaded the plugin or that the
host extension has been enabled.

Installer invocations start in their own process group. **Cancel Setup** and
the 45-second timeout stop that invocation's launcher and descendants, then
wait for cleanup before permitting retry; existing Copilot sessions are never
signalled. CLI output remains suppressed.

Only the distinct **`cmux-maestro-native`** plugin is installed. Existing
`maestro-cmux`, other plugins, provider settings, and sidebar selection are
never replaced automatically. Moving/replacing the native app requires enabling
the integration again: Copilot caches local plugin contents, and generated hooks
contain the **absolute current bundled helper path**.

### Disable or uninstall

Use **Uninstall Native Plugin…**, then explicitly confirm. This runs only
`copilot plugin uninstall cmux-maestro-native`. Restart/resume existing CLI
sessions to unload their cached hooks. Disable this sidebar in CMUX separately
if desired; uninstall does not select or remove any other provider.

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

### Bounded retention and discovery

- The 256-row reducer budget retires the oldest terminal **leaf**, not active,
  idle, blocked, or unknown work. Retained descendants, pending requests, and
  unresolved active ownership protect their ancestors. Agent row IDs stay stable
  across fresh lifecycles; retirement does not permanently blacklist an agent ID.
  Completed tool ownership is reclaimed separately so the 4,096-relationship
  budget does not become the next long-session bottleneck. Recent completed
  owners still support delayed parent joins; retired joins remain unresolved.
- Spawn replay keys use the spawn tool ID; turn replay keys use owner + turn ID.
  A new spawn tool or previously unseen scoped turn is fresh activity, even for
  a retained or retired terminal agent. Completions pair with the row's current
  spawn, so a late old completion cannot finish a newer lifecycle. A turn alone
  recreates an unknown agent, not an invented old name/parent/spawn. Enriching an
  unknown row must not silently discard its pending requests.
- Work/lifecycle/tool/request replay keys keep up to 4,096 exact recent tombstones.
  Older identities spill into a deterministic 128-KiB replay filter; its bits are
  never cleared within a transcript generation. This bounded filter has no false
  negatives, but can have false positives: a cold match suppresses resurrection
  **and reports `readLimitReached`**, rather than claiming exact replay knowledge.
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
  newer bytes remain; this is not a current/complete snapshot. Torn or malformed
  prefixes cannot become fabricated complete evidence. A failed observation
  cannot pin every later session indefinitely.
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

**Downstream integration (PR #27 history / PR #28 attention):** merge the
retention policy into the richer reducer, not a wholesale reducer replacement.
Preserve terminal timestamps/event IDs, request ownership and resolved-request
tombstones, started-lifecycle/event replay guards, attention ordering, and
`canPublishProjection`. Apply bounded spill/fail-closed handling to those richer
guards too; retaining their old fixed event/tombstone rejection caps would merely
move the starvation point. Retiring a row must clean its terminal attention,
turn/activity/outcome state and obsolete tool joins without discarding pending
requests, unknown placeholders, or required ancestors. Keep history presentation
limits separate from ingestion/admission limits. Keep agent identity distinct
from lifecycle identity: history/attention terminal records and replay guards
must preserve current-spawn/turn pairing, allow fresh scoped starts after row
retirement, and never attach an old completion to a new spawn. Carry finite
catch-up watermarks, staged-binding revalidation, and overflow scheduling together
with the reader. Re-run the continuous-session, reconstruction, exact versus fresh
lifecycle replay, multi-batch overflow, append-traffic, and attention tests together.

## Requirements

- macOS 14 or newer.
- Xcode 26.6 at `/Applications/Xcode.app` for local builds.
- CMUX with sidebar ExtensionKit support.
- A Copilot CLI version supporting local plugin installation and the three
  documented command hooks, with canonical session identity in hook input.

The CMUX ExtensionKit package is pinned to CMUX commit
`ae7fbce99f98c98df5ccf915e548dd080d33cfa8`. It is fetched into ignored
`vendor/CmuxExtensionKit/`; no CMUX source changes are required.

**Host footer compatibility:** the native view reserves 50 points of bottom
clearance for the current CMUX overlaid footer. The SDK provides no footer-inset
contract; a rendered-strip regression test checks that both sidebar modes leave
this area clear. Reverify the clearance when host chrome changes.

## Build and test

```sh
./scripts/fetch-sdk.sh
./scripts/build-unsigned.sh
./scripts/test.sh
```

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

## Build and register locally

```sh
./scripts/build-register.sh
```

This explicit script builds with an ad hoc identity, registers the embedded
extension with `pluginkit`, and verifies discovery of
`com.jdylanmc.CMUXMaestroPreview.Extension`. It **does not install a Copilot
plugin**, enable/select the sidebar, launch an observer, or modify a legacy
integration. Plugin installation is a separate deliberate in-app consent step.
It explicitly pins production IDs and the real CMUX point, verifies resolved
settings and source sandbox grants before the build, and checks built IDs,
point, strict signatures, and the extension's effective sandbox grants before
its explicit `pluginkit` registration. Xcode's own app-registration task can
also run inside this deliberately requested publication build.
The post-registration check requires the production bundle ID and canonical
`.appex` path in the registry listing; it does not prove the hosted UI loaded.

### After replacing a local build

An already-selected preview may retain a lost connection after replacement.
An observed workaround: right-click CMUX's sidebar toggle, select the default
sidebar, then reselect **CMUX Maestro Preview**. This recreated the host view
and loaded the replacement extension without restarting CMUX or Copilot
sessions in the observed case; it is not a universal fix or proof of an OS cause.
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
Hook manifests follow the [command-hook
reference](https://docs.github.com/en/copilot/reference/hooks-reference), including
`version: 1`, `type: command`, `bash`, and `timeoutSec`.
