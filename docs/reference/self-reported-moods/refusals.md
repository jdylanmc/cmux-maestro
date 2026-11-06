# Refusals

[↑ Self-reported moods](../self-reported-moods.md) | [← Agent interface and cosmetic preview](agent-interface.md) | [Store version 1 →](store-version-1.md)

Both native and CLI paths expose only bounded categories:

| Code | Boundary |
| --- | --- |
| `mood-busy` | The existing control lock is held. No write was attempted. |
| `mood-proof-unavailable` | Native own-session proof could not complete or verify. |
| `mood-identity-unverified` | Exact actor, current route, ancestry or custody could not be verified. |
| `mood-placement-unavailable` | Exact current host workspace/surface placement could not be verified. |
| `mood-store-unavailable` | The private state or mood store could not be read, validated or written. Nothing was published. |
| `mood-rate-limited` | A distinct non-clear change arrived inside three seconds. |
| `mood-capacity-unavailable` | A store or sequence bound prevents admission. |
| `mood-input-invalid` | The own-session request has an invalid shape or value. |
| `mood-unavailable` | The operation failed or its outcome remains uncertain, including a failure after the new record was published. |

These categories identify the failing boundary, not the hidden root cause.
They never echo helper output, paths, capabilities or process details. Inspect
the named prerequisite through supported diagnostics; do not automatically
retry, enqueue, widen permissions or fall back to terminal input. A historical
generic refusal cannot be retrospectively attributed to one of these causes.
