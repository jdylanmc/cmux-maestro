# Native messaging: architecture and research findings

This guide preserves Maestro's public research. Comparisons are **pinned source evidence**, not
tests of those products' installed behavior. Maestro's separate live observations
and outstanding acceptance are recorded in [delivery findings](delivery-proof.md).
Nothing here requires access to private research artifacts.

## What the upstream systems actually do

Pinned source comparisons of Orca, Paseo, Herdr and upstream CMUX are in
[what the upstream systems do](native-messaging/upstream-systems.md).

### Orca: durable mailbox, two different attention paths

See [Orca: durable mailbox, two different attention paths](native-messaging/upstream-systems.md#orca-durable-mailbox-two-different-attention-paths).

### Paseo: daemon-owned provider sessions, including Copilot over ACP

See [Paseo: daemon-owned provider sessions, including Copilot over ACP](native-messaging/upstream-systems.md#paseo-daemon-owned-provider-sessions-including-copilot-over-acp).

### Herdr: identity reporting is not its message delivery channel

See [Herdr: identity reporting is not its message delivery channel](native-messaging/upstream-systems.md#herdr-identity-reporting-is-not-its-message-delivery-channel).

### Upstream CMUX: background transport is not a draft-safe mailbox

See [Upstream CMUX: background transport is not a draft-safe mailbox](native-messaging/upstream-systems.md#upstream-cmux-background-transport-is-not-a-draft-safe-mailbox).

## Chosen Maestro contract

Each participant joins its own CLI conversation and sends native prompts without
receipts or retries. See [chosen Maestro contract](native-messaging/maestro-contract.md).

### Managed steering and turn boundaries (#163)

Managed recipients request native `immediate` steering. See
[managed steering and turn boundaries](native-messaging/managed-steering.md).

## Installed lifecycle and permissions

Explicit setup installs the native loader and adapter for new launches. See
[installed lifecycle and permissions](native-messaging/installed-lifecycle.md).

### Born managed sessions (#252, ADR 0025)

An eligible Copilot session started in a CMUX terminal with no launcher inputs
asks to enroll as its own managed root when the loader joins it. The controller
verifies it first, and a refusal leaves it unmanaged. See
[born managed sessions](native-messaging/born-managed-sessions.md).

### Ordinary-session readiness (partial #162)

Readiness diagnostics for an ordinary CMUX session are in
[ordinary-session readiness](native-messaging/ordinary-session-readiness.md).

### Explicit owned-descendant close

`maestro_close` admission and the stock host close are in
[explicit owned-descendant close](native-messaging/owned-descendant-close.md) and
[stock host behavior and admission limits](native-messaging/close-host-behavior.md).

## Evidence, corrected assumptions, and remaining gap

SDK versions, corrected assumptions and the remaining acceptance gap are in
[evidence and remaining gap](native-messaging/evidence.md).
