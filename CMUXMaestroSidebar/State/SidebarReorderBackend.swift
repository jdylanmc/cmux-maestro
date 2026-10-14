import Foundation

/// Who decides a sibling list's order (ADR 0021).
nonisolated enum SidebarReorderAuthority: Equatable, Sendable {
    /// Maestro's saved order (`sidebar-order.json`) is applied over CMUX's order.
    case maestroLocal
    /// CMUX's snapshot order is the truth; the local overlay is bypassed.
    case host
}

nonisolated struct SidebarReorderCapabilities: Equatable, Sendable {
    var canMove: Bool
    var canReset: Bool

    static let none = Self(canMove: false, canReset: false)
    static let full = Self(canMove: true, canReset: true)
}

/// The one seam every move or reset goes through, whether from drag, menu or VoiceOver.
/// Operations take exact CMUX UUIDs only (ADR 0002). `siblings` is the current CMUX
/// order of the list with pin flags; a host backend may ignore it.
@MainActor
protocol SidebarReorderBackend: AnyObject {
    func authority(for kind: SidebarOrderScope.Kind) -> SidebarReorderAuthority
    func capabilities(for kind: SidebarOrderScope.Kind) -> SidebarReorderCapabilities
    /// Saved Maestro order for one list, or nil. Ignored unless the authority is local.
    func overlay(for scope: SidebarOrderScope) -> [UUID]?
    func moveWorkspace(_ id: UUID, _ placement: SidebarOrderPlacement, window: UUID, siblings: [SidebarOrderItem])
    func moveSurface(_ id: UUID, _ placement: SidebarOrderPlacement, workspace: UUID, siblings: [SidebarOrderItem])
    func resetOrder(_ scope: SidebarOrderScope)
    /// Latest visible failure, if any.
    var notice: String? { get }
}

/// Today's behaviour: Maestro-only order in the sidebar container. Never touches CMUX.
@MainActor
final class LocalSidebarReorderBackend: SidebarReorderBackend {
    private let store: SidebarPreferences

    init(store: SidebarPreferences) { self.store = store }

    func authority(for kind: SidebarOrderScope.Kind) -> SidebarReorderAuthority { .maestroLocal }
    func capabilities(for kind: SidebarOrderScope.Kind) -> SidebarReorderCapabilities { .full }
    func overlay(for scope: SidebarOrderScope) -> [UUID]? { store.order.ids(for: scope) }

    func moveWorkspace(_ id: UUID, _ placement: SidebarOrderPlacement, window: UUID, siblings: [SidebarOrderItem]) {
        store.applyOrder(.move(id, placement, scope: .workspaces(window: window), items: siblings))
    }

    func moveSurface(_ id: UUID, _ placement: SidebarOrderPlacement, workspace: UUID, siblings: [SidebarOrderItem]) {
        store.applyOrder(.move(id, placement, scope: .surfaces(workspace: workspace), items: siblings))
    }

    func resetOrder(_ scope: SidebarOrderScope) { store.applyOrder(.reset(scope)) }
    var notice: String? { store.orderNotice }
}

/// Routes each list kind to its own backend so workspaces and surfaces can switch
/// to native CMUX ordering independently.
@MainActor
final class SidebarScopedReorderBackend: SidebarReorderBackend {
    nonisolated struct Selection: Equatable, Sendable {
        let workspaces: SidebarReorderAuthority
        let surfaces: SidebarReorderAuthority
    }

    let workspaces: any SidebarReorderBackend
    let surfaces: any SidebarReorderBackend

    init(workspaces: any SidebarReorderBackend, surfaces: any SidebarReorderBackend) {
        self.workspaces = workspaces
        self.surfaces = surfaces
    }

    static func localOnly(store: SidebarPreferences) -> SidebarScopedReorderBackend {
        let local = LocalSidebarReorderBackend(store: store)
        return .init(workspaces: local, surfaces: local)
    }

    var selection: Selection {
        .init(workspaces: workspaces.authority(for: .workspaces), surfaces: surfaces.authority(for: .surfaces))
    }

    private func backend(_ kind: SidebarOrderScope.Kind) -> any SidebarReorderBackend {
        kind == .workspaces ? workspaces : surfaces
    }

    func authority(for kind: SidebarOrderScope.Kind) -> SidebarReorderAuthority { backend(kind).authority(for: kind) }
    func capabilities(for kind: SidebarOrderScope.Kind) -> SidebarReorderCapabilities { backend(kind).capabilities(for: kind) }
    func overlay(for scope: SidebarOrderScope) -> [UUID]? { backend(scope.kind).overlay(for: scope) }

    func moveWorkspace(_ id: UUID, _ placement: SidebarOrderPlacement, window: UUID, siblings: [SidebarOrderItem]) {
        workspaces.moveWorkspace(id, placement, window: window, siblings: siblings)
    }

    func moveSurface(_ id: UUID, _ placement: SidebarOrderPlacement, workspace: UUID, siblings: [SidebarOrderItem]) {
        surfaces.moveSurface(id, placement, workspace: workspace, siblings: siblings)
    }

    func resetOrder(_ scope: SidebarOrderScope) { backend(scope.kind).resetOrder(scope) }

    var notice: String? {
        if workspaces === surfaces { return workspaces.notice }
        let notices = [workspaces.notice, surfaces.notice].compactMap { $0 }
        return notices.isEmpty ? nil : notices.joined(separator: " ")
    }
}

/// One sibling list as displayed: CMUX order, or Maestro's overlay when local.
nonisolated struct SidebarReorderList<Value> {
    let kind: SidebarOrderScope.Kind
    /// Nil when CMUX did not report the list's owner identity (e.g. no window ID).
    let scope: SidebarOrderScope?
    let authority: SidebarReorderAuthority
    let capabilities: SidebarReorderCapabilities
    /// Every sibling in CMUX order, including rows not shown.
    let items: [SidebarOrderItem]
    /// Shown rows in display order.
    let displayed: [Value]
    let visible: [UUID]
    let hasCustomOrder: Bool
}

/// Display-order composition. The UI asks this, never `SidebarOrdering`, for order.
@MainActor
enum SidebarReorderComposition {
    static func compose<Value>(
        _ values: [Value], kind: SidebarOrderScope.Kind, scope: SidebarOrderScope?,
        backend: any SidebarReorderBackend, shown: ((Value) -> Bool)? = nil,
        item: (Value) -> SidebarOrderItem
    ) -> SidebarReorderList<Value> {
        let authority = backend.authority(for: kind)
        // Native authority bypasses the overlay even if a saved local order remains on disk.
        let overlay = authority == .maestroLocal ? scope.flatMap(backend.overlay(for:)) : nil
        let ordered = SidebarOrdering.arrange(values, saved: overlay, item: item)
        let displayed = shown.map { ordered.filter($0) } ?? ordered
        return .init(
            kind: kind, scope: scope, authority: authority, capabilities: backend.capabilities(for: kind),
            items: values.map(item), displayed: displayed, visible: displayed.map { item($0).id },
            hasCustomOrder: overlay != nil
        )
    }

    static func isUnambiguous(_ items: [SidebarOrderItem]) -> Bool { SidebarOrdering.isUnambiguous(items) }

    static func step(
        _ id: UUID, _ direction: SidebarOrderDirection, visible: [UUID], items: [SidebarOrderItem]
    ) -> SidebarOrderPlacement? {
        SidebarOrdering.step(id, direction, visible: visible, items: items)
    }
}
