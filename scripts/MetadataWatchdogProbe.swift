import Darwin
import Foundation
@testable import CMUXMaestroPreview

@main
struct MetadataWatchdogProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let mode = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        let watchdog = try MetadataProcessTestWatchdog(
            directory: directory, limit: .seconds(mode == "complete" ? 0.3 : 2))
        if mode == "complete" {
            watchdog.begin("completed-negative-control")
            let before = ContinuousClock.now
            let observed = watchdog.now()
            guard observed >= before, observed <= ContinuousClock.now else { exit(1) }
            watchdog.finish()
            try await Task.sleep(for: .seconds(0.6))
            return
        }
        guard ["stalled-clock", "polling-clock"].contains(mode) else { exit(2) }
        // Both controls launch a real, finite child through the unchanged runner.
        // Faults exist only in this disposable executable's injected clock.
        let server = directory.appendingPathComponent("server")
        let pidFile = CopilotPluginManifest.shellQuoted(directory.appendingPathComponent("child.pid").path)
        let command = mode == "stalled-clock" ? "/usr/bin/true" : "/bin/sleep 10"
        try Data("#!/bin/sh\nprintf '%s' $$ > \(pidFile)\nexec \(command)\n".utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        watchdog.begin("negative-control/\(mode)")
        let frozen = ContinuousClock.now
        let runner = LocalCopilotSetupRunner(timeout: 0.1, terminationGrace: 0.02, deadlineNow: {
            let instant = watchdog.now()
            if mode == "stalled-clock" {
                Thread.sleep(forTimeInterval: 10)
                return instant
            }
            return frozen
        })
        let result = await runner.metadata(executable: server, path: "/usr/bin:/bin")
        // A return is a failed negative control, never a successful real-process test.
        FileHandle.standardError.write(Data("Negative control unexpectedly returned: \(result)\n".utf8))
        exit(1)
    }
}
