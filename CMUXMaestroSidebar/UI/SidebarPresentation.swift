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

    func titled(_ title: String) -> Self {
        .init(title: title, symbol: symbol, tone: tone)
    }
}

enum SidebarPresentation {
    static let minimumControlSize: Double = 24

    static func state(_ state: CopilotWorkState) -> SidebarVisual {
        switch state {
        case .working: .init(title: "Working", symbol: "circle.fill", tone: .green)
        case .blocked: .init(title: "Blocked", symbol: "pause.circle", tone: .amber)
        case .completed: .init(title: "Finished", symbol: "checkmark.circle", tone: .neutral)
        case .failed: .init(title: "Failed", symbol: "exclamationmark.circle", tone: .red)
        case .cancelled: .init(title: "Cancelled", symbol: "xmark.circle", tone: .neutral)
        case .idle: .init(title: "Idle", symbol: "circle", tone: .neutral)
        case .unknown: .init(title: "Unknown", symbol: "circle.dashed", tone: .neutral)
        }
    }

    static func process(_ liveness: CopilotLiveness) -> SidebarVisual {
        switch liveness {
        case .alive: .init(title: "Process alive", symbol: "circle", tone: .neutral)
        case .dead: .init(title: "Process ended", symbol: "minus.circle", tone: .neutral)
        case .ambiguous: .init(title: "Unconfirmed owner", symbol: "circle.dashed", tone: .neutral)
        case .unknown: .init(title: "Process unknown", symbol: "circle.dashed", tone: .neutral)
        }
    }

    static func kind(_ kind: CopilotWorkKind) -> String {
        switch kind {
        case .subagent: "Agent"
        case .skill: "Skill"
        case .shell: "Shell"
        case .unknown: "Kind unknown"
        }
    }

    static func activityCaption(_ activity: AgentActivity?, runningShells: Int = 0) -> String? {
        var caption: String?
        if let activity, activity.kind == .executing,
           let summary = activity.summary, summary.hasPrefix("Executing tool: "),
           let tool = CopilotEventProjection.safeToolName(String(summary.dropFirst("Executing tool: ".count))) {
            switch tool {
            case "bash", "powershell", "local_shell": caption = "Running a command"
            case "view", "read": caption = "Reading files"
            case "rg", "grep", "glob": caption = "Searching files"
            case "edit", "apply_patch", "create": caption = "Editing files"
            case "task": caption = "Delegating work"
            default: caption = "Using a tool"
            }
        }
        guard runningShells > 0 else { return caption }
        let commands = runningShells == 1 ? "Running a command" : "Running \(runningShells) commands"
        guard let caption, caption != "Running a command" else { return commands }
        return "\(caption) · \(runningShells) \(runningShells == 1 ? "command" : "commands")"
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
        var result = counts.isEmpty ? [] : [counts.joined(separator: " · ")]
        if summary.incomplete { result.append("States or counts incomplete") }
        if summary.omittedActive > 0 { result.append("\(summary.omittedActive) working/blocked tasks not shown") }
        return result
    }

    static func unmanagedSurfaces(
        _ surfaces: [HierarchySurface], workspaceID: UUID, managed: [SidebarOrchestrationNode]
    ) -> [HierarchySurface] {
        let owned = Set(managed.filter { $0.workspaceId == workspaceID }.map(\.surfaceId))
        return surfaces.filter { !owned.contains($0.id) }
    }

    static func sessionState(_ session: SidebarCopilotSession) -> SidebarVisual {
        if session.state == .blocked { return state(.blocked) }
        switch session.liveness {
        case .alive: return state(session.state)
        case .dead: return process(.dead)
        case .ambiguous: return .init(title: "Unconfirmed owner", symbol: "circle.dashed", tone: .neutral)
        case .unknown: return .init(title: "State unavailable", symbol: "circle.dashed", tone: .neutral)
        }
    }

    static func managedState(
        _ node: SidebarOrchestrationNode, availability: SidebarOrchestrationAvailability,
        now: Date
    ) -> SidebarVisual {
        let age = now.timeIntervalSince(node.updatedAt)
        guard (availability == .ready || availability == .partial),
              age >= -1, age <= SidebarOrchestrationReader.staleInterval else {
            return .init(title: "State unverified · last observation is not current",
                         symbol: "circle.dashed", tone: .neutral)
        }
        let phase = SidebarOrchestrationPhase(rawValue: node.phase)
        let title = phase?.title(availability: node.availability) ?? "Unrecognized state"
        switch phase {
        case .registered: return state(.idle).titled("Registered · activity not inferred")
        case .launching, .turnQueued: return .init(title: title, symbol: "clock", tone: .neutral)
        case .turnRunning: return state(.working).titled(title)
        case .reportedCompleted: return state(.completed).titled(title)
        case .reportedBlocked: return state(.blocked).titled(title)
        case .reportedFailed, .turnFailed, .launchFailed, .startupFailed:
            return state(.failed).titled(title)
        case .reportMissing: return .init(title: title, symbol: "questionmark.circle", tone: .amber)
        case .permissionDenied: return state(.blocked).titled(title)
        case .processDisappeared, .terminalDisappeared:
            return process(.dead).titled(title)
        case .resourceRetired: return process(.dead).titled(title)
        case .none: return state(.unknown).titled(title)
        }
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

    static func managedNodeDetails(
        _ node: SidebarOrchestrationNode,
        hierarchy: HierarchySnapshot,
        tree: SidebarCopilotTree,
        now: Date = Date()
    ) -> [SidebarDetailLine] {
        var result: [SidebarDetailLine] = []
        if let model = managedModel(for: node, in: tree, now: now) {
            result.append(.init(title: "Model", value: model))
        }
        if node.hasFreshGitEvidence(at: now) {
            if let branch = node.branchLabel {
                result.append(.init(title: "Branch", value: branch))
            }
            if let worktree = node.worktreeLabel {
                result.append(.init(title: "Worktree", value: worktree))
            }
            if let captured = node.gitEvidenceAt {
                result.append(.init(title: "Git evidence", value: "Verified \(date(captured))"))
            }
        } else if let captured = node.gitEvidenceAt {
            let status = node.gitEvidenceStatus == "unavailable" ? "Unavailable" : "Stale"
            result.append(.init(title: "Git evidence", value: "\(status) · \(date(captured))"))
        }
        let paths = hierarchy.pathContext(
            workspaceID: node.workspaceId, surfaceID: node.surfaceId
        )
        result += [
            .init(title: "Working directory", value: paths.workingDirectory.pathDisplayText),
            .init(title: "Role", value: node.role.capitalized)
        ]
        if let sessionID = node.copilotSessionId {
            result.append(.init(title: "Copilot session", value: sessionID.uuidString))
        }
        result += [
            .init(title: "Worker ID", value: node.id.uuidString),
            .init(title: "Run ID", value: node.runId.uuidString),
            .init(title: "Workspace ID", value: node.workspaceId.uuidString),
            .init(title: "Surface ID", value: node.surfaceId.uuidString)
        ]
        return result
    }

    static func managedModel(
        for node: SidebarOrchestrationNode,
        in tree: SidebarCopilotTree,
        now: Date = Date()
    ) -> String? {
        guard tree.availability == .ready || tree.availability == .partial,
              let generatedAt = tree.generatedAt,
              SidebarCopilotTree.isFresh(generatedAt, now: now) else {
            return nil
        }
        let matches: [SidebarCopilotSession]
        if let sessionID = node.copilotSessionId {
            matches = tree.sessions.filter {
                $0.id == sessionID && $0.surfaceID == node.surfaceId
                    && $0.liveness == .alive
                    && SidebarCopilotTree.isFresh($0.observedAt, now: now)
            }
        } else if node.role == "coordinator" {
            matches = tree.sessions.filter {
                $0.surfaceID == node.surfaceId
                    && $0.liveness == .alive
                    && SidebarCopilotTree.isFresh($0.observedAt, now: now)
            }
        } else {
            return nil
        }
        guard matches.count == 1 else { return nil }
        return matches[0].model
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
