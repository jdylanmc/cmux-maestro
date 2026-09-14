import Foundation
import Testing
@testable import CMUXMaestroPreview

@Suite(.serialized)
nonisolated struct CopilotInteractionTests {
    @Test func unjoinedShellNotificationCannotProveCurrentPrimaryTurnCompletion() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let a = UUID(), b = UUID(), notification = UUID()
        reducer.consume(try interactionEvent("assistant.turn_start", id: a, turn: "0", interaction: "A"))
        reducer.consume(try interactionEvent("assistant.turn_end", parent: a, turn: "0"))
        reducer.consume(try interactionEvent("assistant.turn_start", id: b, turn: "0", interaction: "B"))
        reducer.consume(try interactionEvent("system.notification", id: notification, parent: b, data: [
            "kind": ["type": "shell_completed", "shellId": "unjoined", "exitCode": 0]
        ]))
        #expect(reducer.value().children.first?.state == .completed)
        reducer.consume(try interactionEvent("assistant.turn_end", parent: notification, turn: "0"))
        #expect(reducer.value().state == .unknown)
        #expect(reducer.value().attention.isEmpty)
    }

    @Test func oldSubagentToolAssociationCannotUseGenericParentFallback() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let a = UUID(), b = UUID(), childEnd = UUID()
        reducer.consume(try interactionEvent("assistant.turn_start", id: a, turn: "0", interaction: "A"))
        reducer.consume(try interactionEvent("tool.execution_start", parent: a,
                                             data: ["toolCallId": "spawn", "toolName": "task"]))
        reducer.consume(try interactionEvent("subagent.started", owner: "child",
                                             data: ["toolCallId": "spawn", "agentDisplayName": "Child"]))
        reducer.consume(try interactionEvent("assistant.turn_start", id: b, turn: "0", interaction: "B"))
        reducer.consume(try interactionEvent("subagent.completed", id: childEnd, parent: b,
                                             data: ["toolCallId": "spawn", "agentDisplayName": "Child"]))
        #expect(reducer.value().children.first?.state == .completed)
        #expect(reducer.value().state == .working)
        reducer.consume(try interactionEvent("assistant.turn_end", parent: childEnd, turn: "0"))
        #expect(reducer.value().state == .unknown)
        #expect(reducer.value().attention.isEmpty)
    }

    @Test(arguments: ["tool.execution_complete", "tool.execution_partial_result"], [false, true])
    func oldToolProvenanceCannotBeOverriddenByCurrentParent(type: String, turnTag: Bool) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let a = UUID(), b = UUID(), toolEvent = UUID()
        reducer.consume(try interactionEvent("assistant.turn_start", id: a, turn: "0", interaction: "A"))
        reducer.consume(try interactionEvent("tool.execution_start", parent: a,
                                             data: ["toolCallId": "old", "toolName": "view"]))
        reducer.consume(try interactionEvent("assistant.turn_start", id: b, turn: "0", interaction: "B"))
        let working = reducer.value()
        reducer.consume(try interactionEvent(type, id: toolEvent, parent: b,
                                             turn: turnTag ? "0" : nil,
                                             data: ["toolCallId": "old", "success": true,
                                                    "partialOutput": "PRIVATE_OLD_OUTPUT"]))
        #expect(reducer.value() == working)
        reducer.consume(try interactionEvent("permission.requested", data: ["requestId": "pending-b"]))
        let permission = reducer.value().attention
        reducer.consume(try interactionEvent("assistant.turn_end", parent: toolEvent, turn: "0"))
        #expect(reducer.value().state == .blocked)
        #expect(reducer.value().attention == permission)
        #expect(reducer.issues == [.ambiguousTurn])
        #expect(reducer.retentionCounts.requests == 1)
    }

    @Test(arguments: ["tool.execution_complete", "tool.execution_partial_result"])
    func currentToolOriginStillAnchorsAndExactOldEventsDoNotAffectNextInteraction(type: String) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let a = UUID(), b = UUID(), toolEventID = UUID(), endID = UUID()
        reducer.consume(try interactionEvent("assistant.turn_start", id: a, turn: "0", interaction: "A"))
        reducer.consume(try interactionEvent("assistant.turn_end", parent: a, turn: "0"))
        reducer.consume(try interactionEvent("assistant.turn_start", id: b, turn: "0", interaction: "B"))
        reducer.consume(try interactionEvent("tool.execution_start", parent: b,
                                             data: ["toolCallId": "current", "toolName": "view"]))
        let toolEvent = try interactionEvent(type, id: toolEventID, parent: UUID(),
                                             data: ["toolCallId": "current", "success": true,
                                                    "partialOutput": "PRIVATE_CURRENT_OUTPUT"])
        reducer.consume(toolEvent)
        let end = try interactionEvent("assistant.turn_end", id: endID, parent: toolEventID, turn: "0")
        reducer.consume(end)
        #expect(reducer.value().state == .idle)
        #expect(reducer.value().attention.last?.evidence.eventID == endID)
        reducer.consume(try interactionEvent("assistant.turn_start", turn: "0", interaction: "C"))
        let current = reducer.value()
        reducer.consume(toolEvent)
        reducer.consume(end)
        #expect(reducer.value() == current)
        #expect(reducer.issues.isEmpty)
    }

    @Test(arguments: [false, true])
    func partialResultNeedsKnownCurrentToolOriginEvenWhenParentIsCurrent(knownID: Bool) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let a = UUID(), b = UUID(), partial = UUID()
        reducer.consume(try interactionEvent("assistant.turn_start", id: a, turn: "0", interaction: "A"))
        reducer.consume(try interactionEvent("assistant.turn_end", parent: a, turn: "0"))
        reducer.consume(try interactionEvent("assistant.turn_start", id: b, turn: "0", interaction: "B"))
        var data: [String: Any] = ["partialOutput": "PRIVATE_OUTPUT"]
        if knownID {
            reducer.consume(try interactionEvent("tool.execution_start", parent: UUID(),
                                                 data: ["toolCallId": "unproven", "toolName": "view"]))
            data["toolCallId"] = "unproven"
        }
        reducer.consume(try interactionEvent("tool.execution_partial_result", id: partial, parent: b, data: data))
        reducer.consume(try interactionEvent("assistant.turn_end", parent: partial, turn: "0"))
        #expect(reducer.value().state == .unknown)
        #expect(reducer.value().attention.isEmpty)
        #expect(reducer.issues == [.ambiguousTurn])
    }

    @Test func validOldToolTagsCannotAnchorCurrentInteractionThroughAConflictingParent() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let a = UUID(), b = UUID(), oldEnd = UUID()
        reducer.consume(try interactionEvent("assistant.turn_start", id: a, turn: "0", interaction: "A"))
        reducer.consume(try interactionEvent("tool.execution_start", parent: a,
                                             data: ["toolCallId": "old", "toolName": "view"]))
        reducer.consume(try interactionEvent("assistant.turn_start", id: b, turn: "0", interaction: "B"))
        let before = reducer.value()
        reducer.consume(try interactionEvent("tool.execution_complete", id: oldEnd, parent: b,
                                             turn: "0", interaction: "A",
                                             data: ["toolCallId": "old", "success": true]))
        #expect(reducer.value() == before)
        reducer.consume(try interactionEvent("assistant.turn_end", parent: oldEnd, turn: "0"))
        #expect(reducer.value().state == .unknown)
        #expect(reducer.value().attention.isEmpty)
    }

    @Test func knownToolWithoutOriginCannotAcquireProvenanceFromCompletionParent() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let a = UUID(), b = UUID(), wrong = UUID(), right = UUID()
        reducer.consume(try interactionEvent("assistant.turn_start", id: a, turn: "0", interaction: "A"))
        reducer.consume(try interactionEvent("assistant.turn_end", parent: a, turn: "0"))
        reducer.consume(try interactionEvent("assistant.turn_start", id: b, turn: "0", interaction: "B"))
        reducer.consume(try interactionEvent("tool.execution_start", parent: UUID(),
                                             data: ["toolCallId": "tool", "toolName": "view"]))
        let before = reducer.value()
        reducer.consume(try interactionEvent("tool.execution_complete", id: wrong, parent: b,
                                             turn: "0", interaction: "A",
                                             data: ["toolCallId": "tool", "success": false]))
        #expect(reducer.value() == before)
        reducer.consume(try interactionEvent("tool.execution_complete", id: right, parent: b,
                                             turn: "0", interaction: "B",
                                             data: ["toolCallId": "tool", "success": true]))
        reducer.consume(try interactionEvent("assistant.turn_end", parent: right, turn: "0"))
        #expect(reducer.value().state == .unknown)
        #expect(reducer.value().attention.isEmpty)
        #expect(reducer.issues == [.ambiguousTurn])
    }

    @Test(arguments: ["interaction", "turn"], [nil, "child"] as [String?])
    func contradictoryToolCompletionTagsCannotChangeCurrentWorkOrAnchorItsEnd(
        mismatch: String, owner: String?
    ) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let a = UUID(), b = UUID(), toolStart = UUID(), wrongEnd = UUID(), correctEnd = UUID()
        for row in try [
            interactionEvent("assistant.turn_start", id: a, owner: owner, turn: "0", interaction: "A"),
            interactionEvent("assistant.turn_end", parent: a, owner: owner, turn: "0"),
            interactionEvent("assistant.turn_start", id: b, owner: owner, turn: "0", interaction: "B"),
            interactionEvent("permission.requested", owner: owner, data: ["requestId": "pending"]),
            interactionEvent("tool.execution_start", id: toolStart, parent: b, owner: owner,
                             data: ["toolCallId": "tool", "toolName": "view"])
        ] { reducer.consume(row) }
        let before = reducer.value()
        reducer.consume(try interactionEvent("tool.execution_complete", id: wrongEnd, parent: toolStart,
                                             owner: owner, turn: mismatch == "turn" ? "1" : "0",
                                             interaction: mismatch == "interaction" ? "A" : "B",
                                             data: ["toolCallId": "tool", "success": false]))
        #expect(reducer.value() == before)
        reducer.consume(try interactionEvent("assistant.turn_end", parent: wrongEnd, owner: owner, turn: "0"))
        #expect(reducer.issues == [.ambiguousTurn])
        #expect(reducer.retentionCounts.requests == 1)
        #expect(reducer.value().attention.allSatisfy { $0.kind != .turnFinished })
        reducer.consume(try interactionEvent("tool.execution_complete", id: correctEnd, parent: toolStart,
                                             owner: owner, turn: "0", interaction: "B",
                                             data: ["toolCallId": "tool", "success": true]))
        reducer.consume(try interactionEvent("assistant.turn_end", parent: correctEnd, owner: owner, turn: "0"))
        reducer.consume(try interactionEvent("permission.completed", owner: owner, data: ["requestId": "pending"]))
        if let owner {
            #expect(reducer.value().children.first { $0.id == owner }?.state == .idle)
        } else {
            #expect(reducer.value().state == .idle)
            #expect(reducer.value().attention.map(\.kind) == [.turnFinished])
        }
    }

    @Test(arguments: ["both", "interaction-only", "turn-only", "nil"])
    func matchingOptionalToolCompletionTagsKeepExistingOriginAnchoring(fields: String) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let a = UUID(), b = UUID(), toolStart = UUID(), toolEnd = UUID(), end = UUID()
        for row in try [
            interactionEvent("assistant.turn_start", id: a, turn: "0", interaction: "A"),
            interactionEvent("assistant.turn_end", parent: a, turn: "0"),
            interactionEvent("assistant.turn_start", id: b, turn: "0", interaction: "B"),
            interactionEvent("tool.execution_start", id: toolStart, parent: b,
                             data: ["toolCallId": "tool", "toolName": "view"])
        ] { reducer.consume(row) }
        var data: [String: Any] = ["toolCallId": "tool", "success": true]
        data["interactionId"] = fields == "both" || fields == "interaction-only" ? "B" : NSNull()
        data["turnId"] = fields == "both" || fields == "turn-only" ? "0" : NSNull()
        reducer.consume(try interactionEvent("tool.execution_complete", id: toolEnd, parent: UUID(), data: data))
        reducer.consume(try interactionEvent("assistant.turn_end", id: end, parent: toolEnd, turn: "0"))
        #expect(reducer.value().state == .idle)
        #expect(reducer.value().attention.last?.evidence.eventID == end)
        #expect(reducer.issues.isEmpty)
    }

    @Test(arguments: [false, true])
    func explicitToolTagsAloneCannotCreateMissingOwnershipOrCausalProof(knownTool: Bool) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let a = UUID(), b = UUID(), toolEnd = UUID()
        reducer.consume(try interactionEvent("assistant.turn_start", id: a, turn: "0", interaction: "A"))
        reducer.consume(try interactionEvent("assistant.turn_end", parent: a, turn: "0"))
        reducer.consume(try interactionEvent("assistant.turn_start", id: b, turn: "0", interaction: "B"))
        if knownTool {
            reducer.consume(try interactionEvent("tool.execution_start", parent: UUID(),
                                                 data: ["toolCallId": "tool", "toolName": "view"]))
        }
        reducer.consume(try interactionEvent("tool.execution_complete", id: toolEnd,
                                             parent: knownTool ? UUID() : b, turn: "0", interaction: "B",
                                             data: ["toolCallId": "tool", "success": true]))
        reducer.consume(try interactionEvent("assistant.turn_end", parent: toolEnd, turn: "0"))
        #expect(reducer.value().state == .unknown)
        #expect(reducer.value().attention.isEmpty)
        #expect(reducer.issues == [.ambiguousTurn])
    }

    @Test func invalidToolCompletionTagsCannotFallBackToUntypedCompletion() throws {
        for field in ["interactionId", "turnId"] {
            for invalid: Any in ["", String(repeating: "x", count: 257), "bad\nid", 12, ["value"]] {
                var reducer = CopilotEventReducer(sessionID: UUID())
                let start = UUID()
                reducer.consume(try interactionEvent("assistant.turn_start", id: start, turn: "0", interaction: "A"))
                reducer.consume(try interactionEvent("tool.execution_start", parent: start,
                                                     data: ["toolCallId": "tool", "toolName": "view"]))
                let before = reducer.value()
                reducer.consume(try interactionEvent("tool.execution_complete", data: [
                    "toolCallId": "tool", "success": true, field: invalid
                ]))
                #expect(reducer.value() == before)
                #expect(reducer.issues == [.malformedData])
                #expect(!reducer.canPublishProjection)
            }
        }
    }

    @Test func interactionReplaySaturationDoesNotResetBackgroundOwners() throws {
        var reducer = CopilotEventReducer(
            sessionID: UUID(), maximumRelationships: 8, maximumLifecycleEvents: 8, maximumReplayFilterWords: 1
        )
        reducer.consume(try attentionEvent("subagent.started", agent: "background", data: [
            "toolCallId": "background", "agentDisplayName": "Background"
        ]))
        reducer.consume(try attentionEvent("permission.requested", agent: "waiting", data: ["requestId": "waiting"]))
        for index in 0..<128 {
            reducer.consume(try interactionEvent("assistant.turn_start", turn: "0", interaction: "scope-\(index)"))
            #expect(reducer.value().children.first { $0.id == "background" }?.state == .working)
            #expect(reducer.value().children.first { $0.id == "waiting" }?.state == .blocked)
            #expect(reducer.retentionCounts.requests == 1)
            #expect(reducer.retentionCounts.interactionOwners <= reducer.retentionCounts.work + 1)
        }
        #expect(reducer.issues.contains(.readLimitReached))
        #expect(reducer.value().state != .completed)
        #expect(reducer.value().attention.isEmpty)
        #expect(reducer.retentionCounts.replayWords == 1)
        #expect(reducer.canPublishProjection)
    }

    @Test(arguments: ["session.error", "abort"])
    func fatalPrimaryOutcomeRemainsDistinctFromNormalToolFailureCompletion(type: String) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        reducer.consume(try interactionEvent("assistant.turn_start", turn: "0", interaction: "A"))
        reducer.consume(try interactionEvent(type))
        reducer.consume(try interactionEvent("assistant.turn_end", turn: "0", interaction: "A"))
        #expect(reducer.value().state == (type == "abort" ? .cancelled : .failed))
        #expect(reducer.value().attention.map(\.kind) == [type == "abort" ? .aborted : .error])
        reducer.consume(try interactionEvent("assistant.turn_start", turn: "0", interaction: "B"))
        #expect(reducer.value().state == .working)
        #expect(reducer.value().attention.isEmpty)
    }

    @Test @MainActor
    func readerPublishesInteractionOutcomesAndAmbiguityWithoutReusingOldAcknowledgements() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_789_214_500)
        let reader = fixture.reader(clock: { now })
        let a = UUID(), aEnd = UUID(), b = UUID(), bEnd = UUID(), c = UUID(), cEnd = UUID()
        try fixture.writeEvents([
            attentionEvent("subagent.started", agent: "background", data: [
                "toolCallId": "background", "agentDisplayName": "Background"
            ]),
            interactionEvent("assistant.turn_start", id: a, at: now.addingTimeInterval(-40),
                             turn: "0", interaction: "A"),
            interactionEvent("assistant.turn_end", id: aEnd, parent: a, at: now.addingTimeInterval(-39), turn: "0")
        ])
        let first = try await reader.read(surfaceIDs: [fixture.surface])
        let firstTree = interactionTree(first, fixture: fixture)
        let acknowledgedA = SidebarAttentionSettings(acknowledged: firstTree.acknowledgeableOutcomes)
        #expect(acknowledgedA.acknowledged.count == 1)
        #expect(interactionTree(first, fixture: fixture, attention: acknowledgedA).attentionOwnerCount == 0)
        for row in try [
            interactionEvent("assistant.turn_start", id: b, at: now.addingTimeInterval(-30),
                             turn: "0", interaction: "B"),
            interactionEvent("assistant.turn_end", id: bEnd, parent: b, at: now.addingTimeInterval(-29), turn: "0")
        ] { try fixture.append(row + Data([10])) }
        let second = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(second.isComplete)
        #expect(second.sessions.first?.state == .idle)
        let secondTree = interactionTree(second, fixture: fixture, attention: acknowledgedA)
        #expect(secondTree.attentionOwnerCount == 1)
        #expect(secondTree.sessions.first?.attention.last?.evidence.eventID == bEnd)
        for row in try [
            interactionEvent("assistant.turn_start", id: c, at: now.addingTimeInterval(-20),
                             turn: "0", interaction: "C"),
            interactionEvent("assistant.turn_end", parent: a, at: now.addingTimeInterval(-19), turn: "0")
        ] { try fixture.append(row + Data([10])) }
        let uncertain = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(uncertain.issues == [.ambiguousTurn])
        #expect(uncertain.sessions.first?.state == .unknown)
        #expect(uncertain.sessions.first?.attention == [])
        #expect(uncertain.sessions.first?.children.first?.state == .working)
        #expect(interactionTree(uncertain, fixture: fixture).availability == .partial)
        for row in try [
            interactionEvent("permission.requested", at: now.addingTimeInterval(-18), data: ["requestId": "permission"]),
            interactionEvent("permission.completed", at: now.addingTimeInterval(-17), data: ["requestId": "permission"]),
            interactionEvent("assistant.turn_end", id: cEnd, parent: c, at: now.addingTimeInterval(-16), turn: "0")
        ] { try fixture.append(row + Data([10])) }
        let recovered = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(recovered.sessions.first?.state == .idle)
        #expect(recovered.sessions.first?.attention?.last?.evidence.eventID == cEnd)
        #expect(interactionTree(recovered, fixture: fixture, attention: acknowledgedA).attentionOwnerCount == 1)
        let rebuilt = try await fixture.reader(clock: { now }).read(surfaceIDs: [fixture.surface])
        #expect(rebuilt == recovered)
    }

    @Test func scopedTurnColdCollisionRetainsTerminalFailOpenAndBoundedKeys() throws {
        let keys = ["interaction-raw-turn:6:worker:0", "interaction-turn:6:worker:1:A:0"]
            + (0..<4).map { "turn:0::noise-\($0)" }
        var witness = CopilotReplayGuard(capacity: 2, wordCount: 1)
        for key in keys {
            let remembered = witness.remember(key)
            #expect(remembered)
        }
        #expect(witness.occupiedBits == 24 && witness.occupiedBits < 32)
        #expect(witness.match("interaction-turn:6:worker:9:fresh-236:0") == .uncertain)
        #expect(witness.match("retired-interaction:6:worker:fresh-236") == .absent)
        var reducer = CopilotEventReducer(
            sessionID: UUID(), maximumRelationships: 2, maximumReplayFilterWords: 1
        )
        reducer.consume(try interactionEvent("assistant.turn_start", owner: "worker", turn: "0", interaction: "A"))
        reducer.consume(try interactionEvent("abort", owner: "worker"))
        for index in 0..<4 {
            reducer.consume(try interactionEvent("assistant.turn_start", turn: "noise-\(index)"))
        }
        #expect(reducer.value().children.first?.state == .cancelled)
        reducer.consume(try interactionEvent("assistant.turn_start", owner: "worker",
                                             turn: "0", interaction: "fresh-236"))
        #expect(reducer.value().children.first?.state == .unknown)
        #expect(reducer.value().children.first?.terminalEvent == nil)
        #expect(reducer.issues == [.readLimitReached])
        #expect(reducer.retentionCounts.tombstones <= 2)
        #expect(reducer.retentionCounts.replayWords == 1)
        #expect(reducer.canPublishProjection)
    }

    @Test func retiredStartsAndExactOldEndsCannotChangeCurrentOwnerOrBackgroundRequests() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let a = UUID()
        let oldStart = try interactionEvent("assistant.turn_start", id: a, turn: "0", interaction: "A")
        let oldEnd = try interactionEvent("assistant.turn_end", parent: a, turn: "0")
        reducer.consume(oldStart)
        reducer.consume(oldEnd)
        let b = UUID()
        reducer.consume(try interactionEvent("assistant.turn_start", id: b, turn: "0", interaction: "B"))
        reducer.consume(try interactionEvent("assistant.turn_start", owner: "child", turn: "0", interaction: "child"))
        reducer.consume(try interactionEvent("permission.requested", owner: "child", data: ["requestId": "child"]))
        reducer.consume(try interactionEvent("permission.requested", data: ["requestId": "root"]))
        let current = reducer.value()
        for row in try [
            oldStart, oldEnd,
            interactionEvent("assistant.turn_start", turn: "0", interaction: "A"),
            interactionEvent("assistant.turn_start", turn: "never-seen", interaction: "A"),
            interactionEvent("assistant.turn_end", parent: b, turn: "0", interaction: "A"),
            interactionEvent("assistant.turn_end", parent: b, owner: "child", turn: "0", interaction: "B")
        ] {
            reducer.consume(row)
            #expect(reducer.value() == current)
        }
        #expect(reducer.retentionCounts.requests == 2)
        #expect(reducer.issues.isEmpty)
        reducer.consume(try interactionEvent("permission.completed", data: ["requestId": "root"]))
        reducer.consume(try interactionEvent("assistant.turn_end", parent: b, turn: "0"))
        #expect(reducer.value().state == .idle)
        #expect(reducer.value().attention.map(\.kind) == [.turnFinished])
        #expect(reducer.value().children.first?.state == .blocked)
    }

    @Test(arguments: ["explicit", "linked", "missing-link", "old-parent", "wrong-interaction"])
    func reusedNilEndRequiresCurrentEvidenceAndContradictoryClocksDoNotInventAge(proof: String) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let date = Date(timeIntervalSince1970: 1_789_214_400)
        let a = UUID()
        reducer.consume(try interactionEvent("assistant.turn_start", id: a, at: date, turn: "0", interaction: "A"))
        reducer.consume(try interactionEvent("assistant.turn_end", parent: a, at: date.addingTimeInterval(1), turn: "0"))
        let b = UUID()
        reducer.consume(try interactionEvent("assistant.turn_start", id: b, at: date.addingTimeInterval(10),
                                             turn: "0", interaction: "B"))
        let endID = UUID()
        let parent: UUID? = proof == "linked" ? b : proof == "old-parent" ? a : nil
        let interaction: String? = proof == "explicit" ? "B" : proof == "wrong-interaction" ? "A" : nil
        reducer.consume(try interactionEvent("assistant.turn_end", id: endID, parent: parent,
                                             at: date.addingTimeInterval(5), turn: "0", interaction: interaction))
        if proof == "explicit" || proof == "linked" {
            #expect(reducer.value().state == .idle)
            #expect(reducer.value().attention.last?.evidence.eventID == endID)
            #expect(reducer.value().attention.last?.occurredAt == nil)
        } else if proof == "wrong-interaction" {
            #expect(reducer.value().state == .working)
            #expect(reducer.value().attention.isEmpty)
            #expect(reducer.issues.isEmpty)
        } else {
            #expect(reducer.value().state == .unknown)
            #expect(reducer.value().attention.isEmpty)
            #expect(reducer.issues == [.ambiguousTurn])
            #expect(reducer.canPublishProjection)
            let verified = UUID()
            reducer.consume(try interactionEvent("assistant.turn_end", id: verified, parent: b,
                                                 at: date.addingTimeInterval(11), turn: "0"))
            #expect(reducer.value().state == .idle)
            #expect(reducer.value().attention.last?.evidence.eventID == verified)
        }
    }

    @Test func mismatchedEndCannotPoisonTheCurrentCausalTip() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let a = UUID(), b = UUID(), wrong = UUID()
        reducer.consume(try interactionEvent("assistant.turn_start", id: a, turn: "0", interaction: "A"))
        reducer.consume(try interactionEvent("assistant.turn_end", parent: a, turn: "0"))
        reducer.consume(try interactionEvent("assistant.turn_start", id: b, turn: "0", interaction: "B"))
        reducer.consume(try interactionEvent("assistant.turn_end", id: wrong, parent: b, turn: "0", interaction: "A"))
        #expect(reducer.value().state == .working)
        reducer.consume(try interactionEvent("assistant.turn_end", parent: wrong, turn: "0"))
        #expect(reducer.value().state == .unknown)
        #expect(reducer.value().attention.isEmpty)
    }

    @Test func ignoredPayloadEnvelopesBridgeCurrentTurnWithoutPublishingPayloadOrInteractionIDs() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let a = UUID(), b = UUID(), message = UUID()
        reducer.consume(try interactionEvent("assistant.turn_start", id: a, turn: "0", interaction: "PRIVATE_INTERACTION_A"))
        reducer.consume(try interactionEvent("assistant.turn_end", parent: a, turn: "0"))
        reducer.consume(try interactionEvent("assistant.turn_start", id: b, turn: "0", interaction: "PRIVATE_INTERACTION_B"))
        let row = try interactionEvent("assistant.message", id: message, parent: b, data: [
            "content": "PRIVATE_PAYLOAD", "arguments": ["command": "PRIVATE_ARGUMENT"],
            "interactionId": "PRIVATE_UNSELECTED_DATA"
        ])
        let projection = try JSONDecoder().decode(CopilotEventProjection.self, from: row)
        #expect(projection.parentEventID == b.uuidString)
        #expect(projection.interactionID == nil)
        reducer.consume(row)
        reducer.consume(try interactionEvent("assistant.turn_end", parent: message, turn: "0"))
        let value = reducer.value()
        #expect(value.state == .idle)
        let observation = CopilotSessionObservation(
            sessionID: reducer.sessionID, surfaceID: UUID(), launchWorkspaceID: UUID(),
            liveness: .alive, state: value.state, model: value.model, children: value.children,
            observedAt: Date(), attention: value.attention, activity: value.activity
        )
        let publicText = String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
        #expect(!publicText.contains("PRIVATE_"))
        #expect(!publicText.contains("interactionId"))
        #expect(!publicText.contains(message.uuidString))
    }

    @Test func oldToolCompletionCannotProveANewInteractionsNilEnd() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let a = UUID(), b = UUID(), oldToolStart = UUID(), oldToolEnd = UUID()
        reducer.consume(try interactionEvent("assistant.turn_start", id: a, turn: "0", interaction: "A"))
        reducer.consume(try interactionEvent("tool.execution_start", id: oldToolStart, parent: a,
                                             data: ["toolCallId": "old-tool", "toolName": "view"]))
        reducer.consume(try interactionEvent("assistant.turn_start", id: b, turn: "0", interaction: "B"))
        reducer.consume(try interactionEvent("tool.execution_complete", id: oldToolEnd, parent: oldToolStart,
                                             data: ["toolCallId": "old-tool", "success": true]))
        reducer.consume(try interactionEvent("assistant.turn_end", parent: oldToolEnd, turn: "0"))
        #expect(reducer.value().state == .unknown)
        #expect(reducer.value().attention.isEmpty)
    }

    @Test func interactionIDsAreOpaqueBoundedStringsAndInvalidValuesNeverBecomeLegacy() throws {
        for interaction in ["not-a-UUID", "contains spaces + /=", "case-SENSITIVE", "case-sensitive"] {
            var reducer = CopilotEventReducer(sessionID: UUID())
            let row = try interactionEvent("assistant.turn_start", turn: "0", interaction: interaction)
            #expect(try JSONDecoder().decode(CopilotEventProjection.self, from: row).interactionID == interaction)
            reducer.consume(row)
            reducer.consume(try interactionEvent("assistant.turn_end", turn: "0", interaction: interaction))
            #expect(reducer.value().state == .idle)
            #expect(reducer.value().attention.map(\.kind) == [.turnFinished])
        }
        for invalid: Any in ["", String(repeating: "x", count: 257), "bad\nid", 12, ["value"]] {
            var reducer = CopilotEventReducer(sessionID: UUID())
            reducer.consume(try interactionEvent("assistant.turn_start", turn: "legacy"))
            let before = reducer.value()
            reducer.consume(try interactionEvent("assistant.turn_start", data: [
                "turnId": "0", "interactionId": invalid, "model": "unproven"
            ]))
            #expect(reducer.value() == before)
            #expect(reducer.issues == [.malformedData])
            #expect(!reducer.canPublishProjection)
        }
    }

    @Test func legacyMissingOrNullInteractionMetadataKeepsItsExistingPairing() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let first = try interactionEvent("assistant.turn_start", data: ["turnId": "old", "interactionId": NSNull()])
        reducer.consume(first)
        reducer.consume(try interactionEvent("assistant.turn_end", turn: "old"))
        #expect(reducer.value().state == .idle)
        reducer.consume(try interactionEvent("assistant.turn_start", turn: "new"))
        let working = reducer.value()
        reducer.consume(first)
        reducer.consume(try interactionEvent("assistant.turn_end", turn: "old"))
        #expect(reducer.value() == working)
        reducer.consume(try interactionEvent("assistant.turn_end", turn: "new"))
        #expect(reducer.value().state == .idle)
        #expect(reducer.issues.isEmpty)
    }

    @Test func retiredInteractionScopesSurviveResumeAndNewSpawnBoundaries() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        reducer.consume(try interactionEvent("assistant.turn_start", turn: "0", interaction: "root-A"))
        reducer.consume(try interactionEvent("assistant.turn_start", owner: "child", turn: "0", interaction: "child-A"))
        reducer.consume(try interactionEvent("session.resume"))
        reducer.consume(try interactionEvent("assistant.turn_start", turn: "0", interaction: "root-B"))
        let current = reducer.value()
        reducer.consume(try interactionEvent("assistant.turn_start", turn: "unseen", interaction: "root-A"))
        reducer.consume(try interactionEvent("assistant.turn_start", owner: "child", turn: "unseen", interaction: "child-A"))
        #expect(reducer.value() == current)

        reducer.consume(try interactionEvent("subagent.started", owner: "child", data: [
            "toolCallId": "spawn", "agentDisplayName": "Child"
        ]))
        reducer.consume(try interactionEvent("assistant.turn_start", owner: "child", turn: "0", interaction: "child-B"))
        reducer.consume(try interactionEvent("subagent.started", owner: "child", data: [
            "toolCallId": "fresh-spawn", "agentDisplayName": "New child"
        ]))
        let fresh = reducer.value()
        reducer.consume(try interactionEvent("assistant.turn_start", owner: "child", turn: "unseen", interaction: "child-B"))
        #expect(reducer.value() == fresh)
    }

    @Test func manyInteractionsRemainBoundedAndReconstructWithoutResettingBackgroundWork() throws {
        let session = UUID()
        var reducer = CopilotEventReducer(sessionID: session, maximumWorkItems: 4,
                                          maximumRelationships: 16, maximumLifecycleEvents: 8)
        var rows = [
            try interactionEvent("assistant.turn_start", owner: "child", turn: "0", interaction: "child"),
            try interactionEvent("permission.requested", owner: "child", data: ["requestId": "child"])
        ]
        for index in 0..<128 {
            for turn in ["0", "1"] {
                let id = UUID()
                rows += try [
                    interactionEvent("assistant.turn_start", id: id, turn: turn, interaction: "interaction-\(index)"),
                    interactionEvent("assistant.turn_end", parent: id, turn: turn)
                ]
            }
        }
        for row in rows {
            reducer.consume(row)
            let counts = reducer.retentionCounts
            #expect(counts.work <= 4 && counts.owners <= 16 && counts.requests <= 1)
            #expect(counts.tombstones <= 16 && counts.events <= 8)
            #expect(counts.interactionOwners <= counts.work + 1 && counts.turns <= counts.work + 1)
            #expect(counts.replayWords <= 16_384 && counts.eventReplayWords <= 16_384)
        }
        #expect(reducer.value().state == .idle)
        #expect(reducer.value().children.first?.state == .blocked)
        #expect(reducer.value().attention.map(\.kind) == [.turnFinished])
        #expect(reducer.issues.isEmpty)
        var rebuilt = CopilotEventReducer(sessionID: session, maximumWorkItems: 4,
                                          maximumRelationships: 16, maximumLifecycleEvents: 8)
        for row in rows { rebuilt.consume(row) }
        #expect(rebuilt.value() == reducer.value())
    }

    @Test func providerInteractionsReuseZeroAndOneWithoutLosingPrimaryCompletion() throws {
        let session = UUID()
        var reducer = CopilotEventReducer(sessionID: session)
        var rows: [Data] = []
        let background = try attentionEvent("subagent.started", agent: "background", data: [
            "toolCallId": "background", "agentDisplayName": "Background"
        ])
        let waiting = try attentionEvent("permission.requested", agent: "waiting", data: ["requestId": "waiting"])
        rows += [background, waiting]
        reducer.consume(background)
        reducer.consume(waiting)

        // Counter reuse and optional-end interaction metadata follow the supplied
        // real A0/A1/B0/B1/C0 packet. IDs, tool activity and causal edges are synthetic.
        let sequence = [("interaction-A", "0"), ("interaction-A", "1"),
                        ("interaction-B", "0"), ("interaction-B", "1"), ("interaction-C", "0")]
        var previousOutcome: UUID?
        for (index, pair) in sequence.enumerated() {
            let date = Date(timeIntervalSince1970: 1_789_214_400 + Double(index * 10))
            let startID = UUID()
            let toolStartID = UUID()
            let toolEndID = UUID()
            let endID = UUID()
            let start = try interactionEvent("assistant.turn_start", id: startID, at: date,
                                             turn: pair.1, interaction: pair.0)
            reducer.consume(start)
            rows.append(start)
            #expect(reducer.value().state == .working)
            #expect(reducer.value().attention.isEmpty)
            let tool = "synthetic-tool-\(index)"
            let toolStart = try interactionEvent("tool.execution_start", id: toolStartID,
                                                 parent: startID, at: date.addingTimeInterval(1),
                                                 data: ["toolCallId": tool, "toolName": "view"])
            reducer.consume(toolStart)
            rows.append(toolStart)
            if index == 4 {
                let request = try interactionEvent("permission.requested", at: date.addingTimeInterval(2),
                                                   data: ["requestId": "denied"])
                let denied = try interactionEvent("permission.completed", at: date.addingTimeInterval(3),
                                                  data: ["requestId": "denied"])
                reducer.consume(request)
                #expect(reducer.value().state == .blocked)
                reducer.consume(denied)
                rows += [request, denied]
            }
            let toolEnd = try interactionEvent("tool.execution_complete", id: toolEndID,
                                               parent: toolStartID, at: date.addingTimeInterval(4),
                                               data: ["toolCallId": tool, "success": index != 4])
            let end = try interactionEvent("assistant.turn_end", id: endID, parent: toolEndID,
                                           at: date.addingTimeInterval(5), turn: pair.1)
            reducer.consume(toolEnd)
            reducer.consume(end)
            rows += [toolEnd, end]
            let state = reducer.value()
            #expect(state.state == .idle)
            #expect(state.attention.map(\.kind) == (index == 4 ? [.error, .turnFinished] : [.turnFinished]))
            #expect(state.attention.last?.evidence.eventID == endID)
            #expect(state.attention.last?.evidence.eventID != previousOutcome)
            #expect(state.children.first { $0.id == "background" }?.state == .working)
            #expect(state.children.first { $0.id == "waiting" }?.state == .blocked)
            #expect(state.children.first { $0.id == "background" }?.terminalEvent == nil)
            previousOutcome = endID
        }
        var rebuilt = CopilotEventReducer(sessionID: session)
        for row in rows { rebuilt.consume(row) }
        #expect(rebuilt.value() == reducer.value())
    }
}

@MainActor
private func interactionTree(
    _ snapshot: CopilotSnapshot, fixture: CopilotReaderFixture,
    attention: SidebarAttentionSettings = .init()
) -> SidebarCopilotTree {
    let hierarchy = HierarchySnapshot(
        sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
        workspaceMetadataAvailable: true, surfaceMetadataAvailable: true, workspacePathsAvailable: false,
        workspaces: [
            .init(id: fixture.workspace, title: .available("Synthetic"), detail: .available(nil),
                  isSelected: .available(true), isPinned: .available(false), unreadCount: .available(0),
                  rootPath: .unavailable, projectRootPath: .unavailable, surfaces: .available([
                    .init(id: fixture.surface, title: "Synthetic", kind: .terminal, isFocused: true,
                          isPinned: false, unreadCount: 0, workingDirectory: .unavailable)
                  ]))
        ], windowID: UUID(uuidString: "60000000-0000-0000-0000-000000000006")
    )
    return SidebarCopilotTree.project(snapshot, onto: SidebarTopology(hierarchy),
                                      now: snapshot.generatedAt, attention: attention)
}

nonisolated func interactionEvent(
    _ type: String, id: UUID = UUID(), parent: UUID? = nil, at date: Date? = nil,
    owner: String? = nil, turn: String? = nil, interaction: String? = nil,
    data: [String: Any] = [:]
) throws -> Data {
    var fields = data
    if let turn { fields["turnId"] = turn }
    if let interaction { fields["interactionId"] = interaction }
    var event: [String: Any] = ["id": id.uuidString, "type": type, "data": fields]
    if let parent { event["parentId"] = parent.uuidString }
    if let date { event["timestamp"] = date.ISO8601Format() }
    if let owner { event["agentId"] = owner }
    return try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
}
