import Foundation

/// Agent tags, version 1 (#51). One canonical slug per tag, shared by every session; human and
/// agent assignments are separate sets bound to the exact Copilot session UUID; only humans
/// choose colors. Decision: ADR 0026. The controller applies the same
/// canonicalization; both run scripts/test-fixtures/tag-slug-cases.json.
nonisolated enum SidebarTagSlug {
    static let version = 1
    /// Unicode scalars per canonical slug.
    static let maximumLength = 24
    /// Tags per session per source (human or agent).
    static let maximumPerSource = 6

    /// NFKC, per-scalar default lowercase mapping, NFKC again, then every run of characters that
    /// are not letters (L*) or numbers (N*) becomes one hyphen; leading and trailing hyphens drop.
    /// The empty string means the text has no letter or number.
    static func canonical(_ text: String) -> String {
        var lowered = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCompatibilityMapping.unicodeScalars {
            lowered.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
        }
        var result = String.UnicodeScalarView()
        var separated = false
        for scalar in String(lowered).precomposedStringWithCompatibilityMapping.unicodeScalars {
            if isLetterOrNumber(scalar) {
                if separated && !result.isEmpty { result.append("-") }
                separated = false
                result.append(scalar)
            } else {
                separated = true
            }
        }
        return String(result)
    }

    static func isCanonical(_ slug: String) -> Bool {
        // Exact scalars: String equality would accept a canonically equivalent, decomposed spelling.
        !slug.isEmpty && slug.unicodeScalars.count <= maximumLength
            && canonical(slug).unicodeScalars.elementsEqual(slug.unicodeScalars)
    }

    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            true
        default:
            false
        }
    }

    /// Comma-separated human entry. Refuses rather than truncates.
    static func parse(_ input: String) throws(SidebarTagError) -> [String] {
        var slugs: [String] = []
        for piece in input.split(separator: ",") where !piece.allSatisfy(\.isWhitespace) {
            let slug = canonical(String(piece))
            guard !slug.isEmpty else { throw .noLetterOrNumber }
            guard slug.unicodeScalars.count <= maximumLength else { throw .tooLong }
            if !slugs.contains(slug) { slugs.append(slug) }
        }
        guard slugs.count <= maximumPerSource else { throw .tooMany }
        return slugs
    }
}

nonisolated enum SidebarTagError: Error, Equatable {
    case noLetterOrNumber, tooLong, tooMany

    var message: String {
        switch self {
        case .noLetterOrNumber: "Each tag needs a letter or number."
        case .tooLong: "Tags are at most \(SidebarTagSlug.maximumLength) characters."
        case .tooMany: "At most \(SidebarTagSlug.maximumPerSource) tags."
        }
    }
}

nonisolated struct SidebarTagColor: Hashable, Sendable {
    let red: UInt8, green: UInt8, blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Opaque sRGB only; no shorthand, whitespace, alpha, or non-ASCII digits.
    init?(hex: String) {
        let bytes = Array(hex.utf8)
        guard bytes.count == 7, bytes[0] == 35,
              bytes.dropFirst().allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: UInt8((rgb >> 16) & 255), green: UInt8((rgb >> 8) & 255), blue: UInt8(rgb & 255))
    }

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// WCAG 2 relative luminance.
    var luminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    static let black = Self(red: 0, green: 0, blue: 0)
    static let white = Self(red: 255, green: 255, blue: 255)

    static func contrast(_ first: Self, _ second: Self) -> Double {
        let (a, b) = (first.luminance, second.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Black or white, whichever contrasts more with this background.
    var foreground: Self {
        Self.contrast(.black, self) >= Self.contrast(.white, self) ? .black : .white
    }
}

/// Human-chosen opaque colors. Foregrounds are selected by actual contrast, including custom colors.
nonisolated enum SidebarTagSwatch: RawRepresentable, CaseIterable, Codable, Hashable, Sendable {
    case rose, peach, gold, lime, mint, teal, sky, periwinkle, lavender, orchid, slate, forest, ocean, plum
    case custom(SidebarTagColor)

    static let allCases: [Self] = [
        .rose, .peach, .gold, .lime, .mint, .teal, .sky, .periwinkle, .lavender, .orchid, .slate, .forest, .ocean, .plum
    ]

    init?(rawValue: String) {
        if let named = Self.allCases.first(where: { $0.rawValue == rawValue }) { self = named }
        else if let color = SidebarTagColor(hex: rawValue) { self = .custom(color) }
        else { return nil }
    }

    var rawValue: String {
        switch self {
        case .rose: "rose"
        case .peach: "peach"
        case .gold: "gold"
        case .lime: "lime"
        case .mint: "mint"
        case .teal: "teal"
        case .sky: "sky"
        case .periwinkle: "periwinkle"
        case .lavender: "lavender"
        case .orchid: "orchid"
        case .slate: "slate"
        case .forest: "forest"
        case .ocean: "ocean"
        case .plum: "plum"
        case .custom(let color): color.hex
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let color = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid tag color.")
        }
        self = color
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var title: String {
        if case .custom(let color) = self { return color.hex }
        return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    var color: SidebarTagColor {
        switch self {
        case .rose: .init(red: 0xef, green: 0xb8, blue: 0xc8)
        case .peach: .init(red: 0xef, green: 0xc2, blue: 0xa1)
        case .gold: .init(red: 0xe8, green: 0xd2, blue: 0x8d)
        case .lime: .init(red: 0xc8, green: 0xdd, blue: 0xa0)
        case .mint: .init(red: 0xa6, green: 0xd8, blue: 0xb9)
        case .teal: .init(red: 0x9e, green: 0xd7, blue: 0xd1)
        case .sky: .init(red: 0xad, green: 0xd5, blue: 0xed)
        case .periwinkle: .init(red: 0xb7, green: 0xc5, blue: 0xed)
        case .lavender: .init(red: 0xcb, green: 0xb9, blue: 0xed)
        case .orchid: .init(red: 0xdf, green: 0xb2, blue: 0xdd)
        case .slate: .init(red: 0xc3, green: 0xca, blue: 0xd4)
        case .forest: .init(red: 0x27, green: 0x56, blue: 0x41)
        case .ocean: .init(red: 0x29, green: 0x4f, blue: 0x75)
        case .plum: .init(red: 0x64, green: 0x42, blue: 0x70)
        case .custom(let color): color
        }
    }
}

nonisolated enum SidebarTagPalette {
    /// Version 1: FNV-1a over the slug's Unicode scalars selects an HSL color with hue 0-359,
    /// saturation 0.48-0.60 and lightness 0.64-0.72 (the approved prototype's reference).
    static func automatic(_ slug: String) -> SidebarTagColor {
        var hash: UInt32 = 2_166_136_261
        for scalar in slug.unicodeScalars { hash = (hash ^ scalar.value) &* 16_777_619 }
        return hsl(hue: Int(hash % 360), saturationStep: Int((hash >> 9) % 13), lightnessStep: Int((hash >> 17) % 9))
    }

    static func hsl(hue: Int, saturationStep: Int, lightnessStep: Int) -> SidebarTagColor {
        let sector = Double(hue) / 60
        let saturation = 0.48 + Double(saturationStep) / 100
        let lightness = 0.64 + Double(lightnessStep) / 100
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - chroma / 2
        let (r, g, b): (Double, Double, Double) = switch sector {
        case ..<1: (chroma, x, 0)
        case ..<2: (x, chroma, 0)
        case ..<3: (0, chroma, x)
        case ..<4: (0, x, chroma)
        case ..<5: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        func channel(_ value: Double) -> UInt8 { UInt8(((value + m) * 255).rounded()) }
        return .init(red: channel(r), green: channel(g), blue: channel(b))
    }
}

/// One chip: a slug, who assigned it, and its shared color.
nonisolated struct SidebarResolvedTag: Equatable, Identifiable, Sendable {
    let slug: String
    let human: Bool
    let agent: Bool
    let swatch: SidebarTagSwatch?
    var id: String { slug }
    var background: SidebarTagColor { swatch?.color ?? SidebarTagPalette.automatic(slug) }
    var foreground: SidebarTagColor { background.foreground }

    var owners: String {
        switch (human, agent) {
        case (true, true): "You + agent"
        case (true, false): "You"
        default: "Agent"
        }
    }

    /// Human tags first, then agent-only tags, each in assignment order.
    static func resolve(human: [String], agent: [String], colors: [String: SidebarTagSwatch]) -> [Self] {
        var order: [String] = []
        for slug in human + agent where !order.contains(slug) { order.append(slug) }
        return order.map { .init(slug: $0, human: human.contains($0), agent: agent.contains($0), swatch: colors[$0]) }
    }

    static func summary(_ tags: [Self]) -> String {
        tags.map { "\($0.slug) (\($0.owners.lowercased()))" }.joined(separator: ", ")
    }
}

/// The human's tags and the shared color overrides, in the sidebar's own container.
nonisolated struct SidebarTagSettings: SidebarPreferenceValue {
    /// Named-only choices stay compatible with old builds; custom hex requires format 2.
    var version: Int {
        colors.values.contains { if case .custom = $0 { return true }; return false } ? 2 : 1
    }
    /// Exact session UUID (uppercase) to the human's slugs, in order.
    var assignments: [String: [String]] = [:]
    /// Slug to its human color; absent means the automatic color.
    var colors: [String: SidebarTagSwatch] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey { case version, assignments, colors }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decode(Int.self, forKey: .version)
        guard [1, 2].contains(storedVersion) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported tag preferences.")
        }
        assignments = try container.decode([String: [String]].self, forKey: .assignments)
        colors = try container.decode([String: SidebarTagSwatch].self, forKey: .colors)
        if storedVersion == 1, colors.values.contains(where: {
            if case .custom = $0 { return true }
            return false
        }) {
            throw DecodingError.dataCorruptedError(forKey: .colors, in: container, debugDescription: "Custom colors require version 2.")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(assignments, forKey: .assignments)
        try container.encode(colors, forKey: .colors)
    }

    /// Above the largest valid store (about 1.6 MB), so the entry caps, which pruning handles, always bind first.
    static let maximumStoredBytes = 4_194_304
    static let maximumEntries = 2_048
    static let failOpen = Self()
    static let unreadableNotice = "Tags unavailable."
    static let saveNotice = "Tags not saved."

    static func key(_ session: UUID) -> String { session.uuidString }

    var isValid: Bool {
        assignments.count <= Self.maximumEntries && colors.count <= Self.maximumEntries
            && assignments.allSatisfy { key, slugs in
                UUID(uuidString: key)?.uuidString == key && !slugs.isEmpty
                    && slugs.count <= SidebarTagSlug.maximumPerSource && Set(slugs).count == slugs.count
                    && slugs.allSatisfy(SidebarTagSlug.isCanonical)
            }
            && colors.keys.allSatisfy(SidebarTagSlug.isCanonical)
    }
}

/// Agents' own tags, written only by the controller's exact-self `tags` command and read here
/// through the sidebar's existing read-only Copilot grant. The sidebar never writes it.
nonisolated struct SidebarAgentTagsFile: Sendable {
    static let filename = "agent-tags.json"
    static let maximumBytes = 2_097_152
    static let maximumSessions = 2_048
    let directory: URL

    static func standard() -> Self? {
        (try? CopilotPaths.integrationRoot()).map { .init(directory: $0.appendingPathComponent("tags", isDirectory: true)) }
    }

    /// No store yet reads as no agent tags. Anything else invalid throws; callers keep what they had.
    func read() throws -> [UUID: [String]] {
        let owner = getuid()
        let folder: Int32
        do {
            folder = try CopilotFileAccess.openDirectory(directory, owner: owner)
        } catch CopilotFileError.missing {
            return [:]
        }
        defer { close(folder) }
        let data: Data
        do {
            data = try CopilotFileAccess.readStableRegular(
                at: folder, filename: Self.filename, owner: owner, maximum: Self.maximumBytes, permissions: 0o600
            )
        } catch CopilotFileError.missing {
            return [:]
        }
        return try Self.decode(data)
    }

    /// The controller's rules (`tags_decode`): plain UTF-8 JSON with unique keys and Int64
    /// integers only. Both run scripts/test-fixtures/tag-store-cases.json.
    static func decode(_ data: Data) throws -> [UUID: [String]] {
        guard !data.contains(0), !SidebarBeatsState.containsByteOrderMark(data), SidebarBeatsState.isPlainJSON(data),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "sessions"],
              let version = object["version"] as? NSNumber, CFGetTypeID(version) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(version), version.intValue == SidebarTagSlug.version,
              let sessions = object["sessions"] as? [String: Any], sessions.count <= maximumSessions
        else { throw CopilotFileError.changed }
        var result: [UUID: [String]] = [:]
        for (key, value) in sessions {
            guard let id = UUID(uuidString: key), id.uuidString.lowercased() == key,
                  let slugs = value as? [String], !slugs.isEmpty, slugs.count <= SidebarTagSlug.maximumPerSource,
                  Set(slugs).count == slugs.count, slugs.allSatisfy(SidebarTagSlug.isCanonical)
            else { throw CopilotFileError.changed }
            result[id] = slugs
        }
        return result
    }
}
