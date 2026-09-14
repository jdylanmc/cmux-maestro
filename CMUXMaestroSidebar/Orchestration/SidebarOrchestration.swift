import Darwin
import Foundation
import Observation

nonisolated struct SidebarOrchestrationNode: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let runId: UUID
    let parentId: UUID?
    let role: String
    let label: String
    let workspaceId: UUID
    let surfaceId: UUID
    let generation: Int
    let phase: String
    let availability: String
    let createdAt: Date
    let updatedAt: Date

    var isActive: Bool {
        !["reported-completed", "reported-failed", "launch-failed",
          "process-disappeared", "terminal-disappeared"].contains(phase)
    }
}

nonisolated struct SidebarOrchestrationSnapshot: Codable, Equatable, Sendable {
    let version: Int
    let generatedAt: Date
    let complete: Bool
    let omittedCount: Int
    let nodes: [SidebarOrchestrationNode]

    static let empty = Self(
        version: 1, generatedAt: .distantPast, complete: true, omittedCount: 0, nodes: []
    )
}

nonisolated enum SidebarOrchestrationAvailability: Equatable, Sendable {
    case waiting, loading, ready, partial, unavailable, hidden, disconnected
}

nonisolated enum SidebarOrchestrationReader {
    static let maximumBytes = 1_048_576
    static let maximumNodes = 128

    static func read() throws -> SidebarOrchestrationSnapshot {
        let owner = getuid()
        let root = try CopilotFileAccess.openDirectory(try CopilotPaths.orchestrationRoot(), owner: owner)
        defer { close(root) }
        let observer = try CopilotFileAccess.openDirectory(at: root, name: "observer", owner: owner)
        defer { close(observer) }
        let data = try CopilotFileAccess.readStableRegular(
            at: observer, filename: "current.json", owner: owner,
            maximum: maximumBytes, permissions: 0o600
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            guard let date = fractional.date(from: value) ?? standard.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(), debugDescription: "Invalid timestamp"
                )
            }
            return date
        }
        let snapshot = try decoder.decode(SidebarOrchestrationSnapshot.self, from: data)
        guard snapshot.version == 1, snapshot.nodes.count <= maximumNodes,
              snapshot.omittedCount >= 0,
              snapshot.nodes.allSatisfy({
                  !$0.label.isEmpty && $0.label.utf8.count <= 100
                      && $0.generation >= 0
                      && ["coordinator", "worker"].contains($0.role)
              }),
              Set(snapshot.nodes.map(\.id)).count == snapshot.nodes.count else {
            throw CopilotFileError.unsafePath
        }
        return snapshot
    }
}

@Observable
@MainActor
final class SidebarOrchestrationPolling {
    typealias Read = @Sendable () async throws -> SidebarOrchestrationSnapshot
    typealias Pause = @Sendable () async throws -> Void

    private(set) var availability: SidebarOrchestrationAvailability = .waiting
    private(set) var snapshot = SidebarOrchestrationSnapshot.empty
    private var topology = SidebarTopology(.empty)
    private var visible = false
    private var connected = false
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?
    private let read: Read
    private let pause: Pause

    init(
        read: Read? = nil,
        pause: @escaping Pause = { try await Task.sleep(for: .seconds(2)) }
    ) {
        self.read = read ?? {
            try await Task.detached { try SidebarOrchestrationReader.read() }.value
        }
        self.pause = pause
    }

    var roots: [SidebarOrchestrationNode] {
        let ids = Set(snapshot.nodes.map(\.id))
        return snapshot.nodes.filter { node in
            guard let parent = node.parentId else { return true }
            return !ids.contains(parent)
        }
    }

    func children(of id: UUID) -> [SidebarOrchestrationNode] {
        snapshot.nodes.filter { $0.parentId == id }
    }

    func update(topology: SidebarTopology, connected: Bool) {
        guard self.topology != topology || self.connected != connected else { return }
        self.topology = topology
        self.connected = connected
        invalidate()
    }

    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        invalidate()
    }

    private func invalidate() {
        generation &+= 1
        worker?.cancel()
        worker = nil
        snapshot = .empty
        availability = !visible ? .hidden : !connected ? .disconnected : .loading
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard worker == nil, visible, connected else { return }
        let token = generation
        let topology = topology
        let read = read
        let pause = pause
        worker = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let raw = try await read()
                    guard let self, self.generation == token, !Task.isCancelled else { break }
                    let nodes = raw.nodes.filter {
                        topology.workspaceBySurface[$0.surfaceId] == $0.workspaceId
                    }
                    self.snapshot = SidebarOrchestrationSnapshot(
                        version: raw.version, generatedAt: raw.generatedAt,
                        complete: raw.complete && nodes.count == raw.nodes.count,
                        omittedCount: raw.omittedCount + raw.nodes.count - nodes.count,
                        nodes: nodes
                    )
                    self.availability = self.snapshot.complete ? .ready : .partial
                } catch CopilotFileError.missing {
                    self?.snapshot = .empty
                    self?.availability = .waiting
                } catch {
                    self?.snapshot = .empty
                    self?.availability = .unavailable
                }
                do { try await pause() } catch { break }
            }
            guard let self else { return }
            self.worker = nil
            if self.generation != token { self.startIfNeeded() }
        }
    }
}
