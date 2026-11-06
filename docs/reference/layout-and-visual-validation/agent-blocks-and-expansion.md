# Agent blocks and expansion

Part of [Taskboard, layout, and visual validation](../layout-and-visual-validation.md). Previous page is [Outline grouping and density](outline-grouping-and-density.md). Next page is [Sidebar order and layout storage](sidebar-order-and-layout-storage.md).

An expanded agent block is one row group: a managed root agent with its descendants, a
terminal surface row with its session's children or sessions, or a listed Copilot session
with its children. Workspace headers are not grouped. One tracking area covers the group, so
the pointer moving between its rows never exits it; after every layout the group re-checks
where the pointer is, so a group that collapses, reorders or expands under a still pointer
follows it without waiting for the next enter or exit. Hovering any row draws one rounded
highlight behind the whole group and shows the agent row's actions (…); rows inside add no
highlight of their own and show their own actions (…) or dismiss controls on their own hover.
When the agent row's surface is focused, the leading blue focus bar spans the group; collapsed,
it spans the row only. Nested blocks join the outermost expanded group: no inner highlight or
bar. Only one bar shows at a time: rows inside a focused group that share its surface draw none, and a
descendant with its own focused surface keeps its own row-height bar. Presentation only:
hover, grouping and the bar change no focus, read state, expansion or order.

Hierarchy expansion persists by workspace/surface UUID and provider/session/
child identity—not names, paths or current window. Moves and reloads keep
the setting. New identities start expanded. Reusing same child ID in a
different session/provider does not inherit a collapse. Returning with
same full identity intentionally does. Collapsed ancestors retain visible
running, blocked and attention summaries. Incomplete counts stay labelled.
Collapse never dismisses or acknowledges work and never changes retention.
Internal-task groups and task-child disclosure share exact provider/session/task
identities across both views and reloads, independently of actual child-agent tabs.

Density overrides, collapsed identities and workspace-local idle-task reveal
choices are stored in a versioned
`CMUXMaestroPreview/sidebar-layout.json` record in extension container's
Application Support directory. Coordinated, atomic action-level writes merge
across views/processes. They do not replace a stale window snapshot. Local
views synchronize immediately. Native file-presentation notifications refresh
other processes. Reloads also happen on host/observation updates, activation and
appearance.
Storage is bounded to **2,048 overrides / 1 MiB**. Oldest collapse overrides
are evicted first, which only **expands** branches. Off-window state is never
pruned based on a current snapshot. Unreadable or unknown-schema settings
expand all branches and show recoverable notice. Only **Reset layout
settings** replaces that record. **Expand all branches** preserves density.
Layout reset restores Compact and does not alter history or attention settings.
