import CmuxExtensionKit

/// The only place that decides who orders the sidebar (ADR 0021).
@MainActor
enum SidebarReorderBackends {
    /// Selects a backend per list kind from the host's granted actions.
    ///
    /// Today `CmuxExtensionActionScope` has no reorder or move scope, so both kinds are
    /// always Maestro-local. `grantedActionScopes` and `host` are taken now so the switch
    /// to native ordering changes only this function.
    ///
    /// EXTENSION POINT — when the SDK adds reordering:
    /// 1. Add the new scope (e.g. `.reorderWorkspace`, `.reorderSurface`) to the manifest's
    ///    `actionScopes` in `CMUXMaestroSidebarExtension`.
    /// 2. Add a `HostSidebarReorderBackend` that conforms to `SidebarReorderBackend`:
    ///    `authority` returns `.host`; `capabilities` reports only what CMUX accepts
    ///    (reset is usually unsupported because CMUX's order is the truth); moves call the
    ///    new `CmuxSidebarHost` methods (the matching `CmuxSidebarAction` cases, backed by
    ///    the host's `workspace.reorder` / `surface.reorder`) with the exact UUIDs, and
    ///    surface refusals through `notice`.
    /// 3. Below, pick it per kind when the scope is granted, keeping local otherwise.
    /// Nothing else changes: display composition bypasses the local overlay for a
    /// `.host` kind, and the saved local order stays in `sidebar-order.json`.
    static func make(
        grantedActionScopes: Set<CmuxExtensionActionScope>, host: CmuxSidebarHost, store: SidebarPreferences
    ) -> SidebarScopedReorderBackend {
        let local = LocalSidebarReorderBackend(store: store)
        // TODO(ADR 0021): when the SDK grows reorder scopes, select per kind here, e.g.
        //   workspaces: grantedActionScopes.contains(.reorderWorkspace) ? host backend : local
        //   surfaces:   grantedActionScopes.contains(.reorderSurface)   ? host backend : local
        // These cases do not exist yet, so there is nothing to detect.
        _ = (grantedActionScopes, host)
        return SidebarScopedReorderBackend(workspaces: local, surfaces: local)
    }
}
