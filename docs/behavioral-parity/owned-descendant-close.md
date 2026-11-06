# Explicit owned-descendant and subtree close (#90, #91, #377)

Part of [behavioral parity and proof](../behavioral-parity.md).

The native adapter's `maestro_close` and controller's private `native-close`
ingress admit one exact, currently owned strict-descendant interactive session
(#377 widened this from direct children only), then request
stock `surface.close` once with the documented initial Boolean `force: true`.
This selects the noninteractive host route while retaining last-terminal
refusal, not UI confirmation/pinning parity. Earlier CMUX 0.65 requests omitted
the field and returned `confirmation_required`; tagged source confirms that
false-default branch. Behavioral fixtures distinguish the published running-
terminal confirmation and noninteractive branches, including stock refusal
before force handling. This is source proof, not installed/live acceptance.
No retry, force-after-refusal or confirmation manipulation follows. It never
waits for disappearance or starts a provider-exit/retry protocol.

Optional scope defaults to target-only and preserves the original flat receipt.
Explicit subtree captures private descendants once, admits them under the real
actor, and returns complete exact per-target results descendants-first. Refusal
or unknown host results do not block valid siblings/parents. Fixed selection,
retained ended roots, late children, changed generation/session/surface/ancestry,
source/process/workspace changes and leases have behavioral fixtures. Records,
routes and resource accounting remain byte-preserved except fixture-owned races.
Actual subprocess timeout arguments and CLI wire output are exercised across
127 selected targets: the 45-second pass, five-second target windows, nonwaiting
locks, and unchanged 60-second/65,536-byte transport bounds are not source-text
assertions. Oversized complete plans refuse before effects; remaining budget
targets are reported not attempted. Context deadlines reset after success/failure.
Real adapter `execFile` fixtures preserve a 127-result reply and report overflow,
in-flight cancellation and already-aborted refusal without retry. These are
synthetic source/transport proofs, not real-host survivor or partial-failure proof.

`NativeCloseTests` in `scripts/test-delivery-proof.py` exercise private
actor/invoker authority, strict-descendant scope, stale target fields, process/source
anchors, workspace movement, launch leases, preflight changes, real store-lock
exclusion, existing RPC error/timeout behavior and byte-preserved records/routes.
An owned real subprocess also exits without being reaped while retaining its
start identity and source marker: close refuses before any host call. Close
requires affirmative non-zombie process state plus the exact PID/start; unknown
state refuses. Shared conservative resource-retention observation is unchanged.
Separate real-process tests cover a live launch wrapper whose distinct direct
child owns the only source marker, and a same-PID launch/source owner. The
wrapper case failed with the original marker-PID-equals-launch-PID assumption.
A zombie source child under a live wrapper, a deeper source descendant,
controlled sibling/unrelated/foreign ownership, changed parent/start/marker and
unknown evidence refuse before host calls. Only the evidenced immediate-child
relationship is supported. Stored launch anchors are unchanged.
Native adapter tests cover strict public input, bound private identity, one
controller invocation, transport refusal/lost reply/cancellation and no fallback.
They use synthetic hosts, synthetic or owned test processes and disposable local sources,
not live CMUX resources. The existing three runtime suites remain required.

Acceptance is explicitly `closeAccepted: true`, `removal: "unconfirmed"`; it
does not prove removal, release capacity or complete work. Source metadata is
conservative preflight evidence, not atomic host/provider session-generation
fencing. Real disposable native proof and hosted validation are separate
delivery evidence, not claims made by these regression tests.
