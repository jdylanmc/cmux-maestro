import Foundation
import Observation
import Testing

@MainActor
struct SidebarOrchestrationDeadlineTests {
    private let initial = Date(timeIntervalSince1970: 1_800_000_000)
    private let fixtures = SidebarTreeFixtures()

    @Test(arguments: [false, true], [false, true])
    func oldNodeExpiresInsideFreshSnapshotWithoutCopilotUpdates(
        unavailableCopilot: Bool, deadlineWake: Bool
    ) async throws {
        let clock = CopilotReaderTestClock(initial.addingTimeInterval(50))
        let harness = OrchestrationDeadlineHarness()
        let older = node(at: initial, surface: fixtures.surfaceA)
        let newer = node(at: clock.now(), surface: fixtures.surfaceB, workspace: fixtures.workspaceB)
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: clock.now(), complete: true, omittedCount: 0, nodes: [older, newer]
        )
        let poller = SidebarOrchestrationPolling(
            read: { snapshot }, pause: { try await harness.pause() },
            expiryPause: { try await harness.wait($0) }, now: { clock.now() }
        )
        let copilot = SidebarCopilotTree(
            availability: unavailableCopilot ? .unavailable : .ready, sessions: [], issues: [], generatedAt: clock.now()
        )
        poller.updateObservedSessions(copilot, now: clock.now())
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        defer { poller.setVisible(false) }
        await sidebarEventually { await harness.paused }
        #expect(SidebarPresentation.managedState(
            older, availability: poller.availability, now: clock.now(), tree: copilot
        ).title == "Working")
        let notifications = CopilotReaderTestClock(initial)
        withObservationTracking { _ = poller.snapshot } onChange: { notifications.advance(by: 1) }
        await sidebarEventually { await harness.timerCount == 1 }
        await harness.resumePause()
        await sidebarEventually { await harness.readPauses == 2 }
        #expect(notifications.now() == initial, "Unchanged polls still do not publish")
        #expect(await harness.timerRegistrations == 1, "Unchanged polls retain the existing deadline")
        let delay = try #require(await harness.nextDelay)
        #expect(delay > 10 && delay < 11)
        clock.advance(by: 10)
        #expect(SidebarPresentation.managedState(
            older, availability: poller.availability, now: clock.now(), tree: copilot
        ).title == "Working")
        clock.advance(by: delay - 10)
        if deadlineWake {
            await harness.fire()
        } else {
            await harness.resumePause()
            await sidebarEventually { await harness.readPauses == 3 }
        }
        await sidebarEventually { notifications.now() != initial }
        #expect(poller.availability == .ready, "The envelope and newer node are still fresh")
        #expect(poller.snapshot == snapshot, "Deadline notification never changes evidence")
        #expect(SidebarPresentation.managedState(
            older, availability: poller.availability, now: clock.now(), tree: copilot
        ).title.contains("Observation: Stale"))
        #expect(SidebarPresentation.managedState(
            newer, availability: poller.availability, now: clock.now(), tree: copilot
        ).title == "Working")
        var summary = SidebarBranchSummary(nodes: [])
        summary.include(managed: poller.snapshot.nodes, availability: poller.availability, now: clock.now())
        #expect(summary.running == 1 && summary.incomplete)
        #expect(await harness.readPauses == (deadlineWake ? 2 : 3),
                "The deadline does not read or wait for another poll")
        poller.setVisible(false)
        await sidebarEventually { await harness.timerCount == 0 }
    }

    @Test func processAndGitDeadlinesInvalidateWithoutChangingTheEnvelope() async throws {
        let clock = CopilotReaderTestClock(initial.addingTimeInterval(50))
        let harness = OrchestrationDeadlineHarness()
        let owner = node(
            at: clock.now(), surface: fixtures.surfaceA, gitAt: initial,
            gitChangesAt: initial.addingTimeInterval(-10)
        )
        let process = SidebarProcessObservation.Node(
            nodeId: owner.id, copilotSessionId: UUID(), generation: 1, state: "owned-current",
            observedAt: initial, processes: [
                .init(pid: 1234, startMicros: 1, name: "synthetic", group: "separate", state: "owned-current", listeners: [])
            ], omittedCount: 0
        )
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: clock.now(), complete: true, omittedCount: 0,
            nodes: [owner], processes: [owner.id: process]
        )
        let poller = SidebarOrchestrationPolling(
            read: { snapshot }, pause: { try await harness.pause() },
            expiryPause: { try await harness.wait($0) }, now: { clock.now() }
        )
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        defer { poller.setVisible(false) }
        await sidebarEventually { await harness.timerCount == 1 }
        #expect(owner.hasFreshGitEvidence(at: clock.now()))
        #expect(owner.currentGitChanges(at: clock.now()) != nil)
        #expect(SidebarProcessPresentation.lines(process, now: clock.now()).first?.copyableValue == "1234")
        let notifications = CopilotReaderTestClock(initial)
        withObservationTracking { _ = poller.snapshot } onChange: { notifications.advance(by: 1) }
        clock.advance(by: try #require(await harness.nextDelay))
        await harness.fire()
        await sidebarEventually { notifications.now() != initial }
        #expect(owner.currentGitChanges(at: clock.now()) == nil)
        #expect(owner.hasFreshGitEvidence(at: clock.now()))
        #expect(SidebarProcessPresentation.lines(process, now: clock.now()).first?.copyableValue == "1234")
        await sidebarEventually { await harness.timerCount == 1 }
        let changesExpired = notifications.now()
        withObservationTracking { _ = poller.snapshot } onChange: { notifications.advance(by: 1) }
        clock.advance(by: try #require(await harness.nextDelay))
        await harness.fire()
        await sidebarEventually { notifications.now() != changesExpired }
        #expect(!owner.hasFreshGitEvidence(at: clock.now()))
        #expect(SidebarProcessPresentation.lines(process, now: clock.now()).first?.value.contains("Stale") == true)
        #expect(SidebarProcessPresentation.lines(process, now: clock.now()).first?.copyableValue == nil)
        await sidebarEventually { await harness.timerCount == 1 }
        // The node/envelope expire next; the retained process has a separate five-minute limit.
        clock.advance(by: try #require(await harness.nextDelay))
        await harness.fire()
        await sidebarEventually { poller.availability == .stale }
        await sidebarEventually { await harness.timerCount == 1 }
        withObservationTracking { _ = poller.snapshot } onChange: { notifications.advance(by: 1) }
        let previous = notifications.now()
        clock.advance(by: try #require(await harness.nextDelay))
        await harness.fire()
        await sidebarEventually { notifications.now() != previous }
        #expect(SidebarProcessPresentation.lines(process, now: clock.now()).first?.value == "Unavailable")
        #expect(poller.snapshot == snapshot)
        await sidebarEventually { await harness.timerCount == 0 }
    }

    @Test func futureNodeBecomesCurrentWithoutAnotherRead() async throws {
        let clock = CopilotReaderTestClock(initial.addingTimeInterval(50))
        let harness = OrchestrationDeadlineHarness()
        let future = node(at: initial.addingTimeInterval(80), surface: fixtures.surfaceA)
        let snapshot = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: clock.now(), complete: true, omittedCount: 0, nodes: [future]
        )
        let poller = SidebarOrchestrationPolling(
            read: { snapshot }, pause: { try await harness.pause() },
            expiryPause: { try await harness.wait($0) }, now: { clock.now() }
        )
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        defer { poller.setVisible(false) }
        await sidebarEventually { await harness.timerCount == 1 }
        #expect(SidebarPresentation.managedState(
            future, availability: poller.availability, now: clock.now()
        ).title.contains("Observation: Unavailable"))
        let notifications = CopilotReaderTestClock(initial)
        withObservationTracking { _ = poller.snapshot } onChange: { notifications.advance(by: 1) }
        let delay = try #require(await harness.nextDelay)
        #expect(delay == 29)
        clock.advance(by: delay)
        await harness.fire()
        await sidebarEventually { notifications.now() != initial }
        #expect(SidebarPresentation.managedState(
            future, availability: poller.availability, now: clock.now()
        ).title == "Working")
        #expect(await harness.readPauses == 1)
    }

    private func node(
        at date: Date, surface: UUID, workspace: UUID? = nil, gitAt: Date? = nil, gitChangesAt: Date? = nil
    ) -> SidebarOrchestrationNode {
        .init(id: UUID(), runId: UUID(), parentId: nil, role: "worker", label: "Synthetic",
              workspaceId: workspace ?? fixtures.workspaceA, surfaceId: surface, generation: 1,
              phase: "turn-running", availability: "busy",
              worktreeLabel: gitAt == nil ? nil : "synthetic",
              gitEvidenceStatus: gitAt == nil ? nil : "verified", gitEvidenceAt: gitAt,
              gitChangesStatus: gitChangesAt == nil ? nil : "verified",
              gitChanges: gitChangesAt.map { _ in .init(files: 1, insertions: 1, deletions: 0, untrackedFiles: 0, binaryFiles: 0) },
              gitChangesAt: gitChangesAt,
              createdAt: date, updatedAt: date)
    }
}

private actor OrchestrationDeadlineHarness {
    private(set) var readPauses = 0
    private(set) var timerRegistrations = 0
    private var idle: CheckedContinuation<Void, Error>?
    private var timers: [UUID: (delay: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = [:]
    var paused: Bool { idle != nil }
    var timerCount: Int { timers.count }
    var nextDelay: TimeInterval? { timers.values.map(\.delay).min() }

    func pause() async throws {
        readPauses += 1
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { idle = $0 }
        } onCancel: { Task { await self.cancelPause() } }
    }

    func wait(_ delay: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                timerRegistrations += 1
                timers[id] = (delay, $0)
            }
        } onCancel: { Task { await self.cancelTimer(id) } }
    }

    func fire() {
        let pending = timers.values
        timers.removeAll()
        for timer in pending { timer.continuation.resume() }
    }

    func resumePause() {
        let pending = idle
        idle = nil
        pending?.resume()
    }

    private func cancelTimer(_ id: UUID) { timers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
    private func cancelPause() {
        let pending = idle
        idle = nil
        pending?.resume(throwing: CancellationError())
    }
}
