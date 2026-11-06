# Triggers

[↑ Background processes and ports](../processes-and-ports.md) | [← `observer/processes.json`](observer-processes-json.md) | [Sidebar and known limits →](sidebar.md)

`processes.mjs`, installed next to `adapter.mjs` and `extension.mjs`, decides when a session asks. Before it starts the controller, it checks `observer/processes.json`: a pass that began after the event already covers it, and with nothing pending a pass written under 2 s ago by any session means no request.
- When the session becomes managed (a launched worker, or a born root once enrolled): one request.
- After `postToolUse` and `agentStop`: one request, at most once every 2 s.
- Every 10 s while the session runs, only while its own entry has a `separate` owned process, a retained `escaped` or `exited` one (so it expires), or `scan-incomplete`, or has no entry yet. An idle session only reads the file's metadata, and parses it again only when it changed.

A hook event is never dropped by the debounce or by another session's pass: it stays pending until the file's `observedAt` is at or after the event, with one trailing request once the debounce or the controller's 2 s interval allows, and at most 3 requests per event if no pass publishes.

It stops at `sessionEnd` and on shutdown. Unmanaged sessions never ask. Output is ignored. A failed pass waits for the next. If the module is missing, `extension.mjs` runs without it, and `messaging_configuration` refuses the install (`processes.mjs`, at most 16 KiB).
