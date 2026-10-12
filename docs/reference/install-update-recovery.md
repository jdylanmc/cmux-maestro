# Install, update, and recovery

Stable local preview install, update, rollback, recover, transaction contract, uninstall. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

## Install a stable local preview

This is a **local, user-owned preview**. It is not a public release, auto-updater,
notarized distribution, license decision, or legacy-plugin cutover. Stable
default: **`~/Applications/CMUX Maestro Preview.app`**. App, extension and
bundled helper do not depend on a disposable Git worktree after install.
The Python 3 command uses the standard library and macOS `ditto`, `codesign`,
LaunchServices and `pluginkit`. It does not install a service or dependency.

The alpha installer coordinates the app and its owned Copilot integration as
one journaled operation. The owned-source boundary uses public
exact-source identity for the fixed owned path. It rejects foreign or unproven
owned provenance. Unrelated plugins are preserved, not certified.
**Issue #114 still requires current-head independent review, full hosted CI,
combined installer/native-host acceptance and guarded live installed-session
acceptance.** Registration withdrawal/re-registration or earlier native-only
proof does not establish the current combined artifact's loaded-generation
behavior or live acceptance.

Before native retirement, the installer queries the exact production extension
identifier and public sidebar extension point. It reports eligible external
same-ID paths. It does not change the app first and discover a blocked native
reload afterward. It recognizes receipt-owned paths and this checkout's verified development
source. Retire the latter only with the explicit
`--retire-development-registration` option. Ignored/superseded records are
preserved. Unknown or debugger-only election is reported as ambiguity. Other
identifiers/extension points and unrelated Copilot plugins are outside this check.
Historical external registrations need a separate ownership/consent decision.
Do not adopt them, sweep a namespace or treat them as a routine manual-uninstall step.

From a trusted checkout, build and install the ad-hoc-signed alpha explicitly:

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
`build-register.sh` validates the built product, then invokes the same coordinated installer.
It does not separately publish the development extension.
Xcode can still register its source app during the build. No
`REGISTER_APP_WITH_LAUNCH_SERVICES=NO` setting is supported. The install command stages and
verifies the signed copy, installs it atomically, then retires **only this
checkout's known `.build/adhoc` registration** before registering the stable
app and extension. The flag is optional for separately supplied signed
artifacts. No other development copies are discovered or deregistered.
Source files are **never removed**.

The helper target supplies its resolved production/validation
identifier to `codesign` explicitly. Otherwise a command-line tool can keep its
linker-generated identifier despite `PRODUCT_BUNDLE_IDENTIFIER`. Publication
and installation verify the effective helper identity. Rebuild older products
with linker-generated helper IDs. They are not accepted as install sources.
The helper's optional `com.apple.application-identifier` entitlement must match
that exact identity. It does not permit additional access entitlements.

The command confirms the exact production bundle ID and canonical path in
both LaunchServices and the extension registry. Exit status zero is not enough.
The extension parser accepts pluginkit's documented election markers, including
`=` (superseded) and `?` (unknown). Retained sibling registrations do not prevent
an exact match. They are never removed merely for appearing in the listing.
This does not claim CMUX has selected or loaded the new extension.

Copilot setup is included. The installer invokes a production-only, non-UI
bridge from its verified candidate, preserving the stable destination helper
path. It checkpoints the prior owned state before replacement. It keeps the
app receipt/previous-generation retention pending until setup, public discovery
and exact app registration succeed. No setup window, separate Enable
action or chat restart is required. Both commands accept an explicit `--copilot-executable` option
when the intended CLI is not on `PATH`.
New source artifacts must advertise the signed `copilot-install-v1` and
`graceful-lifecycle-v1` capabilities in their containing-app metadata.
Both configurations merge these custom markers from
`CMUXMaestroPreview/Info.plist`. Xcode still generates the namespace-specific
bundle identifiers and versions. Arbitrary `INFOPLIST_KEY_*` build settings
alone do not emit these custom keys.
Older installed apps can still be
upgraded or restored. An old source artifact lacking the bridge is rejected
before launch, to avoid its GUI interpreting an unknown argument.
Completion reports configured all/subset disables or unresolved disable-key
applicability separately from ordinary current-on-disk state.

### Update, rollback and status

Updates journal and verify their candidate, then automatically withdraw
only the receipt-owned app/extension registration. The installer verifies
registration absence, then waits up to 120 seconds for positively identified
preview executables to exit before replacing the app. It re-registers the stable
app afterward. Selecting CMUX's Default sidebar is not an installer prerequisite.
`cmux sidebar reload` is not used.

The installer handles a running receipt-owned containing app automatically. It
journals the process generation, code identity and hidden state, then requests
a normal quit through `NSRunningApplication.terminate()`. Exact bundle and
executable paths, owner/start generation and running code identity must match.
Same-name apps, other copies, extensions and helpers are not quit targets.
An accepted quit request is not exit proof. The existing kernel process guard
must still observe release before replacement. Refusal or continued execution
aborts safely, without force termination.

If the containing app was running, successful update or failure recovery
restores a verified instance of the appropriate app through `NSWorkspace` at
the exact path. Launch disables activation, other-app hiding, version
substitution, duplicate-instance creation, recent-item changes and optional
system prompts. An already-running exact instance is reused without activation.
Quarantined apps refuse background relaunch, to avoid Gatekeeper UI
or changing quarantine/permission settings. An app that was previously closed
stays closed. An identical verified install does not quit or relaunch it.
Relaunch intent/results are journaled for interrupted recovery.

Helpers, extensions and unverifiable processes still block replacement.
They are never force-killed. No operation quits CMUX, restarts a CLI session,
injects terminal input or uses an activation/keystroke fallback.
Registration and process checks do not prove that the stock host
observed the disappearance and loaded the replacement. Hosted native acceptance
is still required.

An unrelated application's updater can leave a live process whose old executable
path was deleted. For that missing-path condition only, the installer
compares the kernel-cached executable code-directory hash with every Mach-O
architecture in the receipt-verified preview apps and backups. It requires
unchanged bundle contents, process ownership/start time and executable identity.
A matching hash, missing signature, unsupported/partial inventory, changed
evidence or permission denial still blocks the update. No process is exempted
by name or terminated. Mapped-library listings are not used as proof of the
running executable's identity.

The older **`prepare-update`** operation remains an optional explicit
registration-withdrawal diagnostic. It is not a required step. Update and rollback
perform withdrawal themselves. Preparation does not delete or replace app
files, change plugin settings or signal any process. If preparation is
interrupted or you decide not to update, **`recover`** restores the current
registration. Until update/rollback/recovery completes, `status` can report the
expected missing registration. An identical no-op correctly requires that
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
explicit `rollback` command keeps its app-only compatibility behavior for
older backups, including versions without the new bridge. It differs from
automatic combined failure recovery. It may require explicit integration
maintenance afterward.
The stock host's identity-disappearance/reappearance behavior motivates the
automatic registration transition. Mocked registry tests do not establish
real loaded-generation or focus-preservation acceptance.

Updates may replace a changed development build with the same build number.
They never silently downgrade. `install` also upgrades an existing receipt-owned
app in place. Manual uninstall is not required. An identical artifact verifies
the app, exact registration, owned integration resources and public provider
state. A fully current repeat skips app/resource replacement and plugin mutation.
If only integration needs repair, the same command performs a journaled
integration refresh without exchanging the app. It does not require idleness, since no
executable is replaced. Missing registration or altered app contents still
refuse. They never pass as a verified no-op. Explicit development-source
retirement still applies when requested.
Rollback revalidates the previous app's **own** matching app/extension
version, strict ad-hoc signatures, production identities and compatible
entitlements. A previous preview with fewer approved read-only grants is
allowed. Missing sandbox, broader or unknown grants, unsigned components and
test namespaces are refused. Normal publication/install validation still
requires the current build number. This feature does not bump it.

### Transaction and recovery contract

- One kernel-held, nonblocking install lock and a private `0700` ownership
  directory live at `~/Applications/.cmux-maestro-preview-install/`. Receipts
  are `0600`, atomically written and synchronized. The persistent lock file is
  **not a stale lock** just because the caller has exited. A one-command
  Python supervisor retains the lock while a mutating `ditto`, `lsregister`
  or `pluginkit` invocation, or a non-UI integration bridge, runs. This holds
  after caller timeout or `SIGKILL`.
  The trusted integration bridge also inherits the descriptor, solely to record
  its nested provider groups. Other tools and actual provider executables do
  not receive it. Each provider starts behind an EOF-safe gate. It cannot
  execute until its separately owned group is recorded and synchronized.
  The supervisor waits for both the bridge group and every recorded provider
  group, not merely direct-child exit or pipe EOF. Killing the bridge therefore
  cannot permit restoration while its provider can still write.
  No daemon is installed. No persistent background observer exists.
- A bounded marker in that same lock file records command progress. A gated
  launcher cannot execute the tool until its private process group is durably
  recorded. If the supervisor itself dies, a new lock owner still refuses
  recovery while any recorded bridge/provider group exists, even if their
  original supervisors exited. Once all groups are gone, recovery may resume. A launcher whose
  group was never recorded cannot pass its gate. Corrupt/unverifiable markers
  fail closed. Never delete or truncate the lock to bypass this barrier.
- The 120-second command timeout ends the caller's wait, **not** a surviving
  mutator's lifetime. Wait for the protected workers to finish, then retry
  `recover`. A hung worker keeps blocking new operations, to avoid
  a delayed deregistration affecting a later installation. This supervision
  covers the fixed foreground macOS tools only. It is not a general-purpose launcher for
  programs that daemonize into independent sessions. It does not control
  unrelated operating-system services or other apps' registry requests.
- Source and staged copy must match an integrity receipt and pass effective
  signed-profile verification. Files and directory metadata are synchronized
  before commit. Darwin `renamex_np(RENAME_SWAP)` exchanges an update/rollback
  with the live destination in one operation: no deliberate
  missing-app interval exists. First install uses exclusive rename. Unsupported
  filesystems fail closed. No non-atomic replacement fallback exists.
- A completed update retains **one verified previous app** in an owned slot.
  It may also retain **one inactive retired app**, separate from that required
  rollback generation. Preparation permits at most **four** managed bundles:
  current, previous, retired and one staging candidate. Completion returns to
  at most **three**: current, previous and retired. These are archival bounds,
  not additional active installations or process permissions.
- A healthy retired slot does not block a verified identical install or trigger
  housekeeping. Stage and verify a changed candidate before reclaiming
  the old retired slot. Reclamation is journaled. It occurs only while the
  owned native registration is withdrawn and relevant owned processes are
  idle. Partial staging remains unverified node-owned cleanup, never a trusted
  retired artifact.
- Successful update retains the old previous generation as retired. Failed
  update retains the verified failed candidate after restoring the original
  current/previous generations. Its bridge remains available for compensation,
  checkpoint release and non-activating relaunch, even when the older app has
  no bridge. All owned registration retirement precedes final publication.
  No same-ID unregister, deletion or forced refresh follows it. A failed
  release or relaunch remains pending. It never becomes healthy retirement.
- Recovery verifies an already-correct exact registration without forcing
  `lsregister -f` again. It can register an absent exact app/extension pair.
  During verified transaction-owned publication, it completes an app-present/extension-absent
  pair with only `pluginkit -a` for the exact extension. It does not register the app
  again. It rechecks the pair before completion and reads it back
  afterward. Extension-present/app-absent remains unsafe to force, because the
  extension may already be hosted. Partial pairs outside transaction authority
  also refuse. Errors include the exact observed pair, never hiding it.
  A durable verified commit finishes release/retention. Pre-commit failures
  still restore the previous working state. Explicit uninstall includes only
  receipt-owned retired storage, under its existing consent and idle guards.
- Before app replacement, a private `0600` checkpoint at
  `~/Library/Application Support/CMUXMaestroPreview/Orchestration/install-transaction.json`
  captures the fixed owned resource set, registration provenance, prior absence,
  modes and public provider identities. It sits outside every sidebar-readable
  prefix. No sandbox grant is added. Recovery validates its schema, exact paths, file bounds and
  transaction identity first. Separate setup refuses
  while the coordinated transaction is pending.
- Every observer-receipt write records its exact permitted bytes, permissions
  and independently established source provenance in the checkpoint before
  publication. Recovery without a final `after` snapshot accepts only the
  known prior image or those bounded exact intents, never desired-generation
  equality alone. Edited plugin/source identities preserve their bytes and
  pending journal. Durable-after and resource-only enrichment checks remain
  strict. Ambiguous older interrupted checkpoints are not guessed into authority.
- The app receipt journals the companion transaction ID and its progress.
  Pending failure recovery first verifies/restores integration. It uses
  official `plugins.install` at the unchanged owned source path, or `plugins.uninstall`
  scoped by the returned `directSourceId` for prior absence. Then it restores the
  old app and registration. The install RPC receipt binds that exact source.
  Later discovery must match it. Current settings
  must still match the checkpoint's values or known CLI normalization. Unrelated
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
  file's choice. Direct disable is not effective on 1.0.88. Never claim it
  as a supported restoration there.
- Install and disable are separate provider operations, **not an atomic
  provider primitive**: the plugin can temporarily report enabled, and a crash
  can retain that state until recovery runs. Dedicated staging remains inactive
  throughout this interval. No success or restored-state claim is emitted
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
- A surviving or unconfirmed command supervisor blocks restoration. The
  installer never races a still-running mutator. A failed restoration reports
  both errors and retains recoverable state. The durable commit decision is
  written only after both components are verified. An interruption after that
  decision finishes checkpoint/backup bookkeeping. It does not undo an already
  verified commit. Cleanup errors remain explicit. No GUI reload or existing
  chat behavior is inferred from restoring registrations.
- A committed checkpoint awaiting cleanup blocks separate preparation,
  historical rollback and uninstall until `recover` finishes bookkeeping.
  Resuming a pending rollback re-verifies previously restored integration
  before changing the app. A concurrent user change cannot hide behind a
  saved `restored` phase. Malformed false-shaped checkpoint identities are
  rejected, not interpreted as legacy app-only state.

```sh
python3 scripts/local-preview.py status
python3 scripts/local-preview.py recover

# Recover interrupted replacement by restoring its previous app (or absence):
python3 scripts/local-preview.py recover --restore-previous
```

For coordinated installs with retained source authority, recovery restores both prior components whenever the
app receipt still records a pending transaction, including after the app was
already exchanged. Older app-only journals keep their finish-forward
recovery behavior. Recovery can
resume its own interrupted cleanup or rollback. If no transaction is pending,
it verifies owned apps and refreshes the stable registration. A new explicit
`install`/`update` first restores any interrupted install's prior app state
before staging its requested artifact. It does not silently finish that
interrupted combined install.
`recover --restore-previous` restores absence after an interrupted first install.
Recovery refuses ambiguous identities, replaced partial-cleanup directories, foreign backups,
and corrupt receipts. It never guesses or deletes them. Preserve the
receipt, apps and original checkout/source while a transaction is pending.
Do not manually shuffle slots or remove metadata to force an update.

When exact LaunchServices verification fails, the error includes a single JSON
diagnostic: the operation (`verify`, `register`, `unregister`, `ensure-existing`
or `ensure-completed`), installer stage, transaction kind/phase, bundle ID, exact
target, and expected/observed presence. A failed query reports `observed: unknown`
and its exception class, never verified absence. The diagnostic uses the same
query result as the guard. It does not requery, dump registry contents or list
other application paths. Target strings are JSON-escaped. Direct adapter checks
without installer context report null stage/transaction/phase.

These diagnostics identify the failing check, not its cause or an installation
repair (#185). They cover the LaunchServices check in `verify_registration`.
Earlier mutation/query failures and extension verification keep their existing
errors. Automatic restoration preserves the original diagnostic. If restoration
also fails, both failures remain in the error and the journal remains available.
Preserve the complete failure output. Successful later `status` verification
does not establish why the original installation failed. A new live installation
or recovery still requires its own authorization. Diagnostics add no retry.

Only an existing, normal, non-root user's real home is used. `HOME` overrides
are not install roots. Symlink components, foreign ownership, group/world
writable paths, escaping bundle symlinks and hard-linked files are refused.
Internal relative framework symlinks are allowed. Specify an alternate destination
**before** the command. It must be a direct `.app` child of the
same `~/Applications`, for example:

```sh
python3 scripts/local-preview.py \
  --destination "$HOME/Applications/My Maestro Preview.app" install \
  --source "$PWD/.build/adhoc/Build/Products/Debug/CMUX Maestro Preview.app"
```

The singleton receipt binds that destination. Use the same option thereafter.
No automatic adoption, relocation or force-overwrite mode exists, even for
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
The option is an operator assertion, not a scan of private CLI state. `recover` resumes an
interrupted removal. Ownership metadata and the lock
remain for safe future installs. Observation records, history/attention
preferences, containers, native plugin settings and source builds are retained.
No purge option exists. Neither removal nor update touches `maestro-cmux`,
legacy settings, hooks, sidebars, other apps or CMUX configuration.

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
