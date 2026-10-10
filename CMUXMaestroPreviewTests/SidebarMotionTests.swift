import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarMotionTests {
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
        #expect(summary.agentCount == 1 && summary.retainedRecordCount == 0)
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

    @Test(arguments: [(false, true, false, false), (false, true, true, false),
                      (true, true, false, false), (true, false, false, false),
                      (true, true, true, false), (true, false, true, false),
                      (false, true, false, true)], SidebarMode.allCases)
    func retainedManagedIdentityDoesNotMaskNewWorkingObservation(
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
        let snapshots = SidebarMotionSnapshots(f.snapshot(sessions: [
            oldObservation, currentObservation(.working), childObservation, otherObservation
        ], now: now))
        if scenario.delayedIdle {
            await snapshots.replace(f.snapshot(sessions: [
                f.session(id: f.otherSessionID, state: .idle, now: now), childObservation, otherObservation
            ], now: now))
        }
        let poller = SidebarCopilotPolling(read: neutralRead { _ in await snapshots.read() },
                                          pause: { try await Task.sleep(for: .milliseconds(10)) })
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
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences))
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
                if scenario.delayedIdle {
                    try await Task.sleep(for: .seconds(SidebarCopilotTree.maximumAge + 0.1))
                }
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
            let retained = rows.filter { $0.accessibilityLabel() == "Inspect work context New observed session" }
            let retainedRow = try #require(retained.first)
            let current = rows.filter { $0.accessibilityLabel() == currentLabel }
            let observedRow = try #require(current.first)
            #expect(retained.count == 1 && current.count == 1)
            #expect(retainedRow.toolTip?.contains("Work context") == true)
            #expect(!rows.contains { $0.accessibilityLabel() == "Focus New observed session" })
            #expect(hosting.convert(retainedRow.bounds, from: retainedRow).minY
                    > hosting.convert(observedRow.bounds, from: observedRow).minY)
            let retainedActions = descendants(hosting).compactMap { ($0 as? SidebarRowMenuAnchorView)?.presenter }
                .flatMap(\.groups).flatMap(\.actions).filter { $0.title == "Focus original session" }
            let retainedActionCount = 1
            #expect(retainedActions.count == retainedActionCount && retainedActions.allSatisfy { $0.unavailable != nil })
            retainedRow.activate()
            capturedPrimary?()
            if let (presenter, item) = capturedFocus {
                #expect(item.isEnabled, "Exercise a menu captured before the surface was reused")
                presenter.invoke(item)
            }
            #expect(model.navigation.status == .idle && navigationCalls.isEmpty, "Retained record primary action only inspects")
            #expect(poller.tree.sessions.first { $0.id == f.sessionID }?.attention == [currentNotice])
            #expect(!rows.contains { $0.accessibilityLabel() == "Focus Copilot session 20000000" },
                    "History must not duplicate the exact managed identity")
            #expect(rows.contains { $0.accessibilityLabel() == "Focus Protected descendant" })
            #expect(rows.contains { $0.accessibilityLabel() == "Focus Other current root" })
            if mode == .taskboard {
                let independent = try #require(rows.first { $0.accessibilityLabel() == "Focus Other current root" })
                let descendant = try #require(rows.first { $0.accessibilityLabel() == "Focus Protected descendant" })
                #expect(hosting.convert(independent.bounds, from: independent).minY
                        < hosting.convert(retainedRow.bounds, from: retainedRow).minY,
                        "Independent current roots precede retained context")
                #expect(child.parentId == old.id)
                #expect(hosting.convert(descendant.bounds, from: descendant).minY
                        > hosting.convert(retainedRow.bounds, from: retainedRow).minY,
                        "A real child stays beneath its required ancestor, not in a duplicate flat session row")
            }
            #expect(try leadingInk(of: retainedRow, in: hosting) == 0, "Retained record has no current focus stripe")
            #expect(try leadingInk(of: observedRow, in: hosting) > 0, "Current session keeps its focus stripe")
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
            #expect(try greenPixels(in: retainedRow) == 0, "Never borrow the new session's working state")
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
                                             history: preferences.history, showEnded: preferences.showEnded)
            let summary = SidebarPresentation.workspaceSummary(
                surfaces: [], sessions: visible.tree.sessions, managed: visible.managed,
                orchestrationAvailability: orchestration.availability, countsComplete: true,
                now: Date(), observations: visible.tree
            )
            print("Retained rows mode=\(mode.rawValue) scenario=\(scenario) state=\(state.rawValue) agents=\(summary.agentCount) "
                  + "states=\(summary.states.map { "\($0.title):\($0.count)" }) "
                  + "primaryGreenPixels=\(statePixels) "
                  + "oldObservedRows=\(rows.filter { $0.accessibilityLabel() == "Focus Copilot session 20000000" }.count)")
            #expect(summary.agentCount == 4, "Internal tasks do not inflate real agent entries")
            #expect(summary.retainedRecordCount == 1)
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

    private func leadingInk(of row: NSView, in hosting: NSView) throws -> Int {
        let frame = hosting.convert(row.bounds, from: row)
        let strip = NSRect(x: 0, y: frame.midY - 2, width: 9, height: 4)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: strip))
        hosting.cacheDisplay(in: strip, to: bitmap)
        var count = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                if try #require(bitmap.colorAt(x: x, y: y)).alphaComponent > 0.1 { count += 1 }
            }
        }
        return count
    }

    @Test(arguments: [(2, 340.0, SidebarDensity.compact), (2, 240.0, SidebarDensity.comfortable),
                      (8, 240.0, SidebarDensity.compact), (8, 340.0, SidebarDensity.comfortable)])
    func retainedObservedSubtreeKeepsItsManagedOwnersIndentation(
        _ scenario: (depth: Int, width: Double, density: SidebarDensity)
    ) async throws {
        let f = SidebarTreeFixtures()
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.showEnded = true
        preferences.setDensity(scenario.density)
        let now = Date()
        let oldDate = now.addingTimeInterval(-172_800)
        let runID = UUID()
        var chain: [SidebarOrchestrationNode] = []
        for depth in 0...scenario.depth {
            chain.append(.init(
                id: UUID(), runId: runID, parentId: chain.last?.id,
                role: depth == 0 ? "coordinator" : "worker", label: "Managed \(depth)",
                workspaceId: f.workspaceA, surfaceId: depth == scenario.depth ? f.surfaceA : UUID(),
                generation: 1, phase: "turn-failed", availability: "idle",
                copilotSessionId: depth == scenario.depth ? f.otherSessionID : UUID(),
                executionMode: .interactive, createdAt: oldDate.addingTimeInterval(Double(depth)), updatedAt: oldDate
            ))
        }
        let owner = try #require(chain.last)
        let root = chain[0]
        let ancestor = chain[1]
        let sibling = SidebarOrchestrationNode(
            id: UUID(), runId: runID, parentId: root.id, role: "worker", label: "Unrelated sibling",
            workspaceId: f.workspaceA, surfaceId: f.surfaceB, generation: 1,
            phase: "turn-failed", availability: "idle", copilotSessionId: UUID(),
            executionMode: .interactive, createdAt: now, updatedAt: oldDate
        )
        let managed = chain + [sibling]
        let oldObservation = CopilotSessionObservation(
            sessionID: f.otherSessionID, surfaceID: f.surfaceA, launchWorkspaceID: f.workspaceA,
            liveness: .dead, state: .unknown, model: nil, children: [
                .init(id: "nested-child", parentID: nil, kind: .skill, name: "Observed child",
                      state: .blocked, model: nil, attention: [
                        .init(kind: .permission, evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: now)
                      ]),
                .init(id: "nested-grandchild", parentID: "nested-child", kind: .skill, name: "Observed grandchild",
                      state: .blocked, model: nil, attention: [
                        .init(kind: .answer, evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: now)
                      ])
            ], observedAt: now
        )
        let snapshots = SidebarMotionSnapshots(f.snapshot(
            sessions: [oldObservation, f.session(state: .working, now: now)], now: now
        ))
        let poller = SidebarCopilotPolling(read: neutralRead { _ in await snapshots.read() },
                                          pause: { try await Task.sleep(for: .milliseconds(10)) })
        let orchestration = SidebarOrchestrationPolling(read: {
            .init(version: 1, generatedAt: oldDate, complete: true, omittedCount: 0, nodes: managed)
        }, pause: { try await Task.sleep(for: .seconds(60)) })
        let model = SidebarConnectionModel(copilot: poller, orchestration: orchestration)
        let hierarchy = HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true, workspaceMetadataAvailable: true,
            surfaceMetadataAvailable: true, workspacePathsAvailable: false,
            workspaces: [.init(
                id: f.workspaceA, title: .available("Synthetic nesting"), detail: .available(nil),
                isSelected: .available(true), isPinned: .available(false), unreadCount: .available(0),
                rootPath: .unavailable, projectRootPath: .unavailable,
                surfaces: .available(managed.map {
                    .init(id: $0.surfaceId, title: "Replacement", kind: .terminal, isFocused: false,
                          isPinned: false, unreadCount: 0, workingDirectory: .unavailable)
                })
            )], windowID: f.windowID
        )
        model.showConnected(workspaceCount: 1, surfaceCount: managed.count)
        model.replaceHierarchy(with: hierarchy)
        model.navigation.update(topology: SidebarTopology(hierarchy), connected: true,
                                workspaceAllowed: true, surfaceAllowed: true,
                                perform: { _ in Issue.record("Nesting must not navigate") })
        model.setVisible(true)
        defer { model.setVisible(false) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: scenario.width, height: 1200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        await sidebarEventually { poller.tree.sessions.count == 2 && orchestration.snapshot.nodes.count == managed.count }
        func titles(_ view: NSView) -> [SidebarTitleNativeButton] {
            view.subviews.flatMap { child in
                (child as? SidebarTitleNativeButton).map { $0.localFocusID == "taskboard" ? [] : [$0] } ?? titles(child)
            }
        }
        for (ancestorExpanded, ownerExpanded) in [(true, true), (true, false), (false, true)] {
            preferences.setExpanded(ancestorExpanded, for: .managed(ancestor.id))
            preferences.setExpanded(ownerExpanded, for: .managed(owner.id))
            await sidebarEventually {
                hosting.layoutSubtreeIfNeeded()
                let rows = titles(hosting)
                return rows.contains {
                    $0.accessibilityLabel() == "Focus Terminal Replacement" && $0.toolTip?.contains("Working") == true
                } && rows.contains { $0.accessibilityLabel() == "Inspect work context Managed \(scenario.depth)" } == ancestorExpanded
                    && rows.filter { $0.accessibilityLabel()?.hasPrefix("Inspect context activity Observed ") == true }.count
                        == (ancestorExpanded && ownerExpanded ? 2 : 0)
            }
            let rows = titles(hosting)
            let rootRow = try #require(rows.first { $0.accessibilityLabel() == "Focus Managed 0" })
            let siblingRow = try #require(rows.first { $0.accessibilityLabel() == "Focus Unrelated sibling" })
            let ownerRow = rows.first { $0.accessibilityLabel() == "Inspect work context Managed \(scenario.depth)" }
            let observedRows = rows.filter { $0.accessibilityLabel()?.hasPrefix("Inspect context activity Observed ") == true }
            let replacement = try #require(rows.first { $0.accessibilityLabel() == "Focus Terminal Replacement" })
            let origin = hosting.convert(rootRow.bounds, from: rootRow).minX
            let step = scenario.density == .compact ? 8.0 : 10.8
            let scale = window.backingScaleFactor
            #expect(Double(hosting.convert(siblingRow.bounds, from: siblingRow).minX) == pixelAligned(origin + step, scale: scale))
            #expect(observedRows.count == (ancestorExpanded && ownerExpanded ? 2 : 0))
            #expect((ownerRow != nil) == ancestorExpanded)
            if ancestorExpanded, let ownerRow {
                let ownerX = hosting.convert(ownerRow.bounds, from: ownerRow).minX
                if ownerExpanded {
                    let child = try #require(observedRows.first { $0.accessibilityLabel()?.contains("Observed child,") == true })
                    let grandchild = try #require(observedRows.first { $0.accessibilityLabel()?.contains("Observed grandchild,") == true })
                    let childFrame = hosting.convert(child.bounds, from: child)
                    let grandchildFrame = hosting.convert(grandchild.bounds, from: grandchild)
                    let densityScale = scenario.density == .compact ? 1.0 : 1.35
                    let cap = min(32, (scenario.width - (scenario.density == .compact ? 10 : 13.5)) * 0.12)
                    let ownerIndent = min((scenario.depth == 2 ? 16.0 : 44.0) * densityScale, cap)
                    let grandchildIndent = min((scenario.depth == 2 ? 24.0 : 48.0) * densityScale, cap)
                    print("R117 nesting \(scenario) scale=\(scale) originX=\(origin) ownerX=\(ownerX) "
                          + "childX=\(childFrame.minX) grandchildX=\(grandchildFrame.minX) "
                          + "expectedOwner=\(pixelAligned(origin + ownerIndent, scale: scale)) "
                          + "expectedChild=\(pixelAligned(origin + step + ownerIndent, scale: scale))")
                    #expect(Double(ownerX) == pixelAligned(origin + ownerIndent, scale: scale))
                    #expect(Double(childFrame.minX) == pixelAligned(origin + step + ownerIndent, scale: scale))
                    #expect(Double(grandchildFrame.minX) == pixelAligned(origin + step + grandchildIndent, scale: scale))
                    #expect(grandchildFrame.minX >= childFrame.minX)
                    let renderedCap = ceil((step + cap) * window.backingScaleFactor) / window.backingScaleFactor
                    #expect(grandchildFrame.minX - origin <= renderedCap,
                            "Combined managed/session depth must be capped once, not accumulated")
                } else {
                    let ownerFrame = hosting.convert(ownerRow.bounds, from: ownerRow)
                    let siblingFrame = hosting.convert(siblingRow.bounds, from: siblingRow)
                    let rowPadding = (scenario.density.rowHeight - ownerFrame.height) / 2
                    let top = ownerFrame.maxY + rowPadding
                    let strip = NSRect(x: 0, y: top, width: scenario.width,
                                       height: siblingFrame.minY - rowPadding - top)
                    try #require(strip.height > 0, "The collapsed retained summary occupies its own row")
                    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: strip))
                    hosting.cacheDisplay(in: strip, to: bitmap)
                    var ink: [Int] = []
                    for x in 0..<bitmap.pixelsWide {
                        for y in 0..<bitmap.pixelsHigh {
                            let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                            if color.alphaComponent > 0.2
                                && max(color.redComponent, color.greenComponent, color.blueComponent) < 0.75 {
                                ink.append(x)
                                break
                            }
                        }
                    }
                    let summaryX = Double(try #require(ink.first)) * strip.width / Double(bitmap.pixelsWide)
                    print("R117 nesting collapsed \(scenario) ownerX=\(ownerX) summaryInkX=\(summaryX)")
                    #expect((ownerX - 28 - 0.5...ownerX - 28 + 4).contains(summaryX),
                            "Collapsed summary ink stays aligned with its owner, allowing glyph inset")
                }
            }
            #expect(rows.allSatisfy {
                let frame = hosting.convert($0.bounds, from: $0)
                return frame.minX >= 0 && frame.maxX <= scenario.width && frame.width >= 80
            })
            #expect(try greenPixels(in: replacement) > 0)
            let summary = SidebarPresentation.workspaceSummary(
                surfaces: [], sessions: poller.tree.sessions, managed: managed,
                orchestrationAvailability: orchestration.availability, countsComplete: true, now: Date(),
                observations: poller.tree
            )
            let attention = SidebarPresentation.workspaceAttention(
                sessions: poller.tree.sessions, managed: managed, availability: orchestration.availability,
                now: Date(), observations: poller.tree
            )
            #expect(summary.agentCount == scenario.depth + 3)
            #expect(attention.needsInput == 2 && attention.questions == 1 && attention.approvals == 1)
            #expect(orchestration.snapshot.nodes == managed && preferences.attention.acknowledged.isEmpty)
            #expect(model.navigation.status == .idle && !window.isVisible)
        }
    }

    @Test(arguments: [(1.0, 85.0, 95.0), (2.0, 84.5, 95.5)])
    func retainedGeometryMatchesIndependentlyAlignedBackingCoordinates(
        _ sample: (scale: Double, ownerX: Double, childX: Double)
    ) {
        #expect(pixelAligned(63 + 21.6, scale: sample.scale) == sample.ownerX)
        #expect(pixelAligned(63 + 21.6 + 10.8, scale: sample.scale) == sample.childX)
        #expect(pixelAligned(63 + 27.18 + 10.8, scale: sample.scale) == 101)
        #expect(pixelAligned(63 + 10.8, scale: sample.scale) != sample.childX,
                "Omitting the managed-owner indentation must still fail on either backing grid")
    }

    private func pixelAligned(_ coordinate: Double, scale: Double) -> Double {
        (coordinate * scale).rounded() / scale
    }

    private actor SidebarMotionSnapshots {
        private var snapshot: CopilotSnapshot
        init(_ snapshot: CopilotSnapshot) { self.snapshot = snapshot }
        func read() -> CopilotSnapshot {
            // Production rows use wall time; each synthetic read is a new observation.
            let now = Date()
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

    @Test func nativeMotionAndStaticNegativeControlsStayInsideTheStatusLane() async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, reduceMotion, needsInput) in [
            ("working", false, false), ("reduced-motion", true, false), ("needs-input", false, true),
            ("needs-input-reduced-motion", true, true)
        ] {
            let host = NSHostingView(rootView:
                HStack {
                    SidebarStateBadge(visual: SidebarPresentation.state(.working), needsInput: needsInput)
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
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            let first = try capture(host, to: folder.appendingPathComponent("polish-\(name)-frame0.png"))
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let second = try capture(host, to: folder.appendingPathComponent("polish-\(name)-frame1.png"))
            #expect(!window.isVisible)
            let left = differences(first, second, columns: 0..<40)
            let rest = differences(first, second, columns: 40..<first.pixelsWide)
            #expect(rest == 0, "No row shimmer or text motion: \(name)")
            if name == "working" || name == "needs-input" {
                #expect(left > 0, "The native status badge animates inside its lane while hosted: \(name)")
            } else {
                #expect(left == 0, "Static negative control: \(name)")
            }
            print("P57 native motion \(name): changedStatusPixels=\(left), changedOtherPixels=\(rest)")
        }
    }

    private func capture(_ view: NSView, to file: URL) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        try #require(view.bounds == NSRect(x: 0, y: 0, width: 280, height: 40),
                     "Both native snapshots must use the same logical viewport, not a transient intrinsic height")
        let before = view.bounds
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 560, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(view.bounds == before && bitmap.size == before.size)
        print("P57 capture \(file.lastPathComponent): before=\(before), after=\(view.bounds), bitmapSize=\(bitmap.size)")
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
