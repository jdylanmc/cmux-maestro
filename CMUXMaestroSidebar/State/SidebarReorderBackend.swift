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

nonisolated enum SidebarReorderOutcome: Equatable, Sendable {
    case applied
    /// Accepted by an asynchronous backend; the next snapshot shows the result.
    case pending
    case refused(String)
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
    @discardableResult
    func moveWorkspace(_ id: UUID, _ placement: SidebarOrderPlacement, window: UUID, siblings: [SidebarOrderItem]) -> SidebarReorderOutcome
    @discardableResult
    func moveSurface(_ id: UUID, _ placement: SidebarOrderPlacement, workspace: UUID, siblings: [SidebarOrderItem]) -> SidebarReorderOutcome
    func resetOrder(_ scope: SidebarOrderScope)
    /// Settings' global reset. False when any kind it covers is host-ordered, so a reset
    /// can never wipe a saved order that is waiting to be migrated (ADR 0021).
    var canResetAll: Bool { get }
    /// Whether anything is saved (or unreadable) for the global reset to clear.
    var hasSavedOrder: Bool { get }
    func resetAll()
    /// Re-read any stored order (on appear and activation).
    func refresh()
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

    func moveWorkspace(_ id: UUID, _ placement: SidebarOrderPlacement, window: UUID, siblings: [SidebarOrderItem]) -> SidebarReorderOutcome {
        apply(.move(id, placement, scope: .workspaces(window: window), items: siblings))
    }

    func moveSurface(_ id: UUID, _ placement: SidebarOrderPlacement, workspace: UUID, siblings: [SidebarOrderItem]) -> SidebarReorderOutcome {
        apply(.move(id, placement, scope: .surfaces(workspace: workspace), items: siblings))
    }

    private func apply(_ change: SidebarOrderChange) -> SidebarReorderOutcome {
        store.applyOrder(change)
        return store.orderNotice.map(SidebarReorderOutcome.refused) ?? .applied
    }

    func resetOrder(_ scope: SidebarOrderScope) { store.applyOrder(.reset(scope)) }
    var canResetAll: Bool { true }
    var hasSavedOrder: Bool { store.hasSavedOrder || store.orderNotice != nil }
    func resetAll() { store.resetOrder() }
    func refresh() { store.refreshOrder() }
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

    func moveWorkspace(_ id: UUID, _ placement: SidebarOrderPlacement, window: UUID, siblings: [SidebarOrderItem]) -> SidebarReorderOutcome {
        workspaces.moveWorkspace(id, placement, window: window, siblings: siblings)
    }

    func moveSurface(_ id: UUID, _ placement: SidebarOrderPlacement, workspace: UUID, siblings: [SidebarOrderItem]) -> SidebarReorderOutcome {
        surfaces.moveSurface(id, placement, workspace: workspace, siblings: siblings)
    }

    func resetOrder(_ scope: SidebarOrderScope) { backend(scope.kind).resetOrder(scope) }

    /// Only when every kind is Maestro-local; the local file covers both kinds.
    var canResetAll: Bool {
        selection == .init(workspaces: .maestroLocal, surfaces: .maestroLocal)
            && workspaces.canResetAll && surfaces.canResetAll
    }

    var hasSavedOrder: Bool { workspaces.hasSavedOrder || surfaces.hasSavedOrder }

    func resetAll() {
        guard canResetAll else { return }
        workspaces.resetAll()
        if surfaces !== workspaces { surfaces.resetAll() }
    }

    func refresh() {
        workspaces.refresh()
        if surfaces !== workspaces { surfaces.refresh() }
    }

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
    /// Row titles for announcements, by ID.
    var titles: [UUID: String] = [:]
}

/// Display-order composition. The UI asks this, never `SidebarOrdering`, for order.
@MainActor
enum SidebarReorderComposition {
    static func compose<Value>(
        _ values: [Value], kind: SidebarOrderScope.Kind, scope: SidebarOrderScope?,
        backend: any SidebarReorderBackend, shown: ((Value) -> Bool)? = nil,
        title: ((Value) -> String)? = nil,
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
            hasCustomOrder: overlay != nil,
            titles: title.map { title in
                Dictionary(values.map { (item($0).id, title($0)) }, uniquingKeysWith: { first, _ in first })
            } ?? [:]
        )
    }

    /// Why the whole list can't be reordered (duplicate IDs, unknown pin state), or nil.
    static func refusal(_ items: [SidebarOrderItem]) -> SidebarOrderRefusal? { SidebarOrdering.refusal(items) }

    static func step(
        _ id: UUID, _ direction: SidebarOrderDirection, visible: [UUID], items: [SidebarOrderItem]
    ) -> SidebarOrderPlacement? {
        SidebarOrdering.step(id, direction, visible: visible, items: items)
    }
}
