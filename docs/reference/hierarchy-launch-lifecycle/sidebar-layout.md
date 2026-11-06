# Sidebar layout

[↑ Managed hierarchy, launch, and close](../hierarchy-launch-lifecycle.md) | [Launch commands and interactive workers →](launch-commands-and-interactive-workers.md)

Coordinator explicitly registers terminal-backed run: coordinator
→ worker → nested-worker links become primary compact hierarchy.
Every worker is a real unfocused terminal tab in coordinator's current
CMUX pane/workspace. Rows show safe labels and explicit lifecycle state. Details
holds exact run, parent, worker, workspace, surface and generation IDs.
Select current row: uses existing typed CMUX Focus action. Each workspace
appears once. Explicit managed agents and remaining terminals share its outline. Exact
managed workspace/surface pair normally replaces its observed terminal row.
Fresh, unique live observation may prove different session ID on that pair.
Then observed session keeps own primary row. The old registration leaves no
row in either view, regardless of **Show ended agents**. Neither does its
exact old observation. Their attention leaves with them. An observed session on
a managed surface that is not that agent's own gets no row of its own, but
stays as evidence for that agent's state and attention. Unrelated incomplete
history never hides current session.

An unknown interactive root may also yield its row after an in-process session
replacement, but only to one fresh, uniquely bound alive session on the exact same
surface with the same recorded provider PID and microsecond start time. The old
root must have no failed/blocked state, attention, tasks or omitted/hidden task
evidence. Protected or incomplete retained reader history withholds correlation
after custody loss without publishing that stale content as current state.
Ambiguous custody, duplicate identities, missing process correlation,
stale evidence and denied access keep the old row. Process correlation is
transient reader-to-presentation metadata: it is neither encoded in snapshots
nor displayed, and it never changes custody, enrollment or capacity (#347).

An ended ancestor is not kept for its descendants: a live descendant shows as
a normal row, a root when its parent is not shown. Captured focus actions stay
bound to original workspace and surface. After move, use newly rendered row.

This is presentation filtering. Not deletion, not session termination, not inferred
end state. Stored registrations, observations and history preferences stay
unchanged. Missing, stale, denied or ambiguous replacement evidence keeps
conservative view. Names, paths and guessed relationships never establish
ownership.
