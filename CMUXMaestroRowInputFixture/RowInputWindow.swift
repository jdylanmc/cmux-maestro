import AppKit

final class RowInputWindow: NSWindow {
    var observe: (NSEvent) -> (() -> Void)? = { _ in nil }

    override func sendEvent(_ event: NSEvent) {
        let afterDispatch = observe(event)
        super.sendEvent(event)
        afterDispatch?()
    }
}
