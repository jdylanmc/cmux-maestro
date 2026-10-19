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
    var petId: String?

    static func validPetID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 48 && value.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        }
    }

    var isValid: Bool {
        version == 1 && (iconId != nil || iconColor != nil || petId != nil)
            && (petId.map(Self.validPetID) ?? true)
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

/// The branch fact the hook publishes from tool paths: a branch name and whether it is a
/// linked worktree. Never a path. Schema 2 records add the session's current worktree
/// (`CopilotSessionLocationRecord`, CopilotWorktree.swift).
nonisolated struct CopilotSessionLocation: Equatable, Sendable {
    static let maximumBytes = 2048
    static let maximumBranchBytes = 200
    static let keys: Set<String> = ["schemaVersion", "sessionID", "branch", "worktree", "recordedAt"]

    let branch: String
    let worktree: Bool

    static func validBranch(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBranchBytes && !value.hasPrefix("-")
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0x80...0x9F).contains($0.value) }
    }

    static func encode(sessionID: UUID, location: CopilotSessionLocation, recordedAt: Date) throws -> Data {
        let object: [String: Any] = [
            "schemaVersion": 1, "sessionID": sessionID.uuidString.lowercased(), "branch": location.branch,
            "worktree": location.worktree, "recordedAt": Int64((recordedAt.timeIntervalSince1970 * 1000).rounded()),
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Exact key set, exact types, matching session; anything else is no location.
    static func decode(_ data: Data, sessionID: UUID) -> CopilotSessionLocation? {
        struct Wire: Decodable {
            let schemaVersion: Int
            let sessionID: String
            let branch: String
            let worktree: Bool
            let recordedAt: Int64
        }
        guard data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == keys,
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              wire.schemaVersion == 1, wire.recordedAt > 0,
              let id = UUID(uuidString: wire.sessionID), id == sessionID,
              wire.sessionID == wire.sessionID.lowercased(), validBranch(wire.branch)
        else { return nil }
        return CopilotSessionLocation(branch: wire.branch, worktree: wire.worktree)
    }
}
