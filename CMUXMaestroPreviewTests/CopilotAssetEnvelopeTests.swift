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
}
