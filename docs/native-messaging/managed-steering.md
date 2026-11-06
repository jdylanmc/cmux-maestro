# Managed steering and turn boundaries (#163)

[↑ Native messaging: architecture and research findings](../native-messaging-architecture.md) | [← Chosen Maestro contract](maestro-contract.md) | [Installed lifecycle and permissions →](installed-lifecycle.md)

Managed recipients request Copilot's native `immediate` mode. The separate
legacy/disposable `a`/`b` proof transport keeps `enqueue`, and its historical
observations are not evidence for the managed mode.

The public bundled SDK in Copilot **1.0.93** defines this contract:

- `copilot-sdk/generated/rpc.d.ts:4159-4171`: `enqueue` appends to the normal
  queue; `immediate` interjects during an in-progress turn. The API is marked
  experimental.
- `copilot-sdk/generated/session-events.d.ts:605-614`: `queued` delivery runs
  after the busy run, `steering` joins the in-flight run, and `idle` starts a run.
- `copilot-sdk/session.d.ts:126-137`: `send` returns on admission and processing
  is asynchronous. Its returned message ID does not prove consumption.

The declarations' SHA-256 values, respectively, are
`2fc5dfc654d148ba3835bdc196f5687b7453502b52b53e49dc85523c3db8c275`,
`9c4c5d82d93c09f8ff64af639d79158a9f9a2373acc5fe15e19741e8621f0bdd`,
and `81f8e880aa2519549214082e7a476b07144504b176151c81679d5011e0bf9de7`.
This is version-specific API evidence, not a claim that every supported
Copilot 1.x host steers identically, and implies no new minimum version. A
rejected send keeps the bounded recipient diagnostic and is neither retried nor
silently downgraded to enqueue.

| Recipient state | Requested behavior and limit |
| --- | --- |
| Working in a model turn | Native steering, not another after-turn queued run. Consumption remains Copilot-owned. |
| Waiting for a tool | Submit once without awaiting that tool. Maestro neither aborts the tool nor guarantees processing before tool completion. |
| Awaiting human input or permission | No approval, response injection or bypass. Processing may remain blocked. |
| Idle or completing a turn | Copilot owns the transition and wake; Maestro adds no state probe, race retry or wake timer. |

Coordinators still finish bounded decisions, yield when waiting for other
owners, and reconcile actually received returns against current candidates.
Unresolved findings and their provenance are preserved, and a newer message is
not treated as resolution. The change affects future sends only: earlier queued
messages are not read, promoted, replayed or discarded.

The historical operator report of blocked decisions and fleet shutdown is unresolved impact evidence until actual native acceptance, not just a changed mode. Real-socket tests in [`test-delivery-proof.mjs`](../../scripts/test-delivery-proof.mjs) mock native sessions and do not simulate Copilot's scheduler. Live input-to-action latency, draft preservation and the state transitions above need separately authorized native acceptance. The tests establish no numeric SLA, active-tool preemption guarantee or end-to-end #163 closure. [Earlier behavior, #163 evidence and the test inventory](../evidence/native-messaging.md#managed-steering-and-turn-boundaries-163).
