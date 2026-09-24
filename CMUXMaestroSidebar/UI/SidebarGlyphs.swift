import CoreText
import CryptoKit
import SwiftUI

final class SidebarIconResources: NSObject {
    static let bundle = Bundle(for: SidebarIconResources.self)
}

@MainActor
final class SidebarGlyphCatalog {
    struct Glyph: Identifiable {
        let name: String
        let character: String
        let code: String
        var id: String { name }
    }

    struct Preset: Decodable, Identifiable {
        let id: String
        let name: String
        let glyph: String
        let color: SidebarAvatarColor
    }

    private struct RawGlyph: Decodable {
        let char: String?
        let code: String?
        let version: String?
    }

    enum ResourceError: Error {
        case unavailable, invalid, unsupportedVersion
    }

    static let version = "3.5.1"
    static let shared = Result { try SidebarGlyphCatalog() }
    static var notice: String? {
        if case .failure = shared { return "Icon font unavailable. Reinstall the preview; session state is unchanged." }
        return nil
    }

    let glyphs: [String: Glyph]
    let presets: [Preset]
    private let orderedGlyphs: [Glyph]
    private let searchTerms: [String: String]
    private let font: CTFont
    private let paths = NSCache<NSString, CGPath>()

    private init() throws {
        let catalogData = try Self.resource("glyphnames.json", maximum: 2_097_152)
        let fontData = try Self.resource("SymbolsNerdFont-Regular.ttf", maximum: 4_194_304)
        guard Self.digest(catalogData) == "d2fa6615a38eb527462cb71ff17aa44b1d6453d437ed263ab8d5b458393669e8",
              Self.digest(fontData) == "2839f0a572d4559f3f17a6fb74b8772e183f0c0a47150998ab194932cad55829" else {
            throw ResourceError.invalid
        }
        let raw = try JSONDecoder().decode([String: RawGlyph].self, from: catalogData)
        guard raw["METADATA"]?.version == Self.version else { throw ResourceError.unsupportedVersion }
        guard raw.count <= 20_000 else { throw ResourceError.invalid }
        var glyphs: [String: Glyph] = [:]
        for (name, value) in raw where name != "METADATA" && name != "cod-blank" {
            guard SidebarGlyphName.isValid(name), let character = value.char, let code = value.code,
                  let integer = UInt32(code, radix: 16), let scalar = UnicodeScalar(integer),
                  String(scalar) == character else { throw ResourceError.invalid }
            glyphs[name] = .init(name: name, character: character, code: code)
        }
        self.glyphs = glyphs
        presets = try JSONDecoder().decode(
            [Preset].self, from: Self.resource("presets.json", maximum: 32_768)
        )
        guard presets.count <= 64, Set(presets.map(\.id)).count == presets.count,
              presets.allSatisfy({ SidebarGlyphName.isValid($0.id) && glyphs[$0.glyph] != nil }) else {
            throw ResourceError.invalid
        }
        var preferred = Set<String>()
        let favorites = presets.compactMap { preset in
            preferred.insert(preset.glyph).inserted ? glyphs[preset.glyph] : nil
        }
        orderedGlyphs = favorites + glyphs.values.filter { !preferred.contains($0.name) }.sorted { $0.name < $1.name }
        let aliases = Dictionary(grouping: presets, by: \.glyph)
        searchTerms = glyphs.mapValues { glyph in
            Self.normalized(([glyph.name] + (aliases[glyph.name] ?? []).flatMap { [$0.id, $0.name] }).joined(separator: " "))
        }
        guard let provider = CGDataProvider(data: fontData as CFData),
              let graphicsFont = CGFont(provider) else { throw ResourceError.invalid }
        font = CTFontCreateWithGraphicsFont(graphicsFont, 1_000, nil, nil)
        paths.countLimit = 256
    }

    func glyph(named value: String) -> Glyph? {
        var name = value.lowercased()
        if name.hasPrefix("nf-") { name = String(name.dropFirst(3)) }
        name = presets.first(where: { $0.id == name })?.glyph ?? name
        return glyphs[name]
    }

    func search(_ query: String) -> [Glyph] {
        let terms = Self.normalized(query).split(separator: " ")
        guard !terms.isEmpty else { return orderedGlyphs }
        return orderedGlyphs.filter { glyph in
            let text = searchTerms[glyph.name] ?? ""
            return terms.allSatisfy { text.contains($0) }
        }
    }

    private static func normalized(_ value: String) -> String {
        var value = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("nf-") { value = String(value.dropFirst(3)) }
        return value.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    func path(for name: String) -> CGPath? {
        guard let entry = glyph(named: name) else { return nil }
        if let cached = paths.object(forKey: entry.name as NSString) { return cached }
        let characters = Array(entry.character.utf16)
        var mapped = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, characters, &mapped, characters.count),
              let glyph = mapped.first(where: { $0 != 0 }),
              let path = CTFontCreatePathForGlyph(font, glyph, nil),
              path.boundingBoxOfPath.width > 0, path.boundingBoxOfPath.height > 0 else { return nil }
        paths.setObject(path, forKey: entry.name as NSString)
        return path
    }

    private static func resource(_ name: String, maximum: Int) throws -> Data {
        guard let url = SidebarIconResources.bundle.resourceURL?
            .appendingPathComponent("NerdFonts", isDirectory: true).appendingPathComponent(name),
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximum else { throw ResourceError.unavailable }
        return try Data(contentsOf: url)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct SidebarFontGlyphShape: Shape {
    let outline: CGPath

    func path(in rect: CGRect) -> Path {
        let bounds = outline.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return Path() }
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        return Path(outline).applying(CGAffineTransform(
            a: scale, b: 0, c: 0, d: -scale,
            tx: rect.midX - bounds.midX * scale, ty: rect.midY + bounds.midY * scale
        ))
    }
}

struct SidebarGlyphIcon: View {
    let name: String
    var tint: Color = .primary
    var catalog: Result<SidebarGlyphCatalog, Error> = SidebarGlyphCatalog.shared

    var body: some View {
        Group {
            if case .success(let catalog) = catalog,
               let path = catalog.path(for: name) {
                SidebarFontGlyphShape(outline: path).fill(tint)
                    .accessibilityLabel(name)
            } else {
                Image(systemName: "questionmark.square")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Icon unavailable: \(name)")
                    .help("Glyph \(name) is unavailable in the bundled Nerd Font.")
            }
        }
        .frame(width: 20, height: 20)
        .padding(2)
    }
}
