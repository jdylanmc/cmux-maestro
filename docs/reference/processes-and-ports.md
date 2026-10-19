# Background processes and ports

What the agent hover shows about processes an agent started (#78) and the TCP ports they listen on (#75). Terms: [CONTEXT](../../CONTEXT.md). Decision: [ADR 0029](../adr/0029-owned-processes-come-from-the-session-binding.md).

## Producer

`cmux-maestro-orchestrator process-observe` runs outside the sandbox and covers every managed node in one pass:

1. Reads `state.json` under the shared state lock. Takes `control/processes.lock`; if another pass holds it, or the last pass was under 2 s ago, it exits without scanning.
2. One `ps -axo pid=,ppid=,pgid=,uid=,ucomm=`. `ucomm` is the kernel's accounting name, sanitized to `[A-Za-z0-9._ +-]` and 32 characters. Never argv or environment.
3. Per node (a born root whose session ended in place is skipped: its provider now runs another session): the recorded `providerProcess` must still be the same process (sysctl start time within the recorded second), owned by this user, recorded by no other current node, and the only live `inuse.<PID>.lock` holder for the node's session (itself or a direct child). Descendants of that root are the candidates. Each one's identity is its PID plus its start time in microseconds, read with sysctl.
4. One `lsof -nP -w -a -p <pids> -iTCP -sTCP:LISTEN -Fpn` for every candidate. Exit status 1 means no match; any diagnostic or unparsable row makes the scan incomplete.
5. A second `ps` plus an identity re-read fences the result. A process that left the tree or changed identity during the pass is dropped.
6. Diffs against the previous `processes.json` for the same node, session and generation.
7. Writes `observer/processes.json` atomically, mode `0600`, at most 1 MiB. A failure never changes control state.

Each pass is bounded: 5 s per tool, about 100 ms in practice for one `ps`, one `lsof` and one more `ps`.

## `observer/processes.json`

```json
{"version": 1, "observedAt": "…Z", "nodes": [{
  "nodeId": "…", "copilotSessionId": "…", "generation": 1,
  "state": "owned-current", "observedAt": "…Z", "omittedCount": 0,
  "processes": [{"pid": 4242, "startMicros": 1799999990000007, "name": "python3.12",
    "group": "separate", "state": "owned-current",
    "listeners": [{"protocol": "tcp", "address": "127.0.0.1", "port": 5173, "scope": "loopback"}]}]
}]}
```

| Node `state` | Meaning |
| --- | --- |
| `owned-current` | Custody verified this pass; the list is complete. |
| `scan-incomplete` | Custody verified, but `lsof` failed or a descendant belongs to another user: the list shows what was proven. If either `ps` failed, the session directory could not be read, or the provider was missing or changed during the pass, the last list is kept unchanged. Only a complete pass classifies an escape. |
| `denied` | The provider runs as another user. No list. |
| `no-custody` | The session directory was read and holds no live lock (none, or only stale ones). No list. |
| `ambiguous` | Another process holds the session's lock, or two nodes record one provider. No list. |
| `exited` | The provider is gone; only retained detached or exited entries remain. |

| Process `state` | Meaning |
| --- | --- |
| `owned-current` | In the tree this pass. Carries listeners. |
| `escaped` | Owned in an earlier pass; alive outside the tree after a complete pass. Never attributed again, even if it shows up in the tree; no listeners. Kept 5 minutes. |
| `exited` | Owned or detached earlier; gone or its PID now belongs to another process. Kept 5 minutes. |

Bounds per node: 32 owned processes, 16 retained `escaped` or `exited`, 8 listeners per process. Only the 32 kept are probed: `separate` first, newest PID first. `omittedCount` counts skipped `separate` processes; `omittedHelperCount` counts skipped helpers. Published order: `separate` first, then processes with listeners, then newest. `group` is `provider` for a process under a direct child of the provider that shares the provider's process group (Copilot's MCP servers and extensions, and everything they start, such as a browser in its own group) and `separate` otherwise. It sorts presentation only.

`scope` is `loopback` (`127.*`, `[::1]`), `any` (`*`, `0.0.0.0`, `[::]`) or `other` (any other bound address). `protocol` is always `tcp`.

## Triggers

`processes.mjs`, installed next to `adapter.mjs` and `extension.mjs`, decides when a session asks. Before it starts the controller, it checks `observer/processes.json`: a pass that began after the event already covers it, and with nothing pending a pass written under 2 s ago by any session means no request.
- When the session becomes managed (a launched worker, or a born root once enrolled): one request.
- After `postToolUse` and `agentStop`: one request, at most once every 2 s.
- Every 10 s while the session runs, only while its own entry has a `separate` owned process, a retained `escaped` or `exited` one (so it expires), or `scan-incomplete`, or has no entry yet. An idle session only reads the file's metadata, and parses it again only when it changed.

A hook event is never dropped by the debounce or by another session's pass: it stays pending until the file's `observedAt` is at or after the event, with one trailing request once the debounce or the controller's 2 s interval allows, and at most 3 requests per event if no pass publishes.

It stops at `sessionEnd` and on shutdown. Unmanaged sessions never ask. Output is ignored; a failed pass waits for the next. If the module is missing, `extension.mjs` runs without it, and `messaging_configuration` refuses the install (`processes.mjs`, at most 16 KiB).

## Sidebar

The sidebar reads `processes.json` with the existing read-only `observer/` grant, like `icons.json`. A missing or malformed file shows no list, never an error. It keeps an entry only when its node, session and generation match a node in `current.json`.

The managed agent hover shows:
- **Background processes**: the count of `separate` processes (including `omittedCount`), `None`, `Scan incomplete`, `Denied`, `Unavailable`, `Not observed` or `Session ended`, with `Stale` after 60 s. After 5 minutes it shows `Unavailable`.
- One line per `separate` process: its name and `PID <n>`, copyable while current. Detached and exited processes show `· Detached` or `· Exited`, never copyable. At most 8 lines, then **More background processes**.
- **Copilot helpers**: the count of `provider` processes plus `omittedHelperCount`. Not listed.
- **Listening (loopback | all interfaces | network)**: one line per listener of any owned process, as `127.0.0.1:5173 · TCP · python3.12 4242`. Copy gives the bound endpoint exactly (`127.0.0.1:5173`, `[::1]:9000`, `*:3000`). No open action, no probe, no URL. `Listening: None` only for a complete, current list.

CMUX's workspace-wide port numbers (`networkPorts`) carry no owner, address, protocol or completeness, so they never appear on the agent hover.

## Known limits

- A process that detaches before the first pass (`nohup … &`, a double fork) is never attributed.
- Same-user processes and TCP only.
- After a session switch inside one Copilot process, both nodes are `ambiguous`.
- Sub-agent work is attributed to its session.
- The live hosted hover and live trigger timing are not yet verified in CMUX.
