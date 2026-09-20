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
    func preparePlugin(root: URL, helper: URL, controller: URL, skill: URL) throws -> URL {
        root.appendingPathComponent("plugin")
    }
}

private final class SetupAccessSpy: CopilotSetupFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func executable(selected: URL?, path: String) throws -> URL {
        record()
        return URL(fileURLWithPath: "/synthetic/copilot")
    }

    func preparePlugin(root: URL, helper: URL, controller: URL, skill: URL) throws -> URL {
        record()
        return root.appendingPathComponent("plugin")
    }

    private func record() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
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
    private let controller = URL(fileURLWithPath: "/Applications/Maestro.app/Contents/Resources/cmux-maestro-orchestrator.py")
    private let skill = URL(fileURLWithPath: "/Applications/Maestro.app/Contents/Resources/SKILL.md")

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
        let setup = CopilotSetup(files: SetupFileStub(fail: false), runner: runner,
                                 bundleIdentifier: CopilotSetupAccess.productionBundleIdentifier)
        #expect(await runner.calls.isEmpty)
        #expect(await setup.perform(.install, selected: nil, path: "", root: root, helper: helper,
                                    controller: controller, skill: skill) == .installed)
        #expect(await setup.perform(.uninstall, selected: nil, path: "", root: root, helper: helper,
                                    controller: controller, skill: skill) == .uninstalled)
        #expect(await runner.calls == [
            ["/chosen/copilot", "--no-auto-update", "plugin", "install", "/synthetic/integration/plugin"],
            ["/chosen/copilot", "--no-auto-update", "plugin", "uninstall", "cmux-maestro-native"],
        ])
    }

    @Test func reportsRealFailureAndNeverRunsWhenFilesystemFails() async {
        let failure = SetupRunnerSpy(result: .exited(7))
        let setup = CopilotSetup(files: SetupFileStub(fail: false), runner: failure,
                                 bundleIdentifier: CopilotSetupAccess.productionBundleIdentifier)
        #expect(await setup.perform(.install, selected: nil, path: "", root: root, helper: helper,
                                    controller: controller, skill: skill) == .failed(7))
        let unavailable = CopilotSetup(files: SetupFileStub(fail: true), runner: failure,
                                       bundleIdentifier: CopilotSetupAccess.productionBundleIdentifier)
        #expect(await unavailable.perform(.install, selected: nil, path: "", root: root, helper: helper,
                                          controller: controller, skill: skill) == .unavailable)
        #expect(await failure.calls.count == 1)
        let timeout = CopilotSetup(files: SetupFileStub(fail: false), runner: SetupRunnerSpy(result: .timedOut),
                                   bundleIdentifier: CopilotSetupAccess.productionBundleIdentifier)
        #expect(await timeout.perform(.install, selected: nil, path: "", root: root, helper: helper,
                                      controller: controller, skill: skill) == .timedOut)
        let cancelled = CopilotSetup(files: SetupFileStub(fail: false), runner: SetupRunnerSpy(result: .cancelled),
                                     bundleIdentifier: CopilotSetupAccess.productionBundleIdentifier)
        #expect(await cancelled.perform(.install, selected: nil, path: "", root: root, helper: helper,
                                        controller: controller, skill: skill) == .cancelled)
    }

    @Test(arguments: [
        nil, "", "com.jdylanmc.CMUXMaestroPreview.Validation.Tests",
        "com.jdylanmc.CMUXMaestroPreview.Validation.Unsigned",
        "com.jdylanmc.CMUXMaestroPreview.Extension", "com.jdylanmc.CMUXMaestroPreview.other"
    ] as [String?])
    func nonproductionCopiesCannotTouchSetupFilesOrRunCopilot(bundleIdentifier: String?) async {
        let files = SetupAccessSpy()
        let runner = SetupRunnerSpy()
        let setup = CopilotSetup(files: files, runner: runner, bundleIdentifier: bundleIdentifier)
        for action: CopilotSetupAction in [.install, .uninstall] {
            #expect(await setup.perform(action, selected: helper, path: "/synthetic",
                                        root: root, helper: helper, controller: controller,
                                        skill: skill) == .validationOnly)
        }
        #expect(files.calls == 0)
        #expect(await runner.calls.isEmpty)
        #expect(!CopilotSetupAccess.allowsChanges(bundleIdentifier: bundleIdentifier))
    }

    @Test func defaultSetupUsesTheActualNonproductionHostIdentity() async {
        #expect(!CopilotSetupAccess.currentAppAllowsChanges)
        let files = SetupAccessSpy()
        let runner = SetupRunnerSpy()
        let setup = CopilotSetup(files: files, runner: runner)
        #expect(await setup.perform(.install, selected: nil, path: "", root: root, helper: helper,
                                    controller: controller, skill: skill) == .validationOnly)
        #expect(files.calls == 0)
        #expect(await runner.calls.isEmpty)
    }

    @Test(arguments: [false, true])
    func timeoutAndCancellationStopLauncherAndChildWithoutLateWrites(cancel: Bool) async throws {
        try await exerciseCleanup(cancel: cancel)
    }

    @Test func delayedStartupDoesNotExpireBeforeDeadlineIsArmed() async throws {
        try await exerciseCleanup(cancel: false, delayStartup: true)
    }

    @Test func supervisionDefaultsKeepTheRealMonotonicClock() {
        let before = ContinuousClock.now
        let runner = LocalCopilotSetupRunner()
        let sample = runner.deadlineNow()
        #expect(runner.timeout == 45)
        #expect(runner.terminationGrace == 0.25)
        #expect(sample >= before && sample <= ContinuousClock.now)
    }

    @Test func cancellationBeforeEntryDoesNotSpawnInstaller() async throws {
        let fixture = try gatedInstallerFixture()
        let directory = fixture.directory
        defer {
            try? fixture.reader.close()
            try? fixture.writer.close()
            try? fixture.completion.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let gate = AsyncStream<Void>.makeStream()
        let runner = LocalCopilotSetupRunner(timeout: 0.4, terminationGrace: 0.05)
        let arguments = gatedInstallerArguments(in: directory)
        let task = Task {
            for await _ in gate.stream { break }
            return await runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                    arguments: arguments, path: "/usr/bin:/bin")
        }
        task.cancel()
        gate.continuation.finish()
        #expect(await task.value == .cancelled)
        for name in ["launch-started", "launcher.pid", "child.pid", "ready", "late-mutation"] {
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }
    }

    @Test @MainActor
    func concurrentSupervisionDoesNotOccupyCooperativeExecutor() async throws {
        var fixtures = [try gatedInstallerFixture()]
        defer {
            for fixture in fixtures {
                try? fixture.reader.close()
                try? fixture.writer.close()
                try? fixture.completion.close()
                try? FileManager.default.removeItem(at: fixture.directory)
            }
        }
        fixtures.append(try gatedInstallerFixture())
        let clocks = fixtures.map { _ in SetupDeadlineClock() }
        let tasks = fixtures.enumerated().map { index, fixture in
            let directory = fixture.directory
            let clock = clocks[index]
            let runner = LocalCopilotSetupRunner(timeout: 0.4, terminationGrace: 0.05,
                                                 deadlineNow: { clock.now() })
            let arguments = gatedInstallerArguments(in: directory)
            return Task.detached {
                await runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                 arguments: arguments, path: "/usr/bin:/bin")
            }
        }
        defer { tasks.forEach { $0.cancel() } }
        // Keep drivers on the cooperative executor and the observer on MainActor.
        // Yielding here would let inherited actor tasks masquerade as detached drivers.
        func allReady() -> Bool {
            fixtures.indices.allSatisfy { index in
                clocks[index].wasSampled
                    && FileManager.default.fileExists(atPath: fixtures[index].directory.appendingPathComponent("ready").path)
            }
        }
        func observeReadiness() -> Bool {
            let readiness = ContinuousClock.now.advanced(by: .seconds(3))
            while !allReady(), ContinuousClock.now < readiness {
                Thread.sleep(forTimeInterval: 0.01)
            }
            return allReady()
        }
        let startedConcurrently = observeReadiness()
        let readyCount = fixtures.filter {
            FileManager.default.fileExists(atPath: $0.directory.appendingPathComponent("ready").path)
        }.count
        let sampledCount = clocks.filter(\.wasSampled).count
        if !startedConcurrently { tasks.forEach { $0.cancel() } }
        clocks.forEach { $0.advance(by: .seconds(0.4)) }
        for task in tasks {
            let result = await task.value
            if startedConcurrently { #expect(result == .timedOut) }
        }
        #expect(startedConcurrently,
                "Blocking supervision: \(readyCount)/2 writers ready; \(sampledCount)/2 supervisors sampled their clocks")
        for fixture in fixtures {
            try fixture.reader.close()
            _ = releaseMutationGate(fixture.writer)
            #expect(try mutationCompletion(fixture.completion).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("late-mutation").path))
        }
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
        let startupStarted = ContinuousClock.now
        let task = Task {
            await runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                             arguments: arguments, path: "/usr/bin:/bin")
        }
        defer { task.cancel() }
        let ready = try await waitForGatedWriter(in: directory, deadlineClock: clock)
        var readinessFailure = "Synthetic child must execute before the timeout/cancellation assertion"
        if !ready {
            let sampled = clock.wasSampled
            task.cancel()
            let stopped = await task.value
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            let boundedFiles = files.sorted().prefix(16).map { String($0.prefix(64)) }.joined(separator: ",")
            readinessFailure += "; result=\(stopped); clock.wasSampled=\(sampled); files=\(boundedFiles)"
        }
        try #require(ready, Comment(rawValue: readinessFailure))
        let launcherPID = try recordedProcessValue("launcher.pid", in: directory)
        let childPID = try recordedProcessValue("child.pid", in: directory)
        try #require(HookProcess.current(launcherPID) != nil)
        try #require(HookProcess.current(childPID) != nil)
        #expect(clock.elapsed == .zero)
        #expect(getpgid(launcherPID) == launcherPID)
        #expect(getpgid(childPID) == launcherPID)
        #expect(launcherPID != getpgrp())
        if delayStartup {
            #expect(try String(contentsOf: directory.appendingPathComponent("delay-started"), encoding: .utf8) == "0.6")
            #expect(try String(contentsOf: directory.appendingPathComponent("delay-completed"), encoding: .utf8) == "0.6")
            #expect(startupStarted.duration(to: ContinuousClock.now) > .seconds(runner.timeout))
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
        writer.executableURL = URL(fileURLWithPath: "/bin/sh")
        writer.arguments = [directory.appendingPathComponent("child.sh").path, directory.path]
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
            try """
            #!/bin/sh
            set -eu
            printf started > "$1/launch-started"
            printf '%s' "$$" > "$1/launcher.pid"
            if [ "${2:-}" = "--delay-startup" ]; then
                printf '0.6' > "$1/delay-started"
                /bin/sleep 0.6
                printf '0.6' > "$1/delay-completed"
            fi
            /bin/sh "$1/child.sh" "$1" &
            wait "$!"

            """.write(to: directory.appendingPathComponent("launcher.sh"), atomically: true, encoding: .utf8)
            try """
            #!/bin/sh
            set -eu
            trap '' TERM
            printf started > "$1/child-started"
            printf '%s' "$$" > "$1/child.pid"
            exec 3< "$1/mutation-gate"
            printf opened > "$1/gate-opened"
            exec 4> "$1/mutation-completion"
            printf opened > "$1/completion-opened"
            printf started > "$1/ready"
            IFS= read -r release <&3
            [ "$release" = "release" ]
            printf forbidden > "$1/late-mutation"
            printf mutated >&4

            """.write(to: directory.appendingPathComponent("child.sh"), atomically: true, encoding: .utf8)
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
        [directory.appendingPathComponent("launcher.sh").path, directory.path]
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
        let controller = directory.appendingPathComponent("controller.py")
        let skill = directory.appendingPathComponent("SKILL.md")
        try Data("#!/usr/bin/env python3\n".utf8).write(to: controller)
        try Data("# native controller module\n".utf8).write(
            to: directory.appendingPathComponent("maestro_native.py")
        )
        try Data("---\nname: cmux-maestro-orchestrate\n---\n".utf8).write(to: skill)
        let iconSkillDirectory = directory.appendingPathComponent("maestro-icon", isDirectory: true)
        try FileManager.default.createDirectory(at: iconSkillDirectory, withIntermediateDirectories: true)
        let iconSkill = iconSkillDirectory.appendingPathComponent("SKILL.md")
        try Data("---\nname: maestro-icon\n---\n".utf8).write(to: iconSkill)
        try FileManager.default.copyItem(
            at: repository.appendingPathComponent("Resources/NerdFonts"),
            to: directory.appendingPathComponent("NerdFonts")
        )
        let integration = directory.appendingPathComponent("integration")
        let plugin = try local.preparePlugin(
            root: integration, helper: executable, controller: controller, skill: skill
        )
        #expect(try Data(contentsOf: plugin.appendingPathComponent("hooks.json"))
            == CopilotPluginManifest.files(helper: executable)["hooks.json"])
        #expect(try Data(contentsOf: plugin.appendingPathComponent("skills/cmux-maestro-orchestrate/SKILL.md"))
            == Data(contentsOf: skill))
        #expect(try Data(contentsOf: plugin.appendingPathComponent("skills/maestro-icon/SKILL.md"))
            == Data(contentsOf: iconSkill))
        let installed = directory.appendingPathComponent(
            "Orchestration/bin/cmux-maestro-orchestrator"
        )
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))
        #expect(try Data(contentsOf: installed) == Data(contentsOf: controller))
        #expect(try Data(contentsOf: installed.deletingLastPathComponent().appendingPathComponent("NerdFonts/glyphnames.json"))
            == Data(contentsOf: repository.appendingPathComponent("Resources/NerdFonts/glyphnames.json")))
        #expect(try String(contentsOf: configuration, encoding: .utf8) == "preserved")
        #expect(try local.executable(selected: executable, path: "") == executable)
        #expect(throws: (any Error).self) { try local.executable(selected: nil, path: ".:relative") }
    }
}
