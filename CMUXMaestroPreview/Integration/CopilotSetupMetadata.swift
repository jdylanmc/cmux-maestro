import Darwin
import Foundation

nonisolated struct CopilotSetupMetadata: Equatable, Sendable {
    struct Hook: Decodable, Equatable, Sendable {
        let hookType: String
        let origin: String
        let source: String
        let enabled: Bool
        let disableKey: String?
    }

    struct Plugin: Decodable, Equatable, Sendable {
        let name: String
        let marketplace: String
        let enabled: Bool
        let directSourceId: String?
    }

    let version: String
    let protocolVersion: Int
    let hooks: [Hook]
    let plugins: [Plugin]

    var supported: Bool { version == "1.0.88" && protocolVersion == 3 }
}

nonisolated enum CopilotMetadataResult: Sendable {
    case value(CopilotSetupMetadata)
    case failed(CopilotProcessResult)
}

// A bounded client of the selected CLI's public metadata RPCs. It never connects
// to an existing server, creates a session, loads an extension or sends a prompt.
nonisolated final class CopilotMetadataExchange: @unchecked Sendable {
    static let maximumOutput = 262_144
    private(set) var input: [Int32] = [-1, -1]
    private(set) var output: [Int32] = [-1, -1]
    private var buffer = Data()
    private var received = 0
    private var responses: [Int: Data] = [:]
    private(set) var snapshot: CopilotSetupMetadata?

    init() throws {
        guard pipe(&input) == 0, pipe(&output) == 0 else {
            closeAll()
            throw CopilotFileError.io
        }
        do {
            for fd in input + output {
                guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw CopilotFileError.io }
            }
            guard fcntl(output[0], F_SETFL, O_NONBLOCK) == 0 else { throw CopilotFileError.io }
            let methods = ["status.get", "hooks.discover", "plugins.list"]
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
                guard snapshot != nil else { throw CopilotFileError.io }
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
                guard (1...3).contains(id), responses[id] == nil, let result = message["result"] else {
                    throw CopilotFileError.io
                }
                responses[id] = try JSONSerialization.data(withJSONObject: result)
            } else if message["method"] as? String == nil {
                throw CopilotFileError.io
            }
        }
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
}
