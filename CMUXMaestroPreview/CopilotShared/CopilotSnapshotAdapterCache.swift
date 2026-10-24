import Foundation

/// Caches value conversion only; every read still supplies current evidence and placement.
actor CopilotSnapshotAdapterCache {
    private struct Entry {
        let input: CopilotSessionObservation
        let output: AgentSessionSnapshotItem
    }

    private var placement: [UUID: UUID]?
    private var workspaces: [CMUXWorkspaceSnapshot] = []
    private var entries: [UUID: Entry] = [:]
    private(set) var sessionBuildCount = 0
    private(set) var workspaceBuildCount = 0
    var retainedSessionCount: Int { entries.count }

    func snapshot(_ source: CopilotSnapshot, workspaceBySurface: [UUID: UUID]) -> AgentSessionSnapshot {
        if placement != workspaceBySurface {
            placement = workspaceBySurface
            workspaces = CopilotSnapshotAdapter.workspaces(workspaceBySurface)
            workspaceBuildCount += 1
            entries.removeAll()
        }
        let present = Set(source.sessions.map(\.sessionID))
        entries = entries.filter { present.contains($0.key) }
        let sessions = source.sessions.map { observation in
            var input = observation
            input.observedAt = .distantPast
            var item: AgentSessionSnapshotItem
            if let cached = entries[observation.sessionID], cached.input == input {
                item = cached.output
            } else {
                item = CopilotSnapshotAdapter.session(observation, workspaceBySurface: workspaceBySurface)
                sessionBuildCount += 1
                if entries[observation.sessionID] != nil || entries.count < CopilotReaderLimits().maximumSessions {
                    entries[observation.sessionID] = Entry(input: input, output: item)
                }
            }
            item.observedAt = observation.observedAt
            return item
        }
        return AgentSessionSnapshot(
            generatedAt: source.generatedAt, workspaces: workspaces, sessions: sessions,
            issues: source.issues.map { .init(rawValue: $0.rawValue) }, completeness: .known(source.isComplete)
        )
    }
}
