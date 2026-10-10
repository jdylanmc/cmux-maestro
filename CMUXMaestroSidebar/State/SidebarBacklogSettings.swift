import Foundation

nonisolated struct SidebarBacklogSettings: SidebarPreferenceValue {
    var version = 1
    var urls: [String: String] = [:]

    static let maximumStoredBytes = 1_048_576
    static let maximumEntries = 2_048
    static let failOpen = Self()
    static var unreadableNotice: String {
        String(localized: "Backlog settings could not be read. Saved URLs were not replaced. Reset backlog settings to recover.")
    }
    static var saveNotice: String {
        String(localized: "Backlog URL could not be saved. Check storage and try again.")
    }
    static var invalidNotice: String {
        String(localized: "Enter an absolute HTTP or HTTPS URL with a host.")
    }

    var isValid: Bool {
        version == 1 && urls.count <= Self.maximumEntries && urls.allSatisfy { key, value in
            UUID(uuidString: key)?.uuidString == key && Self.validatedURL(value) != nil
        }
    }

    func urlText(for workspaceID: UUID) -> String? { urls[workspaceID.uuidString] }

    static func validatedURL(_ text: String) -> URL? {
        guard !text.isEmpty,
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              let components = URLComponents(string: text),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              let url = components.url else { return nil }
        return url
    }

    mutating func setURL(_ text: String, for workspaceID: UUID) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            urls.removeValue(forKey: workspaceID.uuidString)
            return
        }
        guard Self.validatedURL(text) != nil else {
            throw SidebarPreferenceRejection(notice: Self.invalidNotice)
        }
        urls[workspaceID.uuidString] = text
        guard urls.count <= Self.maximumEntries else {
            throw SidebarPreferenceRejection(
                notice: String(localized: "Backlog storage is full. Remove an unused URL before adding another.")
            )
        }
    }
}
