import CryptoKit
import Foundation
import Testing

@MainActor
struct LegacySnapshotValidationTests {
    @Test func actualFrozenV1CodecAndValidatorAcceptAdditiveGraphsAndOriginalFixtures() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixturesDirectory = root.appendingPathComponent("CMUXMaestroPreviewTests/Fixtures")
        let frozen = try Data(contentsOf: fixturesDirectory.appendingPathComponent("AgentSessionSnapshot-v1.swift.txt"))
        try #require(SHA256.hash(data: frozen).map { String(format: "%02x", $0) }.joined()
                     == "baf24b16abe354e737bfeafeb987ae25a0991d5455410c1b65c3c73ee1f140a5")
        let frozenSignals = try Data(contentsOf: fixturesDirectory.appendingPathComponent("AgentSignals-v1.swift.txt"))
        try #require(SHA256.hash(data: frozenSignals).map { String(format: "%02x", $0) }.joined()
                     == "1fee615a6c8a4996f093ace358150e0b398b89fd84ea00d63329ca4cc56ff042")
        let directory = root.appendingPathComponent(".build/neutral-v1-fixtures/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Frozen v1 fixture cleanup failed: \(error)") }
        }
        let domain = directory.appendingPathComponent("LegacyDomain.swift")
        try frozen.write(to: domain)
        let signals = directory.appendingPathComponent("LegacySignals.swift")
        try frozenSignals.write(to: signals)
        let main = directory.appendingPathComponent("LegacyMain.swift")
        try Data(Self.driver.utf8).write(to: main)
        let executable = directory.appendingPathComponent("validator")
        let compiled = try await Task.detached {
            try Self.run("/usr/bin/xcrun", arguments: [
                "swiftc", "-swift-version", "5", "-parse-as-library",
                signals.path, domain.path, main.path, "-o", executable.path
            ], directory: directory)
        }.value
        try #require(compiled.status == 0, "\(String(decoding: compiled.output, as: UTF8.self))")
        let fixtures = SidebarTreeFixtures()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let graphs: [(String, [CopilotChildWork], [String], Bool)] = [
            ("pair", [fixtures.child("parent"), fixtures.child("child", parent: "parent")], ["parent"], true),
            ("child-before-parent", [fixtures.child("child", parent: "parent"), fixtures.child("parent")], ["parent"], true),
            ("missing-parent", [fixtures.child("child", parent: "missing")], [], false),
            ("cycle", [fixtures.child("a", parent: "b"), fixtures.child("b", parent: "a")], [], false)
        ]
        var inputs: [(String, Data)] = try ["hierarchy", "taskboard", "degraded-unbound"].map {
            ($0, try Data(contentsOf: fixturesDirectory.appendingPathComponent("\($0).json")))
        }
        var ordinary: Data?
        for (name, children, legacyRoots, lossless) in graphs {
            let snapshot = CopilotSnapshotAdapter.snapshot(
                fixtures.snapshot(sessions: [fixtures.session(children: children, now: now)], now: now),
                workspaceBySurface: fixtures.topology().workspaceBySurface
            )
            try snapshot.validate()
            #expect(snapshot.sessions[0].childWork.map(\.id.rawValue) == legacyRoots)
            #expect(snapshot.sessions[0].childWorkObservation?.items.map(\.id.rawValue) == children.map(\.id))
            #expect(snapshot.sessions[0].childWorkObservation?.items.map(\.parentID) == children.map(\.parentID))
            #expect(snapshot.sessions[0].childWorkObservation?.legacyProjectionIsLossless == lossless)
            if lossless {
                #expect(snapshot.sessions[0].childWork[0].children.map(\.id.rawValue) == ["child"])
            }
            let data = try AgentSessionSnapshotJSONCodec.encode(snapshot)
            inputs.append((name, data))
            if name == "pair" { ordinary = data }
        }
        for (name, data) in inputs {
            let input = directory.appendingPathComponent("\(name).json")
            try data.write(to: input)
            let result = try await Task.detached {
                try Self.run(executable.path, arguments: [input.path], directory: directory)
            }.value
            print("N10-R1 actual base validator: \(name), exit=\(result.status)")
            #expect(result.status == 0, "\(name): \(String(decoding: result.output, as: UTF8.self))")
            #expect(String(decoding: result.output, as: UTF8.self).contains("validated schema=1"))
        }

        // The same executable must retain the actual old negative oracles.
        let ordinaryData = try #require(ordinary)
        var object = try #require(JSONSerialization.jsonObject(with: ordinaryData) as? [String: Any])
        var sessions = try #require(object["sessions"] as? [[String: Any]])
        var roots = try #require(sessions[0]["childWork"] as? [[String: Any]])
        let nested = try #require(roots[0]["children"] as? [[String: Any]])
        roots[0]["children"] = []
        roots.append(contentsOf: nested)
        sessions[0]["childWork"] = roots
        object["sessions"] = sessions
        let invalid = directory.appendingPathComponent("invalid-old-hierarchy.json")
        try JSONSerialization.data(withJSONObject: object).write(to: invalid)
        let rejected = try await Task.detached {
            try Self.run(executable.path, arguments: [invalid.path], directory: directory)
        }.value
        #expect(rejected.status != 0)
        #expect(String(decoding: rejected.output, as: UTF8.self).contains("invalidHierarchyReference"))
        print("N10-R1 actual base negative hierarchy: exit=\(rejected.status)")
        #expect(throws: AgentSessionSnapshotValidationError.self) {
            try AgentSessionSnapshotJSONCodec.decode(JSONSerialization.data(withJSONObject: object)).validate()
        }
        sessions[0]["childWork"] = []
        sessions[0]["state"] = ["availability": "known", "value": "idle"]
        object["sessions"] = sessions
        try JSONSerialization.data(withJSONObject: object).write(to: invalid)
        let unsupportedState = try await Task.detached {
            try Self.run(executable.path, arguments: [invalid.path], directory: directory)
        }.value
        #expect(unsupportedState.status != 0)
        #expect(String(decoding: unsupportedState.output, as: UTF8.self).contains("idle"))
        print("N10-R1 actual base negative state: exit=\(unsupportedState.status)")
    }

    private nonisolated static func run(
        _ executable: String, arguments: [String], directory: URL
    ) throws -> (status: Int32, output: Data) {
        let log = directory.appendingPathComponent("process-\(UUID().uuidString).log")
        try Data().write(to: log)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = handle
        process.standardError = handle
        do { try process.run() } catch { try handle.close(); throw error }
        process.waitUntilExit()
        try handle.close()
        return (process.terminationStatus, try Data(contentsOf: log))
    }

    private static let driver = """
    import Foundation
    @main struct LegacyValidator {
        static func main() {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
                let snapshot = try AgentSessionSnapshotJSONCodec.decode(data)
                try snapshot.validate()
                print("validated schema=\\(snapshot.schemaVersion.rawValue)")
            } catch {
                FileHandle.standardError.write(Data("\\(error)\\n".utf8))
                exit(1)
            }
        }
    }
    """
}
