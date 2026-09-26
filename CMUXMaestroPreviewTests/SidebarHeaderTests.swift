import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(SidebarAppKitTestScope())
struct SidebarHeaderTests {
    @Test func exactHeaderOrderAndUnavailableReasonsDoNotClaimCapabilities() throws {
        #expect(SidebarHeaderAction.allCases == [.directory, .beats, .taskboard, .history, .settings, .fermata])
        #expect(SidebarHeaderAction.allCases.map(\.title) == [
            "Open directory as new workspace", "Beats", "Taskboard", "History", "Maestro settings", "Fermata"
        ])
        for action in SidebarHeaderAction.allCases {
            if let symbol = action.symbol { #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil) }
            #expect((action.unavailable != nil) == [.directory, .beats, .fermata].contains(action))
        }
        var actions: [SidebarHeaderAction] = []
        let header = SidebarHeader(taskboardActive: false, activate: { actions.append($0) })
        #expect(actions.isEmpty)
        for action in SidebarHeaderAction.allCases { header.activate(action) }
        #expect(actions == SidebarHeaderAction.allCases)
    }

    @Test(arguments: [false, true], [240, 280, 350, 500])
    func titleAndFixedNativeActionGroup(dark: Bool, width: Int) async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: SidebarHeader(taskboardActive: true, availability: .stale, activate: { _ in
            Issue.record("Rendering a shortcut cannot activate it")
        }).padding(.horizontal, 5).environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: CGFloat(width), height: 40))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        #expect(host.fittingSize.width <= CGFloat(width) && host.fittingSize.height <= 40)
        #expect(!window.isVisible)
        let buttons = descendants(host).compactMap { $0 as? NSButton }
        try #require(buttons.count == 6)
        let frames = buttons.map { host.convert($0.bounds, from: $0) }
        #expect(frames.allSatisfy { $0.size == CGSize(width: 28, height: 28) && host.bounds.contains($0) })
        for index in 1..<frames.count {
            #expect(frames[index].minX - frames[index - 1].maxX == 2)
        }
        #expect(frames.last?.maxX == CGFloat(width) - 5)
        print("TARGET header \(width): \(frames)")
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/visual-target/header")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("header-\(width)-\(dark ? "dark" : "light").png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
        try JSONEncoder().encode(frames).write(to: file.appendingPathExtension("geometry.json"))
        let lines = try SidebarRenderingEvidence.recognizedLines(in: file, dark: dark)
        #expect(!lines.contains { $0.contains("Workspaces") || $0.contains("Hierarchy") })
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
