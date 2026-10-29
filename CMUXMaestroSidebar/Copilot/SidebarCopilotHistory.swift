import Foundation

nonisolated enum SidebarHistoryRetention: String, Codable, CaseIterable, Identifiable, Sendable {
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

nonisolated struct SidebarDismissedOutcome: Codable, Hashable, Sendable {
    let sessionID: UUID
    let childID: String
    let eventID: UUID

    var isValid: Bool {
        !childID.isEmpty && childID.utf8.count <= 512 && childID.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.:/".unicodeScalars.contains($0)
        }
    }
}

nonisolated struct SidebarHistorySettings: Codable, Equatable, Sendable {
    static let maximumDismissals = 2048
    static let maximumStoredBytes = 1_048_576
    var version = 1
    var retention: SidebarHistoryRetention = .fifteenSeconds
    var dismissed: Set<SidebarDismissedOutcome> = []
    var dismissedManaged: Set<SidebarDismissedManagedOutcome>? = nil

    var isValid: Bool {
        version == 1 && dismissed.count + (dismissedManaged?.count ?? 0) <= Self.maximumDismissals
            && dismissed.allSatisfy(\.isValid) && (dismissedManaged?.allSatisfy(\.isValid) ?? true)
    }

    func isDismissed(sessionID: UUID, child: AgentChildWork) -> Bool {
        guard child.workState.isTerminal, let event = child.terminalEvent else { return false }
        return dismissed.contains(.init(sessionID: sessionID, childID: child.id.rawValue, eventID: event.id))
    }

    func deadline(for child: AgentChildWork, generatedAt: Date, now: Date) -> Date? {
        guard !child.isInternalTask, child.workState.isTerminal, child.workState != .failed, let duration = retention.duration,
              let timestamp = Self.knownTimestamp(child.terminalEvent, generatedAt: generatedAt, now: now) else {
            return nil
        }
        return timestamp.addingTimeInterval(duration)
    }

    static func knownTimestamp(_ event: AgentTerminalEvent?, generatedAt: Date, now: Date) -> Date? {
        knownDate(event?.timestamp, generatedAt: generatedAt, now: now)
    }

    static func knownDate(_ date: Date?, generatedAt: Date, now: Date) -> Date? {
        guard let timestamp = date, timestamp.timeIntervalSince1970.isFinite,
              timestamp <= generatedAt, timestamp <= now else { return nil }
        return timestamp
    }
}

nonisolated struct SidebarDismissedManagedOutcome: Codable, Hashable, Sendable {
    let nodeID: UUID
    let generation: Int
    let phase: String

    var isValid: Bool {
        generation > 0 && ["reported-failed", "turn-failed", "launch-failed", "startup-failed"].contains(phase)
    }
}

extension SidebarHistorySettings: SidebarPreferenceValue {
    nonisolated static var failOpen: Self { .init(retention: .never) }
    nonisolated static var unreadableNotice: String {
        "History settings could not be read. Nothing is hidden by history controls. Reset history settings to recover."
    }
    nonisolated static var saveNotice: String {
        "History settings could not be saved. Check local storage and retry or reset history settings."
    }
}

nonisolated struct SidebarAcknowledgedOutcome: Codable, Hashable, Sendable {
    let sessionID: UUID
    let ownerID: String?
    let evidence: AgentEvidenceID

    var isValid: Bool {
        evidence.source == "copilot.events" && (ownerID.map {
            SidebarDismissedOutcome(sessionID: sessionID, childID: $0, eventID: evidence.eventID).isValid
        } ?? true)
    }
}

nonisolated struct SidebarAttentionSettings: Codable, Equatable, Sendable {
    static let legacyMaximumAcknowledgements = 2048
    static let legacyMaximumStoredBytes = 1_048_576
    static let maximumAcknowledgements = 20_480
    static let maximumStoredBytes = 4_194_304
    var version = 2
    var acknowledged: Set<SidebarAcknowledgedOutcome> = []

    var maximumEncodedBytes: Int {
        version == 1 ? Self.legacyMaximumStoredBytes : Self.maximumStoredBytes
    }

    var isValid: Bool {
        [1, 2].contains(version)
            && acknowledged.count <= (version == 1 ? Self.legacyMaximumAcknowledgements : Self.maximumAcknowledgements)
            && acknowledged.allSatisfy(\.isValid)
    }

    private enum CodingKeys: String, CodingKey { case version, acknowledged, archive }

    init(version: Int = 2, acknowledged: Set<SidebarAcknowledgedOutcome> = []) {
        self.version = version
        self.acknowledged = acknowledged
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        switch version {
        case 1:
            guard !container.contains(.archive) else {
                throw DecodingError.dataCorruptedError(forKey: .archive, in: container, debugDescription: "Unexpected archive")
            }
            acknowledged = try container.decode(Set<SidebarAcknowledgedOutcome>.self, forKey: .acknowledged)
        case 2:
            guard !container.contains(.acknowledged) else {
                throw DecodingError.dataCorruptedError(forKey: .acknowledged, in: container, debugDescription: "Ambiguous archive")
            }
            // Group exact event UUIDs by session and owner; the empty owner denotes the primary owner.
            let archive = try container.decode([String: [String: [UUID]]].self, forKey: .archive)
            for (session, owners) in archive {
                guard let sessionID = UUID(uuidString: session), !owners.isEmpty else {
                    throw DecodingError.dataCorruptedError(forKey: .archive, in: container, debugDescription: "Invalid session")
                }
                for (owner, events) in owners {
                    guard !events.isEmpty, events.count <= Self.maximumAcknowledgements - acknowledged.count else {
                        throw DecodingError.dataCorruptedError(forKey: .archive, in: container, debugDescription: "Invalid event count")
                    }
                    for event in events {
                        let key = SidebarAcknowledgedOutcome(
                            sessionID: sessionID, ownerID: owner.isEmpty ? nil : owner,
                            evidence: .init(source: "copilot.events", eventID: event)
                        )
                        guard key.isValid, acknowledged.insert(key).inserted else {
                            throw DecodingError.dataCorruptedError(forKey: .archive, in: container, debugDescription: "Invalid or duplicate identity")
                        }
                    }
                }
            }
        default:
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported version")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        if version == 1 {
            try container.encode(acknowledged, forKey: .acknowledged)
        } else {
            guard acknowledged.allSatisfy(\.isValid) else {
                throw EncodingError.invalidValue(acknowledged, .init(
                    codingPath: encoder.codingPath, debugDescription: "Invalid acknowledgement identity"
                ))
            }
            var archive: [String: [String: [UUID]]] = [:]
            for key in acknowledged {
                archive[key.sessionID.uuidString, default: [:]][key.ownerID ?? "", default: []].append(key.evidence.eventID)
            }
            try container.encode(archive, forKey: .archive)
        }
    }

    func contains(_ signal: AgentAttention, sessionID: UUID, ownerID: String?) -> Bool {
        !signal.kind.isBlocking && acknowledged.contains(.init(
            sessionID: sessionID, ownerID: ownerID, evidence: signal.evidence
        ))
    }
}

extension SidebarAttentionSettings: SidebarPreferenceValue {
    nonisolated static var failOpen: Self { .init() }
    nonisolated static var unreadableNotice: String {
        "Acknowledgements could not be read. No attention is hidden. Reset acknowledgements to recover."
    }
    nonisolated static var saveNotice: String {
        "Acknowledgements could not be saved. Check local storage and retry or reset acknowledgements."
    }
}
