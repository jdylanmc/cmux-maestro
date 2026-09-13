import Foundation
import Testing
@testable import CMUXMaestroPreview

nonisolated struct CopilotEventReducerTests {
    @Test func completedInvocationsCannotStarveFreshBlockedSubagent() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        for index in 0..<256 {
            let tool = "shell-\(index)"
            try feed(&reducer, "tool.execution_start", ["toolCallId": tool, "toolName": "bash"])
            try feed(&reducer, "tool.execution_complete", ["toolCallId": tool, "success": true])
        }
        try feed(&reducer, "tool.execution_start", ["toolCallId": "fresh", "toolName": "task"])
        try feed(&reducer, "subagent.started", agent: "fresh", [
            "toolCallId": "fresh", "agentDisplayName": "Fresh"
        ])
        try feed(&reducer, "permission.requested", agent: "fresh", ["requestId": "approval"])
        #expect(reducer.value().children.first(where: { $0.id == "fresh" })?.state == .blocked)
        #expect(reducer.value().children.count <= 256)
        #expect(reducer.issues.isEmpty)
    }

    @Test func terminalRetirementPreservesAncestorsPendingAndUnknownWork() throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumWorkItems: 4)
        for (id, parent) in [("parent", "root"), ("child", "parent"), ("spare", "root")] {
            try feed(&reducer, "subagent.started", agent: id, [
                "toolCallId": id, "agentDisplayName": id, "parentId": parent
            ])
        }
        try feed(&reducer, "skill.invoked", ["name": "unknown-lifetime"])
        for id in ["parent", "spare"] {
            try feed(&reducer, "subagent.completed", ["toolCallId": id, "agentDisplayName": id])
        }
        try feed(&reducer, "permission.requested", agent: "child", ["requestId": "approval"])
        try feed(&reducer, "subagent.started", agent: "new", [
            "toolCallId": "new", "agentDisplayName": "new", "parentId": "parent"
        ])
        let value = reducer.value()
        #expect(value.children.count == 4)
        #expect(value.children.first(where: { $0.id == "parent" })?.state == .completed)
        #expect(value.children.first(where: { $0.id == "child" })?.state == .blocked)
        #expect(value.children.first(where: { $0.id == "child" })?.parentID == "parent")
        #expect(value.children.contains(where: { $0.kind == .skill && $0.state == .unknown }))
        #expect(!value.children.contains(where: { $0.id == "spare" }))
        #expect(reducer.issues.isEmpty)
        try feed(&reducer, "subagent.started", agent: "overflow", [
            "toolCallId": "overflow", "agentDisplayName": "overflow", "parentId": "root"
        ])
        #expect(reducer.value() == value)
        #expect(reducer.issues == [.readLimitReached])
        try feed(&reducer, "permission.completed", ["requestId": "approval"])
        #expect(reducer.value().children.first(where: { $0.id == "child" })?.state == .working)
    }

    @Test(arguments: [false, true])
    func freshSpawnReusesAgentIDButOldLifecycleReplayCannotAffectIt(retire: Bool) throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumWorkItems: 1)
        let toolA = try copilotTestEvent("tool.execution_start", agent: "parent-a", data: [
            "toolCallId": "tool-a", "toolName": "task"
        ])
        let startA = try copilotTestEvent("subagent.started", agent: "worker", data: [
            "toolCallId": "tool-a", "agentDisplayName": "A", "parentId": "parent-a"
        ])
        let turnA = try copilotTestEvent("assistant.turn_start", agent: "worker", data: ["turnId": "turn-a"])
        let endA = try copilotTestEvent("assistant.turn_end", agent: "worker", data: ["turnId": "turn-a"])
        let requestA = try copilotTestEvent("permission.requested", agent: "worker", data: ["requestId": "request-a"])
        let finishA = try copilotTestEvent("subagent.completed", data: [
            "toolCallId": "tool-a", "agentDisplayName": "A"
        ])
        for row in [toolA, startA, turnA, requestA, endA, finishA, startA, turnA] { reducer.consume(row) }
        #expect(reducer.value().children.first?.state == .completed)
        if retire {
            try feed(&reducer, "system.notification", [
                "kind": ["type": "shell_completed", "shellId": "retire-a", "exitCode": 0]
            ])
            #expect(!reducer.value().children.contains(where: { $0.id == "worker" }))
        }
        try feed(&reducer, "tool.execution_start", agent: "parent-b", ["toolCallId": "tool-b", "toolName": "task"])
        try feed(&reducer, "subagent.started", agent: "worker", [
            "toolCallId": "tool-b", "agentDisplayName": "B", "parentId": "parent-b"
        ])
        try feed(&reducer, "permission.requested", agent: "worker", ["requestId": "request-b"])
        let fresh = try #require(reducer.value().children.first(where: { $0.id == "worker" }))
        #expect(fresh.state == .blocked)
        #expect(fresh.name == "B")
        #expect(fresh.parentID == "parent-b")
        for row in [toolA, startA, turnA, endA, requestA, finishA] { reducer.consume(row) }
        #expect(reducer.value().children.first == fresh)
        #expect(reducer.retentionCounts.owners == 1)
        // Same old tool/turn with a different event UUID is still the old
        // lifecycle, unlike a previously unseen scoped turn or spawn tool.
        try feed(&reducer, "subagent.started", agent: "worker", [
            "toolCallId": "tool-a", "agentDisplayName": "A", "parentId": "parent-a"
        ])
        try feed(&reducer, "assistant.turn_start", agent: "worker", ["turnId": "turn-a"])
        #expect(reducer.value().children.first == fresh)
        try feed(&reducer, "permission.completed", ["requestId": "request-b"])
        #expect(reducer.value().children.first?.state == .working)
        try feed(&reducer, "subagent.completed", ["toolCallId": "tool-b", "agentDisplayName": "B"])
        #expect(reducer.value().children.first?.state == .completed)
        #expect(reducer.issues.isEmpty)
    }

    @Test func turnOwnersAreScopedAndEnrichmentCannotDiscardPendingRequests() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        for id in ["a", "b"] {
            try feed(&reducer, "assistant.turn_start", agent: id, ["turnId": "shared"])
            try feed(&reducer, "permission.requested", agent: id, ["requestId": "permission-\(id)"])
        }
        try feed(&reducer, "subagent.started", agent: "a", [
            "toolCallId": "spawn-a", "agentDisplayName": "A", "parentId": "parent"
        ])
        let a = try #require(reducer.value().children.first(where: { $0.id == "a" }))
        let b = try #require(reducer.value().children.first(where: { $0.id == "b" }))
        #expect(a.state == .blocked)
        #expect(a.name == "A")
        #expect(a.parentID == "parent")
        #expect(b.state == .blocked)
        try feed(&reducer, "permission.completed", ["requestId": "permission-a"])
        #expect(reducer.value().children.first(where: { $0.id == "a" })?.state == .working)
        try feed(&reducer, "assistant.turn_end", agent: "a", ["turnId": "shared"])
        #expect(reducer.value().children.first(where: { $0.id == "a" })?.state == .idle)
        #expect(reducer.value().children.first(where: { $0.id == "b" })?.state == .blocked)
        #expect(reducer.issues.isEmpty)
    }

    @Test func repeatedAgentLifecyclesStayBoundedAndReconstructDeterministically() throws {
        let session = UUID()
        var original = CopilotEventReducer(sessionID: session, maximumWorkItems: 1, maximumRelationships: 32)
        var rebuilt = CopilotEventReducer(sessionID: session, maximumWorkItems: 1, maximumRelationships: 32)
        for index in 0..<128 {
            let rows = [
                try copilotTestEvent("subagent.started", agent: "worker", data: [
                    "toolCallId": "spawn-\(index)", "agentDisplayName": "Worker", "parentId": "parent"
                ]),
                try copilotTestEvent("assistant.turn_start", agent: "worker", data: ["turnId": "turn-\(index)"]),
                try copilotTestEvent("permission.requested", agent: "worker", data: ["requestId": "request-\(index)"]),
                try copilotTestEvent("subagent.completed", data: [
                    "toolCallId": "spawn-\(index)", "agentDisplayName": "Worker"
                ]),
                try copilotTestEvent("system.notification", data: [
                    "kind": ["type": "shell_completed", "shellId": "retire-\(index)", "exitCode": 0]
                ])
            ]
            for row in rows { original.consume(row); rebuilt.consume(row) }
        }
        let fresh = try copilotTestEvent("assistant.turn_start", agent: "worker", data: ["turnId": "last-fresh"])
        original.consume(fresh); rebuilt.consume(fresh)
        #expect(original.value() == rebuilt.value())
        #expect(original.value().children.first?.id == "worker")
        #expect(original.value().children.first?.state == .working)
        #expect(original.issues.isEmpty)
        #expect(original.retentionCounts.work == 1)
        #expect(original.retentionCounts.agents <= 1)
        #expect(original.retentionCounts.tombstones <= 32)
        #expect(original.retentionCounts.replayWords == 16_384)
    }

    @Test(arguments: [false, true])
    func freshScopedTurnReopensRetainedOrRetiredAgentWithoutInventedMetadata(retire: Bool) throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumWorkItems: 1)
        let spawnA = try copilotTestEvent("subagent.started", agent: "worker", data: [
            "toolCallId": "spawn-a", "agentDisplayName": "Old name", "parentId": "old-parent"
        ])
        let turnA = try copilotTestEvent("assistant.turn_start", agent: "worker", data: ["turnId": "turn-a"])
        let endA = try copilotTestEvent("assistant.turn_end", agent: "worker", data: ["turnId": "turn-a"])
        let completeA = try copilotTestEvent("subagent.completed", data: [
            "toolCallId": "spawn-a", "agentDisplayName": "Old name"
        ])
        for row in [spawnA, turnA, endA, completeA] { reducer.consume(row) }
        if retire {
            try feed(&reducer, "system.notification", [
                "kind": ["type": "shell_completed", "shellId": "retire-a", "exitCode": 0]
            ])
        }
        try feed(&reducer, "assistant.turn_start", agent: "worker", ["turnId": "turn-b", "model": "fresh-model"])
        let fresh = try #require(reducer.value().children.first(where: { $0.id == "worker" }))
        #expect(fresh.state == .working)
        #expect(fresh.kind == .unknown)
        #expect(fresh.name == "Unknown agent")
        #expect(fresh.parentID == "unresolved-owner")
        #expect(fresh.model == "fresh-model")
        for row in [spawnA, turnA, endA, completeA] { reducer.consume(row) }
        #expect(reducer.value().children.first == fresh)
        try feed(&reducer, "permission.requested", agent: "worker", ["requestId": "new-request"])
        #expect(reducer.value().children.first?.state == .blocked)
        try feed(&reducer, "assistant.turn_end", agent: "worker", ["turnId": "turn-b"])
        #expect(reducer.value().children.first?.state == .blocked)
        try feed(&reducer, "permission.completed", ["requestId": "new-request"])
        #expect(reducer.value().children.first?.state == .idle)
        #expect(reducer.issues.isEmpty)
    }

    @Test func continuousHistoryReclaimsRelationshipCapsAndRebuildsDeterministically() throws {
        let session = UUID()
        var reducer = CopilotEventReducer(sessionID: session)
        var rebuilt = CopilotEventReducer(sessionID: session)
        // Cross BOTH original caps in the same session, without resume/reset.
        for index in 0..<5000 {
            for row in [
                try copilotTestEvent("tool.execution_start", data: ["toolCallId": "shell-\(index)", "toolName": "bash"]),
                try copilotTestEvent("tool.execution_complete", data: ["toolCallId": "shell-\(index)", "success": true]),
                try copilotTestEvent("tool.execution_start", data: ["toolCallId": "agent-\(index)", "toolName": "task"]),
                try copilotTestEvent("subagent.started", agent: "agent-\(index)", data: [
                    "toolCallId": "agent-\(index)", "agentDisplayName": "Worker"
                ]),
                try copilotTestEvent("subagent.completed", data: [
                    "toolCallId": "agent-\(index)", "agentDisplayName": "Worker"
                ])
            ] {
                reducer.consume(row)
                rebuilt.consume(row)
            }
        }
        let fresh = try copilotTestEvent("subagent.started", agent: "fresh", data: [
            "toolCallId": "fresh", "agentDisplayName": "Fresh", "parentId": "root"
        ])
        let permission = try copilotTestEvent("permission.requested", agent: "fresh", data: ["requestId": "fresh-request"])
        for row in [fresh, permission] { reducer.consume(row); rebuilt.consume(row) }
        #expect(reducer.value() == rebuilt.value())
        #expect(reducer.value().children.last?.id == "fresh")
        #expect(reducer.value().children.last?.state == .blocked)
        #expect(reducer.issues.isEmpty)
        #expect(rebuilt.issues.isEmpty)
        let counts = reducer.retentionCounts
        #expect(counts.work == 256)
        #expect(counts.owners <= 256)
        #expect(counts.agents <= 256)
        #expect(counts.requests == 1)
        #expect(counts.tombstones <= 4096)
        #expect(counts.replayWords == 16_384)
        // Cold tombstones are conservative, explicitly uncertain, and not erased.
        try feed(&reducer, "tool.execution_start", ["toolCallId": "shell-0", "toolName": "bash"])
        try feed(&reducer, "subagent.started", agent: "agent-0", [
            "toolCallId": "agent-0", "agentDisplayName": "Worker"
        ])
        #expect(reducer.value() == rebuilt.value())
        #expect(reducer.issues == [.readLimitReached])
    }

    @Test func replayFilterIsBoundedAndSaturationNeverErasesOldProtection() {
        var guardState = CopilotReplayGuard(capacity: 2, wordCount: 2)
        var remembered: [String] = []
        var refused = false
        for index in 0..<1000 {
            let key = "terminal-\(index)"
            if !guardState.remember(key) { refused = true; break }
            remembered.append(key)
        }
        #expect(refused)
        #expect(guardState.retainedCount == 2)
        #expect(guardState.filterWordCount == 2)
        #expect(remembered.allSatisfy { guardState.match($0) != .absent })
    }

    @Test func completedToolOwnersStillJoinDelayedStartsAndRetireUnderPressure() throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumRelationships: 8)
        try feed(&reducer, "tool.execution_start", agent: "parent", [
            "toolCallId": "delayed", "toolName": "task"
        ])
        try feed(&reducer, "tool.execution_complete", ["toolCallId": "delayed", "success": true])
        try feed(&reducer, "subagent.started", agent: "child", [
            "toolCallId": "delayed", "agentDisplayName": "Child"
        ])
        #expect(reducer.value().children.first?.parentID == "parent")
        for index in 0..<100 {
            try feed(&reducer, "tool.execution_start", ["toolCallId": "read-\(index)", "toolName": "view"])
            try feed(&reducer, "tool.execution_complete", ["toolCallId": "read-\(index)", "success": true])
        }
        try feed(&reducer, "tool.execution_start", ["toolCallId": "fresh", "toolName": "task"])
        try feed(&reducer, "subagent.started", agent: "fresh", [
            "toolCallId": "fresh", "agentDisplayName": "Fresh"
        ])
        #expect(reducer.value().children.first?.parentID == "parent")
        #expect(reducer.value().children.last?.id == "fresh")
        #expect(reducer.retentionCounts.owners <= 8)
        #expect(reducer.retentionCounts.tombstones <= 8)
        #expect(reducer.issues.isEmpty)
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
