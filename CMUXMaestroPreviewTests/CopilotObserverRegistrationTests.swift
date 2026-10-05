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

    func begin(_ action: CopilotSetupAction, metadata: CopilotSetupMetadata,
               isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> CopilotObserverRegistration.Transaction {
        let operation = try registration.begin(action, metadata: metadata, isCancelled: isCancelled)
        try operation.bindSource(.init(source: source.path, version: metadata.version, protocolVersion: 3,
                                       directSourceId: "opaque-provider-source"))
        return operation
    }

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

    func metadata(installed: Bool, enabled: Bool = true) throws -> CopilotSetupMetadata {
        var hooks: [CopilotSetupMetadata.Hook] = []
        let settingsObject = FileManager.default.fileExists(atPath: settings.path)
            ? try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any] : nil
        let disabledKeys = settingsObject?["disabledHooks"] as? [String] ?? []
        for (url, origin, source) in [
            (file, "user", "hooks/\(CopilotObserverRegistration.filename)"),
            (cache.appendingPathComponent("hooks.json"), "plugin", CopilotPluginManifest.name),
        ] {
            if origin == "plugin", !installed || !enabled { continue }
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
        return CopilotSetupMetadata(version: enabled ? "1.0.88" : "1.0.89", protocolVersion: 3, hooks: hooks,
            plugins: installed ? [.init(name: CopilotPluginManifest.name, marketplace: "", enabled: enabled,
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

struct FailingResourceSetupFiles: CopilotSetupFileSystem {
    let fixture: ObserverFixture
    let blockedDirectory: URL

    func executable(selected: URL?, path: String) throws -> URL { fixture.helper }
    func preparePlugin(root: URL, helper: URL, controller: URL, skill: URL) throws -> URL {
        let plan = CopilotPluginResources(writes: [
            .init(file: fixture.helperRecord, data: try CopilotSetupJSON.data(["helper": helper.path])),
            .init(file: blockedDirectory.appendingPathComponent("blocked-resource"), data: Data("write".utf8)),
        ], routes: fixture.home)
        try plan.publish()
        return fixture.source
    }
    func removeMessaging(root: URL) throws {}
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
    var afterMutationResult: CopilotProcessResult?
    var pluginOperations: [String] = []
    private var nativeEnabled = true
    private var loseReceipt = false
    private var receiptIdentity = "opaque-provider-source"
    var bootstrapCalls: [URL] = []
    var bootstrapFailure = false
    var selectedIdentity = "opaque-provider-source"
    private var changeDuringBootstrap: String?
    private var changeReceiptAtMetadataCall: Int?
    private var disableFailure = false
    var installedWithInactiveObserver: [Bool] = []
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
                   cancelDuringStaging: Bool = false, afterMutationResult: CopilotProcessResult? = nil) {
        self.result = result; self.failingMetadataCall = failingMetadataCall
        self.invalidInstall = invalidInstall; self.stagingEnabled = stagingEnabled
        self.settingsEffect = settingsEffect
        self.cancelDuringStaging = cancelDuringStaging
        self.afterMutationResult = afterMutationResult
    }
    func supplyMetadata(owned: [CopilotSetupMetadata.Hook]? = nil, unrelated: [CopilotSetupMetadata.Hook] = [],
                        plugins: [CopilotSetupMetadata.Plugin] = [], version: String? = nil) {
        ownedRowsOverride = owned
        unrelatedRows = unrelated
        unrelatedPlugins = plugins
        suppliedVersion = version
    }
    func nativePlugin(enabled: Bool = true, loseReceipt: Bool = false,
                      receiptIdentity: String = "opaque-provider-source") {
        nativeEnabled = enabled
        self.loseReceipt = loseReceipt
        self.receiptIdentity = receiptIdentity
    }
    func sourceIdentity(executable: URL, source: URL, path: String) async -> CopilotSourceIdentityResult {
        bootstrapCalls.append(source)
        if bootstrapFailure { return .failed(.unavailable) }
        if changeDuringBootstrap == "selection" { selectedIdentity = "foreign-source" }
        if changeDuringBootstrap == "source" || changeDuringBootstrap == "receipt" {
            do {
                try fixture.write(["modified": true], to: changeDuringBootstrap == "source"
                    ? source.appendingPathComponent("hooks.json") : fixture.registration.receiptFile)
            } catch { return .failed(.unavailable) }
        }
        return .value(.init(source: source.path, version: suppliedVersion ?? (nativeEnabled ? "1.0.88" : "1.0.89"),
                            protocolVersion: 3, directSourceId: "opaque-provider-source"))
    }
    func configureSource(identity: String = "opaque-provider-source", fail: Bool = false, change: String? = nil) {
        selectedIdentity = identity
        bootstrapFailure = fail
        changeDuringBootstrap = change
    }
    func changeReceipt(onMetadataCall call: Int) { changeReceiptAtMetadataCall = call }
    func failDisabling(_ value: Bool) { disableFailure = value }
    func run(executable: URL, arguments: [String], path: String, providerHome: URL?) async -> CopilotProcessResult {
        providerHomes.append(providerHome)
        calls.append([executable.path] + arguments)
        guard result == .exited(0) else { return result }
        do {
            if arguments.contains("uninstall") {
                installed = false
                if FileManager.default.fileExists(atPath: fixture.cache.path) {
                    try FileManager.default.removeItem(at: fixture.cache)
                }
            }
            else {
                installed = true
                nativeEnabled = true
                for name in ["plugin.json", "hooks.json", "skills/cmux-maestro-orchestrate/SKILL.md",
                             "skills/maestro-icon/SKILL.md", "skills/maestro/SKILL.md"] {
                    let source = fixture.source.appendingPathComponent(name)
                    let target = fixture.cache.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: source.path) {
                        try fixture.write(Data(contentsOf: source), to: target)
                    } else if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
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
            if let failure = afterMutationResult {
                afterMutationResult = nil
                return failure
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
            if metadataCalls == changeReceiptAtMetadataCall {
                var receipt = try CopilotSetupJSON.object(Data(contentsOf: fixture.registration.receiptFile))
                receipt["previous"] = receipt["desired"]
                try fixture.write(receipt, to: fixture.registration.receiptFile)
            }
            var value = try fixture.metadata(installed: installed, enabled: nativeEnabled)
            value = .init(version: value.version, protocolVersion: value.protocolVersion, hooks: value.hooks,
                plugins: value.plugins.map { .init(name: $0.name, marketplace: $0.marketplace, enabled: $0.enabled,
                                                   directSourceId: selectedIdentity) })
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

    func plugin(executable: URL, operation: CopilotPluginOperation, path: String,
                providerHome: URL?) async -> CopilotPluginOperationResult {
        let arguments: [String]
        switch operation {
        case .install(let source, let identity):
            guard identity == nil || identity == "opaque-provider-source" else { return .failed(.unavailable) }
            pluginOperations.append("install:\(source.path)")
            let staged = try? CopilotSetupJSON.object(Data(contentsOf: fixture.file))
            installedWithInactiveObserver.append(staged?["disableAllHooks"] as? Bool == true)
            arguments = ["--no-auto-update", "plugin", "install", source.path]
        case .uninstall(let identity):
            guard identity == "opaque-provider-source" else { return .failed(.unavailable) }
            pluginOperations.append("uninstall:\(identity)")
            arguments = ["--no-auto-update", "plugin", "uninstall", CopilotPluginManifest.name]
        case .disable(let identity):
            guard installed, identity == selectedIdentity else { return .failed(.unavailable) }
            pluginOperations.append("disable:\(identity)")
            guard !disableFailure else { return .failed(.exited(9)) }
            nativeEnabled = false
            return .value(.init(plugin: .init(name: CopilotPluginManifest.name, marketplace: "", enabled: false,
                                              directSourceId: identity), directInstallDeprecated: false))
        }
        let respondsBeforeFailure = afterMutationResult != nil
        let result = await run(executable: executable, arguments: arguments, path: path, providerHome: providerHome)
        let value = installed ? CopilotSetupMetadata.Plugin(name: CopilotPluginManifest.name, marketplace: "",
            enabled: nativeEnabled, directSourceId: receiptIdentity) : nil
        let receipt = CopilotPluginReceipt(plugin: value, directInstallDeprecated: installed)
        guard result == .exited(0) else {
            return .failed(result, receipt: respondsBeforeFailure && !loseReceipt ? receipt : nil)
        }
        return .value(receipt)
    }
}
private struct CheckpointOfficialProvider: CopilotSetupProcessRunner {
    let home: URL
    private let runner = LocalCopilotSetupRunner()

    func run(executable: URL, arguments: [String], path: String, providerHome: URL?) async -> CopilotProcessResult {
        await runner.run(executable: executable, arguments: arguments, path: path, providerHome: providerHome)
    }
    func metadata(executable: URL, path: String, providerHome: URL?) async -> CopilotMetadataResult {
        let result = await runner.metadata(executable: executable, path: path, providerHome: providerHome)
        let marker = home.appendingPathComponent(".fixture-crash-after-receipt-publication")
        if FileManager.default.fileExists(atPath: marker.path), case .value = result {
            let support = home.appendingPathComponent("Library/Application Support/CMUXMaestroPreview")
            let journal = support.appendingPathComponent("Orchestration/install-transaction.json")
            let receipt = support.appendingPathComponent("Copilot/observer-registration.json")
            if FileManager.default.fileExists(atPath: journal.path), FileManager.default.fileExists(atPath: receipt.path) {
                do {
                    let saved = try CopilotSetupJSON.object(Data(contentsOf: journal))
                    let owned = try CopilotSetupJSON.object(Data(contentsOf: receipt))
                    if saved["phase"] as? String == "applying", owned["phase"] as? String == "staged" {
                        try Data("staged".utf8).write(to: marker)
                    } else if saved["phase"] as? String == "applying", owned["phase"] as? String == "current",
                              try String(contentsOf: marker, encoding: .utf8) == "staged" {
                        let evidence = try CopilotSetupJSON.data(["phase": "applying", "afterMissing": saved["after"] == nil,
                                                                 "receipt": "current"])
                        try evidence.write(to: home.appendingPathComponent("receipt-crash-state.json"))
                        try FileManager.default.removeItem(at: marker)
                        Darwin._exit(95)
                    }
                } catch { return .failed(.unavailable) }
            }
        }
        return result
    }
    func sourceIdentity(executable: URL, source: URL, path: String) async -> CopilotSourceIdentityResult {
        await runner.sourceIdentity(executable: executable, source: source, path: path)
    }
    func plugin(executable: URL, operation: CopilotPluginOperation, path: String,
                providerHome: URL?) async -> CopilotPluginOperationResult {
        let result = await runner.plugin(executable: executable, operation: operation, path: path, providerHome: providerHome)
        let marker = home.appendingPathComponent(".fixture-crash-after-official-install")
        if case .install = operation, case .value = result, FileManager.default.fileExists(atPath: marker.path) {
            do { try FileManager.default.removeItem(at: marker) }
            catch { return .failed(.unavailable) }
            Darwin._exit(92)
        }
        return result
    }
}

private actor CheckpointProcessProvider: CopilotSetupProcessRunner {
    let home: URL
    let root: URL
    var provider: URL { home.appendingPathComponent(".copilot") }
    var cache: URL { provider.appendingPathComponent("installed-plugins/_direct/plugin") }
    var marker: URL { provider.appendingPathComponent(".fixture-provider-installed") }

    init(home: URL, root: URL) { self.home = home; self.root = root }

    func sourceIdentity(executable: URL, source: URL, path: String) async -> CopilotSourceIdentityResult {
        .value(.init(source: source.path, version: "1.0.89", protocolVersion: 3, directSourceId: "fixture-stable-source"))
    }

    func run(executable: URL, arguments: [String], path: String, providerHome: URL?) async -> CopilotProcessResult {
        do {
            if arguments.contains("uninstall") {
                if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
                if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
            } else {
                guard arguments.last == root.appendingPathComponent("plugin").path else { return .exited(3) }
                for name in ["plugin.json", "hooks.json", "skills/cmux-maestro-orchestrate/SKILL.md",
                             "skills/maestro-icon/SKILL.md", "skills/maestro/SKILL.md"] {
                    let source = root.appendingPathComponent("plugin/\(name)")
                    let target = cache.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: source.path) {
                        let directory = try HookFiles.directory(target.deletingLastPathComponent(), create: true)
                        defer { close(directory) }
                        try HookFiles.atomicWrite(Data(contentsOf: source), name: target.lastPathComponent, directory: directory)
                    } else if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }

                }
                try Data("installed".utf8).write(to: marker)
            }
            return .exited(0)
        } catch { return .exited(9) }
    }

    func plugin(executable: URL, operation: CopilotPluginOperation, path: String,
                providerHome: URL?) async -> CopilotPluginOperationResult {
        let arguments: [String]
        switch operation {
        case .install(let source, let identity):
            guard identity == nil || identity == "fixture-stable-source" else { return .failed(.unavailable) }
            arguments = ["--no-auto-update", "plugin", "install", source.path]
        case .uninstall(let identity):
            guard identity == "fixture-stable-source" else { return .failed(.unavailable) }
            arguments = ["--no-auto-update", "plugin", "uninstall", CopilotPluginManifest.name]
        case .disable:
            return .failed(.unavailable)
        }
        let result = await run(executable: executable, arguments: arguments, path: path, providerHome: providerHome)
        guard result == .exited(0) else { return .failed(result) }
        let installed = FileManager.default.fileExists(atPath: marker.path)
        return .value(.init(plugin: installed ? .init(name: CopilotPluginManifest.name, marketplace: "",
            enabled: true, directSourceId: "fixture-stable-source") : nil, directInstallDeprecated: installed))
    }

    func metadata(executable: URL, path: String, providerHome: URL?) async -> CopilotMetadataResult {
        do {
            let installed = FileManager.default.fileExists(atPath: marker.path)
            let settingsURL = provider.appendingPathComponent("settings.json")
            let settings = FileManager.default.fileExists(atPath: settingsURL.path)
                ? try CopilotSetupJSON.object(Data(contentsOf: settingsURL)) : [:]
            let keys = settings["disabledHooks"] as? [String] ?? []
            let global = settings["disableAllHooks"] as? Bool ?? false
            var hooks: [CopilotSetupMetadata.Hook] = []
            for (url, origin, source) in [
                (provider.appendingPathComponent("hooks/cmux-maestro-observer.json"), "user", "hooks/cmux-maestro-observer.json"),
                (cache.appendingPathComponent("hooks.json"), "plugin", CopilotPluginManifest.name),
            ] {
                if origin == "plugin" && !installed { continue }
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let value = try CopilotSetupJSON.object(Data(contentsOf: url))
                let disabled = value["disableAllHooks"] as? Bool ?? false
                for event in (value["hooks"] as? [String: Any] ?? [:]).keys {
                    let key = "fixture-key-\(event)"
                    hooks.append(.init(hookType: event, origin: origin, source: source,
                        enabled: !disabled && !global && !keys.contains(key), disableKey: disabled ? nil : key))
                }
            }
            return .value(.init(version: "1.0.89", protocolVersion: 3, hooks: hooks,
                plugins: installed ? [.init(name: CopilotPluginManifest.name, marketplace: "", enabled: true,
                                           directSourceId: "fixture-stable-source")] : []))
        } catch { return .failed(.unavailable) }
    }
}

nonisolated enum CopilotInstallBridgeProcessFixture {
    static func run(_ arguments: [String]) async -> Int32 {
        do {
            guard let request = try CopilotSetupCommandLine.bridge(arguments: arguments) else { return 2 }
            let home = request.application.deletingLastPathComponent().deletingLastPathComponent()
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            guard home.path.hasPrefix(repository.path + "/.build/local-preview-tests/") else {
                return 2
            }
            let homeFD = try CopilotFileAccess.openDirectory(home, owner: getuid())
            close(homeFD)
            let marker = try CopilotSetupJSON.object(Data(contentsOf: home.appendingPathComponent(".bridge-fixture.json")))
            guard marker["owner"] as? String == "local-preview-tests", let routePath = marker["routes"] as? String,
                  routePath.hasPrefix("/private/tmp/maestro-combined-") else { return 2 }
            let bundle = URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let resources = bundle.appendingPathComponent("Contents/Resources")
            let root = home.appendingPathComponent("Library/Application Support/CMUXMaestroPreview/Copilot")
            let executable = home.appendingPathComponent("fixture-copilot")
            if !FileManager.default.fileExists(atPath: executable.path) {
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            }
            let runner: any CopilotSetupProcessRunner
            let selected: URL
            if marker["provider"] as? String == "isolated-official" {
                _ = try CopilotProviderLease.load(required: true)
                guard let requested = request.executable,
                      requested.path.hasPrefix(home.path + "/") else { return 2 }
                runner = CheckpointOfficialProvider(home: home)
                selected = requested
            } else {
                runner = CheckpointProcessProvider(home: home, root: root)
                selected = executable
            }
            let checkpoint = CopilotInstallCheckpoint(id: request.id, home: home, root: root,
                application: request.application, bundle: bundle,
                controller: resources.appendingPathComponent("cmux-maestro-orchestrator.py"),
                skill: resources.appendingPathComponent("SKILL.md"), selected: selected, path: "/usr/bin:/bin",
                runner: runner,
                messagingRoutes: URL(fileURLWithPath: routePath))
            let unchanged = try await checkpoint.perform(request.action, allowAbsent: request.allowAbsent)
            let health = try await checkpoint.registrationStatus()
            let data = try JSONSerialization.data(withJSONObject: [
                "schema": 1, "action": request.action, "transaction": request.id.uuidString.lowercased(),
                "unchanged": unchanged, "registration": health.rawValue, "nativePlugin": checkpoint.nativePluginStatus,
            ], options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("Fixture bridge failed: \(error)\n".utf8))
            return 1
        }
    }
}

final class InstallCheckpointFixture: @unchecked Sendable {
    let fixture: ObserverFixture
    let bundle: URL
    let application: URL
    let routes: URL
    let runner: ObserverSetupRunner
    let id = UUID()
    var resources: URL { bundle.appendingPathComponent("Contents/Resources") }
    var helper: URL { application.appendingPathComponent("Contents/Helpers/CMUXMaestroCopilotHook") }

    init(legacy: Bool = false, disabled: Bool = false) throws {
        fixture = try ObserverFixture()
        bundle = fixture.directory.appendingPathComponent("Candidate.app")
        application = fixture.home.appendingPathComponent("Applications/Maestro.app")
        var template = Array("/private/tmp/maestro-checkpoint-XXXXXX".utf8CString)
        routes = URL(fileURLWithPath: String(cString: try #require(mkdtemp(&template))))
        runner = ObserverSetupRunner(fixture, installed: legacy)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for target in [bundle.appendingPathComponent("Contents/Helpers/CMUXMaestroCopilotHook"), helper] {
            try fixture.write(Data("#!/bin/sh\nexit 0\n".utf8), to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        }
        try fixture.write(Data("#!/usr/bin/env python3\n".utf8), to: resources.appendingPathComponent("controller.py"))
        try fixture.write(Data("---\nname: cmux-maestro-orchestrate\n---\n".utf8), to: resources.appendingPathComponent("SKILL.md"))
        try fixture.write(Data("---\nname: maestro-icon\n---\n".utf8), to: resources.appendingPathComponent("maestro-icon/SKILL.md"))
        for name in ["adapter.mjs", "extension.mjs"] {
            try FileManager.default.copyItem(at: repository.appendingPathComponent("scripts/delivery-proof/\(name)"),
                                             to: resources.appendingPathComponent(name))
        }
        try FileManager.default.copyItem(at: repository.appendingPathComponent("Resources/NerdFonts"),
                                         to: resources.appendingPathComponent("NerdFonts"))
        if legacy { try fixture.legacy(helper: helper, disabled: disabled) }
    }

    func checkpoint(id: UUID? = nil) -> CopilotInstallCheckpoint {
        CopilotInstallCheckpoint(id: id ?? self.id, home: fixture.home, root: fixture.root,
            application: application, bundle: bundle, controller: resources.appendingPathComponent("controller.py"),
            skill: resources.appendingPathComponent("SKILL.md"), selected: fixture.helper, path: "/usr/bin:/bin",
            runner: runner, messagingRoutes: routes)
    }

    func record() throws -> CopilotInstallCheckpoint.Record {
        try JSONDecoder().decode(CopilotInstallCheckpoint.Record.self,
            from: Data(contentsOf: CopilotInstallCheckpoint.location(root: fixture.root)))
    }

    func verifyRestored(_ original: CopilotInstallCheckpoint.Record) throws {
        for entry in original.entries {
            let state = try CopilotSetupFileState.read(URL(fileURLWithPath: entry.path), maximum: entry.maximum)
            #expect(entry.before.matches(state), "Restoration must match each recorded owned file")
        }
        #expect(original.settings.matches(try CopilotSetupFileState.read(fixture.settings)))
        #expect(try record().phase == "restored")
    }

    func clean() throws {
        try FileManager.default.removeItem(at: routes)
        try fixture.clean()
    }
}

struct CopilotInstallCheckpointTests {
    @Test(arguments: [false, true])
    func deletedExistingReceiptIsNotAnAuthorizedNilPlaceholder(durableAfter: Bool) async throws {
        let value = try InstallCheckpointFixture(); defer { try? value.clean() }
        for action in ["prepare", "apply", "finish", "release"] {
            _ = try await value.checkpoint().perform(action)
        }
        try value.fixture.write(Data("#!/usr/bin/env python3\n# updated fixture\n".utf8),
                                to: value.resources.appendingPathComponent("controller.py"))
        let id = UUID()
        _ = try await value.checkpoint(id: id).perform("prepare")
        _ = try await value.checkpoint(id: id).perform("apply")
        let journal = CopilotInstallCheckpoint.location(root: value.fixture.root)
        if !durableAfter {
            var saved = try CopilotSetupJSON.object(Data(contentsOf: journal))
            saved["phase"] = "applying"
            saved.removeValue(forKey: "after")
            try value.fixture.write(saved, to: journal)
        }
        let saved = try value.record()
        let receipt = value.fixture.registration.receiptFile
        let entry = try #require(saved.entries.first(where: { $0.path == receipt.path }))
        #expect(entry.before.data != nil)
        #expect(try #require(saved.receiptIntents).allSatisfy { $0.data != nil })
        try FileManager.default.removeItem(at: receipt)
        let resources = try saved.entries.map {
            try CopilotSetupFileState.read(URL(fileURLWithPath: $0.path), maximum: $0.maximum)
        }
        let pending = try CopilotSetupFileState.read(journal, maximum: CopilotInstallCheckpoint.maximum)
        let calls = await value.runner.pluginOperations
        do {
            _ = try await value.checkpoint(id: id).perform("restore")
            Issue.record("Receipt absence must not match the generic desired:nil placeholder")
        } catch {}
        #expect(!FileManager.default.fileExists(atPath: receipt.path))
        for resource in resources { try resource.revalidate() }
        try pending.revalidate()
        #expect(await value.runner.pluginOperations == calls)
    }

    @Test(arguments: [false, true], ["pluginIdentity", "source-path", "source-id"])
    func editedReceiptProvenanceIsPreservedWithOrWithoutAfterSnapshot(durableAfter: Bool, field: String) async throws {
        let value = try InstallCheckpointFixture(); defer { try? value.clean() }
        _ = try await value.checkpoint().perform("prepare")
        _ = try await value.checkpoint().perform("apply")
        if !durableAfter {
            let journal = CopilotInstallCheckpoint.location(root: value.fixture.root)
            var record = try CopilotSetupJSON.object(Data(contentsOf: journal))
            record["phase"] = "applying"
            record.removeValue(forKey: "after")
            try value.fixture.write(record, to: journal)
        }
        let receipt = value.fixture.registration.receiptFile
        var changed = try CopilotSetupJSON.object(Data(contentsOf: receipt))
        if field == "pluginIdentity" {
            changed["pluginIdentity"] = "foreign-receipt-edit"
        } else {
            var binding = try #require(changed["sourceIdentity"] as? [String: Any])
            binding[field == "source-path" ? "source" : "directSourceId"] = field == "source-path" ? "/foreign/plugin" : "foreign-id"
            changed["sourceIdentity"] = binding
        }
        try value.fixture.write(changed, to: receipt)
        let before = try CopilotSetupFileState.read(receipt)
        let resources = try value.record().entries.map {
            try CopilotSetupFileState.read(URL(fileURLWithPath: $0.path), maximum: $0.maximum)
        }
        let calls = await value.runner.pluginOperations
        do {
            _ = try await value.checkpoint().perform("restore")
            Issue.record("Edited provenance must not be accepted as an owned intermediate receipt")
        } catch {}
        try before.revalidate()
        for resource in resources { try resource.revalidate() }
        #expect(await value.runner.pluginOperations == calls)
        #expect(try value.record().phase == (durableAfter ? "applied" : "applying"))
    }

    @Test(arguments: ["reenabled-after-verification", "foreign-source-during-recovery"])
    func disabledRestorationDoesNotOverwriteNewChoiceOrForeignSource(change: String) async throws {
        let value = try InstallCheckpointFixture(legacy: true); defer { try? value.clean() }
        await value.runner.supplyMetadata(version: "1.0.89")
        await value.runner.nativePlugin(enabled: false)
        _ = try await value.checkpoint().perform("prepare")
        if change == "foreign-source-during-recovery" { await value.runner.failDisabling(true) }
        do { _ = try await value.checkpoint().perform("apply") }
        catch {
            #expect(change == "foreign-source-during-recovery")
        }
        if change == "reenabled-after-verification" {
            #expect(try value.record().phase == "applied")
            await value.runner.nativePlugin(enabled: true)
        } else {
            #expect(try value.record().phase == "applying")
            await value.runner.configureSource(identity: "foreign-source")
            await value.runner.failDisabling(false)
        }
        let calls = await value.runner.pluginOperations
        let receipt = try CopilotSetupFileState.read(value.fixture.registration.receiptFile)
        do {
            _ = try await value.checkpoint().perform("restore")
            Issue.record("New choice or foreign source must not be disabled or overwritten")
        } catch is CopilotRegistrationConflict {}
        #expect(await value.runner.pluginOperations == calls)
        try receipt.revalidate()
    }

    @Test func interruptedFirstInstallRemovalRetainsSourceUntilAbsenceIsVerified() async throws {
        let value = try InstallCheckpointFixture(); defer { try? value.clean() }
        _ = try await value.checkpoint().perform("prepare")
        let original = try value.record()
        _ = try await value.checkpoint().perform("apply")
        await value.runner.configure(afterMutationResult: .exited(9))
        do {
            _ = try await value.checkpoint().perform("restore")
            Issue.record("A failed provider exit must leave compensation pending")
        } catch let error as CopilotRegistrationConflict {
            #expect(error.message.contains("compensation failed"))
        }
        #expect(await value.runner.installed == false)
        #expect(try value.record().phase == "restoring")
        #expect(try CopilotSetupFileState.read(value.fixture.source.appendingPathComponent("plugin.json")).data != nil)
        let calls = await value.runner.pluginOperations
        #expect(calls.last == "uninstall:opaque-provider-source")
        await value.runner.configure()
        _ = try await value.checkpoint().perform("restore")
        try value.verifyRestored(original)
        #expect(await value.runner.pluginOperations == calls)
        #expect(try CopilotSetupFileState.read(value.fixture.source.appendingPathComponent("plugin.json")).data == nil)
        _ = try await value.checkpoint().perform("release")
    }

    @Test func disabledProvenanceRefreshAndRecoveryPreserveForeignReceiptChanges() async throws {
        let value = try InstallCheckpointFixture(); defer { try? value.clean() }
        await value.runner.supplyMetadata(version: "1.0.89")
        for action in ["prepare", "apply", "finish", "release"] {
            _ = try await value.checkpoint().perform(action)
        }
        let receipt = value.fixture.registration.receiptFile
        var object = try CopilotSetupJSON.object(Data(contentsOf: receipt))
        object.removeValue(forKey: "sourceIdentity")
        try value.fixture.write(object, to: receipt)
        await value.runner.nativePlugin(enabled: false)
        let id = UUID()
        _ = try await value.checkpoint(id: id).perform("prepare")
        await value.runner.changeReceipt(onMetadataCall: await value.runner.metadataCalls + 2)
        let calls = await value.runner.pluginOperations
        do {
            _ = try await value.checkpoint(id: id).perform("apply")
            Issue.record("Do not enrich a receipt changed after preparation")
        } catch {}
        let changed = try CopilotSetupFileState.read(receipt)
        #expect(try CopilotSetupJSON.object(changed.data ?? Data())["previous"] != nil)
        do {
            _ = try await value.checkpoint(id: id).perform("restore")
            Issue.record("Do not erase a foreign receipt change during compensation")
        } catch {}
        try changed.revalidate()
        #expect(await value.runner.pluginOperations == calls)
        #expect(try value.record().phase == "applying")
    }

    @Test(arguments: ["name-derived", "previous-version"])
    func disabledCurrentReceiptIsBootstrappedWithoutReenabling(kind: String) async throws {
        let value = try InstallCheckpointFixture(); defer { try? value.clean() }
        await value.runner.supplyMetadata(version: "1.0.89")
        for action in ["prepare", "apply", "finish", "release"] {
            _ = try await value.checkpoint().perform(action)
        }
        let receipt = value.fixture.registration.receiptFile
        var object = try CopilotSetupJSON.object(Data(contentsOf: receipt))
        if kind == "name-derived" {
            object.removeValue(forKey: "sourceIdentity")
        } else {
            var binding = try #require(object["sourceIdentity"] as? [String: Any])
            binding["version"] = "1.0.88"
            object["sourceIdentity"] = binding
        }
        try value.fixture.write(object, to: receipt)
        await value.runner.nativePlugin(enabled: false)
        let beforeCalls = await value.runner.pluginOperations
        let hooks = try CopilotSetupFileState.read(value.fixture.file)
        let id = UUID()
        #expect(try await value.checkpoint(id: id).perform("prepare") == false)
        _ = try await value.checkpoint(id: id).perform("apply")
        _ = try await value.checkpoint(id: id).perform("verify")
        #expect(await value.runner.pluginOperations == beforeCalls)
        try hooks.revalidate()
        let updated = try #require(CopilotSetupJSON.object(Data(contentsOf: receipt))["sourceIdentity"] as? [String: Any])
        #expect(updated["directSourceId"] as? String == "opaque-provider-source")
        #expect(updated["version"] as? String == "1.0.89")
        _ = try await value.checkpoint(id: id).perform("finish")
        _ = try await value.checkpoint(id: id).perform("release")
    }

    @Test(arguments: [false, true])
    func disabledNativePluginPreservesChoiceWithoutProviderMutation(resourceUpdate: Bool) async throws {
        let value = try InstallCheckpointFixture(); defer { try? value.clean() }
        await value.runner.supplyMetadata(version: "1.0.89")
        for action in ["prepare", "apply", "finish", "release"] {
            _ = try await value.checkpoint().perform(action)
        }
        await value.runner.nativePlugin(enabled: false)
        let beforeCalls = await value.runner.pluginOperations
        let oldController = value.fixture.root.deletingLastPathComponent()
            .appendingPathComponent("Orchestration/bin/cmux-maestro-orchestrator")
        let beforeController = try CopilotSetupFileState.read(oldController)
        let observer = try CopilotSetupFileState.read(value.fixture.file)
        if resourceUpdate {
            try value.fixture.write(Data("#!/usr/bin/env python3\n# replacement fixture\n".utf8),
                                    to: value.resources.appendingPathComponent("controller.py"))
        }
        let id = UUID()
        #expect(try await value.checkpoint(id: id).perform("prepare") == !resourceUpdate)
        let before = try value.record()
        #expect(try await value.checkpoint(id: id).perform("apply") == !resourceUpdate)
        _ = try await value.checkpoint(id: id).perform("verify")
        #expect(await value.runner.pluginOperations == beforeCalls)
        #expect(try CopilotSetupFileState.read(value.fixture.file) == observer)
        if resourceUpdate {
            #expect(try CopilotSetupFileState.read(oldController).data != beforeController.data)
            _ = try await value.checkpoint(id: id).perform("restore")
            try value.verifyRestored(before)
            #expect(try CopilotSetupFileState.read(oldController).data == beforeController.data)
        } else {
            _ = try await value.checkpoint(id: id).perform("finish")
        }
        #expect(await value.runner.pluginOperations == beforeCalls)
        _ = try await value.checkpoint(id: id).perform("release")
    }

    @Test(arguments: [false, true], ["success", "late-failure", "disable-failure", "install-failure"])
    func disabledPayloadReplacementAndRestorationReapplyOfficialChoice(legacy: Bool, outcome: String) async throws {
        let value = try InstallCheckpointFixture(legacy: legacy); defer { try? value.clean() }
        await value.runner.supplyMetadata(version: "1.0.89")
        if !legacy {
            for action in ["prepare", "apply", "finish", "release"] {
                _ = try await value.checkpoint().perform(action)
            }
            try value.fixture.write(Data("---\nname: maestro-icon\n---\nChanged fixture\n".utf8),
                                    to: value.resources.appendingPathComponent("maestro-icon/SKILL.md"))
        }
        await value.runner.nativePlugin(enabled: false)
        let id = UUID()
        _ = try await value.checkpoint(id: id).perform("prepare")
        let before = try value.record()
        #expect(!before.resourceOnly)
        if outcome == "disable-failure" { await value.runner.failDisabling(true) }
        if outcome == "install-failure" { await value.runner.configure(afterMutationResult: .exited(9)) }
        if outcome.hasPrefix("late") || outcome == "success" {
            _ = try await value.checkpoint(id: id).perform("apply")
        } else {
            do {
                _ = try await value.checkpoint(id: id).perform("apply")
                Issue.record("Provider/install disable failure must not yield installation success")
            } catch is CopilotRegistrationConflict {}
            #expect(try value.record().phase == "applying")
            #expect(try value.record().providerMutationStarted == true)
            #expect(try CopilotSetupJSON.bool(CopilotSetupJSON.object(Data(contentsOf: value.fixture.file))["disableAllHooks"]))
        }
        await value.runner.failDisabling(false)
        if outcome == "success" {
            _ = try await value.checkpoint(id: id).perform("verify")
            if legacy {
                #expect(try CopilotSetupJSON.bool(CopilotSetupJSON.object(Data(contentsOf: value.fixture.file))["disableAllHooks"]))
            }
            _ = try await value.checkpoint(id: id).perform("finish")
        } else {
            _ = try await value.checkpoint(id: id).perform("restore")
            try value.verifyRestored(before)
        }
        guard case .value(let metadata) = await value.runner.metadata(executable: value.fixture.helper, path: "",
                                                                     providerHome: value.fixture.provider) else {
            Issue.record("Restored disabled state must be discoverable"); return
        }
        #expect(metadata.plugins.first(where: { $0.name == CopilotPluginManifest.name })?.enabled == false)
        #expect(await value.runner.installedWithInactiveObserver.allSatisfy { $0 })
        #expect(await value.runner.pluginOperations.contains("disable:opaque-provider-source"))
        _ = try await value.checkpoint(id: id).perform("release")
    }

    @Test func bootstrapAuthorizesRecoveryWhenMutationResponseIsLost() async throws {
        let value = try InstallCheckpointFixture(); defer { try? value.clean() }
        _ = try await value.checkpoint().perform("prepare")
        await value.runner.nativePlugin(loseReceipt: true)
        await value.runner.configure(afterMutationResult: .exited(9))
        do {
            _ = try await value.checkpoint().perform("apply")
            Issue.record("A lost provider receipt must fail installation")
        } catch is CopilotRegistrationConflict {}
        #expect(await value.runner.installed)
        let beforeCalls = await value.runner.pluginOperations
        _ = try await value.checkpoint().perform("restore")
        #expect(await value.runner.pluginOperations == beforeCalls + ["uninstall:opaque-provider-source"])
        #expect(try value.record().phase == "restored")
        #expect(await value.runner.installed == false)
        #expect(try CopilotSetupFileState.read(value.fixture.file).data == nil)
    }

    @Test func receiptIdentityMustMatchSubsequentDiscovery() async throws {
        let value = try InstallCheckpointFixture(); defer { try? value.clean() }
        _ = try await value.checkpoint().perform("prepare")
        await value.runner.nativePlugin(receiptIdentity: "different-provider-source")
        do {
            _ = try await value.checkpoint().perform("apply")
            Issue.record("A different same-name source cannot satisfy the public install receipt")
        } catch is CopilotRegistrationConflict {}
        #expect(try value.record().phase == "applying")
        let hooks = try CopilotSetupJSON.object(Data(contentsOf: value.fixture.file))
        #expect(try CopilotSetupJSON.bool(hooks["disableAllHooks"]))
        _ = try await value.checkpoint().perform("restore")
        #expect(try value.record().phase == "restored")
        #expect(await value.runner.installed == false)
    }

    @Test func nativeDisableAfterApplyCannotBeClearedByCompensation() async throws {
        let value = try InstallCheckpointFixture(legacy: true); defer { try? value.clean() }
        await value.runner.supplyMetadata(version: "1.0.89")
        _ = try await value.checkpoint().perform("prepare")
        _ = try await value.checkpoint().perform("apply")
        await value.runner.nativePlugin(enabled: false)
        let beforeCalls = await value.runner.pluginOperations
        do {
            _ = try await value.checkpoint().perform("restore")
            Issue.record("A newer explicit disabled choice must survive compensation")
        } catch is CopilotRegistrationConflict {}
        #expect(await value.runner.pluginOperations == beforeCalls)
    }

    @Test func checkpointRemainsOutsideAllSidebarReadableSupportPrefixes() throws {
        let value = try InstallCheckpointFixture(); defer { try? value.clean() }
        let checkpoint = CopilotInstallCheckpoint.location(root: value.fixture.root)
        #expect(!checkpoint.path.hasPrefix(value.fixture.root.path + "/"))
        #expect(!checkpoint.path.hasPrefix(value.fixture.root.deletingLastPathComponent().appendingPathComponent("Orchestration/observer").path + "/"))
        #expect(checkpoint.deletingLastPathComponent().lastPathComponent == "Orchestration")
    }

    @Test func combinedCheckpointSuccessAndIdenticalNoopUseStableSource() async throws {
        let value = try InstallCheckpointFixture(); defer { try? value.clean() }
        #expect(try await value.checkpoint().perform("prepare") == false)
        #expect(throws: CopilotRegistrationConflict.self) { try value.fixture.registration.validateLocal() }
        #expect(try await value.checkpoint().perform("apply") == false)
        _ = try await value.checkpoint().perform("verify")
        let installed = try value.record()
        let stamps = try installed.entries.map {
            try CopilotSetupFileState.read(URL(fileURLWithPath: $0.path), maximum: $0.maximum).stamp
        }
        _ = try await value.checkpoint().perform("finish")
        #expect(try value.record().phase == "committed")
        _ = try await value.checkpoint().perform("release")
        let repeated = UUID()
        let before = await value.runner.calls.count
        #expect(try await value.checkpoint(id: repeated).perform("prepare"))
        #expect(try await value.checkpoint(id: repeated).perform("apply"))
        _ = try await value.checkpoint(id: repeated).perform("verify")
        #expect(await value.runner.calls.count == before)
        #expect(try installed.entries.map {
            try CopilotSetupFileState.read(URL(fileURLWithPath: $0.path), maximum: $0.maximum).stamp
        } == stamps)
        _ = try await value.checkpoint(id: repeated).perform("finish")
        _ = try await value.checkpoint(id: repeated).perform("release")
        #expect(await value.runner.calls.allSatisfy { $0.last == value.fixture.source.path })
    }

    @Test(arguments: [false, true])
    func lateProviderFailureRestoresExactPriorStateFromFreshCheckpoint(legacy: Bool) async throws {
        let value = try InstallCheckpointFixture(legacy: legacy); defer { try? value.clean() }
        try value.fixture.write(["unrelated": "keep", "disableAllHooks": false], to: value.fixture.settings)
        _ = try await value.checkpoint().perform("prepare")
        let before = try value.record()
        await value.runner.configure(settingsEffect: "normalize", afterMutationResult: .exited(9))
        do {
            _ = try await value.checkpoint().perform("apply")
            Issue.record("Partial official plugin failure must fail the combined operation")
        } catch is CopilotRegistrationConflict {}
        #expect(try value.record().phase == "applying")
        #expect(await value.runner.installed)
        _ = try await value.checkpoint().perform("restore")
        try value.verifyRestored(before)
        #expect(await value.runner.installed == legacy)
        _ = try await value.checkpoint().perform("release")
    }

    @Test func interruptionAfterPublicationRestoresLegacyDisableAndUnrelatedState() async throws {
        let value = try InstallCheckpointFixture(legacy: true, disabled: true); defer { try? value.clean() }
        try value.fixture.write(["unrelated": "preserve"], to: value.fixture.settings)
        _ = try await value.checkpoint().perform("prepare")
        let before = try value.record()
        await value.runner.configure(failingMetadataCall: 9)
        do {
            _ = try await value.checkpoint().perform("apply")
            Issue.record("Late discovery failure must retain a recoverable checkpoint")
        } catch is CopilotRegistrationConflict {}
        #expect(try value.record().phase == "applying")
        await value.runner.configure(result: .exited(7))
        do {
            _ = try await value.checkpoint().perform("restore")
            Issue.record("Failed official compensation must remain pending")
        } catch is CopilotRegistrationConflict {}
        #expect(try value.record().phase == "restoring")
        await value.runner.configure()
        _ = try await value.checkpoint().perform("restore")
        try value.verifyRestored(before)
        #expect(try CopilotSetupJSON.bool(CopilotSetupJSON.object(
            Data(contentsOf: value.fixture.cache.appendingPathComponent("hooks.json")))["disableAllHooks"]))
        _ = try await value.checkpoint().perform("release")
    }

    @Test func foreignOwnedFileAndWrongTransactionRefuseWithoutOverwrite() async throws {
        let value = try InstallCheckpointFixture(); defer { try? value.clean() }
        _ = try await value.checkpoint().perform("prepare")
        do {
            _ = try await value.checkpoint(id: UUID()).perform("restore")
            Issue.record("A different transaction cannot restore this checkpoint")
        } catch {}
        let target = value.fixture.root.appendingPathComponent("plugin/skills/cmux-maestro-orchestrate/SKILL.md")
        try value.fixture.write(Data("foreign concurrent change".utf8), to: target)
        let before = try CopilotSetupFileState.read(target)
        do {
            _ = try await value.checkpoint().perform("restore")
            Issue.record("Concurrent foreign content must not be overwritten")
        } catch {}
        #expect(try CopilotSetupFileState.read(target) == before)
        #expect(await value.runner.calls.isEmpty)
    }

    @Test func changedDisableAfterVerifiedApplyIsPreservedRatherThanRolledBackBlindly() async throws {
        let value = try InstallCheckpointFixture(); defer { try? value.clean() }
        _ = try await value.checkpoint().perform("prepare")
        _ = try await value.checkpoint().perform("apply")
        var object = try CopilotSetupJSON.object(Data(contentsOf: value.fixture.file))
        object["disableAllHooks"] = true
        try value.fixture.write(object, to: value.fixture.file)
        let before = try CopilotSetupFileState.read(value.fixture.file)
        let calls = await value.runner.calls.count
        do {
            _ = try await value.checkpoint().perform("restore")
            Issue.record("A concurrent explicit disable must not be cleared by compensation")
        } catch {}
        #expect(try CopilotSetupFileState.read(value.fixture.file) == before)
        #expect(await value.runner.calls.count == calls)
    }

    @Test func checkpointCannotRedirectRestorationOutsideFixedOwnedFiles() async throws {
        let value = try InstallCheckpointFixture(); defer { try? value.clean() }
        _ = try await value.checkpoint().perform("prepare")
        let journal = CopilotInstallCheckpoint.location(root: value.fixture.root)
        var object = try CopilotSetupJSON.object(Data(contentsOf: journal))
        var entries = try #require(object["entries"] as? [[String: Any]])
        let foreign = value.fixture.directory.appendingPathComponent("foreign.txt")
        try value.fixture.write(Data("preserve".utf8), to: foreign)
        entries[0]["path"] = foreign.path
        object["entries"] = entries
        try value.fixture.write(object, to: journal)
        let calls = await value.runner.metadataCalls
        do {
            _ = try await value.checkpoint().perform("restore")
            Issue.record("A journal must not grant arbitrary file-write authority")
        } catch {}
        #expect(try Data(contentsOf: foreign) == Data("preserve".utf8))
        #expect(await value.runner.metadataCalls == calls)
    }

    @Test func alreadyRestoredPrePluginFailureDoesNotRequireWritingReadOnlyHookDirectory() async throws {
        let value = try InstallCheckpointFixture(); defer { try? value.clean() }
        _ = try await value.checkpoint().perform("prepare")
        let before = try value.record()
        let hooks = value.fixture.file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: hooks.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hooks.path) }
        do {
            _ = try await value.checkpoint().perform("apply")
            Issue.record("Read-only hooks must reject publication")
        } catch is CopilotRegistrationConflict {}
        _ = try await value.checkpoint().perform("restore")
        try value.verifyRestored(before)
        #expect(await value.runner.calls.isEmpty)
        #expect((try FileManager.default.attributesOfItem(atPath: hooks.path)[.posixPermissions] as? Int) == 0o500)
        _ = try await value.checkpoint().perform("release")
    }

    @Test func compensationRestoresDistinctPriorSourceAndInstalledPayloadThroughStableSource() async throws {
        let value = try InstallCheckpointFixture(); defer { try? value.clean() }
        _ = try await value.checkpoint().perform("prepare")
        _ = try await value.checkpoint().perform("apply")
        _ = try await value.checkpoint().perform("finish")
        _ = try await value.checkpoint().perform("release")
        let relative = "skills/cmux-maestro-orchestrate/SKILL.md"
        let source = value.fixture.source.appendingPathComponent(relative)
        let cache = value.fixture.cache.appendingPathComponent(relative)
        let installedBefore = try Data(contentsOf: cache)
        let sourceBefore = Data("staged but not installed".utf8)
        try value.fixture.write(sourceBefore, to: source)
        let id = UUID()
        _ = try await value.checkpoint(id: id).perform("prepare")
        let before = try value.record()
        await value.runner.configure(afterMutationResult: .exited(9))
        do {
            _ = try await value.checkpoint(id: id).perform("apply")
            Issue.record("Partial provider failure must be reported")
        } catch is CopilotRegistrationConflict {}
        _ = try await value.checkpoint(id: id).perform("restore")
        try value.verifyRestored(before)
        #expect(try Data(contentsOf: source) == sourceBefore)
        #expect(try Data(contentsOf: cache) == installedBefore)
        #expect(await value.runner.calls.allSatisfy { $0.last == value.fixture.source.path })
        _ = try await value.checkpoint(id: id).perform("release")
    }
}

struct CopilotObserverRegistrationTests {
    @Test func forgedReceiptPathCannotBorrowACorrectProviderIdentity() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        try fixture.legacy()
        try fixture.write([
            "schema": 1, "desired": ["id": UUID().uuidString, "helper": fixture.helper.path],
            "phase": "staged", "pluginIdentity": "opaque-provider-source",
            "sourceIdentity": ["source": "/foreign/plugin", "version": "1.0.88",
                               "protocolVersion": 3, "directSourceId": "opaque-provider-source"],
        ], to: fixture.registration.receiptFile)
        let receipt = try CopilotSetupFileState.read(fixture.registration.receiptFile)
        let runner = ObserverSetupRunner(fixture, installed: true)
        let result = await perform(setup(fixture, runner: runner), fixture)
        guard case .conflict = result else { Issue.record("Foreign receipt path must refuse before effects"); return }
        #expect(await runner.calls.isEmpty)
        #expect(await runner.bootstrapCalls == [fixture.source])
        #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
        try receipt.revalidate()
    }

    @Test(arguments: ["absent", "name-derived", "forged-binding"], ["plain", "noncanonical-link", "safe-alias"])
    func wrongOwnedNameSourceIsRejectedBeforeEffects(receiptKind: String, alias: String) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        try fixture.legacy()
        let foreign = fixture.directory.appendingPathComponent("foreign-source")
        try fixture.write(["name": CopilotPluginManifest.name, "hooks": "hooks.json"],
                          to: foreign.appendingPathComponent("plugin.json"))
        try fixture.write(["version": 1, "hooks": CopilotPluginManifest.observerHooks(helper: fixture.helper)],
                          to: foreign.appendingPathComponent("hooks.json"))
        if alias != "plain" {
            try FileManager.default.createSymbolicLink(
                at: fixture.cache.deletingLastPathComponent().appendingPathComponent("noncanonical-owned-alias"),
                withDestinationURL: foreign)
        }
        if alias == "safe-alias" {
            try FileManager.default.copyItem(at: fixture.cache,
                to: fixture.cache.deletingLastPathComponent().appendingPathComponent("safe-owned-name"))
        }
        if receiptKind != "absent" {
            var value: [String: Any] = [
                "schema": 1, "desired": ["id": UUID().uuidString, "helper": fixture.helper.path],
                "phase": "staged", "pluginIdentity": "foreign-source",
            ]
            if receiptKind == "forged-binding" {
                value["sourceIdentity"] = ["source": fixture.source.path, "version": "1.0.88",
                                          "protocolVersion": 3, "directSourceId": "foreign-source"]
            }
            try fixture.write(value, to: fixture.registration.receiptFile)
        }
        let paths = [fixture.file, fixture.registration.receiptFile, fixture.settings, fixture.helperRecord,
                     fixture.source.appendingPathComponent("plugin.json"), fixture.source.appendingPathComponent("hooks.json"),
                     fixture.cache.appendingPathComponent("plugin.json"), fixture.cache.appendingPathComponent("hooks.json"),
                     foreign.appendingPathComponent("plugin.json"), foreign.appendingPathComponent("hooks.json")]
        let before = try paths.map { try CopilotSetupFileState.read($0) }
        let runner = ObserverSetupRunner(fixture, installed: true)
        await runner.configureSource(identity: "foreign-source")
        let result = await perform(setup(fixture, runner: runner), fixture)
        guard case .conflict = result else { Issue.record("Owned collision must be pre-effect conflict: \(result)"); return }
        #expect(await runner.calls.isEmpty)
        #expect(await runner.bootstrapCalls == [fixture.source])
        for state in before { try state.revalidate() }
    }

    @Test(arguments: ["failure", "selection", "source", "receipt"])
    func bootstrapFailureOrDriftCannotAuthorizeProductionMutation(change: String) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        try fixture.legacy()
        let installed = try CopilotSetupFileState.read(fixture.cache.appendingPathComponent("hooks.json"))
        let runner = ObserverSetupRunner(fixture, installed: true)
        await runner.configureSource(fail: change == "failure", change: change)
        let result = await perform(setup(fixture, runner: runner), fixture)
        guard case .conflict = result else { Issue.record("Bootstrap failure must precede effects: \(result)"); return }
        #expect(await runner.calls.isEmpty)
        #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
        try installed.revalidate()
    }

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
        #expect(await runner.metadataCalls == 5)
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

    @Test(arguments: [1, 2, 3, 4, 5])
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
        await runner.configure(failingMetadataCall: await runner.metadataCalls + 3)
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
        let operation = try fixture.begin(.install, metadata: fixture.metadata(installed: false))
        try operation.stage()
        try fixture.write(["foreign": "preserve"], to: fixture.file)
        let foreign = try CopilotSetupFileState.read(fixture.file)
        #expect(throws: CMUXMaestroPreview.CopilotFileError.changed) { try operation.restoreStaging() }
        #expect(try CopilotSetupFileState.read(fixture.file) == foreign)
    }

    @Test func resourcePreparationFailureRestoresStagingAndPreviousHelperBeforePluginCommand() async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let oldHelper = fixture.directory.appendingPathComponent("old/CMUXMaestroCopilotHook")
        try fixture.legacy(helper: oldHelper)
        let helperBefore = try CopilotSetupFileState.read(fixture.helperRecord)
        let legacyBefore = try CopilotSetupFileState.read(fixture.cache.appendingPathComponent("hooks.json"))
        let blocked = fixture.directory.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o500])
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let runner = ObserverSetupRunner(fixture, installed: true)
        let service = CopilotSetup(
            files: FailingResourceSetupFiles(fixture: fixture, blockedDirectory: blocked), runner: runner,
            bundleIdentifier: CopilotSetupAccess.productionBundleIdentifier, registration: fixture.registration)
        let result = await perform(service, fixture)
        #expect(result.message.contains("previous owned resource files were restored and verified"))
        #expect(result.message.contains("Previous observer-file and provenance"))
        #expect(await runner.calls.isEmpty)
        #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
        #expect(try CopilotSetupFileState.read(fixture.root.appendingPathComponent(CopilotObserverRegistration.receiptName)).data == nil)
        #expect(try CopilotSetupFileState.read(fixture.helperRecord).data == helperBefore.data)
        #expect(try CopilotSetupFileState.read(legacyBefore.url) == legacyBefore)
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
        let operation = try fixture.begin(.install, metadata: metadata)
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

    @Test(arguments: ["1.0.88", "1.0.89", "1.0.91", "1.1.0"])
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
        let operation = try fixture.begin(.install, metadata: fixture.metadata(installed: false))
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
            CopilotSetupMetadata(version: "2.0.0", protocolVersion: 3, hooks: known.hooks, plugins: known.plugins),
            CopilotSetupMetadata(version: "1.0.88", protocolVersion: 3, hooks: known.hooks,
                plugins: [.init(name: CopilotPluginManifest.name, marketplace: "", enabled: false, directSourceId: "opaque")]),
            CopilotSetupMetadata(version: "1.0.88", protocolVersion: 3, hooks: known.hooks,
                plugins: [.init(name: CopilotPluginManifest.name, marketplace: "foreign", enabled: true, directSourceId: nil)]),
        ] {
            #expect(throws: CopilotRegistrationConflict.self) { try fixture.begin(.install, metadata: metadata) }
        }
        #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
    }

    @Test(arguments: [
        ("1.0.88", 3, true), ("1.0.89", 3, true),
        ("1.0.0", 3, true), ("1.0.87", 3, true), ("1.0.90", 3, true),
        ("1.0.91", 3, true), ("1.1.0", 3, true), ("1.99.123", 3, true),
        ("0.9.0", 3, false), ("2.0.0", 3, false), ("10.0.0", 3, false),
        ("1", 3, false), ("1.0", 3, false), ("1..0", 3, false), ("1.0.", 3, false),
        ("1.0.0.1", 3, false), ("01.0.0", 3, false), ("1.00.0", 3, false),
        ("1.0.-1", 3, false), ("1.0.91\n", 3, false), ("v1.0.91", 3, false),
        ("1.0.89-preview", 3, false), ("1.0.89", 2, false), ("1.0.89", 4, false),
    ])
    func metadataAllowsStableMajorOneWithSupportedProtocol(version: String, protocolVersion: Int, expected: Bool) {
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
        #expect(throws: CopilotRegistrationConflict.self) { try fixture.begin(.install, metadata: changed) }
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
        let first = try fixture.begin(.install, metadata: fixture.metadata(installed: false))
        try first.stage()
        let second = try fixture.begin(.install, metadata: fixture.metadata(installed: false))
        #expect(throws: CopilotRegistrationConflict.self) { try second.stage() }
        try first.revalidate()
        #expect(first.phase == .staged)
        #expect(second.phase == .preflight)
    }

    @Test(arguments: ["host-relative", "absolute", "parent-component", "foreign-origin"])
    func providerSourceLabelsAreMatchedOnlyToTheExactOwnedFile(kind: String) throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let operation = try fixture.begin(.install, metadata: fixture.metadata(installed: false))
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

    @Test func unownedHelperCallingPluginIsPreservedWithoutSafetyCertification() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let directory = fixture.provider.appendingPathComponent("installed-plugins/community/other")
        try fixture.write(["name": "other", "hooks": "hooks.json"], to: directory.appendingPathComponent("plugin.json"))
        let hooks = directory.appendingPathComponent("hooks.json")
        try fixture.write(["version": 1, "hooks": ["postToolUse": [["type": "command", "bash": ":"]]]], to: hooks)
        let metadata = CopilotSetupMetadata(version: "1.0.88", protocolVersion: 3,
            hooks: [.init(hookType: "postToolUse", origin: "plugin", source: "other@community", enabled: true, disableKey: "opaque")],
            plugins: [.init(name: "other", marketplace: "community", enabled: true, directSourceId: nil)])
        let before = try Data(contentsOf: hooks)
        _ = try fixture.begin(.install, metadata: metadata)
        #expect(try Data(contentsOf: hooks) == before)
        try fixture.write(["version": 1, "hooks": CopilotPluginManifest.observerHooks(helper: fixture.helper)], to: hooks)
        let external = try CopilotSetupFileState.read(hooks)
        #expect(try fixture.begin(.install, metadata: metadata).pluginWasInstalled == false)
        try external.revalidate()
        #expect(IntegrationRegistrationHealth.currentOnDisk.message.contains("Unrelated helper callers"))
    }

    @Test(arguments: [false, true])
    func unrelatedHelperCallingLinkIsPreservedAcrossOwnedLifecycle(legacy: Bool) async throws {
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
    func unownedProviderProvenanceIsNotInferredFromSafeStaleCache(kind: String) throws {
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
        let operation = try fixture.begin(.install, metadata: selected)
        #expect(!operation.pluginWasInstalled)
        #expect(try CopilotSetupFileState.read(cached) == before)
        #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
        #expect((try FileManager.default.attributesOfItem(atPath: hidden.path)[.posixPermissions] as? Int) == 0o000)
    }

    @Test func providerProvenanceChangeInvalidatesAnAlreadyStagedInventory() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let original = try overlappingMetadata(fixture, marketplace: "community")
        let operation = try fixture.begin(.install, metadata: original)
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
        #expect(throws: CopilotRegistrationConflict.self) { try fixture.begin(.install, metadata: value) }
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
        _ = try fixture.begin(.install, metadata: metadata)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkedGroup.path) == target.path)
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int) == 0o000)
    }

    @Test func foreignMarketplaceCacheAliasesDoNotGrantOwnedAuthority() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let metadata = try overlappingMetadata(fixture, marketplace: "community")
        let group = fixture.provider.appendingPathComponent("installed-plugins/community")
        let irrelevantTarget = fixture.directory.appendingPathComponent("unreadable-irrelevant")
        try FileManager.default.createDirectory(at: irrelevantTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: group.appendingPathComponent("unrelated-link"), withDestinationURL: irrelevantTarget)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: irrelevantTarget.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: irrelevantTarget.path) }
        _ = try fixture.begin(.install, metadata: metadata)
        let duplicate = CopilotSetupMetadata(version: metadata.version, protocolVersion: metadata.protocolVersion,
            hooks: metadata.hooks, plugins: metadata.plugins + metadata.plugins)
        #expect(try fixture.begin(.install, metadata: duplicate).pluginWasInstalled == false)
        let saved = fixture.provider.appendingPathComponent("saved-community")
        try FileManager.default.moveItem(at: group, to: saved)
        try FileManager.default.createSymbolicLink(at: group, withDestinationURL: saved)
        #expect(try fixture.begin(.install, metadata: metadata).pluginWasInstalled == false)
    }

    @Test(arguments: [
        "relevant-plugin-link", "relevant-group-link", "hook-link", "unreadable-hooks",
        "missing-identity", "duplicate-identity", "duplicate-manifest", "missing-hooks", "missing-event",
        "aliased-relevant-link", "hidden-observer-link",
    ])
    func unownedCacheOpacityDoesNotCertifyOrSuppressExternalHelperCalls(scenario: String) throws {
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
        if scenario == "relevant-group-link" {
            // This group is also an ancestor of the exact OWNED cache.
            #expect(throws: (any Error).self) { try fixture.begin(.install, metadata: metadata) }
        } else {
            #expect(try fixture.begin(.install, metadata: metadata).pluginWasInstalled == false)
        }
        #expect(try CopilotSetupFileState.read(fixture.file).data == nil)
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int) == 0o000)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        #expect(try Data(contentsOf: target.appendingPathComponent("hooks.json")) == targetBytes)
    }

    @Test(arguments: ["directory-link", "new-duplicate", "changed-identity", "new-relevant-source"])
    func foreignPublicInventoryNotCacheAliasesIsRevalidatedDuringStaging(change: String) throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let metadata = try overlappingMetadata(fixture)
        let operation = try fixture.begin(.install, metadata: metadata)
        let group = fixture.provider.appendingPathComponent("installed-plugins/_direct")
        let plugin = group.appendingPathComponent("maestro-cmux")
        if change == "directory-link" {
            let moved = fixture.directory.appendingPathComponent("moved-plugin")
            try FileManager.default.moveItem(at: plugin, to: moved)
            try FileManager.default.createSymbolicLink(at: plugin, withDestinationURL: moved)
            try operation.stage()
            #expect(operation.phase == .staged)
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
        if change == "new-duplicate" {
            try operation.verifyStaging(changed)
        } else {
            #expect(throws: (any Error).self) { try operation.verifyStaging(changed) }
        }
        #expect(operation.phase == .staged)
        #expect(try CopilotSetupJSON.bool(CopilotSetupJSON.object(Data(contentsOf: fixture.file))["disableAllHooks"]))
        #expect(try CopilotSetupFileState.read(fixture.source.appendingPathComponent("plugin.json")).data == nil)
    }

    @Test func ownedRemovalDoesNotAdoptOrDeleteAForeignCacheAlias() throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let metadata = try overlappingMetadata(fixture)
        let operation = try fixture.begin(.uninstall, metadata: metadata)
        try operation.stage()
        try operation.verifyStaging(metadata)
        try operation.removeRegistration()
        let group = fixture.provider.appendingPathComponent("installed-plugins/_direct")
        try FileManager.default.copyItem(at: group.appendingPathComponent("maestro-cmux"),
                                        to: group.appendingPathComponent("late-duplicate"))
        try operation.verifyRemoval(metadata)
        #expect(operation.phase == .pluginRemoved)
        #expect(FileManager.default.fileExists(atPath: group.appendingPathComponent("late-duplicate/plugin.json").path))
    }

    @Test func metadataProcessUsesSupervisorForSuccessTimeoutAndMalformedOutput() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let watchdog = try MetadataProcessTestWatchdog(directory: repository.appendingPathComponent(
            ".build/tests/scoped-results/metadata-diagnostics/\(UUID().uuidString)"))
        defer { watchdog.finish() }
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
        watchdog.begin("success")
        try script("/bin/cat \(CopilotPluginManifest.shellQuoted(responses.path))\n/bin/cat >/dev/null")
        let runner = LocalCopilotSetupRunner(timeout: 2, deadlineNow: { watchdog.now() })
        guard case .value(let metadata) = await runner.metadata(executable: server, path: "/usr/bin:/bin") else {
            Issue.record("Expected bounded metadata response"); return
        }
        #expect(metadata.supported)
        watchdog.begin("malformed-output")
        try script("printf 'Content-Length: 999999\\r\\n\\r\\n'\n/bin/cat >/dev/null")
        guard case .failed(.unavailable) = await runner.metadata(executable: server, path: "/usr/bin:/bin") else {
            Issue.record("Oversized metadata must fail closed"); return
        }
        watchdog.begin("timeout-cleanup")
        try script("trap '' TERM\n/bin/sleep 10 &\nwait")
        let short = LocalCopilotSetupRunner(timeout: 0.1, terminationGrace: 0.02, deadlineNow: { watchdog.now() })
        guard case .failed(.timedOut) = await short.metadata(executable: server, path: "/usr/bin:/bin") else {
            Issue.record("Metadata must retain supervised deadline"); return
        }
    }

    @Test(arguments: [Duration.zero, .seconds(4)])
    func cancellingMetadataStopsItsOwnedProcessBeforeReturning(launchDelay: Duration) async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let watchdog = try MetadataProcessTestWatchdog(
            directory: repository.appendingPathComponent(
                ".build/tests/scoped-results/metadata-diagnostics/\(UUID().uuidString)"),
            testIdentity: "CMUXMaestroPreviewTests/CopilotObserverRegistrationTests/cancellingMetadataStopsItsOwnedProcessBeforeReturning(launchDelay:)/\(launchDelay)")
        defer { watchdog.finish() }
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        let server = fixture.directory.appendingPathComponent("metadata-waiter")
        let ready = fixture.directory.appendingPathComponent("metadata.pid")
        let pending = fixture.directory.appendingPathComponent("metadata.pid.pending")
        let command = "#!/bin/sh\nset -eu\nprintf '%s' $$ > \(CopilotPluginManifest.shellQuoted(pending.path))\n/bin/mv \(CopilotPluginManifest.shellQuoted(pending.path)) \(CopilotPluginManifest.shellQuoted(ready.path))\ntrap '' TERM\n/bin/cat >/dev/null\n"
        try fixture.write(Data(command.utf8), to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let clock = SetupDeadlineClock()
        let runner = LocalCopilotSetupRunner(terminationGrace: 0.02, deadlineNow: {
            _ = watchdog.now()
            return clock.now()
        })
        watchdog.begin("startup/\(launchDelay)")
        let task = Task {
            defer { clock.finishStartup() }
            do { try await Task.sleep(for: launchDelay) }
            catch is CancellationError { return CopilotMetadataResult.failed(.cancelled) }
            catch { Issue.record(error); return CopilotMetadataResult.failed(.unavailable) }
            let result = await runner.metadata(executable: server, path: "/usr/bin:/bin")
            watchdog.metadataCallReturned()
            return result
        }
        defer { task.cancel() }
        do {
            let started = await clock.waitForStartup()
            if !started {
                watchdog.begin("startup-failed-cancellation")
                task.cancel()
                let stopped = await task.value
                watchdog.taskValueReceived()
                Issue.record("Metadata did not spawn; result=\(stopped)")
                return
            }
            watchdog.begin("pid-publication")
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let readyExists = FileManager.default.fileExists(atPath: ready.path)
            if !readyExists {
                watchdog.begin("missing-pid-cancellation")
                task.cancel()
                let stopped = await task.value
                watchdog.taskValueReceived()
                Issue.record("Metadata writer was not ready after spawn; result=\(stopped); sampled=\(clock.wasSampled)")
            }
            try #require(readyExists)
            let pid = try #require(Int32(String(contentsOf: ready, encoding: .utf8)))
            watchdog.metadataPIDReady(pid)
            watchdog.begin("cancel-and-await-owned-process")
            task.cancel()
            let result = await task.value
            watchdog.taskValueReceived()
            guard case .failed(.cancelled) = result else {
                Issue.record("Expected metadata cancellation"); return
            }
            watchdog.begin("verify-owned-process-exit")
            #expect(HookProcess.current(pid) == nil)
            #expect(kill(pid, 0) == -1 && errno == ESRCH)
        } catch {
            watchdog.begin("error-cancellation")
            task.cancel()
            _ = await task.value
            watchdog.taskValueReceived()
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
        let operation = try fixture.begin(.install, metadata: fixture.metadata(installed: false))
        #expect(throws: CMUXMaestroPreview.CopilotFileError.io) { try operation.pluginCommandSucceeded() }
    }

    @Test(arguments: ["staged", "modified-disabled", "missing-disabled", "completed-disabled"])
    func durablePhaseAndPluginValidationPrecedeConfiguredDisable(scenario: String) async throws {
        let fixture = try ObserverFixture(); defer { try? fixture.clean() }
        if scenario == "staged" {
            let transaction = try fixture.begin(.install, metadata: fixture.metadata(installed: false))
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
            #expect(expectedResult.message.contains("some owned observer"))
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
            _ = try fixture.begin(.install, metadata: metadata)
        } else {
            #expect(throws: CopilotRegistrationConflict.self) { try fixture.begin(.install, metadata: metadata) }
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
