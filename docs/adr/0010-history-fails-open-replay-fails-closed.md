# History fails open, replay and capacity fail closed

Malformed history, storage errors, or schema mismatch disable hiding and offer a reset. Visibility wins over tidiness. Replay and active-capacity limits go the other way: at capacity Maestro reports `readLimitReached` and keeps unknown or partial state. It never forgets history or fabricates completion to admit more.

Why: hiding by suspect state buries real work. Admitting past a replay limit lets a stale event close a new turn.

Rejected: silent repair, overwrite on corruption, eviction of exact evidence at capacity.

Consequence: users may see more history until reset. A false positive in the 128-KiB spill filter rejects a fresh event.

## Amendment (2026-10-24, #336): superseded ended bindings

Successful identity hooks may retire bounded batches of superseded,
verified-dead binding records under their existing session locks. The newest
dead binding per workspace/surface remains for ended presentation. Sanitized
identity archives remain outside discovery; reader correctness never depends
on cleanup. The [retirement contract](../reference/binding-retirement.md)
defines exact death/resume proof, permissions, retained evidence and bounds.
No lock is deleted and no live process is controlled.

## Amendment (2026-10-23): tool invocation outcomes are not agent failures

An accepted `tool.execution_complete`, successful or not, is ordinary tool work.
It creates no persistent error/attention outcome on the invocation or its owning
agent. Ended shell invocations leave the sidebar child projection, not the
reader snapshot: bounded terminal outcomes, lifecycle evidence and replay guards
remain available to reader consumers. Running invocations keep
their existing presentation. This exclusion is independent of history settings,
expiry and manual dismissal, and does not infer that a background process exited.

Agent-level failures, genuine sub-agent failures, blocked states, permission and
answer requests, uncertain attention and necessary ancestry remain protected.
Only an exact accepted invocation completion ends that invocation. Unknown,
unmatched or contradictory completion evidence cannot hide active work.
An unresolved agent left without protected descendants uses the existing
unresolved-fragment compaction; it is not assigned invented ancestry.

## Amendment (2026-10-22): owner-approved bounded cold-start tails

The sidebar does not reconstruct an entire large event log on cold start.
The human-selected tail window defaults to 4 MiB and is bounded to 1–64 MiB.
This intentionally changes the previous cold-start reconstruction contract:
older, unobserved history is omitted, not admitted as complete or lazily backfilled.
Its exact session carries `readLimitReached`; healthy siblings are not thereby
incomplete. Recent events must establish current state, otherwise it is unknown.

The existing 8 MiB aggregate and 4 MiB per-session payload budgets remain.
Larger windows initialize across multiple polls, with a fixed captured end.
Changing the setting affects subsequent new, replaced or oversized-gap reads,
never expands or rewinds an already admitted window. If no window is in progress
and unseen appends exceed the selected window, resume at the newest bounded tail.
Skipped gaps invalidate projected state, not already observed replay evidence.
Unchanged files require no event-byte reads.

Observed replay evidence is still retained under the existing bounded guards;
this is not permission to clear a live replay ledger or evict exact evidence.
The unseen prefix has no replay or completeness guarantee. Header identity,
process, binding and file-generation checks remain conservative. A separate
bounded header check does not import historical state or model information.
It must find an exact-session, supported `session.start` as the first event.

Unrelated topology changes, discovery restarts and temporary verifier uncertainty
retain the still-selected cohort's private replay guards. They never grant cached
publication: routing, process and file evidence must pass current validation.
Selection revocation and actual binding or file-generation changes remain
invalidation boundaries. At the 64-session admission limit, keep admitted live or
uncertain owners; verified-dead binding owners release their slots. Check owner
death before admitting historical bindings, including bindings whose session
directories no longer exist. Additional sessions wait with an explicit limit
until owner death or a selection/binding change frees capacity. Missing files,
permission failures and unknown probes alone do not release observed replay
evidence. Do not rotate live/uncertain tails or fast-retry a capacity wait.

Ended presentation is separate from active-tail capacity. Retain the newest
verified-dead owner's binding per selected surface, at most `maximumBindings`
records, without transcript state or replay guards. Binding time orders only
these already-proven ended candidates; it never proves ownership or death.
Revalidate routing and owner evidence before publishing content-free ended rows.
Conflicting live markers remain ambiguous. Overflow remains explicit. This
preserves ended-agent visibility without letting historical bindings pin live
admission.

## Clarification (2026-10-21, #269): isolate child-local doubt

An invalid child field or disagreement between its legacy and observed
projections disables hiding for that child, not every child in the session.
Suspect evidence still cannot hide its owner or required ancestry; unrelated
valid children retain their history controls. Malformed inherited ancestry
protects the affected descendants. Rejected duplicate or empty child identities
protect their identifiable ancestor chains before the rows are filtered out.
Children whose parent transitively names a rejected duplicate, empty or
foreign-owner identity also remain invalid and unresolved before history filtering.
Consistency checks cannot be
waived by an invalid peer in either projection. Strict validation still rejects
the snapshot, and the session's counts remain partial.

Unattributable doubt stays session-wide: a legacy child absent from observed
evidence, a truncated legacy traversal, or a rejected identity without an
identifiable child ancestor chain disables child hiding for the session.
Malformed stored settings, schema mismatch, replay and capacity policy do not
change.

## Amendment (2026-10-20, #280): ended nodes' launch payload leaves control state

Retired history filled the 1 MiB control-state cap with launch-only payload (task text, PATH), and every write refused. Compaction is not eviction: on each state write, an ended node (`resource-retired`, `terminal-disappeared`, `process-disappeared`, `launch-failed`, `startup-failed`) with no launch lease, archive in progress or unresolved surface moves its `task` and `copilotExecutable` to `control/retired/<node-id>.json` (owner-only directory and file, same protection as `state.json`), keyed by generation, and drops its `launchPath` (a resume uses its own terminal's PATH). Identity, lineage, generation, outcome, timestamps, account, launch settings, policy, messaging and Git evidence stay in state, so resume, archive, capacity and the sidebar projection read the node as before.

Fails closed: an unreadable archive is never overwritten, and a payload whose archive is unreadable, unwritable or would pass the byte bound stays in state. An unusable archive never blocks a state write. Archiving a node removes its archive, as it removes its launch scripts. Capacity preflight reports `hostStateByteWarning` at 80% of the cap.

Rejected: dropping task text outright (history the owner may want), raising the cap, compacting live or uncertain nodes, moving launch settings, policy or messaging (resume replays and compares them).
