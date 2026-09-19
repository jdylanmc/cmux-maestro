import Foundation

nonisolated struct CopilotIdentityRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sessionID: UUID
    let surfaceID: UUID
    let launchWorkspaceID: UUID
    let ownerPID: Int32
    let ownerStartSeconds: UInt64
    let ownerStartMicroseconds: UInt64
    let recordedAt: Date

    init(
        schemaVersion: Int = 1, sessionID: UUID, surfaceID: UUID,
        launchWorkspaceID: UUID, ownerPID: Int32, ownerStartSeconds: UInt64,
        ownerStartMicroseconds: UInt64, recordedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.surfaceID = surfaceID
        self.launchWorkspaceID = launchWorkspaceID
        self.ownerPID = ownerPID
        self.ownerStartSeconds = ownerStartSeconds
        self.ownerStartMicroseconds = ownerStartMicroseconds
        self.recordedAt = recordedAt
    }
}

nonisolated struct CopilotSessionAppearance: Codable, Equatable, Sendable {
    var version = 1
    let sessionID: UUID
    var iconId: String?
    var iconColor: String?

    var isValid: Bool {
        version == 1 && (iconId != nil || iconColor != nil)
            && (iconId.map {
                !$0.isEmpty && $0.utf8.count <= 128 && $0.utf8.allSatisfy {
                    (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
                }
            } ?? true)
            && (iconColor.map { ["theme", "green", "teal", "blue", "purple", "pink", "red", "gray"].contains($0) } ?? true)
    }
}

nonisolated enum CopilotIdentityJSON {
    static func encode(_ record: CopilotIdentityRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    static func decode(_ data: Data) throws -> CopilotIdentityRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(CopilotIdentityRecord.self, from: data)
    }
}
