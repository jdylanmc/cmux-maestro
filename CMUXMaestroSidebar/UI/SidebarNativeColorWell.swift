import AppKit

/// Owns one native panel edit. Continuous changes stay in the well until deactivation.
@MainActor
final class SidebarNativeColorWell: NSColorWell {
    private var source: SidebarTagColor?
    private var editing = false
    private var discard = false
    private weak var panelParent: NSWindow?
    private weak var ownedPanel: NSColorPanel?
    private var choose: (SidebarTagColor) -> Void = { _ in }
    private var unavailable: (Bool) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        colorWellStyle = .minimal
        supportsAlpha = false
        isContinuous = true
        target = self
        action = #selector(colorChanged)
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        color: NSColor, label: String, choose: @escaping (SidebarTagColor) -> Void,
        unavailable: @escaping (Bool) -> Void
    ) {
        let incoming = SidebarTagColor(nativeColor: color)
        if editing, incoming != source { cancel() }
        self.choose = choose
        self.unavailable = unavailable
        source = incoming
        if !editing { self.color = color }
        setAccessibilityLabel(label)
        setAccessibilityValue(SidebarTagColor(nativeColor: self.color)?.hex ?? "")
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        activate(true)
        return isActive
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        // Route the entire well to our owned panel, not AppKit's separate swatch popover.
        activate(true)
    }

    override func activate(_ exclusive: Bool) {
        guard !editing else { return }
        let panel = NSColorPanel.shared
        guard panel.parent == nil else {
            unavailable(true)
            return
        }
        unavailable(false)
        editing = true
        super.activate(true)
        ownedPanel = panel
        if let window {
            // NSPopover refuses outside-click dismissal while it owns a child window.
            window.addChildWindow(panel, ordered: .above)
            panelParent = window
        }
        panel.orderFront(nil)
    }

    override func deactivate() {
        guard editing else { super.deactivate(); return }
        editing = false
        if let panelParent, let ownedPanel, ownedPanel.parent === panelParent {
            panelParent.removeChildWindow(ownedPanel)
        }
        panelParent = nil
        ownedPanel = nil
        super.deactivate()
        if !discard { commit() }
    }

    func cancel() {
        guard editing, let ownedPanel else { return }
        discard = true
        ownedPanel.close()
        deactivate()
        discard = false
    }

    func finish() {
        guard editing, let ownedPanel else { return }
        ownedPanel.close()
        deactivate()
    }

    @objc private func colorChanged() {
        let rgb = SidebarTagColor(nativeColor: color)
        unavailable(rgb == nil)
        setAccessibilityValue(rgb?.hex ?? "")
        if !editing { commit() }
    }

    private func commit() {
        guard let rgb = SidebarTagColor(nativeColor: color) else {
            unavailable(true)
            return
        }
        unavailable(false)
        guard rgb != source else { return }
        source = rgb
        choose(rgb)
    }
}
