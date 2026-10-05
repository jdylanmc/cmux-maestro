import SwiftUI

private enum SidebarCopyableValueLayout {
    static let actionSize: CGFloat = 24
}

struct SidebarCopyableValue: View {
    let value: String
    let label: String
    let clipboardValue: String
    let copy: (String) -> Bool
    var focusChanged: (Bool) -> Void = { _ in }
    @State private var labelHovered = false
    @State private var actionFocused = false
    @State private var copied: Bool?

    private var feedback: String {
        switch copied {
        case true: "Copied"
        case false: "Could not copy. Try again."
        case nil: "Not copied"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 0) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SidebarCopyButton(
                    label: "Copy \(label.prefix(1).lowercased())\(label.dropFirst())",
                    feedback: feedback, copied: copied == true,
                    action: { copied = copy(clipboardValue) },
                    focusChanged: {
                        actionFocused = $0
                        focusChanged($0)
                    }
                )
                .frame(width: SidebarCopyableValueLayout.actionSize, height: SidebarCopyableValueLayout.actionSize)
                .opacity(labelHovered || actionFocused ? 1 : 0)
            }
            .fixedSize(horizontal: true, vertical: false)
            .background(SidebarCopyHoverAnchor(
                isHovered: $labelHovered, actionWidth: SidebarCopyableValueLayout.actionSize
            ))
            Text(value).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if copied != nil {
                SidebarCopyFeedback(text: feedback)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .onChange(of: value) { copied = nil }
        .onChange(of: clipboardValue) { copied = nil }
    }
}

private struct SidebarCopyHoverAnchor: NSViewRepresentable {
    @Binding var isHovered: Bool
    let actionWidth: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(isHovered: $isHovered) }

    func makeNSView(context: Context) -> SidebarCopyableValueHoverView {
        SidebarCopyableValueHoverView()
    }

    func updateNSView(_ view: SidebarCopyableValueHoverView, context: Context) {
        context.coordinator.isHovered = $isHovered
        view.actionWidth = actionWidth
        let coordinator = context.coordinator
        view.hoverChanged = { [weak coordinator] in coordinator?.isHovered.wrappedValue = $0 }
    }

    final class Coordinator {
        var isHovered: Binding<Bool>

        init(isHovered: Binding<Bool>) {
            self.isHovered = isHovered
        }
    }
}

final class SidebarCopyableValueHoverView: NSView {
    var actionWidth: CGFloat = SidebarCopyableValueLayout.actionSize
    var hoverChanged: (Bool) -> Void = { _ in }

    private var labelRect: NSRect {
        NSRect(x: bounds.minX, y: bounds.minY, width: max(0, bounds.width - actionWidth), height: bounds.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard !bounds.isEmpty else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.activeInActiveApp, .mouseEnteredAndExited], owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hoverChanged(labelRect.contains(convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) { hoverChanged(false) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); updateTrackingAreas() }
}

private struct SidebarCopyFeedback: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.isSelectable = false
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabelColor
        label.setAccessibilityElement(true)
        label.setAccessibilityRole(.staticText)
        label.setAccessibilityIdentifier("hover-copy-feedback")
        return label
    }

    func updateNSView(_ label: NSTextField, context: Context) {
        label.stringValue = text
        if label.enclosingScrollView != nil {
            DispatchQueue.main.async { label.scrollToVisible(label.bounds) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, let cell = nsView.cell else { return nil }
        let size = cell.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: width, height: .greatestFiniteMagnitude
        ))
        return CGSize(width: width, height: size.height)
    }
}

private struct SidebarCopyButton: NSViewRepresentable {
    let label: String
    let feedback: String
    let copied: Bool
    let action: () -> Void
    let focusChanged: (Bool) -> Void

    func makeNSView(context: Context) -> SidebarCopyNativeButton { SidebarCopyNativeButton() }

    func updateNSView(_ button: SidebarCopyNativeButton, context: Context) {
        button.activate = action
        button.focusChanged = focusChanged
        button.image = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: nil)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityValue(feedback)
        button.setAccessibilityIdentifier("hover-copy-value")
    }
}

private final class SidebarCopyNativeButton: NSButton {
    var activate: () -> Void = {}
    var focusChanged: (Bool) -> Void = { _ in }
    private var reportsFocus = false

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        focusRingType = .exterior
        imagePosition = .imageOnly
        setButtonType(.momentaryPushIn)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        target = self
        action = #selector(copyValue)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor && window != nil }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became && !reportsFocus {
            reportsFocus = true
            focusChanged(true)
            needsDisplay = true
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned && reportsFocus {
            reportsFocus = false
            focusChanged(false)
            needsDisplay = true
        }
        return resigned
    }

    @objc private func copyValue() { activate() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48,
           event.modifierFlags.contains(.shift),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let window {
            window.selectPreviousKeyView(self)
        } else if (event.keyCode == 36 || event.keyCode == 49),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if isEnabled && !event.isARepeat { performClick(nil) }
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }
}
