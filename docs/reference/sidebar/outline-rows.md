# Outline rows and Git evidence

[↑ Sidebar presentation](../sidebar-presentation.md) | [Managed Git context and notices →](managed-git-context.md)

The default view is a restrained workspace outline. Primary semibold workspace
headers contain explicit coordinator → worker → nested-worker rows, with guide
lines showing hierarchy and durable disclosure keyed by stable node identity.
Each row leads with its safe name. Below it, one quiet kind/location line
appears when the external controller verified those facts from the explicitly
assigned working directory (Assigned directory). The worktree label is the
verified repository root basename, and the branch label comes from
`git symbolic-ref`. Detached `HEAD` omits the branch but keeps the verified
worktree. Non-Git and missing directories, timeouts, invalid or overlong output
and failed root queries publish no Git labels, and such a directory is never
called a worktree.

The controller refreshes exact assigned-directory evidence at bounded worker
heartbeats, turn boundaries, follow-up queueing and explicit status checks.
Each projection carries a separate Git evidence status and capture time. Stale
verified locations remain useful context, with a static unverified-state cue and
explicit **last verified** qualification in hover, details and accessibility;
they are never presented as current Git state. Unavailable evidence is omitted.
Probes batch by assigned directory and run outside the global state mutation
lock. The sandboxed sidebar never runs Git and never receives the private full
assigned path through observer metadata.
