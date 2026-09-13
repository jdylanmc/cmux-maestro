import Darwin
import Foundation
import Testing
@testable import CMUXMaestroPreview

private actor SetupRunnerSpy: CopilotSetupProcessRunner {
    var calls: [[String]] = []
    let result: CopilotProcessResult
    init(result: CopilotProcessResult = .exited(0)) { self.result = result }
    func run(executable: URL, arguments: [String], path: String) async -> CopilotProcessResult {
        calls.append([executable.path] + arguments)
        return result
    }
}

private struct SetupFileStub: CopilotSetupFileSystem {
    let fail: Bool
    func executable(selected: URL?, path: String) throws -> URL {
        if fail { throw HookFiles.Failure.unavailable }
        return URL(fileURLWithPath: "/chosen/copilot")
    }
    func preparePlugin(root: URL, helper: URL) throws -> URL { root.appendingPathComponent("plugin") }
}

private final class SetupDeadlineClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin: ContinuousClock.Instant
    private var instant: ContinuousClock.Instant
    private var sampled = false

    init() {
        let initial = ContinuousClock.now
        origin = initial
        instant = initial
    }

    func now() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        sampled = true
        return instant
    }

    var wasSampled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sampled
    }

    var elapsed: Duration {
        lock.lock()
        defer { lock.unlock() }
        return origin.duration(to: instant)
    }

    func advance(by duration: Duration) {
        precondition(duration >= .zero)
        lock.lock()
        defer { lock.unlock() }
        instant = instant.advanced(by: duration)
    }
}

struct CopilotSetupTests {
    private let root = URL(fileURLWithPath: "/synthetic/integration")
    private let helper = URL(fileURLWithPath: "/Applications/Maestro's App.app/Contents/Helpers/CMUXMaestroCopilotHook")

    @Test func buildNamespacesAndPublicationGuardsStaySeparate() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("scripts/test-build-metadata.py").path]
        process.currentDirectoryURL = root
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let detail = String(decoding: output.fileHandleForReading.readDataToEndOfFile().prefix(8_192), as: UTF8.self)
        #expect(process.terminationStatus == 0, Comment(rawValue: detail))
    }

    @Test func constructionDoesNotInstallAndConsentUsesExactOwnPluginArguments() async {
        let runner = SetupRunnerSpy()
        let setup = CopilotSetup(files: SetupFileStub(fail: false), runner: runner)
        #expect(await runner.calls.isEmpty)
        #expect(await setup.perform(.install, selected: nil, path: "", root: root, helper: helper) == .installed)
        #expect(await setup.perform(.uninstall, selected: nil, path: "", root: root, helper: helper) == .uninstalled)
        #expect(await runner.calls == [
            ["/chosen/copilot", "plugin", "install", "/synthetic/integration/plugin"],
            ["/chosen/copilot", "plugin", "uninstall", "cmux-maestro-native"],
        ])
    }

    @Test func reportsRealFailureAndNeverRunsWhenFilesystemFails() async {
        let failure = SetupRunnerSpy(result: .exited(7))
        let setup = CopilotSetup(files: SetupFileStub(fail: false), runner: failure)
        #expect(await setup.perform(.install, selected: nil, path: "", root: root, helper: helper) == .failed(7))
        let unavailable = CopilotSetup(files: SetupFileStub(fail: true), runner: failure)
        #expect(await unavailable.perform(.install, selected: nil, path: "", root: root, helper: helper) == .unavailable)
        #expect(await failure.calls.count == 1)
        let timeout = CopilotSetup(files: SetupFileStub(fail: false), runner: SetupRunnerSpy(result: .timedOut))
        #expect(await timeout.perform(.install, selected: nil, path: "", root: root, helper: helper) == .timedOut)
        let cancelled = CopilotSetup(files: SetupFileStub(fail: false), runner: SetupRunnerSpy(result: .cancelled))
        #expect(await cancelled.perform(.install, selected: nil, path: "", root: root, helper: helper) == .cancelled)
    }

    @Test(arguments: [false, true])
    func timeoutAndCancellationStopLauncherAndChildWithoutLateWrites(cancel: Bool) async throws {
        try await exerciseCleanup(cancel: cancel)
    }

    @Test func delayedStartupDoesNotExpireBeforeDeadlineIsArmed() async throws {
        try await exerciseCleanup(cancel: false, delayStartup: true)
    }

    private func exerciseCleanup(cancel: Bool, delayStartup: Bool = false) async throws {
        let fixture = try gatedInstallerFixture()
        let directory = fixture.directory
        defer {
            try? fixture.reader.close()
            try? fixture.writer.close()
            try? fixture.completion.close()
            try? FileManager.default.removeItem(at: directory)
        }

        let unrelated = Process()
        let unrelatedInput = Pipe()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/cat")
        unrelated.standardInput = unrelatedInput
        unrelated.standardOutput = FileHandle.nullDevice
        unrelated.standardError = FileHandle.nullDevice
        try unrelated.run()
        defer {
            try? unrelatedInput.fileHandleForWriting.close()
            if unrelated.isRunning { unrelated.terminate() }
            unrelated.waitUntilExit()
        }
        let clock = SetupDeadlineClock()
        let runner = LocalCopilotSetupRunner(timeout: 0.4, terminationGrace: 0.05,
                                             deadlineNow: { clock.now() })
        let arguments = gatedInstallerArguments(in: directory) + (delayStartup ? ["--delay-startup"] : [])
        let task = Task {
            await runner.run(executable: URL(fileURLWithPath: "/usr/bin/env"),
                             arguments: arguments, path: "/usr/bin:/bin")
        }
        defer { task.cancel() }
        let ready = try await waitForGatedWriter(in: directory, deadlineClock: clock)
        var readinessFailure = "Synthetic child must execute before the timeout/cancellation assertion"
        if !ready {
            task.cancel()
            let stopped = await task.value
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            readinessFailure += "; result=\(stopped); files=\(files.sorted().joined(separator: ","))"
        }
        try #require(ready, Comment(rawValue: readinessFailure))
        let launcherPID = try recordedProcessValue("launcher.pid", in: directory)
        let childPID = try recordedProcessValue("child.pid", in: directory)
        #expect(try recordedProcessValue("launcher.pgid", in: directory) == launcherPID)
        #expect(try recordedProcessValue("child.pgid", in: directory) == launcherPID)
        #expect(launcherPID != getpgrp())
        try #require(HookProcess.current(launcherPID) != nil)
        try #require(HookProcess.current(childPID) != nil)
        #expect(clock.elapsed == .zero)
        if delayStartup {
            let delay = try #require(Double(String(
                contentsOf: directory.appendingPathComponent("startup-delay"), encoding: .utf8
            )))
            #expect(delay > runner.timeout)
        }
        try fixture.reader.close()
        if cancel {
            task.cancel()
        } else {
            clock.advance(by: .seconds(runner.timeout))
        }
        let result = await task.value
        #expect(result == (cancel ? .cancelled : .timedOut))
        #expect(clock.elapsed == (cancel ? .zero : .seconds(runner.timeout)))
        #expect(unrelated.isRunning)
        #expect(HookProcess.current(launcherPID) == nil)
        #expect(HookProcess.current(childPID) == nil)
        #expect(kill(launcherPID, 0) == -1 && errno == ESRCH, "Direct child must be reaped")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("late-mutation").path))

        // Release only after the returned result, then wait for completion EOF:
        // the child cannot perform another write after that channel closes.
        let release = releaseMutationGate(fixture.writer)
        try #require(release.bytes == 8 || (release.bytes == -1 && release.error == EPIPE))
        #expect(try mutationCompletion(fixture.completion).isEmpty, "A writer survived returned cleanup")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("late-mutation").path))
        #expect(unrelated.isRunning)
    }

    @Test func mutationGateDetectsLiveWriterWithoutCleanup() async throws {
        let fixture = try gatedInstallerFixture()
        let directory = fixture.directory
        defer {
            try? fixture.reader.close()
            try? fixture.writer.close()
            try? fixture.completion.close()
            try? FileManager.default.removeItem(at: directory)
        }
        // Deliberately bypass runner cleanup: the very same gated child remains
        // alive at the release boundary and must produce the forbidden write.
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        writer.arguments = gatedInstallerArguments(in: directory) + ["--writer-only"]
        writer.environment = ["PATH": "/usr/bin:/bin"]
        writer.standardInput = FileHandle.nullDevice
        writer.standardOutput = FileHandle.nullDevice
        writer.standardError = FileHandle.nullDevice
        try writer.run()
        defer {
            if writer.isRunning { kill(writer.processIdentifier, SIGKILL) }
            writer.waitUntilExit()
        }
        try #require(await waitForGatedWriter(in: directory))
        #expect(try recordedProcessValue("child.pid", in: directory) == writer.processIdentifier)
        try #require(HookProcess.current(writer.processIdentifier) != nil)
        try fixture.reader.close()
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("late-mutation").path))
        let release = releaseMutationGate(fixture.writer)
        #expect(release.bytes == 8 && release.error == 0, "The negative-control writer must receive the gate")
        #expect(try String(decoding: mutationCompletion(fixture.completion), as: UTF8.self) == "mutated")
        writer.waitUntilExit()
        #expect(writer.terminationStatus == 0)
        #expect(try String(contentsOf: directory.appendingPathComponent("late-mutation"), encoding: .utf8) == "forbidden")
    }

    private func gatedInstallerFixture() throws -> (
        directory: URL, reader: FileHandle, writer: FileHandle, completion: FileHandle
    ) {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent(".build/setup-fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var reader: Int32 = -1
        var writer: Int32 = -1
        var completion: Int32 = -1
        do {
            // Fork and capture native IDs in-process instead of scheduling
            // additional metadata executables within the short timeout.
            try """
            import os
            import signal
            import sys
            import time

            root = sys.argv[1]

            def record(name, value):
                with open(os.path.join(root, name), "w") as output:
                    output.write(str(value))

            def write_after_gate():
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                with open(os.path.join(root, "mutation-gate")) as gate, \\
                     open(os.path.join(root, "mutation-completion"), "w") as completion:
                    record("child.pid", os.getpid())
                    record("child.pgid", os.getpgrp())
                    record("ready", "started")
                    if gate.readline() != "release\\n":
                        sys.exit(3)
                    record("late-mutation", "forbidden")
                    completion.write("mutated")

            if "--delay-startup" in sys.argv:
                started = time.monotonic()
                time.sleep(0.6)
                record("startup-delay", time.monotonic() - started)

            if "--writer-only" in sys.argv:
                write_after_gate()
            else:
                record("launcher.pid", os.getpid())
                record("launcher.pgid", os.getpgrp())
                child = os.fork()
                if child == 0:
                    write_after_gate()
                    os._exit(0)
                _, status = os.waitpid(child, 0)
                sys.exit(os.waitstatus_to_exitcode(status))

            """.write(to: directory.appendingPathComponent("installer.py"), atomically: true, encoding: .utf8)
            let gate = directory.appendingPathComponent("mutation-gate").path
            let acknowledgement = directory.appendingPathComponent("mutation-completion").path
            guard mkfifo(gate, 0o600) == 0, mkfifo(acknowledgement, 0o600) == 0 else {
                throw POSIXError(.EIO)
            }
            // A temporary reader lets us open the writer before spawning. Close
            // it once the child's ready event proves its real reader is open.
            reader = open(gate, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            writer = open(gate, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            completion = open(acknowledgement, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard reader >= 0, writer >= 0, completion >= 0, fcntl(writer, F_SETNOSIGPIPE, 1) == 0 else {
                throw POSIXError(.EIO)
            }
            return (directory, FileHandle(fileDescriptor: reader, closeOnDealloc: true),
                    FileHandle(fileDescriptor: writer, closeOnDealloc: true),
                    FileHandle(fileDescriptor: completion, closeOnDealloc: true))
        } catch {
            if reader >= 0 { close(reader) }
            if writer >= 0 { close(writer) }
            if completion >= 0 { close(completion) }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func waitForGatedWriter(
        in directory: URL, deadlineClock: SetupDeadlineClock? = nil
    ) async throws -> Bool {
        // Observe the runner's baseline sample before advancing test time, even
        // if the child happens to become ready before the spawning thread resumes.
        func ready() -> Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path)
                && (deadlineClock?.wasSampled ?? true)
        }
        let readiness = ContinuousClock.now.advanced(by: .seconds(3))
        while !ready(), ContinuousClock.now < readiness {
            try await Task.sleep(for: .milliseconds(10))
        }
        return ready()
    }

    private func gatedInstallerArguments(in directory: URL) -> [String] {
        ["python3", "-I", "-S", directory.appendingPathComponent("installer.py").path, directory.path]
    }

    private func recordedProcessValue(_ name: String, in directory: URL) throws -> Int32 {
        try #require(Int32(String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func releaseMutationGate(_ gate: FileHandle) -> (bytes: Int, error: Int32) {
        Data("release\n".utf8).withUnsafeBytes {
            let count = Darwin.write(gate.fileDescriptor, $0.baseAddress, $0.count)
            return (count, count < 0 ? errno : 0)
        }
    }

    private func mutationCompletion(_ completion: FileHandle) throws -> Data {
        let flags = fcntl(completion.fileDescriptor, F_GETFL)
        try #require(flags >= 0 && fcntl(completion.fileDescriptor, F_SETFL, flags & ~O_NONBLOCK) == 0)
        return try completion.readToEnd() ?? Data()
    }

    @Test func isolatedRunnerPreservesExitStatusAndSpawnFailure() async {
        let runner = LocalCopilotSetupRunner(timeout: 2)
        #expect(await runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                 arguments: ["-c", "exit 7"], path: "/usr/bin:/bin") == .exited(7))
        #expect(await runner.run(executable: URL(fileURLWithPath: "/nonexistent/maestro-test-executable"),
                                 arguments: [], path: "/usr/bin:/bin") == .unavailable)
    }

    @Test func manifestRegistersOnlySafeIdentityEventsAndAbsoluteHelper() throws {
        let files = try CopilotPluginManifest.files(helper: helper)
        let manifestData = try #require(files["plugin.json"])
        let hooksData = try #require(files["hooks.json"])
        let manifest = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        #expect(manifest["name"] as? String == "cmux-maestro-native")
        let hooks = try #require(JSONSerialization.jsonObject(with: hooksData) as? [String: Any])
        #expect(hooks["version"] as? Int == 1)
        let entries = try #require(hooks["hooks"] as? [String: [[String: Any]]])
        #expect(Set(entries.keys) == Set(["sessionStart", "userPromptSubmitted", "postToolUse"]))
        for value in entries.values {
            #expect(value.count == 1)
            #expect(value[0]["timeoutSec"] as? Int == 2)
            #expect(value[0]["type"] as? String == "command")
            #expect(value[0]["bash"] as? String == CopilotPluginManifest.command(helper: helper))
        }
    }

    @Test func wrapperExecutesNegativeControlButAlwaysSilencesMissingAndFailingHelpers() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent(".build/setup-fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("hook's executable")
        let proof = directory.appendingPathComponent("executed")
        let script = "#!/bin/sh\nprintf ran > \(CopilotPluginManifest.shellQuoted(proof.path))\necho secret\necho secret >&2\nexit 17\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let signal = directory.appendingPathComponent("signaled")
        try "#!/bin/sh\nkill -TERM $$\n".write(to: signal, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: signal.path)
        for candidate in [executable, signal, directory.appendingPathComponent("missing")] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-ec", CopilotPluginManifest.command(helper: candidate)]
            process.currentDirectoryURL = directory
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
            #expect(error.fileHandleForReading.readDataToEndOfFile().isEmpty)
        }
        #expect(try String(contentsOf: proof, encoding: .utf8) == "ran")
    }

    @Test func writesCurrentBundleManifestWithoutTouchingOtherConfiguration() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent(".build/setup-fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("helper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let configuration = directory.appendingPathComponent("unrelated-settings.json")
        try Data("preserved".utf8).write(to: configuration)
        let local = LocalCopilotSetupFiles()
        let plugin = try local.preparePlugin(root: directory.appendingPathComponent("integration"), helper: executable)
        #expect(try Data(contentsOf: plugin.appendingPathComponent("hooks.json"))
            == CopilotPluginManifest.files(helper: executable)["hooks.json"])
        #expect(try String(contentsOf: configuration, encoding: .utf8) == "preserved")
        #expect(try local.executable(selected: executable, path: "") == executable)
        #expect(throws: (any Error).self) { try local.executable(selected: nil, path: ".:relative") }
    }
}
