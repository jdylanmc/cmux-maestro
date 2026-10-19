import Foundation
import Testing

/// Worktrees grouping comes only from each exact session's current-worktree evidence (ADR 0026).
@MainActor
struct SidebarWorktreeProjectionTests {
    private let workspace = UUID()
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func identity(_ key: String, _ repository: String = "repo", head: CopilotWorktreeHead = .branch("main"))
        -> CopilotWorktreeIdentity {
        .init(key: key, repository: repository, head: head, linked: true)
    }

    private func verified(_ identity: CopilotWorktreeIdentity, current: Bool = true) -> AgentSessionWorktree {
        .init(evidence: .verified(identity), isCurrent: current)
    }

    @Test func sameRepositoryAndBranchStaySeparateByKeyAndStatesStayExplicit() {
        let left = identity("0000000000000001"), right = identity("0000000000000002")
        let members: [(String, AgentSessionWorktree?)] = [
            ("unknown-nil", nil),
            ("a", verified(left)),
            ("stale", verified(left, current: false)),
            ("b", verified(right)),
            ("plain", .init(evidence: .nonRepository, isCurrent: true)),
            ("stale-plain", .init(evidence: .nonRepository, isCurrent: false)),
            ("a2", verified(left)),
            ("unknown", .init(evidence: .unknown, isCurrent: true)),
        ]
        let groups = SidebarWorktreeGrouping.groups(members) { $0.1 }
        #expect(groups.map(\.key) == [.worktree(left.key), .worktree(right.key), .lastKnown(left.key),
                                      .nonRepository, .unknown])
        #expect(groups.map { $0.members.map(\.0) } == [["a", "a2"], ["b"], ["stale"], ["plain"],
                                                         ["unknown-nil", "stale-plain", "unknown"]])
        #expect(groups.map(\.title) == ["repo", "repo", "repo", "No repository", "Unknown"])
        #expect(groups[0].detail == "main · 0000000" && groups[1].detail == "main · 0000000")
        #expect(groups[0].id != groups[1].id)
        #expect(groups[2].isLastKnown && !groups[0].isLastKnown)
        #expect(groups[3].detail == nil && groups[4].detail == nil)
    }

    @Test func verifiedGroupsSortByRepositoryThenBranchAndShowDetachedCommits() {
        let detached = identity("00000000000000aa", "beta", head: .detached("abcdef1"))
        let groups = SidebarWorktreeGrouping.groups([
            verified(detached), verified(identity("00000000000000bb", "alpha", head: .branch("zed"))),
            verified(identity("00000000000000cc", "alpha", head: .branch("main"))),
        ]) { $0 }
        #expect(groups.map(\.detail) == ["main · 0000000", "zed · 0000000", "Detached HEAD · abcdef1 · 0000000"])
    }

    @Test func managedEvidenceRequiresTheExactSessionWorkspaceAndSurface() {
        let session = UUID(), surface = UUID()
        let worktree = verified(identity("0000000000000001"))
        var observed = SidebarCopilotSession(
            id: session, workspaceID: workspace, surfaceID: surface, liveness: .alive, state: .working,
            model: nil, observedAt: now, nodes: [], childrenComplete: true, treeDegraded: false,
            omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
        observed.currentWorktree = worktree
        let tree = SidebarCopilotTree(availability: .ready, sessions: [observed], issues: [], generatedAt: now)
        func node(session: UUID?, surface: UUID, workspace: UUID) -> SidebarOrchestrationNode {
            .init(id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Agent",
                  workspaceId: workspace, surfaceId: surface, generation: 1, phase: "turn-running",
                  availability: "busy", copilotSessionId: session, createdAt: now, updatedAt: now)
        }
        #expect(SidebarWorktreeGrouping.evidence(for: node(session: session, surface: surface, workspace: workspace),
                                                 in: tree) == worktree)
        #expect(SidebarWorktreeGrouping.evidence(for: node(session: session, surface: UUID(), workspace: workspace),
                                                 in: tree) == nil)
        #expect(SidebarWorktreeGrouping.evidence(for: node(session: session, surface: surface, workspace: UUID()),
                                                 in: tree) == nil)
        #expect(SidebarWorktreeGrouping.evidence(for: node(session: nil, surface: surface, workspace: workspace),
                                                 in: tree) == nil)
    }

    /// The parent's session is in a verified worktree; its spawned child's own session has no
    /// evidence. The child is Unknown, never grouped with its parent.
    @Test func childNeverTakesItsParentsWorktree() {
        let parentSession = UUID(), parentSurface = UUID(), childSession = UUID(), childSurface = UUID()
        let worktree = verified(identity("0000000000000001"))
        func session(_ id: UUID, _ surface: UUID, _ evidence: AgentSessionWorktree?) -> SidebarCopilotSession {
            var result = SidebarCopilotSession(
                id: id, workspaceID: workspace, surfaceID: surface, liveness: .alive, state: .working,
                model: nil, observedAt: now, nodes: [], childrenComplete: true, treeDegraded: false,
                omittedChildrenCount: 0, omittedActiveChildrenCount: 0
            )
            result.currentWorktree = evidence
            return result
        }
        let tree = SidebarCopilotTree(
            availability: .ready, sessions: [session(parentSession, parentSurface, worktree),
                                             session(childSession, childSurface, nil)],
            issues: [], generatedAt: now
        )
        let parent = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Parent", workspaceId: workspace,
            surfaceId: parentSurface, generation: 1, phase: "turn-running", availability: "busy",
            copilotSessionId: parentSession, executionMode: .interactive, createdAt: now, updatedAt: now
        )
        let child = SidebarOrchestrationNode(
            id: UUID(), runId: parent.runId, parentId: parent.id, role: "worker", label: "Child",
            workspaceId: workspace, surfaceId: childSurface, generation: 1, phase: "turn-running",
            availability: "busy", copilotSessionId: childSession, executionMode: .interactive,
            createdAt: now, updatedAt: now
        )
        #expect(SidebarWorktreeGrouping.evidence(for: parent, in: tree) == worktree)
        #expect(SidebarWorktreeGrouping.evidence(for: child, in: tree) == nil)
        let groups = SidebarWorktreeGrouping.groups([parent, child]) { SidebarWorktreeGrouping.evidence(for: $0, in: tree) }
        #expect(groups.map(\.key) == [.worktree("0000000000000001"), .unknown])
        #expect(groups.map { $0.members.map(\.label) } == [["Parent"], ["Child"]])
    }

    @Test func groupHeaderShowsNoBranchWhenMembersDisagree() {
        let main = identity("0000000000000001"), topic = identity("0000000000000001", head: .branch("topic"))
        let agreeing = SidebarWorktreeGrouping.groups([verified(main), verified(main)]) { $0 }
        #expect(agreeing.map(\.detail) == ["main · 0000000"])
        let disagreeing = SidebarWorktreeGrouping.groups([verified(main), verified(topic)]) { $0 }
        #expect(disagreeing.count == 1 && disagreeing[0].detail == "0000000" && disagreeing[0].members.count == 2)
    }

    @Test func groupDisclosureIsStoredPerWorkspaceAndKey() throws {
        let key = SidebarWorktreeGroupKey.worktree("0000000000000001")
        var layout = SidebarLayoutSettings()
        let id = SidebarExpansionID.worktreeGroup(key, workspaceID: workspace)
        #expect(id.isValid && layout.isExpanded(id))
        layout.setExpanded(false, for: id)
        #expect(!layout.isExpanded(id))
        #expect(layout.isExpanded(.worktreeGroup(key, workspaceID: UUID())))
        #expect(layout.isExpanded(.worktreeGroup(.lastKnown("0000000000000001"), workspaceID: workspace)))
        let decoded = try JSONDecoder().decode(SidebarLayoutSettings.self, from: JSONEncoder().encode(layout))
        #expect(!decoded.isExpanded(id) && decoded.isValid)
        for storage in ["tree:XYZ", "tree:", "other", "last:0000000000000001/x"] {
            #expect(!SidebarExpansionID(kind: .worktreeGroup, id: workspace, childID: storage).isValid)
        }
        #expect(SidebarExpansionID(kind: .worktreeGroup, id: workspace, childID: "unknown").isValid)
    }

    @Test func projectionIsOneGlobalPersistedChoiceDefaultingToSubAgents() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let first = fixture.preferences()
        #expect(first.projection == .subAgents)
        first.projection = .worktrees
        #expect(fixture.defaults.string(forKey: "sidebar.projection") == "worktrees")
        #expect(fixture.preferences().projection == .worktrees)
        fixture.defaults.set("workspace", forKey: "sidebar.projection")
        #expect(fixture.preferences().projection == .subAgents)
        #expect(SidebarProjection.allCases.map(\.title) == ["Worktrees", "Sub-agents"])
    }

    /// Worktrees keeps the saved Maestro order of root agents (by surface), then the default order.
    @Test func savedRootOrderSurvivesGrouping() {
        let worktree = verified(identity("0000000000000001"))
        func root(_ label: String, age: Double) -> SidebarOrchestrationNode {
            .init(id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: label, workspaceId: workspace,
                  surfaceId: UUID(), generation: 1, phase: "turn-running", availability: "busy",
                  copilotSessionId: UUID(), createdAt: now.addingTimeInterval(-age), updatedAt: now)
        }
        let older = root("A", age: 20), newer = root("B", age: 10)
        let saved = ManagedHierarchyContent.orderedRoots([older, newer], visible: [newer.surfaceId, older.surfaceId])
        let groups = SidebarWorktreeGrouping.groups(saved) { _ in worktree }
        #expect(groups.first?.members.map(\.label) == ["B", "A"])
        let unsaved = ManagedHierarchyContent.orderedRoots([older, newer], visible: nil)
        #expect(SidebarWorktreeGrouping.groups(unsaved) { _ in worktree }.first?.members.map(\.label) == ["A", "B"])
    }
}
