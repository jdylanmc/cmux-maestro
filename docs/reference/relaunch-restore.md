# Relaunch restore

How Copilot tabs come back after CMUX quits or crashes and opens again. Rules: [ADR 0024](../adr/0024-resume-ended-managed-sessions-after-relaunch.md), [ADR 0025](../adr/0025-copilot-sessions-started-in-cmux-are-born-managed.md). Terms: [CONTEXT](../../CONTEXT.md).

## What survives a relaunch

CMUX restores windows, workspaces, and surfaces with the same UUIDs. It does not restore processes. Each Copilot tab comes back as a plain shell unless something restarts Copilot in it.

## Born-managed roots

A session you started in CMUX is a born-managed root. CMUX's own Copilot restore runs `copilot --resume <id>` in the restored surface. The Maestro extension then joins the resumed session and asks the controller to enroll it. The controller finds the node recorded for that exact session ID and resumes it as the next generation of the same node, in the same run. The root keeps its children.

The controller resumes only when all of these hold:

- The node is a born root, and the session ID matches exactly. A Maestro launch refuses with `session-previously-managed`; it resumes through its binding instead.
- The workspace and surface match the record exactly, and the provider's controlling TTY is that surface's TTY. A different surface refuses with `surface-mismatch`; a TTY mismatch with `cmux-identity-unverified`.
- The prior generation ended without an observed user exit. Maestro's extension records a Copilot `SessionEnd` for its exact session only when it is `/exit`. After that, a manual `copilot --resume` refuses with `session-ended`; it is the human's new start, not a relaunch restore.

  Copilot 1.0.98 reports reason `user_exit` for `/exit`, a terminal hangup, a closed terminal, and `SIGHUP` or `SIGTERM` alike, so the reason alone cannot tell a CMUX quit from `/exit`. Measured in a disposable Copilot (spike on #252): every signal or hangup sends the extension `SIGHUP` before `SessionEnd`; `/exit` sends only `SIGTERM`. So the extension records nothing once it has seen `SIGHUP`. `SIGKILL` delivers no `SessionEnd` at all. On `SIGTERM` the extension waits up to two seconds for the record, and a Maestro launch's binding clear, to land before it exits. The record is written first; the clear has one second. If Copilot changes this order, a quit could be recorded as an exit and the session would not come back managed; that fails closed.
- The recorded process has ended, and the new provider (or its direct child) is the only owner of the session's `inuse.<PID>.lock`. Any other marker, live or stale, refuses with `session-live-or-uncertain`. This is checked again inside the state lock, right before the commit.
- The session's current account matches the recorded account. A different account refuses with `account-mismatch`, and `maestro_readiness` names the recorded login. Sign in to that account and restart the session. Nodes without a recorded account refuse with `account-unrecorded`. If Copilot does not report the session's account in time, the resume refuses with `account-unverified`.
- The resumed provider started after the Maestro integration was installed, like any new enrollment. Otherwise it refuses with `session-started-before-install`.
- A root whose surface had been retired (`resource-retired`) needs a free workspace slot to come back. Otherwise it refuses with `capacity-unavailable`.
- The resumed provider started at most 120 seconds before it asks to enroll. A later request refuses with `enrollment-window-passed`. A login or trust prompt answered after that window leaves the session unmanaged.

The node keeps its run and children. Its provider executable and PATH are refreshed from the resumed process. The old generation's peer route and capability are retired; the new generation gets a new route. Peers see the new address. Addresses are exact per generation: a child's task prompt names its coordinator's address at launch, and that address stops working once the coordinator resumes. The child finds the coordinator's current address with `maestro_peers`.

Policy: CMUX's own restore replays the session's original command line, so the born root keeps whatever flags the human started it with. Maestro's recorded policy for a born root is the default with no grants, which its children inherit.

Any refusal leaves the session running but unmanaged. Maestro does not retry.

CMUX's own restore needs its Copilot hooks. `cmux hooks copilot install` fails on Copilot 1.0.98 because Copilot writes comments in `config.json`. See [Known gaps](#known-gaps).

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

## Known gaps

- Maestro setup does not yet install CMUX's Copilot hooks (#252 follow-up). Without them CMUX has no record to restore, and the tab stays a plain shell.
- CMUX's Copilot restore keeps `--name` and adds `--resume`. Copilot 1.0.98 refuses that pair. A session started with `--name` does not come back through CMUX's restore. Rename the session inside Copilot instead.
- Sessions launched through wrappers such as Agency are not covered.
- Until the sidebar names born roots from their session (the next change in this stack), a resumed born root shows as "Terminal" in the Maestro sidebar.
- Launches made before this change have no binding and do not resume.
- A session started before the Maestro integration was installed is never enrolled, so it is not resumed as managed.
- If recording a born root's `/exit` fails twice (for example the state lock stays busy), the extension logs it and the end stays unrecorded. A later manual `copilot --resume` in the same surface can then come back managed.
