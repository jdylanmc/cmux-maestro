import Foundation
import Darwin
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

    @Test func nonShownSessionLoadDoesNotWakeTheReader() async throws {
        let fixtures = SidebarTreeFixtures()
        let clock = CopilotReaderTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let root = URL(fileURLWithPath: "/synthetic/sessions", isDirectory: true)
        let bindings = URL(fileURLWithPath: "/synthetic/bindings", isDirectory: true)
        let registrations = AsyncStream<SyntheticFileLease>.makeStream()
        let trigger = await SidebarRefreshTrigger.copilot(
            bindings: bindings, sessionRoot: root, coalesce: {},
            watch: {
                let lease = SyntheticFileLease(scope: $0)
                registrations.continuation.yield(lease)
                return lease
            }
        )
        var leases = registrations.stream.makeAsyncIterator()
        let initial = try #require(await leases.next())
        #expect(initial.scope.recursive.isEmpty)
        #expect(initial.scope.directories == [bindings])
        let reads = RefreshReadGate<CopilotSnapshot>()
        let fallback = RefreshBarrier()
        let poller = SidebarCopilotPolling(
            read: { CopilotSnapshotAdapter.snapshot(try await reads.read(), workspaceBySurface: $0) },
            pause: { try await fallback.wait() }, expiryPause: sidebarFrozenExpiry,
            changes: { trigger }, now: { clock.now() }
        )
        defer {
            poller.setVisible(false)
            registrations.continuation.finish()
            Task { await reads.cancel() }
        }
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        await sidebarEventually { await reads.calls == 1 }
        await reads.complete(fixtures.snapshot(sessions: [fixtures.session(now: clock.now())], now: clock.now()))
        let shown = try #require(await leases.next())
        await sidebarEventually { await reads.calls == 2 }
        await reads.complete(fixtures.snapshot(sessions: [fixtures.session(now: clock.now())], now: clock.now()))
        await sidebarEventually { await fallback.active == 1 }
        let baseline = await reads.calls
        let hidden = (0..<1_000).map {
            root.appendingPathComponent(String(format: "30000000-0000-0000-0000-%012d/events.jsonl", $0))
        }
        try #require(!shown.emit(hidden[0]), "A non-shown session must not enter the reader's notification stream")
        for epoch in 1...30 {
            for path in hidden { #expect(!shown.emit(path)) }
            #expect(await reads.calls == baseline + epoch - 1)
            clock.advance(by: 2)
            await fallback.release()
            await sidebarEventually { await reads.calls == baseline + epoch }
            await reads.complete(fixtures.snapshot(sessions: [fixtures.session(now: clock.now())], now: clock.now()))
            await sidebarEventually { await fallback.active == 1 }
        }
        #expect(await reads.calls - baseline == 30)
        print("Synthetic controlled 60s: 30000 off-scope events, 0 event-driven reads, 30 fallback reads (0.5/s). Not wall-clock CPU evidence.")
        #expect(!shown.emit(bindings.appendingPathComponent("nested/unrelated.json")))
        #expect(shown.emit(root.appendingPathComponent(fixtures.sessionID.uuidString.lowercased() + "/events.jsonl")))
        await sidebarEventually { await reads.calls == baseline + 31 }
        await reads.complete(fixtures.snapshot(
            sessions: [fixtures.session(id: fixtures.otherSessionID, now: clock.now())], now: clock.now()
        ))
        let replaced = try #require(await leases.next())
        #expect(!replaced.emit(root.appendingPathComponent(fixtures.sessionID.uuidString.lowercased() + "/events.jsonl")))
        #expect(replaced.scope.recursive == [root.appendingPathComponent(fixtures.otherSessionID.uuidString.lowercased(), isDirectory: true)])
        await sidebarEventually { await reads.calls == baseline + 32 }
        poller.setVisible(false)
        await reads.complete(fixtures.snapshot(sessions: [], now: clock.now()))
        await sidebarEventually { !poller.isReading }
    }

    @Test func failedRegistrationRecoversOnFallbackWithoutNativeEvents() async throws {
        let attempts = CopilotReaderTestClock(Date(timeIntervalSince1970: 0))
        let lease = SyntheticFileLease(scope: .init(recursive: [], directories: [URL(fileURLWithPath: "/synthetic")]))
        let trigger = SidebarRefreshTrigger(coalesce: {}, watch: {
            attempts.advance(by: 1)
            if attempts.now().timeIntervalSince1970 == 1 { throw CopilotFileError.missing }
            return lease
        })
        let fallback = RefreshBarrier()
        for count in 1...2 {
            let pending = Task { try await trigger.wait { try await fallback.wait() } }
            await sidebarEventually { await fallback.active == 1 }
            await fallback.release()
            try await pending.value
            #expect(attempts.now().timeIntervalSince1970 == Double(count))
        }
        let pending = Task { try await trigger.wait { try await fallback.wait() } }
        defer { pending.cancel() }
        await sidebarEventually { await fallback.active == 1 }
        try #require(lease.emit(URL(fileURLWithPath: "/synthetic/binding.json")))
        try await pending.value
        #expect(await fallback.released == 2)
        await trigger.stop()
    }

    @Test func endedStreamReRegistersBeforeReturningToTheReader() async throws {
        let lease = SyntheticFileLease(scope: .init(recursive: [], directories: [URL(fileURLWithPath: "/synthetic")]))
        let attempts = CopilotReaderTestClock(Date(timeIntervalSince1970: 0))
        let trigger = SidebarRefreshTrigger(coalesce: {}, watch: { attempts.advance(by: 1); return lease })
        let old = AsyncStream<Void>.makeStream()
        await trigger.subscribe(old.stream)
        let fallback = RefreshBarrier()
        let pending = Task { try await trigger.wait { try await fallback.wait() } }
        defer { pending.cancel(); Task { await trigger.stop() } }
        await sidebarEventually { await fallback.active == 1 }
        old.continuation.finish()
        try await pending.value
        #expect(attempts.now().timeIntervalSince1970 == 1)
        #expect(await fallback.released == 0)
        let next = Task { try await trigger.wait { try await fallback.wait() } }
        defer { next.cancel() }
        await sidebarEventually { await fallback.active == 1 }
        try #require(lease.emit(URL(fileURLWithPath: "/synthetic/current.json")))
        try await next.value
        #expect(attempts.now().timeIntervalSince1970 == 1)
        await trigger.stop()
    }

    @Test(arguments: [DispatchSource.FileSystemEvent.rename, .delete, .revoke, [.write, .rename]])
    func bindingWritesReadWithoutReRegisteringAndReplacementRecovers(
        invalidation: DispatchSource.FileSystemEvent
    ) async throws {
        let fixtures = SidebarTreeFixtures()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let registrations = CopilotReaderTestClock(Date(timeIntervalSince1970: 0))
        let leases = AsyncStream<SyntheticDirectoryLease>.makeStream()
        let trigger = await SidebarRefreshTrigger.copilot(
            bindings: URL(fileURLWithPath: "/synthetic/bindings"),
            sessionRoot: URL(fileURLWithPath: "/synthetic/sessions"),
            coalesce: {},
            watch: { _ in
                registrations.advance(by: 1)
                let lease = SyntheticDirectoryLease()
                leases.continuation.yield(lease)
                return lease
            }
        )
        var iterator = leases.stream.makeAsyncIterator()
        let first = try #require(await iterator.next())
        let reads = RefreshReadGate<CopilotSnapshot>()
        let fallback = RefreshBarrier()
        let value = fixtures.snapshot(sessions: [], now: date)
        let poller = SidebarCopilotPolling(
            read: { CopilotSnapshotAdapter.snapshot(try await reads.read(), workspaceBySurface: $0) },
            pause: { try await fallback.wait() }, expiryPause: sidebarFrozenExpiry,
            changes: { trigger }, now: { date }
        )
        defer {
            poller.setVisible(false)
            leases.continuation.finish()
            Task { await reads.cancel() }
        }
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        await sidebarEventually { await reads.calls == 1 }
        await reads.complete(value)
        await sidebarEventually { await fallback.active == 1 }
        for index in 1...30 {
            first.delivery.receive(.write)
            await sidebarEventually { await reads.calls == index + 1 }
            try #require(registrations.now().timeIntervalSince1970 == 1,
                         "Ordinary bindings writes must not rebuild native registrations")
            await reads.complete(value)
            await sidebarEventually { await fallback.active == 1 }
        }
        first.delivery.receive(invalidation)
        await sidebarEventually { await reads.calls == 32 }
        #expect(registrations.now().timeIntervalSince1970 == 2)
        let replacement = try #require(await iterator.next())
        await reads.complete(value)
        await sidebarEventually { await fallback.active == 1 }
        replacement.delivery.receive(.write)
        await sidebarEventually { await reads.calls == 33 }
        #expect(registrations.now().timeIntervalSince1970 == 2)
        #expect(await fallback.released == 0)
        poller.setVisible(false)
        await reads.complete(value)
        await sidebarEventually { !poller.isReading }
    }

    @Test func missingSessionRootsDoNotDiscardHealthyRootsButUnsafeRootsRefuse() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/watcher-fixtures/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let healthy = root.appendingPathComponent("healthy", isDirectory: true)
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        try FileManager.default.createDirectory(at: healthy, withIntermediateDirectories: false)
        let scope = SidebarFileWatcher.Scope(recursive: [missing, healthy], directories: [])
        #expect(try scope.existingRecursiveRoots(owner: getuid()) == [healthy])
        let unsafe = root.appendingPathComponent("unsafe", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: healthy)
        #expect(throws: CopilotFileError.unsafePath) {
            try SidebarFileWatcher.Scope(recursive: [missing, healthy, unsafe], directories: [])
                .existingRecursiveRoots(owner: getuid())
        }
    }

    @Test(arguments: ["missing", "denied", "start"])
    func failedWatcherCreationKeepsCopilotTreeReadyOnFallback(failure: String) async throws {
        let fixtures = SidebarTreeFixtures()
        let clock = CopilotReaderTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let trigger = await SidebarRefreshTrigger.copilot(
            bindings: URL(fileURLWithPath: "/synthetic/bindings"),
            sessionRoot: URL(fileURLWithPath: "/synthetic/sessions"),
            coalesce: {}, watch: { _ in
                switch failure {
                case "missing": throw CopilotFileError.missing
                case "denied": throw CopilotFileError.permissionDenied
                default: throw SidebarFileWatcher.Failure.start
                }
            }
        )
        let reads = RefreshReadGate<CopilotSnapshot>()
        let fallback = RefreshBarrier()
        let poller = SidebarCopilotPolling(
            read: { CopilotSnapshotAdapter.snapshot(try await reads.read(), workspaceBySurface: $0) },
            pause: { try await fallback.wait() }, expiryPause: sidebarFrozenExpiry,
            changes: { trigger }, now: { clock.now() }
        )
        defer { poller.setVisible(false); Task { await reads.cancel() } }
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        for index in 1...8 {
            await sidebarEventually { await reads.calls == index }
            var session = fixtures.session(state: .working, now: clock.now())
            session.sessionName = "Synthetic live session"
            await reads.complete(fixtures.snapshot(sessions: [session], now: clock.now()))
            if index == 1 {
                // The first shown-set registration requests one catch-up read, even if it fails.
                await sidebarEventually { await reads.calls == 2 }
            } else {
                await sidebarEventually { await fallback.active == 1 }
            }
            #expect(poller.tree.availability == .ready)
            #expect(poller.tree.sessions.first?.state == .working)
            #expect(poller.tree.sessions.first?.sessionName == "Synthetic live session")
            if index > 1 && index < 8 {
                clock.advance(by: 2)
                await fallback.release()
            }
        }
        #expect(await fallback.released == 6)
        #expect(await reads.maximumActive == 1)
    }
}

@MainActor
struct SidebarFileWatcherAcceptanceTests {
    @Test(.enabled(if: SidebarAppKitTestScope.localAcceptanceEnabled))
    func nativeWatcherSignalsNestedAppendsAndRejectsSymlinkRoots() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/watcher-fixtures/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let file = child.appendingPathComponent("events.jsonl")
        try Data("synthetic\n".utf8).write(to: file)
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        let watcher = try SidebarFileWatcher(roots: [missing, root])
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

        let directory = try SidebarFileWatcher(scope: .init(recursive: [missing], directories: [child]))
        let replaced = RefreshCounter()
        let bindingConsumer = Task {
            for await _ in directory.events { await replaced.increment(); break }
        }
        defer { bindingConsumer.cancel() }
        try Data("replacement\n".utf8).write(to: file, options: .atomic)
        await sidebarEventually { await replaced.count == 1 }
        bindingConsumer.cancel()
        await bindingConsumer.value
        withExtendedLifetime(directory) {}
    }

    @Test(.enabled(if: SidebarAppKitTestScope.localAcceptanceEnabled))
    func endedStreamAndMissingRootRecoverAtFallbackWithoutAnExtraTimer() async throws {
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

    @Test(.enabled(if: SidebarAppKitTestScope.localAcceptanceEnabled))
    func nativeRootReplacementEndsOldLease() async throws {
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

nonisolated private final class SyntheticFileLease: SidebarFileWatching {
    let scope: SidebarFileWatcher.Scope
    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(scope: SidebarFileWatcher.Scope) {
        self.scope = scope
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit { continuation.finish() }

    // Model the native registration boundary, not the production reader or its coalescing.
    func emit(_ path: URL) -> Bool {
        guard scope.recursive.contains(where: { path.path.hasPrefix($0.path + "/") })
                || scope.directories.contains(where: { $0.path == path.deletingLastPathComponent().path }) else { return false }
        continuation.yield(())
        return true
    }
}

nonisolated private final class SyntheticDirectoryLease: SidebarFileWatching {
    let events: AsyncStream<Void>
    let delivery: SidebarFileWatcher.DirectoryEvents

    init() {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = stream.stream
        delivery = .init(continuation: stream.continuation)
    }

    deinit { delivery.continuation.finish() }
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
