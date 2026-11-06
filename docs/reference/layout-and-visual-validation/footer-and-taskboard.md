# Footer, Taskboard and Beats

Part of [Taskboard, layout, and visual validation](../layout-and-visual-validation.md). Next page is [Details inspector and row state](details-inspector-and-row-state.md).

The workspace menu's **Rename… (⇧⌘R)** selects the workspace and shows a reminder of
CMUX's own shortcut instead of renaming it. **Active window** footer has a drag handle on
its top divider. Shrink it to the pet row or grow it to half the sidebar. Double-click resets. Size is remembered.
Taskboard renders only in sidebar. No reusable or movable content tabs. Extension SDK offers no content-tab host. Taskboard is a state board: one card per agent session.
Cards group under headings with count: **Waiting on you**, **Working**, **Failed**, **Idle**, **Finished**, **Unknown**.
Card shows agent icon and title, current activity, workspace with model on right. Card shows branch only when agent works in git repository or linked
worktree (worktrees labelled). No sub-agent, skill, shell or
internal-task rows. Those stay in Hierarchy. Select card to focus its terminal.

## Beats

Beats opens native popover. Create (header **+**, "New Beat"), edit, turn on or off
(row switch or the row's **Enable**/**Disable** menu item), delete recurring prompts there.
Each row control's VoiceOver label names its schedule and prompt prefix ("Beat on/off,
Hourly, …"). Rows show a preset name or the
cron, the prompt on one line, and the session only when unscoped; a slashed circle marks a
session not running. Next-run estimates, "fires only while the session runs" and Copilot
timing are in tooltips and VoiceOver values, not visible prose. Icon lights while a Beat is enabled.
An agent row (managed agent, single-session terminal, or listed Copilot session) and a
Taskboard card show the same Beat icon as their rightmost item, after collapsed summaries,
pin and unread badges and the row's actions (…) slot, at rest and on hover, with its glyph
8 pt in from the row's trailing content edge (where the header controls end), when that row's
exact session UUID has an enabled Beat. No title, path or label matching; retained context
and status-only rows and internal tasks get none. Lit when the session is alive in a current
observation (the freshness hover cards use); dim when it is not running, stale, hidden or
disconnected. The lit glow is one Core Animation opacity pulse (about 1 second each way) in
the render server, removed under Reduce Motion (static glow) and while the icon has no window
or is hidden. Clicking it opens Beats scoped to that session, or rescopes an open panel in
place, without focusing the row or navigating CMUX. A scoped **New Beat** (**+**) targets only that
session; **Show all** returns to every Beat and is absent while a form is open, so a draft
is never discarded. Opening Beats from the header shows every Beat.
Beats run on Copilot's own scheduler. Maestro extension loaded in each CMUX Copilot
session asks the controller (`beats-snapshot`) for that session's enabled Beats and
mirrors them into native cron schedules. It never parses `beats.json` itself. An invalid
store changes no schedule. No clock process,
managed launch or socket frame involved. Beats are only on or off. Session
re-registers its enabled Beats on every start. Copilot-specific
scheduling call is isolated in `createScheduleGateway` in installed adapter.
CMUX does not expose keep-awake, so no Fermata control.
