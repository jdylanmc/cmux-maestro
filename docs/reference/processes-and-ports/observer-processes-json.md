# `observer/processes.json`

Part of [Background processes and ports](../processes-and-ports.md). Previous page is [Producer](producer.md). Next page is [Triggers](triggers.md).

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
| `owned-current` | Custody verified this pass. The list is complete. |
| `scan-incomplete` | Custody verified, but `lsof` failed or a descendant belongs to another user: the list shows what was proven. If either `ps` failed, the session directory could not be read, or the provider was missing or changed during the pass, the last list is kept unchanged. Only a complete pass classifies an escape. |
| `denied` | The provider runs as another user. The list is omitted. |
| `no-custody` | The session directory was read and holds no live lock (none, or only stale ones). The list is omitted. |
| `ambiguous` | Another process holds the session's lock, or two nodes record one provider. The list is omitted. |
| `exited` | The provider is gone. Only retained detached or exited entries remain. |

| Process `state` | Meaning |
| --- | --- |
| `owned-current` | In the tree this pass. Carries listeners. |
| `escaped` | Owned in an earlier pass. Alive outside the tree after a complete pass. Never attributed again, even if it shows up in the tree. No listeners. Kept 5 minutes. |
| `exited` | Owned or detached earlier. Gone or its PID now belongs to another process. Kept 5 minutes. |

Bounds per node: 32 owned processes, 16 retained `escaped` or `exited`, 8 listeners per process. Only the 32 kept are probed: `separate` first, newest PID first. `omittedCount` counts skipped `separate` processes. `omittedHelperCount` counts skipped helpers. Published order: `separate` first, then processes with listeners, then newest. `group` is `provider` for a process under a direct child of the provider that shares the provider's process group (Copilot's MCP servers and extensions, and everything they start, such as a browser in its own group) and `separate` otherwise. It sorts presentation only.

`scope` is `loopback` (`127.*`, `[::1]`), `any` (`*`, `0.0.0.0`, `[::]`) or `other` (any other bound address). `protocol` is always `tcp`.
