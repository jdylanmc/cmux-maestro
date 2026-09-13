import Foundation
import Testing

@MainActor
struct SidebarHistoryReaderTests {
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
        let limits = CopilotReaderLimits(maximumLifecycleEvents: 2)
        let reader = reader(fixture, clock: clock, limits: limits)
        try fixture.writeEvents([
            copilotTestEvent("subagent.started", agent: "child", data: [
                "toolCallId": "task", "agentDisplayName": "Child"
            ]),
            copilotTestEvent("assistant.turn_start", data: ["turnId": "root"])
        ])
        #expect(try await reader.read(surfaceIDs: [fixture.surface]).sessions.first?.children.first?.state == .working)
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

    @Test(arguments: [CopilotWorkState.completed, .failed, .cancelled])
    func capTwoCannotKeepRestartedChildHiddenByItsPreviousOutcome(_ state: CopilotWorkState) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let clock = HistoryReaderClock()
        let limits = CopilotReaderLimits(maximumLifecycleEvents: 2)
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
        try fixture.append(copilotTestEvent("subagent.started", agent: "child", data: [
            "toolCallId": "new", "agentDisplayName": "Child"
        ]) + Data([10]))
        clock.advance(30)
        let restarted = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(restarted.issues == [.readLimitReached])
        #expect(restarted.sessions.first?.children.first?.state == .unknown)
        #expect(restarted.sessions.first?.children.first?.terminalEvent == nil)
        let tree = try project(restarted, fixture: fixture, history: history, attention: attention)
        #expect(tree.sessions.first?.nodes.first?.state == .unknown)
        #expect(tree.hiddenHistoryCount == 0)
        #expect(tree.dismissibleOutcomes.isEmpty)
        #expect(!tree.hasCompleteCounts)
        clock.advance(30)
        let refreshed = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(try project(refreshed, fixture: fixture, history: history).sessions.first?.nodes.first?.state == .unknown)
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
