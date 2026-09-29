import Darwin
import Foundation
import Testing
@testable import CMUXMaestroPreview

final class ObserverFixture: Sendable {
    let directory: URL
    let home: URL
    let root: URL
    let helper: URL
    var provider: URL { home.appendingPathComponent(".copilot") }
    var cache: URL { provider.appendingPathComponent("installed-plugins/_direct/plugin") }
    var source: URL { root.appendingPathComponent("plugin") }
    var file: URL { provider.appendingPathComponent("hooks/\(CopilotObserverRegistration.filename)") }
    var settings: URL { provider.appendingPathComponent("settings.json") }
    var helperRecord: URL { root.deletingLastPathComponent().appendingPathComponent("Orchestration/bin/identity-helper.json") }
    var registration: CopilotObserverRegistration {
        CopilotObserverRegistration(home: home, root: root, helper: helper,
                                    alternateHome: nil, processHome: home.path)
    }

    init() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        directory = repository.appendingPathComponent(".build/observer-tests/\(UUID().uuidString)")
        home = directory.appendingPathComponent("home")
        root = directory.appendingPathComponent("support/Copilot")
        helper = directory.appendingPathComponent("App/CMUXMaestroCopilotHook")
        for url in [home, provider, helper.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    }

    func clean() throws { try FileManager.default.removeItem(at: directory) }

    func write(_ object: [String: Any], to url: URL) throws {
        try write(CopilotSetupJSON.data(object), to: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func legacy(helper oldHelper: URL? = nil, disabled: Bool = false) throws {
        let selected = oldHelper ?? helper
        try write(["helper": selected.path], to: helperRecord)
        for directory in [source, cache] {
            for (name, data) in try CopilotPluginManifest.files(helper: selected, includeObserverHooks: true) {
                if name == "hooks.json", disabled {
                    var object = try CopilotSetupJSON.object(data)
                    object["disableAllHooks"] = true
                    try write(object, to: directory.appendingPathComponent(name))
                } else { try write(data, to: directory.appendingPathComponent(name)) }
            }
        }
    }

    func metadata(installed: Bool) throws -> CopilotSetupMetadata {
        var hooks: [CopilotSetupMetadata.Hook] = []
        for (url, origin, source) in [
            (file, "user", "hooks/\(CopilotObserverRegistration.filename)"),
            (cache.appendingPathComponent("hooks.json"), "plugin", CopilotPluginManifest.name),
        ] {
            if origin == "plugin", !installed { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let disabled = object["disableAllHooks"] as? Bool ?? false
            let events = (object["hooks"] as? [String: Any]) ?? [:]
            hooks += events.keys.map {
                CopilotSetupMetadata.Hook(hookType: $0, origin: origin, source: source, enabled: !disabled,
                                           disableKey: disabled ? nil : "provider-key-\($0)")
            }
        }
        return CopilotSetupMetadata(version: "1.0.88", protocolVersion: 3, hooks: hooks,
            plugins: installed ? [.init(name: CopilotPluginManifest.name, marketplace: "", enabled: true,
                                       directSourceId: "opaque-provider-source")] : [])
    }
}

struct ObserverSetupFiles: CopilotSetupFileSystem {
    let fixture: ObserverFixture
    var failPrepare = false
    var failRemoval = false
    func executable(selected: URL?, path: String) throws -> URL { fixture.helper }
    func preparePlugin(root: URL, helper: URL, controller: URL, skill: URL) throws -> URL {
        if failPrepare { throw CopilotFileError.io }
        try fixture.write(["helper": helper.path], to: fixture.helperRecord)
        return fixture.source
    }
    func removeMessaging(root: URL) throws {
        if failRemoval { throw CopilotFileError.io }
    }
}

actor ObserverSetupRunner: CopilotSetupProcessRunner {
    let fixture: ObserverFixture
    var installed: Bool
    var result: CopilotProcessResult = .exited(0)
    var calls: [[String]] = []
    var metadataCalls = 0
    var providerHomes: [URL?] = []
    var failingMetadataCall: Int?
    var invalidInstall = false
    var stagingEnabled = false
    var settingsEffect: String?
    private var writtenSettings: CopilotSetupFileState?

    init(_ fixture: ObserverFixture, installed: Bool = false) {
        self.fixture = fixture; self.installed = installed
    }
    func configure(result: CopilotProcessResult = .exited(0), failingMetadataCall: Int? = nil,
                   invalidInstall: Bool = false, stagingEnabled: Bool = false, settingsEffect: String? = nil) {
        self.result = result; self.failingMetadataCall = failingMetadataCall
        self.invalidInstall = invalidInstall; self.stagingEnabled = stagingEnabled
        self.settingsEffect = settingsEffect
    }
    func run(executable: URL, arguments: [String], path: String, providerHome: URL?) async -> CopilotProcessResult {
        providerHomes.append(providerHome)
        calls.append([executable.path] + arguments)
        guard result == .exited(0) else { return result }
        do {
            if arguments.contains("uninstall") { installed = false }
            else {
                installed = true
                for name in ["plugin.json", "hooks.json"] {
                    let data = try Data(contentsOf: fixture.source.appendingPathComponent(name))
                    try fixture.write(data, to: fixture.cache.appendingPathComponent(name))
                }
                if invalidInstall { try fixture.write(["version": 2, "hooks": [:]], to: fixture.cache.appendingPathComponent("hooks.json")) }
            }
            if let settingsEffect {
                var object: [String: Any] = [:]
                if FileManager.default.fileExists(atPath: fixture.settings.path) {
                    guard let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.settings)) as? [String: Any] else {
                        throw CMUXMaestroPreview.CopilotFileError.io
                    }
                    object = decoded
                }
                if object["enabledPlugins"] == nil { object["enabledPlugins"] = [String: Any]() }
                switch settingsEffect {
                case "disable-all": object["disableAllHooks"] = true
                case "disabled-keys": object["disabledHooks"] = ["new-user-choice"]
                case "unrelated": object["userNote"] = "concurrent change"
                case "plugin-map": object["enabledPlugins"] = ["other@marketplace": false]
                default: break
                }
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
                try data.write(to: fixture.settings, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.settings.path)
                writtenSettings = try CopilotSetupFileState.read(fixture.settings)
            }
            return result
        } catch { return .unavailable }
    }
    func metadata(executable: URL, path: String, providerHome: URL?) async -> CopilotMetadataResult {
        providerHomes.append(providerHome)
        metadataCalls += 1
        if metadataCalls == failingMetadataCall { return .failed(.unavailable) }
        do {
            var value = try fixture.metadata(installed: installed)
            if stagingEnabled, metadataCalls == 2 {
                value = CopilotSetupMetadata(version: value.version, protocolVersion: value.protocolVersion,
                    hooks: value.hooks.map { .init(hookType: $0.hookType, origin: $0.origin, source: $0.source,
                                                  enabled: true, disableKey: $0.disableKey) }, plugins: value.plugins)
            }
            return .value(value)
        } catch { return .failed(.unavailable) }
    }

    func settingsUnchangedSinceCLI() throws -> Bool {
        try CopilotSetupFileState.read(fixture.settings) == writtenSettings
    }
}

struct CopilotObserverRegistrationTests {
    func setup(_ fixture: ObserverFixture, runner: ObserverSetupRunner,
               files: ObserverSetupFiles? = nil) -> CopilotSetup {
        CopilotSetup(files: files ?? ObserverSetupFiles(fixture: fixture), runner: runner,
                     bundleIdentifier: CopilotSetupAccess.productionBundleIdentifier,
                     registration: fixture.registration)
    }
    func perform(_ setup: CopilotSetup, _ fixture: ObserverFixture, action: CopilotSetupAction = .install) async -> CopilotSetupResult {
        await setup.perform(action, selected: nil, path: "/usr/bin:/bin", root: fixture.root,
                            helper: fixture.helper, controller: fixture.helper, skill: fixture.helper)
    }

    @Test func freshInstallRegistersExactlyThreeEventsAndHooklessPlugin() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let runner = ObserverSetupRunner(fixture)
        #expect(fixture.registration.health() == .missing)
        #expect(await runner.calls.isEmpty)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installed)
        #expect(fixture.registration.health() == .currentOnDisk)
        let object = try CopilotSetupJSON.object(Data(contentsOf: fixture.file))
        #expect(Set((object["hooks"] as? [String: Any])?.keys.map { $0 } ?? []) == Set(CopilotPluginManifest.events))
        #expect(try CopilotSetupJSON.bool(object["disableAllHooks"]) == false)
        let plugin = try CopilotSetupJSON.object(Data(contentsOf: fixture.cache.appendingPathComponent("hooks.json")))
        #expect((plugin["hooks"] as? [String: Any])?.isEmpty == true)
        #expect(await runner.metadataCalls == 4)
        #expect(await runner.providerHomes.allSatisfy { $0?.path == fixture.provider.path })
    }

    @Test func legacyMigrationHasNoEnabledDuplicateAndPreservesWrapper() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        try fixture.legacy()
        let runner = ObserverSetupRunner(fixture, installed: true)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installed)
        let file = try CopilotSetupJSON.object(Data(contentsOf: fixture.file))
        let hooks = try #require(file["hooks"] as? [String: [[String: Any]]])
        for event in CopilotPluginManifest.events {
            #expect(hooks[event]?.first?["bash"] as? String == CopilotPluginManifest.command(helper: fixture.helper))
            #expect(hooks[event]?.first?["timeoutSec"] as? Int == 2)
        }
    }

    @Test(arguments: [["old-post-tool"], ["old-start", "unrelated-key"]])
    func refusesUnresolvableDisableKeysBeforeAnyLegacyMutation(keys: [String]) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        try fixture.legacy()
        try fixture.write(["disabledHooks": keys, "unrelated": ["keep": true]], to: fixture.settings)
        let old = try Data(contentsOf: fixture.source.appendingPathComponent("hooks.json"))
        let settings = try Data(contentsOf: fixture.settings)
        let runner = ObserverSetupRunner(fixture, installed: true)
        guard case .conflict(let reason) = await perform(setup(fixture, runner: runner), fixture) else {
            Issue.record("Expected an explicit key-resolution conflict"); return
        }
        #expect(reason.contains("destination keys"))
        #expect(try Data(contentsOf: fixture.settings) == settings)
        #expect(try Data(contentsOf: fixture.source.appendingPathComponent("hooks.json")) == old)
        #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
        #expect(await runner.calls.isEmpty)
    }

    @Test(arguments: [false, true])
    func preservesGlobalAndLegacyFileDisables(global: Bool) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        try fixture.legacy(disabled: !global)
        if global { try fixture.write(["disableAllHooks": true, "unrelated": "keep"], to: fixture.settings) }
        let settings = try CopilotSetupFileState.read(fixture.settings)
        let runner = ObserverSetupRunner(fixture, installed: true)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installedDisabled)
        #expect(fixture.registration.health() == .disabled)
        #expect(try CopilotSetupJSON.bool(CopilotSetupJSON.object(Data(contentsOf: fixture.file))["disableAllHooks"]))
        #expect(try CopilotSetupFileState.read(fixture.settings) == settings)
        if !global {
            #expect(try CopilotSetupJSON.bool(CopilotSetupJSON.object(
                Data(contentsOf: fixture.cache.appendingPathComponent("hooks.json")))["disableAllHooks"]))
        }
    }

    @Test(arguments: [false, true])
    func blanketDisableDoesNotBypassUnresolvedSubsetPreservation(global: Bool) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        try fixture.legacy(disabled: !global)
        try fixture.write(["disabledHooks": ["old-post-tool"], "disableAllHooks": global], to: fixture.settings)
        let old = try Data(contentsOf: fixture.cache.appendingPathComponent("hooks.json"))
        let runner = ObserverSetupRunner(fixture, installed: true)
        guard case .conflict = await perform(setup(fixture, runner: runner), fixture) else {
            Issue.record("A blanket disable must not erase subset intent on a later re-enable"); return
        }
        #expect(await runner.calls.isEmpty)
        #expect(try Data(contentsOf: fixture.cache.appendingPathComponent("hooks.json")) == old)
        #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
    }

    @Test func preservesOwnedFileDisableAndUnrelatedHooksWithoutChmod() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let runner = ObserverSetupRunner(fixture)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installed)
        var object = try CopilotSetupJSON.object(Data(contentsOf: fixture.file))
        object["disableAllHooks"] = true
        try fixture.write(object, to: fixture.file)
        let unrelated = fixture.file.deletingLastPathComponent().appendingPathComponent("other.json")
        try fixture.write(["version": 1, "hooks": ["sessionStart": [["type": "command", "bash": ":"]]]], to: unrelated)
        let saved = try Data(contentsOf: unrelated)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unrelated.deletingLastPathComponent().path)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installedDisabled)
        #expect(try Data(contentsOf: unrelated) == saved)
        #expect((try FileManager.default.attributesOfItem(atPath: unrelated.deletingLastPathComponent().path)[.posixPermissions] as? Int) == 0o755)
    }

    @Test func explicitDedicatedReenableDoesNotClearOldHooklessPluginFlag() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        try fixture.legacy(disabled: true)
        let runner = ObserverSetupRunner(fixture, installed: true)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installedDisabled)
        var object = try CopilotSetupJSON.object(Data(contentsOf: fixture.file))
        object["disableAllHooks"] = false
        try fixture.write(object, to: fixture.file)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installed)
        #expect(try CopilotSetupJSON.bool(CopilotSetupJSON.object(
            Data(contentsOf: fixture.cache.appendingPathComponent("hooks.json")))["disableAllHooks"]))
    }

    @Test(arguments: ["symlink", "hardlink", "modified", "foreign", "malformed", "duplicate-key", "unsafe-mode"])
    func rejectsUnownedOrUnsafeTarget(kind: String) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let runner = ObserverSetupRunner(fixture)
        if kind == "modified" {
            #expect(await perform(setup(fixture, runner: runner), fixture) == .installed)
        }
        switch kind {
        case "symlink":
            try fixture.write(["foreign": true], to: fixture.file)
            try FileManager.default.removeItem(at: fixture.file)
            try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: fixture.helper)
        case "hardlink":
            try fixture.write(["foreign": true], to: fixture.file)
            try #require(link(fixture.file.path, fixture.directory.appendingPathComponent("second-link").path) == 0)
        case "modified":
            var object = try CopilotSetupJSON.object(Data(contentsOf: fixture.file))
            object["extra"] = "foreign"
            try fixture.write(object, to: fixture.file)
        case "malformed": try fixture.write(Data("{broken".utf8), to: fixture.file)
        case "duplicate-key":
            try fixture.write(Data("{\"disableAllHooks\":true,\"disableAllHooks\":false}".utf8), to: fixture.settings)
        case "unsafe-mode":
            try fixture.write(["foreign": true], to: fixture.file)
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: fixture.file.path)
        default: try fixture.write(["version": 1, "hooks": [:]], to: fixture.file)
        }
        let before = await runner.calls.count
        guard case .conflict = await perform(setup(fixture, runner: runner), fixture) else {
            Issue.record("Unsafe target must refuse before installer"); return
        }
        #expect(await runner.calls.count == before)
    }

    @Test func rejectsAlternateHomeAndDuplicateObserverWithoutTouchingFiles() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let wrong = CopilotObserverRegistration(home: fixture.home, root: fixture.root, helper: fixture.helper,
                                               alternateHome: "/elsewhere", processHome: fixture.home.path)
        #expect(throws: CopilotRegistrationConflict.self) { try wrong.validateHome() }
        let duplicate = fixture.file.deletingLastPathComponent().appendingPathComponent("foreign-observer.json")
        try fixture.write(["version": 1, "hooks": CopilotPluginManifest.observerHooks(helper: fixture.helper)], to: duplicate)
        let runner = ObserverSetupRunner(fixture)
        guard case .conflict = await perform(setup(fixture, runner: runner), fixture) else {
            Issue.record("Duplicate source must refuse"); return
        }
        #expect(await runner.calls.isEmpty)
    }

    @Test(arguments: [CopilotProcessResult.exited(7), .timedOut, .cancelled])
    func failedPluginMutationRetainsDisabledStageAndLegacyForRetry(result: CopilotProcessResult) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let oldHelper = fixture.directory.appendingPathComponent("Previous.app/CMUXMaestroCopilotHook")
        try fixture.legacy(helper: oldHelper)
        let legacy = try Data(contentsOf: fixture.cache.appendingPathComponent("hooks.json"))
        let runner = ObserverSetupRunner(fixture, installed: true)
        await runner.configure(result: result)
        guard case .incomplete(.pluginPrepared, _) = await perform(setup(fixture, runner: runner), fixture) else {
            Issue.record("Expected explicit prepared-phase failure"); return
        }
        #expect(try Data(contentsOf: fixture.cache.appendingPathComponent("hooks.json")) == legacy)
        #expect(fixture.registration.health() == .disabled)
        await runner.configure()
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installedDisabled)
    }

    @Test(arguments: [1, 2, 3, 4])
    func metadataFailuresNeverMasqueradeAsSuccess(call: Int) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let runner = ObserverSetupRunner(fixture)
        await runner.configure(failingMetadataCall: call)
        let result = await perform(setup(fixture, runner: runner), fixture)
        if call == 1 { #expect(result == .unavailable) }
        else {
            guard case .incomplete = result else { Issue.record("Expected phase-aware failure"); return }
        }
        if call <= 2 { #expect(await runner.calls.isEmpty) }
        #expect(result != .installed)
    }

    @Test func rejectsUnconfirmedInactiveStageAndCLIInvalidSuccess() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let runner = ObserverSetupRunner(fixture)
        await runner.configure(stagingEnabled: true)
        guard case .incomplete(.staged, _) = await perform(setup(fixture, runner: runner), fixture) else {
            Issue.record("Unconfirmed stage must stop before plugin mutation"); return
        }
        #expect(await runner.calls.isEmpty)
        await runner.configure(invalidInstall: true)
        guard case .incomplete(.pluginPrepared, _) = await perform(setup(fixture, runner: runner), fixture) else {
            Issue.record("CLI exit zero is not registration proof"); return
        }
    }

    @Test func changedFilesInvalidateTransactionAndUninstallOnlyRemovesOwnedRegistration() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let metadata = try fixture.metadata(installed: false)
        let operation = try fixture.registration.begin(.install, metadata: metadata)
        try fixture.write(["disableAllHooks": true], to: fixture.settings)
        #expect(throws: CMUXMaestroPreview.CopilotFileError.changed) { try operation.stage() }
        #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
        let runner = ObserverSetupRunner(fixture)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installedDisabled)
        let settings = try Data(contentsOf: fixture.settings)
        #expect(await perform(setup(fixture, runner: runner), fixture, action: .uninstall) == .uninstalled)
        #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
        #expect(try Data(contentsOf: fixture.settings) == settings)
        #expect(fixture.registration.health() == .missing)
    }

    @Test(arguments: ["1.0.88", "1.0.89"])
    func metadataParserEnforcesFramingAndOutputBound(version: String) throws {
        let exchange = try CopilotMetadataExchange()
        defer { exchange.closeAll() }
        let responses: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "result": ["version": version, "protocolVersion": 3]],
            ["jsonrpc": "2.0", "id": 2, "result": ["hooks": [], "warnings": [], "errors": []]],
            ["jsonrpc": "2.0", "id": 3, "result": ["plugins": []]],
        ]
        for object in responses {
            let body = try JSONSerialization.data(withJSONObject: object)
            let header = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
            #expect(header.withUnsafeBytes { Darwin.write(exchange.output[1], $0.baseAddress, $0.count) } == header.count)
            try exchange.poll()
            #expect(body.withUnsafeBytes { Darwin.write(exchange.output[1], $0.baseAddress, $0.count) } == body.count)
            try exchange.poll()
        }
        #expect(exchange.snapshot?.supported == true)
        let invalid = try CopilotMetadataExchange()
        defer { invalid.closeAll() }
        let header = Data("Content-Length: \(CopilotMetadataExchange.maximumOutput + 1)\r\n\r\n".utf8)
        _ = header.withUnsafeBytes { Darwin.write(invalid.output[1], $0.baseAddress, $0.count) }
        #expect(throws: (any Error).self) { try invalid.poll() }
    }

    @Test(arguments: ["provider-symlink", "hooks-symlink", "receipt-hardlink", "unreadable", "directory-mode"])
    func rejectsUnsafeAncestorsAndProvenance(kind: String) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let runner = ObserverSetupRunner(fixture)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installed)
        switch kind {
        case "provider-symlink", "hooks-symlink":
            let target = kind == "provider-symlink" ? fixture.provider : fixture.file.deletingLastPathComponent()
            let saved = target.deletingLastPathComponent().appendingPathComponent("saved-\(target.lastPathComponent)")
            try FileManager.default.moveItem(at: target, to: saved)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: saved)
        case "receipt-hardlink":
            let receipt = fixture.root.appendingPathComponent(CopilotObserverRegistration.receiptName)
            try #require(link(receipt.path, fixture.directory.appendingPathComponent("receipt-alias").path) == 0)
        case "unreadable":
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.file.path)
        default:
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.file.deletingLastPathComponent().path)
        }
        let calls = await runner.calls.count
        guard case .conflict = await perform(setup(fixture, runner: runner), fixture) else {
            Issue.record("Unsafe ancestor/provenance must refuse"); return
        }
        #expect(await runner.calls.count == calls)
    }

    @Test func modifiedLegacyAndEnabledDuplicateAreNotSilentlyMigrated() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        try fixture.legacy()
        let cached = fixture.cache.appendingPathComponent("hooks.json")
        var changed = try CopilotSetupJSON.object(Data(contentsOf: cached))
        changed["foreign"] = true
        try fixture.write(changed, to: cached)
        let runner = ObserverSetupRunner(fixture, installed: true)
        guard case .conflict = await perform(setup(fixture, runner: runner), fixture) else {
            Issue.record("Modified legacy cache must refuse"); return
        }
        #expect(await runner.calls.isEmpty)
        try fixture.legacy()
        var reformatted = try Data(contentsOf: cached)
        reformatted.append(10)
        try fixture.write(reformatted, to: cached)
        guard case .conflict = await perform(setup(fixture, runner: runner), fixture) else {
            Issue.record("Legacy serialization is part of the owned-registration precondition"); return
        }
        #expect(await runner.calls.isEmpty)
        try fixture.legacy()
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installed)
        try fixture.legacy()
        guard case .conflict = await perform(setup(fixture, runner: runner), fixture) else {
            Issue.record("Enabled dual registration must refuse"); return
        }
    }

    @Test func changedCacheAfterVerificationPreventsActivation() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let operation = try fixture.registration.begin(.install, metadata: fixture.metadata(installed: false))
        try operation.stage()
        try operation.verifyStaging(fixture.metadata(installed: false))
        try fixture.write(["helper": fixture.helper.path], to: fixture.helperRecord)
        try operation.acceptPreparedResources()
        try operation.preparePluginManifest()
        for name in ["plugin.json", "hooks.json"] {
            try fixture.write(Data(contentsOf: fixture.source.appendingPathComponent(name)),
                              to: fixture.cache.appendingPathComponent(name))
        }
        try operation.verifyPlugin(fixture.metadata(installed: true))
        try fixture.write(["version": 1, "hooks": CopilotPluginManifest.observerHooks(helper: fixture.helper)],
                          to: fixture.cache.appendingPathComponent("hooks.json"))
        #expect(throws: CMUXMaestroPreview.CopilotFileError.changed) { try operation.publish() }
        #expect(try CopilotSetupJSON.bool(CopilotSetupJSON.object(Data(contentsOf: fixture.file))["disableAllHooks"]))
    }

    @Test func incompleteSourcePreparationAndResourceFailureRetryConservatively() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let runner = ObserverSetupRunner(fixture)
        let files = ObserverSetupFiles(fixture: fixture, failPrepare: true)
        guard case .incomplete(.staged, _) = await perform(setup(fixture, runner: runner, files: files), fixture) else {
            Issue.record("Resource failure must preserve staged phase"); return
        }
        let manifest = try #require(CopilotPluginManifest.files(helper: fixture.helper)["plugin.json"])
        try fixture.write(manifest, to: fixture.source.appendingPathComponent("plugin.json"))
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installedDisabled)
        let failure = ObserverSetupFiles(fixture: fixture, failRemoval: true)
        guard case .incomplete(.pluginRemoved, _) = await perform(
            setup(fixture, runner: runner, files: failure), fixture, action: .uninstall) else {
            Issue.record("Messaging removal must not conceal completed plugin removal"); return
        }
        #expect(await perform(setup(fixture, runner: runner), fixture, action: .uninstall) == .uninstalled)
    }

    @Test func currentKeysAndExistingSessionFilesRemainUntouched() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let runner = ObserverSetupRunner(fixture)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installed)
        try fixture.write(["disabledHooks": ["provider-key-postToolUse", "unrelated"]], to: fixture.settings)
        let settings = try Data(contentsOf: fixture.settings)
        let marker = fixture.provider.appendingPathComponent("session-state/retained/events.jsonl")
        try fixture.write(Data("existing-session-unchanged".utf8), to: marker)
        let before = try Data(contentsOf: fixture.file)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installed)
        #expect(try Data(contentsOf: fixture.file) == before)
        #expect(try Data(contentsOf: fixture.settings) == settings)
        #expect(try Data(contentsOf: marker) == Data("existing-session-unchanged".utf8))
    }

    @Test func unknownVersionAndDisabledOrForeignPluginIdentityRefuse() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        try fixture.legacy()
        let known = try fixture.metadata(installed: true)
        for metadata in [
            CopilotSetupMetadata(version: "1.0.90", protocolVersion: 3, hooks: known.hooks, plugins: known.plugins),
            CopilotSetupMetadata(version: "1.0.88", protocolVersion: 3, hooks: known.hooks,
                plugins: [.init(name: CopilotPluginManifest.name, marketplace: "", enabled: false, directSourceId: "opaque")]),
            CopilotSetupMetadata(version: "1.0.88", protocolVersion: 3, hooks: known.hooks,
                plugins: [.init(name: CopilotPluginManifest.name, marketplace: "foreign", enabled: true, directSourceId: nil)]),
        ] {
            #expect(throws: CopilotRegistrationConflict.self) { try fixture.registration.begin(.install, metadata: metadata) }
        }
        #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
    }

    @Test(arguments: [
        ("1.0.88", 3, true), ("1.0.89", 3, true),
        ("1.0.87", 3, false), ("1.0.90", 3, false), ("2.0.0", 3, false),
        ("1.0.89-preview", 3, false), ("1.0.89", 2, false), ("1.0.89", 4, false),
    ])
    func metadataAllowsOnlyExactTestedVersionProtocolPairs(version: String, protocolVersion: Int, expected: Bool) {
        let metadata = CopilotSetupMetadata(version: version, protocolVersion: protocolVersion, hooks: [], plugins: [])
        #expect(metadata.supported == expected)
    }

    @Test func staleHelperUpdatesOnlyWithoutUnresolvedDisableIntent() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let runner = ObserverSetupRunner(fixture)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installed)
        let moved = fixture.directory.appendingPathComponent("Moved.app/CMUXMaestroCopilotHook")
        let registration = CopilotObserverRegistration(home: fixture.home, root: fixture.root, helper: moved,
                                                       alternateHome: nil, processHome: fixture.home.path)
        #expect(registration.health() == .stale)
        let updated = CopilotSetup(files: ObserverSetupFiles(fixture: fixture), runner: runner,
                                   bundleIdentifier: CopilotSetupAccess.productionBundleIdentifier, registration: registration)
        try fixture.write(["disabledHooks": ["old-provider-key"]], to: fixture.settings)
        let before = try Data(contentsOf: fixture.file)
        guard case .conflict = await updated.perform(.install, selected: nil, path: "", root: fixture.root,
                helper: moved, controller: fixture.helper, skill: fixture.helper) else {
            Issue.record("Stale-helper key drift must not bypass disable intent"); return
        }
        #expect(try Data(contentsOf: fixture.file) == before)
        try fixture.write([:], to: fixture.settings)
        #expect(await updated.perform(.install, selected: nil, path: "", root: fixture.root,
                                      helper: moved, controller: fixture.helper, skill: fixture.helper) == .installed)
        #expect(registration.health() == .currentOnDisk)
        #expect(try String(contentsOf: fixture.file, encoding: .utf8).contains("Moved.app"))
    }

    @Test func interruptedRemovalRetainsOtherStateAndCanRetry() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let runner = ObserverSetupRunner(fixture)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installed)
        await runner.configure(result: .exited(9))
        guard case .incomplete(.registrationRemoved, _) = await perform(
            setup(fixture, runner: runner), fixture, action: .uninstall) else {
            Issue.record("Removal must expose its completed phase"); return
        }
        #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
        #expect(fixture.registration.health() == .incomplete)
        await runner.configure()
        #expect(await perform(setup(fixture, runner: runner), fixture, action: .uninstall) == .uninstalled)
    }

    @Test func sharedUnsafeCacheAncestorAndChangedParentAreRejected() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        try fixture.legacy()
        let unsafe = fixture.provider.appendingPathComponent("installed-plugins")
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: unsafe.path)
        #expect(throws: CMUXMaestroPreview.CopilotFileError.unsafePath) {
            try CopilotSetupFileState.read(fixture.cache.appendingPathComponent("hooks.json"))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unsafe.path)
        let file = fixture.source.appendingPathComponent("hooks.json")
        let snapshot = try CopilotSetupFileState.read(file)
        let saved = fixture.root.appendingPathComponent("plugin-saved")
        try FileManager.default.moveItem(at: fixture.source, to: saved)
        try FileManager.default.createSymbolicLink(at: fixture.source, withDestinationURL: saved)
        #expect(throws: (any Error).self) { try snapshot.replacing(with: Data("do not write".utf8)) }
        #expect(try Data(contentsOf: saved.appendingPathComponent("hooks.json")) == snapshot.data)
    }

    @Test func recordedProviderIdentityCannotBeSilentlyReplaced() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let runner = ObserverSetupRunner(fixture)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installed)
        let known = try fixture.metadata(installed: true)
        let changed = CopilotSetupMetadata(version: known.version, protocolVersion: known.protocolVersion,
            hooks: known.hooks, plugins: [.init(name: CopilotPluginManifest.name, marketplace: "",
                                               enabled: true, directSourceId: "different-provider-identity")])
        #expect(throws: CopilotRegistrationConflict.self) { try fixture.registration.begin(.install, metadata: changed) }
    }

    @Test func stagingWriteFailureReportsProvenanceRatherThanClaimingDisabledFile() async throws {
        let fixture = try ObserverFixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.file.deletingLastPathComponent().path)
            try? fixture.clean()
        }
        let runner = ObserverSetupRunner(fixture)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installed)
        let before = try Data(contentsOf: fixture.file)
        let calls = await runner.calls.count
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.file.deletingLastPathComponent().path)
        guard case .incomplete(.provenanceRecorded, _) = await perform(setup(fixture, runner: runner), fixture) else {
            Issue.record("Failed staging must not claim a disabled file was published"); return
        }
        #expect(try Data(contentsOf: fixture.file) == before)
        #expect(await runner.calls.count == calls)
    }

    @Test func simultaneousExplicitSetupCannotShareTheMutationLease() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let first = try fixture.registration.begin(.install, metadata: fixture.metadata(installed: false))
        try first.stage()
        let second = try fixture.registration.begin(.install, metadata: fixture.metadata(installed: false))
        #expect(throws: CopilotRegistrationConflict.self) { try second.stage() }
        try first.revalidate()
        #expect(first.phase == .staged)
        #expect(second.phase == .preflight)
    }

    @Test(arguments: ["host-relative", "absolute", "parent-component", "foreign-origin"])
    func providerSourceLabelsAreMatchedOnlyToTheExactOwnedFile(kind: String) throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let operation = try fixture.registration.begin(.install, metadata: fixture.metadata(installed: false))
        try operation.stage()
        let observed = try fixture.metadata(installed: false)
        let hooks = observed.hooks.map { hook in
            CopilotSetupMetadata.Hook(
                hookType: hook.hookType, origin: kind == "foreign-origin" ? "policy" : hook.origin,
                source: kind == "absolute" ? fixture.file.path
                    : kind == "parent-component" ? "hooks/../hooks/\(CopilotObserverRegistration.filename)" : hook.source,
                enabled: hook.enabled, disableKey: hook.disableKey)
        }
        let metadata = CopilotSetupMetadata(version: observed.version, protocolVersion: observed.protocolVersion,
                                            hooks: hooks, plugins: observed.plugins)
        if kind == "host-relative" || kind == "absolute" { try operation.verifyStaging(metadata) }
        else {
            #expect(throws: CopilotRegistrationConflict.self) { try operation.verifyStaging(metadata) }
        }
    }

    @Test func unrelatedPluginHooksSurviveAndForeignObserverPluginRefuses() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let directory = fixture.provider.appendingPathComponent("installed-plugins/community/other")
        try fixture.write(["name": "other", "hooks": "hooks.json"], to: directory.appendingPathComponent("plugin.json"))
        let hooks = directory.appendingPathComponent("hooks.json")
        try fixture.write(["version": 1, "hooks": ["postToolUse": [["type": "command", "bash": ":"]]]], to: hooks)
        let metadata = CopilotSetupMetadata(version: "1.0.88", protocolVersion: 3,
            hooks: [.init(hookType: "postToolUse", origin: "plugin", source: "other@community", enabled: true, disableKey: "opaque")],
            plugins: [.init(name: "other", marketplace: "community", enabled: true, directSourceId: nil)])
        let before = try Data(contentsOf: hooks)
        _ = try fixture.registration.begin(.install, metadata: metadata)
        #expect(try Data(contentsOf: hooks) == before)
        try fixture.write(["version": 1, "hooks": CopilotPluginManifest.observerHooks(helper: fixture.helper)], to: hooks)
        #expect(throws: CopilotRegistrationConflict.self) { try fixture.registration.begin(.install, metadata: metadata) }
    }

    @Test func metadataProcessUsesSupervisorForSuccessTimeoutAndMalformedOutput() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let server = fixture.directory.appendingPathComponent("metadata-server")
        let responses = fixture.directory.appendingPathComponent("responses")
        var content = Data()
        let replies: [(Int, [String: Any])] = [
            (1, ["version": "1.0.88", "protocolVersion": 3]),
            (2, ["hooks": [], "warnings": [], "errors": []]),
            (3, ["plugins": []]),
        ]
        for (id, result) in replies {
            let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
            content.append(Data("Content-Length: \(body.count)\r\n\r\n".utf8)); content.append(body)
        }
        try fixture.write(content, to: responses)
        func script(_ body: String) throws {
            try fixture.write(Data("#!/bin/sh\n\(body)\n".utf8), to: server)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        }
        try script("/bin/cat \(CopilotPluginManifest.shellQuoted(responses.path))\n/bin/cat >/dev/null")
        let runner = LocalCopilotSetupRunner(timeout: 2)
        guard case .value(let metadata) = await runner.metadata(executable: server, path: "/usr/bin:/bin") else {
            Issue.record("Expected bounded metadata response"); return
        }
        #expect(metadata.supported)
        try script("printf 'Content-Length: 999999\\r\\n\\r\\n'\n/bin/cat >/dev/null")
        guard case .failed(.unavailable) = await runner.metadata(executable: server, path: "/usr/bin:/bin") else {
            Issue.record("Oversized metadata must fail closed"); return
        }
        try script("trap '' TERM\n/bin/sleep 10 &\nwait")
        let short = LocalCopilotSetupRunner(timeout: 0.1, terminationGrace: 0.02)
        guard case .failed(.timedOut) = await short.metadata(executable: server, path: "/usr/bin:/bin") else {
            Issue.record("Metadata must retain supervised deadline"); return
        }
    }

    @Test(arguments: [Duration.zero, .seconds(4)])
    func cancellingMetadataStopsItsOwnedProcessBeforeReturning(launchDelay: Duration) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let server = fixture.directory.appendingPathComponent("metadata-waiter")
        let ready = fixture.directory.appendingPathComponent("metadata.pid")
        let command = "#!/bin/sh\nprintf '%s' $$ > \(CopilotPluginManifest.shellQuoted(ready.path))\ntrap '' TERM\n/bin/cat >/dev/null\n"
        try fixture.write(Data(command.utf8), to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let clock = SetupDeadlineClock()
        let runner = LocalCopilotSetupRunner(terminationGrace: 0.02, deadlineNow: { clock.now() })
        let task = Task {
            defer { clock.finishStartup() }
            do { try await Task.sleep(for: launchDelay) }
            catch is CancellationError { return CopilotMetadataResult.failed(.cancelled) }
            catch { Issue.record(error); return CopilotMetadataResult.failed(.unavailable) }
            return await runner.metadata(executable: server, path: "/usr/bin:/bin")
        }
        defer { task.cancel() }
        let started = await clock.waitForStartup()
        if !started {
            let stopped = await task.value
            Issue.record("Metadata did not spawn; result=\(stopped)")
            return
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let readyExists = FileManager.default.fileExists(atPath: ready.path)
        if !readyExists {
            task.cancel()
            let stopped = await task.value
            Issue.record("Metadata writer was not ready after spawn; result=\(stopped); sampled=\(clock.wasSampled)")
        }
        try #require(readyExists)
        let pid = try #require(Int32(String(contentsOf: ready, encoding: .utf8)))
        task.cancel()
        guard case .failed(.cancelled) = await task.value else {
            Issue.record("Expected metadata cancellation"); return
        }
        #expect(HookProcess.current(pid) == nil)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func registrationErrorsHaveTheAppModuleIdentity() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.provider.path)
        do {
            _ = try CopilotSetupFileState.read(fixture.settings)
            Issue.record("Expected the setup adapter's unsafe-path rejection")
        } catch {
            let expected = String(reflecting: CMUXMaestroPreview.CopilotFileError.self)
            let actual = String(reflecting: type(of: error))
            print("H114_ERROR_TYPES local=\(String(reflecting: CopilotFileError.self)) app=\(expected) thrown=\(actual)")
            #expect(actual == expected)
            #expect(error as? CMUXMaestroPreview.CopilotFileError == .unsafePath)
        }
    }

    @Test(arguments: ["absent", "empty", "unrelated", "plugin-map"])
    func successfulCLISettingsRewritePreservesAllIntent(initial: String) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        var original: [String: Any] = [:]
        if initial == "unrelated" { original["userNote"] = ["preserve": true] }
        if initial == "plugin-map" { original["enabledPlugins"] = ["other@marketplace": false] }
        if initial != "absent" { try fixture.write(original, to: fixture.settings) }
        let runner = ObserverSetupRunner(fixture)
        await runner.configure(settingsEffect: "cli-rewrite")
        let setup = setup(fixture, runner: runner)
        for action: CopilotSetupAction in [.install, .install, .uninstall] {
            #expect(await perform(setup, fixture, action: action) == (action == .install ? .installed : .uninstalled))
            #expect(try await runner.settingsUnchangedSinceCLI())
        }
        var expected = original
        if expected["enabledPlugins"] == nil { expected["enabledPlugins"] = [String: Any]() }
        #expect(try CopilotSetupJSON.data(CopilotSetupJSON.object(Data(contentsOf: fixture.settings)))
            == CopilotSetupJSON.data(expected))
    }

    @Test(arguments: ["disable-all", "disabled-keys", "unrelated", "plugin-map"])
    func unexpectedCLIWindowSettingsChangesStillRefuse(effect: String) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        try fixture.write([:], to: fixture.settings)
        let runner = ObserverSetupRunner(fixture)
        await runner.configure(settingsEffect: effect)
        guard case .incomplete(.pluginPrepared, _) = await perform(setup(fixture, runner: runner), fixture) else {
            Issue.record("Changed disable or unrelated intent must not be accepted as CLI normalization"); return
        }
        #expect(try await runner.settingsUnchangedSinceCLI())
        #expect(try CopilotSetupJSON.bool(CopilotSetupJSON.object(Data(contentsOf: fixture.file))["disableAllHooks"]))
    }

    @Test func CLISettingsReconciliationRequiresTheExplicitCommandBoundary() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let operation = try fixture.registration.begin(.install, metadata: fixture.metadata(installed: false))
        #expect(throws: CMUXMaestroPreview.CopilotFileError.io) { try operation.pluginCommandSucceeded() }
    }

    @Test func fileWorkLeavesTheCooperativeExecutorAndJoinsCancelledWriter() async throws {
        let context = try await CopilotSetupFileWork.run {
            (Thread.isMainThread, withUnsafeCurrentTask { $0 == nil })
        }
        #expect(!context.0)
        #expect(context.1)
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let file = fixture.directory.appendingPathComponent("in-flight-write")
        let task = Task {
            do {
                try await CopilotSetupFileWork.run {
                    started.continuation.yield(())
                    started.continuation.finish()
                    gate.wait()
                    try Data("writer-finished".utf8).write(to: file)
                }
                return false
            } catch is CancellationError { return true }
            catch { Issue.record(error); return false }
        }
        for await _ in started.stream { break }
        task.cancel()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        gate.signal()
        #expect(await task.value)
        #expect(try String(contentsOf: file, encoding: .utf8) == "writer-finished")
    }
}
