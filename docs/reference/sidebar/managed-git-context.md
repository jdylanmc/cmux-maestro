# Managed Git context and notices

[↑ Sidebar presentation](../sidebar-presentation.md) | [← Outline rows and Git evidence](outline-rows.md) | [Navigation and ended rows →](navigation.md)

Managed rows show concise worktree context beside the exact state cue. Hover,
Details and the existing pinned footer keep Git diagnostics. Fresh Git evidence
carries a changed-file count and **+green / -red** tracked-text line counts
against `HEAD` (staged and unstaged changes combined). File totals include
untracked files and binary changes. Line totals exclude them and submodule
contents, and renames count once. Conflicts, unborn `HEAD`, failed or oversized
probes and stale evidence never become zero counts. Counts are sampled and do not form an atomic snapshot of concurrent edits.
Missing current counts remain unavailable.
Count freshness has its own timestamp, independent of branch metadata refreshed
by older supervisors.
Hover cards and pinned details reuse one wrapping semantic Git summary. It includes
the assigned-directory label, comparison basis and terse untracked/binary counts
and exclusions. Missing counts display **Git changes: Unavailable**, and the tooltip's
**Git source: Assigned directory** retains provenance without an explanatory sentence.
Large counts wrap and never widen either detail surface. Text signs and
accessible descriptions keep meaning without color, and user tint never
recolors additions or deletions. Missing current counts are explicit text, not
a zero-valued badge. This presentation neither changes collection nor
establishes the agent's current working directory.
Only bounded aggregates cross into the sandbox, never paths or file contents.
Older controller versions omit these optional fields; refresh the native
integration explicitly to install the new controller. Existing supervisors and
sessions are not restarted or taken over to populate counts.

Nonblocking notices use a Design 06-inspired green, with a darker light-mode
variant. Blocked and failed states are red. Words and symbols separate attention from
active work or successful outcomes. Short IDs no longer lead outline rows. A row for exactly
one Copilot session leads with its **session name** (ADR 0022) and state; when
the name is unavailable, the CMUX surface title shows unchanged. The title is
never split on " - ". Managed rows keep their launch label, except a
born-managed root, which has none and uses its exact session's name; plain terminals,
browsers and other surfaces keep the CMUX title. Hover cards, details, the
Active window footer, Taskboard cards and Beat targets use the same name.
During observation loss a row keeps its last name for the grace period, but
the Active window footer shows only a live, confirmed session (otherwise the
CMUX title), for unmanaged and born-managed rows alike.
Exact session identity stays in details.
