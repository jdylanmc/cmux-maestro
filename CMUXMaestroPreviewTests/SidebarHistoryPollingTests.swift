import Foundation
import Testing

@MainActor
struct SidebarHistoryPollingTests {
    private let fixtures = SidebarTreeFixtures()
    private let initial = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func acknowledgementReprojectsWithoutReadingAndCannotRestoreExpiredObservation() async {
        let clock = HistoryTestClock(initial)
        let harness = HistoryPollingHarness()
        let poller = poller(clock, harness)
        let outcome = AgentAttention(kind: .turnFinished, evidence: .init(source: "copilot.events", eventID: UUID()),
                                     occurredAt: initial)
        let observation = CopilotSessionObservation(
            sessionID: fixtures.sessionID, surfaceID: fixtures.surfaceA, launchWorkspaceID: fixtures.workspaceA,
            liveness: .alive, state: .idle, model: nil, children: [], observedAt: initial, attention: [outcome]
        )
        start(poller)
        await sidebarEventually { await harness.reads == 1 }
        await harness.succeed(fixtures.snapshot(sessions: [observation], now: initial))
        await sidebarEventually { await harness.isPaused && poller.tree.attentionOwnerCount == 1 }
        let settings = SidebarAttentionSettings(acknowledged: poller.tree.acknowledgeableOutcomes)
        poller.updateAttention(settings)
        #expect(poller.tree.attentionOwnerCount == 0)
        #expect(poller.tree.sessions.first?.state == .idle)
        #expect(await harness.reads == 1)
        poller.updateHistory(.init(retention: .never))
        #expect(poller.tree.attentionOwnerCount == 0)
        await sidebarEventually { await harness.activeTimers == 1 }
        clock.advance(8)
        await harness.fire(delay: 8)
        await sidebarEventually { poller.tree.availability == .unavailable }
        poller.updateAttention(.init())
        #expect(poller.tree.sessions.isEmpty)
        #expect(poller.tree.acknowledgeableOutcomes.isEmpty)
        poller.setVisible(false)
        await sidebarEventually { await harness.activeTimers == 0 && !poller.isReading }
    }

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
        await sidebarEventually { await harness.activeTimers == 1 }
        #expect(poller.tree.statusSessions.count == 1)
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

    @Test func readLossRetainsOnlyVisualStatusForFiveMinutesThenRecovers() async throws {
        let clock = HistoryTestClock(initial)
        let harness = HistoryPollingHarness()
        let poller = poller(clock, harness)
        start(poller)
        await sidebarEventually { await harness.reads == 1 }
        await harness.succeed(snapshot(at: initial))
        await sidebarEventually { await harness.isPaused }
        clock.advance(2)
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 2 }
        await harness.failRead(CopilotFileError.io)
        await sidebarEventually { await harness.isPaused && poller.tree.statusSessions.count == 1 }
        #expect(poller.tree.sessions.isEmpty)
        #expect(poller.tree.dismissibleOutcomes.isEmpty)
        #expect(poller.tree.acknowledgeableOutcomes.isEmpty)
        let display = SidebarVisibleWork(tree: poller.tree, managed: [], history: .init(), showEnded: false).tree
        let session = try #require(display.sessions.first)
        #expect(session.id == fixtures.sessionID && session.surfaceID == fixtures.surfaceA)
        #expect(session.liveness == .unknown && session.state == .unknown)
        #expect(session.model == nil && session.activity == nil && session.attention.isEmpty)
        #expect(SidebarPresentation.sessionState(session).title == "Idle")
        #expect(session.nodes.contains { $0.id == "working" && $0.isInternalTask })
        #expect(session.nodes.allSatisfy { $0.state == .unknown && $0.terminalEvent == nil })
        #expect(display.dismissibleOutcomes.isEmpty && display.acknowledgeableOutcomes.isEmpty)
        #expect(SidebarSeenWork.capture(.session(session.id), tree: display).notices.isEmpty)
        #expect(SidebarPresentation.inspection(
            for: .unmanaged(.session(session.id)), hierarchy: fixtures.hierarchy(), connected: true,
            tree: display, managed: .empty, availability: .ready, now: clock.read()
        ) == nil)
        #expect(SidebarPresentation.inspection(
            for: .unmanaged(.surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA)),
            hierarchy: fixtures.hierarchy(), connected: true, tree: display,
            managed: .empty, availability: .ready, now: clock.read()
        ) != nil)
        clock.advance(299)
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 3 }
        await harness.failRead(CopilotFileError.io)
        await sidebarEventually {
            let paused = await harness.isPaused
            let timers = await harness.activeTimers
            return paused && timers == 1
        }
        #expect(SidebarPresentation.sessionState(try #require(poller.tree.statusSessions.first)).title == "Idle")
        clock.advance(1)
        await harness.fire(delay: 1)
        await sidebarEventually { poller.tree.statusSessions.first?.lastKnownState == nil }
        #expect(SidebarPresentation.sessionState(try #require(poller.tree.statusSessions.first)).title == "Status unavailable")
        #expect(poller.tree.statusSessions.first?.nodes.allSatisfy { $0.lastKnownState == nil } == true)
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 4 }
        await harness.succeed(snapshot(at: clock.read()))
        await sidebarEventually { await harness.isPaused && poller.tree.sessions.count == 1 }
        #expect(poller.tree.statusSessions.isEmpty)
        #expect(poller.tree.knownRunningChildren == 1)
        poller.setVisible(false)
        await sidebarEventually { await harness.activeTimers == 0 && !poller.isReading }
    }

    @Test(arguments: [CopilotIssue.permissionDenied, .identityChanged, .ambiguousIdentity,
                      .integrationNotInstalled, .noIdentityRecords])
    func unsafeEvidenceInvalidatesVisualGraceImmediately(_ issue: CopilotIssue) async {
        let clock = HistoryTestClock(initial)
        let harness = HistoryPollingHarness()
        let poller = poller(clock, harness)
        start(poller)
        await sidebarEventually { await harness.reads == 1 }
        await harness.succeed(snapshot(at: initial))
        await sidebarEventually { await harness.isPaused }
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 2 }
        await harness.failRead(CopilotFileError.io)
        await sidebarEventually { await harness.isPaused && !poller.tree.statusSessions.isEmpty }
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 3 }
        await harness.succeed(fixtures.snapshot(sessions: [], issues: [issue], complete: false, now: clock.read()))
        await sidebarEventually { await harness.isPaused }
        #expect(poller.tree.sessions.isEmpty && poller.tree.statusSessions.isEmpty)
        poller.setVisible(false)
        await sidebarEventually { await harness.activeTimers == 0 && !poller.isReading }
    }

    @Test func unsupportedSnapshotSchemaInvalidatesVisualGrace() async {
        let clock = HistoryTestClock(initial)
        let harness = HistoryPollingHarness()
        let poller = SidebarCopilotPolling(
            read: { placements in
                let source = try await harness.read()
                let snapshot = CopilotSnapshotAdapter.snapshot(source, workspaceBySurface: placements)
                return AgentSessionSnapshot(
                    schemaVersion: source.issues.contains(.unsupportedFormat) ? .init(rawValue: 999) : .current,
                    generatedAt: snapshot.generatedAt, workspaces: snapshot.workspaces,
                    sessions: snapshot.sessions, issues: snapshot.issues, completeness: snapshot.completeness
                )
            },
            pause: { try await harness.pause() },
            expiryPause: { try await harness.wait($0) },
            now: { clock.read() }
        )
        start(poller)
        await sidebarEventually { await harness.reads == 1 }
        await harness.succeed(snapshot(at: initial))
        await sidebarEventually { await harness.isPaused }
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 2 }
        await harness.failRead(CopilotFileError.io)
        await sidebarEventually { await harness.isPaused && !poller.tree.statusSessions.isEmpty }
        clock.advance(2)
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 3 }
        await harness.succeed(snapshot(at: clock.read(), issues: [.unsupportedFormat]))
        await sidebarEventually { await harness.isPaused }
        #expect(poller.tree.sessions.isEmpty && poller.tree.statusSessions.isEmpty)
        #expect(poller.tree.availability == .unavailable)
        clock.advance(2)
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 4 }
        await harness.succeed(snapshot(at: clock.read()))
        await sidebarEventually { await harness.isPaused }
        #expect(poller.tree.sessions.first?.state == .idle)
        poller.setVisible(false)
        await sidebarEventually { await harness.activeTimers == 0 && !poller.isReading }
    }

    @Test func unsupportedChildLifecycleDoesNotSuppressHealthySiblingPollsOrRecovery() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let healthySurface = UUID()
        let healthyDirectory = try fixture.addSession(surface: healthySurface)
        let healthyID = try #require(UUID(uuidString: healthyDirectory.lastPathComponent))
        let healthyEvents = healthyDirectory.appendingPathComponent("events.jsonl")
        try Data().write(to: healthyDirectory.appendingPathComponent("inuse.\(fixture.process.pid).lock"))
        try (copilotTestEvent("session.idle") + Data([10])).write(to: healthyEvents)
        try fixture.writeEvents([
            copilotTestEvent("session.idle"),
            copilotTestEvent("subagent.started", agent: "child", data: [
                "toolCallId": "task", "agentDisplayName": "Child"
            ])
        ])
        let topology = SidebarTopology(.init(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: true, surfaceMetadataAvailable: true, workspacePathsAvailable: false,
            workspaces: [.init(
                id: fixture.workspace, title: .available("Synthetic"), detail: .available(nil),
                isSelected: .available(false), isPinned: .available(false), unreadCount: .available(0),
                rootPath: .unavailable, projectRootPath: .unavailable,
                surfaces: .available([fixture.surface, healthySurface].map {
                    .init(id: $0, title: "Background chat", kind: .terminal, isFocused: false,
                          isPinned: false, unreadCount: 0, workingDirectory: .unavailable)
                })
            )], windowID: UUID()
        ))
        let clock = HistoryTestClock(initial)
        let reader = fixture.reader(clock: { clock.read() })
        let harness = HistoryPollingHarness()
        let poller = poller(clock, harness)
        poller.update(topology: topology, connected: true)
        poller.setVisible(true)
        await sidebarEventually { await harness.reads == 1 }
        await harness.succeed(try await reader.read(surfaceIDs: [fixture.surface, healthySurface]))
        await sidebarEventually { await harness.isPaused }
        #expect(poller.tree.sessions.count == 2)
        try fixture.append(copilotTestEvent("subagent.future_lifecycle", agent: "child") + Data([10]))
        let handle = try FileHandle(forWritingTo: healthyEvents)
        try handle.seekToEnd()
        try handle.write(contentsOf: copilotTestEvent("assistant.turn_start", data: ["turnId": "new"]) + Data([10]))
        try handle.close()

        for index in 2...4 {
            clock.advance(2)
            await harness.nextRead()
            await sidebarEventually { await harness.reads == index }
            let source = try await reader.read(surfaceIDs: [fixture.surface, healthySurface])
            #expect(source.issues.contains(.unsupportedFormat))
            let child = try #require(source.sessions.first { $0.sessionID == fixture.sessionID }?.children.first)
            #expect(child.state == .unknown && child.terminalEvent == nil)
            await harness.succeed(source)
            await sidebarEventually { await harness.isPaused }
            #expect(poller.tree.availability == .partial)
            #expect(poller.tree.issues.contains(.unsupportedFormat))
            #expect(poller.tree.sessions.count == 2 && poller.tree.statusSessions.isEmpty)
            #expect(poller.tree.sessions.first { $0.id == healthyID }?.state == .working)
            #expect(poller.tree.sessions.allSatisfy { $0.observedAt == clock.read() })
            #expect(!poller.tree.hasCompleteCounts)
        }

        try FileManager.default.removeItem(at: healthyEvents)
        clock.advance(2)
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 5 }
        await harness.succeed(try await reader.read(surfaceIDs: [fixture.surface, healthySurface]))
        await sidebarEventually { await harness.isPaused }
        #expect(poller.tree.sessions.map(\.id) == [fixture.sessionID])
        #expect(poller.tree.statusSessions.first?.id == healthyID)
        #expect(poller.tree.statusSessions.first?.lastKnownState == .working)
        #expect(poller.tree.issues.contains(.unsupportedFormat))

        try (copilotTestEvent("session.idle") + Data([10])).write(to: healthyEvents)
        clock.advance(2)
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 6 }
        await harness.succeed(try await reader.read(surfaceIDs: [fixture.surface, healthySurface]))
        await sidebarEventually { await harness.isPaused }
        #expect(poller.tree.sessions.count == 2 && poller.tree.statusSessions.isEmpty)
        #expect(poller.tree.sessions.first { $0.id == healthyID }?.state == .idle)
        #expect(poller.tree.issues.contains(.unsupportedFormat))
        poller.setVisible(false)
        await sidebarEventually { await harness.activeTimers == 0 && !poller.isReading }
    }

    @Test(arguments: ["replacement", "removed", "duplicate", "ambiguous"])
    func confirmedSubjectChangesCannotBorrowRetainedStatus(_ change: String) async {
        let clock = HistoryTestClock(initial)
        let harness = HistoryPollingHarness()
        let poller = poller(clock, harness)
        start(poller)
        await sidebarEventually { await harness.reads == 1 }
        await harness.succeed(snapshot(at: initial))
        await sidebarEventually { await harness.isPaused }
        clock.advance(2)
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 2 }
        let sessions: [CopilotSessionObservation]
        switch change {
        case "replacement": sessions = [fixtures.session(id: fixtures.otherSessionID, state: .working, now: clock.read())]
        case "duplicate": sessions = [fixtures.session(now: clock.read()), fixtures.session(now: clock.read())]
        case "ambiguous": sessions = [fixtures.session(liveness: .ambiguous, now: clock.read())]
        default: sessions = []
        }
        await harness.succeed(fixtures.snapshot(sessions: sessions, now: clock.read()))
        await sidebarEventually { await harness.isPaused }
        #expect(poller.tree.statusSessions.isEmpty)
        #expect(!poller.tree.sessions.contains { $0.id == fixtures.sessionID && $0.liveness == .alive })
        if change == "replacement" {
            #expect(poller.tree.sessions.first?.id == fixtures.otherSessionID)
            #expect(poller.tree.sessions.first?.state == .working)
        }
        poller.setVisible(false)
        await sidebarEventually { await harness.activeTimers == 0 && !poller.isReading }
    }

    @Test func idleRefreshIsNotLossAndOlderEvidenceCannotRecoverGrace() async {
        let clock = HistoryTestClock(initial)
        let harness = HistoryPollingHarness()
        let poller = poller(clock, harness)
        start(poller)
        for index in 1...5 {
            await sidebarEventually { await harness.reads == index }
            await harness.succeed(fixtures.snapshot(sessions: [fixtures.session(now: clock.read())], now: clock.read()))
            await sidebarEventually { await harness.isPaused }
            #expect(poller.tree.sessions.first?.state == .idle)
            #expect(poller.tree.statusSessions.isEmpty)
            clock.advance(100)
            await harness.nextRead()
        }
        await sidebarEventually { await harness.reads == 6 }
        await harness.failRead(CopilotFileError.io)
        await sidebarEventually { await harness.isPaused }
        for index in 7...8 {
            await harness.nextRead()
            await sidebarEventually { await harness.reads == index }
            let generated = index == 7 ? initial : clock.read()
            await harness.succeed(fixtures.snapshot(sessions: [fixtures.session(now: initial)], now: generated))
            await sidebarEventually { await harness.isPaused }
            #expect(poller.tree.sessions.isEmpty)
            #expect(poller.tree.statusSessions.first?.lastKnownState == .idle)
        }
        clock.advance(8)
        await harness.fire(delay: 8)
        await sidebarEventually { await harness.delays.contains(292) }
        clock.advance(292)
        await harness.fire(delay: 292)
        await sidebarEventually { poller.tree.statusSessions.first?.lastKnownState == nil }
        poller.setVisible(false)
        await sidebarEventually { await harness.activeTimers == 0 && !poller.isReading }
    }

    @Test(arguments: ["move", "revoke", "generation"], [false, true])
    func scopeChangesRejectCachedEvidenceUntilFreshRecovery(_ change: String, whileHidden: Bool) async throws {
        func registration(_ generation: Int) -> SidebarOrchestrationSnapshot {
            .init(version: 1, generatedAt: initial, complete: true, omittedCount: 0, nodes: [
                .init(id: fixtures.sessionID, runId: fixtures.otherSessionID, parentId: nil, role: "worker",
                      label: "Synthetic", workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA,
                      generation: generation, phase: "turn-running", availability: "busy",
                      copilotSessionId: fixtures.sessionID, executionMode: .interactive,
                      createdAt: initial, updatedAt: initial)
            ])
        }
        let clock = HistoryTestClock(initial)
        let harness = HistoryPollingHarness()
        let poller = poller(clock, harness)
        if change == "generation" { poller.updateManagedSubjects(registration(1)) }
        start(poller)
        await sidebarEventually { await harness.reads == 1 }
        await harness.succeed(snapshot(at: initial))
        await sidebarEventually { await harness.isPaused }
        clock.advance(1)
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 2 }
        await harness.failRead(CopilotFileError.io)
        await sidebarEventually { await harness.isPaused && !poller.tree.statusSessions.isEmpty }
        if whileHidden {
            poller.setVisible(false)
            await sidebarEventually {
                let paused = await harness.isPaused
                return !poller.isReading && !paused
            }
        }
        clock.advance(1)
        if change == "generation" {
            poller.updateManagedSubjects(registration(2))
        } else {
            poller.update(topology: fixtures.topology(moved: change == "move", granted: change != "revoke"), connected: true)
        }
        #expect(poller.tree.sessions.isEmpty && poller.tree.statusSessions.isEmpty)
        if change == "revoke" {
            await sidebarEventually {
                let paused = await harness.isPaused
                return !poller.isReading && !paused
            }
            clock.advance(1)
            poller.update(topology: fixtures.topology(), connected: true)
        }
        if whileHidden { poller.setVisible(true) }
        await sidebarEventually { await harness.reads == 3 }
        clock.advance(1)
        await harness.succeed(fixtures.snapshot(
            sessions: [fixtures.session(now: initial)], issues: [.stateUnavailable], complete: false, now: clock.read()
        ))
        await sidebarEventually { await harness.isPaused }
        #expect(poller.tree.sessions.isEmpty && poller.tree.statusSessions.isEmpty)

        // Hide/show cannot erase the scope barrier, even if the next cached read has no warning.
        clock.advance(1)
        poller.setVisible(false)
        poller.setVisible(true)
        await sidebarEventually { await harness.reads == 4 }
        await harness.succeed(fixtures.snapshot(sessions: [fixtures.session(now: initial)], now: clock.read()))
        await sidebarEventually { await harness.isPaused }
        #expect(poller.tree.sessions.isEmpty && poller.tree.statusSessions.isEmpty)

        // A newer cached timestamp still cannot initialize display memory while explicitly unreadable.
        let unreadableAt = clock.read()
        clock.advance(1)
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 5 }
        await harness.succeed(fixtures.snapshot(
            sessions: [fixtures.session(now: unreadableAt)], issues: [.stateUnavailable],
            complete: false, now: clock.read()
        ))
        await sidebarEventually { await harness.isPaused }
        #expect(poller.tree.sessions.isEmpty && poller.tree.statusSessions.isEmpty)
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 6 }
        await harness.failRead(CopilotFileError.io)
        await sidebarEventually { await harness.isPaused }
        clock.advance(301)
        poller.updateHistory(.init(retention: .never))
        #expect(poller.tree.sessions.isEmpty && poller.tree.statusSessions.isEmpty)

        await harness.nextRead()
        await sidebarEventually { await harness.reads == 7 }
        await harness.succeed(fixtures.snapshot(
            sessions: [fixtures.session(state: .working, now: clock.read())], now: clock.read()
        ))
        await sidebarEventually { await harness.isPaused }
        let recovered = try #require(poller.tree.sessions.first)
        #expect(recovered.state == .working && poller.tree.statusSessions.isEmpty)
        #expect(recovered.workspaceID == (change == "move" ? fixtures.workspaceB : fixtures.workspaceA))
        clock.advance(1)
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 8 }
        await harness.failRead(CopilotFileError.io)
        await sidebarEventually { await harness.isPaused }
        let retained = try #require(poller.tree.statusSessions.first)
        #expect(retained.lastKnownState == .working)
        #expect(retained.observedAt == recovered.observedAt && retained.workspaceID == recovered.workspaceID)
        #expect(poller.tree.sessions.isEmpty)
        if change == "generation" {
            #expect(retained.statusOwnerGeneration == 2)
            #expect(retained.statusOwnerID == fixtures.sessionID)
        }
        await sidebarEventually { await harness.activeTimers == 1 }
        clock.advance(300)
        await harness.fire(delay: 300)
        await sidebarEventually { poller.tree.statusSessions.first?.lastKnownState == nil }
        poller.setVisible(false)
        await sidebarEventually { await harness.activeTimers == 0 && !poller.isReading }
    }

    @Test(arguments: ["coordinator", "worker"])
    func managedVisualMemoryRequiresTheSameRegistrationGeneration(_ role: String) async {
        func node(_ generation: Int) -> SidebarOrchestrationNode {
            .init(id: fixtures.sessionID, runId: fixtures.otherSessionID, parentId: nil, role: role,
                  label: "Synthetic", workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA,
                  generation: generation, phase: role == "coordinator" ? "registered" : "turn-running",
                  availability: role == "coordinator" ? "idle" : "busy",
                  copilotSessionId: role == "coordinator" ? nil : fixtures.sessionID,
                  executionMode: .interactive, createdAt: initial, updatedAt: initial)
        }
        let clock = HistoryTestClock(initial)
        let harness = HistoryPollingHarness()
        let poller = poller(clock, harness)
        poller.updateManagedSubjects(.init(
            version: 1, generatedAt: initial, complete: true, omittedCount: 0, nodes: [node(1)]
        ))
        start(poller)
        await sidebarEventually { await harness.reads == 1 }
        await harness.succeed(snapshot(at: initial))
        await sidebarEventually { await harness.isPaused }
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 2 }
        await harness.failRead(CopilotFileError.io)
        await sidebarEventually { await harness.isPaused && !poller.tree.statusSessions.isEmpty }
        #expect(SidebarPresentation.managedState(node(1), availability: .ready, now: initial, tree: poller.tree).title == "Idle")
        #expect(SidebarPresentation.managedState(node(2), availability: .ready, now: initial, tree: poller.tree).title != "Idle")
        #expect(SidebarPresentation.managedModel(for: node(1), in: poller.tree, now: initial) == nil)
        #expect(!SidebarPresentation.managedNeedsInput(node(1), tree: poller.tree, now: initial))
        poller.setVisible(false)
        await sidebarEventually { await harness.activeTimers == 0 && !poller.isReading }
    }

    @Test func unavailableObserverPlaceholderIsNotAConfirmedRegistrationRemoval() async {
        let clock = HistoryTestClock(initial)
        let harness = HistoryPollingHarness()
        let poller = poller(clock, harness)
        poller.updateManagedSubjects(.init(
            version: 1, generatedAt: initial, complete: true, omittedCount: 0, nodes: [
                .init(id: fixtures.sessionID, runId: fixtures.otherSessionID, parentId: nil, role: "worker",
                      label: "Synthetic", workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA,
                      generation: 1, phase: "turn-running", availability: "busy",
                      copilotSessionId: fixtures.sessionID, executionMode: .interactive,
                      createdAt: initial, updatedAt: initial)
            ]
        ))
        start(poller)
        await sidebarEventually { await harness.reads == 1 }
        await harness.succeed(snapshot(at: initial))
        await sidebarEventually { await harness.isPaused }
        await harness.nextRead()
        await sidebarEventually { await harness.reads == 2 }
        await harness.failRead(CopilotFileError.io)
        await sidebarEventually { await harness.isPaused }
        poller.updateManagedSubjects(.empty)
        #expect(poller.tree.statusSessions.first?.lastKnownState == .idle)
        #expect(poller.tree.statusSessions.first?.statusOwnerGeneration == 1)
        #expect(await harness.reads == 2)

        clock.advance(1)
        poller.updateManagedSubjects(.init(
            version: 1, generatedAt: clock.read(), complete: true, omittedCount: 0, nodes: []
        ))
        #expect(poller.tree.sessions.isEmpty && poller.tree.statusSessions.isEmpty)
        await sidebarEventually { await harness.reads == 3 }
        clock.advance(1)
        await harness.succeed(fixtures.snapshot(sessions: [fixtures.session(now: initial)], now: clock.read()))
        await sidebarEventually { await harness.isPaused }
        #expect(poller.tree.sessions.isEmpty && poller.tree.statusSessions.isEmpty)
        poller.setVisible(false)
        await sidebarEventually { await harness.activeTimers == 0 && !poller.isReading }
    }

    private func poller(_ clock: HistoryTestClock, _ harness: HistoryPollingHarness) -> SidebarCopilotPolling {
        SidebarCopilotPolling(
            read: neutralRead { _ in try await harness.read() },
            pause: { try await harness.pause() },
            expiryPause: { try await harness.wait($0) },
            now: { clock.read() }
        )
    }

    private func snapshot(at date: Date, issues: [CopilotIssue] = []) -> CopilotSnapshot {
        let completed = CopilotChildWork(
            id: "ended", parentID: nil, kind: .skill, name: "Ended", state: .completed, model: nil,
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
    func failRead(_ error: any Error = CocoaError(.fileReadNoPermission)) {
        let pending = reading
        reading = nil
        pending?.resume(throwing: error)
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
