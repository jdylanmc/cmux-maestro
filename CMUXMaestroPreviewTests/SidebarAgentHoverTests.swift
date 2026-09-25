import Foundation
import Testing

@MainActor
struct SidebarAgentHoverTests {
    private let fixtures = SidebarTreeFixtures()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(
        id: UUID? = nil, surface: UUID? = nil, name: String = "model",
        liveness: CopilotLiveness = .alive
    ) -> SidebarCopilotSession {
        .init(
            id: id ?? fixtures.sessionID, workspaceID: fixtures.workspaceA,
            surfaceID: surface ?? fixtures.surfaceA, liveness: liveness, state: .working, model: name,
            observedAt: now, nodes: [], childrenComplete: true, treeDegraded: false,
            omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
    }

    private func card(
        _ target: SidebarAgentHoverTarget, sessions: [SidebarCopilotSession],
        hierarchy: HierarchySnapshot? = nil, connected: Bool = true,
        generatedAt: Date? = nil, nodes: [SidebarOrchestrationNode] = [],
        availability: SidebarOrchestrationAvailability = .ready
    ) -> SidebarHoverCardData? {
        SidebarAgentHoverContent.card(
            for: target, hierarchy: hierarchy ?? fixtures.hierarchy(), connected: connected,
            tree: .init(availability: .ready, sessions: sessions, issues: [], generatedAt: generatedAt ?? now),
            managed: .init(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: nodes),
            availability: availability, now: now
        )
    }

    @Test func sessionPreviewUsesItsExactSubjectAndDoesNotBorrowFromSameNamedPeers() throws {
        let a = session()
        let b = session(id: fixtures.otherSessionID, name: "different-model")
        let result = try #require(card(.session(a.id), sessions: [a, b]))
        #expect(result.lines.contains(.init(title: "Model", value: "model")))
        #expect(!result.lines.contains { $0.value == "different-model" })
        #expect(result.id == "session-\(a.id)")
        #expect(result.lines.filter { $0.copyableSessionID != nil } == [.sessionID(a.id)])
        #expect(card(.session(a.id), sessions: [a, a]) == nil)
        #expect(card(.session(a.id), sessions: [a], connected: false) == nil)
        #expect(card(.session(a.id), sessions: [a], hierarchy: fixtures.hierarchy(granted: false)) == nil)
        #expect(card(.session(a.id), sessions: [a], hierarchy: fixtures.hierarchy(moved: true)) == nil)
        #expect(card(.session(UUID()), sessions: [a]) == nil)
    }

    @Test func staleOrMissingAgentEvidenceCannotAdvertiseCurrentMetrics() throws {
        let a = session()
        let result = try #require(card(.session(a.id), sessions: [a], generatedAt: now.addingTimeInterval(-9)))
        #expect(result.notice == "Session observation is no longer current.")
        #expect(result.lines.isEmpty && result.subtitle == nil)
        let current = try #require(card(.session(a.id), sessions: [a]))
        #expect(!current.lines.contains { ["Context", "Elapsed", "Git changes", "Pet"].contains($0.title) })
    }

    @Test func observedChildKeepsParentPlacementAndItsOwnModel() throws {
        var a = session()
        a.nodes = [.init(id: "child", parentID: nil, depth: 0, kind: .subagent, name: "Review agent",
                         state: .blocked, model: "child-model", ancestryUnresolved: true, hasChildren: false)]
        let result = try #require(card(.child(sessionID: a.id, childID: "child"), sessions: [a]))
        #expect(result.title == "Review agent")
        #expect(result.lines.contains(.init(title: "Model", value: "child-model")))
        #expect(result.lines.contains(.init(title: "Placement", value: "Observed child; native placement belongs to its parent session")))
        #expect(!result.lines.contains { $0.title == "Surface ID" || $0.title == "Session glyph" })
        #expect(result.lines.filter { $0.copyableSessionID != nil } == [.sessionID(a.id, isParent: true)])
        #expect(result.lines.contains { $0.title == "Parent session ID" && $0.value == a.id.uuidString })
        a.nodes.append(a.nodes[0])
        #expect(card(.child(sessionID: a.id, childID: "child"), sessions: [a]) == nil)
        #expect(card(.child(sessionID: UUID(), childID: "child"), sessions: [a]) == nil)
    }

    @Test func managedPreviewRejectsAReplacedGenerationAndShowsOnlyVerifiedMetrics() throws {
        let node = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "worker", label: "Managed agent",
            workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA, generation: 2,
            phase: "turn-running", availability: "busy", copilotSessionId: fixtures.sessionID,
            executionMode: .interactive, worktreeLabel: "not-current", branchLabel: "old-branch",
            gitEvidenceStatus: "verified", gitEvidenceAt: now.addingTimeInterval(-3_600),
            createdAt: now.addingTimeInterval(-100), updatedAt: now
        )
        let result = try #require(card(.managed(node.id, generation: 2), sessions: [session()], nodes: [node]))
        #expect(result.title == node.label)
        #expect(result.lines.contains(.init(title: "Model", value: "model")))
        #expect(!result.lines.contains { $0.value == "old-branch" || $0.value == "not-current" })
        #expect(result.lines.contains { $0.title == "Git evidence" && $0.value.hasPrefix("Stale") })
        #expect(result.lines.filter { $0.copyableSessionID != nil } == [.sessionID(fixtures.sessionID)])
        #expect(!result.lines.contains { $0.copyableSessionID == node.id || $0.copyableSessionID == node.runId })
        let withoutObservedSession = try #require(card(.managed(node.id, generation: 2), sessions: [], nodes: [node]))
        #expect(withoutObservedSession.lines.filter { $0.copyableSessionID != nil } == [.sessionID(fixtures.sessionID)])
        #expect(card(.managed(node.id, generation: 3), sessions: [session()], nodes: [node]) == nil)
        #expect(card(.managed(node.id, generation: 2), sessions: [session()], nodes: [node, node]) == nil)
        let stale = try #require(card(
            .managed(node.id, generation: 2), sessions: [session()], nodes: [node], availability: .stale
        ))
        #expect(stale.lines.allSatisfy { $0.copyableSessionID == nil })
    }

    @Test func unavailableAndAmbiguousSessionIdentitiesHaveNoCopyAction() throws {
        for liveness in [CopilotLiveness.ambiguous, .unknown] {
            var a = session(liveness: liveness)
            a.nodes = [.init(id: "child", parentID: nil, depth: 0, kind: .subagent, name: "Child",
                             state: .working, model: nil, ancestryUnresolved: false, hasChildren: false)]
            for target in [SidebarAgentHoverTarget.session(a.id), .child(sessionID: a.id, childID: "child")] {
                let result = try #require(card(target, sessions: [a]))
                #expect(result.lines.contains { $0.value == a.id.uuidString })
                #expect(result.lines.allSatisfy { $0.copyableSessionID == nil })
            }
        }
        let node = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "worker", label: "Starting",
            workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA, generation: 1,
            phase: "launching", availability: "busy", createdAt: now, updatedAt: now
        )
        let missing = try #require(card(.managed(node.id, generation: 1), sessions: [session()], nodes: [node]))
        #expect(missing.lines.allSatisfy { $0.copyableSessionID == nil })
        #expect(!missing.lines.contains { $0.title == "Session ID" })
        #expect(SidebarDetailLine(title: "Session ID", value: fixtures.sessionID.uuidString).copyableSessionID == nil)
    }

    @Test func generatingAllPreviewSubjectsLeavesEvidenceAndPreferencesUnchanged() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let state = (preferences.history, preferences.attention, preferences.layout, preferences.icons)
        var a = session()
        a.nodes = [.init(id: "child", parentID: nil, depth: 0, kind: .subagent, name: "Child",
                         state: .working, model: nil, ancestryUnresolved: false, hasChildren: false)]
        let before = a
        _ = card(.session(a.id), sessions: [a])
        _ = card(.child(sessionID: a.id, childID: "child"), sessions: [a])
        #expect(a == before)
        #expect(preferences.history == state.0 && preferences.attention == state.1)
        #expect(preferences.layout == state.2 && preferences.icons == state.3)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("CMUXMaestroSidebar/UI/SidebarAgentHoverContent.swift"), encoding: .utf8)
        for forbidden in ["SidebarPreferences", "SidebarNavigation", "markSeen(", "acknowledge(", "inspect(", "context.host"] {
            #expect(!source.contains(forbidden))
        }
    }
}
