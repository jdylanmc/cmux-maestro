import Foundation

/// Placement keys retain identity, freshness and a bounded protection summary, not child history.
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
        fileprivate var surfaceOwners: [Surface: [UUID]] = [:]
        fileprivate var exactOwners: [Identity: [UUID]] = [:]
        fileprivate var identityCounts: [UUID: Int] = [:]
        fileprivate var sessionIndices: [Identity: [Int]] = [:]

        func ownedSessionIndices(managed: [SidebarOrchestrationNode]) -> [UUID: [Int]] {
            let allowed = Set(managed.map(\.id))
            var result: [UUID: [Int]] = [:]
            for (identity, candidates) in exactOwners where identityCounts[identity.session] == 1 {
                let exact = candidates.filter { allowed.contains($0) }
                guard exact.count == 1, let owner = exact.first, !displaced.contains(owner) else { continue }
                result[owner, default: []] += sessionIndices[identity] ?? []
            }
            return result
        }

        /// Sub-groups restrict owners, not the evidence used to attest a unique session.
        func materialize(
            _ sessions: [SidebarCopilotSession], managed: [SidebarOrchestrationNode]
        ) -> [SidebarSessionPlacement] {
            let allowed = Set(managed.map(\.id))
            return sessions.map { session in
                let surface = Surface(workspace: session.workspaceID, surface: session.surfaceID)
                let exact = (exactOwners[Identity(surface: surface, session: session.id)] ?? []).filter { allowed.contains($0) }
                let owner = surfaceOwners[surface]?.first { allowed.contains($0) }
                let content = exact.count == 1 && identityCounts[session.id] == 1
                    && !displaced.contains(exact[0]) ? exact[0] : nil
                return SidebarSessionPlacement(session: session, managedNodeID: owner, contentOwnerID: content)
            }
        }
    }

    fileprivate struct Surface: Hashable {
        let workspace: UUID
        let surface: UUID
    }

    fileprivate struct Identity: Hashable {
        let surface: Surface
        let session: UUID
    }

    private struct Session: Equatable {
        let id: UUID
        let workspace: UUID
        let surface: UUID
        let alive: Bool
        let dead: Bool
        let fresh: Bool
        let withinEnvelope: Bool
        let bindingProcess: AgentBindingProcess?
        let canYieldUnknown: Bool
        let statusOnly: Bool
    }

    private struct Managed: Equatable {
        let id: UUID
        let workspace: UUID
        let surface: UUID
        let session: UUID?
        let canYieldUnknown: Bool
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
                        } ?? false,
                        bindingProcess: tree.sessions[index].bindingProcess,
                        canYieldUnknown: SidebarPresentation.canYieldUnknownSession(tree.sessions[index]),
                        statusOnly: tree.sessions[index].statusOnly)
            },
            managed: managed.map {
                Managed(id: $0.id, workspace: $0.workspaceId, surface: $0.surfaceId, session: $0.copilotSessionId,
                        canYieldUnknown: SidebarPresentation.canYieldUnknownRoot($0))
            },
            current: [.ready, .partial].contains(tree.availability) && !tree.issues.contains(.permissionDenied)
                && tree.generatedAt.map { SidebarCopilotTree.isFresh($0, now: now) } == true
        )
        guard key != input else { return snapshot }
        computationCount += 1
        var result = Snapshot()
        let identityCounts = input.sessions.reduce(into: [UUID: Int]()) { $0[$1.id, default: 0] += 1 }
        result.identityCounts = identityCounts
        result.displaced = SidebarPresentation.displacedManagedNodeIDs(managed, observations: tree, now: now)
        let owners = input.managed.filter { !result.displaced.contains($0.id) }
        for node in input.managed {
            let surface = Surface(workspace: node.workspace, surface: node.surface)
            if !result.displaced.contains(node.id) {
                result.surfaceOwners[surface, default: []].append(node.id)
            }
            if let session = node.session {
                result.exactOwners[Identity(surface: surface, session: session), default: []].append(node.id)
            }
        }
        for index in input.sessions.indices {
            let session = input.sessions[index]
            result.sessionIndices[Identity(
                surface: Surface(workspace: session.workspace, surface: session.surface), session: session.id
            ), default: []].append(index)
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
