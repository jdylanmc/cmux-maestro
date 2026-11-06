# Chosen Maestro contract

[↑ Native messaging: architecture and research findings](../native-messaging-architecture.md) | [Managed steering and turn boundaries (#163) →](managed-steering.md)

```text
agent A: maestro_send(destination, body)
  -> A's CLI-owned adapter supplies its bound sender/return address
  -> one bounded local Unix-socket write
  -> B's adapter validates destination, sender and current bindings
  -> B's CLI-owned session.send({ prompt, mode: "immediate" })
```

Each participating session joins its own CLI conversation through
`joinSession({ tools })` and owns one private socket. Maestro runs no standalone broker or second authenticated Copilot client. Discovery lists participating
same-workspace peers, not availability. Installed addresses contain exact
workspace/session identities and generation. Replies use the envelope's bound
sender address, never an address asserted inside the untrusted message body.
Peer messaging grants no ancestor-only lifecycle or process-control privileges.

Copilot owns scheduling. Maestro adds no receipt, acknowledgement, retry,
completion tracker or custom busy scheduler. A local-write result is not
delivery, consumption or task-success evidence. Offline, stale or unsupported
recipients can fail, and an uncertain result does not prove nothing arrived.
Bodies are bounded to 4 KiB UTF-8 and frames to 8 KiB. Private bindings and
sender capabilities enforce local routing within a **same-OS-user trust
boundary**: a malicious process running as that user can read private files.
This is not an OS sandbox or a cryptographic identity claim against that user.
