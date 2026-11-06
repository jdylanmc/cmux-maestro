# Explicit owned-descendant and subtree close (#90, #91, #377)

[↑ Behavioral parity and proof](../behavioral-parity.md)

The contract is in [explicit close](../reference/hierarchy-launch-lifecycle/explicit-close.md),
with admission and host detail in
[owned-descendant close](../native-messaging/owned-descendant-close.md) and
[stock host behavior](../native-messaging/close-host-behavior.md). #377 widened
admission from direct children only to any strict descendant. This page lists
the regression evidence.

Behavioral fixtures separate the published running-terminal confirmation and
noninteractive branches, including stock refusal before force handling. That is
source proof, not installed/live acceptance. Subtree fixtures cover fixed
selection, retained ended roots, late children, changed
generation/session/surface/ancestry, source/process/workspace changes and
leases. Records, routes and resource accounting remain byte-preserved except for
fixture-owned races. Real subprocess timeout arguments and CLI wire output are
exercised across 127 selected targets, so the 45-second pass, five-second
target windows, nonwaiting locks and unchanged 60-second/65,536-byte transport
bounds are not source-text assertions. Real adapter `execFile` fixtures
preserve a 127-result reply and report overflow, in-flight cancellation and
already-aborted refusal without retry. These synthetic source/transport proofs
do not prove real-host survivors or partial failure.

`NativeCloseTests` in `scripts/test-delivery-proof.py` exercise private
actor/invoker authority, strict-descendant scope, stale target fields,
process/source anchors, workspace movement, launch leases, preflight changes,
real store-lock exclusion, existing RPC error/timeout behavior and
byte-preserved records/routes. An owned real subprocess that exits unreaped,
with its start identity and source marker intact, makes close refuse before any
host call. Unknown process state refuses.

Real-process tests cover a live launch wrapper whose distinct direct child holds
the only source marker, and a same-PID launch/source owner. The wrapper case
failed under the original marker-PID-equals-launch-PID assumption. A zombie
source child under a live wrapper, a deeper source descendant, controlled
sibling/unrelated/foreign ownership, changed parent/start/marker and unknown
evidence all refuse before host calls. Native adapter tests cover strict public
input, bound private identity, one controller invocation, transport
refusal/lost reply/cancellation and no fallback. They use synthetic hosts,
synthetic or owned test processes and disposable local sources, not live CMUX
resources. All three runtime suites remain required. Real disposable native
proof and hosted validation are separate delivery evidence that these
regression tests do not claim.
