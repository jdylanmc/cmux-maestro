import Foundation

nonisolated enum SidebarGlyphName {
    static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128 && name.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

nonisolated enum SidebarAvatarColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case theme, green, teal, blue, purple, pink, red, gray
    var id: Self { self }
    var title: String { self == .theme ? "Theme default" : rawValue.capitalized }
}

nonisolated struct SidebarIconChoice: Codable, Equatable, Sendable {
    var glyph: String
    var color: SidebarAvatarColor
}
