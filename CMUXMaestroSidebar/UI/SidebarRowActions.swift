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
}

@MainActor
final class SidebarRowMenuPresenter: NSObject, NSMenuDelegate {
    var groups: [SidebarRowActionGroup] = []
    weak var anchor: NSView?
    var dismissPreview: () -> Void = {}
    var preview: (() -> Bool)?
    var focusChanged: (Bool) -> Void = { _ in }
    var hoverChanged: (Bool) -> Void = { _ in }
    var liftFocusChanged: (Bool) -> Void = { _ in }
    var liftEligible = false
    private(set) var focusedControls: Set<UUID> = []
    var currentMenuEvent: () -> NSEvent? = { NSApp.currentEvent }
    private var menuTracking: (menu: NSMenu, window: NSWindow, startedAt: TimeInterval)?
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
            parent.submenu = submenu
            menu.addItem(parent)
        }
        return menu
    }

    @objc func invoke(_ item: NSMenuItem) {
        guard item.isEnabled, let action = item.representedObject as? SidebarRowAction,
              action.unavailable == nil else { return }
        recordMenuInput()
        action.perform()
    }

    func show(at point: NSPoint? = nil) {
        guard let anchor, let window = anchor.window, !anchor.visibleRect.isEmpty else { return }
        dismissPreview()
        let menu = menu()
        let previousTracking = menuTracking
        menuTracking = (menu, window, ProcessInfo.processInfo.systemUptime)
        menu.delegate = self
        defer {
            if menuTracking?.menu === menu {
                recordMenuInput()
                menuTracking = previousTracking
            }
            menu.delegate = nil
        }
        present(menu, point ?? NSPoint(x: anchor.bounds.minX, y: anchor.bounds.maxY), anchor)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menuTracking?.menu === menu else { return }
        recordMenuInput()
    }

    private func recordMenuInput() {
        guard let tracking = menuTracking, let event = currentMenuEvent(),
              event.timestamp >= tracking.startedAt, event.window === tracking.window else { return }
        // The app's last event is not necessarily from this menu; never remap another window's input.
        SidebarRowMenuAnchorView.distributeInput(event, in: tracking.window)
    }

    func controlFocusChanged(_ id: UUID, focused: Bool) {
        if focused { focusedControls.insert(id) }
        else { focusedControls.remove(id) }
        (anchor as? SidebarRowMenuAnchorView)?.refreshKeyboardFocus()
    }

    func detach() {
        menuTracking = nil
        anchor = nil
        groups = []
        dismissPreview = {}
        preview = nil
        focusChanged = { _ in }
        hoverChanged = { _ in }
        liftFocusChanged = { _ in }
        liftEligible = false
        focusedControls.removeAll()
    }
}

final class SidebarRowMenuAnchorView: NSView {
    private static let inputNotification = Notification.Name("com.jdylanmc.CMUXMaestroPreview.sidebarRowInput")
    var presenter: SidebarRowMenuPresenter?
    private var monitor: Any?
    private weak var lastInput: NSEvent?
    private(set) var keyboardInteraction = false
    private(set) var keyboardFocused = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        NotificationCenter.default.removeObserver(self)
        lastInput = nil
        keyboardInteraction = false
        setKeyboardFocused(false)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(receiveInput(_:)), name: Self.inputNotification, object: window
        )
        for name in [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshKeyboardFocus), name: name, object: window)
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown, .leftMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            self.observeInput(event)
            guard self.handles(event) else { return event }
            self.presenter?.show(at: self.convert(event.locationInWindow, from: nil))
            return nil
        }
    }

    func observeInput(_ event: NSEvent) {
        guard let window, event.window === window, lastInput !== event else { return }
        Self.distributeInput(event, in: window)
    }

    fileprivate static func distributeInput(_ event: NSEvent, in window: NSWindow) {
        switch event.type {
        case .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseUp, .rightMouseUp, .otherMouseUp:
            NotificationCenter.default.post(name: inputNotification, object: window, userInfo: ["event": event])
        default:
            break
        }
    }

    @objc private func receiveInput(_ notification: Notification) {
        guard let event = notification.userInfo?["event"] as? NSEvent,
              let source = notification.object as? NSWindow, source === window else { return }
        lastInput = event
        switch event.type {
        case .keyDown, .keyUp:
            keyboardInteraction = presenter?.liftEligible == true
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            keyboardInteraction = false
        default:
            return
        }
        refreshKeyboardFocus()
    }

    @objc func refreshKeyboardFocus() {
        guard presenter?.liftEligible == true, keyboardInteraction,
              let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor,
              !frame.isEmpty, !bounds.isEmpty, !visibleRect.isEmpty else {
            setKeyboardFocused(false)
            return
        }
        if presenter?.focusedControls.isEmpty == false {
            setKeyboardFocused(true)
            return
        }
        guard let control = window.firstResponder as? NSView,
              control !== window.contentView, !control.isHiddenOrHasHiddenAncestor,
              control.window === window, !visibleRect.isEmpty else {
            setKeyboardFocused(false)
            return
        }
        let controlRect = convert(control.bounds, from: control)
        setKeyboardFocused(!controlRect.isEmpty && bounds.contains(controlRect)
                           && !visibleRect.intersection(controlRect).isEmpty)
    }

    private func setKeyboardFocused(_ focused: Bool) {
        guard keyboardFocused != focused else { return }
        keyboardFocused = focused
        presenter?.liftFocusChanged(focused)
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
        NotificationCenter.default.removeObserver(self)
        lastInput = nil
        keyboardInteraction = false
        setKeyboardFocused(false)
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
    func sidebarRowActions(title: String, groups: [SidebarRowActionGroup], liftEligible: Bool = false) -> some View {
        SidebarRowActions(title: title, groups: groups, liftEligible: liftEligible) { self }
    }
}

struct SidebarRowActions<Content: View>: View {
    let title: String
    let groups: [SidebarRowActionGroup]
    var liftEligible = false
    @ViewBuilder var content: Content
    @State private var presenter = SidebarRowMenuPresenter()
    @State private var hovered = false
    @State private var focused = false
    @State private var keyboardFocused = false

    var body: some View {
        HStack(spacing: 2) {
            content
            ZStack {
                Color.clear
                if hovered || focused || keyboardFocused {
                    if liftEligible {
                        overflowButton.buttonStyle(.plain)
                    } else {
                        overflowButton.buttonStyle(.borderless)
                    }
                }
            }
            .frame(width: 24, height: 24)
        }
        .environment(\.sidebarRowMenu, configuredPresenter)
        .background {
            if liftEligible {
                SidebarRowLiftSurface(lifted: SidebarRowLiftStyle.isLifted(
                    eligible: liftEligible, hovered: hovered, keyboardFocused: keyboardFocused
                ))
            }
        }
        .background(SidebarRowMenuAnchor(presenter: presenter))
        .onHover { presenter.hoverChanged($0) }
        .onDisappear {
            hovered = false
            focused = false
            keyboardFocused = false
        }
    }

    private var overflowButton: some View {
        Button { presenter.show() } label: {
            Image(systemName: "ellipsis").font(.caption2)
                .frame(width: 24, height: 24)
        }
        .accessibilityLabel("Actions for \(title)")
        .help("Actions for \(title); Shift-F10 on the row")
        .modifier(SidebarRowControlFocus())
    }

    private var configuredPresenter: SidebarRowMenuPresenter {
        presenter.groups = groups
        presenter.focusChanged = { focused = $0 }
        presenter.hoverChanged = { hovered = $0 }
        presenter.liftEligible = liftEligible
        presenter.liftFocusChanged = { keyboardFocused = $0 }
        return presenter
    }
}

extension SidebarRowActionGroup {
    static func appearance(icon: (() -> Void)?, agent: Bool, child: Bool = false) -> Self {
        let catalogNotice = SidebarGlyphCatalog.notice
        let availableIcon = catalogNotice == nil ? icon : nil
        var actions: [SidebarRowAction] = [
            availableIcon.map { callback in .init(title: "Choose icon…", perform: { callback() }) }
                ?? .unavailable("Choose icon…", catalogNotice ?? (child ? "Activity-only child has no independent icon." : "Exact icon identity unavailable."))
        ]
        if agent {
            actions.append(.unavailable("Choose pet…", child ? "Activity-only child has no independent pet." : "Pet selection is not available."))
            actions.append(.unavailable("Edit tags…", "Tag editing is not available."))
        }
        return .init(title: "Appearance", actions: actions)
    }

    static var placement: Self {
        .init(title: "Organization", actions: [
            .unavailable("Move or reorder…", "Native placement and sibling reordering are not available.")
        ])
    }

    static func lifecycle(child: Bool = false) -> Self {
        .init(title: "Lifecycle", actions: [
            .unavailable("Exit and close…", child ? "Open the parent chat; no independent child lifecycle control." : "Exit and close is not available.")
        ])
    }
}
