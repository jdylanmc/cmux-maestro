# Native messaging: architecture and research findings

These pages record Maestro's public research and the native messaging contract.
Comparisons with other products are **pinned source evidence**, not tests of
their installed behavior, and need no private research artifacts. Maestro's own
live observations and outstanding acceptance are in
[delivery findings](delivery-proof.md).

<a id="acceptance-limit"></a>
Acceptance limit for this family: native messaging tests mock Copilot sessions
and transports. They do not simulate Copilot's scheduler or prove native UI
behavior, reliable delivery, input-to-action latency or draft preservation.
Live native acceptance is separate and needs explicit authorization.

## What the upstream systems actually do

Pinned-source comparisons of Orca, Paseo, Herdr and upstream CMUX are recorded as evidence in [ADR 0005](adr/0005-native-peer-messaging-is-fire-and-forget.md#evidence-what-the-upstream-systems-do).

### Orca: durable mailbox, two different attention paths

[Orca: durable mailbox, two different attention paths](adr/0005-native-peer-messaging-is-fire-and-forget.md#orca-durable-mailbox-two-different-attention-paths).

### Paseo: daemon-owned provider sessions, including Copilot over ACP

[Paseo: daemon-owned provider sessions, including Copilot over ACP](adr/0005-native-peer-messaging-is-fire-and-forget.md#paseo-daemon-owned-provider-sessions-including-copilot-over-acp).

### Herdr: identity reporting is not its message delivery channel

[Herdr: identity reporting is not its message delivery channel](adr/0005-native-peer-messaging-is-fire-and-forget.md#herdr-identity-reporting-is-not-its-message-delivery-channel).

### Upstream CMUX: background transport is not a draft-safe mailbox

[Upstream CMUX: background transport is not a draft-safe mailbox](adr/0005-native-peer-messaging-is-fire-and-forget.md#upstream-cmux-background-transport-is-not-a-draft-safe-mailbox).

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

<a id="evidence"></a>
Source declarations justified an experiment, not a compatibility or
draft-safety guarantee. The installed exchange disproves a dependency on
selecting the Maestro sidebar, not all visibility conditions, and does not show
reliable delivery. Mocked transport/setup tests and packaging checks do not
prove native UI behavior. No exact upstream cause of the plugin-based
guide-discovery failure is claimed. Observed global guide discovery is not a
guarantee across CLI versions or proof of every live messaging condition.
Installed Settings UI acceptance and any consentful guide refresh remain
separate from that observed discovery success. SDK versions, corrected
assumptions and dated observations are [archived](evidence/native-messaging.md#evidence-corrected-assumptions-and-remaining-gap).
