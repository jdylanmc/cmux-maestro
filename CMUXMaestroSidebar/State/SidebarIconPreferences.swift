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
    var version = 1
    var overrides: [String: SidebarIconOverride] = [:]

    static let maximumStoredBytes = 1_048_576
    static let maximumEntries = 2_048
    static let failOpen = Self()
    static let unreadableNotice = "Icon preferences could not be read. Saved choices were not replaced. Reset icon preferences in Sidebar settings to recover."
    static let saveNotice = "Icon preferences could not be saved. Check available storage and retry."

    var isValid: Bool {
        version == 1 && overrides.count <= Self.maximumEntries && overrides.allSatisfy { key, value in
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
