# Owned-descendant close: stock host behavior and admission limits

[↑ Native messaging: architecture and research findings](../native-messaging-architecture.md) | [← Explicit owned-descendant close](owned-descendant-close.md)

Close inherits stock host behavior, including last-terminal refusal. CMUX 0.65
requests without the field returned `confirmation_required`, and immutable v0.65.0
source defaults an omitted force to false and requires true for the
noninteractive branch. Selecting that published initial branch is a
source-contract correction, not a host patch, retry, global setting or
permission to invoke a separate live RPC. Installed/live acceptance remains
unverified until separately authorized proof. Any host refusal is preserved
without fallback or confirmation manipulation.

An exact successful reply maps to `closeAccepted: true`,
`removal: "unconfirmed"`. The host's result naming does not prove removal.
Errors, timeout, cancellation and lost replies surface without retries or
post-send observations. In subtree results, accepted alone adds
`closeAccepted: true`. Preflight failure (including a missing captured session)
is refused. Host failure, malformed text or a lost reply after dispatch is
unknown. Deadline expiry before dispatch and the budget remainder are not
attempted. Captured ancestry, exact identity, actor/source/process, workspace
and leases are rechecked under each target lock. Replacements are never
substituted and late children never added. No process exit, completion
acknowledgement, new lifecycle state, capacity release, archive or automatic
cleanup follows.

Close-local admission explicitly refuses an absent or null stored worker-actor
session before shared native authorization indexes it. Capability,
control-token and original-actor checks are unchanged, and native spawn and
observation authorization are not modified.

The lock serializes controller changes only. PID/start precision and source
marker freshness are limited by their sources. Markers are not an OS lock
Maestro acquires or an authoritative host current-session assertion, and the
same-user boundary still applies. Host close takes no expected session or
provider generation, so preflight cannot promise atomic fencing against
replacement or movement after inspection. Ordinary independent observation and
resource reconciliation remain separate.
