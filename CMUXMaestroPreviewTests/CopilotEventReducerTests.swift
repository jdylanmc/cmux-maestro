import Foundation
import Testing
@testable import CMUXMaestroPreview

nonisolated struct CopilotEventReducerTests {
    @Test func acceptedCompletionCarriesDurableEvidenceNotObservationTime() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        try feed(&reducer, "subagent.started", agent: "child", [
            "toolCallId": "spawn", "agentDisplayName": "Child"
        ])
        let completion = try copilotTestEvent("subagent.completed", data: [
            "toolCallId": "spawn", "agentDisplayName": "Child"
        ])
        reducer.consume(completion)
        let encoded = try JSONEncoder().encode(reducer.value().children)
        let children = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        #expect(children.first?["terminalEvent"] != nil)
    }

    @Test(arguments: [
        "2026-09-12T12:00:00Z", "2026-09-12T12:00:00.123Z",
        "2026-09-12T14:30:00+02:30", "2026-09-12T07:00:00.123-05:00"
    ])
    func parsesPublicTimestampForms(_ timestamp: String) throws {
        let data = try event("subagent.completed", id: UUID(), timestamp: timestamp, [
            "toolCallId": "spawn", "agentDisplayName": "Child"
        ])
        let projected = try JSONDecoder().decode(CopilotEventProjection.self, from: data)
        let seconds = try #require(projected.timestamp?.timeIntervalSince1970)
        #expect(abs(seconds - (timestamp.contains(".123") ? 1_789_214_400.123 : 1_789_214_400)) < 0.0001)
    }

    @Test func malformedAndMissingTimestampsKeepTerminalIdentityAndWireCompatibility() throws {
        for timestamp: Any? in [nil, "not-a-date", 12345, NSNull()] {
            var reducer = CopilotEventReducer(sessionID: UUID())
            try feed(&reducer, "subagent.started", agent: "child", ["toolCallId": "spawn", "agentDisplayName": "Child"])
            let id = UUID()
            reducer.consume(try event("subagent.completed", id: id, timestamp: timestamp, [
                "toolCallId": "spawn", "agentDisplayName": "Child"
            ]))
            let child = try #require(reducer.value().children.first)
            #expect(child.state == .completed)
            #expect(child.terminalEvent?.id == id)
            #expect(child.terminalEvent?.timestamp == nil)
        }
        let legacy = Data(#"{"id":"child","kind":"subagent","name":"Child","state":"completed"}"#.utf8)
        #expect(try JSONDecoder().decode(CopilotChildWork.self, from: legacy).terminalEvent == nil)
    }

    @Test(arguments: [CopilotWorkState.completed, .failed, .cancelled])
    func acceptedOutcomeSurvivesDuplicatesLateCompletionAndReconstruction(_ state: CopilotWorkState) throws {
        let session = UUID()
        let start = try copilotTestEvent("subagent.started", agent: "child", data: [
            "toolCallId": "spawn", "agentDisplayName": "Child"
        ])
        let id = UUID()
        let completion = try event(state == .failed ? "subagent.failed" : "subagent.completed",
            id: id, timestamp: "2026-09-12T12:00:01.250Z", [
                "toolCallId": "spawn", "agentDisplayName": "Child", "cancelled": state == .cancelled
            ])
        let late = try event("subagent.completed", id: UUID(), timestamp: "2026-09-12T13:00:00Z", [
            "toolCallId": "spawn", "agentDisplayName": "Child"
        ])
        var first = CopilotEventReducer(sessionID: session)
        var rebuilt = CopilotEventReducer(sessionID: session)
        for line in [start, completion, completion, start, late] {
            first.consume(line)
            rebuilt.consume(line)
        }
        let child = try #require(first.value().children.first)
        #expect(child.state == state)
        #expect(child.terminalEvent?.id == id)
        #expect(child.terminalEvent?.timestamp == Date(timeIntervalSince1970: 1_789_214_401.25))
        #expect(first.value() == rebuilt.value())
    }

    @Test func reusedChildRejectsOldToolCompletionAndAcceptsNewOutcome() throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumRelationships: 1)
        for tool in ["old", "new"] {
            try feed(&reducer, "subagent.started", agent: "same", ["toolCallId": tool, "agentDisplayName": "Same label"])
            #expect(reducer.value().children.first?.state == .working)
            #expect(reducer.value().children.first?.terminalEvent == nil)
            if tool == "new" {
                try feed(&reducer, "subagent.failed", ["toolCallId": "old", "agentDisplayName": "Same label"])
                #expect(reducer.value().children.first?.state == .working)
            }
            try feed(&reducer, "subagent.completed", ["toolCallId": tool, "agentDisplayName": "Same label"])
        }
        #expect(reducer.value().children.first?.state == .completed)
        #expect(!reducer.issues.contains(.readLimitReached))
    }

    @Test func oldStartsAndCaseVariantDuplicatesCannotResurrectFinishedWork() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let start = try copilotTestEvent("subagent.started", agent: "child", data: [
            "toolCallId": "spawn", "agentDisplayName": "Child"
        ])
        reducer.consume(start)
        try feed(&reducer, "subagent.completed", ["toolCallId": "spawn", "agentDisplayName": "Child"])
        let ended = reducer.value()
        var duplicate = try #require(JSONSerialization.jsonObject(with: start) as? [String: Any])
        duplicate["id"] = (duplicate["id"] as? String)?.lowercased()
        reducer.consume(try JSONSerialization.data(withJSONObject: duplicate))
        #expect(reducer.value() == ended)
        var stale = duplicate
        stale["id"] = UUID().uuidString
        stale["timestamp"] = "2026-09-11T00:00:00Z"
        reducer.consume(try JSONSerialization.data(withJSONObject: stale))
        #expect(reducer.value() == ended)
    }

    @Test func replayProtectionExhaustionFailsExplicitlyUnknown() throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumLifecycleEvents: 2)
        try feed(&reducer, "subagent.started", agent: "child", ["toolCallId": "spawn", "agentDisplayName": "Child"])
        try feed(&reducer, "assistant.turn_start", ["turnId": "1"])
        try feed(&reducer, "subagent.completed", ["toolCallId": "spawn", "agentDisplayName": "Child"])
        #expect(reducer.value().state == .unknown)
        #expect(reducer.value().children.first?.state == .unknown)
        #expect(reducer.value().children.first?.terminalEvent == nil)
        #expect(reducer.issues.contains(.readLimitReached))
    }

    @Test(arguments: [4, 65_536])
    func retiredInvocationIdentityCannotReopenAfterMappingMovesToNewInvocation(_ limit: Int) throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumLifecycleEvents: limit)
        for tool in ["old", "new"] {
            try feed(&reducer, "subagent.started", agent: "child", ["toolCallId": tool, "agentDisplayName": "Child"])
            try feed(&reducer, "subagent.completed", ["toolCallId": tool, "agentDisplayName": "Child"])
        }
        let ended = reducer.value()
        try feed(&reducer, "subagent.started", agent: "child", ["toolCallId": "old", "agentDisplayName": "Old label"])
        #expect(reducer.value() == ended)
        try feed(&reducer, "subagent.failed", ["toolCallId": "old", "agentDisplayName": "Old label"])
        #expect(reducer.value() == ended)
    }

    @Test func retiredTurnIdentitiesAreScopedAndCannotReopenRootOrChildWork() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        for agent: String? in [nil, "child", "sibling"] {
            if let agent {
                try feed(&reducer, "subagent.started", agent: agent, ["toolCallId": agent, "agentDisplayName": agent])
            }
            for turn in ["old", "new"] {
                try feed(&reducer, "assistant.turn_start", agent: agent, ["turnId": turn])
                if let agent {
                    #expect(reducer.value().children.first { $0.id == agent }?.state == .working)
                } else {
                    #expect(reducer.value().state == .working)
                }
                try feed(&reducer, "assistant.turn_end", agent: agent, ["turnId": turn])
            }
        }
        let idle = reducer.value()
        for agent: String? in [nil, "child", "sibling"] {
            try feed(&reducer, "assistant.turn_start", agent: agent, ["turnId": "old"])
            #expect(reducer.value() == idle)
        }
    }

    @Test func repeatedShellInvocationIdentityCannotReopenTerminalShell() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        try feed(&reducer, "tool.execution_start", ["toolCallId": "shell", "toolName": "bash"])
        try feed(&reducer, "tool.execution_complete", ["toolCallId": "shell", "success": false])
        let ended = reducer.value()
        try feed(&reducer, "tool.execution_start", ["toolCallId": "shell", "toolName": "bash"])
        #expect(reducer.value() == ended)
    }

    @Test(arguments: [false, true], [false, true])
    func sessionSafetyChecksPrecedeReplayAndCapacityGuards(_ atCap: Bool, duplicateID: Bool) throws {
        for invalidVersion in [false, true] {
            let session = UUID()
            var reducer = CopilotEventReducer(sessionID: session, maximumLifecycleEvents: atCap ? 2 : 20)
            let start = try copilotTestEvent("subagent.started", agent: "child", data: [
                "toolCallId": "task", "agentDisplayName": "Child"
            ])
            reducer.consume(start)
            try feed(&reducer, "subagent.completed", ["toolCallId": "task", "agentDisplayName": "Child"])
            let startObject = try #require(JSONSerialization.jsonObject(with: start) as? [String: Any])
            let id = duplicateID ? try #require(UUID(uuidString: startObject["id"] as? String ?? "")) : UUID()
            reducer.consume(try event("session.start", id: id, timestamp: nil, [
                "sessionId": invalidVersion ? session.uuidString : UUID().uuidString,
                "version": invalidVersion ? 0 : 1
            ]))
            #expect(reducer.issues.contains(invalidVersion ? .unsupportedFormat : .identityChanged))
            #expect(!reducer.canPublishProjection)
        }
    }

    @Test(arguments: [CopilotWorkState.completed, .failed, .cancelled])
    func capacityPreservesTerminalProtectionButCannotHideAnUnprocessedRestart(_ state: CopilotWorkState) throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumLifecycleEvents: 2)
        try feed(&reducer, "subagent.started", agent: "child", ["toolCallId": "old", "agentDisplayName": "Child"])
        try feed(&reducer, state == .failed ? "subagent.failed" : "subagent.completed", [
            "toolCallId": "old", "agentDisplayName": "Child", "cancelled": state == .cancelled
        ])
        let terminal = reducer.value().children.first?.terminalEvent
        try feed(&reducer, "subagent.completed", ["toolCallId": "old", "agentDisplayName": "Child"])
        #expect(reducer.value().children.first?.state == state)
        #expect(reducer.value().children.first?.terminalEvent == terminal)
        try feed(&reducer, "subagent.started", agent: "child", ["toolCallId": "new", "agentDisplayName": "Child"])
        #expect(reducer.value().children.first?.state == .unknown)
        #expect(reducer.value().children.first?.terminalEvent == nil)
        #expect(reducer.canPublishProjection)
    }

    @Test(arguments: [false, true])
    func lifecycleUncertaintyDemotesTerminalScopeWithoutFabricatingAnOutcome(_ unresolvedScope: Bool) throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumLifecycleEvents: 4)
        for child in ["affected", "unrelated"] {
            try feed(&reducer, "subagent.started", agent: child, ["toolCallId": child, "agentDisplayName": child])
            try feed(&reducer, "subagent.failed", ["toolCallId": child, "agentDisplayName": child])
        }
        let unrelated = reducer.value().children.last?.terminalEvent
        try feed(&reducer, "subagent.future_lifecycle", agent: unresolvedScope ? nil : "affected", [:])
        #expect(reducer.value().children.first?.state == .unknown)
        #expect(reducer.value().children.first?.terminalEvent == nil)
        #expect(reducer.value().children.last?.state == (unresolvedScope ? .unknown : .failed))
        #expect(reducer.value().children.last?.terminalEvent == (unresolvedScope ? nil : unrelated))
    }

    @Test func replayedRootTurnAtCapacityCannotReopenEndedSession() throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumLifecycleEvents: 5)
        for turn in ["old", "new"] {
            try feed(&reducer, "assistant.turn_start", ["turnId": turn])
            try feed(&reducer, "assistant.turn_end", ["turnId": turn])
        }
        try feed(&reducer, "session.shutdown", ["shutdownType": "routine"])
        #expect(reducer.value().state == .completed)
        try feed(&reducer, "assistant.turn_start", ["turnId": "old"])
        #expect(reducer.value().state == .completed)
        #expect(reducer.issues.isEmpty)
    }

    @Test(arguments: ["subagent.started", "assistant.turn_start"], [false, true])
    func futureTimingCannotSuppressANewLifecycleIdentity(_ type: String, futureStart: Bool) throws {
        let session = UUID()
        let initial = try event("subagent.started", id: UUID(),
            timestamp: futureStart ? "2099-01-01T00:00:00Z" : "2026-09-12T12:00:00Z",
            ["toolCallId": "old", "agentDisplayName": "Child"], agent: "child")
        let completion = try event("subagent.completed", id: UUID(), timestamp: "2099-01-01T01:00:00Z",
            ["toolCallId": "old", "agentDisplayName": "Child"])
        let fresh = try event(type, id: UUID(), timestamp: "2026-09-12T12:00:01Z",
            ["toolCallId": "new", "agentDisplayName": "Child", "turnId": "new-turn"], agent: "child")
        for _ in 0..<2 {
            var reducer = CopilotEventReducer(sessionID: session)
            for row in [initial, completion, fresh] { reducer.consume(row) }
            #expect(reducer.value().children.first?.state == .working)
            #expect(reducer.value().children.first?.terminalEvent == nil)
        }
    }

    @Test(arguments: ["abort", "session.error"])
    func rejectedStaleChildTerminalEventKeepsCurrentPendingRequests(_ type: String) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        try feed(&reducer, "subagent.started", agent: "child", ["toolCallId": "task", "agentDisplayName": "Child"])
        try feed(&reducer, "permission.requested", agent: "child", ["requestId": "permission"])
        try feed(&reducer, "user_input.requested", agent: "child", ["requestId": "input"])
        #expect(reducer.value().children.first?.state == .blocked)
        reducer.consume(try event(type, id: UUID(), timestamp: "2026-09-12T11:59:00Z", [:], agent: "child"))
        #expect(reducer.value().children.first?.state == .blocked)
        #expect(reducer.value().children.first?.terminalEvent == nil)
        try feed(&reducer, "permission.completed", agent: "child", ["requestId": "permission"])
        #expect(reducer.value().children.first?.state == .blocked)
        try feed(&reducer, "user_input.completed", agent: "child", ["requestId": "input"])
        #expect(reducer.value().children.first?.state == .working)
    }

    @Test func shellAndScopedAbortUseAcceptedTerminalEvidence() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        try feed(&reducer, "tool.execution_start", ["toolCallId": "shell", "toolName": "bash"])
        try feed(&reducer, "tool.execution_complete", ["toolCallId": "shell", "success": false])
        let failed = reducer.value().children.first?.terminalEvent
        try feed(&reducer, "tool.execution_complete", ["toolCallId": "shell", "success": true])
        #expect(reducer.value().children.first?.terminalEvent == failed)
        try feed(&reducer, "subagent.started", agent: "child", ["toolCallId": "task", "agentDisplayName": "Child"])
        try feed(&reducer, "abort", agent: "child", [:])
        #expect(reducer.value().children.last?.state == .cancelled)
        #expect(reducer.value().children.last?.terminalEvent != nil)
        try feed(&reducer, "system.notification", [
            "kind": ["type": "shell_completed", "shellId": "background", "exitCode": 0]
        ])
        #expect(reducer.value().children.last?.terminalEvent != nil)
    }

    @Test func staleCompletionAndUnsupportedLifecycleDoNotFabricateProgress() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        try feed(&reducer, "subagent.started", agent: "child", ["toolCallId": "task", "agentDisplayName": "Child"])
        reducer.consume(try event("subagent.completed", id: UUID(), timestamp: "2026-09-11T12:00:00Z", [
            "toolCallId": "task", "agentDisplayName": "Child"
        ]))
        #expect(reducer.value().children.first?.state == .working)
        try feed(&reducer, "subagent.future_lifecycle", agent: "child", [:])
        #expect(reducer.value().children.first?.state == .unknown)
        #expect(reducer.value().children.first?.terminalEvent == nil)
        #expect(reducer.issues.contains(.unsupportedFormat))
    }

    private func event(
        _ type: String, id: UUID, timestamp: Any?, _ data: [String: Any], agent: String? = nil
    ) throws -> Data {
        var event: [String: Any] = ["id": id.uuidString, "type": type, "data": data]
        if let timestamp { event["timestamp"] = timestamp }
        if let agent { event["agentId"] = agent }
        return try JSONSerialization.data(withJSONObject: event)
    }

    @Test func joinsToolOwnerNotChronologicalParentAndPreservesDuplicateNames() throws {
        let session = UUID()
        var reducer = CopilotEventReducer(sessionID: session)
        try feed(&reducer, "tool.execution_start", ["toolCallId": "spawn-a", "toolName": "task"])
        try feed(&reducer, "subagent.started", agent: "a", [
            "toolCallId": "spawn-a", "agentDisplayName": "Worker"
        ])
        try feed(&reducer, "tool.execution_start", ["toolCallId": "spawn-b", "toolName": "task"])
        try feed(&reducer, "subagent.started", agent: "b", [
            "toolCallId": "spawn-b", "agentDisplayName": "Worker"
        ])
        try feed(&reducer, "tool.execution_start", agent: "a", [
            "toolCallId": "spawn-c", "toolName": "task"
        ])
        try feed(&reducer, "subagent.started", agent: "c", [
            "toolCallId": "spawn-c", "agentDisplayName": "Grandchild"
        ])
        let children = reducer.value().children
        #expect(children.map(\.id) == ["a", "b", "c"])
        #expect(children[0].parentID == nil)
        #expect(children[1].parentID == nil)
        #expect(children[2].parentID == "a")
        #expect(children[0].name == children[1].name)
        #expect(reducer.issues.isEmpty)
    }

    @Test func explicitRegistryParentAndUnresolvedEdgesDoNotInventRootOwnership() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        try feed(&reducer, "subagent.started", agent: "child", [
            "toolCallId": "spawn", "agentDisplayName": "Child", "parentId": "parent"
        ])
        try feed(&reducer, "subagent.started", agent: "unresolved", [
            "toolCallId": "missing-tool", "agentDisplayName": "Child"
        ])
        #expect(reducer.value().children[0].parentID == "parent")
        #expect(reducer.value().children[1].parentID == "unresolved-tool:missing-tool")
        try feed(&reducer, "tool.execution_start", ["toolCallId": "missing-tool", "toolName": "task"])
        #expect(reducer.value().children[1].parentID == nil)
    }

    @Test func failedAndCancelledAreNotOverwrittenByLateCompletion() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        for id in ["failed", "cancelled", "completed"] {
            try feed(&reducer, "subagent.started", agent: id, [
                "toolCallId": id, "agentDisplayName": id, "parentId": "root"
            ])
        }
        try feed(&reducer, "subagent.failed", [
            "toolCallId": "failed", "agentDisplayName": "failed", "error": "ERROR_SENTINEL"
        ])
        try feed(&reducer, "subagent.completed", [
            "toolCallId": "cancelled", "agentDisplayName": "cancelled", "cancelled": true
        ])
        for id in ["failed", "cancelled", "completed"] {
            try feed(&reducer, "subagent.completed", ["toolCallId": id, "agentDisplayName": id])
        }
        #expect(reducer.value().children.map(\.state) == [.failed, .cancelled, .completed])
    }

    @Test func questionsPairByKindAndIDAndShutdownRetiresPending() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        try feed(&reducer, "assistant.turn_start", ["turnId": "1", "model": "test-model"])
        try feed(&reducer, "permission.requested", ["requestId": "same", "permissionRequest": ["secret": "PERMISSION"]])
        try feed(&reducer, "user_input.requested", ["requestId": "same", "question": "QUESTION_SENTINEL"])
        #expect(reducer.value().state == .blocked)
        try feed(&reducer, "permission.completed", ["requestId": "same", "result": "secret"])
        #expect(reducer.value().state == .blocked)
        try feed(&reducer, "user_input.completed", ["requestId": "other", "answer": "ANSWER_SENTINEL"])
        #expect(reducer.value().state == .blocked)
        try feed(&reducer, "user_input.completed", ["requestId": "same", "answer": "ANSWER_SENTINEL"])
        #expect(reducer.value().state == .working)
        try feed(&reducer, "user_input.requested", ["requestId": "pending", "question": "secret"])
        try feed(&reducer, "session.shutdown", ["shutdownType": "routine"])
        #expect(reducer.value().state == .completed)
        try feed(&reducer, "user_input.completed", ["requestId": "pending"])
        #expect(reducer.value().state == .completed)
    }

    @Test func rootIdleDoesNotFinishWorkingChildrenAndChildQuestionIsScoped() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        try feed(&reducer, "tool.execution_start", ["toolCallId": "spawn", "toolName": "task"])
        try feed(&reducer, "subagent.started", agent: "child", [
            "toolCallId": "spawn", "agentDisplayName": "Child", "model": "child-model"
        ])
        try feed(&reducer, "session.idle", [:])
        #expect(reducer.value().state == .idle)
        #expect(reducer.value().children[0].state == .working)
        try feed(&reducer, "user_input.requested", agent: "child", ["requestId": "child-request", "question": "secret"])
        #expect(reducer.value().state == .idle)
        #expect(reducer.value().children[0].state == .blocked)
        try feed(&reducer, "user_input.completed", ["requestId": "child-request"])
        #expect(reducer.value().children[0].state == .working)
    }

    @Test func skillsAndShellUseOnlySupportedMetadataAndExcludePayloads() throws {
        let session = UUID()
        var reducer = CopilotEventReducer(sessionID: session)
        try feed(&reducer, "session.start", [
            "sessionId": session.uuidString, "version": 1, "selectedModel": "model-one",
            "context": ["cwd": "PATH_SENTINEL"]
        ])
        try feed(&reducer, "skill.invoked", [
            "name": "review", "model": "skill-model", "content": "PROMPT_SENTINEL",
            "path": "PATH_SENTINEL"
        ])
        try feed(&reducer, "tool.execution_start", [
            "toolCallId": "shell", "toolName": "bash",
            "arguments": ["command": "ARGS_SENTINEL"]
        ])
        try feed(&reducer, "tool.execution_complete", [
            "toolCallId": "shell", "success": false,
            "error": ["message": "ERROR_SENTINEL"], "result": "RESULT_SENTINEL"
        ])
        try feed(&reducer, "assistant.message", ["content": "PROMPT_SENTINEL"])
        try feed(&reducer, "future.unknown_event", ["anything": ["credential": "CREDENTIAL_SENTINEL"]])
        let value = reducer.value()
        #expect(value.children.map(\.kind) == [.skill, .shell])
        #expect(value.children.map(\.state) == [.unknown, .failed])
        #expect(value.model == "model-one")
        let publicData = try JSONEncoder().encode(value.children)
        let text = String(decoding: publicData, as: UTF8.self)
        #expect(!text.contains("SENTINEL"))
        #expect(reducer.issues.isEmpty)
    }

    @Test func malformedRowsCannotMutateStateAndCyclesAreBounded() throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumDepth: 2)
        try feed(&reducer, "session.idle", [:])
        reducer.consume(Data("{torn".utf8))
        try feed(&reducer, "assistant.turn_start", ["turnId": 123])
        #expect(reducer.value().state == .idle)
        #expect(reducer.issues == [.malformedData])
        try feed(&reducer, "subagent.started", agent: "a", [
            "toolCallId": "a", "agentDisplayName": "a", "parentId": "b"
        ])
        try feed(&reducer, "subagent.started", agent: "b", [
            "toolCallId": "b", "agentDisplayName": "b", "parentId": "a"
        ])
        #expect(reducer.value().children.allSatisfy { $0.parentID?.hasPrefix("unresolved-cycle:") == true })
    }

    @Test func sessionMismatchAndStateCapsAreExplicit() throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumWorkItems: 1)
        try feed(&reducer, "session.start", ["sessionId": UUID().uuidString, "version": 1])
        for id in ["a", "b"] {
            try feed(&reducer, "skill.invoked", ["name": id])
        }
        #expect(reducer.value().children.count == 1)
        #expect(reducer.issues.contains(.identityChanged))
        #expect(reducer.issues.contains(.readLimitReached))
    }

    @Test func backgroundShellExitUsesStructuredNotificationNotContentOrArguments() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        try feed(&reducer, "system.notification", [
            "content": "PROMPT_SENTINEL",
            "kind": ["type": "shell_completed", "shellId": "background-1", "exitCode": 7, "description": "ARGS_SENTINEL"]
        ])
        let child = try #require(reducer.value().children.first)
        #expect(child.id == "shell-session:background-1")
        #expect(child.state == .failed)
        #expect(child.name == "Background shell")
        #expect(reducer.issues.isEmpty)
    }

    @Test func crashResumeDemotesHistoricalActiveChildrenUntilFreshEvidence() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        for id in ["working", "idle", "failed", "cancelled", "completed"] {
            try feed(&reducer, "tool.execution_start", ["toolCallId": id, "toolName": "task"])
            try feed(&reducer, "subagent.started", agent: id, ["toolCallId": id, "agentDisplayName": id])
        }
        try feed(&reducer, "assistant.turn_end", agent: "idle", ["turnId": "old"])
        try feed(&reducer, "subagent.failed", ["toolCallId": "failed", "agentDisplayName": "failed"])
        try feed(&reducer, "subagent.completed", [
            "toolCallId": "cancelled", "agentDisplayName": "cancelled", "cancelled": true
        ])
        try feed(&reducer, "subagent.completed", ["toolCallId": "completed", "agentDisplayName": "completed"])
        try feed(&reducer, "tool.execution_start", ["toolCallId": "old-shell", "toolName": "bash"])
        try feed(&reducer, "user_input.requested", agent: "working", ["requestId": "orphan", "question": "secret"])
        #expect(reducer.value().children[0].state == .blocked)

        // A crash has no shutdown event to retire the previous owner's work.
        try feed(&reducer, "session.resume", [:])
        try feed(&reducer, "assistant.turn_start", ["turnId": "new"])
        try feed(&reducer, "assistant.turn_end", ["turnId": "new"])
        let resumed = reducer.value()
        #expect(resumed.state == .idle)
        #expect(resumed.children.map(\.state) == [.unknown, .unknown, .failed, .cancelled, .completed, .unknown])

        try feed(&reducer, "assistant.turn_start", agent: "working", ["turnId": "fresh-child"])
        #expect(reducer.value().children[0].state == .working)
        #expect(reducer.value().children[1].state == .unknown)
    }

    @Test func hookResolvedPermissionNeverBlocksAndRetiresOnlyMatchingPermission() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        try feed(&reducer, "assistant.turn_start", ["turnId": "1"])
        try feed(&reducer, "permission.requested", ["requestId": "automatic", "resolvedByHook": true])
        #expect(reducer.value().state == .working)
        try feed(&reducer, "permission.requested", ["requestId": "pending", "resolvedByHook": false])
        #expect(reducer.value().state == .blocked)
        try feed(&reducer, "permission.requested", ["requestId": "automatic", "resolvedByHook": true])
        #expect(reducer.value().state == .blocked)
        try feed(&reducer, "permission.requested", ["requestId": "pending", "resolvedByHook": true])
        #expect(reducer.value().state == .working)

        try feed(&reducer, "user_input.requested", ["requestId": "shared", "question": "secret"])
        try feed(&reducer, "permission.requested", ["requestId": "shared", "resolvedByHook": true])
        #expect(reducer.value().state == .blocked)
        try feed(&reducer, "user_input.completed", ["requestId": "shared"])
        #expect(reducer.value().state == .working)
        #expect(reducer.issues.isEmpty)
    }

    private func feed(
        _ reducer: inout CopilotEventReducer, _ type: String, agent: String? = nil, _ data: [String: Any]
    ) throws {
        reducer.consume(try copilotTestEvent(type, agent: agent, data: data))
    }
}

nonisolated func copilotTestEvent(
    _ type: String, agent: String? = nil, data: [String: Any] = [:]
) throws -> Data {
    var event: [String: Any] = [
        "id": UUID().uuidString, "type": type, "data": data,
        "parentId": UUID().uuidString, "timestamp": "2026-09-12T12:00:00Z"
    ]
    if let agent { event["agentId"] = agent }
    return try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
}
