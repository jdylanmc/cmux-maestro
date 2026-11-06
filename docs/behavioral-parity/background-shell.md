# Background-shell representation

Part of [behavioral parity and proof](../behavioral-parity.md).

Structured `shell_completed` and `shell_detached_completed` notifications remain
decoded, but no longer create synthetic "Background shell" work rows, outcome
attention or dismissal candidates, regardless of exit code. This is an explicit
UI removal policy (#155), not evidence of deliberate cancellation or successful
shell/worker execution. Real worker/task errors and independently observed
`shell:<toolCallId>` tool invocations remain unchanged. Raw provider history and
stored dismissal settings are not deleted or migrated.

`./scripts/test-copilot-shell-reducer.sh` compiles the actual Foundation decoder
and reducer without launching the app or a UI test host. It checks both
notification kinds across zero, ordinary nonzero, signal-compatible and missing
exit codes, replay/reconstruction, independent error preservation, real-work
retirement, request reuse, one-word replay saturation and 128 bounded lifecycles.
CI runs it as its own step.
The former notification-based retirement fixtures now admit and complete real
shell tool work while preserving original assertions, bounds and stress, with
explicit retirement preconditions. These scoped checks do not substitute for
the full hosted test matrix or current-head CI.
