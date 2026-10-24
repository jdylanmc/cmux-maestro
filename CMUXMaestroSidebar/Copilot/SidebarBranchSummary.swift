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
    var taskCount = 0
    var running = 0
    var blocked = 0
    var attention = 0
    var incomplete = false
    var omittedActive = 0

    init(nodes: [SidebarCopilotNode]) {
        for node in nodes {
            if node.isInternalTask { taskCount += 1 }
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
            incomplete = incomplete || !session.childrenComplete || session.state == .unknown
                || session.attentionDegraded || session.internalTaskCountsIncomplete
            omittedActive += session.omittedActiveChildrenCount
        }
    }

    /// Child work only; the owning session already has its own state badge.
    init(childrenOf sessions: [SidebarCopilotSession]) {
        self.init(nodes: sessions.flatMap(\.nodes))
        for session in sessions {
            incomplete = incomplete || !session.childrenComplete || session.internalTaskCountsIncomplete
                || session.treeDegraded || session.attentionDegraded
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

struct SidebarChildSection: Identifiable {
    let rows: [SidebarChildRow]
    let taskDisclosure: SidebarExpansionID?
    var id: String { rows[0].id }
}

extension SidebarCopilotSession {
    var unresolvedFragments: [SidebarCopilotNode] {
        unresolvedFragments(layout: .init())
    }

    func unresolvedFragments(layout: SidebarLayoutSettings, taskboard: Bool = false) -> [SidebarCopilotNode] {
        let shown = shownNodes(layout: layout, taskboard: taskboard)
        let compacted = compactedFragmentIDs(in: shown)
        return shown.filter { compacted.contains($0.id) }
    }

    private func compactedFragmentIDs(in shown: [SidebarCopilotNode]) -> Set<String> {
        var protectedParents: Set<String> = []
        var compacted: Set<String> = []
        // Nodes are in preorder. A compacted fragment cannot protect another fragment.
        for node in shown.reversed() {
            if node.kind == .unknown && node.ancestryUnresolved && !protectedParents.contains(node.id)
                && !node.historyAncestor && node.attention.isEmpty && !node.attentionDegraded
                && node.state != .blocked && node.state != .failed {
                compacted.insert(node.id)
            } else if let parent = node.parentID {
                protectedParents.insert(parent)
            }
        }
        return compacted
    }

    /// Apply the workspace eye before disclosure and compaction, retaining real child context.
    private func shownNodes(layout: SidebarLayoutSettings, taskboard: Bool) -> [SidebarCopilotNode] {
        let candidates = taskboard ? nodes : outlineNodes
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let reveal = layout.revealingIdleTasksIn.contains(workspaceID)
        var retained = Set(candidates.filter {
            reveal || !($0.isInternalTask && $0.state == .completed)
                || !$0.attention.isEmpty || $0.attentionDegraded
        }.map(\.id))
        for node in candidates where retained.contains(node.id) {
            var parent = node.parentID
            while let id = parent, let ancestor = byID[id], retained.insert(id).inserted {
                parent = ancestor.parentID
            }
        }
        return candidates.filter { retained.contains($0.id) }
    }

    var taskboardActivity: [SidebarCopilotNode] {
        let compacted = Set(unresolvedFragments.map(\.id))
        return nodes.filter { !$0.isInternalTask && !compacted.contains($0.id) }
    }

    func taskSections(layout: SidebarLayoutSettings) -> [SidebarChildSection] {
        var layout = layout
        for node in nodes where !node.isInternalTask {
            layout.setExpanded(true, for: .child(node.id, sessionID: id))
        }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var ancestry: Set<String> = []
        for node in nodes where node.isInternalTask {
            var parent = node.parentID
            while let id = parent, ancestry.insert(id).inserted { parent = byID[id]?.parentID }
        }
        return childSections(layout: layout, taskboard: true).filter {
            $0.taskDisclosure != nil || $0.rows.contains { ancestry.contains($0.id) }
        }
    }

    // Keep literal ancestry and provider order. A task section includes its
    // nested activity, but never another independently bound terminal/session.
    func childSections(layout: SidebarLayoutSettings, taskboard: Bool = false) -> [SidebarChildSection] {
        let shown = shownNodes(layout: layout, taskboard: taskboard)
        let compacted = compactedFragmentIDs(in: shown)
        let rows = childRows(layout: layout, shown: shown.filter { !compacted.contains($0.id) })
        var result: [SidebarChildSection] = []
        var index = 0
        while index < rows.count {
            let first = rows[index]
            guard first.node.isInternalTask else {
                result.append(.init(rows: [first], taskDisclosure: nil))
                index += 1
                continue
            }
            var end = index + 1
            while end < rows.count {
                let next = rows[end].node
                if next.depth > first.node.depth
                    || (next.isInternalTask && next.parentID == first.node.parentID && next.depth == first.node.depth) {
                    end += 1
                } else { break }
            }
            result.append(.init(rows: Array(rows[index..<end]),
                                taskDisclosure: .internalTasks(sessionID: id, parentID: first.node.parentID)))
            index = end
        }
        return result
    }

    func taskSummary(for section: SidebarChildSection) -> SidebarBranchSummary {
        let roots = Set(section.rows.map(\.id))
        let descendants = nodes.filter { node in
            if roots.contains(node.id) { return true }
            var parent = node.parentID
            var visited: Set<String> = []
            while let id = parent, visited.insert(id).inserted {
                if roots.contains(id) { return true }
                parent = nodes.first(where: { $0.id == id })?.parentID
            }
            return false
        }
        var summary = SidebarBranchSummary(nodes: descendants)
        summary.incomplete = summary.incomplete || !childrenComplete || internalTaskCountsIncomplete || treeDegraded
        summary.omittedActive = omittedActiveChildrenCount
        return summary
    }

    var foldedShellIDs: Set<String> {
        guard liveness == .alive else { return [] }
        let knownIDs = Set(nodes.map(\.id))
        let parentIDs = Set(nodes.compactMap(\.parentID))
        return Set(nodes.filter {
            $0.kind == .shell && $0.state == .working
                && $0.attention.isEmpty && !$0.attentionDegraded && !$0.ancestryUnresolved
                && !parentIDs.contains($0.id)
                && ($0.parentID.map { knownIDs.contains($0) } ?? true)
        }.map(\.id))
    }

    func foldedShellCount(parentID: String?) -> Int {
        let folded = foldedShellIDs
        return nodes.filter { $0.parentID == parentID && folded.contains($0.id) }.count
    }

    var outlineNodes: [SidebarCopilotNode] {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let folded = foldedShellIDs
        var retained = Set(nodes.filter {
            // A failed nested shell command is passive history (Other activity), not an outline row.
            !folded.contains($0.id) && (($0.kind != .skill && $0.kind != .shell)
                || $0.state == .working || $0.state == .blocked || ($0.state == .failed && $0.kind != .shell)
                || !$0.attention.isEmpty || $0.attentionDegraded || $0.ancestryUnresolved)
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

    /// Finished internal tasks stay hidden until the workspace eye is on, so they must not
    /// make a row look expandable.
    func hasShownOutline(_ layout: SidebarLayoutSettings) -> Bool {
        !shownNodes(layout: layout, taskboard: false).isEmpty
    }

    var secondaryActivity: [SidebarCopilotNode] {
        let primary = Set(outlineNodes.map(\.id))
        return nodes.filter { !primary.contains($0.id) }
    }

    func outlineChildRows(layout: SidebarLayoutSettings) -> [SidebarChildRow] {
        childRows(layout: layout, shown: shownNodes(layout: layout, taskboard: false))
    }

    func childRows(layout: SidebarLayoutSettings) -> [SidebarChildRow] {
        childRows(layout: layout, shown: nodes)
    }

    private func childRows(layout: SidebarLayoutSettings, shown: [SidebarCopilotNode]) -> [SidebarChildRow] {
        let parents = Set(shown.compactMap(\.parentID))
        let collapsed = Set(shown.compactMap { node in
            layout.isExpanded(.child(node.id, sessionID: id)) ? nil : node.id
        })
        var presentation = self
        presentation.nodes = shown
        return presentation.visibleNodes(collapsed: collapsed).map { source in
            var node = source
            node.hasChildren = parents.contains(node.id)
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
                || internalTaskCountsIncomplete
            return SidebarChildRow(
                node: node, expansionID: .child(node.id, sessionID: id), expanded: expanded,
                collapsedSummary: !expanded && node.hasChildren ? summary : nil
            )
        }
    }
}
