import SwiftUI

struct SidebarPathDisclosureButton: NSViewRepresentable {
    let label: String
    let expanded: Bool
    let available: Bool
    let toggle: () -> Void
    let focusChanged: (Bool) -> Void

    func makeNSView(context: Context) -> SidebarCopyNativeButton { SidebarCopyNativeButton() }

    func updateNSView(_ button: SidebarCopyNativeButton, context: Context) {
        button.activate = toggle
        button.focusChanged = focusChanged
        if !available { Self.returnLocalFocus(from: button) }
        button.isEnabled = available
        button.isHidden = !available
        button.setAccessibilityElement(available)
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        let action = expanded
            ? String(localized: "sidebar.path.collapse", defaultValue: "Collapse \(label)")
            : String(localized: "sidebar.path.expand", defaultValue: "Expand \(label)")
        button.toolTip = action
        button.setAccessibilityLabel(action)
        button.setAccessibilityValue(expanded
            ? String(localized: "sidebar.path.expanded", defaultValue: "Expanded")
            : String(localized: "sidebar.path.collapsed", defaultValue: "Collapsed"))
        button.setAccessibilityExpanded(expanded)
        button.setAccessibilityIdentifier(available ? "sidebar-path-disclosure" : nil)
    }

    static func dismantleNSView(_ button: SidebarCopyNativeButton, coordinator: ()) {
        returnLocalFocus(from: button)
    }

    private static func returnLocalFocus(from button: NSButton) {
        guard let window = button.window, window.firstResponder === button,
              let root = window.contentView else { return }
        let controls = buttons(in: root)
        guard let index = controls.firstIndex(where: { $0 === button }) else { return }
        let preceding = controls[..<index].last { $0.canBecomeKeyView }
        let following = controls.dropFirst(index + 1).first { $0.canBecomeKeyView }
        window.makeFirstResponder(preceding ?? following)
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        if let button = view as? NSButton { return [button] }
        return view.subviews.flatMap { buttons(in: $0) }
    }
}
