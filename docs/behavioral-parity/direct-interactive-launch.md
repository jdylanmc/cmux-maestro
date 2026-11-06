# Direct interactive launch and legacy startup (#61)

[↑ Behavioral parity and proof](../behavioral-parity.md) | [Launch: legacy fixtures and lock budgets →](launch-legacy-fixtures.md)

The controller Harness reproduces both a delayed runtime after caller timeout
and a child whose exact attachment is delayed. The former previously revoked
the lease and produced `Worker launch lease is no longer active`; the latter
exited on its own attachment timer. These are controlled source mechanisms,
not a reproduction or explanation of the historical native host trigger.
The earlier provider-initialization explanation was retracted: supervisor
identity is recorded **before** the provider is launched.

New interactive roots/children now directly exec Copilot through
`initial_command`, with no supervisor/startup polling window. Synthetic
regressions exercise actual argument quoting and verbatim task wrapping,
terminal I/O, the validated executable/PATH/cwd, acceptance with missing
observations, native observation on either side of attachment, cancellation
and ambiguous creation, exact generation/process identity, account/policy
boundaries and both admission paths at the configured `MAX_LIVE_WORKERS` cap,
including managed roots and retained terminals. Native adapter tests exercise
precreated bindings, exact session join and one independent observation,
ordinary peer send/reply and no retries. Hooks remain observers; these fixtures
do not claim hook delivery or prompt consumption.

Presentation-model regressions cover fresh exact working/idle/blocked observations
for interactive coordinators and children after the controller node and projection
expire, including accepted/pending `launching` nodes. Both row state and workspace
counts use the same independent observation selection. Missing work does not
become Working from `turn-running`; stale, duplicate, foreign, denied or ambiguous
observations remain unknown. Legacy bounded reports, stale Git provenance and
the distinction between surface suppression and exact session-content ownership
remain covered. No heartbeat, timestamp refresh or visual styling change follows.

Native-loader subprocess regressions use the actual loader/adapter with a fake
joined session. They reproduce a SIGTERM-left socket blocking a same-binding
replacement with `EADDRINUSE`, then verify owned-listener cleanup, termination
during join/observation/chmod, and normal CLI-style reload. Live occupied and
forced-termination stale sockets remain untouched and refused; diagnostics do
not reveal raw exception text or private values. This is isolated lifecycle
evidence, not a replacement for real CLI/provider proof.
