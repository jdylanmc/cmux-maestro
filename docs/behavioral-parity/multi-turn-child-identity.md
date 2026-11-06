# Multi-turn child identity and completion attribution

[↑ Behavioral parity and proof](../behavioral-parity.md) | [Multi-turn child identity: unknown turns and capability →](multi-turn-unknown-and-capability.md)

Copilot 1.0.88 can persist `subagent.configured(multiTurn: true)`, complete the
original spawn task, then start another interaction on the same child without
another `subagent.started`. The reducer keeps that child's observed name, kind
and ancestry on the fresh interaction and retires the old spawn-result join.
Completion stays a terminal task outcome until fresh activity is observed.
Documented `subagent.selected` profile metadata neither replaces the spawn
identity nor revokes that capability; other unknown subagent lifecycle events
still invalidate it. Reused turn numbers need the existing causal guards.
`CopilotInteractionTests.demonstratedMultiTurnFragmentPreservesIdentityOnlyOnFreshContinuation`
replays a redacted seven-event producer fragment; its omitted causal envelopes
do not prove an untagged final end.

An approved metadata-only Copilot 1.0.88 probe later showed that
`assistant.message` carries both the current `interactionId` and `turnId`, even
across root-owned warning/hook envelopes, while its linked `assistant.turn_end`
carries only the reused turn number. The reducer reads only those two bounded
message identifiers, verifies the exact owner and current interaction/turn, and
uses the message as that owner's completion anchor. Message content is never
decoded or projected. Messages cannot create a turn, revive ended work or
replace spawn identity, and their event IDs use the existing bounded replay
guard.

`producerTaggedMessagesProveRepeatedChildFollowUpCompletion` and
`readerProjectsTaggedInterleavedParentChildAndGrandchildIdle` cover this
producer-shaped attribution through repeated follow-ups and the reader/tree
seams, keeping identity and ancestry while returning to Idle. The nested
fixture is a synthetic composition of the observed single-child sequence, not
installed-app or live grandchild acceptance.
