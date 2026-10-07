import SwiftUI

enum SidebarAgentHoverTarget {
    case managed(UUID, generation: Int)
    case session(UUID)
    case child(sessionID: UUID, childID: String)
}

enum SidebarAgentHoverContent {
    static func card(
        for target: SidebarAgentHoverTarget, hierarchy: HierarchySnapshot, connected: Bool,
        tree: SidebarCopilotTree, managed: SidebarOrchestrationSnapshot,
        availability: SidebarOrchestrationAvailability, now: Date
    ) -> SidebarHoverCardData? {
        guard connected else { return nil }
        let topology = SidebarTopology(hierarchy)
        switch target {
        case .managed(let id, let generation):
            let matches = managed.nodes.filter { $0.id == id && $0.generation == generation }
            guard matches.count == 1, let node = matches.first,
                  topology.workspaceBySurface[node.surfaceId] == node.workspaceId else { return nil }
            let retained = SidebarPresentation.displacedManagedNodeIDs([node], observations: tree, now: now).contains(node.id)
            let allowed = Set([
                "Context", "Focus", "Model", "Role", "Branch", "Worktree", "Last verified location",
                "Git evidence", "Git changes", SidebarSurfaceDirectory.title, "Session ID",
                "Observed", "Child history", "Workspace path", "Project path"
            ])
            var lines = SidebarPresentation.managedNodeDetails(node, hierarchy: hierarchy, tree: tree, now: now)
                .filter { allowed.contains($0.title) }
            let current = availability == .ready || availability == .partial
            if !current && availability != .stale {
                lines = lines.map { line in
                    var result = line
                    result.copyableSessionID = nil
                    result.copyableValue = nil
                    return result
                }
            }
            return .init(
                id: "managed-\(id)-\(generation)", category: retained ? "Work context" : "Agent preview", title: node.label,
                subtitle: SidebarPresentation.managedState(node, availability: availability, now: now, tree: tree).title,
                lines: lines,
                notice: retained ? SidebarPresentation.retainedFocusUnavailable
                    : current ? nil : "Managed observation is stale or unavailable. Last-known metadata is not live state."
            )
        case .session(let id):
            guard let session = uniqueSession(id, in: tree),
                  topology.workspaceBySurface[session.surfaceID] == session.workspaceID else { return nil }
            return sessionCard(session, hierarchy: hierarchy, tree: tree, now: now,
                               retained: SidebarPresentation.retainedSessionIDs(tree, managed: managed.nodes, now: now).contains(id))
        case .child(let sessionID, let childID):
            guard let session = uniqueSession(sessionID, in: tree),
                  topology.workspaceBySurface[session.surfaceID] == session.workspaceID else { return nil }
            let matches = session.nodes.filter { $0.id == childID }
            guard matches.count == 1, let child = matches.first else { return nil }
            guard isFresh(session, tree: tree, now: now) else {
                return .init(id: "child-\(sessionID)-\(childID)", category: "Agent preview", title: child.name,
                             notice: "Child observation is no longer current.")
            }
            let allowed = Set(["Name", "Kind", "Model", "Last reported model", "Ancestry", "Completion", "Child ID", "Parent session ID"])
            let retained = SidebarPresentation.retainedSessionIDs(tree, managed: managed.nodes, now: now).contains(sessionID)
            var lines = SidebarPresentation.nodeDetails(child, session: session).filter { allowed.contains($0.title) }
            lines += [
                .init(title: "Placement", value: "Observed child; native placement belongs to its parent session"),
                SidebarSurfaceDirectory.line(hierarchy.pathContext(
                    workspaceID: session.workspaceID, surfaceID: session.surfaceID
                ).workingDirectory, isParent: true, retained: retained, copyable: true)
            ]
            let notices = [retained ? SidebarPresentation.retainedFocusUnavailable : nil,
                session.childrenComplete && !session.treeDegraded ? nil : "Child history is incomplete; missing work is not assumed finished."]
                .compactMap { $0 }
            return .init(
                id: "child-\(sessionID)-\(childID)", category: retained ? "Context activity" : child.kind == .subagent ? "Agent preview" : "Activity preview", title: child.name,
                subtitle: session.liveness == .alive ? SidebarPresentation.state(child.state).title : "Last reported: \(child.state.rawValue)",
                lines: lines, notice: notices.isEmpty ? nil : notices.joined(separator: " ")
            )
        }
    }

    private static func uniqueSession(_ id: UUID, in tree: SidebarCopilotTree) -> SidebarCopilotSession? {
        let matches = tree.sessions.filter { $0.id == id }
        return matches.count == 1 ? matches.first : nil
    }

    private static func isFresh(_ session: SidebarCopilotSession, tree: SidebarCopilotTree, now: Date) -> Bool {
        [.ready, .partial].contains(tree.availability)
            && tree.generatedAt.map { SidebarCopilotTree.isFresh($0, now: now) } == true
            && SidebarCopilotTree.isFresh(session.observedAt, now: now)
    }

    private static func sessionCard(
        _ session: SidebarCopilotSession, hierarchy: HierarchySnapshot, tree: SidebarCopilotTree, now: Date,
        retained: Bool = false
    ) -> SidebarHoverCardData {
        let title = SidebarPresentation.surfaceTitle(for: session, in: hierarchy)
        guard isFresh(session, tree: tree, now: now) else {
            return .init(id: "session-\(session.id)", category: "Agent preview", title: title,
                         notice: "Session observation is no longer current.")
        }
        let allowed = Set(["Model", "Observed", "Child history", "Session ID"])
        var lines = SidebarPresentation.sessionDetails(session).filter { allowed.contains($0.title) }
        if session.liveness != .alive {
            lines = lines.map { $0.title == "Model" ? .init(title: "Last reported model", value: $0.value) : $0 }
        }
        if !retained { lines += SidebarPresentation.paths(hierarchy.pathContext(
            workspaceID: session.workspaceID, surfaceID: session.surfaceID
        ), copyable: true) }
        return .init(
            id: "session-\(session.id)", category: retained ? "Session context" : "Agent preview", title: title,
            subtitle: SidebarPresentation.sessionState(session).title,
            lines: lines, notice: retained ? SidebarPresentation.retainedFocusUnavailable
                : session.liveness == .alive ? nil : "Live session ownership is not confirmed."
        )
    }
}

private struct SidebarAgentHoverProviderKey: EnvironmentKey {
    static let defaultValue: (SidebarAgentHoverTarget) -> SidebarHoverCardData? = { _ in nil }
}

extension EnvironmentValues {
    var sidebarAgentHoverProvider: (SidebarAgentHoverTarget) -> SidebarHoverCardData? {
        get { self[SidebarAgentHoverProviderKey.self] }
        set { self[SidebarAgentHoverProviderKey.self] = newValue }
    }
}

private struct SidebarAgentHoverModifier: ViewModifier {
    let target: SidebarAgentHoverTarget?
    @Environment(\.sidebarAgentHoverProvider) private var provider
    func body(content: Content) -> some View {
        SidebarHoverRegion(data: target.flatMap(provider)) { content }
    }
}

extension View {
    func agentHoverPreview(_ target: SidebarAgentHoverTarget?) -> some View {
        modifier(SidebarAgentHoverModifier(target: target))
    }
}
