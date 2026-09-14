import Foundation

@MainActor
struct PreferenceAttentionFixture {
    let sessionID = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
    let eventID = UUID(uuidString: "70000000-0000-0000-0000-000000000002")!
    let workspaceID = UUID(uuidString: "70000000-0000-0000-0000-000000000003")!
    let surfaceID = UUID(uuidString: "70000000-0000-0000-0000-000000000004")!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func key(_ owner: String?) -> SidebarAcknowledgedOutcome {
        .init(sessionID: sessionID, ownerID: owner, evidence: .init(source: "copilot.events", eventID: eventID))
    }

    func tree(
        owners: [String] = ["a", "b"], blocked: Bool = true,
        history: SidebarHistorySettings = .init(), attention: SidebarAttentionSettings = .init()
    ) -> SidebarCopilotTree {
        var children = owners.map { owner in
            CopilotChildWork(
                id: owner, parentID: nil, kind: .subagent, name: "Synthetic outcome", state: .failed, model: nil,
                terminalEvent: .init(id: eventID, timestamp: now.addingTimeInterval(-60)),
                attention: [.init(kind: .error, evidence: key(owner).evidence, occurredAt: now.addingTimeInterval(-60))]
            )
        }
        if blocked {
            children.append(.init(
                id: "blocked", parentID: owners.first, kind: .subagent, name: "Synthetic blocker", state: .blocked,
                model: nil, attention: [.init(kind: .permission, evidence: key("blocked").evidence, occurredAt: now)]
            ))
        }
        let snapshot = CopilotSnapshot(generatedAt: now, sessions: [
            .init(sessionID: sessionID, surfaceID: surfaceID, launchWorkspaceID: workspaceID,
                  liveness: .alive, state: .idle, model: nil, children: children, observedAt: now)
        ], issues: [], isComplete: true)
        let hierarchy = HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: true, surfaceMetadataAvailable: true, workspacePathsAvailable: false,
            workspaces: [
                .init(id: workspaceID, title: .available("Synthetic workspace"), detail: .unavailable,
                      isSelected: .available(true), isPinned: .available(false), unreadCount: .available(0),
                      rootPath: .unavailable, projectRootPath: .unavailable, surfaces: .available([
                        .init(id: surfaceID, title: "Synthetic surface", kind: .terminal, isFocused: true,
                              isPinned: false, unreadCount: 0, workingDirectory: .unavailable)
                      ]))
            ], windowID: UUID(uuidString: "70000000-0000-0000-0000-000000000005")!
        )
        return SidebarCopilotTree.project(snapshot, onto: SidebarTopology(hierarchy), now: now, history: history, attention: attention)
    }
}
