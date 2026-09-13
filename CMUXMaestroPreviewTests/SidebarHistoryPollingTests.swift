import Foundation
import Testing

@MainActor
struct SidebarHistoryPollingTests {
    private let fixtures = SidebarTreeFixtures()
    private let initial = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func rapidRefreshDoesNotResetHistoryDeadlineAndBoundaryDoesNotBusyLoop() async {
        let clock = HistoryTestClock(initial)
        let harness = HistoryPollingHarness()
        let poller = poller(clock, harness)
        start(poller)
        await sidebarEventually { await harness.reads == 1 }
        await harness.succeed(snapshot(at: clock.read()))
        await sidebarEventually {
            let paused = await harness.isPaused
            let count = await harness.delays.count
            return paused && count == 2
        }
        #expect(await harness.delays.sorted() == [5, 8])
        for index in 2...4 {
            clock.advance(1)
            await harness.nextRead()
            await sidebarEventually { await harness.reads == index }
            await harness.succeed(snapshot(at: clock.read()))
            await sidebarEventually { await harness.isPaused }
        }
        #expect(poller.tree.nextHistoryExpiry == initial.addingTimeInterval(5))
        #expect(await harness.delays.filter { $0 == 5 }.count == 1)
        clock.advance(2)
        await harness.fire(delay: 5)
        await sidebarEventually { poller.tree.retainedHistoryCount == 0 }
        #expect(poller.tree.knownRunningChildren == 1)
        #expect(poller.tree.hiddenHistoryCount == 1)
        #expect(poller.tree.nextHistoryExpiry == nil)
        #expect(await harness.delays.allSatisfy { $0 > 0 })
        #expect(await harness.delays.count == 5)
        poller.setVisible(false)
        await sidebarEventually { await harness.activeTimers == 0 && !poller.isReading }
    }

    @Test func retentionChangeReschedulesWithoutReadAndNeverCancelsOnlyHistoryTimer() async {
        let clock = HistoryTestClock(initial)
        let harness = HistoryPollingHarness()
        let poller = poller(clock, harness)
        start(poller)
        await sidebarEventually { await harness.reads == 1 }
        await harness.succeed(snapshot(at: initial))
        await sidebarEventually { await harness.delays.count == 2 }
        poller.updateHistory(.init(retention: .oneMinute))
        await sidebarEventually { await harness.delays.contains(50) }
        #expect(await harness.reads == 1)
        #expect(poller.tree.nextHistoryExpiry == initial.addingTimeInterval(50))
        poller.updateHistory(.init(retention: .never))
        await sidebarEventually { await harness.activeTimers == 1 }
        #expect(poller.tree.nextHistoryExpiry == nil)
        #expect(poller.tree.retainedHistoryCount == 1)
        let outcomes = poller.tree.dismissibleOutcomes
        poller.updateHistory(.init(retention: .never, dismissed: outcomes))
        #expect(poller.tree.retainedHistoryCount == 0)
        #expect(poller.tree.knownRunningChildren == 1)
        poller.updateHistory(.init(retention: .never))
        #expect(poller.tree.retainedHistoryCount == 1)
        poller.setVisible(false)
        await sidebarEventually { await harness.activeTimers == 0 && !poller.isReading }
    }

    @Test(arguments: ["hide", "disconnect", "revoke", "denied", "failed"])
    func lossOfVisibilityOrAccessCancelsTimersAndDropsHistory(_ mode: String) async {
        let clock = HistoryTestClock(initial)
        let harness = HistoryPollingHarness()
        let poller = poller(clock, harness)
        start(poller)
        await sidebarEventually { await harness.reads == 1 }
        await harness.succeed(snapshot(at: initial))
        await sidebarEventually {
            let paused = await harness.isPaused
            let count = await harness.activeTimers
            return paused && count == 2
        }
        switch mode {
        case "hide": poller.setVisible(false)
        case "disconnect": poller.update(topology: fixtures.topology(), connected: false)
        case "revoke": poller.update(topology: fixtures.topology(granted: false), connected: true)
        default:
            await harness.nextRead()
            await sidebarEventually { await harness.reads == 2 }
            if mode == "denied" {
                await harness.succeed(snapshot(at: initial, issues: [.permissionDenied]))
            } else {
                await harness.failRead()
            }
        }
        await sidebarEventually { await harness.activeTimers == 0 && poller.tree.sessions.isEmpty }
        poller.updateHistory(.init(retention: .never))
        #expect(poller.tree.sessions.isEmpty)
        #expect(poller.tree.dismissibleOutcomes.isEmpty)
        clock.advance(100)
        await harness.fire(delay: 5)
        #expect(poller.tree.sessions.isEmpty)
        poller.setVisible(false)
        await sidebarEventually { !poller.isReading }
    }

    @Test func staleOrRegressingSnapshotCannotRestartRetentionAndFreshnessCannotBeBypassed() async {
        let clock = HistoryTestClock(initial)
        let harness = HistoryPollingHarness()
        let poller = poller(clock, harness)
        start(poller)
        await sidebarEventually { await harness.reads == 1 }
        await harness.succeed(snapshot(at: initial))
        await sidebarEventually {
            let paused = await harness.isPaused
            let count = await harness.delays.count
            return paused && count == 2
        }
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 2 }
        await harness.succeed(snapshot(at: initial.addingTimeInterval(-1)))
        await sidebarEventually { await harness.isPaused }
        #expect(await harness.delays.count == 2)
        clock.advance(8)
        await harness.fire(delay: 8)
        await sidebarEventually { poller.tree.availability == .unavailable }
        poller.updateHistory(.init(retention: .never))
        #expect(poller.tree.sessions.isEmpty)
        await sidebarEventually { await harness.activeTimers == 0 }
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 3 }
        await harness.succeed(snapshot(at: clock.read()))
        await sidebarEventually { poller.tree.retainedHistoryCount == 1 }
        #expect(poller.tree.knownRunningChildren == 1)
        poller.setVisible(false)
        await sidebarEventually { await harness.activeTimers == 0 && !poller.isReading }
    }

    private func start(_ poller: SidebarCopilotPolling) {
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
    }

    private func poller(_ clock: HistoryTestClock, _ harness: HistoryPollingHarness) -> SidebarCopilotPolling {
        SidebarCopilotPolling(
            read: { _ in try await harness.read() },
            pause: { try await harness.pause() },
            expiryPause: { try await harness.wait($0) },
            now: { clock.read() }
        )
    }

    private func snapshot(at date: Date, issues: [CopilotIssue] = []) -> CopilotSnapshot {
        let completed = CopilotChildWork(
            id: "ended", parentID: nil, kind: .subagent, name: "Ended", state: .completed, model: nil,
            terminalEvent: .init(id: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
                                 timestamp: initial.addingTimeInterval(-10))
        )
        return fixtures.snapshot(sessions: [fixtures.session(children: [
            completed, fixtures.child("working", state: .working)
        ], now: date)], issues: issues, complete: issues.isEmpty, now: date)
    }
}

private final class HistoryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private actor HistoryPollingHarness {
    private(set) var reads = 0
    private(set) var delays: [TimeInterval] = []
    private var reading: CheckedContinuation<CopilotSnapshot, Error>?
    private var pausing: CheckedContinuation<Void, Error>?
    private var timers: [Int: CheckedContinuation<Void, Error>] = [:]
    var isPaused: Bool { pausing != nil }
    var activeTimers: Int { timers.count }

    func read() async throws -> CopilotSnapshot {
        reads += 1
        return try await withCheckedThrowingContinuation { reading = $0 }
    }
    func succeed(_ snapshot: CopilotSnapshot) {
        let pending = reading
        reading = nil
        pending?.resume(returning: snapshot)
    }
    func failRead() {
        let pending = reading
        reading = nil
        pending?.resume(throwing: CocoaError(.fileReadNoPermission))
    }
    func pause() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { pausing = $0 }
        } onCancel: { Task { await self.cancelPause() } }
    }
    func nextRead() {
        let pending = pausing
        pausing = nil
        pending?.resume()
    }
    private func cancelPause() {
        let pending = pausing
        pausing = nil
        pending?.resume(throwing: CancellationError())
    }
    func wait(_ delay: TimeInterval) async throws {
        let index = delays.count
        delays.append(delay)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { timers[index] = $0 }
        } onCancel: { Task { await self.cancelTimer(index) } }
    }
    func fire(delay: TimeInterval) {
        for index in timers.keys.filter({ delays[$0] == delay }) {
            timers.removeValue(forKey: index)?.resume()
        }
    }
    private func cancelTimer(_ index: Int) {
        timers.removeValue(forKey: index)?.resume(throwing: CancellationError())
    }
}
