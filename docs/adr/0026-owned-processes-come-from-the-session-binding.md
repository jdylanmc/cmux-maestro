# Owned processes come from the session binding

A managed agent's background processes and listening ports are the descendants of its node's recorded provider process, for the node's exact session and generation. The controller decides custody and publishes a separate, sanitized `observer/processes.json`. The sidebar shows an entry only when its node, session and generation match `current.json`.

Why: one Copilot process can keep `inuse.<PID>.lock` files for two sessions after a session switch, so lock files alone would give the same tree to both. A PID alone can be reused; its start time in microseconds (sysctl) cannot, while `ps -o lstart` has one-second resolution.

Rejected:
- Ownership from lock files alone, process names, ports, working directories or process groups.
- Re-attributing a process that left the tree: a process re-parented to `launchd` is reported as detached once, then dropped.
- Per-surface ports from CMUX: the pinned SDK exposes only workspace-wide port numbers with no owner, address, protocol or completeness. They stay a separate, labelled workspace row.
- Probing ports or guessing HTTP.
- A daemon or a sidebar-side scan: the sandbox cannot see other processes, and the controller already runs outside it.

Consequence:
- A process that detaches before the first pass (for example `nohup … &`) is never attributed.
- Only same-user processes and TCP `LISTEN` sockets are covered.
- Sub-agents share their parent's Copilot process, so their work belongs to that session.
- Process groups only sort Copilot's own helpers (MCP servers and extensions) into a counted group. That sort is not ownership evidence. When it is wrong, it shows a helper as a background process; it never hides one.
- Each managed session asks for one pass when it becomes managed, after tool use and agent stops (at most one request per 2 s), and every 10 s until it ends. One pass covers every managed node. The controller runs at most one pass at a time and at most one every 2 s.
