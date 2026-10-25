import Darwin
import Foundation

nonisolated struct MaestroNotificationAssets {
    static func sidebarRoot(home: URL) -> URL {
        home.appendingPathComponent(
            "Library/Containers/com.jdylanmc.CMUXMaestroPreview.Extension/Data/Library/Application Support/CMUXMaestroPreview"
        )
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
}
