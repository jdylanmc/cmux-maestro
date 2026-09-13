import Foundation
import Testing
@testable import CMUXMaestroPreview

nonisolated struct CopilotAttentionTests {
    @Test func requestPairingIncludesOwnerAndKind() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        for owner: String? in [nil, "child"] {
            if let owner {
                reducer.consume(try copilotTestEvent("subagent.started", agent: owner, data: [
                    "toolCallId": "spawn", "agentDisplayName": "Child"
                ]))
            }
            reducer.consume(try copilotTestEvent("assistant.turn_start", agent: owner, data: ["turnId": "turn"]))
            reducer.consume(try copilotTestEvent("permission.requested", agent: owner, data: ["requestId": "shared"]))
            reducer.consume(try copilotTestEvent("user_input.requested", agent: owner, data: ["requestId": "shared"]))
        }
        reducer.consume(try copilotTestEvent("permission.completed", agent: "child", data: ["requestId": "shared"]))
        reducer.consume(try copilotTestEvent("user_input.completed", agent: "child", data: ["requestId": "shared"]))
        #expect(reducer.value().state == .blocked)
        #expect(reducer.value().children.first?.state == .working)
    }

    @Test func completedRequestCannotReopenFromLateRequest() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        reducer.consume(try copilotTestEvent("assistant.turn_start", data: ["turnId": "turn"]))
        reducer.consume(try copilotTestEvent("permission.completed", data: ["requestId": "request"]))
        reducer.consume(try copilotTestEvent("permission.requested", data: ["requestId": "request"]))
        #expect(reducer.value().state == .working)
    }

    @Test func oldTurnEndCannotIdleNewPrimaryTurn() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        for turn in ["old", "new"] {
            reducer.consume(try copilotTestEvent("assistant.turn_start", data: ["turnId": turn]))
        }
        reducer.consume(try copilotTestEvent("assistant.turn_end", data: ["turnId": "old"]))
        #expect(reducer.value().state == .working)
    }

    @Test func staleRootAbortCannotEraseCurrentPermission() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        reducer.consume(try copilotTestEvent("assistant.turn_start", data: ["turnId": "turn"]))
        reducer.consume(try copilotTestEvent("permission.requested", data: ["requestId": "permission"]))
        var stale = try #require(JSONSerialization.jsonObject(with: copilotTestEvent("abort")) as? [String: Any])
        stale["timestamp"] = "2026-09-11T00:00:00Z"
        reducer.consume(try JSONSerialization.data(withJSONObject: stale))
        #expect(reducer.value().state == .blocked)
    }

    @Test func hookResolutionAndRepeatedRequestsRespectOwnerKindAndStableEvidence() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let rootPermission = try attentionEvent("permission.requested", data: ["requestId": "same"])
        for line in try [
            rootPermission, rootPermission,
            attentionEvent("permission.requested", data: ["requestId": "same"]),
            attentionEvent("permission.requested", agent: "child", data: ["requestId": "same"]),
            attentionEvent("user_input.requested", agent: "child", data: ["requestId": "same"]),
            attentionEvent("permission.requested", agent: "child", data: ["requestId": "same", "resolvedByHook": true])
        ] { reducer.consume(line) }
        let result = reducer.value()
        #expect(result.attention.map(\.kind) == [.permission])
        #expect(result.attention.first?.evidence.eventID == (try eventID(rootPermission)))
        #expect(result.children.first?.attention?.map(\.kind) == [.answer])
        #expect(result.children.first?.id == "child")
        #expect(result.children.first?.parentID == "unresolved-owner")
        #expect(result.children.first?.state == .blocked)
    }

    @Test func mainCompletionIsNotSessionOrChildCompletionAndDoesNotRepeat() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let finish = try attentionEvent("assistant.turn_end", data: ["turnId": "main"])
        for line in try [
            attentionEvent("assistant.turn_start", data: ["turnId": "main"]),
            attentionEvent("tool.execution_start", data: ["toolCallId": "task", "toolName": "task"]),
            attentionEvent("subagent.started", agent: "child", data: ["toolCallId": "task", "agentDisplayName": "Child"]),
            finish, finish,
            attentionEvent("assistant.turn_end", data: ["turnId": "main"])
        ] { reducer.consume(line) }
        #expect(reducer.value().state == .idle)
        #expect(reducer.value().children.first?.state == .working)
        #expect(reducer.value().children.first?.attention == [])
        #expect(reducer.value().attention.map(\.kind) == [.turnFinished])
        #expect(reducer.value().attention.first?.evidence.eventID == (try eventID(finish)))
        #expect(AgentAttentionKind.turnFinished.title == "Turn finished")
        #expect(!AgentAttentionKind.turnFinished.isBlocking)
    }

    @Test func newPrimaryTurnBoundsOutcomesButDoesNotResolveChildRequests() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        for line in try [
            attentionEvent("assistant.turn_start", data: ["turnId": "old"]),
            attentionEvent("subagent.started", agent: "failed", data: ["toolCallId": "failed", "agentDisplayName": "Child"]),
            attentionEvent("subagent.failed", data: ["toolCallId": "failed", "agentDisplayName": "Child"]),
            attentionEvent("permission.requested", agent: "waiting", data: ["requestId": "permission"]),
            attentionEvent("assistant.turn_end", data: ["turnId": "old"])
        ] { reducer.consume(line) }
        #expect(reducer.value().children.first?.attention?.first?.kind == .error)
        #expect(reducer.value().attention.first?.kind == .turnFinished)
        reducer.consume(try attentionEvent("assistant.turn_start", data: ["turnId": "new"]))
        #expect(reducer.value().attention.isEmpty)
        #expect(reducer.value().children.first?.state == .failed)
        #expect(reducer.value().children.first?.terminalEvent != nil)
        #expect(reducer.value().children.first?.attention == [])
        #expect(reducer.value().children.last?.attention?.first?.kind == .permission)
        #expect(reducer.value().children.last?.state == .blocked)
    }

    @Test func resumedOwnerRetiresSignalsWithoutInventingChildCompletion() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        for line in try [
            attentionEvent("assistant.turn_start", data: ["turnId": "old"]),
            attentionEvent("tool.execution_start", agent: "child", data: ["toolCallId": "tool", "toolName": "view"]),
            attentionEvent("session.error"),
            attentionEvent("session.resume"),
            attentionEvent("assistant.turn_end", data: ["turnId": "old"]),
            attentionEvent("tool.execution_complete", agent: "child", data: ["toolCallId": "tool", "success": false])
        ] { reducer.consume(line) }
        let state = reducer.value()
        #expect(state.state == .unknown)
        #expect(state.attention.isEmpty)
        #expect(state.activity == nil)
        #expect(state.children.first?.state == .unknown)
        #expect(state.children.first?.attention == [])
        #expect(state.children.first?.activity == nil)
    }

    @Test(arguments: ["session.error", "abort"])
    func acceptedRootOutcomeDoesNotEndOrUnblockBackgroundWork(_ type: String) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        for line in try [
            attentionEvent("assistant.turn_start", data: ["turnId": "main"]),
            attentionEvent("permission.requested", data: ["requestId": "root"]),
            attentionEvent("permission.requested", agent: "child", data: ["requestId": "child"]),
            attentionEvent(type)
        ] { reducer.consume(line) }
        let outcome = reducer.value().attention
        #expect(outcome.map(\.kind) == [type == "abort" ? .aborted : .error])
        #expect(reducer.value().children.first?.state == .blocked)
        reducer.consume(try attentionEvent(type))
        #expect(reducer.value().attention == outcome)
    }

    @Test(arguments: ["session.error", "abort"], [false, true])
    func rejectedStaleOutcomeOrRequestDoesNotChangeCurrentOwner(_ type: String, child: Bool) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let owner: String? = child ? "child" : nil
        reducer.consume(try attentionEvent("assistant.turn_start", agent: owner, data: ["turnId": "fresh"],
                                          timestamp: "2026-09-12T12:00:10Z"))
        reducer.consume(try attentionEvent("permission.requested", agent: owner, data: ["requestId": "old"]))
        #expect(child ? reducer.value().children.first?.state == .working : reducer.value().state == .working)
        reducer.consume(try attentionEvent("permission.requested", agent: owner, data: ["requestId": "fresh"],
                                          timestamp: "2026-09-12T12:00:20Z"))
        reducer.consume(try attentionEvent(type, agent: owner, timestamp: "2026-09-12T12:00:15Z"))
        let signals = child ? reducer.value().children.first?.attention : reducer.value().attention
        #expect(signals?.map(\.kind) == [.permission])
    }

    @Test func activityUsesOwnedToolNamesAndCompletionIdentityNotPayloads() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let root = try attentionEvent("tool.execution_start", data: [
            "toolCallId": "root", "toolName": "view", "arguments": ["path": "PRIVATE_ARGUMENT"],
            "prompt": "PRIVATE_PROMPT"
        ])
        for line in try [
            root,
            attentionEvent("tool.execution_start", agent: "child", data: ["toolCallId": "child", "toolName": "rg"]),
            attentionEvent("tool.execution_complete", agent: "wrong-owner", data: ["toolCallId": "child", "success": true]),
            attentionEvent("tool.execution_complete", data: ["toolCallId": "unmatched", "success": true])
        ] { reducer.consume(line) }
        #expect(reducer.value().activity?.summary == "Executing tool: view")
        #expect(reducer.value().children.first?.activity?.summary == "Executing tool: rg")
        reducer.consume(try attentionEvent("tool.execution_complete", agent: "child", data: [
            "toolCallId": "child", "success": true, "result": "PRIVATE_RESULT", "error": "PRIVATE_ERROR"
        ]))
        #expect(reducer.value().activity?.summary == "Executing tool: view")
        #expect(reducer.value().children.first?.activity?.summary == "Last completed tool: rg")
        #expect(reducer.value().children.first?.activity?.kind == .idle)
        #expect(reducer.value().children.first?.activity?.lastEventAt != nil)
        let encoded = String(decoding: try JSONEncoder().encode(reducer.value().children), as: UTF8.self)
        #expect(!encoded.contains("PRIVATE_"))
    }

    @Test func multipleExecutingToolsAndDuplicateCompletionKeepHonestActivity() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        for (id, name) in [("one", "view"), ("two", "rg")] {
            reducer.consume(try attentionEvent("tool.execution_start", data: ["toolCallId": id, "toolName": name]))
        }
        #expect(reducer.value().activity?.summary == "Executing tool: rg")
        reducer.consume(try attentionEvent("tool.execution_complete", data: ["toolCallId": "two", "success": true]))
        #expect(reducer.value().activity?.summary == "Executing tool: view")
        reducer.consume(try attentionEvent("tool.execution_complete", data: ["toolCallId": "one", "success": true]))
        let completed = reducer.value().activity
        #expect(completed?.summary == "Last completed tool: view")
        reducer.consume(try attentionEvent("tool.execution_complete", data: ["toolCallId": "two", "success": true],
                                          timestamp: "2026-09-12T13:00:00Z"))
        #expect(reducer.value().activity == completed)
    }

    @Test(arguments: ["not-a-date", "2099-01-01T00:00:00Z", nil])
    func missingOrUntrustedTimingDoesNotCreateOrLoseIdentity(_ timestamp: String?) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        reducer.consume(try attentionEvent("assistant.turn_start", data: ["turnId": "turn"]))
        let end = try attentionEvent("assistant.turn_end", data: ["turnId": "turn"], timestamp: timestamp)
        reducer.consume(end)
        #expect(reducer.value().attention.first?.evidence.eventID == (try eventID(end)))
        #expect(reducer.value().attention.first?.kind == .turnFinished)
    }

    @Test func oldWireContractStillDecodesAndNewSignalsRoundTrip() throws {
        let session = UUID()
        let old = Data("""
        {"sessionID":"\(session)","surfaceID":"\(UUID())","launchWorkspaceID":"\(UUID())",
         "liveness":"alive","state":"idle","children":[],"observedAt":1}
        """.utf8)
        let decoded = try JSONDecoder().decode(CopilotSessionObservation.self, from: old)
        #expect(decoded.attention == nil)
        #expect(decoded.activity == nil)
        var reducer = CopilotEventReducer(sessionID: session)
        reducer.consume(try attentionEvent("permission.requested", agent: "child", data: ["requestId": "request"]))
        let children = reducer.value().children
        #expect(try JSONDecoder().decode([CopilotChildWork].self, from: JSONEncoder().encode(children)) == children)
    }

    @Test func resumeRejectsPreResumeChildErrorsAndRetiresPriorPendingIdentity() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        reducer.consume(try attentionEvent("permission.requested", agent: "child", data: ["requestId": "old"]))
        reducer.consume(try attentionEvent("session.resume", timestamp: "2026-09-12T12:00:10Z"))
        reducer.consume(try attentionEvent("session.error", agent: "child"))
        reducer.consume(try attentionEvent("permission.requested", agent: "child", data: ["requestId": "old"],
                                          timestamp: "2026-09-12T12:00:20Z"))
        #expect(reducer.value().children.first?.state == .unknown)
        #expect(reducer.value().children.first?.attention == [])
        #expect(reducer.value().children.first?.terminalEvent == nil)
    }

    @Test func shutdownCannotReplaceAcceptedErrorIdentityOrTurnFailureGreen() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        reducer.consume(try attentionEvent("session.error"))
        let original = reducer.value().attention
        for type in ["routine", "error", "routine"] {
            reducer.consume(try attentionEvent("session.shutdown", data: ["shutdownType": type]))
            #expect(reducer.value().attention == original)
            #expect(reducer.value().state == .failed)
        }
    }

    @Test func childReopenAndToolActivityRetireOnlyTheirOwnersOutcome() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        for line in try [
            attentionEvent("assistant.turn_start", data: ["turnId": "main"]),
            attentionEvent("assistant.turn_start", agent: "child", data: ["turnId": "old"]),
            attentionEvent("abort", agent: "child"),
            attentionEvent("assistant.turn_end", data: ["turnId": "main"])
        ] { reducer.consume(line) }
        let main = reducer.value().attention
        reducer.consume(try attentionEvent("assistant.turn_start", agent: "child", data: ["turnId": "new"]))
        #expect(reducer.value().children.first?.state == .working)
        #expect(reducer.value().children.first?.attention == [])
        #expect(reducer.value().attention == main)
        reducer.consume(try attentionEvent("tool.execution_start", data: ["toolCallId": "tool", "toolName": "view"]))
        #expect(reducer.value().attention.isEmpty)
        #expect(reducer.value().activity?.summary == "Executing tool: view")
        reducer.consume(try attentionEvent("tool.execution_complete", data: ["toolCallId": "tool", "success": false]))
        #expect(reducer.value().attention.first?.kind == .error)
    }

    @Test func primaryTurnEndDoesNotSilentlyAcknowledgeAnEarlierToolError() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        for line in try [
            attentionEvent("assistant.turn_start", data: ["turnId": "main"]),
            attentionEvent("tool.execution_start", data: ["toolCallId": "tool", "toolName": "view"]),
            attentionEvent("tool.execution_complete", data: ["toolCallId": "tool", "success": false]),
            attentionEvent("assistant.turn_end", data: ["turnId": "main"])
        ] { reducer.consume(line) }
        #expect(reducer.value().state == .idle)
        #expect(reducer.value().attention.map(\.kind) == [.error, .turnFinished])
        reducer.consume(try attentionEvent("tool.execution_start", data: ["toolCallId": "new", "toolName": "rg"]))
        #expect(reducer.value().attention.isEmpty)
    }

    @Test(arguments: ["unsafe name PRIVATE_ARGUMENT", "tool\nname", "/private/path", "\u{202E}tool", ""])
    func toolMetadataOutsideSymbolicAllowlistCannotBecomeActivity(_ name: String) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        reducer.consume(try attentionEvent("tool.execution_start", data: ["toolCallId": "tool", "toolName": name]))
        #expect(reducer.value().activity == nil)
        reducer.consume(try attentionEvent("tool.execution_complete", data: ["toolCallId": "tool", "success": true]))
        #expect(reducer.value().activity == nil)
    }

    private func eventID(_ line: Data) throws -> UUID {
        let event = try JSONDecoder().decode(CopilotEventProjection.self, from: line)
        return try #require(UUID(uuidString: event.id))
    }
}

nonisolated func attentionEvent(
    _ type: String, agent: String? = nil, data: [String: Any] = [:],
    timestamp: String? = "2026-09-12T12:00:00Z"
) throws -> Data {
    var event: [String: Any] = ["id": UUID().uuidString, "type": type, "data": data]
    event["agentId"] = agent
    event["timestamp"] = timestamp
    return try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
}
