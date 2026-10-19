# Messaging, launch settings, and capacity

Native peer messaging, account and model settings, workspace capacity, legacy workers. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

### Native peer messaging

After explicit integration setup, select initial coordinator account and
model in **Agent launch settings**. Then use `launch-coordinator`.
`launch-settings` reports `messagingInstalled` separately from saved-account/
model `ready`. Neither field proves a recipient loaded its native adapter.
Neither identifies the invoking session's account.
New installed-controller spawns auto-bind exact Copilot session,
generation, and CMUX workspace before launch. They enable CLI native extensions
with `--experimental`. No per-project fixture preparation needed. Ordinary
unmanaged sessions, existing workers, and registered coordinators without a
launcher-owned Copilot session stay **unsupported recipients**. Never adopt or
restart them automatically.

Use global `/maestro` for `maestro_peers` discovery, `maestro_send`, and replies
to the supplied sender address. Any participating same-workspace peer can send,
including siblings and peers from another run. Messaging grants no lifecycle or
process-control rights. Native adapter joins only its CLI-owned session.
It uses `session.send({ prompt, mode: "enqueue" })`. Copilot owns scheduling.
No sidebar, selected workspace, foreground application, terminal keystroke,
composer inspection, acknowledgement, receipt, retry, or completion tracker is
involved. A local-write attempt is **not** a delivery or completion guarantee.
Source package and unchanged confirmed purpose live in `skills/maestro/`.
It has no tool-permission grants in frontmatter. It reuses installed
`/cmux-maestro-native:cmux-maestro-orchestrate` skill for lifecycle operations.
For skill tool, pass `{"skill":"maestro"}`. Only existing lifecycle/icon
plugin slash commands stay namespaced. Global messaging guide is not namespaced.

Prospective native children of an interactive managed parent: omitted
`allowTools` and `yolo` inherit parent's explicit **recorded launch policy**.
Born-managed parents additionally derive allow-all from their exact provider's
launch flags, with bound PID/start-time checks. `--yolo`, `--allow-all`, or all of
`--allow-all-tools`, `--allow-all-paths`, and `--allow-all-urls` qualify (`=true`
supported). Tools plus paths alone stay default rather than widen URL access.
Only mode and source are retained; never argv. Missing evidence defaults,
and an unrecorded manual deny prevents inherited allow-all. Only the controller's
audited benign-option allowlists qualify alongside the allow-all flags.
Unreplayed plugins, configuration/workspace loaders, tool selectors, and resumed
or alternate session selectors (including `--resume` / `--session-id`) default
rather than drop unknown restrictions. See ADR 0006 for the option boundary.
Spawn reports `permissionMode` and `permissionSource`; descendants retain the
recorded mode. Runtime `/allow-all` toggles are invisible: off-to-on does not
enable inheritance, and on-to-off cannot invalidate recorded launch flags.
Deny-only request keeps recorded mode/allows and adds denies. Explicit
`allowTools` list (including `[]`) or `yolo: false` selects requested default mode
without `--allow-all`. Omitted allows still inherit. Parent denies survive.
Default-mode parents keep literal allow-subset checks. Recorded YOLO parents
permit bounded finite child allow rules without redundant parent allows. They
keep all denies and reject wildcard/broad rules. A coordinator
may request `yolo: true` **only with explicit human approval**, without a narrowing
allow-list. Combining both intents refuses. Workers' explicit YOLO requests still
refuse before credentials/reservation, separately from inheriting parent YOLO.
Missing recorded provenance or policy drift before reservation refuses.

This is **recorded/requested policy, not verified current provider permissions**.
Human `/permissions` changes can make launch records stale. Copilot's
`defaultPermissionMode: "allow-all"` or `COPILOT_ALLOW_ALL` may elevate
a new session despite omitted `--allow-all`. Requested default mode is not
proof of actual manual startup. Inspected SDK exposes current mode/path
getters. It has no verified complete current tool/deny/URL policy snapshot and no atomic
same-or-narrower external-child admission. Full live inheritance/restricted-startup
acceptance stays unverified. No permission callback, persistent setting change,
or launch-then-policy mutation is used.

Each native child has one private Unix socket and a launcher-created binding
under `~/.copilot/extensions/maestro/r/`. Account credentials never enter these
files or messaging tools. Addresses contain workspace/session UUIDs and generation,
not secrets. Limits: payloads 4 KiB UTF-8, frames 8 KiB, registered
participants 128, connections/pending native sends eight per receiver.
Per-workspace live managed session cap is `MAX_LIVE_WORKERS` in
[`scripts/cmux-maestro-orchestrator.py`](../../scripts/cmux-maestro-orchestrator.py).
It includes managed coordinators and retained resources. Routes use exclusive
creation. Routes retire after exact provider exit (or closed-run archive). Clearing/resuming
a conversation cannot rebind them. Restart/clear/replaced-session,
offline, unsupported, invalid, or stale routes fail closed. Request fresh managed
sessions only with user authorization. Same-user processes are trusted: private
capabilities do not defend against a malicious process running as your user.

See [native delivery findings](../delivery-proof.md) for observed agent
exchange, human-confirmed draft preservation, separate harness-origin background
check, and outstanding installed-product live acceptance. Mocked contract tests
are not native UI proof.

### Local agent launch settings

The containing app's **Settings > Agent launches** tab has **Launch agents with
subscription:** and an optional worker-model setting. Dropdown lists
configured GitHub.com accounts from GitHub CLI. It shows no credentials
and infers no subscription plan names. **Use Copilot default** leaves
authentication and model selection to Copilot.

Preferences live only in user's private Application Support
`CMUXMaestroPreview/Orchestration/worker-settings.json`, not in this repository.
Project ships no account or model pin. Launch resolves a configured account from
its stored credential and passes it only through `COPILOT_GITHUB_TOKEN`.
Unavailable credentials fail closed before a new terminal is created. No
silent fallback to a different account. Tokens are not written to settings,
state, launch tickets, arguments, observer files, or logs. Git identity and
active `gh` account are not switched. Changes affect only future workers. Direct
controller callers may keep Copilot defaults by omitting the requirement flag.
Bundled orchestration skill deliberately does not omit it. It always requires the
pinned Maestro account and model.

### Optional per-launch preferences

Native `maestro_spawn` accepts optional `model`, `contextTier` and
`reasoningEffort` strings. Omission preserves existing configured launches:
no model query, no new warning, no context/effort flag. No activity defaults
are inferred from worker names, roles, or task text.

For explicit preferences, existing joined extension reads
`session.rpc.model.list()` using that session's authentication context. It
checks the invoking account before and after. Only bounded model IDs,
supported tiers/efforts, and advertised default effort enter private launch
evidence. Raw model/billing/quota data does not enter state, prompts, or host
commands. Provider-native defaults are validated against raw advertised support.
Valid defaults outside current CLI's effort levels are omitted from the
projection. They are not invented as CLI flags and not used to reject unrelated selections.
Malformed, duplicate, oversized, or foreign evidence and account drift
refuse before launch. This is a capability snapshot, not atomic account/provider
admission or an observation of the child's running settings.

Supported selections feed actual `--model`, `--context` and
`--reasoning-effort` arguments. Unsupported safe optional requests **warn**:
an unavailable requested model falls back only to the configured pin when that
pin is available in the session catalog. No available configured fallback
means refusal, never arbitrary model substitution. A valid selected model
survives an unsupported context/effort request: context falls to its default
tier, effort to its advertised default (or no override when unavailable).
Unavailable experimental model lookup warns and preserves the old configured
launch without optional overrides. Unsafe input, missing credentials,
ownership, permission, and capacity failures are not preference fallback.

Bounded private `launchSelection` record and receipt distinguish requested
preferences, configured arguments, evidence source, and warnings. `observed`
stays unknown. `long_context` is a supported tier, not a numeric context-window
claim. Account entitlements and actual provider application stay unverified
until independently observed. On a supporting installed adapter,
`maestro_identity({"includeModel":true})` reads the responding session's
`session.rpc.model.getCurrent()` and returns a bounded `modelObservation`:
`observed` with source, timestamp, and actually reported model/context/effort,
or `unavailable` with a reason. Unreported context/effort is omitted, not replaced
with launch defaults. No catalog, plan-model alternative, or raw error is returned.
Account and exact binding are rechecked after the read. Drift refuses.
Default identity calls keep existing account-only behavior and make
no model query. Parent cannot use this to observe a child. Child must make
its own explicit query. This does not wait for startup, poll, persist observations,
switch models, or prove entitlement, token-window size, or installed execution.
Timestamp is local collection time, not an atomic provider revision.
A reported virtual `auto` model does not identify the backing model of a turn.

CLI adds `spawn --model`, `--context-tier` and `--reasoning-effort`. Direct
callers lack joined-session evidence, so new selections warn and keep
configured defaults. `launch-coordinator --model` keeps its pre-existing
explicit-over-configured precedence and syntax validation. It claims no
session-catalog support. Its new context/effort options warn and stay omitted.
Neither native Settings nor persistent Copilot configuration changes.

### Workspace launch capacity

Controller `capacity --workspace <workspace-uuid>` command returns a
read-only, **advisory** preflight. It needs no provider credentials or host RPCs.
Authenticated `status` also includes the same workspace-wide `capacity` summary:
managed roots, workers, retained resources, pending launches, used
slots, configured limit, and workspace stored-node slots. Pending leases are
already counted through their managed nodes, not added twice. Unknown or stale
process/terminal ownership is not free capacity.

To persist a limit, a human-directed workspace coordinator uses:

```sh
python3 scripts/cmux-maestro-orchestrator.py capacity \
  --workspace <workspace-uuid> --limit 64 \
  --actor-id <coordinator-id> --token <private-control-token>
```

Keep control token private, as with other authenticated controller commands.
Worker actors and coordinators from other workspaces cannot change the limit.
Limits are integers from **1 through 128**, default **32** when omitted.
They live in existing private `Orchestration/control/state.json`, separately
from account/model settings. Native Settings does not edit them. Lowering a limit
below current usage preserves every session and retained resource. It refuses
new admissions until usage permits them. No automatic cleanup or reuse occurs.

A successful preflight reserves nothing. Root and child launch reservations
recheck latest limit and exact resource usage inside their exclusive
transaction. Separate **128-node per-workspace** and **8-level** bounds still apply. A
configured limit of 128 does not guarantee 128 available nodes or demonstrate
128-provider load. `storedNodes`, `storedNodeLimit` and `nodeSlotsRemaining`
count only the queried workspace, including resource-retired history and
registered coordinators. Another workspace's history does not consume these
slots. Retained terminal records stay separately bounded to 128 per workspace.
Live-workspace `remaining` alone is not an
admission check. Increasing live capacity, closing a tab, or deleting records
automatically does not repair history exhaustion.

Independent **host safety limits** bound the shared store: 1,024 total nodes
(including leases), 1,024 retained resources, 128 configured workspace-limit
entries, and 1 MiB each for state and observer/icon output. Preflight exposes
`hostStoredNodes`, `hostNodeLimit`, `hostNodeSlotsRemaining`,
`hostRetainedResources`, `hostRetainedResourceLimit`,
`hostRetainedResourceSlotsRemaining`, `hostStateBytes`,
`hostStateByteLimit`, `hostStateBytesRemaining`, `hostCapacitySettings` and
`hostCapacitySettingLimit`. These are distinct from
workspace allowances. A host protection refusal names its host bound.
Current byte room is advisory, not a guarantee that a proposed record fits.
Actual serialized state/projections are checked before external creation.
There is no automatic pruning, quota bypass, state reset, or live migration.
Schema-1 saved states stay readable. Older installed readers/controllers
keep their previous bounds until an explicitly authorized upgrade. Source
publication alone does not activate the multi-workspace allowance (#167).

Shared managed-message route scan has matching finite host bounds:
1,024 private bindings and 2,048 directory entries (route/socket pairs), with
at most 128 participants in the responding workspace. Other-workspace bindings
are validated but omitted from its peer list. Send/receive keep exact address,
generation, capability, and frame/body checks. Legacy proof transport is unchanged.
Saved schema-1 UUID spellings share a canonical workspace census without
rewriting ownership records or migrating the store. Equivalent case spellings
cannot obtain separate node/retained allowances.

Lock acquisition keeps the existing 32-session reference
policy: ordinary waits stay bounded to 4 seconds, two-second waits to 8 seconds,
and zero-wait requests stay immediate, regardless of workspace capacity.
Upstream activation ordering and installed-runtime validation are separate.

### Legacy bounded-worker compatibility

Existing bounded workers keep `follow-up` and `report`. Follow-up queues privately only after a directly owned
worker has a successful exact-session boundary for its current generation.
It then uses that worker's preassigned exact `--resume` session ID. Explicitly reported
outcomes are preferred. A report-missing or permission-denied generation may be
re-prompted without claiming its earlier task succeeded.
Supervisor multiplexes bounded JSON output and promptly forwards provider
diagnostics. It continues current-generation heartbeats during silent turns.
It never answers permission prompts. Noninteractive Copilot can deny a tool in
JSON without offering an interactive prompt, so stderr inheritance is not a
permission mechanism. Terminal existence and a zero CLI exit are
not success. Completed, blocked, and failed states require both a successful
exact-session process boundary and one strict generation-matched whole-final-
message report. Report is versioned, identity-bound, and permission-free.
Refused: ordinary prose, fenced or extra JSON, tool-bearing final messages, and dual
helper/final reports. It stays a worker self-reported outcome,
not independent artifact validation or reviewer acceptance. Missing reports,
permission denials, nonzero
or malformed turns, startup failure, process
disappearance, and terminal disappearance stay distinct. An explicit launch
lease prevents archive from crossing CMUX surface creation/attachment. Any
exact surface created before a later launch failure stays accounted. Eight
still-live managed worker resources are allowed per workspace.
Reported completion does not free a slot. Archive retains bounded history and
never kills processes or deletes tabs, so still-present archived worker tabs
keep consuming the resource bound. Tool permissions are not auto-approved.
Interactive archive checks exact process exit under the lock both before
admission and before deletion. Failed process probes stay uncertain, not
proof of exit. Interactive-only runs need no cooperative stop marker, so a
refused archive leaves their records, messaging routes, and archive flags intact.
Cancelling an unclaimed launch lease records explicit pre-runtime failure
evidence. Stale recovery can retire that never-started worker after its exact
surface is closed (or when creation produced no surface), even without process
anchors. Missing anchors alone, idle time, and startup timeouts are not exit
proof. No-start evidence requires lease cancellation before runtime
claimed ownership. Legacy supervisors keep their cooperative archive stop.
Read-only controller snapshots use shared locks. State mutations stay
exclusive. Idle supervisors therefore do not serialize their status reads
behind the mutation lock as a workspace approaches its worker limit.
Spawn accepts bounded caller-explicit `--allow-tool` and `--deny-tool` rules.
Registered/legacy defaults add no grants. Denies win. Descendants cannot
exceed their parent's explicit allows or remove inherited denies. Prospective
native interactive children inherit recorded parent policy as qualified above.
Legacy bounded behavior is unchanged. These Copilot flags are policy controls,
not an operating-system sandbox. No shell or wildcard grant is synthesized from
tool visibility or prompt text. Recorded parent YOLO and explicitly approved
coordinator YOLO requests append `--allow-all` while retaining denies.
