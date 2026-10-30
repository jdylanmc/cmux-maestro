import Foundation

/// A read-only projection of one exact session. Attention is already acknowledgement-filtered.
struct SidebarPetMoodInput: Equatable {
    struct Identity: Equatable {
        let session: UUID
        let workspace: UUID
        let surface: UUID
        var node: UUID?
        var run: UUID?
        var generation: Int?
        var process: AgentBindingProcess?
    }

    var identity: Identity?
    var observationAvailable = false
    var session: SidebarCopilotSession?
    var selfReport: SidebarMoodObservation.Mood?
    var selfReportSequence: Int?
    var preview: SidebarMoodObservation.Playback?

    static let unavailable = Self()

    static func project(
        session: SidebarCopilotSession?, node: SidebarOrchestrationNode? = nil,
        tree: SidebarCopilotTree, managed: SidebarOrchestrationSnapshot,
        availability: SidebarOrchestrationAvailability, now: Date
    ) -> Self {
        let matches = session.map { session in
            managed.nodes.filter {
                $0.copilotSessionId == session.id && $0.workspaceId == session.workspaceID
                    && $0.surfaceId == session.surfaceID
            }
        } ?? []
        let owner = node ?? (matches.count == 1 ? matches.first : nil)
        let exactSession = session ?? owner.flatMap { owner in
            let candidates = tree.sessions.filter {
                $0.id == owner.copilotSessionId && $0.workspaceID == owner.workspaceId
                    && $0.surfaceID == owner.surfaceId
            }
            return candidates.count == 1 ? candidates.first : nil
        }
        guard let id = exactSession?.id ?? owner?.copilotSessionId,
              let workspace = exactSession?.workspaceID ?? owner?.workspaceId,
              let surface = exactSession?.surfaceID ?? owner?.surfaceId else { return .unavailable }
        let identity = Identity(session: id, workspace: workspace, surface: surface,
                                node: owner?.id, run: owner?.runId, generation: owner?.generation,
                                process: exactSession?.bindingProcess)
        let current = exactSession.map {
            tree.isCurrent($0, now: now) && !$0.statusOnly && !tree.hasGlobalPermissionDenial
                && tree.sessions.filter { $0.id == id }.count == 1
                && [.alive, .dead].contains($0.liveness)
        } ?? false
        let ownerCurrent = owner.map { owner in
            // Native sessions do not heartbeat lifecycle timestamps. Fresh exact Copilot
            // evidence confirms the binding; the reader has already fenced the claim's generation.
            [.ready, .partial, .stale].contains(availability)
                && managed.generatedAt <= now.addingTimeInterval(1)
                && owner.updatedAt <= now.addingTimeInterval(1)
                && tree.exactLiveSession(id: id, workspaceID: workspace, surfaceID: surface, now: now) == exactSession
                && owner.copilotSessionId == id && owner.workspaceId == workspace && owner.surfaceId == surface
                && managed.nodes.filter { $0.id == owner.id }.count == 1
                && managed.nodes.contains(owner)
                && owner.generation > 0
                && managed.nodes.filter {
                    $0.copilotSessionId == id && $0.workspaceId == workspace && $0.surfaceId == surface
                }.count == 1
        } ?? false
        return Self(identity: identity, observationAvailable: current, session: current ? exactSession : nil,
                    selfReport: current && ownerCurrent && !managed.moodsUnavailable ? owner?.selfReportedMood : nil,
                    selfReportSequence: current && ownerCurrent && !managed.moodsUnavailable
                        ? owner?.selfReportedMoodSequence : nil,
                    preview: current && ownerCurrent && !managed.moodsUnavailable ? owner?.moodPreview : nil)
    }
}
