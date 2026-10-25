import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct MaestroNotificationPet: Sendable {
    let home: URL
    let bundledSheet: URL

    static func sidebarRoot(home: URL) -> URL {
        home.appendingPathComponent(
            "Library/Containers/com.jdylanmc.CMUXMaestroPreview.Extension/Data/Library/Application Support/CMUXMaestroPreview"
        )
    }

    func png(session: UUID, agentChoice: String?) throws -> Data {
        let chosen = humanChoice(session: session) ?? agentChoice ?? "maestro"
        if chosen != "maestro", CopilotSessionAppearance.validPetID(chosen) {
            let folders = [
                Self.sidebarRoot(home: home).appendingPathComponent("Pets/\(chosen)"),
                home.appendingPathComponent("Library/Application Support/CMUXMaestroPreview/Copilot/pets/sessions/\(session.uuidString.lowercased())/\(chosen)")
            ]
            for folder in folders {
                if let frame = try? customFrame(folder: folder, id: chosen) { return frame }
            }
        }
        return try Self.idleFrame(Self.readBundled(bundledSheet, maximum: 10 * 1024 * 1024))
    }

    private func humanChoice(session: UUID) -> String? {
        let domain = "com.jdylanmc.CMUXMaestroPreview.Extension"
        let file = home.appendingPathComponent("Library/Containers/\(domain)/Data/Library/Preferences/\(domain).plist")
        guard let data = try? Self.read(file, maximum: 262_144),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let encoded = plist["sidebar.pet.overrides.v1"] as? Data,
              let overrides = try? JSONDecoder().decode([String: String].self, from: encoded),
              overrides.count <= 512 else { return nil }
        return overrides[session.uuidString.lowercased()]
    }

    private func customFrame(folder: URL, id: String) throws -> Data {
        struct Manifest: Decodable { let id: String; let spritesheetPath: String }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Self.read(folder.appendingPathComponent("pet.json"), maximum: 65_536))
        guard manifest.id == id, !manifest.spritesheetPath.isEmpty,
              !manifest.spritesheetPath.contains("/"), ![".", ".."].contains(manifest.spritesheetPath),
              ["png", "webp"].contains((manifest.spritesheetPath as NSString).pathExtension.lowercased()) else {
            throw MaestroNotificationFailure.unavailable
        }
        return try Self.idleFrame(Self.read(folder.appendingPathComponent(manifest.spritesheetPath), maximum: 10 * 1024 * 1024))
    }

    static func read(_ file: URL, maximum: Int) throws -> Data {
        let directory = try CopilotFileAccess.openDirectory(file.deletingLastPathComponent(), owner: getuid())
        defer { close(directory) }
        let stamp = try CopilotFileAccess.statEntry(at: directory, name: file.lastPathComponent)
        guard stamp.permissions & 0o022 == 0 else { throw CopilotFileError.unsafePath }
        return try CopilotFileAccess.readStableRegular(
            at: directory, filename: file.lastPathComponent, owner: getuid(), maximum: maximum,
            permissions: stamp.permissions
        )
    }

    static func readBundled(_ file: URL, maximum: Int, user: UInt32 = getuid()) throws -> Data {
        let directory = try CopilotFileAccess.openDirectory(file.deletingLastPathComponent())
        defer { close(directory) }
        let parent = try CopilotFileAccess.statFile(directory)
        let stamp = try CopilotFileAccess.statEntry(at: directory, name: file.lastPathComponent)
        guard [0, user].contains(parent.uid), parent.permissions & 0o022 == 0,
              [0, user].contains(stamp.uid), stamp.permissions & 0o022 == 0 else {
            throw CopilotFileError.unsafePath
        }
        return try CopilotFileAccess.readStableRegular(
            at: directory, filename: file.lastPathComponent, owner: stamp.uid, maximum: maximum,
            permissions: stamp.permissions
        )
    }

    static func idleFrame(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (512...4096).contains(width), width % 8 == 0,
              height >= (9 * 208 * width + 1535) / 1536, height <= width * 2,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let frame = image.cropping(to: CGRect(x: 0, y: 0, width: width / 8, height: 208 * width / 1536))
        else { throw MaestroNotificationFailure.unavailable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw MaestroNotificationFailure.unavailable
        }
        CGImageDestinationAddImage(destination, frame, nil)
        guard CGImageDestinationFinalize(destination) else { throw MaestroNotificationFailure.unavailable }
        return output as Data
    }
}
