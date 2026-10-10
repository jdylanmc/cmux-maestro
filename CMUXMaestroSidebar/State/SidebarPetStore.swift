import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Codex pet sheet contract: 8 columns x 9 rows of 192x208 cells (1536x1872).
enum SidebarPetSheet {
    static let columns = 8
    static let rows = 9
    static let cellWidth = 192
    static let cellHeight = 208
    static let width = columns * cellWidth
    static let height = rows * cellHeight
    static let maximumBytes = 10 * 1024 * 1024
    /// Populated frames per row: idle, run right, run left, wave, jump, failure, waiting, working, review.
    static let frameCounts = [6, 8, 8, 4, 5, 8, 6, 6, 6]
}

enum SidebarPetState: Equatable {
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
    static let shared = SidebarPetStore()
    static let defaultID = "maestro"
    private static let overridesKey = "sidebar.pet.overrides.v1"
    private static let maximumOverrides = 512
    private static let sessionCacheSeconds: TimeInterval = 3
    static let galleryURL = URL(string: "https://codexpets.org/gallery")!
    static let generatorURL = URL(string: "https://www.autosprite.io/codex-pet-generator")!

    private(set) var installed: [SidebarPetDescriptor] = []
    private(set) var overrides: [String: String] = [:]
    private(set) var notice: String?
    private var sheets: [String: CGImage] = [:]
    private var sessionCache: [UUID: (date: Date, pets: [SidebarPetDescriptor])] = [:]
    private let defaults: UserDefaults
    private let uploadDirectory: URL
    private let sessionDirectory: URL?

    init(defaults: UserDefaults = .standard, uploadDirectory: URL? = nil, sessionDirectory: URL? = nil) {
        self.defaults = defaults
        self.uploadDirectory = uploadDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CMUXMaestroPreview/Pets", isDirectory: true)
        self.sessionDirectory = sessionDirectory ?? (try? CopilotPaths.integrationRoot())
            .map { $0.appendingPathComponent("pets/sessions", isDirectory: true) }
        overrides = (defaults.data(forKey: Self.overridesKey)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }) ?? [:]
        refresh()
    }

    // MARK: Catalog

    /// Pets that every agent may use, plus any this session's agent made for itself.
    func available(for session: UUID?) -> [SidebarPetDescriptor] {
        installed + (session.map(sessionPets) ?? [])
    }

    func descriptor(_ id: String, session: UUID?) -> SidebarPetDescriptor? {
        installed.first { $0.id == id } ?? session.flatMap { sessionPets($0).first { $0.id == id } }
    }

    private func sessionPets(_ session: UUID) -> [SidebarPetDescriptor] {
        if let cached = sessionCache[session], Date().timeIntervalSince(cached.date) < Self.sessionCacheSeconds {
            return cached.pets
        }
        let pets = Self.scan(sessionDirectory?.appendingPathComponent(session.uuidString.lowercased(), isDirectory: true),
                             source: .session, excluding: Set(installed.map(\.id)))
        sessionCache[session] = (Date(), pets)
        return pets
    }

    func refresh() {
        sessionCache = [:]
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
                  seen.insert(id).inserted, sheet(in: folder, manifest: manifest) != nil else { continue }
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
        guard let pet = descriptor(id, session: session) else { return nil }
        let key = pet.source == .session ? "\(session?.uuidString.lowercased() ?? "")/\(id)" : id
        if let cached = sheets[key] { return cached }
        let image: CGImage?
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
        if let image { sheets[key] = image }
        return image
    }

    func frame(petID: String, session: UUID?, state: SidebarPetState, index: Int) -> CGImage? {
        guard let sheet = sheet(for: petID, session: session) ?? sheet(for: Self.defaultID, session: nil),
              state.frameCount > 0 else { return nil }
        let column = ((index % state.frameCount) + state.frameCount) % state.frameCount
        return sheet.cropping(to: CGRect(
            x: column * SidebarPetSheet.cellWidth, y: state.row * SidebarPetSheet.cellHeight,
            width: SidebarPetSheet.cellWidth, height: SidebarPetSheet.cellHeight))
    }

    nonisolated private static func sheet(in folder: URL, manifest: SidebarPetManifest) -> CGImage? {
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

    nonisolated private static func image(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == SidebarPetSheet.width, image.height == SidebarPetSheet.height else { return nil }
        return image
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
            throw PetError(message: "The spritesheet must be \(SidebarPetSheet.width)×\(SidebarPetSheet.height) pixels (8×9 cells of 192×208).")
        }
        if id.isEmpty { id = "pet" }
        if id == defaultID { id = "maestro-custom" }
        return (id, String(name.prefix(64)), data, ext)
    }
}
