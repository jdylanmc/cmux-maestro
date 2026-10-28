import Foundation

nonisolated enum CopilotWorkState: String, Codable, Equatable, Sendable {
    case working, idle, blocked, completed, failed, cancelled, unknown

    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}

nonisolated enum CopilotLiveness: String, Codable, Equatable, Sendable {
    case alive, dead, ambiguous, unknown
}

nonisolated enum CopilotWorkKind: String, Codable, Equatable, Sendable {
    case subagent, skill, shell, unknown
}

nonisolated struct CopilotTerminalEvent: Codable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date?
}

nonisolated struct CopilotChildWork: Codable, Equatable, Sendable {
    let id: String
    let parentID: String?
    let kind: CopilotWorkKind
    let name: String
    let state: CopilotWorkState
    let model: String?
    let terminalEvent: CopilotTerminalEvent?
    let attention: [AgentAttention]?
    let activity: AgentActivity?
    init(
        id: String, parentID: String?, kind: CopilotWorkKind, name: String,
        state: CopilotWorkState, model: String?, terminalEvent: CopilotTerminalEvent? = nil,
        attention: [AgentAttention]? = nil, activity: AgentActivity? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.name = name
        self.state = state
        self.model = model
        self.terminalEvent = terminalEvent
        self.attention = attention
        self.activity = activity
    }
}

nonisolated struct CopilotSessionObservation: Codable, Equatable, Sendable {
    var iconId: String? = nil
    var iconColor: String? = nil
    var petId: String? = nil
    var branch: String? = nil
    var worktree: Bool? = nil
    var currentWorktree: AgentSessionWorktree? = nil
    var sessionName: String? = nil
    var sessionIssues: [CopilotIssue]? = nil
    var bindingProcess: AgentBindingProcess? = nil
    let sessionID: UUID
    let surfaceID: UUID
    let launchWorkspaceID: UUID
    let liveness: CopilotLiveness
    let state: CopilotWorkState
    let model: String?
    let children: [CopilotChildWork]
    var observedAt: Date
    let attention: [AgentAttention]?
    let activity: AgentActivity?
    var presentation: AgentPresentationInputs? = nil

    private enum CodingKeys: String, CodingKey {
        case iconId, iconColor, petId, branch, worktree, currentWorktree, sessionName, sessionIssues
        case sessionID, surfaceID, launchWorkspaceID, liveness, state, model, children, observedAt, attention, activity
        case presentation
    }

    init(
        sessionID: UUID, surfaceID: UUID, launchWorkspaceID: UUID,
        liveness: CopilotLiveness, state: CopilotWorkState, model: String?,
        children: [CopilotChildWork], observedAt: Date,
        attention: [AgentAttention]? = nil, activity: AgentActivity? = nil
    ) {
        self.sessionID = sessionID
        self.surfaceID = surfaceID
        self.launchWorkspaceID = launchWorkspaceID
        self.liveness = liveness
        self.state = state
        self.model = model
        self.children = children
        self.observedAt = observedAt
        self.attention = attention
        self.activity = activity
    }
}

nonisolated enum CopilotIssue: String, Codable, Equatable, Sendable {
    case integrationNotInstalled, noIdentityRecords, stateUnavailable
    case permissionDenied, malformedData, unsupportedFormat, loadingHistory
    case identityChanged, ambiguousIdentity, ambiguousTurn, readLimitReached
    case appearanceUnavailable

    // Cosmetic issues describe optional sidecars; they never affect trust or completeness.
    var isCosmetic: Bool { self == .appearanceUnavailable }

    // Exact-session identity, unavailable state and history bounds stay local.
    var isSessionScoped: Bool {
        self == .ambiguousIdentity || self == .identityChanged || self == .stateUnavailable
            || self == .permissionDenied || self == .readLimitReached
    }
}

nonisolated struct CopilotSnapshot: Codable, Equatable, Sendable {
    let generatedAt: Date
    let sessions: [CopilotSessionObservation]
    let issues: [CopilotIssue]
    let isComplete: Bool

    init(
        generatedAt: Date, sessions: [CopilotSessionObservation],
        issues: [CopilotIssue], isComplete: Bool
    ) {
        self.generatedAt = generatedAt
        self.sessions = sessions
        self.issues = issues
        self.isComplete = isComplete
    }
}

/// What a row may show for a session the Maestro controller enrolled by exact identity, before the
/// observer hook can bind it (#261): its Copilot name and its own chosen appearance.
nonisolated struct CopilotManagedSessionDetails: Equatable, Sendable {
    var sessionName: String?
    var iconId: String?
    var iconColor: String?
    var petId: String?
    let readAt: Date
}
