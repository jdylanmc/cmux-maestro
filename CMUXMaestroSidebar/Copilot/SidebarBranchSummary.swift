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
