import AppKit
import Foundation
import SwiftUI
import Testing

@MainActor
struct SidebarPreferencesTests {
    @Test
    func exposesExactlyTheTwoSidebarChoices() {
        #expect(SidebarMode.allCases.map(\.title) == ["Hierarchy", "Taskboard"])
    }

    @Test
    func defaultsToHierarchy() {
        withIsolatedDefaults { defaults in
            #expect(SidebarPreferences(defaults: defaults).selectedMode == .hierarchy)
        }
    }

    @Test
    func switchesImmediatelyWithoutChangingAnyConnectionState() {
        withIsolatedDefaults { defaults in
            let preferences = SidebarPreferences(defaults: defaults)
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
    func persistsThroughReconstruction() {
        withIsolatedDefaults { defaults in
            let original = SidebarPreferences(defaults: defaults)
            original.selectedMode = .taskboard

            let reconstructed = SidebarPreferences(defaults: defaults)

            #expect(reconstructed.selectedMode == .taskboard)
        }
    }

    @Test
    func invalidPersistedValueFallsBackToHierarchy() {
        withIsolatedDefaults { defaults in
            defaults.set("unknown-mode", forKey: "sidebar.selectedMode")

            #expect(SidebarPreferences(defaults: defaults).selectedMode == .hierarchy)
        }
    }

    @Test
    func renderedContentClearsTheHostsOverlaidFooter() async throws {
        let suite = "SidebarFooterTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SidebarPreferences(defaults: defaults)
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
    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "SidebarPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
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
