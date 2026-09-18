import Foundation
import Testing

@MainActor
struct SidebarHistoryReaderTests {
    @Test(arguments: ["view", "bash"], [false, true])
    func selectiveShellAliasExposesHiddenOwnerAndAcceptsItsIndependentRequest(
        toolName: String, expired: Bool
    ) async throws {
        copilotSelectiveShellAliasWitness()
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let clock = HistoryReaderClock()
        let limits = CopilotReaderLimits(maximumReplayFilterWords: 1, maximumRelationships: 2)
        let reader = reader(fixture, clock: clock, limits: limits)
        var rows = try [
            attentionEvent("subagent.started", agent: "worker", data: [
                "toolCallId": "spawn-a", "agentDisplayName": "A", "model": "known-model"
            ]),
            timedEvent("subagent.completed", at: clock.read(), data: [
                "toolCallId": "spawn-a", "agentDisplayName": "A"
            ])
        ] + copilotTestColdStartPressure()
        try fixture.writeEvents(rows)
        let initial = try await reader.read(surfaceIDs: [fixture.surface])
        let initialTree = try project(initial, fixture: fixture)
        #expect(initialTree.retainedHistoryCount == 1)
        let history = expired ? SidebarHistorySettings() : SidebarHistorySettings(
            retention: .never, dismissed: initialTree.dismissibleOutcomes
        )
        if expired { clock.advance(15) }
        let hidden = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(try project(hidden, fixture: fixture, history: history).hiddenHistoryCount == 1)
        let start = try attentionEvent("tool.execution_start", agent: "worker", data: [
            "toolCallId": "fresh-owner-31", "toolName": toolName, "model": "unproven-model"
        ], timestamp: clock.read().addingTimeInterval(3600).ISO8601Format())
        rows.append(start)
        try fixture.append(start + Data([10]))
        let uncertain = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(uncertain.issues == [.readLimitReached])
        let child = try #require(uncertain.sessions.first?.children.first)
        #expect(child.state == .unknown && child.terminalEvent == nil)
        #expect(child.model == "known-model" && child.activity == nil)
        let exposed = try project(uncertain, fixture: fixture, history: history)
        #expect(exposed.sessions.first?.nodes.first?.id == "worker")
        #expect(exposed.hiddenHistoryCount == 0 && exposed.knownRunningChildren == 0)
        #expect(exposed.nextHistoryExpiry == nil)

        let request = try attentionEvent("permission.requested", agent: "worker", data: [
            "requestId": "current"
        ], timestamp: clock.read().ISO8601Format())
        rows.append(request)
        try fixture.append(request + Data([10]))
        let blocked = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(blocked.sessions.first?.children.first?.state == .blocked)
        #expect(blocked.sessions.first?.children.first?.attention?.map(\.kind) == [.permission])
        let waiting = try project(blocked, fixture: fixture, history: history)
        #expect(waiting.attentionOwnerCount == 1)
        #expect(waiting.hiddenHistoryCount == 0 && waiting.acknowledgeableOutcomes.isEmpty)
        for row in try [
            attentionEvent("subagent.completed", data: ["toolCallId": "spawn-a", "agentDisplayName": "A"]),
            start
        ] {
            rows.append(row)
            try fixture.append(row + Data([10]))
        }
        let repeated = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(repeated.sessions == blocked.sessions)
        let rebuilt = try await self.reader(fixture, clock: clock, limits: limits).read(surfaceIDs: [fixture.surface])
        #expect(rebuilt.sessions == blocked.sessions)
        try fixture.writeEvents(rows, atomic: true)
        let rotated = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(rotated.sessions == blocked.sessions)
        #expect(try project(rotated, fixture: fixture, history: history).attentionOwnerCount == 1)
    }

    @Test func longHistoryKeepsCurrentAttentionAndRejectsStaleAcknowledgementsAcrossRebuild() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let preferencesFixture = try SidebarPreferenceFixture()
        defer { preferencesFixture.cleanup() }
        let preferences = preferencesFixture.preferences()
        let clock = HistoryReaderClock()
        let limits = CopilotReaderLimits(
            linesPerSession: 64, maximumLifecycleEvents: 8, maximumRelationships: 8
        )
        let reader = reader(fixture, clock: clock, limits: limits)
        var rows = [try attentionEvent("assistant.turn_start", data: ["turnId": "main"])]
        for index in 0..<300 {
            let id = "old-\(index)"
            rows += try [
                attentionEvent("tool.execution_start", data: ["toolCallId": id, "toolName": "task"]),
                attentionEvent("subagent.started", agent: id, data: ["toolCallId": id, "agentDisplayName": "Old"]),
                attentionEvent("subagent.completed", data: ["toolCallId": id, "agentDisplayName": "Old"]),
                attentionEvent("tool.execution_complete", data: ["toolCallId": id, "success": true])
            ]
        }
        let spawnA = try attentionEvent("subagent.started", agent: "worker", data: [
            "toolCallId": "spawn-a", "agentDisplayName": "A"
        ])
        rows += try [
            attentionEvent("tool.execution_start", data: ["toolCallId": "spawn-a", "toolName": "task"]),
            spawnA,
            attentionEvent("tool.execution_complete", data: ["toolCallId": "spawn-a", "success": true]),
            attentionEvent("assistant.turn_end", data: ["turnId": "main"]),
            attentionEvent("tool.execution_start", agent: "worker", data: ["toolCallId": "view-a", "toolName": "view"]),
            attentionEvent("permission.requested", agent: "worker", data: ["requestId": "request-a"])
        ]
        try fixture.writeEvents(rows)
        let initial = try await caughtUp(reader, surface: fixture.surface)
        #expect(initial.isComplete)
        #expect((initial.sessions.first?.children.count ?? 0) <= 256)
        let initialTree = try project(initial, fixture: fixture)
        let worker = try #require(initialTree.sessions.first?.nodes.first { $0.id == "worker" })
        #expect(worker.state == .blocked)
        #expect(worker.attention.map(\.kind) == [.permission])
        #expect(worker.activity?.summary == "Executing tool: view")
        #expect(initialTree.attentionOwnerCount == 2)
        let oldRootKeys = initialTree.acknowledgeableOutcomes
        #expect(oldRootKeys.count == 1 && oldRootKeys.allSatisfy { $0.ownerID == nil })
        preferences.acknowledge(oldRootKeys, in: initialTree)
        #expect(preferencesFixture.preferences().attention.acknowledged == oldRootKeys)

        try fixture.append(attentionEvent("assistant.turn_start", data: ["turnId": "next"]) + Data([10]))
        let next = try await caughtUp(reader, surface: fixture.surface)
        let nextTree = try project(next, fixture: fixture)
        #expect(nextTree.attentionOwnerCount == 1)
        preferences.resetAcknowledgements()
        preferences.acknowledge(oldRootKeys, in: nextTree)
        #expect(preferences.attention.acknowledged.isEmpty)
        #expect(nextTree.sessions.first?.nodes.first { $0.id == "worker" }?.state == .blocked)

        try fixture.append(attentionEvent("permission.completed", data: ["requestId": "request-a"]) + Data([10]))
        let wrongOwner = try await caughtUp(reader, surface: fixture.surface)
        #expect(wrongOwner.sessions.first?.children.first { $0.id == "worker" }?.state == .blocked)
        try fixture.append(attentionEvent("permission.completed", agent: "worker", data: ["requestId": "request-a"]) + Data([10]))
        let error = try attentionEvent("abort", agent: "worker")
        try fixture.append(error + Data([10]))
        let ended = try await caughtUp(reader, surface: fixture.surface)
        let endedWorker = try #require(ended.sessions.first?.children.first { $0.id == "worker" })
        let event = try #require(endedWorker.terminalEvent)
        let history = SidebarHistorySettings(dismissed: [
            .init(sessionID: fixture.sessionID, childID: "worker", eventID: event.id)
        ])
        let outstanding = try project(ended, fixture: fixture, history: history)
        #expect(outstanding.sessions.first?.nodes.first { $0.id == "worker" }?.attention.map(\.kind) == [.aborted])
        #expect(outstanding.hiddenHistoryCount == (ended.sessions.first?.children.count ?? 1) - 1)
        preferences.acknowledge(oldRootKeys, in: outstanding)
        #expect(preferences.attention.acknowledged.isEmpty)
        preferences.acknowledge(outstanding.acknowledgeableOutcomes, in: outstanding)
        #expect(preferences.attention.acknowledged.count == 1)
        #expect(try project(ended, fixture: fixture, history: history, attention: preferences.attention)
            .sessions.first?.nodes.contains { $0.id == "worker" } == false)
        let reconstructed = try await caughtUp(self.reader(fixture, clock: clock, limits: limits), surface: fixture.surface)
        #expect(reconstructed.sessions == ended.sessions)
        let reloaded = preferencesFixture.preferences()
        #expect(try project(reconstructed, fixture: fixture, history: history, attention: reloaded.attention)
            .sessions.first?.nodes.contains { $0.id == "worker" } == false)

        for row in try [
            attentionEvent("tool.execution_start", data: ["toolCallId": "spawn-b", "toolName": "task"]),
            attentionEvent("subagent.started", agent: "worker", data: ["toolCallId": "spawn-b", "agentDisplayName": "B"]),
            attentionEvent("tool.execution_complete", data: ["toolCallId": "spawn-b", "success": true]),
            attentionEvent("permission.requested", agent: "worker", data: ["requestId": "request-b"])
        ] { try fixture.append(row + Data([10])) }
        for index in 0..<16 {
            try fixture.append(attentionEvent("assistant.turn_start", data: ["turnId": "spill-\(index)"]) + Data([10]))
        }
        let current = try await caughtUp(reader, surface: fixture.surface)
        let currentWorker = try #require(current.sessions.first?.children.first { $0.id == "worker" })
        #expect(currentWorker.name == "B" && currentWorker.state == .blocked)
        for row in try [
            spawnA,
            attentionEvent("subagent.started", agent: "worker", data: ["toolCallId": "spawn-a", "agentDisplayName": "A"]),
            attentionEvent("subagent.completed", data: ["toolCallId": "spawn-a", "agentDisplayName": "A"]),
            attentionEvent("permission.completed", agent: "worker", data: ["requestId": "request-a"])
        ] { try fixture.append(row + Data([10])) }
        let replayed = try await caughtUp(reader, surface: fixture.surface)
        #expect(replayed.sessions.first?.children.first { $0.id == "worker" } == currentWorker)
        #expect(replayed.issues == [.readLimitReached])
        let liveTree = try project(replayed, fixture: fixture, history: history, attention: reloaded.attention)
        #expect(liveTree.sessions.first?.nodes.first { $0.id == "worker" }?.state == .blocked)
        #expect(liveTree.attentionOwnerCount == 1)
        #expect(liveTree.acknowledgeableOutcomes.isEmpty)
        let liveRebuilt = try await caughtUp(self.reader(fixture, clock: clock, limits: limits), surface: fixture.surface)
        #expect(liveRebuilt.sessions == replayed.sessions)
    }

    @Test func clockChangesAndFreshReadersCannotResurrectMatchedWorkOrLoseIndependentQuestions() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let clock = HistoryReaderClock(Date(timeIntervalSince1970: 1_789_214_410))
        let reader = reader(fixture, clock: clock)
        try fixture.writeEvents([
            attentionEvent("tool.execution_start", data: ["toolCallId": "spawn", "toolName": "task"]),
            attentionEvent("subagent.started", agent: "child", data: ["toolCallId": "spawn", "agentDisplayName": "Child"]),
            attentionEvent("assistant.turn_start", data: ["turnId": "main"], timestamp: "2026-09-12T12:00:20Z"),
            attentionEvent("tool.execution_start", data: ["toolCallId": "view", "toolName": "view"],
                           timestamp: "2026-09-12T12:00:20Z"),
            attentionEvent("tool.execution_complete", data: ["toolCallId": "view", "success": true],
                           timestamp: "2026-09-12T12:00:10Z"),
            attentionEvent("permission.requested", agent: "child", data: ["requestId": "shared"],
                           timestamp: "2026-09-12T12:00:20Z"),
            attentionEvent("user_input.requested", agent: "child", data: ["requestId": "shared"],
                           timestamp: "2026-09-12T12:00:10Z"),
            attentionEvent("permission.completed", agent: "child", data: ["requestId": "shared"],
                           timestamp: "2026-09-12T12:00:21Z"),
            attentionEvent("assistant.turn_end", data: ["turnId": "main"], timestamp: "2026-09-12T12:00:10Z")
        ])
        let initial = try await reader.read(surfaceIDs: [fixture.surface])
        let initialTree = try project(initial, fixture: fixture)
        #expect(initial.isComplete)
        #expect(initialTree.sessions.first?.state == .idle)
        #expect(initialTree.sessions.first?.activity?.summary == "Last completed tool: view")
        #expect(initialTree.sessions.first?.activity?.lastEventAt == nil)
        #expect(initialTree.sessions.first?.attention.first?.kind == .turnFinished)
        #expect(initialTree.sessions.first?.attention.first?.occurredAt == nil)
        #expect(initialTree.sessions.first?.nodes.first?.state == .blocked)
        #expect(initialTree.sessions.first?.nodes.first?.attention.map(\.kind) == [.answer])
        let acknowledgement = SidebarAttentionSettings(acknowledged: initialTree.acknowledgeableOutcomes)
        #expect(acknowledgement.acknowledged.count == 1)
        for advance in [20.0, 30, 10] {
            clock.advance(advance)
            let cached = try await reader.read(surfaceIDs: [fixture.surface])
            let rebuilt = try await self.reader(fixture, clock: clock).read(surfaceIDs: [fixture.surface])
            #expect(rebuilt == cached)
            #expect(rebuilt.sessions.first?.attention == initial.sessions.first?.attention)
            #expect(rebuilt.sessions.first?.activity == initial.sessions.first?.activity)
            #expect(rebuilt.sessions.first?.children == initial.sessions.first?.children)
            let tree = try project(rebuilt, fixture: fixture, attention: acknowledgement)
            #expect(tree.sessions.first?.state == .idle)
            #expect(tree.sessions.first?.attention.isEmpty == true)
            #expect(tree.sessions.first?.activity?.summary == "Last completed tool: view")
            #expect(tree.sessions.first?.activity?.lastEventAt == nil)
            #expect(tree.sessions.first?.nodes.first?.state == .blocked)
            #expect(tree.attentionOwnerCount == 1)
        }
    }

    @Test func verifiedReaderProjectsOwnedAttentionAndSafeActivityAcrossTornReadsAndReload() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let clock = HistoryReaderClock()
        let reader = reader(fixture, clock: clock)
        try fixture.writeEvents([
            attentionEvent("assistant.turn_start", data: ["turnId": "main"]),
            attentionEvent("tool.execution_start", data: ["toolCallId": "task", "toolName": "task"]),
            attentionEvent("subagent.started", agent: "child", data: ["toolCallId": "task", "agentDisplayName": "Child"]),
            attentionEvent("tool.execution_start", agent: "child", data: ["toolCallId": "rg", "toolName": "rg", "arguments": "PRIVATE_ARGS"]),
            attentionEvent("permission.requested", agent: "child", data: ["requestId": "request", "question": "PRIVATE_PROMPT"]),
            attentionEvent("assistant.turn_end", data: ["turnId": "main"])
        ])
        let initial = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(initial.sessions.first?.attention?.first?.kind == .turnFinished)
        #expect(initial.sessions.first?.children.first?.attention?.first?.kind == .permission)
        #expect(initial.sessions.first?.children.first?.activity?.summary == "Executing tool: rg")
        #expect(initial.sessions.first?.state == .idle)
        #expect(initial.sessions.first?.children.first?.state == .blocked)
        let tree = try project(initial, fixture: fixture)
        #expect(tree.attentionOwnerCount == 2)
        let attention = SidebarAttentionSettings(acknowledged: tree.acknowledgeableOutcomes)
        #expect(attention.acknowledged.count == 1)
        let completion = try attentionEvent("permission.completed", agent: "child", data: ["requestId": "request"])
        try fixture.append(completion)
        let torn = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(torn.issues.contains(.loadingHistory))
        #expect(torn.sessions == initial.sessions)
        #expect(try project(torn, fixture: fixture, attention: attention).attentionOwnerCount == 1)
        try fixture.append(Data([10]))
        try fixture.append(attentionEvent("tool.execution_complete", agent: "child", data: [
            "toolCallId": "rg", "success": true, "result": "PRIVATE_RESULT"
        ]) + Data([10]))
        let complete = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(complete.sessions.first?.children.first?.activity?.summary == "Last completed tool: rg")
        #expect(try project(complete, fixture: fixture, attention: attention).attentionOwnerCount == 0)
        let rebuilt = try await self.reader(fixture, clock: clock).read(surfaceIDs: [fixture.surface])
        #expect(rebuilt == complete)
        #expect(try project(rebuilt, fixture: fixture, attention: attention).attentionOwnerCount == 0)
        #expect(!String(decoding: try JSONEncoder().encode(rebuilt), as: UTF8.self).contains("PRIVATE_"))

        try fixture.append(Data("{malformed}\n".utf8))
        try fixture.append(attentionEvent("abort") + Data([10]))
        clock.advance(30)
        let unsafe = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(unsafe.issues.contains(.malformedData))
        #expect(unsafe.sessions == complete.sessions)
        #expect(try project(unsafe, fixture: fixture, attention: attention).acknowledgeableOutcomes.isEmpty)
        #expect(try project(unsafe, fixture: fixture, attention: attention).sessions.isEmpty)

        try fixture.writeEvents([
            attentionEvent("assistant.turn_start", data: ["turnId": "new"]),
            attentionEvent("assistant.turn_end", data: ["turnId": "new"])
        ], atomic: true)
        let reset = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(reset.isComplete)
        #expect(try project(reset, fixture: fixture, attention: attention).attentionOwnerCount == 1)
    }

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
        let attention = SidebarAttentionSettings(
            acknowledged: try project(ended, fixture: fixture, history: unexpired).acknowledgeableOutcomes
        )
        #expect(attention.acknowledged.count == (state == .completed ? 0 : 1))
        let history = SidebarHistorySettings(
            retention: .never,
            dismissed: try project(ended, fixture: fixture, history: unexpired, attention: attention).dismissibleOutcomes
        )
        #expect(history.dismissed.count == 1)
        #expect(try project(ended, fixture: fixture, history: history, attention: attention).sessions.first?.nodes.isEmpty == true)
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
        let tree = try project(restarted, fixture: fixture, history: history, attention: attention)
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
        let acknowledgedA = SidebarAttentionSettings(acknowledged: initialTree.acknowledgeableOutcomes)
        let historyEligible = try project(initial, fixture: fixture, attention: acknowledgedA)
        let dismissed = SidebarHistorySettings(retention: .never, dismissed: historyEligible.dismissibleOutcomes)
        #expect(try project(initial, fixture: fixture, history: dismissed, attention: acknowledgedA).hiddenHistoryCount == 1)
        clock.advance(15)
        let expired = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(try project(expired, fixture: fixture, attention: acknowledgedA).hiddenHistoryCount == (outcome == .failed ? 0 : 1))

        if retire {
            // Presentation acknowledgement is not an ingestion signal. A new
            // primary turn makes the prior nonblocking outcome cycle obsolete.
            try fixture.append(copilotTestEvent("assistant.turn_start", data: [
                "turnId": "retention-cycle"
            ]) + Data([10]))
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
        let acknowledgedB = SidebarAttentionSettings(
            acknowledged: acknowledgedA.acknowledged.union(visible.acknowledgeableOutcomes)
        )
        #expect(try project(finished, fixture: fixture, attention: acknowledgedB).nextHistoryExpiry
            == (outcome == .failed ? nil : clock.read().addingTimeInterval(15)))
        clock.advance(15)
        let refreshed = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(try project(refreshed, fixture: fixture, attention: acknowledgedB).sessions.first?.nodes.contains {
            $0.id == "worker"
        } == (outcome == .failed))
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

    private func caughtUp(_ reader: CopilotSessionReader, surface: UUID) async throws -> CopilotSnapshot {
        var snapshot = try await reader.read(surfaceIDs: [surface])
        for _ in 0..<32 {
            guard await reader.hasPendingHistory() else { break }
            snapshot = try await reader.read(surfaceIDs: [surface])
        }
        #expect(await reader.hasPendingHistory() == false)
        return snapshot
    }

    private func timedEvent(_ type: String, at date: Date, data: [String: Any]) throws -> Data {
        var event = try #require(JSONSerialization.jsonObject(with: copilotTestEvent(type, data: data)) as? [String: Any])
        event["timestamp"] = date.ISO8601Format()
        return try JSONSerialization.data(withJSONObject: event)
    }

    private func project(
        _ snapshot: CopilotSnapshot, fixture: CopilotReaderFixture,
        history: SidebarHistorySettings = SidebarHistorySettings(),
        attention: SidebarAttentionSettings = SidebarAttentionSettings()
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
        return SidebarCopilotTree.project(snapshot, onto: topology, now: snapshot.generatedAt, history: history, attention: attention)
    }
}

private final class HistoryReaderClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_789_216_200)) { self.date = date }
    func read() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}
