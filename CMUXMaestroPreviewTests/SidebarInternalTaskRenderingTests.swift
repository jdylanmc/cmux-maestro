import AppKit
import SwiftUI
import Testing

// Hosted synthetic evidence only. Never launch or register a Maestro/CMUX app.
@MainActor
@Suite(SidebarAppKitTestScope())
struct SidebarInternalTaskRenderingTests {
    @Test(arguments: SidebarMode.allCases)
    func managedOwnerRendersItsTasksOnceWithoutReplacingRealSurfaces(_ mode: SidebarMode) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.selectedMode = mode
        let data = SidebarTreeFixtures()
        let model = makeModel(data, children: [
            .init(id: "owned", parentID: nil, kind: .subagent, name: "Owned internal task", state: .working, model: nil)
        ], now: Date(), managed: true)
        defer { model.setVisible(false) }
        let mounted = mount(model, preferences, width: 280)
        defer { mounted.window.contentView = nil; mounted.window.close() }
        await sidebarEventually {
            model.orchestration.snapshot.nodes.count == 1 && names(mounted.host).count == 1
                && buttons(mounted.host).contains { $0.accessibilityLabel() == "Focus Managed owner" }
        }
        #expect(names(mounted.host).map(\.stringValue) == ["Owned internal task"])
        let titles = buttons(mounted.host)
        #expect(titles.filter { $0.accessibilityLabel() == "Focus Managed owner" }.count == 1)
        #expect(!titles.contains { $0.accessibilityLabel() == "Focus Copilot session 10000000" })
        if mode == .hierarchy {
            #expect(titles.contains { $0.localFocusID == "surface:\(data.surfaceB)" })
        }
        #expect(SidebarTopology(model.hierarchy).workspaceBySurface.count == 2)
        #expect(model.navigation.status == .idle)
        try capture(mounted.host, name: "internal-tasks-managed-\(mode.rawValue)-280")
    }

    @Test(arguments: [280, 350, 460], SidebarMode.allCases)
    func compactTasksKeepNamesAndStatusEdgeAtProductionDepth(_ width: Int, _ mode: SidebarMode) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.selectedMode = mode
        let data = SidebarTreeFixtures()
        let now = Date()
        let children = (0...12).map { depth in
            CopilotChildWork(
                id: "depth-\(depth)", parentID: depth == 0 ? nil : "depth-\(depth - 1)", kind: .subagent,
                name: "Inspect nested task \(depth): " + String(repeating: "long-name-", count: 15) + "unique-\(depth)",
                state: .working, model: nil
            )
        } + [
            .init(id: "finished", parentID: nil, kind: .subagent, name: "Review completed changes",
                  state: .completed, model: nil, terminalEvent: .init(id: UUID(), timestamp: now)),
            .init(id: "failed", parentID: nil, kind: .subagent, name: "Check failed assumptions",
                  state: .failed, model: nil, terminalEvent: .init(id: UUID(), timestamp: now)),
            .init(id: "blocked", parentID: nil, kind: .subagent, name: "Wait for permission",
                  state: .blocked, model: nil)
        ]
        let model = makeModel(data, children: children, now: now)
        defer { model.setVisible(false) }
        for density in SidebarDensity.allCases {
            preferences.setDensity(density)
            for reducedMotion in [false, true] {
                let mounted = mount(model, preferences, width: width, reduceMotion: reducedMotion)
                defer { mounted.window.contentView = nil; mounted.window.close() }
                await sidebarEventually { model.copilot.tree.sessions.count == 1 && names(mounted.host).count == 16 }
                mounted.host.layoutSubtreeIfNeeded()
                let fields = names(mounted.host)
                try #require(fields.count == 16)
                let frames = fields.map { mounted.host.convert($0.bounds, from: $0) }
                let rightEdges = frames.map(\.maxX)
                #expect((rightEdges.max() ?? 0) - (rightEdges.min() ?? 0) < 1)
                #expect(frames.allSatisfy { $0.width >= 124 && $0.height == 24 })
                #expect(fields.contains { $0.stringValue.hasSuffix("unique-12") })
                #expect(fields.allSatisfy { !$0.isEditable && !$0.isSelectable })
                #expect(fields.allSatisfy { $0.toolTip?.contains($0.stringValue) == true })
                #expect(fields.allSatisfy { $0.accessibilityLabel()?.contains($0.stringValue) == true })
                let metrics = SidebarRenderingEvidence.metrics(for: mounted.host)
                #expect(metrics.documentWidth <= metrics.viewportWidth + 0.5)
                #expect(model.navigation.status == .idle)
                #expect(!mounted.window.isVisible)
                try capture(mounted.host, name: "internal-tasks-\(mode.rawValue)-\(density.rawValue)-\(width)-motion-\(reducedMotion)")
            }
        }
    }

    @Test func productionNodeCapDoesNotDropWorkingEvidenceOrInventCompleteTotals() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let data = SidebarTreeFixtures()
        let now = Date()
        let children = (0...256).map {
            CopilotChildWork(id: "task-\($0)", parentID: nil, kind: .subagent, name: "Bounded synthetic task \($0)",
                             state: .working, model: nil)
        }
        let model = makeModel(data, children: children, now: now)
        defer { model.setVisible(false) }
        let mounted = mount(model, fixture.preferences(), width: 280)
        defer { mounted.window.contentView = nil; mounted.window.close() }
        await sidebarEventually { model.copilot.tree.sessions.count == 1 && names(mounted.host).count == 256 }
        mounted.host.layoutSubtreeIfNeeded()
        #expect(names(mounted.host).count == 256)
        #expect(model.copilot.tree.sessions[0].omittedActiveChildrenCount == 1)
        #expect(!model.copilot.tree.hasCompleteCounts)
        let header = try #require(buttons(mounted.host).first { $0.localFocusID?.hasPrefix("task-disclosure:") == true })
        #expect(header.accessibilityLabel()?.contains("256 observed") == true)
        #expect(header.toolTip?.contains("1 additional working/blocked tasks") == true)
        #expect(header.toolTip?.contains("Counts may be incomplete") == true)
        try capture(mounted.host, name: "internal-tasks-production-cap-280")
    }

    @Test func taskDisclosureKeyboardAndPointerSharePersistedIdentityAcrossModes() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let data = SidebarTreeFixtures()
        let now = Date()
        let children: [CopilotChildWork] = [
            .init(id: "parent", parentID: nil, kind: .subagent, name: "Parent task", state: .working, model: nil),
            .init(id: "nested", parentID: "parent", kind: .subagent, name: "Nested task", state: .blocked, model: nil)
        ]
        let model = makeModel(data, children: children, now: now)
        defer { model.setVisible(false) }
        let mounted = mount(model, preferences, width: 350)
        defer { mounted.window.contentView = nil; mounted.window.close() }
        await sidebarEventually { names(mounted.host).count == 2 }
        let parent = try #require(buttons(mounted.host).first { $0.localFocusID == "task-children:\(data.sessionID):parent" })
        parent.performClick(nil)
        await sidebarEventually { names(mounted.host).count == 1 }
        #expect(!preferences.layout.isExpanded(.child("parent", sessionID: data.sessionID)))
        let group = try #require(buttons(mounted.host).first { $0.localFocusID == "task-disclosure:\(data.sessionID):session" })
        try #require(mounted.window.makeFirstResponder(group))
        group.keyDown(with: keyEvent(window: mounted.window))
        await sidebarEventually { names(mounted.host).isEmpty }
        #expect(!preferences.layout.isExpanded(.internalTasks(sessionID: data.sessionID)))
        #expect(group.toolTip?.contains("1 known running") == true)
        #expect(group.toolTip?.contains("1 blocked") == true)
        preferences.selectedMode = .taskboard
        await sidebarEventually {
            buttons(mounted.host).contains { $0.localFocusID == "task-disclosure:\(data.sessionID):session" }
                && names(mounted.host).isEmpty
        }
        let current = try #require(buttons(mounted.host).first { $0.localFocusID == "task-disclosure:\(data.sessionID):session" })
        current.performClick(nil)
        await sidebarEventually { names(mounted.host).count == 1 }
        #expect(fixture.preferences().layout.isExpanded(.internalTasks(sessionID: data.sessionID)))
        #expect(!fixture.preferences().layout.isExpanded(.child("parent", sessionID: data.sessionID)))
        #expect(model.navigation.status == .idle)
    }

    @Test(arguments: [true, false], SidebarMode.allCases)
    func exactOutcomeDismissalRestoresVisibleLocalFocusWithoutNavigation(_ ownerAlive: Bool, _ mode: SidebarMode) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.selectedMode = mode
        let data = SidebarTreeFixtures()
        let now = Date()
        let event = UUID()
        let child = CopilotChildWork(id: "result", parentID: nil, kind: .subagent, name: "Reviewed outcome",
                                    state: .completed, model: nil, terminalEvent: .init(id: event, timestamp: now))
        let model = makeModel(data, children: [child], now: now, liveness: ownerAlive ? .alive : .dead)
        defer { model.setVisible(false) }
        let hierarchy = model.hierarchy
        let mounted = mount(model, preferences, width: 280)
        defer { mounted.window.contentView = nil; mounted.window.close() }
        await sidebarEventually { names(mounted.host).count == 1 }
        let control = try #require(buttons(mounted.host).first { $0.localFocusID == "task-dismiss:\(data.sessionID):result" })
        try #require(mounted.window.makeFirstResponder(control))
        control.keyDown(with: keyEvent(window: mounted.window))
        await sidebarEventually {
            names(mounted.host).isEmpty && mounted.window.firstResponder !== control
                && mounted.window.firstResponder is SidebarTitleNativeButton
        }
        let focused = try #require(mounted.window.firstResponder as? SidebarTitleNativeButton)
        #expect(!focused.isHiddenOrHasHiddenAncestor && focused.window === mounted.window)
        let expected = !ownerAlive && mode == .taskboard ? "taskboard" : "surface:\(data.surfaceA)"
        #expect(focused.localFocusID == expected)
        #expect(preferences.history.dismissed == [.init(sessionID: data.sessionID, childID: "result", eventID: event)])
        #expect(model.navigation.status == .idle)
        #expect(model.hierarchy == hierarchy)
        #expect(SidebarTopology(model.hierarchy).workspaceBySurface.count == 2)
        #expect(!mounted.window.isVisible)
        try capture(mounted.host, name: "internal-task-dismiss-\(mode.rawValue)-owner-\(ownerAlive)")
    }

    private func names(_ view: NSView) -> [NSTextField] {
        descendants(view).compactMap { $0 as? NSTextField }.filter { $0.accessibilityIdentifier() == "internal-task-name" }
    }
    private func buttons(_ view: NSView) -> [SidebarTitleNativeButton] {
        descendants(view).compactMap { $0 as? SidebarTitleNativeButton }
    }
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    private func keyEvent(window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: " ",
                         charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
    }
    private func mount(
        _ model: SidebarConnectionModel, _ preferences: SidebarPreferences, width: Int, reduceMotion: Bool = false
    ) -> (window: NSWindow, host: NSView) {
        let frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SidebarView(model: model, preferences: preferences)
            .environment(\._accessibilityReduceMotion, reduceMotion)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }
    private func makeModel(
        _ data: SidebarTreeFixtures, children: [CopilotChildWork], now: Date,
        liveness: CopilotLiveness = .alive, managed: Bool = false
    ) -> SidebarConnectionModel {
        let snapshot = data.snapshot(sessions: [data.session(liveness: liveness, children: children, now: now)], now: now)
        let polling = SidebarCopilotPolling(
            read: neutralRead { _ in snapshot }, pause: { try await sidebarFrozenExpiry(0) },
            expiryPause: sidebarFrozenExpiry, now: { now }
        )
        let nodes: [SidebarOrchestrationNode] = managed ? [
            .init(id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Managed owner",
                  workspaceId: data.workspaceA, surfaceId: data.surfaceA, generation: 1, phase: "registered",
                  availability: "active", copilotSessionId: data.sessionID, executionMode: .interactive,
                  createdAt: now, updatedAt: now)
        ] : []
        let orchestration = SidebarOrchestrationPolling(
            read: { .init(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: nodes) },
            pause: { try await sidebarFrozenExpiry(0) }
        )
        let model = SidebarConnectionModel(copilot: polling, orchestration: orchestration)
        let hierarchy = data.hierarchy()
        model.replaceHierarchy(with: hierarchy)
        model.showConnected(workspaceCount: 2, surfaceCount: 2)
        let topology = SidebarTopology(hierarchy)
        polling.update(topology: topology, connected: true)
        orchestration.update(topology: topology, connected: true)
        model.navigation.update(topology: topology, connected: true, workspaceAllowed: true, surfaceAllowed: true,
                                perform: { _ in Issue.record("Internal task controls must not invoke native navigation") })
        model.setVisible(true)
        return model
    }
    private func capture(_ view: NSView, name: String) throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent("\(name).png"))
        try JSONEncoder().encode(SidebarRenderingEvidence.metrics(for: view))
            .write(to: folder.appendingPathComponent("\(name).json"))
    }
}
