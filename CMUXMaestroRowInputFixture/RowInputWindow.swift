import AppKit

final class RowInputWindow: NSWindow {
    var observe: (NSEvent) -> Void = { _ in }

    override func sendEvent(_ event: NSEvent) {
        observe(event)
        super.sendEvent(event)
    }
}
