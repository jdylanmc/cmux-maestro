import Darwin
import Foundation
import Testing
@testable import CMUXMaestroPreview

private actor SetupRunnerSpy: CopilotSetupProcessRunner {
    var calls: [[String]] = []
    let result: CopilotProcessResult
    init(result: CopilotProcessResult = .exited(0)) { self.result = result }
    func run(executable: URL, arguments: [String], path: String, providerHome: URL?) async -> CopilotProcessResult {
        calls.append([executable.path] + arguments)
        return result
    }
    func metadata(executable: URL, path: String, providerHome: URL?) async -> CopilotMetadataResult { .failed(.unavailable) }
    func plugin(executable: URL, operation: CopilotPluginOperation, path: String,
                providerHome: URL?) async -> CopilotPluginOperationResult { .failed(.unavailable) }
    func sourceIdentity(executable: URL, source: URL, path: String) async -> CopilotSourceIdentityResult { .failed(.unavailable) }
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
    func removeMessaging(root: URL) throws {}
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
    func removeMessaging(root: URL) throws { record() }

    private func record() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

final class SetupDeadlineClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin: ContinuousClock.Instant
    private var instant: ContinuousClock.Instant
    private var sampled = false
    private var driverEntered = false
    private let startup = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    init() {
        let initial = ContinuousClock.now
        origin = initial
        instant = initial
    }

    func now() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        if !sampled {
            sampled = true
            startup.continuation.yield(())
            startup.continuation.finish()
        }
        return instant
    }

    func waitForStartup() async -> Bool {
        for await _ in startup.stream { return !Task.isCancelled }
        return false
    }

    func finishStartup() {
        startup.continuation.finish()
    }

    func noteDriverEntry() {
        lock.lock()
        defer { lock.unlock() }
        driverEntered = true
    }

    var driverDidEnter: Bool {
        lock.lock()
        defer { lock.unlock() }
        return driverEntered
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

struct CopilotPluginExchangeTests {
    @Test func bootstrapUsesAnIsolatedHomeAndExactSourceThenCleansIt() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let capture = fixture.directory.appendingPathComponent("bootstrap-environment.json")
        let executable = fixture.directory.appendingPathComponent("bootstrap-provider")
        let script = """
        #!/usr/bin/python3
        import json, os, sys
        methods = []
        while True:
            header = sys.stdin.buffer.readline()
            if not header:
                break
            length = int(header.decode().split(": ", 1)[1])
            assert sys.stdin.buffer.readline() == b"\\r\\n"
            request = json.loads(sys.stdin.buffer.read(length))
            methods.append(request["method"])
            if request["method"] == "status.get":
                result = {"version": "1.0.89", "protocolVersion": 3}
            else:
                assert request["method"] == "plugins.install"
                with open(\(String(reflecting: capture.path)), "w") as output:
                    json.dump({"source": request["params"]["source"], "methods": methods,
                               "home": os.environ["HOME"], "providerHome": os.environ["COPILOT_HOME"],
                               "cwd": os.getcwd(), "config": os.environ["XDG_CONFIG_HOME"],
                               "credentialsPresent": any(k in os.environ for k in ["GH_TOKEN", "GITHUB_TOKEN", "COPILOT_GITHUB_TOKEN"])}, output)
                result = {"plugin": {"name": "cmux-maestro-native", "marketplace": "", "enabled": True,
                                     "directSourceId": "actual-response-not-a-name-join"}}
            body = json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}).encode()
            sys.stdout.buffer.write(("Content-Length: %s\\r\\n\\r\\n" % len(body)).encode() + body)
            sys.stdout.buffer.flush()
        """
        try fixture.write(Data(script.utf8), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let result = await LocalCopilotSetupRunner().sourceIdentity(executable: executable, source: fixture.source, path: "/usr/bin:/bin")
        guard case .value(let identity) = result else { Issue.record("Public bootstrap fixture must succeed: \(result)"); return }
        #expect(identity.source == fixture.source.path)
        #expect(identity.directSourceId == "actual-response-not-a-name-join")
        let object = try CopilotSetupJSON.object(Data(contentsOf: capture))
        let home = try #require(object["home"] as? String)
        #expect(home.hasPrefix("/private/tmp/cmux-maestro-source-"))
        #expect(object["providerHome"] as? String == home + "/.copilot")
        #expect(object["cwd"] as? String == home)
        #expect(object["config"] as? String == home)
        #expect(object["credentialsPresent"] as? Bool == false)
        #expect(object["methods"] as? [String] == ["status.get", "plugins.install"])
        #expect(!FileManager.default.fileExists(atPath: home))
    }

    private func send(_ exchange: CopilotMetadataExchange, id: Int, result: Any) throws {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
        let frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
        #expect(frame.withUnsafeBytes { Darwin.write(exchange.output[1], $0.baseAddress, $0.count) } == frame.count)
        try exchange.poll()
    }

    private func requests(_ exchange: CopilotMetadataExchange) throws -> String {
        #expect(fcntl(exchange.input[0], F_SETFL, O_NONBLOCK) == 0)
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.read(exchange.input[0], &bytes, bytes.count)
        if count < 0, errno == EAGAIN { return "" }
        return String(decoding: bytes.prefix(max(0, count)), as: UTF8.self)
    }

    private func installed(_ identity: String = "returned-opaque-identity") -> [String: Any] {
        ["plugin": ["name": CopilotPluginManifest.name, "marketplace": "", "enabled": true,
                    "directSourceId": identity], "deprecationWarning": "Untrusted provider wording"]
    }

    @Test func installUsesExactSourceAndProviderReceiptAfterVersionCheck() throws {
        let source = URL(fileURLWithPath: "/owned/stable/plugin")
        let exchange = try CopilotMetadataExchange(operation: .install(source: source, expectedIdentity: nil))
        let initial = try requests(exchange)
        #expect(initial.contains("status.get"))
        #expect(!initial.contains("plugins.install"))
        try send(exchange, id: 1, result: ["version": "1.0.89", "protocolVersion": 3])
        let request = try requests(exchange).replacingOccurrences(of: "\\/", with: "/")
        #expect(request.contains("plugins.install"))
        #expect(request.contains(source.path))
        #expect(!request.contains("disable"))
        try send(exchange, id: 4, result: installed())
        #expect(exchange.pluginReceipt?.plugin?.directSourceId == "returned-opaque-identity")
        #expect(exchange.pluginReceipt?.directInstallDeprecated == true)
        #expect(exchange.input[1] == -1)
    }

    @Test func uninstallUsesExactSourceIdentityAndAcceptsNullResult() throws {
        let exchange = try CopilotMetadataExchange(operation: .uninstall(identity: "owned-opaque-id"))
        _ = try requests(exchange)
        try send(exchange, id: 1, result: ["version": "1.0.89", "protocolVersion": 3])
        let request = try requests(exchange)
        #expect(request.contains("plugins.uninstall"))
        #expect(request.contains("directSourceId"))
        #expect(request.contains("owned-opaque-id"))
        try send(exchange, id: 4, result: NSNull())
        #expect(exchange.pluginReceipt != nil)
        #expect(exchange.pluginReceipt?.plugin == nil)
    }

    @Test(arguments: ["1.0.87", "1.0.90", "invalid"])
    func unsupportedProviderNeverReceivesMutation(version: String) throws {
        let exchange = try CopilotMetadataExchange(operation: .uninstall(identity: "owned-id"))
        _ = try requests(exchange)
        #expect(throws: (any Error).self) {
            try send(exchange, id: 1, result: ["version": version, "protocolVersion": 3])
        }
        #expect(try requests(exchange).isEmpty)
        #expect(exchange.pluginReceipt == nil)
    }

    @Test(arguments: ["different-id", "marketplace", "managed", "disabled", "missing-id", "foreign-name", "live-source"])
    func installRejectsUnboundReceipt(kind: String) throws {
        let exchange = try CopilotMetadataExchange(operation: .install(
            source: URL(fileURLWithPath: "/owned/plugin"), expectedIdentity: "owned-id"))
        try send(exchange, id: 1, result: ["version": "1.0.89", "protocolVersion": 3])
        var plugin: [String: Any] = ["name": CopilotPluginManifest.name, "marketplace": "",
                                     "enabled": true, "directSourceId": "owned-id"]
        switch kind {
        case "different-id": plugin["directSourceId"] = "unrelated-id"
        case "marketplace": plugin["marketplace"] = "unrelated-marketplace"
        case "managed": plugin["managed"] = true
        case "disabled": plugin["enabled"] = false
        case "missing-id": plugin.removeValue(forKey: "directSourceId")
        case "foreign-name": plugin["name"] = "unrelated-plugin"
        case "live-source": plugin["source"] = "/unrelated/plugin"
        default: Issue.record("Unexpected fixture")
        }
        #expect(throws: (any Error).self) { try send(exchange, id: 4, result: ["plugin": plugin]) }
        #expect(exchange.pluginReceipt == nil)
    }

    @Test func unsolicitedReceiptCannotCauseOrVerifyMutation() throws {
        let exchange = try CopilotMetadataExchange(operation: .install(
            source: URL(fileURLWithPath: "/owned/plugin"), expectedIdentity: nil))
        _ = try requests(exchange)
        #expect(throws: (any Error).self) { try send(exchange, id: 4, result: installed()) }
        #expect(try requests(exchange).isEmpty)
        #expect(exchange.pluginReceipt == nil)
    }
}

struct CopilotSetupTests {
    private let root = URL(fileURLWithPath: "/synthetic/integration")
    private let helper = URL(fileURLWithPath: "/Applications/Maestro's App.app/Contents/Helpers/CMUXMaestroCopilotHook")
    private let controller = URL(fileURLWithPath: "/Applications/Maestro.app/Contents/Resources/cmux-maestro-orchestrator.py")
    private let skill = URL(fileURLWithPath: "/Applications/Maestro.app/Contents/Resources/SKILL.md")

    @Test(arguments: [false, true])
    func resourceFailureRestoresPreviousFilesOrAbsence(firstInstall: Bool) throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let first = fixture.root.appendingPathComponent("large-resource")
        let second = fixture.root.appendingPathComponent("controller")
        let blocked = fixture.root.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        if !firstInstall {
            try fixture.write(Data(repeating: 7, count: 100_000), to: first)
            try fixture.write(Data("previous executable".utf8), to: second)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: second.path)
        }
        let previous = try [first, second].map { try CopilotSetupFileState.read($0, maximum: 131_072) }
        let unrelated = fixture.root.appendingPathComponent("unrelated")
        try fixture.write(Data("retain".utf8), to: unrelated)
        let unrelatedBefore = try CopilotSetupFileState.read(unrelated)
        let plan = CopilotPluginResources(writes: [
            .init(file: first, data: Data(repeating: 9, count: 100_000), maximum: 131_072),
            .init(file: second, data: Data("new executable".utf8), permissions: 0o700),
            .init(file: blocked.appendingPathComponent("late-file"), data: Data("cannot write".utf8)),
        ], routes: fixture.home)
        do {
            try plan.publish()
            Issue.record("Expected a real late filesystem write failure")
        } catch let failure as CopilotResourcePreparationFailure {
            #expect(failure.restored)
        }
        for old in previous {
            let restored = try CopilotSetupFileState.read(old.url, maximum: old.maximum)
            #expect(restored.data == old.data)
            #expect(restored.stamp?.permissions == old.stamp?.permissions)
            if old.data != nil { #expect(restored.stamp != old.stamp, "The earlier write must actually have occurred before restoration") }
        }
        #expect(try CopilotSetupFileState.read(unrelated) == unrelatedBefore)
        #expect(try CopilotSetupFileState.read(blocked.appendingPathComponent("late-file")).data == nil)
    }

    @Test func identicalResourcePublicationRetainsFileIdentityAndLargeFileBound() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let target = fixture.root.appendingPathComponent("resource")
        let plan = CopilotPluginResources(writes: [
            .init(file: target, data: Data(repeating: 3, count: 100_000), maximum: 131_072),
        ], routes: fixture.home)
        try plan.publish()
        let before = try CopilotSetupFileState.read(target, maximum: 131_072)
        try plan.publish()
        #expect(try CopilotSetupFileState.read(target, maximum: 131_072) == before)
        try before.revalidate()
        let oversized = CopilotPluginResources(writes: [
            .init(file: target, data: Data(repeating: 5, count: 131_073), maximum: 131_072),
        ], routes: fixture.home)
        #expect(throws: CopilotResourcePreparationFailure.self) { try oversized.publish() }
        #expect(try CopilotSetupFileState.read(target, maximum: 131_072) == before)
    }

    @Test func unsafeLateResourceRefusesBeforeEarlierResourceMutation() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let target = fixture.root.appendingPathComponent("safe-resource")
        let alias = fixture.root.appendingPathComponent("linked-resource")
        try fixture.write(Data("unchanged".utf8), to: target)
        let before = try CopilotSetupFileState.read(target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let plan = CopilotPluginResources(writes: [
            .init(file: target, data: Data("must not publish".utf8)),
            .init(file: alias, data: Data("must not follow".utf8)),
        ], routes: fixture.home)
        #expect(throws: CopilotResourcePreparationFailure.self) { try plan.publish() }
        #expect(try CopilotSetupFileState.read(target) == before)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == target.path)
    }

    @Test func commandLineSetupIsExplicitAndRejectsAmbiguousArguments() throws {
        #expect(try CopilotSetupCommandLine.executable(arguments: []) == nil)
        #expect(try CopilotSetupCommandLine.executable(arguments: ["--unrelated"]) == nil)
        let flag = CopilotSetupCommandLine.installFlag
        let executable = "/Applications/A Tool's Folder/copilot"
        #expect(try CopilotSetupCommandLine.executable(
            arguments: [flag, "--copilot-executable", executable]
        )?.path == executable)
        for arguments in [
            [flag], [flag, "--copilot-executable", "relative"],
            [flag, "--copilot-executable", "/path", flag],
            [flag, "--copilot-executable", "/path\ninjected"],
            ["--copilot-executable", "/path", flag],
        ] {
            #expect(throws: CopilotSetupCommandLine.Failure.self) {
                try CopilotSetupCommandLine.executable(arguments: arguments)
            }
        }
    }

    @Test func coordinatedBridgeRequiresExactTransactionAndArguments() throws {
        let id = UUID().uuidString.lowercased()
        let args = [CopilotSetupCommandLine.bridgeFlag, "prepare", "--transaction", id,
                    "--application", "/Users/example/Applications/Maestro.app"]
        let request = try #require(try CopilotSetupCommandLine.bridge(arguments: args))
        #expect(request.id.uuidString.lowercased() == id)
        #expect(request.executable == nil)
        #expect(!request.allowAbsent)
        #expect(try CopilotSetupCommandLine.bridge(arguments: args + ["--copilot-executable", "/trusted/copilot"])?.executable?.path == "/trusted/copilot")
        for bad in [
            args + ["--allow-absent"],
            args + ["--transaction", id],
            [CopilotSetupCommandLine.bridgeFlag, "unknown"] + Array(args.dropFirst(2)),
            Array(args.prefix(3)) + ["not-a-uuid"] + Array(args.dropFirst(4)),
            Array(args.prefix(5)) + ["/Users/example/Applications/../Other.app"],
        ] {
            #expect(throws: CopilotSetupCommandLine.Failure.self) { try CopilotSetupCommandLine.bridge(arguments: bad) }
        }
    }

    @Test func validationHostCannotEnterCoordinatedInstall() async {
        let request = CopilotSetupCommandLine.Bridge(action: "prepare", id: UUID(),
            application: URL(fileURLWithPath: "/Applications/NotAllowed.app"), executable: nil, allowAbsent: false)
        #expect(await CopilotSetupCommandLine.coordinate(request).exitCode == 1)
    }

    @Test func commandLineSetupCannotInstallFromValidationHost() async {
        #expect(!CopilotSetupAccess.currentAppAllowsChanges)
        #expect(await CopilotSetupCommandLine.install(
            selected: URL(fileURLWithPath: "/nonexistent/copilot")
        ) == .validationOnly)
    }

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

    @Test func constructionDoesNotInstallAndConsentUsesExactOwnPluginArguments() async throws {
        let fixture = try ObserverFixture()
        defer { try? fixture.clean() }
        let runner = ObserverSetupRunner(fixture)
        let setup = CopilotSetup(files: ObserverSetupFiles(fixture: fixture), runner: runner,
                                 bundleIdentifier: CopilotSetupAccess.productionBundleIdentifier,
                                 registration: fixture.registration)
        #expect(await runner.calls.isEmpty)
        #expect(await runner.metadataCalls == 0)
        #expect(await setup.perform(.install, selected: nil, path: "", root: fixture.root, helper: fixture.helper,
                                    controller: controller, skill: skill) == .installed)
        #expect(await setup.perform(.uninstall, selected: nil, path: "", root: fixture.root, helper: fixture.helper,
                                    controller: controller, skill: skill) == .uninstalled)
        #expect(await runner.calls == [
            [fixture.helper.path, "--no-auto-update", "plugin", "install", fixture.source.path],
            [fixture.helper.path, "--no-auto-update", "plugin", "uninstall", "cmux-maestro-native"],
        ])
    }

    @Test func reportsRealFailureAndNeverRunsWhenFilesystemFails() async throws {
        let fixture = try ObserverFixture()
        defer { try? fixture.clean() }
        let failure = ObserverSetupRunner(fixture)
        await failure.configure(result: .exited(7))
        let setup = CopilotSetup(files: ObserverSetupFiles(fixture: fixture), runner: failure,
                                 bundleIdentifier: CopilotSetupAccess.productionBundleIdentifier,
                                 registration: fixture.registration)
        #expect(await setup.perform(.install, selected: nil, path: "", root: fixture.root, helper: fixture.helper,
                                    controller: controller, skill: skill)
            == .incomplete(.pluginPrepared, CopilotSetupResult.failed(7).message))
        let unavailable = CopilotSetup(files: SetupFileStub(fail: true), runner: failure,
                                       bundleIdentifier: CopilotSetupAccess.productionBundleIdentifier,
                                       registration: fixture.registration)
        guard case .conflict = await unavailable.perform(.install, selected: nil, path: "", root: fixture.root,
                helper: fixture.helper, controller: controller, skill: skill) else {
            Issue.record("Filesystem failure must be explicit"); return
        }
        #expect(await failure.calls.count == 1)
        for outcome: CopilotProcessResult in [.timedOut, .cancelled] {
            await failure.configure(result: outcome)
            let result = await setup.perform(.install, selected: nil, path: "", root: fixture.root,
                helper: fixture.helper, controller: controller, skill: skill)
            let message = outcome == .timedOut ? CopilotSetupResult.timedOut.message : CopilotSetupResult.cancelled.message
            #expect(result == .incomplete(.pluginPrepared, message))
        }
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

    @Test(arguments: [false, true])
    func queuedStartupDoesNotConsumeChildReadinessBudget(cancel: Bool) async throws {
        try await exerciseCleanup(cancel: cancel, delayStartup: true, launchDelay: .seconds(4))
    }

    @Test func lateQueuedStartupRetainsFullChildReadinessBudget() async throws {
        try await exerciseCleanup(cancel: false, delayStartup: true, launchDelay: .seconds(2.7))
    }

    @Test(arguments: [false, true])
    func startupObservationFinishesWhenRunnerCannotSpawn(cancel: Bool) async {
        let clock = SetupDeadlineClock()
        let runner = LocalCopilotSetupRunner(deadlineNow: { clock.now() })
        let task = Task {
            defer { clock.finishStartup() }
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            return await runner.run(executable: URL(fileURLWithPath: "/nonexistent/maestro-test-executable"),
                                    arguments: [], path: "/usr/bin:/bin")
        }
        #expect(await clock.waitForStartup() == false)
        #expect(await task.value == (cancel ? .cancelled : .unavailable))
        #expect(!clock.wasSampled)
        #expect(clock.elapsed == .zero)
    }

    @Test func startupObservationIsCancellationAware() async {
        let clock = SetupDeadlineClock()
        defer { clock.finishStartup() }
        let waiter = Task { await clock.waitForStartup() }
        waiter.cancel()
        #expect(await waiter.value == false)
        #expect(!clock.wasSampled)
    }

    @Test func startedRunnerDoesNotBypassMissingWriterReadiness() async throws {
        let fixture = try gatedInstallerFixture()
        defer {
            try? fixture.reader.close()
            try? fixture.writer.close()
            try? fixture.completion.close()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let clock = SetupDeadlineClock()
        let runner = LocalCopilotSetupRunner(deadlineNow: { clock.now() })
        let task = Task {
            defer { clock.finishStartup() }
            return await runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                    arguments: ["-c", "exit 7"], path: "/usr/bin:/bin")
        }
        defer { task.cancel() }
        #expect(await clock.waitForStartup())
        let waiting = ContinuousClock.now
        #expect(try await waitForGatedWriter(in: fixture.directory, deadlineClock: clock) == false)
        #expect(waiting.duration(to: .now) >= .seconds(3))
        #expect(await task.value == .exited(7))
        #expect(clock.elapsed == .zero)
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
                clock.noteDriverEntry()
                return await runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
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
        let enteredCount = clocks.filter(\.driverDidEnter).count
        if !startedConcurrently { tasks.forEach { $0.cancel() } }
        clocks.forEach { $0.advance(by: .seconds(0.4)) }
        var results: [CopilotProcessResult] = []
        for task in tasks {
            let result = await task.value
            results.append(result)
            if startedConcurrently { #expect(result == .timedOut) }
        }
        #expect(startedConcurrently,
                "Blocking supervision: \(readyCount)/2 writers ready; \(sampledCount)/2 supervisors sampled their clocks; \(enteredCount)/2 detached drivers entered before cancellation; results=\(results)")
        for fixture in fixtures {
            try fixture.reader.close()
            _ = releaseMutationGate(fixture.writer)
            #expect(try mutationCompletion(fixture.completion).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("late-mutation").path))
        }
    }

    private func exerciseCleanup(
        cancel: Bool, delayStartup: Bool = false, launchDelay: Duration = .zero
    ) async throws {
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
            defer { clock.finishStartup() }
            let actor: (any Actor)? = #isolation
            #expect(actor == nil, "The nonisolated fixture driver must not inherit MainActor")
            if launchDelay > .zero {
                print("SETUP_STARTUP_PROBE cancel=\(cancel) actorIsNil=\(actor == nil) launchDelay=\(launchDelay)")
                do {
                    try await Task.sleep(for: launchDelay)
                } catch is CancellationError {
                    return CopilotProcessResult.cancelled
                } catch {
                    Issue.record(error)
                    return CopilotProcessResult.unavailable
                }
            }
            return await runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                    arguments: arguments, path: "/usr/bin:/bin")
        }
        defer { task.cancel() }
        // The runner first samples after posix_spawn. Scheduling its driver is
        // not part of the child's three-second readiness budget.
        var ready = false
        if await clock.waitForStartup() {
            ready = try await waitForGatedWriter(in: directory, deadlineClock: clock)
        }
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
        let directory = repository.appendingPathComponent(".build/s/\(UUID().uuidString.prefix(6))")
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
        let files = try CopilotPluginManifest.files(helper: helper, includeObserverHooks: true)
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

    @Test func globalGuideIsSeparateFromManifestQualifiedLifecycleAndIconSkills() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = [
            ("cmux-maestro-orchestrate", ".agents/skills/cmux-maestro-orchestrate/SKILL.md"),
            ("maestro-icon", ".agents/skills/maestro-icon/SKILL.md"),
        ]
        for (name, path) in sources {
            let text = try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
            #expect(text.hasPrefix("---\nname: \(name)\n"))
            #expect(text.contains("/\(CopilotPluginManifest.name):\(name)"))
            #expect(!text.contains("`/cmux-maestro-orchestrate`"))
            #expect(!text.contains("`/maestro-icon`"))
        }
        let messaging = try String(contentsOf: repository.appendingPathComponent("skills/maestro/SKILL.md"), encoding: .utf8)
        #expect(messaging.hasPrefix("---\nname: maestro\n"))
        #expect(messaging.contains("`/maestro`"))
        #expect(messaging.contains(#"{"skill":"maestro"}"#))
        #expect(!messaging.contains("cmux-maestro-native:maestro"))
        #expect(messaging.contains("/cmux-maestro-native:cmux-maestro-orchestrate"))
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
        var routeTemplate = Array("/private/tmp/maestro-setup-XXXXXX".utf8CString)
        let routePath = try #require(mkdtemp(&routeTemplate))
        let routes = URL(fileURLWithPath: String(cString: routePath), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: routes) }
        let local = LocalCopilotSetupFiles(nativeExtensions: directory.appendingPathComponent("e"), messagingRoutes: routes)
        let controller = directory.appendingPathComponent("controller.py")
        let skill = directory.appendingPathComponent("SKILL.md")
        try Data("#!/usr/bin/env python3\n".utf8).write(to: controller)
        try Data("---\nname: cmux-maestro-orchestrate\n---\n".utf8).write(to: skill)
        let iconSkillDirectory = directory.appendingPathComponent("maestro-icon", isDirectory: true)
        try FileManager.default.createDirectory(at: iconSkillDirectory, withIntermediateDirectories: true)
        let iconSkill = iconSkillDirectory.appendingPathComponent("SKILL.md")
        try Data("---\nname: maestro-icon\n---\n".utf8).write(to: iconSkill)
        for name in ["adapter.mjs", "extension.mjs"] {
            try FileManager.default.copyItem(
                at: repository.appendingPathComponent("scripts/delivery-proof/\(name)"),
                to: directory.appendingPathComponent(name)
            )
        }
        try FileManager.default.copyItem(
            at: repository.appendingPathComponent("Resources/NerdFonts"),
            to: directory.appendingPathComponent("NerdFonts")
        )
        let integration = directory.appendingPathComponent("Copilot")
        let oversized = LocalCopilotSetupFiles(
            nativeExtensions: directory.appendingPathComponent("e"),
            messagingRoutes: directory.appendingPathComponent(String(repeating: "r", count: 101)))
        #expect(throws: (any Error).self) {
            try oversized.preparePlugin(root: integration, helper: executable, controller: controller, skill: skill)
        }
        #expect(!FileManager.default.fileExists(atPath: integration.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Orchestration").path))
        #expect(!FileManager.default.fileExists(atPath: local.nativeExtensions.path))
        let plugin = try local.preparePlugin(
            root: integration, helper: executable, controller: controller, skill: skill
        )
        #expect(!FileManager.default.fileExists(atPath: plugin.appendingPathComponent("hooks.json").path),
                "Resource preparation must not publish observer declarations outside the guarded transaction")
        #expect(try Data(contentsOf: plugin.appendingPathComponent("skills/cmux-maestro-orchestrate/SKILL.md"))
            == Data(contentsOf: skill))
        #expect(try Data(contentsOf: plugin.appendingPathComponent("skills/maestro-icon/SKILL.md"))
            == Data(contentsOf: iconSkill))
        #expect(!FileManager.default.fileExists(atPath: plugin.appendingPathComponent("skills/maestro").path))
        let native = local.nativeExtensions.appendingPathComponent("maestro")
        #expect(try Data(contentsOf: native.appendingPathComponent("extension.mjs"))
            == Data(contentsOf: directory.appendingPathComponent("extension.mjs")))
        #expect(try Data(contentsOf: native.appendingPathComponent("adapter.mjs"))
            == Data(contentsOf: directory.appendingPathComponent("adapter.mjs")))
        #expect(try routes.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        let installed = directory.appendingPathComponent(
            "Orchestration/bin/cmux-maestro-orchestrator"
        )
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))
        #expect(try Data(contentsOf: installed) == Data(contentsOf: controller))
        let messagingConfiguration = installed.deletingLastPathComponent().appendingPathComponent("messaging.json")
        let messagingConfig = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: messagingConfiguration)) as? [String: Any]
        )
        #expect(Set(messagingConfig.keys) == Set(["version", "routes", "extension"]))
        #expect(messagingConfig["version"] as? Int == 1)
        #expect(messagingConfig["routes"] as? String == routes.path)
        #expect(messagingConfig["extension"] as? String == native.path)
        #expect(try messagingConfiguration.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true)
        #expect((try FileManager.default.attributesOfItem(atPath: messagingConfiguration.path)[.posixPermissions] as? Int) == 0o600)
        #expect(try Data(contentsOf: installed.deletingLastPathComponent().appendingPathComponent("NerdFonts/glyphnames.json"))
            == Data(contentsOf: repository.appendingPathComponent("Resources/NerdFonts/glyphnames.json")))
        #expect(try String(contentsOf: configuration, encoding: .utf8) == "preserved")
        #expect(try local.executable(selected: executable, path: "") == executable)
        #expect(throws: (any Error).self) { try local.executable(selected: nil, path: ".:relative") }
        // Simulate only the obsolete installer-owned copy, not a global installation.
        let obsolete = plugin.appendingPathComponent("skills/maestro")
        let obsoleteFD = try HookFiles.privateDirectory(obsolete)
        defer { close(obsoleteFD) }
        try HookFiles.atomicWrite(Data("---\nname: maestro\n---\n".utf8), name: "SKILL.md", directory: obsoleteFD)
        let unrelatedSkill = plugin.appendingPathComponent("skills/unrelated")
        try FileManager.default.createDirectory(at: unrelatedSkill, withIntermediateDirectories: true)
        let unrelatedGuide = unrelatedSkill.appendingPathComponent("SKILL.md")
        try Data("unrelated guide".utf8).write(to: unrelatedGuide)
        let retainedExtra = obsolete.appendingPathComponent("user-notes.txt")
        try Data("preserve".utf8).write(to: retainedExtra)
        for _ in 0..<2 {
            _ = try local.preparePlugin(root: integration, helper: executable, controller: controller, skill: skill)
            #expect(!FileManager.default.fileExists(atPath: obsolete.appendingPathComponent("SKILL.md").path))
            #expect(try Data(contentsOf: unrelatedGuide) == Data("unrelated guide".utf8))
            #expect(try Data(contentsOf: retainedExtra) == Data("preserve".utf8))
            #expect(try Data(contentsOf: plugin.appendingPathComponent("skills/cmux-maestro-orchestrate/SKILL.md"))
                == Data(contentsOf: skill))
            #expect(try Data(contentsOf: plugin.appendingPathComponent("skills/maestro-icon/SKILL.md"))
                == Data(contentsOf: iconSkill))
        }
        let obsoleteGuide = obsolete.appendingPathComponent("SKILL.md")
        try FileManager.default.createSymbolicLink(at: obsoleteGuide, withDestinationURL: unrelatedGuide)
        #expect(throws: (any Error).self) {
            try local.preparePlugin(root: integration, helper: executable, controller: controller, skill: skill)
        }
        #expect(try Data(contentsOf: unrelatedGuide) == Data("unrelated guide".utf8))
        try FileManager.default.removeItem(at: obsoleteGuide)
        let savedObsolete = plugin.appendingPathComponent("skills/maestro-saved")
        try FileManager.default.moveItem(at: obsolete, to: savedObsolete)
        try FileManager.default.createSymbolicLink(at: obsolete, withDestinationURL: unrelatedSkill)
        #expect(throws: (any Error).self) {
            try local.preparePlugin(root: integration, helper: executable, controller: controller, skill: skill)
        }
        #expect(try Data(contentsOf: unrelatedGuide) == Data("unrelated guide".utf8))
        let retained = routes.appendingPathComponent("retained.json")
        try Data("live route must survive uninstall".utf8).write(to: retained)
        try local.removeMessaging(root: integration)
        #expect(!FileManager.default.fileExists(atPath: native.appendingPathComponent("extension.mjs").path))
        #expect(!FileManager.default.fileExists(atPath: installed.deletingLastPathComponent().appendingPathComponent("messaging.json").path))
        #expect(FileManager.default.fileExists(atPath: retained.path))
    }
}
