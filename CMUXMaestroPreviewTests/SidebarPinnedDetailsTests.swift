import AppKit
import SwiftUI
import Testing
@_spi(CmuxHostTransport) import CmuxExtensionKit

@MainActor
private final class RetainedMenuSource {
    var node: SidebarOrchestrationNode
    let evidence: AgentAttention
    let date: Date

    init(node: SidebarOrchestrationNode, evidence: AgentAttention, date: Date) {
        self.node = node
        self.evidence = evidence
        self.date = date
    }

    var managed: SidebarOrchestrationSnapshot {
        .init(version: 1, generatedAt: date, complete: true, omittedCount: 0, nodes: [node])
    }

    var observed: CopilotSnapshot {
        .init(generatedAt: date, sessions: [
            .init(sessionID: node.copilotSessionId!, surfaceID: node.surfaceId, launchWorkspaceID: node.workspaceId,
                  liveness: .alive, state: .idle, model: "retained-menu-model", children: [], observedAt: date,
                  attention: [evidence])
        ], issues: [], isComplete: true)
    }
}

@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarPinnedDetailsTests {
    private let fixtures = SidebarTreeFixtures()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func hierarchy(
        active: UUID? = nil, kind: HierarchySurfaceKind = .terminal,
        focused: Bool = true, duplicateFocus: Bool = false, duplicateID: Bool = false,
        granted: Bool = true, paths: Bool = true
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
                    workingDirectory: paths ? .available("/synthetic/worktree-\(index)") : .unavailable
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
        id: UUID? = nil, other: Bool = false, liveness: CopilotLiveness = .alive,
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
        #expect(pinned(hierarchy(paths: false)).lines.contains(.init(title: "Working directory", value: "Path unavailable")))
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
            #expect(content.lines.contains(.init(title: "Branch", value: "feat/pinned-details")))
            #expect(content.lines.contains(.init(title: "Worktree", value: "pinned-46")))
            #expect(content.gitChanges == node.gitChanges)
            #expect(!content.lines.contains { $0.value.contains("ended-model") || $0.value.contains(fixture.sessionID.uuidString) })

            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            var copied: [UUID] = []
            var inspections = 0
            let hosting = NSHostingView(rootView: SidebarPinnedFooter(
                content: content, inspect: { inspections += 1 },
                copySessionID: { copied.append($0); return SidebarSessionCopy.copy($0, to: pasteboard) }
            ).frame(width: 300))
            hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 220)
            try await settle(hosting)
            let buttons = views(hosting).compactMap { $0 as? NSButton }
                .filter { $0.accessibilityIdentifier() == "hover-copy-value" }
            #expect(buttons.count == 1)
            #expect(try #require(buttons.first).accessibilityPerformPress())
            #expect(copied == [replacementID] && inspections == 0)
            #expect(pasteboard.string(forType: .string) == replacementID.uuidString)
        }
    }

    @Test func managedIdentityRequiresCurrentUniqueBindingAndNeverBorrowsFromReusedSurface() {
        let node = managed()
        let result = pinned(nodes: [node])
        #expect(result.title == node.label && result.isAgent)
        #expect(result.lines.contains(.init(title: "Branch", value: "feat/pinned-details")))
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
        #expect(staleGit.lines.contains { $0.title == "Git evidence" && $0.value.hasPrefix("Stale") })
        #expect(staleGit.lines.contains(.init(title: "Git changes", value: "Current counts unavailable")))
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

    @Test(arguments: ["unchanged", "generation", "run", "session", "workspace", "surface"], SidebarMode.allCases)
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
                generation: replaced && change == "generation" ? 2 : 1,
                phase: "turn-running", availability: "busy",
                copilotSessionId: replaced && change == "session" ? fixtures.otherSessionID : fixtures.sessionID,
                executionMode: .interactive, createdAt: date, updatedAt: date
            )
        }
        let original = node(replaced: false), replacement = node(replaced: true)
        let evidence = AgentAttention(kind: .turnFinished,
                                      evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: date)
        let source = RetainedMenuSource(node: original, evidence: evidence, date: date)
        let orchestration = SidebarOrchestrationPolling(
            read: { await source.managed }, pause: { try await Task.sleep(for: .seconds(60)) }
        )
        let polling = SidebarCopilotPolling(
            read: { _ in await source.observed }, pause: { try await Task.sleep(for: .seconds(60)) },
            expiryPause: sidebarFrozenExpiry, now: { date }
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
        let showActions = try #require(title.showActions)
        showActions()
        let menu = try #require(capturedMenu)
        let item = try #require(menu.items.flatMap { $0.submenu?.items ?? [] }.first { $0.title == "Open details" })
        let presenter = try #require(item.target as? SidebarRowMenuPresenter)
        #expect(item.isEnabled && preferences.attention.acknowledged.isEmpty && nativeActions.isEmpty)

        source.node = replacement
        model.setVisible(false)
        refreshHierarchy(moved: change == "workspace")
        model.setVisible(true)
        await sidebarEventually {
            orchestration.snapshot.nodes == [replacement] && polling.tree.sessions.first?.id == replacement.copilotSessionId
                && polling.tree.attentionOwnerCount == 1
        }
        try await settle(hosting)
        let pinnedBefore = SidebarPresentation.pinnedDetails(
            hierarchy: model.hierarchy, connected: true, tree: polling.tree,
            managed: orchestration.snapshot, availability: orchestration.availability, now: date
        )
        #expect(preferences.attention.acknowledged.isEmpty && nativeActions.isEmpty)
        #expect(item.target === presenter)
        #expect(NSApp.sendAction(try #require(item.action), to: presenter, from: item))
        try await Task.sleep(for: .milliseconds(100))
        let inspectorWindows = window.childWindows ?? []
        let inspectorViews = inspectorWindows.compactMap(\.contentView).flatMap { [$0] + views($0) }
        let copyControls = inspectorViews.compactMap { $0 as? NSButton }
            .filter { $0.accessibilityIdentifier() == "hover-copy-value" }
        #expect(!inspectorWindows.isEmpty, "Production inspection must show details or its explicit unavailable state")
        let fields = inspectorViews.compactMap { ($0 as? NSTextField)?.stringValue }
        let panelContent = try #require(inspectorWindows.first?.contentView)
        panelContent.layoutSubtreeIfNeeded()
        let bitmap = try #require(panelContent.bitmapImageRepForCachingDisplay(in: panelContent.bounds))
        panelContent.cacheDisplay(in: panelContent.bounds, to: bitmap)
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/polish/remediation2")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let capture = folder.appendingPathComponent("retained-menu-\(mode.rawValue)-\(change).png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: capture)
        let text = try SidebarRenderingEvidence.recognizedNativeLines(in: capture)
        if change == "unchanged" {
            #expect(copyControls.count == 1)
            #expect(fields.contains(fixtures.sessionID.uuidString))
            #expect(preferences.attention.acknowledged == [
                .init(sessionID: fixtures.sessionID, ownerID: nil, evidence: evidence.evidence)
            ])
        } else {
            #expect(copyControls.isEmpty, "A retained action must not inspect a replacement session")
            #expect(text.contains("Details no longer available"), "\(text)")
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
    }

    @Test func footerRendersNativeLightDarkNarrowShortAndCopiesWithoutInspection() async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var inspections = 0
        var copies: [UUID] = []
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
                                            copySessionID: { copies.append($0); return SidebarSessionCopy.copy($0, to: pasteboard) })
                        Spacer(minLength: 50)
                    }
                    .padding(10)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor)))
                    window.contentView = hosting
                    defer { window.contentView = nil; window.close() }
                    try await settle(hosting)
                    #expect(!window.isVisible && inspections == 0)
                    let buttons = views(hosting).compactMap { $0 as? NSButton }
                        .filter { $0.accessibilityIdentifier() == "hover-copy-value" }
                    let button = try #require(buttons.first)
                    #expect(buttons.count == 1)
                    #expect(button.acceptsFirstResponder && button.accessibilityLabel() == "Copy session ID")
                    #expect(button.accessibilityPerformPress())
                    try await settle(hosting)
                    #expect(button.accessibilityValue() as? String == "Copied")
                    #expect(pasteboard.string(forType: .string) == fixtures.sessionID.uuidString)
                    let feedback = try #require(views(hosting).compactMap { $0 as? NSTextField }
                        .first { $0.accessibilityIdentifier() == "hover-copy-feedback" })
                    #expect(feedback.stringValue == "Copied" && feedback.accessibilityValue() == "Copied")
                    let drawing = feedback.alignmentRect(forFrame: feedback.bounds)
                    #expect(drawing.height > 0 && feedback.visibleRect.contains(drawing))
                    let viewport = try #require(feedback.enclosingScrollView?.contentView)
                    #expect(viewport.bounds.contains(viewport.convert(drawing, from: feedback)))
                    let bitmap = try capture(hosting)
                    #expect(bitmap.pixelsWide == Int(width) * 2 && bitmap.pixelsHigh == Int(height + 70) * 2)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    let destination = folder.appendingPathComponent(
                        "pinned46-\(dark ? "dark" : "light")-\(Int(width))x\(Int(height)).png"
                    )
                    try png.write(to: destination)
                    let text = try SidebarRenderingEvidence.recognizedNativeLines(in: destination)
                    #expect(text.contains { $0.contains("Verified agent") },
                            "\(destination.lastPathComponent): \(text)")
                    #expect(text.contains("verified-model"),
                            "\(destination.lastPathComponent): \(text)")
                    #expect(text.contains("Copied"),
                            "\(destination.lastPathComponent): \(text)")
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
    func footerRenderEvidenceRejectsWrongMissingHiddenAndClippedModels(dark: Bool) async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for control in ["visible", "wrong", "missing", "hidden", "clipped"] {
            var content = pinned(nodes: [managed()])
            if control == "wrong" || control == "missing" {
                content.lines.removeAll { $0.title == "Model" }
                if control == "wrong" { content.lines.append(.init(title: "Model", value: "verifled-model")) }
            }
            let frame = NSRect(x: 0, y: 0, width: 240, height: 214)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: VStack {
                SidebarPinnedFooter(content: content, maximumHeight: 144,
                                    inspect: { Issue.record("Rendering must not inspect") },
                                    copySessionID: { _ in Issue.record("Rendering must not copy"); return false })
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
            #expect(text.contains("verified-model") == (control == "visible"),
                    "\(destination.lastPathComponent): \(text)")
            #expect(!text.contains("Copied"), "\(destination.lastPathComponent): \(text)")
            if control != "hidden" {
                #expect(text.contains("Verified agent"), "\(destination.lastPathComponent): \(text)")
            }
        }
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
        try #require(expected.pixelsWide == actual.pixelsWide && expected.pixelsHigh == actual.pixelsHigh)
        try #require(left > 0 && top > 0 && right < actual.pixelsWide && bottom < actual.pixelsHigh)
        let background = try #require(expected.colorAt(x: right - 1, y: middle)?.usingColorSpace(.deviceRGB))
        var best = Double.infinity
        var differingPixels = Int.max
        var alignment = [0, 0]
        var referenceInk = [0, 0]
        for dy in -1...1 {
            for dx in -1...1 {
                var error = 0.0, differences = 0
                var ink = [0, 0]
                for y in top..<bottom {
                    for x in left..<right {
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
                            ink[y < middle ? 0 : 1] += 1
                        }
                    }
                }
                try #require(ink[0] > 20 && ink[1] > 100, "Blank or incomplete literal reference")
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
            "regionPixels": [left, top, right - left, bottom - top], "tolerance": 0
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
