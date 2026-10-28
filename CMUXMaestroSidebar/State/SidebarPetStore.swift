import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Nine-row Codex sheets and the fixed twenty-row Maestro mood atlas.
enum SidebarPetSheet {
    static let columns = 8
    static let rows = 9
    static let cellWidth = 192
    static let cellHeight = 208
    static let width = columns * cellWidth
    static let height = rows * cellHeight
    static let moodRows = 20
    /// A standard extended atlas is 25,559,040 RGBA bytes, before decoder/cache overhead.
    static let maximumMoodWidth = 1536

    enum Mood: String, CaseIterable {
        case idle, thinking, working, delegating, question
        case needsPermission = "needs-permission"
        case confused, content, startled, sad, compacting, sleepy, gone, proud, celebrating

        fileprivate var rows: (preferred: Int, fallback: Int) {
            switch self {
            case .idle: (0, 0)
            case .thinking: (11, 8)
            case .working: (7, 7)
            case .delegating: (12, 1)
            case .question: (6, 6)
            case .needsPermission: (13, 6)
            case .confused: (14, 8)
            case .content: (3, 3)
            case .startled: (9, 4)
            case .sad: (5, 5)
            case .compacting: (15, 2)
            case .sleepy: (16, 0)
            case .gone: (17, 0)
            case .proud: (18, 3)
            case .celebrating: (19, 4)
            }
        }
    }

    struct Playback: Equatable {
        let row: Int
        let frameCount: Int
    }

    static func hasMoods(width: Int, height: Int) -> Bool {
        width % columns == 0 && (512...maximumMoodWidth).contains(width)
            && height == (moodRows * cellHeight * width + Self.width - 1) / Self.width
    }

    /// Only exact twenty-row geometry opts in; legacy tails (including Codex v2) stay legacy.
    static func accepts(width: Int, height: Int) -> Bool {
        guard width % columns == 0, (512...4096).contains(width) else { return false }
        let minimum = (rows * cellHeight * width + Self.width - 1) / Self.width
        return (height >= minimum && height <= 2 * width) || hasMoods(width: width, height: height)
    }

    /// Select the authored mood row or its legacy fallback, including that row's loop length.
    static func playback(for mood: Mood, width: Int, height: Int) -> Playback? {
        guard accepts(width: width, height: height) else { return nil }
        let row = hasMoods(width: width, height: height) ? mood.rows.preferred : mood.rows.fallback
        let count: Int
        switch row {
        case 9, 19: count = 5
        case 12: count = 8
        case 11, 13...17: count = 6
        case 18: count = 4
        default: count = frameCounts[row]
        }
        return Playback(row: row, frameCount: count)
    }

    /// Pixel scale of a sheet relative to the 1536-wide standard.
    static func scale(width: Int) -> CGFloat { CGFloat(width) / CGFloat(Self.width) }
    static let maximumBytes = 10 * 1024 * 1024
    static let frameCounts = [6, 8, 8, 4, 5, 8, 6, 6, 6]
    /// Maximum trim, independent of the alpha measured across playable frames.
    static let maximumTopInset: CGFloat = 19 / 208

    /// Fully transparent top rows shared by every played cell, as a fraction of cell height, capped at
    /// `maximumTopInset`. `pixels` is a top-down premultiplied RGBA bitmap of the whole sheet.
    static func topInset(pixels: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> CGFloat {
        let scale = Self.scale(width: width)
        let cellWidth = Int((CGFloat(Self.cellWidth) * scale).rounded())
        let cellHeight = CGFloat(Self.cellHeight) * scale
        let limit = Int((cellHeight * maximumTopInset).rounded(.down))
        var inset = limit
        for mood in Mood.allCases {
            guard let playback = playback(for: mood, width: width, height: height) else { return 0 }
            let top = Int((CGFloat(playback.row) * cellHeight).rounded())
            for column in 0..<playback.frameCount {
                let left = column * cellWidth
                var clear = 0
                scan: while clear < inset, top + clear < height {
                    let line = pixels + (top + clear) * bytesPerRow
                    for x in left..<min(left + cellWidth, width) where line[x * 4 + 3] != 0 { break scan }
                    clear += 1
                }
                inset = min(inset, clear)
                if inset == 0 { return 0 }
            }
        }
        return CGFloat(inset) / cellHeight
    }
}

enum SidebarPetState: Equatable, CaseIterable {
    case idle, working, needsInput, finished, failed

    var row: Int {
        switch self {
        case .idle: 0
        case .finished: 3
        case .failed: 5
        case .needsInput: 6
        case .working: 7
        }
    }

    var frameCount: Int { SidebarPetSheet.frameCounts[row] }

    var title: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .needsInput: "Needs input"
        case .finished: "Turn finished"
        case .failed: "Blocked or failed"
        }
    }

    static func resolve(visual: SidebarVisual?, needsInput: Bool) -> SidebarPetState {
        if needsInput { return .needsInput }
        guard let visual else { return .idle }
        if visual.tone == .green { return .working }
        switch visual.symbol {
        case "checkmark.circle": return .finished
        case "exclamationmark.circle", "pause.circle", "xmark.circle": return .failed
        default: return .idle
        }
    }
}

struct SidebarPetDescriptor: Identifiable, Equatable {
    enum Source: Equatable { case bundled, uploaded, session }
    let id: String
    let displayName: String
    let source: Source
    var isBundled: Bool { source == .bundled }
}

private struct SidebarPetManifest: Codable {
    var id: String?
    var displayName: String?
    var description: String?
    var spritesheetPath: String?
}

/// Pet catalog and per-session choices. Precedence: human choice, then the agent's own
/// verified choice, then the bundled Maestro pet. A pet an agent makes is usable only by
/// that agent's session until the human saves it to the shared uploaded-pet repository.
@Observable
@MainActor
final class SidebarPetStore {
    static let defaultID = "maestro"
    private static let overridesKey = "sidebar.pet.overrides.v1"
    private static let hiddenKey = "sidebar.pet.hidden.v1"
    private static let maximumOverrides = 512
    private let sessionCacheSeconds: TimeInterval
    static let galleryURL = URL(string: "https://codexpets.org/gallery")!
    static let generatorURL = URL(string: "https://www.autosprite.io/codex-pet-generator")!

    private(set) var installed: [SidebarPetDescriptor] = []
    private(set) var overrides: [String: String] = [:]
    private(set) var hidden: Set<String> = []
    private(set) var notice: String?
    private var sheets: [String: CGImage] = [:]
    private var topInsets: [String: CGFloat] = [:]
    /// Sheets that passed the header probe but failed to decode; retried after `refresh()`.
    @ObservationIgnored private var failedSheets: Set<String> = []
    private var frames: [String: CGImage] = [:]
    private var sessionCache: [UUID: (date: Date, pets: [SidebarPetDescriptor])] = [:]
    private let defaults: UserDefaults
    private let uploadDirectory: URL
    private let sessionDirectory: URL?

    init(defaults: UserDefaults = .standard, uploadDirectory: URL? = nil, sessionDirectory: URL? = nil,
         sessionCacheSeconds: TimeInterval = 3) {
        self.defaults = defaults
        self.sessionCacheSeconds = sessionCacheSeconds
        self.uploadDirectory = uploadDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CMUXMaestroPreview/Pets", isDirectory: true)
        self.sessionDirectory = sessionDirectory ?? (try? CopilotPaths.integrationRoot())
            .map { $0.appendingPathComponent("pets/sessions", isDirectory: true) }
        overrides = (defaults.data(forKey: Self.overridesKey)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }) ?? [:]
        hidden = Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
        refresh()
    }

    // MARK: Catalog

    /// Pets that every agent may use, plus any this session's agent made for itself.
    func available(for session: UUID?) -> [SidebarPetDescriptor] {
        (installed + (session.map(sessionPets) ?? [])).filter { !failedSheets.contains(sheetKey($0, session: session)) }
    }

    private func sheetKey(_ pet: SidebarPetDescriptor, session: UUID?) -> String {
        pet.source == .session ? "\(session?.uuidString.lowercased() ?? "")/\(pet.id)" : pet.id
    }

    func descriptor(_ id: String, session: UUID?) -> SidebarPetDescriptor? {
        installed.first { $0.id == id } ?? session.flatMap { sessionPets($0).first { $0.id == id } }
    }

    private func sessionPets(_ session: UUID) -> [SidebarPetDescriptor] {
        if let cached = sessionCache[session], Date().timeIntervalSince(cached.date) < sessionCacheSeconds {
            return cached.pets
        }
        let pets = Self.scan(sessionDirectory?.appendingPathComponent(session.uuidString.lowercased(), isDirectory: true),
                             source: .session, excluding: Set(installed.map(\.id)))
        sessionCache[session] = (Date(), pets)
        return pets
    }

    func refresh() {
        sessionCache = [:]
        failedSheets = []
        installed = [SidebarPetDescriptor(id: Self.defaultID, displayName: "Maestro", source: .bundled)]
            + Self.scan(uploadDirectory, source: .uploaded, excluding: [Self.defaultID])
    }

    nonisolated private static func scan(_ directory: URL?, source: SidebarPetDescriptor.Source,
                                         excluding: Set<String>) -> [SidebarPetDescriptor] {
        guard let directory else { return [] }
        var seen = excluding
        var pets: [SidebarPetDescriptor] = []
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let manifest = manifest(in: folder), let id = manifest.id, id == folder.lastPathComponent,
                  seen.insert(id).inserted, sheetFits(in: folder, manifest: manifest) else { continue }
            pets.append(.init(id: id, displayName: manifest.displayName ?? id, source: source))
        }
        return pets
    }

    // MARK: Choice

    func resolvedID(session: UUID?, agentChoice: String?) -> String {
        if let session, let id = overrides[session.uuidString.lowercased()],
           descriptor(id, session: session) != nil { return id }
        if let agentChoice, descriptor(agentChoice, session: session) != nil { return agentChoice }
        return Self.defaultID
    }

    func hasOverride(session: UUID) -> Bool { overrides[session.uuidString.lowercased()] != nil }

    /// The pet shown for an exact agent session, or nil with no session or when hidden for it.
    func visibleID(session: UUID?, agentChoice: String?) -> String? {
        guard let session, !isHidden(session: session) else { return nil }
        return resolvedID(session: session, agentChoice: agentChoice)
    }

    func isHidden(session: UUID) -> Bool { hidden.contains(session.uuidString.lowercased()) }

    func setHidden(_ value: Bool, session: UUID) {
        let key = session.uuidString.lowercased()
        var updated = hidden
        if value {
            updated.insert(key)
            if updated.count > Self.maximumOverrides, let drop = updated.sorted().first(where: { $0 != key }) {
                updated.remove(drop)
            }
        } else {
            updated.remove(key)
        }
        hidden = updated
        defaults.set(updated.sorted(), forKey: Self.hiddenKey)
    }

    /// A human choice of the bundled pet, which wins over the agent's own choice until reset.
    func resetToDefault(session: UUID) { choose(Self.defaultID, session: session) }

    func isDefaultChoice(session: UUID) -> Bool { overrides[session.uuidString.lowercased()] == Self.defaultID }

    func choose(_ id: String, session: UUID) {
        guard descriptor(id, session: session) != nil else { return }
        var updated = overrides
        let key = session.uuidString.lowercased()
        updated[key] = id
        if updated.count > Self.maximumOverrides, let drop = updated.keys.sorted().first(where: { $0 != key }) {
            updated.removeValue(forKey: drop)
        }
        save(updated)
    }

    func clearChoice(session: UUID) {
        var updated = overrides
        updated.removeValue(forKey: session.uuidString.lowercased())
        save(updated)
    }

    private func save(_ value: [String: String]) {
        overrides = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.overridesKey) }
    }

    // MARK: Repository

    func removeUpload(_ id: String) {
        guard installed.first(where: { $0.id == id })?.source == .uploaded else { return }
        try? FileManager.default.removeItem(at: uploadDirectory.appendingPathComponent(id, isDirectory: true))
        sheets[id] = nil
        topInsets[id] = nil
        frames.removeAll()
        refresh()
    }

    /// Copies an agent-made session pet into the shared repository so any agent can use it.
    @discardableResult
    func saveToRepository(_ id: String, session: UUID) -> String? {
        guard let pet = descriptor(id, session: session), pet.source == .session,
              let source = sessionDirectory?.appendingPathComponent(session.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent(id, isDirectory: true),
              let manifest = Self.manifest(in: source),
              let image = manifest.spritesheetPath.flatMap(Self.plainFilename) else { return nil }
        let name = pet.displayName
        return store(Self.Package(id: id, name: name,
                                  data: try? Data(contentsOf: source.appendingPathComponent(image)),
                                  ext: (image as NSString).pathExtension.lowercased()), session: session)
    }

    /// Accepts a Codex pet folder (pet.json + spritesheet) or a bare 1536x1872 PNG/WebP sheet.
    /// Returns the installed pet id on success.
    @discardableResult
    func upload(from url: URL) -> String? {
        do {
            let (id, name, data, ext) = try Self.read(url)
            return store(Self.Package(id: id, name: name, data: data, ext: ext), session: nil)
        } catch let error as PetError {
            notice = error.message
        } catch {
            notice = "The pet could not be uploaded."
        }
        return nil
    }

    fileprivate struct Package { let id: String; let name: String; let data: Data?; let ext: String }

    private func store(_ package: Package, session: UUID?) -> String? {
        guard let data = package.data, ["webp", "png"].contains(package.ext) else {
            notice = "The pet could not be saved."
            return nil
        }
        let id = package.id == Self.defaultID ? "\(package.id)-custom" : package.id
        do {
            let target = uploadDirectory.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try data.write(to: target.appendingPathComponent("spritesheet.\(package.ext)"), options: .atomic)
            let manifest = SidebarPetManifest(id: id, displayName: package.name, description: nil,
                                              spritesheetPath: "spritesheet.\(package.ext)")
            try JSONEncoder().encode(manifest).write(to: target.appendingPathComponent("pet.json"), options: .atomic)
            notice = nil
            sheets[id] = nil
            topInsets[id] = nil
            frames.removeAll()
            refresh()
            if let session, id != package.id { choose(id, session: session) }
            return id
        } catch {
            notice = "The pet could not be saved."
            return nil
        }
    }

    // MARK: Frames

    func sheet(for id: String, session: UUID?) -> CGImage? {
        decodedSheet(for: id, session: session)?.image
    }

    /// Transparent top band of the pet's played cells (fraction of cell height), measured once per decode.
    func topInset(petID: String, session: UUID?) -> CGFloat {
        (decodedSheet(for: petID, session: session) ?? decodedSheet(for: Self.defaultID, session: nil))?.topInset ?? 0
    }

    private func decodedSheet(for id: String, session: UUID?) -> DecodedSheet? {
        guard let pet = descriptor(id, session: session) else { return nil }
        let key = sheetKey(pet, session: session)
        if let cached = sheets[key], let inset = topInsets[key] { return .init(image: cached, topInset: inset) }
        guard !failedSheets.contains(key) else { return nil }
        let image: DecodedSheet?
        switch pet.source {
        case .bundled:
            image = Bundle.main.url(forResource: "maestro-pet", withExtension: "webp").flatMap(Self.image)
        case .uploaded:
            let folder = uploadDirectory.appendingPathComponent(id, isDirectory: true)
            image = Self.manifest(in: folder).flatMap { Self.sheet(in: folder, manifest: $0) }
        case .session:
            let folder = session.flatMap {
                sessionDirectory?.appendingPathComponent($0.uuidString.lowercased(), isDirectory: true)
            }?.appendingPathComponent(id, isDirectory: true)
            image = folder.flatMap { folder in Self.manifest(in: folder).flatMap { Self.sheet(in: folder, manifest: $0) } }
        }
        if let image {
            sheets[key] = image.image
            topInsets[key] = image.topInset
        } else {
            failedSheets.insert(key)
        }
        return image
    }

    func frame(petID: String, session: UUID?, state: SidebarPetState, index: Int) -> CGImage? {
        guard let sheet = sheet(for: petID, session: session) ?? sheet(for: Self.defaultID, session: nil) else { return nil }
        return frame(sheet: sheet, playback: .init(row: state.row, frameCount: state.frameCount), index: index)
    }

    func playback(petID: String, session: UUID?, mood: SidebarPetSheet.Mood) -> SidebarPetSheet.Playback? {
        guard let sheet = sheet(for: petID, session: session) ?? sheet(for: Self.defaultID, session: nil) else { return nil }
        return SidebarPetSheet.playback(for: mood, width: sheet.width, height: sheet.height)
    }

    func frame(petID: String, session: UUID?, mood: SidebarPetSheet.Mood, index: Int) -> CGImage? {
        guard let sheet = sheet(for: petID, session: session) ?? sheet(for: Self.defaultID, session: nil),
              let playback = SidebarPetSheet.playback(for: mood, width: sheet.width, height: sheet.height) else { return nil }
        return frame(sheet: sheet, playback: playback, index: index)
    }

    private func frame(sheet: CGImage, playback: SidebarPetSheet.Playback, index: Int) -> CGImage? {
        let column = ((index % playback.frameCount) + playback.frameCount) % playback.frameCount
        let key = "\(ObjectIdentifier(sheet).hashValue)/\(playback.row)/\(column)"
        if let cached = frames[key] { return cached }
        let scale = SidebarPetSheet.scale(width: sheet.width)
        let cellWidth = CGFloat(SidebarPetSheet.cellWidth) * scale, cellHeight = CGFloat(SidebarPetSheet.cellHeight) * scale
        let cell = sheet.cropping(to: CGRect(
            x: (CGFloat(column) * cellWidth).rounded(), y: (CGFloat(playback.row) * cellHeight).rounded(),
            width: cellWidth.rounded(), height: cellHeight.rounded()))
        if let cell { frames[key] = cell }
        return cell
    }

    nonisolated private static func sheet(in folder: URL, manifest: SidebarPetManifest) -> DecodedSheet? {
        manifest.spritesheetPath.flatMap(plainFilename).flatMap { image(folder.appendingPathComponent($0)) }
    }

    // MARK: Reading

    struct PetError: Error { let message: String }

    nonisolated private static func plainFilename(_ value: String) -> String? {
        let name = (value as NSString).lastPathComponent
        return name == value && !name.isEmpty && !name.hasPrefix(".") ? name : nil
    }

    nonisolated private static func manifest(in folder: URL) -> SidebarPetManifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("pet.json")), data.count < 64 * 1024 else { return nil }
        return try? JSONDecoder().decode(SidebarPetManifest.self, from: data)
    }

    struct DecodedSheet { let image: CGImage; let topInset: CGFloat }

    /// Catalog scans read only the image header; full decodes stay in the cached `decodedSheet`.
    nonisolated private static func sheetFits(in folder: URL, manifest: SidebarPetManifest) -> Bool {
        guard let name = manifest.spritesheetPath.flatMap(plainFilename),
              let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(name) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return SidebarPetSheet.accepts(width: width, height: height)
    }

    #if DEBUG
    private static let decodeLock = NSLock()
    nonisolated(unsafe) private static var decodes: [String: Int] = [:]
    /// Full sheet decode attempts per file path; a test seam for keeping decodes off repeated lookups.
    nonisolated static func decodeCount(_ url: URL) -> Int {
        decodeLock.withLock { decodes[url.standardizedFileURL.path, default: 0] }
    }
    #endif

    nonisolated private static func image(_ url: URL) -> DecodedSheet? {
        #if DEBUG
        decodeLock.withLock { decodes[url.standardizedFileURL.path, default: 0] += 1 }
        #endif
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= SidebarPetSheet.maximumBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              SidebarPetSheet.accepts(width: width, height: height),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              SidebarPetSheet.accepts(width: image.width, height: image.height) else { return nil }
        return decoded(image)
    }

    /// Lazy WebP/PNG images re-decode the whole sheet on every render; draw once into a bitmap.
    /// The same pass measures the played cells' transparent top band.
    nonisolated static func decoded(_ image: CGImage) -> DecodedSheet? {
        guard SidebarPetSheet.accepts(width: image.width, height: image.height),
              let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let decoded = context.makeImage(), let data = context.data else { return nil }
        let inset = SidebarPetSheet.topInset(
            pixels: data.assumingMemoryBound(to: UInt8.self), width: context.width, height: context.height,
            bytesPerRow: context.bytesPerRow)
        return DecodedSheet(image: decoded, topInset: inset)
    }

    nonisolated private static func slug(_ value: String) -> String {
        let lowered = value.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let parts = lowered.split(separator: "-").joined(separator: "-")
        return String(parts.prefix(48))
    }

    nonisolated private static func read(_ url: URL) throws -> (String, String, Data, String) {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            throw PetError(message: "That item could not be found.")
        }
        var sheetURL = url
        var name = url.deletingPathExtension().lastPathComponent
        var id = slug(name)
        if isFolder.boolValue {
            guard let manifest = manifest(in: url) else {
                throw PetError(message: "That folder has no readable pet.json. Choose a Codex pet folder or a spritesheet image.")
            }
            guard let path = manifest.spritesheetPath, let file = plainFilename(path) else {
                throw PetError(message: "pet.json must name a spritesheet file inside the pet folder.")
            }
            sheetURL = url.appendingPathComponent(file)
            name = manifest.displayName ?? manifest.id ?? name
            id = slug(manifest.id ?? name)
        }
        let ext = sheetURL.pathExtension.lowercased()
        guard ["webp", "png"].contains(ext) else { throw PetError(message: "The spritesheet must be a PNG or WebP image.") }
        let size = (try? sheetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= SidebarPetSheet.maximumBytes else {
            throw PetError(message: "The spritesheet must be smaller than 10 MB.")
        }
        guard image(sheetURL) != nil, let data = try? Data(contentsOf: sheetURL) else {
            throw PetError(message: "Use a legacy Codex sheet (standard 1536×1872, including v2) or a 20-row mood sheet (standard 1536×4160). Width must be a multiple of 8: 512–4096 for legacy sheets, 512–1536 for mood sheets.")
        }
        if id.isEmpty { id = "pet" }
        if id == defaultID { id = "maestro-custom" }
        return (id, String(name.prefix(64)), data, ext)
    }
}
