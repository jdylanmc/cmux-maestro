import Foundation

/// Placement depends on identity and freshness, never a session's potentially large child history.
@MainActor
final class SidebarPlacementCache {
    struct Placement: Equatable {
        let sessionIndex: Int
        let managedNodeID: UUID?
        let contentOwnerID: UUID?
        var hasNoSurfaceRow: Bool { managedNodeID != nil && contentOwnerID == nil }
    }

    struct Snapshot {
        var byWorkspace: [UUID: [Placement]] = [:]
        var displaced: Set<UUID> = []
    }

    private struct Session: Equatable {
        let id: UUID
        let workspace: UUID
        let surface: UUID
        let alive: Bool
        let dead: Bool
        let fresh: Bool
        let withinEnvelope: Bool
    }

    private struct Managed: Equatable {
        let id: UUID
        let workspace: UUID
        let surface: UUID
        let session: UUID?
    }

    private struct Key: Equatable {
        let sessions: [Session]
        let managed: [Managed]
        let current: Bool
    }

    private var key: Key?
    private var snapshot = Snapshot()
    private(set) var computationCount = 0

    func placements(tree: SidebarCopilotTree, managed: [SidebarOrchestrationNode], now: Date) -> Snapshot {
        let input = Key(
            sessions: tree.sessions.indices.map { index in
                Session(id: tree.sessions[index].id, workspace: tree.sessions[index].workspaceID,
                        surface: tree.sessions[index].surfaceID,
                        alive: tree.sessions[index].liveness == .alive,
                        dead: tree.sessions[index].liveness == .dead,
                        fresh: SidebarCopilotTree.isFresh(tree.sessions[index].observedAt, now: now),
                        withinEnvelope: tree.generatedAt.map {
                            tree.sessions[index].observedAt <= $0.addingTimeInterval(1)
                        } ?? false)
            },
            managed: managed.map {
                Managed(id: $0.id, workspace: $0.workspaceId, surface: $0.surfaceId, session: $0.copilotSessionId)
            },
            current: [.ready, .partial].contains(tree.availability) && !tree.issues.contains(.permissionDenied)
                && tree.generatedAt.map { SidebarCopilotTree.isFresh($0, now: now) } == true
        )
        computationCount += 1
        var result = Snapshot()
        let identityCounts = input.sessions.reduce(into: [UUID: Int]()) { $0[$1.id, default: 0] += 1 }
        if input.current {
            for node in input.managed {
                guard let ownSession = node.session else { continue }
                let candidates = input.sessions.indices.filter {
                    input.sessions[$0].workspace == node.workspace && input.sessions[$0].surface == node.surface
                        && !input.sessions[$0].dead
                }
                guard candidates.count == 1, let index = candidates.first else { continue }
                let session = input.sessions[index]
                if session.alive && session.fresh && session.withinEnvelope
                    && identityCounts[session.id] == 1 && session.id != ownSession {
                    result.displaced.insert(node.id)
                }
            }
        }
        let owners = input.managed.filter { !result.displaced.contains($0.id) }
        for index in input.sessions.indices {
            let session = input.sessions[index]
            let exact = input.managed.filter {
                $0.workspace == session.workspace && $0.surface == session.surface && $0.session == session.id
            }
            let owner = owners.first { $0.workspace == session.workspace && $0.surface == session.surface }
            let content = exact.count == 1 && identityCounts[session.id] == 1
                && !result.displaced.contains(exact[0].id) ? exact[0].id : nil
            result.byWorkspace[session.workspace, default: []].append(
                Placement(sessionIndex: index, managedNodeID: owner?.id, contentOwnerID: content)
            )
        }
        key = input
        snapshot = result
        return result
    }
}
