# Workspaces on top; Worktrees or Sub-agents below

The Hierarchy always lists CMUX workspaces at the top level. Inside each workspace, one control chooses how agents are grouped: **Worktrees** (by the exact session's current worktree, [ADR 0026](0026-current-worktree-from-the-session-selected-directory.md)) or **Sub-agents** (by recorded spawning parent). The choice is one global, saved preference for every workspace in every window, as in the approved prototype. Default: Sub-agents, the earlier tree.

Interactive agents (managed agents and single-session Copilot surfaces) have one row each: icon, name, tag chips, state cue. No subtitle. A collapsed Worktrees group, or a collapsed parent in Sub-agents, is an icon card: every agent's icon and state in one row that scrolls inside the card, with a separate expand control. Each icon focuses its agent's surface. Internal tasks keep their subordinate text rows under their exact owner. Every row and icon is navigable.

Why: the owner decided on 2026-10-19 that workspaces stay the organizing level, that there is no separate Workspace projection, and that the app shows no explanatory prose in normal browsing; the collapsed count and summary lines and the agent subtitles were prose. The worktree group header carries the location instead.

Rejected: the three-way Worktrees / Sub-agents / Workspace selector of the September design (#58). A per-workspace choice. Grouping by branch label, repository name, pane, title, or a parent's worktree.

Consequence: assigned-directory context and activity captions no longer appear on agent rows; both remain in the row's help, and the assigned directory in hover cards and details. Agents with no current-worktree evidence group under `Unknown` until their next hook. The layout record gains a `worktreeGroup` disclosure kind; an older build cannot read a layout record that contains one and shows its existing layout notice.
