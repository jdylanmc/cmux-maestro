import SwiftUI

/// Fixed-size status decoration; animation never publishes SwiftUI state or requests layout.
struct SidebarStatusAnimation: NSViewRepresentable {
    let kind: SidebarStatusAnimationView.Kind

    func makeNSView(context: Context) -> SidebarStatusAnimationView { SidebarStatusAnimationView() }
    func updateNSView(_ view: SidebarStatusAnimationView, context: Context) { view.configure(kind) }
}
