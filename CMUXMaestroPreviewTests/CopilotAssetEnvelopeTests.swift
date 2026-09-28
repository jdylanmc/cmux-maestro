import Darwin
import Foundation
import Testing

@MainActor
struct CopilotAssetEnvelopeTests {
    @Test(arguments: [1, 7, 257, 2048])
    func projectsOnlyAssetEnvelopeAcrossChunkBoundaries(chunkSize: Int) throws {
        let id = UUID().uuidString
        let parent = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id, "parentId": parent, "type": "session.binary_asset",
            "data": [
                "data": String(repeating: "YWJj", count: 4096),
                "description": #"\"}, "type": "assistant.turn_start", "data": {"turnId":"fake"}"#,
                "nested": [["braces": "{}[]", "unicode": "α"]]
            ]
        ], options: [.sortedKeys])
        var envelope = CopilotAssetEnvelope(maximumBytes: 512)
        for start in stride(from: 0, to: data.count, by: chunkSize) {
            envelope.consume(Data(data[start..<min(data.count, start + chunkSize)]))
        }
        let projected = try #require(envelope.projectedBinaryAsset)
        #expect(projected.count <= 512)
        let event = try JSONDecoder().decode(CopilotEventProjection.self, from: projected)
        #expect(event.type == "session.binary_asset")
        #expect(event.id == id)
        #expect(event.parentEventID == parent)
        #expect(!String(decoding: projected, as: UTF8.self).contains("YWJj"))
    }

    @Test func rejectsLifecycleSpoofingDuplicatesUnfinishedAndOverDeepEnvelopes() {
        let id = UUID().uuidString
        let examples = [
            #"{"id":"\#(id)","type":"assistant.turn_start","data":{"type":"session.binary_asset","turnId":"1"}}"#,
            #"{"id":"\#(id)","type":"assistant.turn_start","type":"session.binary_asset","data":{}}"#,
            #"{"id":"\#(id)","type":"session.binary_asset","data":{},"data":{}}"#,
            #"{"id":"invalid","type":"session.binary_asset","data":{}}"#,
            #"{"id":"\#(id)","type":"session.binary_asset","data":{"data":"unfinished"#,
            #"{"id":"\#(id)","type":"session.binary_asset","data":[1,2]}"#,
            #"{"id":"\#(id)","type":"session.binary_asset","data":{]"#,
            #"{"id":"\#(id)","type":"session.binary_asset","data":{},"extra":}"#,
            #"{"id":"\#(id)","type":"session.binary_asset","data":{"x":"#
                + String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65) + "}}"
        ]
        for input in examples {
            var envelope = CopilotAssetEnvelope(maximumBytes: 512)
            envelope.consume(Data(input.utf8))
            #expect(!envelope.isIgnorableBinaryAsset)
        }
    }

    @Test func largeAssetBeforeCurrentTurnDoesNotPoisonLiveActivity() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let asset = try copilotTestEvent("session.binary_asset", data: [
            "data": String(repeating: "YWJj", count: 4096),
            "mimeType": "image/png"
        ])
        try fixture.writeEvents([
            copilotTestEvent("session.idle"),
            asset,
            copilotTestEvent("assistant.turn_start", data: ["turnId": "current", "interactionId": "fresh"])
        ])
        let reader = fixture.reader(limits: .init(
            bytesPerRead: 1024, bytesPerSession: 1024, maximumLineBytes: 512
        ))
        var snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        for _ in 0..<100 {
            if !(await reader.hasPendingHistory()) { break }
            snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        }
        #expect(snapshot.isComplete)
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.sessions.first?.state == .working)
        #expect(snapshot.sessions.first?.liveness == .alive)
    }

    @Test func oversizedLifecycleDataStillFailsClosed() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let reader = fixture.reader(limits: .init(maximumLineBytes: 512))
        let original = try await reader.read(surfaceIDs: [fixture.surface])
        try fixture.append(try copilotTestEvent("assistant.turn_start", data: [
            "turnId": "current", "padding": String(repeating: "x", count: 2048)
        ]) + Data([10]))
        let snapshot = try await reader.read(surfaceIDs: [fixture.surface])
        #expect(snapshot.issues.contains(.malformedData))
        #expect(snapshot.issues.contains(.readLimitReached))
        #expect(snapshot.sessions == original.sessions)
    }

    @Test(arguments: [511, 512, 513, 16_384], [false, true])
    func toolCompletionPreservesOutcomeAcrossLineLimit(bytes: Int, success: Bool) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let start = UUID(), completionID = UUID()
        let completion = try sizedCompletion(id: completionID, parent: start, bytes: bytes, success: success)
        #expect(completion.count == bytes)
        try fixture.writeEvents([
            interactionEvent("assistant.turn_start", id: start, turn: "0", interaction: "current"),
            interactionEvent("tool.execution_start", parent: start, data: ["toolCallId": "tool", "toolName": "bash"])
        ])
        let reader = fixture.reader(limits: .init(bytesPerRead: 257, bytesPerSession: 257, maximumLineBytes: 512))
        let working = try await settled(reader, surface: fixture.surface)
        #expect(working.sessions.first?.state == .working)
        try fixture.append(completion + Data([10]))
        let completed = try await settled(reader, surface: fixture.surface)
        #expect(completed.isComplete)
        #expect(completed.issues.isEmpty)
        #expect(completed.sessions.first?.children.first?.state == (success ? .completed : .failed))
        try fixture.append(try interactionEvent("assistant.turn_end", parent: completionID, turn: "0") + Data([10]))
        let idle = try await settled(reader, surface: fixture.surface)
        #expect(idle.isComplete)
        #expect(idle.sessions.first?.state == .idle)
        #expect(!String(decoding: try JSONEncoder().encode(idle), as: UTF8.self).contains("PRIVATE_PAYLOAD"))
    }

    @Test(arguments: [1_048_575, 1_048_576, 1_048_577], [false, true])
    func defaultLineLimitHasNoOutcomeDiscontinuity(bytes: Int, success: Bool) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let start = UUID(), completion = UUID()
        let row = try sizedCompletion(id: completion, parent: start, bytes: bytes, success: success)
        #expect(row.count == bytes)
        try fixture.writeEvents([
            interactionEvent("assistant.turn_start", id: start, turn: "0", interaction: "current"),
            interactionEvent("tool.execution_start", parent: start, data: ["toolCallId": "tool", "toolName": "bash"]),
            row,
            interactionEvent("assistant.turn_end", parent: completion, turn: "0")
        ])
        let snapshot = try await settled(fixture.reader(), surface: fixture.surface)
        #expect(snapshot.isComplete && snapshot.issues.isEmpty)
        #expect(snapshot.sessions.first?.state == .idle)
        #expect(snapshot.sessions.first?.children.first?.state == (success ? .completed : .failed))
    }

    @Test(arguments: ["model.model_call_success", "model.messages_snapshot", "session.binary_asset", "assistant.message"])
    func validOpaquePayloadDoesNotPoisonLaterState(type: String) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let start = UUID(), message = UUID()
        try fixture.writeEvents([
            interactionEvent("assistant.turn_start", id: start, turn: "0", interaction: "current"),
            interactionEvent(type, id: message, parent: start, turn: "0", interaction: "current", data: [
                "content": String(repeating: "PRIVATE_PAYLOAD", count: 1024),
                "result": ["nested": [true, false, NSNull(), ["escaped": "\"\\\t😀"]]]
            ]),
            interactionEvent("assistant.message", id: UUID(), parent: message, turn: "0", interaction: "current"),
            interactionEvent("session.idle")
        ])
        let reader = fixture.reader(limits: .init(bytesPerRead: 1024, bytesPerSession: 1024, maximumLineBytes: 512))
        let snapshot = try await settled(reader, surface: fixture.surface)
        #expect(snapshot.isComplete)
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.sessions.first?.state == .idle)
        #expect(!String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("PRIVATE_PAYLOAD"))
    }

    @Test(arguments: [
        #"{"x":tru}"#, #"{"x":01}"#, #"{"x":1.}"#, #"{"x":[1,]}"#,
        #"{"x":"\q"}"#, #"{"x":"\uD800"}"#, #"{"x":1,"x":2}"#,
        #"{"x":{"a":1,"\u0061":2}}"#, #"{"x":true false}"#
    ])
    func opaquePayloadStillRequiresValidUnambiguousJSON(payload: String) {
        let row = #"{"id":"\#(UUID())","type":"session.binary_asset","data":\#(payload)}"#
        var envelope = CopilotAssetEnvelope(maximumBytes: 512)
        envelope.consume(Data(row.utf8))
        #expect(envelope.projectedBinaryAsset == nil)
    }

    @Test(arguments: [1, 2, 7, 257, 4096], [false, true])
    func metadataProjectionValidatesEscapesAndPayloadOrder(chunkSize: Int, payloadFirst: Bool) throws {
        let id = UUID(), parent = UUID()
        let payload = #""result":{"content":"\uD83D\uDE00\/\\\"\b\f\n\r\t"# +
            String(repeating: "PRIVATE_PAYLOAD", count: 1024) +
            #"","values":[null,true,false,-0,1.25e-4,{"escaped":"[]{}\""}]}"#
        let metadata = #""toolCallId":"tool","success":false,"turnId":"0","interactionId":"current""#
        let fields = payloadFirst ? payload + "," + metadata : metadata + "," + payload
        let row = Data(#"{"data":{\#(fields)},"agentId":"child","parentId":"\#(parent)","id":"\#(id)","type":"tool.execution_complete"}"#.utf8)
        var envelope = CopilotAssetEnvelope(maximumBytes: 512)
        for index in stride(from: 0, to: row.count, by: chunkSize) {
            envelope.consume(Data(row[index..<min(row.count, index + chunkSize)]))
            #expect(envelope.retainedByteCount < 4096)
        }
        let projected = try #require(envelope.projectedEvent)
        let event = try JSONDecoder().decode(CopilotEventProjection.self, from: projected)
        #expect(event.id == id.uuidString && event.parentEventID == parent.uuidString)
        #expect(event.agentID == "child" && event.toolCallID == "tool" && event.success == false)
        #expect(event.turnID == "0" && event.interactionID == "current")
        #expect(!String(decoding: projected, as: UTF8.self).contains("PRIVATE_PAYLOAD"))
    }

    @Test func opaquePayloadRejectsInvalidUTF8AndEveryTruncatedPrefix() throws {
        let prefix = Data(#"{"id":"\#(UUID())","type":"session.binary_asset","data":{"x":""#.utf8)
        let suffix = Data(#""}}"#.utf8)
        for invalid in [
            [0xc0, 0x80], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80],
            [0xe0, 0x80, 0x80], [0x80], [0xe2, 0x22], [0x1f]
        ] as [[UInt8]] {
            var envelope = CopilotAssetEnvelope(maximumBytes: 512)
            envelope.consume(prefix + Data(invalid) + suffix)
            #expect(envelope.projectedEvent == nil)
        }
        let row = prefix + Data("😀".utf8) + suffix
        var envelope = CopilotAssetEnvelope(maximumBytes: 512)
        for byte in row.dropLast() {
            envelope.consume(Data([byte]))
            #expect(envelope.projectedEvent == nil)
        }
        envelope.consume(Data([try #require(row.last)]))
        #expect(envelope.projectedEvent != nil)
        envelope.consume(Data("false".utf8))
        #expect(envelope.projectedEvent == nil)
    }

    @Test func arraysScalarsAndContainerShapesKeepTheOrdinaryDecoderContract() throws {
        for type in ["model.messages_snapshot", "assistant.message", "tool.execution_complete"] {
            for value in [#"["opaque",{"nested":[null,-2e+3]}]"#, "null", "true", "42", #""opaque""#, "{}"] {
                let row = Data(#"{"id":"\#(UUID())","type":"\#(type)","data":\#(value)}"#.utf8)
                var envelope = CopilotAssetEnvelope(maximumBytes: 512)
                for byte in row { envelope.consume(Data([byte])) }
                let ordinary = try? JSONDecoder().decode(CopilotEventProjection.self, from: row)
                if let ordinary {
                    let projected = try #require(envelope.projectedEvent)
                    let event = try JSONDecoder().decode(CopilotEventProjection.self, from: projected)
                    #expect(event.type == ordinary.type)
                    #expect(event.messageHasTurnMetadata == ordinary.messageHasTurnMetadata)
                    #expect(event.turnID == ordinary.turnID && event.interactionID == ordinary.interactionID)
                } else {
                    #expect(envelope.projectedEvent == nil)
                }
            }
        }
    }

    @Test func envelopeResourceBoundsAreExplicitAndFailClosed() throws {
        let id = UUID()
        func project(_ payload: String, limit: Int = 512) -> Data? {
            var envelope = CopilotAssetEnvelope(maximumBytes: limit)
            envelope.consume(Data(#"{"id":"\#(id)","type":"session.binary_asset","data":\#(payload)}"#.utf8))
            return envelope.projectedEvent
        }
        let keys = (0..<64).map { "\"k\($0)\":0" }.joined(separator: ",")
        #expect(project("{" + keys + "}") != nil)
        // Arbitrary payload maps are bounded by encoded key memory, not the
        // unrelated fixed cardinality of the observer's projection fields.
        #expect(project("{" + keys + ",\"extra\":0}") != nil)
        #expect(project("{\"" + String(repeating: "k", count: 1022) + "\":0}") != nil)
        #expect(project("{\"" + String(repeating: "k", count: 1023) + "\":0}") == nil)
        #expect(project("{\"x\":" + String(repeating: "[", count: 62) + "0" + String(repeating: "]", count: 62) + "}") != nil)
        #expect(project("{\"x\":" + String(repeating: "[", count: 63) + "0" + String(repeating: "]", count: 63) + "}") == nil)
        let manyKeys = (0..<63).map { "\"\(String(repeating: "k", count: 510))\($0)\":0" }.joined(separator: ",")
        #expect(project("{" + manyKeys + ",\"nested\":{" + manyKeys + "}}") != nil)
        #expect(project("{" + manyKeys + ",\"nested\":{" + manyKeys + ",\"nested\":{" + manyKeys + "}}}") == nil)
        #expect(project("{}", limit: 8) == nil)

        var tool = CopilotAssetEnvelope(maximumBytes: 512)
        tool.consume(try copilotTestEvent("tool.execution_complete", data: [
            "toolCallId": String(repeating: "a", count: 4096), "success": true
        ]))
        #expect(tool.projectedEvent == nil)
        // The same oversized scalar is irrelevant to an opaque event.
        var opaque = CopilotAssetEnvelope(maximumBytes: 512)
        opaque.consume(try copilotTestEvent("model.messages_snapshot", data: [
            "toolCallId": String(repeating: "a", count: 4096)
        ]))
        #expect(opaque.projectedEvent != nil)
    }

    @Test func metadataDuplicatesAndInvalidTokensAreNeverRecoveredAsValidEnvelopes() {
        let id = UUID()
        let prefix = #"{"id":"\#(id)","type":"tool.execution_complete","data":{"toolCallId":"tool","success":true"#
        for suffix in [
            #","success":false}}"#, #","s\u0075ccess":false}}"#, #",}}"#,
            #"},"agentId":"child","agentId":"other"}"#, #"},"id":"\#(UUID())"}"#,
            #","result":{"x":+1}}}"#, #","result":{"x":1e}}}"#, #","result":[,1]}}"#,
            #","result":{"x":Infinity}}}"#, #","result":{"x":undefined}}}"#
        ] {
            var envelope = CopilotAssetEnvelope(maximumBytes: 512)
            for byte in (prefix + suffix).utf8 { envelope.consume(Data([byte])) }
            #expect(envelope.projectedEvent == nil)
        }
    }

    @Test(arguments: [false, true])
    func incompleteOversizedAppendNeverPublishesBeforeValidNewline(malformed: Bool) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([copilotTestEvent("session.idle")])
        let reader = fixture.reader(limits: .init(bytesPerSession: 1024, maximumLineBytes: 512))
        let before = try await settled(reader, surface: fixture.surface)
        let row = try copilotTestEvent("model.messages_snapshot", data: [
            "messages": String(repeating: "PRIVATE_PAYLOAD", count: 512)
        ])
        let split = row.count / 2
        try fixture.append(row.prefix(split))
        let partial = try await settled(reader, surface: fixture.surface)
        #expect(partial.issues.contains(.loadingHistory))
        #expect(!partial.issues.contains(.malformedData))
        #expect(partial.sessions == before.sessions)
        if malformed {
            try fixture.append(Data("\"\n".utf8))
        } else {
            try fixture.append(row.suffix(row.count - split))
            let unterminated = try await settled(reader, surface: fixture.surface)
            #expect(unterminated.issues.contains(.loadingHistory))
            #expect(unterminated.sessions == before.sessions)
            try fixture.append(Data([10]))
        }
        try fixture.append(try interactionEvent("assistant.turn_start", turn: "0", interaction: "fresh") + Data([10]))
        let after = try await settled(reader, surface: fixture.surface)
        if malformed {
            #expect(after.issues.contains(.malformedData) && after.issues.contains(.readLimitReached))
            #expect(after.sessions == before.sessions)
        } else {
            #expect(after.isComplete && after.issues.isEmpty)
            #expect(after.sessions.first?.state == .working)
        }
    }

    @Test(arguments: ["owner", "turn", "interaction"])
    func oversizedCompletionCannotBorrowOtherOwnerOrTurnAndReplayCannotEndFreshWork(mismatch: String) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let turn = UUID(), tool = UUID(), completed = UUID()
        try fixture.writeEvents([
            interactionEvent("subagent.started", owner: "child", data: ["toolCallId": "spawn", "agentDisplayName": "Child"]),
            interactionEvent("assistant.turn_start", id: turn, owner: "child", turn: "0", interaction: "current"),
            interactionEvent("tool.execution_start", id: tool, parent: turn, owner: "child",
                             data: ["toolCallId": "tool", "toolName": "view"])
        ])
        let reader = fixture.reader(limits: .init(maximumLineBytes: 512))
        let before = try await settled(reader, surface: fixture.surface)
        #expect(before.sessions.first?.children.first?.state == .working)
        let payload: [String: Any] = [
            "toolCallId": "tool", "success": true, "result": String(repeating: "PRIVATE_PAYLOAD", count: 512)
        ]
        try fixture.append(try interactionEvent("tool.execution_complete", parent: tool,
            owner: mismatch == "owner" ? "other" : "child",
            turn: mismatch == "turn" ? "1" : "0",
            interaction: mismatch == "interaction" ? "old" : "current", data: payload) + Data([10]))
        let unmatched = try await settled(reader, surface: fixture.surface)
        #expect(unmatched.sessions.first?.children.first { $0.id == "child" }?.state == .working)
        let valid = try interactionEvent("tool.execution_complete", id: completed, parent: tool,
            owner: "child", turn: "0", interaction: "current", data: payload)
        let end = try interactionEvent("assistant.turn_end", parent: completed, owner: "child", turn: "0")
        try fixture.append(valid + Data([10]) + end + Data([10]))
        let idle = try await settled(reader, surface: fixture.surface)
        #expect(!idle.issues.contains(.malformedData))
        #expect(idle.sessions.first?.children.first { $0.id == "child" }?.state == .idle)
        try fixture.append(try interactionEvent("assistant.turn_start", owner: "child", turn: "0", interaction: "next") + Data([10]))
        let next = try await settled(reader, surface: fixture.surface)
        try fixture.append(valid + Data([10]) + end + Data([10]))
        let replayed = try await settled(reader, surface: fixture.surface)
        #expect(replayed.sessions == next.sessions)
        #expect(replayed.sessions.first?.children.first { $0.id == "child" }?.state == .working)
    }

    @Test(arguments: ["valid", "partial", "null", "wrong-owner", "wrong-turn", "wrong-interaction"])
    func oversizedMessageKeepsAdvisoryAttributionConservative(tags: String) async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let first = UUID(), current = UUID(), message = UUID()
        var data: [String: Any] = [
            "turnId": tags == "wrong-turn" ? "1" : "0",
            "interactionId": tags == "wrong-interaction" ? "old" : "current",
            "content": String(repeating: "PRIVATE_PAYLOAD", count: 512)
        ]
        if tags == "partial" { data.removeValue(forKey: "interactionId") }
        if tags == "null" { data["interactionId"] = NSNull() }
        try fixture.writeEvents([
            interactionEvent("assistant.turn_start", id: first, turn: "0", interaction: "old"),
            interactionEvent("assistant.turn_end", parent: first, turn: "0"),
            interactionEvent("assistant.turn_start", id: current, turn: "0", interaction: "current"),
            interactionEvent("assistant.message", id: message, parent: current,
                             owner: tags == "wrong-owner" ? "other" : nil, data: data),
            interactionEvent("assistant.turn_end", parent: message, turn: "0")
        ])
        let snapshot = try await settled(fixture.reader(limits: .init(maximumLineBytes: 512)), surface: fixture.surface)
        #expect(!snapshot.issues.contains(.malformedData))
        #expect(snapshot.sessions.first?.state == (tags == "valid" ? .idle : .unknown))
        #expect(snapshot.issues.contains(.ambiguousTurn) == (tags != "valid"))
    }

    @Test func unsupportedLifecycleAndMalformedMetadataDoNotBecomeHealthyByProjection() async throws {
        for row in try [
            copilotTestEvent("tool.execution_future", data: ["content": String(repeating: "x", count: 1024)]),
            copilotTestEvent("tool.execution_complete", data: ["toolCallId": "tool", "success": "true",
                                                             "result": String(repeating: "x", count: 1024)])
        ] {
            let fixture = try CopilotReaderFixture()
            defer { fixture.remove() }
            try fixture.writeEvents([
                interactionEvent("assistant.turn_start", turn: "0", interaction: "current"), row
            ])
            let snapshot = try await settled(fixture.reader(limits: .init(maximumLineBytes: 512)), surface: fixture.surface)
            #expect(!snapshot.isComplete)
            #expect(snapshot.issues.contains(.unsupportedFormat) || snapshot.issues.contains(.malformedData))
            #expect(snapshot.sessions.first?.state == .unknown)
        }
    }

    @Test func defaultBudgetsRecoverLargeSyntheticHistoryThroughSidebar() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        let start = UUID(), tool = UUID(), completion = UUID()
        let rows = try [
            interactionEvent("assistant.turn_start", id: start, turn: "0", interaction: "current"),
            interactionEvent("tool.execution_start", id: tool, parent: start, data: [
                "toolCallId": "tool", "toolName": "view",
                "arguments": ["query": String(repeating: "PRIVATE_PAYLOAD", count: 80_000)]
            ]),
            sizedCompletion(id: completion, parent: tool, bytes: 1_577_176, success: true)
        ] + ["model.model_call_success", "model.messages_snapshot", "model.model_call_success", "model.messages_snapshot"].map {
            try copilotTestEvent($0, data: ["messages": String(repeating: "x", count: 2_611_759)])
        } + [copilotTestEvent("session.binary_asset", data: ["data": String(repeating: "Y", count: 1_711_934)])]
        try fixture.writeEvents(rows)
        let reader = fixture.reader()
        let limits = CopilotReaderLimits()
        #expect(limits.maximumLineBytes == 1_048_576 && limits.bytesPerSession == 4_194_304)
        let size = rows.reduce(0) { $0 + $1.count + 1 }
        let expectedReads = (size + limits.bytesPerSession - 1) / limits.bytesPerSession
        var reads = 0
        var snapshot: CopilotSnapshot?
        let started = ContinuousClock.now
        var maximumBatch = Duration.zero
        repeat {
            let batchStart = ContinuousClock.now
            snapshot = try await reader.read(surfaceIDs: [fixture.surface])
            maximumBatch = max(maximumBatch, batchStart.duration(to: .now))
            reads += 1
        } while await reader.hasPendingHistory() && reads < expectedReads + 1
        let working = try #require(snapshot)
        #expect(reads == expectedReads)
        #expect(working.isComplete && working.issues.isEmpty)
        #expect(working.sessions.first?.state == .working)
        #expect(tree(working, fixture: fixture).sessions.first?.state == .working)
        try fixture.append(try interactionEvent("assistant.turn_end", parent: completion, turn: "0") + Data([10]))
        let idle = try await settled(reader, surface: fixture.surface)
        let projected = tree(idle, fixture: fixture)
        #expect(idle.isComplete && projected.availability == .ready)
        #expect(projected.sessions.map(\.id) == [fixture.sessionID])
        #expect(projected.sessions.first?.surfaceID == fixture.surface)
        #expect(projected.sessions.first?.workspaceID == fixture.workspace)
        #expect(projected.sessions.first?.state == .idle)
        let publicJSON = String(decoding: try JSONEncoder().encode(idle), as: UTF8.self)
        #expect(!publicJSON.contains("PRIVATE_PAYLOAD") && !publicJSON.contains("messages"))
        var usage = rusage()
        let rss = getrusage(RUSAGE_SELF, &usage) == 0 ? usage.ru_maxrss : -1
        print("READER121_SYNTHETIC bytes=\(size) reads=\(reads) elapsed=\(started.duration(to: .now)) maximumBatch=\(maximumBatch) processPeakRSSBytes=\(rss)")
    }

    @Test(arguments: [64, 65, 256], [false, true])
    func arbitraryAssetAndToolMapsRecoverAcrossOrdinaryLineLimit(keyCount: Int, oversized: Bool) async throws {
        for type in ["session.binary_asset", "tool.execution_complete"] {
            let fixture = try CopilotReaderFixture()
            defer { fixture.remove() }
            let start = UUID(), tool = UUID(), completion = UUID()
            let row = try widePayloadEvent(
                type, id: completion, parent: tool, keyCount: keyCount,
                targetBytes: oversized ? 1_200_000 : 1_048_572
            )
            #expect((row.count > CopilotReaderLimits().maximumLineBytes) == oversized)
            let ordinary = try JSONDecoder().decode(CopilotEventProjection.self, from: row)
            #expect(ordinary.type == type)
            try fixture.writeEvents([
                interactionEvent("assistant.turn_start", id: start, turn: "0", interaction: "current"),
                interactionEvent("tool.execution_start", id: tool, parent: start,
                                 data: ["toolCallId": "tool", "toolName": "view"])
            ])
            let reader = fixture.reader(limits: .init(bytesPerRead: 262_144, bytesPerSession: 262_144))
            let working = try await settled(reader, surface: fixture.surface)
            #expect(tree(working, fixture: fixture).sessions.first?.state == .working)
            try fixture.append(row + Data([10]))
            let afterPayload = try await settled(reader, surface: fixture.surface)
            #expect(afterPayload.isComplete && afterPayload.issues.isEmpty)
            #expect(afterPayload.sessions.first?.state == .working)
            let endParent: UUID
            if type == "session.binary_asset" {
                endParent = UUID()
                try fixture.append(try interactionEvent(
                    "tool.execution_complete", id: endParent, parent: tool,
                    turn: "0", interaction: "current", data: ["toolCallId": "tool", "success": true]
                ) + Data([10]))
            } else {
                endParent = completion
            }
            try fixture.append(try interactionEvent("assistant.turn_end", parent: endParent, turn: "0") + Data([10]))
            let idle = try await settled(reader, surface: fixture.surface)
            let projected = tree(idle, fixture: fixture)
            #expect(idle.isComplete && idle.issues.isEmpty)
            #expect(projected.availability == .ready)
            #expect(projected.sessions.map(\.id) == [fixture.sessionID])
            #expect(projected.sessions.first?.surfaceID == fixture.surface)
            #expect(projected.sessions.first?.state == .idle)
            let published = String(decoding: try JSONEncoder().encode(idle), as: UTF8.self)
            #expect(!published.contains("PRIVATE_MAP_VALUE") && !published.contains("structuredContent"))
        }
    }

    @Test(arguments: [64, 65, 256], [1, 257, 262_144])
    func arbitraryPayloadMapProjectionSurvivesChunkBoundaries(keyCount: Int, chunkSize: Int) throws {
        for type in ["session.binary_asset", "tool.execution_complete"] {
            let id = UUID(), parent = UUID()
            let row = try widePayloadEvent(type, id: id, parent: parent, keyCount: keyCount, targetBytes: 32_768)
            let ordinary = try JSONDecoder().decode(CopilotEventProjection.self, from: row)
            var envelope = CopilotAssetEnvelope(maximumBytes: 512)
            var peak = 0
            for index in stride(from: 0, to: row.count, by: chunkSize) {
                envelope.consume(Data(row[index..<min(row.count, index + chunkSize)]))
                peak = max(peak, envelope.retainedByteCount)
            }
            #expect(peak < 8192)
            let projected = try #require(envelope.projectedEvent)
            let event = try JSONDecoder().decode(CopilotEventProjection.self, from: projected)
            #expect(event.id == ordinary.id && event.parentEventID == ordinary.parentEventID)
            #expect(event.type == type && event.toolCallID == ordinary.toolCallID)
            #expect(event.success == ordinary.success && event.turnID == ordinary.turnID)
            #expect(event.interactionID == ordinary.interactionID)
            #expect(!String(decoding: projected, as: UTF8.self).contains("PRIVATE_MAP_VALUE"))
        }
    }

    @Test func arbitraryMapStillRejectsExactAggregateKeyBudgetOverflow() throws {
        func encodedKey(_ index: Int, bytes: Int) -> String {
            let prefix = "k\(index)"
            return "\"" + prefix + String(repeating: "x", count: bytes - prefix.utf8.count - 2) + "\""
        }
        let firstKeys = (0..<65).map { encodedKey($0, bytes: 1000) + ":0" }.joined(separator: ",")
        // Root id/type/data keys consume 16 encoded bytes; metadata consumes 10.
        // The inner map's 65,510 bytes make exactly 65,536 across open objects.
        for extraByte in [0, 1] {
            let payload = firstKeys + "," + encodedKey(65, bytes: 510 + extraByte) + ":0"
            let row = Data(#"{"id":"\#(UUID())","type":"session.binary_asset","data":{"metadata":{\#(payload)}}}"#.utf8)
            _ = try JSONDecoder().decode(CopilotEventProjection.self, from: row)
            var envelope = CopilotAssetEnvelope(maximumBytes: 512)
            for index in stride(from: 0, to: row.count, by: 257) {
                envelope.consume(Data(row[index..<min(row.count, index + 257)]))
            }
            #expect((envelope.projectedEvent != nil) == (extraByte == 0))
        }
    }

    @Test func wideOpaqueMapsStillRejectDuplicatesAndMalformedValues() {
        let fields = (0..<256).map { "\"k\($0)\":0" }.joined(separator: ",")
        for suffix in [#""k65":1"#, #""\u006b65":1"#, #""extra":[1,]"#] {
            let row = Data(#"{"id":"\#(UUID())","type":"session.binary_asset","data":{"metadata":{\#(fields),\#(suffix)}}}"#.utf8)
            var envelope = CopilotAssetEnvelope(maximumBytes: 512)
            for index in stride(from: 0, to: row.count, by: 257) {
                envelope.consume(Data(row[index..<min(row.count, index + 257)]))
            }
            #expect(envelope.projectedEvent == nil)
        }
    }

    private func widePayloadEvent(
        _ type: String, id: UUID, parent: UUID, keyCount: Int, targetBytes: Int
    ) throws -> Data {
        let metadata = Dictionary(uniqueKeysWithValues: (0..<keyCount).map { ("k\($0)", "PRIVATE_MAP_VALUE") })
        func encode(padding: Int) throws -> Data {
            let content = String(repeating: "YWJj", count: padding / 4)
            if type == "session.binary_asset" {
                return try interactionEvent(type, id: id, parent: parent, data: [
                    "data": content, "mimeType": "image/png", "metadata": metadata
                ])
            }
            return try interactionEvent(type, id: id, parent: parent, turn: "0", interaction: "current", data: [
                "toolCallId": "tool", "success": true,
                "result": ["content": [["type": "text", "text": content]], "structuredContent": metadata]
            ])
        }
        let base = try encode(padding: 0)
        try #require(base.count <= targetBytes)
        let row = try encode(padding: targetBytes - base.count)
        #expect((targetBytes - 3...targetBytes).contains(row.count))
        return row
    }

    private func tree(_ snapshot: CopilotSnapshot, fixture: CopilotReaderFixture) -> SidebarCopilotTree {
        let topology = SidebarTopology(HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: true, surfaceMetadataAvailable: true, workspacePathsAvailable: false,
            workspaces: [
                .init(id: fixture.workspace, title: .available("Synthetic"), detail: .available(nil),
                      isSelected: .available(true), isPinned: .available(false), unreadCount: .available(0),
                      rootPath: .unavailable, projectRootPath: .unavailable, surfaces: .available([
                        .init(id: fixture.surface, title: "Synthetic", kind: .terminal, isFocused: true,
                              isPinned: false, unreadCount: 0, workingDirectory: .unavailable)
                      ]))
            ], windowID: UUID()
        ))
        return SidebarCopilotTree.project(snapshot, onto: topology, now: snapshot.generatedAt)
    }

    private func sizedCompletion(id: UUID, parent: UUID, bytes: Int, success: Bool) throws -> Data {
        let fields: [String: Any] = [
            "toolCallId": "tool", "success": success, "result": "PRIVATE_PAYLOAD"
        ]
        let base = try interactionEvent("tool.execution_complete", id: id, parent: parent,
                                        turn: "0", interaction: "current", data: fields)
        var padded = fields
        try #require(base.count <= bytes)
        padded["result"] = "PRIVATE_PAYLOAD" + String(repeating: "x", count: bytes - base.count)
        return try interactionEvent("tool.execution_complete", id: id, parent: parent,
                                    turn: "0", interaction: "current", data: padded)
    }

    private func settled(_ reader: CopilotSessionReader, surface: UUID) async throws -> CopilotSnapshot {
        var snapshot = try await reader.read(surfaceIDs: [surface])
        for _ in 0..<256 {
            if !(await reader.hasPendingHistory()) { break }
            snapshot = try await reader.read(surfaceIDs: [surface])
        }
        #expect(await reader.hasPendingHistory() == false)
        return snapshot
    }
}
