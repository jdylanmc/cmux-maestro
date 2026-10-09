import Darwin
import Foundation
import os
@testable import CMUXMaestroPreview

@main
struct MetadataWatchdogProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let mode = CommandLine.arguments[1]
        guard ["complete", "stalled-clock", "polling-clock", "sampler-timeout",
               "sampler-exit-no-output", "sampler-exit-with-output", "sampler-timeout-no-output",
               "owned-living", "owned-result-before-task", "owned-task-received", "owned-exited",
               "diagnostic-cancel-pending", "diagnostic-cancel-returned", "diagnostic-lock-held"]
            .contains(mode) else { exit(2) }
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        var sampler = URL(fileURLWithPath: "/usr/bin/sample")
        if mode.hasPrefix("sampler-") || mode.hasPrefix("owned-") || mode.hasPrefix("diagnostic-") {
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
            case "sampler-timeout":
                behavior = "printf 'partial-sample-before-stall\\n' > \"$5\"\ntrap '' TERM\nexec /bin/sleep 10"
            default:
                behavior = "exit 17"
            }
            let script = """
            #!/bin/sh
            printf '%s' $$ > \(pidFile)
            \(behavior)
            """
            try Data((script + "\n").utf8).write(to: sampler)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sampler.path)
        }
        let storage = OSAllocatedUnfairLock(initialState: CopilotSetupObservation.Snapshot())
        let observation = mode.hasPrefix("diagnostic-") ? CopilotSetupObservation(storage: storage) : nil
        let watchdog = try MetadataProcessTestWatchdog(
            directory: directory, testIdentity: "MetadataWatchdogProbe/\(mode)",
            limit: .seconds(mode == "complete" ? 0.3 : 2),
            samplerExecutable: sampler, observation: observation)
        if mode == "complete" {
            watchdog.begin("completed-negative-control")
            let before = ContinuousClock.now
            let observed = watchdog.now()
            guard observed >= before, observed <= ContinuousClock.now else { exit(1) }
            watchdog.finish()
            try await Task.sleep(for: .seconds(0.6))
            return
        }
        if mode.hasPrefix("diagnostic-") {
            watchdog.begin("negative-control/\(mode)")
            if mode == "diagnostic-lock-held" {
                storage.withLock { _ in holdTask() }
                exit(1)
            }
            observation?.begin(.cancelCall)
            observation?.begin(.execute)
            if mode == "diagnostic-cancel-returned" { observation?.end(.cancelCall) }
            holdTask()
            exit(1)
        }
        if mode.hasPrefix("owned-") {
            try await ownedProcessControl(mode, directory: directory, watchdog: watchdog)
            exit(1)
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

    private static func ownedProcessControl(
        _ mode: String, directory: URL, watchdog: MetadataProcessTestWatchdog
    ) async throws {
        let server = directory.appendingPathComponent("server")
        let ready = directory.appendingPathComponent("child.pid")
        let pending = directory.appendingPathComponent("child.pending")
        let command = """
        #!/bin/sh
        trap '' TERM
        printf '%s' $$ > \(CopilotPluginManifest.shellQuoted(pending.path))
        /bin/mv \(CopilotPluginManifest.shellQuoted(pending.path)) \(CopilotPluginManifest.shellQuoted(ready.path))
        exec /bin/sleep 8
        """
        try Data((command + "\n").utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        if mode == "owned-exited" {
            try await exitedProcessControl(directory: directory, watchdog: watchdog)
            return
        }
        let frozen = ContinuousClock.now
        let runner = LocalCopilotSetupRunner(terminationGrace: 0.02, deadlineNow: {
            _ = watchdog.now()
            return frozen
        })
        watchdog.begin("negative-control/\(mode)")
        let task = Task {
            let result = await runner.metadata(executable: server, path: "/usr/bin:/bin")
            watchdog.metadataCallReturned()
            if mode == "owned-result-before-task" {
                // Result production is not task completion: deliberately hold
                // this disposable task after the unchanged runner returns.
                holdTask()
            }
            return result
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: ready.path), .now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try Int32(String(contentsOf: ready, encoding: .utf8))
        guard let pid else { exit(3) }
        watchdog.metadataPIDReady(pid)
        let observed = MetadataProcessTestWatchdog.observeProcess(pid)
        guard var stale = observed.process else { exit(4) }
        stale.startSeconds += 1
        let changed = MetadataProcessTestWatchdog.observeProcess(pid, expected: stale)
        guard changed.state == "identity-changed", changed.members == nil, changed.process == nil else { exit(5) }
        try JSONEncoder().encode(changed).write(to: directory.appendingPathComponent("stale-identity.json"))
        let incomplete = MetadataProcessTestWatchdog.observeProcess(pid, memberLimit: 1)
        guard incomplete.groupState == "unknown-enumeration", incomplete.members == nil else { exit(11) }
        try JSONEncoder().encode(incomplete).write(to: directory.appendingPathComponent("incomplete-group.json"))
        if mode != "owned-living" { task.cancel() }
        let result = await task.value
        watchdog.taskValueReceived()
        guard case .failed(.cancelled) = result, kill(pid, 0) == -1, errno == ESRCH else { exit(6) }
        try await Task.sleep(for: .seconds(10))
    }

    private static func holdTask() {
        Thread.sleep(forTimeInterval: 10)
    }

    private static func exitedProcessControl(
        directory: URL, watchdog: MetadataProcessTestWatchdog
    ) async throws {
        // Retain our own finite POSIX child's zombie instead of letting
        // Foundation reap it. No signals or production cleanup substitutes.
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { exit(7) }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { exit(8) }
        var input: [Int32] = [-1, -1]
        guard pipe(&input) == 0 else { exit(12) }
        defer { for fd in input where fd >= 0 { close(fd) } }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { exit(13) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO) == 0 else { exit(14) }
        let arguments: [String] = ["/bin/sh", "-c", "IFS= read -r gate"]
        let strings = arguments.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({ $0 != nil }) else { exit(9) }
        var pid: Int32 = 0
        let result = (strings + [nil]).withUnsafeBufferPointer { argv in
            [UnsafeMutablePointer<CChar>?](arrayLiteral: nil).withUnsafeBufferPointer { env in
                posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv.baseAddress, env.baseAddress)
            }
        }
        guard result == 0 else { exit(10) }
        try Data(String(pid).utf8).write(to: directory.appendingPathComponent("child.pid"))
        watchdog.metadataPIDReady(pid)
        // EOF releases only this child after readiness capture; retain its
        // unreaped PID until the deliberately failing probe exits.
        close(input[1])
        input[1] = -1
        watchdog.begin("negative-control/owned-exited")
        try await Task.sleep(for: .seconds(10))
    }
}
