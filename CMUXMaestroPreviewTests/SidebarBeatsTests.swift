import Foundation
import Testing
@testable import CMUXMaestroPreview

@MainActor
struct SidebarBeatsTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts/test-fixtures")

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("beats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func newYork(_ identifier: String = "America/New_York") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    // MARK: Cron parity with the orchestrator (shared fixture)

    @Test func cronFixtureMatchesTheOrchestrator() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("beats-cron-cases.json"))
        let cases = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let valid = try #require(cases["valid"] as? [[String]])
        let invalid = try #require(cases["invalid"] as? [String])
        for pair in valid {
            #expect(try BeatsCron(pair[0]).expression == pair[1], "\(pair[0].debugDescription)")
        }
        for expression in invalid {
            #expect(throws: BeatsError.self, "\(expression.debugDescription)") { try BeatsCron(expression) }
        }
    }

    @Test func weekdaySevenIsSundayAndBothDayFieldsAreOred() throws {
        #expect(try BeatsCron("0 0 * * 7").weekdays == [0])
        let spec = try BeatsCron("0 9 13 * 5")
        #expect(spec.matchesDay(month: 10, day: 9, weekday: 5))     // a Friday
        #expect(spec.matchesDay(month: 10, day: 13, weekday: 2))    // the 13th, a Tuesday
        #expect(!spec.matchesDay(month: 10, day: 14, weekday: 3))
        let weekdays = try BeatsCron("0 9 * * 1-5")
        #expect(weekdays.matchesDay(month: 10, day: 9, weekday: 5) && !weekdays.matchesDay(month: 10, day: 10, weekday: 6))
    }

    @Test func nextTimesAreLocalAndSkipNonexistentMinutes() throws {
        let calendar = newYork()
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 20)))
        let times = try BeatsCron("30 9 * * 1-5").nextTimes(after: start, count: 3, calendar: calendar)
        let parts = times.map { calendar.dateComponents([.month, .day, .hour, .minute], from: $0) }
        #expect(parts.map(\.day) == [12, 13, 14] && parts.allSatisfy { $0.hour == 9 && $0.minute == 30 })
        // 2026-03-08 02:30 does not exist in New York.
        let spring = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12)))
        let skipped = try BeatsCron("30 2 * * *").nextTimes(after: spring, count: 2, calendar: calendar)
        #expect(skipped.map { calendar.component(.day, from: $0) } == [9, 10])
    }

    @Test func repeatedLocalMinuteAppearsOnce() throws {
        let calendar = newYork()
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12)))
        let times = try BeatsCron("30 1 * * *").nextTimes(after: start, count: 2, calendar: calendar)
        #expect(times.map { calendar.component(.day, from: $0) } == [1, 2])
    }

    // MARK: Store

    @Test func sampleStoreFromTheOrchestratorDecodesAndRoundTrips() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("beats-store-sample.json"))
        let state = try SidebarBeatsState.decode(data)
        #expect(state.beats.count == 2)
        #expect(state.beats[0].lastFiredMinute == nil && state.beats[1].lastFiredMinute == "2026-10-05T09:00")
        #expect(state.beats[0].prompt == "Check the board.\nSummarize blockers / risks.")
        #expect(state.beats[1].status == .needsRecovery)
        let again = try SidebarBeatsState.decode(state.encoded())
        #expect(again == state)
        #expect(String(decoding: try state.encoded(), as: UTF8.self).contains("\"lastFiredMinute\":null"))
    }

    @Test func malformedStoresAreRefused() throws {
        let sample = try Data(contentsOf: Self.fixtures.appendingPathComponent("beats-store-sample.json"))
        var object = try #require(JSONSerialization.jsonObject(with: sample) as? [String: Any])
        for mutate: (inout [String: Any]) -> Void in [
            { $0["version"] = 2 },
            { $0["extra"] = true },
            { var beats = $0["beats"] as! [[String: Any]]; beats[0]["surprise"] = 1; $0["beats"] = beats },
            { var beats = $0["beats"] as! [[String: Any]]; beats[0].removeValue(forKey: "cron"); $0["beats"] = beats },
            { var beats = $0["beats"] as! [[String: Any]]; beats[0]["cron"] = "bogus"; $0["beats"] = beats },
            { var beats = $0["beats"] as! [[String: Any]]; beats[0]["id"] = beats[1]["id"]; $0["beats"] = beats },
            { var beats = $0["beats"] as! [[String: Any]]; beats[0]["sessionId"] = "not-a-uuid"; $0["beats"] = beats },
            { var beats = $0["beats"] as! [[String: Any]]; beats[0]["prompt"] = "bell\u{07}"; $0["beats"] = beats }
        ] {
            var copy = object
            mutate(&copy)
            #expect(throws: BeatsError.self) {
                _ = try SidebarBeatsState.decode(JSONSerialization.data(withJSONObject: copy))
            }
        }
        object["version"] = 1
        _ = try SidebarBeatsState.decode(JSONSerialization.data(withJSONObject: object))
        #expect(throws: BeatsError.self) { _ = try SidebarBeatsState.decode(Data("nope".utf8)) }
    }

    // MARK: Human operations

    @Test func humanOperationsFollowTheRecoveryPolicy() throws {
        var state = SidebarBeatsState()
        let first = UUID(), second = UUID()
        let beat = try state.create(session: first, cron: "  0   9 * * 1-5", prompt: "Plan the day")
        #expect(beat.cron == "0 9 * * 1-5" && beat.status == .active)
        try state.pause(id: beat.id)
        #expect(state.beats[0].status == .paused)
        try state.enable(id: beat.id)
        #expect(state.beats[0].status == .active)
        // Editing never changes whether recurrence runs.
        try state.edit(id: beat.id, cron: "30 9 * * *", prompt: nil, session: nil)
        #expect(state.beats[0].status == .active && state.beats[0].revision == 4)
        // Repair to another session leaves it paused behind the human gate, never silently resumed.
        try state.edit(id: beat.id, cron: nil, prompt: "New words", session: second)
        #expect(state.beats[0].sessionId == second.uuidString.lowercased())
        #expect(state.beats[0].status == .needsRecovery && state.beats[0].prompt == "New words")
        try state.enable(id: beat.id)
        #expect(state.beats[0].status == .active)
        // A human cannot enable a Beat whose target ended until another session is chosen.
        state.beats[0].targetEnded = true
        #expect(throws: BeatsError.self) { try state.enable(id: beat.id) }
        try state.edit(id: beat.id, cron: nil, prompt: nil, session: first)
        #expect(state.beats[0].status == .needsRecovery)
        try state.delete(id: beat.id)
        #expect(state.beats.isEmpty)
        #expect(throws: BeatsError.self) { try state.delete(id: beat.id) }
    }

    @Test func validationAndLimits() throws {
        var state = SidebarBeatsState()
        let session = UUID()
        for (cron, prompt) in [("nope", "x"), ("* * * * *", "   "), ("* * * * *", String(repeating: "a", count: 4097)),
                               ("* * * * *", "bell\u{07}")] {
            #expect(throws: BeatsError.self) { _ = try state.create(session: session, cron: cron, prompt: prompt) }
        }
        for _ in 0..<BeatsLimits.maximumPerSession { _ = try state.create(session: session, cron: "* * * * *", prompt: "x") }
        #expect(throws: BeatsError.self) { _ = try state.create(session: session, cron: "* * * * *", prompt: "x") }
        _ = try state.create(session: UUID(), cron: "* * * * *", prompt: "other session is fine")
    }

    // MARK: File

    @Test func fileStoreIsPrivateAtomicAndShared() throws {
        let root = try temporaryRoot().appendingPathComponent("Beats")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = SidebarBeatsFile(root: root)
        #expect(try file.read().beats.isEmpty)
        let session = UUID()
        let id = try file.mutate { try $0.create(session: session, cron: "*/5 * * * *", prompt: "tick").id }
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("beats.json").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(try file.read().beats.map(\.id) == [id])
        let before = try Data(contentsOf: root.appendingPathComponent("beats.json"))
        #expect(throws: BeatsError.self) { try file.mutate { try $0.edit(id: id, cron: "bogus", prompt: nil, session: nil) } }
        #expect(try Data(contentsOf: root.appendingPathComponent("beats.json")) == before)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".pending") }
        #expect(leftovers.isEmpty)
    }

    @Test func concurrentWritersLoseNothing() async throws {
        let root = try temporaryRoot().appendingPathComponent("Beats")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = SidebarBeatsFile(root: root)
        let sessions = (0..<20).map { _ in UUID() }
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask { _ = try? file.mutate { _ = try $0.create(session: session, cron: "0 9 * * *", prompt: "x") } }
            }
        }
        #expect(try file.read().beats.count == 20)
    }

    @Test func symlinkedStoreIsRefused() throws {
        let root = try temporaryRoot().appendingPathComponent("Beats")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let elsewhere = root.deletingLastPathComponent().appendingPathComponent("elsewhere.json")
        try Data("{\"beats\":[],\"version\":1}\n".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("beats.json"), withDestinationURL: elsewhere)
        #expect(throws: BeatsError.self) { _ = try SidebarBeatsFile(root: root).read() }
    }

    @Test func controllerRefreshesAndReportsFailuresWithoutPersisting() throws {
        let root = try temporaryRoot().appendingPathComponent("Beats")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let controller = SidebarBeatsController(file: SidebarBeatsFile(root: root))
        #expect(controller.beats.isEmpty && controller.notice == nil)
        let session = UUID()
        #expect(controller.perform { _ = try $0.create(session: session, cron: "0 9 * * *", prompt: "go") } == nil)
        #expect(controller.beats.count == 1)
        #expect(controller.perform { _ = try $0.create(session: session, cron: "bad", prompt: "go") } != nil)
        #expect(controller.beats.count == 1)
        // Another writer (the orchestrator) changes the store; refresh picks it up.
        _ = try SidebarBeatsFile(root: root).mutate { try $0.delete(id: $0.beats[0].id) }
        controller.refresh()
        #expect(controller.beats.isEmpty)
    }
}
