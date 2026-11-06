# Relaunch restore

How Copilot tabs come back after CMUX quits or crashes and opens again. Rules: [ADR 0024](../adr/0024-resume-ended-managed-sessions-after-relaunch.md), [ADR 0025](../adr/0025-copilot-sessions-started-in-cmux-are-born-managed.md). Terms: [CONTEXT](../../CONTEXT.md).

## What survives a relaunch

CMUX restores windows, workspaces, and surfaces with the same UUIDs. It does not restore processes. Each Copilot tab comes back as a plain shell unless something restarts Copilot in it.

## Born-managed roots

How CMUX's own restore resumes a session you started, and every check the
controller makes, is in [born-managed roots](relaunch-restore/born-managed-roots.md).

### After a born-managed resume

See [after a born-managed resume](relaunch-restore/after-a-born-managed-resume.md).

### CMUX's Copilot hooks file

See [CMUX's Copilot hooks file](relaunch-restore/after-a-born-managed-resume.md#cmuxs-copilot-hooks-file).

## Maestro-launched sessions

Children and launched coordinators come back through a resume binding. See
[Maestro-launched sessions](relaunch-restore/maestro-launched-sessions.md).

### Resume command checks

See [resume command checks](relaunch-restore/resume-command-checks.md).

### One-time approval in CMUX

See [one-time approval in CMUX](relaunch-restore/one-time-approval-in-cmux.md).

## Sidebar rows

See [sidebar rows](relaunch-restore/sidebar-rows.md).

## Known gaps

See [known gaps](relaunch-restore/known-gaps.md).

## Live checks

See [live checks](relaunch-restore/live-checks.md).
