import Foundation
import Observation

@Observable
@MainActor
final class SidebarCopilotPolling {
    typealias Read = @Sendable (Set<UUID>) async throws -> CopilotSnapshot
    typealias Pause = @Sendable () async throws -> Void
    typealias PendingHistory = @Sendable () async -> Bool
    typealias ExpiryPause = @Sendable (TimeInterval) async throws -> Void

    private(set) var tree: SidebarCopilotTree = .waiting
    private(set) var isReading = false
    private var topology = SidebarTopology(.empty)
    private var visible = false
    private var connected = false
    private var generation: UInt64 = 0
    private var lastGeneratedAt: Date?
    private var worker: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var historyExpiry: Task<Void, Never>?
    private var historyDeadline: Date?
    private var historyGeneration: UInt64 = 0
    private var snapshot: CopilotSnapshot?
    private var history = SidebarHistorySettings()
    private let read: Read
    private let hasPendingHistory: PendingHistory
    private let pause: Pause
    private let catchUpPause: Pause
    private let expiryPause: ExpiryPause
    private let now: @Sendable () -> Date

    init(
        read: Read? = nil,
        hasPendingHistory: PendingHistory? = nil,
        pause: @escaping Pause = { try await Task.sleep(for: .seconds(2)) },
        catchUpPause: @escaping Pause = { try await Task.sleep(for: .milliseconds(10)) },
        expiryPause: @escaping ExpiryPause = { try await Task.sleep(for: .seconds($0)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let reader = CopilotSessionReader()
        self.read = read ?? { try await reader.read(surfaceIDs: $0) }
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
        invalidate()
    }

    func updateHistory(_ history: SidebarHistorySettings) {
        guard history != self.history else { return }
        self.history = history
        reprojectHistory()
    }

    private func invalidate() {
        generation &+= 1
        worker?.cancel()
        expiry?.cancel()
        expiry = nil
        cancelHistoryExpiry()
        snapshot = nil
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
                    let snapshot = try await read(Set(capturedTopology.workspaceBySurface.keys))
                    let pending = await hasPendingHistory()
                    guard let self, self.generation == token, !Task.isCancelled else { break }
                    let accepted = self.accept(snapshot, topology: capturedTopology, token: token)
                    hasUnreadHistory = accepted && !snapshot.isComplete && pending
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { break }
                    self.expiry?.cancel()
                    self.expiry = nil
                    self.cancelHistoryExpiry()
                    self.snapshot = nil
                    self.tree = SidebarCopilotTree(
                        availability: .unavailable, sessions: [], issues: [], generatedAt: nil
                    )
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

    private func accept(_ snapshot: CopilotSnapshot, topology: SidebarTopology, token: UInt64) -> Bool {
        guard lastGeneratedAt.map({ snapshot.generatedAt >= $0 }) ?? true else { return false }
        lastGeneratedAt = snapshot.generatedAt
        if snapshot.issues.contains(.permissionDenied) {
            self.snapshot = nil
            expiry?.cancel()
            expiry = nil
            cancelHistoryExpiry()
            tree = SidebarCopilotTree(
                availability: .partial, sessions: [], issues: snapshot.issues, generatedAt: snapshot.generatedAt
            )
            return false
        }
        self.snapshot = snapshot
        tree = SidebarCopilotTree.project(snapshot, onto: topology, now: now(), history: history)
        scheduleHistoryExpiry()
        expiry?.cancel()
        guard tree.availability == .ready || tree.availability == .partial else {
            self.snapshot = nil
            return false
        }
        let earliestObservation = ([snapshot.generatedAt] + tree.sessions.map(\.observedAt)).min() ?? snapshot.generatedAt
        let delay = max(0, SidebarCopilotTree.maximumAge - now().timeIntervalSince(earliestObservation))
        let expiryPause = expiryPause
        expiry = Task { [weak self] in
            do { try await expiryPause(delay) } catch { return }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.snapshot = nil
            self.cancelHistoryExpiry()
            self.tree = SidebarCopilotTree(
                availability: .unavailable, sessions: [], issues: [], generatedAt: nil
            )
        }
        return SidebarCopilotTree.isFresh(snapshot.generatedAt, now: now())
    }

    private func reprojectHistory() {
        guard canPoll, let snapshot else { return }
        tree = SidebarCopilotTree.project(snapshot, onto: topology, now: now(), history: history)
        scheduleHistoryExpiry()
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
