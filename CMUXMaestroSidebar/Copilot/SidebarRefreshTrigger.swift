import Foundation
import OSLog

/// A single pending invalidation survives reads; bursts share one cancellable coalescing delay.
actor SidebarRefreshTrigger {
    typealias Pause = @Sendable () async throws -> Void
    typealias Watch = @Sendable () throws -> SidebarFileWatcher
    enum Failure: Error { case overlappingWait }
    private var changed = false
    private var stopped = false
    private var waiting = false
    private var waiter: (id: UUID, continuation: CheckedContinuation<Void, Error>)?
    private var subscription: Task<Void, Never>?
    private var subscriptionID: UUID?
    private var watcher: SidebarFileWatcher?
    private var coalescing: Task<Void, Error>?
    private var reportedFailure = false
    private let coalesce: Pause
    private let watch: Watch?

    init(
        coalesce: @escaping Pause = { try await Task.sleep(for: .milliseconds(200)) },
        watch: Watch? = nil
    ) {
        self.coalesce = coalesce
        self.watch = watch
    }

    static func live(roots: @escaping @Sendable () throws -> [URL]) async -> SidebarRefreshTrigger {
        let trigger = SidebarRefreshTrigger(watch: { try SidebarFileWatcher(roots: roots()) })
        await trigger.restoreWatcher()
        return trigger
    }

    private func restoreWatcher() {
        guard !stopped, subscription == nil, let watch else { return }
        do {
            let watcher = try watch()
            subscribe(watcher.events, retaining: watcher)
            reportedFailure = false
        } catch {
            if !reportedFailure {
                Logger(subsystem: "com.jdylanmc.CMUXMaestroPreview", category: "file-notifications")
                    .warning("File notifications unavailable; retaining safety polling.")
                reportedFailure = true
            }
        }
    }

    func subscribe(_ events: AsyncStream<Void>, retaining watcher: SidebarFileWatcher? = nil) {
        guard subscription == nil, !stopped else { return }
        self.watcher = watcher
        let id = UUID()
        subscriptionID = id
        subscription = Task { [weak self] in
            for await _ in events {
                guard !Task.isCancelled else { break }
                await self?.notify()
            }
            if !Task.isCancelled { await self?.watchEnded(id) }
        }
    }

    private func watchEnded(_ id: UUID) {
        guard subscriptionID == id, !stopped else { return }
        subscription = nil
        subscriptionID = nil
        watcher = nil
        Logger(subsystem: "com.jdylanmc.CMUXMaestroPreview", category: "file-notifications")
            .notice("File notifications ended; revalidating watched roots.")
        notify()
    }

    func notify() {
        guard !stopped else { return }
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume()
        } else {
            changed = true
        }
    }

    func wait(fallback: @escaping Pause) async throws {
        guard !stopped else { throw CancellationError() }
        guard !waiting else { throw Failure.overlappingWait }
        waiting = true
        defer { waiting = false }
        let event = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await self.waitForChange(); return true }
            group.addTask { try await fallback(); return false }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        if event {
            let coalesce = coalesce
            let delay = Task { try await coalesce() }
            coalescing = delay
            defer { coalescing = nil }
            try await withTaskCancellationHandler {
                try await delay.value
            } onCancel: { delay.cancel() }
            changed = false
        }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        // Recover missing/replaced roots at the existing read cadence, never a retry timer.
        restoreWatcher()
    }

    func stop() {
        stopped = true
        subscription?.cancel()
        subscription = nil
        subscriptionID = nil
        coalescing?.cancel()
        coalescing = nil
        watcher = nil
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(throwing: CancellationError())
        }
        changed = false
    }

    private func waitForChange() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            if changed {
                changed = false
                return
            }
            try await withCheckedThrowingContinuation { continuation in
                waiter = (id, continuation)
            }
        } onCancel: {
            Task { await self.cancelWait(id) }
        }
    }

    private func cancelWait(_ id: UUID) {
        guard waiter?.id == id else { return }
        let pending = waiter
        waiter = nil
        pending?.continuation.resume(throwing: CancellationError())
    }
}
