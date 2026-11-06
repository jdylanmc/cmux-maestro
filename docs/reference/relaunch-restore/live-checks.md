# Live checks

Part of [relaunch restore](../relaunch-restore.md). Previous page is [Known gaps](known-gaps.md).

Nothing in this document has been verified in a live CMUX yet. Run these before calling relaunch restore done. CMUX's CLI refuses processes started outside CMUX, so a human (or a verifier driving the CMUX window through Computer Use) runs them inside CMUX.

Prerequisites:

- Maestro production setup has run, including CMUX's Copilot hooks file. Remove any CMUX Copilot hooks you installed yourself, so CMUX does not receive each event twice. Confirm Copilot lists the four hooks from `cmux-maestro-cmux-hooks.json` as enabled.
- **Resume agent sessions** (`terminal.autoResumeAgentSessions`) is on.
- The prefix `<controller> resume` is approved once in **CMUX Settings > Terminal > Resume Commands**.
- Copilot sessions are restarted once after setup.

Cases (quit CMUX with ⌘Q and reopen it unless noted):

1. A session you start after setup: `maestro_readiness` says managed, it sees its peers, and its recorded account is yours. Its row shows its session name.
2. A session that was running before setup stays unmanaged until its next extension join. After `/clear` (or an extension reload you run) it reports managed.
3. After relaunch, the born root comes back managed as generation 2 and its row shows its session name, not `Terminal`.
4. A `maestro_spawn` child comes back on its exact session after relaunch, keeps its deny rules, sees its peers, and its row shows its launch label. Send it a message and close it from its parent.
5. For an unmanaged restored session's row, record what it shows before and after the observer hook binds it.
6. With two CMUX windows open, each window's rows come back in their own window.
7. `/exit` a born root, then run `copilot --resume <id>` by hand: it comes back managed as the next generation. Relaunch CMUX after an `/exit` without resuming: the session does not come back.
8. ⌘Q with a born root and a child running: neither records an end (`sessionEndedGeneration` absent), and both come back managed.
9. Sign in to a different account than the born root recorded, then relaunch: it stays unmanaged with `account-mismatch` naming the recorded login.
10. `/exit` a child, then relaunch: it does not come back.
11. Running a live session's resume command refuses. A signed-out recorded account produces one line naming it.
12. No Maestro-launched tab (`maestro_spawn` child or `launch-coordinator` root, which run with `CMUX_COPILOT_HOOKS_DISABLED=1`) appears in `~/.cmuxterm/copilot-hook-sessions.json`, while each born root does have its CMUX restore record there. `cmux surface resume show --json` holds no token.
