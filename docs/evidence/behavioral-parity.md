# Evidence archive: behavioral parity

Archived 2026-11-06. Verbatim text moved out of the living documentation so those pages describe current behavior only. Nothing here is a current contract; follow the links back for that.

## Coordinated alpha installation (#114)

From [`docs/behavioral-parity/alpha-installation.md`](../behavioral-parity/alpha-installation.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

Focused Python tests cover ordinary `install` upgrades, exact registered
identical no-ops (no app replacement, receipt change or lost backup), automatic
restoration after copy, exchange or registration failure, first-install
absence, interrupted restoration, exact development-source registration
restoration, and refusal to race an unfinished command guardian. Existing
ownership, integrity, process-identity and partial-cleanup controls remain.

Changed-app publication withdraws only the owned registration, waits at most
120 seconds for positively identified preview processes to exit, then registers
the replacement. Unknown process evidence fails immediately. Tests cover
ordered withdrawal and re-registration, untouched unrelated registrations,
bounded waiting and restoration when release fails, with no UI selection, host
restart or script-sidebar reload.

The containing app is not an indefinitely busy extension. A changed-app update
journals the running app's exact owner/start generation, executable and code
identity, then requests only `NSRunningApplication.terminate()`. Refusal or
failure to exit aborts without force termination. An exact-URL `NSWorkspace`
launch restores the prior running/hidden choice without activating, hiding
other apps, substituting another installation, duplicating the instance or
prompting for optional UI. Quarantine refuses relaunch instead of bypassing
system policy.

Injected AppKit handles cover ownership mismatches, PID-generation changes,
other app copies, helper/extension exclusion, refusal and idempotent
restoration. A non-UI process fixture compares the public Security-framework
code identity with the kernel-cached code hash. Installer tests cover
quit/launch interruptions, failed restoration and rollback after a replacement
app started. None invokes real GUI quit/launch; the hosted stock-host proof
must still establish real release/recreation and focus behavior.

The receipt separates a healthy `retired` slot from unresolved `garbage`
deletion. Older schema-1 receipts without `retired` remain readable. Slot aliases
and more than four managed bundles during preparation (three after completion)
are rejected. Current and previous are the working and rollback generations.
Retired is disposable maintenance, not an extra active install. A verified
no-op neither deletes retirement nor republishes registration.

## Alpha installation: retired slots and native publication

From [`docs/behavioral-parity/install-retired-slots.md`](../behavioral-parity/install-retired-slots.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

A changed install stages and verifies the new bridge before reclaiming the old
retired slot. A `reclaiming` transaction journals exact digest/node-based
cleanup while owned registrations are withdrawn and owned processes idle.
Failure restores the working app/integration and required previous backup; the
verified new candidate can stay retired to finish old-app relaunch and
checkpoint release. Partially copied candidates keep the original unverified
staging cleanup rules. On success, old previous becomes retired only after
bridge work finishes. The durable `committed` boundary separates
release/retention cleanup from reversible failures.

Native publication uses exact app/extension state. A correct registration is
verified without a second forced registration, and an absent pair can be published.
Verified transaction-owned app-present/extension-absent publication reuses the
per-component registration primitive to add only the missing extension, with
source/identity preflight and fresh pair/readback checks. A now-complete pair
is left alone, and a changed unsupported pair refuses. Extension-present/app-absent
never authorizes a forced app registration while a native view may be hosted.
Outside the transaction, partial ambiguity refuses. Staging cleanup keeps its
transaction until the restored registration verifies. None of this is an
atomic macOS service acknowledgment.

Restoration confirms the retained candidate's registration is absent before
publishing the old app. No retirement mutation follows final publication. Tests
cover repeated failure bounds, old apps without bridge capability, original
running/hidden state, interrupted optional deletion, release and receipt
writes, alias/tamper/missing slots, first-install absence and explicit
uninstall. They do not establish asynchronous service drain or that stock CMUX
saw an identity disappear.

Ordinary install runs an exact production-ID/public-point sibling preflight
before staging or provider effects and revalidates before native withdrawal.
Only receipt-owned paths and an explicitly authorized, verified
current-checkout development source may be retired. External eligible paths
and unknown/debugger elections fail with a concrete error, without adoption.
Ignored or superseded records, other points/identifiers and unrelated provider
hooks remain unchanged. The historical sibling-recovery proposal still needs
separate production consent.

## Alpha installation: integration checkpoint

From [`docs/behavioral-parity/install-integration-checkpoint.md`](../behavioral-parity/install-integration-checkpoint.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

`build-register.sh` hands its verified artifact to the same `install`
entrypoint instead of registering the development extension separately. The
installer calls a production-only, non-UI bridge with a transaction UUID and the
stable application path. The bridge prepares an owned integration checkpoint
before the app exchange, applies Copilot, verifies provider discovery and exact
app registration, and only then commits current/previous app retention. An
identical app still checks integration; a fully current repeat skips resource
replacement and official plugin mutation.

The durable checkpoint is private `0600` data in
`Orchestration/install-transaction.json`, outside the sidebar's granted
`Copilot/` and `Orchestration/observer/` prefixes, so no permission widens.
Recovery validates the schema, fixed file paths, original modes/absence,
expected resource bytes and transaction UUID. It keeps observers inactive while
compensating through official install/uninstall at the stable owned source,
restores prior settings only across verified CLI normalization, and verifies
the original public plugin/hook inventory before restoring the app. It also
verifies the fixed owned installed payload. If source and installed copies
differed before an interrupted setup, compensation temporarily puts the saved
installed payload at that source, verifies official replacement, then
conditionally restores the original source bytes. Provider-private state and
unrelated plugin directories are never rewritten. Unexpected concurrent content
or disable changes refuse compensation instead of being overwritten. Failed
compensation keeps the checkpoint.

Receipt publication has a write-ahead exact-image boundary. Before a
staged/current observer receipt can change, the checkpoint validates its current
image and durably records the complete intended bytes, mode and source binding.
Missing-`after` recovery cannot substitute generation equality for that
authorization. Tests change plugin identity and source path/ID without changing
the generation, and require the edited bytes/resources and journal to survive
with no compensating provider mutation. A real compiled-bridge exit after
current-receipt publication but before the final snapshot still recovers.

The finite command guardian also covers nested provider groups. Standalone
provider processes keep independent groups and original timeout/cancellation
cleanup. Coordinated providers use the same grouping but wait behind a launcher
gate until the trusted bridge syncs their group IDs into the inherited
install-guard record; providers never inherit that descriptor or its
environment. After bridge exit the guardian re-reads and drains the complete
record. If the guardian also terminates, fresh recovery refuses while any recorded
group survives. Real compiled bridge/provider gates prove this for forward and
compensation paths, with and without guardian termination, and leave unrelated
processes alone. The earlier late-write-after-restoration results stay recorded
as red evidence, not relabeled as supported behavior.

## Alpha installation: plugin identity and disabled state

From [`docs/behavioral-parity/install-plugin-state.md`](../behavioral-parity/install-plugin-state.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

Plugin mutations use public sessionless RPCs and check the supported status
before the mutation request. An install receipt supplies the exact owned
`directSourceId`, which later discovery must match; removal and compensation
target that identity, not just the manifest name. A receipt is kept for
recovery even when a failing provider-process exit follows it. Independent
bootstrap records the same source's identity before real-home mutation, so a
lost production response can still be compensated without adopting a
name-only list row. Recovery bootstraps again and checks current selection
before effects. Source files remain until exact-ID removal succeeds. Failed
bootstrap and foreign identity drift grant no compensation authority.

The pinned [1.0.89 changelog](https://github.com/github/copilot-cli/blob/8dfa6009c4a04b3a22a5ca4a7c36a056edd718dd/changelog.md)
supersedes SDK comments claiming direct installs are always enabled.
Disposable official-provider probes confirm direct disable/enable, zero
discovered plugin hooks while disabled, and re-enabling on both install and
update. The installer keeps a verified disabled native plugin without provider
mutation for no-ops and compatible external-resource-only updates. For a
required payload replacement it records original state and mutation intent
before the official operation, keeps dedicated staging inactive, and requires
official `plugins.disable` plus exact-source readback before
publication/commit. The disable RPC is attempted on stable 1.x releases using
protocol 3 and checks the selected identity before its name-based mutation.
Unsupported operations or failed disabled-state readback block publication.
Install/update success alone does not prove preservation. Disabled legacy
observer migration also disables the dedicated file, and an existing dedicated
file keeps its independent choice.

## Alpha installation: plugin-state recovery and tests

From [`docs/behavioral-parity/install-plugin-recovery.md`](../behavioral-parity/install-plugin-recovery.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

If a disable response is lost or fails, or the process exits between the
operations in [plugin identity and disabled state](../behavioral-parity/install-plugin-state.md),
recovery uses the durable intent, independently re-established source authority
and official disabled-state restoration. Exact prior cache/source and settings
are verified before the app rollback completes. An intact prior payload is not
reinstalled. No private enablement key is guessed or edited. User re-enablement
after verified apply, and foreign identity drift, refuse instead of being
cleared. These are separate provider operations: the intermediate enabled state
is real, and these docs do not call it atomic suppression. Local tests cover
that boundary without executing hooks or restarting sessions; actual stock-host
and installed-session gates remain separate.

The Python suite runs the compiled Swift bridge in separate processes over real
disposable files: success, no-op, upgrade, late failure, first absence and a
real installer-process exit after apply, after which a fresh installer recovers
both generations from disk. These tests use a provider double and synthetic
registries and do not prove real stock-host reload. Another real process-exit
case stops between integration restoration and the app exchange: resumed
recovery refuses a later foreign edit, then completes once the fixture restores
the verified input. Pending committed checkpoint cleanup blocks legacy
maintenance mutations, and false-shaped receipt fields cannot bypass
coordination.

The Swift checkpoint suite separately covers stable-source compensation,
disabled legacy restoration, repeated recovery, arbitrary-path refusal and
concurrent-write controls. The focused test script's compile-only mode builds
that non-UI fixture, and its normal CI command still runs every existing test.
Current eleven-command hosted CI, source-binding resolution, native lifecycle
proof and later installed fresh-session acceptance remain separate gates.

[CopilotObserverRegistrationTests](../../CMUXMaestroPreviewTests/CopilotObserverRegistrationTests.swift)
cover isolated registration, migration, exact event/wrapper content, preserved
disables, unavailable-key refusal, unsafe/foreign/modified state, interrupted
phases, retry, concurrent replacement, metadata and owned removal. Existing
setup cleanup tests keep their original deadlines, negative controls and
unrelated-process assertions. Complete CI, independent review and any later
production/live acceptance remain separate candidate gates.

Metadata cancellation fixtures publish the completed PID marker by same-folder
rename, not by file existence before `printf` finishes. A gate-controlled
negative control shows the old empty-marker window; the atomic case cannot
expose it. Error and cancellation paths join the owned task before deleting its
fixtures.

## Background-shell representation

From [`docs/behavioral-parity/background-shell.md`](../behavioral-parity/background-shell.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

Structured `shell_completed` and `shell_detached_completed` notifications stay
decoded but no longer create synthetic "Background shell" work rows, outcome
attention or dismissal candidates, whatever the exit code. This is an explicit
UI removal policy (#155), not evidence of deliberate cancellation or successful
shell/worker execution. Real worker/task errors and independently observed
`shell:<toolCallId>` tool invocations are unchanged. Raw provider history and
stored dismissal settings are neither deleted nor migrated.

`./scripts/test-copilot-shell-reducer.sh` compiles the actual Foundation
decoder and reducer without launching the app or a UI test host, and CI runs it
as its own step. It checks both notification kinds across zero, ordinary
nonzero, signal-compatible and missing exit codes. It also checks
replay/reconstruction, independent error preservation, real-work retirement,
request reuse, one-word replay saturation and 128 bounded lifecycles. The former notification-based
retirement fixtures now admit and complete real shell tool work, keeping their
original assertions, bounds and stress, with explicit retirement
preconditions. These scoped checks do not replace the full hosted test matrix
or current-head CI.

## Setup fixture readiness

From [`docs/behavioral-parity/setup-fixture-readiness.md`](../behavioral-parity/setup-fixture-readiness.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

Process-cleanup tests wait for the injected clock's first post-`posix_spawn`
sample before arming the unchanged three-second child-readiness watchdog. The
test clock publishes a bounded one-shot signal; a driver that returns without
spawning closes it, and a cancelled waiter unwinds. This separates
task/dispatch scheduling from the fixture's readiness requirement without
changing the production runner, its timeout or executor policy.

`queuedStartupDoesNotConsumeChildReadinessBudget` and
`lateQueuedStartupRetainsFullChildReadinessBudget` hold the test driver for
four and 2.7 seconds before invoking the runner. Under the old watchdog
ordering they reproduced both the no-launch and the started-but-unfinished
delay failures. The corrected ordering keeps every timeout/cancellation, exact
process-group/reaping, unrelated-process and late-write assertion. The real
0.6-second launcher delay and frozen 0.4-second product deadline are unchanged.
These controlled probes report a non-actor-isolated driver; they do not
establish MainActor inheritance or measure hosted dispatch latency.

Early unavailable/cancelled runner outcomes, waiter cancellation, and a started
runner without a ready writer are separate controls. The independent
non-yielding `concurrentSupervisionDoesNotOccupyCooperativeExecutor` observer
keeps its three-second budget and detached drivers. The change adds no suite
serialization, startup retry or larger readiness timeout. Startup observation
has no added wall-time limit before the first sample; the dedicated concurrency
test remains the bounded dispatch-progress regression.

## Hosted integrated runner

From [`docs/behavioral-parity/hosted-integrated-runner.md`](../behavioral-parity/hosted-integrated-runner.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

The hosted integrated runner builds once, runs the **one unchanged test**
`concurrentSupervisionDoesNotOccupyCooperativeExecutor` alone in the integrated
test host, then runs every remaining test from the same build in a second
invocation. It does not serialize the remaining suite or alter either detached
driver, any assertion or the three-second bound. `xcresulttool` must report
exactly one executed, correctly identified test before that selector may be
excluded from the loaded invocation. Both scopes must pass with explicit
nonzero, reconciled counts; unrelated skipped tests and a repeated concurrency
test are errors. A selector/count extraction failure runs an unfiltered
coverage fallback but **still fails** the command. The runner never retries
until a pass.

The preexisting opt-in
`CopilotReaderTests/coldStartBenchmarkWith230MiBOfIgnoredSyntheticPayloads()`
is the only optional skipped identity. It stays disabled unless the inherited
`CMUX_MAESTRO_READER_BENCHMARK` is exactly `"1"`; when enabled, its exact
identity must have one nonparameterized passed execution, and absence or a skip
fails. The harness records that flag and exact skip attribution with the
verified isolated-selector exclusion, without enabling the benchmark or
rewriting reported counts/details. A skipped parameter, another identity or an
unverified selector exclusion is not permitted. Full fallback remains red even
when the benchmark skip is correctly attributed.

Result accounting separates logical test cases from recorded executions. The
top-level summary must match the tree's complete logical status vector, and
device/configuration counters must match normalized execution statuses.
Parameterized argument groups are not blindly equated with logical parents, and
parameterized evidence without its execution counters is rejected.
Unrecognized execution shapes, contradictory parent/run results, hidden runs
and repetition nodes cannot certify coverage. The known nonparameterized
isolated method must have exactly one non-repeated execution.

Each hosted invocation keeps separate xcresults, raw summary/test JSON and
`coverage.json` under `.build/tests/scoped-results/`. Raw test trees, summaries
and reconciled counts also go to the job log, so the parent verifies the actual
hosted selector and parameter hierarchy instead of accepting a guessed selector
or local standalone count. The inherited-MainActor negative remains sensitive
because the test body and non-yielding observer are unchanged. Earlier hosted
concurrency reds and the separate native viewport-settlement failure remain on
record. Only a necessary current-head hosted run can establish their state.

CI always uploads every scoped-results JSON file as the separate
`integrated-test-scope-evidence` artifact, kept for 14 days, including after
test failure. Missing JSON fails the upload instead of falling back to success.
Full xcresult bundles are not in this diagnostic artifact. The required
`sidebar-layout-offscreen` PNG artifact and all eleven validation commands are
unchanged and required.

## Dedicated observer registration (#114)

From [`docs/behavioral-parity/observer-registration.md`](../behavioral-parity/observer-registration.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

Explicit setup manages a dedicated version-1 user file for exactly
`sessionStart`, `userPromptSubmitted` and `postToolUse`. The bundled helper,
identity checks, session reader and renderer are unchanged. The lifecycle/icon
plugin remains, without observer declarations. Generation/provenance checks,
bounded descriptor-relative reads, conditional writes, a same-setup lock and
phase-specific results tell missing, stale, disabled, conflicting, incomplete
and current-on-disk registration apart.

Persisted incomplete/conflicting plugin state takes precedence over disable classification.
A completed receipt binds opaque provider-returned event keys to the exact
registration generation/version, so fresh file-only status can tell all from
subset disables. Unknown keys or missing/stale applicability evidence report
unresolved, not ordinary current-on-disk. Check Registration starts no metadata
process. The command-line installer treats verified enabled,
all/subset-disabled and unresolved-applicability completions as success, with
explicit messages. Real errors and usage keep nonzero exits.

Setup attempts **stable Copilot CLI 1.x releases using SDK protocol 3**, with
public metadata, exact-source and operation-readback checks. Other major
versions, prereleases and protocols refuse before registration changes. The
historical live probes in [provider probe evidence](../behavioral-parity/observer-provider-probes.md)
cover 1.0.88 and 1.0.89, not every release the range admits. Setup uses only
`status.get`, `hooks.discover` and `plugins.list` over a new, bounded public
stdio connection. It sends no agent/session creation or model request, never
attaches to an existing session, and shuts the metadata process down after its
three replies. Framing, malformed replies, output limits, timeout, cancellation
and process-group cleanup are checked independently. No private native module
or hash implementation is a product dependency.

Host-only discovery labels this file `hooks/cmux-maestro-observer.json`;
project-scoped discovery uses its absolute path. Only those exact user-origin
labels are recognized, alongside independent file/provenance checks. Arbitrary
relative paths and other origins are not normalized into ownership.
Registration file work and the setup UI's read-only status checks use a
concurrent file-worker queue, not MainActor or the cooperative executor. Each
invocation awaits its own transaction steps; cancellation joins an
already-started writer before returning. This neither serializes the test suite
nor widens the original process-cleanup/readiness deadlines.

## Observer registration: provider probe evidence

From [`docs/behavioral-parity/observer-provider-probes.md`](../behavioral-parity/observer-provider-probes.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

The 1.0.89 maintenance probe covers public metadata, inactive file staging,
official plugin settings normalization, real-core migration/install/update/
removal, and related/unrelated-key refusal in disposable homes. It makes zero
model calls and does not extend the earlier 1.0.88 event-execution,
running-session reload or global-disable observations to 1.0.89. Its initial
conservative unrelated-key refusal is superseded only for the positively proven
unaffected case: complete exact-owned prior keys, all owned events enabled, and
every global disabled key resolved to an unrelated action. Affected subsets,
missing keys and ambiguous metadata still refuse. No settings migrator, enabled
duplicate preview or private key hash is introduced.

The earlier 1.0.88 probes established these separate facts:

| Evidence level | Observed result and limit |
|---|---|
| Source/on-disk format | User version-1 files are accepted independently of plugins. Sources combine, and the provider does not deduplicate them. |
| Public discovery | File-level `disableAllHooks` returns disabled rows but omits their destination disable keys. The actual legacy sorted-key producer and four justified user representations did not preserve legacy keys: normalization changed serialized config order, not inherently source identity. |
| Disable-key mapping | Additive old/new **global** keys preserve all-three and single-event intent in discovery. Repository `disabledHooks` was ineffective even against the unchanged legacy source. These are not event-execution claims. |
| Actual activation | `sessionStart` and `userPromptSubmitted` markers preceded the only quota-rejected model request. Permission-free public `tools.execute` produced `postToolUse` markers. No successful model turn was available. |
| Concrete session cache | Existing disposable-session `postToolUse` retained A after disk changed to B. A fresh session used B. Explicit supported hook reload switched the existing session to B. Other events were not separately re-proved after reload. |
| Global disable limitation | `disableAllHooks:true` did **not** suppress `postToolUse` on the tested `tools.execute` path, including in a fresh runtime. This is not generalized to a successful model loop. |

The implemented fallback is deliberately smaller than a speculative settings
migrator: when a change needs unavailable destination-key mapping, refuse
**before changing the legacy registration**. Never enable a duplicate just to
discover a key, reverse-engineer hashes, drop old keys or approximate a
single-event disable with a new blanket policy. Maestro reads global settings
without writing them. The official CLI can replace `settings.json`; after a
successful command only identical values or an added empty `enabledPlugins`
map are acknowledged, with fresh safe-file checks, and any changed disable or
unrelated value refuses. An explicit global/file disable keeps an owned file
disabled. Setup does not claim to repair provider-wide enforcement.

## Observer registration: migration and restoration

From [`docs/behavioral-parity/observer-migration.md`](../behavioral-parity/observer-migration.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

Migration stages only the exact owned **disabled** file, confirms disabled
discovery, prepares and officially installs the hookless plugin, verifies its
cached declarations and public metadata, then publishes the intended file.
Foreign or modified owned registrations, wrong selected owned identities,
unsafe owned paths and changing inputs refuse instead of being overwritten.
Public install into a disposable provider home independently bootstraps
exact-source identity, using the same absolute source path, not a copied path
or private hash. The supported-version result must match current real-home
selection and any old receipt before effects. A name-derived receipt is not
authority, and forged or foreign source provenance fails the independent check.
Fresh-install authority is recorded before real-home provider mutation.

The false foreign-cache audit is gone. Public foreign identity/hook continuity
is checked without reading their source/cache directories or claiming
selected-source coverage. Unrelated same-event direct, marketplace, live,
built-in and opaque records are preserved; an unsafe ancestor of the actual
owned cache still refuses. The historical alias counterexamples stay as
evidence against the old audit, and owned-name/source alias cases are mandatory
pre-effect rejection tests. An unowned plugin may still invoke current or old
helpers and cause extra executions or writes; this is neither prevented nor
certified harmless. Status covers owned registration, not provider-wide
uniqueness. Directly inspected user-file conflicts, disable-key refusals and
no-follow guards remain.

A failure confined to provenance/disabled staging restores and verifies the
previous owned file/provenance bytes, absence and permissions before returning,
including on cancellation. Concurrent replacement refuses restoration instead
of overwriting foreign bytes. All resource inputs and the unchanged socket-path
bound are checked before resource writes begin. The resource fixture uses an
exclusive short disposable directory instead of depending on checkout path
length, and exercises the overlong-path refusal before effects.

Owned resource preparation preflights the complete fixed file set and uses the
conditional file-state writer. On failure it verifies and restores earlier
resource writes, including executable modes, absent files, large bounded
font/catalog resources and the obsolete owned guide. A verified resource
restoration also permits restoring disabled observer staging. Unchanged
resource bytes/modes are no-ops, not inode replacements. Real permission-denied
late writes exercise reversal, with changed file stamps proving an earlier
write happened. Unsafe later targets refuse before earlier writes.
Preflight/no-write, verified restoration and unverified restoration are
separate outcomes, and unrelated files and live routes remain untouched.
Standalone maintenance keeps this in-process compensation; the normal alpha
installer adds the durable coordinated boundary in
[coordinated alpha installation](../behavioral-parity/alpha-installation.md).

A later failed step reports the last completed phase; the next phase may have
partly refreshed setup resources. Retry revalidates recorded generations and
known partial preparation and keeps a retained disabled stage. It never rolls
back blindly or changes existing sessions. Removing integration preserves global
keys, unrelated hooks and live messaging route/session state.

## Direct interactive launch and legacy startup (#61)

From [`docs/behavioral-parity/direct-interactive-launch.md`](../behavioral-parity/direct-interactive-launch.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

The controller Harness reproduces a runtime delayed past caller timeout and a
child whose exact attachment is delayed. The first used to revoke the lease
with `Worker launch lease is no longer active`; the second exited on its own
attachment timer. These controlled source mechanisms neither reproduce nor explain the
historical native host trigger. The earlier
provider-initialization explanation is retracted: supervisor identity is
recorded **before** the provider launches.

New interactive roots and children directly exec Copilot through
`initial_command`, with no supervisor/startup polling window. Synthetic
regressions exercise actual argument quoting and verbatim task wrapping,
terminal I/O, the validated executable/PATH/cwd, acceptance with missing
observations, native observation on either side of attachment, cancellation
and ambiguous creation, exact generation/process identity, account/policy
boundaries, and both admission paths at the configured `MAX_LIVE_WORKERS` cap,
including managed roots and retained terminals. Native adapter tests exercise
precreated bindings, exact session join and one independent observation,
ordinary peer send/reply and no retries. Hooks remain observers; these fixtures
do not claim hook delivery or prompt consumption.

Presentation-model regressions cover fresh exact working/idle/blocked
observations for interactive coordinators and children after the controller
node and projection expire, including accepted/pending `launching` nodes. Row
state and workspace counts use the same independent observation selection.
Missing work does not become Working from `turn-running`; stale, duplicate,
foreign, denied or ambiguous observations stay unknown. Legacy bounded
reports, stale Git provenance, and the difference between surface suppression
and exact session-content ownership remain covered. No heartbeat, timestamp
refresh or visual styling change follows.

Native-loader subprocess regressions run the actual loader/adapter with a fake
joined session. They reproduce a SIGTERM-left socket blocking a same-binding
replacement with `EADDRINUSE`, then verify owned-listener cleanup, termination
during join/observation/chmod, and normal CLI-style reload. Live occupied and
forced-termination stale sockets remain untouched and refused; diagnostics hide
raw exception text and private values. This is isolated lifecycle evidence,
not a replacement for real CLI/provider proof.

## Launch: legacy fixtures and lock budgets

From [`docs/behavioral-parity/launch-legacy-fixtures.md`](../behavioral-parity/launch-legacy-fixtures.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

Preserved legacy tests still cover attachment-ticket serialization, late-claim
refusal, strict reports and exact resume. The inherited eight-pending fixture
used to give each held runtime a ten-second synthetic barrier deadline while
launching all eight in sequence and checking rejection/archive, so its first
runtime could expire before release on hosted runners. It now uses an
owner-held kernel lock released after the admission assertions instead of an
elapsed-time assumption. The capacity regression requires the configured
maximum reservations and eventual results and refuses any further launch. The
barrier repair enlarged no production or CI timeout.

Legacy report fixtures release their synthetic first-turn output after the
launch receipt, keeping post-start protocol assertions apart from the unchanged
rejection of an already-failed first boundary during startup. Fixture
condition waits read committed control state under its shared lock; an
atomically replaced `state.json` alone does not mean observer publication has
finished or the writer has released ownership. Snapshot reads copy bounded,
stable file bytes under that lock, then decode and validate the immutable copy
after releasing it. A gated validation regression proves a new writer can
commit without changing the captured snapshot; malformed and invalid snapshots
still fail. Read-modify-write operations keep their full exclusive transaction
and bounded acquisition waits. Legacy runtime attachment/token reads share the
read lock until the exclusive startup mutation; private ticket guards and the
attachment-file lease are unchanged. Control-character checks keep their UTF-8
byte bounds and exact accepted/rejected characters without a per-character
Python scan of every node's stored provider path.

Lock-acquisition budgets scale by `max(1, MAX_LIVE_WORKERS / 8)`, keeping the
original eight-session allowance against the fixed 32-session reference for
serialized durable writes; ordinary and runtime acquisitions share that
reference. Per-workspace admission limits (default 32, configurable from 1
through 128) neither shrink nor enlarge these waits. The 50ms retry interval,
immediate zero-wait behavior, lock modes and failure on exhaustion are
unchanged, so launch/result deadlines are not extended and non-contention
failures are not retried. Deterministic clock tests use real contended locks to
prove successful acquisition and bounded refusal at several reference
capacities. The reference-scaled budget is an explicit policy change, not an
inference that shorter critical sections alone fixed CI.

The pending-capacity fixture scales its bounded six-second result wait by the
same factor, so the wait cannot expire before an allowed runtime acquisition
can finish. This synthetic allowance changes no production result deadline,
still requires every exact completed report and provider call, and keeps
simultaneous maximum reservations, over-cap refusal and archive protection.

## Launch: workspace capacity

From [`docs/behavioral-parity/launch-workspace-capacity.md`](../behavioral-parity/launch-workspace-capacity.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

Workspace capacity regressions cover persisted CLI configuration, rejected
worker/cross-workspace changes, root/child admission at limits 2, 32, 64 and
128 with retained resources, non-double-counted leases, unknown ownership, and
concurrent admission after an advisory preflight. The 128-boundary proof uses
synthetic retained resources and is not a 128-provider load measurement.

The #167 regressions store 128 synthetic records in workspace A (including
retired history) while B admits independently, keep A unchanged, reject A's
next node, and race last-slot registrations in both workspaces. Saved schema-1
reload, complete multi-workspace observer output, workspace retained-resource
bounds and distinct host node/byte protection are checked without real fleets.
The Swift reader accepts 256 nodes across two 128-node workspaces but rejects
129 in one workspace and 1,025 host-wide. Source publication does not upgrade
an older installed reader/controller or demonstrate live activation.

Managed adapter regressions use 128 private A route/socket pairs plus two B
participants: B discovers only B, exchanges one send/reply through the real
local receiver, and refuses cross-workspace routing. Separate checks accept
1,024 host bindings with 128 local participants, refuse 129 local or 1,025
host, and cap directory scans at 2,048 entries. Mixed-case equivalent saved
workspace UUIDs share node/retained quotas without rewriting the original
records, matching the Swift reader's UUID grouping. A decoded observer-wire
control mixes 127 lowercase spellings and one uppercase spelling of the same
workspace UUID: 128 is accepted, and a 129th equivalent spelling is refused.
These synthetic contract tests neither run 1,024 real sessions nor measure
provider latency.

## Launch: native-child permissions

From [`docs/behavioral-parity/launch-child-permissions.md`](../behavioral-parity/launch-child-permissions.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

Prospective native-child permission regressions exercise explicit recorded
parent mode/allow/deny inheritance, deny-only additions, explicit list/false
narrowing, coordinator-only broad requests and contradictory-intent refusal.
Finite narrowing under recorded YOLO does not need redundant explicit parent allow strings: empty and redundant lists produce the same default-mode child, one
reservation/lease/launch and retained denies. Default-mode parent escalation
and wildcard grants still refuse, and matching deny strings remove allows.
Store normalization keeps negative provenance when filling a missing
interactive tool policy, and a missing mode remains missing. Neither becomes
verified parent policy. Exclusive reservation rechecks the recorded snapshot
before adding a child or lease. Legacy bounded normalization and explicit
worker YOLO refusals are unchanged. These checks establish recorded/requested
policy only. They do not inspect human-modified live permissions, prove atomic
provider-policy comparison, or guarantee actual manual startup when provider
defaults/environment request allow-all; that runtime acceptance gap stays
explicit.

## Launch: model selection

From [`docs/behavioral-parity/launch-model-selection.md`](../behavioral-parity/launch-model-selection.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

Optional launch-selection tests exercise real native assignment forwarding,
sanitized session-scoped model metadata, account rechecking, malformed/foreign
evidence refusal, supported argv and warned configured fallback. Generic omission does not query models, and an unavailable experimental lookup keeps the
prior launch. Model-specific tier/effort fallback keeps a valid selected model.
With no available configured fallback, launch refuses instead of picking
arbitrarily. Root model precedence is unchanged, and new options without joined
evidence warn without injecting unsupported flags. These synthetic source contracts do not observe child model/context settings,
entitlements or a numeric long-context window. Full catalog/billing data is absent from persisted
selection metadata.

For #152, a disposable extension-free SDK session on installed CLI and SDK
1.0.100 returned 23 public model entries. Its raw CAPI snake_case effort and
pricing-tier fields differ from the typed camelCase `Model` shape of
`models.list`. A minimized projection in `scripts/fixtures/model-list-1.0.100.json`
reproduces the earlier loss of all effort/long-context support. Native adapter
tests and the real Python selection/argument path now keep those capabilities
for model-only and model+tier+effort requests. An absent `gpt-5.4-mini`
request warns and falls back to a configured model present in the catalog; it
does not bypass the configured-fallback requirement.

That isolated catalog did **not reproduce** the original installed generic
proof-route refusal. No affected live session was modified or retried, and
#199's root cause remains unproven. Separate negative controls name account
drift, malformed/foreign evidence, the 32-KiB evidence and 64-KiB request
bounds, controller refusal, invalid success/JSON replies and process-output
failure. The real 23-entry projection fits both bounds. These controls tell
failure stages apart but do not show which stage failed in the reported
session. The new parser module takes part in app resources, coordinated setup,
installed readiness and resource-size checks. No live installation is evidence
from this repair; an authorized post-install native attempt is still
outstanding.

Mixed-catalog controls tell valid provider-native effort defaults from
malformed non-advertised defaults before known-CLI projection. Unrepresentable
valid defaults are omitted without poisoning another supported model; a
selected model without a representable default keeps the provider default with
a warning and no fabricated effort argument.

Optional identity-observation regressions exercise the exact joined session's
current model read, account/binding recheck, bounded field projection and
explicit unavailable reasons. Omitted or false `includeModel` does not query the model and keeps the old identity response. Missing effort/context is not filled
from configuration; provider-native safe effort values stay observations, not
invented CLI overrides. Wrong-session calls and account drift refuse. These
mocked SDK responses are source-contract evidence, not an installed-child
demonstration. Spawning still does not wait for an observation. The
failed-attachment capacity fixture stops only its completed synthetic
supervisors, keeps every terminal, and requires the actual configured
resource-limit error, not a busy-store error. Separate live-supervisor capacity
and recovery cases remain intact.

Fixtures are not installed workers, live provider readiness, visible native
acceptance or evidence that the historical host delay is understood. Full
delivery CI and independent review remain separate gates; live host/provider
experiments need a separately authorized release.

## Deep-outline fixture readiness

From [`docs/behavioral-parity/deep-outline-fixtures.md`](../behavioral-parity/deep-outline-fixtures.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

Focus-layout fixtures own **available content width**, not AppKit's preferred
scroller style. A test-host-only modifier applies `scrollIndicators(.never)` to
the unchanged production sidebar/tree and reserves a constant trailing gutter
derived from the public `NSScrollView.contentSize` API, separately for overlay
and legacy budgets. No gutter size is hard-coded and no content width is
frozen: resizing the owned window still changes the viewport and title. These
are **overlay/legacy-equivalent available-width inputs**, not claims of native
indicator appearance or identical row geometry.

The stronger policy is intentional:
[`.hidden` can still show macOS indicators when a mouse is connected](https://developer.apple.com/documentation/swiftui/scrollindicatorvisibility/hidden).
[`.never` overrides that policy](https://developer.apple.com/documentation/swiftui/scrollindicatorvisibility/never).
Before immutable baseline capture, preparation requires absent native
scrollers, no native width gutter, a visible deep title, document/clip width
agreement and matching geometry samples. It claims neither native quiescence
nor a pinned style:
[AppKit can later update style and retile](https://developer.apple.com/documentation/appkit/nsscroller/preferredscrollerstyle).
Cold-start evidence saw that update on both fixed-budget fixtures without
changing their title/viewport frames, while an unmodified native control's
width changed. A one-time explicit style assignment alone failed that stress.
The matching hosted width delta still does not establish its trigger.

`deepOutlineFixedViewportSurvivesNativeStyleChanges` compares each budget's
available viewport with a separate real-native production render, then
requires exact title/viewport equality through both native style-transition
directions. Focus and no-focus tests run both budgets; focus keeps both
densities and appearances, the 124-point minimum, height/depth caps and 20 ms
effect interval. The real-window-width negative control also runs both budgets,
requires the full 26-point viewport loss and still rejects changed title
frames.

`nativeEightLevelOutlineRetainsMinimumTitleWidthAt280` separately protects the
native depth-eight title at a 280-point host: at least 124 points wide and at
most 70 points high, in both densities, light/dark appearances and both native
scroller styles. It verifies the requested style and visible native geometry
before each static measurement, without the fixed-input inset or a later timed
equality check. This absolute guard is needed because the equivalent-width
fixture's inset changes indentation and gives its legacy title two extra
points, so that fixture alone cannot protect the native minimum. Style
assignment is not treated as a pin against later AppKit updates.

`deepOutlineLateNativeStyleChangeInvalidatesSampledBaseline` exercises
overlay-to-legacy and legacy-to-overlay transitions through the public setter,
in run-owned offscreen fixtures without focus. It requires opposite viewport
width directions, equal title/viewport width deltas and an unchanged title
height. The original exact frame comparison rejects both changes. This control
and all ordinary full production renders stay outside the fixed-input
modifier, and neither layer restores geometry after baseline. Global
preferences, production layout and AppKit test gates are unchanged. Fixed-input
focus coverage and native composition/transition coverage are separate layers;
neither substitutes for the other.

## Managed Git provenance

From [`docs/behavioral-parity/managed-git-provenance.md`](../behavioral-parity/managed-git-provenance.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

Managed Git branch/worktree labels, verification times and change counts
describe the **assigned directory**, not Copilot's current `/cwd` or a tool's
working directory. The controller's `collect_git_evidence` probes
`node.workingDirectory` via `git_display_metadata`, applies evidence only to
the matching run/directory, and publishes bounded labels/counts through
`Orchestration/observer/current.json`. The sidebar's reader validates that
projection; `managedGitDetails` shares the assigned-directory qualifier across
inspector, hover, pinned details and row tooltips. Compact row labels are
unchanged; the count badge identifies the assigned directory in its caption, tooltip
and accessibility description.

The 60-second Git freshness checks still suppress current branch/worktree
fields and counts when stale. Last-verified labels stay explicitly historical.
Unavailable evidence never proves a non-repository, and detached HEAD needs no
branch label. CMUX **Surface directory** and **Parent surface directory** stay
separate host reports with unchanged permission and provenance rules. No dynamic
directory collector, worktree identity/grouping key or new grant is added. This
correction references #119/#59 without completing either.

`SidebarAgentHoverTests.managedGitConsumersQualifyAssignedDirectoryWithoutChangingFreshness`
covers shared fresh, stale, unavailable, absent, stale-count and detached-HEAD
presentation. Pinned-detail and native row-tooltip assertions keep their
identity, freshness and compact-layout checks. These tests need the unchanged
hosted native suite; source inspection or an unsigned build alone does not
establish test execution or installed-host acceptance.

The combined owner/task-depth render gets its frozen observation clock through
the shared `sidebarPresentationNow` environment seam. Outline placement,
retained context, details, hover and action revalidation use that clock;
production still reads `Date()` on demand, with the same eight-second identity
freshness boundary.
`controlledPresentationAgeExpiresRetainedOwnerWithoutChangingObservations`
checks the exact retained-owner label at eight seconds and its expiry at 8.001
seconds in both modes without refreshing observations. Geometry assertions are
unchanged, and failures include native owner labels and observation ages.

Footer model rendering uses the inspector's zero-tolerance native-pixel
comparator against an independent literal `verified-model` reference in its
expected region. All eight production size/theme combinations keep copy and
geometry checks, and both themes must reject wrong `verifled-model`, suffix,
missing, hidden, clipped and elsewhere text. This replaces only the model-line
OCR oracle, not production typography or content: whole-image OCR misread the
visible line in both initial hosted runs. An earlier owner-label failure fits
the fixture's frozen clock crossing wall-clock freshness, but its failure-time
labels/ages were not logged, so that cause remains inferred. Repair execution and
sensitivity evidence still need hosted CI.

## Lazy preference observation (#169)

From [`docs/behavioral-parity/lazy-preference-observation.md`](../behavioral-parity/lazy-preference-observation.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

Layout stays read-only until an explicit action. When the target is absent, its
file presenter watches the nearest existing container. Changes to the
presenter's own item, including directory-content and attribute notifications,
invalidate the target through the existing refresh path. Unrelated subitem
events stay filtered; no polling, eager directory creation or new writer is
added. Each accepted notification schedules one byte-bounded coordinated read,
and equal values publish no new store value.

`SidebarLayoutTests.lazyPresenterOwnItemChangesRefreshWithoutCreatingTarget`
drives the actual presenter through `NSFilePresenter`, with an absent nested
target and unrelated-event controls.
`presenterOwnItemChangesRetainCoordinatedReadAndNoticeSemantics` checks
repeated unchanged reads, file-byte preservation and explicit malformed-file
notices. The original two-process lazy-layout convergence test keeps its
ten-second deadline and observation, layout, history and attention assertions.
These deterministic callback regressions establish the documented invalidation
path, not the exclusive cause of the earlier hosted convergence failure or
installed-runtime acceptance.

## Bounded oversized event projection

From [`docs/behavioral-parity/oversized-event-projection.md`](../behavioral-parity/oversized-event-projection.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

The reader keeps its 1 MiB ordinary-line limit, 4 MiB per-session / 8 MiB
per-read I/O budgets and 2,048-line per-session budget. When a line exceeds the
ordinary limit, the streaming envelope seam validates its full JSON structure
but keeps only the event decoder's metadata keys. Tool
start/completion/partial-result payloads, assistant messages, binary assets and
otherwise opaque events (including model diagnostics) therefore keep their
ordinary decoder semantics without keeping arguments, results or message
content. Other known lifecycle events still fail closed when oversized. Unknown
work-lifecycle events still reach the reducer's explicit degradation and are
not treated as harmless model diagnostics.

The streaming validator rejects malformed tokens, invalid UTF-8/escapes,
unpaired Unicode surrogates, duplicate keys (including escaped equivalents) and
invalid/truncated container structure. Bounds are 64 total container levels,
1,024 encoded bytes per key and 65,536 encoded key bytes across open objects.
Arbitrary binary-asset `metadata` and tool-result `structuredContent` maps have
no separate per-object key-count ceiling. Even an empty JSON string key costs
two encoded bytes with its quotes, so the aggregate budget allows at most
32,768 live key entries across open objects. That is a conservative
cardinality bound, not a 64 KiB heap-allocation limit: Swift String/Set storage
and frame overhead come on top, with cardinality bounded by the same budget and
depth limit, and wide maps can cost more overhead than narrow ones within it.
The decoder's CodingKeys separately fix retained projection-field cardinality,
so admitting wider opaque maps adds no projected fields. Arrays and opaque
strings are scanned, not buffered.

Selected scalar retention is capped at 2,048 encoded bytes per field. A scalar
over that cap remains present but unusable to the decoder; it is never silently
omitted or defaulted. Irrelevant fields of opaque events stay ignored. The
final projected envelope must fit the unchanged ordinary-line limit. These
resource bounds can conservatively reject otherwise valid pathological JSON;
they do not permit clearing an earlier reader error.

Work is linear in consumed bytes with bounded stack/key storage. Crossing the
line limit also scans the already-buffered prefix once (at most 1 MiB with
defaults), without rereading or accumulating the rest of the payload.
Publication still needs a complete newline and a verified file/identity
boundary. Torn appends keep the previous complete observation and report
loading, and malformed completed lines keep explicit degradation. No Working or
Idle state is inferred from process liveness, and no persisted tail is
repaired by discarding errors.

`CopilotAssetEnvelopeTests` covers synthetic below/exact/above default and
reduced line limits, ordered/escaped/chunked payloads, malformed and incomplete
JSON, resource boundaries, tool success/failure and wrong-owner/turn/replay
controls, advisory message attribution, and a multi-batch large-history
reader-to-sidebar Working-to-Idle transition. This is source-level recovery
evidence for #121, not installed-app acceptance or proof of every reported
missing/Unknown row.

The wide-map regressions cover 64, 65 and 256 unique keys in asset metadata and
tool structured results, below and above the ordinary line limit and across
chunk boundaries. Their red/green proof corrects the earlier unsupported 64-key
ceiling instead of waiving a producer-contract failure. Duplicate keys and
malformed values after the 64th entry stay rejected; the aggregate-key control
admits exactly 65,536 encoded bytes across open objects and rejects 65,537.

## Multi-turn child identity and completion attribution

From [`docs/behavioral-parity/multi-turn-child-identity.md`](../behavioral-parity/multi-turn-child-identity.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

Copilot 1.0.88 can persist `subagent.configured(multiTurn: true)`, complete the
original spawn task, then start another interaction on the same child without
another `subagent.started`. The reducer keeps that child's observed name, kind
and ancestry on the fresh interaction and retires the old spawn-result join.
Completion stays a terminal task outcome until fresh activity is observed.
Documented `subagent.selected` profile metadata neither replaces the spawn
identity nor revokes that capability; other unknown subagent lifecycle events
still invalidate it. Reused turn numbers need the existing causal guards.
`CopilotInteractionTests.demonstratedMultiTurnFragmentPreservesIdentityOnlyOnFreshContinuation`
replays a redacted seven-event producer fragment; its omitted causal envelopes
do not prove an untagged final end.

An approved metadata-only Copilot 1.0.88 probe later showed that
`assistant.message` carries both the current `interactionId` and `turnId`, even
across root-owned warning/hook envelopes, while its linked `assistant.turn_end`
carries only the reused turn number. The reducer reads only those two bounded
message identifiers, verifies the exact owner and current interaction/turn, and
uses the message as that owner's completion anchor. Message content is never
decoded or projected. Messages cannot create a turn, revive ended work or
replace spawn identity, and their event IDs use the existing bounded replay
guard.

`producerTaggedMessagesProveRepeatedChildFollowUpCompletion` and
`readerProjectsTaggedInterleavedParentChildAndGrandchildIdle` cover this
producer-shaped attribution through repeated follow-ups and the reader/tree
seams, keeping identity and ancestry while returning to Idle. The nested
fixture is a synthetic composition of the observed single-child sequence, not
installed-app or live grandchild acceptance.

## Multi-turn child identity: unknown turns and capability

From [`docs/behavioral-parity/multi-turn-unknown-and-capability.md`](../behavioral-parity/multi-turn-unknown-and-capability.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

**Missing current-turn proof remains Unknown.** The earlier review packet did
not establish message tags, and its negative regressions stay:
`interleavedUntaggedFollowUpNeedsOwnedProofNotGlobalChronology`,
`repeatedProducerShapedUntaggedFollowUpsRemainExplicitlyUnknown` and the
matching reader/tree regression keep the child's name/kind/ancestry but report
Unknown / `ambiguousTurn`, including on repeated follow-ups. The global
chronological chain is not ownership proof. Partial, malformed, null,
conflicting, wrong-owner and replayed message tags cannot borrow a current
parent link. Unusable advisory message metadata does not suppress the whole
session; a completion with no other valid anchor reports the explicit
ambiguity. Legacy untagged same-owner envelope linkage and current-tool-origin
controls stay supported. A tool first observed after a gap still cannot attest
a turn.

Capability is private, bounded reducer state: strict boolean configuration in a
timestamped initial spawn window, before any child turn, with one admission per
observed child ID. Missing or late configuration, missing spawn evidence, known
old timestamps and reused child IDs cannot grant continuation, even if the old
child became Unknown and was retired before its configuration was observed.
Explicit false revokes it. Failed/cancelled child outcomes, scoped abort/error,
shutdown/resume and uncertain lifecycle boundaries invalidate it; a root-turn
abort/error does not imply independent background children ended. Retired rows
stay retired. Legacy model projection, including lagging configuration
timestamps, is independent of capability admission, and public snapshots are
unchanged. This fixes demonstrated continuation identity and tagged-message
attribution, not every Unknown agent or a particular screenshot. It does not
complete #118/#119, select a shared runtime architecture, add saved-session
resurrection, or grant child control/placement.

Managed report fixtures include the real terminal sequence: `final_answer`,
`assistant.turn_end`, `session.usage_checkpoint`, `assistant.idle`, then
`result`. Only non-content terminal bookkeeping is permitted; later
assistant/tool work and post-result events stay rejected. Policy denial needs a
failed tool's structured error code, not words found in successful output.
Resumed-session empty `session.background_tasks_changed` invalidations are
accepted as notifications, never as proof that background work finished. The
CLI's ephemeral `assistant.reasoning` auxiliary envelope is ignored without
using or publishing its contents. It is not a new reply or a task report.

Owned pre-orchestration installs may lack the newer controller/skill assets
when their signed profile has no orchestration grant. Their exact receipts are
still required for status, preparation, recovery, update and rollback. New
sources and any profile granting orchestration access still need the complete
asset pair.

## Explicit owned-descendant and subtree close (#90, #91, #377)

From [`docs/behavioral-parity/owned-descendant-close.md`](../behavioral-parity/owned-descendant-close.md). Regression evidence, test inventories and limits moved here verbatim; the page now lists test names and links the contract.

The contract is in [explicit close](../reference/hierarchy-launch-lifecycle/explicit-close.md),
with admission and host detail in
[owned-descendant close](../native-messaging/owned-descendant-close.md) and
[stock host behavior](../native-messaging/close-host-behavior.md). #377 widened
admission from direct children only to any strict descendant. This page lists
the regression evidence.

Behavioral fixtures separate the published running-terminal confirmation and
noninteractive branches, including stock refusal before force handling. That is
source proof, not installed/live acceptance. Subtree fixtures cover fixed
selection, retained ended roots, late children, changed
generation/session/surface/ancestry, source/process/workspace changes and
leases. Records, routes and resource accounting remain byte-preserved except for
fixture-owned races. Real subprocess timeout arguments and CLI wire output are
exercised across 127 selected targets, so the 45-second pass, five-second
target windows, nonwaiting locks and unchanged 60-second/65,536-byte transport
bounds are not source-text assertions. Real adapter `execFile` fixtures
preserve a 127-result reply and report overflow, in-flight cancellation and
already-aborted refusal without retry. These synthetic source/transport proofs
do not prove real-host survivors or partial failure.

`NativeCloseTests` in `scripts/test-delivery-proof.py` exercise private
actor/invoker authority, strict-descendant scope, stale target fields,
process/source anchors, workspace movement, launch leases, preflight changes,
real store-lock exclusion, existing RPC error/timeout behavior and
byte-preserved records/routes. An owned real subprocess that exits unreaped,
with its start identity and source marker intact, makes close refuse before any
host call. Unknown process state refuses.

Real-process tests cover a live launch wrapper whose distinct direct child holds
the only source marker, and a same-PID launch/source owner. The wrapper case
failed under the original marker-PID-equals-launch-PID assumption. A zombie
source child under a live wrapper, a deeper source descendant, controlled
sibling/unrelated/foreign ownership, changed parent/start/marker and unknown
evidence all refuse before host calls. Native adapter tests cover strict public
input, bound private identity, one controller invocation, transport
refusal/lost reply/cancellation and no fallback. They use synthetic hosts,
synthetic or owned test processes and disposable local sources, not live CMUX
resources. All three runtime suites remain required. Real disposable native
proof and hosted validation are separate delivery evidence that these
regression tests do not claim.
