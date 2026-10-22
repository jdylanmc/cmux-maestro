import Foundation
import OSLog

/// A single pending invalidation survives reads; bursts share one cancellable coalescing delay.
actor SidebarRefreshTrigger {
    typealias Pause = @Sendable () async throws -> Void
    private var changed = false
    private var stopped = false
    private var waiter: (id: UUID, continuation: CheckedContinuation<Void, Error>)?
    private var subscription: Task<Void, Never>?
    private var watcher: SidebarFileWatcher?
    private let coalesce: Pause

    init(coalesce: @escaping Pause = { try await Task.sleep(for: .milliseconds(200)) }) {
        self.coalesce = coalesce
    }

    static func live(roots: @Sendable () throws -> [URL]) async -> SidebarRefreshTrigger {
        let trigger = SidebarRefreshTrigger()
        do {
            let watcher = try SidebarFileWatcher(roots: roots())
            await trigger.subscribe(watcher.events, retaining: watcher)
        } catch {
            Logger(subsystem: "com.jdylanmc.CMUXMaestroPreview", category: "file-notifications")
                .warning("File notifications unavailable; retaining safety polling.")
        }
        return trigger
    }

    func subscribe(_ events: AsyncStream<Void>, retaining watcher: SidebarFileWatcher? = nil) {
        guard subscription == nil, !stopped else { return }
        self.watcher = watcher
        subscription = Task { [weak self] in
            for await _ in events {
                guard !Task.isCancelled else { break }
                await self?.notify()
            }
        }
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
        let event = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await self.waitForChange(); return true }
            group.addTask { try await fallback(); return false }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        if event {
            try await coalesce()
            changed = false
        }
        try Task.checkCancellation()
    }

    func stop() {
        stopped = true
        subscription?.cancel()
        subscription = nil
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
