import SwiftUI

struct SidebarCopyableValue: View {
    let value: String
    let label: String
    let copy: () -> Bool
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
            HStack(alignment: .top, spacing: 4) {
                Text(value).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SidebarCopyButton(
                    label: "Copy \(label.prefix(1).lowercased())\(label.dropFirst())",
                    feedback: feedback, copied: copied == true, action: { copied = copy() }
                )
                .frame(width: 24, height: 24)
            }
            if copied != nil {
                Text(feedback).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("hover-copy-feedback")
            }
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .onChange(of: value) { copied = nil }
    }
}

private struct SidebarCopyButton: NSViewRepresentable {
    let label: String
    let feedback: String
    let copied: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> SidebarCopyNativeButton { SidebarCopyNativeButton() }

    func updateNSView(_ button: SidebarCopyNativeButton, context: Context) {
        button.activate = action
        button.image = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: nil)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityValue(feedback)
        button.setAccessibilityIdentifier("hover-copy-value")
    }
}

private final class SidebarCopyNativeButton: NSButton {
    var activate: () -> Void = {}

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryPushIn)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        target = self
        action = #selector(copyValue)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { isEnabled }

    @objc private func copyValue() { activate() }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ",
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
