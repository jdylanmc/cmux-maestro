# Other activity, session history and history settings

[↑ History and internal tasks](../history-and-internal-tasks.md) | [← Internal Copilot tasks](completed-work-history.md) | [History storage and dismissal keys →](history-storage-and-dismissal-keys.md)

Tool invocation completion is not an agent failure. Successful and failed shell
invocations leave the sidebar child rows when their exact completion is
accepted. Other tools also create no failure attention on their owner.
They require no manual dismissal and are not restored by **Show ended agents**.
Reader snapshots retain bounded terminal outcomes and replay evidence. Agent errors, real sub-agent
failures and independent permission/answer requests retain their protections.

## History settings and dismissal

The completed-work history controls in sidebar **Settings** are shared by
**Hierarchy** and **Taskboard**. The default active outline hides finished/cancelled
non-task activity and confirmed ended process observations. Native surface rows
stay available. Managed workers leave when a terminal outcome is known. Active
descendants, blockers, unknown state and unread errors keep necessary context.
This only filters the sidebar. Terminals, sessions and controller ownership are
never closed, stopped or archived.

**Show ended agents** reveals observations still retained by history.
Failed agent rows remain until explicit dismissal with their **×** control. Focusing
or inspecting them only marks nonblocking notices read. Questions, permissions,
uncertain attention and live descendants protect rows from dismissal. Legacy
automatic "viewed failure" markers no longer hide rows.
Finished and cancelled **non-task activity** outcomes are retained for
**15 seconds** by default. Choose **1 minute**, **5 minutes**, **1 hour**, or
**Never**. Retention starts at the accepted terminal event's RFC 3339 timestamp.
It does not start at poll, first display, or application launch. Missing, malformed, or
future timing shows as **Completion age unknown**. Never auto-expire while
unknown. Source events are not deleted.

Use a row's separate **Dismiss** button, or **Clear completed** for eligible
retained outcomes on current-window surfaces (including collapsed branches,
excluding display-capped/off-window/expired work). These controls never focus,
cancel, approve, prompt, or otherwise control an agent. Working, blocked, idle,
and unknown work stays visible under the existing display limits. A hidden
terminal parent remains as **child context** when descendants still need it.
Running counts and retained/hidden history counts are separate. Empty history
is not evidence that a session has finished.

Structured `shell_completed` and `shell_detached_completed` notifications stay
decoded but no longer create synthetic "Background shell" work rows, outcome
attention or dismissal candidates, whatever the exit code. This is an explicit
UI removal policy (#155), not evidence of deliberate cancellation or successful
shell/worker execution. Real worker/task errors and independently observed
`shell:<toolCallId>` tool invocations are unchanged. Raw provider history and
stored dismissal settings are neither deleted nor migrated.
