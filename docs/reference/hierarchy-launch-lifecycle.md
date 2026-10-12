# Managed hierarchy, launch, and close

Coordinators, interactive workers, launch contract, maestro_close. Short version: [README](../../README.md). Terms: [CONTEXT](../../CONTEXT.md).

## Sidebar layout

Coordinator explicitly registers terminal-backed run: coordinator
→ worker → nested-worker links become primary compact hierarchy.
Every worker is a genuine unfocused terminal tab in coordinator's current
CMUX pane/workspace. Rows show safe labels and explicit lifecycle state. Details
holds exact run, parent, worker, workspace, surface and generation IDs.
Select current row: uses existing typed CMUX Focus action. Each workspace
appears once. Explicit managed agents and remaining terminals share its outline. Exact
managed workspace/surface pair normally replaces its observed terminal row.
Fresh, unique live observation may prove different session ID on that pair.
Then observed session keeps own primary row. Unneeded old registrations and
their exact unprotected observed copies drop automatically in both views,
regardless of **Show ended agents**. Unrelated incomplete history never hides
current session. It never keeps unneeded old registration on screen.
Recorded failed turn qualifies only when exact original session is freshly
confirmed dead and current replacement is verified. Failed phase alone
never proves old work ended.

Ancestors and original-session content needed by known descendants, unresolved
attention or incomplete own evidence remain as **Work context**. Their actions
inspect that context, not replacement terminal. Each descendant keeps own
state, attention and supported navigation. Counts separate required
context from current agents. Both views put current content before old context.
Captured focus actions stay bound to original workspace and surface.
After move, use newly rendered row.

This is presentation filtering. Not deletion, not session termination, not inferred
end state. Stored registrations, observations and history preferences stay
unchanged. Missing, stale, denied or ambiguous replacement evidence keeps
conservative view. Names, paths and guessed relationships never establish
ownership.

Installed skill exposes `launch-coordinator`, `launch-settings`, `status`,
`focus`, and `archive`. `register` and exact stale-surface `recover` remain for
legacy lifecycle ownership. Registration is not messaging adoption.
Start new managed coordinator with explicitly selected initial account and
model. Public `maestro_identity` tool reports actual session/account
without credentials. Native `maestro_spawn` reads that session's current account
for each child. It keeps explicit model selection and permission bounds.
Saved account defaults and unrelated Git authentication never select child's
subscription. Missing identity/API/credentials fail before terminal creation.
Current credential resolver uses GitHub CLI's keychain-backed account
store. Authenticate required account there once. Copilot-only login is
not silently imported or replaced with another GitHub CLI account.
Ordinary shell `spawn` cannot establish that evidence and refuses. Source-only
disposable proof compatibility is not production fallback. **New workers are
interactive Copilot sessions**, launched with `--interactive` and initial
task. Their terminal is normal conversation: humans can type follow-ups and
answer permission/questions directly. Completing task does not close it.
Copilot itself owns terminal I/O, including Ctrl-C. No interactive
supervisor. No captured JSON stream. Observed process exit never claims task
success. New workers cannot be
launched in headless mode. Never substitute invisible SDK tasks for
visible Maestro roles when startup fails.

Native `maestro_close` requests closure of one explicitly authorized, currently
owned direct child. It uses exact `workerId`, `workspaceId`, `surfaceId`,
`sessionId` and `generation`. It validates private native authority, process and
session-source anchors, current workspace membership and launch fences. Then it
sends one initial stock CMUX `surface.close` with documented Boolean
`force: true`, selecting its noninteractive route. This is not public toggle or
escalation after refusal. No sidebar control or host change involved.
Inherit stock host refusals, including last terminal. This is not UI-close
parity. Earlier CMUX 0.65 requests omitting the field returned
`confirmation_required`. Tagged source confirms false default. Source
contract is corrected. Installed/live proof remains separate. No retry,
force-after-refusal or confirmation fallback.

Omitted `scope` or `"scope": "target-only"` keeps that single-target contract.
Explicit `"scope": "subtree"` captures exact child's private descendants
once. It attempts safely admitted targets descendants-first, at most once.
Refused or unknown descendants do not block independently valid siblings or
parents. Every selected identity appears in `results`, with `attempted`,
`outcome`, compact `reason`, and `removal: "unconfirmed"`. New children and
replacement identities never enter the pass. 45-second budget and five-second
target windows leave remaining targets explicitly not attempted. Oversized
complete result plan or unrepresentable numeric generation refuses before host
effects, keeping existing numeric wire without rounding identities.
Missing captured sessions are refused individually. Loss of invoking worker's
stored session between targets keeps prior results and refuses remaining
targets, without changing shared native authorization. Pre-dispatch expiry is not
an attempt. Malformed host text after dispatch remains unknown. It does not erase
prior results or stop valid remaining targets. Existing 60-second,
65,536-byte adapter transport remains unchanged. Synthetic source/transport
coverage does not replace separately authorized disposable live-host proof.

`closeAccepted: true` with `removal: "unconfirmed"` means only local request
acceptance. No disappearance wait, retry, provider shutdown, typing or
force-kill fallback. Timeout/cancellation/lost replies remain uncertain. Records,
unselected descendants and resource accounting stay intact. Missing or changed
provider/source evidence refuses, rather than closing possibly repurposed
shell. Separate preflight and UUID-based host close are **not atomic
session/generation fencing**. See the
[installed lifecycle guide](../../.agents/skills/cmux-maestro-orchestrate/SKILL.md#request-an-owned-child-or-explicit-subtree-close)
for exact tool shape and source limits.

Interactive startup uses `surface.create` with `initial_command`, not
CLI `new-surface --command`, which queues input behind interactive shell
initialization. Only caller's executable search path is added to startup
environment. Credentials are not passed through host creation request.
Host may rewrite that environment. So launch record also captures
validated absolute Copilot executable and caller search path privately.
One-shot non-login shell sources private launch environment, restores
that PATH and immediately `exec`s absolute Copilot executable with fresh
`--session-id` and `--interactive` prompt. Pinned subscription credentials are
resolved through existing bounded GitHub CLI lookup directly into process
environment. Never persisted or included in host command.
Necessary authorization, setup, create/attach and individual I/O remain bounded.
**Return is immediate after exact terminal creation/ownership:** no supervisor
acknowledgement, sleep, startup observation window, hook/model/provider wait or
optional readiness gate. Creation acceptance does not establish provider start.

One reusable prompt wrapper keeps original task verbatim. It explains
human interaction, exact `maestro_peers`/`maestro_send` discovery and genuine
envelope-sender replies, fire-and-forget uncertainty and prohibition on
terminal-input fallbacks. It supplies genuine coordinator address only when
available. Agent begins task without startup acknowledgement.
`/maestro-minion` and other slash skills are not launch dependencies.

Private native bindings are prepared **before** creation. After joining its
exact CLI-owned conversation, native adapter independently records
session/generation/surface and exec-preserved provider PID/start identity,
verifying process ancestry. This can occur before or after caller attachment.
Neither side waits for other. Hooks remain independent observers, not tool
providers. Missing/late hooks or native observation are unknown, not death.
If caller disappears or creation/attachment is ambiguous, lease,
private setup and capacity stay retained: Copilot may already be running.
No failed caller may guess that it prevented execution.

Managed interactive rows and workspace counts use fresh, uniquely exact
session/workspace/surface observations in both `launching` and `turn-running`,
even when controller metadata is older than its 60-second freshness budget.
Native process observation alone never means Working. Absent, stale or ambiguous
work evidence remains unknown. Git provenance keeps own freshness budget.
Fresh session activity does not refresh old branch, worktree or change count.

Launch receipts and private `status` distinguish evidence below. This
applies to interactive sessions and preserved legacy bounded workers. Neither
receipt is turn-completion boundary.

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
these phases. Inventory/probe errors remain unknown, not death. Confirmed
missing surface can cancel unchanged **legacy** unclaimed lease. Direct
launches cannot infer Copilot never ran: unresolved leases stay retained,
and missing process anchor blocks reclamation. Status captures process and host
probes outside global write lock. Then it applies only identity/lease-matched
evidence under lock. Launch receipts revalidate current ownership and
lease at attachment, without startup probes. Changed identities reset status
probe facts to `null`. Retained facts keep their capture timestamp. Cancelled
legacy leases refuse late execution. Direct native observation refuses
foreign surface/session/generation/token/process identities without adoption.
No duplicate spawn, focus change, terminal input or automatic process cleanup
is attempted. Pending launches retain their credential and capacity slot.
If create reply is lost, unidentified possibly-created terminal retains
its slot and blocks archive/recovery. Missing surface identity is not proof
that no resource exists. Reconcile original launch. Never retry it.
Verify exact surfaces, native tools, and returned evidence separately.
Root callers must retain private custody receipt even when startup returns
`ok: false`. Its control token remains private. Controller keeps bounded
setup/attachment errors in private receipts and lifecycle diagnostics. Provider
exec or extension errors remain visible in terminal. Absent native
observation cannot become controller success or failure claim.
Managed coordinators have own controlled sessions and runs. Existing
conversations are not converted. Live or uncertain legacy supervisor blocks
new coordinator schema. Launcher fails rather than interrupting it.
Existing provider sessions need not end when old supervisors
already exited. Resource reconciliation retires only unchanged records
with absent surfaces and proven process exit. Never retires active launch lease.

Lifecycle `follow-up` command remains refused for interactive workers.
Participating peers use native fire-and-forget messaging below instead. No prompt
is injected into terminal input. Close interactive Copilot normally
before archiving. Archive does not interrupt it. Existing legacy workers are
preserved and visibly labeled **Legacy worker**. Never silently converted.
