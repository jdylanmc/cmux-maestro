# Producer

[↑ Background processes and ports](../processes-and-ports.md) | [`observer/processes.json` →](observer-processes-json.md)

`cmux-maestro-orchestrator process-observe` runs outside the sandbox and covers every managed node in one pass:

1. Reads `state.json` under the shared state lock. Takes `control/processes.lock`; if another pass holds it, or the last pass was under 2 s ago, it exits without scanning.
2. One `ps -axo pid=,ppid=,pgid=,uid=,ucomm=`. `ucomm` is the kernel's accounting name, sanitized to `[A-Za-z0-9._ +-]` and 32 characters. Never argv or environment.
3. Per node (a born root whose session ended in place is skipped: its provider now runs another session): the recorded `providerProcess` must still be the same process (sysctl start time within the recorded second), owned by this user, recorded by no other current node, and the only live `inuse.<PID>.lock` holder for the node's session (itself or a direct child). Descendants of that root are the candidates. Each one's identity is its PID plus its start time in microseconds, read with sysctl.
4. One `lsof -nP -w -a -p <pids> -iTCP -sTCP:LISTEN -Fpn` for every candidate. Exit status 1 means no match. Any diagnostic or unparsable row makes the scan incomplete.
5. A second `ps` plus an identity re-read fences the result. A process that left the tree or changed identity during the pass is dropped.
6. Diffs against the previous `processes.json` for the same node, session and generation.
7. Writes `observer/processes.json` atomically, mode `0600`, at most 1 MiB. A failure never changes control state.

Each pass is bounded: 5 s per tool, about 100 ms in practice for one `ps`, one `lsof` and one more `ps`.
