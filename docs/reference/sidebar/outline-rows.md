# Outline rows and Git evidence

[↑ Sidebar presentation](../sidebar-presentation.md) | [Managed Git context and notices →](managed-git-context.md)

Default view: restrained workspace outline. Primary semibold workspace headers
contain explicit coordinator → worker → nested-worker rows. Guide lines show hierarchy.
Disclosure is durable, keyed by stable node identity. Each row leads with its safe name.
Below it, one quiet kind/location line appears when the external controller verified
those facts from the explicitly assigned working directory (Assigned directory). Worktree label = verified
repository root basename. Branch label comes from `git symbolic-ref`.
Detached `HEAD` omits the branch, keeps the verified worktree. Non-Git
directories, missing directories, timeouts, invalid output, overlong output and
failed root queries publish no Git labels. Never call such a directory a
worktree. Controller refreshes exact assigned-directory evidence at bounded
worker heartbeats, turn boundaries, follow-up queueing and explicit status checks.
Each projection carries a separate Git evidence status and capture time. Stale
verified locations stay useful context. They get a static unverified-state cue and
explicit **last verified** hover/details and accessibility qualification. Never present them as current
Git state. Omit unavailable evidence. Probes batch by assigned directory and run outside the global
state mutation lock. Sandboxed sidebar never runs Git. It never receives the
private full assigned path through observer metadata.
