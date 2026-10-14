# Beats use Copilot's own scheduler

A Beat is a cron prompt for one exact session. Each CMUX Copilot session registers its enabled Beats through `session.schedule.addCron`, wrapped in one gateway. Maestro runs no clock process, no managed launch, and no socket frame for Beats. A Beat is simply on or off.

Why: Copilot already schedules prompts and owns busy state. A second clock would race it.

Rejected: a Maestro-side timer or daemon, a recovery gate that pauses Beats when a target ends.

Consequence: the schedule API is unsupported by Copilot, so it is isolated in `createScheduleGateway`. Beats fire only while the session runs. Copilot keeps schedules across resume (schedule IDs are stable, rebuilt from the session's event log), so the extension owns schedules by those IDs (ADR 0002).
