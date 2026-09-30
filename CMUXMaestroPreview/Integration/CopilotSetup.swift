import Darwin
import Dispatch
import Foundation

nonisolated enum CopilotSetupAction: Equatable, Sendable {
    case install, uninstall
}

nonisolated enum CopilotSetupAccess {
    static let productionBundleIdentifier = "com.jdylanmc.CMUXMaestroPreview"

    static func allowsChanges(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == productionBundleIdentifier
    }

    static var currentAppAllowsChanges: Bool {
        allowsChanges(bundleIdentifier: Bundle.main.bundleIdentifier)
    }
}

nonisolated enum CopilotSetupResult: Equatable, Sendable {
    case installed, uninstalled, unavailable, failed(Int32), timedOut, cancelled, validationOnly
    case installedDisabled
    case installedPartiallyDisabled, installedDisableUnresolved
    case conflict(String)
    case incomplete(IntegrationSetupPhase, String)

    var message: String {
        switch self {
        case .installed:
            "The owned hookless native plugin and dedicated observer registration are verified on disk. Unrelated helper callers are not certified or suppressed. Loaded hooks, observation and messaging readiness are not implied. Maestro did not restart or reload existing sessions."
        case .installedDisabled:
            "The native plugin is installed; all owned observer events are configured disabled. Disable choices were preserved; loaded behavior and effective provider-wide suppression are not implied."
        case .installedPartiallyDisabled:
            "The native plugin is installed; some owned observer events are configured disabled. Other owned events are not marked disabled. Keys are preserved; loaded behavior is not verified."
        case .installedDisableUnresolved:
            "Owned registration is verified on disk, but applicability of configured disable keys is unresolved. No keys were changed; loaded behavior is not verified."
        case .uninstalled:
            "Owned observer registration and the native plugin are removed, and new messaging entry points are disabled. Existing sessions may retain cached hooks and adapters; close them normally."
        case .unavailable:
            "Setup could not access the selected executable, bundled helper, or integration directory. Choose a trusted Copilot CLI executable and retry."
        case .failed(let status):
            "Copilot setup failed (exit \(status)). Check your CLI installation and retry. CLI output is not displayed."
        case .timedOut:
            "Copilot setup timed out and its installer processes were stopped. Check your CLI installation before retrying."
        case .cancelled:
            "Copilot setup was cancelled and its installer processes were stopped."
        case .validationOnly:
            "This validation copy cannot install or uninstall Copilot integration. Use the installed CMUX Maestro Preview app."
        case .conflict(let reason):
            "Setup refused before changing observer registration: \(reason)"
        case .incomplete(let phase, let reason):
            "Setup is incomplete after \(phase.label). \(reason) Review registration status before retrying. Maestro did not restart or reload sessions."
        }
    }
}

nonisolated enum CopilotSetupCommandLine {
    static let installFlag = "--install-copilot-integration"
    static let bridgeFlag = "--coordinate-copilot-install"
    static let usage = """
    Usage: CMUX Maestro Preview --install-copilot-integration --copilot-executable /absolute/path/to/copilot
    Internal installer: --coordinate-copilot-install <prepare|apply|verify|restore|finish|release> --transaction <uuid> --application /absolute/path/to/app [--copilot-executable /absolute/path/to/copilot]
    """

    enum Failure: Error { case usage }

    struct Completion: Equatable {
        let exitCode: Int32
        let useStandardOutput: Bool
        let text: String
    }

    struct Bridge: Equatable {
        let action: String
        let id: UUID
        let application: URL
        let executable: URL?
        let allowAbsent: Bool
    }

    static func bridge(arguments: [String]) throws -> Bridge? {
        guard arguments.contains(bridgeFlag) else { return nil }
        guard arguments.count >= 6, arguments[0] == bridgeFlag,
              ["prepare", "apply", "verify", "restore", "finish", "release"].contains(arguments[1]),
              arguments[2] == "--transaction", let id = UUID(uuidString: arguments[3]),
              id.uuidString.lowercased() == arguments[3],
              arguments[4] == "--application", arguments[5].hasPrefix("/"),
              !arguments[5].split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !arguments.contains(where: { $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
        else { throw Failure.usage }
        var remaining = Array(arguments.dropFirst(6))
        var executable: URL?
        if remaining.first == "--copilot-executable" {
            guard remaining.count >= 2, remaining[1].hasPrefix("/") else { throw Failure.usage }
            executable = URL(fileURLWithPath: remaining[1])
            remaining.removeFirst(2)
        }
        let allowAbsent = remaining == ["--allow-absent"] && ["restore", "release"].contains(arguments[1])
        guard remaining.isEmpty || allowAbsent else { throw Failure.usage }
        return Bridge(action: arguments[1], id: id, application: URL(fileURLWithPath: arguments[5]),
                      executable: executable, allowAbsent: allowAbsent)
    }

    static func coordinate(_ request: Bridge) async -> Completion {
        guard CopilotSetupAccess.currentAppAllowsChanges else { return completion(.validationOnly) }
        do {
            _ = try CopilotProviderLease.load(required: true)
            let home = try CopilotPaths.realUserHome()
            let application = request.application
            guard application.deletingLastPathComponent() == home.appendingPathComponent("Applications"),
                  application.pathExtension == "app",
                  let root = try? CopilotPaths.integrationRoot(),
                  let controller = Bundle.main.url(forResource: "cmux-maestro-orchestrator", withExtension: "py"),
                  let skill = Bundle.main.url(forResource: "SKILL", withExtension: "md") else { throw Failure.usage }
            try CopilotObserverRegistration(home: home, root: root,
                helper: application.appendingPathComponent("Contents/Helpers/CMUXMaestroCopilotHook"),
                installTransaction: request.id).validateHome()
            let checkpoint = CopilotInstallCheckpoint(
                id: request.id, home: home, root: root, application: application, bundle: Bundle.main.bundleURL,
                controller: controller, skill: skill, selected: request.executable,
                path: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            let unchanged = try await checkpoint.perform(request.action, allowAbsent: request.allowAbsent)
            let health = try await checkpoint.registrationStatus()
            let data = try JSONSerialization.data(withJSONObject: [
                "schema": 1, "action": request.action, "transaction": request.id.uuidString.lowercased(),
                "unchanged": unchanged, "registration": health.rawValue, "nativePlugin": checkpoint.nativePluginStatus,
            ], options: [.sortedKeys])
            return Completion(exitCode: 0, useStandardOutput: true, text: String(decoding: data, as: UTF8.self) + "\n")
        } catch {
            let reason = (error as? CopilotRegistrationConflict)?.message
                ?? "Owned integration could not be verified. Preserve the app receipt and integration checkpoint for recovery."
            return Completion(exitCode: 1, useStandardOutput: false, text: reason + "\n")
        }
    }

    static func completion(_ result: CopilotSetupResult) -> Completion {
        let success: Bool
        switch result {
        case .installed, .installedDisabled, .installedPartiallyDisabled, .installedDisableUnresolved: success = true
        default: success = false
        }
        return Completion(exitCode: success ? 0 : 1, useStandardOutput: success, text: result.message + "\n")
    }

    static var usageCompletion: Completion {
        Completion(exitCode: 2, useStandardOutput: false, text: usage + "\n")
    }

    static func executable(arguments: [String]) throws -> URL? {
        guard arguments.contains(installFlag) else { return nil }
        guard arguments.count == 3, arguments[0] == installFlag,
              arguments[1] == "--copilot-executable", arguments[2].hasPrefix("/"),
              !arguments[2].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw Failure.usage }
        return URL(fileURLWithPath: arguments[2])
    }

    static func install(selected: URL) async -> CopilotSetupResult {
        guard CopilotSetupAccess.currentAppAllowsChanges else { return .validationOnly }
        guard let root = try? CopilotPaths.integrationRoot(),
              let controller = Bundle.main.url(forResource: "cmux-maestro-orchestrator", withExtension: "py"),
              let skill = Bundle.main.url(forResource: "SKILL", withExtension: "md") else {
            return .unavailable
        }
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/CMUXMaestroCopilotHook")
        return await CopilotSetup().perform(
            .install, selected: selected,
            path: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            root: root, helper: helper, controller: controller, skill: skill
        )
    }
}

nonisolated enum CopilotPluginManifest {
    static let name = "cmux-maestro-native"
    static let events = ["sessionStart", "userPromptSubmitted", "postToolUse"]

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func command(helper: URL) -> String {
        // Keep a shell parent so helper crashes/signals/missing binaries cannot
        // become hook control output or a negative exit status.
        "{ \(shellQuoted(helper.path)) >/dev/null 2>&1 || :; } >/dev/null 2>&1; exit 0"
    }

    static func observerHooks(helper: URL) -> [String: [[String: Any]]] {
        let hook: [String: Any] = ["type": "command", "bash": command(helper: helper), "timeoutSec": 2]
        return Dictionary(uniqueKeysWithValues: events.map { ($0, [hook]) })
    }

    static func files(helper: URL, includeObserverHooks: Bool = false) throws -> [String: Data] {
        guard helper.isFileURL, helper.path.hasPrefix("/"), !helper.path.contains("\0") else {
            throw HookFiles.Failure.unavailable
        }
        let hooks = includeObserverHooks ? observerHooks(helper: helper) : [:]
        return [
            "plugin.json": try JSONSerialization.data(withJSONObject: [
                "name": name, "version": "1.1.0",
                "description": "CMUX Maestro session identity, lifecycle and icon skills",
                "hooks": "hooks.json",
            ], options: [.prettyPrinted, .sortedKeys]),
            "hooks.json": try JSONSerialization.data(withJSONObject: [
                "version": 1, "hooks": hooks,
            ], options: [.prettyPrinted, .sortedKeys]),
        ]
    }
}

nonisolated protocol CopilotSetupFileSystem: Sendable {
    func executable(selected: URL?, path: String) throws -> URL
    func preparePlugin(root: URL, helper: URL, controller: URL, skill: URL) throws -> URL
    func removeMessaging(root: URL) throws
}

nonisolated struct CopilotResourcePreparationFailure: Error {
    enum Outcome { case untouched, restored, unverified }
    let outcome: Outcome
    var restored: Bool { outcome == .restored }
}

nonisolated struct CopilotPluginResources {
    struct Write {
        let file: URL
        let data: Data?
        var permissions: UInt16 = 0o600
        var maximum: Int = 65_536
    }

    let writes: [Write]
    let routes: URL

    func publish() throws {
        let before: [CopilotSetupFileState]
        do {
            guard writes.count <= 32, Set(writes.map(\.file)).count == writes.count,
                  writes.allSatisfy({ change in
                      change.maximum > 0 && change.maximum <= 4_194_304
                          && (change.data.map { !$0.isEmpty && $0.count <= change.maximum } ?? true)
                  })
            else { throw CopilotFileError.tooLarge }
            before = try writes.map { try CopilotSetupFileState.read($0.file, maximum: $0.maximum) }
            let routeDirectory = try HookFiles.directory(routes, create: true)
            defer { close(routeDirectory) }
            let info = try HookFiles.metadata(routeDirectory, directory: true)
            guard info.st_mode & 0o777 == 0o700 else { throw CopilotFileError.unsafePath }
        } catch {
            throw CopilotResourcePreparationFailure(outcome: .untouched)
        }
        var current = before
        var attempted: Int?
        do {
            for (index, change) in writes.enumerated() {
                attempted = index
                current[index] = try current[index].replacing(with: change.data, permissions: change.permissions)
            }
            for file in current { try file.revalidate() }
        } catch {
            do {
                // A rename can succeed before fsync/readback fails. Only the
                // in-flight write may be reconciled to its exact desired bytes.
                if let index = attempted {
                    let actual = try CopilotSetupFileState.read(writes[index].file, maximum: writes[index].maximum)
                    if actual != current[index] {
                        guard actual.data == writes[index].data,
                              actual.stamp?.permissions == (writes[index].data == nil ? nil : writes[index].permissions)
                        else { throw CopilotFileError.changed }
                        current[index] = actual
                    }
                }
                for file in current { try file.revalidate() }
                for index in current.indices.reversed() {
                    current[index] = try current[index].replacing(
                        with: before[index].data, permissions: before[index].stamp?.permissions)
                }
                for index in current.indices {
                    try current[index].revalidate()
                    guard current[index].data == before[index].data,
                          current[index].stamp?.permissions == before[index].stamp?.permissions
                    else { throw CopilotFileError.changed }
                }
            } catch {
                throw CopilotResourcePreparationFailure(outcome: .unverified)
            }
            throw CopilotResourcePreparationFailure(outcome: .restored)
        }
    }
}

nonisolated struct LocalCopilotSetupFiles: CopilotSetupFileSystem {
    var nativeExtensions = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".copilot/extensions", isDirectory: true)
    var messagingRoutes: URL?

    func executable(selected: URL?, path: String) throws -> URL {
        let candidates: [URL]
        if let selected {
            guard selected.isFileURL, selected.path.hasPrefix("/") else { throw HookFiles.Failure.unavailable }
            candidates = [selected]
        } else {
            candidates = path.split(separator: ":").compactMap { component in
                guard component.hasPrefix("/") else { return nil }
                return URL(fileURLWithPath: String(component), isDirectory: true).appendingPathComponent("copilot")
            }
        }
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath()
            var info = stat()
            if stat(resolved.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
               info.st_uid == getuid() || info.st_uid == 0,
               info.st_mode & 0o022 == 0, access(resolved.path, X_OK) == 0 {
                return candidate
            }
        }
        throw HookFiles.Failure.unavailable
    }

    func preparePlugin(root: URL, helper: URL, controller: URL, skill: URL) throws -> URL {
        let plan: CopilotPluginResources
        do { plan = try resources(root: root, helper: helper, controller: controller, skill: skill) }
        catch { throw CopilotResourcePreparationFailure(outcome: .untouched) }
        try plan.publish()
        return root.appendingPathComponent("plugin", isDirectory: true)
    }

    func resources(root: URL, helper: URL, controller: URL, skill: URL,
                   helperExecutable: URL? = nil) throws -> CopilotPluginResources {
        let iconSkill = skill.deletingLastPathComponent().appendingPathComponent("maestro-icon/SKILL.md")
        let resources = skill.deletingLastPathComponent()
        let adapterData = try boundedResource(resources.appendingPathComponent("adapter.mjs"), maximum: 65_536)
        let loaderData = try boundedResource(resources.appendingPathComponent("extension.mjs"), maximum: 8192)
        guard FileManager.default.isExecutableFile(atPath: (helperExecutable ?? helper).path),
              FileManager.default.isReadableFile(atPath: controller.path),
              FileManager.default.isReadableFile(atPath: skill.path),
              FileManager.default.isReadableFile(atPath: iconSkill.path) else {
            throw HookFiles.Failure.unavailable
        }
        let iconSkillData = try boundedResource(iconSkill, maximum: 65_536)
        let glyphRoot = skill.deletingLastPathComponent().appendingPathComponent("NerdFonts", isDirectory: true)
        let glyphFiles: [(String, Int)] = [
            ("glyphnames.json", 2_097_152), ("presets.json", 32_768), ("manifest.json", 8_192),
            ("SymbolsNerdFont-Regular.ttf", 4_194_304), ("LICENSE", 16_384),
            ("NOTICE.md", 16_384), ("GLYPH-SOURCES.md", 32_768)
        ]
        let glyphData = try glyphFiles.map { name, limit in
            (name, try boundedResource(glyphRoot.appendingPathComponent(name), maximum: limit))
        }
        let skillData = try boundedResource(skill, maximum: 65_536)
        let controllerData = try boundedResource(controller, maximum: 1_048_576)
        let nativeRoot = nativeExtensions.appendingPathComponent("maestro", isDirectory: true)
        let routes = messagingRoutes ?? nativeRoot.appendingPathComponent("r", isDirectory: true)
        guard routes.appendingPathComponent(String(repeating: "0", count: 16) + ".sock").path.utf8.count <= 100 else {
            throw HookFiles.Failure.unavailable
        }
        let plugin = root.appendingPathComponent("plugin", isDirectory: true)
        let orchestration = root.deletingLastPathComponent()
            .appendingPathComponent("Orchestration", isDirectory: true)
        let bin = orchestration.appendingPathComponent("bin", isDirectory: true)
        var writes: [CopilotPluginResources.Write] = [
            .init(file: plugin.appendingPathComponent("skills/cmux-maestro-orchestrate/SKILL.md"), data: skillData),
            .init(file: plugin.appendingPathComponent("skills/maestro-icon/SKILL.md"), data: iconSkillData),
            .init(file: bin.appendingPathComponent("identity-helper.json"),
                  data: try JSONSerialization.data(withJSONObject: ["helper": helper.path], options: [.sortedKeys])),
            .init(file: bin.appendingPathComponent("cmux-maestro-orchestrator"), data: controllerData,
                  permissions: 0o700, maximum: 1_048_576),
            .init(file: nativeRoot.appendingPathComponent("adapter.mjs"), data: adapterData),
            .init(file: nativeRoot.appendingPathComponent("extension.mjs"), data: loaderData),
            .init(file: bin.appendingPathComponent("messaging.json"), data: try JSONSerialization.data(withJSONObject: [
                "version": 1, "routes": routes.path, "extension": nativeRoot.path,
            ], options: [.sortedKeys])),
        ]
        for (index, resource) in glyphData.enumerated() {
            writes.append(.init(file: bin.appendingPathComponent("NerdFonts/\(resource.0)"),
                                data: resource.1, maximum: glyphFiles[index].1))
        }
        _ = try obsoleteMessagingSkill(plugin: plugin)
        writes.append(.init(file: plugin.appendingPathComponent("skills/maestro/SKILL.md"), data: nil))
        return CopilotPluginResources(writes: writes, routes: routes)
    }

    private func obsoleteMessagingSkill(plugin: URL) throws -> URL? {
        // Only the obsolete copy in this installer's plugin, never global skills.
        let directory: Int32
        do {
            directory = try CopilotFileAccess.openDirectory(plugin.appendingPathComponent("skills/maestro"), owner: getuid())
        } catch CopilotFileError.missing { return nil }
        defer { close(directory) }
        let info = try HookFiles.metadata(directory, directory: true)
        guard info.st_mode & 0o777 == 0o700 else { throw HookFiles.Failure.unavailable }
        do {
            _ = try CopilotFileAccess.readStableRegular(
                at: directory, filename: "SKILL.md", owner: getuid(), maximum: 65_536, permissions: 0o600
            )
        } catch CopilotFileError.missing { return nil }
        return plugin.appendingPathComponent("skills/maestro/SKILL.md")
    }

    func removeMessaging(root: URL) throws {
        // Remove only the installed entry point/configuration. Do not touch live
        // route bindings, sockets, cached children, or other extensions.
        let targets = [
            nativeExtensions.appendingPathComponent("maestro/extension.mjs"),
            root.deletingLastPathComponent().appendingPathComponent("Orchestration/bin/messaging.json"),
        ]
        for target in targets {
            let directory: Int32
            do {
                directory = try CopilotFileAccess.openDirectory(target.deletingLastPathComponent(), owner: getuid())
            } catch CopilotFileError.missing { continue }
            defer { close(directory) }
            if unlinkat(directory, target.lastPathComponent, 0) != 0, errno != ENOENT {
                throw HookFiles.Failure.unavailable
            }
        }
    }

    private func boundedResource(_ url: URL, maximum: Int) throws -> Data {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
            throw HookFiles.Failure.unavailable
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximum else {
            throw HookFiles.Failure.unavailable
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == size else { throw HookFiles.Failure.unavailable }
        return data
    }
}

// Durable companion to the app install receipt. Only the fixed setup-owned
// resources are checkpointed; provider registration changes use its public RPCs.
nonisolated final class CopilotInstallCheckpoint: @unchecked Sendable {
    static let filename = "install-transaction.json"
    static let maximum = 32 * 1024 * 1024

    static func location(root: URL) -> URL {
        root.deletingLastPathComponent().appendingPathComponent("Orchestration/\(filename)")
    }

    struct Image: Codable, Equatable {
        let data: Data?
        let permissions: UInt16?

        init(_ state: CopilotSetupFileState) {
            data = state.data; permissions = state.stamp?.permissions
        }
        init(data: Data?, permissions: UInt16) {
            self.data = data
            self.permissions = data == nil ? nil : permissions
        }
        func matches(_ state: CopilotSetupFileState) -> Bool { self == Image(state) }
        func valid(maximum: Int) -> Bool {
            guard let data else { return permissions == nil }
            guard let permissions else { return false }
            return !data.isEmpty && data.count <= maximum
                && permissions & ~0o755 == 0 && permissions & 0o400 != 0
        }
    }

    struct Entry: Codable {
        let path: String
        let before: Image
        let desired: Data?
        let permissions: UInt16
        let maximum: Int
    }

    struct Record: Codable {
        let schema: Int
        let id: UUID
        let application: String
        let executable: String
        let generation: CopilotObserverGeneration
        let disabled: Bool
        let metadata: CopilotSetupMetadata
        let foreignGuard: String
        let settings: Image
        let cache: [Image]
        let entries: [Entry]
        let unchanged: Bool
        var phase: String
        var after: [Image]?
        var sourceIdentity: CopilotSourceIdentity? = nil
        var keepsProviderRegistration: Bool? = nil
        var providerMutationStarted: Bool? = nil
        var receiptIntents: [Image]? = nil

        var resourceOnly: Bool {
            keepsProviderRegistration ?? (metadata.plugins.first { $0.name == CopilotPluginManifest.name }?.enabled == false)
        }
    }

    let id: UUID
    let home: URL
    let root: URL
    let application: URL
    let bundle: URL
    let controller: URL
    let skill: URL
    let selected: URL?
    let path: String
    let runner: any CopilotSetupProcessRunner
    let messagingRoutes: URL?
    private var record: Record?
    private var journal: CopilotSetupFileState?
    private var lease: Int32 = -1
    private var observerLease: Int32 = -1
    private(set) var nativePluginStatus = "unverified"
    var helper: URL { application.appendingPathComponent("Contents/Helpers/CMUXMaestroCopilotHook") }
    private var journalURL: URL { Self.location(root: root) }
    private var settingsURL: URL { home.appendingPathComponent(".copilot/settings.json") }
    private var files: LocalCopilotSetupFiles {
        LocalCopilotSetupFiles(nativeExtensions: home.appendingPathComponent(".copilot/extensions"),
                              messagingRoutes: messagingRoutes)
    }
    private var registration: CopilotObserverRegistration {
        CopilotObserverRegistration(home: home, root: root, helper: helper,
            alternateHome: nil, processHome: home.path, installTransaction: id,
            installGeneration: record?.generation,
            beforeReceiptWrite: { before, data, permissions, identity in
                try self.recordReceiptIntent(before: before, data: data, permissions: permissions, identity: identity)
            })
    }

    init(id: UUID, home: URL, root: URL, application: URL, bundle: URL,
         controller: URL, skill: URL, selected: URL?, path: String,
         runner: any CopilotSetupProcessRunner = LocalCopilotSetupRunner(), messagingRoutes: URL? = nil) {
        self.id = id; self.home = home; self.root = root; self.application = application
        self.bundle = bundle; self.controller = controller; self.skill = skill
        self.selected = selected; self.path = path; self.runner = runner
        self.messagingRoutes = messagingRoutes
    }

    deinit {
        if observerLease >= 0 { flock(observerLease, LOCK_UN); close(observerLease) }
        if lease >= 0 { flock(lease, LOCK_UN); close(lease) }
    }

    func registrationStatus() async throws -> IntegrationRegistrationHealth {
        try await CopilotSetupFileWork.run { self.registration.health() }
    }

    func perform(_ action: String, allowAbsent: Bool = false) async throws -> Bool {
        if allowAbsent && ["restore", "release"].contains(action) {
            let absent = try await CopilotSetupFileWork.run {
                try CopilotSetupFileState.read(self.journalURL, maximum: Self.maximum).data == nil
            }
            if absent { return true }
        }
        try await CopilotSetupFileWork.run { try self.acquire() }
        defer {
            if observerLease >= 0 { flock(observerLease, LOCK_UN); close(observerLease); observerLease = -1 }
            if lease >= 0 { flock(lease, LOCK_UN); close(lease); lease = -1 }
        }
        if action == "prepare" {
            try await CopilotSetupFileWork.run {
                let directory = try HookFiles.directory(self.root, create: true)
                defer { close(directory) }
                self.observerLease = openat(directory, ".observer-setup.lock",
                    O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
                guard self.observerLease >= 0 else { throw CopilotFileError.current() }
                _ = try HookFiles.metadata(self.observerLease)
                guard flock(self.observerLease, LOCK_EX | LOCK_NB) == 0 else {
                    throw CopilotRegistrationConflict("A separate observer setup is still running.")
                }
            }
        }
        try await CopilotSetupFileWork.run { try self.load() }
        switch action {
        case "prepare":
            if let record {
                guard record.phase == "prepared" else { throw CopilotFileError.changed }
                try await verifyBefore()
                return record.unchanged
            }
            return try await prepare()
        case "apply":
            guard let record else { throw CopilotFileError.missing }
            if record.phase == "applied" { try await verifyApplied(); return record.unchanged }
            guard record.phase == "prepared" else {
                throw CopilotRegistrationConflict("Interrupted integration must be restored before another apply.")
            }
            try await verifyBefore()
            if !record.unchanged {
                try await CopilotSetupFileWork.run { try self.phase("applying") }
                if record.resourceOnly {
                    try await CopilotSetupFileWork.run {
                        _ = try self.files.preparePlugin(root: self.root, helper: self.helper,
                                                        controller: self.controller, skill: self.skill)
                    }
                } else {
                    let result = await CopilotSetup(files: files, runner: runner,
                        bundleIdentifier: CopilotSetupAccess.productionBundleIdentifier, registration: registration,
                        beforePluginMutation: {
                            self.record?.providerMutationStarted = true
                            try self.save()
                        }).perform(
                            .install, selected: URL(fileURLWithPath: record.executable), path: path,
                            root: root, helper: helper, controller: controller, skill: skill)
                    guard CopilotSetupCommandLine.completion(result).exitCode == 0 else {
                        throw CopilotRegistrationConflict(result.message)
                    }
                }
            }
            let observed = try await metadata()
            try await CopilotSetupFileWork.run {
                try self.verifyForeign(observed)
                if record.resourceOnly,
                   let identity = record.sourceIdentity {
                    try self.verifyAllowed(self.readEntries())
                    try self.registration.refreshCurrentProvenance(observed, identity: identity)
                }
                let identity = try self.registration.recordedSourceIdentity()
                guard identity != nil,
                      self.record?.sourceIdentity == nil || self.record?.sourceIdentity == identity,
                      try self.registration.verifyCurrent(observed, identity: identity) else { throw CopilotFileError.changed }
                self.record?.sourceIdentity = identity
                try self.verifyDesiredCache()
                let states = try self.readEntries()
                try self.verifyAllowed(states)
                self.record?.after = states.map(Image.init)
                try self.phase("applied")
            }
            return record.unchanged
        case "verify":
            guard let record else { throw CopilotFileError.missing }
            try await verifyApplied()
            return record.unchanged
        case "restore":
            if record == nil {
                guard allowAbsent else { throw CopilotFileError.missing }
                return true
            }
            try await restore()
            return true
        case "finish":
            guard let record else { throw CopilotFileError.missing }
            if ["applied", "committed"].contains(record.phase) {
                try await verifyApplied()
                try await CopilotSetupFileWork.run { try self.phase("committed") }
            }
            else if record.phase == "restored" { try await verifyBefore() }
            else { throw CopilotFileError.changed }
            return true
        case "release":
            guard let record else {
                guard allowAbsent else { throw CopilotFileError.missing }
                return true
            }
            guard ["committed", "restored"].contains(record.phase) else { throw CopilotFileError.changed }
            try await CopilotSetupFileWork.run {
                guard let journal = self.journal else { throw CopilotFileError.missing }
                self.journal = try journal.replacing(with: nil)
                self.record = nil
            }
            return true
        default: throw CopilotFileError.io
        }
    }

    private func acquire() throws {
        let directory = try HookFiles.directory(root, create: true)
        defer { close(directory) }
        _ = try HookFiles.metadata(directory, directory: true)
        lease = openat(directory, ".install-setup.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lease >= 0 else { throw CopilotFileError.current() }
        _ = try HookFiles.metadata(lease)
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            close(lease); lease = -1
            throw CopilotRegistrationConflict("Another coordinated integration operation is running.")
        }
    }

    private func load() throws {
        journal = try CopilotSetupFileState.read(journalURL, maximum: Self.maximum)
        guard let data = journal?.data else { return }
        guard journal?.stamp?.permissions == 0o600 else { throw CopilotFileError.unsafePath }
        _ = try CopilotSetupJSON.object(data)
        let value = try JSONDecoder().decode(Record.self, from: data)
        guard try CopilotSetupJSON.data(CopilotSetupJSON.object(JSONEncoder().encode(value))) == data else {
            throw CopilotFileError.unsafePath
        }
        guard value.schema == 1, value.id == id, value.application == application.path,
              value.generation.helper == helper.path, value.metadata.supported,
              value.executable.hasPrefix("/"),
              !value.executable.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              value.metadata.hooks.count <= 256, value.metadata.plugins.count <= 128,
              ["prepared", "applying", "applied", "committed", "restoring", "restored"].contains(value.phase),
              value.entries.count <= 32,
              value.settings.valid(maximum: 65_536), value.cache.allSatisfy({ $0.valid(maximum: 65_536) }),
              value.after == nil || value.after?.count == value.entries.count else { throw CopilotFileError.unsafePath }
        record = value
        if let identity = value.sourceIdentity {
            guard identity.valid, identity.source == registration.plugin.path,
                  identity.version == value.metadata.version else { throw CopilotFileError.unsafePath }
        }
        let targets = try targets(disabled: value.disabled)
        guard targets.count == value.entries.count else { throw CopilotFileError.changed }
        guard value.cache.count == pluginEntries().count else { throw CopilotFileError.unsafePath }
        for (index, pair) in zip(targets, value.entries).enumerated() {
            let (target, entry) = pair
            guard target.file.path == entry.path, target.maximum == entry.maximum,
                  target.permissions == entry.permissions, target.data == entry.desired,
                  entry.before.valid(maximum: entry.maximum),
                  value.after?[index].valid(maximum: entry.maximum) ?? true
            else { throw CopilotFileError.unsafePath }
        }
        if let intents = value.receiptIntents {
            guard intents.count <= 8 else { throw CopilotFileError.tooLarge }
            for image in intents {
                guard image.valid(maximum: 65_536) else { throw CopilotFileError.unsafePath }
                if let data = image.data {
                    try registration.validateReceiptIntent(data, generation: value.generation,
                        identity: value.sourceIdentity,
                        initiallyInstalled: value.metadata.plugins.contains { $0.name == CopilotPluginManifest.name })
                }
            }
        }
    }

    private func recordReceiptIntent(before: CopilotSetupFileState, data: Data?, permissions: UInt16,
                                     identity: CopilotSourceIdentity?) throws {
        guard let record, record.phase == "applying",
              before.url == registration.receiptFile,
              let entry = record.entries.first(where: { $0.path == before.url.path }),
              entry.before.matches(before) || record.receiptIntents?.contains(where: { $0.matches(before) }) == true
        else { throw CopilotRegistrationConflict("Observer receipt changed outside the recorded write intent.") }
        try before.revalidate()
        let image = Image(data: data, permissions: permissions)
        guard image.valid(maximum: entry.maximum) else { throw CopilotFileError.unsafePath }
        if image == entry.before { return }
        if let identity {
            guard identity.valid, identity.source == registration.plugin.path,
                  identity.version == record.metadata.version,
                  record.sourceIdentity == nil || record.sourceIdentity == identity else { throw CopilotFileError.changed }
            self.record?.sourceIdentity = identity
        }
        if let data {
            try registration.validateReceiptIntent(data, generation: record.generation,
                identity: self.record?.sourceIdentity,
                initiallyInstalled: record.metadata.plugins.contains { $0.name == CopilotPluginManifest.name })
        }
        var intents = record.receiptIntents ?? []
        if !intents.contains(image) {
            guard intents.count < 8 else { throw CopilotFileError.tooLarge }
            intents.append(image)
        }
        self.record?.receiptIntents = intents
        try save()
    }

    private func save() throws {
        guard let record, let journal else { throw CopilotFileError.io }
        let data = try CopilotSetupJSON.data(CopilotSetupJSON.object(JSONEncoder().encode(record)))
        guard data.count <= Self.maximum else { throw CopilotFileError.tooLarge }
        self.journal = try journal.replacing(with: data, permissions: 0o600)
    }

    private func phase(_ value: String) throws {
        record?.phase = value
        try save()
    }

    private func targets(disabled: Bool) throws -> [CopilotPluginResources.Write] {
        var values = try files.resources(root: root, helper: helper, controller: controller, skill: skill,
            helperExecutable: bundle.appendingPathComponent("Contents/Helpers/CMUXMaestroCopilotHook")).writes
        let manifest = try CopilotPluginManifest.files(helper: helper)
        var hooks = try CopilotSetupJSON.object(manifest["hooks.json"] ?? Data())
        if disabled { hooks["disableAllHooks"] = true }
        values += [
            .init(file: registration.plugin.appendingPathComponent("plugin.json"), data: manifest["plugin.json"]),
            .init(file: registration.plugin.appendingPathComponent("hooks.json"), data: try CopilotSetupJSON.data(hooks)),
            .init(file: registration.file, data: nil),
            .init(file: registration.receiptFile, data: nil),
        ]
        return values
    }

    private func prepare() async throws -> Bool {
        let executable = try await CopilotSetupFileWork.run {
            try self.registration.validateLocal()
            return try self.files.executable(selected: self.selected, path: self.path)
        }
        let observed = try await metadata(executable: executable)
        let operation = try await CopilotSetupFileWork.run { try self.registration.begin(.install, metadata: observed) }
        if operation.hasBootstrapSource {
            let identity = try await CopilotSetup.bootstrap(runner: runner, executable: executable,
                                                           source: registration.plugin, path: path)
            try await CopilotSetupFileWork.run { try operation.bindSource(identity) }
            let current = try await metadata(executable: executable)
            try await CopilotSetupFileWork.run { try operation.verifySelection(current) }
        }
        return try await CopilotSetupFileWork.run {
            let sourceHooks = try CopilotSetupFileState.read(self.registration.plugin.appendingPathComponent("hooks.json"))
            let cachedHooks = try CopilotSetupFileState.read(self.registration.cache.appendingPathComponent("hooks.json"))
            let pluginDisabled = try [sourceHooks, cachedHooks].contains { file in
                try file.data.map { try CopilotSetupJSON.bool(CopilotSetupJSON.object($0)["disableAllHooks"]) } ?? false
            }
            let targets = try self.targets(disabled: pluginDisabled)
            let before = try targets.map { try CopilotSetupFileState.read($0.file, maximum: $0.maximum) }
            let cache = try targets.filter { $0.file.path.hasPrefix(self.registration.plugin.path + "/") }.map {
                try CopilotSetupFileState.read(self.cacheURL(source: $0.file.path), maximum: $0.maximum)
            }
            let unchanged = try self.registration.verifyCurrent(observed, identity: operation.sourceIdentity)
                && operation.identityIsRecorded()
                && zip(targets.dropLast(2), before.dropLast(2)).allSatisfy {
                    $0.data == $1.data && ($0.data == nil || $0.permissions == $1.stamp?.permissions)
                }
                && zip(targets.filter { $0.file.path.hasPrefix(self.registration.plugin.path + "/") }, cache).allSatisfy {
                    $0.data == $1.data && ($0.data == nil || $0.permissions == $1.stamp?.permissions)
                }
            var resourceOnly = false
            if !operation.pluginEnabled {
                let native = targets.enumerated().filter { $0.element.file.path.hasPrefix(self.registration.plugin.path + "/") }
                resourceOnly = try self.registration.verifyCurrent(observed, identity: operation.sourceIdentity)
                      && native.allSatisfy({ index, target in
                          target.data == before[index].data
                              && (target.data == nil || target.permissions == before[index].stamp?.permissions)
                      })
                      && zip(native.map(\.element), cache).allSatisfy({
                          $0.data == $1.data && ($0.data == nil || $0.permissions == $1.stamp?.permissions)
                      })
            }
            let settings = try CopilotSetupFileState.read(self.settingsURL)
            guard zip(targets, before).allSatisfy({ Image($1).valid(maximum: $0.maximum) }),
                  Image(settings).valid(maximum: 65_536),
                  cache.allSatisfy({ Image($0).valid(maximum: $0.maximum) }) else { throw CopilotFileError.unsafePath }
            try operation.verifyCheckpointInputs()
            self.record = Record(schema: 1, id: self.id, application: self.application.path,
                executable: executable.path, generation: operation.generation, disabled: pluginDisabled,
                metadata: observed, foreignGuard: try self.registration.installationGuard(observed),
                settings: Image(settings), cache: cache.map(Image.init),
                entries: zip(targets, before).map { target, state in
                    Entry(path: target.file.path, before: Image(state), desired: target.data,
                          permissions: target.permissions, maximum: target.maximum)
                }, unchanged: unchanged, phase: "prepared", after: nil)
            self.record?.sourceIdentity = operation.sourceIdentity
            self.record?.keepsProviderRegistration = resourceOnly
            self.record?.providerMutationStarted = false
            self.record?.receiptIntents = []
            try self.save()
            return unchanged
        }
    }

    private func metadata(executable: URL? = nil) async throws -> CopilotSetupMetadata {
        try await CopilotSetupFileWork.run { try self.registration.validateMetadataPaths() }
        let executable = try executable ?? record.map { try files.executable(
            selected: URL(fileURLWithPath: $0.executable), path: path) }
        guard let executable else { throw CopilotFileError.missing }
        switch await runner.metadata(executable: executable, path: path, providerHome: registration.providerHome) {
        case .value(let value):
            guard value.supported else { throw CopilotFileError.io }
            nativePluginStatus = value.plugins.first(where: { $0.name == CopilotPluginManifest.name })
                .map { $0.enabled ? "enabled" : "disabled" } ?? "absent"
            return value
        case .failed:
            throw CopilotRegistrationConflict("Provider metadata could not verify the coordinated installation.")
        }
    }

    private func readEntries() throws -> [CopilotSetupFileState] {
        guard let record else { throw CopilotFileError.missing }
        return try record.entries.map { try CopilotSetupFileState.read(URL(fileURLWithPath: $0.path), maximum: $0.maximum) }
    }

    private func pluginEntries() -> [Entry] {
        record?.entries.filter { $0.path.hasPrefix(registration.plugin.path + "/") } ?? []
    }

    private func cacheURL(source: String) -> URL {
        registration.cache.appendingPathComponent(String(source.dropFirst(registration.plugin.path.count + 1)))
    }

    private func verifyDesiredCache() throws {
        for entry in pluginEntries() {
            let state = try CopilotSetupFileState.read(cacheURL(source: entry.path), maximum: entry.maximum)
            guard state.data == entry.desired,
                  state.stamp?.permissions == (entry.desired == nil ? nil : entry.permissions)
            else { throw CopilotFileError.changed }
        }
    }

    @discardableResult
    private func verifyForeign(_ observed: CopilotSetupMetadata, verifySettings: Bool = true) throws -> CopilotSetupFileState {
        guard let record, observed.version == record.metadata.version,
              try registration.installationGuard(observed) == record.foreignGuard else { throw CopilotFileError.changed }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try record.metadata.plugins.filter { $0.name != CopilotPluginManifest.name }.map { try encoder.encode($0).base64EncodedString() }.sorted()
        let after = try observed.plugins.filter { $0.name != CopilotPluginManifest.name }.map { try encoder.encode($0).base64EncodedString() }.sorted()
        guard before == after else { throw CopilotFileError.changed }
        func foreign(_ hook: CopilotSetupMetadata.Hook) -> Bool {
            !(hook.origin == "plugin" && hook.source == CopilotPluginManifest.name)
                && !(hook.origin == "user" && [registration.file.path,
                    "hooks/\(CopilotObserverRegistration.filename)"].contains(hook.source))
        }
        let beforeHooks = try record.metadata.hooks.filter(foreign).map { try encoder.encode($0).base64EncodedString() }.sorted()
        let afterHooks = try observed.hooks.filter(foreign).map { try encoder.encode($0).base64EncodedString() }.sorted()
        guard beforeHooks == afterHooks else { throw CopilotFileError.changed }
        let current = try CopilotSetupFileState.read(settingsURL)
        guard verifySettings else { return current }
        if !record.settings.matches(current) {
            let original = try record.settings.data.map(CopilotSetupJSON.object) ?? [:]
            var normalized = original
            if normalized["enabledPlugins"] == nil { normalized["enabledPlugins"] = [String: Any]() }
            guard let data = current.data else { throw CopilotFileError.changed }
            let observed = try CopilotSetupJSON.data(CopilotSetupJSON.object(data))
            let originalData = try CopilotSetupJSON.data(original)
            let normalizedData = try CopilotSetupJSON.data(normalized)
            guard observed == originalData || observed == normalizedData
            else { throw CopilotFileError.changed }
        }
        return current
    }

    private func verifyBefore() async throws {
        guard let record else { throw CopilotFileError.missing }
        let observed = try await metadata()
        try await CopilotSetupFileWork.run {
            try self.verifyForeign(observed)
            guard zip(record.entries, try self.readEntries()).allSatisfy({ $0.before.matches($1) }) else {
                throw CopilotFileError.changed
            }
            guard record.settings.matches(try CopilotSetupFileState.read(self.settingsURL)) else { throw CopilotFileError.changed }
            try self.verifyProvider(observed)
        }
    }

    private func verifyApplied() async throws {
        guard let record, ["applied", "committed"].contains(record.phase), let after = record.after else { throw CopilotFileError.changed }
        let observed = try await metadata()
        try await CopilotSetupFileWork.run {
            try self.verifyForeign(observed)
            guard zip(after, try self.readEntries()).allSatisfy({ $0.matches($1) }),
                  try self.registration.verifyCurrent(observed, identity: record.sourceIdentity) else { throw CopilotFileError.changed }
            try self.verifyDesiredCache()
        }
    }

    private func verifyAllowed(_ states: [CopilotSetupFileState]) throws {
        guard let record else { throw CopilotFileError.missing }
        for (index, pair) in zip(record.entries, states).enumerated() {
            let (entry, state) = pair
            if entry.before.matches(state) || record.after?[index].matches(state) == true { continue }
            if record.resourceOnly,
               entry.path == registration.file.path || entry.path == registration.receiptFile.path {
                guard entry.path == registration.receiptFile.path, let before = entry.before.data,
                      let identity = record.sourceIdentity,
                      state.data == (try registration.enrichingReceipt(before, identity: identity)),
                      state.stamp?.permissions == entry.before.permissions else { throw CopilotFileError.changed }
                continue
            }
            if record.phase == "restoring",
               let cacheIndex = pluginEntries().firstIndex(where: { $0.path == entry.path }),
               record.cache[cacheIndex].matches(state) { continue }
            if entry.path == registration.file.path, record.after == nil || record.phase == "restoring", let data = state.data,
               try record.generation.recognizes(data) { continue }
            if entry.path == registration.receiptFile.path, record.after == nil,
               record.receiptIntents?.contains(where: { $0.matches(state) }) == true { continue }
            guard state.data == entry.desired,
                  state.stamp?.permissions == (entry.desired == nil ? nil : entry.permissions)
            else { throw CopilotRegistrationConflict("An owned resource changed outside the recorded installation; restoration refuses to overwrite it.") }
        }
    }

    private func verifyProvider(_ observed: CopilotSetupMetadata) throws {
        guard try providerMatches(observed) else { throw CopilotFileError.changed }
    }

    private func providerMatches(_ observed: CopilotSetupMetadata) throws -> Bool {
        guard let record else { throw CopilotFileError.missing }
        let own = observed.plugins.filter { $0.name == CopilotPluginManifest.name }
        let original = record.metadata.plugins.filter { $0.name == CopilotPluginManifest.name }
        guard own == original else { return false }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let beforeHooks = try record.metadata.hooks.map { try encoder.encode($0).base64EncodedString() }.sorted()
        let afterHooks = try observed.hooks.map { try encoder.encode($0).base64EncodedString() }.sorted()
        guard beforeHooks == afterHooks else { return false }
        if !original.isEmpty {
            for (entry, image) in zip(pluginEntries(), record.cache) {
                guard image.matches(try CopilotSetupFileState.read(cacheURL(source: entry.path), maximum: entry.maximum))
                else { return false }
            }
        }
        return true
    }

    private func installedPayloadMatches(_ observed: CopilotSetupMetadata) throws -> Bool {
        guard let record else { throw CopilotFileError.missing }
        guard observed.plugins.filter({ $0.name == CopilotPluginManifest.name })
                == record.metadata.plugins.filter({ $0.name == CopilotPluginManifest.name }) else { return false }
        return try zip(pluginEntries(), record.cache).allSatisfy {
            $1.matches(try CopilotSetupFileState.read(cacheURL(source: $0.path), maximum: $0.maximum))
        }
    }

    private func restore() async throws {
        guard let record else { throw CopilotFileError.missing }
        if record.phase == "prepared" || record.phase == "restored" {
            try await verifyBefore()
            try await CopilotSetupFileWork.run { try self.phase("restored") }
            return
        }
        let observed = try await metadata()
        let priorInstalled = record.metadata.plugins.contains { $0.name == CopilotPluginManifest.name }
        let priorDisabled = record.metadata.plugins.first { $0.name == CopilotPluginManifest.name }?.enabled == false
        let reapplyDisabled = priorDisabled && !record.resourceOnly && record.providerMutationStarted == true
            && ["applying", "restoring"].contains(record.phase)
        if priorDisabled && !reapplyDisabled,
           observed.plugins.first(where: { $0.name == CopilotPluginManifest.name })?.enabled != false {
            throw CopilotRegistrationConflict("The owned disabled state changed outside an in-progress provider mutation; recovery will not overwrite the newer choice.")
        }
        let binding: CopilotSourceIdentity?
        if priorInstalled || observed.plugins.contains(where: { $0.name == CopilotPluginManifest.name }) {
            let sources = try await CopilotSetupFileWork.run {
                try self.verifyForeign(observed, verifySettings: !reapplyDisabled)
                let states = try self.readEntries()
                try self.verifyAllowed(states)
                return try self.pluginEntries().map {
                    try CopilotSetupFileState.read(URL(fileURLWithPath: $0.path), maximum: $0.maximum)
                }
            }
            let executable = try files.executable(selected: URL(fileURLWithPath: record.executable), path: path)
            let identity = try await CopilotSetup.bootstrap(runner: runner, executable: executable,
                                                           source: registration.plugin, path: path)
            let current = try await metadata()
            try await CopilotSetupFileWork.run {
                for source in sources { try source.revalidate() }
                try self.verifyForeign(current, verifySettings: !reapplyDisabled)
                guard identity.version == record.metadata.version,
                      record.sourceIdentity == nil || record.sourceIdentity == identity,
                      current.plugins.filter({ $0.name == CopilotPluginManifest.name })
                        == observed.plugins.filter({ $0.name == CopilotPluginManifest.name }),
                      current.plugins.filter({ $0.name == CopilotPluginManifest.name }).allSatisfy({
                          $0.isUnmanagedDirectInstall && $0.directSourceId == identity.directSourceId
                      }),
                      record.metadata.plugins.filter({ $0.name == CopilotPluginManifest.name }).allSatisfy({
                          $0.directSourceId == identity.directSourceId
                      }) else {
                    throw CopilotRegistrationConflict("Restoration source authority changed; no same-name replacement is authorized.")
                }
            }
            binding = identity
        } else { binding = nil }
        let restoringMetadata: CopilotSetupMetadata
        if reapplyDisabled, observed.plugins.first(where: { $0.name == CopilotPluginManifest.name })?.enabled == true {
            guard let binding else { throw CopilotFileError.changed }
            let executable = try files.executable(selected: URL(fileURLWithPath: record.executable), path: path)
            try await CopilotSetup.reapplyDisabled(runner: runner, executable: executable, identity: binding.directSourceId,
                                                  path: path, providerHome: registration.providerHome)
            restoringMetadata = try await metadata()
        } else { restoringMetadata = observed }
        if record.resourceOnly {
            try await CopilotSetupFileWork.run {
                let settings = try self.verifyForeign(observed)
                try self.verifyProvider(observed)
                let states = try self.readEntries()
                try self.verifyAllowed(states)
                try self.phase("restoring")
                for (entry, state) in zip(record.entries, states) {
                    _ = try state.replacing(with: entry.before.data, permissions: entry.before.permissions)
                }
                _ = try settings.replacing(with: record.settings.data, permissions: record.settings.permissions)
            }
            try await verifyBefore()
            try await CopilotSetupFileWork.run { try self.phase("restored") }
            return
        }
        let unchanged = try await CopilotSetupFileWork.run {
            _ = try self.verifyForeign(restoringMetadata, verifySettings: !reapplyDisabled)
            let states = try self.readEntries()
            try self.verifyAllowed(states)
            guard zip(record.entries, states).allSatisfy({ $0.before.matches($1) }),
                  try self.providerMatches(restoringMetadata) else { return false }
            let settings = try self.verifyForeign(restoringMetadata)
            _ = try settings.replacing(with: record.settings.data, permissions: record.settings.permissions)
            return true
        }
        if unchanged {
            try await verifyBefore()
            try await CopilotSetupFileWork.run { try self.phase("restored") }
            return
        }
        let replaceProvider = try await CopilotSetupFileWork.run {
            try priorInstalled && !(priorDisabled && self.installedPayloadMatches(restoringMetadata))
        }
        let staging = try await CopilotSetupFileWork.run {
            try self.verifyForeign(restoringMetadata, verifySettings: !reapplyDisabled)
            try self.verifyAllowed(self.readEntries())
            let helpers = [record.generation.helper] + record.entries.compactMap { entry -> String? in
                guard entry.path.hasSuffix("/identity-helper.json"), let data = entry.before.data else { return nil }
                return try? CopilotSetupJSON.object(data)["helper"] as? String
            }
            let identity = binding?.directSourceId
            let pluginEntries = self.pluginEntries()
            let manifestIndex = pluginEntries.firstIndex { $0.path == self.registration.plugin.appendingPathComponent("plugin.json").path }
            let hooksIndex = pluginEntries.firstIndex { $0.path == self.registration.plugin.appendingPathComponent("hooks.json").path }
            guard let manifestIndex, let hooksIndex else { throw CopilotFileError.io }
            let installed = try self.registration.verifyCompensatablePlugin(restoringMetadata, identity: identity, helpers: helpers,
                previousManifest: record.cache[manifestIndex].data, previousHooks: record.cache[hooksIndex].data)
            guard priorDisabled || restoringMetadata.plugins.first(where: { $0.name == CopilotPluginManifest.name })?.enabled != false else {
                throw CopilotRegistrationConflict("The native plugin was disabled after preparation; compensation will not re-enable it.")
            }
            if let binding { self.record?.sourceIdentity = binding }
            try self.phase("restoring")
            let owned = try CopilotSetupFileState.read(self.registration.file)
            let observer = try owned.replacing(with: record.generation.manifest(disabled: true))
            let receipt = try CopilotSetupFileState.read(self.registration.receiptFile)
            let states = try self.readEntries()
            for (entry, state) in zip(record.entries, states) where
                entry.path != self.registration.file.path && entry.path != self.registration.receiptFile.path {
                if !priorInstalled && installed && entry.path.hasPrefix(self.registration.plugin.path + "/") { continue }
                _ = try state.replacing(with: entry.before.data, permissions: entry.before.permissions)
            }
            if replaceProvider {
                // Reinstall the previous selected payload at the same source,
                // even when an earlier incomplete setup had changed its source
                // files without updating the provider's installed copy.
                for (entry, image) in zip(pluginEntries, record.cache) {
                    let current = try CopilotSetupFileState.read(URL(fileURLWithPath: entry.path), maximum: entry.maximum)
                    guard entry.before.matches(current) else { throw CopilotFileError.changed }
                    _ = try current.replacing(with: image.data, permissions: image.permissions)
                }
            }
            let sources = try pluginEntries.map {
                try CopilotSetupFileState.read(URL(fileURLWithPath: $0.path), maximum: $0.maximum)
            }
            return (installed: installed, identity: identity, observer: observer, receipt: receipt, sources: sources)
        }
        if replaceProvider || (!priorInstalled && staging.installed) {
            let executable = try files.executable(selected: URL(fileURLWithPath: record.executable), path: path)
            guard let identity = staging.identity else {
                throw CopilotRegistrationConflict("No authoritative plugin identity was retained; compensation cannot target a same-name installation.")
            }
            let operation: CopilotPluginOperation = priorInstalled
                ? .install(source: registration.plugin, expectedIdentity: identity)
                : .uninstall(identity: identity)
            if priorDisabled {
                try await CopilotSetupFileWork.run {
                    self.record?.providerMutationStarted = true
                    try self.save()
                }
            }
            let result = await runner.plugin(executable: executable, operation: operation, path: path,
                                             providerHome: registration.providerHome)
            if priorDisabled {
                try await CopilotSetup.reapplyDisabled(runner: runner, executable: executable, identity: identity,
                                                      path: path, providerHome: registration.providerHome)
            }
            guard case .value(let receipt) = result else {
                throw CopilotRegistrationConflict("Official plugin compensation failed; preserve the install checkpoint.")
            }
            if priorInstalled {
                guard let plugin = receipt.plugin, plugin.isUnmanagedDirectInstall, plugin.enabled,
                      plugin.name == CopilotPluginManifest.name, plugin.directSourceId == identity else {
                    throw CopilotRegistrationConflict("Official compensation did not return the previous owned source identity.")
                }
            } else if receipt.plugin != nil { throw CopilotFileError.changed }
        }
        let compensated = try await metadata()
        try await CopilotSetupFileWork.run {
            let settings = try self.verifyForeign(compensated)
            let own = compensated.plugins.filter { $0.name == CopilotPluginManifest.name }
            guard own == record.metadata.plugins.filter({ $0.name == CopilotPluginManifest.name }) else {
                throw CopilotFileError.changed
            }
            if priorInstalled {
                for (index, pair) in zip(self.pluginEntries(), record.cache).enumerated() {
                    let (entry, image) = pair
                    guard image.matches(try CopilotSetupFileState.read(self.cacheURL(source: entry.path), maximum: entry.maximum))
                    else { throw CopilotFileError.changed }
                    let source = staging.sources[index]
                    _ = try source.replacing(with: entry.before.data, permissions: entry.before.permissions)
                }
            } else {
                for (source, entry) in zip(staging.sources, self.pluginEntries()) {
                    _ = try source.replacing(with: entry.before.data, permissions: entry.before.permissions)
                }
            }
            for entry in record.entries where entry.path == self.registration.file.path || entry.path == self.registration.receiptFile.path {
                let current = entry.path == self.registration.file.path ? staging.observer : staging.receipt
                _ = try current.replacing(with: entry.before.data, permissions: entry.before.permissions)
            }
            _ = try settings.replacing(with: record.settings.data, permissions: record.settings.permissions)
        }
        try await verifyBefore()
        try await CopilotSetupFileWork.run { try self.phase("restored") }
    }
}

nonisolated enum CopilotProcessResult: Equatable, Sendable {
    case exited(Int32), unavailable, timedOut, cancelled
}

nonisolated protocol CopilotSetupProcessRunner: Sendable {
    func run(executable: URL, arguments: [String], path: String, providerHome: URL?) async -> CopilotProcessResult
    func metadata(executable: URL, path: String, providerHome: URL?) async -> CopilotMetadataResult
    func plugin(executable: URL, operation: CopilotPluginOperation, path: String, providerHome: URL?) async -> CopilotPluginOperationResult
    func sourceIdentity(executable: URL, source: URL, path: String) async -> CopilotSourceIdentityResult
}

private nonisolated final class CopilotSetupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        requested = true
    }
}

nonisolated enum CopilotSetupFileWork {
    private static let queue = DispatchQueue(
        label: "com.jdylanmc.CMUXMaestroPreview.copilot-setup-files",
        qos: .userInitiated, attributes: .concurrent)

    static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let cancellation = CopilotSetupCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value: Value = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        continuation.resume(returning: try operation())
                    } catch { continuation.resume(throwing: error) }
                }
            }
            // Cancellation waits for an already-started writer to finish. A
            // returned result must never race a still-running file mutation.
            try Task.checkCancellation()
            return value
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func restore<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        // Caller cancellation must not abandon a bounded restoration already
        // needed by its completed writes. No provider process runs here.
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

nonisolated struct CopilotProviderLease {
    static let prefix = "CMUX_MAESTRO_INSTALL_LEASE_"
    private static let registrationLock = NSLock()
    let descriptor: Int32
    let token: String
    let python: String
    let helper: String

    static func load(required: Bool = false) throws -> Self? {
        let environment = ProcessInfo.processInfo.environment
        let keys = ["FD", "TOKEN", "PYTHON", "HELPER"]
        if keys.allSatisfy({ environment[prefix + $0] == nil }) && !required { return nil }
        registrationLock.lock()
        defer { registrationLock.unlock() }
        guard let value = environment[prefix + "FD"], let descriptor = Int32(value), descriptor > 2,
              let token = environment[prefix + "TOKEN"], token.count == 32,
              token.allSatisfy({ "0123456789abcdef".contains($0) }),
              let python = environment[prefix + "PYTHON"], python.hasPrefix("/"),
              let helper = environment[prefix + "HELPER"], helper.hasPrefix("/") else {
            throw CopilotRegistrationConflict("Coordinated provider execution requires its inherited install guard.")
        }
        let lease = Self(descriptor: descriptor, token: token, python: python, helper: helper)
        _ = try lease.marker()
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw CopilotFileError.io }
        return lease
    }

    private func marker() throws -> [String: Any] {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), getuid() != 0, geteuid() == getuid(),
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 4096 else { throw CopilotFileError.unsafePath }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard pread(descriptor, &bytes, bytes.count, 0) == bytes.count else { throw CopilotFileError.io }
        let value = try CopilotSetupJSON.object(Data(bytes))
        guard Set(value.keys) == ["schema", "state", "token", "supervisor", "group", "providers"],
              value["schema"] as? Int == 2, value["state"] as? String == "running",
              value["token"] as? String == token, value["group"] as? Int == Int(getpgrp()),
              let supervisor = value["supervisor"] as? Int, supervisor > 1,
              let providers = value["providers"] as? [Int], providers.count <= 128,
              providers.allSatisfy({ $0 > 1 && $0 <= Int(Int32.max) }),
              Set(providers).count == providers.count else {
            throw CopilotRegistrationConflict("The inherited provider guard does not identify this bridge.")
        }
        return value
    }

    func register(_ pid: Int32) throws {
        Self.registrationLock.lock()
        defer { Self.registrationLock.unlock() }
        guard pid > 1, pid != getpgrp(), getpgid(pid) == pid else { throw CopilotFileError.changed }
        var record = try marker()
        guard var providers = record["providers"] as? [Int], providers.count < 128 else { throw CopilotFileError.tooLarge }
        if !providers.contains(Int(pid)) { providers.append(Int(pid)) }
        record["providers"] = providers
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        guard data.count <= 4096,
              data.withUnsafeBytes({ pwrite(descriptor, $0.baseAddress, $0.count, 0) }) == data.count,
              ftruncate(descriptor, off_t(data.count)) == 0, fsync(descriptor) == 0 else {
            throw CopilotFileError.io
        }
    }
}

nonisolated struct LocalCopilotSetupRunner: CopilotSetupProcessRunner {
    var timeout: TimeInterval = 45
    var terminationGrace: TimeInterval = 0.25
    var deadlineNow: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }

    // POSIX waits must not occupy Swift's cooperative executor. Concurrent
    // dispatch workers also let independent invocations make progress together.
    private static let processQueue = DispatchQueue(
        label: "com.jdylanmc.CMUXMaestroPreview.copilot-setup",
        qos: .userInitiated,
        attributes: .concurrent
    )

    func run(executable: URL, arguments: [String], path: String, providerHome: URL? = nil) async -> CopilotProcessResult {
        await invoke(executable: executable, arguments: arguments, path: path, providerHome: providerHome, exchange: nil)
    }

    func metadata(executable: URL, path: String, providerHome: URL? = nil) async -> CopilotMetadataResult {
        do {
            let exchange = try CopilotMetadataExchange()
            defer { exchange.closeAll() }
            let result = await invoke(executable: executable, arguments: [
                "--no-auto-update", "--headless", "--stdio", "--disable-builtin-mcps",
                "--no-custom-instructions", "--no-remote", "--no-remote-export", "--log-level", "error",
            ], path: path, providerHome: providerHome, exchange: exchange)
            guard result == .exited(0), let snapshot = exchange.snapshot else {
                return .failed(result == .exited(0) ? .unavailable : result)
            }
            return .value(snapshot)
        } catch { return .failed(.unavailable) }
    }

    func plugin(executable: URL, operation: CopilotPluginOperation, path: String,
                providerHome: URL? = nil) async -> CopilotPluginOperationResult {
        do {
            let exchange = try CopilotMetadataExchange(operation: operation)
            defer { exchange.closeAll() }
            let result = await invoke(executable: executable, arguments: [
                "--no-auto-update", "--headless", "--stdio", "--disable-builtin-mcps",
                "--no-custom-instructions", "--no-remote", "--no-remote-export", "--log-level", "error",
            ], path: path, providerHome: providerHome, exchange: exchange)
            guard result == .exited(0), let receipt = exchange.pluginReceipt else {
                return .failed(result == .exited(0) ? .unavailable : result, receipt: exchange.pluginReceipt)
            }
            return .value(receipt)
        } catch { return .failed(.unavailable) }
    }

    func sourceIdentity(executable: URL, source: URL, path: String) async -> CopilotSourceIdentityResult {
        guard !Task.isCancelled else { return .failed(.cancelled) }
        var temporary: URL?
        var cleanupConfirmed = true
        let outcome: CopilotSourceIdentityResult
        do {
            let directory = try await CopilotSetupFileWork.restore {
                var template = Array("/private/tmp/cmux-maestro-source-XXXXXX".utf8CString)
                guard let created = mkdtemp(&template) else { throw CopilotFileError.current() }
                return URL(fileURLWithPath: String(cString: created))
            }
            temporary = directory
            let exchange = try CopilotMetadataExchange(operation: .install(source: source, expectedIdentity: nil))
            defer { exchange.closeAll() }
            let result = await invoke(executable: executable, arguments: [
                "--no-auto-update", "--no-auto-login", "--headless", "--stdio", "--disable-builtin-mcps",
                "--no-custom-instructions", "--no-remote", "--no-remote-export", "--log-level", "error",
            ], path: path, providerHome: directory.appendingPathComponent(".copilot"),
               exchange: exchange, isolatedHome: directory)
            cleanupConfirmed = result != .unavailable
            if result == .exited(0), let receipt = exchange.pluginReceipt, let plugin = receipt.plugin,
               let identity = plugin.directSourceId, let version = exchange.providerVersion {
                outcome = .value(.init(source: source.path, version: version, protocolVersion: 3, directSourceId: identity))
            } else { outcome = .failed(result == .exited(0) ? .unavailable : result) }
        } catch { outcome = .failed(.unavailable) }
        if let temporary {
            guard cleanupConfirmed else { return .failed(.unavailable, retainedHome: temporary) }
            do {
                try await CopilotSetupFileWork.restore { try FileManager.default.removeItem(at: temporary) }
            } catch { return .failed(.unavailable, retainedHome: temporary) }
        }
        return outcome
    }

    private func invoke(executable: URL, arguments: [String], path: String, providerHome: URL?,
                        exchange: CopilotMetadataExchange?, isolatedHome: URL? = nil) async -> CopilotProcessResult {
        guard !Task.isCancelled else { return .cancelled }
        let cancellation = CopilotSetupCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.processQueue.async {
                    let result: CopilotProcessResult
                    if cancellation.isCancelled {
                        result = .cancelled
                    } else {
                        var environment = ProcessInfo.processInfo.environment
                        environment["PATH"] = executable.deletingLastPathComponent().path + ":" + path
                        if let providerHome { environment["COPILOT_HOME"] = providerHome.path }
                        if let isolatedHome {
                            for key in ["HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME",
                                        "GH_CONFIG_DIR", "ZDOTDIR", "TMPDIR", "COPILOT_CUSTOM_INSTRUCTIONS_DIRS"] {
                                environment[key] = isolatedHome.path
                            }
                            for key in ["COPILOT_GITHUB_TOKEN", "GITHUB_TOKEN", "GH_TOKEN"] {
                                environment.removeValue(forKey: key)
                            }
                            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
                            environment["GIT_CONFIG_NOSYSTEM"] = "1"
                            environment["BASH_ENV"] = "/dev/null"
                            environment["ENV"] = "/dev/null"
                        }
                        result = execute(executable: executable, arguments: arguments,
                                         environment: environment, cancellation: cancellation, exchange: exchange,
                                         workingDirectory: isolatedHome)
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func execute(executable: URL, arguments: [String], environment: [String: String],
                         cancellation: CopilotSetupCancellation,
                         exchange: CopilotMetadataExchange?, workingDirectory: URL? = nil) -> CopilotProcessResult {
        guard !cancellation.isCancelled else { return .cancelled }
        guard timeout.isFinite, timeout > 0, terminationGrace.isFinite, terminationGrace >= 0
        else { return .unavailable }
        guard let pid = Self.spawn(executable: executable, arguments: arguments,
                                   environment: environment, cancellation: cancellation, exchange: exchange,
                                   workingDirectory: workingDirectory) else {
            return cancellation.isCancelled ? .cancelled : .unavailable
        }
        exchange?.spawned()
        let deadline = deadlineNow().advanced(by: .seconds(timeout))
        var outcome: CopilotProcessResult
        while true {
            do { try exchange?.poll() } catch {
                _ = Self.stopGroup(pid, grace: terminationGrace)
                return .unavailable
            }
            if cancellation.isCancelled {
                outcome = .cancelled
                break
            }
            switch Self.childState(pid) {
            case .exited(let status):
                if Self.groupIsQuiescent(pid) {
                    Self.reap(pid)
                    return .exited(status)
                }
            case .unavailable:
                _ = Self.stopGroup(pid, grace: terminationGrace)
                return .unavailable
            default: break
            }
            if deadlineNow() >= deadline {
                outcome = .timedOut
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // Cancellation cannot bypass cleanup: this synchronous wait stays on
        // the dispatch worker until no member can perform further writes.
        return Self.stopGroup(pid, grace: terminationGrace) ? outcome : .unavailable
    }

    private static func spawn(executable: URL, arguments: [String],
                              environment: [String: String],
                              cancellation: CopilotSetupCancellation,
                              exchange: CopilotMetadataExchange?, workingDirectory: URL? = nil) -> Int32? {
        let lease: CopilotProviderLease?
        do { lease = try CopilotProviderLease.load() }
        catch { return nil }
        var gate: [Int32] = [-1, -1]
        defer { for fd in gate where fd >= 0 { close(fd) } }
        if lease != nil {
            guard pipe(&gate) == 0,
                  gate.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }) else { return nil }
        }
        // Automatic child reaping would invalidate the retained PID/group anchor.
        var disposition = sigaction()
        guard sigaction(SIGCHLD, nil, &disposition) == 0,
              disposition.__sigaction_u.__sa_handler == nil,
              disposition.sa_flags & SA_NOCLDWAIT == 0 else { return nil }
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let workingDirectory {
            let result: Int32
            if #available(macOS 26.0, *) {
                result = posix_spawn_file_actions_addchdir(&actions, workingDirectory.path)
            } else {
                result = posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)
            }
            guard result == 0 else { return nil }
        }
        var mask = sigset_t()
        sigemptyset(&mask)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE] { sigaddset(&defaults, signal) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK
                          | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0
        else { return nil }
        if let exchange {
            guard posix_spawn_file_actions_adddup2(&actions, exchange.input[0], STDIN_FILENO) == 0,
                  posix_spawn_file_actions_adddup2(&actions, exchange.output[1], STDOUT_FILENO) == 0
            else { return nil }
        } else {
            guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
                  posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0
            else { return nil }
        }
        let strings: [String]
        let launchPath: String
        if let lease {
            guard posix_spawn_file_actions_adddup2(&actions, gate[0], 3) == 0 else { return nil }
            launchPath = lease.python
            strings = [lease.python, "-I", "-S", "-B", lease.helper, "--gate", "3", executable.path] + arguments
        } else {
            launchPath = executable.path
            strings = [executable.path] + arguments
        }
        let variables = environment.filter { !$0.key.hasPrefix(CopilotProviderLease.prefix) }.map { "\($0.key)=\($0.value)" }
        guard !(strings + variables).contains(where: { $0.contains("\0") }) else { return nil }
        let argv = strings.map { strdup($0) }
        let envp = variables.map { strdup($0) }
        defer {
            for pointer in argv + envp { free(pointer) }
        }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { return nil }
        var pid: pid_t = 0
        let result = (argv + [nil]).withUnsafeBufferPointer { arguments in
            (envp + [nil]).withUnsafeBufferPointer { environment in
                guard !cancellation.isCancelled else { return ECANCELED }
                return posix_spawn(&pid, launchPath, &actions, &attributes,
                                   arguments.baseAddress, environment.baseAddress)
            }
        }
        guard result == 0 else { return nil }
        if let lease {
            do {
                guard !cancellation.isCancelled else { throw CancellationError() }
                try lease.register(pid)
                var allowed: UInt8 = 71
                guard write(gate[1], &allowed, 1) == 1 else { throw CopilotFileError.io }
            } catch {
                _ = stopGroup(pid, grace: 0.25)
                return nil
            }
        }
        return pid
    }

    private enum ChildState {
        case running, exited(Int32), unavailable
    }

    private static func childState(_ pid: Int32) -> ChildState {
        var info = siginfo_t()
        var result: Int32
        repeat {
            result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        } while result < 0 && errno == EINTR
        guard result == 0 else { return .unavailable }
        guard info.si_pid == pid else { return .running }
        return .exited(info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status)
    }

    private static func groupMembers(_ group: Int32) -> [Int32]? {
        let required = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard required >= 0 else { return nil }
        var members = [Int32](repeating: 0, count: Int(required) / MemoryLayout<Int32>.size + 32)
        let capacity = Int32(members.count * MemoryLayout<Int32>.size)
        let count = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), &members, capacity)
        guard count >= 0, count < capacity else { return nil }
        return members.prefix(Int(count) / MemoryLayout<Int32>.size).filter { $0 > 0 }.sorted()
    }

    private static func groupIsQuiescent(_ group: Int32) -> Bool {
        guard let members = groupMembers(group) else { return false }
        for pid in members {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
                if info.pbi_pgid == UInt32(group), info.pbi_status != 5 { return false }
            } else if errno != ESRCH {
                return false
            }
        }
        // A member may have forked immediately before exiting. Re-enumerate
        // rather than treating a disappearing PID as proof the whole group ended.
        return groupMembers(group) == members
    }

    private static func stopGroup(_ pid: Int32, grace: TimeInterval) -> Bool {
        // posix_spawn atomically gave this invocation a new group named by its
        // PID. WNOWAIT retains its leader until cleanup, preventing group-ID
        // reuse. Never signal the application's group or a reaped invocation.
        guard pid > 1, pid != getpgrp() else { return false }
        if case .unavailable = childState(pid) { return false }
        kill(-pid, SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: .seconds(grace))
        while !groupIsQuiescent(pid), ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if case .unavailable = childState(pid) { return false }
        kill(-pid, SIGKILL)
        while !groupIsQuiescent(pid) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        reap(pid)
        return true
    }

    private static func reap(_ pid: Int32) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
}

nonisolated struct CopilotSetup: Sendable {
    let files: any CopilotSetupFileSystem
    let runner: any CopilotSetupProcessRunner
    private let allowsChanges: Bool
    private let registration: CopilotObserverRegistration?
    private let beforePluginMutation: @Sendable () throws -> Void

    init(files: any CopilotSetupFileSystem = LocalCopilotSetupFiles(),
         runner: any CopilotSetupProcessRunner = LocalCopilotSetupRunner(),
         bundleIdentifier: String? = Bundle.main.bundleIdentifier,
         registration: CopilotObserverRegistration? = nil,
         beforePluginMutation: @escaping @Sendable () throws -> Void = {}) {
        self.files = files
        self.runner = runner
        allowsChanges = CopilotSetupAccess.allowsChanges(bundleIdentifier: bundleIdentifier)
        self.registration = registration
        self.beforePluginMutation = beforePluginMutation
    }

    // Only the explicit consent buttons call this; constructing the app performs
    // no discovery, writes, CLI invocations or provider observation.
    func perform(_ action: CopilotSetupAction, selected: URL?, path: String,
                 root: URL, helper: URL, controller: URL, skill: URL) async -> CopilotSetupResult {
        guard allowsChanges else { return .validationOnly }
        let cancellation = CopilotSetupCancellation()
        return await withTaskCancellationHandler {
            await executeSetup(action, selected: selected, path: path, root: root,
                               helper: helper, controller: controller, skill: skill, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func bootstrap(runner: any CopilotSetupProcessRunner, executable: URL, source: URL,
                          path: String) async throws -> CopilotSourceIdentity {
        switch await runner.sourceIdentity(executable: executable, source: source, path: path) {
        case .value(let identity):
            guard identity.valid, identity.source == source.path else { throw CopilotFileError.changed }
            return identity
        case .failed(let failure, let retainedHome):
            let retained = retainedHome.map { " Disposable bootstrap state retained at \($0.path); cleanup was not confirmed." } ?? ""
            throw CopilotRegistrationConflict("Public owned-source bootstrap failed before provider mutation. \(processFailure(failure).message)\(retained)")
        }
    }

    static func reapplyDisabled(runner: any CopilotSetupProcessRunner, executable: URL, identity: String,
                               path: String, providerHome: URL) async throws {
        guard case .value(let receipt) = await runner.plugin(executable: executable, operation: .disable(identity: identity),
                                                             path: path, providerHome: providerHome),
              let plugin = receipt.plugin, plugin.name == CopilotPluginManifest.name,
              plugin.isUnmanagedDirectInstall, plugin.directSourceId == identity, !plugin.enabled else {
            throw CopilotRegistrationConflict("Official restoration of the owned disabled state was not verified; dedicated staging remains inactive and recovery is pending.")
        }
    }

    private func executeSetup(_ action: CopilotSetupAction, selected: URL?, path: String,
                              root: URL, helper: URL, controller: URL, skill: URL,
                              cancellation: CopilotSetupCancellation) async -> CopilotSetupResult {
        var transaction: CopilotObserverRegistration.Transaction?
        do {
            try Task.checkCancellation()
            let (registration, executable) = try await CopilotSetupFileWork.run {
                let registration = try self.registration ?? CopilotObserverRegistration(
                    home: CopilotPaths.realUserHome(), root: root, helper: helper)
                try registration.validateLocal()
                return (registration, try self.files.executable(selected: selected, path: path))
            }
            let initial: CopilotSetupMetadata
            switch await runner.metadata(executable: executable, path: path, providerHome: registration.providerHome) {
            case .value(let value): initial = value
            case .failed(let failure): return Self.processFailure(failure)
            }
            let operation = try await CopilotSetupFileWork.run {
                try registration.begin(action, metadata: initial, isCancelled: { cancellation.isCancelled })
            }
            transaction = operation
            if operation.hasBootstrapSource {
                let identity = try await Self.bootstrap(runner: runner, executable: executable, source: registration.plugin, path: path)
                try await CopilotSetupFileWork.run { try operation.bindSource(identity) }
                switch await runner.metadata(executable: executable, path: path, providerHome: registration.providerHome) {
                case .value(let value): try await CopilotSetupFileWork.run { try operation.verifySelection(value) }
                case .failed(let failure): return Self.processFailure(failure)
                }
            }
            try await CopilotSetupFileWork.run { try operation.stage() }
            switch await runner.metadata(executable: executable, path: path, providerHome: registration.providerHome) {
            case .value(let value): try await CopilotSetupFileWork.run { try operation.verifyStaging(value) }
            case .failed(let failure): return await Self.incomplete(operation, reason: Self.processFailure(failure).message)
            }
            let pluginOperation: CopilotPluginOperation?
            switch action {
            case .install:
                let plugin = try await CopilotSetupFileWork.run {
                    operation.preparingResources()
                    let plugin = try self.files.preparePlugin(
                        root: root, helper: helper, controller: controller, skill: skill)
                    try operation.acceptPreparedResources()
                    try operation.preparePluginManifest()
                    return plugin
                }
                if operation.sourceIdentity == nil {
                    let identity = try await Self.bootstrap(runner: runner, executable: executable, source: plugin, path: path)
                    try await CopilotSetupFileWork.run { try operation.bindSource(identity) }
                }
                pluginOperation = .install(source: plugin, expectedIdentity: operation.expectedPluginIdentity)
            case .uninstall:
                try await CopilotSetupFileWork.run { try operation.removeRegistration() }
                pluginOperation = operation.expectedPluginIdentity.map { .uninstall(identity: $0) }
            }
            switch await runner.metadata(executable: executable, path: path, providerHome: registration.providerHome) {
            case .value(let value): try await CopilotSetupFileWork.run { try operation.verifySelection(value) }
            case .failed(let failure): return .incomplete(operation.phase, Self.processFailure(failure).message)
            }
            try await CopilotSetupFileWork.run {
                try operation.beforePluginCommand()
                if action == .install || operation.pluginWasInstalled { try self.beforePluginMutation() }
            }
            if action == .install || operation.pluginWasInstalled {
                guard let pluginOperation else { throw CopilotFileError.changed }
                let result = await runner.plugin(executable: executable, operation: pluginOperation, path: path,
                                                 providerHome: registration.providerHome)
                if action == .install, !operation.pluginEnabled {
                    guard let identity = operation.expectedPluginIdentity else { throw CopilotFileError.changed }
                    try await Self.reapplyDisabled(runner: runner, executable: executable, identity: identity,
                                                   path: path, providerHome: registration.providerHome)
                }
                switch result {
                case .failed(let failure, let receipt):
                    if let receipt {
                        try await CopilotSetupFileWork.restore {
                            try operation.pluginCommandSucceeded()
                            try operation.acceptPluginReceipt(receipt)
                        }
                    }
                    return .incomplete(operation.phase, Self.processFailure(failure).message)
                case .value(let receipt):
                    try await CopilotSetupFileWork.run {
                        try operation.pluginCommandSucceeded()
                        try operation.acceptPluginReceipt(receipt)
                    }
                }
            }
            let changed: CopilotSetupMetadata
            switch await runner.metadata(executable: executable, path: path, providerHome: registration.providerHome) {
            case .value(let value): changed = value
            case .failed(let failure): return .incomplete(operation.phase, Self.processFailure(failure).message)
            }
            if action == .uninstall {
                try await CopilotSetupFileWork.run {
                    try operation.verifyRemoval(changed)
                    try self.files.removeMessaging(root: root)
                }
                return .uninstalled
            }
            try await CopilotSetupFileWork.run {
                try operation.verifyPlugin(changed)
                try operation.publish()
            }
            switch await runner.metadata(executable: executable, path: path, providerHome: registration.providerHome) {
            case .value(let value): try await CopilotSetupFileWork.run { try operation.verifyPublished(value) }
            case .failed(let failure): return .incomplete(operation.phase, Self.processFailure(failure).message)
            }
            switch operation.registrationHealth {
            case .disabled: return .installedDisabled
            case .partiallyDisabled: return .installedPartiallyDisabled
            case .disableUnresolved: return .installedDisableUnresolved
            default: return .installed
            }
        } catch {
            let reason: String
            if let conflict = error as? CopilotRegistrationConflict { reason = conflict.message }
            else if let resources = error as? CopilotResourcePreparationFailure {
                if resources.outcome != .unverified, let transaction {
                    do { try await CopilotSetupFileWork.restore { try transaction.resourcesWereRestored() } }
                    catch {
                        return .incomplete(transaction.phase, "Resource restoration could not be verified against helper provenance.")
                    }
                }
                switch resources.outcome {
                case .untouched: reason = "Resource preparation refused before changing resource files."
                case .restored: reason = "Resource preparation failed; previous owned resource files were restored and verified."
                case .unverified: reason = "Resource preparation failed and previous owned resources could not be restored and verified."
                }
            } else if error is CancellationError { reason = CopilotSetupResult.cancelled.message }
            else { reason = "A required file is unsafe, unreadable, malformed or changed during setup. No unverified rollback was attempted." }
            if let transaction, transaction.phase != .preflight {
                return await Self.incomplete(transaction, reason: reason)
            }
            return error is CancellationError ? .cancelled : .conflict(reason)
        }
    }

    private static func incomplete(_ operation: CopilotObserverRegistration.Transaction,
                                   reason: String) async -> CopilotSetupResult {
        do {
            let restored = try await CopilotSetupFileWork.restore { try operation.restoreStaging() }
            return .incomplete(operation.phase, reason + (restored
                ? " Previous observer-file and provenance bytes, absence and permissions were restored and verified; no plugin command ran."
                : " Previous integration state has not been restored."))
        } catch {
            return .incomplete(operation.phase,
                reason + " Observer staging restoration failed verification; retain the incomplete state for recovery.")
        }
    }

    private static func processFailure(_ result: CopilotProcessResult) -> CopilotSetupResult {
        switch result {
        case .exited(let status): status == 0 ? .unavailable : .failed(status)
        case .unavailable: .unavailable
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        }
    }
}
