# Evidence archive: delivery proof

Archived 2026-11-06. Dated evidence moved verbatim from the living documentation. Where a statement here is still current, the linked living page restates it.

## Delivery proof: contract and boundary

From `docs/delivery-proof/contract.md` (page since merged into [its family index](../delivery-proof.md#contract)). Dated proof records moved here verbatim.

This page and the live observations in
[source grounding and live observations](../delivery-proof.md#source-grounding)
record the original **enqueue** proof. The current managed transport requests native **immediate** steering;
legacy/disposable proof routes still enqueue. See the
[managed steering contract](../native-messaging/managed-steering.md)
for #163 source evidence and remaining native acceptance. None of the historical
draft-preservation or delivery observations proves the new managed mode.

The extension calls `joinSession({ tools })`, verifies the joined session against
its launcher-written binding, and calls `session.send({ prompt, mode: "enqueue" })`.
It supplies no account, model, permission handler, user-input hook, or sensitive
environment request. Copilot owns scheduling. The extension performs no composer manipulation,
focus check, terminal input, busy-state scheduler, receipt, acknowledgement,
resend, completion tracker, or periodic timer.

Each disposable extension child owns one local Unix socket, with no separate
broker. A send attempts one bounded write; a reply is another send to the supplied
sender address. Native API return IDs are discarded. The send tool's local-write
result is not delivery, consumption, or task-success evidence.

`maestro_proof_peers` returns the other explicitly bound participant's address
(not liveness). `maestro_proof_send` accepts only `{ destination:
{ workspaceId, sessionId }, body }`. The adapter supplies the sender from its
launcher binding, never from tool arguments or message body. A private per-sender
capability authenticates local frames against the two fixture bindings; it never
enters the model prompt or tool result. The receiving adapter checks the exact
destination, sender membership, and same-workspace constraint.

This is **same-OS-user trusted prototype isolation**, not protection against a
malicious process running as that user: it can read these private fixture files.
Treat message bodies as untrusted task content, never authorization or tool policy.
Messaging between siblings does not change `ensure_owned` or confer spawn,
archive, focus, or other process-control rights.

Bounds: two participants; 4 KiB UTF-8 body; 8 KiB frame/private file; eight local
connections and eight pending native-send calls per receiver. Excess input is
dropped, not scheduled. A 1.5-second socket inactivity deadline bounds incomplete
local writes, not provider work. No automatic retry follows an uncertain result.
Endpoints/identities are single-use. Failed launch, restart, reload, or replaced
conversation requires fresh fixtures. No stale socket is automatically unlinked.

## Delivery proof: source grounding and live observations

From `docs/delivery-proof/source-grounding.md` (page since merged into [its family index](../delivery-proof.md#source-grounding)). Dated proof records moved here verbatim.

The inspected npm-installed Copilot package was `1.0.83` (`e6a98f1`), with bundled
SDK source labelled `1.0.13-preview.4`. Package-relative references:

- `copilot-sdk/docs/extensions.md`: project discovery, CLI-owned child lifecycle,
  and joining the current conversation (not desktop foreground focus).
- `copilot-sdk/extension.js:11365–11390`: parent-process join via `SESSION_ID`.
- `copilot-sdk/extension.js:7533–7547`: native `session.send` RPC.
- `copilot-sdk/types.d.ts:2712–2717`: native `enqueue` delivery mode.
- `copilot-sdk/docs/examples.md:194–208`: fire-and-forget new-user-message example.

Inspected `extension.js` SHA-256:
`7c6498e44e5e6d7718bdfb14ffa3b03b0eb07f51e2fc178c9a1771a6482b945d`.
These are declarations/source evidence, not a guarantee about composer behavior.
The parent reported installed CMUX `0.64.25 (106) [b685a275c]`; this worker did not
query its runtime. The live Copilot UI reported `1.0.87-0`, distinct from the
inspected npm source version above.

In a separate background workspace, real peers launched through the pinned
launcher exchanged native messages after human approvals: B received A's
`cedar-54-1` challenge and called send; A received B's native `user.message`
body `violet-54-1` and rendered final answer `violet-54-1`. B's earlier initial
turn returned “No response was returned”. It did not prevent the later exchange.
External MCP startup warnings were also present. That exchange alone did not
verify draft preservation or every
[bounded live check](../delivery-proof.md#live-checks).

### L3 live draft-preservation observation

The human placed `HUMAN-DRAFT-54` unsent in B. The parent then injected one native
test message through the disposable A capability route to B, using private
same-user fixture bindings. B received the native `user.message`. This was
**parent-controlled, harness-origin injection, not a message authored by A**,
unlike the first real A → B → A agent-tool exchange above. No terminal-input or
focus operation was used.

The human explicitly confirmed **“Preserved exactly and still editable”**, then
“yeah it worked” and “brilliant”. This confirmation, not screenshots, is the
evidence for preservation and continued editability of the unsent draft.
This draft result alone does not establish app-background or sidebar-hidden
delivery. The separate app-background observation follows.

### L3 app-background delivery observation

The user explicitly said they were putting the app in the background. The parent
injected one native harness message through the disposable B route to fresh A,
with body `Parent harness app-background check: background-54-1`. A's native
final response contained that exact body at `2026-09-21T22:03:01.267Z`.
This was parent-controlled harness injection using the disposable route, not
a message authored by B.

Read-only `NSWorkspace` observations showed CMUX was **not foreground immediately
before or after** the check; different non-CMUX applications were foreground
at those two observations. Their names are intentionally omitted. The harness
performed no focus, window, or workspace operations.

**App-background delivery was observed**, supported by the user's stated action,
the before/after foreground observations, and the native response. These are
point-in-time observations, not continuous foreground-state monitoring.
**Sidebar-hidden remains unconfirmed**. This check does not establish it.

### L4 fresh YOLO-launch observation

The parent reported a successful autonomous exchange using fresh fixture
`live54b` in a new background workspace. Both new sessions launched with
`--delivery-proof-yolo` and `--delivery-proof-experimental`. B received challenge
`cedar-54-2`. A's native session rendered final answer `violet-54-2` at
`2026-09-21T21:58:20.459Z`. The parent harness performed no approval clicks,
terminal input, or resends. These were fresh sessions, not reuse of the first
pair whose permissions had been changed by human interaction.

**Fresh explicit YOLO-launch verification is demonstrated.** This establishes
the per-spawn opt-in, not full parent-permission inheritance. A background
workspace does not establish the application's foreground/background state or
the sidebar-hidden condition. The separate L3 check above supplies app-background
evidence. Sidebar-hidden remains unconfirmed.

The [discovery foundation](../agent/discovery/issue-38-shared-agent-interaction.md)
preserves the Orca, Paseo, Herdr, and CMUX revision-pinned comparisons and their
source-versus-runtime distinctions. This proof does not redo that research.

## Guide distribution decision after live proof

From `docs/delivery-proof/guide-distribution.md` (page since merged into [its family index](../delivery-proof.md#guide-distribution)). Dated proof records moved here verbatim.

Parent research against the exact `1.0.87-0` executable found the installed
`cmux-maestro-native` `1.1.0` plugin enabled in CLI discovery, while a fresh
interactive session's skill registry omitted `maestro`. Native messaging worked;
bare skill-tool invocation failed. The upstream cause is not established.
`joinSession` with unspecified discovery/plugin options does not justify resetting
configuration. The tool identifier is `maestro`, not
`cmux-maestro-native:maestro`. The latter was the plugin slash UI namespace.

The parent later reported **live failures with both bare plugin loading
and the explicit `--plugin-dir` mitigation**. Source loading order and mocked
launcher tests did not establish live interactive skill availability. No
upstream root cause was demonstrated. The workaround is removed, not advertised
as a fix.

**User-observed success at `2026-09-22T12:03:56.533Z`:** `npx skills` **1.5.26**
installed the local-source guide globally at `~/.agents/skills/maestro`, and
Copilot global discovery succeeded. The user chose this as the **one canonical
guide distribution**. The location is evidence for that run, not a hardcoded
`.copilot` global-path assumption. Global invocation is **`/maestro`** or
**`{"skill":"maestro"}`**, without additional required activation grants.

Native Maestro **Settings > CLI Integration** now presents the purpose,
selectable command and one copy button in a minimal native section. Richer card,
status detection, update and coverage flows are deferred for separate backlog
tracking by the parent. They do not block messaging. The section has no local
scan, re-check action, remote freshness claim or embedded terminal. The command is:

```sh
npx skills add jdylanmc/cmux-maestro --skill maestro --agent github-copilot --global --copy
```

The human must run it and review interactive confirmation. Settings executes
nothing, opens no terminal/browser, and touches no global skill. This GitHub-source
command needs the skill merged to `main`. For development/PR acceptance, from the
checkout root the human may instead run:

```sh
npx skills add . --skill maestro --agent github-copilot --global --copy
```

No movable branch ref or release machinery is embedded. The user's working
global local-source copy is not refreshed by this author; any content refresh
remains parent/user-consented.

Runtime installation stays in **Enable Copilot Integration**. The guide never
installs runtime and messaging remains usable without it. The canonical source
is `skills/maestro/{SKILL.md,intent.md}`; it is no longer bundled into app resources
or copied into the runtime plugin. Lifecycle/icon plugin skills remain.
Explicit setup removes only its obsolete `Copilot/plugin/skills/maestro/SKILL.md`
using existing owned-directory patterns, refusing symlinks and preserving
unrelated/global skills and other files. This correction does not mutate installed
live files or cached sessions.

Setup writes `{version, routes, extension}`. The launcher cheaply ignores an old
`pluginDirectory` field and never validates or passes it to Copilot. Both old
and new stored nodes retain the three-field contract; no guide-driven setup
upgrade is required. Pins, denies, coordinator-only explicit `--allow-all`,
native `--experimental`, terminal I/O and all R1-R5 lifecycle fixes are retained.
The change adds no receipts, retries, custom scheduling, new timers or host changes.

## Parent-reported installed exchange and skill-name correction

From `docs/delivery-proof/installed-exchange.md` (page since merged into [its family index](../delivery-proof.md#installed-exchange)). Dated proof records moved here verbatim.

The parent installed revision `93d6968` through the normal updater and the human
successfully used **Enable Copilot Integration**. Three fresh managed participants
launched with explicitly approved `--yolo` in ordinary working directories, not
proof fixtures. A called `maestro_peers` and found B and C with generation-bearing
addresses. The installed A -> B -> A exchange produced `installed-violet-54-1` at
`2026-09-22T00:13:46.727Z`. CMUX's **Default sidebar** was selected, demonstrating
that this exchange did not require the Maestro sidebar to be selected. This does
not establish the separate sidebar-hidden condition or repeat draft/background
acceptance on the installed build.

The same run exposed a skill-discovery failure: the skill tool call
`{"skill":"maestro"}` failed with **`Skill not found: maestro`**, although the parent
reported plugin `cmux-maestro-native` v1.1.0 and its installed `skills/maestro`
directory. The plugin layout follows the documented legacy `skills/` default;
this is not evidence that the package needs an explicit `skills` field.

Copilot **1.0.87-0** shipped `app.js` constructs plugin skill commands as
`pluginName:skillName` (functions `DUe` at line 1514 and `n0n` at line 1800);
skill listing/recognition uses `skillsInvocationName` at line 3122.
The [public plugin reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-plugin-reference#component-path-fields)
confirms the default directory convention. The initial interpretation incorrectly
conflated qualified slash-command names with skill-tool identifiers. A received
the parent's qualified-name diagnostic but correctly ignored it as outside its
authorized peer task. A separate fresh participant explicitly authorized to test
`{"skill":"cmux-maestro-native:maestro"}` then failed with
**`Skill not found: cmux-maestro-native:maestro`** at
`2026-09-22T00:19:41.795Z`.

Bounded read-only discovery using the exact worker executable and CLI **1.0.87-0**
later listed the installed messaging skill as `name: maestro`,
`source: plugin`, `enabled: true`. The native loader identifies its plugin as
`cmux-maestro-native`, while `skillsInvocationName` returns the bare skill name.
At that stage, the plugin used slash command `/cmux-maestro-native:maestro`
and skill-tool argument `{"skill":"maestro"}`. That distinction did not fix live
discovery. The [final distribution decision](../delivery-proof.md#guide-distribution)
supersedes plugin messaging-guide installation and invocation with global
`/maestro`. Lifecycle/icon slash references remain qualified.

**The cause of the initial missing-inventory observation remains unresolved.** The failing
session's startup model-visible inventory did not contain the messaging skill,
whereas later read-only discovery did. The permitted comparison found no
installer/runtime root or registered-plugin discrepancy; it did not establish
the cause of that startup/current-inventory difference. Neither the namespace
correction nor plugin discovery proved live skill execution. Subsequent bare
plugin and explicit-plugin-directory live failures led to the observed successful
global installation in
[guide distribution](../delivery-proof.md#guide-distribution). No private registry contents, account/model data,
credentials or full debug transcripts are included in these findings.

## Installed implementation: checkpoint and validation

From `docs/delivery-proof/installed-validation.md` (page since merged into [its family index](../delivery-proof.md#installed-validation)). Dated proof records moved here verbatim.

**Implementation checkpoint:** runtime/setup/resource wiring and their targeted
contracts are implemented. The user-confirmed intent is stored unchanged at
`skills/maestro/intent.md`; the simple repo-native `SKILL.md` beside it teaches
discovery/send/reply and cross-references the existing lifecycle skill, without
an atomic-skill framework or tool-permission frontmatter grants. The source folder
is discoverable by `npx skills`, not an app resource or a runtime prerequisite.
The parent still owns final complete CI, independent review and installed live
validation. Targeted build and test evidence is recorded below.

Final distribution-correction validation:

- **M2 launcher:** three-field setup/node compatibility, ignored obsolete
  `pluginDirectory`, no `--plugin-dir`, and launches without any guide/plugin
  source. This correction leaves lifecycle R1-R5 code unchanged.
- **M3 Settings/setup/resources:** default production and validation Settings
  scenes share the native tabs; the actual copy handler emits the exact
  interactive global command. Isolated setup covers absent guide resources,
  precise obsolete-copy removal, repeated setup, preserved unrelated files,
  symlink refusal and unchanged runtime installation/uninstallation.
- **M4 tests/CI:** isolated Settings/setup/hook suite **35 passed**, integrated
  Settings/setup suites **20 passed**, launcher/proof/skill suite **55 passed**,
  orchestration **45 passed**, adapter **10 passed**, metadata **15 passed**,
  local-preview **60 passed**.
  The existing CI setup step now also compiles and runs Settings tests.
  Unsigned build and namespace validation passed; the built app contains no
  messaging guide. These are targeted checks, not a final full-CI claim.
- **M5 guide/findings:** global `/maestro`, separate runtime consent, prior live
  failures and user-reported global success, and the pre-merge local-source
  command are documented. `intent.md` remains byte-identical with SHA-256
  `8dd1495be16e27a92b43a038ab7b728b4d6fedcbae1e53f41aac11452fe54d42`.

This author performed no production setup, global install/refresh, provider
launch, live binding read or live endpoint mutation. Installed Settings UI
acceptance and independent review remain parent-owned; the GitHub-source command
cannot install this unpublished guide until merge.

Historical targeted validation before the final distribution correction (the
old packaged guide below is no longer shipped):

- `./scripts/build-unsigned.sh`: **BUILD SUCCEEDED**, and both namespace checks passed.
  The built app identifier is
  `com.jdylanmc.CMUXMaestroPreview.Validation.Unsigned`, not production.
- Exact byte comparisons passed for packaged `adapter.mjs`, `extension.mjs`,
  `maestro/SKILL.md`, `maestro/intent.md`, and lifecycle `SKILL.md`.
  Confirmed intent SHA-256 remains
  `8dd1495be16e27a92b43a038ab7b728b4d6fedcbae1e53f41aac11452fe54d42`,
  matching the parent's storage-gate receipt.
- `./scripts/test-copilot-setup.sh`: **30 tests passed**. Installation uses
  synthetic private paths and the real new skill/adapter resources; no provider
  process, production setup, or live endpoint is involved.
- Existing CI-registered suites passed: **45 orchestration, 20 Python
  launcher/proof/skill, 10 Node adapter, 15 metadata, 60 local-preview tests**.
  `git diff --check` passed. These are targeted results, not a claim that the
  parent's final full CI/review or live installed-product checks are complete.

## Bounded live checks and cleanup: worktree test note

From `docs/delivery-proof/live-checks.md` (page since merged into [its family index](../delivery-proof.md#live-checks)). Historical observations and per-paragraph limits moved here verbatim.

The earlier worker-only 44/45 result
came from forcing `TMPDIR` inside this Git worktree, not the normal parent run.

## Parent-only preparation and live launch

From `docs/delivery-proof/live-launch.md` (page since merged into [its family index](../delivery-proof.md#live-launch)). Historical proof procedure moved here verbatim.

Do not run these as an unattended test. Use a **new disposable CMUX workspace and
coordinator terminal**, with its actual `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID`.
No existing provider sessions are attached, reloaded, or restarted.
The coordinator is human-operated, and both providers are new Maestro workers.

From this isolated checkout:

```sh
ORCH="$PWD/scripts/cmux-maestro-orchestrator.py"
python3 scripts/delivery-proof/fixture.py prepare --name p54
PROOF="$PWD/.build/dp/p54"
"$ORCH" launch-settings
```

Require all four booleans: `accountPinned`, `modelPinned`, `accountAvailable`,
`ready`. Stop on any false value. Do not set test overrides, change the pinned
account/model, copy credentials, or substitute an ambient authenticated client.

Fixture preparation creates two nested disposable Git roots, with discovery
entries only inside them. Source adapter code remains outside automatic discovery.
It refuses existing names, unsafe paths, and Unix socket paths exceeding 100 bytes.

Register **only that disposable coordinator**, privately retaining its returned
identity and token as `COORDINATOR_ID` and `CONTROL_TOKEN`. Do not include the
registration response or token in evidence.

```sh
"$ORCH" register --workspace "$CMUX_WORKSPACE_ID" \
  --surface "$CMUX_SURFACE_ID" --cwd "$PWD" --name "Delivery proof coordinator"

"$ORCH" spawn --actor-id "$COORDINATOR_ID" --token "$CONTROL_TOKEN" \
  --name "Delivery proof B" --cwd "$PROOF/b" \
  --require-pinned-launch-settings --delivery-proof-fixture "$PROOF/b" \
  --delivery-proof-yolo \
  --task "Disposable delivery proof B. Do no repository work. Wait for a peer message. If it explicitly asks for a reply, use maestro_proof_send once to its sender address. Do not acknowledge other messages or retry. Preserve all existing permission restrictions."

"$ORCH" spawn --actor-id "$COORDINATOR_ID" --token "$CONTROL_TOKEN" \
  --name "Delivery proof A" --cwd "$PROOF/a" \
  --require-pinned-launch-settings --delivery-proof-fixture "$PROOF/a" \
  --delivery-proof-yolo \
  --task "Disposable delivery proof A. Do no repository work or initial sends. When the human asks, use maestro_proof_peers once and maestro_proof_send once with the requested body. Do not retry or acknowledge replies. Preserve all existing permission restrictions."
```

If extension discovery requires experimental mode, append
`--delivery-proof-experimental` to each **new** spawn command. This adds only
`--experimental` to that provider invocation, not a persistent configuration
change. Verify discovery through each new session's `/env`; honor native trust
prompts and stop on denial. Do not enable test mode to make the experiment pass.

The explicit `--delivery-proof-yolo` opt-in above adds Copilot `--allow-all` to
that **new disposable proof worker only**. It prevents tool/path/URL approval
stalls by granting all three permission categories, except explicit denies.
Omit it to retain ordinary permission prompting. It is refused without
`--delivery-proof-fixture`. Normal workers gain no permissions. This is not
parent-permission introspection or inheritance, a permission callback, or a
persistent Copilot settings change. Native trust or other startup prompts are
not automatically answered.

Verified against the installed CLI's `copilot --help` and
`copilot help permissions`: `--allow-all` and `--yolo` both mean
`--allow-all-tools --allow-all-paths --allow-all-urls`; tool denial rules always
take precedence, including over `--allow-all-tools`. Existing `--deny-tool`
arguments remain unchanged. Recheck provider semantics before using another
version. Do not drop denies if they cannot be preserved.

**Review correction R1:** the original source opt-in checked descendant explicit
allow lists but did not account for the later `--allow-all` flag. A worker actor
with only `read` could request proof YOLO and bypass its grant bound. Both the
preserved `--delivery-proof-yolo` and installed `--yolo` now require a coordinator
actor before credential resolution or reservation. Negative worker-actor tests
cover both forms. Denies and the coordinator's explicit opt-in remain intact.
This is deliberately not full parent-permission inheritance.

Both calls use the existing pinned interactive launcher, native terminal I/O,
exact session ID, and existing explicit tool-policy rules. The opt-in is stored
as `deliveryProof.yolo`; old `{fixture, experimental}` nodes remain valid and
default to no YOLO. The proof options are
source-checkout-only wiring. Nothing is installed over the active integration.
The existing controller store still owns these new workers; no alternate
authentication or replacement control store is created.

## Bounded live checks and cleanup

From `docs/delivery-proof/live-checks.md` (page since merged into [its family index](../delivery-proof.md#live-checks)). Historical proof procedure and results moved here verbatim.

### Bounded live checks

After both adapters load, the human asks A to send one synthetic message,
for example: `Ask the other proof peer for the word "violet"; request one reply
to your return address.` Observe the ordinary reply in A, without adding protocol
acknowledgements or waiting logic. Limit each observation to 120 seconds; missing
output is an inconclusive/failed observation, not a reason to resend automatically.

Repeat separate, explicitly requested single sends while:

1. B is selected and its input is focused.
2. The human is typing or has an unsent sentinel draft in B. Check the exact draft
   and editability before/after. This check requires human participation.
3. Another workspace is selected, then CMUX is app-backgrounded.
4. B has active work; let Copilot choose scheduling, without asserting when it
   must run the new prompt.
5. The sidebar is hidden.

Observe no focus stealing, workspace switching, draft clearing/submission, or
keystroke interference. Record versions, synthetic bodies, sanitized workspace/
session aliases, visible observations, and unmet cases. Do not copy binding
files, controller state, credentials, raw provider logs, or unrelated transcripts.
No mocks prove these checks. Stop on interference.

### Local validation and cleanup

```sh
python3 scripts/test-delivery-proof.py
node --test scripts/test-delivery-proof.mjs
python3 scripts/test-cmux-maestro-orchestrator.py
```

The first two suites use disposable files and local sockets under `.build/`,
with mocked native sessions/launcher processes, and remove their own fixtures.
No dependencies are added. Repository CI's other declared checks remain
unchanged and belong to the parent’s complete validation pass.

The orchestrator suite uses fake CMUX/Copilot processes in temporary roots.
Its fixture-only Python startup hook carries a shared lifetime descriptor
through subprocesses and shell execution. Teardown closes fixture admission,
signals only recorded PID/start identities, and requires exclusive lifetime
ownership before deleting the root. A writer that outlives the existing
three-second shutdown budget causes an explicit failure and preserves the
sandbox, including against automatic temporary-directory cleanup. Do not remove
a preserved root until its exact fixture processes have stopped. New fixture
launch paths must preserve the lifetime descriptor and startup hook; neither
is installed into real CMUX or Copilot sessions.

Parent validation before the permission correction: **all 9 declared repository
CI command steps passed on first attempts**, including **45/45** orchestrator
tests and **7 Python + 7 Node** proof tests.
The permission correction adds targeted Python coverage for default/opt-in
launches, preserved denies/pins, serialized opt-in, refusal outside proof, and
old stored-node compatibility. Full post-correction CI belongs to the parent.
Post-correction targeted validation: **12/12 Python proof tests passed**, and
`git diff --check` passed. No live endpoints were operated or reloaded.

After the human stops the two exact proof sessions, use existing owned-worker
archive/recovery guidance as applicable. The adapter does not kill providers,
close tabs, or delete controller records. Only then remove the exact disposable
`$PROOF` directory. Never delete it while extensions are live, reuse its bindings,
or clean other runs. Preserve sanitized human findings alongside this prototype
before recommending anything for #38. Current recommendation: **core mechanism
demonstrated**, including fresh explicit YOLO launches and the bounded
[app-background observation](delivery-proof.md#l3-app-background-delivery-observation);
complete sidebar-hidden verification before
claiming that condition.

[Archived evidence](delivery-proof.md#bounded-live-checks-and-cleanup-worktree-test-note).

## Installed adapter wiring

From `docs/delivery-proof/installed-adapter.md` (page since merged into [its family index](../delivery-proof.md#installed-adapter)). Implementation record moved here verbatim.

The existing explicit production **Enable Copilot Integration** action now
packages and writes the shared adapter and minimal native loader under
`~/.copilot/extensions/maestro/`, lifecycle/icon plugin skills, and a private
`Orchestration/bin/messaging.json` configuration. Validation app identifiers are
still denied installation, and app construction has no writes. Setup changes no
Copilot settings, shell files, host selection or other plugins. The global
extension discovery path and SDK import mechanism are documented by the inspected
Copilot SDK's `docs/extensions.md`; SDK resolution is CLI-owned, with no npm
dependency, separate Copilot client, credential read or permission callback.

Each new installed-controller spawn automatically creates an exclusive
launcher-owned binding for its exact node/session/generation/workspace, in an
ordinary working directory. The existing account/model pinning is required;
native-extension launch uses `--experimental`. The loader does not join or add
tools unless those environment identities match a private binding and the
CLI-supplied `SESSION_ID`. Existing coordinators have no launcher-bound session
and cannot receive. No adoption or hidden coordinator adapter is implied.

The same transport now supports `maestro_peers` and `maestro_send` for any
participating same-workspace peers, across sibling branches/runs, without
changing ancestor-only lifecycle authorization. Installed addresses add
`generation`. Sender/return addresses are bound, not caller-supplied; capabilities
never appear in tool output or native prompts. Tools expose participation, not
liveness. Before every tool use or native submission, the adapter rechecks its own
binding. Stale/removed identities fail closed. The unchanged fixture interface
continues to use `maestro_proof_*` and its historical two-peer address shape.

Native children own their sockets; normal provider exit retires the exact
binding/socket, with offline status/archive cleanup for interrupted supervisors.
No route is unlinked to make a duplicate launch work. Uninstall removes the
entry point and new-launch configuration, not live bindings/adapters. Conversation
replacement, restart or missing/unsupported CLI extension APIs do not trigger
adoption, restart, keystroke fallback or retries.

## Native delivery proof (#54, child of #38)

From [`docs/delivery-proof.md`](../delivery-proof.md). Dated status of the #54 proof moved here verbatim.

**Status: native A → B → A delivery observed after human permission approvals,
with unsent draft preservation and editability explicitly confirmed by the
human. A fresh explicit YOLO-launch exchange worked without approval clicks,
and a separate parent-controlled check observed app-background delivery. The
core mechanism is demonstrated, and the pages below list the remaining checks.**
Question: can two Maestro-launched visible Copilot sessions exchange native
prompts without touching human input or changing focus? Source inspection
cannot answer the UI question, and contract tests mock Copilot, so they are not
live proof.
