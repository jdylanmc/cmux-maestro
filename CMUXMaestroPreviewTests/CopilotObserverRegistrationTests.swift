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
        let settingsObject = FileManager.default.fileExists(atPath: settings.path)
            ? try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any] : nil
        let disabledKeys = settingsObject?["disabledHooks"] as? [String] ?? []
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
                CopilotSetupMetadata.Hook(hookType: $0, origin: origin, source: source,
                                           enabled: !disabled && !disabledKeys.contains("provider-key-\($0)"),
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
    var cancelDuringStaging = false
    var settingsEffect: String?
    private var writtenSettings: CopilotSetupFileState?
    private var ownedRowsOverride: [CopilotSetupMetadata.Hook]?
    private var unrelatedRows: [CopilotSetupMetadata.Hook] = []
    private var unrelatedPlugins: [CopilotSetupMetadata.Plugin] = []
    private var suppliedVersion: String?

    init(_ fixture: ObserverFixture, installed: Bool = false) {
        self.fixture = fixture; self.installed = installed
    }
    func configure(result: CopilotProcessResult = .exited(0), failingMetadataCall: Int? = nil,
                   invalidInstall: Bool = false, stagingEnabled: Bool = false, settingsEffect: String? = nil,
                   cancelDuringStaging: Bool = false) {
        self.result = result; self.failingMetadataCall = failingMetadataCall
        self.invalidInstall = invalidInstall; self.stagingEnabled = stagingEnabled
        self.settingsEffect = settingsEffect
        self.cancelDuringStaging = cancelDuringStaging
    }
    func supplyMetadata(owned: [CopilotSetupMetadata.Hook]? = nil, unrelated: [CopilotSetupMetadata.Hook] = [],
                        plugins: [CopilotSetupMetadata.Plugin] = [], version: String? = nil) {
        ownedRowsOverride = owned
        unrelatedRows = unrelated
        unrelatedPlugins = plugins
        suppliedVersion = version
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
        if cancelDuringStaging, metadataCalls == 2 {
            withUnsafeCurrentTask { $0?.cancel() }
            return .failed(.cancelled)
        }
        if metadataCalls == failingMetadataCall { return .failed(.unavailable) }
        do {
            var value = try fixture.metadata(installed: installed)
            if stagingEnabled, metadataCalls == 2 {
                value = CopilotSetupMetadata(version: value.version, protocolVersion: value.protocolVersion,
                    hooks: value.hooks.map { .init(hookType: $0.hookType, origin: $0.origin, source: $0.source,
                                                  enabled: true, disableKey: $0.disableKey) }, plugins: value.plugins)
            }
            var rows = value.hooks
            let staged = rows.contains { $0.origin == "user" && !$0.enabled && $0.disableKey == nil }
            if let ownedRowsOverride, !staged, rows.contains(where: { $0.origin == "user" }) {
                rows = ownedRowsOverride
            }
            value = CopilotSetupMetadata(version: suppliedVersion ?? value.version, protocolVersion: value.protocolVersion,
                                        hooks: rows + unrelatedRows, plugins: value.plugins + unrelatedPlugins)
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
        #expect(fixture.registration.health() == .incomplete)
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
        if call == 2 {
            #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
            #expect(try CopilotSetupFileState.read(
                fixture.root.appendingPathComponent(CopilotObserverRegistration.receiptName)).data == nil)
            #expect(result.message.contains("restored and verified"))
            #expect(fixture.registration.health() == .missing)
        }
    }

    @Test func failedStagingRestoresPreviousEnabledRegistrationAndPermissions() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let runner = ObserverSetupRunner(fixture)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installed)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.file.path)
        let original = try CopilotSetupFileState.read(fixture.file)
        let receiptURL = fixture.root.appendingPathComponent(CopilotObserverRegistration.receiptName)
        let receipt = try CopilotSetupFileState.read(receiptURL)
        let calls = await runner.calls.count
        await runner.configure(failingMetadataCall: await runner.metadataCalls + 2)
        let result = await perform(setup(fixture, runner: runner), fixture)
        #expect(result.message.contains("restored and verified"))
        #expect(await runner.calls.count == calls)
        #expect(try CopilotSetupFileState.read(fixture.file).data == original.data)
        #expect(try CopilotSetupFileState.read(fixture.file).stamp?.permissions == 0o640)
        #expect(try CopilotSetupFileState.read(receiptURL).data == receipt.data)
        #expect(fixture.registration.health() == .currentOnDisk)
    }

    @Test func stagingRestorationRefusesConcurrentOwnedFileReplacement() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let operation = try fixture.registration.begin(.install, metadata: fixture.metadata(installed: false))
        try operation.stage()
        try fixture.write(["foreign": "preserve"], to: fixture.file)
        let foreign = try CopilotSetupFileState.read(fixture.file)
        #expect(throws: CMUXMaestroPreview.CopilotFileError.changed) { try operation.restoreStaging() }
        #expect(try CopilotSetupFileState.read(fixture.file) == foreign)
    }

    @Test func cancellationWaitsForStagingAbsenceRestoration() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let runner = ObserverSetupRunner(fixture)
        await runner.configure(cancelDuringStaging: true)
        let service = setup(fixture, runner: runner)
        let task = Task {
            await service.perform(.install, selected: nil, path: "", root: fixture.root,
                                  helper: fixture.helper, controller: fixture.helper, skill: fixture.helper)
        }
        let result = await task.value
        #expect(task.isCancelled)
        #expect(result.message.contains("restored and verified"))
        #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
        #expect(fixture.registration.health() == .missing)
        #expect(await runner.calls.isEmpty)
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
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installedDisableUnresolved)
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

    @Test(arguments: [false, true])
    func unrelatedSymlinkDoesNotBlockCompleteOverlappingPluginInventory(legacy: Bool) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        if legacy { try fixture.legacy() }
        let directory = fixture.provider.appendingPathComponent("installed-plugins/_direct/maestro-cmux")
        try fixture.write(["name": "maestro-cmux", "hooks": "hooks.json"], to: directory.appendingPathComponent("plugin.json"))
        let hooks = directory.appendingPathComponent("hooks.json")
        try fixture.write(["version": 1, "hooks": ["postToolUse": [["type": "command", "bash": ":"]]]], to: hooks)
        let target = fixture.directory.appendingPathComponent("unrelated-target")
        try fixture.write(["name": "unrelated-harness", "hooks": "hooks.json"], to: target.appendingPathComponent("plugin.json"))
        try fixture.write(["version": 1, "hooks": CopilotPluginManifest.observerHooks(helper: fixture.helper)],
                          to: target.appendingPathComponent("hooks.json"))
        let link = fixture.provider.appendingPathComponent("installed-plugins/_direct/example-org--unrelated-harness")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let targetFiles = ["plugin.json", "hooks.json"].map { target.appendingPathComponent($0) }
        let saved = try targetFiles.map { try Data(contentsOf: $0) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: target.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path) }
        let runner = ObserverSetupRunner(fixture, installed: legacy)
        await runner.supplyMetadata(
            unrelated: [.init(hookType: "postToolUse", origin: "plugin", source: "maestro-cmux", enabled: true, disableKey: "other-key")],
            plugins: [
                .init(name: "maestro-cmux", marketplace: "", enabled: true, directSourceId: "legacy-source"),
                .init(name: "unrelated-harness", marketplace: "", enabled: true, directSourceId: "unrelated-source"),
            ], version: "1.0.89")
        let setup = setup(fixture, runner: runner)
        #expect(await perform(setup, fixture) == .installed)
        #expect(await perform(setup, fixture) == .installed)
        let movedHelper = fixture.directory.appendingPathComponent("Updated.app/CMUXMaestroCopilotHook")
        let movedRegistration = CopilotObserverRegistration(home: fixture.home, root: fixture.root, helper: movedHelper,
                                                            alternateHome: nil, processHome: fixture.home.path)
        let update = CopilotSetup(files: ObserverSetupFiles(fixture: fixture), runner: runner,
            bundleIdentifier: CopilotSetupAccess.productionBundleIdentifier, registration: movedRegistration)
        #expect(await update.perform(.install, selected: nil, path: "", root: fixture.root, helper: movedHelper,
                                     controller: fixture.helper, skill: fixture.helper) == .installed)
        #expect(movedRegistration.health() == .currentOnDisk)
        #expect(await perform(setup, fixture, action: .uninstall) == .uninstalled)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int) == 0o000)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        #expect(try targetFiles.map { try Data(contentsOf: $0) } == saved)
        #expect(try CopilotSetupJSON.object(Data(contentsOf: hooks))["version"] as? Int == 1)
    }

    private func overlappingMetadata(_ fixture: ObserverFixture, marketplace: String = "") throws -> CopilotSetupMetadata {
        let group = marketplace.isEmpty ? "_direct" : marketplace
        let directory = fixture.provider.appendingPathComponent("installed-plugins/\(group)/maestro-cmux")
        try fixture.write(["name": "maestro-cmux", "hooks": "hooks.json"], to: directory.appendingPathComponent("plugin.json"))
        try fixture.write(["version": 1, "hooks": ["postToolUse": [["type": "command", "bash": ":"]]]],
                          to: directory.appendingPathComponent("hooks.json"))
        let label = marketplace.isEmpty ? "maestro-cmux" : "maestro-cmux@\(marketplace)"
        return CopilotSetupMetadata(version: "1.0.89", protocolVersion: 3,
            hooks: [.init(hookType: "postToolUse", origin: "plugin", source: label, enabled: true, disableKey: "unrelated-key")],
            plugins: [.init(name: "maestro-cmux", marketplace: marketplace, enabled: true,
                            directSourceId: marketplace.isEmpty ? "source-one" : nil)])
    }

    @Test(arguments: ["live", "builtin", "not-installed"])
    func providerProvenanceCannotBeSubstitutedWithSafeStaleCache(kind: String) throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let metadata = try overlappingMetadata(fixture, marketplace: "community")
        let hidden = fixture.directory.appendingPathComponent("active-marketplace")
        try fixture.write(["name": "maestro-cmux", "hooks": CopilotPluginManifest.observerHooks(helper: fixture.helper)],
                          to: hidden.appendingPathComponent("plugin.json"))
        var object: [String: Any] = ["name": "maestro-cmux", "marketplace": "community", "enabled": true]
        if kind == "live" { object["installedFrom"] = hidden.path }
        if kind == "builtin" { object["source"] = "builtin" }
        if kind == "not-installed" { object["managed"] = true; object["installed"] = false }
        let plugin = try JSONDecoder().decode(CopilotSetupMetadata.Plugin.self,
                                             from: JSONSerialization.data(withJSONObject: object))
        let selected = CopilotSetupMetadata(version: "1.0.89", protocolVersion: 3,
                                            hooks: metadata.hooks, plugins: [plugin])
        let cached = fixture.provider.appendingPathComponent("installed-plugins/community/maestro-cmux/hooks.json")
        let before = try CopilotSetupFileState.read(cached)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: hidden.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hidden.path) }
        #expect(throws: CopilotRegistrationConflict.self) { try fixture.registration.begin(.install, metadata: selected) }
        #expect(try CopilotSetupFileState.read(cached) == before)
        #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
        #expect((try FileManager.default.attributesOfItem(atPath: hidden.path)[.posixPermissions] as? Int) == 0o000)
    }

    @Test func providerProvenanceChangeInvalidatesAnAlreadyStagedInventory() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let original = try overlappingMetadata(fixture, marketplace: "community")
        let operation = try fixture.registration.begin(.install, metadata: original)
        try operation.stage()
        let staged = try fixture.metadata(installed: false)
        let changed = CopilotSetupMetadata(version: "1.0.89", protocolVersion: 3,
            hooks: original.hooks + staged.hooks,
            plugins: [.init(name: "maestro-cmux", marketplace: "community", enabled: true,
                            directSourceId: nil, installedFrom: fixture.directory.path)])
        #expect(throws: CopilotRegistrationConflict.self) { try operation.verifyStaging(changed) }
        #expect(operation.phase == .staged)
    }

    @Test func providerMetadataRetainsAllSourceAndManagedFields() throws {
        let data = try CopilotSetupJSON.data([
            "name": "other", "marketplace": "community", "enabled": false,
            "directSourceId": "opaque", "installedFrom": "/marketplace", "source": "builtin",
            "managed": true, "managedDesiredEnabled": false, "installed": false,
        ])
        let value = try JSONDecoder().decode(CopilotSetupMetadata.Plugin.self, from: data)
        #expect(value.directSourceId == "opaque")
        #expect(value.installedFrom == "/marketplace")
        #expect(value.source == "builtin")
        #expect(value.managed == true)
        #expect(value.managedDesiredEnabled == false)
        #expect(value.installed == false)
        #expect(!value.usesInstalledCache)
        #expect(!value.isUnmanagedDirectInstall)
    }

    @Test(arguments: ["live", "builtin", "managed", "not-installed"])
    func ownPluginCannotAdoptForeignProviderProvenance(kind: String) throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        try fixture.legacy()
        let known = try fixture.metadata(installed: true)
        let plugin = CopilotSetupMetadata.Plugin(
            name: CopilotPluginManifest.name, marketplace: "", enabled: true,
            directSourceId: "opaque-provider-source",
            installedFrom: kind == "live" ? fixture.directory.path : nil,
            source: kind == "builtin" ? "builtin" : nil,
            managed: kind == "managed" ? true : nil,
            installed: kind == "not-installed" ? false : nil)
        let before = try CopilotSetupFileState.read(fixture.cache.appendingPathComponent("hooks.json"))
        let value = CopilotSetupMetadata(version: "1.0.89", protocolVersion: 3,
                                        hooks: known.hooks, plugins: [plugin])
        #expect(throws: CopilotRegistrationConflict.self) { try fixture.registration.begin(.install, metadata: value) }
        #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
        #expect(try CopilotSetupFileState.read(before.url) == before)
    }

    @Test func unrelatedMarketplaceSymlinkIsNotAnInspectedSource() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let metadata = try overlappingMetadata(fixture)
        let target = fixture.directory.appendingPathComponent("unreadable-marketplace")
        try fixture.write(["name": "hidden", "hooks": CopilotPluginManifest.observerHooks(helper: fixture.helper)],
                          to: target.appendingPathComponent("plugin.json"))
        let linkedGroup = fixture.provider.appendingPathComponent("installed-plugins/unrelated-marketplace")
        try FileManager.default.createSymbolicLink(at: linkedGroup, withDestinationURL: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: target.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path) }
        _ = try fixture.registration.begin(.install, metadata: metadata)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkedGroup.path) == target.path)
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int) == 0o000)
    }

    @Test func relevantMarketplaceStillRequiresSafeCompleteUniqueIdentity() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let metadata = try overlappingMetadata(fixture, marketplace: "community")
        let group = fixture.provider.appendingPathComponent("installed-plugins/community")
        let irrelevantTarget = fixture.directory.appendingPathComponent("unreadable-irrelevant")
        try FileManager.default.createDirectory(at: irrelevantTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: group.appendingPathComponent("unrelated-link"), withDestinationURL: irrelevantTarget)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: irrelevantTarget.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: irrelevantTarget.path) }
        _ = try fixture.registration.begin(.install, metadata: metadata)
        let duplicate = CopilotSetupMetadata(version: metadata.version, protocolVersion: metadata.protocolVersion,
            hooks: metadata.hooks, plugins: metadata.plugins + metadata.plugins)
        #expect(throws: CopilotRegistrationConflict.self) { try fixture.registration.begin(.install, metadata: duplicate) }
        let saved = fixture.provider.appendingPathComponent("saved-community")
        try FileManager.default.moveItem(at: group, to: saved)
        try FileManager.default.createSymbolicLink(at: group, withDestinationURL: saved)
        #expect(throws: CopilotRegistrationConflict.self) { try fixture.registration.begin(.install, metadata: metadata) }
    }

    @Test(arguments: [
        "relevant-plugin-link", "relevant-group-link", "hook-link", "unreadable-hooks",
        "missing-identity", "duplicate-identity", "duplicate-manifest", "missing-hooks", "missing-event",
        "aliased-relevant-link", "hidden-observer-link",
    ])
    func overlappingInventoryRefusesUnresolvedUnsafeAndAmbiguousSources(scenario: String) throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        var metadata = try overlappingMetadata(fixture)
        let group = fixture.provider.appendingPathComponent("installed-plugins/_direct")
        let plugin = group.appendingPathComponent("maestro-cmux")
        let target = fixture.directory.appendingPathComponent("link-target")
        try fixture.write(["name": "maestro-cmux", "hooks": "hooks.json"], to: target.appendingPathComponent("plugin.json"))
        try fixture.write(["version": 1, "hooks": CopilotPluginManifest.observerHooks(helper: fixture.helper)],
                          to: target.appendingPathComponent("hooks.json"))
        let targetBytes = try Data(contentsOf: target.appendingPathComponent("hooks.json"))
        if scenario == "relevant-plugin-link" || scenario == "aliased-relevant-link" {
            if scenario == "aliased-relevant-link" {
                try FileManager.default.copyItem(at: plugin, to: group.appendingPathComponent("safe-alias"))
            }
            try FileManager.default.removeItem(at: plugin)
            try FileManager.default.createSymbolicLink(at: plugin, withDestinationURL: target)
        } else if scenario == "relevant-group-link" {
            let saved = fixture.provider.appendingPathComponent("saved-direct")
            try FileManager.default.moveItem(at: group, to: saved)
            try FileManager.default.createSymbolicLink(at: group, withDestinationURL: target)
        } else if scenario == "hook-link" {
            try FileManager.default.removeItem(at: plugin.appendingPathComponent("hooks.json"))
            try FileManager.default.createSymbolicLink(at: plugin.appendingPathComponent("hooks.json"),
                                                       withDestinationURL: target.appendingPathComponent("hooks.json"))
        } else if scenario == "unreadable-hooks" {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: plugin.appendingPathComponent("hooks.json").path)
        } else if scenario == "missing-identity" {
            metadata = CopilotSetupMetadata(version: metadata.version, protocolVersion: 3, hooks: metadata.hooks, plugins: [])
        } else if scenario == "duplicate-identity" {
            metadata = CopilotSetupMetadata(version: metadata.version, protocolVersion: 3, hooks: metadata.hooks,
                plugins: metadata.plugins + [.init(name: "maestro-cmux", marketplace: "", enabled: true, directSourceId: "source-two")])
        } else if scenario == "duplicate-manifest" {
            try FileManager.default.copyItem(at: plugin, to: group.appendingPathComponent("duplicate-alias"))
        } else if scenario == "missing-hooks" {
            try FileManager.default.removeItem(at: plugin.appendingPathComponent("hooks.json"))
        } else if scenario == "missing-event" {
            try fixture.write(["version": 1, "hooks": ["sessionStart": [["type": "command", "bash": ":"]]]],
                              to: plugin.appendingPathComponent("hooks.json"))
        } else {
            let link = group.appendingPathComponent("example-org--unrelated-harness")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            metadata = CopilotSetupMetadata(version: metadata.version, protocolVersion: 3,
                hooks: metadata.hooks + [.init(hookType: "postToolUse", origin: "plugin", source: "unrelated-harness",
                                               enabled: true, disableKey: "hidden-key")],
                plugins: metadata.plugins + [.init(name: "unrelated-harness", marketplace: "", enabled: true, directSourceId: "hidden-source")])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: target.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path) }
        #expect(throws: (any Error).self) { try fixture.registration.begin(.install, metadata: metadata) }
        #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int) == 0o000)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        #expect(try Data(contentsOf: target.appendingPathComponent("hooks.json")) == targetBytes)
    }

    @Test(arguments: ["directory-link", "new-duplicate", "changed-identity", "new-relevant-source"])
    func overlappingInventoryRevalidatesAcrossDisabledStaging(change: String) throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let metadata = try overlappingMetadata(fixture)
        let operation = try fixture.registration.begin(.install, metadata: metadata)
        let group = fixture.provider.appendingPathComponent("installed-plugins/_direct")
        let plugin = group.appendingPathComponent("maestro-cmux")
        if change == "directory-link" {
            let moved = fixture.directory.appendingPathComponent("moved-plugin")
            try FileManager.default.moveItem(at: plugin, to: moved)
            try FileManager.default.createSymbolicLink(at: plugin, withDestinationURL: moved)
            #expect(throws: (any Error).self) { try operation.stage() }
            #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
            return
        }
        try operation.stage()
        let staged = try fixture.metadata(installed: false)
        var plugins = metadata.plugins
        var hooks = metadata.hooks
        if change == "new-duplicate" {
            try FileManager.default.copyItem(at: plugin, to: group.appendingPathComponent("new-alias"))
        } else if change == "changed-identity" {
            plugins = [.init(name: "maestro-cmux", marketplace: "", enabled: true, directSourceId: "replaced-source")]
        } else {
            let target = fixture.directory.appendingPathComponent("hidden-target")
            try fixture.write(["name": "hidden", "hooks": CopilotPluginManifest.observerHooks(helper: fixture.helper)],
                              to: target.appendingPathComponent("plugin.json"))
            try FileManager.default.createSymbolicLink(at: group.appendingPathComponent("hidden"), withDestinationURL: target)
            plugins.append(.init(name: "hidden", marketplace: "", enabled: true, directSourceId: "hidden-source"))
            hooks.append(.init(hookType: "postToolUse", origin: "plugin", source: "hidden", enabled: true, disableKey: "hidden-key"))
        }
        let changed = CopilotSetupMetadata(version: "1.0.89", protocolVersion: 3, hooks: hooks + staged.hooks, plugins: plugins)
        #expect(throws: (any Error).self) { try operation.verifyStaging(changed) }
        #expect(operation.phase == .staged)
        #expect(try CopilotSetupJSON.bool(CopilotSetupJSON.object(Data(contentsOf: fixture.file))["disableAllHooks"]))
        #expect(try CopilotSetupFileState.read(fixture.source.appendingPathComponent("plugin.json")).data == nil)
    }

    @Test func removalCannotIgnoreAnAddedOverlappingAlias() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let metadata = try overlappingMetadata(fixture)
        let operation = try fixture.registration.begin(.uninstall, metadata: metadata)
        try operation.stage()
        try operation.verifyStaging(metadata)
        try operation.removeRegistration()
        let group = fixture.provider.appendingPathComponent("installed-plugins/_direct")
        try FileManager.default.copyItem(at: group.appendingPathComponent("maestro-cmux"),
                                        to: group.appendingPathComponent("late-duplicate"))
        #expect(throws: CopilotRegistrationConflict.self) { try operation.verifyRemoval(metadata) }
        #expect(operation.phase == .registrationRemoved)
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
        let pending = fixture.directory.appendingPathComponent("metadata.pid.pending")
        let command = "#!/bin/sh\nset -eu\nprintf '%s' $$ > \(CopilotPluginManifest.shellQuoted(pending.path))\n/bin/mv \(CopilotPluginManifest.shellQuoted(pending.path)) \(CopilotPluginManifest.shellQuoted(ready.path))\ntrap '' TERM\n/bin/cat >/dev/null\n"
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
        do {
            let started = await clock.waitForStartup()
            if !started {
                task.cancel()
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
        } catch {
            task.cancel()
            _ = await task.value
            throw error
        }
    }

    @Test(arguments: [false, true])
    func metadataPIDPublicationDoesNotExposeAnEmptyReadyMarker(atomic: Bool) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let ready = fixture.directory.appendingPathComponent("ready.pid")
        let pending = fixture.directory.appendingPathComponent("ready.pid.pending")
        let opened = fixture.directory.appendingPathComponent("opened")
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let target = atomic ? pending : ready
        let publish = atomic ? "/bin/mv \(CopilotPluginManifest.shellQuoted(pending.path)) \(CopilotPluginManifest.shellQuoted(ready.path))" : ":"
        process.arguments = ["-ec", """
        exec 3> \(CopilotPluginManifest.shellQuoted(target.path))
        printf opened > \(CopilotPluginManifest.shellQuoted(opened.path))
        IFS= read -r gate
        printf '%s' $$ >&3
        exec 3>&-
        \(publish)
        """]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: opened.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: opened.path))
        #expect(FileManager.default.fileExists(atPath: ready.path) == !atomic)
        #expect(try Data(contentsOf: target).isEmpty)
        if !atomic {
            #expect(try Int32(String(contentsOf: ready, encoding: .utf8)) == nil,
                    "Negative control reproduces existence before PID publication.")
        }
        try input.fileHandleForWriting.write(contentsOf: Data("publish\n".utf8))
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try Int32(String(contentsOf: ready, encoding: .utf8)) == process.processIdentifier)
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

    @Test(arguments: ["staged", "modified-disabled", "missing-disabled", "completed-disabled"])
    func durablePhaseAndPluginValidationPrecedeConfiguredDisable(scenario: String) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        if scenario == "staged" {
            let transaction = try fixture.registration.begin(.install, metadata: fixture.metadata(installed: false))
            try transaction.stage()
            #expect(fixture.registration.health() == .incomplete)
            #expect(try CopilotSetupJSON.bool(CopilotSetupJSON.object(Data(contentsOf: fixture.file))["disableAllHooks"]))
            return
        }
        try fixture.write(["disableAllHooks": true], to: fixture.settings)
        let runner = ObserverSetupRunner(fixture)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installedDisabled)
        if scenario == "modified-disabled" {
            try fixture.write(["version": 1, "hooks": [:], "foreign": true],
                              to: fixture.cache.appendingPathComponent("hooks.json"))
            #expect(fixture.registration.health() == .conflict)
        } else if scenario == "missing-disabled" {
            try FileManager.default.removeItem(at: fixture.cache.appendingPathComponent("hooks.json"))
            try FileManager.default.removeItem(at: fixture.cache.appendingPathComponent("plugin.json"))
            #expect(fixture.registration.health() == .incomplete)
        } else {
            #expect(fixture.registration.health() == .disabled)
        }
    }

    private func independentOwnedRows(disabled: Set<String> = []) -> [CopilotSetupMetadata.Hook] {
        [
            ("sessionStart", "opaque-start"), ("userPromptSubmitted", "opaque-prompt"), ("postToolUse", "opaque-tool"),
        ].map { event, key in
            CopilotSetupMetadata.Hook(hookType: event, origin: "user",
                source: "hooks/cmux-maestro-observer.json", enabled: !disabled.contains(key), disableKey: key)
        }
    }

    @Test(arguments: ["all", "subset", "unrelated", "unknown"])
    func ownedKeyIntentSurvivesExplicitSetupAndFreshStatus(scenario: String) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let runner = ObserverSetupRunner(fixture)
        await runner.supplyMetadata(owned: independentOwnedRows())
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installed)
        let file = try Data(contentsOf: fixture.file)
        let keys = scenario == "all" ? ["opaque-start", "opaque-prompt", "opaque-tool"]
            : scenario == "subset" ? ["opaque-tool"] : [scenario == "unrelated" ? "other-key" : "unknown-key"]
        try fixture.write(["disabledHooks": keys, "unrelatedSetting": ["preserve": true]], to: fixture.settings)
        let settings = try Data(contentsOf: fixture.settings)
        var unrelated: [CopilotSetupMetadata.Hook] = []
        if scenario == "unrelated" {
            try fixture.write(["version": 1, "hooks": ["sessionStart": [["type": "command", "bash": ":"]]]],
                to: fixture.file.deletingLastPathComponent().appendingPathComponent("unrelated.json"))
            unrelated = [.init(hookType: "sessionStart", origin: "user", source: "hooks/unrelated.json",
                                enabled: false, disableKey: "other-key")]
        }
        await runner.supplyMetadata(owned: independentOwnedRows(disabled: Set(keys)), unrelated: unrelated)
        let expectedResult: CopilotSetupResult = scenario == "all" ? .installedDisabled
            : scenario == "subset" ? .installedPartiallyDisabled
            : scenario == "unknown" ? .installedDisableUnresolved : .installed
        #expect(await perform(setup(fixture, runner: runner), fixture) == expectedResult)
        let expectedHealth: IntegrationRegistrationHealth = scenario == "all" ? .disabled
            : scenario == "subset" ? .partiallyDisabled
            : scenario == "unknown" ? .disableUnresolved : .currentOnDisk
        #expect(fixture.registration.health() == expectedHealth)
        #expect(try Data(contentsOf: fixture.settings) == settings)
        #expect(try Data(contentsOf: fixture.file) == file)
        if scenario == "subset" {
            #expect(!expectedHealth.message.contains("All observer"))
            #expect(expectedResult.message.contains("some observer"))
        }
    }

    @Test(arguments: ["missing", "wrong-generation", "unknown-version", "missing-event"])
    func unresolvedStoredKeyProvenanceIsNotReportedAsOrdinaryCurrent(scenario: String) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let runner = ObserverSetupRunner(fixture)
        await runner.supplyMetadata(owned: independentOwnedRows())
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installed)
        try fixture.write(["disabledHooks": ["opaque-tool"]], to: fixture.settings)
        let receipt = fixture.root.appendingPathComponent(CopilotObserverRegistration.receiptName)
        var object = try CopilotSetupJSON.object(Data(contentsOf: receipt))
        var evidence = try #require(object["keyEvidence"] as? [String: Any])
        switch scenario {
        case "missing": object.removeValue(forKey: "keyEvidence")
        case "wrong-generation": evidence["generation"] = UUID().uuidString
        case "unknown-version": evidence["version"] = "9.9.9"
        default:
            var events = try #require(evidence["events"] as? [String: String])
            events.removeValue(forKey: "sessionStart")
            evidence["events"] = events
        }
        if scenario != "missing" { object["keyEvidence"] = evidence }
        try fixture.write(object, to: receipt)
        #expect(fixture.registration.health() == .disableUnresolved)
        let settings = try Data(contentsOf: fixture.settings)
        await runner.supplyMetadata(owned: independentOwnedRows(disabled: ["opaque-tool"]))
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installedPartiallyDisabled)
        #expect(fixture.registration.health() == .partiallyDisabled)
        #expect(try Data(contentsOf: fixture.settings) == settings)
    }

    @Test func missingPublicKeysKeepDisableApplicabilityExplicitlyUnresolved() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let runner = ObserverSetupRunner(fixture)
        await runner.supplyMetadata(owned: independentOwnedRows())
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installed)
        try fixture.write(["disabledHooks": ["opaque-tool"]], to: fixture.settings)
        let settings = try Data(contentsOf: fixture.settings)
        let unknown = independentOwnedRows(disabled: ["opaque-tool"]).map {
            CopilotSetupMetadata.Hook(hookType: $0.hookType, origin: $0.origin, source: $0.source,
                                       enabled: $0.enabled, disableKey: nil)
        }
        await runner.supplyMetadata(owned: unknown)
        #expect(await perform(setup(fixture, runner: runner), fixture) == .installedDisableUnresolved)
        #expect(fixture.registration.health() == .disableUnresolved)
        #expect(try Data(contentsOf: fixture.settings) == settings)
    }

    @Test(arguments: ["unaffected", "affected", "missing-key", "duplicate-event", "unknown-key", "blanket-unresolved"])
    func migrationRequiresPositiveUnaffectedPriorKeys(scenario: String) throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        try fixture.legacy()
        try fixture.write(["version": 1, "hooks": ["sessionStart": [["type": "command", "bash": ":"]]]],
            to: fixture.file.deletingLastPathComponent().appendingPathComponent("unrelated.json"))
        let configured = scenario == "affected" ? ["legacy-tool"] : scenario == "unknown-key" ? ["unresolved"] : ["unrelated"]
        try fixture.write(["disabledHooks": configured], to: fixture.settings)
        let known = try fixture.metadata(installed: true)
        var own: [CopilotSetupMetadata.Hook] = [
            ("sessionStart", "legacy-start"), ("userPromptSubmitted", "legacy-prompt"), ("postToolUse", "legacy-tool"),
        ].map { event, key in
            .init(hookType: event, origin: "plugin", source: "cmux-maestro-native",
                  enabled: !configured.contains(key), disableKey: key)
        }
        if scenario == "missing-key" || scenario == "blanket-unresolved" {
            own[0] = .init(hookType: "sessionStart", origin: "plugin", source: "cmux-maestro-native", enabled: false, disableKey: nil)
        }
        if scenario == "duplicate-event" { own.append(own[0]) }
        if scenario == "blanket-unresolved" {
            try fixture.write(["disableAllHooks": true, "disabledHooks": configured], to: fixture.settings)
        }
        let other = CopilotSetupMetadata.Hook(hookType: "sessionStart", origin: "user", source: "hooks/unrelated.json",
                                             enabled: false, disableKey: "unrelated")
        let metadata = CopilotSetupMetadata(version: "1.0.89", protocolVersion: 3, hooks: own + [other], plugins: known.plugins)
        let before = try Data(contentsOf: fixture.settings)
        if scenario == "unaffected" {
            _ = try fixture.registration.begin(.install, metadata: metadata)
        } else {
            #expect(throws: CopilotRegistrationConflict.self) { try fixture.registration.begin(.install, metadata: metadata) }
        }
        #expect(try Data(contentsOf: fixture.settings) == before)
        #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
    }

    @Test func commandLineCompletionClassifiesVerifiedDisableStatesAndRealFailures() {
        for result: CopilotSetupResult in [.installed, .installedDisabled, .installedPartiallyDisabled, .installedDisableUnresolved] {
            let completion = CopilotSetupCommandLine.completion(result)
            #expect(completion.exitCode == 0)
            #expect(completion.useStandardOutput)
            #expect(completion.text == result.message + "\n")
        }
        for result: CopilotSetupResult in [.uninstalled, .conflict("test"), .incomplete(.staged, "test"),
            .failed(9), .timedOut, .cancelled, .unavailable, .validationOnly] {
            let completion = CopilotSetupCommandLine.completion(result)
            #expect(completion.exitCode == 1)
            #expect(!completion.useStandardOutput)
        }
        #expect(CopilotSetupCommandLine.usageCompletion.exitCode == 2)
        #expect(!CopilotSetupCommandLine.usageCompletion.useStandardOutput)
        #expect(CopilotSetupCommandLine.usageCompletion.text == CopilotSetupCommandLine.usage + "\n")
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
