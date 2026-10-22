import AppKit
import SwiftUI

/// The render server advances a bounded sprite sequence without relaying each frame through layout.
struct SidebarPetAnimation: NSViewRepresentable {
    let frames: [CGImage]

    func makeNSView(context: Context) -> SidebarPetAnimationView { SidebarPetAnimationView() }
    func updateNSView(_ view: SidebarPetAnimationView, context: Context) { view.setFrames(frames) }
}
