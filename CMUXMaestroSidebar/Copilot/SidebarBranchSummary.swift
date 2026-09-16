import Foundation

enum SidebarCountText {
    static func copilotSessions(_ count: Int) -> String {
        "\(count) Copilot \(count == 1 ? "session" : "sessions")"
    }

    static func runningChildren(_ count: Int, known: Bool = false) -> String {
        "\(count) \(known ? "known " : "")child \(count == 1 ? "task" : "tasks") running"
    }

    static func attention(_ count: Int) -> String {
        "\(count) \(count == 1 ? "needs" : "need") attention"
    }

    static func attentionRows(_ count: Int) -> String {
        "\(count) session/child \(count == 1 ? "row needs" : "rows need") attention"
    }
}

struct SidebarBranchSummary: Equatable {
    var running = 0
    var blocked = 0
    var attention = 0
    var incomplete = false
    var omittedActive = 0

    init(nodes: [SidebarCopilotNode]) {
        for node in nodes {
            if node.state == .working { running += 1 }
            if node.state == .blocked || node.attention.contains(where: { $0.kind.isBlocking }) { blocked += 1 }
            if !node.attention.isEmpty || node.attentionDegraded { attention += 1 }
            if node.state == .unknown || node.attentionDegraded { incomplete = true }
        }
    }

    init(sessions: [SidebarCopilotSession], complete: Bool = true) {
        self.init(nodes: sessions.flatMap(\.nodes))
        incomplete = incomplete || !complete
        for session in sessions {
            if session.state == .working { running += 1 }
            if session.state == .blocked || session.attention.contains(where: { $0.kind.isBlocking }) { blocked += 1 }
            if !session.attention.isEmpty || session.attentionDegraded { attention += 1 }
            incomplete = incomplete || !session.childrenComplete || session.state == .unknown || session.attentionDegraded
            omittedActive += session.omittedActiveChildrenCount
        }
    }

    mutating func include(
        managed nodes: [SidebarOrchestrationNode],
        availability: SidebarOrchestrationAvailability, now: Date
    ) {
        for node in nodes {
            let age = now.timeIntervalSince(node.updatedAt)
            guard (availability == .ready || availability == .partial),
                  age >= -1, age <= SidebarOrchestrationReader.staleInterval else {
                incomplete = true
                continue
            }
            switch SidebarOrchestrationPhase(rawValue: node.phase) {
            case .turnRunning: running += 1
            case .reportedBlocked: blocked += 1
            case .reportMissing, .permissionDenied, .reportedFailed, .turnFailed,
                 .launchFailed, .startupFailed: attention += 1
            case .none: incomplete = true
            default: break
            }
        }
    }

    var lines: [String] {
        var result = ["\(running) known running · \(blocked) blocked · \(SidebarCountText.attention(attention))"]
        if omittedActive > 0 { result.append("\(omittedActive) additional working/blocked tasks exceed display limits") }
        if incomplete { result.append("Counts may be incomplete") }
        return result
    }
}

struct SidebarChildRow: Identifiable, Equatable {
    let node: SidebarCopilotNode
    let expansionID: SidebarExpansionID
    let expanded: Bool
    let collapsedSummary: SidebarBranchSummary?
    var id: String { node.id }
}

extension SidebarCopilotSession {
    var outlineNodes: [SidebarCopilotNode] {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var retained = Set(nodes.filter {
            ($0.kind != .skill && $0.kind != .shell)
                || $0.state == .working || $0.state == .blocked || $0.state == .failed
                || !$0.attention.isEmpty || $0.attentionDegraded || $0.ancestryUnresolved
        }.map(\.id))
        for node in nodes where retained.contains(node.id) {
            var parent = node.parentID
            while let id = parent, let ancestor = byID[id], retained.insert(id).inserted {
                parent = ancestor.parentID
            }
        }
        return nodes.filter { retained.contains($0.id) }.map { node in
            var row = node
            row.hasChildren = nodes.contains { $0.parentID == node.id && retained.contains($0.id) }
            return row
        }
    }

    var secondaryActivity: [SidebarCopilotNode] {
        let primary = Set(outlineNodes.map(\.id))
        return nodes.filter { !primary.contains($0.id) }
    }

    func outlineChildRows(layout: SidebarLayoutSettings) -> [SidebarChildRow] {
        let primary = Dictionary(uniqueKeysWithValues: outlineNodes.map { ($0.id, $0) })
        return childRows(layout: layout).compactMap { row in
            guard let node = primary[row.id] else { return nil }
            return SidebarChildRow(
                node: node, expansionID: row.expansionID, expanded: row.expanded,
                collapsedSummary: node.hasChildren ? row.collapsedSummary : nil
            )
        }
    }

    func childRows(layout: SidebarLayoutSettings) -> [SidebarChildRow] {
        let collapsed = Set(nodes.compactMap { node in
            layout.isExpanded(.child(node.id, sessionID: id)) ? nil : node.id
        })
        return visibleNodes(collapsed: collapsed).map { node in
            let expanded = !collapsed.contains(node.id)
            let descendants: [SidebarCopilotNode]
            if !expanded, let index = nodes.firstIndex(where: { $0.id == node.id }) {
                descendants = Array(nodes.dropFirst(index + 1).prefix { $0.depth > node.depth })
            } else {
                descendants = []
            }
            var summary = SidebarBranchSummary(nodes: descendants)
            // Display-capped descendants cannot be attributed safely to a particular branch.
            summary.incomplete = summary.incomplete || !childrenComplete
            return SidebarChildRow(
                node: node, expansionID: .child(node.id, sessionID: id), expanded: expanded,
                collapsedSummary: !expanded && node.hasChildren ? summary : nil
            )
        }
    }
}
