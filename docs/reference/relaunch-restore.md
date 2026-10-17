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

## Maestro-launched sessions

Children from `maestro_spawn`, and coordinators from `launch-coordinator`, do not use CMUX's own restore. Their launch sets `CMUX_COPILOT_HOOKS_DISABLED=1`, so CMUX's hooks never record them. CMUX's restore drops launch flags, which could drop deny rules or the parent link.

Instead, each launch attaches a resume binding to its exact surface:

```text
cmux surface resume set --workspace <workspace> --surface <surface> --cwd <dir> \
  --kind agent --checkpoint <session> -- <python> <controller> resume-managed \
  --worker-id <node> --session-id <session>
```

The binding holds identifiers only. It holds no token, prompt, or temporary path. The launch receipt reports `resumeBinding: "set"` or `"unavailable"`.

On relaunch, CMUX types that command into the restored shell. `resume-managed` checks:

- The terminal's `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` match the record. CMUX confirms the surface.
- The node is a Maestro launch with that exact session, and its route configuration is unchanged.
- The recorded process has ended, and no live process holds the session's `inuse.<PID>.lock`.
- The recorded launch policy is valid. It is replayed as is: same model, allow rules, deny rules, and mode. Nothing is added.
- The recorded account resolves through GitHub CLI. The token goes into the process environment only.

Then it records the next generation with a new control token, publishes a new peer route, retires the old one, and replaces itself with `copilot --resume=<session>`. It passes no `--name`, `--session-id`, or prompt.

On any refusal it prints one line, such as `Maestro did not resume this session: recorded account work-user is not signed in to GitHub CLI.`, and the shell stays. It does not retry.

### One-time approval in CMUX

CMUX runs a custom resume binding only after a human approves its command prefix. Open **CMUX Settings > Terminal > Resume Commands** and approve the Maestro `resume-managed` command the first time it appears. Maestro never approves it for you. CMUX also needs **Resume agent sessions** (`terminal.autoResumeAgentSessions`) on.

## Known gaps

- Maestro setup does not yet install CMUX's Copilot hooks (#252 follow-up). Without them CMUX has no record to restore, and the tab stays a plain shell.
- CMUX's Copilot restore keeps `--name` and adds `--resume`. Copilot 1.0.98 refuses that pair. A session started with `--name` does not come back through CMUX's restore. Rename the session inside Copilot instead.
- Sessions launched through wrappers such as Agency are not covered.
- A Maestro-launched session that you exit yourself, before CMUX quits, keeps its binding. It resumes at the next relaunch. Close the tab to end it for good.
- Maestro Settings has no opt-out for managed restore yet. Turn off CMUX's resume setting, or do not approve the prefix.
- Launches made before this change have no binding and do not resume.
- A session started before the Maestro integration was installed is never enrolled, so it is not resumed as managed.
