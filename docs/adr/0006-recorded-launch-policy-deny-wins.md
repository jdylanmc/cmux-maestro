# Recorded launch policy, deny wins

Child launches use the parent's recorded policy: mode, bounded allow rules, deny rules. Denies win, descendants never widen inherited permissions, explicit worker YOLO refuses, and coordinator YOLO needs explicit human approval. The record is history, not proof of live permissions.

Why: the Copilot SDK offers no atomic, verified view of live permissions. Pretending to inherit them would be a guess.

Rejected: a live permission snapshot, mutating permissions after launch, granting shell or wildcard rules from tool visibility or prompt text.

Consequence: `/permissions` or `COPILOT_ALLOW_ALL` can make a record stale. Flags are policy, not an OS sandbox.

## Amendment (2026-10-19): inherit verified parent allow-all

Owner decision: "I want maestro to spawn agents with yolo if the current agent has yolo."

Born-managed roots now derive their launch mode from their exact bound provider
PID, after session custody and enrollment identity checks. Read NUL-delimited
argv once per observation, using macOS `KERN_PROCARGS2` (Linux `/proc` in portable
controller tests), checking the recorded process start time before and after.
No lock file alone selects a provider. Store only `permissionMode` and
`permissionSource`, never argv, prompt text, or environment. This is a narrow
exception to the no-observed-content read rule, not permission to retain content.

`--yolo`, `--allow-all`, or both `--allow-all-tools` and `--allow-all-paths`
prove launch allow-all, including `=true` forms. False/unknown boolean values
do not. Argument values and text after `--` are not flags. A deny flag not
already covered by the recorded tool policy prevents inherited allow-all:
do not discard an unrecorded manual deny or persist it from argv.
Unavailable argv or changed PID identity never proves allow-all.

Enrollment and re-enrollment record the derived mode with source `launch-flags`,
or default with source `unverified`. Spawn refreshes born-parent evidence,
including roots enrolled before this amendment, and rechecks provider identity
at reservation. Maestro-launched descendants retain the existing recorded-policy
contract. Omitted `yolo` and `allowTools` inherit the verified/recorded parent mode,
for both coordinators and workers. Denies still replay. `yolo: false` or an
explicit allow-list narrows to default. The result reports effective requested
`permissionMode` and `permissionSource`; it does not attest to live child settings.
Children record the inherited mode so grandchildren inherit it too.

Explicit `yolo: true` retains the separate existing human-approved coordinator
grant; it is not implicit inheritance and still refuses from workers before
credentials or reservation. Default/unverified parents never gain allow-all
through omission. Missing recorded tool-policy provenance still refuses.

Known limit: runtime `/allow-all` toggles are not visible in argv or usable
events. An argv-default parent is treated as not-YOLO even if toggled on later;
an argv-YOLO parent toggled off cannot be distinguished from its launch mode.
Configuration/environment permissions are also not a verified snapshot.
No persistent Copilot settings change, prompt approval, or live-session control.
