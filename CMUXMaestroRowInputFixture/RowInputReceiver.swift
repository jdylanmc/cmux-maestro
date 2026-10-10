import AppKit

/// A named, non-focusing click destination outside every row and menu.
final class RowInputReceiver: NSView {
    private(set) var downs = 0
    private(set) var ups = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downs += 1 }
    override func mouseUp(with event: NSEvent) { ups += 1 }
}
