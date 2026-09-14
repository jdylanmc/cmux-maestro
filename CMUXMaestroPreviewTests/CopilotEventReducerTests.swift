import Foundation
import Testing
@testable import CMUXMaestroPreview

// Run large synchronous replay fixtures individually, not across every executor worker.
@Suite(.serialized)
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
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumLifecycleEvents: 2, maximumReplayFilterWords: 1)
        try feed(&reducer, "subagent.started", agent: "child", ["toolCallId": "spawn", "agentDisplayName": "Child"])
        try feed(&reducer, "assistant.turn_start", ["turnId": "1"])
        for row in try copilotTestReplayPressure() { reducer.consume(row) }
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
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumLifecycleEvents: 2, maximumReplayFilterWords: 1)
        try feed(&reducer, "subagent.started", agent: "child", ["toolCallId": "old", "agentDisplayName": "Child"])
        try feed(&reducer, state == .failed ? "subagent.failed" : "subagent.completed", [
            "toolCallId": "old", "agentDisplayName": "Child", "cancelled": state == .cancelled
        ])
        let terminal = reducer.value().children.first?.terminalEvent
        for row in try copilotTestReplayPressure() { reducer.consume(row) }
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

    @Test(arguments: [false, true], [false, true])
    func freshSpawnReusesAgentIDButOldLifecycleReplayCannotAffectIt(retire: Bool, spill: Bool) throws {
        var reducer = CopilotEventReducer(
            sessionID: UUID(), maximumWorkItems: 1, maximumRelationships: spill ? 4 : 4096,
            maximumLifecycleEvents: spill ? 2 : 65_536
        )
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
        try feed(&reducer, "assistant.turn_end", agent: "worker", ["turnId": "turn-a"])
        try feed(&reducer, "subagent.failed", ["toolCallId": "tool-a", "agentDisplayName": "A"])
        try feed(&reducer, "permission.requested", agent: "worker", ["requestId": "request-a"])
        #expect(reducer.value().children.first == fresh)
        try feed(&reducer, "permission.completed", ["requestId": "request-b"])
        #expect(reducer.value().children.first?.state == .working)
        try feed(&reducer, "subagent.completed", ["toolCallId": "tool-b", "agentDisplayName": "B"])
        #expect(reducer.value().children.first?.state == .completed)
        #expect(reducer.issues == (spill ? [.readLimitReached] : []))
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
        var original = CopilotEventReducer(
            sessionID: session, maximumWorkItems: 1, maximumRelationships: 32, maximumLifecycleEvents: 8
        )
        var rebuilt = CopilotEventReducer(
            sessionID: session, maximumWorkItems: 1, maximumRelationships: 32, maximumLifecycleEvents: 8
        )
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
        #expect(original.retentionCounts.events <= 8)
        #expect(original.retentionCounts.eventReplayWords == 16_384)
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
        var reducer = CopilotEventReducer(sessionID: session, maximumLifecycleEvents: 32)
        var rebuilt = CopilotEventReducer(sessionID: session, maximumLifecycleEvents: 32)
        // Cross the work, relationship, and exact event windows without reset.
        for index in 0..<5000 {
            for (offset, row) in [
                try copilotTestEvent("tool.execution_start", data: ["toolCallId": "shell-\(index)", "toolName": "bash"]),
                try copilotTestEvent("tool.execution_complete", data: ["toolCallId": "shell-\(index)", "success": true]),
                try copilotTestEvent("tool.execution_start", data: ["toolCallId": "agent-\(index)", "toolName": "task"]),
                try copilotTestEvent("subagent.started", agent: "agent-\(index)", data: [
                    "toolCallId": "agent-\(index)", "agentDisplayName": "Worker"
                ]),
                try copilotTestEvent("subagent.completed", data: [
                    "toolCallId": "agent-\(index)", "agentDisplayName": "Worker"
                ])
            ].enumerated() {
                var stable = try #require(JSONSerialization.jsonObject(with: row) as? [String: Any])
                stable["id"] = String(format: "E0000000-0000-0000-0000-%012X", index * 5 + offset)
                let data = try JSONSerialization.data(withJSONObject: stable)
                reducer.consume(data)
                rebuilt.consume(data)
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
        #expect(counts.events <= 32)
        #expect(counts.eventReplayWords == 16_384)
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

    @Test(arguments: [CopilotWorkState.completed, .failed, .cancelled], ["subagent.started", "assistant.turn_start"])
    func unsaturatedColdStartCollisionCannotKeepObsoleteTerminalEvidence(
        outcome: CopilotWorkState, type: String
    ) throws {
        var reducer = CopilotEventReducer(
            sessionID: UUID(), maximumRelationships: 2, maximumReplayFilterWords: 1
        )
        let start = try copilotTestEvent("subagent.started", agent: "worker", data: [
            "toolCallId": "spawn-a", "agentDisplayName": "A", "model": "known-child-model"
        ])
        reducer.consume(start)
        try feed(&reducer, outcome == .failed ? "subagent.failed" : "subagent.completed", [
            "toolCallId": "spawn-a", "agentDisplayName": "A", "cancelled": outcome == .cancelled
        ])
        try feed(&reducer, "session.model_change", ["newModel": "known-root-model"])
        for row in try copilotTestColdStartPressure() { reducer.consume(row) }
        #expect(reducer.issues.isEmpty)
        let terminal = reducer.value()
        reducer.consume(start)
        #expect(reducer.value() == terminal)
        try feed(&reducer, type, agent: "worker", [
            "toolCallId": "fresh-457", "turnId": "fresh-turn-135",
            "agentDisplayName": "Unattested B", "model": "unattested-model"
        ])
        let uncertain = reducer.value()
        #expect(uncertain.children.first?.state == .unknown)
        #expect(uncertain.children.first?.terminalEvent == nil)
        #expect(uncertain.children.first?.model == "known-child-model")
        #expect(uncertain.state == terminal.state)
        #expect(uncertain.model == terminal.model)
        #expect(reducer.canPublishProjection)
        #expect(reducer.issues == [.readLimitReached])
        try feed(&reducer, "subagent.completed", ["toolCallId": "spawn-a", "agentDisplayName": "A"])
        #expect(reducer.value() == uncertain)
    }

    @Test func unsaturatedColdStartsCannotChangeLiveInvocationOrItsPendingRequest() throws {
        var reducer = CopilotEventReducer(
            sessionID: UUID(), maximumRelationships: 2, maximumReplayFilterWords: 1
        )
        try feed(&reducer, "subagent.started", agent: "worker", ["toolCallId": "spawn-a", "agentDisplayName": "A"])
        try feed(&reducer, "subagent.completed", ["toolCallId": "spawn-a", "agentDisplayName": "A"])
        for row in try copilotTestColdStartPressure() { reducer.consume(row) }
        try feed(&reducer, "subagent.started", agent: "worker", [
            "toolCallId": "spawn-b", "agentDisplayName": "B", "model": "live-model"
        ])
        try feed(&reducer, "permission.requested", agent: "worker", ["requestId": "pending-b"])
        #expect(reducer.issues.isEmpty)
        let live = reducer.value()
        #expect(live.children.first?.state == .blocked)
        for tool in ["spawn-a", "fresh-457"] {
            try feed(&reducer, "subagent.started", agent: "worker", [
                "toolCallId": tool, "agentDisplayName": "Unattested", "model": "unattested-model"
            ])
            #expect(reducer.value() == live)
        }
        try feed(&reducer, "assistant.turn_start", agent: "worker", [
            "turnId": "fresh-turn-135", "model": "unattested-model"
        ])
        try feed(&reducer, "subagent.completed", ["toolCallId": "spawn-a", "agentDisplayName": "A"])
        #expect(reducer.value() == live)
        #expect(reducer.retentionCounts.requests == 1)
        #expect(reducer.issues == [.readLimitReached])
        try feed(&reducer, "permission.completed", ["requestId": "pending-b"])
        #expect(reducer.value().children.first?.state == .working)
    }

    @Test func coldRootTurnDemotesOnlyTerminalRootWithoutAdoptingUnattestedModel() throws {
        var reducer = CopilotEventReducer(
            sessionID: UUID(), maximumRelationships: 2, maximumReplayFilterWords: 1
        )
        try feed(&reducer, "subagent.started", agent: "worker", ["toolCallId": "spawn-a", "agentDisplayName": "A"])
        for row in try copilotTestColdStartPressure() { reducer.consume(row) }
        try feed(&reducer, "session.shutdown", ["shutdownType": "routine", "currentModel": "known-root-model"])
        let terminal = reducer.value()
        try feed(&reducer, "assistant.turn_start", ["turnId": "noise-3"])
        #expect(reducer.value() == terminal)
        try feed(&reducer, "assistant.turn_start", ["turnId": "root-fresh-47", "model": "unattested-model"])
        #expect(reducer.value().state == .unknown)
        #expect(reducer.value().model == "known-root-model")
        #expect(reducer.value().children == terminal.children)
        #expect(reducer.issues == [.readLimitReached])
        try feed(&reducer, "assistant.turn_end", ["turnId": "noise-3"])
        #expect(reducer.value().state == .unknown)
    }

    @Test func saturatedReplayKeepsPendingRequestsAndRejectsObsoleteInvocationCompletions() throws {
        var reducer = CopilotEventReducer(
            sessionID: UUID(), maximumLifecycleEvents: 2, maximumReplayFilterWords: 1
        )
        try feed(&reducer, "subagent.started", agent: "worker", ["toolCallId": "a", "agentDisplayName": "A"])
        try feed(&reducer, "assistant.turn_start", agent: "worker", ["turnId": "turn-a"])
        try feed(&reducer, "subagent.completed", ["toolCallId": "a", "agentDisplayName": "A"])
        try feed(&reducer, "subagent.started", agent: "worker", ["toolCallId": "b", "agentDisplayName": "B"])
        try feed(&reducer, "permission.requested", agent: "worker", ["requestId": "pending-b"])
        #expect(reducer.value().children.first?.state == .blocked)
        for row in try copilotTestReplayPressure() { reducer.consume(row) }
        let limited = reducer.value()
        #expect(limited.children.first?.state == .blocked)
        #expect(limited.children.first?.terminalEvent == nil)
        #expect(reducer.retentionCounts.requests == 1)
        #expect(reducer.issues == [.readLimitReached])
        try feed(&reducer, "subagent.started", agent: "worker", ["toolCallId": "a", "agentDisplayName": "A"])
        try feed(&reducer, "subagent.failed", ["toolCallId": "a", "agentDisplayName": "A"])
        try feed(&reducer, "assistant.turn_end", agent: "worker", ["turnId": "turn-a"])
        #expect(reducer.value() == limited)
        #expect(reducer.canPublishProjection)
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

nonisolated func copilotTestReplayPressure() throws -> [Data] {
    // Exhaust the deliberately tiny one-word filter, not just its exact window.
    try (0..<128).map { index in
        try JSONSerialization.data(withJSONObject: [
            "id": String(format: "F0000000-0000-0000-0000-%012X", index),
            "type": "session.model_change", "data": ["newModel": "pressure"]
        ])
    }
}

nonisolated func copilotTestColdStartPressure() throws -> [Data] {
    var replay = CopilotReplayGuard(capacity: 2, wordCount: 1)
    for key in ["subagent:spawn-a"] + (0..<4).map({ "turn:0::noise-\($0)" }) {
        let remembered = replay.remember(key)
        #expect(remembered)
    }
    #expect(replay.occupiedBits == 18)
    #expect(replay.occupiedBits < 32)
    for key in ["subagent:spawn-a", "subagent:fresh-457", "turn:6:worker:fresh-turn-135", "turn:0::root-fresh-47"] {
        #expect(replay.match(key) == .uncertain)
    }
    #expect(replay.match("subagent:spawn-b") == .absent)
    return try (0..<4).map { try copilotTestEvent("assistant.turn_start", data: ["turnId": "noise-\($0)"]) }
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
