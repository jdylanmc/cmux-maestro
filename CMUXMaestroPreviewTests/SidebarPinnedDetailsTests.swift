import AppKit
import SwiftUI
import Testing
@_spi(CmuxHostTransport) import CmuxExtensionKit

@MainActor
private final class RetainedMenuSource {
    var node: SidebarOrchestrationNode
    var includesNode = true
    let evidence: AgentAttention
    let clock: CopilotReaderTestClock

    init(node: SidebarOrchestrationNode, evidence: AgentAttention, clock: CopilotReaderTestClock) {
        self.node = node
        self.evidence = evidence
        self.clock = clock
    }

    var managed: SidebarOrchestrationSnapshot {
        .init(version: 1, generatedAt: clock.now(), complete: true, omittedCount: 0, nodes: includesNode ? [node] : [])
    }

    var observed: CopilotSnapshot {
        // Each successful fixture read represents new evidence, including after subject replacement.
        clock.advance(by: 0.001)
        let date = clock.now()
        return .init(generatedAt: date, sessions: [
            .init(sessionID: node.copilotSessionId!, surfaceID: node.surfaceId, launchWorkspaceID: node.workspaceId,
                  liveness: .alive, state: .idle, model: "retained-menu-model", children: [], observedAt: date,
                  attention: [evidence])
        ], issues: [], isComplete: true)
    }
}

@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarPinnedDetailsTests {
    @MainActor
    private final class ObservedPlacementSource {
        let sessionID: UUID
        let launchWorkspaceID: UUID
        var surfaceID: UUID
        let notice = UUID()

        init(sessionID: UUID, workspaceID: UUID, surfaceID: UUID) {
            self.sessionID = sessionID
            self.launchWorkspaceID = workspaceID
            self.surfaceID = surfaceID
        }

        var snapshot: CopilotSnapshot {
            let now = Date()
            let attention = AgentAttention(kind: .turnFinished, evidence: .init(source: "copilot.events", eventID: notice), occurredAt: now)
            return .init(generatedAt: now, sessions: [
                .init(sessionID: sessionID, surfaceID: surfaceID, launchWorkspaceID: launchWorkspaceID,
                      liveness: .alive, state: .working, model: nil, children: [
                        .init(id: "moving-child", parentID: nil, kind: .skill, name: "Moving child",
                              state: .working, model: nil, attention: [attention])
                      ], observedAt: now, attention: [attention])
            ], issues: [], isComplete: true)
        }
    }

    private let fixtures = SidebarTreeFixtures()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func hierarchy(
        active: UUID? = nil, kind: HierarchySurfaceKind = .terminal,
        focused: Bool = true, duplicateFocus: Bool = false, duplicateID: Bool = false,
        granted: Bool = true, paths: Bool = true, directory: String? = nil
    ) -> HierarchySnapshot {
        let active = active ?? fixtures.workspaceA
        return .init(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: granted, surfaceMetadataAvailable: granted,
            workspacePathsAvailable: paths,
            workspaces: [fixtures.workspaceA, fixtures.workspaceB].enumerated().map { index, id in
                let surface = HierarchySurface(
                    id: index == 0 || duplicateID ? fixtures.surfaceA : fixtures.surfaceB,
                    title: "Same title", kind: kind, isFocused: focused, isPinned: false, unreadCount: 0,
                    workingDirectory: paths ? .available(directory ?? "/synthetic/worktree-\(index)") : .unavailable
                )
                return .init(
                    id: id, title: .available("Same workspace"), detail: .available(nil),
                    isSelected: .available(id == active), isPinned: .available(false), unreadCount: .available(0),
                    rootPath: paths ? .available("/synthetic") : .unavailable, projectRootPath: .available(nil),
                    surfaces: granted ? .available(duplicateFocus ? [surface, .init(
                        id: UUID(), title: "Other", kind: kind, isFocused: true,
                        isPinned: false, unreadCount: 0, workingDirectory: .unavailable
                    )] : [surface]) : .unavailable
                )
            }, windowID: fixtures.windowID
        )
    }

    private func session(
        id: UUID? = nil, other: Bool = false, liveness: AgentProcessLiveness = .alive,
        observedAt: Date? = nil
    ) -> SidebarCopilotSession {
        .init(
            id: id ?? (other ? fixtures.otherSessionID : fixtures.sessionID),
            workspaceID: other ? fixtures.workspaceB : fixtures.workspaceA,
            surfaceID: other ? fixtures.surfaceB : fixtures.surfaceA,
            liveness: liveness, state: .working, model: other ? "other-model" : "verified-model",
            observedAt: observedAt ?? now,
            nodes: [.init(id: "child", parentID: nil, depth: 0, kind: .subagent, name: "Child",
                          state: .idle, model: "child-model", ancestryUnresolved: false, hasChildren: false)],
            childrenComplete: true, treeDegraded: false, omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
    }

    private func managed(
        id: UUID? = nil, runID: UUID? = nil, generation: Int = 1, sessionID: UUID? = nil,
        coordinator: Bool = false, updatedAt: Date? = nil, gitAt: Date? = nil
    ) -> SidebarOrchestrationNode {
        .init(
            id: id ?? fixtures.surfaceB, runId: runID ?? fixtures.workspaceB, parentId: nil,
            role: coordinator ? "coordinator" : "worker", label: "Verified agent",
            workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA, generation: generation,
            phase: coordinator ? "registered" : "turn-running", availability: "busy",
            copilotSessionId: coordinator ? nil : sessionID ?? fixtures.sessionID, executionMode: .interactive,
            worktreeLabel: "pinned-46", branchLabel: "feat/pinned-details",
            gitEvidenceStatus: "verified", gitEvidenceAt: gitAt ?? now,
            gitChangesStatus: "verified",
            gitChanges: .init(files: 3, insertions: 24, deletions: 2, untrackedFiles: 0, binaryFiles: 0),
            gitChangesAt: gitAt ?? now, createdAt: now, updatedAt: updatedAt ?? now
        )
    }

    private func tree(_ sessions: [SidebarCopilotSession], generatedAt: Date? = nil) -> SidebarCopilotTree {
        .init(availability: .ready, sessions: sessions, issues: [], generatedAt: generatedAt ?? now)
    }

    private func snapshot(_ nodes: [SidebarOrchestrationNode]) -> SidebarOrchestrationSnapshot {
        .init(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: nodes)
    }

    private func pinned(
        _ hierarchy: HierarchySnapshot? = nil, sessions: [SidebarCopilotSession]? = nil,
        nodes: [SidebarOrchestrationNode] = [], connected: Bool = true,
        availability: SidebarOrchestrationAvailability = .ready, generatedAt: Date? = nil
    ) -> SidebarDetailContent {
        SidebarPresentation.pinnedDetails(
            hierarchy: hierarchy ?? self.hierarchy(), connected: connected,
            tree: tree(sessions ?? [session()], generatedAt: generatedAt), managed: snapshot(nodes),
            availability: availability, now: now
        )
    }

    private func inspector(
        _ subject: SidebarInspection, hierarchy: HierarchySnapshot? = nil,
        sessions: [SidebarCopilotSession]? = nil, nodes: [SidebarOrchestrationNode] = [],
        connected: Bool = true, availability: SidebarOrchestrationAvailability = .ready
    ) -> SidebarDetailContent? {
        SidebarPresentation.inspectorDetails(
            for: subject, hierarchy: hierarchy ?? self.hierarchy(), connected: connected,
            tree: tree(sessions ?? [session()]), managed: snapshot(nodes), availability: availability, now: now
        )
    }

    @Test func followsOnlyUniqueCurrentWindowFocusAcrossSameNamedPeers() throws {
        let sessions = [session(), session(other: true)]
        let a = pinned(sessions: sessions)
        let b = pinned(hierarchy(active: fixtures.workspaceB), sessions: sessions)
        #expect(a.isAgent && b.isAgent)
        #expect(a.inspection?.surfaceID == fixtures.surfaceA && b.inspection?.surfaceID == fixtures.surfaceB)
        #expect(a.lines.contains(.init(title: "Model", value: "verified-model")))
        #expect(b.lines.contains(.init(title: "Model", value: "other-model")))
        #expect(a.lines.filter { $0.copyableSessionID != nil } == [.sessionID(fixtures.sessionID)])
        #expect(b.lines.filter { $0.copyableSessionID != nil } == [.sessionID(fixtures.otherSessionID)])
        var windowless = hierarchy()
        windowless.windowID = nil
        for invalid in [HierarchySnapshot.empty, windowless, hierarchy(focused: false),
                        hierarchy(duplicateFocus: true), hierarchy(duplicateID: true), hierarchy(granted: false)] {
            let result = pinned(invalid)
            #expect(!result.isAgent && result.inspection == nil && result.lines.isEmpty)
        }
        #expect(pinned(connected: false).lines.isEmpty)
        #expect(pinned(hierarchy(paths: false)).lines.contains(.init(
            title: "Surface directory", value: "Path unavailable",
            help: "Reported by CMUX for this surface; no report time supplied. Not a verified agent or tool working directory."
        )))
    }

    @Test func pinnedActiveAgentSharesOnlyTheSixPermittedRawCopyFields() throws {
        let source = hierarchy(directory: "/synthetic/work/../current")
        let workspaces = source.workspaces.enumerated().map { index, workspace in
            HierarchyWorkspace(
                id: workspace.id, title: workspace.title, detail: workspace.detail,
                isSelected: workspace.isSelected, isPinned: workspace.isPinned, unreadCount: workspace.unreadCount,
                rootPath: .available(index == 0 ? "/synthetic/root/../workspace" : "/synthetic/peer"),
                projectRootPath: .available(index == 0 ? "/synthetic/project/../repo" : nil),
                surfaces: workspace.surfaces
            )
        }
        let exactPaths = HierarchySnapshot(
            sequence: source.sequence, receivedSnapshot: source.receivedSnapshot,
            workspaceListAvailable: source.workspaceListAvailable,
            workspaceMetadataAvailable: source.workspaceMetadataAvailable,
            surfaceMetadataAvailable: source.surfaceMetadataAvailable,
            workspacePathsAvailable: source.workspacePathsAvailable,
            workspaces: workspaces, windowID: source.windowID
        )
        let content = pinned(exactPaths, sessions: [session()])
        let copied = Dictionary(uniqueKeysWithValues: content.lines.compactMap { line in
            line.copyableValue.map { (line.title, $0) }
        })
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(copied == [
            "Session ID": fixtures.sessionID.uuidString,
            "Observed": timestamp.string(from: now),
            "Child history": "complete",
            "Workspace path": "/synthetic/root/../workspace",
            "Project path": "/synthetic/project/../repo",
            "Surface directory": "/synthetic/work/../current"
        ])
        #expect(content.lines.first { $0.title == "Workspace path" }?.value == "/synthetic/workspace")
        #expect(content.lines.first { $0.title == "Project path" }?.value == "/synthetic/repo")
        #expect(content.lines.first { $0.title == "Surface directory" }?.value == "/synthetic/current")

        let noPaths = pinned(hierarchy(paths: false), sessions: [session()])
        #expect(noPaths.lines.first { $0.title == "Workspace path" }?.copyableValue == nil)
        #expect(noPaths.lines.first { $0.title == "Project path" }?.copyableValue == nil)
        #expect(noPaths.lines.first { $0.title == "Surface directory" }?.copyableValue == nil)
    }

    @Test func ordinarySurfacesAndUnconfirmedIdentityCannotRetainAgentFields() {
        for kind in [HierarchySurfaceKind.browser, .markdown, .filePreview, .unknown] {
            let result = pinned(hierarchy(kind: kind), nodes: [managed()])
            #expect(!result.isAgent && result.notice == nil)
            #expect(result.visual?.title == kind.title)
            #expect(!result.lines.contains { ["Model", "Session ID", "Branch", "Git changes"].contains($0.title) })
        }
        let terminal = pinned(sessions: [], nodes: [managed()])
        #expect(!terminal.isAgent && terminal.notice == nil)
        #expect(pinned(sessions: [session(liveness: .dead)], nodes: [managed()]) == terminal)
        for sessions in [[session(), session()], [session(), session(id: UUID())],
                         [session(liveness: .ambiguous)], [session(liveness: .unknown)],
                         [session(), session(id: UUID(), liveness: .ambiguous)],
                         [session(), session(id: UUID(), liveness: .unknown)],
                         [session(), session(liveness: .dead)],
                         [session(), session(id: fixtures.sessionID, other: true, liveness: .dead)],
                         [session(observedAt: now.addingTimeInterval(-9))]] {
            let result = pinned(sessions: sessions, nodes: [managed()])
            #expect(!result.isAgent && result.notice != nil)
            #expect(!result.lines.contains { $0.copyableSessionID != nil || $0.title == "Model" })
        }
        #expect(!pinned(generatedAt: now.addingTimeInterval(-9)).isAgent)
        #expect(!pinned(sessions: [session(), session(id: fixtures.sessionID, other: true)]).isAgent)
        #expect(pinned(hierarchy(kind: .agentSession), sessions: []).notice != nil)
    }

    @Test func freshDeadRootInspectorQualifiesItsOwnModelAsLastReported() throws {
        let ended = session(liveness: .dead)
        let subject = try #require(SidebarPresentation.inspection(
            for: .unmanaged(.session(ended.id)), hierarchy: hierarchy(), connected: true,
            tree: tree([ended]), managed: .empty, availability: .ready, now: now
        ))

        let details = try #require(inspector(subject, sessions: [ended]))

        #expect(details.lines.filter { $0.title == "Last reported model" }.map(\.value) == ["verified-model"])
        #expect(!details.lines.contains { $0.title == "Model" || $0.value == "child-model" })
        #expect(details.lines.filter { $0.copyableSessionID != nil } == [.sessionID(ended.id)])
    }

    @Test func readerRepublishedDeadOwnerDoesNotSuppressItsLiveReplacement() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let now = now
        try fixture.writeRecord(.init(
            sessionID: fixture.sessionID, surfaceID: fixtures.surfaceA, launchWorkspaceID: fixtures.workspaceA,
            ownerPID: fixture.process.pid, ownerStartSeconds: fixture.process.startSeconds,
            ownerStartMicroseconds: fixture.process.startMicroseconds, recordedAt: fixture.record.recordedAt
        ))
        try fixture.writeEvents([copilotTestEvent("session.model_change", data: ["newModel": "ended-model"])])
        let initial = try await fixture.reader(clock: { now }).read(surfaceIDs: [fixtures.surfaceA])
        let initialTree = SidebarCopilotTree.project(initial, onto: SidebarTopology(hierarchy()), now: now)
        #expect(initialTree.sessions.first?.model == "ended-model")
        #expect(pinned(sessions: initialTree.sessions).lines.contains(.sessionID(fixture.sessionID)))

        let replacement = try fixture.addSession(surface: fixtures.surfaceA)
        let replacementID = try #require(UUID(uuidString: replacement.lastPathComponent))
        let owner = CopilotProcessIdentity(
            pid: 4343, parentPID: 1, uid: fixture.process.uid, startSeconds: 1, startMicroseconds: 0
        )
        try fixture.writeRecord(.init(
            sessionID: replacementID, surfaceID: fixtures.surfaceA, launchWorkspaceID: fixtures.workspaceA,
            ownerPID: owner.pid, ownerStartSeconds: owner.startSeconds,
            ownerStartMicroseconds: owner.startMicroseconds, recordedAt: fixture.record.recordedAt
        ))
        try Data().write(to: replacement.appendingPathComponent("inuse.\(owner.pid).lock"))
        try (copilotTestEvent("session.model_change", data: ["newModel": "replacement-model"]) + Data([10]))
            .write(to: replacement.appendingPathComponent("events.jsonl"))
        let node = managed(sessionID: replacementID)
        for date in [now, now.addingTimeInterval(2)] {
            let observation = try await fixture.reader(
                lookup: { $0 == owner.pid ? .found(owner) : .dead }, clock: { date }
            ).read(surfaceIDs: [fixtures.surfaceA])
            let ended = try #require(observation.sessions.first { $0.sessionID == fixture.sessionID })
            #expect(ended.liveness == .dead && ended.observedAt == date)
            let projected = SidebarCopilotTree.project(observation, onto: SidebarTopology(hierarchy()), now: date)
            #expect(projected.sessions.count == 2)
            let content = SidebarPresentation.pinnedDetails(
                hierarchy: hierarchy(), connected: true, tree: projected, managed: snapshot([node]),
                availability: .ready, now: date
            )
            #expect(content.isAgent && content.title == node.label && content.notice == nil)
            #expect(content.inspection?.sessionID == replacementID)
            #expect(content.lines.contains(.init(title: "Model", value: "replacement-model")))
            #expect(content.lines.filter { $0.copyableSessionID != nil } == [.sessionID(replacementID)])
            #expect(content.lines.contains(.init(title: "Branch", value: "Assigned directory: feat/pinned-details",
                                                help: SidebarPresentation.assignedGitHelp)))
            #expect(content.lines.contains(.init(title: "Worktree", value: "Assigned directory: pinned-46",
                                                help: SidebarPresentation.assignedGitHelp)))
            #expect(content.gitChanges == node.gitChanges)
            #expect(!content.lines.contains { $0.value.contains("ended-model") || $0.value.contains(fixture.sessionID.uuidString) })

            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            var copied: [String] = []
            var inspections = 0
            let hosting = NSHostingView(rootView: SidebarPinnedFooter(
                content: content, inspect: { inspections += 1 },
                copyValue: { copied.append($0); return SidebarSessionCopy.copy($0, to: pasteboard) }
            ).frame(width: 300))
            hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 220)
            try await settle(hosting)
            let buttons = views(hosting).compactMap { $0 as? NSButton }
                .filter { $0.accessibilityIdentifier() == "hover-copy-value" }
            #expect(buttons.count == 5)
            let sessionButton = try #require(buttons.first { $0.accessibilityLabel() == "Copy session ID" })
            #expect(sessionButton.accessibilityPerformPress())
            #expect(copied == [replacementID.uuidString] && inspections == 0)
            #expect(pasteboard.string(forType: .string) == replacementID.uuidString)
        }
    }

    @Test func managedIdentityRequiresCurrentUniqueBindingAndNeverBorrowsFromReusedSurface() {
        let node = managed()
        let result = pinned(nodes: [node])
        #expect(result.title == node.label && result.isAgent)
        #expect(result.lines.contains(.init(title: "Branch", value: "Assigned directory: feat/pinned-details",
                                           help: SidebarPresentation.assignedGitHelp)))
        #expect(result.lines.contains { $0.title == "Git changes" && $0.value.contains("+24") })
        for nodes in [[node, node], [managed(updatedAt: now.addingTimeInterval(-61))],
                      [managed(sessionID: UUID())]] {
            let unbound = pinned(nodes: nodes)
            #expect(unbound.title == "Same title" && unbound.isAgent)
            #expect(!unbound.lines.contains { $0.title == "Branch" || $0.title == "Worktree" })
            #expect(unbound.notice != nil)
        }
        let stale = pinned(nodes: [node], availability: .stale)
        #expect(stale.title == "Same title" && stale.notice != nil)
        let replaced = pinned(sessions: [session(id: fixtures.otherSessionID)], nodes: [node])
        #expect(replaced.lines.filter { $0.copyableSessionID != nil } == [.sessionID(fixtures.otherSessionID)])
        #expect(replaced.title != node.label)
        let staleGit = pinned(nodes: [managed(gitAt: now.addingTimeInterval(-3_600))])
        #expect(!staleGit.lines.contains { $0.title == "Branch" || $0.title == "Worktree" })
        #expect(staleGit.lines.contains { $0.title == "Git evidence" && $0.value.hasPrefix("Assigned directory: Stale") })
        #expect(staleGit.lines.contains(.init(title: "Git changes", value: "Assigned directory: Current counts unavailable",
                                             help: SidebarPresentation.assignedGitHelp)))
        #expect(pinned(nodes: [managed(coordinator: true)]).lines.contains(.sessionID(fixtures.sessionID)))
    }

    @Test func inspectorRevalidatesGenerationRunSessionPlacementAndPermission() throws {
        let node = managed()
        let subject = try #require(pinned(nodes: [node]).inspection)
        #expect(inspector(subject, nodes: [node])?.title == node.label)
        for replacement in [managed(generation: 2), managed(runID: UUID()),
                            managed(sessionID: fixtures.otherSessionID)] {
            #expect(inspector(subject, nodes: [replacement]) == nil)
        }
        #expect(inspector(subject, nodes: [node, node]) == nil)
        #expect(inspector(subject, sessions: [session(id: fixtures.otherSessionID)], nodes: [node]) == nil)
        #expect(inspector(subject, hierarchy: hierarchy(kind: .browser), nodes: [node]) == nil)
        #expect(inspector(subject, hierarchy: hierarchy(granted: false), nodes: [node]) == nil)
        #expect(inspector(subject, nodes: [node], connected: false) == nil)
        #expect(inspector(subject, nodes: [node], availability: .unavailable) == nil)
        var otherWindow = hierarchy()
        otherWindow.windowID = UUID()
        #expect(inspector(subject, hierarchy: otherWindow, nodes: [node]) == nil)
        let stale = try #require(inspector(subject, nodes: [node], availability: .stale))
        #expect(stale.notice != nil)
        #expect(stale.lines.contains(.sessionID(fixtures.sessionID)))
        let coordinator = managed(coordinator: true)
        let coordinatorSubject = try #require(pinned(nodes: [coordinator]).inspection)
        #expect(inspector(coordinatorSubject, sessions: [session(id: UUID())], nodes: [coordinator]) == nil)
    }

    @Test func displacedManagedRecordCanBeInspectedWithoutBorrowingCurrentSurface() throws {
        let node = managed(sessionID: fixtures.otherSessionID)
        let observations = tree([session()])
        let subject = try #require(SidebarPresentation.inspection(
            for: .managed(node), hierarchy: hierarchy(), connected: true, tree: observations,
            managed: snapshot([node]), availability: .ready, now: now
        ))
        #expect(subject.surfaceID == nil && subject.surfaceKind == nil)
        #expect(subject.sessionID == fixtures.otherSessionID)
        let detail = try #require(inspector(subject, nodes: [node]))
        #expect(detail.notice?.contains("Work context") == true)
        #expect(detail.lines.contains(.sessionID(fixtures.otherSessionID)))
        #expect(!detail.lines.contains { $0.value == "/synthetic/worktree-0" || $0.value == "verified-model" })
        #expect(detail.lines.contains { $0.title == "Focus" && $0.value.contains("Original session") })
        #expect(pinned(nodes: [node]).inspection?.sessionID == fixtures.sessionID)
    }

    @Test(arguments: ["session", "child"], ["workspace-primary", "workspace-menu", "surface-primary", "surface-menu"])
    func capturedObservedFocusRejectsChangedPlacement(subject: String, change: String) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.selectedMode = .taskboard
        let source = ObservedPlacementSource(
            sessionID: fixtures.sessionID, workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA
        )
        let polling = SidebarCopilotPolling(read: neutralRead { _ in await source.snapshot },
                                           pause: { try await Task.sleep(for: .milliseconds(10)) })
        let orchestration = SidebarOrchestrationPolling(read: {
            .init(version: 1, generatedAt: Date(), complete: true, omittedCount: 0, nodes: [])
        }, pause: { try await Task.sleep(for: .seconds(60)) })
        let model = SidebarConnectionModel(copilot: polling, orchestration: orchestration)
        var nativeActions: [SidebarNavigationTarget] = []
        func place(workspace: UUID, surface: UUID) {
            let current = HierarchySnapshot(
                sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
                workspaceMetadataAvailable: true, surfaceMetadataAvailable: true, workspacePathsAvailable: true,
                workspaces: [.init(
                    id: workspace, title: .available("Same workspace"), detail: .available(nil),
                    isSelected: .available(true), isPinned: .available(false), unreadCount: .available(0),
                    rootPath: .unavailable, projectRootPath: .unavailable, surfaces: .available([
                        .init(id: surface, title: "Same terminal", kind: .terminal, isFocused: true,
                              isPinned: false, unreadCount: 0, workingDirectory: .unavailable)
                    ])
                )], windowID: fixtures.windowID
            )
            model.replaceHierarchy(with: current)
            model.showConnected(workspaceCount: 1, surfaceCount: 1)
            let topology = SidebarTopology(current)
            polling.update(topology: topology, connected: true)
            orchestration.update(topology: topology, connected: true)
            model.navigation.update(topology: topology, connected: true,
                                    workspaceAllowed: true, surfaceAllowed: true, perform: { nativeActions.append($0) })
        }
        place(workspace: fixtures.workspaceA, surface: fixtures.surfaceA)
        model.setVisible(true)
        defer { model.setVisible(false) }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 340, height: 700),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences))
        window.contentView = hosting
        window.orderFront(nil)
        defer {
            for child in window.childWindows ?? [] { child.close() }
            window.contentView = nil
            window.close()
        }
        let label = subject == "session" ? "Focus Copilot session 10000000" : "Open parent chat for Moving child, Copilot 10000000"
        await sidebarEventually { polling.tree.attentionOwnerCount == 2 }
        try await settle(hosting)
        let oldRow = try #require(views(hosting).compactMap { $0 as? SidebarTitleNativeButton }
            .first { $0.accessibilityLabel() == label })
        let capturedPrimary = oldRow.activate
        var menu: NSMenu?
        for presenter in views(hosting).compactMap({ ($0 as? SidebarRowMenuAnchorView)?.presenter }) {
            presenter.present = { captured, _, _ in menu = captured }
        }
        let showActions = try #require(oldRow.showActions)
        showActions()
        let title = subject == "session" ? "Focus surface" : "Open parent chat"
        let item = try #require(menu?.items.flatMap { $0.submenu?.items ?? [] }.first { $0.title == title })
        let presenter = try #require(item.target as? SidebarRowMenuPresenter)
        #expect(item.isEnabled)

        let workspace = change.hasPrefix("workspace") ? fixtures.workspaceB : fixtures.workspaceA
        let surface = change.hasPrefix("surface") ? fixtures.surfaceB : fixtures.surfaceA
        source.surfaceID = surface
        place(workspace: workspace, surface: surface)
        await sidebarEventually {
            polling.tree.sessions.first?.workspaceID == workspace && polling.tree.sessions.first?.surfaceID == surface
                && polling.tree.attentionOwnerCount == 2
        }
        try await settle(hosting)
        if change.hasSuffix("primary") { capturedPrimary() }
        else { presenter.invoke(item) }
        try await Task.sleep(for: .milliseconds(100))
        print("R123 captured \(subject)/\(change): hostActions=\(nativeActions.count), acknowledgements=\(preferences.attention.acknowledged.count)")
        #expect(nativeActions.isEmpty && model.navigation.status == .idle)
        #expect(preferences.attention.acknowledged.isEmpty && polling.tree.attentionOwnerCount == 2)
        let panels = window.childWindows ?? []
        let panel = try #require(panels.count == 1 ? panels.first?.contentView : nil)
        try await settle(panel)
        let bitmap = try capture(panel)
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("retained123-placement-\(subject)-\(change).png")
        let warning = try await unavailableInspectorPixels(
            in: bitmap, dark: panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
            inset: (panel.bounds.width - 300) / 2, opaque: false, destination: destination
        )
        #expect(warning, "Stale placement must surface the existing explicit unavailable inspector")

        let freshRow = try #require(views(hosting).compactMap { $0 as? SidebarTitleNativeButton }
            .first { $0.accessibilityLabel() == label })
        freshRow.activate()
        await sidebarEventually { model.navigation.status == .selected }
        #expect(nativeActions == [.surface(workspaceID: workspace, surfaceID: surface)])
        #expect(preferences.attention.acknowledged.count == 2)
    }

    @Test(arguments: ["unchanged", "generation", "run", "session", "workspace", "surface",
                      "focus-generation", "focus-missing", "primary-generation"], SidebarMode.allCases)
    func retainedManagedMenuValidatesCapturedSubjectBeforeInspectionAndSeen(change: String, mode: SidebarMode) async throws {
        let preferenceFixture = try SidebarPreferenceFixture()
        defer { preferenceFixture.cleanup() }
        let preferences = preferenceFixture.preferences()
        preferences.selectedMode = mode
        let date = Date()
        let nodeID = UUID(), runID = UUID(), alternateSurface = UUID()
        func node(replaced: Bool) -> SidebarOrchestrationNode {
            .init(
                id: nodeID, runId: replaced && change == "run" ? UUID() : runID, parentId: nil,
                role: "worker", label: "Retained managed subject",
                workspaceId: replaced && change == "workspace" ? fixtures.workspaceB : fixtures.workspaceA,
                surfaceId: replaced && change == "surface" ? alternateSurface : fixtures.surfaceA,
                generation: replaced && ["generation", "focus-generation", "primary-generation"].contains(change) ? 2 : 1,
                phase: "turn-running", availability: "busy",
                copilotSessionId: replaced && ["session", "focus-missing"].contains(change) ? fixtures.otherSessionID : fixtures.sessionID,
                executionMode: .interactive, createdAt: date, updatedAt: date
            )
        }
        let original = node(replaced: false), replacement = node(replaced: true)
        let evidence = AgentAttention(kind: .turnFinished,
                                      evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: date)
        let clock = CopilotReaderTestClock(date)
        let source = RetainedMenuSource(node: original, evidence: evidence, clock: clock)
        let orchestration = SidebarOrchestrationPolling(
            read: { await source.managed }, pause: { try await Task.sleep(for: .seconds(60)) }
        )
        let polling = SidebarCopilotPolling(
            read: neutralRead { _ in await source.observed }, pause: { try await Task.sleep(for: .seconds(60)) },
            expiryPause: sidebarFrozenExpiry, now: { clock.now() }
        )
        let model = SidebarConnectionModel(copilot: polling, orchestration: orchestration)
        var nativeActions: [SidebarNavigationTarget] = []
        func refreshHierarchy(moved: Bool) {
            let original = fixtures.hierarchy(moved: moved)
            let current = HierarchySnapshot(
                sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
                workspaceMetadataAvailable: true, surfaceMetadataAvailable: true, workspacePathsAvailable: true,
                workspaces: original.workspaces.map { workspace in
                    guard workspace.id == fixtures.workspaceA,
                          case .available(var surfaces) = workspace.surfaces else { return workspace }
                    surfaces.append(.init(id: alternateSurface, title: "Other terminal", kind: .terminal,
                                          isFocused: false, isPinned: false, unreadCount: 0, workingDirectory: .unavailable))
                    return .init(id: workspace.id, title: workspace.title, detail: workspace.detail,
                                 isSelected: workspace.isSelected, isPinned: workspace.isPinned,
                                 unreadCount: workspace.unreadCount, rootPath: workspace.rootPath,
                                 projectRootPath: workspace.projectRootPath, surfaces: .available(surfaces))
                }, windowID: fixtures.windowID
            )
            model.replaceHierarchy(with: current)
            model.showConnected(workspaceCount: 2, surfaceCount: 3)
            let topology = SidebarTopology(current)
            polling.update(topology: topology, connected: true)
            orchestration.update(topology: topology, connected: true)
            model.navigation.update(topology: topology, connected: true, workspaceAllowed: true,
                                    surfaceAllowed: true, perform: { nativeActions.append($0) })
        }
        refreshHierarchy(moved: false)
        orchestration.setVisible(true)
        await sidebarEventually { orchestration.snapshot.nodes == [original] }
        polling.updateManagedSubjects(orchestration.snapshot)
        model.setVisible(true)
        defer { model.setVisible(false) }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 340, height: 600),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences))
        window.contentView = hosting
        window.orderFront(nil)
        defer {
            for child in window.childWindows ?? [] { child.close() }
            window.contentView = nil
            window.close()
        }
        await sidebarEventually { orchestration.snapshot.nodes == [original] && polling.tree.attentionOwnerCount == 1 }
        try await settle(hosting)
        var capturedMenu: NSMenu?
        for presenter in views(hosting).compactMap({ ($0 as? SidebarRowMenuAnchorView)?.presenter }) {
            presenter.present = { menu, _, _ in capturedMenu = menu }
        }
        let title = try #require(views(hosting).compactMap { $0 as? SidebarTitleNativeButton }
            .first { $0.accessibilityLabel() == "Focus Retained managed subject" })
        let capturedPrimary = title.activate
        let showActions = try #require(title.showActions)
        showActions()
        let menu = try #require(capturedMenu)
        let actionTitle = change.hasPrefix("focus-") || change.hasPrefix("primary-") ? "Focus surface" : "Open details"
        let item = try #require(menu.items.flatMap { $0.submenu?.items ?? [] }.first { $0.title == actionTitle })
        let presenter = try #require(item.target as? SidebarRowMenuPresenter)
        #expect(item.isEnabled && preferences.attention.acknowledged.isEmpty && nativeActions.isEmpty)

        source.node = replacement
        source.includesNode = change != "focus-missing"
        model.setVisible(false)
        refreshHierarchy(moved: change == "workspace")
        model.setVisible(true)
        await sidebarEventually {
            orchestration.snapshot.nodes == (source.includesNode ? [replacement] : [])
                && polling.tree.sessions.first?.id == replacement.copilotSessionId
                && polling.tree.attentionOwnerCount == 1
        }
        try await settle(hosting)
        let pinnedBefore = SidebarPresentation.pinnedDetails(
            hierarchy: model.hierarchy, connected: true, tree: polling.tree,
            managed: orchestration.snapshot, availability: orchestration.availability, now: date
        )
        #expect(preferences.attention.acknowledged.isEmpty && nativeActions.isEmpty)
        #expect(item.target === presenter)
        if change.hasPrefix("primary-") { capturedPrimary() }
        else { #expect(NSApp.sendAction(try #require(item.action), to: presenter, from: item)) }
        try await Task.sleep(for: .milliseconds(100))
        let inspectorWindows = window.childWindows ?? []
        let inspectorViews = inspectorWindows.compactMap(\.contentView).flatMap { [$0] + views($0) }
        let copyControls = inspectorViews.compactMap { $0 as? NSButton }
            .filter { $0.accessibilityIdentifier() == "hover-copy-value" }
        try #require(inspectorWindows.count == 1, "Production inspection must show one details or unavailable popover")
        let fields = inspectorViews.compactMap { ($0 as? NSTextField)?.stringValue }
        let panelContent = try #require(inspectorWindows.first?.contentView)
        try await settle(panelContent)
        let bitmap = try capture(panelContent)
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("polish-retained-menu-\(mode.rawValue)-\(change).png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination)
        let geometry = views(panelContent).map { view in
            "\(type(of: view)): frame=\(view.frame) bounds=\(view.bounds) visible=\(view.visibleRect) panel=\(panelContent.convert(view.bounds, from: view)) label=\(view.accessibilityLabel() ?? "")"
        }.joined(separator: "\n")
        try geometry.write(to: destination.appendingPathExtension("geometry.txt"), atomically: true, encoding: .utf8)
        #expect(bitmap.pixelsWide == Int(panelContent.bounds.width) * 2
                && bitmap.pixelsHigh == Int(panelContent.bounds.height) * 2)
        if change == "unchanged" {
            #expect(copyControls.contains { $0.accessibilityLabel() == "Copy session ID" })
            #expect(copyControls.count <= 6)
            #expect(fields.contains(fixtures.sessionID.uuidString))
            #expect(preferences.attention.acknowledged == [
                .init(sessionID: fixtures.sessionID, ownerID: nil, evidence: evidence.evidence)
            ])
        } else {
            #expect(copyControls.isEmpty, "A retained action must not inspect a replacement session")
            let dark = panelContent.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let inset = (panelContent.bounds.width - 300) / 2
            let scrolls = views(panelContent).compactMap { $0 as? NSScrollView }
            try #require(scrolls.count == 1)
            let viewport = try #require(scrolls.first?.contentView)
            let document = try #require(scrolls.first?.documentView)
            #expect(panelContent.visibleRect.contains(panelContent.bounds))
            #expect(document.bounds.size == viewport.bounds.size)
            #expect(panelContent.convert(viewport.bounds, from: viewport)
                    == NSRect(x: inset + 12, y: inset + 44, width: 276, height: 26))
            let warning = try await unavailableInspectorPixels(
                in: bitmap, dark: dark, inset: inset, opaque: false, destination: destination
            )
            #expect(warning, "\(destination.lastPathComponent): exact unavailable heading and explanation pixels")
            #expect(fields.isEmpty, "Unavailable details must not retain any native metadata fields")
            #expect(!fields.contains("retained-menu-model") && !fields.contains(replacement.copilotSessionId!.uuidString))
            #expect(preferences.attention.acknowledged.isEmpty && polling.tree.attentionOwnerCount == 1)
        }
        #expect(nativeActions.isEmpty && model.navigation.status == .idle)
        #expect(SidebarPresentation.pinnedDetails(
            hierarchy: model.hierarchy, connected: true, tree: polling.tree,
            managed: orchestration.snapshot, availability: orchestration.availability, now: date
        ) == pinnedBefore)
        print("R2 \(mode.rawValue)/\(change): retained production NSMenuItem dispatched; copies=\(copyControls.count), acknowledgements=\(preferences.attention.acknowledged.count), host=0")
    }

    @Test func reportedModelSwitchUpdatesOnlyExactHoveredSubjectAndLeavesPinnedPeerAlone() throws {
        let fixedPeer = session(other: true)
        let initial = session()
        let updated = SidebarCopilotSession(
            id: initial.id, workspaceID: initial.workspaceID, surfaceID: initial.surfaceID,
            liveness: .alive, state: .working, model: "provider/root-v2", observedAt: now,
            nodes: [.init(id: "child", parentID: nil, depth: 0, kind: .subagent, name: "Child",
                          state: .working, model: "provider/child-v2", ancestryUnresolved: false, hasChildren: false)],
            childrenComplete: true, treeDegraded: false, omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
        let activePeer = hierarchy(active: fixtures.workspaceB)
        let before = pinned(activePeer, sessions: [initial, fixedPeer])
        for (observed, rootModel, childModel) in [
            (initial, "verified-model", "child-model"), (updated, "provider/root-v2", "provider/child-v2")
        ] {
            let observations = tree([observed, fixedPeer])
            for (target, expected) in [
                (SidebarAgentHoverTarget.session(observed.id), rootModel),
                (.child(sessionID: observed.id, childID: "child"), childModel)
            ] {
                let hover = try #require(SidebarAgentHoverContent.card(
                    for: target, hierarchy: activePeer, connected: true, tree: observations,
                    managed: .empty, availability: .ready, now: now
                ))
                #expect(hover.lines.filter { $0.title == "Model" }.map(\.value) == [expected])
                #expect(!hover.lines.contains { $0.value == "other-model" })
            }
            let subject = try #require(SidebarPresentation.inspection(
                for: .unmanaged(.session(observed.id)), hierarchy: activePeer, connected: true,
                tree: observations, managed: .empty, availability: .ready, now: now
            ))
            let details = try #require(inspector(subject, hierarchy: activePeer, sessions: [observed, fixedPeer]))
            #expect(details.lines.filter { $0.title == "Model" }.map(\.value) == [rootModel])
            #expect(pinned(activePeer, sessions: [observed, fixedPeer]) == before)
        }
        #expect(before.inspection?.sessionID == fixedPeer.id)
        #expect(before.lines.contains(.init(title: "Model", value: "other-model")))
    }

    @Test func childInspectionRetainsParentPlacementAndDoesNotChangePinnedSubject() throws {
        let before = pinned()
        let child = try #require(SidebarPresentation.inspection(
            for: .unmanaged(.child(sessionID: fixtures.sessionID, childID: "child")),
            hierarchy: hierarchy(), connected: true, tree: tree([session()]), managed: .empty,
            availability: .ready, now: now
        ))
        let detail = try #require(inspector(child))
        #expect(child.surfaceID == fixtures.surfaceA)
        #expect(detail.lines.contains(.sessionID(fixtures.sessionID, isParent: true)))
        #expect(detail.lines.contains(.init(title: "Model", value: "child-model")))
        #expect(detail.lines.contains { $0.title == "Placement" && $0.value.contains("parent session") })
        #expect(before == pinned())
        #expect(inspector(child, sessions: [session(id: UUID())]) == nil)
        var duplicate = session()
        duplicate.nodes.append(duplicate.nodes[0])
        #expect(inspector(child, sessions: [duplicate]) == nil)
        for selection in [UnmanagedSelection.workspace(fixtures.workspaceA),
                          .surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA),
                          .session(fixtures.sessionID)] {
            let target = try #require(SidebarPresentation.inspection(
                for: .unmanaged(selection), hierarchy: hierarchy(), connected: true,
                tree: tree([session()]), managed: .empty, availability: .ready, now: now
            ))
            #expect(inspector(target) != nil)
        }
    }

    @Test func workspaceInspectionNeedsNoSurfaceGrantAndRedactsPathsIndependently() throws {
        let target = SidebarInspection.Target.unmanaged(.workspace(fixtures.workspaceA))
        let subject = try #require(SidebarPresentation.inspection(
            for: target, hierarchy: hierarchy(), connected: true, tree: tree([session()]),
            managed: .empty, availability: .ready, now: now
        ))
        let raw = CmuxSidebarSnapshot(
            sequence: 1, windowID: fixtures.windowID, selectedWorkspaceID: nil,
            workspaces: [.init(
                id: fixtures.workspaceA, title: "Workspace without surfaces",
                rootPath: "/synthetic/worktree", projectRootPath: "/synthetic",
                surfaces: [.init(id: fixtures.surfaceA, title: "Terminal", kind: .terminal)]
            )]
        )
        func mapped(_ raw: CmuxSidebarSnapshot, scopes: Set<CmuxExtensionScope>) -> HierarchySnapshot {
            let model = SidebarConnectionModel()
            model.update(context: .init(snapshot: raw.filtered(for: scopes), host: .init(performAction: { _, _ in })))
            return model.hierarchy
        }
        for paths in [true, false] {
            let hierarchy = mapped(raw, scopes: paths ? [.workspaceMetadata, .workspacePaths] : [.workspaceMetadata])
            #expect(!SidebarTopology(hierarchy).canReadSessions)
            #expect(hierarchy.workspaces.first?.surfaces == .unavailable)
            let detail = try #require(inspector(subject, hierarchy: hierarchy))
            #expect(detail.title == "Workspace without surfaces")
            #expect(detail.lines == [
                .init(title: "Workspace ID", value: fixtures.workspaceA.uuidString),
                .init(title: "Workspace path", value: paths ? "/synthetic/worktree" : "Path unavailable"),
                .init(title: "Project path", value: paths ? "/synthetic" : "Path unavailable")
            ])
            for dependent in [
                SidebarInspection.Target.unmanaged(.surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA)),
                .unmanaged(.session(fixtures.sessionID)), .unmanaged(.child(sessionID: fixtures.sessionID, childID: "child")),
                .managed(managed())
            ] {
                #expect(SidebarPresentation.inspection(
                    for: dependent, hierarchy: hierarchy, connected: true, tree: tree([session()]),
                    managed: snapshot([managed()]), availability: .ready, now: now
                ) == nil)
            }
            #expect(inspector(subject, hierarchy: hierarchy, connected: false) == nil)
        }
        var windowless = raw
        windowless.windowID = nil
        var otherWindow = raw
        otherWindow.windowID = UUID()
        var removed = raw
        removed.workspaces = []
        var duplicate = raw
        duplicate.workspaces.append(raw.workspaces[0])
        for invalid in [
            HierarchySnapshot.empty, mapped(raw, scopes: []), mapped(raw, scopes: [.workspaceList, .workspacePaths]),
            mapped(windowless, scopes: [.workspaceMetadata]), mapped(otherWindow, scopes: [.workspaceMetadata]),
            mapped(removed, scopes: [.workspaceMetadata]), mapped(duplicate, scopes: [.workspaceMetadata])
        ] {
            #expect(inspector(subject, hierarchy: invalid) == nil)
        }
    }

    @Test func passiveProjectionAndHoverHaveNoInteractionOrUnsupportedMetrics() throws {
        let before = pinned(nodes: [managed()])
        _ = SidebarAgentHoverContent.card(
            for: .child(sessionID: fixtures.sessionID, childID: "child"), hierarchy: hierarchy(),
            connected: true, tree: tree([session()]), managed: snapshot([managed()]), availability: .ready, now: now
        )
        #expect(pinned(nodes: [managed()]) == before)
        #expect(!before.lines.contains { ["Context", "Elapsed", "Tokens", "Duration"].contains($0.title) })
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let presentation = try String(contentsOf: root.appendingPathComponent(
            "CMUXMaestroSidebar/UI/SidebarPresentation.swift"), encoding: .utf8)
        let projection = try #require(presentation.components(separatedBy: "static func pinnedDetails(").last?
            .components(separatedBy: "static func state(").first)
        for forbidden in ["markSeen(", "prepareSeen(", "acknowledge(", "SidebarNavigation", "context.host", "Timer"] {
            #expect(!projection.contains(forbidden))
        }
        let source = try String(contentsOf: root.appendingPathComponent(
            "CMUXMaestroSidebar/UI/SidebarView.swift"), encoding: .utf8)
        #expect(source.contains(".popover(isPresented: $showingInspector)"))
        #expect(source.contains("SidebarPresentation.focusInteraction(from: old, to: new)"))
        #expect(!source.contains("selectionDetails"))
        let footer = try #require(source.components(separatedBy: "struct SidebarPinnedFooter: View").last?
            .components(separatedBy: "private struct PathDetail").first)
        #expect(footer.contains("if content.isAgent { SidebarPlaceholderPet() }"))
        for forbidden in ["SidebarCloseButton", "prepareSeen(", "FocusButton", ".onHover", "RoundedRectangle"] {
            #expect(!footer.contains(forbidden))
        }
    }

    @Test(arguments: [false, true])
    func inspectorRendersFullMetadataThenClearsRevokedSubjectWithoutAffectingFooter(dark: Bool) async throws {
        var observed = session()
        observed.nodes.append(.init(id: "skill", parentID: nil, depth: 0, kind: .skill, name: "Other work",
                                    state: .idle, model: nil, ancestryUnresolved: false, hasChildren: false))
        let pinned = pinned(sessions: [observed])
        let subject = try #require(pinned.inspection)
        let detail = try #require(inspector(subject, sessions: [observed]))
        #expect(detail.otherActivity.map(\.id) == ["skill"])
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frame = NSRect(x: 0, y: 0, width: 300, height: 460)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        func view(_ content: SidebarDetailContent?) -> some View {
            SidebarInspector(content: content, close: {})
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        let hosting = NSHostingView(rootView: view(detail))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        let responder = window.firstResponder
        for available in [true, false] {
            let content = available ? detail : inspector(subject, connected: false)
            hosting.rootView = view(content)
            try await settle(hosting)
            #expect(!window.isVisible && window.firstResponder === responder)
            if !available {
                #expect(!views(hosting).contains { $0.accessibilityIdentifier() == "hover-copy-value" })
            }
            let bitmap = try capture(hosting)
            #expect(bitmap.pixelsWide == 600 && bitmap.pixelsHigh == 920)
            let destination = folder.appendingPathComponent(
                "pinned46-inspector-\(dark ? "dark" : "light")-\(available ? "details" : "unavailable").png"
            )
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination)
            let text = try SidebarRenderingEvidence.recognizedNativeLines(in: destination)
            let model = try await inspectorModelPixels(in: bitmap, dark: dark, destination: destination)
            #expect(model == available, "\(destination.lastPathComponent): exact Model/value pixels")
            if available {
                #expect(text.contains("Model"), "\(destination.lastPathComponent): \(text)")
            } else {
                #expect(text.contains("Details no longer available"), "\(destination.lastPathComponent): \(text)")
                #expect(!text.contains { $0.contains("verified-model") }, "\(destination.lastPathComponent): \(text)")
                #expect(!text.contains { $0.contains("Copilot") || $0 == "working" || $0 == "Model" },
                        "\(destination.lastPathComponent): \(text)")
            }
        }
        #expect(self.pinned(sessions: [observed]) == pinned)
    }

    @Test(arguments: [false, true])
    func inspectorRenderEvidenceRejectsWrongMissingHiddenAndClippedModels(dark: Bool) async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let subject = try #require(pinned().inspection)
        for control in ["visible", "wrong", "missing", "hidden", "clipped", "elsewhere", "suffix"] {
            var content = try #require(inspector(subject))
            if control == "wrong" || control == "elsewhere" || control == "suffix" {
                content.lines = content.lines.map {
                    $0.title == "Model" ? .init(title: "Model", value: control == "suffix"
                                              ? "verified-model-plus-suffix" : "verifled-model") : $0
                }
                if control == "elsewhere" {
                    content.lines = content.lines.map {
                        $0.title == "Process" ? .init(title: "Elsewhere", value: "verified-model") : $0
                    }
                }
            } else if control == "missing" {
                content.lines.removeAll { $0.title == "Model" }
            }
            let frame = NSRect(x: 0, y: 0, width: 300, height: 460)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: SidebarInspector(
                content: content, close: { Issue.record("Rendering must not close the inspector") }
            )
            .frame(width: frame.width, height: frame.height)
            .frame(height: control == "clipped" ? 102 : frame.height, alignment: .top)
            .clipped()
            .opacity(control == "hidden" ? 0 : 1)
            .frame(width: frame.width, height: frame.height, alignment: .top)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            let responder = window.firstResponder
            try await settle(hosting)
            #expect(!window.isVisible && window.firstResponder === responder)
            let bitmap = try capture(hosting)
            #expect(bitmap.pixelsWide == 600 && bitmap.pixelsHigh == 920)
            let destination = folder.appendingPathComponent(
                "pinned46-inspector-control-\(dark ? "dark" : "light")-\(control).png"
            )
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination)
            let text = try SidebarRenderingEvidence.recognizedNativeLines(in: destination)
            let model = try await inspectorModelPixels(in: bitmap, dark: dark, destination: destination)
            #expect(model == (control == "visible"), "\(destination.lastPathComponent): exact Model/value pixels")
            if control != "hidden" {
                #expect(text.contains("working"), "\(destination.lastPathComponent): \(text)")
            }
        }
        try await unavailableInspectorEvidenceRejectsMissingHiddenWrongClippedAndMisplacedWarnings(dark: dark)
    }

    @Test func footerRendersNativeLightDarkNarrowShortAndCopiesWithoutInspection() async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var inspections = 0
        var copies: [String] = []
        for dark in [false, true] {
            for width: CGFloat in [240, 340] {
                for height: CGFloat in [144, 220] {
                    let content = pinned(nodes: [managed()])
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height + 70),
                                          styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let hosting = NSHostingView(rootView: VStack {
                        SidebarPinnedFooter(content: content, maximumHeight: height, inspect: { inspections += 1 },
                                            copyValue: { copies.append($0); return SidebarSessionCopy.copy($0, to: pasteboard) })
                        Spacer(minLength: 50)
                    }
                    .padding(10)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor)))
                    window.contentView = hosting
                    defer { window.contentView = nil; window.close() }
                    try await settle(hosting)
                    #expect(!window.isVisible && inspections == 0)
                    let initialBitmap = try capture(hosting)
                    let initialImage = folder.appendingPathComponent(
                        "pinned46-\(dark ? "dark" : "light")-\(Int(width))x\(Int(height))-initial.png"
                    )
                    try #require(initialBitmap.representation(using: .png, properties: [:])).write(to: initialImage)
                    let initialText = try SidebarRenderingEvidence.recognizedNativeLines(in: initialImage)
                    #expect(initialText.contains { $0.contains("Verified agent") }, "\(initialImage.lastPathComponent): \(initialText)")
                    let initialModel = try await footerModelPixels(
                        in: initialBitmap, dark: dark, destination: initialImage
                    )
                    #expect(initialModel, "\(initialImage.lastPathComponent): exact visible model pixels")
                    let buttons = views(hosting).compactMap { $0 as? NSButton }
                        .filter { $0.accessibilityIdentifier() == "hover-copy-value" }
                    let button = try #require(buttons.first { $0.accessibilityLabel() == "Copy session ID" })
                    #expect(buttons.count == 5)
                    for action in buttons { #expect(action.acceptsFirstResponder) }
                    #expect(button.acceptsFirstResponder)
                    button.scrollToVisible(button.bounds)
                    try await settle(hosting)
                    #expect(button.accessibilityPerformPress())
                    try await settle(hosting)
                    #expect(button.accessibilityValue() as? String == "Copied")
                    #expect(pasteboard.string(forType: .string) == fixtures.sessionID.uuidString)
                    let feedback = try #require(views(hosting).compactMap { $0 as? NSTextField }
                        .first { $0.accessibilityIdentifier() == "hover-copy-feedback" })
                    feedback.scrollToVisible(feedback.bounds)
                    try await settle(hosting)
                    #expect(feedback.stringValue == "Copied" && feedback.accessibilityValue() == "Copied")
                    let drawing = feedback.alignmentRect(forFrame: feedback.bounds)
                    #expect(drawing.height > 0 && feedback.visibleRect.contains(drawing))
                    let viewport = try #require(feedback.enclosingScrollView?.contentView)
                    #expect(viewport.bounds.contains(viewport.convert(drawing, from: feedback)))
                    let scroll = try #require(views(hosting).compactMap { $0 as? NSScrollView }.first)
                    scroll.contentView.scroll(to: .zero)
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try await settle(hosting)
                    let bitmap = try capture(hosting)
                    #expect(bitmap.pixelsWide == Int(width) * 2 && bitmap.pixelsHigh == Int(height + 70) * 2)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    let destination = folder.appendingPathComponent("pinned46-feedback-\(dark ? "dark" : "light")-\(Int(width))x\(Int(height)).png")
                    try png.write(to: destination)
                    for scroll in views(hosting).compactMap({ $0 as? NSScrollView }) {
                        let document = try #require(scroll.documentView)
                        #expect(document.bounds.width <= scroll.contentView.bounds.width + 0.5)
                    }
                }
            }
        }
        #expect(!copies.isEmpty && inspections == 0)
    }

    @Test(arguments: [false, true])
    func directoryProvenanceRendersInProductionHoverPinnedAndDetails(dark: Bool) async throws {
        // A relative report avoids OCR's slash/parenthesis ambiguity; absolute/home paths have projection oracles.
        let hierarchy = hierarchy(directory: "reports")
        let observed = session()
        let node = managed()
        let tree = tree([observed])
        let managed = snapshot([node])
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var cards: [(String, AnyView, String)] = []
        for (name, target, label) in [
            ("session-hover", SidebarAgentHoverTarget.session(observed.id), "Surface directory"),
            ("managed-hover", .managed(node.id, generation: node.generation), "Surface directory"),
            ("child-hover", .child(sessionID: observed.id, childID: "child"), "Parent surface directory")
        ] {
            let content = try #require(SidebarAgentHoverContent.card(
                for: target, hierarchy: hierarchy, connected: true, tree: tree,
                managed: managed, availability: .ready, now: now
            ))
            cards.append((name, AnyView(SidebarHoverCard(
                data: content, close: { Issue.record("Offscreen render must not close") },
                copyValue: { _ in Issue.record("Offscreen render must not copy"); return false }
            )), label))
        }
        for (name, target, label) in [
            ("surface-details", SidebarInspection.Target.unmanaged(.surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA)), "Surface directory"),
            ("session-details", .unmanaged(.session(observed.id)), "Surface directory"),
            ("managed-details", .managed(node), "Surface directory"),
            ("child-details", .unmanaged(.child(sessionID: observed.id, childID: "child")), "Parent surface directory")
        ] {
            let subject = try #require(SidebarPresentation.inspection(
                for: target, hierarchy: hierarchy, connected: true, tree: tree,
                managed: managed, availability: .ready, now: now
            ))
            let content = try #require(SidebarPresentation.inspectorDetails(
                for: subject, hierarchy: hierarchy, connected: true, tree: tree,
                managed: managed, availability: .ready, now: now
            ))
            cards.append((name, AnyView(SidebarInspector(
                content: content, close: { Issue.record("Offscreen render must not close") }
            )), label))
        }
        for (name, sessions, nodes) in [
            ("surface-pinned", [SidebarCopilotSession](), [SidebarOrchestrationNode]()),
            ("session-pinned", [observed], []), ("managed-pinned", [observed], [node])
        ] {
            let content = pinned(hierarchy, sessions: sessions, nodes: nodes)
            cards.append((name, AnyView(SidebarPinnedFooter(
                content: content, maximumHeight: 900, inspect: { Issue.record("Offscreen render must not inspect") },
                copyValue: { _ in Issue.record("Offscreen render must not copy"); return false }
            )), "Surface directory"))
        }
        for (name, card, label) in cards {
            let frame = NSRect(x: 0, y: 0, width: 340, height: 900)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: card
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            let responder = window.firstResponder
            try await settle(hosting)
            if let pathAction = views(hosting).compactMap({ $0 as? NSButton }).first(where: {
                ["Copy surface directory", "Copy parent surface directory"].contains($0.accessibilityLabel())
            }) {
                if let document = pathAction.enclosingScrollView?.documentView {
                    let fieldRect = pathAction.convert(pathAction.bounds, to: document).insetBy(dx: 0, dy: -48)
                    document.scrollToVisible(fieldRect)
                }
                try await settle(hosting)
            }
            #expect(!window.isVisible && window.firstResponder === responder)
            let bitmap = try capture(hosting)
            let destination = folder.appendingPathComponent("directory77-\(name)-\(dark ? "dark" : "light").png")
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination)
            let text = try SidebarRenderingEvidence.recognizedLines(in: destination, dark: dark, naturalLanguage: true)
            #expect(text.contains { $0.contains(label) }, "\(name): directory label must survive all production filters: \(text)")
            #expect(text.contains("reports") || text.contains("Surface directory: reports"),
                    "\(name): exact surface value must render: \(text)")
            #expect(!text.contains { $0.contains("Working directory") || $0.contains("Parent working directory") })
            let metrics = SidebarRenderingEvidence.metrics(for: hosting)
            #expect(metrics.documentWidth <= metrics.viewportWidth + 0.5)
        }
    }

    @Test(arguments: [false, true])
    func footerRenderEvidenceRejectsWrongMissingHiddenAndClippedModels(dark: Bool) async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for control in ["visible", "wrong", "missing", "hidden", "clipped", "elsewhere", "suffix"] {
            var content = pinned(nodes: [managed()])
            if ["wrong", "missing", "elsewhere", "suffix"].contains(control) {
                content.lines.removeAll { $0.title == "Model" }
                if control != "missing" {
                    content.lines.append(.init(title: "Model", value: control == "suffix"
                                               ? "verified-model-plus-suffix" : "verifled-model"))
                }
                if control == "elsewhere" { content.notice = "verified-model" }
            }
            let frame = NSRect(x: 0, y: 0, width: 240, height: 214)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: VStack {
                SidebarPinnedFooter(content: content, maximumHeight: 144,
                                    inspect: { Issue.record("Rendering must not inspect") },
                                    copyValue: { _ in Issue.record("Rendering must not copy"); return false })
                    .frame(height: control == "clipped" ? 60 : nil, alignment: .top)
                    .clipped()
                    .opacity(control == "hidden" ? 0 : 1)
                Spacer(minLength: 50)
            }
            .padding(10)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            try await settle(hosting)
            #expect(!window.isVisible)
            let bitmap = try capture(hosting)
            let destination = folder.appendingPathComponent(
                "pinned46-control-\(dark ? "dark" : "light")-\(control).png"
            )
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination)
            let text = try SidebarRenderingEvidence.recognizedNativeLines(in: destination)
            let model = try await footerModelPixels(in: bitmap, dark: dark, destination: destination)
            #expect(model == (control == "visible"), "\(destination.lastPathComponent): exact visible model pixels")
            #expect(!text.contains("Copied"), "\(destination.lastPathComponent): \(text)")
            if control != "hidden" {
                #expect(text.contains("Verified agent"), "\(destination.lastPathComponent): \(text)")
            }
        }
    }

    private func unavailableInspectorEvidenceRejectsMissingHiddenWrongClippedAndMisplacedWarnings(dark: Bool) async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frame = NSRect(x: 0, y: 0, width: 300, height: 460)
        let controls = ["visible", "missing", "hidden", "wrong", "clipped", "elsewhere"]
        for (popover, control) in [false, true].flatMap({ popover in controls.map { (popover, $0) } }) {
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let content = SidebarInspector(
                content: nil, close: { Issue.record("Warning rendering must not close details") }
            )
            .frame(width: frame.width, height: frame.height)
            .overlay(alignment: .topLeading) {
                if control == "missing" || control == "wrong" {
                    Color(nsColor: .windowBackgroundColor)
                        .frame(width: 244, height: 24)
                        .overlay(alignment: .leading) {
                            if control == "wrong" {
                                Text("Details are still available")
                                    .font(.system(.subheadline).weight(.semibold))
                            }
                        }
                        .padding(12)
                }
            }
            .frame(height: control == "clipped" ? 24 : frame.height, alignment: .top)
            .clipped()
            .opacity(control == "hidden" ? 0 : 1)
            .offset(y: control == "elsewhere" ? 100 : 0)
            .frame(width: frame.width, height: frame.height, alignment: .top)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(popover ? .clear : Color(nsColor: .windowBackgroundColor))
            @ViewBuilder func root() -> some View {
                if popover {
                    Color.clear.frame(width: frame.width, height: frame.height)
                        .popover(isPresented: .constant(true)) { content }
                        .environment(\.colorScheme, dark ? .dark : .light)
                } else {
                    content
                }
            }
            let hosting = NSHostingView(rootView: root())
            window.contentView = hosting
            defer {
                for child in window.childWindows ?? [] { child.close() }
                window.contentView = nil
                window.close()
            }
            let responder = window.firstResponder
            if popover { window.orderFront(nil) }
            try await settle(hosting)
            #expect(window.isVisible == popover && window.firstResponder === responder)
            let captureView = popover ? try #require(window.childWindows?.first?.contentView) : hosting
            try await settle(captureView)
            let bitmap = try capture(captureView)
            let destination = folder.appendingPathComponent(
                "polish-unavailable-control-\(popover ? "popover" : "embedded")-\(dark ? "dark" : "light")-\(control).png"
            )
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination)
            let warning = try await unavailableInspectorPixels(
                in: bitmap, dark: dark, inset: (captureView.bounds.width - 300) / 2,
                opaque: !popover, destination: destination
            )
            #expect(warning == (control == "visible"), "\(destination.lastPathComponent): exact warning pixels")
        }
    }

    private func unavailableInspectorPixels(
        in actual: NSBitmapImageRep, dark: Bool, inset: CGFloat, opaque: Bool, destination: URL
    ) async throws -> Bool {
        let size = actual.size
        try #require(actual.pixelsWide == Int(size.width) * 2 && actual.pixelsHigh == Int(size.height) * 2)
        try #require(inset >= 0 && size.width == 300 + inset * 2 && size.height >= 82 + inset * 2)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Literal copy and fixed compact geometry are independent of the production view and its text fields.
        func reference(visible: Bool) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Details no longer available")
                    .font(.system(.subheadline).weight(.semibold))
                    .frame(width: 244, height: 24, alignment: .leading)
                ScrollView {
                    Text("The subject changed or access is unavailable. Open Details again from a current row.")
                        .font(.system(.caption).weight(.regular)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 420)
            }
            .opacity(visible ? 1 : 0)
            .padding(12)
            .frame(width: 300, height: size.height - inset * 2, alignment: .topLeading)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(opaque ? Color(nsColor: .windowBackgroundColor) : .clear)
        }
        @ViewBuilder func root(visible: Bool) -> some View {
            if opaque {
                reference(visible: visible)
            } else {
                Color.clear.frame(width: 300, height: size.height)
                    .popover(isPresented: .constant(true)) { reference(visible: visible) }
                    .environment(\.colorScheme, dark ? .dark : .light)
            }
        }
        let hosting = NSHostingView(rootView: root(visible: true))
        window.contentView = hosting
        defer {
            for child in window.childWindows ?? [] { child.close() }
            window.contentView = nil
            window.close()
        }
        let responder = window.firstResponder
        let keyWindow = NSApp.keyWindow
        if !opaque { window.orderFront(nil) }
        try await settle(hosting)
        let referenceView = opaque ? hosting : try #require(window.childWindows?.first?.contentView)
        try await settle(referenceView)
        try #require(referenceView.bounds.size == size)
        let expected = try capture(referenceView)
        try #require(expected.representation(using: .png, properties: [:]))
            .write(to: destination.deletingPathExtension().appendingPathExtension("reference.png"))
        hosting.rootView = root(visible: false)
        try await settle(hosting)
        try await settle(referenceView)
        let blank = try capture(referenceView)
        #expect(window.firstResponder === responder)
        #expect(NSApp.keyWindow === keyWindow)
        #expect(window.isVisible == !opaque)
        // Complete title band and both explanation lines, including borders/trailing space. No translation or tolerance.
        let regions = [
            NSRect(x: 11 + inset, y: 11 + inset, width: 246, height: 26),
            NSRect(x: 11 + inset, y: 43 + inset, width: 278, height: 28)
        ]
        var differences: [Int] = [], nonblank: [Int] = []
        for region in regions {
            try #require(NSRect(origin: .zero, size: size).contains(region))
            var changed = 0, painted = 0
            for y in Int(region.minY * 2)..<Int(region.maxY * 2) {
                for x in Int(region.minX * 2)..<Int(region.maxX * 2) {
                    let a = try #require(actual.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let e = try #require(expected.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let b = try #require(blank.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if a.redComponent != e.redComponent || a.greenComponent != e.greenComponent
                        || a.blueComponent != e.blueComponent || a.alphaComponent != e.alphaComponent { changed += 1 }
                    if e.redComponent != b.redComponent || e.greenComponent != b.greenComponent
                        || e.blueComponent != b.blueComponent || e.alphaComponent != b.alphaComponent { painted += 1 }
                }
            }
            try #require(painted > 0, "A blank literal reference cannot prove visible text")
            differences.append(changed)
            nonblank.append(painted)
        }
        let evidence: [String: Any] = [
            "differingPixels": differences, "referenceNonblankPixels": nonblank,
            "regionsPoints": regions.map { [$0.minX, $0.minY, $0.width, $0.height] },
            "sizePoints": [size.width, size.height], "scale": 2, "tolerance": 0, "translation": 0
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.deletingPathExtension().appendingPathExtension("pixels.json"))
        print("R4 exact warning \(destination.lastPathComponent): \(evidence)")
        return differences.allSatisfy { $0 == 0 }
    }

    private func footerModelPixels(
        in actual: NSBitmapImageRep, dark: Bool, destination: URL
    ) async throws -> Bool {
        let size = actual.size
        try #require([CGFloat(240), 340].contains(size.width))
        try #require([CGFloat(214), 290].contains(size.height))
        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var modelRegion = CGRect.null
        // Independent literal header geometry: outer inset, divider, gaps, 24-point heading and 38-point pet.
        let reference = NSHostingView(rootView: VStack(alignment: .leading, spacing: 2) {
            Text("Verified agent").font(.system(.caption).weight(.semibold)).lineLimit(2)
            Label("Working", systemImage: "circle.fill")
                .font(.system(.caption2).weight(.regular))
                .fixedSize(horizontal: false, vertical: true)
            Text("verified-model").font(.system(.caption2).weight(.regular))
                .foregroundStyle(.secondary).lineLimit(1)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named("footer-model-reference"))
                } action: { modelRegion = $0 }
        }
        .frame(width: size.width - 20 - 38 - 8, alignment: .leading)
        .padding(.leading, 10 + 38 + 8).padding(.top, 10 + 0.5 + 4 + 24 + 4)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: "footer-model-reference")
        .environment(\.colorScheme, dark ? .dark : .light)
        .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = reference
        defer { window.contentView = nil; window.close() }
        let responder = window.firstResponder
        try await settle(reference)
        #expect(!window.isVisible && window.firstResponder === responder)
        let expected = try capture(reference)
        try #require(expected.representation(using: .png, properties: [:])).write(to:
            destination.deletingPathExtension().appendingPathExtension("reference.png"))
        try #require(!modelRegion.isNull && !modelRegion.isEmpty)
        let value = modelRegion
        let left = Int((value.minX - 1) * 2), right = Int((size.width - 10) * 2)
        let top = Int((value.minY - 1) * 2), bottom = Int((value.maxY + 1) * 2)
        // Include the entire trailing model column so extra suffix ink cannot match.
        return try exactModelPixels(in: actual, reference: expected, regions: [
            (CGRect(x: left, y: top, width: right - left, height: bottom - top), 100)
        ], destination: destination)
    }

    private func inspectorModelPixels(
        in actual: NSBitmapImageRep, dark: Bool, destination: URL
    ) async throws -> Bool {
        let frame = NSRect(x: 0, y: 0, width: 300, height: 460)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Independent literals and compact typography; no production projection or screenshot supplies the reference.
        let reference = NSHostingView(rootView: VStack(alignment: .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: 1) {
                Text("State").foregroundStyle(.secondary)
                Text("working").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Model").foregroundStyle(.secondary)
                Text("verified-model").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(.caption).weight(.regular))
        .frame(width: 251, alignment: .leading)
        .padding(.leading, 12 + 8).padding(.top, 12 + 24 + 8 + 5)
        .frame(width: 300, height: 460, alignment: .topLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
        .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = reference
        defer { window.contentView = nil; window.close() }
        let responder = window.firstResponder
        try await settle(reference)
        #expect(!window.isVisible && window.firstResponder === responder)
        let expected = try capture(reference)
        let referenceURL = destination.deletingPathExtension().appendingPathExtension("reference.png")
        try #require(expected.representation(using: .png, properties: [:])).write(to: referenceURL)
        let field = try #require(views(reference).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "verified-model" })
        let value = reference.convert(field.alignmentRect(forFrame: field.bounds), from: field)
        // Both full lines plus a one-point border and the entire trailing column: suffix ink must also fail.
        let left = Int((value.minX - 1) * 2), right = 542
        let top = Int((value.minY - value.height - 2) * 2)
        let middle = Int(value.minY * 2)
        let bottom = Int((value.maxY + 1) * 2)
        try #require(actual.pixelsWide == 600 && actual.pixelsHigh == 920)
        return try exactModelPixels(in: actual, reference: expected, regions: [
            (CGRect(x: left, y: top, width: right - left, height: middle - top), 20),
            (CGRect(x: left, y: middle, width: right - left, height: bottom - middle), 100)
        ], destination: destination)
    }

    private func exactModelPixels(
        in actual: NSBitmapImageRep, reference expected: NSBitmapImageRep,
        regions: [(bounds: CGRect, minimumInk: Int)], destination: URL
    ) throws -> Bool {
        try #require(expected.pixelsWide == actual.pixelsWide && expected.pixelsHigh == actual.pixelsHigh)
        try #require(actual.pixelsWide == Int(actual.size.width) * 2 && actual.pixelsHigh == Int(actual.size.height) * 2)
        try #require(!regions.isEmpty)
        let bounds = regions.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        try #require(bounds.minX > 0 && bounds.minY > 0 && bounds.maxX < CGFloat(actual.pixelsWide)
                     && bounds.maxY < CGFloat(actual.pixelsHigh))
        let background = try #require(expected.colorAt(
            x: Int(bounds.maxX) - 1, y: Int(bounds.midY)
        )?.usingColorSpace(.deviceRGB))
        var best = Double.infinity
        var differingPixels = Int.max
        var alignment = [0, 0]
        var referenceInk: [Int] = []
        for dy in -1...1 {
            for dx in -1...1 {
                var error = 0.0, differences = 0
                var ink = Array(repeating: 0, count: regions.count)
                for (index, region) in regions.enumerated() {
                    for y in Int(region.bounds.minY)..<Int(region.bounds.maxY) {
                        for x in Int(region.bounds.minX)..<Int(region.bounds.maxX) {
                            let a = try #require(actual.colorAt(x: x + dx, y: y + dy)?.usingColorSpace(.deviceRGB))
                            let e = try #require(expected.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            let delta = Double(max(abs(a.redComponent - e.redComponent),
                                                   abs(a.greenComponent - e.greenComponent),
                                                   abs(a.blueComponent - e.blueComponent),
                                                   abs(a.alphaComponent - e.alphaComponent)))
                            error = max(error, delta)
                            if delta > 0 { differences += 1 }
                            if max(abs(background.redComponent - e.redComponent),
                                   abs(background.greenComponent - e.greenComponent),
                                   abs(background.blueComponent - e.blueComponent)) > 0.1 {
                                ink[index] += 1
                            }
                        }
                    }
                    try #require(ink[index] > region.minimumInk, "Blank or incomplete literal reference")
                }
                if error < best || (error == best && differences < differingPixels) {
                    best = error
                    differingPixels = differences
                    alignment = [dx, dy]
                    referenceInk = ink
                }
            }
        }
        let evidence: [String: Any] = [
            "maximumChannelDifference": best, "differingPixels": differingPixels,
            "alignmentPixels": alignment, "referenceInkPixels": referenceInk,
            "regionPixels": [Int(bounds.minX), Int(bounds.minY), Int(bounds.width), Int(bounds.height)], "tolerance": 0
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.deletingPathExtension().appendingPathExtension("pixels.json"))
        print("P46 exact pixels \(destination.lastPathComponent): \(evidence)")
        return best == 0
    }

    private func capture(_ view: NSView) throws -> NSBitmapImageRep {
        // Match the layout/copy renderers: unchanged point geometry, actual 2x native glyphs.
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width) * 2, pixelsHigh: Int(view.bounds.height) * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func views(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { views($0) }
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        view.layoutSubtreeIfNeeded()
    }
}
