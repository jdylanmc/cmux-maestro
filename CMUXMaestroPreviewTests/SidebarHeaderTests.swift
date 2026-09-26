import AppKit
import SwiftUI
import Testing

@MainActor
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

    @Test(arguments: [false, true])
    func sixNativeHeaderIconsFitAt280WithNoTextChrome(dark: Bool) async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: SidebarHeader(taskboardActive: true, activate: { _ in
            Issue.record("Rendering a shortcut cannot activate it")
        }).padding(.horizontal, 5).environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        #expect(host.fittingSize.width <= 280 && host.fittingSize.height <= 40)
        #expect(!window.isVisible)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("polish-header-280-\(dark ? "dark" : "light").png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
        let lines = try SidebarRenderingEvidence.recognizedNativeLines(in: file)
        #expect(!lines.contains { $0.contains("Workspaces") || $0.contains("Hierarchy") })
    }
}
