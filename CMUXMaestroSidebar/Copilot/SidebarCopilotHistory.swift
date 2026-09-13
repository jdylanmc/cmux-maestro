import Foundation

enum SidebarHistoryRetention: String, Codable, CaseIterable, Identifiable {
    case fifteenSeconds, oneMinute, fiveMinutes, oneHour, never

    var id: Self { self }
    var title: String {
        switch self {
        case .fifteenSeconds: "15 seconds"
        case .oneMinute: "1 minute"
        case .fiveMinutes: "5 minutes"
        case .oneHour: "1 hour"
        case .never: "Never"
        }
    }
    var duration: TimeInterval? {
        switch self {
        case .fifteenSeconds: 15
        case .oneMinute: 60
        case .fiveMinutes: 300
        case .oneHour: 3600
        case .never: nil
        }
    }
}

struct SidebarDismissedOutcome: Codable, Hashable {
    let sessionID: UUID
    let childID: String
    let eventID: UUID

    var isValid: Bool {
        !childID.isEmpty && childID.utf8.count <= 512 && childID.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.:/".unicodeScalars.contains($0)
        }
    }
}

struct SidebarHistorySettings: Codable, Equatable {
    static let maximumDismissals = 2048
    static let maximumStoredBytes = 1_048_576
    var version = 1
    var retention: SidebarHistoryRetention = .fifteenSeconds
    var dismissed: Set<SidebarDismissedOutcome> = []

    var isValid: Bool {
        version == 1 && dismissed.count <= Self.maximumDismissals && dismissed.allSatisfy(\.isValid)
    }

    func isDismissed(sessionID: UUID, child: CopilotChildWork) -> Bool {
        guard child.state.isTerminal, let event = child.terminalEvent else { return false }
        return dismissed.contains(.init(sessionID: sessionID, childID: child.id, eventID: event.id))
    }

    func deadline(for child: CopilotChildWork, observedAt: Date, now: Date) -> Date? {
        guard child.state.isTerminal, let duration = retention.duration,
              let timestamp = Self.knownTimestamp(child.terminalEvent, observedAt: observedAt, now: now) else {
            return nil
        }
        return timestamp.addingTimeInterval(duration)
    }

    static func knownTimestamp(_ event: CopilotTerminalEvent?, observedAt: Date, now: Date) -> Date? {
        knownDate(event?.timestamp, observedAt: observedAt, now: now)
    }

    static func knownDate(_ date: Date?, observedAt: Date, now: Date) -> Date? {
        guard let timestamp = date, timestamp.timeIntervalSince1970.isFinite,
              timestamp <= observedAt, timestamp <= now else { return nil }
        return timestamp
    }
}

struct SidebarAcknowledgedOutcome: Codable, Hashable {
    let sessionID: UUID
    let ownerID: String?
    let evidence: AgentEvidenceID

    var isValid: Bool {
        evidence.source == "copilot.events" && (ownerID.map {
            SidebarDismissedOutcome(sessionID: sessionID, childID: $0, eventID: evidence.eventID).isValid
        } ?? true)
    }
}

struct SidebarAttentionSettings: Codable, Equatable {
    static let maximumAcknowledgements = 2048
    static let maximumStoredBytes = 1_048_576
    var version = 1
    var acknowledged: Set<SidebarAcknowledgedOutcome> = []

    var isValid: Bool {
        version == 1 && acknowledged.count <= Self.maximumAcknowledgements
            && acknowledged.allSatisfy(\.isValid)
    }

    func contains(_ signal: AgentAttention, sessionID: UUID, ownerID: String?) -> Bool {
        !signal.kind.isBlocking && acknowledged.contains(.init(
            sessionID: sessionID, ownerID: ownerID, evidence: signal.evidence
        ))
    }
}
