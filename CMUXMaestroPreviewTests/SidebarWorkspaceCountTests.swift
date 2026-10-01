import Foundation
import Testing

@MainActor
struct SidebarWorkspaceCountTests {
    private let fixtures = SidebarTreeFixtures()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func legacyCoordinatorCountsOneSurfaceWithoutClaimingSessionContents() throws {
        let root = owner()
        let observed = session(fixtures.sessionID, surface: fixtures.surfaceA)
        let tree = tree([observed])
        let summary = summary(tree, managed: [root])
        #expect(summary.agentCount == 1)
        #expect(summary.states.map { "\($0.title):\($0.count)" } == ["Working:1"])
        #expect(summary.agentLine == "1 agent · 1 working")
        #expect(summary.retainedRecordCount == 0)
        let placement = try #require(SidebarPresentation.sessionPlacements(
            tree.sessions, managed: [root], observations: tree, now: now
        ).first)
        #expect(placement.managedNodeID == root.id)
        #expect(placement.contentOwnerID == nil && placement.requiresSeparateContext)
    }

    @Test(arguments: [false, true])
    func supplementalHistoryDoesNotInflateExactManagedAndUnmanagedCounts(_ exactOwner: Bool) throws {
        let root = owner(sessionID: exactOwner ? fixtures.sessionID : nil)
        let current = session(fixtures.sessionID, surface: fixtures.surfaceA)
        let historical = session(fixtures.otherSessionID, surface: fixtures.surfaceA, state: .completed, liveness: .dead)
        let independent = session(UUID(), surface: fixtures.surfaceB, state: .idle)
        let terminal = surface(UUID()), browser = surface(UUID(), kind: .browser)
        let surfaces = [surface(fixtures.surfaceA), surface(fixtures.surfaceB), terminal, browser]
        let tree = tree([current, historical, independent])
        let summary = summary(tree, managed: [root], surfaces: surfaces)
        #expect(summary.agentCount == 2)
        #expect(summary.states.map { "\($0.title):\($0.count)" } == ["Working:1", "Idle:1"])
        #expect(summary.tabs.contains(.init(kind: .terminal, count: 1)))
        #expect(summary.tabs.contains(.init(kind: .browser, count: 1)))
        #expect(summary.tabs.reduce(0) { $0 + $1.count } == 2)
        #expect(summary.retainedRecordCount == 0)
        #expect(summary.agentLine.hasPrefix("2 agents"))
        let placements = SidebarPresentation.sessionPlacements(tree.sessions, managed: [root], observations: tree, now: now)
        #expect(placements[0].contentOwnerID == (exactOwner ? root.id : nil))
        #expect(placements[1].session.id == historical.id && placements[1].contentOwnerID == nil)
        #expect(placements[1].requiresSeparateContext)
        #expect(placements[2].managedNodeID == nil && placements[2].contentOwnerID == nil)
        #expect(SidebarPresentation.retainedSessionIDs(tree, managed: [root], now: now).contains(historical.id))
        #expect(tree.dismissibleOutcomes.count == 3, "Counting cannot hide or merge exact task outcomes")
        #expect(SidebarPresentation.unmanagedSurfaces(
            surfaces, workspaceID: fixtures.workspaceA, managed: [root], observations: tree, now: now
        ).map(\.id) == [fixtures.surfaceB, terminal.id, browser.id])
    }

    @Test(arguments: ["duplicate", "ambiguous", "stale-snapshot", "stale-observation"], [false, true])
    func uncertainSameSurfaceObservationsNeverAddManagedAgents(_ variant: String, _ exactOwner: Bool) {
        let root = owner(sessionID: exactOwner ? fixtures.sessionID : nil)
        let tree = variantTree(variant)
        let summary = summary(tree, managed: [root])
        #expect(summary.agentCount == 1 && summary.incomplete)
        #expect(summary.states.reduce(0) { $0 + $1.count } == 1)
        let expected = exactOwner && variant == "ambiguous" ? "Working:1" : "Registered:1"
        #expect(summary.states.map { "\($0.title):\($0.count)" } == [expected])
        #expect(summary.retainedRecordCount == 0)
        let placements = SidebarPresentation.sessionPlacements(tree.sessions, managed: [root], observations: tree, now: now)
        #expect(placements.allSatisfy { $0.managedNodeID == root.id })
        #expect(placements.filter { $0.session.id != fixtures.sessionID }.allSatisfy { $0.contentOwnerID == nil })
    }

    @Test(arguments: ["historical", "duplicate", "ambiguous", "stale-snapshot", "stale-observation"])
    func unmanagedCountsUseOneDestinationAndDoNotChooseAmbiguousActivity(_ variant: String) {
        let tree = variantTree(variant)
        let terminal = surface(UUID()), browser = surface(UUID(), kind: .browser)
        let summary = summary(tree, managed: [], surfaces: [surface(fixtures.surfaceA), terminal, browser])
        #expect(summary.agentCount == 1)
        #expect(summary.states.map { "\($0.title):\($0.count)" } == [variant == "historical" ? "Working:1" : "Unknown:1"])
        if variant != "historical" { #expect(summary.incomplete) }
        #expect(summary.tabs.contains(.init(kind: .terminal, count: 1)))
        #expect(summary.tabs.contains(.init(kind: .browser, count: 1)))
        #expect(summary.retainedRecordCount == 0)
    }

    @Test func retainedManagedEntryLegendRemainsDistinctFromSupplementalObservations() {
        let root = owner(sessionID: fixtures.otherSessionID)
        let current = session(fixtures.sessionID, surface: fixtures.surfaceA)
        let old = session(fixtures.otherSessionID, surface: fixtures.surfaceA, state: .completed, liveness: .dead)
        let additionalHistory = session(UUID(), surface: fixtures.surfaceA, state: .completed, liveness: .dead)
        let tree = tree([current, old, additionalHistory])
        let summary = summary(tree, managed: [root])
        #expect(summary.agentCount == 2, "Preserve the existing managed-record plus live-agent entry contract")
        #expect(summary.retainedRecordCount == 1)
        #expect(summary.agentLine.hasPrefix("2 entries · 1 needed for context"))
        #expect(summary.states.reduce(0) { $0 + $1.count } == 2)
        let placements = SidebarPresentation.sessionPlacements(tree.sessions, managed: [root], observations: tree, now: now)
        #expect(placements[0].contentOwnerID == nil)
        #expect(placements[1].contentOwnerID == root.id && placements[1].retainsContents)
        #expect(placements[2].contentOwnerID == nil)
    }

    @Test(arguments: ["coordinator", "worker"], ["launching", "turn-running"])
    func directInteractiveStateUsesFreshExactObservationAfterControllerExpires(_ role: String, _ phase: String) {
        let node = directNode(role: role, phase: phase)
        let projection = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: node.updatedAt, complete: true, omittedCount: 0, nodes: [node]
        )
        #expect(SidebarOrchestrationReader.isStale(projection, now: now))
        for work: AgentWorkState in [.working, .idle, .blocked] {
            let observed = session(fixtures.sessionID, surface: fixtures.surfaceA, state: work)
            let tree = tree([observed])
            for availability: SidebarOrchestrationAvailability in [.ready, .partial, .stale] {
                #expect(SidebarPresentation.managedState(node, availability: availability, now: now, tree: tree)
                        == SidebarPresentation.state(work))
                let summary = summary(tree, managed: [node], availability: availability)
                #expect(summary.agentCount == 1)
                #expect(summary.states.map(\.title) == [SidebarPresentation.state(work).title])
                if availability != .ready { #expect(summary.incomplete) }
            }
        }
        #expect(node.updatedAt == now.addingTimeInterval(-61), "Observation does not refresh controller metadata")
    }

    @Test(arguments: ["coordinator", "worker"], ["launching", "turn-running"])
    func directProviderObservationWithoutWorkNeverMeansWorking(_ role: String, _ phase: String) {
        let node = directNode(role: role, phase: phase, age: 0)
        for tree in [tree([]), tree([session(fixtures.sessionID, surface: fixtures.surfaceA, state: .unknown)])] {
            let row = SidebarPresentation.managedState(node, availability: .ready, now: now, tree: tree)
            #expect(row.tone == .neutral)
            let summary = summary(tree, managed: [node])
            #expect(summary.states.map(\.title) == ["Unknown"])
            #expect(summary.agentCount == 1 && summary.incomplete)
        }
        let noSnapshot = SidebarPresentation.workspaceSummary(
            surfaces: [], sessions: [], managed: [node], orchestrationAvailability: .ready,
            countsComplete: true, now: now
        )
        #expect(noSnapshot.states.map(\.title) == ["Unknown"])
    }

    @Test(arguments: [
        "absent", "stale-snapshot", "missing-date", "future-snapshot", "unavailable", "denied",
        "stale-session", "future-session", "after-snapshot", "unknown", "ambiguous", "dead",
        "foreign-session", "foreign-surface", "foreign-workspace", "missing-managed-session",
        "duplicate", "duplicate-foreign-placement", "duplicate-stale"
    ])
    func directInteractiveStateRejectsUnavailableOrNonuniqueEvidence(_ variant: String) {
        let exact = session(fixtures.sessionID, surface: fixtures.surfaceA)
        var observed = tree([exact])
        switch variant {
        case "absent": observed.sessions = []
        case "stale-snapshot": observed.generatedAt = now.addingTimeInterval(-9)
        case "missing-date": observed.generatedAt = nil
        case "future-snapshot": observed.generatedAt = now.addingTimeInterval(2)
        case "unavailable": observed.availability = .unavailable
        case "denied": observed.issues = [.permissionDenied]
        case "stale-session":
            observed.sessions = [session(fixtures.sessionID, surface: fixtures.surfaceA, observedAt: now.addingTimeInterval(-9))]
        case "future-session":
            observed.sessions = [session(fixtures.sessionID, surface: fixtures.surfaceA, observedAt: now.addingTimeInterval(2))]
        case "after-snapshot": observed.generatedAt = now.addingTimeInterval(-2)
        case "unknown", "ambiguous", "dead":
            let liveness: AgentProcessLiveness = variant == "unknown" ? .unknown : variant == "ambiguous" ? .ambiguous : .dead
            observed.sessions = [session(fixtures.sessionID, surface: fixtures.surfaceA, liveness: liveness)]
        case "foreign-session": observed.sessions = [session(fixtures.otherSessionID, surface: fixtures.surfaceA)]
        case "foreign-surface": observed.sessions = [session(fixtures.sessionID, surface: fixtures.surfaceB)]
        case "foreign-workspace":
            observed.sessions = [session(fixtures.sessionID, surface: fixtures.surfaceA, workspace: fixtures.workspaceB)]
        case "missing-managed-session": break
        case "duplicate": observed.sessions.append(exact)
        case "duplicate-foreign-placement":
            observed.sessions.append(session(fixtures.sessionID, surface: fixtures.surfaceB, workspace: fixtures.workspaceB))
        case "duplicate-stale":
            observed.sessions.append(session(fixtures.sessionID, surface: fixtures.surfaceA, observedAt: now.addingTimeInterval(-9)))
        default: preconditionFailure("Unknown direct observation fixture")
        }
        for role in ["coordinator", "worker"] {
            for phase in ["launching", "turn-running"] {
                let node = directNode(role: role, phase: phase, age: 0, pinnedIdentity: variant != "missing-managed-session")
                #expect(SidebarPresentation.managedState(node, availability: .ready, now: now, tree: observed).tone == .neutral)
                // Inspect only the managed entry; unrelated observed sessions have their own identity and state.
                let summary = SidebarPresentation.workspaceSummary(
                    surfaces: [], sessions: [], managed: [node], orchestrationAvailability: .ready,
                    countsComplete: true, now: now, observations: observed
                )
                #expect(summary.states.map(\.title) == ["Unknown"])
                #expect(summary.agentCount == 1 && summary.incomplete)
            }
        }
    }

    @Test func freshInteractiveActivityDoesNotRefreshGitOrClaimOtherSessionContents() throws {
        let node = directNode(role: "worker", phase: "launching")
        let exact = session(fixtures.sessionID, surface: fixtures.surfaceA, state: .idle)
        let other = session(fixtures.otherSessionID, surface: fixtures.surfaceA, state: .blocked)
        let tree = tree([exact, other])
        let placements = SidebarPresentation.sessionPlacements(tree.sessions, managed: [node], observations: tree, now: now)
        #expect(placements.map(\.managedNodeID) == [node.id, node.id])
        #expect(placements.map(\.contentOwnerID) == [node.id, nil])
        #expect(placements[1].requiresSeparateContext)
        #expect(SidebarPresentation.managedState(node, availability: .stale, now: now, tree: tree).title == "Idle")
        let details = SidebarPresentation.managedNodeDetails(node, hierarchy: fixtures.hierarchy(), tree: tree, now: now)
        #expect(!details.contains { $0.title == "Branch" || $0.title == "Worktree" })
        #expect(try #require(details.first { $0.title == "Git evidence" }).value.hasPrefix("Stale"))
        #expect(node.currentGitChanges(at: now) == nil)
        #expect(node.updatedAt == now.addingTimeInterval(-61))
    }

    @Test func legacyBoundedReportsAndTurnStateDoNotUseInteractiveObservation() {
        let observed = tree([session(fixtures.sessionID, surface: fixtures.surfaceA, state: .working)])
        let completed = directNode(role: "worker", phase: "reported-completed", age: 0, mode: .bounded)
        #expect(SidebarPresentation.managedState(completed, availability: .ready, now: now, tree: observed)
            .title == "Completed · available")
        #expect(summary(observed, managed: [completed]).states.map(\.title) == ["Finished"])
        let stale = directNode(role: "worker", phase: "reported-completed", mode: .bounded)
        #expect(SidebarPresentation.managedState(stale, availability: .stale, now: now, tree: observed).title
            .contains("State unverified"))
        #expect(summary(observed, managed: [stale], availability: .stale).states.map(\.title) == ["Unknown"])
        let running = directNode(role: "worker", phase: "turn-running", age: 0, mode: .bounded)
        #expect(SidebarPresentation.managedState(running, availability: .ready, now: now).title == "Working")
        #expect(summary(tree([]), managed: [running]).states.map(\.title) == ["Working"])
    }

    private func directNode(
        role: String, phase: String, age: TimeInterval = 61, mode: SidebarWorkerMode = .interactive,
        pinnedIdentity: Bool = true
    ) -> SidebarOrchestrationNode {
        let recordedAt = now.addingTimeInterval(-age)
        return .init(
            id: UUID(), runId: UUID(), parentId: role == "worker" ? UUID() : nil, role: role, label: "Managed",
            workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA, generation: 1,
            phase: phase, availability: phase == "reported-completed" ? "idle" : "busy",
            copilotSessionId: pinnedIdentity ? fixtures.sessionID : nil, executionMode: mode,
            worktreeLabel: "observed-worktree", branchLabel: "observed-branch",
            gitEvidenceStatus: "verified", gitEvidenceAt: recordedAt,
            gitChangesStatus: "verified",
            gitChanges: .init(files: 1, insertions: 2, deletions: 0, untrackedFiles: 0, binaryFiles: 0),
            gitChangesAt: recordedAt, createdAt: recordedAt, updatedAt: recordedAt
        )
    }

    private func variantTree(_ variant: String) -> SidebarCopilotTree {
        let current = session(fixtures.sessionID, surface: fixtures.surfaceA)
        switch variant {
        case "historical":
            return tree([session(fixtures.otherSessionID, surface: fixtures.surfaceA, state: .completed, liveness: .dead), current])
        case "duplicate": return tree([current, current])
        case "ambiguous": return tree([current, session(fixtures.otherSessionID, surface: fixtures.surfaceA)])
        case "stale-snapshot": return tree([current], generatedAt: now.addingTimeInterval(-9))
        case "stale-observation": return tree([session(fixtures.sessionID, surface: fixtures.surfaceA, observedAt: now.addingTimeInterval(-9))])
        default: preconditionFailure("Unknown count fixture")
        }
    }

    private func summary(
        _ tree: SidebarCopilotTree, managed: [SidebarOrchestrationNode], surfaces: [HierarchySurface] = [],
        availability: SidebarOrchestrationAvailability = .ready
    ) -> SidebarWorkspaceSummary {
        SidebarPresentation.workspaceSummary(
            surfaces: surfaces, sessions: tree.sessions, managed: managed,
            orchestrationAvailability: availability, countsComplete: true, now: now, observations: tree
        )
    }

    private func tree(_ sessions: [SidebarCopilotSession], generatedAt: Date? = nil) -> SidebarCopilotTree {
        .init(availability: .ready, sessions: sessions, issues: [], generatedAt: generatedAt ?? now)
    }

    private func owner(sessionID: UUID? = nil) -> SidebarOrchestrationNode {
        .init(id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Same title",
              workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA, generation: sessionID == nil ? 0 : 1,
              phase: "registered", availability: "active", copilotSessionId: sessionID,
              executionMode: sessionID == nil ? nil : .interactive, createdAt: now, updatedAt: now)
    }

    private func session(
        _ id: UUID, surface: UUID, state: AgentWorkState = .working,
        liveness: AgentProcessLiveness = .alive, observedAt: Date? = nil, workspace: UUID? = nil
    ) -> SidebarCopilotSession {
        .init(
            id: id, workspaceID: workspace ?? fixtures.workspaceA, surfaceID: surface, liveness: liveness,
            state: state, model: nil, observedAt: observedAt ?? now,
            nodes: [.init(id: "task", parentID: nil, depth: 0, kind: .subagent, name: "Same task name",
                          state: .completed, model: nil, ancestryUnresolved: false, hasChildren: false,
                          terminalEvent: .init(id: id, timestamp: now),
                          observedParent: .session(.init(providerID: "copilot", sessionID: id.uuidString)))],
            childrenComplete: true, treeDegraded: false, omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
    }

    private func surface(_ id: UUID, kind: HierarchySurfaceKind = .terminal) -> HierarchySurface {
        .init(id: id, title: "Same title", kind: kind, isFocused: false, isPinned: false,
              unreadCount: 0, workingDirectory: .unavailable)
    }
}
