import AppKit
import SwiftUI
import Testing

/// Synthetic UI only; never opens a URL or connects to a live CMUX host.
@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarBacklogRenderingTests {
    @Test func unconfiguredWorkspaceOffersExplicitBacklogConfiguration() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let hierarchy = SidebarTreeFixtures().hierarchy()
        let model = SidebarConnectionModel(
            copilot: SidebarCopilotPolling(
                read: neutralRead { _ in .init(generatedAt: Date(), sessions: [], issues: [], isComplete: true) },
                pause: { try await Task.sleep(for: .seconds(60)) }
            ),
            orchestration: SidebarOrchestrationPolling(
                read: { .init(version: 1, generatedAt: Date(), complete: true, omittedCount: 0, nodes: []) },
                pause: { try await Task.sleep(for: .seconds(60)) }
            )
        )
        model.replaceHierarchy(with: hierarchy)
        model.showConnected(workspaceCount: 2, surfaceCount: 2)
        model.navigation.update(
            topology: SidebarTopology(hierarchy), connected: true,
            workspaceAllowed: true, surfaceAllowed: true,
            perform: { _ in Issue.record("Configuring a backlog must not navigate.") }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 340, height: 650),
            styleMask: .titled, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences))
        window.contentView = hosting
        window.orderFront(nil)
        defer {
            model.setVisible(false)
            for child in window.childWindows ?? [] { child.close() }
            window.contentView = nil
            window.close()
        }
        hosting.layoutSubtreeIfNeeded()
        await sidebarEventually {
            descendants(hosting).contains { ($0 as? SidebarTitleNativeButton)?.showActions != nil }
        }
        hosting.layoutSubtreeIfNeeded()
        let title = try #require(descendants(hosting).compactMap { $0 as? SidebarTitleNativeButton }
            .first { $0.accessibilityLabel()?.hasPrefix("Focus workspace ") == true })
        var capturedMenu: NSMenu?
        for presenter in descendants(hosting).compactMap({ ($0 as? SidebarRowMenuAnchorView)?.presenter }) {
            presenter.present = { menu, _, _ in capturedMenu = menu }
        }
        let showActions = try #require(title.showActions)
        showActions()
        let menu = try #require(capturedMenu, "The production workspace keyboard menu must be reachable.")
        let configure = menu.items.flatMap { $0.submenu?.items ?? [] }
            .first { $0.title == "Configure backlog URL..." }
        #expect(configure?.isEnabled == true, "An unconfigured workspace needs an explicit URL editor, not a permanently unavailable backlog action.")
        #expect(model.navigation.status == .idle)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
