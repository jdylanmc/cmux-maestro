# Launch receipt evidence

Part of [Managed hierarchy, launch, and close](../hierarchy-launch-lifecycle.md). Previous page is [Interactive startup and native bindings](interactive-startup-and-native-bindings.md). Next page is [Launch evidence limits and legacy workers](launch-evidence-limits.md).

Launch receipts and private `status` distinguish evidence below. This
applies to interactive sessions and preserved legacy bounded workers. Neither
receipt is turn-completion boundary.

| Field | Evidence, not inference |
| --- | --- |
| `launchAccepted` | Exact native surface attached to the owned launch; `null` for older records without this fact. |
| `startup` | `pending`, `provider-observed` for direct native observation, legacy `supervisor-started`, or `failed`. None establishes model readiness. |
| `initialTask` / `taskConsumption` | Direct launches remain `configured` / `unknown` even after a native process observation. Legacy `submitted` retains its previous process/result boundary meaning. |
| `supervisorStarted` / `providerStarted` | Corresponding process identity recorded, not necessarily still running. A missing provider anchor is not proof it never started. |
| `supervisorRunning` / `providerRunning` / `surfacePresent` | Current exact process/inventory observation: `true`, confirmed `false`, or unknown `null`. |
| `messaging` / `messagingAvailability` | Wiring is `configured` or `unsupported`. Configured availability remains `unknown` here. Native peer observation is separate. |
| `workObservation` | `unavailable` without supported work evidence, or `reported-result` at a strict verified legacy result boundary. Interactive work still uses existing session-event observation, not this launch receipt. |
| `surfaceOwnership` / `observedAt` | Exact, unassigned or unresolved ownership, and the controller observation timestamp. |
