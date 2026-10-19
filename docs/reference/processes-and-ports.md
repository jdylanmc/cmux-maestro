# Background processes and ports

What the agent hover shows about processes an agent started (#78) and the TCP ports they listen on (#75). Terms: [CONTEXT](../../CONTEXT.md). Decision: [ADR 0026](../adr/0026-owned-processes-come-from-the-session-binding.md).

## Producer

`cmux-maestro-orchestrator process-observe` runs outside the sandbox and covers every managed node in one pass:

1. Reads `state.json` under the shared state lock. Takes `control/processes.lock`; if another pass holds it, or the last pass was under 2 s ago, it exits without scanning.
2. One `ps -axo pid=,ppid=,pgid=,uid=,ucomm=`. `ucomm` is the kernel's accounting name, sanitized to `[A-Za-z0-9._ +-]` and 32 characters. Never argv or environment.
3. Per node: the recorded `providerProcess` must still be the same process (sysctl start time within the recorded second), owned by this user, recorded by no other current node, and the only live `inuse.<PID>.lock` holder for the node's session (itself or a direct child). Descendants of that root are the candidates. Each one's identity is its PID plus its start time in microseconds, read with sysctl.
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
| `scan-incomplete` | Custody verified, but a tool failed or a descendant belongs to another user. The list shows what was proven. |
| `denied` | The provider runs as another user. No list. |
| `no-custody` | No live lock for the session, or a stale one. No list. |
| `ambiguous` | Another process holds the session's lock, or two nodes record one provider. No list. |
| `exited` | The provider is gone; only retained detached or exited entries remain. |

| Process `state` | Meaning |
| --- | --- |
| `owned-current` | In the tree this pass. Carries listeners. |
| `escaped` | Owned in an earlier pass; alive now outside the tree. Never attributed again; no listeners. Kept 5 minutes. |
| `exited` | Owned or detached earlier; gone or its PID now belongs to another process. Kept 5 minutes. |

Bounds per node: 32 owned processes (separate group first, then by start), 16 retained `escaped` or `exited`, 8 listeners per process. `group` is `provider` when a process shares the provider's process group (Copilot's MCP servers, extensions and helpers) and `separate` otherwise. It sorts presentation only.

`scope` is `loopback` (`127.*`, `[::1]`), `any` (`*`, `0.0.0.0`, `[::]`) or `other` (any other bound address). `protocol` is always `tcp`.

## Triggers

`processes.mjs`, installed next to `adapter.mjs` and `extension.mjs`, asks for a pass:
- when the session becomes managed (a launched worker, or a born root once enrolled);
- after `postToolUse` and `agentStop`, at most once every 2 s;
- every 10 s while the session runs. It stops at `sessionEnd` and on shutdown.

Unmanaged sessions never ask. Output is ignored; a failed pass waits for the next.

## Known limits

- A process that detaches before the first pass (`nohup … &`, a double fork) is never attributed.
- Same-user processes and TCP only.
- After a session switch inside one Copilot process, both nodes are `ambiguous`.
- Sub-agent work is attributed to its session.
- The sidebar does not read this file yet.
- Live trigger timing is not yet verified in CMUX.
