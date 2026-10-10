import SwiftUI

/// Keeps Copy's label-only hover target and reserved geometry independent of value actions.
struct SidebarLabeledValue<Value: View, Trailing: View>: View {
    let label: String
    let value: String
    let clipboardValue: String?
    let copy: (String) -> Bool
    var focusChanged: (Bool) -> Void = { _ in }
    var font: Font = .caption
    @ViewBuilder let content: () -> Value
    @ViewBuilder let trailing: () -> Trailing
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
                HStack(alignment: .center, spacing: 0) {
                    Text(label).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let clipboardValue {
                        SidebarCopyButton(
                            label: "Copy \(label.prefix(1).lowercased())\(label.dropFirst())",
                            feedback: feedback, copied: copied == true,
                            action: { copied = copy(clipboardValue) },
                            focusChanged: {
                                actionFocused = $0
                                focusChanged($0)
                            }
                        )
                        .frame(width: 24, height: 24)
                        .opacity(labelHovered || actionFocused ? 1 : 0)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(SidebarCopyHoverAnchor(
                    isHovered: $labelHovered, actionWidth: clipboardValue == nil ? 0 : 24
                ))
                trailing()
            }
            content()
            if copied != nil {
                SidebarCopyFeedback(text: feedback)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(font)
        .accessibilityElement(children: .contain)
        .onChange(of: value) { copied = nil }
        .onChange(of: clipboardValue) { copied = nil }
    }
}
