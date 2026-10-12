# Interactive workers only

New workers are visible, interactive Copilot sessions started with `--interactive` through CMUX `surface.create`, with a fresh `--session-id`. Humans can type follow-ups and answer permissions in the terminal. Maestro never launches headless workers, never infers completion from an interactive session exiting, and never closes a terminal because a task ended.

Why: a human must keep direct control and sight of every agent. Headless runs hide work and permission prompts.

Rejected: headless mode, invisible SDK tasks, an interactive supervisor, terminal-input control.

Consequence: no deterministic startup or completion proof. Launch return means exact terminal creation and ownership only. Legacy bounded workers stay as they are, labeled.
