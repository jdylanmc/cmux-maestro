# Relaunch restore

How Copilot tabs come back after CMUX quits or crashes and opens again. Rules: [ADR 0024](../adr/0024-resume-ended-managed-sessions-after-relaunch.md), [ADR 0025](../adr/0025-copilot-sessions-started-in-cmux-are-born-managed.md). Terms: [CONTEXT](../../CONTEXT.md).

## What survives a relaunch

CMUX restores windows, workspaces, and surfaces with the same UUIDs. It does not restore processes. Each Copilot tab comes back as a plain shell unless something restarts Copilot in it.

## Born-managed roots

[Born-managed roots](relaunch-restore/born-managed-roots.md)

### After a born-managed resume

[After a born-managed resume](relaunch-restore/after-a-born-managed-resume.md)

### CMUX's Copilot hooks file

[CMUX's Copilot hooks file](relaunch-restore/after-a-born-managed-resume.md#cmuxs-copilot-hooks-file)

## Maestro-launched sessions

[Maestro-launched sessions](relaunch-restore/maestro-launched-sessions.md)

### Resume command checks

[Resume command checks](relaunch-restore/resume-command-checks.md)

### One-time approval in CMUX

[One-time approval in CMUX](relaunch-restore/one-time-approval-in-cmux.md)

## Sidebar rows

[Sidebar rows](relaunch-restore/sidebar-rows.md)

## Known gaps

[Known gaps](relaunch-restore/known-gaps.md)

## Live checks

[Live checks](relaunch-restore/live-checks.md)
