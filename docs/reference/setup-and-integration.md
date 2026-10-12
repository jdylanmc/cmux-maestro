# Setup and Copilot integration

What install does to Copilot, what it refuses, how disable and rollback behave. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

# CMUX Maestro

Compiled macOS CMUX sidebar. Shows Copilot sessions and explicit
terminal-backed orchestration hierarchies. Native sidebar reads locally. No companion daemon,
watcher, loopback server, XPC service, raw CMUX socket, or session-start ritual.
Separate interpreted Maestro project untouched. Not a dependency.

See [behavioral parity matrix](../behavioral-parity.md) for regression
evidence, live acceptance scope, intentional differences, remaining limits.

Sidebar path labels use real user's account home (`~` or `~/…`). Applies to
workspace/project paths, surface directories, hover and pinned details.
Formatting normalizes separators and dot components lexically. Never
probes filesystem. Never resolves symlinks. Outside paths stay absolute.
Missing/denied states stay explicit. Ownership/navigation values unchanged.
Account-home resolution failure: absolute label explains it.

**Surface directory** = directory CMUX reports for that exact
surface. Not independently verified agent process or last-tool working
directory. **Parent surface directory** = parent placement only. Not a
windowless child's own directory. Help and accessibility keep this source
qualification and the absence of a report timestamp. Fresh session observation
does not establish directory-report age. Assigned/last-verified Git worktree
labels are separate evidence, never directory fallbacks. Retained original
sessions do not borrow replacements' paths.

At pinned SDK/host revision `ae7fbce99f98c98df5ccf915e548dd080d33cfa8`,
[`CmuxSidebarSurface.workingDirectory`](https://github.com/manaflow-ai/cmux/blob/ae7fbce99f98c98df5ccf915e548dd080d33cfa8/Packages/macOS/CmuxExtensionKit/Sources/CmuxExtensionKit/Sidebar/CMUXSidebarSurface.swift)
is optional. `workspacePaths` filters it.
The [sidebar producer](https://github.com/manaflow-ai/cmux/blob/ae7fbce99f98c98df5ccf915e548dd080d33cfa8/Sources/ContentView.swift#L12736-L12748)
uses `reportedPanelDirectory(panelId:)`. Its
[implementation](https://github.com/manaflow-ai/cmux/blob/ae7fbce99f98c98df5ccf915e548dd080d33cfa8/Sources/Workspace%2BSidebarDirectories.swift#L48-L70)
normalizes panel report and applies remote trust gating. It does not use
separate `effectivePanelDirectory` local/requested-directory fallback.
Source-level provenance only. Not installed-host acceptance of #77 or
runtime-directory collection.

## One-time setup

1. Use [alpha installer](#install-a-stable-local-preview). Normal install
   and update include Copilot automatically. Separate setup action not
   required. Installer uses configured `PATH`, or explicit trusted
   `--copilot-executable /absolute/path/to/copilot`. It does not assume shell
   startup files or machine-specific provider cache paths.
2. Containing app keeps **Enable Copilot Integration** and
   **Choose Copilot…** for explicitly requested maintenance. These controls are
   not normal-install prerequisites. Production app also keeps the
   equivalent standalone maintenance command:

   ```sh
   "$HOME/Applications/CMUX Maestro Preview.app/Contents/MacOS/CMUX Maestro Preview" \
     --install-copilot-integration --copilot-executable "$(command -v copilot)"
   ```

   Same installer and production-identity checks. Opens no setup windows,
   changes no accounts, restarts no existing conversations.
   Normal app startup still performs no installation.
   Production preview builds disable coverage instrumentation. Setup leaves no
   `default.profraw` in caller's worktree. Test coverage stays enabled.
3. If not already enabled, select **CMUX Maestro Preview** in CMUX's **Sidebar
   Extensions** browser. Installation does not change host grants or selection.
4. Leave existing Copilot chats running. New sessions load installed
   configuration. Already-running sessions may retain cached hooks. Installation
   neither restarts nor adopts them. Fresh-session acceptance is separate from
   on-disk installation. Setup also
   installs bundled `/cmux-maestro-native:cmux-maestro-orchestrate`
   and `/cmux-maestro-native:maestro-icon`
   skills and local controller. Only newly Maestro-spawned managed
   sessions get native messaging bindings automatically.
5. For optional messaging guide, open Maestro **Settings > CLI Integration**.
   Copy global install command. Run it yourself as described below.
   Runtime setup never installs global guide.

Containing app = installer, not session observer. Close it
after setup. **Check Registration** reads only registration files. Successful
setup verifies dedicated file and hookless installed plugin on disk and
through provider discovery. It does not imply loaded hooks, observed events,
messaging readiness or enabled host extension.

Installer invocations start in own process group. **Cancel Setup** and
45-second timeout stop that invocation's launcher and descendants, then
wait for cleanup before permitting retry. Existing Copilot sessions never
signalled. Same applies to bounded, metadata-only `status.get`,
`hooks.discover` and `plugins.list` checks during explicit setup. Each process
has same deadline. Setup starts no agent/model session or persistent
service. Metadata output capped at 256 KiB. Never displayed as raw
CLI output.
Setup passes `--no-auto-update`. Plugin change does not opt into upgrading
selected CLI.

Setup installs distinct, now **hookless `cmux-maestro-native`** plugin and
its bundled skills, private local controller, native loader at
`~/.copilot/extensions/maestro/extension.mjs`, and
**`~/.copilot/hooks/cmux-maestro-observer.json`**. Dedicated version-1 file
declares only `sessionStart`, `userPromptSubmitted` and `postToolUse`, using
unchanged silenced helper wrapper. Private generation/provenance and
advisory setup lock live under existing application `Copilot/` support
directory. Managed tools require matching launcher/session/workspace/generation
bindings. Ordinary CMUX sessions can expose only nonprivileged
[`maestro_readiness` diagnostic](../native-messaging-architecture.md#ordinary-session-readiness-partial-162).
It does not enroll session or enable Joe activation. Existing
`maestro-cmux`, other plugins, provider settings, and sidebar selection
never replaced automatically. Normal app updates refresh owned integration
through coordinated installer. Generated hooks use **stable installed
helper path**, never staging or backup location. Manual moves outside
receipt-owned destination remain unsupported by app installer.

Observer setup attempts **stable Copilot CLI 1.x releases using protocol 3**.
Other major versions, prereleases and protocols remain unsupported. Compatibility
still requires valid public metadata, exact-source identity and verified operation
readback. Version range alone does not establish runtime compatibility.
Conflicting `HOME` or `COPILOT_HOME` is rejected. This does not broaden
reader beyond standard `~/.copilot`. Setup rejects unsafe, symlinked,
hard-linked, modified or foreign owned-target registration and ambiguous owned sources.
It does not chmod existing shared hooks directory.
Historical plugin-hook reformatting also requires review. Provider disable-key
identity can depend on serialization, not just semantically equal JSON.

Before changing existing owned installation, setup submits its exact safe
absolute source path to public plugin-install RPC in private disposable
provider home. On originally tested 1.0.88 and 1.0.89 versions, that source's returned identity
is home-independent. It must match real provider's selection and any prior
receipt before real-home changes. Legacy/name-derived receipts cannot authorize
their own adoption. Request path, provider version/protocol and returned
identity are recorded together. Subsequent install results and discovery must
match. Fresh source is bound and recorded before its first real-home provider
mutation. No private source-ID algorithm or guessed provider directory used.

Unrelated plugin identities and public hook rows preserved. Not audited
through cache aliases or common event names. Live, built-in and opaque unowned
plugins do not cause blanket refusal. Earlier linked-source/safe-cache-alias
counterexample remains evidence that such audit was false. Not evidence of
safe foreign actions. **An independent unowned plugin can still call the current
or an older helper and cause extra executions/writes.** Setup neither certifies
nor suppresses that behavior. Status describes **owned registration** only.
Unsafe owned paths, owned-name/source collisions and directly inspected
user-file conflicts remain targeted refusals.

For recognized direct legacy installation, setup: records provenance
and stages **owned disabled** dedicated file; confirms disabled discovery;
prepares hookless plugin; runs official plugin installer; verifies installed
observer declarations are gone; only then publishes
intended dedicated state. This migration never enables old and new owned observer sources
at same time.
Maestro does not rewrite unrelated hooks or disable keys.
Official CLI does rewrite `settings.json` during plugin install/uninstall,
including when values unchanged. After successful command, setup accepts
only identical settings object or addition of empty `enabledPlugins` map.
All other values, including disable choices and unrelated preferences, must
remain identical. Unsafe or unexpected changes leave setup incomplete.
If setup fails during disabled staging, before resource preparation or any
plugin command starts, it restores and verifies previous owned observer
file and provenance (including prior absence and permissions). Cancellation
waits for that bounded restoration. Changed owned file never overwritten
to force rollback. Resource preparation snapshots all named owned resources
before writing. Later resource-file write failure conditionally restores their
previous bytes, absence and permissions, then restores observer staging when
that restoration is verified. Unchanged resources keep file identity.
Preflight refusal reported as no resource-file writes, not as rollback.
Standalone maintenance reports later incomplete phases conservatively. Normal
alpha installation additionally uses durable coordinated checkpoint. Failure
or pre-commit interruption restores previous owned files and compensates
provider through official install/uninstall operations at same stable
owned source path. Then verifies public discovery before restoring app.
Rollback restores saved settings bytes only after verifying current values
still match original settings or documented empty-plugin-map
normalization. Unexpected user changes block compensation. Never overwritten.

**Disable preservation is conservative.** Provider omits destination keys
for file-disabled source. When registration change would require mapping
global `disabledHooks`, setup refuses before changing legacy registration.
It neither guesses hashes nor enables duplicate to obtain keys. Change may
proceed with unrelated disables only when complete exact-owned prior metadata
supplies every key, every owned event is enabled, and every configured key is
positively identified as unrelated. Missing/ambiguous keys and affected disabled
subsets still refuse. Settings stay unchanged apart from bounded official
CLI normalization described above. Already
current dedicated registrations keep unchanged hook configuration and
keys. Whole-file/global disable does not bypass unresolved per-key gate:
later re-enabling must not lose disabled subset. Otherwise, explicit
global/file `disableAllHooks` leaves owned file disabled,
including after global flag later cleared. Review owned file and
explicitly change its disable flag before requesting activation again.
No general settings editor or additive disable-key migration. Coordinated
installer's guarded restoration is not permission to accept
arbitrary concurrent settings edits.

**Status retains disable detail.** Completed registration records bounded
opaque provider keys tied to its exact generation and tested provider version.
Check Registration remains file-only. It distinguishes all/some configured
observer disables using that receipt. Reports unresolved applicability for
unknown keys or stale/missing provenance. Never guesses that unrelated key
disables observer. Never starts metadata subprocess. Incomplete transaction or
conflicting/missing plugin state takes precedence over ordinary disabled status.
Verified setup with preserved all/subset disables = successful CLI completion
(stdout, exit 0), with explicit disable message. Actual failures remain
nonzero. Malformed command arguments keep usage exit 2.

Failures identify last completed phase, not blanket installation success.
Interrupted transaction may retain disabled owned file while old
plugin remains installed, or leave hookless plugin awaiting publication.
Retry revalidates provenance and content. Retained disabled stage stays
disabled conservatively. Foreign edits require manual review, not automatic
rollback. Existing sessions keep cached hooks. Any provider reload,
restart or resume is human-owned. See
[compatibility limits](../behavioral-parity.md#dedicated-observer-registration-114).

Messaging launch configuration and stored nodes keep three-field
`{version, routes, extension}` contract. Obsolete `pluginDirectory` setup
field is ignored for compatibility. Never validated or passed to Copilot.
Managed launches keep `--experimental`, pins, denies, coordinator-only explicit
YOLO and terminal I/O. They do not require guide or pass `--plugin-dir`.
