import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized)
struct SidebarHoverTests {
    @Test func pointerTravelAndExplicitDismissalHaveSeparateState() {
        var state = SidebarHoverState()
        #expect(!state.shouldOpen)
        state.anchor(true)
        #expect(state.shouldOpen)
        state.open(explicit: false)
        state.anchor(false)
        #expect(state.shouldClose)
        state.card(true)
        #expect(!state.shouldClose)
        state.card(false)
        #expect(state.shouldClose)
        state.dismiss()
        #expect(state.mode == .hidden)
        state.anchor(true)
        state.open(explicit: true)
        state.anchor(false)
        state.card(false)
        #expect(!state.shouldClose)
        state.anchor(true)
        state.dismiss()
        #expect(!state.shouldOpen)
        state.anchor(false)
        state.anchor(true)
        #expect(state.shouldOpen)
    }

    @Test func leavingOrDetachingCancelsPendingHover() async throws {
        let presenter = SidebarHoverPresenter()
        presenter.hoverAnchor(true)
        presenter.hoverAnchor(false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(presenter.panel == nil && presenter.state.mode == .hidden)
        presenter.hoverAnchor(true)
        presenter.detach()
        try await Task.sleep(for: .milliseconds(400))
        #expect(presenter.panel == nil && presenter.state.mode == .hidden)
    }

    @Test func hoverPanelsCannotBecomeKeyOrMainUnlessExplicitlyRequested() {
        let panel = SidebarHoverPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        panel.allowsKeyboard = true
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.isVisible)
    }

    @Test func losingPanelFocusOrApplicationActivationReleasesPreviewOwnership() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        window.contentView = anchor
        defer { window.contentView = nil; window.close() }
        let group = SidebarHoverGroup()
        for notification in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            let presenter = SidebarHoverPresenter(showPanel: { _, _, _ in })
            presenter.update(anchor: anchor, data: .init(id: "one", category: "Preview", title: "One"), group: group)
            let original = window.firstResponder
            presenter.open(explicit: true)
            #expect(presenter.state.mode == .explicit)
            #expect(presenter.isMonitoring)
            let panel = try #require(presenter.panel)
            #expect(!panel.isVisible && !window.isVisible)
            let other = SidebarHoverPresenter(showPanel: { _, _, _ in })
            #expect(!group.claim(other, explicit: false))
            NotificationCenter.default.post(
                name: notification,
                object: notification == NSWindow.didResignKeyNotification ? panel : NSApp
            )
            #expect(presenter.state.mode == .hidden)
            #expect(!presenter.isMonitoring && panel.contentView == nil)
            #expect(window.firstResponder === original)
            #expect(group.claim(other, explicit: false))
        }
    }

    @Test func placementFitsScreenEdgesAndShortAvailableSpace() {
        for visible in [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: -1440, y: 70, width: 1440, height: 830),
            CGRect(x: 100, y: 100, width: 240, height: 180)
        ] {
            for anchor in [
                CGRect(x: visible.minX + 10, y: visible.maxY - 40, width: 180, height: 24),
                CGRect(x: visible.maxX - 190, y: visible.minY + 10, width: 180, height: 24),
                CGRect(x: visible.midX, y: visible.midY, width: 24, height: 24)
            ] {
                let frame = SidebarHoverPlacement.frame(anchor: anchor, visible: visible,
                                                       preferred: CGSize(width: 300, height: 360))
                #expect(visible.contains(frame))
                #expect(frame.width <= 300 && frame.height <= 360)
            }
        }
        let right = SidebarHoverPlacement.frame(
            anchor: CGRect(x: 20, y: 400, width: 180, height: 24),
            visible: CGRect(x: 0, y: 0, width: 1400, height: 900),
            preferred: CGSize(width: 300, height: 260)
        )
        #expect(right.minX == 206)
    }

    @Test func workspaceCardsUseExactIdentityAndGrantedCurrentMetadata() throws {
        let fixtures = SidebarTreeFixtures()
        let original = fixtures.hierarchy()
        let a = try #require(SidebarHoverContent.workspace(fixtures.workspaceA, hierarchy: original, connected: true))
        let b = try #require(SidebarHoverContent.workspace(fixtures.workspaceB, hierarchy: original, connected: true))
        #expect(a.id != b.id && a.title == b.title)
        #expect(a.category == "Workspace preview")
        #expect(a.lines.contains(.init(title: "Shared surfaces", value: "1 terminal")))
        #expect(a.lines.contains(.init(title: "Workspace ID", value: fixtures.workspaceA.uuidString)))
        #expect(!a.lines.contains { $0.title.contains("Agent") || $0.title.contains("Pet") })
        #expect(SidebarHoverContent.workspace(fixtures.workspaceA, hierarchy: original, connected: false) == nil)
        #expect(SidebarHoverContent.workspace(UUID(), hierarchy: original, connected: true) == nil)
        let denied = try #require(SidebarHoverContent.workspace(
            fixtures.workspaceA, hierarchy: fixtures.hierarchy(granted: false), connected: true
        ))
        #expect(denied.lines.isEmpty && denied.notice == "Workspace metadata unavailable")
        let ambiguous = try #require(SidebarHoverContent.workspace(
            fixtures.workspaceA, hierarchy: fixtures.hierarchy(duplicateSurface: true), connected: true
        ))
        #expect(ambiguous.lines.contains(.init(title: "Shared surfaces", value: "Count unavailable; placement is ambiguous")))
        let moved = try #require(SidebarHoverContent.workspace(
            fixtures.workspaceA, hierarchy: fixtures.hierarchy(moved: true), connected: true
        ))
        #expect(moved.lines.contains(.init(title: "Shared surfaces", value: "None")))
    }

    @Test func passiveComponentsHaveNoNavigationOrPreferenceMutationDependencies() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("CMUXMaestroSidebar/UI/SidebarHoverCard.swift"), encoding: .utf8)
        for forbidden in ["SidebarNavigation", "SidebarPreferences", "SidebarSeen", "UserDefaults", "context.host", "markSeen", "acknowledge"] {
            #expect(!source.contains(forbidden))
        }
        #expect(source.contains(".nonactivatingPanel"))
        #expect(source.contains("override var canBecomeMain: Bool { false }"))
    }

    @Test(arguments: [false, true])
    func renderWorkspaceCardWithoutClippingOrSideEffects(dark: Bool) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let before = (preferences.history, preferences.attention, preferences.layout, preferences.icons)
        let data = SidebarHoverCardData(
            id: "synthetic-workspace", category: "Workspace preview",
            title: "Maestro design", subtitle: "Sidebar and personalization",
            lines: [
                .init(title: "Shared surfaces", value: "3 terminal, 1 browser"),
                .init(title: "Workspace path", value: "/synthetic/repository/with/a/long/path/that/must/wrap/without/clipping"),
                .init(title: "Project path", value: "Path unavailable"),
                .init(title: "Workspace ID", value: UUID().uuidString)
            ]
        )
        for size in [NSSize(width: 300, height: 360), NSSize(width: 224, height: 164)] {
            let frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: SidebarHoverCard(data: data, close: {
                Issue.record("Rendering must not dismiss the card")
            }, copySessionID: { _ in
                Issue.record("Rendering must not copy")
                return false
            }).environment(\.colorScheme, dark ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            hosting.frame = frame
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
            #expect(!window.isVisible)
            let metrics = SidebarRenderingEvidence.metrics(for: hosting)
            #expect(metrics.documentWidth <= metrics.viewportWidth + 0.5)
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/layout-validation/offscreen")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let image = root.appendingPathComponent("hover-workspace-\(Int(size.width))-\(dark ? "dark" : "light").png")
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
            let text = try SidebarRenderingEvidence.recognizedLines(in: image, dark: dark, naturalLanguage: true).joined(separator: " ")
            #expect(text.contains("Maestro design"))
            #expect(text.contains("Preview only"))
        }
        #expect(preferences.history == before.0 && preferences.attention == before.1)
        #expect(preferences.layout == before.2 && preferences.icons == before.3)
    }
}
