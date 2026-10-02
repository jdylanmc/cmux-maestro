import AppKit
import SwiftUI
import Testing

// Hosted synthetic evidence only. Never launch or register a Maestro/CMUX app.
@MainActor
@Suite(SidebarAppKitTestScope())
struct SidebarInternalTaskRenderingTests {
    @Test(arguments: SidebarMode.allCases)
    func review001HistoricalTasksKeepTheirOwnSessionHeading(_ mode: SidebarMode) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.selectedMode = mode
        let data = SidebarTreeFixtures()
        let now = Date()
        func result(_ event: UUID) -> CopilotChildWork {
            .init(id: "same-task", parentID: nil, kind: .subagent, name: "Identical task label",
                  state: .completed, model: nil, terminalEvent: .init(id: event, timestamp: now))
        }
        let model = await makeModel(data, children: [result(UUID())], now: now, managed: true, additional: [
            data.session(id: data.otherSessionID, liveness: .dead, children: [
                result(UUID()),
                .init(id: "remaining", parentID: nil, kind: .subagent, name: "Another historical outcome",
                      state: .completed, model: nil, terminalEvent: .init(id: UUID(), timestamp: now))
            ], now: now)
        ])
        defer { model.setVisible(false) }
        let mounted = mount(model, preferences, width: 350)
        defer { mounted.window.contentView = nil; mounted.window.close() }
        await sidebarEventually {
            names(mounted.host).count == 3
                && buttons(mounted.host).contains { $0.accessibilityLabel() == "Inspect context session 20000000" }
        }
        mounted.host.layoutSubtreeIfNeeded()
        let controls = buttons(mounted.host)
        let owner = try #require(controls.first { $0.accessibilityLabel() == "Focus Managed owner" })
        let context = try #require(controls.first { $0.accessibilityLabel() == "Inspect context session 20000000" })
        let currentTask = try #require(names(mounted.host).first { $0.identifier?.rawValue == "\(data.sessionID):same-task" })
        let historicalTask = try #require(names(mounted.host).first { $0.identifier?.rawValue == "\(data.otherSessionID):same-task" })
        func frame(_ view: NSView) -> CGRect { mounted.host.convert(view.bounds, from: view) }
        #expect(frame(currentTask).minY > frame(owner).maxY)
        #expect(frame(context).minY > frame(currentTask).maxY)
        #expect(frame(historicalTask).minY > frame(context).maxY)
        #expect(controls.filter { $0.localFocusID?.hasPrefix("task-dismiss:") == true }.count == 3)
        #expect(model.copilot.tree.dismissibleOutcomes.count == 3)
        #expect(SidebarTopology(model.hierarchy).workspaceBySurface.count == 2)
        #expect(model.navigation.status == .idle)
        try capture(mounted.host, name: "review1-exact-session-context-\(mode.rawValue)")
        let dismiss = try #require(controls.first { $0.localFocusID == "task-dismiss:\(data.otherSessionID):same-task" })
        dismiss.performClick(nil)
        await sidebarEventually {
            names(mounted.host).count == 2
                && (mounted.window.firstResponder as? SidebarTitleNativeButton)?.localFocusID == "session:\(data.otherSessionID)"
        }
        #expect(preferences.history.dismissed.count == 1)
        #expect(preferences.history.dismissed.first?.sessionID == data.otherSessionID)
        #expect(model.copilot.tree.dismissibleOutcomes.contains { $0.sessionID == data.sessionID })
        #expect(model.navigation.status == .idle)
    }

    @Test(arguments: [SidebarHistoryRetention.fifteenSeconds, .never], SidebarMode.allCases)
    func review002DisplayedDismissControlHandlesHiddenCompletedChild(
        _ retention: SidebarHistoryRetention, _ mode: SidebarMode
    ) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.selectedMode = mode
        preferences.setRetention(retention)
        let data = SidebarTreeFixtures(), event = UUID()
        let now = Date()
        let model = await makeModel(data, children: [
            .init(id: "result", parentID: nil, kind: .subagent, name: "Finished task", state: .completed,
                  model: nil, terminalEvent: .init(id: event, timestamp: now)),
            .init(id: "shell", parentID: "result", kind: .shell, name: "Finished shell", state: .completed,
                  model: nil, terminalEvent: .init(id: UUID(), timestamp: now))
        ], now: now)
        defer { model.setVisible(false) }
        let mounted = mount(model, preferences, width: 280)
        defer { mounted.window.contentView = nil; mounted.window.close() }
        await sidebarEventually { names(mounted.host).count == 1 }
        let control = try #require(buttons(mounted.host).first { $0.localFocusID == "task-dismiss:\(data.sessionID):result" })
        #expect(model.copilot.tree.sessions[0].nodes[0].hasChildren)
        control.performClick(nil)
        await sidebarEventually { names(mounted.host).isEmpty }
        #expect(preferences.history.dismissed == [.init(sessionID: data.sessionID, childID: "result", eventID: event)])
        #expect(model.copilot.tree.sessions[0].nodes.contains { $0.id == "shell" })
        #expect(model.navigation.status == .idle)
        #expect(SidebarTopology(model.hierarchy).workspaceBySurface.count == 2)
        try capture(mounted.host, name: "review1-dismiss-hidden-child-\(retention.rawValue)-\(mode.rawValue)")
    }

    @Test(arguments: [false, true])
    func review003ManagedTaskboardKeepsMixedLegacyActivityAcrossCollapse(_ showEnded: Bool) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.showEnded = showEnded
        preferences.setRetention(.never)
        preferences.selectedMode = .taskboard
        let data = SidebarTreeFixtures(), now = Date()
        let model = await makeModel(data, children: [
            .init(id: "task", parentID: nil, kind: .subagent, name: "Internal task", state: .completed,
                  model: nil, terminalEvent: .init(id: UUID(), timestamp: now)),
            .init(id: "shell", parentID: "task", kind: .shell, name: "Running shell", state: .working, model: nil),
            .init(id: "idle", parentID: nil, kind: .skill, name: "Idle skill", state: .idle, model: nil),
            .init(id: "unknown", parentID: nil, kind: .skill, name: "Unknown skill", state: .unknown, model: nil),
            .init(id: "finished", parentID: nil, kind: .skill, name: "Finished skill", state: .completed,
                  model: nil, terminalEvent: .init(id: UUID(), timestamp: now))
        ], now: now, managed: true)
        defer { model.setVisible(false) }
        let mounted = mount(model, preferences, width: 350)
        defer { mounted.window.contentView = nil; mounted.window.close() }
        await sidebarEventually { model.orchestration.snapshot.nodes.count == 1 }
        let owner = try #require(model.orchestration.snapshot.nodes.first)
        let expected = ["Running shell", "Idle skill", "Unknown skill"] + (showEnded ? ["Finished skill"] : [])
        for expanded in [true, false] {
            preferences.setExpanded(expanded, for: .managed(owner.id))
            preferences.setExpanded(expanded, for: .internalTasks(sessionID: data.sessionID))
            preferences.selectedMode = .hierarchy
            await Task.yield()
            preferences.selectedMode = .taskboard
            await sidebarEventually {
                let labels = buttons(mounted.host).compactMap { $0.accessibilityLabel() }
                return expected.allSatisfy { name in labels.contains("Open parent chat for \(name), Copilot 10000000") }
                    && names(mounted.host).count == (expanded ? 1 : 0)
            }
            let labels = buttons(mounted.host).compactMap { $0.accessibilityLabel() }
            for name in expected {
                #expect(labels.filter { $0 == "Open parent chat for \(name), Copilot 10000000" }.count == 1)
            }
            #expect(labels.filter { $0 == "Focus Managed owner" }.count == 1)
            #expect(!labels.contains("Focus Copilot session 10000000"))
            #expect(names(mounted.host).count == (expanded ? 1 : 0))
            #expect(model.navigation.status == .idle)
        }
        try capture(mounted.host, name: "review1-legacy-taskboard-ended-\(showEnded)")
    }

    @Test(arguments: SidebarMode.allCases)
    func review004CollapsedMixedBranchAndOwnerRetainEvidenceAfterReload(_ mode: SidebarMode) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let data = SidebarTreeFixtures(), now = Date()
        let preferences = fixture.preferences()
        preferences.selectedMode = mode
        preferences.setExpanded(false, for: .internalTasks(sessionID: data.sessionID))
        func signal(_ kind: AgentAttentionKind, source: String = "copilot.events") -> AgentAttention {
            .init(kind: kind, evidence: .init(source: source, eventID: UUID()), occurredAt: now)
        }
        let model = await makeModel(data, children: [
            .init(id: "task", parentID: nil, kind: .subagent, name: "Mixed task", state: .completed, model: nil),
            .init(id: "working", parentID: "task", kind: .shell, name: "Working shell", state: .working, model: nil),
            .init(id: "blocked", parentID: "task", kind: .shell, name: "Blocked shell", state: .blocked, model: nil,
                  attention: [signal(.permission)]),
            .init(id: "failed", parentID: "task", kind: .skill, name: "Failed skill", state: .failed, model: nil,
                  attention: [signal(.error)]),
            .init(id: "uncertain", parentID: "task", kind: .shell, name: "Uncertain shell", state: .unknown, model: nil,
                  attention: [signal(.error, source: "invalid")]),
            .init(id: "hidden", parentID: nil, kind: .subagent, name: "Hidden unknown task", state: .unknown, model: nil)
        ], now: now, managed: true)
        defer { model.setVisible(false) }
        let reloaded = fixture.preferences()
        let mounted = mount(model, reloaded, width: 350)
        defer { mounted.window.contentView = nil; mounted.window.close() }
        await sidebarEventually {
            buttons(mounted.host).contains { $0.localFocusID == "task-disclosure:\(data.sessionID):session" }
        }
        let group = try #require(buttons(mounted.host).first { $0.localFocusID == "task-disclosure:\(data.sessionID):session" })
        #expect(group.toolTip?.contains("1 known running") == true)
        #expect(group.toolTip?.contains("1 blocked") == true)
        #expect(group.toolTip?.contains("3 need attention") == true)
        #expect(group.toolTip?.contains("Counts may be incomplete") == true)
        #expect(names(mounted.host).isEmpty)
        try capture(mounted.host, name: "review1-mixed-collapsed-group-\(mode.rawValue)")
        let owner = try #require(model.orchestration.snapshot.nodes.first)
        reloaded.setExpanded(false, for: .managed(owner.id))
        await sidebarEventually {
            !buttons(mounted.host).contains { $0.localFocusID == "task-disclosure:\(data.sessionID):session" }
        }
        let summary = SidebarBranchSummary(sessions: model.copilot.tree.sessions)
        #expect(summary.incomplete && summary.running == 1 && summary.blocked == 1 && summary.attention == 3)
        #expect(model.copilot.tree.sessions[0].internalTaskCountsIncomplete)
        #expect(!fixture.preferences().layout.isExpanded(.managed(owner.id)))
        #expect(model.navigation.status == .idle)
        try capture(mounted.host, name: "review1-mixed-collapsed-owner-\(mode.rawValue)")
    }

    @Test(arguments: [(280, false), (280, true), (350, false), (350, true), (460, false), (460, true)],
          SidebarMode.allCases)
    func combinedProductionOwnerAndTaskDepthKeepsGeometry(
        _ scenario: (width: Int, retained: Bool), _ mode: SidebarMode
    ) async throws {
        let data = SidebarTreeFixtures(), now = Date(), run = UUID()
        var chain: [SidebarOrchestrationNode] = []
        for depth in 0...SidebarOrchestrationReader.maximumDepth {
            chain.append(.init(
                id: UUID(), runId: run, parentId: chain.last?.id, role: depth == 0 ? "coordinator" : "worker",
                label: "Managed depth \(depth)", workspaceId: data.workspaceA,
                surfaceId: depth == SidebarOrchestrationReader.maximumDepth ? data.surfaceA : UUID(),
                generation: 1, phase: "turn-failed", availability: "idle",
                copilotSessionId: depth == SidebarOrchestrationReader.maximumDepth ? data.sessionID : UUID(),
                executionMode: .interactive, createdAt: now, updatedAt: now
            ))
        }
        try SidebarOrchestrationReader.validate(.init(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: chain), now: now)
        let children = (0...SidebarCopilotTree.maximumDepth).map { depth in
            CopilotChildWork(
                id: "nested-\(depth)", parentID: depth == 0 ? nil : "nested-\(depth - 1)", kind: .subagent,
                name: "Provider depth \(depth): " + String(repeating: "combined-long-name-", count: 8) + "suffix-\(depth)",
                state: scenario.retained ? .completed : .working, model: nil,
                terminalEvent: scenario.retained ? .init(id: UUID(), timestamp: now) : nil
            )
        }
        let hierarchy = HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true, workspaceMetadataAvailable: true,
            surfaceMetadataAvailable: true, workspacePathsAvailable: true,
            workspaces: [.init(
                id: data.workspaceA, title: .available("Combined depth fixture"), detail: .available(nil),
                isSelected: .available(false), isPinned: .available(false), unreadCount: .available(0),
                rootPath: .available(nil), projectRootPath: .available(nil),
                surfaces: .available(chain.map {
                    .init(id: $0.surfaceId, title: $0.label, kind: .terminal, isFocused: false,
                          isPinned: false, unreadCount: 0, workingDirectory: .available(nil))
                })
            )], windowID: data.windowID
        )
        let additional = scenario.retained ? [data.session(id: data.otherSessionID, state: .working, now: now)] : []
        for density in SidebarDensity.allCases {
            let fixture = try SidebarPreferenceFixture()
            defer { fixture.cleanup() }
            let preferences = fixture.preferences()
            preferences.selectedMode = mode
            preferences.setDensity(density)
            let model = await makeModel(data, children: children, now: now, liveness: scenario.retained ? .dead : .alive,
                                  additional: additional, managedNodes: chain, hierarchyOverride: hierarchy)
            defer { model.setVisible(false) }
            let mounted = mount(model, preferences, width: scenario.width, reduceMotion: true)
            defer { mounted.window.contentView = nil; mounted.window.close() }
            await sidebarEventually {
                model.orchestration.snapshot.nodes.count == 9 && names(mounted.host).count == 13
            }
            let fields = names(mounted.host)
            let deepest = try #require(fields.first { $0.stringValue.hasSuffix("suffix-12") })
            mounted.host.layoutSubtreeIfNeeded()
            deepest.scrollToVisible(deepest.bounds)
            mounted.host.layoutSubtreeIfNeeded()
            let frames = fields.map { mounted.host.convert($0.bounds, from: $0) }
            #expect(frames.count == 13)
            #expect(frames.allSatisfy { $0.width >= 124 && $0.height == 24 })
            #expect((frames.map(\.maxX).max() ?? 0) - (frames.map(\.maxX).min() ?? 0) < 1)
            #expect(fields.allSatisfy { $0.toolTip?.contains($0.stringValue) == true })
            #expect(fields.allSatisfy { $0.accessibilityLabel()?.contains($0.stringValue) == true })
            #expect(model.copilot.tree.sessions.first { $0.id == data.sessionID }?.nodes.map(\.depth).max() == 12)
            #expect(chain.count == 9 && SidebarOrchestrationReader.maximumDepth == 8)
            #expect(SidebarTopology(model.hierarchy).workspaceBySurface.count == 9)
            let expectedOwner = scenario.retained ? "Inspect work context Managed depth 8" : "Focus Managed depth 8"
            #expect(buttons(mounted.host).contains { $0.accessibilityLabel() == expectedOwner })
            let metrics = SidebarRenderingEvidence.metrics(for: mounted.host)
            #expect(metrics.documentWidth <= metrics.viewportWidth + 0.5)
            #expect(model.navigation.status == .idle && !mounted.window.isVisible)
            let name = "review1-combined-owner8-task12-\(scenario.width)-\(mode.rawValue)-\(density.rawValue)-retained-\(scenario.retained)"
            print("I131 C4 \(name): ownerDepth=8 taskDepth=12 taskRows=\(frames.count) "
                  + "minNameWidth=\(frames.map(\.width).min() ?? 0) "
                  + "rightEdgeSpread=\((frames.map(\.maxX).max() ?? 0) - (frames.map(\.maxX).min() ?? 0)) "
                  + "viewport=\(metrics.viewportWidth) document=\(metrics.documentWidth)")
            try capture(mounted.host, name: name)
            let geometry = fields.map {
                TaskGeometry(identity: $0.identifier?.rawValue ?? "", name: $0.stringValue,
                             frame: mounted.host.convert($0.bounds, from: $0))
            }
            let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/layout-validation/offscreen")
            try JSONEncoder().encode(geometry).write(to: folder.appendingPathComponent("\(name)-rows.json"))
        }
    }

    private struct TaskGeometry: Codable {
        let identity: String
        let name: String
        let frame: CGRect
    }

    @Test(arguments: SidebarMode.allCases)
    func managedOwnerRendersItsTasksOnceWithoutReplacingRealSurfaces(_ mode: SidebarMode) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.selectedMode = mode
        let data = SidebarTreeFixtures()
        let model = await makeModel(data, children: [
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
        let model = await makeModel(data, children: children, now: now)
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
        let model = await makeModel(data, children: children, now: now)
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
        let model = await makeModel(data, children: children, now: now)
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
        let model = await makeModel(data, children: [child], now: now, liveness: ownerAlive ? .alive : .dead)
        defer { model.setVisible(false) }
        let hierarchy = model.hierarchy
        let mounted = mount(model, preferences, width: 280)
        defer { mounted.window.contentView = nil; mounted.window.close() }
        try #require(!mounted.window.isVisible, "The fixture must start unordered")
        await sidebarEventually { names(mounted.host).count == 1 }
        try #require(!mounted.window.isVisible, "Mounting and observations must not order the fixture")
        let wasKey = mounted.window.isKeyWindow
        let wasMain = mounted.window.isMainWindow
        let control = try #require(buttons(mounted.host).first { $0.localFocusID == "task-dismiss:\(data.sessionID):result" })
        try #require(mounted.window.makeFirstResponder(control))
        try #require(!mounted.window.isVisible, "Focusing the dismiss control alone must not order the fixture")
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
        #expect(mounted.window.isKeyWindow == wasKey && mounted.window.isMainWindow == wasMain)
        print("R4 \(mode.rawValue)/alive=\(ownerAlive): initial/order-before-action=false; after-dismiss=\(mounted.window.isVisible); local=\(focused.localFocusID ?? "none")")
        try capture(mounted.host, name: "internal-task-dismiss-\(mode.rawValue)-owner-\(ownerAlive)")
    }

    @Test func programmaticFocusRestorationDoesNotOpenTheKeyboardPreview() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let control = SidebarTitleNativeButton(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        window.contentView = control
        defer { window.contentView = nil; window.close() }
        var previewEvents: [Bool] = []
        var localFocusEvents: [Bool] = []
        control.preview = .init(available: true, focus: { previewEvents.append($0) })
        control.focusChanged = { localFocusEvents.append($0) }
        let surface = UUID(), workspace = UUID()
        let focus = SidebarLocalFocus()
        focus.register(control, id: "surface:\(surface)")
        try #require(!window.isVisible)
        #expect(focus.restore(surfaceID: surface, workspaceID: workspace, ownerVisible: true, workspaceVisible: false))
        #expect(window.firstResponder === control)
        #expect(localFocusEvents.contains(true))
        #expect(!previewEvents.contains(true), "Restoring local focus must not call the preview path that orders a child panel")
        #expect(!window.isVisible && !window.isKeyWindow)
        try #require(window.makeFirstResponder(nil))
        try #require(window.makeFirstResponder(control))
        #expect(previewEvents.filter { $0 }.count == 1, "Ordinary keyboard focus must retain its existing preview behavior")
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
        liveness: CopilotLiveness = .alive, managed: Bool = false,
        additional: [CopilotSessionObservation] = [], managedNodes: [SidebarOrchestrationNode]? = nil,
        hierarchyOverride: HierarchySnapshot? = nil
    ) async -> SidebarConnectionModel {
        let snapshot = data.snapshot(sessions: [data.session(liveness: liveness, children: children, now: now)] + additional, now: now)
        let polling = SidebarCopilotPolling(
            read: neutralRead { _ in snapshot }, pause: { try await sidebarFrozenExpiry(0) },
            expiryPause: sidebarFrozenExpiry, now: { now }
        )
        let nodes: [SidebarOrchestrationNode] = managedNodes ?? (managed ? [
            .init(id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Managed owner",
                  workspaceId: data.workspaceA, surfaceId: data.surfaceA, generation: 1, phase: "registered",
                  availability: "active", copilotSessionId: data.sessionID, executionMode: .interactive,
                  createdAt: now, updatedAt: now)
        ] : [])
        let orchestration = SidebarOrchestrationPolling(
            read: { .init(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: nodes) },
            pause: { try await sidebarFrozenExpiry(0) }
        )
        let model = SidebarConnectionModel(copilot: polling, orchestration: orchestration)
        let hierarchy = hierarchyOverride ?? data.hierarchy()
        model.replaceHierarchy(with: hierarchy)
        model.showConnected(workspaceCount: hierarchy.workspaces.count, surfaceCount: SidebarTopology(hierarchy).workspaceBySurface.count)
        let topology = SidebarTopology(hierarchy)
        polling.update(topology: topology, connected: true)
        orchestration.update(topology: topology, connected: true)
        model.navigation.update(topology: topology, connected: true, workspaceAllowed: true, surfaceAllowed: true,
                                perform: { _ in Issue.record("Internal task controls must not invoke native navigation") })
        orchestration.setVisible(true)
        await sidebarEventually { orchestration.snapshot.generatedAt == now }
        polling.updateManagedSubjects(orchestration.snapshot)
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
