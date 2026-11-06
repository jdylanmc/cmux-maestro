# Chosen Maestro contract

Part of [native messaging: architecture and research findings](../native-messaging-architecture.md). Previous page is [Native messaging: what the upstream systems do](upstream-systems.md). Next page is [Managed steering and turn boundaries (#163)](managed-steering.md).

```text
agent A: maestro_send(destination, body)
  -> A's CLI-owned adapter supplies its bound sender/return address
  -> one bounded local Unix-socket write
  -> B's adapter validates destination, sender and current bindings
  -> B's CLI-owned session.send({ prompt, mode: "immediate" })
```

Each participating session joins its own CLI conversation through
`joinSession({ tools })` and owns one private socket; there is no standalone
broker or second authenticated Copilot client. Discovery exposes participating
same-workspace peers, not availability. Installed addresses contain exact
workspace/session identities and generation; replies use the envelope's bound
sender address, never an address asserted inside the untrusted message body.
Peer messaging grants no ancestor-only lifecycle or process-control privileges.

Copilot owns scheduling. Maestro adds no receipt, acknowledgement, retry,
completion tracker or custom busy scheduler. A local-write result is not delivery,
consumption or task-success evidence; offline/stale/unsupported recipients can
fail, and an uncertain result is not proof that nothing arrived.
Bodies are bounded to 4 KiB UTF-8 and frames to 8 KiB. Private bindings and sender
capabilities enforce local routing, but this is a **same-OS-user trust boundary**:
a malicious process running as that user can read private files. It is not an
OS sandbox or a cryptographic identity claim against that user.
