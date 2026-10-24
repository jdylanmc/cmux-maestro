# Relaunch restore

How Copilot tabs come back after CMUX quits or crashes and opens again. Rules: [ADR 0024](../adr/0024-resume-ended-managed-sessions-after-relaunch.md), [ADR 0025](../adr/0025-copilot-sessions-started-in-cmux-are-born-managed.md). Terms: [CONTEXT](../../CONTEXT.md).

## What survives a relaunch

CMUX restores windows, workspaces, and surfaces with the same UUIDs. It does not restore processes. Each Copilot tab comes back as a plain shell unless something restarts Copilot in it.

## Born-managed roots

A session you started in CMUX is a born-managed root. CMUX's own Copilot restore runs `copilot --resume <id>` in the restored surface. The Maestro extension then joins the resumed session and asks the controller to enroll it. The controller finds the node recorded for that exact session ID and resumes it as the next generation of the same node, in the same run. The root keeps its children. The same happens when you run `copilot --resume <id>` yourself, including after `/exit`; if the node was archived, the session enrolls as a new root.

Copilot 1.0.98 `--resume` first joins extensions to a startup placeholder: a session with a fresh ID that it never saves. About a second later it replaces the placeholder with the resumed session in the same process and joins extensions again. The placeholder has no `~/.copilot/session-state/<id>` directory, so the controller refuses it with `session-not-persisted` and records nothing: it takes no surface, archives no run, and does not hold the Copilot process (#261).

The controller resumes only when all of these hold:

- The node is a born root, and the session ID matches exactly. A Maestro launch refuses with `session-previously-managed`; it resumes through its binding instead.
- The workspace and surface match the record exactly, and the provider's controlling TTY is that surface's TTY. A different surface refuses with `surface-mismatch`; a TTY mismatch with `cmux-identity-unverified`.
- The session has a saved session-state directory. A startup placeholder has none and refuses with `session-not-persisted`.
- The prior generation ended. An `/exit` does not block a later resume (#261): CMUX's restore forgets an `/exit`ed session, so only a human's own `copilot --resume` brings it back. Maestro's extension records a Copilot `SessionEnd` for its exact session only when it is `/exit`.

  Copilot 1.0.98 reports reason `user_exit` for `/exit`, a terminal hangup, a closed terminal, and `SIGHUP` or `SIGTERM` alike, so the reason alone cannot tell a CMUX quit from `/exit`. Measured in a disposable Copilot (spike on #252): every signal or hangup sends the extension `SIGHUP` before `SessionEnd`; `/exit` sends only `SIGTERM`. So the extension records nothing once it has seen `SIGHUP`. `SIGKILL` delivers no `SessionEnd` at all. On `SIGTERM` the extension waits up to two seconds for the record, and a Maestro launch's binding clear, to land before it exits. The record is written first; the clear has one second. If Copilot changes this order, a quit could be recorded as an exit; CMUX then forgets the session, and a manual `copilot --resume` still re-enrolls it.
- The recorded process has ended, or the session ended in this same Copilot process and came back to it. The new provider (or its direct child) holds the session's `inuse.<PID>.lock`, and no other live process does. Copilot writes that marker only at the resumed session's first prompt, so the session reports `awaiting-first-prompt` until then and enrolls at the first hook event after it (the prompt, or the `sessionStart` that follows it). A crashed provider's stale marker is ignored. A live marker of another process refuses with `session-live-or-uncertain`. This is checked again inside the state lock, right before the commit.
- The session's current account matches the recorded account. A different account refuses with `account-mismatch`, and `maestro_readiness` names the recorded login. Sign in to that account and restart the session. Nodes without a recorded account refuse with `account-unrecorded`. If Copilot does not report the session's account in time, the resume refuses with `account-unverified`.
- A root whose surface had been retired (`resource-retired`) needs a free workspace slot to come back. Otherwise it refuses with `capacity-unavailable`.
- No other node holds the resumed Copilot process. Otherwise it refuses with `provider-already-enrolled`.

The node keeps its run and children. Its provider executable and PATH are refreshed from the resumed process. An ended node's recorded executable is read from its launch archive (`control/retired/<node-id>.json`) when compaction moved it there. The old generation's peer route and capability are retired; the new generation gets a new route. Peers see the new address. Addresses are exact per generation: a child's task prompt names its coordinator's address at launch, and that address stops working once the coordinator resumes. The child finds the coordinator's current address with `maestro_peers`.

Policy: CMUX's own restore replays the session's original command line, so the born root keeps whatever flags the human started it with. Maestro's recorded policy for a born root is the default with no grants, which its children inherit.

Any refusal leaves the session running but unmanaged, and `maestro_readiness` explains it in plain words. Definitive decisions for a session in a Copilot process are recorded and repeated. The second refusal among `awaiting-first-prompt`, `session-not-persisted` and `enrollment-busy` is final per join; account/provider deferrals neither consume nor reset this shared budget. `account-unverified` is not a final decision: a later exact-session hook re-observes the account and asks again, without account fallback. Older recorded account-unverified refusals are reconsidered with all admission checks. A `provider-already-enrolled` refusal is also checked at later exact-session hooks, but admission still requires that no node holds the exact provider; missing custody is not release. Concurrent hooks share one attempt; there is no scheduled retry.

An exact `user_exit` callback received during extension join is retained as one sanitized pending end, never hook content. It is delivered once after the runtime's observer is installed and startup settles, including a runtime startup failure after observer installation. The existing bounded shutdown wait is armed before join; a definitive refusal or initialization failure settles it when no observer can be installed. A hangup still prevents recording. These synthetic-ordering repairs (#348) do not establish whether an interactive CLI `/resume` delivers the old session's callback; without a recorded exact end, provider conflict still refuses.

CMUX's own restore needs its Copilot hooks. `cmux hooks copilot install` fails on Copilot 1.0.98 because Copilot writes comments in `config.json`. Maestro's setup therefore installs `~/.copilot/hooks/cmux-maestro-cmux-hooks.json`. It declares `SessionStart`, `Stop`, `Notification`, and `SessionEnd` with CMUX 0.65.1's exact `cmux hooks enqueue copilot <event>` commands and guards: they run only inside a CMUX surface, and never when `CMUX_COPILOT_HOOKS_DISABLED=1`. Setup writes it only once the plugin is verified (or in the same checkpointed transaction as the other owned files for a coordinated install), refuses (and names) a file at that name that Maestro did not write, and leaves every other hook alone. A file that appears at that name while setup runs, after the plugin is already published, is still never replaced: setup reports a named incomplete result, and running setup again (once the file is moved away) finishes. Setup also refuses before changing anything when the four CMUX hook rows (and the observer's three, if not yet reported) would push Copilot's hook discovery past the 256 rows Maestro can verify. Uninstall removes it only when its bytes are a manifest Maestro shipped; a file it did not write stays and is named. CMUX's `PreToolUse` Feed bridge is not included; restore needs only these four events. Setup checks the file on disk; Copilot loading it is a live check. Sessions started before setup are not recorded; restart them once.

## Maestro-launched sessions

Children from `maestro_spawn`, and coordinators from `launch-coordinator`, do not use CMUX's own restore. The owner approved the binding for `launch-coordinator` roots too: they carry recorded flags just like children. Their launch sets `CMUX_COPILOT_HOOKS_DISABLED=1`, so CMUX's hooks never record them. CMUX's restore drops launch flags, which could drop deny rules or the parent link.

Instead, each launch attaches a resume binding to its exact surface:

```text
cmux surface resume set --workspace <workspace> --surface <surface> --cwd <dir> \
  --kind agent --checkpoint <session> -- <controller> resume <session>
```

Only launches with Maestro messaging get a binding (delivery-proof fixture launches do not). If the session already ended with `/exit` before the binding landed, Maestro clears it at once. Archiving a run clears its launches' bindings and removes every generation's launch script. A resumed `launch-coordinator` root keeps its launch receipt's token for the owner commands `status`, `focus`, and `archive` only; each resumed provider gets its own token, and every other command needs it. The binding holds identifiers only. It holds no token, prompt, or temporary path. `<controller>` is the installed `~/Library/Application Support/CMUXMaestroPreview/Orchestration/bin/cmux-maestro-orchestrator`. It runs through its own `#!/usr/bin/env python3`, so the binding and its approved prefix survive Python and app upgrades. The session ID is the only varying argument, so one approval of `<controller> resume` covers every launch. The launch receipt reports `resumeBinding: "set"` or `"unavailable"`.

When the session ends by `/exit` (a Copilot `SessionEnd` with no `SIGHUP` before it; see [Born-managed roots](#born-managed-roots)), Maestro's native extension records the end for that generation and clears that surface's binding with `cmux surface resume clear`, like CMUX does for its own records. It sends only identifiers and reads nothing from the hook input. If the clear fails, the binding stays, but the resume still refuses a user-ended generation. A quit, hangup, or signal is not trusted as an exit. The extension is Maestro's own SessionEnd observer: `CMUX_COPILOT_HOOKS_DISABLED` silences only CMUX's hooks, never Maestro's extension or its identity hook. The resume refuses when the Maestro integration that carries this observer is not installed. An exit during the session's first moments is held until its provider is observed, then recorded. A quit or crash records no end, so the session resumes at the next relaunch.

On relaunch, CMUX types that command into the restored shell. The resume command checks:

- The terminal's `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` match the record. CMUX confirms the surface, and the command's controlling TTY is the TTY CMUX reports for it.
- Exactly one node has that session ID, it is a Maestro launch, and its route configuration is unchanged.
- A launch whose surface had been retired (`resource-retired`) needs a free workspace slot. Otherwise it refuses with `no free workspace slot`.
- The recorded process has ended, and no live process holds the session's `inuse.<PID>.lock`. A marker older than the process now using its PID is stale.
- The recorded launch policy is valid. It is replayed as is: same model, allow rules, deny rules, and mode. Nothing is added.
- Copilot resolves: the recorded executable, or `copilot` on this terminal's `PATH` after an upgrade. Otherwise it refuses with `Copilot is not installed on this terminal's PATH`.

Then, inside the state lock, it checks all of this again and records the next generation with a new control token and itself as the provider process; it publishes a new peer route and retires the old one. Only then does it read the recorded account's credential through GitHub CLI, check the terminal and session lock once more, and replace itself with `copilot --resume=<session>`. The token goes into the process environment only. It passes no `--name`, `--session-id`, or prompt. If anything fails after the reservation, that generation is recorded as never started, its route is retired, and the next relaunch decides again. A Copilot that exits early leaves an ended node that the next relaunch can resume.

On any refusal it prints one line, such as `Maestro did not resume this session: recorded account work-user is not signed in to GitHub CLI.`, and the shell stays. It does not retry.

### One-time approval in CMUX

CMUX runs a custom resume binding only after a human approves its command prefix. Open **CMUX Settings > Terminal > Resume Commands** and approve the prefix `<controller> resume` once (or choose "apply to all commands starting with" when CMUX asks; that choice may be scoped to the folder). Maestro never approves it for you. CMUX also needs **Resume agent sessions** (`terminal.autoResumeAgentSessions`) on.

## Sidebar rows

A restored tab used to show as `Terminal`. The sidebar shows an unmanaged Copilot row only after Maestro's observer hook binds the session to its surface. A restored session can show the CMUX surface title until that binding exists. Live checks must confirm when the hook binds a resumed session.

A born-managed or resumed managed session is expected not to wait for the hook: the controller's projection names its exact surface, so the sidebar should show a managed Copilot row as soon as the projection is read. This is not yet confirmed in a live CMUX (see [Live checks](#live-checks)). A born root's row shows its Copilot session name under ADR 0022's rules: one live, fresh observation of that exact session in that workspace and surface, or the last name read during observation loss while its grace lasts.

Copilot 1.0.98 defers a resumed session's `sessionStart` hook and its `inuse.<PID>.lock` until the first prompt, so the observer hook cannot bind a relaunched session before then. Until the observer has any evidence of that session, a running born root's row takes its name, and its pet, from the exact session UUID in the controller's projection (ADR 0022 amendment, #261). Otherwise it shows `Copilot session`.

## Known gaps

- If you also installed CMUX's Copilot hooks yourself (in `config.json` or another hook file), both sets run and CMUX receives each event twice. Remove your copy and keep Maestro's file, which setup maintains.
- CMUX's Copilot restore keeps `--name` and adds `--resume`. Copilot 1.0.98 refuses that pair. A session started with `--name` does not come back through CMUX's restore. Rename the session inside Copilot instead.
- Sessions launched through wrappers such as Agency are not covered.
- Launches made before this change have no binding and do not resume.
- A session started before the Maestro integration was installed enrolls only at its next extension join (`/clear`, `/resume`, or an extension reload you run). Maestro never triggers one.
- After `/clear` or an in-session `/resume`, the new session takes over the tab only when the previous session's end was recorded; otherwise it stays unmanaged with `provider-already-enrolled`. If the previous root still has live children, it releases the tab and keeps them: no row shows that run, its children appear as their own observed sessions, and the new root cannot close them. A later `/resume` of the released session in another tab refuses with `surface-mismatch`.
- Before its first prompt, a new or resumed session reports `awaiting-first-prompt` and its Maestro tools refuse.
- If a second tab resumes a session that is already managed, the first tab loses Maestro authority as soon as the second holds the session lock (`session-custody-lost`), and the second is refused. Neither is managed until one of them joins again (extension reload, `/resume`, or a relaunch) as the sole holder.
- An unmanaged restored session can show the CMUX surface title (for example `Terminal`) until Maestro's observer hook binds it.

## Live checks

Nothing in this document has been verified in a live CMUX yet. Run these before calling relaunch restore done. CMUX's CLI refuses processes started outside CMUX, so a human (or a verifier driving the CMUX window through Computer Use) runs them inside CMUX.

Prerequisites:

- Maestro production setup has run, including CMUX's Copilot hooks file. Remove any CMUX Copilot hooks you installed yourself, so CMUX does not receive each event twice. Confirm Copilot lists the four hooks from `cmux-maestro-cmux-hooks.json` as enabled.
- **Resume agent sessions** (`terminal.autoResumeAgentSessions`) is on.
- The prefix `<controller> resume` is approved once in **CMUX Settings > Terminal > Resume Commands**.
- Copilot sessions are restarted once after setup.

Cases (quit CMUX with ⌘Q and reopen it unless noted):

1. A session you start after setup: `maestro_readiness` says managed, it sees its peers, and its recorded account is yours. Its row shows its session name.
2. A session that was running before setup stays unmanaged until its next extension join; after `/clear` (or an extension reload you run) it reports managed.
3. After relaunch, the born root comes back managed as generation 2 and its row shows its session name, not `Terminal`.
4. A `maestro_spawn` child comes back on its exact session after relaunch, keeps its deny rules, sees its peers, and its row shows its launch label. Send it a message and close it from its parent.
5. An unmanaged restored session's row: record what it shows before and after the observer hook binds it.
6. With two CMUX windows open, each window's rows come back in their own window.
7. `/exit` a born root, then run `copilot --resume <id>` by hand: it comes back managed as the next generation. Relaunch CMUX after an `/exit` without resuming: the session does not come back.
8. ⌘Q with a born root and a child running: neither records an end (`sessionEndedGeneration` absent); both come back managed.
9. Sign in to a different account than the born root recorded, then relaunch: it stays unmanaged with `account-mismatch` naming the recorded login.
10. `/exit` a child, then relaunch: it does not come back.
11. A live session: running its resume command refuses. A signed-out recorded account: one line naming it.
12. No Maestro-launched tab (`maestro_spawn` child or `launch-coordinator` root, which run with `CMUX_COPILOT_HOOKS_DISABLED=1`) appears in `~/.cmuxterm/copilot-hook-sessions.json`, while each born root does have its CMUX restore record there. `cmux surface resume show --json` holds no token.
