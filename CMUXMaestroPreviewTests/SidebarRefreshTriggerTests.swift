import Foundation
import Observation
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

    @Test(arguments: [false, true], [false, true])
    func cancellationAndStopReleasePendingWaits(coalescing: Bool, stop: Bool) async {
        let fallback = RefreshBarrier()
        let coalesce = RefreshBarrier()
        let trigger = SidebarRefreshTrigger(coalesce: { try await coalesce.wait() })
        let pending = Task { try await trigger.wait { try await fallback.wait() } }
        await sidebarEventually { await fallback.calls == 1 }
        if coalescing {
            await trigger.notify()
            await sidebarEventually { await coalesce.calls == 1 }
        }
        if stop { await trigger.stop() } else { pending.cancel() }
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

    @Test func overlappingWaitIsRejectedWithoutLosingTheFirstWaiter() async throws {
        let fallback = RefreshBarrier()
        let trigger = SidebarRefreshTrigger(coalesce: {})
        let first = Task { try await trigger.wait { try await fallback.wait() } }
        await sidebarEventually { await fallback.active == 1 }
        do {
            try await trigger.wait {}
            Issue.record("Overlapping wait accepted")
        } catch {
            #expect(error is SidebarRefreshTrigger.Failure)
        }
        await trigger.notify()
        try await first.value
        await trigger.stop()
    }

    @Test func copilotEventsRetainInFlightChangesAndStopOnHide() async throws {
        let fixtures = SidebarTreeFixtures()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let reads = RefreshReadGate<CopilotSnapshot>()
        let fallback = RefreshBarrier()
        let trigger = SidebarRefreshTrigger(coalesce: {})
        let poller = SidebarCopilotPolling(
            read: { placements in
                CopilotSnapshotAdapter.snapshot(try await reads.read(), workspaceBySurface: placements)
            },
            pause: { try await fallback.wait() }, expiryPause: sidebarFrozenExpiry,
            changes: { trigger }, now: { date }
        )
        defer { poller.setVisible(false); Task { await reads.cancel() } }
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        await sidebarEventually { await reads.calls == 1 }
        await reads.complete(fixtures.snapshot(sessions: [fixtures.session(now: date)], now: date))
        await sidebarEventually { await fallback.active == 1 }
        let projections = poller.projectionCount
        let publications = CopilotReaderTestClock(date)
        withObservationTracking { _ = poller.tree } onChange: { publications.advance(by: 1) }
        await trigger.notify()
        await sidebarEventually { await reads.calls == 2 }
        try #require(await reads.calls == 2, "Notification must wake the real poller without releasing fallback")
        for _ in 0..<100 { await trigger.notify() }
        #expect(await reads.calls == 2)
        await reads.complete(fixtures.snapshot(sessions: [fixtures.session(now: date)], now: date))
        await sidebarEventually { await reads.calls == 3 }
        #expect(poller.projectionCount == projections)
        #expect(publications.now() == date)
        await trigger.notify()
        await reads.complete(fixtures.snapshot(sessions: [fixtures.session(state: .working, now: date)], now: date))
        await sidebarEventually { await reads.calls == 4 }
        #expect(poller.tree.sessions.first?.state == .working)
        #expect(poller.projectionCount == projections + 1)
        #expect(await reads.maximumActive == 1)
        #expect(await fallback.released == 0)
        poller.setVisible(false)
        await reads.complete(fixtures.snapshot(sessions: [fixtures.session(now: date)], now: date))
        await sidebarEventually { !poller.isReading }
        #expect(poller.tree.availability == .hidden)
        await trigger.notify()
        do {
            try await trigger.wait {}
            Issue.record("Hidden poller retained its watcher")
        } catch { #expect(error is CancellationError) }
        #expect(await reads.calls == 4)
    }

    @Test func orchestrationEventsSerializeReplacementAndRetireOldTrigger() async throws {
        let fixtures = SidebarTreeFixtures()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let reads = RefreshReadGate<SidebarOrchestrationSnapshot>()
        let fallback = RefreshBarrier()
        let triggers = RefreshTriggerFactory()
        let poller = SidebarOrchestrationPolling(
            read: { try await reads.read() }, pause: { try await fallback.wait() },
            expiryPause: sidebarFrozenExpiry, changes: { await triggers.make() }, now: { date }
        )
        defer { poller.setVisible(false); Task { await reads.cancel() } }
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        let value = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: date, complete: true, omittedCount: 0, nodes: []
        )
        await sidebarEventually { await reads.calls == 1 }
        await reads.complete(value)
        await sidebarEventually { await fallback.active == 1 }
        let first = try #require(await triggers.values.first)
        await first.notify()
        await sidebarEventually { await reads.calls == 2 }
        await first.notify()
        poller.update(topology: fixtures.topology(moved: true), connected: true)
        #expect(await reads.calls == 2)
        #expect(await triggers.values.count == 1)
        await reads.complete(value)
        await sidebarEventually { await reads.calls == 3 }
        #expect(await reads.maximumActive == 1)
        #expect(await triggers.values.count == 2)
        do {
            try await first.wait {}
            Issue.record("Obsolete scope retained its trigger")
        } catch { #expect(error is CancellationError) }
        await first.notify()
        await reads.complete(value)
        await sidebarEventually { await fallback.active == 1 }
        #expect(poller.availability == .ready)
        #expect(await reads.calls == 3)
        await fallback.release()
        await sidebarEventually { await reads.calls == 4 }
        poller.setVisible(false)
        await reads.complete(value)
        await sidebarEventually { await reads.active == 0 }
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

    @Test func endedStreamAndMissingRootRecoverAtFallbackWithoutAnExtraTimer() async throws {
        let parent = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/watcher-fixtures/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("later", isDirectory: true)
        let attempts = CopilotReaderTestClock(Date(timeIntervalSince1970: 0))
        let trigger = SidebarRefreshTrigger(coalesce: {}, watch: {
            attempts.advance(by: 1)
            return try SidebarFileWatcher(roots: [root])
        })
        let fallback = RefreshBarrier()
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        await trigger.subscribe(events)
        let ended = Task { try await trigger.wait { try await fallback.wait() } }
        await sidebarEventually { await fallback.active == 1 }
        continuation.finish()
        try await ended.value
        #expect(attempts.now().timeIntervalSince1970 == 1)
        #expect(await fallback.released == 0)

        let missing = Task { try await trigger.wait { try await fallback.wait() } }
        await sidebarEventually { await fallback.active == 1 }
        await fallback.release()
        try await missing.value
        #expect(attempts.now().timeIntervalSince1970 == 2)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let recover = Task { try await trigger.wait { try await fallback.wait() } }
        await sidebarEventually { await fallback.active == 1 }
        await fallback.release()
        try await recover.value
        #expect(attempts.now().timeIntervalSince1970 == 3)

        let received = RefreshCounter()
        let changed = Task {
            try await trigger.wait { try await fallback.wait() }
            await received.increment()
        }
        defer { changed.cancel(); Task { await trigger.stop() } }
        await sidebarEventually { await fallback.active == 1 }
        try Data("synthetic".utf8).write(to: root.appendingPathComponent("snapshot.json"), options: .atomic)
        await sidebarEventually { await received.count == 1 }
        try await changed.value
        #expect(await fallback.released == 2)
        #expect(attempts.now().timeIntervalSince1970 == 3, "Healthy watchers do not reopen roots per read")
        await trigger.stop()
    }

    @Test func nativeRootReplacementEndsOldLease() async throws {
        let parent = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/watcher-fixtures/\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("observed", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let watcher = try SidebarFileWatcher(roots: [root])
        let ended = RefreshCounter()
        let consumer = Task {
            for await _ in watcher.events {}
            await ended.increment()
        }
        defer { consumer.cancel() }
        try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("retired"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        await sidebarEventually { await ended.count == 1 }
        consumer.cancel()
        await consumer.value
        withExtendedLifetime(watcher) {}
    }
}

private actor RefreshCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor RefreshTriggerFactory {
    private(set) var values: [SidebarRefreshTrigger] = []
    func make() -> SidebarRefreshTrigger {
        let trigger = SidebarRefreshTrigger(coalesce: {})
        values.append(trigger)
        return trigger
    }
}

private actor RefreshReadGate<Value: Sendable> {
    private(set) var calls = 0
    private(set) var maximumActive = 0
    private var pending: [CheckedContinuation<Value, Error>] = []
    var active: Int { pending.count }

    func read() async throws -> Value {
        calls += 1
        return try await withCheckedThrowingContinuation {
            pending.append($0)
            maximumActive = max(maximumActive, pending.count)
        }
    }

    func complete(_ value: Value) {
        guard !pending.isEmpty else { Issue.record("No pending read"); return }
        pending.removeFirst().resume(returning: value)
    }

    func cancel() {
        let continuations = pending
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
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
