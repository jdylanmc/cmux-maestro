import Foundation
import Testing
@testable import CMUXMaestroPreview

@Suite(.serialized)
nonisolated struct CopilotInteractionTests {
    @Test(arguments: ["known-retained", "known-retired", "missing-retained", "missing-retired"], [false, true])
    func rawOwnerReuseGuardSurvivesUnknownKindAndRetirement(scenario: String, spill: Bool) throws {
        let missingSpawn = scenario.hasPrefix("missing")
        let retire = scenario.hasSuffix("retired")
        var reducer = CopilotEventReducer(
            sessionID: UUID(), maximumWorkItems: 1,
            maximumRelationships: spill ? 16 : 4096, maximumLifecycleEvents: spill ? 8 : 65_536
        )
        let rows = try multiTurnFragment()
        for (index, row) in rows.prefix(6).enumerated()
            where index != 1 && (!missingSpawn || index != 0) {
            reducer.consume(row)
        }
        #expect(reducer.value().children.first?.kind == .unknown)
        reducer.consume(try interactionEvent("abort", at: Date(timeIntervalSince1970: 2_008), owner: "child"))
        #expect(reducer.value().children.first?.state == .cancelled)
        for index in 0..<(spill ? 32 : 1) {
            reducer.consume(try interactionEvent("assistant.turn_start", turn: "root-\(index)",
                                                 interaction: "root-\(index)"))
        }
        if retire {
            reducer.consume(try interactionEvent("tool.execution_start", data: ["toolCallId": "pressure", "toolName": "bash"]))
            reducer.consume(try interactionEvent("tool.execution_complete", data: ["toolCallId": "pressure", "success": true]))
            #expect(reducer.value().children.allSatisfy { $0.id != "child" })
            #expect(reducer.retentionCounts.work == 1)
            if spill {
                for index in 0..<32 {
                    reducer.consume(try interactionEvent("assistant.turn_start", turn: "after-retirement-\(index)",
                                                         interaction: "after-retirement-\(index)"))
                }
            }
        }
        for row in try [
            interactionEvent("subagent.started", at: Date(timeIntervalSince1970: 2_010), owner: "child",
                             data: ["toolCallId": "new-spawn", "agentDisplayName": "New child"]),
            interactionEvent("subagent.configured", at: Date(timeIntervalSince1970: 2_011), owner: "child",
                             data: ["model": "synthetic-model", "multiTurn": true]),
            interactionEvent("assistant.turn_start", at: Date(timeIntervalSince1970: 2_012),
                             owner: "child", turn: "0", interaction: "new-A"),
            interactionEvent("subagent.completed", at: Date(timeIntervalSince1970: 2_013), owner: "child",
                             data: ["toolCallId": "new-spawn", "agentDisplayName": "New child"]),
            interactionEvent("assistant.turn_start", at: Date(timeIntervalSince1970: 2_014),
                             owner: "child", turn: "0", interaction: "new-B")
        ] { reducer.consume(row) }
        #expect(reducer.value().children.first?.name == "Unknown agent")
        #expect(reducer.value().children.first?.kind == .unknown)
        #expect(reducer.value().children.first?.state == .working)
        #expect(reducer.retentionCounts.work == 1)
        #expect(reducer.retentionCounts.tombstones <= (spill ? 16 : 4096))
        #expect(reducer.retentionCounts.events <= (spill ? 8 : 65_536))
    }

    @Test func saturatedReplayCannotReattestRetiredUnknownOwner() throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumWorkItems: 1,
                                          maximumLifecycleEvents: 16, maximumReplayFilterWords: 1)
        for (index, row) in try multiTurnFragment().prefix(6).enumerated() where index != 1 {
            reducer.consume(row)
        }
        reducer.consume(try interactionEvent("abort", owner: "child"))
        reducer.consume(try interactionEvent("assistant.turn_start", turn: "root", interaction: "root"))
        reducer.consume(try interactionEvent("tool.execution_start", data: ["toolCallId": "pressure", "toolName": "bash"]))
        reducer.consume(try interactionEvent("tool.execution_complete", data: ["toolCallId": "pressure", "success": true]))
        #expect(reducer.value().children.allSatisfy { $0.id != "child" })
        #expect(reducer.retentionCounts.work == 1)
        for row in try copilotTestReplayPressure() { reducer.consume(row) }
        for row in try [
            interactionEvent("subagent.started", owner: "child", data: [
                "toolCallId": "new-spawn", "agentDisplayName": "New child"
            ]),
            interactionEvent("subagent.configured", owner: "child", data: [
                "model": "synthetic-model", "multiTurn": true
            ]),
            interactionEvent("assistant.turn_start", owner: "child", turn: "0", interaction: "new-A")
        ] { reducer.consume(row) }
        #expect(reducer.value().children.allSatisfy { $0.id != "child" || $0.state == .unknown })
        #expect(reducer.issues.contains(.readLimitReached))
        #expect(reducer.retentionCounts.work <= 1)
        #expect(reducer.retentionCounts.eventReplayWords == 1)
    }

    @Test func laggingModelOnlyConfigurationPreservesLegacyProjection() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let rows = try multiTurnFragment()
        for row in rows.prefix(6) { reducer.consume(row) }
        let before = try #require(reducer.value().children.first)
        reducer.consume(try interactionEvent("subagent.configured", at: Date(timeIntervalSince1970: 2_001),
                                             owner: "child", data: ["model": "late-model"]))
        let after = try #require(reducer.value().children.first)
        #expect(after.model == "late-model")
        #expect(after.name == before.name)
        #expect(after.kind == before.kind)
        #expect(after.parentID == before.parentID)
        #expect(after.state == before.state)
        #expect(after.terminalEvent == before.terminalEvent)
        #expect(reducer.issues.isEmpty)
    }

    @Test func documentedCustomSelectionDoesNotInvalidateConfiguredChild() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let rows = try multiTurnFragment()
        reducer.consume(rows[0])
        reducer.consume(rows[1])
        reducer.consume(try interactionEvent(
            "subagent.selected",
            id: UUID(uuidString: "11810000-0000-0000-0000-000000000001")!,
            parent: UUID(uuidString: "11800000-0000-0000-0000-000000000065")!,
            at: Date(timeIntervalSince1970: 2_001), owner: "child",
            data: ["agentName": "synthetic-profile", "agentDisplayName": "Selection is not spawn identity",
                   "tools": ["view"]]
        ))
        #expect(reducer.value().children.first?.state == .working)
        #expect(reducer.value().children.first?.name == "Synthetic child")
        for row in rows[2...4] { reducer.consume(row) }
        #expect(reducer.value().children.first?.state == .completed)
        #expect(reducer.value().children.first?.terminalEvent != nil)
        reducer.consume(rows[5])
        #expect(reducer.value().children.first?.state == .working)
        #expect(reducer.value().children.first?.name == "Synthetic child")
        #expect(reducer.value().children.first?.kind == .subagent)
        #expect(reducer.issues.isEmpty)
    }

    @Test func unknownSubagentLifecycleStillInvalidatesConfiguredChild() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let rows = try multiTurnFragment()
        reducer.consume(rows[0])
        reducer.consume(rows[1])
        reducer.consume(try interactionEvent("subagent.future_lifecycle", owner: "child"))
        #expect(reducer.value().children.first?.state == .unknown)
        reducer.consume(rows[4])
        #expect(reducer.value().children.first?.state == .unknown)
        #expect(reducer.value().children.first?.terminalEvent == nil)
        #expect(reducer.issues == [.unsupportedFormat])
    }

    @Test(arguments: ["none", "proven", "unproven"])
    func interleavedUntaggedFollowUpNeedsOwnedProofNotGlobalChronology(toolMode: String) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let fragment = try multiTurnFragment()
        for row in fragment.prefix(5) { reducer.consume(row) }
        let rows = try interleavedUntaggedFollowUp(toolMode: toolMode)
        reducer.consume(rows[0])
        #expect(reducer.value().children.first?.state == .working)
        #expect(reducer.value().children.first?.name == "Synthetic child")
        for row in rows.dropFirst() { reducer.consume(row) }
        let current = reducer.value()
        #expect(current.children.first?.state == (toolMode == "proven" ? .idle : .unknown))
        #expect(current.children.first?.kind == .subagent)
        #expect(current.children.first?.name == "Synthetic child")
        #expect(current.children.first?.terminalEvent == nil)
        #expect(reducer.issues == (toolMode == "proven" ? [] : [.ambiguousTurn]))
        for row in fragment.prefix(5) { reducer.consume(row) }
        #expect(reducer.value() == current)
    }

    @Test func repeatedProducerShapedUntaggedFollowUpsRemainExplicitlyUnknown() throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumWorkItems: 2,
                                          maximumRelationships: 16, maximumLifecycleEvents: 8)
        var rebuilt = reducer
        for row in try multiTurnFragment().prefix(5) { reducer.consume(row); rebuilt.consume(row) }
        for index in 0..<128 {
            let rows = try interleavedUntaggedFollowUp(seed: 1_000 + index * 10, interaction: "followup-\(index)")
            reducer.consume(rows[0])
            rebuilt.consume(rows[0])
            #expect(reducer.value().children.first?.state == .working)
            for row in rows.dropFirst() { reducer.consume(row); rebuilt.consume(row) }
            #expect(reducer.value().children.first?.state == .unknown)
            #expect(reducer.value().children.first?.name == "Synthetic child")
            #expect(reducer.issues == [.ambiguousTurn])
            let counts = reducer.retentionCounts
            #expect(counts.work == 1 && counts.agents == 0 && counts.owners == 0)
            #expect(counts.tombstones <= 16 && counts.events <= 8 && counts.turns <= 1)
        }
        #expect(reducer.value() == rebuilt.value())
        #expect(reducer.canPublishProjection)
    }

    @Test func producerTaggedMessagesProveRepeatedChildFollowUpCompletion() throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumWorkItems: 2,
                                          maximumRelationships: 16, maximumLifecycleEvents: 8)
        var rebuilt = reducer
        let fragment = try multiTurnFragment()
        for row in fragment.prefix(5) { reducer.consume(row); rebuilt.consume(row) }
        let originalParent = try #require(reducer.value().children.first).parentID
        for index in 0..<128 {
            let rows = try interleavedUntaggedFollowUp(
                seed: 2_000 + index * 10, interaction: "followup-\(index)", messageTags: true
            )
            for row in rows { reducer.consume(row); rebuilt.consume(row) }
            let child = try #require(reducer.value().children.first)
            #expect(child.state == .idle)
            #expect(child.name == "Synthetic child" && child.kind == .subagent)
            #expect(child.parentID == originalParent && child.terminalEvent == nil)
            #expect(reducer.issues.isEmpty)
            let counts = reducer.retentionCounts
            #expect(counts.work == 1 && counts.agents == 0 && counts.owners == 0 && counts.turns == 0)
            #expect(counts.tombstones <= 16 && counts.events <= 8)
        }
        #expect(reducer.value() == rebuilt.value())
        let beforeReplay = reducer.value()
        for row in fragment.prefix(5) { reducer.consume(row) }
        #expect(reducer.value() == beforeReplay)
    }

    @Test(arguments: ["matching", "old-interaction", "wrong-turn", "interaction-only", "turn-only",
                       "null", "malformed", "wrong-owner"], [nil, "child"] as [String?])
    func messageAttributionCannotBorrowCurrentParent(proof: String, owner: String?) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let first = UUID(), current = UUID(), message = UUID()
        reducer.consume(try interactionEvent("assistant.turn_start", id: first, owner: owner,
                                             turn: "0", interaction: "A"))
        reducer.consume(try interactionEvent("assistant.turn_end", parent: first, owner: owner, turn: "0"))
        reducer.consume(try interactionEvent("assistant.turn_start", id: current, owner: owner,
                                             turn: "0", interaction: "B"))
        var tags: [String: Any] = ["turnId": "0", "interactionId": "B"]
        switch proof {
        case "old-interaction": tags["interactionId"] = "A"
        case "wrong-turn": tags["turnId"] = "1"
        case "interaction-only": tags.removeValue(forKey: "turnId")
        case "turn-only": tags.removeValue(forKey: "interactionId")
        case "null": tags["interactionId"] = NSNull()
        case "malformed": tags["turnId"] = ["not-an-identifier"]
        default: break
        }
        let row = try interactionEvent("assistant.message", id: message,
                                        parent: proof == "matching" ? UUID() : current,
                                        owner: proof == "wrong-owner" ? "other" : owner, data: tags)
        let before = reducer.value()
        reducer.consume(row)
        #expect(reducer.value() == before)
        reducer.consume(try interactionEvent("assistant.turn_end", parent: message, owner: owner, turn: "0"))
        let state = owner == nil ? reducer.value().state : reducer.value().children.first?.state
        #expect(state == (proof == "matching" ? .idle : .unknown))
        #expect(reducer.issues == (proof == "matching" ? [] : [.ambiguousTurn]))
        #expect(reducer.canPublishProjection)
    }

    @Test func invalidMessageTagsStayUnusableWithoutSuppressingTheSession() throws {
        for key in ["turnId", "interactionId"] {
            for invalid: Any in ["", String(repeating: "x", count: 257), "bad\nid", 12, ["value"], NSNull()] {
                var reducer = CopilotEventReducer(sessionID: UUID())
                let first = UUID(), current = UUID(), message = UUID()
                reducer.consume(try interactionEvent("assistant.turn_start", id: first, turn: "0", interaction: "A"))
                reducer.consume(try interactionEvent("assistant.turn_end", parent: first, turn: "0"))
                reducer.consume(try interactionEvent("assistant.turn_start", id: current, turn: "0", interaction: "B"))
                var data: [String: Any] = ["turnId": "0", "interactionId": "B"]
                data[key] = invalid
                reducer.consume(try interactionEvent("assistant.message", id: message, parent: current, data: data))
                reducer.consume(try interactionEvent("assistant.turn_end", parent: message, turn: "0"))
                #expect(reducer.value().state == .unknown)
                #expect(reducer.issues == [.ambiguousTurn])
                #expect(reducer.canPublishProjection)
            }
        }
    }

    @Test(arguments: [false, true])
    func replayedMessageCannotAnchorAnotherInteraction(spill: Bool) throws {
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumLifecycleEvents: spill ? 4 : 65_536)
        let first = UUID(), messageID = UUID()
        let message = try interactionEvent("assistant.message", id: messageID, parent: first,
                                           turn: "0", interaction: "A")
        reducer.consume(try interactionEvent("assistant.turn_start", id: first, turn: "0", interaction: "A"))
        reducer.consume(message)
        reducer.consume(try interactionEvent("assistant.turn_end", parent: messageID, turn: "0"))
        if spill {
            for index in 0..<16 {
                reducer.consume(try interactionEvent("assistant.turn_start", turn: "noise-\(index)",
                                                     interaction: "noise-\(index)"))
            }
        }
        let current = UUID()
        reducer.consume(try interactionEvent("assistant.turn_start", id: current, turn: "0", interaction: "B"))
        reducer.consume(message)
        // A reused event ID cannot become fresh proof by changing its tags or parent.
        reducer.consume(try interactionEvent("assistant.message", id: messageID, parent: current,
                                             turn: "0", interaction: "B"))
        reducer.consume(try interactionEvent("assistant.turn_end", parent: messageID, turn: "0"))
        #expect(reducer.value().state == .unknown)
        #expect(reducer.issues.contains(.ambiguousTurn))
    }

    @Test(arguments: ["abort", "session.resume", "session.shutdown"])
    func messageAttributionCannotReviveInvalidatedWork(boundary: String) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        for row in try multiTurnFragment().prefix(6) { reducer.consume(row) }
        reducer.consume(try interactionEvent(boundary, owner: boundary == "abort" ? "child" : nil,
                                             data: boundary == "session.shutdown" ? ["shutdownType": "routine"] : [:]))
        let before = reducer.value()
        let message = UUID()
        reducer.consume(try interactionEvent("assistant.message", id: message, owner: "child",
                                             turn: "0", interaction: "B"))
        #expect(reducer.value() == before)
        reducer.consume(try interactionEvent("assistant.turn_end", parent: message, owner: "child", turn: "0"))
        #expect(reducer.value() == before)
    }

    @Test func malformedMessageContainerIsNotLegacyEnvelopeProof() throws {
        for data: Any in [NSNull(), "opaque", ["not-an-object"]] {
            var reducer = CopilotEventReducer(sessionID: UUID())
            let first = UUID(), current = UUID(), message = UUID()
            reducer.consume(try interactionEvent("assistant.turn_start", id: first, turn: "0", interaction: "A"))
            reducer.consume(try interactionEvent("assistant.turn_end", parent: first, turn: "0"))
            reducer.consume(try interactionEvent("assistant.turn_start", id: current, turn: "0", interaction: "B"))
            reducer.consume(try JSONSerialization.data(withJSONObject: [
                "id": message.uuidString, "type": "assistant.message", "parentId": current.uuidString, "data": data
            ]))
            reducer.consume(try interactionEvent("assistant.turn_end", parent: message, turn: "0"))
            #expect(reducer.value().state == .unknown)
            #expect(reducer.issues == [.ambiguousTurn])
            #expect(reducer.canPublishProjection)
        }
    }

    @Test @MainActor
    func readerProjectsTaggedInterleavedParentChildAndGrandchildIdle() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_020)
        let names = ["parent", "child", "grandchild"]
        var rows = try [
            interactionEvent("session.start", data: ["sessionId": fixture.sessionID.uuidString, "version": 1]),
            interactionEvent("tool.execution_start", data: ["toolCallId": "spawn-parent", "toolName": "task"])
        ]
        for (index, owner) in names.enumerated() {
            rows += try multiTurnFragment(owner: owner, seed: 200 + index * 100,
                                           parentAgent: index == 0 ? nil : names[index - 1]).prefix(5)
            rows += try interleavedUntaggedFollowUp(seed: 4_000 + index * 10, owner: owner, messageTags: true)
        }
        try fixture.writeEvents(rows)
        let snapshot = try await fixture.reader(clock: { now }).read(surfaceIDs: [fixture.surface])
        let hidden = interactionTree(snapshot, fixture: fixture)
        #expect(hidden.sessions.first?.nodes.isEmpty == true && hidden.hasCompleteCounts)
        let sourceChildren = try #require(snapshot.sessions.first?.children)
        #expect(sourceChildren.map(\.id) == names)
        #expect(sourceChildren.map(\.parentID) == [nil, "parent", "child"])
        #expect(sourceChildren.allSatisfy { $0.kind == .subagent && $0.state == .idle && $0.terminalEvent == nil })
        let tree = interactionTree(snapshot, fixture: fixture, revealIdle: true)
        let session = try #require(tree.sessions.first)
        #expect(snapshot.isComplete && snapshot.issues.isEmpty && tree.hasCompleteCounts)
        #expect(tree.sessions.count == 1 && session.surfaceID == fixture.surface)
        #expect(session.nodes.map(\.id) == names)
        #expect(session.nodes.map(\.name) == names.map { "Synthetic \($0)" })
        #expect(session.nodes.map(\.parentID) == [nil, "parent", "child"])
        #expect(session.nodes.map(\.depth) == [0, 1, 2])
        #expect(session.nodes.allSatisfy { $0.kind == .subagent && $0.state == .idle && $0.terminalEvent == nil })
        #expect(tree.knownRunningChildren == 0 && tree.attentionOwnerCount == 0)
        let rebuilt = try await fixture.reader(clock: { now }).read(surfaceIDs: [fixture.surface])
        #expect(rebuilt == snapshot)
        let publicText = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!publicText.contains("SYNTHETIC_MESSAGE_PAYLOAD"))
        #expect(!publicText.contains("SYNTHETIC_WARNING_PAYLOAD"))
        #expect(!publicText.contains("interactionId") && !publicText.contains("messageId"))
    }

    @Test @MainActor
    func readerReportsProducerInterleavingAsPartialUnknownWithoutLosingChildIdentity() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_020)
        try fixture.writeEvents([
            interactionEvent("session.start", data: ["sessionId": fixture.sessionID.uuidString, "version": 1]),
            interactionEvent("tool.execution_start", data: ["toolCallId": "spawn-child", "toolName": "task"])
        ] + multiTurnFragment().prefix(5) + interleavedUntaggedFollowUp())
        let snapshot = try await fixture.reader(clock: { now }).read(surfaceIDs: [fixture.surface])
        #expect(!snapshot.isComplete)
        #expect(snapshot.issues == [.ambiguousTurn])
        let tree = interactionTree(snapshot, fixture: fixture)
        let session = try #require(tree.sessions.first)
        #expect(tree.availability == .partial)
        #expect(!tree.hasCompleteCounts)
        #expect(tree.sessions.count == 1)
        #expect(session.id == fixture.sessionID && session.surfaceID == fixture.surface)
        let observed = try #require(snapshot.sessions.first?.children.first)
        #expect(observed.state == .unknown && observed.name == "Synthetic child" && observed.kind == .subagent)
        #expect(observed.parentID == nil && observed.terminalEvent == nil)
        let neutral = CopilotSnapshotAdapter.child(observed, session: .init(providerID: "copilot", sessionID: fixture.sessionID.uuidString))
        #expect(neutral.id.rawValue == observed.id && neutral.workState == .unknown)
        #expect(neutral.title.knownValue == "Synthetic child" && neutral.kind == .subagent)
        #expect(neutral.parentID == nil && neutral.terminalEvent == nil)
        #expect(session.nodes.isEmpty && session.internalTaskCountsIncomplete)
        #expect(interactionTree(snapshot, fixture: fixture, revealIdle: true).sessions.first?.nodes.isEmpty == true)
        #expect(session.knownRunningChildren == 0)
        #expect(tree.attentionOwnerCount == 0)
        let publicText = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!publicText.contains("SYNTHETIC_WARNING_PAYLOAD"))
        #expect(!publicText.contains("SYNTHETIC_MESSAGE_PAYLOAD"))
    }

    @Test func demonstratedMultiTurnFragmentPreservesIdentityOnlyOnFreshContinuation() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let rows = try multiTurnFragment()
        for row in rows.prefix(5) { reducer.consume(row) }
        let completed = try #require(reducer.value().children.first)
        #expect(completed.state == .completed)
        #expect(completed.name == "Synthetic child")
        #expect(completed.kind == .subagent)
        #expect(completed.terminalEvent != nil)

        reducer.consume(rows[5])
        let continued = try #require(reducer.value().children.first)
        #expect(continued.state == .working)
        #expect(continued.id == completed.id)
        #expect(continued.name == completed.name)
        #expect(continued.kind == completed.kind)
        #expect(continued.parentID == completed.parentID)
        #expect(continued.terminalEvent == nil)
        #expect(reducer.issues.isEmpty)

        // The sanitized seven-event excerpt omits intervening causal envelopes.
        // Metadata continuity must not make its unlinked, untagged end authoritative.
        reducer.consume(rows[6])
        #expect(reducer.value().children.first?.state == .unknown)
        #expect(reducer.issues == [.ambiguousTurn])
    }

    @Test func sameOwnerCausalControlFinishesIdleWithoutRespawn() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let rows = try multiTurnFragment()
        reducer.consume(try interactionEvent("tool.execution_start", data: [
            "toolCallId": "spawn-child", "toolName": "task"
        ]))
        for row in rows.prefix(6) { reducer.consume(row) }
        // Hypothetical same-owner control, not the observed producer interleaving.
        reducer.consume(try multiTurnEndBridge())
        reducer.consume(rows[6])
        let child = try #require(reducer.value().children.first)
        #expect(child.id == "child")
        #expect(child.name == "Synthetic child")
        #expect(child.kind == .subagent)
        #expect(child.parentID == nil)
        #expect(child.state == .idle)
        #expect(child.terminalEvent == nil)
        #expect(child.attention?.isEmpty != false)
        #expect(reducer.issues.isEmpty)
    }

    @Test @MainActor
    func readerProjectsSyntheticCausalControlThroughParentChildAndGrandchild() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_010)
        let reader = fixture.reader(clock: { now })
        let parentRows = try multiTurnFragment(owner: "parent", seed: 200)
        let childRows = try multiTurnFragment(owner: "child", seed: 300, parentAgent: "parent")
        let grandchildRows = try multiTurnFragment(owner: "grandchild", seed: 400, parentAgent: "child")
        let families = [parentRows, childRows, grandchildRows]
        try fixture.writeEvents([
            interactionEvent("session.start", data: ["sessionId": fixture.sessionID.uuidString, "version": 1]),
            interactionEvent("tool.execution_start", data: ["toolCallId": "spawn-parent", "toolName": "task"])
        ] + families.flatMap { Array($0.prefix(5)) } + [interactionEvent("session.idle")])
        let initial = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(initial.isComplete)
        let first = try #require(interactionTree(initial, fixture: fixture).sessions.first)
        #expect(first.nodes.map(\.state) == [.completed, .completed, .completed])
        #expect(first.nodes.map(\.name) == ["Synthetic parent", "Synthetic child", "Synthetic grandchild"])
        #expect(first.nodes.map(\.parentID) == [nil, "parent", "child"])
        #expect(first.nodes.map(\.depth) == [0, 1, 2])
        for rows in families { try fixture.append(rows[5] + Data([10])) }
        let active = try await reader.read(surfaceIDs: [fixture.surface])
        let tree = interactionTree(active, fixture: fixture)
        let session = try #require(tree.sessions.first)
        #expect(tree.sessions.count == 1)
        #expect(session.id == fixture.sessionID)
        #expect(session.surfaceID == fixture.surface)
        #expect(session.workspaceID == fixture.workspace)
        #expect(session.state == .idle)
        #expect(session.nodes.map(\.id) == first.nodes.map(\.id))
        #expect(session.nodes.map(\.name) == first.nodes.map(\.name))
        #expect(session.nodes.map(\.parentID) == first.nodes.map(\.parentID))
        #expect(session.nodes.map(\.kind) == [.subagent, .subagent, .subagent])
        #expect(session.nodes.map(\.depth) == [0, 1, 2])
        #expect(session.nodes.allSatisfy { !$0.ancestryUnresolved && $0.state == .working && $0.terminalEvent == nil })
        #expect(tree.hasCompleteCounts)
        #expect(tree.knownRunningChildren == 3)
        #expect(tree.attentionOwnerCount == 0)
        for (index, owner) in ["parent", "child", "grandchild"].enumerated() {
            try fixture.append(multiTurnEndBridge(owner: owner, seed: 200 + index * 100) + Data([10]))
            try fixture.append(families[index][6] + Data([10]))
        }
        let idle = try await reader.read(surfaceIDs: [fixture.surface])
        let idleTree = interactionTree(idle, fixture: fixture)
        #expect(idle.isComplete)
        let idleChildren = try #require(idle.sessions.first?.children)
        #expect(idleChildren.map(\.id) == ["parent", "child", "grandchild"])
        #expect(idleChildren.map(\.state) == [.idle, .idle, .idle])
        #expect(idleChildren.map(\.parentID) == [nil, "parent", "child"])
        #expect(idleTree.sessions.first?.nodes.isEmpty == true && idleTree.hasCompleteCounts)
        let revealedIdle = interactionTree(idle, fixture: fixture, revealIdle: true)
        #expect(revealedIdle.sessions.first?.nodes.map(\.state) == [.idle, .idle, .idle])
        #expect(revealedIdle.sessions.first?.nodes.map(\.id) == idleChildren.map(\.id))
        #expect(revealedIdle.sessions.first?.nodes.map(\.parentID) == idleChildren.map(\.parentID))
        #expect(revealedIdle.sessions.first?.nodes.map(\.depth) == [0, 1, 2])
        #expect(idleTree.knownRunningChildren == 0)
        #expect(idleTree.attentionOwnerCount == 0)
        #expect(idleTree.retainedHistoryCount == 0)
        let rebuilt = try await fixture.reader(clock: { now }).read(surfaceIDs: [fixture.surface])
        #expect(rebuilt == idle)
        let publicText = String(decoding: try JSONEncoder().encode(idle), as: UTF8.self)
        #expect(!publicText.contains("multiTurn"))
        #expect(!publicText.contains("configurationStart"))
        #expect(!publicText.contains("interactionID"))
    }

    @Test func configurationMustBelongToInitialKnownSpawnAndUseStrictBoolean() throws {
        let rows = try multiTurnFragment()
        for value: Any in [false, NSNull(), "true", 1, ["true"]] {
            var reducer = CopilotEventReducer(sessionID: UUID())
            reducer.consume(rows[0])
            reducer.consume(try interactionEvent("subagent.configured", at: Date(timeIntervalSince1970: 2_001),
                                                 owner: "child", data: ["model": "new-model", "multiTurn": value]))
            for row in rows[2...5] { reducer.consume(row) }
            #expect(reducer.value().children.first?.kind == .unknown)
            #expect(reducer.value().children.first?.name == "Unknown agent")
            if value is String || value is Int || value is [String] {
                #expect(reducer.issues == [.malformedData])
                #expect(!reducer.canPublishProjection)
            }
        }
        for placement in ["absent", "model-only", "before-spawn", "after-turn", "after-completion",
                          "missing-spawn", "missing-time", "old-time", "unrelated", "root", "late-spawn"] {
            var reducer = CopilotEventReducer(sessionID: UUID())
            if placement == "before-spawn" || placement == "late-spawn" { reducer.consume(rows[1]) }
            if placement != "missing-spawn" && placement != "late-spawn" { reducer.consume(rows[0]) }
            if ["model-only", "missing-time", "old-time", "unrelated", "root"].contains(placement) {
                reducer.consume(try interactionEvent(
                    "subagent.configured",
                    at: placement == "missing-time" ? nil : Date(timeIntervalSince1970: placement == "old-time" ? 1_999 : 2_001),
                    owner: placement == "root" ? nil : placement == "unrelated" ? "other" : "child",
                    data: placement == "model-only" ? ["model": "new-model"]
                        : ["model": "new-model", "multiTurn": true]
                ))
            }
            reducer.consume(rows[2])
            if placement == "late-spawn" { reducer.consume(rows[0]); reducer.consume(rows[1]) }
            if placement == "after-turn" || placement == "missing-spawn" { reducer.consume(rows[1]) }
            reducer.consume(rows[3])
            reducer.consume(rows[4])
            if placement == "after-completion" { reducer.consume(rows[1]) }
            reducer.consume(rows[5])
            #expect(reducer.value().children.first?.kind == .unknown, "\(placement)")
            #expect(reducer.value().children.first?.name == "Unknown agent", "\(placement)")
            #expect(reducer.value().children.first?.state == .working, "\(placement)")
            #expect(reducer.retentionCounts.work == 1)
        }
    }

    @Test(arguments: ["subagent.failed", "cancelled", "abort", "session.error", "session.shutdown", "session.resume"])
    func multiTurnCannotCrossInvalidatedOrUnprovenTerminalBoundary(boundary: String) throws {
        let rows = try multiTurnFragment()
        var reducer = CopilotEventReducer(sessionID: UUID())
        for row in rows.prefix(4) { reducer.consume(row) }
        if boundary == "session.shutdown" || boundary == "session.resume" { reducer.consume(rows[4]) }
        reducer.consume(try interactionEvent(
            boundary == "cancelled" ? "subagent.completed" : boundary,
            at: Date(timeIntervalSince1970: 2_004),
            owner: boundary == "session.shutdown" || boundary == "session.resume" ? nil : "child",
            data: ["toolCallId": "spawn-child", "agentDisplayName": "Synthetic child",
                   "cancelled": true, "shutdownType": "routine"]
        ))
        // An old/newly delivered configuration cannot re-attest this lifetime.
        reducer.consume(try interactionEvent("subagent.configured", at: Date(timeIntervalSince1970: 2_005),
                                             owner: "child", data: ["model": "synthetic-model", "multiTurn": true]))
        reducer.consume(rows[5])
        #expect(reducer.value().children.first?.kind == .unknown)
        #expect(reducer.value().children.first?.name == "Unknown agent")
        #expect(reducer.value().children.first?.state == .working)
    }

    @Test(arguments: ["abort", "session.error"])
    func primaryTurnFailureDoesNotInvalidateIndependentMultiTurnChild(boundary: String) throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let rows = try multiTurnFragment()
        for row in rows.prefix(5) { reducer.consume(row) }
        reducer.consume(try interactionEvent(boundary))
        let root = reducer.value()
        reducer.consume(rows[5])
        reducer.consume(try multiTurnEndBridge())
        reducer.consume(rows[6])
        #expect(reducer.value().state == root.state)
        #expect(reducer.value().attention == root.attention)
        #expect(reducer.value().children.first?.name == "Synthetic child")
        #expect(reducer.value().children.first?.state == .idle)
    }

    @Test(arguments: [false, true])
    func continuedInteractionRejectsDelayedSpawnOutcomeAndOldStarts(completionBeforeFollowUp: Bool) throws {
        let rows = try multiTurnFragment()
        var reducer = CopilotEventReducer(sessionID: UUID())
        for row in rows.prefix(completionBeforeFollowUp ? 5 : 4) { reducer.consume(row) }
        reducer.consume(rows[5])
        reducer.consume(try interactionEvent("permission.requested", owner: "child", data: ["requestId": "current"]))
        let active = reducer.value()
        #expect(active.children.first?.state == .blocked)
        #expect(active.children.first?.kind == .subagent)
        for row in [rows[0], rows[1], rows[2], rows[3], rows[4]] { reducer.consume(row) }
        for row in try [
            interactionEvent("subagent.started", owner: "child", data: [
                "toolCallId": "spawn-child", "agentDisplayName": "Wrong old label", "model": "old-model"
            ]),
            interactionEvent("subagent.failed", owner: "child", data: [
                "toolCallId": "spawn-child", "agentDisplayName": "Wrong old label"
            ]),
            interactionEvent("assistant.turn_start", owner: "child", turn: "unseen", interaction: "A")
        ] { reducer.consume(row) }
        #expect(reducer.value() == active)
        reducer.consume(try interactionEvent("subagent.configured", at: Date(timeIntervalSince1970: 2_001),
                                             owner: "child", data: ["model": "old-model", "multiTurn": true]))
        let afterConfiguration = try #require(reducer.value().children.first)
        let beforeConfiguration = try #require(active.children.first)
        #expect(afterConfiguration.model == "old-model")
        #expect(afterConfiguration.name == beforeConfiguration.name && afterConfiguration.kind == beforeConfiguration.kind)
        #expect(afterConfiguration.parentID == beforeConfiguration.parentID)
        #expect(afterConfiguration.state == beforeConfiguration.state)
        #expect(afterConfiguration.terminalEvent == beforeConfiguration.terminalEvent)
        #expect(afterConfiguration.attention == beforeConfiguration.attention)
        #expect(reducer.retentionCounts.requests == 1)
        #expect(reducer.retentionCounts.agents == 0)
        reducer.consume(try multiTurnEndBridge())
        reducer.consume(rows[6])
        reducer.consume(try interactionEvent("permission.completed", owner: "child", data: ["requestId": "current"]))
        #expect(reducer.value().children.first?.state == .idle)
        #expect(reducer.value().children.first?.name == "Synthetic child")
        #expect(reducer.issues.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func newSpawnOrRetiredChildCannotInheritPriorMultiTurnConfiguration(
        retire: Bool, configuredInitially: Bool
    ) throws {
        let rows = try multiTurnFragment()
        var reducer = CopilotEventReducer(sessionID: UUID(), maximumWorkItems: 1)
        for (index, row) in rows.prefix(5).enumerated() where configuredInitially || index != 1 {
            reducer.consume(row)
        }
        if retire {
            reducer.consume(try interactionEvent("tool.execution_start", data: ["toolCallId": "retire", "toolName": "bash"]))
            reducer.consume(try interactionEvent("tool.execution_complete", data: ["toolCallId": "retire", "success": true]))
            #expect(reducer.value().children.allSatisfy { $0.id != "child" })
            #expect(reducer.retentionCounts.work == 1)
        }
        reducer.consume(try interactionEvent("subagent.started", at: Date(timeIntervalSince1970: 2_010),
                                             owner: "child", data: [
                                                "toolCallId": "new-spawn", "agentDisplayName": "New child",
                                                "parentId": "new-parent", "model": "new-model"
                                             ]))
        let fresh = reducer.value()
        for (index, row) in rows.prefix(5).enumerated() where index != 1 { reducer.consume(row) }
        #expect(reducer.value() == fresh)
        // Model metadata keeps legacy clock-tolerant projection; the stale
        // configuration still cannot attest this reused owner's capability.
        reducer.consume(rows[1])
        #expect(reducer.value().children.first?.name == "New child")
        #expect(reducer.value().children.first?.state == .working)
        // Even fresh-looking configuration cannot borrow an already used raw ID.
        reducer.consume(try interactionEvent("subagent.configured", at: Date(timeIntervalSince1970: 2_011),
                                             owner: "child", data: ["model": "new-model", "multiTurn": true]))
        for row in try [
            interactionEvent("assistant.turn_start", at: Date(timeIntervalSince1970: 2_012),
                             owner: "child", turn: "0", interaction: "new-A"),
            interactionEvent("subagent.completed", at: Date(timeIntervalSince1970: 2_013), owner: "child",
                             data: ["toolCallId": "new-spawn", "agentDisplayName": "New child"]),
            interactionEvent("assistant.turn_start", at: Date(timeIntervalSince1970: 2_014),
                             owner: "child", turn: "0", interaction: "new-B")
        ] { reducer.consume(row) }
        #expect(reducer.value().children.first?.name == "Unknown agent")
        #expect(reducer.value().children.first?.kind == .unknown)
        #expect(reducer.value().children.first?.parentID == "unresolved-owner")
    }

    @Test(arguments: ["missing", "same"])
    func terminalContinuationRequiresANewExplicitInteraction(namespace: String) throws {
        let rows = try multiTurnFragment()
        var reducer = CopilotEventReducer(sessionID: UUID())
        for row in rows.prefix(5) { reducer.consume(row) }
        reducer.consume(try interactionEvent("assistant.turn_start", owner: "child", turn: "unseen",
                                             interaction: namespace == "same" ? "A" : nil))
        #expect(reducer.value().children.first?.kind == .unknown)
        #expect(reducer.value().children.first?.state == .working)
    }

    @Test func modelOnlyConfigurationDoesNotReviveWorkAndExplicitFalseRevokesContinuation() throws {
        let rows = try multiTurnFragment()
        var reducer = CopilotEventReducer(sessionID: UUID())
        for row in rows.prefix(5) { reducer.consume(row) }
        let terminal = reducer.value().children.first?.terminalEvent
        reducer.consume(try interactionEvent("subagent.configured", at: Date(timeIntervalSince1970: 2_004),
                                             owner: "child", data: ["model": "updated-model"]))
        #expect(reducer.value().children.first?.state == .completed)
        #expect(reducer.value().children.first?.terminalEvent == terminal)
        #expect(reducer.value().children.first?.model == "updated-model")
        reducer.consume(try interactionEvent("subagent.configured", at: Date(timeIntervalSince1970: 2_004),
                                             owner: "child", data: ["model": "updated-model", "multiTurn": false]))
        reducer.consume(rows[5])
        #expect(reducer.value().children.first?.kind == .unknown)
    }

    @Test func malformedConfigurationCannotPublishPreviouslyAttestedContinuation() throws {
        let rows = try multiTurnFragment()
        var reducer = CopilotEventReducer(sessionID: UUID())
        for row in rows.prefix(5) { reducer.consume(row) }
        reducer.consume(try interactionEvent("subagent.configured", owner: "child", data: [
            "model": "synthetic-model", "multiTurn": "true"
        ]))
        reducer.consume(rows[5])
        #expect(!reducer.canPublishProjection)
        #expect(reducer.issues == [.malformedData])
    }

    @Test func taggedEndControlRemainsBoundedAndReconstructsAfterReplayWindowSpill() throws {
        let session = UUID()
        var reducer = CopilotEventReducer(sessionID: session, maximumWorkItems: 2,
                                          maximumRelationships: 8, maximumLifecycleEvents: 4)
        var rebuilt = reducer
        let fragment = try multiTurnFragment()
        for row in fragment.prefix(5) { reducer.consume(row); rebuilt.consume(row) }
        // Tagged ends isolate replay retention; 1.0.88's observed ends are untagged
        // and covered separately by the producer-shaped interleaving regression.
        for index in 0..<128 {
            for row in try [
                interactionEvent("assistant.turn_start", owner: "child", turn: "0", interaction: "followup-\(index)"),
                interactionEvent("assistant.turn_end", owner: "child", turn: "0", interaction: "followup-\(index)")
            ] {
                reducer.consume(row)
                rebuilt.consume(row)
                let counts = reducer.retentionCounts
                #expect(counts.work == 1 && counts.agents == 0 && counts.owners == 0)
                #expect(counts.tombstones <= 8 && counts.events <= 4)
                #expect(counts.interactionOwners == 1 && counts.turns <= 1)
            }
        }
        #expect(reducer.value() == rebuilt.value())
        #expect(reducer.value().children.first?.name == "Synthetic child")
        #expect(reducer.value().children.first?.state == .idle)
        #expect(reducer.issues.isEmpty)
        let current = reducer.value()
        for row in fragment.prefix(5) { reducer.consume(row) }
        #expect(reducer.value() == current)
        #expect(reducer.issues == [.readLimitReached])
    }

    @Test(arguments: [false, true])
    func retiredOrReplayLimitedContinuationCannotBorrowTerminalIdentity(limited: Bool) throws {
        let rows = try multiTurnFragment()
        var reducer = CopilotEventReducer(
            sessionID: UUID(), maximumWorkItems: 1, maximumLifecycleEvents: limited ? 2 : 65_536,
            maximumReplayFilterWords: limited ? 1 : 16_384
        )
        for row in rows.prefix(5) { reducer.consume(row) }
        if limited {
            for row in try copilotTestReplayPressure() { reducer.consume(row) }
        } else {
            reducer.consume(try interactionEvent("tool.execution_start", data: ["toolCallId": "retire", "toolName": "bash"]))
            reducer.consume(try interactionEvent("tool.execution_complete", data: ["toolCallId": "retire", "success": true]))
            #expect(reducer.value().children.first?.id != "child")
            #expect(reducer.retentionCounts.work == 1)
        }
        reducer.consume(rows[5])
        let child = try #require(reducer.value().children.first { $0.id == "child" })
        #expect(child.terminalEvent == nil)
        if limited {
            #expect(child.state == .unknown)
            #expect(reducer.issues.contains(.readLimitReached))
        } else {
            #expect(child.state == .working)
            #expect(child.kind == .unknown)
            #expect(child.name == "Unknown agent")
        }
        let current = reducer.value()
        reducer.consume(rows[4])
        #expect(reducer.value() == current)
    }

    @Test func unjoinedShellNotificationCannotProveCurrentPrimaryTurnCompletion() throws {
        var reducer = CopilotEventReducer(sessionID: UUID())
        let a = UUID(), b = UUID(), notification = UUID()
        reducer.consume(try interactionEvent("assistant.turn_start", id: a, turn: "0", interaction: "A"))
        reducer.consume(try interactionEvent("assistant.turn_end", parent: a, turn: "0"))
        reducer.consume(try interactionEvent("assistant.turn_start", id: b, turn: "0", interaction: "B"))
        reducer.consume(try interactionEvent("system.notification", id: notification, parent: b, data: [
            "kind": ["type": "shell_completed", "shellId": "unjoined", "exitCode": 0]
        ]))
        #expect(reducer.value().children.isEmpty)
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
            "content": "PRIVATE_PAYLOAD", "arguments": ["command": "PRIVATE_ARGUMENT"]
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
    attention: SidebarAttentionSettings = .init(), revealIdle: Bool = false
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
                                      now: snapshot.generatedAt, attention: attention,
                                      revealingIdleTasksIn: revealIdle ? [fixture.workspace] : [])
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

// Copilot 1.0.88's observed seven-event sequence, with deterministic replacement
// IDs/labels/times. The excerpt's missing chronological predecessors stay missing.
nonisolated func multiTurnFragment(
    owner: String = "child", seed: Int = 100, parentAgent: String? = nil
) throws -> [Data] {
    let ids = (0..<12).map {
        UUID(uuidString: String(format: "11800000-0000-0000-0000-%012X", seed + $0))!
    }
    let date = Date(timeIntervalSince1970: 2_000)
    var spawn: [String: Any] = [
        "toolCallId": "spawn-\(owner)", "agentDisplayName": "Synthetic \(owner)",
        "agentName": "task", "resumable": false, "model": "synthetic-model"
    ]
    if let parentAgent { spawn["parentId"] = parentAgent }
    return try [
        interactionEvent("subagent.started", id: ids[0], parent: ids[7], at: date,
                         owner: owner, data: spawn),
        interactionEvent("subagent.configured", id: ids[1], parent: ids[8],
                         at: date.addingTimeInterval(1), owner: owner,
                         data: ["multiTurn": true, "model": "synthetic-model"]),
        interactionEvent("assistant.turn_start", id: ids[2], parent: ids[9],
                         at: date.addingTimeInterval(2), owner: owner, turn: "0", interaction: "A"),
        interactionEvent("assistant.turn_end", id: ids[3], parent: ids[10],
                         at: date.addingTimeInterval(3), owner: owner, turn: "0"),
        interactionEvent("subagent.completed", id: ids[4], parent: ids[10],
                         at: date.addingTimeInterval(4), owner: owner, data: spawn),
        interactionEvent("assistant.turn_start", id: ids[5], parent: ids[10],
                         at: date.addingTimeInterval(5), owner: owner, turn: "0", interaction: "B"),
        interactionEvent("assistant.turn_end", id: ids[6], parent: ids[11],
                         at: date.addingTimeInterval(7), owner: owner, turn: "0")
    ]
}

// Hypothetical same-owner control; the reported producer trace has intervening
// root-owned warning/hook envelopes instead of this direct link.
nonisolated func multiTurnEndBridge(owner: String = "child", seed: Int = 100) throws -> Data {
    try interactionEvent(
        "assistant.message",
        id: UUID(uuidString: String(format: "11800000-0000-0000-0000-%012X", seed + 11))!,
        parent: UUID(uuidString: String(format: "11800000-0000-0000-0000-%012X", seed + 5))!,
        owner: owner
    )
}

// Missing message tags retain the original review's evidence gap. Tagged messages
// mirror the later metadata-only 1.0.88 probe; tool modes remain synthetic controls.
nonisolated func interleavedUntaggedFollowUp(
    seed: Int = 1_000, interaction: String = "B", toolMode: String = "none",
    owner: String = "child", messageTags: Bool = false
) throws -> [Data] {
    let ids = (0..<7).map {
        UUID(uuidString: String(format: "11820000-0000-0000-0000-%012X", seed + $0))!
    }
    let date = Date(timeIntervalSince1970: 2_010)
    let tool = "followup-tool-\(seed)"
    var rows = [try interactionEvent("assistant.turn_start", id: ids[0], at: date,
                                     owner: owner, turn: "0", interaction: interaction)]
    if toolMode == "proven" {
        rows.append(try interactionEvent("tool.execution_start", id: ids[3], parent: ids[0],
                                         at: date.addingTimeInterval(1), owner: owner,
                                         data: ["toolCallId": tool, "toolName": "view"]))
    }
    rows += try [
        interactionEvent("session.warning", id: ids[1], parent: toolMode == "proven" ? ids[3] : ids[0],
                         at: date.addingTimeInterval(2),
                         data: ["warningType": "synthetic", "message": "SYNTHETIC_WARNING_PAYLOAD"]),
        interactionEvent("hook.start", id: ids[2], parent: ids[1], at: date.addingTimeInterval(3),
                         data: ["hookInvocationId": "synthetic-hook-\(seed)", "hookType": "preToolUse"])
    ]
    if toolMode == "unproven" {
        rows.append(try interactionEvent("tool.execution_start", id: ids[3], parent: ids[2],
                                         at: date.addingTimeInterval(4), owner: owner,
                                         data: ["toolCallId": tool, "toolName": "view"]))
    }
    if toolMode != "none" {
        rows.append(try interactionEvent("tool.execution_complete", id: ids[4],
                                         parent: toolMode == "proven" ? ids[2] : ids[3],
                                         at: date.addingTimeInterval(5), owner: owner,
                                         data: ["toolCallId": tool, "success": true]))
    }
    rows += try [
        interactionEvent("assistant.message", id: ids[5], parent: toolMode == "none" ? ids[2] : ids[4],
                         at: date.addingTimeInterval(6), owner: owner,
                         turn: messageTags ? "0" : nil, interaction: messageTags ? interaction : nil,
                         data: ["messageId": "synthetic-message-\(seed)", "content": "SYNTHETIC_MESSAGE_PAYLOAD"]),
        interactionEvent("assistant.turn_end", id: ids[6], parent: ids[5], at: date.addingTimeInterval(7),
                         owner: owner, turn: "0")
    ]
    return rows
}
