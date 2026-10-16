# Interactive workers only

New workers are visible, interactive Copilot sessions started with `--interactive` through CMUX `surface.create`, with a fresh `--session-id`. Humans can type follow-ups and answer permissions in the terminal. Maestro never launches headless workers, never infers completion from an interactive session exiting, and never closes a terminal because a task ended.

Why: a human must keep direct control and sight of every agent. Headless runs hide work and permission prompts.

Rejected: headless mode, invisible SDK tasks, an interactive supervisor, terminal-input control.

Consequence: no deterministic startup or completion proof. Launch return means exact terminal creation and ownership only. Legacy bounded workers stay as they are, labeled.

## Amendment (2026-10-16, #252)

A fresh `--session-id` applies to new workers only. A managed session that CMUX ended by quitting or crashing may be resumed in its restored terminal with its recorded session ID, under [ADR 0024](0024-resume-ended-managed-sessions-after-relaunch.md). A resumed session is still visible and interactive. Maestro still never restarts, adopts, or signals a live session.

## Amendment (2026-10-16, #252): born managed

A Copilot session the human starts in a CMUX terminal is managed from its start under [ADR 0025](0025-copilot-sessions-started-in-cmux-are-born-managed.md). Maestro does not launch it and does not give it a session ID. It is still a visible, interactive session. Already-running sessions are still never enrolled.
