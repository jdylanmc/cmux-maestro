# History fails open, replay and capacity fail closed

Malformed history, storage errors, or schema mismatch disable hiding and offer a reset. Visibility wins over tidiness. Replay and active-capacity limits go the other way: at capacity Maestro reports `readLimitReached` and keeps unknown or partial state. It never forgets history or fabricates completion to admit more.

Why: hiding by suspect state buries real work. Admitting past a replay limit lets a stale event close a new turn.

Rejected: silent repair, overwrite on corruption, eviction of exact evidence at capacity.

Consequence: users may see more history until reset. A false positive in the 128-KiB spill filter rejects a fresh event.

## Amendment (2026-10-20, #280): ended nodes' launch payload leaves control state

Retired history filled the 1 MiB control-state cap with launch-only payload (task text, PATH), and every write refused. Compaction is not eviction: on each state write, an ended node (`resource-retired`, `terminal-disappeared`, `process-disappeared`, `launch-failed`, `startup-failed`) with no launch lease, archive in progress or unresolved surface moves its `task` and `copilotExecutable` to `control/retired/<node-id>.json` (owner-only directory and file, same protection as `state.json`), keyed by generation, and drops its `launchPath` (a resume uses its own terminal's PATH). Identity, lineage, generation, outcome, timestamps, account, launch settings, policy, messaging and Git evidence stay in state, so resume, archive, capacity and the sidebar projection read the node as before.

Fails closed: an unreadable archive is never overwritten, and a payload whose archive would pass the byte bound stays in state. Archiving a node removes its archive, as it removes its launch scripts. Capacity preflight reports `hostStateByteWarning` at 80% of the cap.

Rejected: dropping task text outright (history the owner may want), raising the cap, compacting live or uncertain nodes, moving launch settings, policy or messaging (resume replays and compares them).
