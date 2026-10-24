import Foundation

/// Owned by one poller. Global identity checks run before any session is reused.
final class SidebarSessionProjectionCache {
    private struct Context: Equatable {
        let topology: SidebarTopology
        let schema: SnapshotSchemaVersion
        let issues: [AgentSnapshotIssue]
        let complete: Bool
        let history: SidebarHistorySettings
        let attention: SidebarAttentionSettings
        let revealingIdleTasksIn: Set<UUID>
    }

    private var context: Context?
    private var entries: [UUID: SidebarCopilotProjectionCache] = [:]
    private(set) var computationCount = 0
    private(set) var lastPassComputationCount = 0
    private(set) var childAssessmentCount = 0

    func assessment(snapshot: AgentSessionSnapshot, index: Int) -> AgentSessionObservationAssessment {
        childAssessmentCount += 1
        return snapshot.assess(snapshot.sessions[index], at: "sessions[\(index)]")
    }

    func prepare(
        snapshot: AgentSessionSnapshot, topology: SidebarTopology, history: SidebarHistorySettings,
        attention: SidebarAttentionSettings, revealingIdleTasksIn: Set<UUID>
    ) {
        let next = Context(
            topology: topology, schema: snapshot.schemaVersion, issues: snapshot.globalIssues,
            complete: snapshot.isCompleteApartFromSessionIssues, history: history,
            attention: attention, revealingIdleTasksIn: revealingIdleTasksIn
        )
        if context != next { entries.removeAll(); context = next }
        let present = Set(snapshot.sessions.compactMap { UUID(uuidString: $0.identity.sessionID) })
        entries = entries.filter { present.contains($0.key) }
        lastPassComputationCount = 0
    }

    func reused(
        id: UUID, snapshot: AgentSessionSnapshot, index: Int, now: Date
    ) -> (session: SidebarCopilotSession, nextExpiry: Date?)? {
        guard let cached = entries[id], cached.matches(input(snapshot, index: index), now: now),
              var session = cached.tree.sessions.first,
              let observedAt = snapshot.sessions[index].observedAt else { return nil }
        session.observedAt = observedAt
        return (session, cached.tree.nextHistoryExpiry)
    }

    func store(
        _ session: SidebarCopilotSession, nextExpiry: Date?, snapshot: AgentSessionSnapshot, index: Int, now: Date
    ) {
        computationCount += 1
        lastPassComputationCount += 1
        entries[session.id] = SidebarCopilotProjectionCache(
            snapshot: input(snapshot, index: index),
            tree: .init(availability: session.treeDegraded ? .partial : .ready, sessions: [session], issues: [],
                        generatedAt: snapshot.generatedAt, nextHistoryExpiry: nextExpiry),
            now: now
        )
    }

    func removeAll() {
        entries.removeAll()
        context = nil
    }

    private func input(_ snapshot: AgentSessionSnapshot, index: Int) -> AgentSessionSnapshot {
        .init(schemaVersion: snapshot.schemaVersion, generatedAt: snapshot.generatedAt,
              workspaces: snapshot.workspaces, sessions: [snapshot.sessions[index]],
              issues: context?.issues ?? snapshot.globalIssues, completeness: snapshot.completeness)
    }
}
