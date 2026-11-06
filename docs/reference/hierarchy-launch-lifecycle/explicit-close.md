# Explicit close

[↑ Managed hierarchy, launch, and close](../hierarchy-launch-lifecycle.md) | [← Launch commands and interactive workers](launch-commands-and-interactive-workers.md) | [Interactive startup and native bindings →](interactive-startup-and-native-bindings.md)

Native `maestro_close` requests closure of one explicitly authorized, currently
owned strict descendant, including a grandchild, by exact `workerId`,
`workspaceId`, `surfaceId`, `sessionId` and `generation`. It validates private
native authority, process and session-source anchors, current workspace
membership and launch fences. A launch lease fences its own node: a lease on
the target, a target descendant, the actor or either closing surface refuses,
but an unrelated sibling's lease does not. Close then sends one initial stock
CMUX `surface.close` with documented Boolean `force: true`, which selects the
noninteractive route. That is not a public toggle or an escalation after
refusal, and it involves no sidebar control or host change. Stock host
refusals, including last terminal, are inherited, so this is not UI-close
(confirmation/pinning) parity. CMUX 0.65 requests that omitted the field returned
`confirmation_required`, and tagged source confirms the false default. The source contract is corrected, and installed/live proof is separate. No
retry, force-after-refusal or confirmation fallback follows.

Omitted `scope` or `"scope": "target-only"` keeps that single-target contract.
Explicit `"scope": "subtree"` captures the selected descendant's private
descendants once and attempts safely admitted targets descendants-first, each
at most once. Refused or unknown descendants do not block independently valid
siblings or parents. Every selected identity appears in `results` with
`attempted`, `outcome`, a compact `reason` and `removal: "unconfirmed"`. New
children and replacement identities never enter the pass. The 45-second budget
and five-second target windows leave remaining targets explicitly not
attempted. An oversized complete result plan or an unrepresentable numeric
generation refuses before host effects, keeping the numeric wire without
rounding identities. Missing captured sessions are refused individually. If
the invoking worker's stored session is lost between targets, prior results
stand and remaining targets refuse, without changing shared native
authorization. Expiry before dispatch is not an attempt. Malformed host text
after dispatch is unknown and neither erases prior results nor stops valid
remaining targets. The 60-second, 65,536-byte adapter transport is unchanged.
Synthetic source/transport coverage does not replace separately authorized
disposable live-host proof.

`closeAccepted: true` with `removal: "unconfirmed"` means only local request
acceptance. No disappearance wait, retry, provider shutdown, typing or force-kill fallback
follows. Timeout, cancellation and lost replies remain uncertain.
Records, unselected descendants and resource accounting are left intact.
Missing or changed provider/source evidence refuses instead of closing a
possibly repurposed shell. Separate preflight and UUID-based host close are
**not atomic session/generation fencing**. The
[installed lifecycle guide](../../../.agents/skills/cmux-maestro-orchestrate/SKILL.md#request-an-owned-descendant-or-explicit-subtree-close)
has the exact tool shape and source limits.
