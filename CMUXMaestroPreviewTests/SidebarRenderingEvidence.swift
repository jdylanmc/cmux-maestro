import AppKit

@MainActor
enum SidebarRenderingEvidence {
    struct Metrics: Codable {
        let width: Double
        let height: Double
        let viewportWidth: Double
        let viewportHeight: Double
        let documentWidth: Double
        let documentHeight: Double
        let visibleHostWindows: Int
    }

    static func metrics(for view: NSView) -> Metrics {
        var scrollViews: [NSScrollView] = []
        func visit(_ child: NSView) {
            if let scroll = child as? NSScrollView { scrollViews.append(scroll) }
            child.subviews.forEach(visit)
        }
        visit(view)
        let scroll = scrollViews.max { $0.bounds.height < $1.bounds.height }
        return Metrics(
            width: view.bounds.width, height: view.bounds.height,
            viewportWidth: Double(scroll?.contentView.bounds.width ?? 0),
            viewportHeight: Double(scroll?.contentView.bounds.height ?? 0),
            documentWidth: Double(scroll?.documentView?.bounds.width ?? 0),
            documentHeight: Double(scroll?.documentView?.bounds.height ?? 0),
            visibleHostWindows: NSApp.windows.filter(\.isVisible).count
        )
    }
}
