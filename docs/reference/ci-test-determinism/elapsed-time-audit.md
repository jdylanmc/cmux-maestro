# Elapsed-time audit (#310)

Part of [required CI and local acceptance](../ci-test-determinism.md). Previous page is [Repeated focused diagnostics and timing ratchet](repeated-focused-diagnostics.md).

The post-kill quiescence tests use the existing controllable setup clock through
the stop-group clock/sleep seam. They assert SIGTERM at zero, SIGKILL at 200 ms,
and refusal without reaping at 250 ms of **virtual** time. Substituting
`max(grace, postKillGrace)` produces 400 ms and fails the exact assertion.
The zero-grace timeout, already-expired deadline, eventual quiescence and
reap-after-quiescence cases also use virtual time, not real sleeps.
The production clock, sleep cadence and grace values are unchanged.

The audit covered the Swift unit and guide UI targets, their helpers, and
portable test sources selected by the ratchet:

| Elapsed/duration use | Disposition |
| --- | --- |
| `CopilotProcessQuiescenceTests`' two elapsed upper bounds | Replaced with exact virtual-time/state assertions. |
| `test-delivery-proof.mjs`' four session-end elapsed comparisons | Replaced with controlled timer registration, explicit record-entry/release, timer firing and cancellation assertions. No 50 ms settling sleep. |
| `SetupDeadlineClock`, `SidebarManualHoverClock`, Python delivery-proof elapsed budgets | Retained: manually advanced clocks/counters and explicit scheduled-action selection, not wall time. |
| Guide acceptance/readiness and `GuideAcceptanceEvidence` | Retained: existing 180-second whole-case hang guard and finite monotonic producer/consumer provenance. These are native venue/lifetime limits, not a subsecond speed requirement. Exact statements have specific exceptions. |
| Reader/envelope benchmarks, multiwindow phase records, internal-task rendering age, orchestrator status duration | Retained: printed diagnostics/attachments only. Elapsed values do not decide test success. |
| Real-process readiness/exit polling and watchdogs | Retained: event/exit hang guards, not elapsed performance assertions. Existing shorter legacy guards remain frozen. This audit does not claim all legacy timing dependencies are deterministic. |
| Motion observation-age and animation configuration | Retained: injected dates or configured duration values, not measured runner speed. |

The ratchet now also catches `elapsed`/`duration` comparisons on continuation
lines (including reversed operands) and `ProcessInfo.processInfo.systemUptime`.
Negative controls cover the original `ContinuousClock.now - started` assertion,
`Date().timeIntervalSince`, multiline assertions, Python and JavaScript aliases.
Removed speed assertions have no remaining allowlist entries. Clock reads used
only to seed the virtual setup clock do not advance it.
