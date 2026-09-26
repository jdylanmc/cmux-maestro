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
            item.representedObject = SidebarRowAction(title: "Preview details", perform: { _ = preview() })
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
        action.perform()
    }

    func show(at point: NSPoint? = nil) {
        guard let anchor, anchor.window != nil, !anchor.visibleRect.isEmpty else { return }
        dismissPreview()
        present(menu(), point ?? NSPoint(x: anchor.bounds.minX, y: anchor.bounds.maxY), anchor)
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
        presenter?.anchor = nil
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
    func sidebarRowActions(title: String, groups: [SidebarRowActionGroup]) -> some View {
        SidebarRowActions(title: title, groups: groups) { self }
    }
}

struct SidebarRowActions<Content: View>: View {
    let title: String
    let groups: [SidebarRowActionGroup]
    @ViewBuilder var content: Content
    @State private var presenter = SidebarRowMenuPresenter()
    @State private var hovered = false
    @State private var focused = false

    var body: some View {
        HStack(spacing: 2) {
            content
            if hovered || focused {
                Button { presenter.show() } label: {
                    Image(systemName: "ellipsis").font(.caption2)
                        .frame(width: 20, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Actions for \(title)")
                .help("Actions for \(title); Shift-F10 on the row")
            }
        }
        .environment(\.sidebarRowMenu, configuredPresenter)
        .background(SidebarRowMenuAnchor(presenter: presenter))
        .onHover { hovered = $0 }
    }

    private var configuredPresenter: SidebarRowMenuPresenter {
        presenter.groups = groups
        presenter.focusChanged = { focused = $0 }
        return presenter
    }
}

extension SidebarRowActionGroup {
    static func appearance(icon: (() -> Void)?, agent: Bool, child: Bool = false) -> Self {
        var actions: [SidebarRowAction] = [
            icon.map { callback in .init(title: "Choose icon…", perform: { callback() }) }
                ?? .unavailable("Choose icon…", child ? "Activity-only child has no independent icon." : "Exact icon identity unavailable.")
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
