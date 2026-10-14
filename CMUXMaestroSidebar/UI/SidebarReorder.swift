import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The row being dragged and the insertion cue being shown. In-process only:
/// drops are accepted from this sidebar's own drag, never from pasteboard text.
@Observable
@MainActor
final class SidebarReorderDragSession {
    struct Indicator: Equatable {
        let scope: SidebarOrderScope
        let placement: SidebarOrderPlacement
    }

    private(set) var dragging: (scope: SidebarOrderScope, id: UUID)?
    private(set) var indicator: Indicator?

    func begin(_ scope: SidebarOrderScope, _ id: UUID) {
        dragging = (scope, id)
        indicator = nil
    }

    func show(_ indicator: Indicator?) {
        if self.indicator != indicator { self.indicator = indicator }
    }

    func end() {
        dragging = nil
        indicator = nil
    }
}

nonisolated extension SidebarOrderScope.Kind {
    var dragType: UTType {
        UTType(exportedAs: "com.jdylanmc.CMUXMaestroPreview.sidebar-order.\(rawValue)")
    }
}

/// One sibling list (all workspaces in a window, or all surfaces in a workspace).
/// Every move or reset goes through `backend`; order comes from `SidebarReorderComposition`.
@MainActor
struct SidebarReorderContext {
    static let localHelp = "Changes Maestro's order only; CMUX's order is unchanged."
    static let hostHelp = "Changes CMUX's order."
    let kind: SidebarOrderScope.Kind
    let scope: SidebarOrderScope?
    let authority: SidebarReorderAuthority
    let capabilities: SidebarReorderCapabilities
    let items: [SidebarOrderItem]
    let visible: [UUID]
    let hasCustomOrder: Bool
    let session: SidebarReorderDragSession
    let backend: any SidebarReorderBackend

    init<Value>(_ list: SidebarReorderList<Value>, backend: any SidebarReorderBackend, session: SidebarReorderDragSession) {
        kind = list.kind
        scope = list.scope
        authority = list.authority
        capabilities = list.capabilities
        items = list.items
        visible = list.visible
        hasCustomOrder = list.hasCustomOrder
        self.session = session
        self.backend = backend
    }

    var help: String { authority == .host ? Self.hostHelp : Self.localHelp }

    var unavailable: String? {
        if scope == nil { return "CMUX did not report this window's identity, so reordering is unavailable." }
        if !SidebarReorderComposition.isUnambiguous(items) { return SidebarOrderRefusal.ambiguous.notice }
        if !capabilities.canMove { return "CMUX does not allow reordering this list." }
        return nil
    }

    func handle(for id: UUID, noun: String) -> SidebarReorderHandle {
        .init(context: self, id: id, noun: noun)
    }
}

@MainActor
struct SidebarReorderHandle {
    let context: SidebarReorderContext
    let id: UUID
    let noun: String

    func step(_ direction: SidebarOrderDirection) -> SidebarOrderPlacement? {
        guard context.unavailable == nil else { return nil }
        return SidebarReorderComposition.step(id, direction, visible: context.visible, items: context.items)
    }

    func move(_ placement: SidebarOrderPlacement) {
        guard let scope = context.scope, context.unavailable == nil else { return }
        switch scope.kind {
        case .workspaces: context.backend.moveWorkspace(id, placement, window: scope.id, siblings: context.items)
        case .surfaces: context.backend.moveSurface(id, placement, workspace: scope.id, siblings: context.items)
        }
    }

    func resetScope() {
        guard let scope = context.scope, context.capabilities.canReset else { return }
        context.backend.resetOrder(scope)
    }

    var pinned: Bool { context.items.first { $0.id == id }?.pinned ?? false }

    /// Accepts only this sidebar's own drag of a sibling in the same pin group.
    func accepts(dragging: (scope: SidebarOrderScope, id: UUID)?) -> Bool {
        guard context.unavailable == nil, let dragging, dragging.scope == context.scope, dragging.id != id,
              let moving = context.items.first(where: { $0.id == dragging.id }) else { return false }
        return moving.pinned == pinned
    }

    var dragSource: SidebarReorderSource? {
        guard let scope = context.scope, context.unavailable == nil else { return nil }
        let session = context.session
        return .init(
            type: NSPasteboard.PasteboardType(scope.kind.dragType.identifier),
            payload: id.uuidString,
            began: { session.begin(scope, id) },
            ended: { session.end() },
            actions: accessibilityActions
        )
    }

    var accessibilityActions: [SidebarReorderAccessibilityAction] {
        let suffix = context.authority == .host ? "" : " in Maestro"
        var actions: [SidebarReorderAccessibilityAction] = []
        if let up = step(.up) { actions.append(.init(name: "Move up\(suffix)", perform: { move(up) })) }
        if let down = step(.down) { actions.append(.init(name: "Move down\(suffix)", perform: { move(down) })) }
        return actions
    }
}

struct SidebarReorderAccessibilityAction {
    let name: String
    let perform: @MainActor () -> Void
}

struct SidebarReorderSource {
    let type: NSPasteboard.PasteboardType
    let payload: String
    let began: @MainActor () -> Void
    let ended: @MainActor () -> Void
    let actions: [SidebarReorderAccessibilityAction]
}

private struct SidebarReorderSourceKey: EnvironmentKey {
    static let defaultValue: SidebarReorderSource? = nil
}

extension EnvironmentValues {
    var sidebarReorderSource: SidebarReorderSource? {
        get { self[SidebarReorderSourceKey.self] }
        set { self[SidebarReorderSourceKey.self] = newValue }
    }
}

extension SidebarRowActionGroup {
    static func placement(_ handle: SidebarReorderHandle?) -> Self {
        guard let handle else { return .placement }
        let context = handle.context
        if let reason = context.unavailable {
            return .init(title: "Organization", actions: [
                .unavailable("Move Up", reason), .unavailable("Move Down", reason)
            ], footnote: context.help)
        }
        let groupName = handle.pinned ? "pinned \(handle.noun)s" : "\(handle.noun)s"
        var actions: [SidebarRowAction] = [
            handle.step(.up).map { placement in .init(title: "Move Up", perform: { handle.move(placement) }) }
                ?? .unavailable("Move Up", "Already first among \(groupName)."),
            handle.step(.down).map { placement in .init(title: "Move Down", perform: { handle.move(placement) }) }
                ?? .unavailable("Move Down", "Already last among \(groupName).")
        ]
        if context.capabilities.canReset {
            let title = context.kind == .workspaces ? "Reset Workspace Order" : "Reset Order in Workspace"
            actions.append(context.hasCustomOrder
                ? .init(title: title, perform: { handle.resetScope() })
                : .unavailable(title, "Already in CMUX's order."))
        }
        return .init(title: "Organization", actions: actions, footnote: context.help)
    }
}

private struct SidebarReorderDropDelegate: DropDelegate {
    let handle: SidebarReorderHandle
    let height: Double

    private func placement(_ info: DropInfo) -> SidebarOrderPlacement {
        SidebarReorderDrop.placement(locationY: info.location.y, height: height, target: handle.id)
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard let kind = handle.context.scope?.kind else { return false }
        return info.hasItemsConforming(to: [kind.dragType]) && handle.accepts(dragging: handle.context.session.dragging)
    }

    func dropEntered(info: DropInfo) { _ = dropUpdated(info: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info), let scope = handle.context.scope else {
            return DropProposal(operation: .forbidden)
        }
        handle.context.session.show(.init(scope: scope, placement: placement(info)))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if handle.context.session.indicator?.placement.target == handle.id { handle.context.session.show(nil) }
    }

    func performDrop(info: DropInfo) -> Bool {
        let session = handle.context.session
        defer { session.end() }
        guard validateDrop(info: info), let dragging = session.dragging else { return false }
        SidebarReorderHandle(context: handle.context, id: dragging.id, noun: handle.noun).move(placement(info))
        return true
    }
}

private struct SidebarReorderDropModifier: ViewModifier {
    let handle: SidebarReorderHandle?
    @State private var height: Double = 0

    func body(content: Content) -> some View {
        if let handle, let kind = handle.context.scope?.kind, handle.context.unavailable == nil {
            content
                .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { height = $0 }
                .onDrop(of: [kind.dragType], delegate: SidebarReorderDropDelegate(handle: handle, height: height))
                .overlay(alignment: edge(handle) ?? .top) {
                    if edge(handle) != nil {
                        Capsule().fill(Color.accentColor)
                            .frame(height: 2)
                            .padding(.horizontal, 2)
                            .offset(y: edge(handle) == .top ? -1 : 1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        } else {
            content
        }
    }

    private func edge(_ handle: SidebarReorderHandle) -> Alignment? {
        guard let indicator = handle.context.session.indicator, indicator.scope == handle.context.scope,
              indicator.placement.target == handle.id else { return nil }
        if case .before = indicator.placement { return .top }
        return .bottom
    }
}

extension View {
    /// Drop target and insertion cue for a whole row, including the children it carries.
    func sidebarReorderDrop(_ handle: SidebarReorderHandle?) -> some View {
        modifier(SidebarReorderDropModifier(handle: handle))
    }
}

extension SidebarTitleNativeButton: NSDraggingSource {
    /// Starts a reorder drag once the pointer moves; otherwise the click proceeds normally.
    func trackReorderDrag(_ event: NSEvent) -> Bool {
        guard let source = reorder, let window, event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control), NSEvent.pressedMouseButtons & 1 == 1 else { return false }
        let start = event.locationInWindow
        while let next = window.nextEvent(
            matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture, inMode: .eventTracking, dequeue: false
        ) {
            guard next.type == .leftMouseDragged else { return false }
            _ = window.nextEvent(matching: .leftMouseDragged)
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= 4 {
                beginReorderDrag(source, event: event)
                return true
            }
        }
        return false
    }

    private func beginReorderDrag(_ source: SidebarReorderSource, event: NSEvent) {
        preview.dismiss()
        let item = NSPasteboardItem()
        item.setString(source.payload, forType: source.type)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        dragging.setDraggingFrame(bounds, contents: image)
        source.began()
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        reorder?.ended()
    }
}
