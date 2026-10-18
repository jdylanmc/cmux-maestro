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

  Copilot 1.0.98 reports reason `user_exit` for `/exit`, a terminal hangup, a closed terminal, and `SIGHUP` or `SIGTERM` alike, so the reason alone cannot tell a CMUX quit from `/exit`. Measured in a disposable Copilot (spike on #252): every signal or hangup sends the extension `SIGHUP` before `SessionEnd`; `/exit` sends only `SIGTERM`. So the extension records nothing once it has seen `SIGHUP`. `SIGKILL` delivers no `SessionEnd` at all. On `SIGTERM` the extension waits up to one second for the record to land before it exits. If Copilot changes this order, a quit could be recorded as an exit and the session would not come back managed; that fails closed.
- The recorded process has ended, and the new provider (or its direct child) is the only owner of the session's `inuse.<PID>.lock`. Any other marker, live or stale, refuses with `session-live-or-uncertain`. This is checked again inside the state lock, right before the commit.
- The session's current account matches the recorded account. A different account refuses with `account-mismatch`, and `maestro_readiness` names the recorded login. Sign in to that account and restart the session. Nodes without a recorded account refuse with `account-unrecorded`. If Copilot does not report the session's account in time, the resume refuses with `account-unverified`.
- The resumed provider started after the Maestro integration was installed, like any new enrollment. Otherwise it refuses with `session-started-before-install`.
- A root whose surface had been retired (`resource-retired`) needs a free workspace slot to come back. Otherwise it refuses with `capacity-unavailable`.
- The resumed provider started at most 120 seconds before it asks to enroll. A later request refuses with `enrollment-window-passed`. A login or trust prompt answered after that window leaves the session unmanaged.

The node keeps its run and children. Its provider executable and PATH are refreshed from the resumed process. The old generation's peer route and capability are retired; the new generation gets a new route. Peers see the new address.

Policy: CMUX's own restore replays the session's original command line, so the born root keeps whatever flags the human started it with. Maestro's recorded policy for a born root is the default with no grants, which its children inherit.

Any refusal leaves the session running but unmanaged. Maestro does not retry.

CMUX's own restore needs its Copilot hooks. `cmux hooks copilot install` fails on Copilot 1.0.98 because Copilot writes comments in `config.json`. See [Known gaps](#known-gaps).

## Known gaps

- Maestro setup does not yet install CMUX's Copilot hooks (#252 follow-up). Without them CMUX has no record to restore, and the tab stays a plain shell.
- CMUX's Copilot restore keeps `--name` and adds `--resume`. Copilot 1.0.98 refuses that pair. A session started with `--name` does not come back through CMUX's restore. Rename the session inside Copilot instead.
- Sessions launched through wrappers such as Agency are not covered.
- Until the sidebar names born roots from their session (the next change in this stack), a resumed born root shows as "Terminal" in the Maestro sidebar.
- A session started before the Maestro integration was installed is never enrolled, so it is not resumed as managed.
- If recording a born root's `/exit` fails twice (for example the state lock stays busy), the extension logs it and the end stays unrecorded. A later manual `copilot --resume` in the same surface can then come back managed.
