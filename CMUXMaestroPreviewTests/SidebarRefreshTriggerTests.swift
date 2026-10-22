import Foundation
import Testing

@MainActor
struct SidebarRefreshTriggerTests {
    @Test func burstSharesOneCoalescingDelayAndIdleUsesFallback() async throws {
        let fallback = RefreshBarrier()
        let coalesce = RefreshBarrier()
        let trigger = SidebarRefreshTrigger(coalesce: { try await coalesce.wait() })
        let first = Task { try await trigger.wait { try await fallback.wait() } }
        await sidebarEventually { await fallback.calls == 1 }
        await trigger.notify()
        await sidebarEventually { await coalesce.calls == 1 }
        for _ in 0..<100 { await trigger.notify() }
        await coalesce.release()
        try await first.value

        let idle = Task { try await trigger.wait { try await fallback.wait() } }
        await sidebarEventually { await fallback.calls == 2 }
        #expect(await coalesce.calls == 1)
        await fallback.release()
        try await idle.value
        #expect(await coalesce.calls == 1)
        await trigger.stop()
    }

    @Test func changeDuringReadIsRetainedForTheNextWait() async throws {
        let fallback = RefreshBarrier()
        let coalesce = RefreshBarrier()
        let trigger = SidebarRefreshTrigger(coalesce: { try await coalesce.wait() })
        await trigger.notify()
        let pending = Task { try await trigger.wait { try await fallback.wait() } }
        await sidebarEventually { await coalesce.calls == 1 }
        await coalesce.release()
        try await pending.value
        // The consumer is reading here; no refresh wait is installed.
        await trigger.notify()
        let next = Task { try await trigger.wait { try await fallback.wait() } }
        await sidebarEventually { await coalesce.calls == 2 }
        await coalesce.release()
        try await next.value
        await trigger.stop()
    }

    @Test(arguments: [false, true])
    func cancellationAndStopReleasePendingWaits(coalescing: Bool) async {
        let fallback = RefreshBarrier()
        let coalesce = RefreshBarrier()
        let trigger = SidebarRefreshTrigger(coalesce: { try await coalesce.wait() })
        let pending = Task { try await trigger.wait { try await fallback.wait() } }
        await sidebarEventually { await fallback.calls == 1 }
        if coalescing {
            await trigger.notify()
            await sidebarEventually { await coalesce.calls == 1 }
            pending.cancel()
        } else {
            await trigger.stop()
        }
        do {
            try await pending.value
            Issue.record("Cancelled refresh unexpectedly completed")
        } catch {
            #expect(error is CancellationError)
        }
        await trigger.stop()
        #expect(await fallback.active == 0)
        #expect(await coalesce.active == 0)
        await trigger.notify()
        do {
            try await trigger.wait { try await fallback.wait() }
            Issue.record("Stopped refresh accepted another wait")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func subscriptionDeliversAChangeWithoutPolling() async throws {
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let fallback = RefreshBarrier()
        let coalesce = RefreshBarrier()
        let trigger = SidebarRefreshTrigger(coalesce: { try await coalesce.wait() })
        await trigger.subscribe(events)
        let pending = Task { try await trigger.wait { try await fallback.wait() } }
        await sidebarEventually { await fallback.calls == 1 }
        continuation.yield(())
        await sidebarEventually { await coalesce.calls == 1 }
        await coalesce.release()
        try await pending.value
        #expect(await fallback.released == 0)
        continuation.finish()
        await trigger.stop()
    }

    @Test func nativeWatcherSignalsNestedAppendsAndRejectsSymlinkRoots() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/watcher-fixtures/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let file = child.appendingPathComponent("events.jsonl")
        try Data("synthetic\n".utf8).write(to: file)
        let watcher = try SidebarFileWatcher(roots: [root])
        let received = RefreshCounter()
        let consumer = Task {
            for await _ in watcher.events {
                await received.increment()
                break
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("change\n".utf8))
        try handle.close()
        await sidebarEventually { await received.count > 0 }
        consumer.cancel()
        await consumer.value
        withExtendedLifetime(watcher) {}

        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: child)
        #expect(throws: CopilotFileError.self) { _ = try SidebarFileWatcher(roots: [link]) }
    }
}

private actor RefreshCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor RefreshBarrier {
    private(set) var calls = 0
    private(set) var released = 0
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    var active: Int { pending.count }

    func wait() async throws {
        let id = UUID()
        calls += 1
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { pending[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        let waiting = pending
        pending.removeAll()
        released += waiting.count
        for continuation in waiting.values { continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
