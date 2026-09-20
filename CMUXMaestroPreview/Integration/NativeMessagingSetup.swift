import Darwin
import Foundation

nonisolated enum NativeMessagingSetup {
    enum Failure: Error { case unavailable }

    static func setEnabled(_ enabled: Bool) throws {
        guard CopilotSetupAccess.currentAppAllowsChanges,
              let executable = Bundle.main.executableURL,
              let resources = Bundle.main.resourceURL else { throw Failure.unavailable }
        guard !enabled || NativeSigningReadiness.current else { throw Failure.unavailable }
        // This supported loader location preserves Copilot's configured home and session identities.
        // No repository-local .github directory or alternative COPILOT_HOME is created.
        guard ProcessInfo.processInfo.environment["COPILOT_HOME"] == nil,
              ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] == nil else {
            throw Failure.unavailable
        }
        let root = try CopilotPaths.orchestrationRoot()
        let rootFD = try HookFiles.privateDirectory(root)
        defer { close(rootFD) }
        let extensions = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/extensions/cmux-maestro-native-messaging")
        if !enabled {
            if unlinkat(rootFD, "native-setup.json", 0) != 0 && errno != ENOENT { throw Failure.unavailable }
            // Inert loader may remain on disk; disabling does not restart or stop any session.
            return
        }
        let bin = try CopilotFileAccess.openDirectory(root.appendingPathComponent("bin"), owner: getuid())
        defer { close(bin) }
        guard faccessat(bin, "cmux-maestro-orchestrator", X_OK, 0) == 0 else { throw Failure.unavailable }
        let directory = try HookFiles.privateDirectory(extensions)
        defer { close(directory) }
        for name in ["extension.mjs", "adapter.mjs"] {
            let source = resources.appendingPathComponent("native-messaging/\(name)")
            let data = try Data(contentsOf: source)
            guard !data.isEmpty, data.count <= 65_536 else { throw Failure.unavailable }
            try HookFiles.atomicWrite(data, name: name, directory: directory)
        }
        try HookFiles.atomicWrite(
            JSONSerialization.data(withJSONObject: [
                "version": 1, "verifier": executable.path, "setupId": UUID().uuidString.lowercased(),
            ]),
            name: "native-setup.json", directory: rootFD
        )
    }
}
