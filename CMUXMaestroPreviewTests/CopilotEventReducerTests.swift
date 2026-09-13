import Foundation
import Testing
@testable import CMUXMaestroPreview

nonisolated struct CopilotEventReducerTests {
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
