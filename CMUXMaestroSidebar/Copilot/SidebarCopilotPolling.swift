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

    private func invalidate() {
        generation &+= 1
        worker?.cancel()
        expiry?.cancel()
        expiry = nil
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
        tree = SidebarCopilotTree.project(snapshot, onto: topology, now: now())
        expiry?.cancel()
        let earliestObservation = ([snapshot.generatedAt] + tree.sessions.map(\.observedAt)).min() ?? snapshot.generatedAt
        let delay = max(0, SidebarCopilotTree.maximumAge - now().timeIntervalSince(earliestObservation))
        let expiryPause = expiryPause
        expiry = Task { [weak self] in
            do { try await expiryPause(delay) } catch { return }
            guard let self, self.generation == token else { return }
            self.tree = SidebarCopilotTree(
                availability: .unavailable, sessions: [], issues: [], generatedAt: nil
            )
        }
        return SidebarCopilotTree.isFresh(snapshot.generatedAt, now: now())
    }
}
