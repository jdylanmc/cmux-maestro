import AppKit
import Foundation
import SwiftUI
import Testing

@MainActor
@Suite(.serialized)
struct SidebarPreferencesTests {
    @Test
    func exposesExactlyTheTwoSidebarChoices() {
        #expect(SidebarMode.allCases.map(\.title) == ["Hierarchy", "Taskboard"])
    }

    @Test
    func defaultsToHierarchy() throws {
        try withIsolatedDefaults { defaults, file, attentionFile, layoutStore in
            #expect(SidebarPreferences(defaults: defaults, historyFile: file, attentionFile: attentionFile, layoutStore: layoutStore).selectedMode == .hierarchy)
        }
    }

    @Test
    func switchesImmediatelyWithoutChangingAnyConnectionState() throws {
        try withIsolatedDefaults { defaults, file, attentionFile, layoutStore in
            let preferences = SidebarPreferences(defaults: defaults, historyFile: file, attentionFile: attentionFile, layoutStore: layoutStore)
            let connection = SidebarConnectionModel()
            let states: [SidebarConnectionState] = [
                .waiting,
                .connected(workspaceCount: 2, surfaceCount: 3),
                .degraded(message: "Host unavailable"),
            ]

            for (index, state) in states.enumerated() {
                set(state, on: connection)
                preferences.selectedMode = index.isMultiple(of: 2) ? .taskboard : .hierarchy

                #expect(preferences.selectedMode == (index.isMultiple(of: 2) ? .taskboard : .hierarchy))
                #expect(connection.state == state)
            }
        }
    }

    @Test
    func persistsThroughReconstruction() throws {
        try withIsolatedDefaults { defaults, file, attentionFile, layoutStore in
            let original = SidebarPreferences(defaults: defaults, historyFile: file, attentionFile: attentionFile, layoutStore: layoutStore)
            original.selectedMode = .taskboard

            let reconstructed = SidebarPreferences(defaults: defaults, historyFile: file, attentionFile: attentionFile, layoutStore: layoutStore)

            #expect(reconstructed.selectedMode == .taskboard)
        }
    }

    @Test
    func invalidPersistedValueFallsBackToHierarchy() throws {
        try withIsolatedDefaults { defaults, file, attentionFile, layoutStore in
            defaults.set("unknown-mode", forKey: "sidebar.selectedMode")

            #expect(SidebarPreferences(defaults: defaults, historyFile: file, attentionFile: attentionFile, layoutStore: layoutStore).selectedMode == .hierarchy)
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults, URL, URL, SidebarLayoutStore) -> Void) throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        body(fixture.defaults, fixture.historyFile, fixture.attentionFile, .init(file: .init(url: fixture.layoutFile)))
    }

    @Test(arguments: SidebarDensity.allCases)
    func renderedContentClearsTheHostsOverlaidFooter(density: SidebarDensity) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.setDensity(density)
        let model = SidebarConnectionModel(copilot: SidebarCopilotPolling(
            read: { _ in .init(generatedAt: Date(), sessions: [], issues: [], isComplete: true) }
        ))
        defer { model.setVisible(false) }
        model.showConnected(workspaceCount: 1, surfaceCount: 1)

        for mode in SidebarMode.allCases {
            preferences.selectedMode = mode
            for size in [NSSize(width: 240, height: 400), NSSize(width: 349, height: 941)] {
                let frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences)
                    .environment(\.colorScheme, .light)
                    .background(Color.white))
                window.contentView = hosting
                defer { window.contentView = nil; window.close() }
                hosting.frame = frame
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
                hosting.layoutSubtreeIfNeeded()
                #expect(!window.isVisible)
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

                let reservedRows = Int(50 * CGFloat(bitmap.pixelsHigh) / size.height)
                var paintedPixels = 0
                for y in (bitmap.pixelsHigh - reservedRows)..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        if min(color.redComponent, color.greenComponent, color.blueComponent) < 0.99 {
                            paintedPixels += 1
                        }
                    }
                }
                #expect(paintedPixels == 0, "\(mode.rawValue) paints into the host's 50-point footer")
            }
        }
    }

    @Test(arguments: SidebarDensity.allCases)
    func renderedHierarchyRemainsResponsiveAcrossScrollingAndModeChanges(density: SidebarDensity) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.setDensity(density)
        preferences.setRetention(.never)
        let data = SidebarTreeFixtures()
        let now = Date(timeIntervalSince1970: 2_000)
        let children = (0..<40).map { index in
            data.child("scroll-\(index)", state: index.isMultiple(of: 2) ? .working : .blocked)
        }
        let snapshot = data.snapshot(sessions: [data.session(children: children, now: now)], now: now)
        let polling = SidebarCopilotPolling(
            read: { _ in snapshot }, pause: { try await Task.sleep(for: .seconds(60)) },
            expiryPause: { _ in
                let (ticks, continuation) = AsyncStream<Void>.makeStream()
                defer { continuation.finish() }
                for await _ in ticks {}
                try Task.checkCancellation()
            }, now: { now }
        )
        let model = SidebarConnectionModel(copilot: polling)
        model.replaceHierarchy(with: data.hierarchy())
        model.showConnected(workspaceCount: 2, surfaceCount: 2)
        polling.update(topology: data.topology(), connected: true)
        model.setVisible(true)
        defer { model.setVisible(false) }
        await sidebarEventually { polling.tree.sessions.count == 1 }

        let frame = NSRect(x: 0, y: 0, width: 240, height: 500)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.frame = frame
        for _ in 0..<3 {
            for mode in SidebarMode.allCases {
                preferences.selectedMode = mode
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
                hosting.layoutSubtreeIfNeeded()
                let scroll = try #require(firstScrollView(in: hosting))
                let document = try #require(scroll.documentView)
                #expect(document.bounds.height > scroll.contentView.bounds.height)
                for y in [max(0, document.bounds.height - scroll.contentView.bounds.height), 0] {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try await Task.sleep(for: .milliseconds(20))
                    hosting.layoutSubtreeIfNeeded()
                    #expect(document.bounds.height.isFinite)
                    #expect(document.bounds.width <= scroll.contentView.bounds.width + 0.5)
                    #expect(polling.tree.sessions.first?.nodes.count == children.count)
                }
                #expect(!window.isVisible)
            }
        }
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { firstScrollView(in: $0) }.first
    }

    private func set(_ state: SidebarConnectionState, on connection: SidebarConnectionModel) {
        switch state {
        case .waiting:
            connection.showWaiting()
        case .connected(let workspaceCount, let surfaceCount):
            connection.showConnected(
                workspaceCount: workspaceCount,
                surfaceCount: surfaceCount
            )
        case .degraded(let message):
            connection.showDegraded(message: message)
        }
    }
}
