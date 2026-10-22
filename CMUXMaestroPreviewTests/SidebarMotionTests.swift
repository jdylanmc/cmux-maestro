import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarMotionTests {
    @Test(arguments: [AgentWorkState.unknown, .queued, .working, .idle, .blocked, .completed, .failed, .cancelled])
    func statusDecorationFootprintAndMotionFollowStateAndReduceMotion(state: AgentWorkState) throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 160, height: 28),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func views(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views($0) } }
        func animations(_ decoration: SidebarStatusAnimationView) -> [CAPropertyAnimation] {
            (decoration.layer?.sublayers ?? []).compactMap {
                $0.animation(forKey: SidebarStatusAnimationView.animationKey) as? CAPropertyAnimation
            }
        }
        for needsInput in [false, true] {
            var previous: [SidebarStatusAnimationView] = []
            for reduceMotion in [false, true, false] {
                let visual = SidebarPresentation.state(state)
                host.rootView = AnyView(SidebarStateBadge(visual: visual, needsInput: needsInput)
                    .background(SidebarActivityBackground(visual: visual, needsInput: needsInput))
                    .environment(\._accessibilityReduceMotion, reduceMotion))
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize == CGSize(width: 12, height: 14),
                        "Status keeps its fixed footprint, including while motion preferences change")
                let decorations = views(host).compactMap { $0 as? SidebarStatusAnimationView }
                let paths = decorations.flatMap(animations).compactMap(\.keyPath).sorted()
                let expected: [String] = reduceMotion ? [] : needsInput
                    ? ["opacity", "shadowOpacity", "shadowOpacity"]
                    : state == .working ? ["transform.rotation.z"] : []
                #expect(paths == expected,
                        "Only working rotation or input glow/tint may animate; Reduce Motion stops all three")
                #expect(decorations.count == (reduceMotion ? 0 : needsInput ? 2 : state == .working ? 1 : 0))
                #expect(previous.filter { $0.window == nil }.allSatisfy { animations($0).isEmpty },
                        "Replaced native decorations must not retain animations")
                previous = decorations
            }
        }
    }

    @Test(arguments: SidebarMode.allCases, [false, true])
    func obsoleteRegistrationDoesNotBecomeAUserFacingRecord(mode: SidebarMode, showEnded: Bool) async throws {
        let f = SidebarTreeFixtures()
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.selectedMode = mode
        preferences.showEnded = showEnded
        let now = Date()
        let old = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Same title",
            workspaceId: f.workspaceA, surfaceId: f.surfaceA, generation: 1, phase: "turn-failed", availability: "idle",
            copilotSessionId: f.otherSessionID, executionMode: .interactive,
            createdAt: now.addingTimeInterval(-172_800), updatedAt: now.addingTimeInterval(-172_800)
        )
        let goneChild = SidebarOrchestrationNode(
            id: UUID(), runId: old.runId, parentId: old.id, role: "worker", label: "Absent child surface",
            workspaceId: f.workspaceA, surfaceId: UUID(), generation: 1, phase: "turn-running", availability: "busy",
            copilotSessionId: UUID(), executionMode: .interactive, createdAt: old.createdAt, updatedAt: old.updatedAt
        )
        let goneGrandchild = SidebarOrchestrationNode(
            id: UUID(), runId: old.runId, parentId: goneChild.id, role: "worker", label: "Absent grandchild surface",
            workspaceId: f.workspaceA, surfaceId: UUID(), generation: 1, phase: "turn-running", availability: "busy",
            copilotSessionId: UUID(), executionMode: .interactive, createdAt: old.createdAt, updatedAt: old.updatedAt
        )
        let raw = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: old.updatedAt, complete: true, omittedCount: 0, nodes: [old, goneChild, goneGrandchild]
        )
        try SidebarOrchestrationReader.validate(raw, now: now)
        let current = CopilotSessionObservation(
            sessionID: f.sessionID, surfaceID: f.surfaceA, launchWorkspaceID: f.workspaceA,
            liveness: .alive, state: .working, model: nil,
            children: [.init(id: "needed", parentID: nil, kind: .subagent, name: "Current child",
                             state: .blocked, model: nil, attention: [
                                .init(kind: .permission, evidence: .init(source: "unsupported", eventID: UUID()), occurredAt: now)
                             ])], observedAt: now
        )
        let snapshots = SidebarMotionSnapshots(f.snapshot(sessions: [
            f.session(id: f.otherSessionID, liveness: .dead, state: .unknown, now: now), current
        ], issues: [.ambiguousTurn], complete: false, now: now))
        let polling = SidebarCopilotPolling(read: neutralRead { _ in await snapshots.read() },
                                           pause: { try await Task.sleep(for: .milliseconds(10)) })
        let orchestration = SidebarOrchestrationPolling(read: { raw }, pause: { try await Task.sleep(for: .seconds(60)) })
        let model = SidebarConnectionModel(copilot: polling, orchestration: orchestration)
        let hierarchy = HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true, workspaceMetadataAvailable: true,
            surfaceMetadataAvailable: true, workspacePathsAvailable: true,
            workspaces: [try #require(f.hierarchy().workspaces.first)], windowID: f.windowID
        )
        model.replaceHierarchy(with: hierarchy)
        model.showConnected(workspaceCount: 1, surfaceCount: 1)
        let topology = SidebarTopology(hierarchy)
        polling.update(topology: topology, connected: true)
        orchestration.update(topology: topology, connected: true)
        model.navigation.update(topology: topology, connected: true, workspaceAllowed: true, surfaceAllowed: true,
                                perform: { _ in Issue.record("Visibility must not navigate or control a session") })
        model.setVisible(true)
        defer { model.setVisible(false) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 800),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences).background(Color.white))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        func views(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views($0) } }
        await sidebarEventually { polling.tree.sessions.count == 2 && orchestration.snapshot.nodes.count == 1 }
        #expect(orchestration.snapshot.nodes == [old], "Existing topology/ancestor projection excludes absent child surfaces")
        #expect(raw.nodes == [old, goneChild, goneGrandchild], "No stored node or lifetime was changed")
        let originalObservation = try #require(polling.tree.sessions.first { $0.id == f.otherSessionID })
        #expect(originalObservation.liveness == .dead && originalObservation.state == .unknown && originalObservation.nodes.isEmpty)
        #expect(SidebarCopilotTree.isFresh(originalObservation.observedAt, now: Date()))
        let currentLabel = mode == .hierarchy ? "Focus Terminal Same title" : "Focus Copilot session 10000000"
        await sidebarEventually {
            hosting.layoutSubtreeIfNeeded()
            return views(hosting).contains { $0.accessibilityLabel() == currentLabel }
        }
        let rows = views(hosting).compactMap { $0 as? SidebarTitleNativeButton }
        #expect(rows.filter { $0.accessibilityLabel() == currentLabel }.count == 1)
        #expect(!rows.contains { $0.accessibilityLabel()?.hasPrefix("Inspect ") == true },
                "The unneeded old registration must not be exposed as a record or context")
        let visible = SidebarVisibleWork(tree: polling.tree, managed: [old], history: preferences.history, showEnded: showEnded)
        #expect(visible.managed.isEmpty && visible.hiddenSurfaces.isEmpty)
        #expect(visible.tree.sessions == polling.tree.sessions.filter { $0.id == f.sessionID })
        #expect(visible.tree.sessions.first?.nodes.first?.name == "Current child")
        #expect(visible.tree.issues == [.ambiguousTurn] && visible.tree.availability == .partial)
        let summary = SidebarPresentation.workspaceSummary(
            surfaces: [], sessions: visible.tree.sessions, managed: visible.managed,
            orchestrationAvailability: orchestration.availability, countsComplete: false, now: Date(), observations: visible.tree
        )
        #expect(summary.agentCount == 1)
        #expect(orchestration.snapshot.nodes == [old] && polling.tree.sessions.count == 2)
        #expect(preferences.history == .init() && preferences.attention.acknowledged.isEmpty && model.navigation.status == .idle)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("liveonly-\(mode.rawValue)-ended\(showEnded).png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination)
        let text = try SidebarRenderingEvidence.recognizedLines(in: destination).joined(separator: " ")
        #expect(text.contains("Same title") && !text.contains("Retained records") && !text.contains("Work context"))
        print("Live-only valid gen1/interactive/turn-failed \(mode.rawValue)/ended\(showEnded): rawManaged=\(raw.nodes.count), projectedManaged=\(orchestration.snapshot.nodes.count), visibleManaged=\(visible.managed.count), observed=\(visible.tree.sessions.count), entries=\(summary.agentCount)")
    }

    /// A born-managed root ended with `/exit` and its run was archived; the same tab then resumed
    /// Copilot unmanaged. Only that tab's live session has a row. A projection that still lists the
    /// ended root (archive not yet projected) must not leave an extra "Copilot session" row either.
    @Test(arguments: [(archived: true, sameSession: true), (true, false), (false, false)], [false, true])
    func archivedBornRootLeavesOnlyTheResumedSessionRow(
        _ run: (archived: Bool, sameSession: Bool), showEnded: Bool
    ) async throws {
        let archived = run.archived
        let f = SidebarTreeFixtures()
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.selectedMode = .hierarchy
        preferences.showEnded = showEnded
        let now = Date()
        var born = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Copilot session",
            workspaceId: f.workspaceA, surfaceId: f.surfaceA, generation: 1, phase: "process-disappeared",
            availability: "unavailable", copilotSessionId: f.otherSessionID, executionMode: .interactive,
            createdAt: now.addingTimeInterval(-600), updatedAt: now.addingTimeInterval(-60)
        )
        born.enrollment = "born"
        let raw = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: archived ? [] : [born]
        )
        try SidebarOrchestrationReader.validate(raw, now: now)
        let resumedID = run.sameSession ? f.otherSessionID : f.sessionID
        let observed = run.sameSession ? [f.session(id: resumedID, state: .working, now: now)] : [
            f.session(id: f.otherSessionID, liveness: .dead, state: .unknown, now: now),
            f.session(id: resumedID, state: .working, now: now)
        ]
        let snapshots = SidebarMotionSnapshots(f.snapshot(sessions: observed, now: now))
        let polling = SidebarCopilotPolling(read: neutralRead { _ in await snapshots.read() },
                                           pause: { try await Task.sleep(for: .milliseconds(10)) })
        let orchestration = SidebarOrchestrationPolling(read: { raw }, pause: { try await Task.sleep(for: .seconds(60)) })
        let model = SidebarConnectionModel(copilot: polling, orchestration: orchestration)
        let hierarchy = HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true, workspaceMetadataAvailable: true,
            surfaceMetadataAvailable: true, workspacePathsAvailable: true,
            workspaces: [try #require(f.hierarchy().workspaces.first)], windowID: f.windowID
        )
        model.replaceHierarchy(with: hierarchy)
        model.showConnected(workspaceCount: 1, surfaceCount: 1)
        let topology = SidebarTopology(hierarchy)
        polling.update(topology: topology, connected: true)
        orchestration.update(topology: topology, connected: true)
        var navigationCalls: [SidebarNavigationTarget] = []
        model.navigation.update(topology: topology, connected: true, workspaceAllowed: true, surfaceAllowed: true,
                                perform: { navigationCalls.append($0) })
        model.setVisible(true)
        defer { model.setVisible(false) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences).background(Color.white))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        await sidebarEventually {
            polling.tree.sessions.count == observed.count && orchestration.snapshot.nodes.count == raw.nodes.count
        }
        func views(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views($0) } }
        let liveLabel = "Focus Terminal Same title"
        await sidebarEventually {
            hosting.layoutSubtreeIfNeeded()
            return views(hosting).contains { $0.accessibilityLabel() == liveLabel }
        }
        let rows = views(hosting).compactMap { $0 as? SidebarTitleNativeButton }
            .filter { $0.localFocusID != "taskboard" && $0.accessibilityLabel()?.hasPrefix("Focus workspace ") != true }
        let labels = rows.map { $0.accessibilityLabel() ?? "" }
        let visible = SidebarVisibleWork(tree: polling.tree, managed: raw.nodes, history: preferences.history,
                                         showEnded: showEnded)
        #expect(visible.managed.isEmpty)
        #expect(!labels.contains { $0.hasPrefix("Inspect ") || $0 == "Focus Copilot session" })
        if showEnded && observed.count > 1 {
            // Show ended agents lists the ended session inside its own tab, as a normal focusable row.
            #expect(labels.first == liveLabel && labels.dropFirst().allSatisfy { $0.hasPrefix("Focus Copilot session ") },
                    "\(labels)")
        } else {
            #expect(labels == [liveLabel], "Only the tab's live session has a row: \(labels)")
            #expect(visible.tree.sessions.map(\.id) == [resumedID])
        }
        let row = try #require(rows.first)
        row.activate()
        await sidebarEventually { model.navigation.status == .selected }
        #expect(navigationCalls == [.surface(workspaceID: f.workspaceA, surfaceID: f.surfaceA)])
    }

    @Test(arguments: [(false, true, false, false), (false, true, true, false),
                      (true, true, false, false), (true, false, false, false),
                      (true, true, true, false), (true, false, true, false),
                      (false, true, false, true)], [SidebarMode.hierarchy])
    func replacedManagedRunLeavesNoRowAndKeepsItsLiveChild(
        _ scenario: (showEnded: Bool, expanded: Bool, protectedObservation: Bool, delayedIdle: Bool),
        mode: SidebarMode
    ) async throws {
        let f = SidebarTreeFixtures()
        let preferenceFixture = try SidebarPreferenceFixture()
        defer { preferenceFixture.cleanup() }
        let preferences = preferenceFixture.preferences()
        preferences.selectedMode = mode
        let currentLabel = mode == .hierarchy ? "Focus Terminal New observed session" : "Focus Copilot session 10000000"
        let now = Date()
        let oldDate = now.addingTimeInterval(-172_800)
        let childSessionID = UUID(), otherSurfaceID = UUID(), otherSessionID = UUID()
        let old = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "New observed session",
            workspaceId: f.workspaceA, surfaceId: f.surfaceA, generation: 1,
            phase: "turn-failed", availability: "idle", copilotSessionId: f.otherSessionID,
            executionMode: .interactive, createdAt: oldDate, updatedAt: oldDate
        )
        let child = SidebarOrchestrationNode(
            id: UUID(), runId: old.runId, parentId: old.id, role: "worker", label: "Protected descendant",
            workspaceId: f.workspaceA, surfaceId: f.surfaceB, generation: 1,
            phase: "turn-running", availability: "busy", copilotSessionId: childSessionID,
            executionMode: .interactive, createdAt: oldDate, updatedAt: now
        )
        let otherRoot = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Other current root",
            workspaceId: f.workspaceA, surfaceId: otherSurfaceID, generation: 1,
            phase: "registered", availability: "active", copilotSessionId: otherSessionID,
            executionMode: .interactive, createdAt: now, updatedAt: now
        )
        let currentNotice = AgentAttention(
            kind: .turnFinished, evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: now
        )
        func currentObservation(_ state: CopilotWorkState) -> CopilotSessionObservation {
            .init(sessionID: f.sessionID, surfaceID: f.surfaceA, launchWorkspaceID: f.workspaceA,
                  liveness: .alive, state: state, model: nil, children: [], observedAt: now, attention: [currentNotice])
        }
        let childObservation = CopilotSessionObservation(
            sessionID: childSessionID, surfaceID: f.surfaceB, launchWorkspaceID: f.workspaceA,
            liveness: .alive, state: .blocked, model: nil, children: [], observedAt: now,
            attention: [.init(kind: .permission, evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: now)]
        )
        let otherObservation = f.session(id: otherSessionID, surface: otherSurfaceID, state: .idle, now: now)
        let oldObservation = CopilotSessionObservation(
            sessionID: f.otherSessionID, surfaceID: f.surfaceA, launchWorkspaceID: f.workspaceA,
            liveness: .dead, state: .unknown, model: nil,
            children: scenario.protectedObservation ? [
                .init(id: "protected-observed", parentID: nil, kind: .subagent, name: "Protected observed child",
                      state: .blocked, model: nil)
            ] : [], observedAt: now,
            attention: scenario.protectedObservation ? [
                .init(kind: .answer, evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: now)
            ] : []
        )
        let clock = SidebarMotionClock()
        let snapshots = SidebarMotionSnapshots(f.snapshot(sessions: [
            oldObservation, currentObservation(.working), childObservation, otherObservation
        ], now: now), clock: clock)
        if scenario.delayedIdle {
            await snapshots.replace(f.snapshot(sessions: [
                f.session(id: f.otherSessionID, state: .idle, now: now), childObservation, otherObservation
            ], now: now))
        }
        let poller = SidebarCopilotPolling(read: neutralRead { _ in await snapshots.read() },
                                          pause: { try await Task.sleep(for: .milliseconds(10)) },
                                          now: { clock.now })
        let orchestration = SidebarOrchestrationPolling(read: {
            .init(version: 1, generatedAt: oldDate, complete: true, omittedCount: 0, nodes: [old, child, otherRoot])
        }, pause: { try await Task.sleep(for: .seconds(60)) })
        let model = SidebarConnectionModel(copilot: poller, orchestration: orchestration)
        let hierarchy = HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true, workspaceMetadataAvailable: true,
            surfaceMetadataAvailable: true, workspacePathsAvailable: false,
            workspaces: [.init(id: f.workspaceA, title: .available("Synthetic"), detail: .available(nil),
                              isSelected: .available(true), isPinned: .available(false), unreadCount: .available(0),
                              rootPath: .unavailable, projectRootPath: .unavailable,
                              surfaces: .available([f.surfaceA, f.surfaceB, otherSurfaceID].map {
                                  .init(id: $0, title: "New observed session", kind: .terminal, isFocused: $0 == f.surfaceA,
                                        isPinned: false, unreadCount: 0, workingDirectory: .unavailable)
                              }))], windowID: f.windowID
        )
        model.showConnected(workspaceCount: 1, surfaceCount: 3)
        model.replaceHierarchy(with: hierarchy)
        var navigationCalls: [SidebarNavigationTarget] = []
        model.navigation.update(topology: SidebarTopology(hierarchy), connected: true,
                                workspaceAllowed: true, surfaceAllowed: true,
                                perform: { navigationCalls.append($0) })
        model.setVisible(true)
        defer { model.setVisible(false) }
        preferences.showEnded = scenario.showEnded
        preferences.setExpanded(true, for: .managed(old.id))
        preferences.setExpanded(scenario.expanded, for: .surface(f.surfaceA))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: mode == .hierarchy ? 700 : 1100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences, actionNow: { clock.now })
            .environment(\.sidebarPresentationNow, { clock.now }))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        await sidebarEventually {
            poller.tree.sessions.count == (scenario.delayedIdle ? 3 : 4) && orchestration.snapshot.nodes.count == 3
        }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        var capturedPrimary: (() -> Void)?
        var capturedFocus: (SidebarRowMenuPresenter, NSMenuItem)?
        if scenario.delayedIdle {
            await sidebarEventually {
                hosting.layoutSubtreeIfNeeded()
                return descendants(hosting).contains { $0.accessibilityLabel() == "Focus New observed session" }
            }
            let previousRow = try #require(descendants(hosting).compactMap { $0 as? SidebarTitleNativeButton }
                .first { $0.accessibilityLabel() == "Focus New observed session" })
            capturedPrimary = previousRow.activate
            var menu: NSMenu?
            for presenter in descendants(hosting).compactMap({ ($0 as? SidebarRowMenuAnchorView)?.presenter }) {
                presenter.present = { captured, _, _ in menu = captured }
            }
            let showActions = try #require(previousRow.showActions)
            showActions()
            let item = try #require(menu?.items.flatMap { $0.submenu?.items ?? [] }.first { $0.title == "Focus surface" })
            capturedFocus = (try #require(item.target as? SidebarRowMenuPresenter), item)
            await snapshots.replace(f.snapshot(sessions: [
                oldObservation, currentObservation(.working), childObservation, otherObservation
            ], now: now))
            await sidebarEventually { poller.tree.sessions.count == 4 }
        }
        let history = preferences.history
        for state: CopilotWorkState in [.working, .idle] {
            if state == .idle {
                if scenario.delayedIdle { clock.advance(SidebarCopilotTree.maximumAge + 0.1) }
                await snapshots.replace(f.snapshot(sessions: [
                    oldObservation, currentObservation(state), childObservation, otherObservation
                ], now: now))
                await sidebarEventually { poller.tree.sessions.first { $0.id == f.sessionID }?.state == .idle }
            }
            await sidebarEventually {
                hosting.layoutSubtreeIfNeeded()
                return descendants(hosting).compactMap { $0 as? SidebarTitleNativeButton }.contains {
                    $0.accessibilityLabel() == currentLabel
                        && $0.toolTip?.contains(state == .working ? "Working" : "Idle") == true
                }
            }
            let rows = descendants(hosting).compactMap { $0 as? SidebarTitleNativeButton }
            let current = rows.filter { $0.accessibilityLabel() == currentLabel }
            let observedRow = try #require(current.first)
            #expect(current.count == 1)
            #expect(!rows.contains { $0.accessibilityLabel() == "Focus New observed session" }, "The replaced run leaves no row")
            #expect(!rows.contains { $0.accessibilityLabel()?.hasPrefix("Inspect ") == true })
            let actions = descendants(hosting).compactMap { ($0 as? SidebarRowMenuAnchorView)?.presenter }
                .flatMap(\.groups).flatMap(\.actions)
            #expect(!actions.contains { $0.title == "Focus original session" })
            capturedPrimary?()
            if let (presenter, item) = capturedFocus {
                #expect(item.isEnabled, "Exercise a menu captured before the surface was reused")
                presenter.invoke(item)
            }
            #expect(model.navigation.status == .idle && navigationCalls.isEmpty,
                    "An action captured before the run was replaced does not reach the new session")
            #expect(poller.tree.sessions.first { $0.id == f.sessionID }?.attention == [currentNotice])
            #expect(!rows.contains { $0.accessibilityLabel() == "Focus Copilot session 20000000" },
                    "History must not duplicate the exact managed identity")
            #expect(rows.contains { $0.accessibilityLabel() == "Focus Protected descendant" },
                    "A live child of the replaced run stays as a normal row")
            #expect(rows.contains { $0.accessibilityLabel() == "Focus Other current root" })
            if scenario.protectedObservation {
                let childEvidence = try #require(oldObservation.children.first)
                #expect(childEvidence.id == "protected-observed" && childEvidence.state == .blocked)
                #expect(childEvidence.name == "Protected observed child")
                #expect(childEvidence.kind == .subagent && childEvidence.attention?.isEmpty != false)
                let neutral = CopilotSnapshotAdapter.child(
                    childEvidence, session: .init(providerID: "copilot", sessionID: f.otherSessionID.uuidString)
                )
                #expect(neutral.id.rawValue == childEvidence.id && neutral.workState == .blocked)
                #expect(neutral.title.knownValue == "Protected observed child")
                let original = try #require(poller.tree.sessions.first { $0.id == f.otherSessionID })
                #expect(original.liveness == .dead && original.internalTaskCountsIncomplete)
                #expect(!original.nodes.contains { $0.id == childEvidence.id },
                        "Dead-owner blocked work without child attention becomes unknown and is state-filtered")
                #expect(original.attention.contains { $0.kind == .answer }, "The actual owner request still protects its context")
            }
            let statePixels: Int
            if mode == .hierarchy { statePixels = try greenPixels(in: observedRow) }
            else {
                let frame = hosting.convert(observedRow.bounds, from: observedRow)
                statePixels = try greenPixels(in: hosting, rect: NSRect(x: 0, y: frame.maxY + 4, width: 340, height: 14))
            }
            #expect((statePixels > 0) == (state == .working),
                    "The primary production row reflects its own working-to-idle transition, even when collapsed")
            #expect(observedRow.toolTip?.contains(state == .working ? "Working" : "Idle") == true)
            if state == .idle && scenario.delayedIdle {
                let observation = try #require(poller.tree.sessions.first { $0.id == f.sessionID })
                #expect(observation.observedAt.timeIntervalSince(now) > SidebarCopilotTree.maximumAge,
                        "The delayed transition must use a new observation, not the aged fixture timestamp")
            }
            let visible = SidebarVisibleWork(tree: poller.tree, managed: [old, child, otherRoot],
                                             history: preferences.history, showEnded: preferences.showEnded, now: clock.now)
            let summary = SidebarPresentation.workspaceSummary(
                surfaces: [], sessions: visible.tree.sessions, managed: visible.managed,
                orchestrationAvailability: orchestration.availability, countsComplete: true,
                now: clock.now, observations: visible.tree
            )
            print("Retained rows mode=\(mode.rawValue) scenario=\(scenario) state=\(state.rawValue) agents=\(summary.agentCount) "
                  + "states=\(summary.states.map { "\($0.title):\($0.count)" }) "
                  + "primaryGreenPixels=\(statePixels) "
                  + "oldObservedRows=\(rows.filter { $0.accessibilityLabel() == "Focus Copilot session 20000000" }.count)")
            #expect(summary.agentCount == 3, "Internal tasks do not inflate real agent entries")
            #expect(visible.managed == [child, otherRoot])
            #expect(summary.states.first { $0.title == (state == .working ? "Working" : "Idle") }?.count == (state == .idle ? 2 : 1))
            #expect(orchestration.snapshot.nodes == [old, child, otherRoot], "Ownership, ancestry and generations are unchanged")
            #expect(!window.isVisible && model.navigation.status == .idle)
            #expect(preferences.attention.acknowledged.isEmpty && preferences.history == history)
            if scenario.showEnded && scenario.expanded && scenario.protectedObservation {
                let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent(".build/layout-validation/offscreen")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let context = try #require(CGContext(
                    data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                let bounds = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
                let appearance = try #require(window.appearance)
                appearance.performAsCurrentDrawingAppearance {
                    context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                    context.fill(bounds)
                }
                context.draw(try #require(bitmap.cgImage), in: bounds)
                let opaque = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
                try #require(opaque.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("retained118-\(mode.rawValue)-\(state.rawValue).png"))
            }
        }
        let currentChild = try #require(descendants(hosting).compactMap { $0 as? SidebarTitleNativeButton }
            .first { $0.accessibilityLabel() == "Focus Protected descendant" })
        currentChild.activate()
        await sidebarEventually { model.navigation.status == .selected }
        #expect(navigationCalls == [.surface(workspaceID: f.workspaceA, surfaceID: f.surfaceB)])
        #expect(poller.tree.sessions.first { $0.id == f.sessionID }?.attention == [currentNotice])
    }

    /// A fixed base captured once plus an offset. Reading `now` never moves time; it moves only when a
    /// test advances it or the synthetic source publishes a new observation (strictly newer, as polling
    /// requires after an invalidation).
    private final class SidebarMotionClock: @unchecked Sendable {
        private let lock = NSLock()
        private let base = Date()
        private var offset: TimeInterval = 0
        var now: Date { lock.withLock { base.addingTimeInterval(offset) } }
        func advance(_ seconds: TimeInterval) { lock.withLock { offset += seconds } }
        func nextObservationTime() -> Date {
            lock.withLock {
                offset += 0.001
                return base.addingTimeInterval(offset)
            }
        }
    }

    private actor SidebarMotionSnapshots {
        private var snapshot: CopilotSnapshot
        private let clock: SidebarMotionClock?
        init(_ snapshot: CopilotSnapshot, clock: SidebarMotionClock? = nil) {
            self.snapshot = snapshot
            self.clock = clock
        }
        func read() -> CopilotSnapshot {
            // Each synthetic read is a new observation, stamped by the injected clock or wall time.
            let now = clock?.nextObservationTime() ?? Date()
            return .init(generatedAt: now, sessions: snapshot.sessions.map { session in
                var observation = CopilotSessionObservation(
                    sessionID: session.sessionID, surfaceID: session.surfaceID,
                    launchWorkspaceID: session.launchWorkspaceID, liveness: session.liveness,
                    state: session.state, model: session.model, children: session.children, observedAt: now,
                    attention: session.attention, activity: session.activity
                )
                observation.iconId = session.iconId
                observation.iconColor = session.iconColor
                return observation
            }, issues: snapshot.issues, isComplete: snapshot.isComplete)
        }
        func replace(_ snapshot: CopilotSnapshot) { self.snapshot = snapshot }
    }

    private func greenPixels(in row: NSView, rect: NSRect? = nil) throws -> Int {
        row.layoutSubtreeIfNeeded()
        let bounds = rect ?? row.bounds
        let bitmap = try #require(row.bitmapImageRepForCachingDisplay(in: bounds))
        row.cacheDisplay(in: bounds, to: bitmap)
        var green = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.greenComponent > color.redComponent + 0.15
                    && color.greenComponent > color.blueComponent + 0.15 { green += 1 }
            }
        }
        return green
    }

    @Test func ringMakesOneLinearRevolutionAndReducedMotionHasNoPhaseChange() throws {
        #expect(SidebarPresentation.statusDescription(SidebarPresentation.state(.blocked), needsInput: true) == "Needs input. Blocked")
        #expect(SidebarPresentation.statusDescription(SidebarPresentation.state(.unknown)) == "Unknown")
        for (time, angle) in [(0.0, 0.0), (0.25, 90), (0.5, 180), (0.75, 270), (1, 0), (1.25, 90)] {
            let date = Date(timeIntervalSinceReferenceDate: time)
            #expect(SidebarPresentation.workingRotation(at: date, reduceMotion: false) == angle)
            #expect(SidebarPresentation.workingRotation(at: date, reduceMotion: true) == 0)
        }
    }

    @Test func unchangedNativeUpdatesPreserveAttachedAnimationPhase() throws {
        let stores = SidebarStoreFixture()
        defer { stores.cleanup() }
        let petID = try installMotionPet(in: stores)
        let frames = try (0..<SidebarPetState.idle.frameCount).map {
            try #require(stores.pets.frame(petID: petID, session: nil, state: .idle, index: $0))
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 160, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.frame)
        root.wantsLayer = true
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        let pet = SidebarPetAnimationView(frame: CGRect(x: 0, y: 0, width: 14, height: 16))
        root.addSubview(pet)
        pet.setFrames(frames)
        let status = SidebarStatusAnimationView(frame: CGRect(x: 20, y: 0, width: 12, height: 14))
        root.addSubview(status)
        for kind in [SidebarStatusAnimationView.Kind.working, .question, .background] {
            status.configure(kind)
            for view in [pet, status] {
                view.layoutSubtreeIfNeeded()
                let backing = try #require(view.layer)
                #expect(view.superview === root && view.window === window)
                let animated = (backing.sublayers ?? []).filter { !($0.animationKeys() ?? []).isEmpty }
                #expect(!animated.isEmpty)
                for layer in animated {
                    #expect(layer.superlayer === backing && !layer.isHidden && layer.speed == 1 && layer.opacity > 0)
                    for key in layer.animationKeys() ?? [] {
                        let animation = try #require(layer.animation(forKey: key)?.copy() as? CAAnimation)
                        animation.beginTime = 10
                        animation.timeOffset = 0.25
                        layer.add(animation, forKey: key)
                        for _ in 0..<3 {
                            status.configure(kind)
                            pet.setFrames(frames)
                            view.needsLayout = true
                            view.layoutSubtreeIfNeeded()
                        }
                        let retained = try #require(layer.animation(forKey: key))
                        #expect(retained.beginTime == 10 && retained.timeOffset == 0.25,
                                "Unchanged updates/layout must not restart or replace a running animation")
                        #expect(retained.repeatCount == .infinity && retained.speed == 1)
                    }
                }
            }
        }
    }

    @Test(.enabled(if: SidebarAppKitTestScope.localAcceptanceEnabled))
    func nativeMotionAndStaticNegativeControlsStayInsideTheStatusLane() async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/presentation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stores = SidebarStoreFixture()
        defer { stores.cleanup() }
        let petID = try installMotionPet(in: stores)
        for (name, reduceMotion, needsInput, isPet) in [
            ("working", false, false, false), ("reduced-motion", true, false, false),
            ("needs-input", false, true, false), ("needs-input-reduced-motion", true, true, false),
            ("idle-pet", false, false, true), ("idle-pet-reduced-motion", true, false, true)
        ] {
            let host = NSHostingView(rootView:
                HStack {
                    if isPet {
                        SidebarPetView(store: stores.pets, petID: petID, state: .idle, width: 14)
                    } else {
                        SidebarStateBadge(visual: SidebarPresentation.state(.working), needsInput: needsInput)
                    }
                    Text("Synthetic status").font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 5)
                .environment(\._accessibilityReduceMotion, reduceMotion)
                .background(SidebarActivityBackground(visual: SidebarPresentation.state(.working)))
                .background(Color.white)
                .frame(width: 280, height: 40)
            )
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 40),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(40))
            let firstValues = try presentationValues(in: host)
            let first = try capture(window, to: folder.appendingPathComponent("polish-\(name)-frame0.png"))
            try await Task.sleep(for: .milliseconds(250))
            let secondValues = try presentationValues(in: host)
            let second = try capture(window, to: folder.appendingPathComponent("polish-\(name)-frame1.png"))
            #expect(window.isVisible)
            let left = differences(first, second, columns: 0..<40)
            let rest = differences(first, second, columns: 40..<first.pixelsWide)
            #expect(rest == 0, "No row shimmer or text motion: \(name)")
            if !reduceMotion {
                #expect(left > 0, "The native status badge animates inside its lane while hosted: \(name)")
                #expect(!firstValues.isEmpty && firstValues != secondValues,
                        "Actual windowed presentation properties must advance: \(name)")
            } else {
                #expect(left == 0, "Static negative control: \(name)")
                #expect(firstValues.isEmpty && secondValues.isEmpty)
            }
            print("Native presentation motion \(name): changedStatusPixels=\(left), changedOtherPixels=\(rest), "
                  + "values=\(firstValues) -> \(secondValues)")
        }
    }

    private func installMotionPet(in stores: SidebarStoreFixture) throws -> String {
        let context = try #require(CGContext(
            data: nil, width: 768, height: 936, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for column in 0..<8 {
            context.setFillColor(NSColor(srgbRed: CGFloat(column + 1) / 8, green: 0.2, blue: 0.5, alpha: 1).cgColor)
            context.fill(CGRect(x: column * 96, y: 0, width: 96, height: 936))
        }
        let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        let file = stores.root.appendingPathComponent("synthetic-motion-pet.png")
        try FileManager.default.createDirectory(at: stores.root, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
        return try #require(stores.pets.upload(from: file))
    }

    private func presentationValues(in view: NSView) throws -> [Double] {
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        var values: [Double] = []
        for native in descendants(view) where native is SidebarStatusAnimationView || native is SidebarPetAnimationView {
            #expect(native.window === view.window && !native.isHiddenOrHasHiddenAncestor)
            var ancestor = native.layer
            while let current = ancestor, current !== view.layer { ancestor = current.superlayer }
            try #require(ancestor != nil, "Native animations must be attached to the window's rendered layer tree")
            for layer in native.layer?.sublayers ?? [] {
                for key in layer.animationKeys() ?? [] {
                    let animation = try #require(layer.animation(forKey: key) as? CAPropertyAnimation)
                    let presentation = try #require(layer.presentation())
                    switch animation.keyPath {
                    case "transform.rotation.z": values.append(presentation.transform.m11)
                    case "shadowOpacity": values.append(Double(presentation.shadowOpacity))
                    case "contents":
                        let contents = try #require(presentation.contents)
                        let sequence = try #require(animation as? CAKeyframeAnimation)
                        let index = try #require(sequence.values?.firstIndex {
                            ($0 as AnyObject) === (contents as AnyObject)
                        }, "The displayed pet frame must belong to its idle sequence")
                        values.append(Double(index))
                    default: Issue.record("Unexpected native animation path: \(animation.keyPath ?? "nil")")
                    }
                }
            }
        }
        return values
    }

    private func capture(_ window: NSWindow, to file: URL) throws -> NSBitmapImageRep {
        let view = try #require(window.contentView)
        try #require(window.isVisible && window.occlusionState.contains(.visible) && view.window === window,
                     "Animation acceptance needs a real ordered window, not an offscreen cache")
        try #require(view.bounds == NSRect(x: 0, y: 0, width: 280, height: 40),
                     "Both native snapshots must use the same logical viewport, not a transient intrinsic height")
        // cacheDisplay renders model state and cannot observe render-server animations.
        // Only this synthetic window's live presentation tree is rendered, never the desktop.
        let presentation = try #require(view.layer?.presentation())
        let context = try #require(CGContext(
            data: nil, width: 560, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        presentation.render(in: context)
        let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        try #require(bitmap.pixelsWide == 560 && bitmap.pixelsHigh == 80)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
        return bitmap
    }

    private func differences(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, columns: Range<Int>) -> Int {
        var count = 0
        for y in 0..<a.pixelsHigh {
            for x in columns {
                if a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { count += 1 }
            }
        }
        return count
    }
}
