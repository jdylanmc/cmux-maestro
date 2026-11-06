# Explicit owned-descendant close

[↑ Native messaging: architecture and research findings](../native-messaging-architecture.md) | [← Ordinary-session readiness (partial #162)](ordinary-session-readiness.md) | [Owned-descendant close: stock host behavior and admission limits →](close-host-behavior.md)

The user-facing contract is in
[explicit close](../reference/hierarchy-launch-lifecycle/explicit-close.md).
`maestro_close({target: {workerId, workspaceId, surfaceId, sessionId, generation}, scope?})`
uses the CLI-owned adapter and the existing controller's private `native-close`
ingress, not the peer socket or the sidebar. The model supplies only one explicit descendant identity. The adapter
binds the actual invoking session and private capability. Controller admission
also requires that session's inherited actor/control token, run, generation,
current surface and provider ancestry. Public peer discovery grants no close
rights. Omitted scope and explicit `target-only` keep the flat single-target
receipt. Explicit `subtree` captures a fixed, bounded private root/descendant
selection and uses the actual actor, not impersonated intermediate parents. The
exact root must remain a strict descendant, and each selected descendant is
admitted separately within that captured tree. Descendants precede parents, at
most once each. An ended root can still identify owned live descendants without
itself passing close admission.

The controller rechecks exact descendant ownership against the initial snapshot
under its exclusive state lock. Active run launch leases, unresolved or changed
identities, moved or missing workspace surfaces, and absent or changed provider
anchors refuse. Admission positively checks non-zombie process state and exact
PID/start before any host call; shared conservative resource-retention
predicates are unchanged. The recorded `providerProcess` remains the launch
anchor, because npm can keep that Node process alive while its direct native
CLI child owns the session source. A bounded metadata-only inspection of each
exact standard session directory requires one safe `inuse.PID.lock` whose owner
is the same live PID or one immediate same-user child of the current recorded
launch PID. Both process identities and the owner's parent link are rechecked.
Marker identity and uniqueness must not change, and marker birth must follow
the source owner's start, which cannot predate launch. Additional markers,
including stale ones, refuse. This permits the evidenced one-edge wrapper
layout, not arbitrary descendant discovery or executable-name inference. No
recorded-anchor/schema rewrite, transcript, hook wait, cross-session scan or
provider API is used.

With the same lock held, one `Cmux.run("rpc", "surface.close", ...)` uses
explicit workspace/surface UUIDs and Boolean `force: true` on the initial
admitted request, selecting the documented noninteractive route. Callers get no
force option, and a refused request is never changed and resent. Target-only
keeps its 15-second I/O bound. Subtree uses context-local deadlines: 45 seconds
for the whole pass including ancestry, and at most five seconds per target
including process probes, inventory and host request. Initial and per-target
state acquisitions do not wait for capacity-scaled lock budgets. The context
resets on success or failure so other commands keep their timeouts. The
complete worst-case JSON result, including CLI wrapper and newline, is reserved
under 65,536 bytes before host effects. Oversized plans and generations outside
the JavaScript safe-integer range refuse without truncating or rounding
identities or enlarging the adapter's 60-second timeout. Every
budget-exhausted remaining target is not attempted.
