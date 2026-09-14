import Foundation
import Testing

@MainActor
struct SidebarHistoryReaderTests {
    @Test func completeVerifiedReadsPublishSemanticDegradationAndKeepItFresh() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let clock = HistoryReaderClock()
        let reader = reader(fixture, clock: clock)
        try fixture.writeEvents([copilotTestEvent("subagent.started", agent: "child", data: [
            "toolCallId": "task", "agentDisplayName": "Child"
        ])])
        let initial = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(initial.sessions.first?.children.first?.state == .working)
        try fixture.append(copilotTestEvent("subagent.future_lifecycle", agent: "child") + Data([10]))
        let degraded = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(degraded.issues.contains(.unsupportedFormat))
        #expect(!degraded.isComplete)
        #expect(degraded.sessions.first?.children.first?.state == .unknown)
        #expect(degraded.sessions.first?.children.first?.terminalEvent == nil)
        #expect(try project(degraded, fixture: fixture).sessions.first?.nodes.first?.state == .unknown)
        #expect(await reader.hasPendingHistory() == false)

        clock.advance(30)
        let refreshed = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(refreshed.sessions.first?.observedAt == clock.read())
        let tree = try project(refreshed, fixture: fixture)
        #expect(tree.availability == .partial)
        #expect(tree.sessions.first?.nodes.first?.state == .unknown)
        #expect(tree.knownRunningChildren == 0)
        #expect(!tree.hasCompleteCounts)

        try fixture.append(copilotTestEvent("assistant.turn_start", agent: "child", data: ["turnId": "new"]) + Data([10]))
        let current = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(!current.isComplete)
        #expect(current.sessions.first?.children.first?.state == .working)
        #expect(try project(current, fixture: fixture).knownRunningChildren == 1)
    }

    @Test func futureTerminalDismissalDoesNotHideANewObservedInvocation() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let clock = HistoryReaderClock()
        let reader = reader(fixture, clock: clock)
        let start = try copilotTestEvent("subagent.started", agent: "child", data: [
            "toolCallId": "old", "agentDisplayName": "Child"
        ])
        var future = try #require(JSONSerialization.jsonObject(with: copilotTestEvent("subagent.completed", data: [
            "toolCallId": "old", "agentDisplayName": "Child"
        ])) as? [String: Any])
        future["timestamp"] = "2099-01-01T00:00:00Z"
        try fixture.writeEvents([start, JSONSerialization.data(withJSONObject: future)])
        let ended = try await reader.read(surfaceIDs: [fixture.surface])
        let history = SidebarHistorySettings(dismissed: try project(ended, fixture: fixture).dismissibleOutcomes)
        #expect(history.dismissed.count == 1)
        #expect(try project(ended, fixture: fixture, history: history).sessions.first?.nodes.isEmpty == true)
        try fixture.append(copilotTestEvent("subagent.started", agent: "child", data: [
            "toolCallId": "new", "agentDisplayName": "Child"
        ]) + Data([10]))
        let working = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(working.sessions.first?.children.first?.terminalEvent == nil)
        #expect(try project(working, fixture: fixture, history: history).knownRunningChildren == 1)
        let rebuilt = try await self.reader(fixture, clock: clock).read(surfaceIDs: [fixture.surface])
        #expect(rebuilt.sessions == working.sessions)
        #expect(try project(rebuilt, fixture: fixture, history: history).knownRunningChildren == 1)
    }

    @Test func replayLimitPublishesConservativeCurrentStateAtVerifiedEOF() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let clock = HistoryReaderClock()
        let limits = CopilotReaderLimits(maximumLifecycleEvents: 2, maximumReplayFilterWords: 1)
        let reader = reader(fixture, clock: clock, limits: limits)
        try fixture.writeEvents([
            copilotTestEvent("subagent.started", agent: "child", data: [
                "toolCallId": "task", "agentDisplayName": "Child"
            ]),
            copilotTestEvent("assistant.turn_start", data: ["turnId": "root"])
        ])
        #expect(try await reader.read(surfaceIDs: [fixture.surface]).sessions.first?.children.first?.state == .working)
        for row in try copilotTestReplayPressure() { try fixture.append(row + Data([10])) }
        try fixture.append(copilotTestEvent("subagent.completed", data: [
            "toolCallId": "task", "agentDisplayName": "Child"
        ]) + Data([10]))
        let limited = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(limited.issues == [.readLimitReached])
        #expect(limited.sessions.first?.state == .unknown)
        #expect(limited.sessions.first?.children.first?.state == .unknown)
        #expect(!limited.isComplete)
        #expect(await reader.hasPendingHistory() == false)
        clock.advance(30)
        let refreshed = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(refreshed.sessions.first?.observedAt == clock.read())
        #expect(try project(refreshed, fixture: fixture).sessions.first?.nodes.first?.state == .unknown)
        let rebuilt = try await self.reader(fixture, clock: clock, limits: limits).read(surfaceIDs: [fixture.surface])
        #expect(rebuilt == refreshed)
    }

    @Test(arguments: [CopilotWorkState.completed, .failed, .cancelled], [false, true])
    func capTwoCannotKeepRestartedChildHiddenByItsPreviousOutcome(
        _ state: CopilotWorkState, saturated: Bool
    ) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let clock = HistoryReaderClock()
        let limits = CopilotReaderLimits(maximumLifecycleEvents: 2, maximumReplayFilterWords: saturated ? 1 : 16_384)
        let reader = reader(fixture, clock: clock, limits: limits)
        try fixture.writeEvents([
            copilotTestEvent("subagent.started", agent: "child", data: [
                "toolCallId": "old", "agentDisplayName": "Child"
            ]),
            copilotTestEvent(state == .failed ? "subagent.failed" : "subagent.completed", data: [
                "toolCallId": "old", "agentDisplayName": "Child", "cancelled": state == .cancelled
            ])
        ])
        let ended = try await reader.read(surfaceIDs: [fixture.surface])
        let unexpired = SidebarHistorySettings(retention: .never)
        let history = SidebarHistorySettings(
            retention: .never,
            dismissed: try project(ended, fixture: fixture, history: unexpired).dismissibleOutcomes
        )
        #expect(history.dismissed.count == 1)
        #expect(try project(ended, fixture: fixture, history: history).sessions.first?.nodes.isEmpty == true)
        if saturated {
            for row in try copilotTestReplayPressure() { try fixture.append(row + Data([10])) }
        }
        try fixture.append(copilotTestEvent("subagent.started", agent: "child", data: [
            "toolCallId": "new", "agentDisplayName": "Child"
        ]) + Data([10]))
        clock.advance(30)
        let restarted = try await reader.read(surfaceIDs: [fixture.surface])
        let expected: CopilotWorkState = saturated ? .unknown : .working
        #expect(restarted.issues == (saturated ? [.readLimitReached] : []))
        #expect(restarted.sessions.first?.children.first?.state == expected)
        #expect(restarted.sessions.first?.children.first?.terminalEvent == nil)
        let tree = try project(restarted, fixture: fixture, history: history)
        #expect(tree.sessions.first?.nodes.first?.state == expected)
        #expect(tree.hiddenHistoryCount == 0)
        #expect(tree.dismissibleOutcomes.isEmpty)
        #expect(!tree.hasCompleteCounts)
        clock.advance(30)
        let refreshed = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(try project(refreshed, fixture: fixture, history: history).sessions.first?.nodes.first?.state == expected)
        let rebuilt = try await self.reader(fixture, clock: clock, limits: limits).read(surfaceIDs: [fixture.surface])
        #expect(rebuilt == refreshed)
    }

    @Test(arguments: [false, true], [false, true])
    func unsafeSessionHeadersCannotPublishAtCapOrWithDuplicateUUID(_ atCap: Bool, duplicateID: Bool) async throws {
        for invalidVersion in [false, true] {
            let fixture = try CopilotReaderFixture()
            defer { fixture.remove() }
            let clock = HistoryReaderClock()
            let reader = reader(fixture, clock: clock, limits: .init(maximumLifecycleEvents: atCap ? 2 : 20))
            let start = try copilotTestEvent("subagent.started", agent: "child", data: [
                "toolCallId": "task", "agentDisplayName": "Child"
            ])
            try fixture.writeEvents([start, copilotTestEvent("subagent.completed", data: [
                "toolCallId": "task", "agentDisplayName": "Child"
            ])])
            let safe = try await reader.read(surfaceIDs: [fixture.surface])
            let original = try #require(JSONSerialization.jsonObject(with: start) as? [String: Any])
            var unsafe = try #require(JSONSerialization.jsonObject(with: copilotTestEvent("session.start", data: [
                "sessionId": invalidVersion ? fixture.sessionID.uuidString : UUID().uuidString,
                "version": invalidVersion ? 0 : 1
            ])) as? [String: Any])
            if duplicateID { unsafe["id"] = original["id"] }
            try fixture.append(JSONSerialization.data(withJSONObject: unsafe) + Data([10]))
            clock.advance(30)
            let rejected = try await reader.read(surfaceIDs: [fixture.surface])
            #expect(rejected.issues.contains(invalidVersion ? .unsupportedFormat : .identityChanged))
            #expect(!rejected.isComplete)
            #expect(rejected.sessions == safe.sessions)
            #expect(try project(rejected, fixture: fixture).sessions.isEmpty)
        }
    }

    @Test func retiredStartsWithNewEventUUIDsCannotReappearAfterReaderReconstruction() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let clock = HistoryReaderClock()
        let reader = reader(fixture, clock: clock)
        var rows: [Data] = []
        for identity in ["old", "new"] {
            rows += try [
                copilotTestEvent("subagent.started", agent: "child", data: [
                    "toolCallId": identity, "agentDisplayName": "Child"
                ]),
                copilotTestEvent("subagent.completed", data: ["toolCallId": identity, "agentDisplayName": "Child"]),
                copilotTestEvent("assistant.turn_start", data: ["turnId": identity]),
                copilotTestEvent("assistant.turn_end", data: ["turnId": identity])
            ]
        }
        try fixture.writeEvents(rows)
        let ended = try await reader.read(surfaceIDs: [fixture.surface])
        let history = SidebarHistorySettings(
            retention: .never,
            dismissed: try project(ended, fixture: fixture, history: .init(retention: .never)).dismissibleOutcomes
        )
        try fixture.append(copilotTestEvent("subagent.started", agent: "child", data: [
            "toolCallId": "old", "agentDisplayName": "Child"
        ]) + Data([10]))
        try fixture.append(copilotTestEvent("assistant.turn_start", data: ["turnId": "old"]) + Data([10]))
        let repeated = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(repeated.sessions == ended.sessions)
        #expect(try project(repeated, fixture: fixture, history: history).sessions.first?.nodes.isEmpty == true)
        let rebuilt = try await self.reader(fixture, clock: clock).read(surfaceIDs: [fixture.surface])
        #expect(rebuilt == repeated)
    }

    @Test(arguments: ["subagent.started", "assistant.turn_start"], [false, true])
    func unsaturatedColdCollisionCannotHideDismissedOrExpiredTerminalWork(
        type: String, expired: Bool
    ) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let clock = HistoryReaderClock()
        let limits = CopilotReaderLimits(maximumReplayFilterWords: 1, maximumRelationships: 2)
        let reader = reader(fixture, clock: clock, limits: limits)
        let start = try copilotTestEvent("subagent.started", agent: "worker", data: [
            "toolCallId": "spawn-a", "agentDisplayName": "A"
        ])
        let completion = try timedEvent("subagent.completed", at: clock.read(), data: [
            "toolCallId": "spawn-a", "agentDisplayName": "A"
        ])
        try fixture.writeEvents([start, completion] + copilotTestColdStartPressure())
        let initial = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(initial.issues.isEmpty)
        let initialTree = try project(initial, fixture: fixture)
        #expect(initialTree.retainedHistoryCount == 1)
        let history = expired ? SidebarHistorySettings() : SidebarHistorySettings(
            retention: .never, dismissed: initialTree.dismissibleOutcomes
        )
        if expired { clock.advance(15) }
        let hidden = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(try project(hidden, fixture: fixture, history: history).hiddenHistoryCount == 1)
        try fixture.append(copilotTestEvent(type, agent: "worker", data: [
            "toolCallId": "fresh-457", "turnId": "fresh-turn-135",
            "agentDisplayName": "Unattested B", "model": "unattested-model"
        ]) + Data([10]))
        let uncertain = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(uncertain.issues == [.readLimitReached])
        #expect(uncertain.sessions.first?.children.first?.state == .unknown)
        #expect(uncertain.sessions.first?.children.first?.terminalEvent == nil)
        let visible = try project(uncertain, fixture: fixture, history: history)
        #expect(visible.sessions.first?.nodes.first?.id == "worker")
        #expect(visible.sessions.first?.nodes.first?.state == .unknown)
        #expect(visible.knownRunningChildren == 0)
        #expect(visible.hiddenHistoryCount == 0)
        #expect(visible.dismissibleOutcomes.isEmpty)
        #expect(!visible.hasCompleteCounts)
        try fixture.append(copilotTestEvent("subagent.completed", data: [
            "toolCallId": "spawn-a", "agentDisplayName": "A"
        ]) + Data([10]))
        let late = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(late.sessions == uncertain.sessions)
        let rebuilt = try await self.reader(fixture, clock: clock, limits: limits).read(surfaceIDs: [fixture.surface])
        #expect(rebuilt.sessions == uncertain.sessions)
        try fixture.writeEvents([
            start, completion
        ] + copilotTestColdStartPressure() + [
            copilotTestEvent(type, agent: "worker", data: [
                "toolCallId": "fresh-457", "turnId": "fresh-turn-135", "agentDisplayName": "Unattested B"
            ])
        ], atomic: true)
        let replaced = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(replaced.sessions.first?.children.first?.state == .unknown)
        #expect(replaced.sessions.first?.children.first?.terminalEvent == nil)
        #expect(try project(replaced, fixture: fixture, history: history).hiddenHistoryCount == 0)
    }

    @Test(arguments: [CopilotWorkState.completed, .failed, .cancelled], [false, true])
    func retiredHistoryAndDismissalCannotHideFreshBlockedInvocation(
        _ outcome: CopilotWorkState, retire: Bool
    ) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let clock = HistoryReaderClock()
        let limits = CopilotReaderLimits(maximumLifecycleEvents: 8)
        let reader = reader(fixture, clock: clock, limits: limits)
        let startA = try copilotTestEvent("subagent.started", agent: "worker", data: [
            "toolCallId": "spawn-a", "agentDisplayName": "A"
        ])
        let turnA = try copilotTestEvent("assistant.turn_start", agent: "worker", data: ["turnId": "turn-a"])
        let requestA = try copilotTestEvent("permission.requested", agent: "worker", data: ["requestId": "request-a"])
        let finishA = try timedEvent(
            outcome == .failed ? "subagent.failed" : "subagent.completed", at: clock.read(), data: [
                "toolCallId": "spawn-a", "agentDisplayName": "A", "cancelled": outcome == .cancelled
            ]
        )
        try fixture.writeEvents([startA, turnA, requestA, finishA])
        let initial = try await reader.read(surfaceIDs: [fixture.surface])
        let initialTree = try project(initial, fixture: fixture)
        #expect(initialTree.retainedHistoryCount == 1)
        let oldEvent = try #require(initial.sessions.first?.children.first?.terminalEvent)
        let dismissed = SidebarHistorySettings(retention: .never, dismissed: initialTree.dismissibleOutcomes)
        #expect(try project(initial, fixture: fixture, history: dismissed).hiddenHistoryCount == 1)
        clock.advance(15)
        let expired = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(try project(expired, fixture: fixture).hiddenHistoryCount == 1)

        if retire {
            for index in 0..<256 {
                try fixture.append(copilotTestEvent("tool.execution_start", data: [
                    "toolCallId": "retire-\(index)", "toolName": "bash"
                ]) + Data([10]))
                try fixture.append(copilotTestEvent("tool.execution_complete", data: [
                    "toolCallId": "retire-\(index)", "success": true
                ]) + Data([10]))
            }
            let retired = try await reader.read(surfaceIDs: [fixture.surface])
            #expect(!retired.sessions.flatMap(\.children).contains { $0.id == "worker" })
        }
        // A fresh turn alone is sufficient after retirement. Structured spawn
        // enrichment must then retain that turn and its pending permission.
        try fixture.append(copilotTestEvent("assistant.turn_start", agent: "worker", data: [
            "turnId": "turn-b", "model": "current"
        ]) + Data([10]))
        try fixture.append(copilotTestEvent("permission.requested", agent: "worker", data: [
            "requestId": "request-b"
        ]) + Data([10]))
        try fixture.append(copilotTestEvent("subagent.started", agent: "worker", data: [
            "toolCallId": "spawn-b", "agentDisplayName": "B"
        ]) + Data([10]))
        let current = try await reader.read(surfaceIDs: [fixture.surface])
        let worker = try #require(current.sessions.flatMap(\.children).first { $0.id == "worker" })
        #expect(worker.state == .blocked)
        #expect(worker.name == "B")
        #expect(worker.terminalEvent == nil)
        #expect(try project(current, fixture: fixture, history: dismissed).sessions.first?.nodes.contains {
            $0.id == "worker" && $0.state == .blocked
        } == true)

        for row in [startA, turnA, requestA, finishA] { try fixture.append(row + Data([10])) }
        for row in try [
            copilotTestEvent("subagent.started", agent: "worker", data: [
                "toolCallId": "spawn-a", "agentDisplayName": "A"
            ]),
            copilotTestEvent("assistant.turn_start", agent: "worker", data: ["turnId": "turn-a"]),
            copilotTestEvent("assistant.turn_end", agent: "worker", data: ["turnId": "turn-a"]),
            copilotTestEvent("subagent.failed", data: ["toolCallId": "spawn-a", "agentDisplayName": "A"]),
            copilotTestEvent("permission.requested", agent: "worker", data: ["requestId": "request-a"])
        ] { try fixture.append(row + Data([10])) }
        let replayed = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(replayed.sessions == current.sessions)
        let rebuilt = try await self.reader(fixture, clock: clock, limits: limits).read(surfaceIDs: [fixture.surface])
        #expect(rebuilt.sessions == replayed.sessions)
        #expect(try project(rebuilt, fixture: fixture, history: dismissed).sessions.first?.nodes.contains {
            $0.id == "worker" && $0.state == .blocked
        } == true)
        try fixture.append(copilotTestEvent("permission.completed", agent: "worker", data: [
            "requestId": "request-b"
        ]) + Data([10]))
        let finishB = try timedEvent(
            outcome == .failed ? "subagent.failed" : "subagent.completed", at: clock.read(), data: [
                "toolCallId": "spawn-b", "agentDisplayName": "B", "cancelled": outcome == .cancelled
            ]
        )
        try fixture.append(finishB + Data([10]))
        let finished = try await reader.read(surfaceIDs: [fixture.surface])
        let completed = try #require(finished.sessions.flatMap(\.children).first { $0.id == "worker" })
        #expect(completed.state == outcome)
        #expect(completed.terminalEvent?.id != oldEvent.id)
        #expect(completed.terminalEvent?.timestamp == clock.read())
        let visible = try project(finished, fixture: fixture, history: dismissed)
        #expect(visible.sessions.first?.nodes.contains { $0.id == "worker" && $0.state == outcome } == true)
        #expect(try project(finished, fixture: fixture).nextHistoryExpiry == clock.read().addingTimeInterval(15))
        clock.advance(15)
        let refreshed = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(try project(refreshed, fixture: fixture).sessions.first?.nodes.contains { $0.id == "worker" } == false)
        let finalRebuilt = try await self.reader(fixture, clock: clock, limits: limits).read(surfaceIDs: [fixture.surface])
        #expect(finalRebuilt.sessions == refreshed.sessions)
        #expect(try project(finalRebuilt, fixture: fixture, history: dismissed).sessions.first?.nodes.contains {
            $0.id == "worker" && $0.state == outcome
        } == true)
    }

    @Test(arguments: ["abort", "session.error"])
    func rejectedTerminalEventCannotUnblockVerifiedCurrentRequests(_ type: String) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let clock = HistoryReaderClock()
        let reader = reader(fixture, clock: clock)
        try fixture.writeEvents([
            copilotTestEvent("subagent.started", agent: "child", data: [
                "toolCallId": "task", "agentDisplayName": "Child"
            ]),
            copilotTestEvent("permission.requested", agent: "child", data: ["requestId": "pending"]),
            copilotTestEvent("user_input.requested", agent: "child", data: ["requestId": "pending"])
        ])
        let blocked = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(blocked.sessions.first?.children.first?.state == .blocked)
        var stale = try #require(JSONSerialization.jsonObject(with: copilotTestEvent(type, agent: "child")) as? [String: Any])
        stale["timestamp"] = "2026-09-12T11:59:00Z"
        try fixture.append(JSONSerialization.data(withJSONObject: stale) + Data([10]))
        let current = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(current.isComplete)
        #expect(try project(current, fixture: fixture).sessions.first?.nodes.first?.state == .blocked)
        #expect(try project(current, fixture: fixture).dismissibleOutcomes.isEmpty)
    }

    @Test(arguments: ["malformed", "mismatched-session", "unsupported-version"])
    func semanticDegradationDoesNotPermitUnsafeHistoryPublication(_ defect: String) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let clock = HistoryReaderClock()
        let reader = reader(fixture, clock: clock)
        try fixture.writeEvents([
            copilotTestEvent("subagent.started", agent: "child", data: [
                "toolCallId": "task", "agentDisplayName": "Child"
            ]),
            copilotTestEvent("subagent.future_lifecycle", agent: "child")
        ])
        let safe = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(safe.sessions.first?.children.first?.state == .unknown)
        let unsafe = defect == "malformed" ? Data("{broken}".utf8) : try copilotTestEvent("session.start", data: [
            "sessionId": defect == "mismatched-session" ? UUID().uuidString : fixture.sessionID.uuidString,
            "version": defect == "unsupported-version" ? 0 : 1
        ])
        try fixture.append(unsafe + Data([10]))
        try fixture.append(copilotTestEvent("assistant.turn_start", agent: "child", data: ["turnId": "new"]) + Data([10]))
        clock.advance(30)
        let rejected = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(!rejected.isComplete)
        #expect(rejected.sessions == safe.sessions)
        #expect(try project(rejected, fixture: fixture).sessions.isEmpty)
    }

    @Test func tornSemanticHistoryWaitsForCompleteReadAndIgnoredPayloadCannotChangeState() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let clock = HistoryReaderClock()
        let reader = reader(fixture, clock: clock)
        try fixture.writeEvents([copilotTestEvent("subagent.started", agent: "child", data: [
            "toolCallId": "task", "agentDisplayName": "Child"
        ])])
        let initial = try await reader.read(surfaceIDs: [fixture.surface])
        let future = try copilotTestEvent("subagent.future_lifecycle", agent: "child")
        try fixture.append(future)
        let torn = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(torn.issues.contains(.loadingHistory))
        #expect(torn.sessions == initial.sessions)
        try fixture.append(Data([10]))
        let repaired = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(repaired.sessions.first?.children.first?.state == .unknown)
        try fixture.append(copilotTestEvent("assistant.turn_start", agent: "child", data: ["turnId": "fresh"]) + Data([10]))
        try fixture.append(copilotTestEvent("tool.execution_partial_result", data: [
            "toolCallId": "task", "partialOutput": "PRIVATE_SENTINEL"
        ]) + Data([10]))
        let current = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(current.sessions.first?.children.first?.state == .working)
        #expect(!String(decoding: try JSONEncoder().encode(current), as: UTF8.self).contains("PRIVATE_SENTINEL"))
    }

    private func reader(
        _ fixture: CopilotReaderFixture, clock: HistoryReaderClock,
        limits: CopilotReaderLimits = CopilotReaderLimits()
    ) -> CopilotSessionReader {
        CopilotSessionReader(
            bindingDirectory: fixture.bindings, sessionStateRoot: fixture.sessions,
            clock: { clock.read() },
            processLookup: { $0 == fixture.process.pid ? .found(fixture.process) : .dead },
            limits: limits
        )
    }

    private func timedEvent(_ type: String, at date: Date, data: [String: Any]) throws -> Data {
        var event = try #require(JSONSerialization.jsonObject(with: copilotTestEvent(type, data: data)) as? [String: Any])
        event["timestamp"] = date.ISO8601Format()
        return try JSONSerialization.data(withJSONObject: event)
    }

    private func project(
        _ snapshot: CopilotSnapshot, fixture: CopilotReaderFixture,
        history: SidebarHistorySettings = SidebarHistorySettings()
    ) throws -> SidebarCopilotTree {
        let topology = SidebarTopology(HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: true, surfaceMetadataAvailable: true, workspacePathsAvailable: false,
            workspaces: [HierarchyWorkspace(
                id: fixture.workspace, title: .available("Workspace"), detail: .available(nil),
                isSelected: .available(false), isPinned: .available(false), unreadCount: .available(0),
                rootPath: .unavailable, projectRootPath: .unavailable,
                surfaces: .available([HierarchySurface(
                    id: fixture.surface, title: "Surface", kind: .terminal,
                    isFocused: false, isPinned: false, unreadCount: 0, workingDirectory: .unavailable
                )])
            )], windowID: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
        ))
        return SidebarCopilotTree.project(snapshot, onto: topology, now: snapshot.generatedAt, history: history)
    }
}

private final class HistoryReaderClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_789_216_200)
    func read() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}
