import Foundation
import os
import Testing
@testable import CMUXMaestroPreview

struct CopilotSetupObservationTests {
    @Test func independentBoundariesPreserveOutstandingBegins() {
        let observation = CopilotSetupObservation()
        observation.begin(.cancelCall)
        observation.begin(.execute)
        observation.begin(.stopGroup)
        observation.begin(.quiescence)
        observation.note(.quiescence, .init(reason: .memberQueryUnknown, result: 0, error: 3, pid: 42))
        observation.end(.quiescence)
        let before = observation.snapshot()
        #expect(before.boundaries[0].begin == 1 && before.boundaries[0].end == 0)
        #expect(before.boundaries[2].begin == 2 && before.boundaries[2].end == 0)
        #expect(before.boundaries[5].detail.reason == .memberQueryUnknown)
        #expect(before.boundaries[5].detail.error == 3)
        observation.end(.cancelCall)
        let after = observation.snapshot()
        #expect(after.boundaries[0].end > after.boundaries[5].end)
        #expect(after.boundaries[2] == before.boundaries[2])
        #expect(!after.invalidTransition)
    }

    @Test func resumeIsDistinctFromAsyncCallerProgress() {
        let observation = CopilotSetupObservation()
        observation.begin(.invoke)
        observation.begin(.metadata)
        observation.begin(.taskValue)
        observation.begin(.resume)
        observation.end(.resume)
        let snapshot = observation.snapshot()
        #expect(snapshot.boundaries[10].end > snapshot.boundaries[10].begin)
        for index in [11, 12, 13] {
            #expect(snapshot.boundaries[index].begin > 0)
            #expect(snapshot.boundaries[index].end == 0)
        }
    }

    @Test func repeatedQueriesHaveFixedSizeAndExplicitUnknownDetails() throws {
        let observation = CopilotSetupObservation()
        for _ in 0..<10_000 {
            observation.begin(.quiescence)
            observation.note(.quiescence, .init(reason: .livingMember, pid: 42, status: 2))
            observation.end(.quiescence)
        }
        observation.begin(.quiescence)
        let snapshot = observation.snapshot()
        #expect(snapshot.boundaries.count == 14)
        #expect(snapshot.boundaries[5].detail.reason == .unknown)
        #expect(snapshot.boundaries[5].detailSequence == 0)
        #expect(snapshot.boundaries[5].end == 0)
        #expect(!snapshot.overflow && !snapshot.invalidTransition)
        let data = try JSONEncoder().encode(snapshot)
        #expect(data.count <= 8192)
        let decoded = try JSONDecoder().decode(CopilotSetupObservation.Snapshot.self, from: data)
        #expect(decoded.boundaries == snapshot.boundaries)
    }

    @Test func overflowAndOverlappingBeginsCannotLookComplete() {
        let storage = OSAllocatedUnfairLock(initialState: CopilotSetupObservation.Snapshot(sequence: UInt64.max - 1))
        let observation = CopilotSetupObservation(storage: storage)
        observation.begin(.cancelCall)
        observation.begin(.cancelCall)
        observation.end(.cancelCall)
        let snapshot = observation.snapshot()
        #expect(snapshot.overflow && snapshot.invalidTransition)
        #expect(snapshot.sequence == UInt64.max)
        #expect(snapshot.boundaries[0].begin == UInt64.max)
        #expect(snapshot.boundaries[0].end == 0)
    }

    @Test func finiteRunnerRecordsReapBeforeResumeAndAsyncReturn() async {
        let storage = OSAllocatedUnfairLock(initialState: CopilotSetupObservation.Snapshot())
        let observation = CopilotSetupObservation(storage: storage)
        let runner = LocalCopilotSetupRunner(observation: observation)
        #expect(await runner.run(executable: URL(fileURLWithPath: "/usr/bin/true"),
                                 arguments: [], path: "/usr/bin:/bin") == .exited(0))
        let snapshot = storage.withLock { $0 }
        #expect(snapshot.availability == .available)
        #expect(!snapshot.invalidTransition && !snapshot.overflow)
        #expect(snapshot.boundaries[9].end > 0)
        #expect(snapshot.boundaries[9].end < snapshot.boundaries[2].end)
        #expect(snapshot.boundaries[2].end < snapshot.boundaries[10].begin)
        // Resumption can run the async caller before resume() returns.
        #expect(snapshot.boundaries[10].end == 0 || snapshot.boundaries[10].end > snapshot.boundaries[10].begin)
        #expect(snapshot.boundaries[11].end > snapshot.boundaries[10].begin)
        #expect(snapshot.boundaries[0].begin == 0)
        #expect(snapshot.boundaries[5].detail.reason == .quiescent)
        #expect(snapshot.boundaries[9].detail.result > 1)
    }

    @Test func finiteEmptyMetadataPreservesResultAndCallerBoundaries() async {
        let storage = OSAllocatedUnfairLock(initialState: CopilotSetupObservation.Snapshot())
        let observation = CopilotSetupObservation(storage: storage)
        let runner = LocalCopilotSetupRunner(observation: observation)
        guard case .failed(.unavailable) = await runner.metadata(
            executable: URL(fileURLWithPath: "/usr/bin/true"), path: "/usr/bin:/bin") else {
            Issue.record("Empty metadata must still fail unavailable")
            return
        }
        let snapshot = storage.withLock { $0 }
        #expect(!snapshot.invalidTransition && !snapshot.overflow)
        for index in [2, 3, 11, 12] {
            #expect(snapshot.boundaries[index].end > snapshot.boundaries[index].begin)
            #expect(snapshot.boundaries[index].begin > 0)
        }
        #expect(snapshot.boundaries[10].begin > snapshot.boundaries[2].end)
        #expect(snapshot.boundaries[11].end < snapshot.boundaries[12].end)
    }

    @Test func numericRecordsPreserveThreadErrorAndWorstCaseSize() throws {
        let storage = OSAllocatedUnfairLock(initialState: CopilotSetupObservation.Snapshot(sequence: UInt64.max - 100))
        let observation = CopilotSetupObservation(storage: storage)
        errno = EDOM
        for boundary in CopilotSetupObservation.Boundary.allCases {
            observation.begin(boundary)
            observation.note(boundary, .init(reason: .memberQueryUnknown, result: Int32.min,
                error: Int32.max, pid: Int32.max, status: Int32.max, code: Int32.max, count: Int32.max))
            observation.end(boundary)
        }
        let snapshot = observation.snapshot()
        #expect(errno == EDOM)
        let data = try JSONEncoder().encode(snapshot)
        #expect(data.count <= 8192)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let boundaries = try #require(json["boundaries"] as? [[String: Any]])
        for boundary in boundaries {
            for (key, value) in boundary where key != "detail" { #expect(value is NSNumber) }
            let detail = try #require(boundary["detail"] as? [String: Any])
            #expect(detail.values.allSatisfy { $0 is NSNumber })
        }
    }
}
