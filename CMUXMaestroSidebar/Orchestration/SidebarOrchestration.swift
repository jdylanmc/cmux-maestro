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
    let worktreeLabel: String?
    let branchLabel: String?
    let createdAt: Date
    let updatedAt: Date

    init(
        id: UUID, runId: UUID, parentId: UUID?, role: String, label: String,
        workspaceId: UUID, surfaceId: UUID, generation: Int, phase: String,
        availability: String, worktreeLabel: String? = nil, branchLabel: String? = nil,
        createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.runId = runId
        self.parentId = parentId
        self.role = role
        self.label = label
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.generation = generation
        self.phase = phase
        self.availability = availability
        self.worktreeLabel = worktreeLabel
        self.branchLabel = branchLabel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isActive: Bool {
        !["reported-completed", "reported-failed", "launch-failed",
          "startup-failed", "turn-failed", "process-disappeared",
          "terminal-disappeared", "resource-retired"].contains(phase)
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
    case waiting, loading, ready, partial, stale, unavailable, hidden, disconnected
}

nonisolated enum SidebarOrchestrationPhase: String, CaseIterable, Hashable, Sendable {
    case registered
    case launching
    case turnQueued = "turn-queued"
    case turnRunning = "turn-running"
    case reportedBlocked = "reported-blocked"
    case reportedCompleted = "reported-completed"
    case reportedFailed = "reported-failed"
    case reportMissing = "report-missing"
    case permissionDenied = "permission-denied"
    case turnFailed = "turn-failed"
    case processDisappeared = "process-disappeared"
    case terminalDisappeared = "terminal-disappeared"
    case launchFailed = "launch-failed"
    case startupFailed = "startup-failed"
    case resourceRetired = "resource-retired"

    func title(availability: String) -> String {
        switch self {
        case .registered: "Registered"
        case .launching: "Launching"
        case .turnQueued: "Queued"
        case .turnRunning: "Working"
        case .reportedBlocked: "Blocked"
        case .reportedCompleted:
            availability == "idle" ? "Completed · available" : "Completed"
        case .reportedFailed:
            availability == "idle" ? "Failed · available" : "Failed"
        case .reportMissing: "Report missing"
        case .permissionDenied: "Permission denied · available"
        case .turnFailed: "Turn failed"
        case .processDisappeared: "Process disappeared"
        case .terminalDisappeared: "Terminal disappeared"
        case .launchFailed: "Launch failed"
        case .startupFailed: "Startup failed"
        case .resourceRetired: "Resource retired"
        }
    }

    func symbolName(role: String) -> String {
        if role == "coordinator" { return "person.2" }
        return self == .permissionDenied ? "exclamationmark.shield" : "terminal"
    }
}

nonisolated enum SidebarOrchestrationReader {
    static let maximumBytes = 1_048_576
    static let maximumNodes = 128
    static let maximumDepth = 8
    static let futureTolerance: TimeInterval = 300
    static let staleInterval: TimeInterval = 60

    static func read() throws -> SidebarOrchestrationSnapshot {
        let owner = getuid()
        let observer = try CopilotFileAccess.openDirectory(
            try CopilotPaths.orchestrationObserverDirectory(), owner: owner
        )
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
        try validate(snapshot)
        return snapshot
    }

    static func validate(_ snapshot: SidebarOrchestrationSnapshot, now: Date = Date()) throws {
        guard snapshot.version == 1, snapshot.nodes.count <= maximumNodes,
              snapshot.omittedCount >= 0,
              Set(snapshot.nodes.map(\.id)).count == snapshot.nodes.count,
              snapshot.generatedAt <= now.addingTimeInterval(futureTolerance) else {
            throw CopilotFileError.unsafePath
        }
        let nodes = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        var surfaces = Set<UUID>()
        var rootsByRun: [UUID: Int] = [:]
        for node in snapshot.nodes {
            guard !node.label.isEmpty, node.label.utf8.count <= 100,
                  boundedLabel(node.worktreeLabel), boundedLabel(node.branchLabel),
                  node.generation >= 0, node.createdAt <= node.updatedAt,
                  node.updatedAt <= now.addingTimeInterval(futureTolerance),
                  node.updatedAt <= snapshot.generatedAt.addingTimeInterval(futureTolerance),
                  surfaces.insert(node.surfaceId).inserted,
                  validState(node) else {
                throw CopilotFileError.unsafePath
            }

            if node.parentId == nil {
                rootsByRun[node.runId, default: 0] += 1
            }
        }
        guard rootsByRun.values.allSatisfy({ $0 == 1 }) else {
            throw CopilotFileError.unsafePath
        }
        for node in snapshot.nodes {
            var current = node
            var seen = Set([node.id])
            var depth = 0
            while let parentId = current.parentId {
                guard let parent = nodes[parentId], seen.insert(parent.id).inserted,
                      parent.runId == node.runId,
                      parent.workspaceId == node.workspaceId else {
                    throw CopilotFileError.unsafePath
                }
                depth += 1
                guard depth <= maximumDepth else { throw CopilotFileError.unsafePath }
                current = parent
            }
            guard current.role == "coordinator" else { throw CopilotFileError.unsafePath }
        }
    }

    private static func boundedLabel(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= 120
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func isStale(_ snapshot: SidebarOrchestrationSnapshot, now: Date = Date()) -> Bool {
        now.timeIntervalSince(snapshot.generatedAt) > staleInterval
    }

    private static func validState(_ node: SidebarOrchestrationNode) -> Bool {
        if node.role == "coordinator" {
            return node.parentId == nil && node.generation == 0
                && node.phase == "registered" && node.availability == "active"
        }
        guard node.role == "worker", node.parentId != nil, node.generation > 0 else {
            return false
        }
        guard let phase = SidebarOrchestrationPhase(rawValue: node.phase) else {
            return false
        }
        switch phase {
        case .launching, .turnQueued, .turnRunning:
            return node.availability == "busy"
        case .reportedBlocked, .reportedCompleted, .reportedFailed,
             .reportMissing, .permissionDenied, .turnFailed:
            return node.availability == "idle"
        case .processDisappeared, .terminalDisappeared, .launchFailed,
             .startupFailed, .resourceRetired:
            return node.availability == "unavailable"
        case .registered:
            return false
        }
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
    // Observe quiescence without exposing cancellable task handles.
    private let taskFinished: @MainActor @Sendable (UInt64) -> Void

    init(
        read: Read? = nil,
        pause: @escaping Pause = { try await Task.sleep(for: .seconds(2)) },
        taskFinished: @escaping @MainActor @Sendable (UInt64) -> Void = { _ in }
    ) {
        self.read = read ?? {
            try await Task.detached { try SidebarOrchestrationReader.read() }.value
        }
        self.pause = pause
        self.taskFinished = taskFinished
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
        let taskFinished = taskFinished
        worker = Task { [weak self] in
            defer { taskFinished(token) }
            while !Task.isCancelled {
                do {
                    let raw = try await read()
                    guard let self, self.generation == token, !Task.isCancelled else { break }
                    let byID = Dictionary(uniqueKeysWithValues: raw.nodes.map { ($0.id, $0) })
                    let onSurface = Set(raw.nodes.compactMap { node in
                        topology.workspaceBySurface[node.surfaceId] == node.workspaceId ? node.id : nil
                    })
                    let nodes = raw.nodes.filter { node in
                        var current: SidebarOrchestrationNode? = node
                        while let candidate = current {
                            guard onSurface.contains(candidate.id) else { return false }
                            current = candidate.parentId.flatMap { byID[$0] }
                        }
                        return true
                    }
                    self.snapshot = SidebarOrchestrationSnapshot(
                        version: raw.version, generatedAt: raw.generatedAt,
                        complete: raw.complete, omittedCount: raw.omittedCount,
                        nodes: nodes
                    )
                    self.availability = SidebarOrchestrationReader.isStale(raw)
                        ? .stale : self.snapshot.complete ? .ready : .partial
                } catch CopilotFileError.missing {
                    guard let self, self.generation == token, !Task.isCancelled else { break }
                    self.snapshot = .empty
                    self.availability = .waiting
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { break }
                    self.snapshot = .empty
                    self.availability = .unavailable
                }
                do { try await pause() } catch { break }
            }
            guard let self, self.generation == token else { return }
            self.worker = nil
        }
    }
}
