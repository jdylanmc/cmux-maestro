# Oversized assets, rerouting and fast retry

[↑ Reader, lifecycle, and retention](../reader-lifecycle-and-retention.md) | [← Catch-up and tail failures](tail-failures.md)

- A line longer than the ordinary 1 MiB limit (`maximumLineBytes`, default
  1,048,576 bytes) is not buffered. A streaming envelope validates its full JSON
  structure and keeps only the event decoder's metadata keys (root `id`, `type`,
  `agentId`, `data`, `timestamp`, `parentId` and the decoder's selected `data`
  fields); arguments, results, message content and binary payloads are discarded
  incrementally. The 1 MiB retained-line limit is not raised.
  - **Projected:** `tool.execution_start`, `tool.execution_complete`,
    `tool.execution_partial_result`, and any event type the reducer does not
    know, such as `session.binary_asset` (whose `data` must be an object),
    `assistant.message` and `model.*` diagnostics. They keep their ordinary
    decoder semantics, so uploaded screenshots or large tool results cannot
    permanently invalidate later working/idle state.
  - **Refused (fail closed):** every other known lifecycle event, such as
    `assistant.turn_start`. The line marks the session malformed and
    `readLimitReached`; the previous state is kept.
  - Unknown work-lifecycle types (`subagent.`, `tool.execution_` or
    `assistant.turn_` prefixes) are projected but still reach the reducer's
    explicit degradation, not healthy state.
  - **Bounds:** 64 container levels, 1,024 encoded bytes per key, 65,536
    encoded key bytes across open objects, and 2,048 encoded bytes per retained
    scalar. Binary-asset `metadata` and tool-result `structuredContent` maps
    have no separate per-object key-count ceiling. The projected envelope must
    fit the ordinary line limit. Malformed tokens, invalid UTF-8, duplicate keys
    and truncated structure are rejected; anything that fails these checks is
    malformed, not projected.
  - Publication still needs a complete newline and a verified file/identity
    boundary; torn appends keep the previous observation.
  - Tests: `CopilotAssetEnvelopeTests` in
    [`CopilotAssetEnvelopeTests.swift`](../../../CMUXMaestroPreviewTests/CopilotAssetEnvelopeTests.swift),
    including `oversizedLifecycleDataStillFailsClosed`,
    `validOpaquePayloadDoesNotPoisonLaterState`,
    `toolCompletionPreservesOutcomeAcrossLineLimit`,
    `unsupportedLifecycleAndMalformedMetadataDoNotBecomeHealthyByProjection`,
    `envelopeResourceBoundsAreExplicitAndFailClosed`,
    `arbitraryAssetAndToolMapsRecoverAcrossOrdinaryLineLimit`,
    `arbitraryMapStillRejectsExactAggregateKeyBudgetOverflow` and
    `incompleteOversizedAppendNeverPublishesBeforeValidNewline`. This is
    source-level recovery for #121, not proof of every reported
    missing/Unknown row.
- Binding rerouted during read is deliberately omitted, **not** returned
  with its superseded surface/session identity as ambiguous row. Other
  verified granted sessions stay visible. Snapshot reports
  `identityChanged` and is incomplete. Later stable read under new grant
  reconstructs that session, including when both surfaces were already granted.
  In contrast, unstable process/marker evidence with unchanged valid routing
  binding still produces content-free ambiguous row while retaining private replay
  guards for a later fully revalidated read. Timestamp-only hook
  refreshes preserve verified row but require stable discovery cycle
  before completeness. Reader tests cover all three distinct contracts and use
  `#require` before unwrapping expected observations.
- `hasPendingHistory` accelerates productive initial/changed-index discovery and
  admitted-tail deltas. Waiting for session capacity uses normal polling,
  not an endless fast retry loop.
  EOF, torn final lines, and warnings alone never request fast retry. No sandbox
  entitlement or ancestor traversal permission is broadened.

**Further presentation integration:** preserve this combined reducer's
accepted terminal UUID/timestamp, current-spawn/turn pairing, bounded event/start/
owner-qualified resolved-request guards, and `canPublishProjection` distinctions.
Retirement must keep cleaning obsolete turn/activity/outcome state without
discarding pending requests, unknown placeholders or required ancestors.
History presentation limits stay separate from ingestion limits. Prior
terminal dismissal cannot hide fresh lifecycle using same agent ID.
Carry finite reader watermarks, staged-binding revalidation, EOF freshness and
overflow scheduling together. Layout, installer and clarity changes must not
weaken quiet validation scene, backend setup denial, current-tree
acknowledgement guards, or host's 50-point footer clearance.
