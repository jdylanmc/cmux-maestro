# Workspace summaries and header actions

[↑ Sidebar presentation](../sidebar-presentation.md) | [← State cues and headers](state-cues.md) | [Projections →](projections.md)

Workspace summaries are action-only: questions/approval requests show **needs
input**, other explicit blockers show **blocked**. Quiet workspaces show no
summary line. Top alert count uses the same rules. Routine turn completions
do not inflate it. Managed and observed representations on the same exact
workspace/surface count once. Collapsed descendants still contribute.
Last-reported managed blockers stay visible, with freshness qualified in help.
Agent totals, idle counts and repeated completeness warnings are not primary UI.
Source diagnostics stay in details. Glyphs have 2 pt insets in their existing
24 pt slots.
Collapsed workspace headers also keep a compact aggregate activity cue
before the workspace eye, in both projections. Collapsed worktree group headers
use the same cue beside their agent count. Priority: needs input, blocked,
failed, working, unknown. Idle and finished work alone add nothing. The count
belongs to the selected state, including internal tasks under exact owners, not
the total group size. Exact managed and observed session representations count
once. Existing summaries still count agents separately from internal tasks.
The cue reuses row glyphs and the working ring (static with Reduce Motion).
Incomplete evidence adds the dashed unknown glyph beside known activity, or
stands alone when no state is known. No fabricated count represents omitted work.
Completeness belongs to that workspace or group: missing children elsewhere do
not add a cue. A waiting or stale orchestration source with no managed nodes in
this scope leaves empty and idle-only headers quiet; source failures that may
hide nodes, and uncertain in-scope nodes, remain explicit.
State/count and incomplete-count qualification are in accessibility and help,
not visible prose. Activating the cue expands its workspace or group without
focus, acknowledgement or session control. Existing observation updates refresh
it, without a new poller or persisted state.
Standalone state keys keep pause/check/error symbols for blocked, finished and
failed states. Workspace headers have a boxed disclosure.
Their trailing ellipsis menu offers Focus, Expand/Collapse and Details as separate
actions. The four header shortcuts are directory-plus, Beats, Taskboard and Maestro
settings, in that order. Directory-plus opens a folder picker and asks
CMUX to create a workspace there (requires the workspace-creation action grants). Settings holds the sidebar
preferences, including the completed-work history controls.
Taskboard temporarily toggles the existing sidebar view (its underline and
accessible state indicate selection). Activate it again to return to the outline.
A workspace's menu has **Rename… (⇧⌘R)** and its preview ends with "⇧⌘R to rename": the
CMUX extension SDK has no rename action, so Maestro selects the workspace and reminds you of
CMUX's own ⇧⌘R shortcut.
