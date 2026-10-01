import Foundation

// Existing reader-shaped fixtures now exercise the production adapter before
// reaching the neutral-only consumer. No reverse adapter exists.
@MainActor
extension SidebarCopilotTree {
    static func project(
        _ source: CopilotSnapshot, onto topology: SidebarTopology, now: Date,
        history: SidebarHistorySettings = .init(), attention: SidebarAttentionSettings = .init(),
        revealingIdleTasksIn: Set<UUID> = []
    ) -> SidebarCopilotTree {
        project(CopilotSnapshotAdapter.snapshot(source, workspaceBySurface: topology.workspaceBySurface),
                onto: topology, now: now, history: history, attention: attention,
                revealingIdleTasksIn: revealingIdleTasksIn)
    }
}

@MainActor
func neutralRead(
    _ read: @escaping @Sendable (Set<UUID>) async throws -> CopilotSnapshot
) -> SidebarCopilotPolling.Read {
    { placements in
        CopilotSnapshotAdapter.snapshot(try await read(Set(placements.keys)), workspaceBySurface: placements)
    }
}
