import Foundation

extension AgentChildWork {
    // The neutral child contract carries a literal session/child parent.
    nonisolated var isInternalTask: Bool { SidebarInternalTaskPolicy.isInternalTask(kind: kind, parent: parent) }
}

nonisolated enum SidebarInternalTaskPolicy {
    static func isInternalTask(kind: AgentWorkKind?, parent: AgentChildWorkParent?) -> Bool {
        guard kind == .subagent, let parent else { return false }
        switch parent {
        case .session(let identity):
            return identity.providerID == CopilotSnapshotAdapter.providerID && UUID(uuidString: identity.sessionID) != nil
        case .child(let id):
            return !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func isRelevant(state: AgentWorkState, revealIdle: Bool, dismissed: Bool) -> Bool {
        switch state {
        case .working, .queued, .blocked: true
        case .completed, .failed: !dismissed
        case .idle: revealIdle
        case .unknown, .cancelled: false
        }
    }
}

enum SidebarCopilotAvailability: Equatable {
    case waiting, loading, ready, partial, unavailable, hidden, disconnected
}

struct SidebarCopilotNode: Identifiable, Equatable {
    let id: String
    let parentID: String?
    let depth: Int
    let kind: AgentWorkKind
    let name: String
    let state: AgentWorkState
    let model: String?
    let ancestryUnresolved: Bool
    var hasChildren: Bool
    var terminalEvent: AgentTerminalEvent? = nil
    var terminalTimestamp: Date? = nil
    var historyAncestor = false
    var attention: [AgentAttention] = []
    var attentionDegraded = false
    var activity: AgentActivity? = nil
    var stateDetail: AgentSessionStateDetail? = nil
    var observedParent: AgentChildWorkParent? = nil
    var outcomeHasProtectedDescendants: Bool? = nil
    var statusOnly = false
    var lastKnownState: AgentWorkState? = nil

    var isInternalTask: Bool { SidebarInternalTaskPolicy.isInternalTask(kind: kind, parent: observedParent) }

    func dismissibleOutcome(sessionID: UUID) -> SidebarDismissedOutcome? {
        if isInternalTask {
            guard [.completed, .failed].contains(state),
                  !(outcomeHasProtectedDescendants ?? hasChildren), !ancestryUnresolved else { return nil }
        }
        guard state.isTerminal, !historyAncestor, !attentionDegraded, attention.isEmpty, let terminalEvent else { return nil }
        let key = SidebarDismissedOutcome(sessionID: sessionID, childID: id, eventID: terminalEvent.id)
        return key.isValid ? key : nil
    }

    func dismissibleFailure(sessionID: UUID) -> SidebarDismissedOutcome? {
        if isInternalTask { return dismissibleOutcome(sessionID: sessionID) }
        guard state == .failed, !historyAncestor, !attentionDegraded,
              !attention.contains(where: { $0.kind.isBlocking }), let terminalEvent else { return nil }
        let key = SidebarDismissedOutcome(sessionID: sessionID, childID: id, eventID: terminalEvent.id)
        return key.isValid ? key : nil
    }
}

struct SidebarCopilotSession: Identifiable, Equatable {
    var iconId: String? = nil
    var iconColor: String? = nil
    var petId: String? = nil
    let id: UUID
    let workspaceID: UUID
    let surfaceID: UUID
    let liveness: AgentProcessLiveness
    let state: AgentWorkState
    let model: String?
    let observedAt: Date
    var nodes: [SidebarCopilotNode]
    let childrenComplete: Bool
    let treeDegraded: Bool
    let omittedChildrenCount: Int
    let omittedActiveChildrenCount: Int
    var hasUncountedChildren = false
    var hiddenHistoryCount = 0
    var attention: [AgentAttention] = []
    var attentionDegraded = false
    var activity: AgentActivity? = nil
    var internalTaskCountsIncomplete = false
    var statusOnly = false
    var lastKnownState: AgentWorkState? = nil
    var lastKnownLiveness: AgentProcessLiveness? = nil
    var statusOwnerID: UUID? = nil
    var statusOwnerRunID: UUID? = nil
    var statusOwnerGeneration: Int? = nil

    var knownRunningChildren: Int { nodes.filter { $0.state == .working }.count }
    var retainedHistoryCount: Int { nodes.filter { $0.state.isTerminal && !$0.historyAncestor }.count }
    var shortID: String { String(id.uuidString.prefix(8)).lowercased() }
    var attentionOwnerCount: Int {
        (attention.isEmpty && !attentionDegraded ? 0 : 1)
            + nodes.filter { !$0.attention.isEmpty || $0.attentionDegraded }.count
    }

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
    var issues: [AgentSnapshotIssue]
    var generatedAt: Date?
    var nextHistoryExpiry: Date? = nil
    // Display records never participate in identity, attention or history authority.
    var statusSessions: [SidebarCopilotSession] = []

    static let waiting = SidebarCopilotTree(
        availability: .waiting, sessions: [], issues: [], generatedAt: nil
    )
    static let maximumAge: TimeInterval = 8
    static let maximumNodes = 256
    static let maximumDepth = 12

    static func statusOnly(_ session: SidebarCopilotSession, retainingStatus: Bool) -> SidebarCopilotSession {
        var result = SidebarCopilotSession(
            id: session.id, workspaceID: session.workspaceID, surfaceID: session.surfaceID,
            liveness: .unknown, state: .unknown, model: nil, observedAt: session.observedAt,
            nodes: session.nodes.map { node in
                var result = SidebarCopilotNode(
                    id: node.id, parentID: node.parentID, depth: node.depth, kind: node.kind,
                    name: node.name, state: .unknown, model: nil,
                    ancestryUnresolved: node.ancestryUnresolved, hasChildren: node.hasChildren
                )
                result.observedParent = node.observedParent
                result.historyAncestor = node.historyAncestor
                result.statusOnly = true
                result.lastKnownState = retainingStatus ? node.state : nil
                return result
            },
            childrenComplete: false, treeDegraded: true,
            omittedChildrenCount: session.omittedChildrenCount,
            omittedActiveChildrenCount: session.omittedActiveChildrenCount
        )
        result.statusOnly = true
        result.lastKnownState = retainingStatus ? session.state : nil
        result.lastKnownLiveness = retainingStatus ? session.liveness : nil
        result.statusOwnerID = session.statusOwnerID
        result.statusOwnerRunID = session.statusOwnerRunID
        result.statusOwnerGeneration = session.statusOwnerGeneration
        return result
    }

    var knownRunningChildren: Int {
        sessions.reduce(0) { $0 + $1.knownRunningChildren }
    }

    var hasCompleteCounts: Bool {
        availability == .ready && sessions.allSatisfy {
            $0.childrenComplete && !$0.internalTaskCountsIncomplete && $0.nodes.allSatisfy { $0.state != .unknown }
        }
    }

    var omittedChildrenCount: Int { sessions.reduce(0) { $0 + $1.omittedChildrenCount } }
    var omittedActiveChildrenCount: Int { sessions.reduce(0) { $0 + $1.omittedActiveChildrenCount } }
    var hasUncountedChildren: Bool { sessions.contains(where: \.hasUncountedChildren) }
    var omittedChildrenDescription: String {
        hasUncountedChildren ? "At least \(omittedChildrenCount); total unknown" : "\(omittedChildrenCount)"
    }
    var retainedHistoryCount: Int { sessions.reduce(0) { $0 + $1.retainedHistoryCount } }
    var hiddenHistoryCount: Int { sessions.reduce(0) { $0 + $1.hiddenHistoryCount } }
    var attentionOwnerCount: Int { sessions.reduce(0) { $0 + $1.attentionOwnerCount } }
    var acknowledgeableOutcomes: Set<SidebarAcknowledgedOutcome> {
        Set(sessions.flatMap { session in
            Self.acknowledgeable(session.attention, sessionID: session.id, ownerID: nil, degraded: session.attentionDegraded)
                + session.nodes.flatMap {
                    Self.acknowledgeable($0.attention, sessionID: session.id, ownerID: $0.id, degraded: $0.attentionDegraded)
                }
        })
    }

    static func acknowledgeable(
        _ attention: [AgentAttention], sessionID: UUID, ownerID: String?, degraded: Bool = false
    ) -> [SidebarAcknowledgedOutcome] {
        guard !degraded, !attention.contains(where: { $0.kind.isBlocking }) else { return [] }
        return attention.filter { !$0.kind.isBlocking }.map {
            SidebarAcknowledgedOutcome(sessionID: sessionID, ownerID: ownerID, evidence: $0.evidence)
        }.filter(\.isValid)
    }

    var dismissibleOutcomes: Set<SidebarDismissedOutcome> {
        Set(sessions.flatMap { session in
            session.nodes.compactMap { $0.dismissibleOutcome(sessionID: session.id) }
        })
    }

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
        _ snapshot: AgentSessionSnapshot,
        onto topology: SidebarTopology,
        now: Date,
        history: SidebarHistorySettings = SidebarHistorySettings(),
        attention: SidebarAttentionSettings = SidebarAttentionSettings(),
        revealingIdleTasksIn: Set<UUID> = []
    ) -> SidebarCopilotTree {
        guard topology.canReadSessions else { return .waiting }
        guard SnapshotSchemaVersion.supported.contains(snapshot.schemaVersion),
              isFresh(snapshot.generatedAt, now: now) else {
            return SidebarCopilotTree(
                availability: .unavailable, sessions: [], issues: [], generatedAt: nil
            )
        }
        let issues = snapshot.issues ?? []
        let groups = Dictionary(grouping: snapshot.sessions.filter {
            $0.identity.providerID == CopilotSnapshotAdapter.providerID
        }, by: { UUID(uuidString: $0.identity.sessionID) })
        var rejected = groups.values.contains { $0.count != 1 }
        var sessions: [SidebarCopilotSession] = []
        var nextExpiry: Date?
        for (sessionIndex, observation) in snapshot.sessions.enumerated() {
            guard observation.identity.providerID == CopilotSnapshotAdapter.providerID,
                  let sessionID = UUID(uuidString: observation.identity.sessionID),
                  groups[sessionID]?.count == 1,
                  case .bound(let binding) = observation.binding,
                  let surfaceID = UUID(uuidString: binding.surfaceID.rawValue),
                  topology.sessionSurfaceIDs.contains(surfaceID),
                  let workspaceID = topology.workspaceBySurface[surfaceID],
                  let observedAt = observation.observedAt,
                  isFresh(observedAt, now: now),
                  observedAt <= snapshot.generatedAt.addingTimeInterval(1) else {
                rejected = true
                continue
            }
            let liveness = observation.liveness ?? .unknown
            let assessment = snapshot.assess(observation, at: "sessions[\(sessionIndex)]")
            let children = assessment.children
            let groups = Dictionary(grouping: children, by: \.id)
            let validated = children.filter {
                guard !$0.id.rawValue.isEmpty, groups[$0.id]?.count == 1 else { return false }
                if case .session(let parent) = $0.parent { return parent == observation.identity }
                return true
            }
            var sessionAttention = signals(
                observation.attention, sessionID: sessionID, ownerID: nil,
                settings: attention, observedAt: observedAt, now: now
            )
            if !assessment.sessionStateIsValid || assessment.hasUncountedChildren { sessionAttention.degraded = true }
            let sessionActivity = safeActivity(observation.activity.knownValue, liveness: liveness,
                                               observedAt: observedAt, now: now)
            let childAttention = Dictionary(uniqueKeysWithValues: validated.map { child in
                var value = signals(child.attention, sessionID: sessionID, ownerID: child.id.rawValue,
                                    settings: attention, observedAt: observedAt, now: now)
                if assessment.invalidChildren.contains(child.id) || assessment.hasUncountedChildren { value.degraded = true }
                return (child.id.rawValue, value)
            })
            var hidden: Set<String> = []
            for child in validated {
                // Outstanding current attention is not completed-history noise.
                // Even malformed attention protects a row until evidence recovers.
                guard childAttention[child.id.rawValue]?.values.isEmpty == true,
                      childAttention[child.id.rawValue]?.degraded == false else { continue }
                if child.isInternalTask {
                    let state = trustworthyState(
                        assessment.invalidStates.contains(child.id) ? .unknown : child.workState, liveness: liveness
                    )
                    if !SidebarInternalTaskPolicy.isRelevant(
                        state: state, revealIdle: revealingIdleTasksIn.contains(workspaceID),
                        dismissed: history.isDismissed(sessionID: sessionID, child: child)
                    ) {
                        hidden.insert(child.id.rawValue)
                    }
                } else if history.isDismissed(sessionID: sessionID, child: child) {
                    hidden.insert(child.id.rawValue)
                } else if let deadline = history.deadline(for: child, observedAt: observedAt, now: now) {
                    if deadline <= now {
                        hidden.insert(child.id.rawValue)
                    } else {
                        nextExpiry = min(nextExpiry ?? deadline, deadline)
                    }
                }
            }
            let byID = Dictionary(uniqueKeysWithValues: validated.map { ($0.id.rawValue, $0) })
            var retained = Set(validated.map(\.id.rawValue)).subtracting(hidden)
            var walked: Set<String> = []
            for child in validated where retained.contains(child.id.rawValue) {
                var parent = child.parentID
                while let id = parent, let ancestor = byID[id], walked.insert(id).inserted {
                    retained.insert(id)
                    parent = ancestor.parentID
                }
            }
            // Filter history before display caps; retain structural ancestry for
            // every surviving state, including idle and unknown, not just running work.
            var tree = childTree(
                validated.filter { retained.contains($0.id.rawValue) }, liveness: liveness,
                historyAncestors: hidden.intersection(retained), observedAt: observedAt, now: now,
                attention: childAttention, invalidStates: assessment.invalidStates,
                unresolvedParents: assessment.unresolvedParents
            )
            // Capture outcome eligibility before either display projection removes
            // harmless legacy history or recomputes disclosure-only hasChildren.
            let uncertainDescendants = !snapshot.isComplete || assessment.hasUncountedChildren
                || tree.omitted > 0 || assessment.omittedChildren > 0
            var protectedAncestors: Set<String> = []
            for child in validated {
                let state = trustworthyState(
                    assessment.invalidStates.contains(child.id) ? .unknown : child.workState, liveness: liveness
                )
                let signals = childAttention[child.id.rawValue]
                let protectsParent = child.isInternalTask
                    ? !hidden.contains(child.id.rawValue) || state == .unknown
                    : ![.completed, .cancelled].contains(state)
                guard protectsParent || signals?.values.isEmpty == false || signals?.degraded == true
                    || assessment.unresolvedParents.contains(child.id) else { continue }
                var parent = child.parentID
                while let id = parent, protectedAncestors.insert(id).inserted {
                    parent = byID[id]?.parentID
                }
            }
            for index in tree.nodes.indices where tree.nodes[index].isInternalTask {
                tree.nodes[index].outcomeHasProtectedDescendants =
                    uncertainDescendants || protectedAncestors.contains(tree.nodes[index].id)
            }
            let degraded = tree.degraded || validated.count != children.count
                || sessionAttention.degraded || sessionActivity.degraded
                || observation.state.isDegraded || observation.activity.isDegraded || observation.model.isDegraded
                || !assessment.isValid
            let complete = snapshot.isComplete && issues.isEmpty
                && liveness == .alive && !degraded
            sessions.append(SidebarCopilotSession(
                iconId: observation.appearance?.iconId, iconColor: observation.appearance?.iconColor,
                petId: observation.appearance?.petId,
                id: sessionID,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                liveness: liveness,
                state: trustworthyState(assessment.sessionStateIsValid ? observation.workState : .unknown, liveness: liveness),
                model: displayMetadata(observation.model.knownValue?.identifier),
                observedAt: observedAt,
                nodes: tree.nodes,
                childrenComplete: complete,
                treeDegraded: degraded,
                omittedChildrenCount: tree.omitted + assessment.omittedChildren,
                omittedActiveChildrenCount: tree.omittedActive,
                hasUncountedChildren: assessment.hasUncountedChildren,
                hiddenHistoryCount: validated.filter { hidden.contains($0.id.rawValue) && $0.workState.isTerminal }.count,
                attention: sessionAttention.values, attentionDegraded: sessionAttention.degraded, activity: sessionActivity.value,
                internalTaskCountsIncomplete: validated.contains {
                    $0.isInternalTask && (trustworthyState($0.workState, liveness: liveness) == .unknown
                        || assessment.invalidChildren.contains($0.id))
                }
            ))
        }
        return SidebarCopilotTree(
            availability: snapshot.isComplete && issues.isEmpty && !rejected
                && !sessions.contains(where: \.treeDegraded) ? .ready : .partial,
            sessions: sessions,
            issues: issues,
            generatedAt: snapshot.generatedAt,
            nextHistoryExpiry: nextExpiry
        )
    }

    static func isFresh(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= -1 && age <= maximumAge
    }

    private static func trustworthyState(
        _ state: AgentWorkState, liveness: AgentProcessLiveness
    ) -> AgentWorkState {
        if liveness == .alive { return state }
        switch state {
        case .completed, .failed, .cancelled: return state
        default: return .unknown
        }
    }

    private static func childTree(
        _ children: [AgentChildWork], liveness: AgentProcessLiveness,
        historyAncestors: Set<String>, observedAt: Date, now: Date,
        attention: [String: (values: [AgentAttention], degraded: Bool)],
        invalidStates: Set<ChildWorkID>, unresolvedParents: Set<ChildWorkID>
    ) -> (nodes: [SidebarCopilotNode], degraded: Bool, omitted: Int, omittedActive: Int) {
        let groups = Dictionary(grouping: children, by: \.id)
        let validated = children.filter { !$0.id.rawValue.isEmpty && groups[$0.id]?.count == 1 }
        let byID = Dictionary(uniqueKeysWithValues: validated.map { ($0.id.rawValue, $0) })
        let active = validated.filter {
            let state = trustworthyState(invalidStates.contains($0.id) ? .unknown : $0.workState, liveness: liveness)
            return state == .working || state == .blocked
                || attention[$0.id.rawValue]?.values.contains { $0.kind.isBlocking } == true
                || (invalidStates.contains($0.id) && liveness == .alive && $0.activity.knownValue?.kind == .executing)
        }
        var selectedIDs: Set<String> = []
        var valid: [AgentChildWork] = []
        func select(_ child: AgentChildWork) {
            guard valid.count < maximumNodes, selectedIDs.insert(child.id.rawValue).inserted else { return }
            valid.append(child)
        }
        for child in active { select(child) }
        // Reserve ancestry before filling remaining capacity with historical work.
        var walkedAncestry: Set<String> = []
        for child in active where selectedIDs.contains(child.id.rawValue) {
            var parent = child.parentID
            while valid.count < maximumNodes, let id = parent, let ancestor = byID[id],
                  walkedAncestry.insert(id).inserted {
                select(ancestor)
                parent = ancestor.parentID
            }
        }
        for child in validated where attention[child.id.rawValue]?.values.isEmpty == false { select(child) }
        for child in validated { select(child) }
        let omitted = validated.count - valid.count
        let omittedActive = active.filter { !selectedIDs.contains($0.id.rawValue) }.count
        let ids = Set(valid.map(\.id.rawValue))
        var degraded = omitted > 0 || validated.count != children.count
        var byParent: [String: [AgentChildWork]] = [:]
        var roots: [AgentChildWork] = []
        var detachedRoots: [AgentChildWork] = []
        for child in valid {
            if unresolvedParents.contains(child.id) {
                degraded = true
                detachedRoots.append(child)
            } else if let parent = child.parentID, ids.contains(parent), parent != child.id.rawValue {
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
        func visit(_ child: AgentChildWork, parentID: String?, depth: Int, unresolved: Bool) {
            guard visited.insert(child.id.rawValue).inserted else {
                degraded = true
                return
            }
            let descendants = byParent[child.id.rawValue] ?? []
            let signals = attention[child.id.rawValue]
            let activity = safeActivity(child.activity.knownValue, liveness: liveness, observedAt: observedAt, now: now)
            if signals?.degraded == true || activity.degraded || child.state.isDegraded
                || child.activity.isDegraded || child.title.isDegraded || child.model?.isDegraded == true {
                degraded = true
            }
            let nodeIndex = nodes.count
            nodes.append(SidebarCopilotNode(
                id: child.id.rawValue, parentID: parentID, depth: depth, kind: child.kind ?? .unknown,
                name: displayMetadata(child.title.knownValue, limit: child.isInternalTask ? 512 : 100)
                    ?? (child.kind ?? .unknown).rawValue.capitalized,
                state: trustworthyState(invalidStates.contains(child.id) ? .unknown : child.workState, liveness: liveness),
                model: displayMetadata(child.model?.knownValue?.identifier),
                ancestryUnresolved: unresolved,
                hasChildren: false,
                terminalEvent: child.terminalEvent,
                terminalTimestamp: SidebarHistorySettings.knownTimestamp(child.terminalEvent, observedAt: observedAt, now: now),
                historyAncestor: historyAncestors.contains(child.id.rawValue),
                attention: signals?.values ?? [], attentionDegraded: signals?.degraded ?? false, activity: activity.value,
                stateDetail: child.stateDetail, observedParent: child.parent
            ))
            guard depth < maximumDepth else {
                if !descendants.isEmpty { degraded = true }
                return
            }
            for descendant in descendants {
                visit(descendant, parentID: child.id.rawValue, depth: depth + 1, unresolved: unresolved)
            }
            nodes[nodeIndex].hasChildren = nodes.count > nodeIndex + 1
        }
        for root in roots { visit(root, parentID: nil, depth: 0, unresolved: false) }
        for root in detachedRoots { visit(root, parentID: nil, depth: 0, unresolved: true) }
        // Disconnected cycles and capped branches remain visible as detached roots.
        for child in valid where !visited.contains(child.id.rawValue) {
            degraded = true
            visit(child, parentID: nil, depth: 0, unresolved: true)
        }
        return (nodes, degraded, omitted, omittedActive)
    }

    private static func displayMetadata(_ value: String?, limit: Int = 100) -> String? {
        guard let value else { return nil }
        let cleaned = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0)
        }
        let text = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : String(text.prefix(limit))
    }

    private static func signals(
        _ attention: [AgentAttention]?, sessionID: UUID, ownerID: String?,
        settings: SidebarAttentionSettings, observedAt: Date, now: Date
    ) -> (values: [AgentAttention], degraded: Bool) {
        var seen: Set<AgentEvidenceID> = []
        var degraded = (attention?.count ?? 0) > 4096
        let values = (attention ?? []).prefix(4096).compactMap { signal -> AgentAttention? in
            let key = SidebarAcknowledgedOutcome(sessionID: sessionID, ownerID: ownerID, evidence: signal.evidence)
            guard key.isValid, seen.insert(signal.evidence).inserted else {
                degraded = true
                return nil
            }
            guard !settings.contains(signal, sessionID: sessionID, ownerID: ownerID) else { return nil }
            return AgentAttention(kind: signal.kind, evidence: signal.evidence,
                                  occurredAt: SidebarHistorySettings.knownDate(signal.occurredAt, observedAt: observedAt, now: now))
        }
        return (values, degraded)
    }

    private static func safeActivity(
        _ activity: AgentActivity?, liveness: AgentProcessLiveness, observedAt: Date, now: Date
    ) -> (value: AgentActivity?, degraded: Bool) {
        guard let activity else { return (nil, false) }
        let prefix: String
        switch activity.kind {
        case .executing: prefix = "Executing tool: "
        case .idle: prefix = "Last completed tool: "
        default: return (nil, true)
        }
        guard let summary = activity.summary, summary.hasPrefix(prefix),
              CopilotEventProjection.safeToolName(String(summary.dropFirst(prefix.count))) != nil else { return (nil, true) }
        if activity.kind == .executing && liveness != .alive { return (nil, false) }
        return (AgentActivity(
            kind: activity.kind, summary: summary,
            lastEventAt: SidebarHistorySettings.knownDate(activity.lastEventAt, observedAt: observedAt, now: now)
        ), false)
    }
}
