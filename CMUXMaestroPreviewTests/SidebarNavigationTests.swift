import Foundation
import Testing
@_spi(CmuxHostTransport) import CmuxExtensionKit

@MainActor
struct SidebarNavigationTests {
    private let fixtures = SidebarTreeFixtures()

    @Test func seenCallbackRunsOnlyAfterSuccessfulCurrentNavigation() async {
        let recorder = SidebarHostRecorder()
        let model = SidebarConnectionModel()
        model.update(context: context(recorder: recorder))
        let target = SidebarNavigationTarget.surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA)
        var seen = 0
        model.navigation.select(target) { seen += 1 }
        await sidebarEventually { recorder.actions.count == 1 }
        #expect(seen == 0)
        recorder.reply(0, .rejected("not selected"))
        await sidebarEventually { model.navigation.status == .rejected }
        #expect(seen == 0)
        model.navigation.select(target) { seen += 1 }
        await sidebarEventually { recorder.actions.count == 2 }
        recorder.reply(1, .accepted)
        await sidebarEventually { model.navigation.status == .selected }
        #expect(seen == 1)
        model.navigation.select(target) { seen += 1 }
        await sidebarEventually { recorder.actions.count == 3 }
        model.setVisible(false)
        recorder.reply(2, .accepted)
        await Task.yield()
        #expect(seen == 1)
        model.navigation.select(.surface(workspaceID: fixtures.workspaceA, surfaceID: UUID())) { seen += 1 }
        #expect(seen == 1)
    }

    @Test func focusInteractionsRequireARealTransitionNotInitialMountOrPolling() {
        func hierarchy(focused: UUID) -> HierarchySnapshot {
            .init(
                sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
                workspaceMetadataAvailable: true, surfaceMetadataAvailable: true, workspacePathsAvailable: false,
                workspaces: [.init(
                    id: fixtures.workspaceA, title: .available("Workspace"), detail: .available(nil),
                    isSelected: .available(true), isPinned: .available(false), unreadCount: .available(0),
                    rootPath: .unavailable, projectRootPath: .unavailable,
                    surfaces: .available([fixtures.surfaceA, fixtures.surfaceB].map {
                        .init(id: $0, title: "Tab", kind: .terminal, isFocused: $0 == focused,
                              isPinned: false, unreadCount: 0, workingDirectory: .unavailable)
                    })
                )], windowID: fixtures.windowID
            )
        }
        let first = hierarchy(focused: fixtures.surfaceA)
        let second = hierarchy(focused: fixtures.surfaceB)
        #expect(SidebarPresentation.focusInteraction(from: .empty, to: first) == nil)
        #expect(SidebarPresentation.focusInteraction(from: first, to: first) == nil)
        #expect(SidebarPresentation.focusInteraction(from: first, to: second)
                == .surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceB))
    }

    @Test
    func navigationUsesTypedHostAndCurrentWorkspaceAfterSurfaceMove() async {
        let recorder = SidebarHostRecorder()
        let model = SidebarConnectionModel()
        model.update(context: context(recorder: recorder, moved: true))
        #expect(model.hierarchy.windowID == fixtures.windowID)
        model.navigation.select(.surface(workspaceID: fixtures.workspaceB, surfaceID: fixtures.surfaceA))
        await sidebarEventually { recorder.actions.count == 1 }
        #expect(recorder.actions[0] == .selectSurface(workspaceID: fixtures.workspaceB, surfaceID: fixtures.surfaceA))
        recorder.reply(0, .accepted)
        await sidebarEventually { model.navigation.status == .selected }

        model.navigation.select(.workspace(fixtures.workspaceA))
        await sidebarEventually { recorder.actions.count == 2 }
        #expect(recorder.actions[1] == .selectWorkspace(fixtures.workspaceA))
        recorder.reply(1, .accepted)
        await sidebarEventually { model.navigation.status == .selected }
    }

    @Test
    func deniedActionAndOffWindowTargetsNeverReachHost() async {
        let recorder = SidebarHostRecorder()
        let model = SidebarConnectionModel()
        model.update(context: context(recorder: recorder, actions: []))
        let target = SidebarNavigationTarget.surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA)
        #expect(model.navigation.disabledReason(for: target)?.contains("permission") == true)
        model.navigation.select(target)
        #expect(model.navigation.status == .denied)
        #expect(recorder.actions.isEmpty)

        model.update(context: context(recorder: recorder, sequence: 2))
        model.navigation.select(.surface(workspaceID: fixtures.workspaceA, surfaceID: UUID()))
        #expect(model.navigation.status == .staleTarget)
        #expect(recorder.actions.isEmpty)
        model.connectionStatusDidChange(.waitingForHost)
        model.navigation.select(target)
        #expect(model.navigation.status == .disconnected)
        #expect(recorder.actions.isEmpty)
        model.update(context: context(recorder: recorder, sequence: 3))
        #expect(model.navigation.status == .idle)
        #expect(model.navigation.disabledReason(for: target) == nil)
    }

    @Test
    func staleTargetReplyCannotOverrideTopologyChange() async {
        let recorder = SidebarHostRecorder()
        let model = SidebarConnectionModel()
        model.update(context: context(recorder: recorder))
        model.navigation.select(.surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA))
        await sidebarEventually { recorder.actions.count == 1 }
        model.update(context: context(recorder: recorder, moved: true, sequence: 2))
        recorder.reply(0, .accepted)
        await Task.yield()
        #expect(model.navigation.status == .staleTarget)
        #expect(model.navigation.disabledReason(for: .surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA)) != nil)
        #expect(model.navigation.disabledReason(for: .surface(workspaceID: fixtures.workspaceB, surfaceID: fixtures.surfaceA)) == nil)
    }

    @Test
    func rapidClicksIgnoreLateResponsesAndKeepLastExplicitTarget() async {
        let recorder = SidebarHostRecorder()
        let model = SidebarConnectionModel()
        model.update(context: context(recorder: recorder))
        model.navigation.select(.surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA))
        await sidebarEventually { recorder.actions.count == 1 }
        model.navigation.select(.surface(workspaceID: fixtures.workspaceB, surfaceID: fixtures.surfaceB))
        await sidebarEventually { recorder.actions.count == 2 }
        recorder.reply(1, .accepted)
        await sidebarEventually { model.navigation.status == .selected }
        recorder.reply(0, .rejected("private host detail"))
        await Task.yield()
        #expect(model.navigation.status == .selected)
        #expect(recorder.actions[1] == .selectSurface(workspaceID: fixtures.workspaceB, surfaceID: fixtures.surfaceB))
    }

    @Test
    func hostRejectionsCancellationAndDisconnectNeverExposeRawText() async {
        let recorder = SidebarHostRecorder()
        let model = SidebarConnectionModel()
        model.update(context: context(recorder: recorder))
        let target = SidebarNavigationTarget.workspace(fixtures.workspaceA)
        model.navigation.select(target)
        await sidebarEventually { recorder.actions.count == 1 }
        recorder.reply(0, .rejected("private host detail"))
        await sidebarEventually { model.navigation.status == .rejected }
        #expect(model.navigation.status.message?.contains("private") == false)
        model.navigation.select(target)
        await sidebarEventually { recorder.actions.count == 2 }
        recorder.reply(1, .cancelled)
        await sidebarEventually { model.navigation.status == .cancelled }
        model.navigation.select(target)
        await sidebarEventually { recorder.actions.count == 3 }
        model.connectionStatusDidChange(.error("private transport detail"))
        recorder.reply(2, .accepted)
        await Task.yield()
        #expect(model.navigation.status == .disconnected)
        #expect(model.navigation.status.message?.contains("private") == false)
    }

    @Test
    func permissionRevocationAndHideInvalidatePendingNavigation() async {
        let recorder = SidebarHostRecorder()
        let model = SidebarConnectionModel()
        model.update(context: context(recorder: recorder))
        let target = SidebarNavigationTarget.workspace(fixtures.workspaceA)
        model.navigation.select(target)
        await sidebarEventually { recorder.actions.count == 1 }
        model.update(context: context(recorder: recorder, sequence: 2, actions: []))
        recorder.reply(0, .accepted)
        await Task.yield()
        #expect(model.navigation.status == .staleTarget)
        #expect(model.navigation.disabledReason(for: target) != nil)

        model.update(context: context(recorder: recorder, sequence: 3))
        model.navigation.select(target)
        await sidebarEventually { recorder.actions.count == 2 }
        model.setVisible(false)
        recorder.reply(1, .accepted)
        await Task.yield()
        #expect(model.navigation.status == .cancelled)
    }

    @Test
    func lateHostSnapshotCannotUndoCurrentPlacement() {
        let recorder = SidebarHostRecorder()
        let model = SidebarConnectionModel()
        model.update(context: context(recorder: recorder, moved: true, sequence: 10))
        model.update(context: context(recorder: recorder, sequence: 9))
        #expect(SidebarTopology(model.hierarchy).workspaceBySurface[fixtures.surfaceA] == fixtures.workspaceB)
    }

    @Test
    func redactedWindowDoesNotResetOrderingOrRestoreRevokedPolling() async {
        let recorder = SidebarHostRecorder()
        let reads = SidebarTopologyReadProbe()
        let polling = SidebarCopilotPolling(
            read: { await reads.read($0) }, pause: { try await Task.sleep(for: .seconds(60)) }
        )
        let model = SidebarConnectionModel(copilot: polling)
        model.setVisible(true)
        let granted = context(recorder: recorder, sequence: 10)
        model.update(context: granted)
        await sidebarEventually { await reads.calls == 1 }

        model.update(context: context(recorder: recorder, sequence: 11, granted: false))
        #expect(model.hierarchy.sequence == 11)
        #expect(model.hierarchy.windowID == nil)
        #expect(!model.hierarchy.surfaceMetadataAvailable)
        #expect(polling.tree.availability == .waiting)
        await sidebarEventually { !polling.isReading }

        model.connectionStatusDidChange(.connected)
        model.update(context: granted)
        await Task.yield()
        #expect(model.hierarchy.sequence == 11)
        #expect(model.hierarchy.windowID == nil)
        #expect(SidebarTopology(model.hierarchy).workspaceBySurface.isEmpty)
        #expect(polling.tree.availability == .waiting)
        #expect(await reads.calls == 1)
        #expect(model.navigation.disabledReason(
            for: .surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA)
        ) != nil)

        model.connectionStatusDidChange(.error("Transient snapshot error"))
        model.connectionStatusDidChange(.connected)
        model.update(context: granted)
        #expect(model.hierarchy.sequence == 11)
        #expect(await reads.calls == 1)

        model.update(context: context(recorder: recorder, sequence: 12))
        await sidebarEventually { await reads.calls == 2 }
        #expect(model.hierarchy.windowID == fixtures.windowID)
        #expect(model.hierarchy.surfaceMetadataAvailable)
        model.setVisible(false)
    }

    @Test
    func onlyDisconnectedHostStartsNewSnapshotOrderingGeneration() async {
        let recorder = SidebarHostRecorder()
        let reads = SidebarTopologyReadProbe()
        let polling = SidebarCopilotPolling(
            read: { await reads.read($0) }, pause: { try await Task.sleep(for: .seconds(60)) }
        )
        let model = SidebarConnectionModel(copilot: polling)
        model.setVisible(true)
        model.update(context: context(recorder: recorder, sequence: 20))
        await sidebarEventually { await reads.calls == 1 }
        let nextWindow = UUID()

        model.update(context: context(recorder: recorder, sequence: 1, windowID: nextWindow))
        #expect(model.hierarchy.sequence == 20)
        #expect(model.hierarchy.windowID == fixtures.windowID)
        #expect(await reads.calls == 1)

        model.connectionStatusDidChange(.waitingForHost)
        model.connectionStatusDidChange(.connected)
        model.update(context: context(recorder: recorder, sequence: 1))
        await sidebarEventually { await reads.calls == 2 }
        #expect(model.hierarchy.sequence == 1)
        #expect(model.hierarchy.windowID == fixtures.windowID)

        model.connectionStatusDidChange(.waitingForHost)
        model.update(context: context(recorder: recorder, sequence: 0, windowID: nextWindow))
        await sidebarEventually { await reads.calls == 3 }
        #expect(model.hierarchy.sequence == 0)
        #expect(model.hierarchy.windowID == nextWindow)
        model.setVisible(false)
    }

    @Test
    func unresponsiveNavigationTimesOutWithoutWaitingForCancelledHostWork() async {
        let navigation = SidebarNavigation(timeout: { try await Task.sleep(for: .milliseconds(15)) })
        let reply = SidebarNavigationGate()
        navigation.update(
            topology: fixtures.topology(), connected: true, workspaceAllowed: true, surfaceAllowed: true,
            perform: { _ in await reply.wait() }
        )
        navigation.select(.workspace(fixtures.workspaceA))
        await sidebarEventually { navigation.status == .timedOut }
        await reply.finish()
        await Task.yield()
        #expect(navigation.status == .timedOut)
        navigation.update(
            topology: fixtures.topology(), connected: true, workspaceAllowed: true, surfaceAllowed: true,
            perform: { _ in }
        )
        navigation.select(.workspace(fixtures.workspaceB))
        await sidebarEventually { navigation.status == .selected }
    }

    @Test
    func realSDKFilteringGatesPresentedWorktreePathsWithoutWorkspaceList() throws {
        let model = SidebarConnectionModel()
        let host = CmuxSidebarHost(performAction: { _, _ in })
        let allowed: Set<CmuxExtensionScope> = [.workspaceMetadata, .surfaceMetadata, .workspacePaths]
        let filtered = pathSnapshot().filtered(for: allowed)
        model.update(context: CmuxSidebarContext(snapshot: filtered, host: host))
        #expect(!filtered.grantedReadScopes.contains(.workspaceList))
        #expect(model.hierarchy.workspaceListAvailable)
        let visible = model.hierarchy.pathContext(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA)
        #expect(visible.rootPath == .available("/repo/.worktrees/feature"))
        #expect(visible.projectRootPath == .available("/repo"))
        #expect(visible.workingDirectory == .available("/repo/.worktrees/feature/src"))
        #expect(visible.workingDirectory.pathDisplayText == "/repo/.worktrees/feature/src")
        #expect(visible.accessibilityDescription.contains("Workspace: /repo/.worktrees/feature"))

        let denied = pathSnapshot(sequence: 2).filtered(for: [.workspaceMetadata, .surfaceMetadata])
        #expect(denied.workspaces[0].rootPath == nil)
        #expect(denied.workspaces[0].projectRootPath == nil)
        #expect(denied.workspaces[0].surfaces[0].workingDirectory == nil)
        model.update(context: CmuxSidebarContext(snapshot: denied, host: host))
        let hidden = model.hierarchy.pathContext(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA)
        #expect(hidden == .unavailable)
        #expect(hidden.workingDirectory.pathDisplayText == "Path unavailable")
        #expect(!hidden.accessibilityDescription.contains("/repo"))
    }

    @Test
    func realSDKGrantedNilPathsRemainDistinctFromUnavailable() {
        let model = SidebarConnectionModel()
        let filtered = pathSnapshot(hasPaths: false).filtered(
            for: [.workspaceMetadata, .surfaceMetadata, .workspacePaths]
        )
        model.update(context: CmuxSidebarContext(
            snapshot: filtered, host: CmuxSidebarHost(performAction: { _, _ in })
        ))
        let paths = model.hierarchy.pathContext(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA)
        #expect(paths.rootPath == .available(nil))
        #expect(paths.projectRootPath == .available(nil))
        #expect(paths.workingDirectory == .available(nil))
        #expect(paths.workingDirectory.pathDisplayText == "No path shared")
        #expect(paths != .unavailable)
        #expect(!paths.accessibilityDescription.contains("unavailable"))
    }

    @Test
    func sessionPathPresentationUsesCurrentSurfacePlacementNotLaunchWorkspace() {
        var raw = pathSnapshot()
        let movedSurface = raw.workspaces[0].surfaces[0]
        raw.workspaces[0].surfaces = []
        raw.workspaces.append(CmuxSidebarWorkspace(
            id: fixtures.workspaceB, title: "Current worktree",
            rootPath: "/repo/.worktrees/current", projectRootPath: "/repo",
            surfaces: [movedSurface]
        ))
        let model = SidebarConnectionModel()
        model.update(context: CmuxSidebarContext(
            snapshot: raw.filtered(for: [.workspaceMetadata, .surfaceMetadata, .workspacePaths]),
            host: CmuxSidebarHost(performAction: { _, _ in })
        ))
        let now = Date()
        let tree = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [fixtures.session(now: now)], now: now),
            onto: SidebarTopology(model.hierarchy), now: now
        )
        #expect(tree.sessions.first?.workspaceID == fixtures.workspaceB)
        let presented = model.hierarchy.pathContext(workspaceID: fixtures.workspaceB, surfaceID: fixtures.surfaceA)
        #expect(presented.rootPath == .available("/repo/.worktrees/current"))
        #expect(presented.workingDirectory == .available("/repo/.worktrees/feature/src"))
        #expect(model.hierarchy.pathContext(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA) == .unavailable)
    }

    @Test
    func pathPermissionAndPresentationRemainWiredInBothModes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try String(
            contentsOf: root.appendingPathComponent("CMUXMaestroSidebar/Extension/CMUXMaestroSidebarExtension.swift"),
            encoding: .utf8
        )
        #expect(manifest.contains(".workspacePaths,"))
        #expect(!manifest.contains(".workspaceList,"))
        let view = try String(
            contentsOf: root.appendingPathComponent("CMUXMaestroSidebar/UI/SidebarView.swift"),
            encoding: .utf8
        )
        #expect(view.contains("selection = .workspace(workspace.id)"))
        #expect(view.contains("selection = .surface(workspaceID: workspaceID, surfaceID: surface.id)"))
        #expect(view.contains(".init(title: \"Workspace path\", value: workspace.rootPath.pathDisplayText)"))
        #expect(view.contains(".init(title: \"Project path\", value: workspace.projectRootPath.pathDisplayText)"))
        #expect(view.contains(".init(title: \"Working directory\", value: surface.workingDirectory.pathDisplayText)"))
        #expect(view.contains("SidebarPresentation.paths(paths)"))
        #expect(view.contains("UnmanagedSelectionDetails("))
    }

    private func pathSnapshot(sequence: UInt64 = 1, hasPaths: Bool = true) -> CmuxSidebarSnapshot {
        CmuxSidebarSnapshot(
            sequence: sequence, windowID: fixtures.windowID, selectedWorkspaceID: fixtures.workspaceA,
            workspaces: [
                CmuxSidebarWorkspace(
                    id: fixtures.workspaceA, title: "Feature worktree",
                    rootPath: hasPaths ? "/repo/.worktrees/feature" : nil,
                    projectRootPath: hasPaths ? "/repo" : nil,
                    surfaces: [
                        CmuxSidebarSurface(
                            id: fixtures.surfaceA, title: "Terminal", kind: .terminal,
                            workingDirectory: hasPaths ? "/repo/.worktrees/feature/src" : nil
                        ),
                    ]
                ),
            ]
        )
    }

    private func context(
        recorder: SidebarHostRecorder,
        moved: Bool = false,
        sequence: UInt64 = 1,
        actions: Set<CmuxExtensionActionScope> = [.selectWorkspace, .selectSurface],
        granted: Bool = true,
        windowID: UUID? = nil
    ) -> CmuxSidebarContext {
        CmuxSidebarContext(
            snapshot: CmuxSidebarSnapshot(
                sequence: sequence,
                windowID: granted ? windowID ?? fixtures.windowID : nil,
                selectedWorkspaceID: fixtures.workspaceA,
                grantedReadScopes: granted ? [.workspaceMetadata, .surfaceMetadata] : [],
                grantedActionScopes: granted ? actions : [],
                workspaces: granted ? [
                    CmuxSidebarWorkspace(
                        id: fixtures.workspaceA, title: "Same workspace",
                        surfaces: moved ? [] : [CmuxSidebarSurface(id: fixtures.surfaceA, title: "Same surface", kind: .terminal)]
                    ),
                    CmuxSidebarWorkspace(
                        id: fixtures.workspaceB, title: "Same workspace",
                        surfaces: (moved ? [fixtures.surfaceA, fixtures.surfaceB] : [fixtures.surfaceB]).map {
                            CmuxSidebarSurface(id: $0, title: "Same surface", kind: .terminal)
                        }
                    ),
                ] : []
            ),
            host: CmuxSidebarHost(performAction: { action, reply in recorder.record(action, reply: reply) })
        )
    }
}

@MainActor
private final class SidebarHostRecorder {
    private(set) var actions: [CmuxSidebarAction] = []
    private var replies: [Int: @MainActor @Sendable (CmuxSidebarActionResult) -> Void] = [:]

    func record(_ action: CmuxSidebarAction, reply: @escaping @MainActor @Sendable (CmuxSidebarActionResult) -> Void) {
        replies[actions.count] = reply
        actions.append(action)
    }

    func reply(_ index: Int, _ result: CmuxSidebarActionResult) {
        replies.removeValue(forKey: index)?(result)
    }
}

private actor SidebarNavigationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SidebarTopologyReadProbe {
    private(set) var calls = 0
    func read(_ surfaceIDs: Set<UUID>) -> CopilotSnapshot {
        calls += 1
        return CopilotSnapshot(generatedAt: Date(), sessions: [], issues: [], isComplete: true)
    }
}
