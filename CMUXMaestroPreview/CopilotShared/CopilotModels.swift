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

    init(
        id: String, parentID: String?, kind: CopilotWorkKind, name: String,
        state: CopilotWorkState, model: String?, terminalEvent: CopilotTerminalEvent? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.name = name
        self.state = state
        self.model = model
        self.terminalEvent = terminalEvent
    }
}

nonisolated struct CopilotSessionObservation: Codable, Equatable, Sendable {
    let sessionID: UUID
    let surfaceID: UUID
    let launchWorkspaceID: UUID
    let liveness: CopilotLiveness
    let state: CopilotWorkState
    let model: String?
    let children: [CopilotChildWork]
    let observedAt: Date

    init(
        sessionID: UUID, surfaceID: UUID, launchWorkspaceID: UUID,
        liveness: CopilotLiveness, state: CopilotWorkState, model: String?,
        children: [CopilotChildWork], observedAt: Date
    ) {
        self.sessionID = sessionID
        self.surfaceID = surfaceID
        self.launchWorkspaceID = launchWorkspaceID
        self.liveness = liveness
        self.state = state
        self.model = model
        self.children = children
        self.observedAt = observedAt
    }
}

nonisolated enum CopilotIssue: String, Codable, Equatable, Sendable {
    case integrationNotInstalled, noIdentityRecords, stateUnavailable
    case permissionDenied, malformedData, unsupportedFormat, loadingHistory
    case identityChanged, ambiguousIdentity, readLimitReached
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
