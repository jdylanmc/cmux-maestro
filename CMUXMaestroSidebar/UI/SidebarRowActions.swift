import SwiftUI

@MainActor
struct SidebarRowAction {
    let title: String
    var unavailable: String? = nil
    let perform: @MainActor () -> Void

    static func unavailable(_ title: String, _ reason: String) -> Self {
        .init(title: title, unavailable: reason, perform: {})
    }
}

@MainActor
struct SidebarRowActionGroup {
    let title: String
    let actions: [SidebarRowAction]
    /// Disabled explanatory line shown after the group's actions.
    var footnote: String? = nil
}

@MainActor
final class SidebarRowMenuPresenter: NSObject {
    var groups: [SidebarRowActionGroup] = []
    weak var anchor: NSView?
    var dismissPreview: () -> Void = {}
    var preview: (() -> Bool)?
    var focusChanged: (Bool) -> Void = { _ in }
    var present: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let preview {
            let item = NSMenuItem(title: "Preview details", action: #selector(invoke(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = SidebarRowAction(title: "Preview details", perform: {
                // Let native menu tracking finish before granting the preview keyboard focus.
                Task { @MainActor in _ = preview() }
            })
            menu.addItem(item)
            menu.addItem(.separator())
        }
        for group in groups where !group.actions.isEmpty {
            let parent = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: group.title)
            submenu.autoenablesItems = false
            for action in group.actions {
                let item = NSMenuItem(title: action.title, action: #selector(invoke(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = action
                item.isEnabled = action.unavailable == nil
                item.toolTip = action.unavailable
                submenu.addItem(item)
                if let reason = action.unavailable {
                    let explanation = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
                    explanation.isEnabled = false
                    explanation.indentationLevel = 1
                    submenu.addItem(explanation)
                }
            }
            if let footnote = group.footnote {
                submenu.addItem(.separator())
                let note = NSMenuItem(title: footnote, action: nil, keyEquivalent: "")
                note.isEnabled = false
                submenu.addItem(note)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }
        return menu
    }

    @objc func invoke(_ item: NSMenuItem) {
        guard item.isEnabled, let action = item.representedObject as? SidebarRowAction,
              action.unavailable == nil else { return }
        action.perform()
    }

    func show(at point: NSPoint? = nil) {
        guard let anchor, anchor.window != nil, !anchor.visibleRect.isEmpty else { return }
        dismissPreview()
        present(menu(), point ?? NSPoint(x: anchor.bounds.minX, y: anchor.bounds.maxY), anchor)
    }

    func detach() {
        anchor = nil
        groups = []
        dismissPreview = {}
        preview = nil
        focusChanged = { _ in }
    }
}

final class SidebarRowMenuAnchorView: NSView {
    var presenter: SidebarRowMenuPresenter?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, self.handles(event) else { return event }
            self.presenter?.show(at: self.convert(event.locationInWindow, from: nil))
            return nil
        }
    }

    func handles(_ event: NSEvent) -> Bool {
        guard event.window === window, window != nil,
              event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
              bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil)) else { return false }
        var hit = window?.contentView?.hitTest(event.locationInWindow)
        while let view = hit {
            if view is SidebarIconNativeButton { return false }
            hit = view.superview
        }
        return true
    }

    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if presenter?.anchor === self { presenter?.detach() }
        presenter = nil
    }
}

private struct SidebarRowMenuAnchor: NSViewRepresentable {
    let presenter: SidebarRowMenuPresenter
    func makeNSView(context: Context) -> SidebarRowMenuAnchorView { SidebarRowMenuAnchorView() }
    func updateNSView(_ view: SidebarRowMenuAnchorView, context: Context) {
        view.presenter = presenter
        presenter.anchor = view
    }
    static func dismantleNSView(_ view: SidebarRowMenuAnchorView, coordinator: ()) { view.detach() }
}

private struct SidebarRowMenuKey: EnvironmentKey {
    static let defaultValue: SidebarRowMenuPresenter? = nil
}

extension EnvironmentValues {
    var sidebarRowMenu: SidebarRowMenuPresenter? {
        get { self[SidebarRowMenuKey.self] }
        set { self[SidebarRowMenuKey.self] = newValue }
    }
}

extension View {
    /// Keep row glyphs on the existing status column, independent of their intrinsic width.
    func sidebarTrailingIconSlot() -> some View {
        frame(width: 12, alignment: .center)
    }

    func sidebarRowActions(title: String, groups: [SidebarRowActionGroup]) -> some View {
        SidebarRowActions(title: title, groups: groups) { self } trailing: { EmptyView() }
    }

    /// `trailing` sits after the actions slot, so it stays the rightmost item whether or not the slot shows.
    func sidebarRowActions<Trailing: View>(
        title: String, groups: [SidebarRowActionGroup], trailingAlignment: VerticalAlignment = .center,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        SidebarRowActions(title: title, groups: groups, trailingAlignment: trailingAlignment) { self } trailing: { trailing() }
    }
}

struct SidebarRowActions<Content: View, Trailing: View>: View {
    let title: String
    let groups: [SidebarRowActionGroup]
    var trailingAlignment: VerticalAlignment = .center
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing
    @State private var presenter = SidebarRowMenuPresenter()
    @State private var hovered = false
    @State private var focused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarRowGroup) private var group
    @Environment(\.sidebarRowGroupHover) private var groupHover
    @Environment(\.sidebarRowGroupHead) private var groupHead
    private var lit: Bool { SidebarRowHover.lit(hovered: hovered, inGroup: group != nil) }
    // Only the head reads the group's hover, so a hover change re-renders the head alone.
    private var showsActions: Bool {
        SidebarRowHover.showsActions(hovered: hovered, focused: focused,
                                     groupHovered: groupHead && groupHover?.hovered == true, groupHead: groupHead)
    }

    var body: some View {
        HStack(alignment: trailingAlignment, spacing: 2) {
            HStack(spacing: 2) {
                content
                actionsSlot
            }
            trailing
        }
        .environment(\.sidebarRowMenu, configuredPresenter)
        .background(SidebarRowMenuAnchor(presenter: presenter))
        .background {
            SidebarHoverLift(lit: lit)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: showsActions)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: lit)
        .onHover { hovered = $0 }
    }

    private var actionsSlot: some View {
        ZStack {
            Color.clear
            if showsActions {
                Button { presenter.show() } label: {
                    Image(systemName: "ellipsis").font(.caption2)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Actions for \(title)")
                .help("Actions for \(title); Shift-F10 on the row")
            }
        }
        .frame(width: 24, height: 24)
    }

    private var configuredPresenter: SidebarRowMenuPresenter {
        presenter.groups = groups
        presenter.focusChanged = { focused = $0 }
        return presenter
    }
}

enum SidebarRowHover {
    /// Inside an expanded row group the group draws the one hover background; rows add none.
    static func lit(hovered: Bool, inGroup: Bool) -> Bool { !inGroup && hovered }

    /// The group's agent row shows its actions (…) whenever the group is hovered; other rows on their own hover.
    static func showsActions(hovered: Bool, focused: Bool, groupHovered: Bool, groupHead: Bool) -> Bool {
        hovered || focused || (groupHead && groupHovered)
    }
}

/// The raised hover background shared by a single row and a whole row group.
struct SidebarHoverLift: View {
    let lit: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(lit ? 0.06 : 0))
            .shadow(color: .black.opacity(lit ? 0.28 : 0), radius: lit ? 5 : 0, y: lit ? 2 : 0)
            .offset(y: lit ? -1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The enclosing expanded agent block: the agent row plus every rendered descendant.
/// Stable while the pointer moves; hover lives in `SidebarRowGroupHover`.
struct SidebarRowGroupScope: Equatable {
    /// The head row's surface; its focus bar spans the whole group.
    var focus: SidebarSeenTarget?
}

/// The group's hover. Observed per property, so only views that read `hovered` re-render.
@MainActor @Observable
final class SidebarRowGroupHover {
    var hovered = false
}

/// The pointer in window coordinates, or nil when unknown. Injectable for offscreen tests.
typealias SidebarPointerLocation = @MainActor (NSView) -> NSPoint?

private struct SidebarRowGroupKey: EnvironmentKey {
    static let defaultValue: SidebarRowGroupScope? = nil
}

private struct SidebarRowGroupHoverKey: EnvironmentKey {
    static let defaultValue: SidebarRowGroupHover? = nil
}

private struct SidebarRowGroupHeadKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SidebarPointerLocationKey: EnvironmentKey {
    static let defaultValue: SidebarPointerLocation? = nil
}

extension EnvironmentValues {
    /// The enclosing expanded row group, if any. Nested groups pass the outer group through.
    var sidebarRowGroup: SidebarRowGroupScope? {
        get { self[SidebarRowGroupKey.self] }
        set { self[SidebarRowGroupKey.self] = newValue }
    }

    /// The owning group's hover; read only by `SidebarRowActions`.
    var sidebarRowGroupHover: SidebarRowGroupHover? {
        get { self[SidebarRowGroupHoverKey.self] }
        set { self[SidebarRowGroupHoverKey.self] = newValue }
    }

    /// Set on the group's own agent row: its actions (…) follow the group's hover.
    var sidebarRowGroupHead: Bool {
        get { self[SidebarRowGroupHeadKey.self] }
        set { self[SidebarRowGroupHeadKey.self] = newValue }
    }

    /// Overrides where row groups find the pointer after layout; nil uses the window's.
    var sidebarPointerLocation: SidebarPointerLocation? {
        get { self[SidebarPointerLocationKey.self] }
        set { self[SidebarPointerLocationKey.self] = newValue }
    }
}

/// One tracking area over the whole group, so moving between its rows never exits or flickers.
/// After every layout it re-checks the pointer, so a group that grows under or moves away
/// from a still pointer follows it without waiting for the next enter or exit.
final class SidebarRowGroupHoverView: NSView {
    var hoverChanged: (Bool) -> Void = { _ in }
    var pointerLocation: SidebarPointerLocation = SidebarRowGroupHoverView.windowPointer
    private(set) var isHovered = false
    private var recheckPending = false

    /// The real pointer, only while this window is on screen and the app active, like the tracking area.
    static func windowPointer(_ view: NSView) -> NSPoint? {
        guard let window = view.window, window.isVisible, NSApp.isActive else { return nil }
        return window.mouseLocationOutsideOfEventStream
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        if !bounds.isEmpty {
            addTrackingArea(NSTrackingArea(
                rect: bounds, options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect], owner: self
            ))
        }
        scheduleRecheck()
    }

    override func mouseEntered(with event: NSEvent) { set(true) }
    override func mouseExited(with event: NSEvent) { set(false) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { set(false) } else { scheduleRecheck() }
    }

    // Layout must not mutate SwiftUI state, so the result lands on the next main-queue turn.
    private func scheduleRecheck() {
        guard !recheckPending else { return }
        recheckPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            recheckPending = false
            recheckPointer()
        }
    }

    func recheckPointer() {
        guard window != nil, let point = pointerLocation(self) else { return }
        let area = bounds.intersection(visibleRect)
        set(!area.isEmpty && area.contains(convert(point, from: nil)))
    }

    private func set(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        hoverChanged(hovered)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); updateTrackingAreas() }
}

private struct SidebarRowGroupHoverTracker: NSViewRepresentable {
    let hover: SidebarRowGroupHover

    func makeNSView(context: Context) -> SidebarRowGroupHoverView {
        let view = SidebarRowGroupHoverView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: SidebarRowGroupHoverView, context: Context) {
        view.hoverChanged = { [hover] hovered in if hover.hovered != hovered { hover.hovered = hovered } }
        view.pointerLocation = context.environment.sidebarPointerLocation ?? SidebarRowGroupHoverView.windowPointer
    }
}

/// Draws an expanded agent block's hover background and focus bar once, behind and beside
/// the agent row and all its visible descendants. Presentation only.
///
/// Nesting: the outermost expanded group wins. An inner block inside an expanded group draws
/// no group background or bar of its own and tracks nothing; its rows join the outer group.
/// One focus bar at a time: the group bar shows only when the head's surface is focused, and
/// rows inside that share the surface draw none; a descendant with its own focused surface
/// keeps its own row-height bar, which can't coincide with the group bar.
private struct SidebarRowGroupModifier: ViewModifier {
    let focus: SidebarSeenTarget?
    let expanded: Bool
    @Environment(\.sidebarRowGroup) private var outer

    func body(content: Content) -> some View {
        if outer != nil {
            // Nested: pass the outer group through untouched.
            content
        } else {
            // Collapsed groups keep tracking, so a stale hover clears before they expand again.
            SidebarRowGroupOwner(focus: focus, expanded: expanded, content: content)
        }
    }
}

private struct SidebarRowGroupOwner<Content: View>: View {
    let focus: SidebarSeenTarget?
    let expanded: Bool
    let content: Content
    @Environment(\.sidebarFocusedSurface) private var focusedSurface
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = SidebarRowGroupHover()

    var body: some View {
        let lit = expanded && hover.hovered
        content
            .environment(\.sidebarRowGroup, expanded ? .init(focus: focus) : nil)
            .environment(\.sidebarRowGroupHover, expanded ? hover : nil)
            .background { SidebarHoverLift(lit: lit) }
            .background { SidebarRowGroupHoverTracker(hover: hover) }
            .overlay(alignment: .leading) {
                if expanded, let focus, focus == focusedSurface {
                    SidebarFocusBar()
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: lit)
    }
}

extension View {
    /// Groups an agent row with its rendered descendants while `expanded`; collapsed, the row stands alone.
    func sidebarRowGroup(focus: SidebarSeenTarget?, expanded: Bool) -> some View {
        modifier(SidebarRowGroupModifier(focus: focus, expanded: expanded))
    }
}

extension SidebarRowActionGroup {
    static func appearance(icon: (() -> Void)?, agent: Bool, child: Bool = false, pet: (() -> Void)? = nil,
                           tags: (() -> Void)? = nil) -> Self {
        let catalogNotice = SidebarGlyphCatalog.notice
        let availableIcon = catalogNotice == nil ? icon : nil
        var actions: [SidebarRowAction] = [
            availableIcon.map { callback in .init(title: "Choose icon…", perform: { callback() }) }
                ?? .unavailable("Choose icon…", catalogNotice ?? (child ? "Activity-only child has no independent icon." : "Exact icon identity unavailable."))
        ]
        if agent {
            actions.append(pet.map { callback in .init(title: "Choose pet…", perform: { callback() }) }
                ?? .unavailable("Choose pet…", child ? "Activity-only child has no independent pet." : "Exact session identity unavailable."))
            actions.append(tags.map { callback in .init(title: "Edit tags…", perform: { callback() }) }
                ?? .unavailable("Edit tags…", child ? "Activity-only child has no independent tags." : "Exact session identity unavailable."))
        }
        return .init(title: "Appearance", actions: actions)
    }

    /// Why a row without its own place in a sibling list can't be moved.
    enum FixedPlacement {
        case movesWithParent, movesWithParentAgent, movesWithParentSession, taskboard, listUnavailable

        var reason: String {
            switch self {
            case .movesWithParent: "Moves with its surface."
            case .movesWithParentAgent: "Moves with its parent agent."
            case .movesWithParentSession: "Moves with its parent session."
            case .taskboard: "Taskboard groups cards by state. Reorder in the Hierarchy."
            case .listUnavailable: "Reordering isn't available in this view."
            }
        }
    }

    static func placement(_ fixed: FixedPlacement) -> Self {
        .init(title: "Organization", actions: [
            .unavailable("Move Up", fixed.reason), .unavailable("Move Down", fixed.reason)
        ])
    }

    static func lifecycle(child: Bool = false) -> Self {
        .init(title: "Lifecycle", actions: [
            .unavailable("Exit and close…", child ? "Open the parent chat; no independent child lifecycle control." : "Exit and close is not available.")
        ])
    }
}
