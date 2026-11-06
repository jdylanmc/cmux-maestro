# Authority and proof

Part of [Hook-owned binding retirement](../binding-retirement.md). Next page is [Coordination and durability](coordination-and-durability.md).

Only an already successful session-start or prompt identity-binding hook may
run one retirement pass. Tool-use payloads do not run retirement.
Appearance and ownership-proof commands do not clean up. No install, daemon,
timer, process signal, terminal operation or adoption is involved.

A candidate must be a supported, owner-only, single-link regular binding with
an exact filename/session UUID. Its generation is the recorded session,
workspace, surface, owner PID and microsecond start time, not an inferred
orchestration generation. Only a process probe reporting that recorded owner
dead qualifies; PID reuse, unavailable probes and foreign owners survive.
Missing directories, file times and titles never establish death.

Retirement also requires the existing session directory and bounded
session-custody inspection to show no live or uncertain holder. Missing,
unsafe, unreadable or over-limit directories preserve the binding. Resume
before inspection therefore preserves the prior binding; resume afterwards
publishes its new binding through the normal session lock.

A strictly newer dead binding for the same workspace and surface must survive
the operation. `recordedAt` orders only already-proven dead bindings; equal
times retain both. Both bindings and their death/custody evidence are checked
again under their session locks. Rewrites, resumes and uncertainty cancel
retirement. The newest dead binding on each surface is never a candidate.

An [in-place restart handoff](../trust-boundary-and-observation/in-place-restart-handoff.md)
is not retirement. A live owner's binding is replaced by its exact direct
child's, under the same session lock. The superseded record is archived first
through the same helpers: the archive directory is created and the integration
root synchronized, with the same digest format and identical-archive reuse. A
failed archive or sync keeps the binding.
