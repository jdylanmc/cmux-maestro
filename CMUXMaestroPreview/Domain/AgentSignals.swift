import Foundation

nonisolated enum AgentActivityKind: String, Codable, Equatable, Sendable {
    case unknown
    case planning
    case executing
    case waiting
    case reviewing
    case idle
}

nonisolated struct AgentActivity: Codable, Equatable, Sendable {
    let kind: AgentActivityKind
    let summary: String?
    let lastEventAt: Date?

    init(kind: AgentActivityKind, summary: String? = nil, lastEventAt: Date? = nil) {
        self.kind = kind
        self.summary = summary
        self.lastEventAt = lastEventAt
    }
}

nonisolated enum AgentAttentionKind: String, Codable, Hashable, CaseIterable, Sendable {
    case permission, answer, error, aborted, turnFinished

    var isBlocking: Bool { self == .permission || self == .answer }
    var title: String {
        switch self {
        case .permission: "Waiting for permission"
        case .answer: "Waiting for answer"
        case .error: "Error reported"
        case .aborted: "Aborted"
        case .turnFinished: "Turn finished"
        }
    }
}

nonisolated struct AgentEvidenceID: Codable, Hashable, Sendable {
    let source: String
    let eventID: UUID
}

// The containing session/child supplies ownership. Neither attention nor activity
// attests to process liveness or permits an action against the provider.
nonisolated struct AgentAttention: Codable, Equatable, Sendable {
    let kind: AgentAttentionKind
    let evidence: AgentEvidenceID
    let occurredAt: Date?
}
