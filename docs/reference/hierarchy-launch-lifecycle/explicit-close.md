# Explicit close

Part of [Managed hierarchy, launch, and close](../hierarchy-launch-lifecycle.md). Previous page is [Launch commands and interactive workers](launch-commands-and-interactive-workers.md). Next page is [Interactive startup and native bindings](interactive-startup-and-native-bindings.md).

Native `maestro_close` requests closure of one explicitly authorized, currently
owned strict descendant, including a grandchild. It uses exact `workerId`, `workspaceId`, `surfaceId`,
`sessionId` and `generation`. It validates private native authority, process and
session-source anchors, current workspace membership and launch fences. A launch
lease fences its own node: one on the target, a target descendant, the actor, or
either closing surface refuses, but an unrelated sibling's lease does not. Then it
sends one initial stock CMUX `surface.close` with documented Boolean
`force: true`, selecting its noninteractive route. This is not public toggle or
escalation after refusal. No sidebar control or host change involved.
Inherit stock host refusals, including last terminal. This is not UI-close
parity. Earlier CMUX 0.65 requests omitting the field returned
`confirmation_required`. Tagged source confirms false default. Source
contract is corrected. Installed/live proof remains separate. No retry,
force-after-refusal or confirmation fallback.

Omitted `scope` or `"scope": "target-only"` keeps that single-target contract.
Explicit `"scope": "subtree"` captures the selected descendant's private descendants
once. It attempts safely admitted targets descendants-first, at most once.
Refused or unknown descendants do not block independently valid siblings or
parents. Every selected identity appears in `results`, with `attempted`,
`outcome`, compact `reason`, and `removal: "unconfirmed"`. New children and
replacement identities never enter the pass. 45-second budget and five-second
target windows leave remaining targets explicitly not attempted. Oversized
complete result plan or unrepresentable numeric generation refuses before host
effects, keeping existing numeric wire without rounding identities.
Missing captured sessions are refused individually. Loss of invoking worker's
stored session between targets keeps prior results and refuses remaining
targets, without changing shared native authorization. Pre-dispatch expiry is not
an attempt. Malformed host text after dispatch remains unknown. It does not erase
prior results or stop valid remaining targets. Existing 60-second,
65,536-byte adapter transport remains unchanged. Synthetic source/transport
coverage does not replace separately authorized disposable live-host proof.

`closeAccepted: true` with `removal: "unconfirmed"` means only local request
acceptance. No disappearance wait, retry, provider shutdown, typing or
force-kill fallback. Timeout/cancellation/lost replies remain uncertain. Records,
unselected descendants and resource accounting stay intact. Missing or changed
provider/source evidence refuses, rather than closing possibly repurposed
shell. Separate preflight and UUID-based host close are **not atomic
session/generation fencing**. See the
[installed lifecycle guide](../../../.agents/skills/cmux-maestro-orchestrate/SKILL.md#request-an-owned-descendant-or-explicit-subtree-close)
for exact tool shape and source limits.
