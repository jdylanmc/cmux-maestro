import Foundation

nonisolated struct MaestroNotificationAppearance: Sendable {
    let home: URL

    func choice(session: UUID, agent: CopilotSessionAppearance?) throws -> SidebarIconChoice {
        guard agent == nil || (agent?.sessionID == session && agent?.isValid == true) else {
            throw MaestroNotificationFailure.unavailable
        }
        let root = MaestroNotificationAssets.sidebarRoot(home: home)
        var icons = SidebarIconSettings()
        if let data = try optional(root.appendingPathComponent("sidebar-icons.json"),
                                   maximum: SidebarIconSettings.maximumStoredBytes) {
            icons = try JSONDecoder().decode(SidebarIconSettings.self, from: data)
            guard icons.isValid else { throw MaestroNotificationFailure.unavailable }
        }
        let domain = "com.jdylanmc.CMUXMaestroPreview.Extension"
        let preferences = home.appendingPathComponent("Library/Containers/\(domain)/Data/Library/Preferences/\(domain).plist")
        var style = "maestro"
        if let data = try optional(preferences, maximum: 262_144) {
            guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw MaestroNotificationFailure.unavailable
            }
            if let value = values["sidebar.agentIconStyle"] {
                guard let saved = value as? String, ["maestro", "copilot"].contains(saved) else {
                    throw MaestroNotificationFailure.unavailable
                }
                style = saved
            }
        }
        let standard = SidebarIconChoice(glyph: style == "copilot" ? "oct-copilot" : "md-robot", color: .theme)
        let selected: SidebarIconChoice? = agent?.iconId != nil || agent?.iconColor != nil
            ? .init(glyph: agent?.iconId ?? standard.glyph,
                    color: agent?.iconColor.flatMap(SidebarAvatarColor.init(rawValue:)) ?? .theme) : nil
        return icons.resolve(target: .session(session), standard: standard, agent: selected).choice
    }

    private func optional(_ file: URL, maximum: Int) throws -> Data? {
        do { return try MaestroNotificationAssets.read(file, maximum: maximum) }
        catch CopilotFileError.missing { return nil }
    }
}
