import SwiftUI

enum SidebarAgentHoverTarget {
    case managed(UUID, generation: Int)
    case session(UUID)
    case child(sessionID: UUID, childID: String)
}

enum SidebarAgentHoverContent {
    /// The reported model is the one labelled value that had no copy action.
    static func copyable(_ lines: [SidebarDetailLine]) -> [SidebarDetailLine] {
        lines.map { line in
            guard line.copyableValue == nil, ["Model", "Last reported model"].contains(line.title),
                  !line.value.isEmpty else { return line }
            var result = line
            result.copyableValue = line.value
            return result
        }
    }

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
                  topology.workspaceBySurface[node.surfaceId] == node.workspaceId,
                  !SidebarPresentation.displacedManagedNodeIDs([node], observations: tree, now: now).contains(node.id)
            else { return nil }
            let allowed = Set([
                "Model", "Role", "Branch", "Worktree", "Last verified location",
                "Git evidence", "Git changes", SidebarSurfaceDirectory.title, "Session ID",
                "Observed", "Child history", "Workspace path", "Project path"
            ])
            var lines = SidebarPresentation.managedNodeDetails(node, hierarchy: hierarchy, tree: tree, now: now)
                .filter { allowed.contains($0.title) }
            lines = Self.copyable(lines)
            let current = availability == .ready || availability == .partial
            if !current && availability != .stale {
                lines = lines.map { line in
                    var result = line
                    result.copyableSessionID = nil
                    result.copyableValue = nil
                    return result
                }
            }
            let state = SidebarPresentation.managedState(node, availability: availability, now: now, tree: tree)
            return .init(
                id: "managed-\(id)-\(generation)", category: "Agent preview", title: node.title,
                subtitle: state.title,
                lines: lines,
                notice: current ? nil : "Managed observation is stale or unavailable. Last-known metadata is not live state.",
                pet: SidebarPresentation.managedPet(node, tree: tree, now: now).map {
                    .init(session: $0.session, choice: $0.choice, state: .resolve(
                        visual: state, needsInput: SidebarPresentation.managedNeedsInput(node, tree: tree, now: now)))
                }
            )
        case .session(let id):
            guard let session = uniqueSession(id, in: tree),
                  topology.workspaceBySurface[session.surfaceID] == session.workspaceID,
                  !SidebarPresentation.rowlessSessionIDs(tree, managed: managed.nodes, now: now).contains(id)
            else { return nil }
            return sessionCard(session, hierarchy: hierarchy, tree: tree, now: now)
        case .child(let sessionID, let childID):
            guard let session = uniqueSession(sessionID, in: tree),
                  topology.workspaceBySurface[session.surfaceID] == session.workspaceID,
                  !SidebarPresentation.rowlessSessionIDs(tree, managed: managed.nodes, now: now).contains(sessionID)
            else { return nil }
            let matches = session.nodes.filter { $0.id == childID }
            guard matches.count == 1, let child = matches.first else { return nil }
            guard isFresh(session, tree: tree, now: now) else {
                return .init(id: "child-\(sessionID)-\(childID)", category: "Agent preview", title: child.name,
                             notice: "Child observation is no longer current.")
            }
            let allowed = Set(["Name", "Kind", "Model", "Last reported model", "Ancestry", "Completion", "Child ID", "Parent session ID"])
            var lines = SidebarPresentation.nodeDetails(child, session: session).filter { allowed.contains($0.title) }
            lines += [
                .init(title: "Placement", value: "Observed child; native placement belongs to its parent session"),
                SidebarSurfaceDirectory.line(hierarchy.pathContext(
                    workspaceID: session.workspaceID, surfaceID: session.surfaceID
                ).workingDirectory, isParent: true, copyable: true)
            ]
            let notices = [session.childrenComplete && !session.treeDegraded ? nil : "Child history is incomplete; missing work is not assumed finished."]
                .compactMap { $0 }
            return .init(
                id: "child-\(sessionID)-\(childID)", category: child.kind == .subagent ? "Agent preview" : "Activity preview", title: child.name,
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
        tree.isCurrent(session, now: now)
    }

    private static func sessionCard(
        _ session: SidebarCopilotSession, hierarchy: HierarchySnapshot, tree: SidebarCopilotTree, now: Date
    ) -> SidebarHoverCardData {
        let unfocusable = session.statusOnly
        let title = SidebarPresentation.agentTitle(for: session, in: hierarchy)
        guard isFresh(session, tree: tree, now: now) else {
            return .init(id: "session-\(session.id)", category: "Agent preview", title: title,
                         notice: "Session observation is no longer current.")
        }
        let allowed = Set(["Model", "Last reported model", "Observed", "Child history", "Session ID"])
        var lines = SidebarPresentation.sessionDetails(session).filter { allowed.contains($0.title) }
        if !unfocusable { lines += SidebarPresentation.paths(hierarchy.pathContext(
            workspaceID: session.workspaceID, surfaceID: session.surfaceID
        ), copyable: true) }
        lines = Self.copyable(lines)
        let state = SidebarPresentation.sessionState(session)
        return .init(
            id: "session-\(session.id)", category: "Agent preview", title: title,
            subtitle: state.title,
            lines: lines, notice: session.liveness == .alive ? nil : "Live session ownership is not confirmed.",
            pet: unfocusable ? nil : .init(session: session.id, choice: session.petId, state: .resolve(
                visual: state, needsInput: SidebarPresentation.needsInput(session.attention)))
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
