# Native delivery proof (#54, child of #38)

**Product scope update:** the user confirmed conversion of this proof into the
installed feature, in one final pull request with its findings. The prototype-only
restriction is superseded for the installed adapter, existing controller/setup/
resources, tests, `/cmux-maestro-native:maestro` skill and associated documentation. The historical
proof below remains reproducible; old `deliveryProof` records and `a`/`b` routes
remain compatible. No live proof sessions are adopted, restarted or modified.

**Status: native A → B → A delivery observed after human permission approvals;
unsent draft preservation and editability explicitly confirmed by the human.
Fresh explicit YOLO-launch exchange also demonstrated without approval clicks.
App-background delivery observed in a separate parent-controlled check.
Core mechanism demonstrated; remaining checks are listed below.**
Question: can two Maestro-launched visible Copilot sessions exchange native
prompts, without touching human input or changing focus? Source inspection cannot
answer the UI question. Contract tests mock Copilot and are not live proof.

## Contract and boundary

The extension calls `joinSession({ tools })`, verifies the joined session against
its launcher-written binding, and calls `session.send({ prompt, mode: "enqueue" })`.
It supplies no account, model, permission handler, user-input hook, or sensitive
environment request. Copilot owns scheduling. There is no composer manipulation,
focus check, terminal input, busy-state scheduler, receipt, acknowledgement,
resend, completion tracker, or periodic timer.

Each disposable extension child owns one local Unix socket. There is no separate
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
conversation requires fresh fixtures; no stale socket is automatically unlinked.

## Source grounding

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
turn returned “No response was returned”; it did not prevent the later exchange.
External MCP startup warnings were also present. That exchange alone did not
verify draft preservation or every bounded live check below.

### L3 live draft-preservation observation

The human placed `HUMAN-DRAFT-54` unsent in B. The parent then injected one native
test message through the disposable A capability route to B, using private
same-user fixture bindings; B received the native `user.message`. This was
**parent-controlled, harness-origin injection, not a message authored by A**,
unlike the first real A → B → A agent-tool exchange above. No terminal-input or
focus operation was used.

The human explicitly confirmed **“Preserved exactly and still editable”**, then
“yeah it worked” and “brilliant”. This confirmation, not screenshots, is the
evidence for preservation and continued editability of the unsent draft.
This draft result alone does not establish app-background or sidebar-hidden
delivery; the separate app-background observation follows.

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
**Sidebar-hidden remains unconfirmed**; this check does not establish it.

### L4 fresh YOLO-launch observation

The parent reported a successful autonomous exchange using fresh fixture
`live54b` in a new background workspace. Both new sessions launched with
`--delivery-proof-yolo` and `--delivery-proof-experimental`. B received challenge
`cedar-54-2`; A's native session rendered final answer `violet-54-2` at
`2026-09-21T21:58:20.459Z`. The parent harness performed no approval clicks,
terminal input, or resends. These were fresh sessions, not reuse of the first
pair whose permissions had been changed by human interaction.

**Fresh explicit YOLO-launch verification is demonstrated.** This establishes
the per-spawn opt-in, not full parent-permission inheritance. A background
workspace does not establish the application's foreground/background state or
the sidebar-hidden condition. The separate L3 check above supplies app-background
evidence; sidebar-hidden remains unconfirmed.

The [discovery foundation](agent/discovery/issue-38-shared-agent-interaction.md)
preserves the Orca, Paseo, Herdr, and CMUX revision-pinned comparisons and their
source-versus-runtime distinctions. This proof does not redo that research.

### Managed skill-source mitigation (pending installed verification)

Parent research against the exact `1.0.87-0` executable found the installed
`cmux-maestro-native` `1.1.0` plugin enabled in CLI discovery, while a fresh
interactive session's skill registry omitted `maestro`. Native messaging worked;
bare skill-tool invocation failed. The upstream cause is not established.
`joinSession` with unspecified discovery/plugin options does not justify resetting
configuration. The tool identifier is `maestro`, not
`cmux-maestro-native:maestro`; the latter is the slash UI namespace.

The bounded mitigation uses the existing supported `--plugin-dir`, whose source
loading and `sessionManager.setAdditionalPlugins` occur before interactive session
creation. Setup adds `pluginDirectory` to its private `messaging.json`, pointing
only at the existing `Copilot/plugin` beside `Orchestration`. The launcher verifies
the exact private, canonical source, `cmux-maestro-native` `1.1.0` manifest and
readable Maestro skill before reservation and again before launch. It appends
`--experimental --plugin-dir <absolute-installed-plugin-path>` only for managed
messaging participants. Pins, denies, coordinator-only explicit `--allow-all`,
and inherited terminal I/O remain unchanged.

The new field stays in setup configuration, **not stored node metadata**. Both
old and new workers keep `{version, routes, extension}` so already-running old
controllers remain compatible with newly written state. Old three-field setup
configuration is readable; a new managed spawn requires a setup upgrade.
Existing exit/route cleanup does not depend on the plugin directory. Normal,
source-only and historical proof launches do not receive `--plugin-dir`.

Contract tests do not establish live registry availability. **Parent next step:**
reinstall the updated app through the approved normal flow, explicitly enable
integration, then create a fresh managed session using pinned launch settings.
Verify its exact installed `--plugin-dir`, invoke `{"skill":"maestro"}`, and
confirm `/cmux-maestro-native:maestro` in the interactive slash UI. Preserve the
existing worker sessions; do not reload, adopt, or restart them. This patch makes
no new installed-runtime success claim.

## Parent-only preparation and live launch

Do not run these as an unattended test. Use a **new disposable CMUX workspace and
coordinator terminal**, with its actual `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID`.
No existing provider sessions are attached, reloaded, or restarted.
The coordinator is human-operated; both providers are new Maestro workers.

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
`--delivery-proof-fixture`; normal workers gain no permissions. This is not
parent-permission introspection or inheritance, a permission callback, or a
persistent Copilot settings change. Native trust or other startup prompts are
not automatically answered.

Verified against the installed CLI's `copilot --help` and
`copilot help permissions`: `--allow-all` and `--yolo` both mean
`--allow-all-tools --allow-all-paths --allow-all-urls`; tool denial rules always
take precedence, including over `--allow-all-tools`. Existing `--deny-tool`
arguments remain unchanged. Recheck provider semantics before using another
version; do not drop denies if they cannot be preserved.

**Review correction R1:** the original source opt-in checked descendant explicit
allow lists but did not account for the later `--allow-all` flag. A worker actor
with only `read` could request proof YOLO and bypass its grant bound. Both the
preserved `--delivery-proof-yolo` and installed `--yolo` now require a coordinator
actor before credential resolution or reservation. Negative worker-actor tests
cover both forms; denies and the coordinator's explicit opt-in remain intact.
This is deliberately not full parent-permission inheritance.

Both calls use the existing pinned interactive launcher, native terminal I/O,
exact session ID, and existing explicit tool-policy rules. The opt-in is stored
as `deliveryProof.yolo`; old `{fixture, experimental}` nodes remain valid and
default to no YOLO. The proof options are
source-checkout-only wiring; nothing is installed over the active integration.
The existing controller store still owns these new workers; no alternate
authentication or replacement control store is created.

## Bounded live checks

After both adapters load, the human asks A to send a single synthetic message,
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

## Local validation and cleanup

```sh
python3 scripts/test-delivery-proof.py
node --test scripts/test-delivery-proof.mjs
python3 scripts/test-cmux-maestro-orchestrator.py
```

The first two suites use disposable files and local sockets under `.build/`,
with mocked native sessions/launcher processes, and remove their own fixtures.
No dependencies are added. Repository CI's other declared checks remain
unchanged and belong to the parent’s complete validation pass.

Parent validation before the permission correction: **all 9 declared repository
CI command steps passed on first attempts**, including **45/45** orchestrator
tests and **7 Python + 7 Node** proof tests. The earlier worker-only 44/45 result
came from forcing `TMPDIR` inside this Git worktree, not the normal parent run.
The permission correction adds targeted Python coverage for default/opt-in
launches, preserved denies/pins, serialized opt-in, refusal outside proof, and
old stored-node compatibility. Full post-correction CI belongs to the parent.
Post-correction targeted validation: **12/12 Python proof tests passed**;
`git diff --check` passed. No live endpoints were operated or reloaded.

After the human stops the two exact proof sessions, use existing owned-worker
archive/recovery guidance as applicable. The adapter does not kill providers,
close tabs, or delete controller records. Only then remove the exact disposable
`$PROOF` directory. Never delete it while extensions are live, reuse its bindings,
or clean other runs. Preserve sanitized human findings alongside this prototype
before recommending anything for #38. Current recommendation: **core mechanism
demonstrated**, including fresh explicit YOLO launches and the bounded
app-background observation above; complete sidebar-hidden verification before
claiming that condition.

## Installed implementation and remaining acceptance

### Parent-reported installed exchange and skill-name correction

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
subsequently listed the installed messaging skill as `name: maestro`,
`source: plugin`, `enabled: true`. The native loader identifies its plugin as
`cmux-maestro-native`, while `skillsInvocationName` returns the bare skill name.
Thus the correct split is **slash command `/cmux-maestro-native:maestro`** and
**skill-tool argument `{"skill":"maestro"}`**. Lifecycle/icon slash references
remain qualified. Frontmatter, installed folders, manifest identity and permissions
are unchanged; no global alias or duplicate skill was added.

**Initial missing-inventory observation remains unresolved.** The failing
session's startup model-visible inventory did not contain the messaging skill,
whereas later read-only discovery did. The permitted comparison found no
installer/runtime root or registered-plugin discrepancy; it did not establish
the cause of that startup/current-inventory difference. Neither the namespace
correction nor current discovery proves live skill execution. The parent is
performing one fresh authorized **bare-name** validation; its result remains
pending here. No private registry contents, account/model data, credentials or
full debug transcripts are included in these findings.

**Implementation checkpoint:** runtime/setup/resource wiring and their targeted
contracts are implemented. The user-confirmed intent is stored unchanged at
`skills/maestro/intent.md`; the simple repo-native `SKILL.md` beside it teaches
discovery/send/reply and cross-references the existing lifecycle skill, without
an atomic-skill framework or tool-permission frontmatter grants. The source folder
is an explicit Xcode resource mapping to `Contents/Resources/maestro/`; setup copies
its `SKILL.md` into the installed plugin's `skills/maestro/`.
The parent still owns final complete CI, independent review and installed live
validation. Targeted build and test evidence is recorded below.

Targeted implementation validation:

- `./scripts/build-unsigned.sh`: **BUILD SUCCEEDED**; both namespace checks passed.
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

The existing explicit production **Enable Copilot Integration** action now
packages and writes the shared adapter and minimal native loader under
`~/.copilot/extensions/maestro/`, the `/cmux-maestro-native:maestro` plugin skill, and a private
`Orchestration/bin/messaging.json` configuration. Validation app identifiers are
still denied installation; app construction has no writes. Setup changes no
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
and cannot receive; no adoption or hidden coordinator adapter is implied.

The same transport now supports `maestro_peers` and `maestro_send` for any
participating same-workspace peers, across sibling branches/runs, without
changing ancestor-only lifecycle authorization. Installed addresses add
`generation`. Sender/return addresses are bound, not caller-supplied; capabilities
never appear in tool output or native prompts. Tools expose participation, not
liveness. Before every tool use or native enqueue, the adapter rechecks its own
binding; stale/removed identities fail closed. The unchanged fixture interface
continues to use `maestro_proof_*` and its historical two-peer address shape.

Native children own their sockets; normal provider exit retires the exact
binding/socket, with offline status/archive cleanup for interrupted supervisors.
No route is unlinked to make a duplicate launch work. Uninstall removes the
entry point and new-launch configuration, not live bindings/adapters. Conversation
replacement, restart or missing/unsupported CLI extension APIs do not trigger
adoption, restart, keystroke fallback or retries.

### Parent-owned installed-product verification

No installed replacement or provider launch was performed by the implementation
worker. After full CI/review and explicit setup approval:

1. Build/package the normal app; use only its existing explicit production setup
   action. The validation copy must still refuse installation. Confirm the app
   bundle contains `adapter.mjs`, `extension.mjs`, and `maestro/SKILL.md`; inspect
   only sanitized `launch-settings` (`ready` and `messagingInstalled`), not secrets.
2. In a fresh disposable workspace, use existing lifecycle registration/spawn
   guidance and an ordinary working directory. Do **not** run fixture preparation
   or set test-mode overrides to claim installed behavior. Launch three fresh
   participants; permit default native trust/tool prompts normally, or use
   coordinator `--yolo` only when explicitly approved.
3. Verify `/cmux-maestro-native:maestro` is discoverable and `maestro_peers` returns the other two
   participants, not an unmanaged terminal, old proof session, or other workspace.
   Ask one participant for one ordinary send/reply through `maestro_send`.
   Verify exact-generation return addresses and no implicit lifecycle authority.
4. Reuse the bounded live checks above, keeping draft preservation, app-background
   and sidebar-hidden observations separate. Historical live proof demonstrates
   the mechanism, **not** installation or new multi-peer acceptance. Sidebar-hidden
   remains unverified until explicitly observed.
5. Close only these new sessions normally. Verify their routes disappear and
   unavailable recipients do not cause retries or focus/input changes. Never
   touch the four preserved proof sessions or the existing human draft.

For safe **offline isolated acceptance now**, rerun the setup contract test and
adapter suites in this worktree. They exercise private disposable `.build/` paths,
the installer file writer, exact tool registration and native enqueue contracts
with mocked sessions, and clean only their own fixtures. The unsigned bundle can
be inspected without opening or installing it. Do not bypass its production
mutation guard to claim a live installed test. Live acceptance is a separate
parent-authorized action using fresh sessions, not an excuse to reuse or reload
the preserved proof routes.

Contract tests cover the generalized adapter, inert/mismatched loader, three-peer
send/reply, foreign workspaces, stale generations, revoked participation, strict
invocations, bound payloads, installer resources and preserved live routes,
coordinator-only YOLO, inherited route scrubbing, pinned launches and legacy
proof/state compatibility. These tests are registered in the existing CI command
steps; they do not assert native UI behavior or guaranteed delivery.
