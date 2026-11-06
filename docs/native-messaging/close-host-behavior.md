# Owned-descendant close: stock host behavior and admission limits

[↑ Native messaging: architecture and research findings](../native-messaging-architecture.md) | [← Explicit owned-descendant close](owned-descendant-close.md) | [Evidence, corrected assumptions, and remaining gap →](evidence.md)

Inherit stock host behavior, including last-terminal refusal. Earlier CMUX 0.65
requests without the field returned `confirmation_required`. Immutable v0.65.0
source defaults omitted force to false and requires true for the noninteractive
branch. Selecting that published initial branch is a source-contract correction,
not a host patch, retry, global setting or permission to invoke a separate live
RPC. Actual installed/live acceptance remains unverified until separately
authorized proof. Preserve any host refusal without fallback or confirmation
manipulation.
An exact successful reply maps to `closeAccepted: true`, `removal: "unconfirmed"`;
the host's result naming is not a removal proof. Errors, timeout, cancellation
and lost replies are surfaced without retries or post-send observations.
Subtree results repeat every captured identity with `attempted`, `outcome`,
`reason` and unconfirmed removal. Accepted alone adds `closeAccepted: true`;
preflight failure (including a missing captured session) is refused; host failure,
malformed text or lost reply after dispatch is unknown; deadline expiry before
dispatch and budget remainder are not attempted. A failed descendant does not
block an independently valid
sibling/parent. Recheck captured ancestry, exact identity, actor/source/process,
workspace and leases under each target lock. Never substitute replacements or
expand with late children. No process exit, completion acknowledgement, new
lifecycle state, capacity release, archive or automatic cleanup follows.

Close-local admission explicitly refuses an absent/null stored worker-actor
session before shared native authorization indexes it. Identity loss between
targets retains earlier accepted results and refuses the remaining targets;
capability, control-token and original-actor checks stay unchanged. Native spawn
and observation authorization are not modified.

The lock serializes controller changes only. PID/start precision and source
marker freshness remain limited by their existing sources; markers are not an
OS lock Maestro acquires or an authoritative host current-session assertion.
The same-user boundary still applies. Host close takes no expected session or
provider generation, so preflight cannot promise atomic fencing against
replacement/movement after inspection. Ordinary independent observation and
resource reconciliation remain separate.
