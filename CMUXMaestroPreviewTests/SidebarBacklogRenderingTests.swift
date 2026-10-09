import AppKit
import SwiftUI
import Testing

/// Synthetic UI only; never opens a URL or connects to a live CMUX host.
@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarBacklogRenderingTests {
    @Test(arguments: SidebarMode.allCases)
    func arrowAndKeyboardMenuShareExactWorkspaceActionWithoutChangingEye(mode: SidebarMode) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let identities = SidebarTreeFixtures()
        let preferences = fixture.preferences()
        preferences.selectedMode = mode
        preferences.setBacklogURL("https://example.com/first", for: identities.workspaceA)
        preferences.setBacklogURL("https://example.org/second", for: identities.workspaceB)
        let now = Date()
        let node = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Synthetic coordinator",
            workspaceId: identities.workspaceA, surfaceId: identities.surfaceA, generation: 1,
            phase: "registered", availability: "active", createdAt: now, updatedAt: now
        )
        let model = SidebarConnectionModel(
            copilot: SidebarCopilotPolling(
                read: neutralRead { _ in .init(generatedAt: now, sessions: [], issues: [], isComplete: true) },
                pause: { try await Task.sleep(for: .seconds(60)) }, expiryPause: sidebarFrozenExpiry, now: { now }
            ),
            orchestration: SidebarOrchestrationPolling(
                read: { .init(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: [node]) },
                pause: { try await Task.sleep(for: .seconds(60)) }
            ),
            backlog: SidebarBacklog(timeout: { try await sidebarFrozenExpiry(0) })
        )
        let hierarchy = identities.hierarchy()
        model.replaceHierarchy(with: hierarchy)
        model.showConnected(workspaceCount: 2, surfaceCount: 2)
        model.copilot.update(topology: SidebarTopology(hierarchy), connected: true)
        model.orchestration.update(topology: SidebarTopology(hierarchy), connected: true)
        var opened: [SidebarBacklog.Request] = []
        model.backlog.update(hierarchy: hierarchy, connected: true, allowed: true, perform: { opened.append($0) })
        model.navigation.update(topology: SidebarTopology(hierarchy), connected: true,
                                workspaceAllowed: true, surfaceAllowed: true,
                                perform: { _ in Issue.record("Backlog must not dispatch separate focus commands.") })
        model.setVisible(true)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 650),
                              styleMask: .titled, backing: .buffered, defer: false)
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
        await sidebarEventually { model.orchestration.snapshot.nodes == [node] }
        hosting.layoutSubtreeIfNeeded()
        await sidebarEventually {
            accessibilityNodes(hosting).contains { $0.identifier == "backlog-\(identities.workspaceA)" }
        }
        hosting.layoutSubtreeIfNeeded()
        let arrow = try #require(accessibilityNodes(hosting).first { $0.identifier == "backlog-\(identities.workspaceA)" })
        let eye = try #require(accessibilityNodes(hosting).first { $0.identifier == "idle-tasks-\(identities.workspaceA)" })
        let arrowFrame = try #require(arrow.frame), eyeFrame = try #require(eye.frame)
        #expect(arrowFrame.width >= 24 && arrowFrame.height >= 24)
        #expect(arrowFrame.minX >= eyeFrame.maxX)
        #expect(!arrowFrame.intersects(eyeFrame))
        #expect(opened.isEmpty && model.navigation.status == .idle)
        let before = preferences.layout
        #expect(arrow.press())
        await sidebarEventually { opened.count == 1 && model.backlog.status == .accepted }
        #expect(opened.first?.workspaceID == identities.workspaceA)
        #expect(opened.first?.surfaceID == identities.surfaceA)
        #expect(opened.first?.url.absoluteString == "https://example.com/first")

        let title = try #require(descendants(hosting).compactMap { $0 as? SidebarTitleNativeButton }
            .first { $0.accessibilityLabel()?.hasPrefix("Focus workspace ") == true })
        var capturedMenu: NSMenu?
        for presenter in descendants(hosting).compactMap({ ($0 as? SidebarRowMenuAnchorView)?.presenter }) {
            presenter.present = { menu, _, _ in capturedMenu = menu }
        }
        title.keyDown(with: try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 109
        )))
        let open = try #require(capturedMenu?.items.flatMap { $0.submenu?.items ?? [] }.first { $0.title == "Open backlog" })
        #expect(open.isEnabled)
        let presenter = try #require(open.target as? SidebarRowMenuPresenter)
        presenter.invoke(open)
        await sidebarEventually { opened.count == 2 && model.backlog.status == .accepted }
        #expect(opened[1] == opened[0])
        #expect(preferences.layout == before)
        #expect(model.navigation.status == .idle)

        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent("backlog-\(mode.rawValue)-280.png"))

        preferences.setBacklogURL("", for: identities.workspaceA)
        model.backlog.open(workspaceID: identities.workspaceA, windowID: identities.windowID, urlText: nil)
        await sidebarEventually {
            accessibilityNodes(hosting).contains { $0.identifier == "sidebar-backlog-status" }
        }
        #expect(model.backlog.status == .missingURL)
        let otherReader = fixture.preferences()
        otherReader.setBacklogURL("https://example.com/configured", for: identities.workspaceA)
        preferences.refreshBacklogs()
        await sidebarEventually {
            model.backlog.status == nil
                && !accessibilityNodes(hosting).contains { $0.identifier == "sidebar-backlog-status" }
        }
        #expect(fixture.preferences().backlog.urlText(for: identities.workspaceA) == "https://example.com/configured")
        #expect(preferences.backlog.urlText(for: identities.workspaceB) == "https://example.org/second")
        #expect(opened.count == 2, "Saving and refreshing configuration must not open another browser.")

        model.backlog.update(hierarchy: .empty, connected: true, allowed: true,
                             perform: { _ in Issue.record("A vanished target cannot open.") })
        model.replaceHierarchy(with: .empty)
        presenter.invoke(open)
        #expect(model.backlog.status == .unavailable)
        await sidebarEventually {
            accessibilityNodes(hosting).contains { $0.identifier == "sidebar-backlog-status" }
        }
        #expect(opened.count == 2, "Retained menu must not navigate a replacement or selected workspace.")
    }

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

    private struct Accessible {
        let object: NSObject
        var identifier: String? { (object as AnyObject).accessibilityIdentifier?() ?? nil }
        var frame: NSRect? { (object as AnyObject).accessibilityFrame?() }
        func press() -> Bool { (object as AnyObject).accessibilityPerformPress?() ?? false }
    }

    private func accessibilityNodes(_ view: NSView) -> [Accessible] {
        var pending: [NSObject] = [view]
        var visited = Set<ObjectIdentifier>()
        var result: [Accessible] = []
        while let object = pending.popLast(), result.count < 2_048 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(Accessible(object: object))
            let children = (object as AnyObject).accessibilityChildren?() ?? []
            pending += NSAccessibility.unignoredChildren(from: children).compactMap { $0 as? NSObject }
        }
        return result
    }
}
