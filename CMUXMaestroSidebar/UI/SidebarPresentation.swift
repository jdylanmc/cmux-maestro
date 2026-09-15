import Foundation

struct SidebarDetailLine: Equatable, Identifiable {
    let title: String
    let value: String
    var id: String { title }
}

enum SidebarTone: CaseIterable, Hashable {
    case blue, teal, purple, pink, amber, green, red, neutral
}

struct SidebarVisual: Equatable {
    let title: String
    let symbol: String
    let tone: SidebarTone
}

enum SidebarPresentation {
    static let minimumControlSize: Double = 24

    static let workspace = SidebarVisual(title: "Workspace", symbol: "square.stack.3d.up.fill", tone: .blue)
    static let session = SidebarVisual(title: "Copilot", symbol: "brain.head.profile", tone: .purple)

    static func surface(_ kind: HierarchySurfaceKind) -> SidebarVisual {
        switch kind {
        case .terminal: .init(title: kind.title, symbol: "terminal.fill", tone: .teal)
        case .browser: .init(title: kind.title, symbol: "globe", tone: .blue)
        case .agentSession: session
        case .project: .init(title: kind.title, symbol: "folder.fill", tone: .blue)
        case .markdown, .filePreview: .init(title: kind.title, symbol: kind.symbolName, tone: .teal)
        case .rightSidebarTool: .init(title: kind.title, symbol: kind.symbolName, tone: .purple)
        case .unknown: .init(title: kind.title, symbol: kind.symbolName, tone: .neutral)
        }
    }

    static func work(_ kind: CopilotWorkKind) -> SidebarVisual {
        switch kind {
        case .subagent: .init(title: "Agent", symbol: "person.crop.square.fill", tone: .pink)
        case .skill: .init(title: "Skill", symbol: "sparkles", tone: .amber)
        case .shell: .init(title: "Shell", symbol: "terminal.fill", tone: .teal)
        case .unknown: .init(title: "Kind unknown", symbol: "questionmark.square.dashed", tone: .neutral)
        }
    }

    static func state(_ state: CopilotWorkState) -> SidebarVisual {
        switch state {
        case .working: .init(title: "Working", symbol: "arrow.triangle.2.circlepath", tone: .blue)
        case .blocked: .init(title: "Blocked", symbol: "hand.raised.fill", tone: .amber)
        case .completed: .init(title: "Finished", symbol: "checkmark.circle.fill", tone: .green)
        case .failed: .init(title: "Failed", symbol: "exclamationmark.circle.fill", tone: .red)
        case .cancelled: .init(title: "Cancelled", symbol: "xmark.circle", tone: .neutral)
        case .idle: .init(title: "Idle", symbol: "pause.circle", tone: .neutral)
        case .unknown: .init(title: "Unknown", symbol: "questionmark.diamond", tone: .neutral)
        }
    }

    static func process(_ liveness: CopilotLiveness) -> SidebarVisual {
        switch liveness {
        case .alive: .init(title: "Process alive", symbol: "waveform.path.ecg", tone: .green)
        case .dead: .init(title: "Process ended", symbol: "power", tone: .red)
        case .ambiguous: .init(title: "Unconfirmed owner", symbol: "person.crop.circle.badge.questionmark", tone: .amber)
        case .unknown: .init(title: "Process unknown", symbol: "questionmark.circle", tone: .neutral)
        }
    }

    static func kind(_ kind: CopilotWorkKind) -> String {
        work(kind).title
    }

    static func overview(_ tree: SidebarCopilotTree) -> String {
        guard !tree.sessions.isEmpty else { return "No current Copilot sessions" }
        var parts = ["\(tree.sessions.count) \(tree.sessions.count == 1 ? "session" : "sessions")"]
        if tree.knownRunningChildren > 0 { parts.append("\(tree.knownRunningChildren) \(tree.hasCompleteCounts ? "" : "known ")working") }
        let unknown = tree.sessions.filter { $0.state == .unknown }.count
            + tree.sessions.flatMap(\.nodes).filter { $0.state == .unknown }.count
        if unknown > 0 { parts.append("\(unknown) state unknown") }
        return parts.joined(separator: " · ")
    }

    static func overviewWarnings(_ tree: SidebarCopilotTree) -> [String] {
        var result: [String] = []
        switch tree.availability {
        case .waiting: result.append("Waiting for workspace data")
        case .loading: result.append("Loading Copilot history")
        case .hidden: result.append("Copilot updates paused")
        case .disconnected: result.append("Copilot disconnected")
        case .unavailable: result.append("Copilot unavailable · no live state inferred")
        case .partial: result.append("Partial data · counts may be incomplete")
        case .ready:
            if !tree.hasCompleteCounts { result.append("Some task states or counts are unknown") }
        }
        if tree.issues.contains(.permissionDenied) { result.append("Copilot access denied") }
        if tree.issues.contains(.integrationNotInstalled) { result.append("Copilot integration is not enabled") }
        if tree.issues.contains(.loadingHistory), tree.availability != .loading { result.append("Child history is still loading") }
        for (issue, message): (CopilotIssue, String) in [
            (.malformedData, "Some Copilot history is unreadable"),
            (.unsupportedFormat, "Unsupported Copilot history format"),
            (.identityChanged, "Session identity changed"),
            (.ambiguousIdentity, "Session identity is unconfirmed"),
            (.ambiguousTurn, "Turn identity is unconfirmed"),
            (.stateUnavailable, "Copilot state unavailable"),
            (.readLimitReached, "History read limit reached")
        ] where tree.issues.contains(issue) { result.append(message) }
        if tree.omittedActiveChildrenCount > 0 {
            result.append("\(tree.omittedActiveChildrenCount) working/blocked tasks beyond display limits")
        } else if tree.omittedChildrenCount > 0 {
            result.append("\(tree.omittedChildrenCount) tasks beyond display limits")
        }
        return result
    }

    static func primaryWarnings(_ tree: SidebarCopilotTree) -> [String] {
        var warnings: [String] = []
        if tree.issues.contains(.permissionDenied) { warnings.append("Copilot access denied") }
        else if tree.issues.contains(.integrationNotInstalled) { warnings.append("Enable Copilot integration") }
        else if let warning = overviewWarnings(tree).first { warnings.append(warning) }
        if tree.omittedActiveChildrenCount > 0 {
            warnings.append("\(tree.omittedActiveChildrenCount) working/blocked tasks not shown")
        }
        return warnings
    }

    static func emptyChildHistoryTitle(complete: Bool) -> String {
        complete ? "No visible child tasks" : "Child history unavailable"
    }

    static func attention(_ signals: [AgentAttention], state: CopilotWorkState, degraded: Bool) -> [String] {
        var result = AgentAttentionKind.allCases.compactMap { kind -> String? in
            let count = signals.filter { $0.kind == kind }.count
            guard count > 0 else { return nil }
            return kind.title + (count > 1 ? " (\(count))" : "")
        }
        if state == .blocked && !signals.contains(where: { $0.kind.isBlocking }) {
            result.append("Blocking reason unavailable")
        }
        if degraded { result.append("Attention evidence incomplete") }
        return result
    }

    static func collapsed(_ summary: SidebarBranchSummary) -> [String] {
        var counts: [String] = []
        if summary.running > 0 { counts.append("\(summary.running) known working") }
        if summary.blocked > 0 { counts.append("\(summary.blocked) blocked") }
        if summary.attention > 0 { counts.append(SidebarCountText.attention(summary.attention)) }
        var result = counts.isEmpty ? ["Branch collapsed"] : [counts.joined(separator: " · ")]
        if summary.incomplete { result.append("States or counts incomplete") }
        if summary.omittedActive > 0 { result.append("\(summary.omittedActive) working/blocked tasks not shown") }
        return result
    }

    static func briefPath(root: HierarchyAvailability<String?>, project: HierarchyAvailability<String?>) -> String? {
        for path in [root, project] {
            if case .available(let value) = path, let value, !value.isEmpty { return value }
        }
        return nil
    }

    static func paths(_ paths: HierarchyPathContext) -> [SidebarDetailLine] {
        [
            .init(title: "Workspace path", value: paths.rootPath.pathDisplayText),
            .init(title: "Project path", value: paths.projectRootPath.pathDisplayText),
            .init(title: "Working directory", value: paths.workingDirectory.pathDisplayText)
        ]
    }

    static func nodeDetails(_ node: SidebarCopilotNode, session: SidebarCopilotSession) -> [SidebarDetailLine] {
        var result: [SidebarDetailLine] = [
            .init(title: "Name", value: node.name),
            .init(title: "Kind", value: kind(node.kind)),
            .init(title: "State", value: node.state.rawValue),
            .init(title: "Session", value: session.id.uuidString),
            .init(title: "Child ID", value: node.id)
        ]
        if let model = node.model { result.insert(.init(title: "Model", value: model), at: 3) }
        if node.historyAncestor { result.append(.init(title: "History", value: "Kept for child context")) }
        if node.state.isTerminal {
            result.append(.init(title: "Completion", value: node.terminalTimestamp.map(date) ?? "Completion age unknown"))
        }
        if node.ancestryUnresolved { result.append(.init(title: "Ancestry", value: "Unresolved ancestry")) }
        return result + activityDetails(node.activity) + attentionDetails(node.attention)
    }

    static func sessionDetails(_ session: SidebarCopilotSession) -> [SidebarDetailLine] {
        var result: [SidebarDetailLine] = [
            .init(title: "Session", value: session.id.uuidString),
            .init(title: "State", value: session.state.rawValue),
            .init(title: "Process", value: session.liveness.rawValue),
            .init(title: "Observed", value: date(session.observedAt)),
            .init(title: "Known working children", value: "\(session.knownRunningChildren)"),
            .init(title: "Retained outcomes", value: "\(session.retainedHistoryCount)"),
            .init(title: "Hidden history", value: "\(session.hiddenHistoryCount)"),
            .init(title: "Omitted children", value: "\(session.omittedChildrenCount)"),
            .init(title: "Child history", value: session.childrenComplete && !session.treeDegraded
                ? "Complete" : "Incomplete; missing work is not assumed finished")
        ]
        if let model = session.model { result.insert(.init(title: "Model", value: model), at: 2) }
        return result + activityDetails(session.activity) + attentionDetails(session.attention)
    }

    static func activityDetails(_ activity: AgentActivity?) -> [SidebarDetailLine] {
        guard let activity else { return [.init(title: "Activity", value: "Not reported")] }
        return [
            .init(title: "Activity", value: activity.summary ?? "Activity unknown"),
            .init(title: "Activity recorded", value: activity.lastEventAt.map(date) ?? "Activity time unknown")
        ]
    }

    static func attentionDetails(_ signals: [AgentAttention]) -> [SidebarDetailLine] {
        var result = signals.enumerated().map { index, signal in
            SidebarDetailLine(title: "Attention \(index + 1)", value: "\(signal.kind.title) · \(signal.occurredAt.map(date) ?? "Event time unknown")")
        }
        if signals.contains(where: { $0.kind == .turnFinished }) {
            result.append(.init(title: "Turn scope", value: "Main turn only; background work may continue."))
        }
        return result
    }

    private static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
