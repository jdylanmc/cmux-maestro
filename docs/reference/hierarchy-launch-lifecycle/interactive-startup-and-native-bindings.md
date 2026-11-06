# Interactive startup and native bindings

Part of [Managed hierarchy, launch, and close](../hierarchy-launch-lifecycle.md). Previous page is [Explicit close](explicit-close.md). Next page is [Launch receipt evidence](launch-receipt-evidence.md).

Interactive startup uses `surface.create` with `initial_command`, not
CLI `new-surface --command`, which queues input behind interactive shell
initialization. Only caller's executable search path is added to startup
environment. Credentials are not passed through host creation request.
Host may rewrite that environment, so the launch record also captures
validated absolute Copilot executable and caller search path privately.
One-shot non-login shell sources private launch environment, restores
that PATH and immediately `exec`s absolute Copilot executable with fresh
`--session-id` and `--interactive` prompt. Pinned subscription credentials are
resolved through existing bounded GitHub CLI lookup directly into process
environment. Never persisted or included in host command.
Necessary authorization, setup, create/attach and individual I/O remain bounded.
**Return is immediate after exact terminal creation/ownership:** no supervisor
acknowledgement, sleep, startup observation window, hook/model/provider wait or
optional readiness gate. Creation acceptance does not establish provider start.

One reusable prompt wrapper keeps original task verbatim. It explains
human interaction, exact `maestro_peers`/`maestro_send` discovery and real
envelope-sender replies, fire-and-forget uncertainty and prohibition on
terminal-input fallbacks. It supplies the real coordinator address only when
available. Agent begins task without startup acknowledgement.
`/maestro-minion` and other slash skills are not launch dependencies.

Private native bindings are prepared **before** creation. After joining its
exact CLI-owned conversation, native adapter independently records
session/generation/surface and exec-preserved provider PID/start identity,
verifying process ancestry. This can occur before or after caller attachment.
Neither side waits for other. Hooks remain independent observers, not tool
providers. Missing/late hooks or native observation are unknown, not death.
If caller disappears or creation/attachment is ambiguous, lease,
private setup and capacity stay retained: Copilot may already be running.
No failed caller may guess that it prevented execution.

Managed interactive rows and workspace counts use fresh, uniquely exact
session/workspace/surface observations in both `launching` and `turn-running`,
even when controller metadata is older than its 60-second freshness budget.
Native process observation alone never means Working. Absent, stale or ambiguous
work evidence remains unknown. Git provenance keeps own freshness budget.
Fresh session activity does not refresh old branch, worktree or change count.
