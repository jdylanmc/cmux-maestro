import Foundation
import Observation

@Observable
@MainActor
final class SidebarCopilotPolling {
    typealias Read = @Sendable ([UUID: UUID]) async throws -> AgentSessionSnapshot
    typealias Pause = @Sendable () async throws -> Void
    typealias PendingHistory = @Sendable () async -> Bool
    typealias ExpiryPause = @Sendable (TimeInterval) async throws -> Void

    private(set) var tree: SidebarCopilotTree = .waiting
    private(set) var isReading = false
    private var topology = SidebarTopology(.empty)
    private var visible = false
    private var connected = false
    private var hasStartedPolling = false
    private var generation: UInt64 = 0
    private var lastGeneratedAt: Date?
    private var invalidatedAt: Date?
    private var worker: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var expiryDeadline: Date?
    private var historyExpiry: Task<Void, Never>?
    private var historyDeadline: Date?
    private var historyGeneration: UInt64 = 0
    private var snapshot: AgentSessionSnapshot?
    private struct LastStatus {
        var session: SidebarCopilotSession
        var lostAt: Date?
    }
    private var lastStatuses: [UUID: LastStatus] = [:]
    static let statusGrace: TimeInterval = 300
    private struct ManagedSubject: Equatable {
        let nodeID: UUID
        let runID: UUID
        let generation: Int
        let role: String
        let sessionID: UUID?
        let workspaceID: UUID
        let surfaceID: UUID
    }
    private var managedSubjects: [ManagedSubject] = []
    private var history = SidebarHistorySettings()
    private var attention = SidebarAttentionSettings()
    private var revealingIdleTasksIn: Set<UUID> = []
    private let read: Read
    private let hasPendingHistory: PendingHistory
    private let pause: Pause
    private let catchUpPause: Pause
    private let expiryPause: ExpiryPause
    private let now: @Sendable () -> Date

    init(
        reader: CopilotSessionReader = CopilotSessionReader(),
        read: Read? = nil,
        hasPendingHistory: PendingHistory? = nil,
        pause: @escaping Pause = { try await Task.sleep(for: .seconds(2)) },
        catchUpPause: @escaping Pause = { try await Task.sleep(for: .milliseconds(10)) },
        expiryPause: @escaping ExpiryPause = { try await Task.sleep(for: .seconds($0)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.read = read ?? { placements in
            let source = try await reader.read(surfaceIDs: Set(placements.keys))
            return CopilotSnapshotAdapter.snapshot(source, workspaceBySurface: placements)
        }
        if let hasPendingHistory {
            self.hasPendingHistory = hasPendingHistory
        } else if read == nil {
            self.hasPendingHistory = { await reader.hasPendingHistory() }
        } else {
            self.hasPendingHistory = { false }
        }
        self.pause = pause
        self.catchUpPause = catchUpPause
        self.expiryPause = expiryPause
        self.now = now
    }

    func update(topology: SidebarTopology, connected: Bool) {
        guard topology != self.topology || connected != self.connected else { return }
        self.topology = topology
        self.connected = connected
        invalidate()
    }

    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        invalidate(scopeChanged: false)
    }

    func updateManagedSubjects(_ snapshot: SidebarOrchestrationSnapshot) {
        let subjects = snapshot.nodes.map {
            ManagedSubject(nodeID: $0.id, runID: $0.runId, generation: $0.generation, role: $0.role,
                           sessionID: $0.copilotSessionId, workspaceID: $0.workspaceId, surfaceID: $0.surfaceId)
        }.sorted { $0.nodeID.uuidString < $1.nodeID.uuidString }
        // Unavailable observer reads are not proof that an existing registration ended.
        guard snapshot.generatedAt != .distantPast,
              snapshot.complete || !subjects.isEmpty, subjects != managedSubjects else { return }
        managedSubjects = subjects
        invalidate()
    }

    func updateHistory(_ history: SidebarHistorySettings) {
        guard history != self.history else { return }
        self.history = history
        reprojectHistory()
    }

    func updateAttention(_ attention: SidebarAttentionSettings) {
        guard attention != self.attention else { return }
        self.attention = attention
        reprojectHistory()
    }

    func updateIdleTasks(_ workspaces: Set<UUID>) {
        guard workspaces != revealingIdleTasksIn else { return }
        revealingIdleTasksIn = workspaces
        reprojectHistory()
    }

    private func invalidate(scopeChanged: Bool = true) {
        // Once reading starts, a new scope must not relabel cached evidence.
        if scopeChanged && hasStartedPolling {
            invalidatedAt = now()
        }
        generation &+= 1
        worker?.cancel()
        expiry?.cancel()
        expiry = nil
        expiryDeadline = nil
        cancelHistoryExpiry()
        snapshot = nil
        lastStatuses.removeAll()
        lastGeneratedAt = nil
        tree = SidebarCopilotTree(
            availability: !visible ? .hidden : !connected ? .disconnected
                : !topology.canReadSessions ? .waiting : .loading,
            sessions: [], issues: [], generatedAt: nil
        )
        startIfNeeded()
    }

    private var canPoll: Bool { visible && connected && topology.canReadSessions }

    private func startIfNeeded() {
        // A cancelled read must unwind before a new topology starts I/O.
        guard worker == nil, canPoll else { return }
        hasStartedPolling = true
        let token = generation
        let capturedTopology = topology
        let read = read
        let hasPendingHistory = hasPendingHistory
        let pause = pause
        let catchUpPause = catchUpPause
        worker = Task { [weak self] in
            while !Task.isCancelled {
                self?.isReading = true
                var hasUnreadHistory = false
                do {
                    let snapshot = try await read(capturedTopology.workspaceBySurface)
                    let pending = await hasPendingHistory()
                    guard let self, self.generation == token, !Task.isCancelled else { break }
                    let accepted = self.accept(snapshot, topology: capturedTopology)
                    hasUnreadHistory = accepted && !snapshot.isComplete && pending
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { break }
                    self.expiry?.cancel()
                    self.expiry = nil
                    self.expiryDeadline = nil
                    self.cancelHistoryExpiry()
                    self.snapshot = nil
                    if Self.invalidatesStatus(error) {
                        self.lastStatuses.removeAll()
                        self.invalidatedAt = self.now()
                    }
                    self.tree = SidebarCopilotTree(
                        availability: .unavailable, sessions: [], issues: [], generatedAt: nil
                    )
                    self.projectStatusLoss()
                    self.scheduleStatusExpiry()
                }
                self?.isReading = false
                // Loading alone is not progress: a torn line at EOF must use the idle delay.
                do {
                    if hasUnreadHistory { try await catchUpPause() } else { try await pause() }
                } catch { break }
            }
            guard let self else { return }
            self.isReading = false
            self.worker = nil
            if self.generation != token { self.startIfNeeded() }
        }
    }

    private func accept(_ snapshot: AgentSessionSnapshot, topology: SidebarTopology) -> Bool {
        let unsafeIssues: [AgentSnapshotIssue] = [
            .permissionDenied, .identityChanged, .ambiguousIdentity,
            .integrationNotInstalled, .noIdentityRecords
        ]
        // Aggregate format warnings can describe only one child's unknown lifecycle.
        // The envelope schema and explicit identity failures remain global barriers.
        if snapshot.issues?.contains(where: { unsafeIssues.contains($0) }) == true
            || !SnapshotSchemaVersion.supported.contains(snapshot.schemaVersion) {
            lastStatuses.removeAll()
            invalidatedAt = now()
            self.snapshot = nil
            tree = .init(availability: .unavailable, sessions: [], issues: snapshot.issues ?? [], generatedAt: nil)
            cancelHistoryExpiry()
            scheduleStatusExpiry()
        }
        if snapshot.issues?.contains(.permissionDenied) == true {
            self.snapshot = nil
            expiry?.cancel()
            expiry = nil
            expiryDeadline = nil
            cancelHistoryExpiry()
            tree = SidebarCopilotTree(
                availability: .partial, sessions: [], issues: snapshot.issues ?? [], generatedAt: snapshot.generatedAt
            )
            return false
        }
        guard invalidatedAt.map({ snapshot.generatedAt > $0 }) ?? true else { return false }
        guard lastGeneratedAt.map({ snapshot.generatedAt >= $0 }) ?? true else { return false }
        guard SidebarCopilotTree.isFresh(snapshot.generatedAt, now: now()),
              SnapshotSchemaVersion.supported.contains(snapshot.schemaVersion) else {
            self.snapshot = nil
            tree = .init(availability: .unavailable, sessions: [], issues: snapshot.issues ?? [], generatedAt: nil)
            cancelHistoryExpiry()
            projectStatusLoss()
            scheduleStatusExpiry()
            return false
        }
        lastGeneratedAt = snapshot.generatedAt
        self.snapshot = snapshot
        tree = SidebarCopilotTree.project(snapshot, onto: topology, now: now(), history: history, attention: attention,
                                         revealingIdleTasksIn: revealingIdleTasksIn)
        if let invalidatedAt { tree.sessions.removeAll { $0.observedAt <= invalidatedAt } }
        reconcileStatuses(snapshot)
        scheduleHistoryExpiry()
        scheduleStatusExpiry()
        return SidebarCopilotTree.isFresh(snapshot.generatedAt, now: now())
    }

    private func reprojectHistory() {
        guard canPoll, let snapshot else { return }
        tree = SidebarCopilotTree.project(snapshot, onto: topology, now: now(), history: history, attention: attention,
                                         revealingIdleTasksIn: revealingIdleTasksIn)
        if let invalidatedAt { tree.sessions.removeAll { $0.observedAt <= invalidatedAt } }
        reconcileStatuses(snapshot)
        scheduleHistoryExpiry()
        scheduleStatusExpiry()
    }

    private static func invalidatesStatus(_ error: any Error) -> Bool {
        if let error = error as? CopilotFileError {
            return [.permissionDenied, .unsafePath, .changed].contains(error)
        }
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoPermission.rawValue)
            || (error.domain == NSPOSIXErrorDomain && [1, 13].contains(error.code))
    }

    private func reconcileStatuses(_ snapshot: AgentSessionSnapshot) {
        let groups = Dictionary(grouping: snapshot.sessions, by: { UUID(uuidString: $0.identity.sessionID) })
        if groups[nil] != nil { lastStatuses.removeAll() }
        let current = Dictionary(grouping: tree.sessions, by: \.surfaceID)
        let unreadable = Set(tree.sessions.filter {
            [.alive, .dead].contains($0.liveness)
                && ((snapshot.issues?.contains(.stateUnavailable) == true && $0.observedAt < snapshot.generatedAt)
                    || (!snapshot.isComplete && $0.state == .unknown))
        }.map(\.id))
        lastStatuses = lastStatuses.filter { id, saved in
            guard topology.workspaceBySurface[saved.session.surfaceID] == saved.session.workspaceID else { return false }
            if let candidates = current[saved.session.surfaceID],
               candidates.contains(where: { $0.id != id }) { return false }
            let observations = groups[id]
            guard let observations else { return !snapshot.isComplete }
            guard observations.count == 1, let observation = observations.first,
                  case .bound(let binding) = observation.binding,
                  UUID(uuidString: binding.surfaceID.rawValue) == saved.session.surfaceID,
                  observation.liveness != .ambiguous else { return false }
            return true
        }
        for session in tree.sessions where [.alive, .dead].contains(session.liveness) {
            guard current[session.surfaceID]?.count == 1 else {
                lastStatuses.removeValue(forKey: session.id)
                continue
            }
            if unreadable.contains(session.id) { continue }
            guard lastStatuses[session.id].map({ session.observedAt >= $0.session.observedAt }) ?? true else { continue }
            // A repeated prefix during history catch-up is not a new observation.
            if let saved = lastStatuses[session.id], saved.lostAt != nil,
               session.observedAt <= saved.session.observedAt { continue }
            var saved = session
            let owners = managedSubjects.filter {
                $0.workspaceID == session.workspaceID && $0.surfaceID == session.surfaceID
                    && ($0.sessionID == session.id || ($0.sessionID == nil && $0.role == "coordinator"))
            }
            if owners.count == 1, let owner = owners.first {
                saved.statusOwnerID = owner.nodeID
                saved.statusOwnerRunID = owner.runID
                saved.statusOwnerGeneration = owner.generation
            }
            lastStatuses[session.id] = LastStatus(session: saved)
        }
        let accepted = Set(tree.sessions.filter { session in
            guard let saved = lastStatuses[session.id] else { return false }
            return !unreadable.contains(session.id) && saved.lostAt == nil && saved.session.observedAt == session.observedAt
                && [.alive, .dead].contains(session.liveness)
        }.map(\.id))
        tree.sessions.removeAll {
            unreadable.contains($0.id) || (lastStatuses[$0.id] != nil && !accepted.contains($0.id))
        }
        projectStatusLoss()
    }

    private func projectStatusLoss() {
        let date = now()
        let currentIDs = Set(tree.sessions.map(\.id))
        for id in lastStatuses.keys where !currentIDs.contains(id) && lastStatuses[id]?.lostAt == nil {
            lastStatuses[id]?.lostAt = date
        }
        tree.statusSessions = lastStatuses.values.compactMap { saved in
            guard let lostAt = saved.lostAt, !currentIDs.contains(saved.session.id) else { return nil }
            return SidebarCopilotTree.statusOnly(saved.session, retainingStatus: date < lostAt.addingTimeInterval(Self.statusGrace))
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func scheduleStatusExpiry() {
        let date = now()
        let freshness = tree.generatedAt.map { generated in
            ([generated] + tree.sessions.map(\.observedAt)).min()!.addingTimeInterval(SidebarCopilotTree.maximumAge)
        }
        let grace = lastStatuses.values.compactMap { $0.lostAt?.addingTimeInterval(Self.statusGrace) }
            .filter { $0 > date }.min()
        let next = [freshness, grace].compactMap({ $0 }).min()
        guard next != expiryDeadline else { return }
        expiry?.cancel()
        expiry = nil
        expiryDeadline = next
        guard let deadline = next else { return }
        let expiresEvidence = freshness == deadline
        let token = generation
        let expiryPause = expiryPause
        expiry = Task { [weak self] in
            do { try await expiryPause(max(0, deadline.timeIntervalSince(date))) } catch { return }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.expiryDeadline = nil
            self.expiry = nil
            if expiresEvidence {
                self.snapshot = nil
                self.cancelHistoryExpiry()
                self.tree = .init(availability: .unavailable, sessions: [], issues: [], generatedAt: nil)
            }
            self.projectStatusLoss()
            self.scheduleStatusExpiry()
        }
    }

    private func cancelHistoryExpiry() {
        historyGeneration &+= 1
        historyExpiry?.cancel()
        historyExpiry = nil
        historyDeadline = nil
    }

    private func scheduleHistoryExpiry() {
        let deadline = canPoll ? tree.nextHistoryExpiry : nil
        guard deadline != historyDeadline else { return }
        cancelHistoryExpiry()
        guard let deadline else { return }
        historyDeadline = deadline
        let token = historyGeneration
        let delay = deadline.timeIntervalSince(now())
        let expiryPause = expiryPause
        historyExpiry = Task { [weak self] in
            do { try await expiryPause(max(0, delay)) } catch { return }
            guard let self, self.historyGeneration == token, !Task.isCancelled else { return }
            self.historyExpiry = nil
            self.historyDeadline = nil
            self.reprojectHistory()
        }
    }
}
