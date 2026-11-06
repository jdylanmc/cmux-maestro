# Ordinary-session readiness (partial #162)

[↑ Native messaging: architecture and research findings](../native-messaging-architecture.md) | [← Born managed sessions (#252, ADR 0025)](born-managed-sessions.md) | [Explicit owned-descendant close →](owned-descendant-close.md)

When this loader is enabled and discovered by Copilot in an ordinary CMUX
session, it can join **only its own CLI-owned conversation** and register
`maestro_readiness({})`. This is a nonprivileged diagnostic, not participation:
no private binding lookup, socket, controller call, account lookup, prompt hook,
permission handler, enrollment, replacement session or restart is added.
Existing managed startup and native tools are unchanged; a failed managed
initialization never falls back to this branch.

The diagnostic reports its joined Copilot session UUID, after matching the
CLI-supplied `SESSION_ID` and the invoking tool session. It reports incomplete
required launcher inputs (message root, peer, worker ID and interactive
execution mode); with no launcher inputs at all, born-managed enrollment owns
the session instead. That is **not** proof that no binding exists on
disk: bindings are not inspected. Complete managed inputs belong exclusively to
the managed initializer.

Well-formed `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` environment hints in either
hexadecimal case are required to enable this branch, but they are **not verified
host identity** and their values are not returned. Missing or malformed CMUX/session hints leave the
ordinary branch inert. This is not a host-location attestation.
The account is explicitly not observed. Capability flags describe only what
this extension registers, not other extensions, deferred-tool discovery or
sidebar visibility. Cross-session calls, invalid arguments, cancellation and
session mismatch fail closed with bounded output. Only the two placement hints
are case-normalized for validation; CLI session/join/invocation identity and
managed/private UUID validation remain exact and unchanged.

This is an **intermediate slice of #162**, not its enrollment/Joe activation
solution. Trusted host provenance for the original direct-human request is
still required before privileged in-place enrollment can be implemented;
caller-supplied message attribution is insufficient. No extra confirmation is
introduced. The original pictured extension failure remains undiagnosed without
its safe error evidence; a successful diagnostic does not retroactively diagnose
that exception, prove repository placement, or establish managed readiness.

The owning Copilot CLI 1.0.93 extension guide and public `extension.d.ts`
document own-foreground-session `joinSession({ tools })` and tool invocation
session IDs, consistent with the pinned
[public SDK extension contract](https://github.com/github/copilot-sdk/blob/f84b4fdc6a2baceb2d4ea0edc2b75de342aeee78/nodejs/docs/extensions.md).
Isolated loader and adapter tests exercise this contract, including
ordinary startup and preserved managed failure paths. They do not prove live
host discovery or availability in an already-running chat. Applying an updated
loader requires the existing separately authorized setup/update path; this
source change does not authorize installation or reload.
