# Projections

[↑ Sidebar presentation](../sidebar-presentation.md) | [← Workspace summaries and header actions](workspace-summaries.md)

Workspaces are always the top level. One segmented control under the header,
**Worktrees | Sub-agents**, applies to every workspace in every window and is saved
(`sidebar.projection`, default Sub-agents) (ADR 0028). Switching changes presentation
only: nothing is focused, moved, acknowledged or adopted.

- **Sub-agents**: agents by recorded spawning parent, as before. A collapsed parent
  shows an icon card of every spawned descendant instead of a count.
- **Worktrees**: each workspace's agents grouped by their exact session's current
  worktree (ADR 0027): most recent verified tool touch this turn, last-known touch,
  then selected-directory fallback. Header: branch glyph, repository name, `branch · tree` or
  `Detached HEAD · commit · tree` (tree = first 7 hex of the opaque key), agent count.
  When members' observations report different heads, the second line shows only `tree`.
  Groups order: current worktrees (by repository, branch, key), last-known worktrees
  (clock glyph), `No repository`, `Unknown`. A child never takes its parent's
  worktree; an agent with no evidence, a non-current non-repository result, or no
  recorded session is `Unknown`. Same repository and branch in two worktrees are two
  groups. Plain terminals and browsers follow the groups.

- A collapsed group or parent is an **icon card**: each agent's state cue and icon in
  one row that scrolls inside the card, plus a separate expand control. Each icon
  focuses its agent's surface and previews like its row. Group disclosure is saved
  per workspace and group (`worktreeGroup` in the layout record), expanded by default.
  Meaningful state overlays the icon's corner. Idle and finished icons have no badge.
  Outstanding attention and incomplete child evidence stay visible, including together
  with activity. Working badges honor Reduce Motion. Icons use equal 28-point targets
  with 4-point gaps, centered with the chevron. A collapsed parent's card starts at
  its title edge. Retained task activity and uncertainty stay inside the card, never
  in a separate summary row beneath it. Counts remain in help and accessibility.
  Card attention follows expanded rows: turn-finished notices and recovered errors
  while working add no badge; permission and answer requests use the needs-input
  question glyph. The parent row already shows its own working state, so only
  hidden work contributes to the card's working count.
- Internal tasks stay subordinate text rows under their exact owner in both views.

Pinned details show labels and values only, not identity/binding explanation paragraphs.
Unconfirmed identity still withholds agent fields; unavailable managed metadata still falls
back to the exact observed session. The details inspector retains its own stale notices.
