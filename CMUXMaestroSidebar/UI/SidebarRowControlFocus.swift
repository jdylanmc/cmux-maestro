import SwiftUI

/// SwiftUI controls may share a hosting responder rather than expose their own NSView.
struct SidebarRowControlFocus: ViewModifier {
    @Environment(\.sidebarRowMenu) private var row
    @FocusState private var focused: Bool
    @State private var controlID = UUID()

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: focused) { _, focused in
                row?.controlFocusChanged(controlID, focused: focused)
            }
            .onDisappear {
                row?.controlFocusChanged(controlID, focused: false)
            }
    }
}
