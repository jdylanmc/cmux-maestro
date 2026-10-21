import Foundation

nonisolated enum SidebarIconTarget: Hashable, Sendable {
    case session(UUID)
    case surface(UUID)

    var key: String {
        switch self {
        case .session(let id): "session:\(id.uuidString)"
        case .surface(let id): "surface:\(id.uuidString)"
        }
    }

    static func isValidKey(_ key: String) -> Bool {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && ["session", "surface"].contains(parts[0])
            && UUID(uuidString: String(parts[1]))?.uuidString == String(parts[1])
    }
}

nonisolated enum SidebarIconOverride: Codable, Equatable, Sendable {
    case standard
    case custom(SidebarIconChoice)
}

nonisolated struct SidebarIconSettings: SidebarPreferenceValue {
    var version = 2
    var overrides: [String: SidebarIconOverride] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey { case version, overrides }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decode(Int.self, forKey: .version)
        guard [1, 2].contains(storedVersion) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported icon preferences.")
        }
        overrides = try container.decode([String: SidebarIconOverride].self, forKey: .overrides)
        if storedVersion == 1, overrides.values.contains(where: {
            if case .custom(let choice) = $0, case .custom = choice.color { return true }
            return false
        }) {
            throw DecodingError.dataCorruptedError(forKey: .overrides, in: container, debugDescription: "Custom colors require version 2.")
        }
    }

    static let maximumStoredBytes = 1_048_576
    static let maximumEntries = 2_048
    static let failOpen = Self()
    static let unreadableNotice = "Icon preferences could not be read. Saved choices were not replaced. Reset icon preferences in Sidebar settings to recover."
    static let saveNotice = "Icon preferences could not be saved. Check available storage and retry."

    var isValid: Bool {
        version == 2 && overrides.count <= Self.maximumEntries && overrides.allSatisfy { key, value in
            guard SidebarIconTarget.isValidKey(key) else { return false }
            if case .custom(let choice) = value { return SidebarGlyphName.isValid(choice.glyph) }
            return true
        }
    }

    func resolve(
        target: SidebarIconTarget?, standard: SidebarIconChoice, agent: SidebarIconChoice?
    ) -> (choice: SidebarIconChoice, source: String) {
        if let target, let override = overrides[target.key] {
            switch override {
            case .standard: return (standard, "Default")
            case .custom(let choice): return (choice, "Your choice")
            }
        }
        if let agent { return (agent, "Agent selection") }
        return (standard, "Default")
    }
}
