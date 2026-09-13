import Darwin
import Foundation

nonisolated enum CopilotPathError: Error {
    case homeUnavailable
}

nonisolated enum CopilotPaths {
    static func realUserHome() throws -> URL {
        // NSHomeDirectory points inside the container in an ExtensionKit host.
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var storage = [CChar](repeating: 0, count: 16_384)
        let path: String? = storage.withUnsafeMutableBufferPointer { buffer in
            guard getpwuid_r(getuid(), &entry, buffer.baseAddress, buffer.count, &result) == 0,
                  result != nil, let home = entry.pw_dir else { return nil }
            return String(validatingCString: home)
        }
        guard let path, path.hasPrefix("/"), path != "/" else {
            throw CopilotPathError.homeUnavailable
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func integrationRoot() throws -> URL {
        try realUserHome().appendingPathComponent(
            "Library/Application Support/CMUXMaestroPreview/Copilot", isDirectory: true
        )
    }

    static func bindingDirectory() throws -> URL {
        try integrationRoot().appendingPathComponent("bindings", isDirectory: true)
    }

    static func sessionStateRoot() throws -> URL {
        try realUserHome().appendingPathComponent(".copilot/session-state", isDirectory: true)
    }
}
