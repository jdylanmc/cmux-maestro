# Activity and publication

[↑ Reader, lifecycle, and retention](../reader-lifecycle-and-retention.md) | [← Retention protection and acknowledgements](acknowledgements.md) | [Projection reuse and publication →](projection-reuse.md)

Activity uses only allowlisted durable tool-name field: **Executing tool**
(latest still-executing invocation for that owner) or **Last completed tool**.
Latter is a tool-invocation event, not a statement that a detached shell
process exited. Child attribution requires real event ownership. Names must be
bounded symbolic identifiers. Never decode arguments, results, prompts or raw errors
for display. Invalid/missing/future timing is explicitly unknown.
Never replace timestamps with poll time. No token/context counters, guessed
percentages or speculative stall detection implemented.
Lifecycle acceptance never depends on current read clock. Tool and turn
completions pair with their own active invocation/owner identities. Contradictory
start/completion timestamps keep completed evidence with **unknown timing**.
They never resurrect executing work on later replay. Validate observation freshness
and future display timestamps separately in sidebar projection.
Display times and retention deadlines accept timestamps through the snapshot's
post-read `generatedAt`, not the session's read-start `observedAt`, and never
after the current display clock. Session freshness still uses `observedAt`.
Missing tool ownership never creates error or executing activity. Bounded
completion tombstone prevents later start from resurrecting that invocation.
Delayed tool metadata for already-ended spawn cannot reopen its owner.
Tool starts classify their start, completed-tool and shell-row replay aliases
together before mutating owner metadata. Exact match = no-op. Uncertainty
in **any** alias fails terminal history open without changing live owner.
Legacy shell-row alias stays checked even for non-shell tool names. This keeps
global tool-ID replay protection conservative across metadata/name differences.
Both ordinary tool and actual shell starts have selective-alias regressions.

Live `SidebarCopilotPolling.Read` and projection consume existing
`Domain/AgentSessionSnapshot.swift` contract through pure
`CopilotSnapshotAdapter`. `CopilotSessionReader` still owns bounded provider
parsing. Only caller's granted current host topology establishes a binding.
Launch workspace/surface evidence is separate. It cannot create current topology.
Activity and attention reuse `Domain/AgentSignals.swift`. These shared types
compile into app, sidebar and tests, not the hook.
