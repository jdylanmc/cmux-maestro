import Darwin
import Foundation
@testable import CMUXMaestroPreview

@main
struct MetadataWatchdogProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let mode = CommandLine.arguments[1]
        guard ["complete", "stalled-clock", "polling-clock", "sampler-timeout",
               "sampler-exit-no-output", "sampler-exit-with-output", "sampler-timeout-no-output"]
            .contains(mode) else { exit(2) }
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        var sampler = URL(fileURLWithPath: "/usr/bin/sample")
        if mode.hasPrefix("sampler-") {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            sampler = directory.appendingPathComponent("stuck-sampler")
            let pidFile = CopilotPluginManifest.shellQuoted(directory.appendingPathComponent("sampler.pid").path)
            let behavior: String
            switch mode {
            case "sampler-exit-no-output":
                behavior = "exit 17"
            case "sampler-exit-with-output":
                behavior = "printf 'synthetic-exit-17-sample\\n' > \"$5\"\nexit 17"
            case "sampler-timeout-no-output":
                behavior = "trap '' TERM\nexec /bin/sleep 10"
            default:
                behavior = "printf 'partial-sample-before-stall\\n' > \"$5\"\ntrap '' TERM\nexec /bin/sleep 10"
            }
            let script = """
            #!/bin/sh
            printf '%s' $$ > \(pidFile)
            \(behavior)
            """
            try Data((script + "\n").utf8).write(to: sampler)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sampler.path)
        }
        let watchdog = try MetadataProcessTestWatchdog(
            directory: directory, testIdentity: "MetadataWatchdogProbe/\(mode)",
            limit: .seconds(mode == "complete" ? 0.3 : 2),
            samplerExecutable: sampler)
        if mode == "complete" {
            watchdog.begin("completed-negative-control")
            let before = ContinuousClock.now
            let observed = watchdog.now()
            guard observed >= before, observed <= ContinuousClock.now else { exit(1) }
            watchdog.finish()
            try await Task.sleep(for: .seconds(0.6))
            return
        }
        // Both controls launch a real, finite child through the unchanged runner.
        // Faults exist only in this disposable executable's injected clock.
        let server = directory.appendingPathComponent("server")
        let pidFile = CopilotPluginManifest.shellQuoted(directory.appendingPathComponent("child.pid").path)
        let command = mode == "polling-clock" ? "/bin/sleep 10" : "/usr/bin/true"
        try Data("#!/bin/sh\nprintf '%s' $$ > \(pidFile)\nexec \(command)\n".utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        watchdog.begin("negative-control/\(mode)")
        let frozen = ContinuousClock.now
        let runner = LocalCopilotSetupRunner(timeout: 0.1, terminationGrace: 0.02, deadlineNow: {
            let instant = watchdog.now()
            if mode != "polling-clock" {
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
