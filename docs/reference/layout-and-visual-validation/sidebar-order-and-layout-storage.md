# Sidebar order and layout storage

[↑ Taskboard, layout, and visual validation](../layout-and-visual-validation.md) | [← Agent blocks and expansion](agent-blocks-and-expansion.md) | [Synthetic layout review images →](synthetic-layout-review-images.md)

Sidebar order ([ADR 0021](../../adr/0021-sidebar-order-is-maestro-local.md)) is a
separate versioned `CMUXMaestroPreview/sidebar-order.json` record in the same
container, using the same coordinator. It holds one list of CMUX UUIDs per window
(workspaces) and per workspace (surfaces) and is never sent to CMUX. A list is
pruned to present IDs only when that list is saved, and dropped when it matches
CMUX's order again. Other windows' lists are never pruned from a current snapshot.
Storage is bounded to **256 lists / 512 IDs each / 1 MiB**. When full, the least
recently changed surface list is evicted first; workspace lists go only when no
surface list is left. Lists for closed workspaces are not pruned before that. Unreadable or unknown-schema files show CMUX's order and a
recoverable notice. Only **Reset sidebar order** replaces them. Drag sources are
the row title controls; drops show a 2-point insertion line at the nearer edge of
the whole row, including the children it carries.
All moves and resets go through `SidebarReorderBackend`; the backend is chosen
per kind in `SidebarReorderBackends.make` (always Maestro-local today). Primary
managed agents share their workspace's surface list as a first block, keyed by
their CMUX surface UUID. Blocks and pin groups keep their slots. Drag types
`com.jdylanmc.CMUXMaestroPreview.sidebar-order.{workspaces,surfaces}` are declared
under `UTExportedTypeDeclarations` in `CMUXMaestroSidebar/Info.plist`.

Layout's file/store types are thin adapters over same preference coordinator
used by history and acknowledgements. Only layout's mutations and safe eviction
policy remain feature-specific. Existing layout path and version-1 schema
unchanged: no layout migration or rewrite on open. Missing layout
files mean Compact and fully expanded. Reads/refreshes do not create a file.
This lazy mode is explicit. History/acknowledgement migration-on-open is unchanged.
Lazy stores observe nearest existing container, so first-file creation in
another process also reaches already-open views, without writing defaults first.
All three records stay separate. Tests and offscreen renders inject all three
storage paths and never fall back to production layout singleton.
