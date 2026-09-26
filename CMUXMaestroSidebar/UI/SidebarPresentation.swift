import Foundation

enum UnmanagedSelection: Equatable {
    case workspace(UUID)
    case surface(workspaceID: UUID, surfaceID: UUID)
    case session(UUID)
    case child(sessionID: UUID, childID: String)
}

struct SidebarInspection: Equatable {
    enum Target: Equatable {
        case managed(SidebarOrchestrationNode)
        case unmanaged(UnmanagedSelection)
    }

    let windowID: UUID
    let workspaceID: UUID
    let surfaceID: UUID?
    let surfaceKind: HierarchySurfaceKind?
    let sessionID: UUID?
    let target: Target
}

struct SidebarDetailContent: Equatable {
    var title: String
    var visual: SidebarVisual? = nil
    var lines: [SidebarDetailLine] = []
    var notice: String? = nil
    var isAgent = false
    var gitChanges: SidebarGitChanges? = nil
    var inspection: SidebarInspection? = nil
    var otherActivity: [SidebarCopilotNode] = []
}

struct SidebarDetailLine: Equatable, Identifiable {
    let title: String
    let value: String
    var copyableSessionID: UUID? = nil
    var id: String { title }

    static func sessionID(_ id: UUID, isParent: Bool = false, canCopy: Bool = true) -> Self {
        .init(title: isParent ? "Parent session ID" : "Session ID", value: id.uuidString,
              copyableSessionID: canCopy ? id : nil)
    }
}

enum SidebarTone: CaseIterable, Hashable {
    case blue, teal, purple, pink, attention, green, red, neutral
}

struct SidebarVisual: Equatable {
    let title: String
    let symbol: String
    let tone: SidebarTone

    func titled(_ title: String) -> Self {
        .init(title: title, symbol: symbol, tone: tone)
    }
}

enum SidebarActivityTreatment: Equatable {
    case rotatingWorking, steadyWorking, steadyAlert, none
}

struct SidebarWorkspaceStateCount: Equatable, Identifiable {
    let title: String
    let count: Int
    let visual: SidebarVisual
    var id: String { title }
}

struct SidebarWorkspaceTabCount: Equatable, Identifiable {
    let kind: HierarchySurfaceKind
    let count: Int
    var id: HierarchySurfaceKind { kind }
}

struct SidebarWorkspaceSummary: Equatable {
    let agentCount: Int
    let states: [SidebarWorkspaceStateCount]
    let tabs: [SidebarWorkspaceTabCount]
    let incomplete: Bool

    var agentLine: String {
        var parts = ["\(agentCount) \(agentCount == 1 ? "agent" : "agents")"]
        parts += states.map { "\($0.count) \($0.title.lowercased())" }
        if incomplete { parts.append("counts incomplete") }
        return parts.joined(separator: " · ")
    }

    var tabLine: String? {
        guard !tabs.isEmpty else { return nil }
        return tabs.map { "\($0.count) \($0.kind.title.lowercased())" }.joined(separator: " · ")
    }
}

struct SidebarWorkspaceAttention: Equatable {
    let needsInput: Int
    let blocked: Int
    let questions: Int
    let approvals: Int
    let lastReportedBlocked: Int

    var total: Int { needsInput + blocked }

    var label: String? {
        var parts: [String] = []
        if needsInput > 0 { parts.append("\(needsInput) \(needsInput == 1 ? "needs" : "need") input") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var detail: String {
        var parts: [String] = []
        if questions > 0 { parts.append("\(questions) asking a question") }
        if approvals > 0 { parts.append("\(approvals) awaiting approval") }
        if blocked > 0 { parts.append("\(blocked) blocked; input reason not reported") }
        if lastReportedBlocked > 0 { parts.append("\(lastReportedBlocked) last-reported blockers; live state unverified") }
        return parts.joined(separator: ". ")
    }
}

enum SidebarSeenTarget: Equatable {
    case surface(workspaceID: UUID, surfaceID: UUID)
    case session(UUID)
    case child(sessionID: UUID, childID: String)
}

struct SidebarSeenWork {
    let target: SidebarSeenTarget
    var notices: Set<SidebarAcknowledgedOutcome> = []

    static func capture(
        _ target: SidebarSeenTarget, tree: SidebarCopilotTree
    ) -> Self {
        var result = Self(target: target)
        for session in tree.sessions {
            let childID: String?
            switch target {
            case .surface(let workspaceID, let surfaceID):
                guard session.workspaceID == workspaceID, session.surfaceID == surfaceID else { continue }
                childID = nil
            case .session(let id):
                guard session.id == id else { continue }
                childID = nil
            case .child(let id, let child):
                guard session.id == id else { continue }
                childID = child
            }
            if childID == nil {
                result.notices.formUnion(SidebarCopilotTree.acknowledgeable(
                    session.attention, sessionID: session.id, ownerID: nil, degraded: session.attentionDegraded
                ))
            }
            for node in session.nodes where childID == nil || node.id == childID {
                result.notices.formUnion(SidebarCopilotTree.acknowledgeable(
                    node.attention, sessionID: session.id, ownerID: node.id, degraded: node.attentionDegraded
                ))
            }
        }
        return result
    }
}

struct SidebarVisibleWork {
    var tree: SidebarCopilotTree
    var managed: [SidebarOrchestrationNode]
    var hiddenSurfaces: Set<UUID> = []

    init(
        tree: SidebarCopilotTree, managed: [SidebarOrchestrationNode],
        history: SidebarHistorySettings, showEnded: Bool
    ) {
        self.tree = tree
        self.managed = managed
        guard !showEnded else { return }
        self.tree.sessions = tree.sessions.compactMap { session in
            var result = session
            let byID = Dictionary(uniqueKeysWithValues: session.nodes.map { ($0.id, $0) })
            var retained = Set(session.nodes.filter { node in
                if node.attentionDegraded || node.attention.contains(where: { $0.kind.isBlocking || $0.kind == .error }) { return true }
                if [.completed, .cancelled].contains(node.state) { return false }
                return true
            }.map(\.id))
            for node in session.nodes where retained.contains(node.id) {
                var parent = node.parentID
                while let id = parent, let ancestor = byID[id], retained.insert(id).inserted {
                    parent = ancestor.parentID
                }
            }
            result.nodes = session.nodes.filter { retained.contains($0.id) }.map { node in
                var row = node
                row.hasChildren = session.nodes.contains { $0.parentID == node.id && retained.contains($0.id) }
                return row
            }
            let protected = session.attentionDegraded || session.attention.contains(where: { $0.kind.isBlocking || $0.kind == .error })
                || result.nodes.contains {
                    $0.state == .failed || $0.state == .blocked || $0.attentionDegraded
                        || $0.attention.contains(where: { $0.kind.isBlocking })
                }
            if session.liveness == .dead && !protected { return nil }
            return result
        }
        let byID = Dictionary(uniqueKeysWithValues: managed.map { ($0.id, $0) })
        var retained = Set(managed.filter { node in
            if node.role != "worker" { return true }
            if tree.sessions.contains(where: {
                $0.workspaceID == node.workspaceId && $0.surfaceID == node.surfaceId
                    && ($0.hasBlockingEvidence || $0.attention.contains(where: { $0.kind == .error })
                        || ($0.liveness == .alive && ($0.state == .working
                            || (node.copilotSessionId != nil && node.copilotSessionId != $0.id)))
                        || $0.nodes.contains(where: { $0.kind == .subagent && !$0.state.isTerminal }))
            }) { return true }
            if ["reported-completed", "process-disappeared", "terminal-disappeared", "resource-retired"].contains(node.phase) {
                return false
            }
            return !(history.dismissedManaged ?? []).contains(
                .init(nodeID: node.id, generation: node.generation, phase: node.phase)
            )
        }.map(\.id))
        for node in managed where retained.contains(node.id) {
            var parent = node.parentId
            while let id = parent, let ancestor = byID[id], retained.insert(id).inserted {
                parent = ancestor.parentId
            }
        }
        self.managed = managed.filter { retained.contains($0.id) }
        let visibleSurfaces = Set(self.tree.sessions.map(\.surfaceID)).union(self.managed.map(\.surfaceId))
        let observedSurfaces = Set(tree.sessions.map(\.surfaceID)).union(managed.map(\.surfaceId))
        hiddenSurfaces = observedSurfaces.subtracting(visibleSurfaces)
        // Managed ownership replaces its observed copy, including when the owned row retires.
        let retiredManaged = Set(managed.filter { !retained.contains($0.id) }.map(\.surfaceId))
        self.tree.sessions.removeAll { retiredManaged.contains($0.surfaceID) }
        hiddenSurfaces.formUnion(retiredManaged)
    }
}

private extension SidebarCopilotSession {
    var hasBlockingEvidence: Bool {
        attentionDegraded || state == .blocked || attention.contains(where: { $0.kind.isBlocking })
            || nodes.contains { $0.attentionDegraded || $0.state == .blocked || $0.attention.contains(where: { $0.kind.isBlocking }) }
    }
}

extension SidebarPreferences {
    func markSeen(_ captured: SidebarSeenWork, in tree: SidebarCopilotTree) {
        let current = SidebarSeenWork.capture(captured.target, tree: tree)
        acknowledge(captured.notices.intersection(current.notices), in: tree)
    }
}

enum SidebarPresentation {
    static let minimumControlSize: Double = 24

    static func dismissibleManagedFailure(
        _ node: SidebarOrchestrationNode, tree: SidebarCopilotTree
    ) -> SidebarDismissedManagedOutcome? {
        let key = SidebarDismissedManagedOutcome(nodeID: node.id, generation: node.generation, phase: node.phase)
        guard node.role == "worker", key.isValid,
              !tree.sessions.contains(where: {
                  $0.workspaceID == node.workspaceId && $0.surfaceID == node.surfaceId
                      && ($0.hasBlockingEvidence
                          || ($0.liveness == .alive && ($0.state == .working
                              || (node.copilotSessionId != nil && node.copilotSessionId != $0.id)))
                          || $0.nodes.contains(where: { $0.kind == .subagent && !$0.state.isTerminal }))
              }) else { return nil }
        return key
    }

    static func workspaceAttention(
        sessions: [SidebarCopilotSession], managed: [SidebarOrchestrationNode],
        availability: SidebarOrchestrationAvailability, now: Date
    ) -> SidebarWorkspaceAttention {
        enum Owner: Hashable {
            case managed(UUID), session(UUID), child(UUID, String)
        }
        var questions = Set<Owner>()
        var approvals = Set<Owner>()
        var blocked = Set<Owner>()
        var historical = Set<Owner>()
        func include(_ owner: Owner, state: CopilotWorkState, signals: [AgentAttention], live: Bool) {
            if signals.contains(where: { $0.kind == .answer }) { questions.insert(owner) }
            if signals.contains(where: { $0.kind == .permission }) { approvals.insert(owner) }
            if live && state == .blocked { blocked.insert(owner) }
        }
        for session in sessions {
            let claimed = managed.first {
                $0.workspaceId == session.workspaceID && $0.surfaceId == session.surfaceID
            }
            let owner = claimed.map { Owner.managed($0.id) } ?? .session(session.id)
            include(owner, state: session.state, signals: session.attention, live: session.liveness == .alive)
            for child in session.nodes {
                include(.child(session.id, child.id), state: child.state, signals: child.attention,
                        live: session.liveness == .alive)
            }
        }
        if [.ready, .partial, .stale].contains(availability) {
            for node in managed where ["reported-blocked", "permission-denied"].contains(node.phase) {
                let owner = Owner.managed(node.id)
                blocked.insert(owner)
                let age = now.timeIntervalSince(node.updatedAt)
                if availability == .stale || age < -1 || age > SidebarOrchestrationReader.staleInterval {
                    historical.insert(owner)
                }
            }
        }
        let input = questions.union(approvals)
        let otherBlocked = blocked.subtracting(input)
        return .init(
            needsInput: input.count, blocked: otherBlocked.count,
            questions: questions.count, approvals: approvals.count,
            lastReportedBlocked: historical.intersection(otherBlocked).count
        )
    }

    static func activityTreatment(_ visual: SidebarVisual, reduceMotion: Bool) -> SidebarActivityTreatment {
        switch visual.tone {
        case .green: reduceMotion ? .steadyWorking : .rotatingWorking
        case .red: .steadyAlert
        default: .none
        }

    }

    static func workingRotation(at date: Date, reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
    }

    static func needsInput(_ attention: [AgentAttention]) -> Bool {
        attention.contains { $0.kind == .answer || $0.kind == .permission }
    }

    static func statusDescription(_ visual: SidebarVisual, needsInput: Bool = false) -> String {
        needsInput ? "Needs input. \(visual.title)" : visual.title
    }

    static func managedNeedsInput(_ node: SidebarOrchestrationNode, tree: SidebarCopilotTree, now: Date) -> Bool {
        managedSession(for: node, in: tree, now: now).map { needsInput($0.attention) } ?? false
    }

    static func childState(_ node: SidebarCopilotNode, session: SidebarCopilotSession) -> SidebarVisual {
        if node.state == .blocked || node.state == .failed { return state(node.state) }
        guard session.liveness == .alive else {
            return process(session.liveness).titled("Last reported: \(state(node.state).title). \(process(session.liveness).title)")
        }
        return state(node.state)
    }

    static func focusInteraction(from old: HierarchySnapshot, to new: HierarchySnapshot) -> SidebarSeenTarget? {
        guard old.receivedSnapshot, old.windowID != nil, old.windowID == new.windowID,
              let previous = focusedSurface(in: old), let current = focusedSurface(in: new),
              previous != current else { return nil }
        return current
    }

    static func focusedSurface(in hierarchy: HierarchySnapshot) -> SidebarSeenTarget? {
        let topology = SidebarTopology(hierarchy)
        guard topology.canReadSessions else { return nil }
        let selected = hierarchy.workspaces.filter { $0.isSelected == .available(true) }
        guard selected.count == 1, case .available(let surfaces) = selected[0].surfaces else { return nil }
        let focused = surfaces.filter(\.isFocused)
        guard focused.count == 1, topology.workspaceBySurface[focused[0].id] == selected[0].id else { return nil }
        return .surface(workspaceID: selected[0].id, surfaceID: focused[0].id)
    }

    static func pinnedDetails(
        hierarchy: HierarchySnapshot, connected: Bool, tree: SidebarCopilotTree,
        managed: SidebarOrchestrationSnapshot, availability: SidebarOrchestrationAvailability, now: Date
    ) -> SidebarDetailContent {
        guard connected else { return .init(title: "Waiting for the current window") }
        guard case .surface(let workspaceID, let surfaceID) = focusedSurface(in: hierarchy),
              let native = inspection(
                for: .unmanaged(.surface(workspaceID: workspaceID, surfaceID: surfaceID)),
                hierarchy: hierarchy, connected: connected, tree: tree, managed: managed, availability: availability, now: now
              ),
              let surface = hierarchy.workspaces.first(where: { $0.id == workspaceID }).flatMap({ workspace in
                  if case .available(let surfaces) = workspace.surfaces { return surfaces.first { $0.id == surfaceID } }
                  return nil
              }) else {
            return .init(title: "No uniquely focused surface", notice: "Current window identity or focus is unavailable.")
        }
        let paths = paths(hierarchy.pathContext(workspaceID: workspaceID, surfaceID: surfaceID))
        var result = SidebarDetailContent(
            title: surface.title.isEmpty ? surface.kind.title : surface.title,
            visual: .init(title: surface.kind.title, symbol: surface.kind.symbolName, tone: .neutral),
            lines: paths, inspection: native
        )
        // Browser and other native surfaces cannot inherit an old terminal's agent.
        guard [.terminal, .agentSession].contains(surface.kind) else { return result }
        let sessions = tree.sessions.filter {
            $0.workspaceID == workspaceID && $0.surfaceID == surfaceID && $0.liveness != .dead
        }
        guard sessions.count == 1, let session = sessions.first,
              tree.sessions.filter({ $0.id == session.id }).count == 1,
              session.liveness == .alive, [.ready, .partial].contains(tree.availability),
              tree.generatedAt.map({ SidebarCopilotTree.isFresh($0, now: now) }) == true,
              SidebarCopilotTree.isFresh(session.observedAt, now: now) else {
            if !sessions.isEmpty || surface.kind == .agentSession {
                result.notice = "Agent identity is stale, unavailable or unconfirmed."
            }
            return result
        }
        result.isAgent = true
        result.visual = sessionState(session)
        result.lines = sessionDetails(session).filter { ["Model", "Session ID"].contains($0.title) } + paths
        result.inspection = inspection(
            for: .unmanaged(.session(session.id)), hierarchy: hierarchy, connected: connected,
            tree: tree, managed: managed, availability: availability, now: now
        )
        let nodes = managed.nodes.filter { $0.workspaceId == workspaceID && $0.surfaceId == surfaceID }
        if nodes.count == 1, let node = nodes.first,
           managed.nodes.filter({ $0.id == node.id }).count == 1,
           [.ready, .partial].contains(availability),
           (-1...SidebarOrchestrationReader.staleInterval).contains(now.timeIntervalSince(managed.generatedAt)),
           (-1...SidebarOrchestrationReader.staleInterval).contains(now.timeIntervalSince(node.updatedAt)),
           managedSession(for: node, in: tree, now: now)?.id == session.id {
            result.title = node.label
            result.visual = managedState(node, availability: availability, now: now, tree: tree)
            let fields = Set(["Model", "Branch", "Worktree", "Git evidence", "Git changes", "Working directory", "Session ID"])
            result.lines = managedNodeDetails(node, hierarchy: hierarchy, tree: tree, now: now)
                .filter { fields.contains($0.title) }
            result.gitChanges = node.currentGitChanges(at: now)
            if !result.lines.contains(where: { $0.title == "Session ID" }) {
                result.lines.append(.sessionID(session.id))
            }
            result.inspection = inspection(
                for: .managed(node), hierarchy: hierarchy, connected: connected,
                tree: tree, managed: managed, availability: availability, now: now
            )
        } else if !nodes.isEmpty {
            result.notice = "Managed metadata is not current or uniquely bound. Showing the observed session."
        }
        return result
    }

    static func inspection(
        for target: SidebarInspection.Target, hierarchy: HierarchySnapshot, connected: Bool,
        tree: SidebarCopilotTree, managed: SidebarOrchestrationSnapshot,
        availability: SidebarOrchestrationAvailability, now: Date = Date()
    ) -> SidebarInspection? {
        let topology = SidebarTopology(hierarchy)
        guard connected, hierarchy.receivedSnapshot, hierarchy.workspaceListAvailable,
              hierarchy.workspaceMetadataAvailable, let windowID = topology.windowID else { return nil }
        let workspaceID: UUID
        let surfaceID: UUID?
        var sessionID: UUID?
        switch target {
        case .managed(let captured):
            let matches = managed.nodes.filter { $0.id == captured.id }
            guard [.ready, .partial, .stale].contains(availability),
                  matches.count == 1, let node = matches.first,
                  node.runId == captured.runId, node.generation == captured.generation,
                  node.copilotSessionId == captured.copilotSessionId,
                  node.workspaceId == captured.workspaceId, node.surfaceId == captured.surfaceId else { return nil }
            workspaceID = node.workspaceId
            surfaceID = node.surfaceId
            sessionID = managedSession(for: node, in: tree, now: now)?.id ?? node.copilotSessionId
            let current = tree.sessions.filter {
                $0.workspaceID == workspaceID && $0.surfaceID == surfaceID
                    && $0.liveness == .alive && SidebarCopilotTree.isFresh($0.observedAt, now: now)
            }
            guard current.isEmpty || (current.count == 1 && current[0].id == sessionID
                && tree.sessions.filter({ $0.id == current[0].id }).count == 1) else { return nil }
        case .unmanaged(let selection):
            switch selection {
            case .workspace(let id):
                workspaceID = id
                surfaceID = nil
            case .surface(let workspace, let surface):
                workspaceID = workspace
                surfaceID = surface
            case .session(let id), .child(let id, _):
                let matches = tree.sessions.filter { $0.id == id }
                guard [.ready, .partial].contains(tree.availability),
                      matches.count == 1, let session = matches.first,
                      [.alive, .dead].contains(session.liveness) else { return nil }
                if case .child(_, let childID) = selection {
                    guard session.nodes.filter({ $0.id == childID }).count == 1 else { return nil }
                }
                workspaceID = session.workspaceID
                surfaceID = session.surfaceID
                sessionID = session.id
            }
        }
        guard topology.workspaceIDs.contains(workspaceID) else { return nil }
        var kind: HierarchySurfaceKind?
        if let surfaceID {
            guard topology.canReadSessions, topology.workspaceBySurface[surfaceID] == workspaceID,
                  let workspace = hierarchy.workspaces.first(where: { $0.id == workspaceID }),
                  case .available(let surfaces) = workspace.surfaces,
                  let surface = surfaces.first(where: { $0.id == surfaceID }) else { return nil }
            kind = surface.kind
            switch target {
            case .managed, .unmanaged(.session), .unmanaged(.child):
                guard [.terminal, .agentSession].contains(surface.kind) else { return nil }
            default: break
            }
        }
        return .init(windowID: windowID, workspaceID: workspaceID, surfaceID: surfaceID,
                     surfaceKind: kind, sessionID: sessionID, target: target)
    }

    static func inspectorDetails(
        for subject: SidebarInspection, hierarchy: HierarchySnapshot, connected: Bool,
        tree: SidebarCopilotTree, managed: SidebarOrchestrationSnapshot,
        availability: SidebarOrchestrationAvailability, now: Date
    ) -> SidebarDetailContent? {
        guard inspection(for: subject.target, hierarchy: hierarchy, connected: connected, tree: tree,
                         managed: managed, availability: availability, now: now) == subject else { return nil }
        switch subject.target {
        case .managed(let captured):
            guard let node = managed.nodes.first(where: { $0.id == captured.id }) else { return nil }
            let current = [.ready, .partial].contains(availability)
                && (-1...SidebarOrchestrationReader.staleInterval).contains(now.timeIntervalSince(managed.generatedAt))
                && (-1...SidebarOrchestrationReader.staleInterval).contains(now.timeIntervalSince(node.updatedAt))
            return .init(
                title: node.label, visual: managedState(node, availability: availability, now: now, tree: tree),
                lines: managedNodeDetails(node, hierarchy: hierarchy, tree: tree, now: now),
                notice: current ? nil : "Managed observation is stale. Last-known metadata is not live state.",
                isAgent: true
            )
        case .unmanaged(let selection):
            switch selection {
            case .workspace(let id):
                guard let workspace = hierarchy.workspaces.first(where: { $0.id == id }) else { return nil }
                let title: String
                if case .available(let name) = workspace.title, !name.isEmpty { title = name } else { title = "Workspace" }
                return .init(title: title, lines: [
                    .init(title: "Workspace ID", value: id.uuidString),
                    .init(title: "Workspace path", value: workspace.rootPath.pathDisplayText),
                    .init(title: "Project path", value: workspace.projectRootPath.pathDisplayText)
                ])
            case .surface(let workspaceID, let surfaceID):
                guard let workspace = hierarchy.workspaces.first(where: { $0.id == workspaceID }),
                      case .available(let surfaces) = workspace.surfaces,
                      let surface = surfaces.first(where: { $0.id == surfaceID }) else { return nil }
                return .init(title: surface.title.isEmpty ? "Surface" : surface.title, lines: [
                    .init(title: "Type", value: surface.kind.title),
                    .init(title: "Surface ID", value: surface.id.uuidString),
                    .init(title: "Working directory", value: surface.workingDirectory.pathDisplayText)
                ])
            case .session(let id), .child(let id, _):
                guard let session = tree.sessions.first(where: { $0.id == id }) else { return nil }
                let current = tree.generatedAt.map { SidebarCopilotTree.isFresh($0, now: now) } == true
                    && SidebarCopilotTree.isFresh(session.observedAt, now: now)
                let notice = current ? nil : "Session observation is stale. Last-known metadata is not live state."
                let context = paths(hierarchy.pathContext(workspaceID: session.workspaceID, surfaceID: session.surfaceID))
                if case .child(_, let childID) = selection {
                    guard let child = session.nodes.first(where: { $0.id == childID }) else { return nil }
                    return .init(title: child.name, lines: nodeDetails(child, session: session) + [
                        .init(title: "Placement", value: "Observed child; native placement belongs to its parent session")
                    ] + context, notice: notice, isAgent: child.kind == .subagent)
                }
                return .init(title: "Copilot · \(session.shortID)", lines: sessionDetails(session) + context,
                             notice: notice, isAgent: true, otherActivity: session.secondaryActivity)
            }
        }
    }

    static func state(_ state: CopilotWorkState) -> SidebarVisual {
        switch state {
        case .working: .init(title: "Working", symbol: "circle.fill", tone: .green)
        case .blocked: .init(title: "Blocked", symbol: "pause.circle", tone: .red)
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
            (.readLimitReached, "History read limit reached"),
            (.appearanceUnavailable, "Session icon metadata unavailable")
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

    static func workspaceSummary(
        surfaces: [HierarchySurface],
        sessions: [SidebarCopilotSession],
        managed: [SidebarOrchestrationNode],
        orchestrationAvailability: SidebarOrchestrationAvailability,
        countsComplete: Bool,
        now: Date,
        observations: SidebarCopilotTree? = nil
    ) -> SidebarWorkspaceSummary {
        let managedSurfaces = Set(managed.map(\.surfaceId))
        let unmanagedSessions = sessions.filter { !managedSurfaces.contains($0.surfaceID) }
        var counts: [AgentSummaryState: Int] = [:]
        var incomplete = !countsComplete || orchestrationAvailability != .ready

        for node in managed {
            let state = coordinatorSession(node, availability: orchestrationAvailability, tree: observations, now: now)
                .map(sessionSummaryState) ?? managedSummaryState(node, availability: orchestrationAvailability, now: now)
            counts[state, default: 0] += 1
            if state == .unknown { incomplete = true }
        }
        for session in unmanagedSessions {
            let state = sessionSummaryState(session)
            counts[state, default: 0] += 1
            if state == .unknown { incomplete = true }
            for node in session.nodes where node.kind == .subagent {
                let state = observedSummaryState(node.state)
                counts[state, default: 0] += 1
                if state == .unknown { incomplete = true }
            }
            incomplete = incomplete || !session.childrenComplete || session.treeDegraded
        }

        let agentSurfaceIDs = managedSurfaces.union(unmanagedSessions.map(\.surfaceID))
        let tabGroups = Dictionary(grouping: surfaces.filter {
            !agentSurfaceIDs.contains($0.id) && $0.kind != .agentSession
        }, by: \.kind)
        let tabs = HierarchySurfaceKind.allCases.compactMap { kind -> SidebarWorkspaceTabCount? in
            guard let count = tabGroups[kind]?.count, count > 0 else { return nil }
            return .init(kind: kind, count: count)
        }
        let states = AgentSummaryState.allCases.compactMap { state -> SidebarWorkspaceStateCount? in
            guard let count = counts[state], count > 0 else { return nil }
            return .init(title: state.title, count: count, visual: state.visual)
        }
        return SidebarWorkspaceSummary(
            agentCount: managed.count + unmanagedSessions.reduce(0) {
                $0 + 1 + $1.nodes.filter { $0.kind == .subagent }.count
            },
            states: states,
            tabs: tabs,
            incomplete: incomplete
        )
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
        now: Date, tree: SidebarCopilotTree? = nil
    ) -> SidebarVisual {
        if node.executionMode == .interactive, node.phase == "turn-running",
           [.ready, .partial, .stale].contains(availability) {
            if let tree, let session = managedSession(for: node, in: tree, now: now) {
                return sessionState(session)
            }
            return state(.unknown).titled("Interactive · session state unavailable")
        }
        if let session = coordinatorSession(node, availability: availability, tree: tree, now: now) {
            return sessionState(session)
        }
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
        case .reportMissing: return .init(title: title, symbol: "questionmark.circle", tone: .attention)
        case .permissionDenied: return state(.blocked).titled(title)
        case .processDisappeared, .terminalDisappeared:
            return process(.dead).titled(title)
        case .resourceRetired: return process(.dead).titled(title)
        case .none: return state(.unknown).titled(title)
        }
    }

    static func briefPath(root: HierarchyAvailability<String?>, project: HierarchyAvailability<String?>) -> String? {
        for path in [root, project] {
            if case .available(let value) = path, let value, !value.isEmpty { return SidebarPathDisplay.text(value) }
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
                result.append(.init(title: "Worktree", value: SidebarPathDisplay.text(worktree)))
            }
            if let captured = node.gitEvidenceAt {
                result.append(.init(title: "Git evidence", value: "Verified \(date(captured))"))
            }
        } else if let captured = node.gitEvidenceAt {
            let status = node.gitEvidenceStatus == "unavailable" ? "Unavailable" : "Stale"
            result.append(.init(title: "Git evidence", value: "\(status) · \(date(captured))"))
        }
        if let changes = node.currentGitChanges(at: now) {
            result.append(.init(title: "Git changes", value: changes.description))
        } else {
            result.append(.init(title: "Git changes", value: "Current counts unavailable"))
        }
        let paths = hierarchy.pathContext(
            workspaceID: node.workspaceId, surfaceID: node.surfaceId
        )
        result += [
            .init(title: "Copilot observation", value: tree.summary),
            .init(title: "Session glyph", value: node.iconId ?? "Sidebar default"),
            .init(title: "Icon color", value: node.iconColor?.title ?? "Theme default"),
            .init(title: "Working directory", value: paths.workingDirectory.pathDisplayText),
            .init(title: "Role", value: node.role.capitalized)
        ]
        if node.role == "worker" {
            result.append(.init(
                title: "Interaction",
                value: node.executionMode == .interactive
                    ? "Interactive Copilot session · talk directly in its tab"
                    : "Legacy bounded worker · coordinator follow-up required"
            ))
        }
        let warnings = overviewWarnings(tree)
        if !warnings.isEmpty {
            result.append(.init(title: "Observation warnings", value: warnings.joined(separator: "\n")))
        }
        if let sessionID = node.copilotSessionId {
            result.append(.sessionID(sessionID))
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
        managedSession(for: node, in: tree, now: now)?.model
    }

    static func managedIconTarget(
        _ node: SidebarOrchestrationNode, tree: SidebarCopilotTree, now: Date
    ) -> SidebarIconTarget? {
        if let id = node.copilotSessionId { return .session(id) }
        return managedSession(for: node, in: tree, now: now).map { .session($0.id) }
    }

    private static func coordinatorSession(
        _ node: SidebarOrchestrationNode, availability: SidebarOrchestrationAvailability,
        tree: SidebarCopilotTree?, now: Date
    ) -> SidebarCopilotSession? {
        guard node.role == "coordinator", node.phase == "registered",
              [.ready, .partial, .stale].contains(availability), let tree else { return nil }
        return managedSession(for: node, in: tree, now: now)
    }

    private static func managedSession(
        for node: SidebarOrchestrationNode, in tree: SidebarCopilotTree, now: Date
    ) -> SidebarCopilotSession? {
        guard tree.availability == .ready || tree.availability == .partial,
              let generatedAt = tree.generatedAt,
              SidebarCopilotTree.isFresh(generatedAt, now: now) else {
            return nil
        }
        let matches: [SidebarCopilotSession]
        if let sessionID = node.copilotSessionId {
            matches = tree.sessions.filter {
                $0.id == sessionID && $0.surfaceID == node.surfaceId
                    && $0.workspaceID == node.workspaceId
                    && $0.liveness == .alive
                    && SidebarCopilotTree.isFresh($0.observedAt, now: now)
            }
        } else if node.role == "coordinator" {
            matches = tree.sessions.filter {
                $0.surfaceID == node.surfaceId
                    && $0.workspaceID == node.workspaceId
                    && $0.liveness == .alive
                    && SidebarCopilotTree.isFresh($0.observedAt, now: now)
            }
        } else {
            return nil
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func nodeDetails(_ node: SidebarCopilotNode, session: SidebarCopilotSession) -> [SidebarDetailLine] {
        var result: [SidebarDetailLine] = [
            .init(title: "Name", value: node.name),
            .init(title: "Kind", value: kind(node.kind)),
            .init(title: "State", value: node.state.rawValue),
            .sessionID(session.id, isParent: true, canCopy: [.alive, .dead].contains(session.liveness)),
            .init(title: "Session glyph", value: session.iconId ?? "Sidebar default"),
            .init(title: "Icon color", value: session.iconColor ?? "theme"),
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
            .sessionID(session.id, canCopy: [.alive, .dead].contains(session.liveness)),
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

    static func surfaceTitle(for session: SidebarCopilotSession, in hierarchy: HierarchySnapshot) -> String {
        guard let workspace = hierarchy.workspaces.first(where: { $0.id == session.workspaceID }),
              case .available(let surfaces) = workspace.surfaces,
              let surface = surfaces.first(where: { $0.id == session.surfaceID }),
              !surface.title.isEmpty else { return "Agent" }
        return surface.title
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

    private enum AgentSummaryState: CaseIterable {
        case working, blocked, idle, finished, failed, cancelled
        case queued, stopped, registered, unknown

        var title: String {
            switch self {
            case .working: "Working"
            case .blocked: "Blocked"
            case .idle: "Idle"
            case .finished: "Finished"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            case .queued: "Queued"
            case .stopped: "Stopped"
            case .registered: "Registered"
            case .unknown: "Unknown"
            }
        }

        var visual: SidebarVisual {
            switch self {
            case .working: SidebarPresentation.state(.working)
            case .blocked: SidebarPresentation.state(.blocked)
            case .idle: SidebarPresentation.state(.idle)
            case .finished: SidebarPresentation.state(.completed)
            case .failed: SidebarPresentation.state(.failed)
            case .cancelled: SidebarPresentation.state(.cancelled)
            case .queued: .init(title: title, symbol: "clock", tone: .neutral)
            case .stopped: SidebarPresentation.process(.dead).titled(title)
            case .registered: .init(title: title, symbol: "person.crop.circle", tone: .neutral)
            case .unknown: SidebarPresentation.state(.unknown)
            }
        }
    }

    private static func observedSummaryState(_ state: CopilotWorkState) -> AgentSummaryState {
        switch state {
        case .working: .working
        case .blocked: .blocked
        case .idle: .idle
        case .completed: .finished
        case .failed: .failed
        case .cancelled: .cancelled
        case .unknown: .unknown
        }
    }

    private static func sessionSummaryState(_ session: SidebarCopilotSession) -> AgentSummaryState {
        switch session.liveness {
        case .alive: observedSummaryState(session.state)
        case .dead: .stopped
        case .ambiguous, .unknown: .unknown
        }
    }

    private static func managedSummaryState(
        _ node: SidebarOrchestrationNode,
        availability: SidebarOrchestrationAvailability,
        now: Date
    ) -> AgentSummaryState {
        let age = now.timeIntervalSince(node.updatedAt)
        guard (availability == .ready || availability == .partial),
              age >= -1, age <= SidebarOrchestrationReader.staleInterval else {
            return .unknown
        }
        switch SidebarOrchestrationPhase(rawValue: node.phase) {
        case .registered: return .registered
        case .launching, .turnQueued: return .queued
        case .turnRunning: return .working
        case .reportedBlocked, .permissionDenied: return .blocked
        case .reportedCompleted: return .finished
        case .reportedFailed, .turnFailed, .launchFailed, .startupFailed: return .failed
        case .processDisappeared, .terminalDisappeared, .resourceRetired: return .stopped
        case .reportMissing, .none: return .unknown
        }
    }
}
