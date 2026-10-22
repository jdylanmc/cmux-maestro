# Owned processes come from the session binding

A managed agent's background processes and listening ports are the descendants of its node's recorded provider process, for the node's exact session and generation. The controller decides custody and publishes a separate, sanitized `observer/processes.json`. The sidebar shows an entry only when its node, session and generation match `current.json`.

Why: one Copilot process can keep `inuse.<PID>.lock` files for two sessions after a session switch, so lock files alone would give the same tree to both. A PID alone can be reused; its start time in microseconds (sysctl) cannot, while `ps -o lstart` has one-second resolution.

Rejected:
- Ownership from lock files alone, process names, ports, working directories or process groups.
- Re-attributing a process that left the tree: a process re-parented to `launchd` is reported as detached once, then dropped.
- Per-surface ports from CMUX: the pinned SDK exposes only workspace-wide port numbers with no owner, address, protocol or completeness. They stay a separate, labelled workspace row.
- Probing ports or claiming TCP listeners speak HTTP.
- A daemon or a sidebar-side scan: the sandbox cannot see other processes, and the controller already runs outside it.

Consequence:
- A process that detaches before the first pass (for example `nohup … &`) is never attributed.
- Only same-user processes and TCP `LISTEN` sockets are covered.
- Sub-agents share their parent's Copilot process, so their work belongs to that session.
- Copilot's own helpers are sorted into a counted group: a subtree under a direct child of the provider that shares its process group (MCP servers and extensions, and what they start). That sort is not ownership evidence. When it is wrong, a helper is listed as a background process, or work started through an MCP server is counted as a helper; neither is dropped.
- An escape is classified only by a complete pass with the provider proven before and after it. Missing parentage keeps the last list.
- Each managed session asks for one pass when it becomes managed and after tool use and agent stops (at most one request per 2 s). Every 10 s it asks again only while it has its own work to watch. A request is skipped when a pass by any session began after the event it serves; an event is never dropped by the debounce. One pass covers every managed node; the controller runs at most one pass at a time and at most one every 2 s.

## Amendment (2026-10-22, #305): explicit browser links

The owner chose a consolidated **Ports** field with click-to-open. This supersedes
the former no-open-action rule, not the no-probing rule. A complete, current scan
may offer an explicit HTTP browser attempt using SwiftUI's standard URL-opening
path, like the sidebar's existing external links. Rendering never opens or probes.
The action does not assert HTTP support, reachability, health or ownership beyond
the scan. Sandbox entitlements and host manifest scopes do not change.

Deduplicate by exact process identity and port, preserving all bound endpoints for
copy and hover help. Loopback entries use `:port`; wildcard entries use `*:port`;
specific network addresses remain visible. IPv4 wildcard and `127.0.0.1` links
use `localhost`; IPv6 wildcard uses `[::1]`; all other specific binds retain their
address, including `[::1]` and `127.0.0.2`. Multiple bindings prefer a wildcard
for opening, otherwise the first observed binding. Stale/incomplete observations
offer neither links nor copies; a complete but probe-bounded list keeps known
endpoints actionable while marking unprobed ports unknown, never `None`.
