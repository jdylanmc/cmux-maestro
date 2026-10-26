import AppKit
import Darwin
import Foundation

nonisolated struct MaestroNotificationController: Sendable {
    let executable: URL
    let hostExecutable: URL

    @MainActor
    static func installed() throws -> Self {
        let root = try CopilotPaths.orchestrationRoot()
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.cmuxterm.app"),
              Bundle(url: app)?.bundleIdentifier == "com.cmuxterm.app" else {
            throw MaestroNotificationFailure.unavailable
        }
        return .init(
            executable: root.appendingPathComponent("bin/cmux-maestro-orchestrator"),
            hostExecutable: app.appendingPathComponent("Contents/Resources/bin/cmux")
        )
    }

    func environment(inherited: [String: String]) -> [String: String] {
        var result = inherited
        // GUI launches lack the terminal's PATH. Resolve the registered host bundle,
        // not a caller-selected executable, and retain inherited session bindings.
        result["PATH"] = hostExecutable.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        return result
    }

    func call(_ command: String, input: Data = Data()) async throws -> Data {
        guard ["notification-authorize", "notification-focus", "notification-confirm"].contains(command), input.count <= 1024 else {
            throw MaestroNotificationFailure.invalidInput
        }
        // Bounded POSIX pipe polling stays off the cooperative executor. The only child
        // is this installed, one-shot controller; no provider is signalled.
        return try await Task.detached {
            let directory = try CopilotFileAccess.openDirectory(executable.deletingLastPathComponent(), owner: getuid())
            defer { close(directory) }
            let stamp = try CopilotFileAccess.statEntry(at: directory, name: executable.lastPathComponent)
            guard stamp.isRegular, stamp.uid == getuid(), stamp.permissions & 0o022 == 0 else {
                throw MaestroNotificationFailure.unavailable
            }
            let process = Process()
            let output = Pipe(), stdin = Pipe()
            process.executableURL = executable
            process.environment = environment(inherited: ProcessInfo.processInfo.environment)
            process.arguments = [command]
            process.standardInput = stdin
            process.standardOutput = output
            process.standardError = output
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
            output.fileHandleForWriting.closeFile()
            defer { output.fileHandleForReading.closeFile() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            var data = Data()
            while ContinuousClock.now < deadline {
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if ready == 0 { continue }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = read(descriptor.fd, &bytes, bytes.count)
                if count == 0 { return data }
                guard count > 0, data.count + count <= 16_384 else { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            if process.isRunning { process.terminate() }
            throw MaestroNotificationFailure.unavailable
        }.value
    }

    func authorize() async throws -> MaestroNotificationAdmission {
        let data = try await call("notification-authorize")
        struct Status: Decodable { let ok: Bool; let error: String? }
        let status = try JSONDecoder().decode(Status.self, from: data)
        guard status.ok else {
            throw status.error.flatMap(MaestroNotificationFailure.init(rawValue:)) ?? .unavailable
        }
        return try JSONDecoder().decode(MaestroNotificationAdmission.self, from: data)
    }

    func focus(token: String) async throws {
        let data = try await tokenCall("notification-focus", token: token)
        struct Reply: Decodable { let target: MaestroNotificationTarget }
        let target = try JSONDecoder().decode(Reply.self, from: data).target
        let root = MaestroNotificationAssets.sidebarRoot(home: try CopilotPaths.realUserHome())
            .appendingPathComponent("NotificationClicks", isDirectory: true)
        try await MaestroNotificationClick(root: root).focus(target)
    }

    func confirm(token: String) async throws {
        _ = try await tokenCall("notification-confirm", token: token)
    }

    private func tokenCall(_ command: String, token: String) async throws -> Data {
        guard token.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw MaestroNotificationFailure.invalidInput
        }
        let data = try await call(command, input: JSONEncoder().encode(["clickToken": token]))
        struct Status: Decodable { let ok: Bool; let error: String? }
        let status = try JSONDecoder().decode(Status.self, from: data)
        guard status.ok else {
            throw status.error.flatMap(MaestroNotificationFailure.init(rawValue:)) ?? .unavailable
        }
        return data
    }
}
