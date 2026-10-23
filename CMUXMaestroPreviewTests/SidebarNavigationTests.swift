import Foundation
import Testing
@_spi(CmuxHostTransport) import CmuxExtensionKit

@MainActor
struct SidebarNavigationTests {
    private let fixtures = SidebarTreeFixtures()

    @Test func registeredCoordinatorKeepsValidatedSurfaceNavigation() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let node = SidebarOrchestrationNode(
            id: fixtures.surfaceB, runId: fixtures.workspaceB, parentId: nil, role: "coordinator",
            label: "Coordinator", workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA,
            generation: 0, phase: "registered", availability: "idle", createdAt: date, updatedAt: date
        )
        let tree = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [fixtures.session(now: date)], now: date),
            onto: fixtures.topology(), now: date
        )
        let target = SidebarNavigationTarget.surface(workspaceID: node.workspaceId, surfaceID: node.surfaceId)
        #expect(SidebarPresentation.focusTarget(
            for: .managed(node), capturedPlacement: target, hierarchy: fixtures.hierarchy(), connected: true,
            tree: tree, managed: .init(version: 1, generatedAt: date, complete: true, omittedCount: 0, nodes: [node]),
            availability: .ready, now: date
        ) == target, "Both primary click and the Focus surface action must retain registration navigation")
    }

    @Test func endedManagedFocusUsesExactSurfaceWithoutDetails() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let node = endedNode(now: date)
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: date, complete: true, omittedCount: 0, nodes: [node]
        )
        let target = SidebarNavigationTarget.surface(workspaceID: node.workspaceId, surfaceID: node.surfaceId)
        let tree = SidebarCopilotTree(availability: .ready, sessions: [], issues: [], generatedAt: date)
        let recorder = SidebarHostRecorder()
        let model = responseOrderingModel()
        model.update(context: context(recorder: recorder))
        // Details can be unavailable while an exact terminal remains navigable.
        let resolved = try #require(SidebarPresentation.focusTarget(
            for: .managed(node), capturedPlacement: target, hierarchy: model.hierarchy,
            connected: true, tree: tree, managed: snapshot, availability: .unavailable, now: date
        ))
        #expect(resolved == target)
        SidebarRowAction.focus(resolved, navigation: model.navigation, prepareSeen: { _ in {} }).perform()
        await sidebarEventually { recorder.actions.count == 1 }
        #expect(recorder.actions == [.selectSurface(workspaceID: node.workspaceId, surfaceID: node.surfaceId)])
        recorder.reply(0, .accepted)
        await sidebarEventually { model.navigation.status == .selected }
    }

    @Test(arguments: [false, true])
    func endedManagedSurfaceRevertsWithoutArchiving(showEnded: Bool) throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let node = endedNode(now: date)
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: date, complete: true, omittedCount: 0, nodes: [node]
        )
        let tree = SidebarCopilotTree(availability: .ready, sessions: [], issues: [], generatedAt: date)
        let hierarchy = fixtures.hierarchy()
        let ended = SidebarPresentation.endedManagedNodeIDs(
            managed: snapshot, availability: .ready, hierarchy: hierarchy, observations: tree, now: date,
            showEnded: showEnded
        )
        #expect(ended == (showEnded ? [] : [node.id]))
        let visible = SidebarVisibleWork(
            tree: tree, managed: snapshot.nodes, history: .init(), showEnded: showEnded,
            now: date, displacedNodeIDs: ended
        )
        #expect(visible.managed == (showEnded ? [node] : []))
        #expect(visible.hiddenSurfaces.isEmpty)
        let workspace = try #require(hierarchy.workspaces.first { $0.id == node.workspaceId })
        guard case .available(let surfaces) = workspace.surfaces else {
            Issue.record("Expected synthetic surfaces"); return
        }
        #expect(SidebarPresentation.unmanagedSurfaces(
            surfaces, workspaceID: node.workspaceId, managed: visible.managed,
            observations: visible.tree, now: date
        ).contains { $0.id == node.surfaceId } == !showEnded)
        #expect(snapshot.nodes == [node], "Presentation must not archive controller history")
        #expect(SidebarPresentation.endedManagedNodeIDs(
            managed: snapshot, availability: .ready, hierarchy: .empty, observations: tree, now: date
        ).isEmpty, "Missing surfaces retain the existing ended-history policy")
    }

    private func endedNode(
        now: Date, generation: Int = 1, phase: String = "process-disappeared", role: String = "coordinator"
    ) -> SidebarOrchestrationNode {
        .init(id: fixtures.surfaceB, runId: fixtures.workspaceB, parentId: nil,
              role: role, label: "Copilot session",
              workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA,
              generation: generation, phase: phase, availability: "unavailable",
              copilotSessionId: fixtures.sessionID, executionMode: .interactive,
              createdAt: now, updatedAt: now)
    }

    @Test(arguments: ["live", "unknown", "ambiguous", "stale", "denied", "missing", "generation", "replacement"])
    func endedSurfaceReversionAndFocusPreserveEvidenceBarriers(_ scenario: String) {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let captured = endedNode(now: date)
        let current = endedNode(now: date, generation: scenario == "generation" ? 2 : 1,
                                phase: scenario == "live" ? "turn-running" : "process-disappeared")
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: scenario == "stale" ? date.addingTimeInterval(-120) : date,
            complete: true, omittedCount: 0, nodes: [current]
        )
        let liveness: AgentProcessLiveness = switch scenario {
        case "unknown": .unknown
        case "ambiguous": .ambiguous
        default: .alive
        }
        let session = SidebarCopilotSession(
            id: scenario == "replacement" ? fixtures.otherSessionID : fixtures.sessionID,
            workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA, liveness: liveness,
            state: .idle, model: nil, observedAt: date, nodes: [], childrenComplete: true,
            treeDegraded: false, omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
        let tree = SidebarCopilotTree(
            availability: .ready, sessions: ["live", "unknown", "ambiguous", "replacement"].contains(scenario) ? [session] : [],
            issues: scenario == "denied" ? [.permissionDenied] : [], generatedAt: date
        )
        let hierarchy = scenario == "missing" ? HierarchySnapshot.empty : fixtures.hierarchy()
        let ended = SidebarPresentation.endedManagedNodeIDs(
            managed: snapshot, availability: .ready, hierarchy: hierarchy, observations: tree, now: date
        )
        if scenario != "generation" { #expect(ended.isEmpty) }
        let target = SidebarNavigationTarget.surface(workspaceID: captured.workspaceId, surfaceID: captured.surfaceId)
        let resolved = SidebarPresentation.focusTarget(
            for: .managed(captured), capturedPlacement: target, hierarchy: hierarchy, connected: true,
            tree: tree, managed: snapshot, availability: .ready, now: date
        )
        #expect(resolved == (["missing", "generation", "replacement"].contains(scenario) ? nil : target))
    }

    @Test(arguments: ["observation", "process", "wrong-generation"])
    func verifiedProcessEndReleasesRowAndRetainsLiveDescendants(_ source: String) {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let node = endedNode(now: date, phase: "turn-running")
        let child = SidebarOrchestrationNode(
            id: UUID(), runId: node.runId, parentId: node.id, role: "worker", label: "Live child",
            workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceB, generation: 1,
            phase: "turn-running", availability: "busy", copilotSessionId: fixtures.otherSessionID,
            executionMode: .interactive, createdAt: date, updatedAt: date
        )
        var snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: date, complete: true, omittedCount: 0, nodes: [node, child]
        )
        let session = SidebarCopilotSession(
            id: fixtures.sessionID, workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA,
            liveness: .dead, state: .unknown, model: nil, observedAt: date, nodes: [],
            childrenComplete: true, treeDegraded: false, omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
        let tree = SidebarCopilotTree(
            availability: .ready, sessions: source == "observation" ? [session] : [], issues: [], generatedAt: date
        )
        if source != "observation" {
            snapshot.processes[node.id] = .init(
                nodeId: node.id, copilotSessionId: fixtures.sessionID, generation: source == "wrong-generation" ? 2 : 1,
                state: "exited", observedAt: date, processes: [], omittedCount: 0
            )
        }
        let ended = SidebarPresentation.endedManagedNodeIDs(
            managed: snapshot, availability: .ready, hierarchy: fixtures.hierarchy(), observations: tree, now: date
        )
        if source == "wrong-generation" {
            #expect(ended.isEmpty)
            return
        }
        #expect(ended == [node.id])
        let visible = SidebarVisibleWork(
            tree: tree, managed: snapshot.nodes, history: .init(), showEnded: false,
            now: date, displacedNodeIDs: ended
        )
        #expect(visible.managed == [child])
        #expect(visible.tree.sessions.isEmpty, "The ended observation must not reappear as an unmanaged agent")
        #expect(visible.hiddenSurfaces.isEmpty)
    }

    @Test(arguments: ["turn-failed", "startup-failed", "reported-failed", "launch-failed",
                      "reported-blocked", "session-error", "session-failed", "permission",
                      "failed-child", "blocked-child", "internal-task", "incomplete"])
    func endedSurfaceKeepsProtectedOutcomesAndFocus(_ scenario: String) throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let failure = SidebarDismissedManagedOutcome(nodeID: fixtures.surfaceB, generation: 1, phase: scenario)
        let phase = failure.isValid || scenario == "reported-blocked" ? scenario : "process-disappeared"
        let node = endedNode(now: date, phase: phase, role: failure.isValid ? "worker" : "coordinator")
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: date, complete: true, omittedCount: 0, nodes: [node]
        )
        var session = SidebarCopilotSession(
            id: fixtures.sessionID, workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA,
            liveness: .dead, state: scenario == "session-failed" ? .failed : .unknown,
            model: nil, observedAt: date, nodes: [], childrenComplete: scenario != "incomplete",
            treeDegraded: false, omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
        if scenario == "session-error" || scenario == "permission" {
            session.attention = [.init(
                kind: scenario == "session-error" ? .error : .permission,
                evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: date
            )]
        }
        if ["failed-child", "blocked-child", "internal-task"].contains(scenario) {
            session.nodes = [.init(
                id: "protected", parentID: nil, depth: 0, kind: .subagent, name: "Protected task",
                state: scenario == "internal-task" ? .idle : scenario == "blocked-child" ? .blocked : .failed, model: nil,
                ancestryUnresolved: false, hasChildren: false
            )]
            if scenario == "internal-task" {
                session.nodes[0].observedParent = .session(.init(providerID: "copilot", sessionID: fixtures.sessionID.uuidString))
            }
        }
        let tree = SidebarCopilotTree(availability: .ready, sessions: [session], issues: [], generatedAt: date)
        let ended = SidebarPresentation.endedManagedNodeIDs(
            managed: snapshot, availability: .ready, hierarchy: fixtures.hierarchy(), observations: tree, now: date
        )
        #expect(ended.isEmpty)
        let visible = SidebarVisibleWork(
            tree: tree, managed: [node], history: .init(), showEnded: false, now: date, displacedNodeIDs: ended
        )
        #expect(visible.managed == [node])
        if ["session-error", "permission", "failed-child", "blocked-child", "internal-task"].contains(scenario) {
            #expect(visible.tree.sessions == [session])
        }
        let target = SidebarNavigationTarget.surface(workspaceID: node.workspaceId, surfaceID: node.surfaceId)
        #expect(SidebarPresentation.focusTarget(
            for: .managed(node), capturedPlacement: target, hierarchy: fixtures.hierarchy(), connected: true,
            tree: tree, managed: snapshot, availability: .ready, now: date
        ) == target)
    }

    @Test(arguments: [1, 2])
    func onlyExactDismissedFailureMayReleaseEndedTerminal(_ dismissedGeneration: Int) {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let node = endedNode(now: date, phase: "turn-failed", role: "worker")
        let session = SidebarCopilotSession(
            id: fixtures.sessionID, workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA,
            liveness: .dead, state: .unknown, model: nil, observedAt: date, nodes: [],
            childrenComplete: true, treeDegraded: false, omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
        let tree = SidebarCopilotTree(availability: .ready, sessions: [session], issues: [], generatedAt: date)
        var history = SidebarHistorySettings()
        history.dismissedManaged = [.init(nodeID: node.id, generation: dismissedGeneration, phase: node.phase)]
        let ended = SidebarPresentation.endedManagedNodeIDs(
            managed: .init(version: 1, generatedAt: date, complete: true, omittedCount: 0, nodes: [node]),
            availability: .ready, hierarchy: fixtures.hierarchy(), observations: tree, now: date, history: history
        )
        #expect(ended == (dismissedGeneration == node.generation ? [node.id] : []))
    }

    @Test func seenCallbackRunsOnlyAfterSuccessfulCurrentNavigation() async {
        let recorder = SidebarHostRecorder()
        let probe = SidebarResponseProbe()
        let model = responseOrderingModel(probe)
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
        await sidebarEventually { probe.processed == 3 }
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
        let model = responseOrderingModel()
        model.update(context: context(recorder: recorder, moved: true))
        #expect(model.hierarchy.windowID == fixtures.windowID)
        model.navigation.select(.surface(workspaceID: fixtures.workspaceB, surfaceID: fixtures.surfaceA))
        await sidebarEventually { recorder.actions.count == 1 }
        #expect(recorder.actions[0] == .selectWorkspace(fixtures.workspaceB))
        recorder.reply(0, .accepted)
        await sidebarEventually { recorder.actions.count == 2 }
        #expect(recorder.actions[1] == .selectSurface(workspaceID: fixtures.workspaceB, surfaceID: fixtures.surfaceA))
        recorder.reply(1, .accepted)
        await sidebarEventually { model.navigation.status == .selected }

        model.navigation.select(.workspace(fixtures.workspaceA))
        await sidebarEventually { recorder.actions.count == 3 }
        #expect(recorder.actions[2] == .selectWorkspace(fixtures.workspaceA))
        recorder.reply(2, .accepted)
        await sidebarEventually { model.navigation.status == .selected }
    }

    @Test
    func rejectedWorkspaceSwitchSkipsSurfaceActionAndNeverReportsSuccess() async {
        let recorder = SidebarHostRecorder()
        let probe = SidebarResponseProbe()
        let model = responseOrderingModel(probe)
        model.update(context: context(recorder: recorder, moved: true))
        var seen = 0
        model.navigation.select(.surface(workspaceID: fixtures.workspaceB, surfaceID: fixtures.surfaceA)) { seen += 1 }
        await sidebarEventually { recorder.actions.count == 1 }
        #expect(recorder.actions[0] == .selectWorkspace(fixtures.workspaceB))
        recorder.reply(0, .rejected("workspace switch refused"))
        await sidebarEventually { probe.processed == 1 }
        #expect(model.navigation.status == .rejected)
        #expect(recorder.actions.count == 1)
        #expect(seen == 0)
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
        let probe = SidebarResponseProbe()
        let model = responseOrderingModel(probe)
        model.update(context: context(recorder: recorder))
        model.navigation.select(.surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA))
        await sidebarEventually { recorder.actions.count == 1 }
        model.update(context: context(recorder: recorder, moved: true, sequence: 2))
        recorder.reply(0, .accepted)
        await sidebarEventually { probe.processed == 1 }
        #expect(model.navigation.status == .staleTarget)
        #expect(model.navigation.disabledReason(for: .surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA)) != nil)
        #expect(model.navigation.disabledReason(for: .surface(workspaceID: fixtures.workspaceB, surfaceID: fixtures.surfaceA)) == nil)
    }

    @Test
    func rapidClicksIgnoreLateResponsesAndKeepLastExplicitTarget() async {
        let recorder = SidebarHostRecorder()
        let probe = SidebarResponseProbe()
        let model = responseOrderingModel(probe)
        model.update(context: context(recorder: recorder))
        model.navigation.select(.surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA))
        await sidebarEventually { recorder.actions.count == 1 }
        model.navigation.select(.surface(workspaceID: fixtures.workspaceB, surfaceID: fixtures.surfaceB))
        await sidebarEventually { recorder.actions.count == 2 }
        recorder.reply(1, .accepted)
        await sidebarEventually { recorder.actions.count == 3 }
        recorder.reply(2, .accepted)
        await sidebarEventually { model.navigation.status == .selected }
        recorder.reply(0, .rejected("private host detail"))
        await sidebarEventually { probe.processed == 2 }
        #expect(model.navigation.status == .selected)
        #expect(recorder.actions[1] == .selectWorkspace(fixtures.workspaceB))
        #expect(recorder.actions[2] == .selectSurface(workspaceID: fixtures.workspaceB, surfaceID: fixtures.surfaceB))
    }

    @Test
    func injectedNavigationTimeoutRejectsLateHostSuccess() async {
        let (ticks, deadline) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { deadline.finish() }
        let probe = SidebarResponseProbe()
        let navigation = SidebarNavigation(timeout: {
            for await _ in ticks { return }
            try Task.checkCancellation()
        }, responseProcessed: { probe.record() })
        let recorder = SidebarHostRecorder()
        let model = SidebarConnectionModel(navigation: navigation)
        model.update(context: context(recorder: recorder))
        var successes = 0
        model.navigation.select(.workspace(fixtures.workspaceA)) { successes += 1 }
        await sidebarEventually { recorder.actions.count == 1 }
        #expect(model.navigation.status == .selecting)
        deadline.yield(())
        await sidebarEventually { model.navigation.status == .timedOut }
        recorder.reply(0, .accepted)
        await sidebarEventually { probe.processed == 1 }
        #expect(model.navigation.status == .timedOut)
        #expect(successes == 0)
    }

    @Test
    func hostRejectionsCancellationAndDisconnectNeverExposeRawText() async {
        let recorder = SidebarHostRecorder()
        let probe = SidebarResponseProbe()
        let model = responseOrderingModel(probe)
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
        await sidebarEventually { probe.processed == 3 }
        #expect(model.navigation.status == .disconnected)
        #expect(model.navigation.status.message?.contains("private") == false)
    }

    @Test
    func permissionRevocationAndHideInvalidatePendingNavigation() async {
        let recorder = SidebarHostRecorder()
        let probe = SidebarResponseProbe()
        let model = responseOrderingModel(probe)
        model.update(context: context(recorder: recorder))
        let target = SidebarNavigationTarget.workspace(fixtures.workspaceA)
        model.navigation.select(target)
        await sidebarEventually { recorder.actions.count == 1 }
        model.update(context: context(recorder: recorder, sequence: 2, actions: []))
        recorder.reply(0, .accepted)
        await sidebarEventually { probe.processed == 1 }
        #expect(model.navigation.status == .staleTarget)
        #expect(model.navigation.disabledReason(for: target) != nil)

        model.update(context: context(recorder: recorder, sequence: 3))
        model.navigation.select(target)
        await sidebarEventually { recorder.actions.count == 2 }
        model.setVisible(false)
        recorder.reply(1, .accepted)
        await sidebarEventually { probe.processed == 2 }
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
            read: neutralRead { await reads.read($0) }, pause: { try await Task.sleep(for: .seconds(60)) }
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
            read: neutralRead { await reads.read($0) }, pause: { try await Task.sleep(for: .seconds(60)) }
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
        let probe = SidebarResponseProbe()
        let navigation = SidebarNavigation(timeout: { try await Task.sleep(for: .milliseconds(15)) },
                                           responseProcessed: { probe.record() })
        let reply = SidebarNavigationGate()
        navigation.update(
            topology: fixtures.topology(), connected: true, workspaceAllowed: true, surfaceAllowed: true,
            perform: { _ in await reply.wait() }
        )
        navigation.select(.workspace(fixtures.workspaceA))
        await sidebarEventually { navigation.status == .timedOut }
        #expect(probe.processed == 0)
        await reply.finish()
        await sidebarEventually { probe.processed == 1 }
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
        #expect(view.components(separatedBy: "selection: unmanagedSelection").count == 3,
                "Hierarchy and Taskboard retain the inspection binding")
        let now = Date()
        for granted in [true, false] {
            let scopes: Set<CmuxExtensionScope> = granted
                ? [.workspaceMetadata, .surfaceMetadata, .workspacePaths] : [.workspaceMetadata, .surfaceMetadata]
            let model = SidebarConnectionModel()
            model.update(context: .init(
                snapshot: pathSnapshot().filtered(for: scopes), host: .init(performAction: { _, _ in })
            ))
            let source = fixtures.snapshot(sessions: [fixtures.session(children: [fixtures.child("child")], now: now)], now: now)
            #expect(source.sessions[0].children[0].id == "child" && source.sessions[0].children[0].state == .idle)
            let hidden = SidebarCopilotTree.project(source, onto: SidebarTopology(model.hierarchy), now: now)
            #expect(hidden.sessions[0].nodes.isEmpty)
            let tree = SidebarCopilotTree.project(
                source, onto: SidebarTopology(model.hierarchy), now: now,
                revealingIdleTasksIn: [fixtures.workspaceA]
            )
            let expectedPaths: [SidebarDetailLine] = [
                .init(title: "Workspace path", value: granted ? "/repo/.worktrees/feature" : "Path unavailable"),
                .init(title: "Project path", value: granted ? "/repo" : "Path unavailable"),
                .init(title: "Surface directory", value: granted ? "/repo/.worktrees/feature/src" : "Path unavailable",
                      help: "Source: CMUX · Report time: Unknown · Agent/tool directory: Unverified")
            ]
            let rawPaths = [
                "Workspace path": "/repo/.worktrees/feature",
                "Project path": "/repo",
                "Surface directory": "/repo/.worktrees/feature/src"
            ]
            func copyable(_ lines: [SidebarDetailLine]) -> [SidebarDetailLine] {
                lines.map { line in
                    var result = line
                    if granted {
                        let title = line.title == "Parent surface directory" ? "Surface directory" : line.title
                        result.copyableValue = rawPaths[title]
                    }
                    return result
                }
            }
            for selection in [
                UnmanagedSelection.workspace(fixtures.workspaceA),
                .surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA),
                .session(fixtures.sessionID), .child(sessionID: fixtures.sessionID, childID: "child")
            ] {
                let subject = try #require(SidebarPresentation.inspection(
                    for: .unmanaged(selection), hierarchy: model.hierarchy, connected: true, tree: tree,
                    managed: .empty, availability: .ready, now: now
                ))
                let detail = try #require(SidebarPresentation.inspectorDetails(
                    for: subject, hierarchy: model.hierarchy, connected: true, tree: tree,
                    managed: .empty, availability: .ready, now: now
                ))
                let expected: [SidebarDetailLine]
                switch selection {
                case .workspace: expected = Array(expectedPaths.prefix(2))
                case .surface: expected = Array(expectedPaths.suffix(1))
                case .session: expected = copyable(expectedPaths)
                case .child:
                    expected = copyable(Array(expectedPaths.prefix(2))) + [
                        .init(title: "Parent surface directory", value: granted ? "/repo/.worktrees/feature/src" : "Path unavailable",
                              copyableValue: granted ? "/repo/.worktrees/feature/src" : nil,
                              help: "Source: CMUX parent surface · Report time: Unknown · Child directory: Unverified")
                    ]
                }
                #expect(detail.lines.filter {
                    ["Workspace path", "Project path", "Surface directory", "Parent surface directory"].contains($0.title)
                } == expected)
            }
        }
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

    // Response ordering must not race the unrelated wall-clock selection deadline.
    private func responseOrderingModel() -> SidebarConnectionModel {
        responseOrderingModel(SidebarResponseProbe())
    }

    private func responseOrderingModel(_ probe: SidebarResponseProbe) -> SidebarConnectionModel {
        SidebarConnectionModel(navigation: SidebarNavigation(
            timeout: { try await sidebarFrozenExpiry(0) }, responseProcessed: { probe.record() }
        ))
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
private final class SidebarResponseProbe {
    private(set) var processed = 0
    func record() { processed += 1 }
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
