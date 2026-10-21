import AppKit

/// Owns one native panel edit. Continuous changes stay in the well until deactivation.
@MainActor
final class SidebarNativeColorWell: NSColorWell {
    private var source: SidebarTagColor?
    private var editing = false
    private var discard = false
    private weak var panelParent: NSWindow?
    private var choose: (SidebarTagColor) -> Void = { _ in }
    private var unavailable: (Bool) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        colorWellStyle = .minimal
        supportsAlpha = false
        isContinuous = true
        target = self
        action = #selector(colorChanged)
        pulldownTarget = self
        pulldownAction = #selector(openPanel)
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

    @objc private func openPanel() { activate(true) }

    override func activate(_ exclusive: Bool) {
        guard !editing else { return }
        editing = true
        super.activate(true)
        if let window {
            let panel = NSColorPanel.shared
            // NSPopover refuses outside-click dismissal while it owns a child window.
            if panel.parent == nil {
                window.addChildWindow(panel, ordered: .above)
                panelParent = window
            }
        }
    }

    override func deactivate() {
        guard editing else { super.deactivate(); return }
        editing = false
        if let panelParent, NSColorPanel.shared.parent === panelParent {
            panelParent.removeChildWindow(NSColorPanel.shared)
        }
        panelParent = nil
        super.deactivate()
        if !discard { commit() }
    }

    func cancel() {
        guard editing else { return }
        discard = true
        deactivate()
        discard = false
        NSColorPanel.shared.close()
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
