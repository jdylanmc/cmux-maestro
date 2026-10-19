# Sidebar order is Maestro-local

A human can drag workspaces, and surfaces within one workspace, into a new order, or use **Move Up** and **Move Down** in a row's actions menu or as VoiceOver actions. That order applies only to Maestro's sidebar. It is stored in the sidebar's own container (`sidebar-order.json`, same preference coordinator as layout and icons) and is never sent to CMUX. CMUX's own sidebar, tab order, and pane layout stay unchanged.

The saved order is a list of CMUX UUIDs per sibling list: one per CMUX window for workspaces, one per workspace for surfaces. CMUX's order stays the base. Saved IDs keep their saved relative order, an item with no saved position goes right after its CMUX predecessor, and stale IDs are ignored and pruned when that list is next saved. Pinned and unpinned items keep the positions CMUX gave their group, so a move never crosses the pin boundary. Surfaces never move to another workspace. Children carried by a row move with it. A duplicate ID makes the list ambiguous, so CMUX's order is shown and moves are refused. An item whose pin state CMUX did not report keeps its place and can't move or be a drop target; unknown is never read as unpinned (ADR 0002).

Primary managed agents are rows for their own CMUX surface, so they share the workspace's surface list, keyed by that surface's UUID. They render as a block before other surfaces, by default active first, then oldest. Each block keeps its place: agents reorder among agents and plain surfaces among plain surfaces. Interleaving the blocks would change the default layout and break the separation between managed and other rows. Nested agents move with their root agent. Work-context rows (agents no longer current on their surface) keep their own section and order.

Amendment (2026-10-18, #259): the Work context section is removed. An agent no longer current on its surface has no row, so there is no separate section to order; a live descendant shown without its parent is a root in the surface list.

Every move or reset, from drag, menu or VoiceOver, goes through one seam, `SidebarReorderBackend`. It takes exact UUIDs, reports per-kind capabilities (the UI offers only what works), and says whether the order is Maestro-local or host-authoritative. `LocalSidebarReorderBackend` is the behaviour above. `SidebarReorderBackends.make(grantedActionScopes:host:store:)` is the only place that chooses a backend, separately for workspaces and surfaces; today it always returns local. Settings copy and its global **Reset sidebar order** also go through the backend; the reset is hidden while any kind is host-ordered.

Why: the human wants a stable order for scanning many agents. The sandboxed sidebar has no way to change CMUX's order, and a second control path into CMUX would break ADR 0001.

Rejected, from a spike against the vendored and upstream SDK:
- A CMUX reorder action: `CmuxExtensionKit` action scopes have no reorder or move action.
- The `cmux://` URL scheme: it handles sign-in only.
- AppleScript `perform action`: terminal-only and relative, and it needs an Apple Events entitlement plus a privacy (TCC) prompt.
- The CMUX socket: its default `cmuxOnly` mode admits only processes descended from CMUX, and the sidebar runs under launchd. It would also need a new sandbox exception and give the sidebar full control of CMUX.
- A CMUX custom (interpreted) sidebar, which can call `workspace.reorder`: a different sidebar type, not this ExtensionKit sidebar.
- Moving surfaces between workspaces or across panes: the snapshot has no pane identity.
- Guessing order identity from titles or positions.

Consequence: Maestro and CMUX can show different orders; menu text says so. When the SDK adds a reorder action scope, adding a host backend and selecting it in the factory is the whole switch: for that kind, CMUX's snapshot order is shown, moves go to CMUX, and the local overlay is bypassed but not deleted. Two options for the saved order then: push it to CMUX once, or drop it. Pushing is recommended, so the human's order survives the switch; it is not built yet. The order follows exact UUIDs, so an item CMUX re-creates with a new UUID starts in CMUX's position. If a CMUX window's UUID changes, its workspace order is lost. Storage is bounded (256 lists of up to 512 IDs, 1 MiB). When full it evicts the least recently *changed* surface list first, and workspace lists only when no surface list is left; lists for closed workspaces are not pruned until then. Drag types are declared in the sidebar's `Info.plist`, and the drag allows a move even if the host reports its window as outside the extension. Drag works in the live CMUX host (owner pilot, 2026-10-14); the menu and VoiceOver actions are the non-drag path.
