import Foundation
import Observation

@Observable
@MainActor
final class SidebarCopilotPolling {
    typealias Read = @Sendable ([UUID: UUID]) async throws -> AgentSessionSnapshot
    typealias Pause = @Sendable () async throws -> Void
    typealias PendingHistory = @Sendable () async -> Bool
    typealias ExpiryPause = @Sendable (TimeInterval) async throws -> Void
    typealias ReadManaged = @Sendable (Set<UUID>) async -> [UUID: CopilotManagedSessionDetails]
    typealias Changes = @Sendable () async -> SidebarRefreshTrigger

    @ObservationIgnored private var storedTree: SidebarCopilotTree = .waiting
    @ObservationIgnored private var currentTree: SidebarCopilotTree = .waiting
    @ObservationIgnored private var evidenceObservers: [UUID: AsyncStream<SidebarCopilotTree>.Continuation] = [:]
    private(set) var tree: SidebarCopilotTree {
        get {
            access(keyPath: \.tree)
            return storedTree
        }
        set {
            if storedTree.hasSamePresentation(as: newValue) {
                storedTree = newValue
            } else {
                withMutation(keyPath: \.tree) { storedTree = newValue }
            }
            for observer in evidenceObservers.values { observer.yield(newValue) }
        }
    }
    private(set) var isReading = false
    @ObservationIgnored private(set) var projectionCount = 0
    @ObservationIgnored private var projectionCache: SidebarCopilotProjectionCache?
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
    private var managedDetails: [UUID: CopilotManagedSessionDetails] = [:]
    private let readManaged: ReadManaged
    private var history = SidebarHistorySettings()
    private var attention = SidebarAttentionSettings()
    private var revealingIdleTasksIn: Set<UUID> = []
    private let read: Read
    private let hasPendingHistory: PendingHistory
    private let pause: Pause
    private let catchUpPause: Pause
    private let expiryPause: ExpiryPause
    private let now: @Sendable () -> Date
    private let changes: Changes?

    init(
        reader: CopilotSessionReader = CopilotSessionReader(),
        read: Read? = nil,
        readManaged: ReadManaged? = nil,
        hasPendingHistory: PendingHistory? = nil,
        pause: @escaping Pause = { try await Task.sleep(for: .seconds(2)) },
        catchUpPause: @escaping Pause = { try await Task.sleep(for: .milliseconds(10)) },
        expiryPause: @escaping ExpiryPause = { try await Task.sleep(for: .seconds($0)) },
        changes: Changes? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.read = read ?? { placements in
            let source = try await reader.read(surfaceIDs: Set(placements.keys))
            return CopilotSnapshotAdapter.snapshot(source, workspaceBySurface: placements)
        }
        self.readManaged = readManaged ?? (read == nil ? { await reader.managedSessionDetails($0) } : { _ in [:] })
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
        self.changes = changes ?? (read == nil ? {
            await SidebarRefreshTrigger.copilot()
        } : nil)
    }

    func update(topology: SidebarTopology, connected: Bool) {
        guard topology != self.topology || connected != self.connected else { return }
        self.topology = topology
        self.connected = connected
        invalidate()
    }

    /// Non-rendering consumers receive refreshed evidence even when the visible tree is equal.
    func evidenceUpdates() -> AsyncStream<SidebarCopilotTree> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SidebarCopilotTree>.makeStream(bufferingPolicy: .bufferingNewest(1))
        evidenceObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.evidenceObservers.removeValue(forKey: id) }
        }
        continuation.yield(tree)
        return stream
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
        defer { tree = currentTree }
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
        projectionCache = nil
        lastStatuses.removeAll()
        managedDetails = [:]
        lastGeneratedAt = nil
        currentTree = SidebarCopilotTree(
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
        let readManaged = readManaged
        let hasPendingHistory = hasPendingHistory
        let pause = pause
        let catchUpPause = catchUpPause
        let changes = changes
        worker = Task { [weak self] in
            let refresh = await changes?()
            while !Task.isCancelled {
                self?.isReading = true
                var hasUnreadHistory = false
                do {
                    let snapshot = try await read(capturedTopology.workspaceBySurface)
                    let pending = await hasPendingHistory()
                    guard let self, self.generation == token, !Task.isCancelled else { break }
                    let managed = Set(self.managedSubjects.compactMap(\.sessionID))
                    let details = managed.isEmpty ? [:] : await readManaged(managed)
                    guard self.generation == token, !Task.isCancelled else { break }
                    self.managedDetails = details
                    let accepted = self.accept(snapshot, topology: capturedTopology)
                    hasUnreadHistory = accepted && !snapshot.isComplete && pending
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { break }
                    defer { self.tree = self.currentTree }
                    self.expiry?.cancel()
                    self.expiry = nil
                    self.expiryDeadline = nil
                    self.cancelHistoryExpiry()
                    self.snapshot = nil
                    self.projectionCache = nil
                    if Self.invalidatesStatus(error) {
                        self.lastStatuses.removeAll()
                        self.invalidatedAt = self.now()
                    }
                    self.currentTree = SidebarCopilotTree(
                        availability: .unavailable, sessions: [], issues: [], generatedAt: nil
                    )
                    self.projectStatusLoss()
                    self.scheduleStatusExpiry()
                }
                self?.isReading = false
                if let self, self.generation == token, !Task.isCancelled {
                    let bound = self.managedSubjects.filter {
                        capturedTopology.workspaceBySurface[$0.surfaceID] == $0.workspaceID
                    }.compactMap(\.sessionID)
                    let shown = (self.currentTree.sessions + self.currentTree.statusSessions).filter {
                        capturedTopology.workspaceBySurface[$0.surfaceID] == $0.workspaceID
                    }.map(\.id)
                    await refresh?.updateSessions(Set(shown).union(bound))
                }
                // Loading alone is not progress: a torn line at EOF must use the idle delay.
                do {
                    if hasUnreadHistory {
                        try await catchUpPause()
                    } else if let refresh {
                        try await refresh.wait(fallback: pause)
                    } else {
                        try await pause()
                    }
                } catch { break }
            }
            await refresh?.stop()
            guard let self else { return }
            self.isReading = false
            self.worker = nil
            if self.generation != token { self.startIfNeeded() }
        }
    }

    private func accept(_ snapshot: AgentSessionSnapshot, topology: SidebarTopology) -> Bool {
        defer { tree = currentTree }
        let date = now()
        let unsafeIssues: [AgentSnapshotIssue] = [
            .permissionDenied, .identityChanged, .ambiguousIdentity,
            .integrationNotInstalled, .noIdentityRecords
        ]
        // Aggregate format warnings can describe only one child's unknown lifecycle.
        // The envelope schema and explicit identity failures remain global barriers.
        if snapshot.globalIssues.contains(where: { unsafeIssues.contains($0) })
            || !SnapshotSchemaVersion.supported.contains(snapshot.schemaVersion) {
            lastStatuses.removeAll()
            invalidatedAt = now()
            self.snapshot = nil
            projectionCache = nil
            currentTree = .init(availability: .unavailable, sessions: [], issues: snapshot.issues ?? [], generatedAt: nil)
            cancelHistoryExpiry()
            scheduleStatusExpiry()
        }
        if snapshot.issues?.contains(.permissionDenied) == true {
            self.snapshot = nil
            projectionCache = nil
            expiry?.cancel()
            expiry = nil
            expiryDeadline = nil
            cancelHistoryExpiry()
            currentTree = SidebarCopilotTree(
                availability: .partial, sessions: [], issues: snapshot.issues ?? [], generatedAt: snapshot.generatedAt
            )
            return false
        }
        guard invalidatedAt.map({ snapshot.generatedAt > $0 }) ?? true else { return false }
        guard lastGeneratedAt.map({ snapshot.generatedAt >= $0 }) ?? true else { return false }
        guard SidebarCopilotTree.isFresh(snapshot.generatedAt, now: now()),
              SnapshotSchemaVersion.supported.contains(snapshot.schemaVersion) else {
            self.snapshot = nil
            projectionCache = nil
            currentTree = .init(availability: .unavailable, sessions: [], issues: snapshot.issues ?? [], generatedAt: nil)
            cancelHistoryExpiry()
            projectStatusLoss()
            scheduleStatusExpiry()
            return false
        }
        lastGeneratedAt = snapshot.generatedAt
        self.snapshot = snapshot
        if let projectionCache, projectionCache.matches(snapshot, now: date) {
            // Reconcile the original projection, not its status-loss-filtered result.
            // Every timestamp comes from this read, never from the display clock.
            var refreshed = projectionCache.tree
            refreshed.generatedAt = snapshot.generatedAt
            let observations = Dictionary(grouping: snapshot.sessions, by: { UUID(uuidString: $0.identity.sessionID) })
            for index in refreshed.sessions.indices {
                let id = refreshed.sessions[index].id
                if let matches = observations[id], matches.count == 1, let observedAt = matches.first?.observedAt {
                    refreshed.sessions[index].observedAt = observedAt
                }
            }
            currentTree = refreshed
        } else {
            projectionCount += 1
            currentTree = SidebarCopilotTree.project(snapshot, onto: topology, now: date, history: history, attention: attention,
                                             revealingIdleTasksIn: revealingIdleTasksIn)
            projectionCache = SidebarCopilotProjectionCache(snapshot: snapshot, tree: currentTree, now: date)
        }
        currentTree.managedDetails = managedDetails
        if let invalidatedAt { currentTree.sessions.removeAll { $0.observedAt <= invalidatedAt } }
        reconcileStatuses(snapshot)
        scheduleHistoryExpiry()
        scheduleStatusExpiry()
        return SidebarCopilotTree.isFresh(snapshot.generatedAt, now: now())
    }

    private func reprojectHistory() {
        guard canPoll, let snapshot else { return }
        defer { tree = currentTree }
        let date = now()
        projectionCount += 1
        currentTree = SidebarCopilotTree.project(snapshot, onto: topology, now: date, history: history, attention: attention,
                                         revealingIdleTasksIn: revealingIdleTasksIn)
        projectionCache = SidebarCopilotProjectionCache(snapshot: snapshot, tree: currentTree, now: date)
        currentTree.managedDetails = managedDetails
        if let invalidatedAt { currentTree.sessions.removeAll { $0.observedAt <= invalidatedAt } }
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
        let current = Dictionary(grouping: currentTree.sessions, by: \.surfaceID)
        let unreadable = Set(currentTree.sessions.filter {
            [.alive, .dead].contains($0.liveness)
                && snapshot.issues?.contains(.stateUnavailable) == true
                && $0.observedAt < snapshot.generatedAt
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
        for session in currentTree.sessions where [.alive, .dead].contains(session.liveness) {
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
        let accepted = Set(currentTree.sessions.filter { session in
            guard let saved = lastStatuses[session.id] else { return false }
            return !unreadable.contains(session.id) && saved.lostAt == nil && saved.session.observedAt == session.observedAt
                && [.alive, .dead].contains(session.liveness)
        }.map(\.id))
        currentTree.sessions.removeAll {
            unreadable.contains($0.id) || (lastStatuses[$0.id] != nil && !accepted.contains($0.id))
        }
        projectStatusLoss()
    }

    private func projectStatusLoss() {
        let date = now()
        let currentIDs = Set(currentTree.sessions.map(\.id))
        for id in lastStatuses.keys where !currentIDs.contains(id) && lastStatuses[id]?.lostAt == nil {
            lastStatuses[id]?.lostAt = date
        }
        currentTree.statusSessions = lastStatuses.values.compactMap { saved in
            guard let lostAt = saved.lostAt, !currentIDs.contains(saved.session.id) else { return nil }
            return SidebarCopilotTree.statusOnly(saved.session, retainingStatus: date < lostAt.addingTimeInterval(Self.statusGrace))
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func scheduleStatusExpiry() {
        let date = now()
        let freshness = currentTree.generatedAt.map { generated in
            ([generated] + currentTree.sessions.map(\.observedAt) + currentTree.managedDetails.values.map(\.readAt))
                .min()!.addingTimeInterval(SidebarCopilotTree.maximumAge)
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
            defer { self.tree = self.currentTree }
            self.expiryDeadline = nil
            self.expiry = nil
            if expiresEvidence {
                self.snapshot = nil
                self.projectionCache = nil
                self.cancelHistoryExpiry()
                self.currentTree = .init(availability: .unavailable, sessions: [], issues: [], generatedAt: nil)
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
        let date = now()
        let futureObservation = snapshot?.sessions.compactMap { $0.observedAt?.addingTimeInterval(-1) }
            .filter { $0 > date }.min()
        let deadline = canPoll ? [projectionCache?.nextClockChange, futureObservation].compactMap { $0 }.min() : nil
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
