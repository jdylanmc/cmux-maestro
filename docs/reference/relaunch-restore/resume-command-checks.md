# Resume command checks

[↑ Relaunch restore](../relaunch-restore.md) | [← Maestro-launched sessions](maestro-launched-sessions.md) | [One-time approval in CMUX →](one-time-approval-in-cmux.md)

On relaunch, CMUX types that command into the restored shell. The resume command checks:

- The terminal's `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` match the record. CMUX confirms the surface, and the command's controlling TTY is the TTY CMUX reports for it.
- Exactly one node has that session ID, it is a Maestro launch, and its route configuration is unchanged.
- A launch whose surface had been retired (`resource-retired`) needs a free workspace slot. Otherwise it refuses with `no free workspace slot`.
- The recorded process has ended, and no live process holds the session's `inuse.<PID>.lock`. A marker older than the process now using its PID is stale.
- The recorded launch policy is valid. It is replayed as is: same model, allow rules, deny rules, and mode. Nothing is added.
- Copilot resolves: the recorded executable, or `copilot` on this terminal's `PATH` after an upgrade. Otherwise it refuses with `Copilot is not installed on this terminal's PATH`.

Then, inside the state lock, it checks all of this again and records the next generation with a new control token and itself as the provider process. It publishes a new peer route and retires the old one. Only then does it read the recorded account's credential through GitHub CLI, check the terminal and session lock once more, and replace itself with `copilot --resume=<session>`. The token goes into the process environment only. It passes no `--name`, `--session-id`, or prompt. If anything fails after the reservation, that generation is recorded as never started, its route is retired, and the next relaunch decides again. A Copilot that exits early leaves an ended node that the next relaunch can resume.

On any refusal it prints one line, such as `Maestro did not resume this session: recorded account work-user is not signed in to GitHub CLI.`, and the shell stays. It does not retry.
