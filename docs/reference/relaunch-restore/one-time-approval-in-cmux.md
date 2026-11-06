# One-time approval in CMUX

Part of [relaunch restore](../relaunch-restore.md). Previous page is [Resume command checks](resume-command-checks.md). Next page is [Sidebar rows](sidebar-rows.md).

CMUX runs a custom resume binding only after a human approves its command prefix. Open **CMUX Settings > Terminal > Resume Commands** and approve the prefix `<controller> resume` once (or choose "apply to all commands starting with" when CMUX asks, and that choice may be scoped to the folder). Maestro never approves it for you. CMUX also needs **Resume agent sessions** (`terminal.autoResumeAgentSessions`) on.
