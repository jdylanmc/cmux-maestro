import Darwin
import Foundation

nonisolated struct CopilotSetupMetadata: Codable, Equatable, Sendable {
    struct Hook: Codable, Equatable, Sendable {
        let hookType: String
        let origin: String
        let source: String
        let enabled: Bool
        let disableKey: String?
    }

    struct Plugin: Codable, Equatable, Sendable {
        let name: String
        let marketplace: String
        let enabled: Bool
        let directSourceId: String?
        let installedFrom: String?
        let source: String?
        let managed: Bool?
        let managedDesiredEnabled: Bool?
        let installed: Bool?

        init(name: String, marketplace: String, enabled: Bool, directSourceId: String?,
             installedFrom: String? = nil, source: String? = nil, managed: Bool? = nil,
             managedDesiredEnabled: Bool? = nil, installed: Bool? = nil) {
            self.name = name; self.marketplace = marketplace; self.enabled = enabled
            self.directSourceId = directSourceId; self.installedFrom = installedFrom
            self.source = source; self.managed = managed; self.managedDesiredEnabled = managedDesiredEnabled
            self.installed = installed
        }

        var usesInstalledCache: Bool { installedFrom == nil && source == nil && installed != false }
        var isUnmanagedDirectInstall: Bool { usesInstalledCache && marketplace.isEmpty && managed != true }
    }

    let version: String
    let protocolVersion: Int
    let hooks: [Hook]
    let plugins: [Plugin]

    var supported: Bool { ["1.0.88", "1.0.89"].contains(version) && protocolVersion == 3 }
}

nonisolated enum CopilotMetadataResult: Sendable {
    case value(CopilotSetupMetadata)
    case failed(CopilotProcessResult)
}

nonisolated enum CopilotPluginOperation: Sendable {
    case install(source: URL, expectedIdentity: String?)
    case uninstall(identity: String)
    case disable(identity: String)
}

nonisolated struct CopilotPluginReceipt: Sendable {
    let plugin: CopilotSetupMetadata.Plugin?
    let directInstallDeprecated: Bool
}

nonisolated enum CopilotPluginOperationResult: Sendable {
    case value(CopilotPluginReceipt)
    case failed(CopilotProcessResult, receipt: CopilotPluginReceipt? = nil)
}

nonisolated struct CopilotSourceIdentity: Codable, Equatable, Sendable {
    let source: String
    let version: String
    let protocolVersion: Int
    let directSourceId: String

    var valid: Bool {
        source.hasPrefix("/") && source == URL(fileURLWithPath: source).standardizedFileURL.path
            && !source.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && CopilotSetupMetadata(version: version, protocolVersion: protocolVersion, hooks: [], plugins: []).supported
            && CopilotMetadataExchange.validIdentity(directSourceId)
    }
}

nonisolated enum CopilotSourceIdentityResult: Sendable {
    case value(CopilotSourceIdentity)
    case failed(CopilotProcessResult, retainedHome: URL? = nil)
}

// A bounded client of public metadata and explicit plugin-operation RPCs. It never
// connects to an existing server, creates a session or sends a prompt.
nonisolated final class CopilotMetadataExchange: @unchecked Sendable {
    static let maximumOutput = 262_144
    private(set) var input: [Int32] = [-1, -1]
    private(set) var output: [Int32] = [-1, -1]
    private var buffer = Data()
    private var received = 0
    private var responses: [Int: Data] = [:]
    private(set) var snapshot: CopilotSetupMetadata?
    private let operation: CopilotPluginOperation?
    private var operationSent = false
    private var disableSent = false
    private var disableReadbackSent = false
    private(set) var pluginReceipt: CopilotPluginReceipt?
    private(set) var providerVersion: String?

    init(operation: CopilotPluginOperation? = nil) throws {
        self.operation = operation
        guard pipe(&input) == 0, pipe(&output) == 0 else {
            closeAll()
            throw CopilotFileError.io
        }
        do {
            for fd in input + output {
                guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw CopilotFileError.io }
            }
            guard fcntl(output[0], F_SETFL, O_NONBLOCK) == 0 else { throw CopilotFileError.io }
            let methods = operation == nil ? ["status.get", "hooks.discover", "plugins.list"] : ["status.get"]
            var request = Data()
            for (index, method) in methods.enumerated() {
                let body = try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0", "id": index + 1, "method": method, "params": [:],
                ])
                request.append(Data("Content-Length: \(body.count)\r\n\r\n".utf8))
                request.append(body)
            }
            guard request.count < 4096,
                  request.withUnsafeBytes({ Darwin.write(input[1], $0.baseAddress, $0.count) }) == request.count
            else { throw CopilotFileError.io }
        } catch {
            closeAll()
            throw error
        }
    }

    deinit { closeAll() }

    func spawned() {
        closeFD(&input[0])
        closeFD(&output[1])
    }

    func closeAll() {
        for index in input.indices { closeFD(&input[index]) }
        for index in output.indices { closeFD(&output[index]) }
    }

    private func closeFD(_ fd: inout Int32) {
        if fd >= 0 { close(fd); fd = -1 }
    }

    func poll() throws {
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(output[0], &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { break }
                throw CopilotFileError.io
            }
            if count == 0 {
                guard snapshot != nil || pluginReceipt != nil else { throw CopilotFileError.io }
                break
            }
            received += count
            guard received <= Self.maximumOutput else { throw CopilotFileError.tooLarge }
            buffer.append(contentsOf: bytes.prefix(count))
            try parse()
        }
    }

    private func parse() throws {
        let separator = Data("\r\n\r\n".utf8)
        while let end = buffer.range(of: separator) {
            guard end.lowerBound < 1024,
                  let header = String(data: buffer[..<end.lowerBound], encoding: .utf8),
                  header.hasPrefix("Content-Length: "),
                  let length = Int(header.dropFirst("Content-Length: ".count)),
                  length > 0, length <= Self.maximumOutput else { throw CopilotFileError.io }
            guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { return }
            let body = buffer.subdata(in: end.upperBound..<(end.upperBound + length))
            buffer = Data(buffer[(end.upperBound + length)...])
            let message = try CopilotSetupJSON.object(body)
            guard message["jsonrpc"] as? String == "2.0", message["error"] == nil
            else { throw CopilotFileError.io }
            if let id = message["id"] as? Int {
                guard (operation == nil ? (1...3).contains(id) : [1, 4, 5, 6].contains(id)),
                      operation == nil || id != 4 || operationSent,
                      id != 5 || disableSent, id != 6 || disableReadbackSent,
                      responses[id] == nil, let result = message["result"] else {
                    throw CopilotFileError.io
                }
                responses[id] = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
            } else if message["method"] as? String == nil {
                throw CopilotFileError.io
            }
            if let operation {
                try parseOperation(operation)
            }
        }
        guard operation == nil else { return }
        guard responses.count == 3, snapshot == nil else { return }
        struct Status: Decodable { let version: String; let protocolVersion: Int }
        struct Hooks: Decodable {
            let hooks: [CopilotSetupMetadata.Hook]
            let warnings: [String]
            let errors: [String]
        }
        struct Plugins: Decodable { let plugins: [CopilotSetupMetadata.Plugin] }
        let decoder = JSONDecoder()
        guard let statusData = responses[1], let hookData = responses[2], let pluginData = responses[3]
        else { throw CopilotFileError.io }
        let status = try decoder.decode(Status.self, from: statusData)
        let hooks = try decoder.decode(Hooks.self, from: hookData)
        let plugins = try decoder.decode(Plugins.self, from: pluginData)
        guard hooks.errors.isEmpty, hooks.warnings.isEmpty,
              hooks.hooks.count <= 256, plugins.plugins.count <= 128 else { throw CopilotFileError.io }
        snapshot = CopilotSetupMetadata(version: status.version, protocolVersion: status.protocolVersion,
                                        hooks: hooks.hooks, plugins: plugins.plugins)
        // Keep stdin open until every asynchronous response arrives. EOF then
        // lets the one-shot server exit; the normal supervisor still owns cleanup.
        closeFD(&input[1])
    }

    private func parseOperation(_ operation: CopilotPluginOperation) throws {
        guard let statusData = responses[1] else { return }
        struct Status: Decodable { let version: String; let protocolVersion: Int }
        let status = try JSONDecoder().decode(Status.self, from: statusData)
        guard CopilotSetupMetadata(version: status.version, protocolVersion: status.protocolVersion,
                                   hooks: [], plugins: []).supported else { throw CopilotFileError.io }
        providerVersion = status.version
        if !operationSent {
            let method: String
            let params: [String: Any]
            switch operation {
            case .install(let source, _):
                guard source.isFileURL, source.path.hasPrefix("/") else { throw CopilotFileError.unsafePath }
                method = "plugins.install"
                params = ["source": source.path]
            case .uninstall(let identity):
                guard Self.validIdentity(identity) else { throw CopilotFileError.unsafePath }
                method = "plugins.uninstall"
                params = ["name": CopilotPluginManifest.name, "directSourceId": identity]
            case .disable(let identity):
                guard status.version == "1.0.89", Self.validIdentity(identity) else { throw CopilotFileError.unsafePath }
                method = "plugins.list"
                params = [:]
            }
            try send(id: 4, method: method, params: params)
            operationSent = true
        }
        guard let result = responses[4], pluginReceipt == nil else { return }
        switch operation {
        case .install(_, let expected):
            struct Result: Decodable {
                let plugin: CopilotSetupMetadata.Plugin
                let deprecationWarning: String?
            }
            let value = try JSONDecoder().decode(Result.self, from: result)
            guard value.plugin.name == CopilotPluginManifest.name, value.plugin.isUnmanagedDirectInstall, value.plugin.enabled,
                  let identity = value.plugin.directSourceId, Self.validIdentity(identity),
                  expected == nil || expected == identity else { throw CopilotFileError.changed }
            pluginReceipt = CopilotPluginReceipt(plugin: value.plugin, directInstallDeprecated: value.deprecationWarning != nil)
        case .uninstall:
            let value = try JSONSerialization.jsonObject(with: result, options: [.fragmentsAllowed])
            guard value is NSNull || (value as? [String: Any])?.isEmpty == true else { throw CopilotFileError.io }
            pluginReceipt = CopilotPluginReceipt(plugin: nil, directInstallDeprecated: false)
        case .disable(let identity):
            let before = try selectedPlugin(result, identity: identity)
            if !before.enabled {
                pluginReceipt = .init(plugin: before, directInstallDeprecated: false)
            } else {
                if !disableSent {
                    try send(id: 5, method: "plugins.disable", params: ["names": [CopilotPluginManifest.name]])
                    disableSent = true
                }
                guard let disabled = responses[5] else { return }
                let value = try JSONSerialization.jsonObject(with: disabled, options: [.fragmentsAllowed])
                guard value is NSNull || (value as? [String: Any])?.isEmpty == true else { throw CopilotFileError.io }
                if !disableReadbackSent {
                    try send(id: 6, method: "plugins.list", params: [:])
                    disableReadbackSent = true
                }
                guard let data = responses[6] else { return }
                let after = try selectedPlugin(data, identity: identity)
                guard !after.enabled else { throw CopilotFileError.changed }
                pluginReceipt = .init(plugin: after, directInstallDeprecated: false)
            }
        }
        closeFD(&input[1])
    }

    private func selectedPlugin(_ data: Data, identity: String) throws -> CopilotSetupMetadata.Plugin {
        struct Plugins: Decodable { let plugins: [CopilotSetupMetadata.Plugin] }
        let values = try JSONDecoder().decode(Plugins.self, from: data).plugins
        let own = values.filter { $0.name == CopilotPluginManifest.name }
        guard values.count <= 128, own.count == 1, own[0].isUnmanagedDirectInstall,
              own[0].directSourceId == identity else { throw CopilotFileError.changed }
        return own[0]
    }

    private func send(id: Int, method: String, params: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ])
        let request = Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
        guard request.count < 8192,
              request.withUnsafeBytes({ Darwin.write(input[1], $0.baseAddress, $0.count) }) == request.count
        else { throw CopilotFileError.io }
    }

    static func validIdentity(_ identity: String) -> Bool {
        !identity.isEmpty && identity.utf8.count <= 256
            && !identity.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
