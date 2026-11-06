# Delivery proof: contract and boundary

Part of the [native delivery proof](../delivery-proof.md). Next page is [Delivery proof: source grounding and live observations](source-grounding.md).

This page and the live observations in
[source grounding and live observations](source-grounding.md)
record the original **enqueue** proof. The current managed transport requests native **immediate** steering;
legacy/disposable proof routes still enqueue. See the
[managed steering contract](../native-messaging/managed-steering.md)
for #163 source evidence and remaining native acceptance. None of the historical
draft-preservation or delivery observations proves the new managed mode.

The extension calls `joinSession({ tools })`, verifies the joined session against
its launcher-written binding, and calls `session.send({ prompt, mode: "enqueue" })`.
It supplies no account, model, permission handler, user-input hook, or sensitive
environment request. Copilot owns scheduling. The extension performs no composer manipulation,
focus check, terminal input, busy-state scheduler, receipt, acknowledgement,
resend, completion tracker, or periodic timer.

Each disposable extension child owns one local Unix socket, with no separate
broker. A send attempts one bounded write; a reply is another send to the supplied
sender address. Native API return IDs are discarded. The send tool's local-write
result is not delivery, consumption, or task-success evidence.

`maestro_proof_peers` returns the other explicitly bound participant's address
(not liveness). `maestro_proof_send` accepts only `{ destination:
{ workspaceId, sessionId }, body }`. The adapter supplies the sender from its
launcher binding, never from tool arguments or message body. A private per-sender
capability authenticates local frames against the two fixture bindings; it never
enters the model prompt or tool result. The receiving adapter checks the exact
destination, sender membership, and same-workspace constraint.

This is **same-OS-user trusted prototype isolation**, not protection against a
malicious process running as that user: it can read these private fixture files.
Treat message bodies as untrusted task content, never authorization or tool policy.
Messaging between siblings does not change `ensure_owned` or confer spawn,
archive, focus, or other process-control rights.

Bounds: two participants; 4 KiB UTF-8 body; 8 KiB frame/private file; eight local
connections and eight pending native-send calls per receiver. Excess input is
dropped, not scheduled. A 1.5-second socket inactivity deadline bounds incomplete
local writes, not provider work. No automatic retry follows an uncertain result.
Endpoints/identities are single-use. Failed launch, restart, reload, or replaced
conversation requires fresh fixtures. No stale socket is automatically unlinked.
