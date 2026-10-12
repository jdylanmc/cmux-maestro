# Native peer messaging is fire-and-forget

Same-workspace sessions that have the global `/maestro` guide message each other through Copilot's native `session.send` with `mode: "enqueue"`. Messages are independent of focus, grant no lifecycle or process control, and use no terminal keystrokes. Copilot owns scheduling: Maestro adds no busy scheduler, receipts, retries, or completion tracker.

Why: typing into a terminal clobbers the human's draft. Copilot already queues prompts.

Rejected: terminal input fallback, acknowledgement and retry layers, a standalone broker.

Consequence: no delivery proof. Same-user processes are trusted; routes are generation-bound and retired on provider exit.
