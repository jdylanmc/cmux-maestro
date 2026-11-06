# Using Maestro: managed sessions and relaunch

Part of the [README](../README.md) usage notes.

Agents launched by Maestro are normal interactive Copilot sessions. You can type to them. They never run headless.

Copilot sessions you start in CMUX after setup enroll as managed when they are eligible: they see their workspace peers and can spawn children. Sessions that were already running are left alone. A session can stay unmanaged, for example at capacity or when an identity check fails. `maestro_readiness` gives the reason, and [ADR 0025](adr/0025-copilot-sessions-started-in-cmux-are-born-managed.md) lists the limits.

After CMUX quits and reopens, sessions Maestro launched are designed to come back on their exact session once you approve Maestro's resume command prefix in **CMUX Settings > Terminal > Resume Commands**. Sessions you started come back only through CMUX's own Copilot restore, which needs CMUX's Copilot hooks and does not work for sessions started with `--name`. Wrapped launches (such as Agency) are not covered. This is not yet verified in a live CMUX. See [relaunch restore](reference/relaunch-restore.md) for the gaps and the live checks.
