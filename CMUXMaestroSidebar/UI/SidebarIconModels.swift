import Foundation

nonisolated enum SidebarGlyphName {
    static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128 && name.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

nonisolated enum SidebarAvatarColor: RawRepresentable, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case theme, green, teal, blue, purple, pink, red, gray
    case custom(SidebarTagColor)

    static let allCases: [Self] = [.theme, .green, .teal, .blue, .purple, .pink, .red, .gray]

    init?(rawValue: String) {
        if let named = Self.allCases.first(where: { $0.rawValue == rawValue }) { self = named }
        else if let color = SidebarTagColor(hex: rawValue) { self = .custom(color) }
        else { return nil }
    }

    var rawValue: String {
        switch self {
        case .theme: "theme"
        case .green: "green"
        case .teal: "teal"
        case .blue: "blue"
        case .purple: "purple"
        case .pink: "pink"
        case .red: "red"
        case .gray: "gray"
        case .custom(let color): color.hex
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let color = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid icon color.")
        }
        self = color
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var id: Self { self }
    var customColor: SidebarTagColor? {
        if case .custom(let color) = self { return color }
        return nil
    }
    var title: String {
        if case .custom(let color) = self { return color.hex }
        return self == .theme ? "Theme default" : rawValue.capitalized
    }
}

nonisolated struct SidebarIconChoice: Codable, Equatable, Sendable {
    var glyph: String
    var color: SidebarAvatarColor
}
