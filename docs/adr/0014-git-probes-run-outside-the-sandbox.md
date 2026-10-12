# Git probes run outside the sandbox

The controller probes Git in each assigned directory and publishes bounded aggregates: branch, worktree flag, changed-file totals, tracked-text line counts. The Copilot hook reads `.git` and `HEAD` directly, with no `git` process, and records only session ID, branch, and worktree flag. The sidebar never receives paths or repository names. Stale or failed evidence is labeled last verified or omitted, never shown as zero.

Why: privacy of paths and repos, and the sandbox cannot run Git anyway.

Rejected: Git in the sidebar, exposing assigned paths through observer metadata.

Consequence: a branch row appears only after a session's first tool call following the hook update. Submodule `.git` files count as no location.
