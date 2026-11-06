# Activity and publication

[↑ Reader, lifecycle, and retention](../reader-lifecycle-and-retention.md) | [← Retention protection and acknowledgements](acknowledgements.md) | [Projection reuse and publication →](projection-reuse.md)

Activity uses only the allowlisted durable tool-name field: **Executing tool**
(the latest still-executing invocation for that owner) or **Last completed
tool**. The latter is a tool-invocation event, not a statement that a detached
shell process exited. Child attribution needs real event ownership, and names
must be bounded symbolic identifiers. Arguments, results, prompts and raw
errors are never decoded for display. Invalid, missing or future timing is
explicitly unknown, and timestamps are never replaced with poll time. No
token/context counters, guessed percentages or speculative stall detection
exist.

Lifecycle acceptance never depends on the current read clock. Tool and turn
completions pair with their own active invocation/owner identities.
Contradictory start/completion timestamps keep completed evidence with
**unknown timing** and never resurrect executing work on later replay. The
sidebar projection validates observation freshness and future display
timestamps separately. Display times and retention deadlines accept timestamps
up to the snapshot's post-read `generatedAt`, not the session's read-start
`observedAt`, and never past the current display clock. Session freshness still
uses `observedAt`. Missing tool ownership never creates error or executing
activity. A bounded completion tombstone stops a later start from resurrecting
that invocation, and delayed tool metadata for an already-ended spawn cannot
reopen its owner.

Tool starts classify their start, completed-tool and shell-row replay aliases
together before mutating owner metadata. An exact match is a no-op.
Uncertainty in **any** alias fails terminal history open without changing the
live owner. The legacy shell-row alias is checked even for non-shell tool
names, which keeps global tool-ID replay protection conservative across
metadata/name differences. Ordinary tool and actual shell starts both have
selective-alias regressions.

Live `SidebarCopilotPolling.Read` and projection consume the
`Domain/AgentSessionSnapshot.swift` contract through the pure
`CopilotSnapshotAdapter`, while `CopilotSessionReader` owns bounded provider
parsing. Only the caller's granted current host topology establishes a binding.
Launch workspace/surface evidence is separate and cannot create current
topology. Activity and attention reuse `Domain/AgentSignals.swift`. These shared
types compile into the app, sidebar and tests, not the hook.
