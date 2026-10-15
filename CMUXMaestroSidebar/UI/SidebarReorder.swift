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
    /// Declared under `UTExportedTypeDeclarations` in `CMUXMaestroSidebar/Info.plist`.
    var dragTypeIdentifier: String { "com.jdylanmc.CMUXMaestroPreview.sidebar-order.\(rawValue)" }
    var dragType: UTType { UTType(exportedAs: dragTypeIdentifier, conformingTo: .data) }
}

/// Sidebar settings' order section, driven only by the backend.
@MainActor
struct SidebarReorderSettings {
    static let resetTitle = "Reset sidebar order"
    static let resetHelp = "Show every workspace and surface in CMUX's order again, in every window. CMUX is unchanged."
    let backend: any SidebarReorderBackend

    var copy: String {
        let how = "Drag a workspace or surface, or use Move Up and Move Down in its actions menu."
        switch (backend.authority(for: .workspaces), backend.authority(for: .surfaces)) {
        case (.maestroLocal, .maestroLocal): return "\(how) \(SidebarReorderContext.localHelp)"
        case (.host, .host): return "\(how) \(SidebarReorderContext.hostHelp)"
        case (.host, .maestroLocal): return "\(how) Workspace moves change CMUX's order; surface moves change Maestro's order only."
        case (.maestroLocal, .host): return "\(how) Surface moves change CMUX's order; workspace moves change Maestro's order only."
        }
    }

    /// Hidden whenever any kind is host-ordered, so it can't wipe an order awaiting migration.
    var resetShown: Bool { backend.canResetAll }
    var resetEnabled: Bool { resetShown && backend.hasSavedOrder }
    var notice: String? { backend.notice }

    func reset() {
        guard resetShown else { return }
        backend.resetAll()
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
    let titles: [UUID: String]
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
        titles = list.titles
        self.session = session
        self.backend = backend
    }

    static func empty(backend: any SidebarReorderBackend, session: SidebarReorderDragSession) -> Self {
        .init(SidebarReorderComposition.compose([UUID](), kind: .surfaces, scope: nil, backend: backend) {
            SidebarOrderItem(id: $0, pinned: false)
        }, backend: backend, session: session)
    }

    var help: String { authority == .host ? Self.hostHelp : Self.localHelp }

    var unavailable: String? {
        if scope == nil { return "CMUX did not report this window's identity, so reordering is unavailable." }
        if let refusal = SidebarReorderComposition.refusal(items) { return refusal.notice }
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

    /// Why this row can't move: the whole list is unavailable, or its own pin state is unknown.
    var unavailable: String? {
        if let reason = context.unavailable { return reason }
        if item?.pinned == nil { return SidebarOrderRefusal.pinUnknown.notice }
        return nil
    }

    func step(_ direction: SidebarOrderDirection) -> SidebarOrderPlacement? {
        guard unavailable == nil else { return nil }
        return SidebarReorderComposition.step(id, direction, visible: context.visible, items: context.items)
    }

    @discardableResult
    func move(_ placement: SidebarOrderPlacement) -> SidebarReorderOutcome {
        guard let scope = context.scope else { return .refused(context.unavailable ?? SidebarOrderRefusal.outsideScope.notice) }
        if let reason = unavailable { return .refused(reason) }
        switch scope.kind {
        case .workspaces: return context.backend.moveWorkspace(id, placement, window: scope.id, siblings: context.items)
        case .surfaces: return context.backend.moveSurface(id, placement, workspace: scope.id, siblings: context.items)
        }
    }

    /// Spoken result of a VoiceOver move: success and what to announce.
    func announcedMove(_ placement: SidebarOrderPlacement) -> SidebarReorderAnnouncement {
        let neighbor = context.titles[placement.target] ?? "the next \(noun)"
        switch move(placement) {
        case .applied, .pending:
            if case .before = placement { return .init(succeeded: true, message: "Moved above \(neighbor)") }
            return .init(succeeded: true, message: "Moved below \(neighbor)")
        case .refused(let reason):
            return .init(succeeded: false, message: reason)
        }
    }

    func resetScope() {
        guard let scope = context.scope, context.capabilities.canReset else { return }
        context.backend.resetOrder(scope)
    }

    private var item: SidebarOrderItem? { context.items.first { $0.id == id } }
    var pinned: Bool { item?.pinned == true }

    /// Accepts only this sidebar's own drag of a sibling in the same group (block and pin).
    func accepts(dragging: (scope: SidebarOrderScope, id: UUID)?) -> Bool {
        guard unavailable == nil, let dragging, dragging.scope == context.scope, dragging.id != id,
              let item, let moving = context.items.first(where: { $0.id == dragging.id }) else { return false }
        return moving.pinned == item.pinned && moving.block == item.block
    }

    var dragSource: SidebarReorderSource? {
        guard let scope = context.scope, unavailable == nil else { return nil }
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
        if let up = step(.up) { actions.append(.init(name: "Move up\(suffix)", perform: { announcedMove(up) })) }
        if let down = step(.down) { actions.append(.init(name: "Move down\(suffix)", perform: { announcedMove(down) })) }
        return actions
    }
}

struct SidebarReorderAnnouncement: Equatable {
    let succeeded: Bool
    let message: String
}

struct SidebarReorderAccessibilityAction {
    let name: String
    let perform: @MainActor () -> SidebarReorderAnnouncement
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
    static func placement(_ handle: SidebarReorderHandle?, otherwise fixed: FixedPlacement = .listUnavailable) -> Self {
        guard let handle else { return .placement(fixed) }
        let context = handle.context
        if let reason = handle.unavailable {
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

/// Drop handling for one row, independent of SwiftUI's `DropInfo` so it can be tested.
@MainActor
struct SidebarReorderDropTarget {
    let handle: SidebarReorderHandle
    let height: Double

    private var session: SidebarReorderDragSession { handle.context.session }

    func placement(locationY: Double) -> SidebarOrderPlacement {
        SidebarReorderDrop.placement(locationY: locationY, height: height, target: handle.id)
    }

    /// `hasPayload`: the drag carries this list kind's declared type.
    func validate(hasPayload: Bool) -> Bool {
        hasPayload && handle.accepts(dragging: session.dragging)
    }

    /// Shows the insertion cue; false means the drop is forbidden here.
    func update(hasPayload: Bool, locationY: Double) -> Bool {
        guard validate(hasPayload: hasPayload), let scope = handle.context.scope else { return false }
        session.show(.init(scope: scope, placement: placement(locationY: locationY)))
        return true
    }

    func exit() {
        if session.indicator?.placement.target == handle.id { session.show(nil) }
    }

    func perform(hasPayload: Bool, locationY: Double) -> Bool {
        defer { session.end() }
        guard validate(hasPayload: hasPayload), let dragging = session.dragging else { return false }
        let outcome = SidebarReorderHandle(context: handle.context, id: dragging.id, noun: handle.noun)
            .move(placement(locationY: locationY))
        if case .refused = outcome { return false }
        return true
    }
}

private struct SidebarReorderDropDelegate: DropDelegate {
    let target: SidebarReorderDropTarget

    private func hasPayload(_ info: DropInfo) -> Bool {
        guard let kind = target.handle.context.scope?.kind else { return false }
        return info.hasItemsConforming(to: [kind.dragType])
    }

    func validateDrop(info: DropInfo) -> Bool { target.validate(hasPayload: hasPayload(info)) }
    func dropEntered(info: DropInfo) { _ = dropUpdated(info: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: target.update(hasPayload: hasPayload(info), locationY: info.location.y) ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) { target.exit() }

    func performDrop(info: DropInfo) -> Bool {
        target.perform(hasPayload: hasPayload(info), locationY: info.location.y)
    }
}

private struct SidebarReorderDropModifier: ViewModifier {
    let handle: SidebarReorderHandle?
    @State private var height: Double = 0

    func body(content: Content) -> some View {
        if let handle, let kind = handle.context.scope?.kind, handle.unavailable == nil {
            content
                .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { height = $0 }
                .onDrop(of: [kind.dragType], delegate: SidebarReorderDropDelegate(
                    target: SidebarReorderDropTarget(handle: handle, height: height)
                ))
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
        // A remote ExtensionKit view may report its host's window as outside this
        // application. Acceptance is gated by the in-process drag session instead.
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        reorder?.ended()
    }
}
