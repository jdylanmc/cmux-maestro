import Darwin
import Foundation
import CryptoKit

nonisolated enum IntegrationRegistrationHealth: String, Equatable, Sendable {
    case missing, currentOnDisk, stale, disabled, partiallyDisabled, disableUnresolved, incomplete, conflict, unavailable

    var message: String {
        switch self {
        case .missing: "Owned observer registration is missing."
        case .currentOnDisk: "Owned observer registration is current on disk. Unrelated helper callers, loaded hooks and observation are not verified."
        case .stale: "Owned observer registration refers to a previous app location. Enable again to update it."
        case .disabled: "All owned observer events are configured disabled. Setup will preserve that choice."
        case .partiallyDisabled: "Some owned observer events are configured disabled. Other owned events are not marked disabled; loaded behavior is not verified."
        case .disableUnresolved: "Owned observer registration is current on disk, but applicability of configured disable keys is unresolved. Run explicit setup to verify metadata; keys are preserved."
        case .incomplete: "Owned observer setup is incomplete. Retry explicit setup after reviewing its last result."
        case .conflict: "Owned observer registration conflicts with modified, foreign, unsafe or unsupported configuration."
        case .unavailable: "Owned observer registration could not be inspected."
        }
    }
}

nonisolated enum IntegrationSetupPhase: String, Equatable, Sendable {
    case preflight, provenanceRecorded, staged, pluginPrepared, pluginChanged, published, registrationRemoved, pluginRemoved

    var label: String {
        switch self {
        case .preflight: "preflight"
        case .provenanceRecorded: "recording registration provenance"
        case .staged: "disabled-file staging"
        case .pluginPrepared: "plugin preparation"
        case .pluginChanged: "verified plugin replacement"
        case .published: "dedicated-file publication"
        case .registrationRemoved: "observer-file removal"
        case .pluginRemoved: "verified plugin removal"
        }
    }
}

nonisolated struct CopilotRegistrationConflict: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

// Snapshots protect named files, not just an already-open inode. Shared provider
// directories are never chmodded. Every mutation checks the named parent again.
nonisolated struct CopilotSetupFileState: Equatable, Sendable {
    let url: URL
    let data: Data?
    let stamp: CopilotFileStamp?
    let maximum: Int

    static func read(_ url: URL, maximum: Int = 65_536) throws -> Self {
        try validateAncestors(url.deletingLastPathComponent())
        let directory: Int32
        do {
            directory = try CopilotFileAccess.openDirectory(url.deletingLastPathComponent(), owner: getuid())
        } catch CopilotFileError.missing {
            return Self(url: url, data: nil, stamp: nil, maximum: maximum)
        }
        defer { close(directory) }
        _ = try HookFiles.metadata(directory, directory: true)
        let fd: Int32
        do {
            fd = try CopilotFileAccess.openRegular(at: directory, name: url.lastPathComponent, owner: getuid())
        } catch CopilotFileError.missing {
            return Self(url: url, data: nil, stamp: nil, maximum: maximum)
        }
        defer { close(fd) }
        let info = try HookFiles.metadata(fd)
        let before = CopilotFileStamp(info)
        guard info.st_mode & 0o400 != 0, before.size > 0, before.size <= maximum else {
            throw CopilotFileError.unsafePath
        }
        let data = try CopilotFileAccess.read(fd, offset: 0, count: maximum + 1)
        guard data.count == before.size, before == (try CopilotFileAccess.statFile(fd)),
              before == (try CopilotFileAccess.statEntry(at: directory, name: url.lastPathComponent))
        else { throw CopilotFileError.changed }
        return Self(url: url, data: data, stamp: before, maximum: maximum)
    }

    private static func validateAncestors(_ directory: URL) throws {
        var current = directory
        for _ in 0..<128 {
            do {
                let fd = try CopilotFileAccess.openDirectory(current)
                defer { close(fd) }
                let stamp = try CopilotFileAccess.statFile(fd)
                let protectedTemporaryRoot = stamp.uid == 0 && stamp.permissions & 0o1000 != 0
                guard stamp.uid == 0 || stamp.uid == getuid(),
                      stamp.permissions & 0o022 == 0 || protectedTemporaryRoot else {
                    throw CopilotFileError.unsafePath
                }
            } catch CopilotFileError.missing {}
            if current.path == "/" { return }
            current.deleteLastPathComponent()
        }
        throw CopilotFileError.unsafePath
    }

    func revalidate() throws {
        guard try Self.read(url, maximum: maximum) == self else { throw CopilotFileError.changed }
    }

    @discardableResult
    func replacing(with bytes: Data?, permissions: UInt16? = nil) throws -> Self {
        try revalidate()
        let mode = permissions ?? stamp?.permissions ?? 0o600
        guard mode & ~0o755 == 0, mode & 0o400 != 0 else { throw CopilotFileError.unsafePath }
        if bytes == data && (bytes == nil || stamp?.permissions == mode) { return self }
        let parent = url.deletingLastPathComponent()
        if bytes != nil {
            let created = try HookFiles.directory(parent, create: true)
            defer { close(created) }
            _ = try HookFiles.metadata(created, directory: true)
        }
        let directory = try CopilotFileAccess.openDirectory(parent, owner: getuid())
        defer { close(directory) }
        let parentStamp = try CopilotFileAccess.statFile(directory)
        _ = try HookFiles.metadata(directory, directory: true)
        let pending = ".maestro-pending-\(UUID().uuidString)"
        defer { unlinkat(directory, pending, 0) }
        if let bytes {
            let fd = openat(directory, pending, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(mode))
            guard fd >= 0 else { throw CopilotFileError.current() }
            defer { close(fd) }
            guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == bytes.count,
                  fchmod(fd, mode_t(mode)) == 0,
                  fsync(fd) == 0 else { throw CopilotFileError.io }
        }
        try revalidate()
        let current = try CopilotFileAccess.openDirectory(parent, owner: getuid())
        defer { close(current) }
        guard parentStamp.sameFile(as: try CopilotFileAccess.statFile(current)) else {
            throw CopilotFileError.changed
        }
        if bytes != nil {
            let result = data == nil
                ? renameatx_np(directory, pending, directory, url.lastPathComponent, UInt32(RENAME_EXCL))
                : renameat(directory, pending, directory, url.lastPathComponent)
            guard result == 0 else { throw CopilotFileError.current() }
        } else if unlinkat(directory, url.lastPathComponent, 0) != 0 {
            throw CopilotFileError.current()
        }
        guard fsync(directory) == 0 else { throw CopilotFileError.io }
        return try Self.read(url, maximum: maximum)
    }
}

nonisolated enum CopilotSetupJSON {
    static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    static func object(_ data: Data) throws -> [String: Any] {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CopilotFileError.io
            }
            object = decoded
        } catch {
            throw CopilotRegistrationConflict("A required registration or settings file contains malformed JSON.")
        }
        // Foundation accepts duplicate keys. Reject ambiguous disable/ownership
        // declarations rather than silently selecting its last value.
        let bytes = Array(data)
        var objects: [Set<String>] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 123 { objects.append([]) }
            if bytes[index] == 125 { _ = objects.popLast() }
            if bytes[index] == 34 {
                let start = index
                index += 1
                while index < bytes.count, bytes[index] != 34 {
                    if bytes[index] == 92 { index += 1 }
                    index += 1
                }
                guard index < bytes.count else { throw CopilotFileError.io }
                var next = index + 1
                while next < bytes.count, [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 58 {
                    let token = Data([91] + Array(bytes[start...index]) + [93])
                    guard let key = (try JSONSerialization.jsonObject(with: token) as? [String])?.first,
                          !objects.isEmpty, objects[objects.count - 1].insert(key).inserted else {
                        throw CopilotRegistrationConflict("Duplicate JSON keys make registration or disable intent ambiguous.")
                    }
                }
            }
            index += 1
        }
        return object
    }

    static func bool(_ value: Any?) throws -> Bool {
        guard let value else { return false }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw CopilotRegistrationConflict("A hook disable flag is not a Boolean.")
        }
        return number.boolValue
    }
}

nonisolated struct CopilotObserverGeneration: Codable, Equatable {
    let id: UUID
    let helper: String

    func manifest(disabled: Bool) throws -> Data {
        let helperURL = URL(fileURLWithPath: helper)
        guard helper.hasPrefix("/"), helper.utf8.count <= 4096,
              !helper.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw CopilotFileError.unsafePath }
        return try CopilotSetupJSON.data([
            "version": 1,
            "maestro": ["owner": CopilotPluginManifest.name, "schema": 1,
                        "generation": id.uuidString.lowercased(), "helper": helper],
            "disableAllHooks": disabled,
            "hooks": CopilotPluginManifest.observerHooks(helper: helperURL),
        ])
    }

    func recognizes(_ data: Data) throws -> Bool {
        let object = try CopilotSetupJSON.object(data)
        let disabled = try CopilotSetupJSON.bool(object["disableAllHooks"])
        return try CopilotSetupJSON.data(object) == manifest(disabled: disabled)
    }
}

private nonisolated struct CopilotObserverKeyEvidence: Codable {
    let generation: UUID
    let version: String
    let protocolVersion: Int
    let events: [String: String]
    let unrelatedDisabledKeys: [String]

    static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 256
            && !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func keys(_ rows: [CopilotSetupMetadata.Hook]) -> [String: String]? {
        guard rows.count == 3, Set(rows.map(\.hookType)) == Set(CopilotPluginManifest.events),
              rows.allSatisfy({ row in
                  guard let key = row.disableKey else { return false }
                  return validKey(key)
              }) else { return nil }
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            row.disableKey.map { (row.hookType, $0) }
        })
    }

    func applies(to generation: CopilotObserverGeneration) -> Bool {
        self.generation == generation.id
            && CopilotSetupMetadata(version: version, protocolVersion: protocolVersion, hooks: [], plugins: []).supported
            && Set(events.keys) == Set(CopilotPluginManifest.events)
            && events.values.allSatisfy(Self.validKey)
            && unrelatedDisabledKeys.count <= 128 && unrelatedDisabledKeys.allSatisfy(Self.validKey)
    }

    func health(disabledKeys: [String]) -> IntegrationRegistrationHealth {
        let disabled = Set(disabledKeys)
        guard disabled.isSubset(of: Set(events.values).union(unrelatedDisabledKeys)) else { return .disableUnresolved }
        let count = events.values.filter { disabled.contains($0) }.count
        return count == 3 ? .disabled : count > 0 ? .partiallyDisabled : .currentOnDisk
    }
}

private nonisolated struct CopilotObserverReceipt: Codable {
    let schema: Int
    let desired: CopilotObserverGeneration
    let previous: CopilotObserverGeneration?
    let phase: String
    let pluginIdentity: String?
    var sourceIdentity: CopilotSourceIdentity? = nil
    var keyEvidence: CopilotObserverKeyEvidence? = nil

    func encoded() throws -> Data {
        let value = try JSONEncoder().encode(self)
        return try CopilotSetupJSON.data(CopilotSetupJSON.object(value))
    }

    static func decode(_ data: Data) throws -> Self {
        _ = try CopilotSetupJSON.object(data)
        let receipt = try JSONDecoder().decode(Self.self, from: data)
        guard receipt.schema == 1, ["staged", "current"].contains(receipt.phase),
              try receipt.encoded() == data else { throw CopilotFileError.unsafePath }
        return receipt
    }
}

nonisolated final class CopilotObserverRegistration: Sendable {
    static let filename = "cmux-maestro-observer.json"
    static let receiptName = "observer-registration.json"
    let home: URL
    let root: URL
    let helper: URL
    private let alternateHome: String?
    private let processHome: String?
    private let installTransaction: UUID?
    private let installGeneration: CopilotObserverGeneration?

    var providerHome: URL { home.appendingPathComponent(".copilot", isDirectory: true) }
    var file: URL { providerHome.appendingPathComponent("hooks/\(Self.filename)") }
    var receiptFile: URL { root.appendingPathComponent(Self.receiptName) }
    var plugin: URL { root.appendingPathComponent("plugin") }
    var cache: URL { providerHome.appendingPathComponent("installed-plugins/_direct/plugin") }

    private func isOwnedSource(_ hook: CopilotSetupMetadata.Hook) -> Bool {
        // Tested host-only discovery uses a provider-home-relative label;
        // project-scoped discovery uses the absolute path. No arbitrary relative
        // path or another origin is interpreted as this owned file.
        hook.origin == "user"
            && (hook.source == "hooks/\(Self.filename)" || hook.source == file.path)
    }

    init(home: URL, root: URL, helper: URL, alternateHome: String? = ProcessInfo.processInfo.environment["COPILOT_HOME"],
         processHome: String? = ProcessInfo.processInfo.environment["HOME"],
         installTransaction: UUID? = nil, installGeneration: CopilotObserverGeneration? = nil) {
        self.home = home
        self.root = root
        self.helper = helper
        self.alternateHome = alternateHome
        self.processHome = processHome
        self.installTransaction = installTransaction
        self.installGeneration = installGeneration
    }

    func validateHome() throws {
        let checkpoint = try CopilotSetupFileState.read(
            CopilotInstallCheckpoint.location(root: root), maximum: CopilotInstallCheckpoint.maximum)
        if let data = checkpoint.data {
            guard let installTransaction,
                  try JSONDecoder().decode(CopilotInstallCheckpoint.Record.self, from: data).id == installTransaction else {
                throw CopilotRegistrationConflict("A coordinated app installation is pending; recover that installation before separate setup.")
            }
        }
        for (value, expected) in [(alternateHome, providerHome), (processHome, home)] {
            if let value {
                guard value.hasPrefix("/"),
                      !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                      URL(fileURLWithPath: value).standardizedFileURL.path == expected.standardizedFileURL.path else {
                    throw CopilotRegistrationConflict("Conflicting HOME or COPILOT_HOME. Setup supports the standard ~/.copilot only.")
                }
            }
        }
        for directory in [home, providerHome, providerHome.appendingPathComponent("hooks")] {
            do {
                let fd = try CopilotFileAccess.openDirectory(directory, owner: getuid())
                defer { close(fd) }
                _ = try HookFiles.metadata(fd, directory: true)
            } catch CopilotFileError.missing { continue }
        }
    }

    func installationGuard(_ metadata: CopilotSetupMetadata) throws -> String {
        let files = try otherHooks()
        let values = files.map { file -> [String: Any] in
            ["path": file.url.path, "data": file.data?.base64EncodedString() ?? "",
             "permissions": Int(file.stamp?.permissions ?? 0)]
        }
        let bytes = try CopilotSetupJSON.data(["files": values])
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func recognizesInstallReceipt(_ data: Data, generation: CopilotObserverGeneration) throws -> Bool {
        try CopilotObserverReceipt.decode(data).desired == generation
    }

    func installReceiptIdentity(_ data: Data, generation: CopilotObserverGeneration) throws -> String? {
        let receipt = try CopilotObserverReceipt.decode(data)
        guard receipt.desired == generation else { throw CopilotFileError.changed }
        guard let binding = receipt.sourceIdentity, binding.valid, binding.source == plugin.path,
              binding.directSourceId == receipt.pluginIdentity else { return nil }
        return binding.directSourceId
    }

    func recordedSourceIdentity() throws -> CopilotSourceIdentity? {
        guard let data = try CopilotSetupFileState.read(receiptFile).data,
              let binding = try CopilotObserverReceipt.decode(data).sourceIdentity else { return nil }
        guard binding.valid, binding.source == plugin.path else { throw CopilotFileError.changed }
        return binding
    }

    func verifyCompensatablePlugin(_ metadata: CopilotSetupMetadata, identity: String?,
                                   helpers: [String], previousManifest: Data?, previousHooks: Data?) throws -> Bool {
        guard metadata.supported else { throw CopilotFileError.io }
        let own = metadata.plugins.filter { $0.name == CopilotPluginManifest.name }
        guard own.isEmpty || identity != nil else {
            throw CopilotRegistrationConflict("No authoritative install receipt was retained; compensation cannot target a same-name plugin.")
        }
        guard own.count <= 1, own.allSatisfy({ $0.isUnmanagedDirectInstall && identity != nil
            && $0.directSourceId == identity }) else {
            throw CopilotRegistrationConflict("Plugin identity changed outside the owned installation; compensation refuses to overwrite it.")
        }
        if !own.isEmpty {
            let current = try pluginFiles(at: cache)
            if previousManifest == nil || previousHooks == nil
                || current.manifest.data != previousManifest || current.hooks.data != previousHooks {
                let value = try kind(current, helpers: helpers)
                guard value == .hookless || value == .legacy else { throw CopilotFileError.unsafePath }
            }
        }
        return !own.isEmpty
    }

    func verifyCurrent(_ metadata: CopilotSetupMetadata, identity: CopilotSourceIdentity? = nil) throws -> Bool {
        guard [.currentOnDisk, .disabled, .partiallyDisabled, .disableUnresolved].contains(health()) else { return false }
        let operation = try begin(.install, metadata: metadata)
        if let identity { try operation.bindSource(identity) }
        return try operation.verifyAlreadyCurrent(metadata)
    }

    func refreshCurrentProvenance(_ metadata: CopilotSetupMetadata, identity: CopilotSourceIdentity) throws {
        let operation = try begin(.install, metadata: metadata)
        try operation.bindSource(identity)
        try operation.refreshCurrentProvenance(metadata)
    }

    func enrichingReceipt(_ data: Data, identity: CopilotSourceIdentity) throws -> Data {
        let original = try CopilotObserverReceipt.decode(data)
        guard identity.valid, identity.source == plugin.path, original.phase == "current",
              original.pluginIdentity == nil || original.pluginIdentity == identity.directSourceId else {
            throw CopilotFileError.changed
        }
        var enriched = CopilotObserverReceipt(schema: original.schema, desired: original.desired,
            previous: original.previous, phase: original.phase, pluginIdentity: identity.directSourceId)
        enriched.keyEvidence = original.keyEvidence
        enriched.sourceIdentity = identity
        return try enriched.encoded()
    }

    func health() -> IntegrationRegistrationHealth {
        do {
            try validateLocal()
            let owned = try CopilotSetupFileState.read(file)
            let state = try CopilotSetupFileState.read(receiptFile)
            guard let data = owned.data else { return state.data == nil ? .missing : .incomplete }
            guard let receiptData = state.data else { return .conflict }
            let receipt = try CopilotObserverReceipt.decode(receiptData)
            let generation = try recognized(data, receipt: receipt)
            let settings = try readSettings()
            let helpers = [receipt.desired.helper, receipt.previous?.helper].compactMap { $0 }
            let sourceKind = try kind(pluginFiles(at: plugin), helpers: helpers, allowPartial: receipt.phase == "staged")
            let cachedKind = try kind(pluginFiles(at: cache), helpers: helpers)
            if receipt.phase != "current" { return .incomplete }
            if sourceKind == .legacy || cachedKind == .legacy { return .conflict }
            if sourceKind == .missing || cachedKind == .missing { return .incomplete }
            guard generation.helper == helper.path else { return .stale }
            if try CopilotSetupJSON.bool(CopilotSetupJSON.object(data)["disableAllHooks"])
                || settings.globalDisabled { return .disabled }
            guard !settings.disabledKeys.isEmpty else { return .currentOnDisk }
            guard let evidence = receipt.keyEvidence, evidence.applies(to: generation) else { return .disableUnresolved }
            return evidence.health(disabledKeys: settings.disabledKeys)
        } catch is CopilotRegistrationConflict { return .conflict }
        catch CopilotFileError.unsafePath { return .conflict }
        catch CopilotFileError.changed { return .conflict }
        catch { return .unavailable }
    }

    func validateLocal() throws {
        try validateHome()
        _ = try readSettings()
        _ = try otherHooks()
        let state = try CopilotSetupFileState.read(receiptFile)
        let receipt = try state.data.map(CopilotObserverReceipt.decode)
        if let data = try CopilotSetupFileState.read(file).data {
            guard let receipt else { throw CopilotRegistrationConflict("The observer filename has no owned provenance.") }
            _ = try recognized(data, receipt: receipt)
        }
    }

    func validateMetadataPaths() throws {
        try validateHome()
        _ = try readSettings()
        _ = try otherHooks()
        _ = try CopilotSetupFileState.read(file)
        _ = try CopilotSetupFileState.read(receiptFile)
    }

    private func recognized(_ data: Data, receipt: CopilotObserverReceipt) throws -> CopilotObserverGeneration {
        for generation in [receipt.desired, receipt.previous].compactMap({ $0 }) {
            if try generation.recognizes(data) { return generation }
        }
        throw CopilotRegistrationConflict("The observer file does not match its recorded generation and exact owned commands.")
    }

    private func readSettings() throws -> (file: CopilotSetupFileState, globalDisabled: Bool, disabledKeys: [String]) {
        let state = try CopilotSetupFileState.read(providerHome.appendingPathComponent("settings.json"))
        let object = try state.data.map(CopilotSetupJSON.object) ?? [:]
        let disabled = try CopilotSetupJSON.bool(object["disableAllHooks"])
        let keys: [String]
        if let value = object["disabledHooks"] {
            guard let values = value as? [String], values.count <= 1024 else {
                throw CopilotRegistrationConflict("Global disabledHooks is malformed or exceeds the setup bound.")
            }
            keys = values
        } else { keys = [] }
        if let hooks = object["hooks"], containsHelper(hooks) {
            throw CopilotRegistrationConflict("Another inline observer declaration conflicts with the dedicated registration.")
        }
        return (state, disabled, keys)
    }

    private func containsHelper(_ value: Any) -> Bool {
        if let text = value as? String { return text.contains("CMUXMaestroCopilotHook") || text.contains(helper.path) }
        if let values = value as? [Any] { return values.contains(where: containsHelper) }
        if let values = value as? [String: Any] { return values.values.contains(where: containsHelper) }
        return false
    }

    private func otherHooks() throws -> [CopilotSetupFileState] {
        let directory: Int32
        do {
            directory = try CopilotFileAccess.openDirectory(file.deletingLastPathComponent(), owner: getuid())
        } catch CopilotFileError.missing { return [] }
        defer { close(directory) }
        _ = try HookFiles.metadata(directory, directory: true)
        let listing = try CopilotFileAccess.names(at: directory, limit: 128)
        guard !listing.limited else { throw CopilotFileError.tooLarge }
        return try listing.names.filter { $0.lowercased().hasSuffix(".json") && $0 != Self.filename }.map { name in
            let state = try CopilotSetupFileState.read(file.deletingLastPathComponent().appendingPathComponent(name))
            guard let data = state.data else { throw CopilotFileError.changed }
            if try containsHelper(CopilotSetupJSON.object(data)) {
                throw CopilotRegistrationConflict("Another user hook file refers to the observer helper. No duplicate is installed or removed.")
            }
            return state
        }
    }

    fileprivate struct ForeignInventory: Equatable {
        let identities: [Data]
        let hooks: [Data]
    }

    private func foreignInventory(_ metadata: CopilotSetupMetadata) throws -> ForeignInventory {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let identities = try metadata.plugins.filter { $0.name != CopilotPluginManifest.name }
            .map { try encoder.encode($0) }.sorted { $0.lexicographicallyPrecedes($1) }
        let hooks = try metadata.hooks.filter {
            !isOwnedSource($0) && !($0.origin == "plugin" && $0.source == CopilotPluginManifest.name)
        }.map { try encoder.encode($0) }.sorted { $0.lexicographicallyPrecedes($1) }
        // Continuity of public metadata, not authority over foreign source files.
        return ForeignInventory(identities: identities, hooks: hooks)
    }

    private func unrelatedDisabledKeys(_ metadata: CopilotSetupMetadata) -> Set<String> {
        let keys = Set(metadata.hooks.filter {
            !isOwnedSource($0) && !($0.origin == "plugin" && $0.source == CopilotPluginManifest.name)
                && ["user", "plugin"].contains($0.origin) && !$0.enabled
        }.compactMap(\.disableKey).filter(CopilotObserverKeyEvidence.validKey))
        return Set(keys.sorted().prefix(128))
    }

    func begin(_ action: CopilotSetupAction, metadata: CopilotSetupMetadata,
               isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> Transaction {
        try validateHome()
        guard metadata.supported else {
            throw CopilotRegistrationConflict("Observer setup is verified only for Copilot CLI 1.0.88 or 1.0.89, protocol 3.")
        }
        let settings = try readSettings()
        let others = try otherHooks()
        let otherPlugins = try foreignInventory(metadata)
        let owned = try CopilotSetupFileState.read(file)
        let receiptState = try CopilotSetupFileState.read(receiptFile)
        let receipt = try receiptState.data.map(CopilotObserverReceipt.decode)
        let prior = try owned.data.map { data in
            guard let receipt else { throw CopilotRegistrationConflict("The observer filename is occupied without owned provenance.") }
            return try recognized(data, receipt: receipt)
        }
        let helperRecord = try CopilotSetupFileState.read(
            root.deletingLastPathComponent().appendingPathComponent("Orchestration/bin/identity-helper.json"))
        let recordedHelper: String?
        if let data = helperRecord.data {
            let object = try CopilotSetupJSON.object(data)
            guard object.count == 1, let value = object["helper"] as? String, value.hasPrefix("/") else {
                throw CopilotRegistrationConflict("The legacy helper provenance is malformed.")
            }
            recordedHelper = value
        } else { recordedHelper = nil }
        let previousHelper = prior?.helper ?? recordedHelper ?? helper.path
        let recognizedHelpers = [previousHelper, receipt?.previous?.helper,
                                 receipt?.desired.helper, recordedHelper].compactMap { $0 }
        let source = try pluginFiles(at: plugin)
        let installed = try pluginFiles(at: cache)
        let sourceKind = try kind(source, helpers: recognizedHelpers, allowPartial: receipt?.phase == "staged")
        let cachedKind = try kind(installed, helpers: recognizedHelpers)
        let ownPlugins = metadata.plugins.filter { $0.name == CopilotPluginManifest.name }
        if let identity = receipt?.pluginIdentity, let observed = ownPlugins.first?.directSourceId,
           identity != observed {
            throw CopilotRegistrationConflict("The installed plugin no longer matches the recorded provider identity.")
        }
        let installedKind: PluginKind = ownPlugins.isEmpty ? .missing : cachedKind
        guard ownPlugins.count <= 1,
              ownPlugins.allSatisfy({ $0.isUnmanagedDirectInstall && $0.directSourceId != nil }),
              (ownPlugins.isEmpty && (cachedKind == .missing || (sourceKind != .missing && helperRecord.data != nil)))
                || (ownPlugins.count == 1 && installedKind != .missing && sourceKind != .missing)
        else { throw CopilotRegistrationConflict("The installed plugin is foreign, ambiguous or lacks the recognized direct-install files.") }
        let pluginHooks = metadata.hooks.filter { $0.origin == "plugin" && $0.source == CopilotPluginManifest.name }
        let pluginEnabled = ownPlugins.first?.enabled ?? true
        let legacyDiscovered = installedKind == .legacy && pluginEnabled
        guard Set(pluginHooks.map(\.hookType)) == (legacyDiscovered ? Set(CopilotPluginManifest.events) : []),
              pluginHooks.count == (legacyDiscovered ? 3 : 0) else {
            throw CopilotRegistrationConflict("Provider discovery disagrees with the recognized installed plugin declarations.")
        }
        if !pluginEnabled, metadata.version != "1.0.89" {
            throw CopilotRegistrationConflict("Disabled direct-plugin behavior has not been verified for this provider version.")
        }
        let fileDisabled = try owned.data.map { try CopilotSetupJSON.bool(CopilotSetupJSON.object($0)["disableAllHooks"]) } ?? false
        if owned.data != nil, !fileDisabled, installedKind == .legacy, pluginEnabled {
            throw CopilotRegistrationConflict("Both observer sources are active on disk. Setup refuses an ambiguous duplicate.")
        }
        let unchanged = prior?.helper == helper.path && installedKind != .legacy
        if action == .install, !settings.disabledKeys.isEmpty, !unchanged {
            let priorRows = installedKind == .legacy ? pluginHooks
                : prior == nil ? [] : metadata.hooks.filter { isOwnedSource($0) }
            let keys = CopilotObserverKeyEvidence.keys(priorRows)
            let unaffected = keys.map {
                Set(settings.disabledKeys).isDisjoint(with: Set($0.values))
                    && Set(settings.disabledKeys).isSubset(of: unrelatedDisabledKeys(metadata))
            } ?? false
            guard unaffected, priorRows.allSatisfy(\.enabled) else {
                throw CopilotRegistrationConflict(
                    "Affected per-hook disable intent cannot be safely mapped: Copilot omits destination keys for disabled staging files. Legacy registration and settings were not changed.")
            }
        }
        let generation: CopilotObserverGeneration
        if let prior, prior.helper == helper.path { generation = prior }
        else { generation = installGeneration ?? CopilotObserverGeneration(id: UUID(), helper: helper.path) }
        guard generation.helper == helper.path else { throw CopilotFileError.changed }
        _ = try generation.manifest(disabled: true)
        let disabled = settings.globalDisabled || fileDisabled
            || (sourceKind == .legacy && source.disabled) || (installedKind == .legacy && installed.disabled)
            || (installedKind == .legacy && !pluginEnabled)
        let previous = receipt?.previous ?? prior ?? (installedKind == .legacy
            ? CopilotObserverGeneration(id: UUID(), helper: previousHelper) : nil)
        return Transaction(store: self, action: action, generation: generation, previous: previous,
                           disabled: disabled, settings: settings.file, others: others, owned: owned,
                           receipt: receiptState, source: source, installed: installed,
                           helperRecord: helperRecord, pluginWasInstalled: !ownPlugins.isEmpty,
                           pluginEnabled: pluginEnabled,
                           otherPlugins: otherPlugins, pluginIdentity: receipt?.pluginIdentity,
                           selectedPlugin: ownPlugins.first, providerVersion: metadata.version,
                           isCancelled: isCancelled)
    }

    fileprivate enum PluginKind { case missing, legacy, hookless, partial }
    fileprivate struct PluginFiles {
        let manifest: CopilotSetupFileState
        let hooks: CopilotSetupFileState
        let disabled: Bool
    }

    private func pluginFiles(at directory: URL) throws -> PluginFiles {
        let manifest = try CopilotSetupFileState.read(directory.appendingPathComponent("plugin.json"))
        let hooks = try CopilotSetupFileState.read(directory.appendingPathComponent("hooks.json"))
        let disabled = try hooks.data.map { try CopilotSetupJSON.bool(CopilotSetupJSON.object($0)["disableAllHooks"]) } ?? false
        return PluginFiles(manifest: manifest, hooks: hooks, disabled: disabled)
    }

    private func kind(_ files: PluginFiles, helpers: [String], allowPartial: Bool = false) throws -> PluginKind {
        if files.manifest.data == nil, files.hooks.data == nil { return .missing }
        guard let helper = helpers.first,
              files.manifest.data == (try CopilotPluginManifest.files(helper: URL(fileURLWithPath: helper)))["plugin.json"]
                || (allowPartial && files.manifest.data == nil) else {
            throw CopilotRegistrationConflict("Plugin manifest is modified or foreign; it will not be replaced.")
        }
        guard let data = files.hooks.data else {
            if allowPartial { return .partial }
            throw CopilotRegistrationConflict("The plugin hooks file is missing without an interrupted owned transaction.")
        }
        var object = try CopilotSetupJSON.object(data)
        guard try CopilotSetupJSON.data(object) == data else {
            throw CopilotRegistrationConflict("Plugin hook serialization differs from the known producer. Its disable-key identity will not be guessed.")
        }
        object.removeValue(forKey: "disableAllHooks")
        let normalized = try CopilotSetupJSON.data(object)
        for helper in helpers {
            let url = URL(fileURLWithPath: helper)
            if normalized == (try CopilotPluginManifest.files(helper: url, includeObserverHooks: true))["hooks.json"] {
                return files.manifest.data == nil ? .partial : .legacy
            }
            if normalized == (try CopilotPluginManifest.files(helper: url))["hooks.json"] {
                return files.manifest.data == nil ? .partial : .hookless
            }
        }
        throw CopilotRegistrationConflict("Plugin hooks are modified or foreign; they will not be replaced.")
    }

    // One invocation awaits each file-worker step before touching this state.
    // The cross-executor handoff is serial; the file lease excludes other writers.
    nonisolated final class Transaction: @unchecked Sendable {
        private let store: CopilotObserverRegistration
        let action: CopilotSetupAction
        let generation: CopilotObserverGeneration
        private let previous: CopilotObserverGeneration?
        let disabled: Bool
        private var settings: CopilotSetupFileState
        private let others: [CopilotSetupFileState]
        private let otherPlugins: ForeignInventory
        private var owned: CopilotSetupFileState
        private var receipt: CopilotSetupFileState
        private let originalOwned: CopilotSetupFileState
        private let originalReceipt: CopilotSetupFileState
        private var source: PluginFiles
        private let installed: PluginFiles
        private var verifiedInstalled: PluginFiles?
        private var helperRecord: CopilotSetupFileState
        let pluginWasInstalled: Bool
        let pluginEnabled: Bool
        private var stagingVerified = false
        private var pluginCommandPending = false
        private var resourcesPreparationStarted = false
        private var lock: Int32 = -1
        private var ownsLock = false
        private var pluginIdentity: String?
        var expectedPluginIdentity: String? { pluginIdentity }
        private let selectedPlugin: CopilotSetupMetadata.Plugin?
        private let providerVersion: String
        private(set) var sourceIdentity: CopilotSourceIdentity?
        var hasBootstrapSource: Bool { source.manifest.data != nil }
        func identityIsRecorded() throws -> Bool {
            guard let sourceIdentity, let data = receipt.data else { return false }
            return try CopilotObserverReceipt.decode(data).sourceIdentity == sourceIdentity
        }
        private(set) var registrationHealth: IntegrationRegistrationHealth = .currentOnDisk
        private let isCancelled: @Sendable () -> Bool
        private(set) var phase: IntegrationSetupPhase = .preflight

        fileprivate init(store: CopilotObserverRegistration, action: CopilotSetupAction,
                         generation: CopilotObserverGeneration, previous: CopilotObserverGeneration?, disabled: Bool,
                         settings: CopilotSetupFileState, others: [CopilotSetupFileState], owned: CopilotSetupFileState,
                         receipt: CopilotSetupFileState, source: PluginFiles, installed: PluginFiles,
                         helperRecord: CopilotSetupFileState, pluginWasInstalled: Bool,
                         pluginEnabled: Bool,
                         otherPlugins: ForeignInventory, pluginIdentity: String?,
                         selectedPlugin: CopilotSetupMetadata.Plugin?, providerVersion: String,
                         isCancelled: @escaping @Sendable () -> Bool) {
            self.store = store; self.action = action; self.generation = generation; self.previous = previous
            self.disabled = disabled; self.settings = settings; self.others = others
            self.owned = owned; self.receipt = receipt; self.source = source; self.installed = installed
            self.originalOwned = owned; self.originalReceipt = receipt
            self.helperRecord = helperRecord; self.pluginWasInstalled = pluginWasInstalled
            self.pluginEnabled = pluginEnabled
            self.otherPlugins = otherPlugins
            self.pluginIdentity = pluginIdentity
            self.selectedPlugin = selectedPlugin
            self.providerVersion = providerVersion
            self.isCancelled = isCancelled
        }

        deinit {
            if lock >= 0 {
                if ownsLock { flock(lock, LOCK_UN) }
                close(lock)
            }
        }

        func revalidate() throws {
            try revalidateOtherInputs()
            try settings.revalidate()
        }

        func verifyCheckpointInputs() throws {
            try revalidate()
            try source.manifest.revalidate(); try source.hooks.revalidate()
            try installed.manifest.revalidate(); try installed.hooks.revalidate()
        }

        func bindSource(_ identity: CopilotSourceIdentity) throws {
            try verifyCheckpointInputs()
            guard identity.valid, identity.source == store.plugin.path, identity.version == providerVersion,
                  selectedPlugin == nil || selectedPlugin?.directSourceId == identity.directSourceId,
                  pluginIdentity == nil || pluginIdentity == identity.directSourceId else {
                throw CopilotRegistrationConflict("The selected owned-name plugin or receipt is not bound to the exact owned source. No foreign source may be adopted.")
            }
            if let data = receipt.data, let previous = try CopilotObserverReceipt.decode(data).sourceIdentity {
                guard previous.valid, previous.source == identity.source,
                      previous.directSourceId == identity.directSourceId else {
                    throw CopilotRegistrationConflict("Recorded source provenance changed or refers to a foreign source.")
                }
            }
            sourceIdentity = identity
            pluginIdentity = identity.directSourceId
            if phase == .pluginPrepared {
                var record = CopilotObserverReceipt(schema: 1, desired: generation, previous: previous,
                    phase: "staged", pluginIdentity: pluginIdentity)
                record.sourceIdentity = identity
                receipt = try receipt.replacing(with: record.encoded())
            }
        }

        func verifySelection(_ metadata: CopilotSetupMetadata) throws {
            try verifyCheckpointInputs()
            guard metadata.version == providerVersion, metadata.supported,
                  metadata.plugins.filter({ $0.name == CopilotPluginManifest.name }) == selectedPlugin.map({ [$0] }) ?? [],
                  try store.foreignInventory(metadata) == otherPlugins else {
                throw CopilotRegistrationConflict("Provider selection or unrelated inventory changed during owned-source bootstrap.")
            }
        }

        private func revalidateOtherInputs() throws {
            try Task.checkCancellation()
            guard !isCancelled() else { throw CancellationError() }
            try store.validateHome()
            guard try store.otherHooks() == others else { throw CopilotFileError.changed }
            try owned.revalidate()
            try receipt.revalidate()
            try helperRecord.revalidate()
        }

        func stage() throws {
            guard action != .install || pluginEnabled || store.installTransaction != nil else {
                throw CopilotRegistrationConflict("Updating a disabled native plugin requires the coordinated app installer and its durable disabled-state checkpoint.")
            }
            guard (!pluginWasInstalled && pluginIdentity == nil) || sourceIdentity != nil else {
                throw CopilotRegistrationConflict("The existing native plugin needs public exact-source bootstrap before any setup changes.")
            }
            try revalidate()
            try source.manifest.revalidate(); try source.hooks.revalidate()
            try installed.manifest.revalidate(); try installed.hooks.revalidate()
            let directory = try HookFiles.directory(store.root, create: true)
            defer { close(directory) }
            _ = try HookFiles.metadata(directory, directory: true)
            lock = openat(directory, ".observer-setup.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw CopilotFileError.current() }
            _ = try HookFiles.metadata(lock)
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                throw CopilotRegistrationConflict("Another explicit observer setup is already running.")
            }
            ownsLock = true
            try revalidate()
            var record = CopilotObserverReceipt(schema: 1, desired: generation, previous: previous,
                                                phase: "staged", pluginIdentity: pluginIdentity)
            record.sourceIdentity = sourceIdentity
            receipt = try receipt.replacing(with: record.encoded())
            phase = .provenanceRecorded
            if action == .install || owned.data != nil {
                owned = try owned.replacing(with: generation.manifest(disabled: true))
            }
            phase = .staged
        }

        func verifyStaging(_ metadata: CopilotSetupMetadata) throws {
            try revalidate()
            try installed.manifest.revalidate(); try installed.hooks.revalidate()
            guard try store.foreignInventory(metadata) == otherPlugins else {
                throw CopilotRegistrationConflict("Unrelated public provider inventory changed during owned setup.")
            }
            let rows = metadata.hooks.filter { store.isOwnedSource($0) }
            let plugins = metadata.plugins.filter { $0.name == CopilotPluginManifest.name }
            let expected = action == .install || owned.data != nil ? 3 : 0
            guard metadata.supported, rows.count == expected,
                  plugins.count == (pluginWasInstalled ? 1 : 0),
                  plugins.allSatisfy({ $0.isUnmanagedDirectInstall && $0.directSourceId == pluginIdentity
                      && $0.enabled == pluginEnabled }),
                  rows.allSatisfy({ $0.origin == "user" && !$0.enabled }),
                  expected == 0 || Set(rows.map(\.hookType)) == Set(CopilotPluginManifest.events) else {
                throw CopilotRegistrationConflict("Copilot did not confirm the staged file is inactive; the legacy source was not changed.")
            }
            stagingVerified = true
        }

        func preparingResources() { resourcesPreparationStarted = true }

        func resourcesWereRestored() throws {
            let restored = try CopilotSetupFileState.read(helperRecord.url)
            guard restored.data == helperRecord.data,
                  restored.stamp?.permissions == helperRecord.stamp?.permissions else {
                throw CopilotFileError.changed
            }
            helperRecord = restored
            resourcesPreparationStarted = false
        }

        func restoreStaging() throws -> Bool {
            guard !resourcesPreparationStarted, !pluginCommandPending,
                  phase == .provenanceRecorded || phase == .staged else { return false }
            try store.validateHome()
            try owned.revalidate(); try receipt.revalidate()
            try source.manifest.revalidate(); try source.hooks.revalidate()
            try installed.manifest.revalidate(); try installed.hooks.revalidate()
            guard try store.otherHooks() == others else { throw CopilotFileError.changed }
            owned = try owned.replacing(with: originalOwned.data, permissions: originalOwned.stamp?.permissions)
            receipt = try receipt.replacing(with: originalReceipt.data, permissions: originalReceipt.stamp?.permissions)
            try owned.revalidate(); try receipt.revalidate()
            guard owned.data == originalOwned.data, receipt.data == originalReceipt.data,
                  owned.stamp?.permissions == originalOwned.stamp?.permissions,
                  receipt.stamp?.permissions == originalReceipt.stamp?.permissions else {
                throw CopilotFileError.changed
            }
            return true
        }

        func acceptPreparedResources() throws {
            let state = try CopilotSetupFileState.read(helperRecord.url)
            guard let data = state.data,
                  try CopilotSetupJSON.data(CopilotSetupJSON.object(data)) == CopilotSetupJSON.data(["helper": generation.helper]) else {
                throw CopilotRegistrationConflict("Prepared helper provenance did not match the selected app.")
            }
            helperRecord = state
        }

        func preparePluginManifest() throws {
            try revalidate()
            try installed.manifest.revalidate(); try installed.hooks.revalidate()
            guard stagingVerified else { throw CopilotFileError.io }
            var files = try CopilotPluginManifest.files(helper: store.helper)
            if source.disabled || installed.disabled, let hooks = files["hooks.json"] {
                var object = try CopilotSetupJSON.object(hooks)
                object["disableAllHooks"] = true
                files["hooks.json"] = try CopilotSetupJSON.data(object)
            }
            source = PluginFiles(
                manifest: try source.manifest.replacing(with: files["plugin.json"]),
                hooks: try source.hooks.replacing(with: files["hooks.json"]),
                disabled: false)
            phase = .pluginPrepared
        }

        func beforePluginCommand() throws {
            try revalidate()
            try installed.manifest.revalidate(); try installed.hooks.revalidate()
            try source.manifest.revalidate(); try source.hooks.revalidate()
            pluginCommandPending = action == .install || pluginWasInstalled
            guard !pluginCommandPending || sourceIdentity != nil else {
                throw CopilotRegistrationConflict("A public exact-source identity must be recorded before provider mutation.")
            }
        }

        func pluginCommandSucceeded() throws {
            guard pluginCommandPending, phase == .pluginPrepared || phase == .registrationRemoved else {
                throw CopilotFileError.io
            }
            pluginCommandPending = false
            try revalidateOtherInputs()
            let current = try CopilotSetupFileState.read(settings.url)
            if current == settings { return }
            guard let data = current.data else { throw CopilotFileError.changed }
            let original = try settings.data.map(CopilotSetupJSON.object) ?? [:]
            var normalized = original
            if normalized["enabledPlugins"] == nil { normalized["enabledPlugins"] = [String: Any]() }
            let observed = try CopilotSetupJSON.data(CopilotSetupJSON.object(data))
            let originalValues = try CopilotSetupJSON.data(original)
            let normalizedValues = try CopilotSetupJSON.data(normalized)
            // Tested versions rewrite this file on successful plugin commands, even
            // without a value change. Accept only that rewrite or an added
            // empty plugin map; never refresh over changed user/disable intent.
            guard observed == originalValues || observed == normalizedValues else {
                throw CopilotFileError.changed
            }
            settings = current
            try revalidate()
        }

        func acceptPluginReceipt(_ value: CopilotPluginReceipt) throws {
            try revalidate()
            if action == .uninstall {
                guard value.plugin == nil else { throw CopilotFileError.changed }
                return
            }
            guard let plugin = value.plugin, plugin.name == CopilotPluginManifest.name,
                  plugin.isUnmanagedDirectInstall, plugin.enabled, let identity = plugin.directSourceId,
                  CopilotMetadataExchange.validIdentity(identity),
                  sourceIdentity?.directSourceId == identity, pluginIdentity == identity else {
                throw CopilotRegistrationConflict("The public install receipt did not bind the exact owned source identity.")
            }
            pluginIdentity = identity
            var record = CopilotObserverReceipt(schema: 1, desired: generation, previous: previous,
                phase: "staged", pluginIdentity: identity)
            record.sourceIdentity = sourceIdentity
            receipt = try receipt.replacing(with: record.encoded())
        }

        func verifyPlugin(_ metadata: CopilotSetupMetadata) throws {
            try revalidate()
            guard try store.foreignInventory(metadata) == otherPlugins else {
                throw CopilotRegistrationConflict("Unrelated public provider inventory changed during owned setup.")
            }
            guard metadata.supported else { throw CopilotFileError.io }
            let own = metadata.plugins.filter { $0.name == CopilotPluginManifest.name }
            guard own.count == 1, own[0].isUnmanagedDirectInstall, own[0].enabled == pluginEnabled, own[0].directSourceId != nil,
                  sourceIdentity != nil, pluginIdentity == own[0].directSourceId,
                  !metadata.hooks.contains(where: { $0.origin == "plugin" && $0.source == CopilotPluginManifest.name })
            else { throw CopilotRegistrationConflict("The CLI did not verify a single hookless direct plugin. Dedicated hooks remain disabled.") }
            let cache = try store.pluginFiles(at: store.cache)
            guard try store.kind(cache, helpers: [generation.helper]) == .hookless else {
                throw CopilotRegistrationConflict("CLI success did not produce the expected hookless installed registration.")
            }
            verifiedInstalled = cache
            pluginIdentity = own[0].directSourceId
            phase = .pluginChanged
        }

        func publish() throws {
            try revalidate()
            guard phase == .pluginChanged, let verifiedInstalled else { throw CopilotFileError.io }
            try verifiedInstalled.manifest.revalidate(); try verifiedInstalled.hooks.revalidate()
            try source.manifest.revalidate(); try source.hooks.revalidate()
            owned = try owned.replacing(with: generation.manifest(disabled: disabled))
            phase = .published
        }

        func verifyAlreadyCurrent(_ metadata: CopilotSetupMetadata) throws -> Bool {
            guard phase == .preflight,
                  try store.kind(source, helpers: [generation.helper]) == .hookless,
                  try store.kind(installed, helpers: [generation.helper]) == .hookless,
                  let data = receipt.data,
                  sourceIdentity != nil,
                  try CopilotObserverReceipt.decode(data).phase == "current" else { return false }
            verifiedInstalled = installed
            phase = .published
            defer { phase = .preflight }
            try verifyPublished(metadata, persist: false)
            return true
        }

        func refreshCurrentProvenance(_ metadata: CopilotSetupMetadata) throws {
            guard try verifyAlreadyCurrent(metadata), let data = receipt.data, let sourceIdentity else {
                throw CopilotFileError.changed
            }
            receipt = try receipt.replacing(with: store.enrichingReceipt(data, identity: sourceIdentity))
        }

        func verifyPublished(_ metadata: CopilotSetupMetadata, persist: Bool = true) throws {
            try revalidate()
            guard let verifiedInstalled else { throw CopilotFileError.io }
            try verifiedInstalled.manifest.revalidate(); try verifiedInstalled.hooks.revalidate()
            try source.manifest.revalidate(); try source.hooks.revalidate()
            guard try store.foreignInventory(metadata) == otherPlugins else {
                throw CopilotRegistrationConflict("Unrelated public provider inventory changed during owned setup.")
            }
            let rows = metadata.hooks.filter { store.isOwnedSource($0) }
            let plugins = metadata.plugins.filter { $0.name == CopilotPluginManifest.name }
            guard phase == .published, metadata.supported, rows.count == 3,
                  plugins.count == 1, plugins[0].isUnmanagedDirectInstall, plugins[0].enabled == pluginEnabled,
                  plugins[0].directSourceId == pluginIdentity,
                  Set(rows.map(\.hookType)) == Set(CopilotPluginManifest.events),
                  rows.allSatisfy({ $0.origin == "user" && (!disabled || !$0.enabled) }),
                  !metadata.hooks.contains(where: { $0.origin == "plugin" && $0.source == CopilotPluginManifest.name })
            else { throw CopilotRegistrationConflict("Published registration was not confirmed by provider discovery.") }
            let settingsInfo = try store.readSettings()
            var evidence: CopilotObserverKeyEvidence?
            if !disabled, let keys = CopilotObserverKeyEvidence.keys(rows),
               rows.allSatisfy({ row in
                   row.enabled == !settingsInfo.disabledKeys.contains(keys[row.hookType] ?? "")
               }) {
                evidence = CopilotObserverKeyEvidence(
                    generation: generation.id, version: metadata.version, protocolVersion: metadata.protocolVersion,
                    events: keys, unrelatedDisabledKeys: store.unrelatedDisabledKeys(metadata).sorted())
            }
            registrationHealth = disabled ? .disabled
                : evidence?.health(disabledKeys: settingsInfo.disabledKeys)
                    ?? (settingsInfo.disabledKeys.isEmpty && rows.allSatisfy(\.enabled) ? .currentOnDisk : .disableUnresolved)
            var record = CopilotObserverReceipt(
                schema: 1, desired: generation, previous: nil, phase: "current", pluginIdentity: pluginIdentity)
            record.sourceIdentity = sourceIdentity
            record.keyEvidence = evidence
            if persist { receipt = try receipt.replacing(with: record.encoded()) }
        }

        func removeRegistration() throws {
            try revalidate()
            guard stagingVerified else { throw CopilotFileError.io }
            if owned.data != nil { owned = try owned.replacing(with: nil) }
            phase = .registrationRemoved
        }

        func verifyRemoval(_ metadata: CopilotSetupMetadata) throws {
            try revalidate()
            guard try store.foreignInventory(metadata) == otherPlugins else {
                throw CopilotRegistrationConflict("Unrelated public provider inventory changed during owned setup.")
            }
            guard metadata.supported,
                  !metadata.plugins.contains(where: { $0.name == CopilotPluginManifest.name }),
                  !metadata.hooks.contains(where: { store.isOwnedSource($0) || ($0.origin == "plugin" && $0.source == CopilotPluginManifest.name) })
            else { throw CopilotRegistrationConflict("The CLI did not confirm removal of the owned registration.") }
            phase = .pluginRemoved
            receipt = try receipt.replacing(with: nil)
        }
    }
}
