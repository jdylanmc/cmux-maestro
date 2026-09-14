import Foundation

enum SidebarCopilotAvailability: Equatable {
    case waiting, loading, ready, partial, unavailable, hidden, disconnected
}

struct SidebarCopilotNode: Identifiable, Equatable {
    let id: String
    let parentID: String?
    let depth: Int
    let kind: CopilotWorkKind
    let name: String
    let state: CopilotWorkState
    let model: String?
    let ancestryUnresolved: Bool
    var hasChildren: Bool
}

struct SidebarCopilotSession: Identifiable, Equatable {
    let id: UUID
    let workspaceID: UUID
    let surfaceID: UUID
    let liveness: CopilotLiveness
    let state: CopilotWorkState
    let model: String?
    let observedAt: Date
    let nodes: [SidebarCopilotNode]
    let childrenComplete: Bool
    let treeDegraded: Bool
    let omittedChildrenCount: Int
    let omittedActiveChildrenCount: Int

    var knownRunningChildren: Int { nodes.filter { $0.state == .working }.count }
    var shortID: String { String(id.uuidString.prefix(8)).lowercased() }

    func visibleNodes(collapsed: Set<String>) -> [SidebarCopilotNode] {
        var hiddenBelowDepth: Int?
        return nodes.filter { node in
            if let depth = hiddenBelowDepth {
                if node.depth > depth { return false }
                hiddenBelowDepth = nil
            }
            if collapsed.contains(node.id) { hiddenBelowDepth = node.depth }
            return true
        }
    }
}

struct SidebarCopilotTree: Equatable {
    var availability: SidebarCopilotAvailability
    var sessions: [SidebarCopilotSession]
    var issues: [CopilotIssue]
    var generatedAt: Date?

    static let waiting = SidebarCopilotTree(
        availability: .waiting, sessions: [], issues: [], generatedAt: nil
    )
    static let maximumAge: TimeInterval = 8
    static let maximumNodes = 256
    static let maximumDepth = 12

    var knownRunningChildren: Int {
        sessions.reduce(0) { $0 + $1.knownRunningChildren }
    }

    var hasCompleteCounts: Bool {
        availability == .ready && sessions.allSatisfy {
            $0.childrenComplete && $0.nodes.allSatisfy { $0.state != .unknown }
        }
    }

    var omittedChildrenCount: Int { sessions.reduce(0) { $0 + $1.omittedChildrenCount } }
    var omittedActiveChildrenCount: Int { sessions.reduce(0) { $0 + $1.omittedActiveChildrenCount } }

    var summary: String {
        switch availability {
        case .waiting: return "Waiting for current-window surface metadata."
        case .loading: return "Loading Copilot history…"
        case .hidden: return "Copilot updates paused while the sidebar is hidden."
        case .disconnected: return "Copilot status unavailable while CMUX is disconnected."
        case .unavailable: return "Copilot status unavailable. No live state is inferred."
        case .ready, .partial:
            if issues.contains(.integrationNotInstalled) {
                return "Enable Copilot integration in CMUX Maestro. Restart Copilot sessions after enabling; existing sessions without identity records cannot be attached."
            }
            if issues.contains(.permissionDenied) {
                return "Copilot access was denied. Review integration access in CMUX Maestro."
            }
            if issues.contains(.loadingHistory) {
                return "Loading Copilot history. Known tasks are shown; missing tasks are not assumed finished."
            }
            if issues.contains(.noIdentityRecords) && sessions.isEmpty {
                return "No bound Copilot sessions on these surfaces. The integration loads when a Copilot session starts or restarts."
            }
            if availability == .partial {
                return "Partial Copilot data. Showing validated observations only; task totals may be incomplete."
            }
            if sessions.isEmpty {
                return "No bound Copilot sessions on current-window surfaces."
            }
            return "Copilot observations refreshed about every 2 seconds."
        }
    }

    static func project(
        _ snapshot: CopilotSnapshot,
        onto topology: SidebarTopology,
        now: Date
    ) -> SidebarCopilotTree {
        guard topology.canReadSessions else { return .waiting }
        guard isFresh(snapshot.generatedAt, now: now) else {
            return SidebarCopilotTree(
                availability: .unavailable, sessions: [], issues: [], generatedAt: nil
            )
        }
        let groups = Dictionary(grouping: snapshot.sessions, by: \.sessionID)
        var rejected = groups.values.contains { $0.count != 1 }
        var sessions: [SidebarCopilotSession] = []
        for observation in snapshot.sessions {
            guard groups[observation.sessionID]?.count == 1,
                  let workspaceID = topology.workspaceBySurface[observation.surfaceID],
                  isFresh(observation.observedAt, now: now),
                  observation.observedAt <= snapshot.generatedAt.addingTimeInterval(1) else {
                rejected = true
                continue
            }
            let tree = childTree(observation.children, liveness: observation.liveness)
            let complete = snapshot.isComplete && snapshot.issues.isEmpty
                && observation.liveness == .alive && !tree.degraded
            sessions.append(SidebarCopilotSession(
                id: observation.sessionID,
                workspaceID: workspaceID,
                surfaceID: observation.surfaceID,
                liveness: observation.liveness,
                state: trustworthyState(observation.state, liveness: observation.liveness),
                model: displayMetadata(observation.model),
                observedAt: observation.observedAt,
                nodes: tree.nodes,
                childrenComplete: complete,
                treeDegraded: tree.degraded,
                omittedChildrenCount: tree.omitted,
                omittedActiveChildrenCount: tree.omittedActive
            ))
        }
        return SidebarCopilotTree(
            availability: snapshot.isComplete && snapshot.issues.isEmpty && !rejected
                && !sessions.contains(where: \.treeDegraded) ? .ready : .partial,
            sessions: sessions,
            issues: snapshot.issues,
            generatedAt: snapshot.generatedAt
        )
    }

    static func isFresh(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= -1 && age <= maximumAge
    }

    private static func trustworthyState(
        _ state: CopilotWorkState, liveness: CopilotLiveness
    ) -> CopilotWorkState {
        if liveness == .alive { return state }
        switch state {
        case .completed, .failed, .cancelled: return state
        default: return .unknown
        }
    }

    private static func childTree(
        _ children: [CopilotChildWork], liveness: CopilotLiveness
    ) -> (nodes: [SidebarCopilotNode], degraded: Bool, omitted: Int, omittedActive: Int) {
        let groups = Dictionary(grouping: children, by: \.id)
        let validated = children.filter { !$0.id.isEmpty && groups[$0.id]?.count == 1 }
        let byID = Dictionary(uniqueKeysWithValues: validated.map { ($0.id, $0) })
        let active = validated.filter {
            let state = trustworthyState($0.state, liveness: liveness)
            return state == .working || state == .blocked
        }
        var selectedIDs: Set<String> = []
        var valid: [CopilotChildWork] = []
        func select(_ child: CopilotChildWork) {
            guard valid.count < maximumNodes, selectedIDs.insert(child.id).inserted else { return }
            valid.append(child)
        }
        for child in active { select(child) }
        // Reserve ancestry before filling remaining capacity with historical work.
        var walkedAncestry: Set<String> = []
        for child in active where selectedIDs.contains(child.id) {
            var parent = child.parentID
            while valid.count < maximumNodes, let id = parent, let ancestor = byID[id],
                  walkedAncestry.insert(id).inserted {
                select(ancestor)
                parent = ancestor.parentID
            }
        }
        for child in validated { select(child) }
        let omitted = validated.count - valid.count
        let omittedActive = active.filter { !selectedIDs.contains($0.id) }.count
        let ids = Set(valid.map(\.id))
        var degraded = omitted > 0 || validated.count != children.count
        var byParent: [String: [CopilotChildWork]] = [:]
        var roots: [CopilotChildWork] = []
        var detachedRoots: [CopilotChildWork] = []
        for child in valid {
            if let parent = child.parentID, ids.contains(parent), parent != child.id {
                byParent[parent, default: []].append(child)
            } else {
                if child.parentID != nil {
                    degraded = true
                    detachedRoots.append(child)
                } else {
                    roots.append(child)
                }
            }
        }
        var visited: Set<String> = []
        var nodes: [SidebarCopilotNode] = []
        func visit(_ child: CopilotChildWork, parentID: String?, depth: Int, unresolved: Bool) {
            guard visited.insert(child.id).inserted else {
                degraded = true
                return
            }
            let descendants = byParent[child.id] ?? []
            let nodeIndex = nodes.count
            nodes.append(SidebarCopilotNode(
                id: child.id, parentID: parentID, depth: depth, kind: child.kind,
                name: displayMetadata(child.name) ?? child.kind.rawValue.capitalized,
                state: trustworthyState(child.state, liveness: liveness),
                model: displayMetadata(child.model),
                ancestryUnresolved: unresolved,
                hasChildren: false
            ))
            guard depth < maximumDepth else {
                if !descendants.isEmpty { degraded = true }
                return
            }
            for descendant in descendants {
                visit(descendant, parentID: child.id, depth: depth + 1, unresolved: unresolved)
            }
            nodes[nodeIndex].hasChildren = nodes.count > nodeIndex + 1
        }
        for root in roots { visit(root, parentID: nil, depth: 0, unresolved: false) }
        for root in detachedRoots { visit(root, parentID: nil, depth: 0, unresolved: true) }
        // Disconnected cycles and capped branches remain visible as detached roots.
        for child in valid where !visited.contains(child.id) {
            degraded = true
            visit(child, parentID: nil, depth: 0, unresolved: true)
        }
        return (nodes, degraded, omitted, omittedActive)
    }

    private static func displayMetadata(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0)
        }
        let text = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : String(text.prefix(100))
    }
}
