import Foundation

nonisolated enum CopilotSnapshotAdapter {
    static let providerID = "copilot"

    // The caller supplies granted current host placement. Provider launch
    // metadata never creates a workspace/surface or authorizes navigation.
    static func snapshot(
        _ source: CopilotSnapshot, workspaceBySurface: [UUID: UUID]
    ) -> AgentSessionSnapshot {
        let placements = Dictionary(grouping: workspaceBySurface, by: \.value)
        let workspaces = placements.keys.sorted { $0.uuidString < $1.uuidString }.map { workspaceID in
            let id = WorkspaceID(workspaceID.uuidString)
            return CMUXWorkspaceSnapshot(
                id: id, title: .unknown(),
                surfaces: (placements[workspaceID] ?? []).map(\.key).sorted { $0.uuidString < $1.uuidString }.map {
                    CMUXSurfaceSnapshot(id: SurfaceID($0.uuidString), workspaceID: id,
                                        title: .unknown(), kind: .unknown)
                }
            )
        }
        return AgentSessionSnapshot(
            generatedAt: source.generatedAt, workspaces: workspaces,
            sessions: source.sessions.map { observation in
                let identity = ProviderSessionIdentity(providerID: providerID, sessionID: observation.sessionID.uuidString)
                let launch = AgentSessionBinding(
                    workspaceID: WorkspaceID(observation.launchWorkspaceID.uuidString),
                    surfaceID: SurfaceID(observation.surfaceID.uuidString)
                )
                let binding: AgentSessionBindingObservation
                if let workspace = workspaceBySurface[observation.surfaceID] {
                    binding = .bound(.init(workspaceID: WorkspaceID(workspace.uuidString), surfaceID: launch.surfaceID))
                } else {
                    binding = .unknown(detail: "Observed surface is not in the supplied current topology")
                }
                let children = observation.children.map { child($0, session: identity) }
                let legacy = legacyHierarchy(children, session: identity)
                return AgentSessionSnapshotItem(
                    identity: identity, binding: binding, title: .unknown(),
                    state: state(observation.state),
                    activity: observation.activity.map { .known($0) } ?? .unknown(),
                    model: model(observation.model), paths: .unknown(), timing: .unknown(),
                    childWork: legacy.roots,
                    stateDetail: detail(observation.state), liveness: liveness(observation.liveness),
                    observedAt: observation.observedAt, launchBinding: launch,
                    appearance: observation.iconId == nil && observation.iconColor == nil && observation.petId == nil ? nil
                        : .init(iconId: observation.iconId, iconColor: observation.iconColor, petId: observation.petId),
                    attention: observation.attention,
                    childWorkObservation: .init(items: children, legacyProjectionIsLossless: legacy.count == children.count)
                )
            },
            issues: source.issues.map { .init(rawValue: $0.rawValue) },
            completeness: .known(source.isComplete)
        )
    }

    // Compatibility output only. Live consumers use the ordered observations,
    // never this derived view. Unreachable/ambiguous edges are not reparented.
    private static func legacyHierarchy(
        _ observations: [AgentChildWork], session: ProviderSessionIdentity
    ) -> (roots: [AgentChildWork], count: Int) {
        let groups = Dictionary(grouping: observations, by: \.id)
        let unique = observations.filter {
            !$0.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && groups[$0.id]?.count == 1
        }
        let byParent = Dictionary(grouping: unique.filter { $0.parentID != nil }, by: \.parentID)
        var count = 0
        func nest(_ child: AgentChildWork, depth: Int) -> AgentChildWork? {
            guard count < AgentSessionObservationAssessment.maximumNodes,
                  depth < AgentSessionObservationAssessment.maximumDepth else { return nil }
            count += 1
            let nested = (byParent[child.id.rawValue] ?? []).compactMap { nest($0, depth: depth + 1) }
            return child.containing(nested)
        }
        let roots = unique.filter { $0.parent == .session(session) }.compactMap { nest($0, depth: 0) }
        return (roots, count)
    }

    static func child(_ source: CopilotChildWork, session: ProviderSessionIdentity) -> AgentChildWork {
        AgentChildWork(
            id: ChildWorkID(source.id),
            parent: source.parentID.map { .child(ChildWorkID($0)) } ?? .session(session),
            title: .known(source.name), state: state(source.state),
            activity: source.activity.map { .known($0) } ?? .unknown(),
            stateDetail: detail(source.state), kind: kind(source.kind), model: model(source.model),
            terminalEvent: source.terminalEvent.map { .init(id: $0.id, timestamp: $0.timestamp) },
            attention: source.attention
        )
    }

    private static func state(_ source: CopilotWorkState) -> SnapshotValue<AgentSessionState> {
        switch source {
        case .working: .known(.working)
        case .blocked: .known(.blocked)
        case .completed: .known(.done)
        case .idle, .failed, .cancelled, .unknown: .unknown()
        }
    }

    private static func detail(_ source: CopilotWorkState) -> AgentSessionStateDetail? {
        switch source {
        case .idle: .idle
        case .failed: .failed
        case .cancelled: .cancelled
        case .working, .blocked, .completed, .unknown: nil
        }
    }

    private static func model(_ value: String?) -> SnapshotValue<AgentModel> {
        value.map { .known(AgentModel(identifier: $0)) } ?? .unknown()
    }

    private static func liveness(_ source: CopilotLiveness) -> AgentProcessLiveness {
        switch source {
        case .alive: .alive
        case .dead: .dead
        case .ambiguous: .ambiguous
        case .unknown: .unknown
        }
    }

    private static func kind(_ source: CopilotWorkKind) -> AgentWorkKind {
        switch source {
        case .subagent: .subagent
        case .skill: .skill
        case .shell: .shell
        case .unknown: .unknown
        }
    }
}
