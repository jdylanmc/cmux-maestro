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
        _ tree: SidebarCopilotTree, managed: [SidebarOrchestrationNode], surfaces: [HierarchySurface] = []
    ) -> SidebarWorkspaceSummary {
        SidebarPresentation.workspaceSummary(
            surfaces: surfaces, sessions: tree.sessions, managed: managed,
            orchestrationAvailability: .ready, countsComplete: true, now: now, observations: tree
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
        liveness: AgentProcessLiveness = .alive, observedAt: Date? = nil
    ) -> SidebarCopilotSession {
        .init(
            id: id, workspaceID: fixtures.workspaceA, surfaceID: surface, liveness: liveness,
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
