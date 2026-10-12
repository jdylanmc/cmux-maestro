# History fails open, replay and capacity fail closed

Malformed history, storage errors, or schema mismatch disable hiding and offer a reset. Visibility wins over tidiness. Replay and active-capacity limits go the other way: at capacity Maestro reports `readLimitReached` and keeps unknown or partial state. It never forgets history or fabricates completion to admit more.

Why: hiding by suspect state buries real work. Admitting past a replay limit lets a stale event close a new turn.

Rejected: silent repair, overwrite on corruption, eviction of exact evidence at capacity.

Consequence: users may see more history until reset. A false positive in the 128-KiB spill filter rejects a fresh event.
