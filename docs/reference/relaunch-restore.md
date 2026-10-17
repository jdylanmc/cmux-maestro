# Relaunch restore

How Copilot tabs come back after CMUX quits or crashes and opens again. Rules: [ADR 0024](../adr/0024-resume-ended-managed-sessions-after-relaunch.md), [ADR 0025](../adr/0025-copilot-sessions-started-in-cmux-are-born-managed.md). Terms: [CONTEXT](../../CONTEXT.md).

## What survives a relaunch

CMUX restores windows, workspaces, and surfaces with the same UUIDs. It does not restore processes. Each Copilot tab comes back as a plain shell unless something restarts Copilot in it.

## Born-managed roots

A session you started in CMUX is a born-managed root. CMUX's own Copilot restore runs `copilot --resume <id>` in the restored surface. The Maestro extension then joins the resumed session and asks the controller to enroll it. The controller finds the node recorded for that exact session ID and resumes it as the next generation of the same node, in the same run. The root keeps its children.

The controller resumes only when all of these hold:

- The node is a born root, and the session ID matches exactly. A Maestro launch refuses with `session-previously-managed`; it resumes through its binding instead.
- The workspace and surface match the record exactly, and the provider's controlling TTY is that surface's TTY. A different surface refuses with `surface-mismatch`; a TTY mismatch with `cmux-identity-unverified`.
- The prior generation ended without an observed user exit. Maestro's extension records a Copilot `SessionEnd` with reason `user_exit` for its exact session. After that, a manual `copilot --resume` refuses with `session-ended`; it is the human's new start, not a relaunch restore. Other end reasons are not recorded, because a CMUX quit may report them.
- The recorded process has ended, and the new provider (or its direct child) is the only owner of the session's `inuse.<PID>.lock`. Any other marker, live or stale, refuses with `session-live-or-uncertain`. This is checked again inside the state lock, right before the commit.
- The session's current account matches the recorded account. A different account refuses with `account-mismatch`, and `maestro_readiness` names the recorded login. Sign in to that account and restart the session. Nodes without a recorded account refuse with `account-unrecorded`.

The node keeps its run and children. Its provider executable and PATH are refreshed from the resumed process. The old generation's peer route and capability are retired; the new generation gets a new route. Peers see the new address.

Policy: CMUX's own restore replays the session's original command line, so the born root keeps whatever flags the human started it with. Maestro's recorded policy for a born root is the default with no grants, which its children inherit.

Any refusal leaves the session running but unmanaged. Maestro does not retry.

CMUX's own restore needs its Copilot hooks. `cmux hooks copilot install` fails on Copilot 1.0.98 because Copilot writes comments in `config.json`. See [Known gaps](#known-gaps).

## Known gaps

- Maestro setup does not yet install CMUX's Copilot hooks (#252 follow-up). Without them CMUX has no record to restore, and the tab stays a plain shell.
- CMUX's Copilot restore keeps `--name` and adds `--resume`. Copilot 1.0.98 refuses that pair. A session started with `--name` does not come back through CMUX's restore. Rename the session inside Copilot instead.
- Sessions launched through wrappers such as Agency are not covered.
- A session started before the Maestro integration was installed is never enrolled, so it is not resumed as managed.
