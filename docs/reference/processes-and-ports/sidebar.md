# Sidebar and known limits

[↑ Background processes and ports](../processes-and-ports.md) | [← Triggers](triggers.md)

The sidebar reads `processes.json` with the existing read-only `observer/` grant, like `icons.json`. A missing or malformed file shows no list, never an error. It keeps an entry only when its node, session and generation match a node in `current.json`.

The managed agent hover shows:
- **Processes**: one wrapping field, `PID 4242 (python3.12); PID 4243 (node)`, in published order, with at most 8 entries. A trailing `+N` combines display overflow and `omittedCount`. No repeated process-name headings or separate overflow row.
- Copy gives only the visible current PIDs, one per line, on a complete, current (`owned-current`, not stale) list. Detached `separate` processes retain `· Detached` beside their entry and never enter the copied list. Retained helpers are not listed. Exited processes remain in the observation but are neither listed nor counted in `+N`.
- Empty or uncertain observations retain `None`, `Scan incomplete`, `Denied`, `Unavailable`, `Not observed` or `Session ended`. `None` requires a complete, current scan. An exited-only list follows the same rule. Stale and incomplete lists retain their count/status prefix before the entries; `Stale` appears after 60 s, then `Unavailable` after 5 minutes. Neither stale nor incomplete lists offer PID or endpoint copies.
- **Copilot helpers**: the count of `provider` processes plus `omittedHelperCount`. Helpers are not listed individually.
- **Ports**: one wrapping field, `:8137 (node); *:3000 (vite)`, for listeners of any owned process, helpers included. One entry per port and exact process (PID plus start time), in published order, at most 8 entries then `+N` known entries. Loopback addresses are omitted from the compact label; wildcard addresses show `*`; specific network addresses are shown (comma-separated when the same process binds a port on several addresses). Hover help retains every exact endpoint, TCP, process name and PID.
- Click a port to attempt HTTP in the default browser through SwiftUI's standard URL-opening path (as with existing sidebar links). IPv4 wildcard and `127.0.0.1` use `http://localhost:PORT`; IPv6 wildcard uses `http://[::1]:PORT`; specific addresses retain their binding, including `[::1]` and `127.0.0.2`. A grouped port prefers its wildcard binding, otherwise its first observed binding. Maestro does no probe, prefetch or auto-open, and does not claim that a TCP listener speaks HTTP.
- Copy gives all bound endpoints of visible port entries exactly, one per line (`127.0.0.1:5173`, `[::1]:9000`, `*:3000`). Links and copies exist only for a complete, current scan, never stale or `scan-incomplete`. `Ports: None` requires a complete, current list with no omitted processes or helpers. `Scan incomplete` marks unknown additional ports when processes were not probed. Known endpoints from a complete pass remain clickable and copyable. Stale, incomplete and ended lists retain qualifiers.

The surrounding hover uses compact observation, owner and child-history labels,
not explanatory footer prose. Process freshness qualifiers and copy guards are
unchanged and remain independent of those surrounding metadata fields.

CMUX's workspace-wide port numbers (`networkPorts`) carry no owner, address, protocol or completeness, so they never appear on the agent hover.

## Known limits

- A process that detaches before the first pass (`nohup … &`, a double fork) is never attributed.
- Same-user processes and TCP only.
- After a session switch inside one Copilot process, both nodes are `ambiguous`.
- Sub-agent work is attributed to its session.
- The live hosted hover and live trigger timing are not yet verified in CMUX.
