# Native messaging: architecture and research findings

Maestro's public research. Comparisons are **pinned source evidence**, not
tests of those products' installed behavior, and need no private research
artifacts. Maestro's own live observations and outstanding acceptance are in
[delivery findings](delivery-proof.md).

## What the upstream systems actually do

[What the upstream systems do](native-messaging/upstream-systems.md)

### Orca: durable mailbox, two different attention paths

[Orca: durable mailbox, two different attention paths](native-messaging/upstream-systems.md#orca-durable-mailbox-two-different-attention-paths).

### Paseo: daemon-owned provider sessions, including Copilot over ACP

[Paseo: daemon-owned provider sessions, including Copilot over ACP](native-messaging/upstream-systems.md#paseo-daemon-owned-provider-sessions-including-copilot-over-acp).

### Herdr: identity reporting is not its message delivery channel

[Herdr: identity reporting is not its message delivery channel](native-messaging/upstream-systems.md#herdr-identity-reporting-is-not-its-message-delivery-channel).

### Upstream CMUX: background transport is not a draft-safe mailbox

[Upstream CMUX: background transport is not a draft-safe mailbox](native-messaging/upstream-systems.md#upstream-cmux-background-transport-is-not-a-draft-safe-mailbox).

## Chosen Maestro contract

[Chosen Maestro contract](native-messaging/maestro-contract.md)

### Managed steering and turn boundaries (#163)

[Managed steering and turn boundaries](native-messaging/managed-steering.md)

## Installed lifecycle and permissions

[Installed lifecycle and permissions](native-messaging/installed-lifecycle.md)

### Born managed sessions (#252, ADR 0025)

An eligible Copilot session started in a CMUX terminal with no launcher inputs
asks to enroll as its own managed root when the loader joins it. The controller
verifies it first, and a refusal leaves it unmanaged. See
[born managed sessions](native-messaging/born-managed-sessions.md).

### Ordinary-session readiness (partial #162)

[Ordinary-session readiness](native-messaging/ordinary-session-readiness.md)

### Explicit owned-descendant close

[Explicit owned-descendant close](native-messaging/owned-descendant-close.md) | [Stock host behavior and admission limits](native-messaging/close-host-behavior.md)

## Evidence, corrected assumptions, and remaining gap

[Evidence and remaining gap](native-messaging/evidence.md): SDK versions, corrected assumptions and the remaining acceptance gap.
