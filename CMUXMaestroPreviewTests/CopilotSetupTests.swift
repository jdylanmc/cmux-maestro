import Darwin
import Foundation
import Testing
@testable import CMUXMaestroPreview

/// Records every provider request; setup policy makes no other kind.
private actor SetupRunnerSpy: CopilotSetupProcessRunner {
    var calls: [String] = []
    func metadata(executable: URL, path: String, providerHome: URL?) async -> CopilotMetadataResult {
        calls.append("metadata")
        return .failed(.unavailable)
    }
    func plugin(executable: URL, operation: CopilotPluginOperation, path: String,
                providerHome: URL?) async -> CopilotPluginOperationResult {
        calls.append("plugin")
        return .failed(.unavailable)
    }
    func sourceIdentity(executable: URL, source: URL, path: String) async -> CopilotSourceIdentityResult {
        calls.append("sourceIdentity")
        return .failed(.unavailable)
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
    func removeMessaging(root: URL) throws -> String? { nil }  // no CMUX hooks file in this stub
    func installCMUXHooks() throws {}  // this stub models no CMUX hooks file
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
    func removeMessaging(root: URL) throws -> String? { record(); return nil }
    func installCMUXHooks() throws { record() }

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

/// Upper bound for a test's wait on supervised real-process work. It is a hang
/// ceiling, not a speed oracle: passing runs finish in a few seconds.
let supervisedWaitLimit: Duration = .seconds(30)

private final class FirstResume<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(_ continuation: CheckedContinuation<Value?, Never>) { self.continuation = continuation }

    func resume(_ value: Value?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// Returns the operation's value, or nil once `limit` elapses. An operation that
/// never completes is abandoned rather than awaited, so the caller cannot hang.
func bounded<Value: Sendable>(
    within limit: Duration = supervisedWaitLimit,
    _ operation: @escaping @Sendable () async -> Value
) async -> Value? {
    await withCheckedContinuation { continuation in
        let first = FirstResume(continuation)
        let timer = Task.detached {
            guard (try? await Task.sleep(for: limit)) != nil else { return }
            first.resume(nil)
        }
        Task.detached {
            let value = await operation()
            timer.cancel()
            first.resume(value)
        }
    }
}

/// Reads to EOF without blocking past `deadline`; nil means a writer stayed open.
/// Polls a nonblocking read because Darwin's poll(2) does not report FIFO hangup.
func boundedReadToEnd(_ fd: Int32, until deadline: ContinuousClock.Instant) -> Data? {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
    var data = Data()
    var bytes = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(fd, &bytes, bytes.count)
        if count > 0 {
            data.append(contentsOf: bytes.prefix(count))
            continue
        }
        if count == 0 { return data }
        guard errno == EAGAIN || errno == EINTR, ContinuousClock.now < deadline else { return nil }
        Thread.sleep(forTimeInterval: 0.01)
    }
}

struct CopilotPluginExchangeTests {
    @Test(arguments: ["1.0.89", "1.0.91", "1.1.0", "1.99.123"])
    func disableUsesIdentityPrecheckOfficialAPIAndReadback(version: String) throws {
        let exchange = try CopilotMetadataExchange(operation: .disable(identity: "owned-id"))
        _ = try requests(exchange)
        try send(exchange, id: 1, result: ["version": version, "protocolVersion": 3])
        #expect(try requests(exchange).contains("plugins.list"))
        var plugin: [String: Any] = ["name": CopilotPluginManifest.name, "marketplace": "",
                                     "enabled": true, "directSourceId": "owned-id"]
        try send(exchange, id: 4, result: ["plugins": [plugin]])
        #expect(try requests(exchange).contains("plugins.disable"))
        #expect(exchange.pluginReceipt == nil)
        try send(exchange, id: 5, result: NSNull())
        #expect(try requests(exchange).contains("plugins.list"))
        #expect(exchange.pluginReceipt == nil)
        plugin["enabled"] = false
        try send(exchange, id: 6, result: ["plugins": [plugin]])
        #expect(exchange.pluginReceipt?.plugin?.enabled == false)
        #expect(exchange.pluginReceipt?.plugin?.directSourceId == "owned-id")
    }

    @Test(arguments: ["unsupported-version", "wrong-source", "ignored-disable"])
    func disableCannotClaimUnsupportedWrongSourceOrUnverifiedState(kind: String) throws {
        let exchange = try CopilotMetadataExchange(operation: .disable(identity: "owned-id"))
        _ = try requests(exchange)
        if kind == "unsupported-version" {
            #expect(throws: (any Error).self) { try send(exchange, id: 1, result: ["version": "2.0.0", "protocolVersion": 3]) }
            #expect(try requests(exchange).isEmpty)
            return
        }
        try send(exchange, id: 1, result: ["version": "1.0.89", "protocolVersion": 3])
        _ = try requests(exchange)
        let plugin: [String: Any] = ["name": CopilotPluginManifest.name, "marketplace": "", "enabled": true,
                                     "directSourceId": kind == "wrong-source" ? "foreign-id" : "owned-id"]
        if kind == "wrong-source" {
            #expect(throws: (any Error).self) { try send(exchange, id: 4, result: ["plugins": [plugin]]) }
            #expect(try requests(exchange).isEmpty)
        } else {
            try send(exchange, id: 4, result: ["plugins": [plugin]])
            _ = try requests(exchange)
            try send(exchange, id: 5, result: NSNull())
            _ = try requests(exchange)
            #expect(throws: (any Error).self) { try send(exchange, id: 6, result: ["plugins": [plugin]]) }
        }
        #expect(exchange.pluginReceipt == nil)
    }

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

    @Test(arguments: ["1.0.88", "1.0.89", "1.0.91", "1.1.0"])
    func installUsesExactSourceAndProviderReceiptAfterVersionCheck(version: String) throws {
        let source = URL(fileURLWithPath: "/owned/stable/plugin")
        let exchange = try CopilotMetadataExchange(operation: .install(source: source, expectedIdentity: nil))
        let initial = try requests(exchange)
        #expect(initial.contains("status.get"))
        #expect(!initial.contains("plugins.install"))
        try send(exchange, id: 1, result: ["version": version, "protocolVersion": 3])
        let request = try requests(exchange).replacingOccurrences(of: "\\/", with: "/")
        #expect(request.contains("plugins.install"))
        #expect(request.contains(source.path))
        #expect(!request.contains("disable"))
        try send(exchange, id: 4, result: installed())
        #expect(exchange.pluginReceipt?.plugin?.directSourceId == "returned-opaque-identity")
        #expect(exchange.pluginReceipt?.directInstallDeprecated == true)
        #expect(exchange.input[1] == -1)
    }

    @Test(arguments: ["1.0.88", "1.0.89", "1.0.91", "1.1.0"])
    func uninstallUsesExactSourceIdentityAndAcceptsNullResult(version: String) throws {
        let exchange = try CopilotMetadataExchange(operation: .uninstall(identity: "owned-opaque-id"))
        _ = try requests(exchange)
        try send(exchange, id: 1, result: ["version": version, "protocolVersion": 3])
        let request = try requests(exchange)
        #expect(request.contains("plugins.uninstall"))
        #expect(request.contains("directSourceId"))
        #expect(request.contains("owned-opaque-id"))
        try send(exchange, id: 4, result: NSNull())
        #expect(exchange.pluginReceipt != nil)
        #expect(exchange.pluginReceipt?.plugin == nil)
    }

    @Test(arguments: [
        ("0.9.0", 3), ("2.0.0", 3), ("invalid", 3), ("1.0.91-preview", 3),
        ("1.0.91", 2), ("1.0.91", 4),
    ])
    func unsupportedProviderNeverReceivesMutation(version: String, protocolVersion: Int) throws {
        let exchange = try CopilotMetadataExchange(operation: .uninstall(identity: "owned-id"))
        _ = try requests(exchange)
        #expect(throws: (any Error).self) {
            try send(exchange, id: 1, result: ["version": version, "protocolVersion": protocolVersion])
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

    @Test func constructionDoesNotInstallAndConsentUsesExactOwnPluginOperations() async throws {
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
        #expect(await runner.calls == ["install:\(fixture.source.path)", "uninstall:opaque-provider-source"])
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

    // Removed 2026-10-15 by owner decision: timeoutAndCancellationStopLauncherAndChild-
    // WithoutLateWrites(cancel:) hung for ~4.5 h in CI run 38680234264 attempt 1;
    // its cause was not established. It was the only exerciseCleanup caller with
    // delayStartup: false. Lost coverage: non-delayed launcher cleanup
    // (delayStartup: false) for both timeout and cancel, the production-like path
    // that hung. Remaining cleanup coverage uses a delayed launcher only:
    // cancel via queuedStartupDoesNotConsumeChildReadinessBudget(cancel: true),
    // timeout via its cancel: false case, delayedStartupDoesNotExpireBeforeDeadlineIsArmed
    // and lateQueuedStartupRetainsFullChildReadinessBudget.

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
        let started = await bounded { await clock.waitForStartup() }
        #expect(started == true, Comment(rawValue: "startup=\(started.map { "\($0)" } ?? "unreturned"); "
            + supervisionDiagnostics(fixture.directory, clock: clock)))
        let waiting = ContinuousClock.now
        #expect(try await waitForGatedWriter(in: fixture.directory, deadlineClock: clock) == false)
        #expect(waiting.duration(to: .now) >= .seconds(3))
        let exited = await bounded { await task.value }
        #expect(exited == .exited(7), Comment(rawValue: "result=\(exited.map { "\($0)" } ?? "unreturned"); "
            + supervisionDiagnostics(fixture.directory, clock: clock)))
        #expect(clock.elapsed == .zero)
    }

    @Test func supervisedWaitHelpersReturnAtTheirBoundInsteadOfHanging() async throws {
        let never = AsyncStream<Void>.makeStream()
        defer { never.continuation.finish() }
        let started = ContinuousClock.now
        let abandoned = await bounded(within: .milliseconds(200)) {
            for await _ in never.stream {}
            return true
        }
        #expect(abandoned == nil)
        #expect(started.duration(to: .now) < .seconds(10))
        #expect(await bounded(within: .seconds(10)) { 7 } == 7)

        var channel: [Int32] = [-1, -1]
        try #require(pipe(&channel) == 0)
        defer { for fd in channel where fd >= 0 { close(fd) } }
        #expect(boundedReadToEnd(channel[0], until: .now.advanced(by: .milliseconds(200))) == nil,
                "An open writer must fail at the bound rather than block")
        try #require(Darwin.write(channel[1], "partial", 7) == 7)
        close(channel[1]); channel[1] = -1
        #expect(boundedReadToEnd(channel[0], until: .now.advanced(by: .seconds(10))) == Data("partial".utf8))
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
        for (index, task) in tasks.enumerated() {
            guard let result = await bounded({ await task.value }) else {
                let detail = fixtures.indices.map {
                    "[\($0)] " + supervisionDiagnostics(fixtures[$0].directory, clock: clocks[$0])
                }.joined(separator: " | ")
                Issue.record("Supervised run \(index) did not return within \(supervisedWaitLimit); \(detail)")
                return
            }
            results.append(result)
            if startedConcurrently { #expect(result == .timedOut) }
        }
        #expect(startedConcurrently,
                "Blocking supervision: \(readyCount)/2 writers ready; \(sampledCount)/2 supervisors sampled their clocks; \(enteredCount)/2 detached drivers entered before cancellation; results=\(results)")
        for fixture in fixtures {
            try fixture.reader.close()
            _ = releaseMutationGate(fixture.writer)
            #expect(try mutationCompletion(fixture.completion, in: fixture.directory).isEmpty)
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
        let started = await bounded { await clock.waitForStartup() }
        if started == true {
            ready = try await waitForGatedWriter(in: directory, deadlineClock: clock)
        }
        var readinessFailure = "Synthetic child must execute before the timeout/cancellation assertion"
        if !ready {
            let detail = supervisionDiagnostics(directory, clock: clock)
            task.cancel()
            let stopped = await bounded { await task.value }
            readinessFailure += "; startup=\(started.map { "\($0)" } ?? "unreturned")"
                + "; result=\(stopped.map { "\($0)" } ?? "unreturned"); \(detail)"
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
        guard let result = await bounded({ await task.value }) else {
            let detail = supervisionDiagnostics(directory, clock: clock)
            Issue.record("Supervised run did not return within \(supervisedWaitLimit); cancel=\(cancel); \(detail)")
            return
        }
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
        #expect(try mutationCompletion(fixture.completion, in: directory, clock: clock).isEmpty,
                "A writer survived returned cleanup")
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
        #expect(try String(decoding: mutationCompletion(fixture.completion, in: directory), as: UTF8.self) == "mutated")
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

    private func mutationCompletion(_ completion: FileHandle, in directory: URL,
                                    clock: SetupDeadlineClock? = nil) throws -> Data {
        // EOF proves every writer closed; a surviving writer fails at the bound.
        guard let data = boundedReadToEnd(completion.fileDescriptor,
                                          until: .now.advanced(by: supervisedWaitLimit)) else {
            let detail = supervisionDiagnostics(directory, clock: clock)
            Issue.record("Completion writer stayed open past \(supervisedWaitLimit); \(detail)")
            throw CancellationError()
        }
        return data
    }

    /// Bounded evidence for a give-up path: clock sampling, fixture files and recorded PIDs.
    private func supervisionDiagnostics(_ directory: URL, clock: SetupDeadlineClock?) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let listing = files.sorted().prefix(16).map { String($0.prefix(64)) }.joined(separator: ",")
        let pids = ["launcher.pid", "child.pid"].map { name in
            let value = (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))
                .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16)) }
            return "\(name)=\(value ?? "unknown")"
        }.joined(separator: " ")
        let sampled = clock.map { "\($0.wasSampled)" } ?? "n/a"
        return "clock.wasSampled=\(sampled); files=\(listing); \(pids)"
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
            ("maestro-pet", ".agents/skills/maestro-pet/SKILL.md"),
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
        let petSkillDirectory = directory.appendingPathComponent("maestro-pet", isDirectory: true)
        try FileManager.default.createDirectory(at: petSkillDirectory, withIntermediateDirectories: true)
        let petSkill = petSkillDirectory.appendingPathComponent("SKILL.md")
        try Data("---\nname: maestro-pet\n---\n".utf8).write(to: petSkill)
        let petKit = petSkillDirectory.appendingPathComponent("pet_kit.py")
        try FileManager.default.copyItem(
            at: repository.appendingPathComponent(".agents/skills/maestro-pet/pet_kit.py"),
            to: petKit
        )
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
        #expect(try Data(contentsOf: plugin.appendingPathComponent("skills/maestro-pet/SKILL.md"))
            == Data(contentsOf: petSkill))
        let installedKit = plugin.appendingPathComponent("skills/maestro-pet/pet_kit.py")
        #expect(try Data(contentsOf: installedKit) == Data(contentsOf: petKit))
        #expect((try FileManager.default.attributesOfItem(atPath: installedKit.path)[.posixPermissions] as? Int) == 0o600)
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
        let restoreHooks = local.cmuxHooksFile
        // Standalone setup writes the active hooks only after the plugin is published.
        #expect(!FileManager.default.fileExists(atPath: restoreHooks.path))
        try local.installCMUXHooks()
        #expect(restoreHooks.path == directory.appendingPathComponent("hooks/cmux-maestro-cmux-hooks.json").path)
        #expect(try Data(contentsOf: restoreHooks) == CopilotCMUXHooks.manifest())
        #expect((try FileManager.default.attributesOfItem(atPath: restoreHooks.path)[.posixPermissions] as? Int) == 0o600)
        let declared = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: restoreHooks)) as? [String: Any])
        let restoreDeclarations = try #require(declared["hooks"] as? [String: [[String: Any]]])
        #expect(Set(restoreDeclarations.keys) == ["SessionStart", "Stop", "Notification", "SessionEnd"])
        // CMUX 0.65.1's exact queued Copilot command and env guards.
        #expect(restoreDeclarations["SessionStart"]?.first?["bash"] as? String == #"cmux_cli="${CMUX_BUNDLED_CLI_PATH:-}"; if [ -z "$cmux_cli" ] || [ ! -x "$cmux_cli" ]; then cmux_cli="$(command -v cmux 2>/dev/null || true)"; fi; agent_pid="${CMUX_COPILOT_PID:-${PPID:-}}"; if [ -n "$CMUX_SURFACE_ID" ] && [ "$CMUX_COPILOT_HOOKS_DISABLED" != "1" ] && [ -n "$cmux_cli" ]; then if [ -n "${CMUX_SOCKET_PATH:-}" ]; then CMUX_COPILOT_PID="$agent_pid" CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=0.5 "$cmux_cli" --socket "$CMUX_SOCKET_PATH" hooks enqueue copilot session-start 2>/dev/null || { cat >/dev/null; echo '{}'; }; else CMUX_COPILOT_PID="$agent_pid" CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=0.5 "$cmux_cli" hooks enqueue copilot session-start 2>/dev/null || { cat >/dev/null; echo '{}'; }; fi; else cat >/dev/null; echo '{}'; fi"#)
        for (event, subcommand) in [("Stop", "stop"), ("Notification", "stop"), ("SessionEnd", "session-end")] {
            #expect(restoreDeclarations[event]?.first?["bash"] as? String == CopilotCMUXHooks.command(subcommand))
            #expect(restoreDeclarations[event]?.first?["timeoutSec"] as? Int == 5)
            #expect(restoreDeclarations[event]?.first?["type"] as? String == "command")
        }
        let kitData = try Data(contentsOf: petKit)
        try FileManager.default.removeItem(at: petKit)
        #expect(throws: (any Error).self) {
            try local.resources(root: integration, helper: executable, controller: controller, skill: skill)
        }
        #expect(try Data(contentsOf: installedKit) == kitData)
        try kitData.write(to: petKit)
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
        let unrelatedHook = restoreHooks.deletingLastPathComponent().appendingPathComponent("unrelated.json")
        try Data("{\"version\":1,\"hooks\":{}}".utf8).write(to: unrelatedHook)
        #expect(try local.removeMessaging(root: integration) == nil)
        #expect(!FileManager.default.fileExists(atPath: native.appendingPathComponent("extension.mjs").path))
        #expect(!FileManager.default.fileExists(atPath: installed.deletingLastPathComponent().appendingPathComponent("messaging.json").path))
        #expect(FileManager.default.fileExists(atPath: retained.path))
        #expect(!FileManager.default.fileExists(atPath: restoreHooks.path))
        #expect(try Data(contentsOf: unrelatedHook) == Data("{\"version\":1,\"hooks\":{}}".utf8))
        // Clean fixture: only the CMUX hooks file can make the next preparations refuse.
        try FileManager.default.removeItem(at: obsolete)
        try FileManager.default.moveItem(at: savedObsolete, to: obsolete)
        _ = try local.preparePlugin(root: integration, helper: executable, controller: controller, skill: skill)
        try local.installCMUXHooks()
        #expect(try Data(contentsOf: restoreHooks) == CopilotCMUXHooks.manifest())
        let extensionFile = native.appendingPathComponent("extension.mjs")
        let installedExtension = try Data(contentsOf: extensionFile)
        // A file at the owned name that Maestro did not write is never replaced or removed.
        let foreign = Data("{\"version\":1,\"hooks\":{\"SessionStart\":[]}}".utf8)
        try foreign.write(to: restoreHooks)
        do {
            _ = try local.preparePlugin(root: integration, helper: executable, controller: controller, skill: skill)
            Issue.record("Setup must refuse a CMUX hooks file Maestro did not write")
        } catch let failure as CopilotResourcePreparationFailure {
            #expect(failure.outcome == .untouched)
            #expect(failure.detail?.contains(restoreHooks.path) == true)
        }
        #expect(try Data(contentsOf: restoreHooks) == foreign)
        #expect(try Data(contentsOf: extensionFile) == installedExtension)
        #expect(try local.removeMessaging(root: integration) == restoreHooks.path)
        #expect(try Data(contentsOf: restoreHooks) == foreign)
        func asideCopies() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: restoreHooks.deletingLastPathComponent().path)
                .filter { $0.contains(".removing-") }
        }
        #expect(try asideCopies().isEmpty)

        // The ownership check binds to the write: bytes that change after planning are refused.
        try FileManager.default.removeItem(at: restoreHooks)
        let planned = try local.resources(root: integration, helper: executable, controller: controller, skill: skill)
        try foreign.write(to: restoreHooks)
        do {
            try planned.publish()
            Issue.record("Publishing over a file Maestro did not write must refuse")
        } catch let failure as CopilotResourcePreparationFailure {
            #expect(failure.outcome == .untouched)
            #expect(failure.detail?.contains(restoreHooks.path) == true)
        }
        #expect(try Data(contentsOf: restoreHooks) == foreign)
        #expect(!FileManager.default.fileExists(atPath: extensionFile.path))  // nothing else was written
        #expect(throws: CopilotResourcePreparationFailure.self) { try local.installCMUXHooks() }
        #expect(try Data(contentsOf: restoreHooks) == foreign)

        // Anything at the name that is not readable as Maestro's bytes is foreign, and named.
        for occupant in ["symlink", "oversized"] {
            try FileManager.default.removeItem(at: restoreHooks)
            if occupant == "symlink" {
                try FileManager.default.createSymbolicLink(at: restoreHooks, withDestinationURL: unrelatedHook)
            } else {
                try Data(repeating: 0x20, count: 70_000).write(to: restoreHooks)
            }
            do {
                _ = try local.preparePlugin(root: integration, helper: executable, controller: controller, skill: skill)
                Issue.record("A \(occupant) at the CMUX hooks name must refuse")
            } catch let failure as CopilotResourcePreparationFailure {
                #expect(failure.detail?.contains(restoreHooks.path) == true)
            }
            #expect(try local.removeMessaging(root: integration) == restoreHooks.path)
        }
        try FileManager.default.removeItem(at: restoreHooks)

        // A copy stranded by an interrupted uninstall is recovered on the next one.
        let hooksDirectory = restoreHooks.deletingLastPathComponent()
        let strandedOwned = hooksDirectory.appendingPathComponent(".\(restoreHooks.lastPathComponent).removing-owned")
        try CopilotCMUXHooks.manifest().write(to: strandedOwned)
        let strandedForeign = hooksDirectory.appendingPathComponent(".\(restoreHooks.lastPathComponent).removing-foreign")
        try foreign.write(to: strandedForeign)
        // Setup recovers them first too: the human's file goes back and is refused by name.
        #expect(throws: CopilotResourcePreparationFailure.self) {
            try local.preparePlugin(root: integration, helper: executable, controller: controller, skill: skill)
        }
        #expect(!FileManager.default.fileExists(atPath: strandedOwned.path))
        #expect(try Data(contentsOf: restoreHooks) == foreign)  // the human's file is back under its name
        try CopilotCMUXHooks.manifest().write(to: strandedOwned)
        try FileManager.default.moveItem(at: restoreHooks, to: strandedForeign)
        try local.removeMessaging(root: integration)
        #expect(!FileManager.default.fileExists(atPath: strandedOwned.path))
        #expect(try Data(contentsOf: restoreHooks) == foreign)
        try foreign.write(to: strandedForeign)
        do {
            try local.removeMessaging(root: integration)
            Issue.record("A stranded foreign copy with its name taken must be named")
        } catch let conflict as CopilotRegistrationConflict {
            #expect(conflict.message.contains(strandedForeign.path))
            #expect(conflict.message.contains(restoreHooks.path))
        }
        try FileManager.default.removeItem(at: strandedForeign)
        #expect(try asideCopies().isEmpty)

        // A foreign file set aside, whose name is taken before it goes back, is named (both paths).
        try foreign.write(to: restoreHooks)
        var squatted = local
        let squatterPath = restoreHooks
        squatted.beforeForeignCMUXHooksPutBack = { try? Data("{}".utf8).write(to: squatterPath) }
        do {
            try squatted.removeMessaging(root: integration)
            Issue.record("A failed put-back of a foreign file must be named")
        } catch let conflict as CopilotRegistrationConflict {
            let aside = try #require(try asideCopies().first)
            #expect(conflict.message.contains(hooksDirectory.appendingPathComponent(aside).path))
            #expect(conflict.message.contains(restoreHooks.path))
            #expect(try Data(contentsOf: hooksDirectory.appendingPathComponent(aside)) == foreign)
            try FileManager.default.removeItem(at: hooksDirectory.appendingPathComponent(aside))
        }
        #expect(try asideCopies().isEmpty)

        // A file swapped in between any check and the removal is the one verified, and kept.
        try FileManager.default.removeItem(at: restoreHooks)
        _ = try local.preparePlugin(root: integration, helper: executable, controller: controller, skill: skill)
        try local.installCMUXHooks()
        var racing = local
        let swapped = restoreHooks
        racing.beforeCMUXHooksRemoval = { try? foreign.write(to: swapped) }
        try racing.removeMessaging(root: integration)
        #expect(try Data(contentsOf: restoreHooks) == foreign)
        #expect(try asideCopies().isEmpty)

        // Uninstall is one transaction: a later removal failure puts the CMUX hooks file back.
        try FileManager.default.removeItem(at: restoreHooks)
        _ = try local.preparePlugin(root: integration, helper: executable, controller: controller, skill: skill)
        try local.installCMUXHooks()
        let messaging = installed.deletingLastPathComponent().appendingPathComponent("messaging.json")
        try FileManager.default.removeItem(at: messaging)
        try FileManager.default.createDirectory(at: messaging.appendingPathComponent("blocker"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try local.removeMessaging(root: integration) }
        #expect(try Data(contentsOf: restoreHooks) == CopilotCMUXHooks.manifest())
        #expect(try asideCopies().isEmpty)
        // If the file cannot be put back (something took its name), uninstall says where it is.
        let squatter = Data("{\"version\":1,\"hooks\":{}}".utf8)
        var blocked = local
        blocked.afterCMUXHooksMovedAside = { try? squatter.write(to: swapped) }
        do {
            try blocked.removeMessaging(root: integration)
            Issue.record("A failed put-back must be reported")
        } catch let conflict as CopilotRegistrationConflict {
            let aside = try #require(try asideCopies().first)
            #expect(conflict.message.contains(restoreHooks.deletingLastPathComponent().appendingPathComponent(aside).path))
            #expect(conflict.message.contains("to \(restoreHooks.path)."))
            #expect(try Data(contentsOf: restoreHooks.deletingLastPathComponent().appendingPathComponent(aside))
                == CopilotCMUXHooks.manifest())
            try FileManager.default.removeItem(at: restoreHooks)
            try FileManager.default.moveItem(at: restoreHooks.deletingLastPathComponent().appendingPathComponent(aside),
                                             to: restoreHooks)
        }
        #expect(try asideCopies().isEmpty)
        try FileManager.default.removeItem(at: messaging)
        try local.removeMessaging(root: integration)
        #expect(!FileManager.default.fileExists(atPath: restoreHooks.path))

        // A manifest an earlier release shipped is Maestro's: setup replaces it, uninstall removes it.
        let earlier = Data("{\"maestro\":{\"cmux\":\"0.64.0\"},\"version\":1}".utf8)
        var upgrading = local
        upgrading.shippedCMUXManifests = [try CopilotCMUXHooks.manifest(), earlier]
        try earlier.write(to: restoreHooks)
        _ = try upgrading.preparePlugin(root: integration, helper: executable, controller: controller, skill: skill)
        try upgrading.installCMUXHooks()
        #expect(try Data(contentsOf: restoreHooks) == CopilotCMUXHooks.manifest())
        try earlier.write(to: restoreHooks)
        try upgrading.removeMessaging(root: integration)
        #expect(!FileManager.default.fileExists(atPath: restoreHooks.path))
        #expect(try asideCopies().isEmpty)

        // Publishing binds the ownership check to the bytes it replaces: a file swapped in after
        // the new manifest is staged survives, whether the name was empty or held Maestro's copy.
        func pendingCopies() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: hooksDirectory.path).filter { $0.contains(".pending-") }
        }
        for existing in [nil, try CopilotCMUXHooks.manifest()] as [Data?] {
            if let existing { try existing.write(to: restoreHooks) }
            var publishing = local
            publishing.beforeCMUXHooksPublish = { try? foreign.write(to: swapped) }
            do {
                try publishing.installCMUXHooks()
                Issue.record("A file swapped in before publish must not be replaced")
            } catch let failure as CopilotResourcePreparationFailure {
                #expect(failure.outcome == .untouched)
                #expect(failure.detail?.contains(restoreHooks.path) == true)
            }
            #expect(try Data(contentsOf: restoreHooks) == foreign)
            #expect(try asideCopies().isEmpty)
            #expect(try pendingCopies().isEmpty)
            try FileManager.default.removeItem(at: restoreHooks)
        }

        // A file that takes the name after the current one is moved aside is not replaced either.
        var late = local
        late.beforeCMUXHooksRename = { try? foreign.write(to: swapped) }
        do {
            try late.installCMUXHooks()
            Issue.record("A file that takes the free name before the rename must not be replaced")
        } catch let failure as CopilotResourcePreparationFailure {
            #expect(failure.detail?.contains(restoreHooks.path) == true)
        }
        #expect(try Data(contentsOf: restoreHooks) == foreign)
        #expect(try pendingCopies().isEmpty)
        try CopilotCMUXHooks.manifest().write(to: restoreHooks)
        do {
            try late.installCMUXHooks()
            Issue.record("Maestro's earlier copy cannot go back over the late file; both must be named")
        } catch let conflict as CopilotRegistrationConflict {
            let aside = try #require(try asideCopies().first)
            #expect(conflict.message.contains(hooksDirectory.appendingPathComponent(aside).path))
            #expect(conflict.message.contains(restoreHooks.path))
            #expect(try Data(contentsOf: hooksDirectory.appendingPathComponent(aside)) == CopilotCMUXHooks.manifest())
            try FileManager.default.removeItem(at: hooksDirectory.appendingPathComponent(aside))
        }
        #expect(try Data(contentsOf: restoreHooks) == foreign)
        #expect(try pendingCopies().isEmpty)
        try FileManager.default.removeItem(at: restoreHooks)

        // Publish rechecks the copy it moved aside before deleting it, and names a failed delete.
        try CopilotCMUXHooks.manifest().write(to: restoreHooks)
        var rewritten = local
        let hooksPath = hooksDirectory
        rewritten.beforeCMUXHooksAsideCleanup = {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: hooksPath.path)) ?? []
            where name.contains(".removing-") { try? foreign.write(to: hooksPath.appendingPathComponent(name)) }
        }
        do {
            try rewritten.installCMUXHooks()
            Issue.record("A moved copy changed before cleanup must be kept and named")
        } catch let conflict as CopilotRegistrationConflict {
            let aside = try #require(try asideCopies().first)
            #expect(conflict.message.contains(hooksDirectory.appendingPathComponent(aside).path))
            #expect(try Data(contentsOf: hooksDirectory.appendingPathComponent(aside)) == foreign)
            try FileManager.default.removeItem(at: hooksDirectory.appendingPathComponent(aside))
        }
        #expect(try Data(contentsOf: restoreHooks) == CopilotCMUXHooks.manifest())
        var undeletable = local
        undeletable.removeEntry = { _, _ in -1 }
        do {
            try undeletable.installCMUXHooks()
            Issue.record("A failed cleanup of the moved copy must be named")
        } catch let conflict as CopilotRegistrationConflict {
            let aside = try #require(try asideCopies().first)
            #expect(conflict.message.contains(hooksDirectory.appendingPathComponent(aside).path))
            try FileManager.default.removeItem(at: hooksDirectory.appendingPathComponent(aside))
        }
        #expect(try asideCopies().isEmpty)

        // Rollback goes through the same ownership-bound path: a file swapped in survives, named.
        let earlierManifest = Data("{\"maestro\":{\"cmux\":\"0.64.0\"},\"version\":1}".utf8)
        for before in [nil, earlierManifest] as [Data?] {
            try CopilotCMUXHooks.manifest().write(to: restoreHooks)
            var rolling = local
            rolling.beforeCMUXHooksPublish = { try? foreign.write(to: swapped) }
            do {
                try rolling.restoreCMUXHooks(to: before, permissions: 0o600, recorded: [try CopilotCMUXHooks.manifest()])
                Issue.record("Rollback must not replace a file swapped in")
            } catch let conflict as CopilotRegistrationConflict {
                #expect(conflict.message.contains(restoreHooks.path))
            }
            #expect(try Data(contentsOf: restoreHooks) == foreign)
            #expect(try asideCopies().isEmpty)
            #expect(try pendingCopies().isEmpty)
            try CopilotCMUXHooks.manifest().write(to: restoreHooks)
            try local.restoreCMUXHooks(to: before, permissions: 0o600, recorded: [try CopilotCMUXHooks.manifest()])
            #expect((try? Data(contentsOf: restoreHooks)) == before)
        }
        try? FileManager.default.removeItem(at: restoreHooks)

        // A file an interrupted uninstall left aside goes back before install, which then refuses it by name.
        try foreign.write(to: hooksDirectory.appendingPathComponent("\(CopilotObserverRegistration.asidePrefix)crash"))
        do {
            _ = try local.preparePlugin(root: integration, helper: executable, controller: controller, skill: skill)
            Issue.record("A recovered foreign file must refuse setup by name")
        } catch let failure as CopilotResourcePreparationFailure {
            #expect(failure.detail?.contains(restoreHooks.path) == true)
        }
        #expect(try Data(contentsOf: restoreHooks) == foreign)
        #expect(try asideCopies().isEmpty)
        try foreign.write(to: hooksDirectory.appendingPathComponent("\(CopilotObserverRegistration.asidePrefix)crash"))
        try FileManager.default.removeItem(at: restoreHooks)
        #expect(throws: CopilotResourcePreparationFailure.self) { try local.installCMUXHooks() }
        #expect(try Data(contentsOf: restoreHooks) == foreign)
        #expect(try asideCopies().isEmpty)
        try FileManager.default.removeItem(at: restoreHooks)

        // The moved copy is rechecked right before deletion: bytes changed after the move go back.
        _ = try local.preparePlugin(root: integration, helper: executable, controller: controller, skill: skill)
        try local.installCMUXHooks()
        var rewriting = local
        let directoryPath = hooksDirectory
        rewriting.afterCMUXHooksMovedAside = {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryPath.path)) ?? []
            for name in names where name.contains(".removing-") {
                try? foreign.write(to: directoryPath.appendingPathComponent(name))
            }
        }
        #expect(try rewriting.removeMessaging(root: integration) == restoreHooks.path)
        #expect(try Data(contentsOf: restoreHooks) == foreign)
        #expect(try asideCopies().isEmpty)
        try FileManager.default.removeItem(at: restoreHooks)

        // A put-back whose directory sync fails says the file is back but durability is unconfirmed.
        _ = try local.preparePlugin(root: integration, helper: executable, controller: controller, skill: skill)
        try local.installCMUXHooks()
        try FileManager.default.removeItem(at: messaging)
        try FileManager.default.createDirectory(at: messaging.appendingPathComponent("blocker"), withIntermediateDirectories: true)
        var unsynced = local
        unsynced.syncDirectory = { _ in -1 }
        do {
            _ = try unsynced.removeMessaging(root: integration)
            Issue.record("A put-back that cannot be made durable must be reported")
        } catch let conflict as CopilotRegistrationConflict {
            #expect(conflict.message.contains("were put back at \(restoreHooks.path)"))
            #expect(conflict.message.contains("durable"))
        }
        #expect(try Data(contentsOf: restoreHooks) == CopilotCMUXHooks.manifest())
        #expect(try asideCopies().isEmpty)
        try FileManager.default.removeItem(at: messaging)
        // A foreign file put back whose directory sync fails says where it is back, and that durability is unconfirmed.
        try foreign.write(to: restoreHooks)
        var unsyncedPutBack = local
        unsyncedPutBack.syncDirectory = { _ in -1 }
        do {
            _ = try unsyncedPutBack.removeMessaging(root: integration)
            Issue.record("A put-back of a foreign file that cannot be made durable must be reported")
        } catch let conflict as CopilotRegistrationConflict {
            #expect(conflict.message.contains("put back at \(restoreHooks.path)"))
            #expect(conflict.message.contains("durable"))
        }
        #expect(try Data(contentsOf: restoreHooks) == foreign)
        #expect(try asideCopies().isEmpty)
        try CopilotCMUXHooks.manifest().write(to: restoreHooks)
        // Publish whose directory sync fails names the written file, separately from the rename.
        var unsyncedInstall = local
        unsyncedInstall.syncDirectory = { _ in -1 }
        do {
            try unsyncedInstall.installCMUXHooks()
            Issue.record("A publish that cannot be made durable must be reported")
        } catch let conflict as CopilotRegistrationConflict {
            #expect(conflict.message.contains("were updated at \(restoreHooks.path)"))
        }
        #expect(try Data(contentsOf: restoreHooks) == CopilotCMUXHooks.manifest())
        #expect(try asideCopies().isEmpty)
        #expect(try pendingCopies().isEmpty)
    }

    @Test func everyShippedCMUXHooksManifestIsOwnedAndLookAlikesAreNot() throws {
        let shipped = try CopilotCMUXHooks.shippedManifests()
        #expect(shipped.first == (try CopilotCMUXHooks.manifest()))
        #expect(shipped.allSatisfy(CopilotCMUXHooks.isOwned))
        var object = try CopilotSetupJSON.object(CopilotCMUXHooks.manifest())
        var maestro = try #require(object["maestro"] as? [String: Any])
        maestro["cmux"] = "0.0.0"
        object["maestro"] = maestro
        #expect(!CopilotCMUXHooks.isOwned(try CopilotSetupJSON.data(object)))
        // The commands were generated from this CMUX release; regenerate and append on any change.
        #expect(CopilotCMUXHooks.cmuxVersion == "0.65.1")
    }

    @Test func cmuxHookCommandFollowsCMUXGuards() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeCLI = directory.appendingPathComponent("cmux")
        let record = directory.appendingPathComponent("record")
        try Data("#!/bin/sh\nprintf '%s|%s' \"$*\" \"$CMUX_COPILOT_PID\" > \"\(record.path)\"\n".utf8).write(to: fakeCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        func run(_ environment: [String: String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", CopilotCMUXHooks.command("session-end")]
            process.environment = ["PATH": "/usr/bin:/bin", "CMUX_BUNDLED_CLI_PATH": fakeCLI.path].merging(environment) { _, new in new }
            let output = Pipe()
            process.standardOutput = output
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        #expect(try run([:]) == "{}\n")
        #expect(!FileManager.default.fileExists(atPath: record.path))
        #expect(try run(["CMUX_SURFACE_ID": "S", "CMUX_COPILOT_HOOKS_DISABLED": "1"]) == "{}\n")
        #expect(!FileManager.default.fileExists(atPath: record.path))
        _ = try run(["CMUX_SURFACE_ID": "S", "CMUX_COPILOT_PID": "4242"])
        #expect(try String(contentsOf: record, encoding: .utf8) == "hooks enqueue copilot session-end|4242")
        _ = try run(["CMUX_SURFACE_ID": "S", "CMUX_COPILOT_PID": "4242", "CMUX_SOCKET_PATH": "/synthetic.sock"])
        #expect(try String(contentsOf: record, encoding: .utf8) == "--socket /synthetic.sock hooks enqueue copilot session-end|4242")
    }
}

struct CopilotProcessQuiescenceTests {
    @Test func unkillableGroupStopsWaitingAtItsDeadline() {
        var polls = 0
        let stopped = LocalCopilotSetupRunner.waitForQuiescence(
            until: .now.advanced(by: .milliseconds(50)), pollInterval: 0.001
        ) { polls += 1; return false }
        #expect(!stopped)
        #expect(polls > 1)
    }

    private func seam(quiescent: @escaping (Int) -> Bool, signals: Box<[Int32]>, reaps: Box<Int>,
                      postKillGrace: TimeInterval = 0.05) -> LocalCopilotSetupRunner.GroupStopSeam {
        var seam = LocalCopilotSetupRunner.GroupStopSeam()
        let polls = Box(0)
        seam.signal = { _, signal in signals.value.append(signal); return 0 }
        seam.childUnavailable = { _ in false }
        seam.isQuiescent = { _ in polls.value += 1; return quiescent(polls.value) }
        seam.reap = { _ in reaps.value += 1 }
        seam.postKillGrace = postKillGrace
        return seam
    }

    @Test func stopGroupTimesOutWithinItsHardBoundIgnoringALargeCallerGraceAndDoesNotReap() {
        let signals = Box<[Int32]>([]), reaps = Box(0)
        // Quiescence is reported after SIGTERM's zero grace but never after SIGKILL.
        let started = ContinuousClock.now
        let stopped = LocalCopilotSetupRunner.stopGroup(
            4242, grace: 0, seam: seam(quiescent: { _ in false }, signals: signals, reaps: reaps))
        #expect(!stopped)
        #expect(signals.value == [SIGTERM, SIGKILL])
        #expect(reaps.value == 0)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func postKillBoundDoesNotGrowWithTheCallerGrace() {
        let signals = Box<[Int32]>([]), reaps = Box(0)
        let started = ContinuousClock.now
        // A caller grace of 0.2 s is consumed by the SIGTERM wait; the post-kill wait must
        // still use its own 0.05 s bound rather than max(grace, bound).
        let stopped = LocalCopilotSetupRunner.stopGroup(
            4242, grace: 0.2, seam: seam(quiescent: { _ in false }, signals: signals, reaps: reaps))
        #expect(!stopped)
        #expect(ContinuousClock.now - started < .milliseconds(400))
    }

    @Test func stopGroupReapsOnlyAfterQuiescence() {
        let signals = Box<[Int32]>([]), reaps = Box(0)
        let stopped = LocalCopilotSetupRunner.stopGroup(
            4242, grace: 0, seam: seam(quiescent: { $0 >= 3 }, signals: signals, reaps: reaps, postKillGrace: 5))
        #expect(stopped)
        #expect(reaps.value == 1)
    }

    @Test func quiescenceObservedBeforeTheDeadlineSucceeds() {
        var polls = 0
        let stopped = LocalCopilotSetupRunner.waitForQuiescence(
            until: .now.advanced(by: .seconds(5)), pollInterval: 0.001
        ) { polls += 1; return polls == 3 }
        #expect(stopped)
        #expect(polls == 3)
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
