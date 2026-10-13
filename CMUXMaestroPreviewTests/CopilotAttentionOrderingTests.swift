import Foundation
import Testing

nonisolated struct CopilotAttentionOrderingTests {
    private let owners: [String?] = [nil, "child", "sibling"]
    private let origin = Date(timeIntervalSince1970: 1_789_214_400)
    // Ordering comes from event timestamps and arrival; the reducer takes no read time.

    @Test(arguments: [nil, "child", "sibling"] as [String?])
    func independentOlderQuestionSurvivesNewerPermissionAndItsCompletion(_ owner: String?) throws {
        let session = UUID()
        var rows: [Data] = []
        for candidate in owners {
            rows += try [
                attentionEvent("assistant.turn_start", agent: candidate, data: ["turnId": "turn"]),
                attentionEvent("permission.requested", agent: candidate, data: ["requestId": "shared"],
                               timestamp: "2026-09-12T12:00:20Z"),
                attentionEvent("user_input.requested", agent: candidate, data: ["requestId": "shared"],
                               timestamp: "2026-09-12T12:00:10Z")
            ]
        }
        rows.append(try attentionEvent("permission.completed", agent: owner, data: ["requestId": "shared"],
                                       timestamp: "2026-09-12T12:00:25Z"))
        var reducer = replay(rows, session: session)
        let value = reducer.value()
        for candidate in owners {
            #expect(state(value, owner: candidate) == .blocked)
            #expect(Set(signals(value, owner: candidate).map(\.kind))
                == (candidate == owner ? [.answer] : [.permission, .answer]))
        }
    }

    @Test(arguments: [nil, "child", "sibling"] as [String?])
    func delayedHookResolutionMatchesOnlyExactRequestAcrossNewerActivity(_ owner: String?) throws {
        var rows: [Data] = []
        for candidate in owners {
            rows += try [
                attentionEvent("assistant.turn_start", agent: candidate, data: ["turnId": "old"]),
                attentionEvent("permission.requested", agent: candidate, data: ["requestId": "old"],
                               timestamp: "2026-09-12T12:00:10Z"),
                attentionEvent("user_input.requested", agent: candidate, data: ["requestId": "old"],
                               timestamp: "2026-09-12T12:00:10Z"),
                attentionEvent("permission.requested", agent: candidate, data: ["requestId": "new"],
                               timestamp: "2026-09-12T12:00:20Z")
            ]
        }
        let beforeResolution = rows
        rows += try [
            attentionEvent("assistant.turn_start", agent: owner, data: ["turnId": "new"],
                           timestamp: "2026-09-12T12:00:30Z"),
            attentionEvent("permission.requested", agent: owner, data: ["requestId": "old", "resolvedByHook": true],
                           timestamp: "2026-09-12T12:00:15Z"),
            attentionEvent("permission.requested", agent: owner, data: ["requestId": "old"],
                           timestamp: "2026-09-12T12:00:40Z")
        ]
        let session = UUID()
        var before = replay(beforeResolution, session: session)
        let old = signals(before.value(), owner: owner).filter { $0.kind == .permission }.map(\.evidence)
        #expect(old.count == 2)
        var after = replay(rows, session: session)
        let result = after.value()
        #expect(signals(result, owner: owner).filter { $0.kind == .permission }.count == 1)
        #expect(signals(result, owner: owner).filter { $0.kind == .answer }.count == 1)
        #expect(state(result, owner: owner) == .blocked)
        for sibling in owners where sibling != owner {
            #expect(signals(result, owner: sibling) == signals(before.value(), owner: sibling))
            #expect(state(result, owner: sibling) == .blocked)
        }
    }

    @Test(arguments: ["view", "bash"], [nil, "child"] as [String?])
    func matchedToolCompletionWithReversedTimingNeverResurrectsExecuting(_ name: String, owner: String?) throws {
        let session = UUID()
        let rows = try [
            attentionEvent("tool.execution_start", agent: owner, data: ["toolCallId": "tool", "toolName": name],
                           timestamp: "2026-09-12T12:00:20Z"),
            attentionEvent("tool.execution_start", agent: "sibling", data: ["toolCallId": "other", "toolName": "rg"]),
            attentionEvent("tool.execution_complete", agent: "sibling", data: ["toolCallId": "tool", "success": true],
                           timestamp: "2026-09-12T12:00:10Z"),
            attentionEvent("tool.execution_complete", agent: owner, data: ["toolCallId": "tool", "success": true],
                           timestamp: "2026-09-12T12:00:10Z")
        ]
        var reducer = replay(rows, session: session)
        let value = reducer.value()
        let activity = owner == nil ? value.activity : value.children.first { $0.id == owner }?.activity
        #expect(activity?.summary == "Last completed tool: \(name)")
        #expect(activity?.lastEventAt == nil)
        #expect(value.children.first { $0.id == "sibling" }?.activity?.summary == "Executing tool: rg")
        if name == "bash" {
            #expect(value.children.first { $0.id == "shell:tool" }?.state == .completed)
            #expect(value.children.first { $0.id == "shell:tool" }?.terminalEvent != nil)
            #expect(value.children.first { $0.id == "shell:tool" }?.terminalEvent?.timestamp == nil)
        }
        reducer.consume(try attentionEvent("tool.execution_complete", agent: owner, data: ["toolCallId": "tool", "success": true],
                                          timestamp: "2026-09-12T12:00:40Z"))
        #expect(reducer.value() == value)
    }

    @Test(arguments: [nil, "child", "sibling"] as [String?])
    func concurrentToolsDoNotMoveTheOwnersRequestAdmissionBoundary(_ owner: String?) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        for row in try [
            attentionEvent("assistant.turn_start", agent: owner, data: ["turnId": "main"]),
            attentionEvent("tool.execution_start", agent: owner, data: ["toolCallId": "tool", "toolName": "view"],
                           timestamp: "2026-09-12T12:00:20Z"),
            attentionEvent("assistant.turn_end", agent: owner, data: ["turnId": "main"],
                           timestamp: "2026-09-12T12:00:15Z"),
            attentionEvent("user_input.requested", agent: owner, data: ["requestId": "question"],
                           timestamp: "2026-09-12T12:00:10Z")
        ] { reducer.consume(row) }
        let value = reducer.value()
        #expect(state(value, owner: owner) == .blocked)
        #expect(signals(value, owner: owner).contains { $0.kind == .answer })
        if owner == nil {
            #expect(value.attention.first { $0.kind == .turnFinished }?.occurredAt == origin.addingTimeInterval(15))
        }
    }

    @Test(arguments: [nil, "child", "sibling"] as [String?])
    func matchedTurnCompletionWithReversedTimingIsOwnerScopedAndReplayStable(_ owner: String?) throws {
        let session = UUID()
        var rows = try owners.map {
            try attentionEvent("assistant.turn_start", agent: $0, data: ["turnId": "shared"],
                               timestamp: "2026-09-12T12:00:20Z")
        }
        rows.append(try attentionEvent("assistant.turn_end", agent: owner, data: ["turnId": "shared"],
                                       timestamp: "2026-09-12T12:00:10Z"))
        var reducer = replay(rows, session: session)
        let result = reducer.value()
        for candidate in owners {
            #expect(state(result, owner: candidate) == (candidate == owner ? .idle : .working))
        }
        #expect(result.attention.map(\.kind) == (owner == nil ? [.turnFinished] : []))
        #expect(result.attention.first?.occurredAt == nil)
        reducer.consume(try attentionEvent("assistant.turn_end", agent: owner, data: ["turnId": "shared"],
                                          timestamp: "2026-09-12T12:00:40Z"))
        #expect(reducer.value() == result)
    }

    @Test(arguments: ["abort", "session.error"], [nil, "child"] as [String?])
    func unscopedFailuresOlderThanTheRequestStayStale(_ type: String, owner: String?) throws {
        func rows(failureAt timestamp: String) throws -> [Data] {
            try [
                attentionEvent("assistant.turn_start", agent: owner, data: ["turnId": "current"]),
                attentionEvent("permission.requested", agent: owner, data: ["requestId": "request"],
                               timestamp: "2026-09-12T12:00:20Z"),
                attentionEvent(type, agent: owner, timestamp: timestamp)
            ]
        }
        var stale = replay(try rows(failureAt: "2026-09-12T12:00:10Z"), session: UUID())
        let value = stale.value()
        #expect(state(value, owner: owner) == .blocked)
        #expect(signals(value, owner: owner).map(\.kind) == [.permission])
        // Control: the same failure after the request is accepted.
        var current = replay(try rows(failureAt: "2026-09-12T12:00:30Z"), session: UUID())
        #expect(state(current.value(), owner: owner) == (type == "abort" ? .cancelled : .failed))
    }

    @Test func matchedToolFailureSharesUnknownTimingAcrossActivityAndAttention() throws {
        for name in ["view", "bash"] {
            for owner in owners {
                let rows = try [
                    attentionEvent("tool.execution_start", agent: owner, data: ["toolCallId": "tool", "toolName": name],
                                   timestamp: "2026-09-12T12:00:20Z"),
                    attentionEvent("tool.execution_complete", agent: owner, data: ["toolCallId": "tool", "success": false],
                                   timestamp: "2026-09-12T12:00:10Z")
                ]
                var reducer = replay(rows, session: UUID())
                let value = reducer.value()
                let outcomeOwner = name == "bash" ? "shell:tool" : owner
                #expect(signals(value, owner: outcomeOwner).map(\.kind) == [.error])
                #expect(signals(value, owner: outcomeOwner).first?.occurredAt == nil)
                let activity = owner == nil ? value.activity : value.children.first { $0.id == owner }?.activity
                #expect(activity?.summary == "Last completed tool: \(name)")
                #expect(activity?.lastEventAt == nil)
            }
        }
    }

    private func replay(_ rows: [Data], session: UUID) -> CopilotEventReducer {
        var reducer = CopilotEventReducer(sessionID: session)
        for row in rows { reducer.consume(row) }
        return reducer
    }

    private func state(_ value: CopilotReducedState, owner: String?) -> CopilotWorkState? {
        owner == nil ? value.state : value.children.first { $0.id == owner }?.state
    }

    private func signals(_ value: CopilotReducedState, owner: String?) -> [AgentAttention] {
        owner == nil ? value.attention : value.children.first { $0.id == owner }?.attention ?? []
    }
}
