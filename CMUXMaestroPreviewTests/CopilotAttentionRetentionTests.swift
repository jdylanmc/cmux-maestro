import Foundation
import Testing
@testable import CMUXMaestroPreview

@Suite(.serialized)
nonisolated struct CopilotAttentionRetentionTests {
    @Test(arguments: [false, true])
    func toolAdmissionCapacityCannotKeepAnObsoleteTerminalOwner(live: Bool) throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumRelationships: 2)
        reducer.consume(try attentionEvent("subagent.started", agent: "worker", data: [
            "toolCallId": "spawn", "agentDisplayName": "Worker", "model": "known"
        ]))
        if live {
            reducer.consume(try attentionEvent("permission.requested", agent: "worker", data: ["requestId": "current"]))
        } else {
            reducer.consume(try attentionEvent("subagent.completed", data: [
                "toolCallId": "spawn", "agentDisplayName": "Worker"
            ]))
        }
        for tool in ["busy-a", "busy-b"] {
            reducer.consume(try attentionEvent("tool.execution_start", data: ["toolCallId": tool, "toolName": "view"]))
        }
        let before = reducer.value()
        reducer.consume(try attentionEvent("tool.execution_start", agent: "worker", data: [
            "toolCallId": "fresh", "toolName": "view", "model": "unproven"
        ], timestamp: "2026-09-12T13:00:00Z"))
        #expect(reducer.retentionCounts.owners == 2)
        #expect(reducer.issues == [.readLimitReached])
        if live {
            #expect(reducer.value() == before)
        } else {
            #expect(reducer.value().children.first?.state == .unknown)
            #expect(reducer.value().children.first?.terminalEvent == nil)
            #expect(reducer.value().children.first?.model == "known")
            #expect(reducer.value().activity == before.activity)
            reducer.consume(try attentionEvent("permission.requested", agent: "worker", data: ["requestId": "current"]))
            #expect(reducer.value().children.first?.state == .blocked)
        }
    }

    @Test(arguments: ["view", "bash"], [false, true])
    func selectiveShellAliasCannotHideTerminalOwnerOrRewriteLiveOwner(toolName: String, live: Bool) throws {
        copilotSelectiveShellAliasWitness(live: live)
        var reducer = CopilotEventReducer(
            sessionID: UUID(), maximumRelationships: 2, maximumReplayFilterWords: 1
        )
        for row in try [
            attentionEvent("session.model_change", data: ["newModel": "known-root"]),
            attentionEvent("subagent.started", agent: "worker", data: [
                "toolCallId": "spawn-a", "agentDisplayName": "A", "model": "model-a"
            ]),
            attentionEvent("subagent.completed", data: ["toolCallId": "spawn-a", "agentDisplayName": "A"])
        ] + copilotTestColdStartPressure() { reducer.consume(row) }
        if live {
            reducer.consume(try attentionEvent("subagent.started", agent: "worker", data: [
                "toolCallId": "spawn-b", "agentDisplayName": "B", "model": "model-b"
            ]))
            reducer.consume(try attentionEvent("permission.requested", agent: "worker", data: ["requestId": "current"]))
        }
        let before = reducer.value()
        reducer.consume(try attentionEvent("tool.execution_start", agent: "worker", data: [
            "toolCallId": "fresh-owner-31", "toolName": toolName, "model": "unproven-model"
        ], timestamp: "2026-09-12T13:00:00Z"))
        let rejected = reducer.value()
        #expect(reducer.issues == [.readLimitReached])
        #expect(reducer.retentionCounts.owners == 0)
        #expect(rejected.children.count == before.children.count)
        #expect(rejected.state == before.state && rejected.model == before.model)
        if live {
            #expect(rejected == before)
            reducer.consume(try attentionEvent("user_input.requested", agent: "worker", data: [
                "requestId": "second"
            ], timestamp: "2026-09-12T12:00:10Z"))
            #expect(reducer.value().children.first?.attention?.count == 2)
        } else {
            #expect(rejected.children.first?.state == .unknown)
            #expect(rejected.children.first?.terminalEvent == nil)
            #expect(rejected.children.first?.model == "model-a")
            #expect(rejected.children.first?.activity == nil)
            reducer.consume(try attentionEvent("permission.requested", agent: "worker", data: [
                "requestId": "current"
            ], timestamp: "2026-09-12T12:00:10Z"))
            #expect(reducer.value().children.first?.attention?.map(\.kind) == [.permission])
        }
        #expect(reducer.value().children.first?.state == .blocked)
        #expect(reducer.canPublishProjection)
    }

    @Test(arguments: ["view", "bash"])
    func exactEventOrToolReplayWinsOverAnUncertainShellAlias(toolName: String) throws {
        copilotSelectiveShellAliasWitness()
        var reducer = CopilotEventReducer(
            sessionID: UUID(), maximumRelationships: 2, maximumReplayFilterWords: 1
        )
        let startA = try attentionEvent("subagent.started", agent: "worker", data: [
            "toolCallId": "spawn-a", "agentDisplayName": "A"
        ])
        for row in try [startA, attentionEvent("subagent.completed", data: [
            "toolCallId": "spawn-a", "agentDisplayName": "A"
        ])] + copilotTestColdStartPressure() { reducer.consume(row) }
        let terminal = reducer.value()
        let candidate = try attentionEvent("tool.execution_start", agent: "worker", data: [
            "toolCallId": "fresh-owner-31", "toolName": toolName, "model": "unproven-model"
        ], timestamp: "2026-09-12T13:00:00Z")
        var exactEvent = reducer
        var duplicate = try #require(JSONSerialization.jsonObject(with: candidate) as? [String: Any])
        duplicate["id"] = try JSONDecoder().decode(CopilotEventProjection.self, from: startA).id
        exactEvent.consume(try JSONSerialization.data(withJSONObject: duplicate))
        #expect(exactEvent.value() == terminal)
        #expect(exactEvent.issues.isEmpty)

        reducer.consume(try attentionEvent("tool.execution_complete", agent: "worker", data: [
            "toolCallId": "fresh-owner-31", "success": true
        ]))
        reducer.consume(candidate)
        #expect(reducer.value() == terminal)
        #expect(reducer.issues.isEmpty)
    }

    @Test func replaySaturationCannotSilentlyAcknowledgeRecordedOutcomesOrRequests() throws {
        var reducer = CopilotEventReducer(
            sessionID: UUID(), maximumRelationships: 8, maximumLifecycleEvents: 8, maximumReplayFilterWords: 1
        )
        for row in try [
            attentionEvent("assistant.turn_start", data: ["turnId": "main"]),
            attentionEvent("subagent.started", agent: "failed", data: ["toolCallId": "failed", "agentDisplayName": "Failed"]),
            attentionEvent("subagent.failed", data: ["toolCallId": "failed", "agentDisplayName": "Failed"]),
            attentionEvent("assistant.turn_end", data: ["turnId": "main"]),
            attentionEvent("permission.requested", data: ["requestId": "root"]),
            attentionEvent("user_input.requested", agent: "waiting", data: ["requestId": "child"])
        ] { reducer.consume(row) }
        let observed = reducer.value()
        #expect(observed.attention.map(\.kind) == [.permission, .turnFinished])
        #expect(observed.children.first { $0.id == "failed" }?.attention?.map(\.kind) == [.error])
        for row in try copilotTestReplayPressure() { reducer.consume(row) }
        let limited = reducer.value()
        #expect(limited.attention == observed.attention)
        #expect(limited.children.first { $0.id == "failed" }?.attention
            == observed.children.first { $0.id == "failed" }?.attention)
        #expect(limited.children.first { $0.id == "waiting" }?.attention
            == observed.children.first { $0.id == "waiting" }?.attention)
        #expect(limited.state == .blocked)
        #expect(limited.children.first { $0.id == "waiting" }?.state == .blocked)
        #expect(reducer.retentionCounts.requests == 2)
        #expect(reducer.issues == [.readLimitReached])
        #expect(reducer.canPublishProjection)
    }

    @Test func unknownLifecyclePreservesRecordedAttentionUntilVerifiedNewActivity() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        for row in try [
            attentionEvent("subagent.started", agent: "worker", data: ["toolCallId": "old", "agentDisplayName": "Old"]),
            attentionEvent("subagent.failed", data: ["toolCallId": "old", "agentDisplayName": "Old"]),
            attentionEvent("permission.requested", agent: "waiting", data: ["requestId": "pending"])
        ] { reducer.consume(row) }
        let observed = reducer.value()
        reducer.consume(try attentionEvent("subagent.future_lifecycle", agent: "worker"))
        #expect(reducer.value().children.first { $0.id == "worker" }?.state == .unknown)
        #expect(reducer.value().children.first { $0.id == "worker" }?.terminalEvent == nil)
        #expect(reducer.value().children.first { $0.id == "worker" }?.attention
            == observed.children.first { $0.id == "worker" }?.attention)
        #expect(reducer.value().children.first { $0.id == "waiting" }?.state == .blocked)
        reducer.consume(try attentionEvent("subagent.started", agent: "worker", data: [
            "toolCallId": "fresh", "agentDisplayName": "Fresh"
        ]))
        #expect(reducer.value().children.first { $0.id == "worker" }?.state == .working)
        #expect(reducer.value().children.first { $0.id == "worker" }?.attention == [])
        #expect(reducer.value().children.first { $0.id == "waiting" }?.state == .blocked)
    }

    @Test(arguments: [false, true])
    func coldToolActivityFailsTerminalHistoryOpenButPreservesLiveBlockingOwner(live: Bool) throws {
        var reducer = CopilotEventReducer(
            sessionID: UUID(), maximumRelationships: 2, maximumReplayFilterWords: 1
        )
        for row in try [
            attentionEvent("subagent.started", agent: "worker", data: ["toolCallId": "spawn-a", "agentDisplayName": "A"]),
            attentionEvent("subagent.completed", data: ["toolCallId": "spawn-a", "agentDisplayName": "A"])
        ] + copilotTestColdStartPressure() { reducer.consume(row) }
        if live {
            reducer.consume(try attentionEvent("subagent.started", agent: "worker", data: [
                "toolCallId": "spawn-b", "agentDisplayName": "B"
            ]))
            reducer.consume(try attentionEvent("permission.requested", agent: "worker", data: ["requestId": "current"]))
        }
        let before = reducer.value()
        reducer.consume(try attentionEvent("tool.execution_start", agent: "worker", data: [
            "toolCallId": "fresh-shell-50", "toolName": "view"
        ]))
        #expect(reducer.issues == [.readLimitReached])
        if live {
            #expect(reducer.value() == before)
            #expect(reducer.retentionCounts.requests == 1)
        } else {
            #expect(reducer.value().children.first?.state == .unknown)
            #expect(reducer.value().children.first?.terminalEvent == nil)
            #expect(reducer.value().children.first?.activity == nil)
            #expect(reducer.value().state == before.state)
        }
    }

    @Test func lateToolMetadataCannotTurnCompletedSpawnIntoFreshOwnerActivity() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        for row in try [
            attentionEvent("assistant.turn_start", data: ["turnId": "main"]),
            attentionEvent("subagent.started", agent: "child", data: ["toolCallId": "spawn", "agentDisplayName": "Child"]),
            attentionEvent("subagent.completed", data: ["toolCallId": "spawn", "agentDisplayName": "Child"]),
            attentionEvent("assistant.turn_end", data: ["turnId": "main"])
        ] { reducer.consume(row) }
        let finished = reducer.value()
        #expect(finished.attention.map(\.kind) == [.turnFinished])
        reducer.consume(try attentionEvent("tool.execution_start", data: ["toolCallId": "spawn", "toolName": "task"]))
        #expect(reducer.value() == finished)
        #expect(reducer.retentionCounts.owners == 0)
    }

    @Test func unmatchedToolCompletionCannotLaterReappearAsExecutingActivity() throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumRelationships: 2)
        reducer.consume(try attentionEvent("tool.execution_complete", agent: "child", data: [
            "toolCallId": "old", "success": false
        ]))
        let unknown = reducer.value()
        reducer.consume(try attentionEvent("tool.execution_start", agent: "child", data: [
            "toolCallId": "old", "toolName": "view"
        ]))
        #expect(reducer.value() == unknown)
        #expect(reducer.retentionCounts.owners == 0)
        #expect(reducer.value().children.isEmpty)
    }

    @Test func finishedHistoryReclaimsSignalsAndJoinsBeforeFreshBlockingWork() throws {
        let session = UUID()
        var reducer = CopilotEventReducer(
            sessionID: session, maximumWorkItems: 4, maximumRelationships: 8, maximumLifecycleEvents: 8
        )
        var rebuilt = CopilotEventReducer(
            sessionID: session, maximumWorkItems: 4, maximumRelationships: 8, maximumLifecycleEvents: 8
        )
        var rows = [try attentionEvent("assistant.turn_start", data: ["turnId": "main"])]
        for index in 0..<128 {
            let owner = "worker-\(index)"
            let spawn = "spawn-\(index)"
            let tool = "view-\(index)"
            rows += try [
                attentionEvent("tool.execution_start", data: ["toolCallId": spawn, "toolName": "task"]),
                attentionEvent("subagent.started", agent: owner, data: [
                    "toolCallId": spawn, "agentDisplayName": "Worker"
                ]),
                attentionEvent("assistant.turn_start", agent: owner, data: ["turnId": "turn-\(index)"]),
                attentionEvent("tool.execution_start", agent: owner, data: ["toolCallId": tool, "toolName": "view"]),
                attentionEvent("permission.requested", agent: owner, data: ["requestId": "request-\(index)"]),
                attentionEvent("permission.completed", agent: owner, data: ["requestId": "request-\(index)"]),
                attentionEvent("tool.execution_complete", agent: owner, data: ["toolCallId": tool, "success": true]),
                attentionEvent("subagent.completed", data: ["toolCallId": spawn, "agentDisplayName": "Worker"]),
                attentionEvent("tool.execution_complete", data: ["toolCallId": spawn, "success": true])
            ]
        }
        rows += try [
            attentionEvent("subagent.started", agent: "fresh", data: [
                "toolCallId": "fresh", "agentDisplayName": "Fresh", "parentId": "root"
            ]),
            attentionEvent("permission.requested", agent: "fresh", data: ["requestId": "approval"])
        ]
        for row in rows {
            reducer.consume(row)
            rebuilt.consume(row)
            let counts = reducer.retentionCounts
            #expect(counts.work <= 4 && counts.owners <= 8 && counts.agents <= 4)
            #expect(counts.turns <= counts.work + 1)
            #expect(counts.outcomes <= counts.work + 2)
            #expect(counts.activities <= counts.work + 1)
            #expect(counts.requests <= 8 && counts.tombstones <= 8 && counts.events <= 8)
            #expect(counts.replayWords <= 16_384 && counts.eventReplayWords <= 16_384)
        }
        #expect(reducer.value() == rebuilt.value())
        #expect(reducer.issues.isEmpty)
        let fresh = try #require(reducer.value().children.first { $0.id == "fresh" })
        #expect(fresh.state == .blocked)
        #expect(fresh.attention?.map(\.kind) == [.permission])
        #expect(fresh.terminalEvent == nil)
        let accepted = reducer.value()
        for row in try [
            attentionEvent("tool.execution_start", data: ["toolCallId": "spawn-0", "toolName": "task"]),
            attentionEvent("permission.requested", agent: "worker-0", data: ["requestId": "request-0"]),
            attentionEvent("subagent.started", agent: "worker-0", data: [
                "toolCallId": "spawn-0", "agentDisplayName": "Worker"
            ])
        ] { reducer.consume(row) }
        #expect(reducer.value() == accepted)
        #expect(reducer.issues == [.readLimitReached])
    }

    @Test func outstandingOutcomeAndPendingAncestryCannotBeRetiredByHistoryPressure() throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumWorkItems: 4, maximumRelationships: 8)
        for row in try [
            attentionEvent("assistant.turn_start", data: ["turnId": "main"]),
            attentionEvent("subagent.started", agent: "failed", data: ["toolCallId": "failed", "agentDisplayName": "Failed"]),
            attentionEvent("subagent.failed", data: ["toolCallId": "failed", "agentDisplayName": "Failed"]),
            attentionEvent("subagent.started", agent: "parent", data: ["toolCallId": "parent", "agentDisplayName": "Parent"]),
            attentionEvent("subagent.completed", data: ["toolCallId": "parent", "agentDisplayName": "Parent"]),
            attentionEvent("subagent.started", agent: "waiting", data: [
                "toolCallId": "waiting", "agentDisplayName": "Waiting", "parentId": "parent"
            ]),
            attentionEvent("permission.requested", agent: "waiting", data: ["requestId": "approval"]),
            attentionEvent("subagent.started", agent: "spare", data: ["toolCallId": "spare", "agentDisplayName": "Spare"]),
            attentionEvent("subagent.completed", data: ["toolCallId": "spare", "agentDisplayName": "Spare"]),
            attentionEvent("skill.invoked", data: ["name": "unknown-lifetime"])
        ] { reducer.consume(row) }
        let protected = reducer.value()
        #expect(protected.children.count == 4)
        #expect(!protected.children.contains { $0.id == "spare" })
        #expect(protected.children.first { $0.id == "failed" }?.attention?.map(\.kind) == [.error])
        #expect(protected.children.first { $0.id == "waiting" }?.state == .blocked)
        #expect(protected.children.first { $0.id == "parent" }?.state == .completed)
        reducer.consume(try attentionEvent("subagent.started", agent: "overflow", data: [
            "toolCallId": "overflow", "agentDisplayName": "Overflow"
        ]))
        #expect(reducer.value() == protected)
        #expect(reducer.issues == [.readLimitReached])
        reducer.consume(try attentionEvent("assistant.turn_start", data: ["turnId": "next-cycle"]))
        reducer.consume(try attentionEvent("subagent.started", agent: "fresh", data: [
            "toolCallId": "fresh", "agentDisplayName": "Fresh"
        ]))
        let next = reducer.value()
        #expect(!next.children.contains { $0.id == "failed" })
        #expect(next.children.contains { $0.id == "fresh" })
        #expect(next.children.first { $0.id == "waiting" }?.state == .blocked)
        #expect(next.children.first { $0.id == "waiting" }?.parentID == "parent")
        #expect(next.children.contains { $0.kind == .skill && $0.state == .unknown })
    }

    @Test func retiredRequestPlaceholderDoesNotPermanentlyTombstoneItsAgentID() throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumWorkItems: 1, maximumRelationships: 4)
        for row in try [
            attentionEvent("permission.requested", agent: "worker", data: ["requestId": "old"]),
            attentionEvent("permission.completed", agent: "worker", data: ["requestId": "old"]),
            attentionEvent("abort", agent: "worker"),
            attentionEvent("assistant.turn_start", data: ["turnId": "next"]),
            attentionEvent("system.notification", data: [
                "kind": ["type": "shell_completed", "shellId": "retire-worker", "exitCode": 0]
            ])
        ] { reducer.consume(row) }
        #expect(!reducer.value().children.contains { $0.id == "worker" })
        reducer.consume(try attentionEvent("permission.requested", agent: "worker", data: ["requestId": "fresh"]))
        let fresh = try #require(reducer.value().children.first { $0.id == "worker" })
        #expect(fresh.kind == .unknown && fresh.state == .blocked)
        #expect(fresh.attention?.map(\.kind) == [.permission])
        #expect(reducer.issues.isEmpty)
        reducer.consume(try attentionEvent("permission.requested", agent: "worker", data: ["requestId": "old"]))
        #expect(reducer.value().children.first == fresh)
    }

    @Test func spilledResolvedRequestsRetainOwnerAndKindNamespaces() throws {
        var reducer = CopilotEventReducer(
            sessionID: UUID(), maximumWorkItems: 3, maximumRelationships: 8, maximumLifecycleEvents: 8
        )
        for owner: String? in [nil, "worker", "sibling"] {
            for row in try [
                attentionEvent("assistant.turn_start", agent: owner, data: ["turnId": "shared"]),
                attentionEvent("permission.requested", agent: owner, data: ["requestId": "shared"]),
                attentionEvent("user_input.requested", agent: owner, data: ["requestId": "shared"])
            ] { reducer.consume(row) }
        }
        for index in 0..<128 {
            reducer.consume(try attentionEvent("permission.completed", data: ["requestId": "old-\(index)"]))
        }
        #expect(reducer.retentionCounts.requests == 6)
        #expect(reducer.retentionCounts.tombstones <= 8 && reducer.retentionCounts.events <= 8)
        let blocked = reducer.value()
        reducer.consume(try attentionEvent("permission.requested", data: ["requestId": "old-0"]))
        #expect(reducer.value() == blocked)
        reducer.consume(try attentionEvent("permission.completed", agent: "worker", data: ["requestId": "shared"]))
        #expect(reducer.value().attention.map(\.kind) == [.answer, .permission])
        #expect(reducer.value().children.first { $0.id == "worker" }?.attention?.map(\.kind) == [.answer])
        #expect(reducer.value().children.first { $0.id == "sibling" }?.attention?.count == 2)
        reducer.consume(try attentionEvent("permission.requested", agent: "worker", data: ["requestId": "old-0"]))
        reducer.consume(try attentionEvent("user_input.requested", data: ["requestId": "old-0"]))
        #expect(reducer.retentionCounts.requests == 7)
        #expect(reducer.value().state == .blocked)
        #expect(reducer.value().children.first { $0.id == "worker" }?.attention?.count == 2)
    }
}

nonisolated func copilotSelectiveShellAliasWitness(live: Bool = false) {
    var replay = CopilotReplayGuard(capacity: 2, wordCount: 1)
    var keys = ["subagent:spawn-a"] + (0..<4).map { "turn:0::noise-\($0)" }
    if live { keys += ["subagent:spawn-b", "tool:spawn-a"] }
    for key in keys {
        let remembered = replay.remember(key)
        #expect(remembered)
    }
    #expect(replay.occupiedBits == (live ? 29 : 18))
    #expect(replay.occupiedBits < 32)
    #expect(replay.match("start-tool:fresh-owner-31") == .absent)
    #expect(replay.match("tool:fresh-owner-31") == .absent)
    #expect(replay.match("work:shell:fresh-owner-31") == .uncertain)
    #expect(replay.match("request:6:worker:permission:current") == .absent)
    #expect(replay.match("request:6:worker:answer:second") == .absent)
}
