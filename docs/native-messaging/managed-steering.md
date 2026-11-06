# Managed steering and turn boundaries (#163)

Part of [native messaging: architecture and research findings](../native-messaging-architecture.md). Previous page is [Chosen Maestro contract](maestro-contract.md). Next page is [Installed lifecycle and permissions](installed-lifecycle.md).

Managed recipients request Copilot's native `immediate` mode. The separate
legacy/disposable `a`/`b` proof transport retains `enqueue`; its historical
observations are not evidence for the new managed mode.

The public bundled SDK in Copilot **1.0.93** provides this contract:

- `copilot-sdk/generated/rpc.d.ts:4159-4171`: `enqueue` appends to the normal
  queue; `immediate` interjects during an in-progress turn. This API is marked
  experimental.
- `copilot-sdk/generated/session-events.d.ts:605-614`: `queued` delivery runs
  after the busy run, `steering` joins the in-flight run, and `idle` starts a run.
- `copilot-sdk/session.d.ts:126-137`: `send` returns on admission and processing
  is asynchronous. Its returned message ID does not prove consumption.

The declarations' SHA-256 values, respectively, are
`2fc5dfc654d148ba3835bdc196f5687b7453502b52b53e49dc85523c3db8c275`,
`9c4c5d82d93c09f8ff64af639d79158a9f9a2373acc5fe15e19741e8621f0bdd`,
and `81f8e880aa2519549214082e7a476b07144504b176151c81679d5011e0bf9de7`.
These are version-specific API evidence, not a claim that every supported
Copilot 1.x host steers identically. No new minimum version is
inferred. A rejected send retains the existing bounded recipient diagnostic
and is not retried or silently downgraded to enqueue.

Previously the managed path explicitly chose after-turn enqueue. A long PM
turn could therefore delay peer input by contract even while tools continued.
The #163 screenshot showed four queued messages, but did not establish their
arrival times, contents, consumption, or the only cause of delay. The historical
operator report of blocked decisions and fleet shutdown remains unresolved
impact evidence until actual native acceptance, not only a changed mode.

| Recipient state | Requested behavior and limit |
| --- | --- |
| Working in a model turn | Native steering, not another after-turn queued run. Consumption remains Copilot-owned. |
| Waiting for a tool | Submit once without awaiting that tool. Maestro neither aborts the tool nor guarantees processing before tool completion. |
| Awaiting human input or permission | No approval, response injection or bypass. Processing may remain blocked. |
| Idle or completing a turn | Copilot owns the transition and wake; Maestro adds no state probe, race retry or wake timer. |

Coordinators still finish bounded decisions, yield when waiting for other
owners, and reconcile actual received returns against current candidates.
Preserve unresolved findings and their provenance rather than treating a newer
message as resolution. This source change affects future sends only: previously
queued messages are not read, promoted, replayed or discarded.

Real-socket tests with mocked native sessions verify steering selection,
unchanged envelopes, independent submissions while admission is pending, and
visible rejection without fallback or application acknowledgements. They do
not simulate Copilot's scheduler. Live input-to-action latency, draft preservation
and the state transitions above require separately authorized native acceptance.
These tests establish no numeric SLA, active-tool preemption guarantee or
end-to-end #163 closure.
