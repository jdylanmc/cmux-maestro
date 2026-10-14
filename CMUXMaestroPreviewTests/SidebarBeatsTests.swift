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

    @Test func previewsMatchCopilotsRecordedNextRuns() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("beats-cron-cases.json"))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let oracle = try #require(root["copilotNextRuns"] as? [String: Any])
        let zone = try #require(oracle["timeZone"] as? String)
        let from = try #require(oracle["from"] as? String)
        let calendar = newYork(zone)
        let parse = DateFormatter()
        parse.calendar = calendar; parse.timeZone = calendar.timeZone
        parse.locale = Locale(identifier: "en_US_POSIX"); parse.dateFormat = "yyyy-MM-dd HH:mm"
        let start = try #require(parse.date(from: from))
        let cases = try #require(oracle["cases"] as? [[String: Any]])
        for item in cases {
            let cron = try #require(item["cron"] as? String)
            let expected = try #require(item["next"] as? [String])
            let times = try BeatsCron(cron).nextTimes(after: start, count: expected.count, calendar: calendar)
            #expect(times.map { parse.string(from: $0) } == expected, "\(cron)")
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

    @Test func sampleStoreFromTheOrchestratorDecodesAndEncodesToTheSameBytes() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("beats-store-sample.json"))
        let state = try SidebarBeatsState.decode(data)
        #expect(state.beats.count == 3)
        #expect(state.beats[0].prompt == "Check the board.\nSummarize blockers / risks.")
        #expect(state.beats[0].enabled && !state.beats[1].enabled)
        #expect(state.beats[2].prompt.contains("😀") && state.beats[2].prompt.contains("\u{2028}"))
        // Byte-identical to the orchestrator's beats_encode (test-beats.py), so both writers
        // measure the same size limit.
        #expect(try state.encoded() == data)
    }

    @Test func storeContractMatchesTheOrchestrator() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("beats-store-cases.json"))
        let cases = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for item in try #require(cases["valid"] as? [[String: String]]) {
            #expect(throws: Never.self, "\(item["name"] ?? "")") { _ = try SidebarBeatsState.decode(Data(item["raw"]!.utf8)) }
        }
        for item in try #require(cases["invalid"] as? [[String: String]]) {
            #expect(throws: BeatsError.self, "\(item["name"] ?? "")") { _ = try SidebarBeatsState.decode(Data(item["raw"]!.utf8)) }
        }
        for item in try #require(cases["legacyEmpty"] as? [[String: String]]) {
            #expect(try SidebarBeatsState.decode(Data(item["raw"]!.utf8)) == SidebarBeatsState(), "\(item["name"] ?? "")")
        }
        let valid = try #require((cases["valid"] as? [[String: String]])?.first?["raw"])
        #expect(throws: BeatsError.self) { _ = try SidebarBeatsState.decode(Data([0xEF, 0xBB, 0xBF]) + Data(valid.utf8)) }
        // UTF-8 only; JSONSerialization would otherwise accept UTF-16/32 that the orchestrator refuses.
        let legacy = "{\"version\":1,\"beats\":[]}"
        let encodings: [String.Encoding] = [.utf16LittleEndian, .utf16BigEndian, .utf16, .utf32LittleEndian, .utf32]
        for raw in encodings.map({ legacy.data(using: $0)! }) + [
            Data([0x7B, 0x00, 0x22, 0x00, 0x31, 0x00, 0x31, 0x5C, 0x00, 0x5C, 0x22, 0x00, 0x3A, 0x00, 0x5B, 0x00, 0x5D, 0x00, 0x7D, 0x00]),
            Data("{\"version\":1,\"beats\":[\"".utf8) + Data([0xFF]) + Data("\"]}".utf8)
        ] {
            #expect(throws: BeatsError.self, "\(Array(raw))") { _ = try SidebarBeatsState.decode(raw) }
        }
    }

    @Test func writersRefusePromptsReadersRefuse() throws {
        var state = SidebarBeatsState()
        for prompt in ["\u{200B}", " \u{200B}\n", "\u{FEFF}", "\u{FEFF}Hello", "a\u{FEFF}b"] {
            #expect(throws: BeatsError.self, "\(prompt.debugDescription)") {
                _ = try state.create(session: UUID(), cron: "* * * * *", prompt: prompt)
            }
        }
        _ = try state.create(session: UUID(), cron: "* * * * *", prompt: "see \\ufeff here")
        #expect(try SidebarBeatsState.decode(state.encoded()) == state)
    }

    @Test func sharedStoreOrDirectoryIsRefused() throws {
        let root = try temporaryRoot().appendingPathComponent("Beats")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = SidebarBeatsFile(root: root)
        _ = try file.mutate { _ = try $0.create(session: UUID(), cron: "0 9 * * *", prompt: "x") }
        let store = root.appendingPathComponent("beats.json").path
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: store)
        #expect(throws: BeatsError.self) { _ = try file.read() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: root.path)
        #expect(throws: BeatsError.self) { _ = try file.read() }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        #expect(try file.read().beats.count == 1)
    }

    @Test func malformedStoresAreRefused() throws {
        let sample = try Data(contentsOf: Self.fixtures.appendingPathComponent("beats-store-sample.json"))
        var object = try #require(JSONSerialization.jsonObject(with: sample) as? [String: Any])
        for mutate: (inout [String: Any]) -> Void in [
            { $0["version"] = 3 },
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
        object["version"] = 2
        _ = try SidebarBeatsState.decode(JSONSerialization.data(withJSONObject: object))
        #expect(throws: BeatsError.self) { _ = try SidebarBeatsState.decode(Data("nope".utf8)) }
    }

    // MARK: Human operations

    @Test func humanOperationsTurnBeatsOnAndOff() throws {
        var state = SidebarBeatsState()
        let first = UUID(), second = UUID()
        let beat = try state.create(session: first, cron: "  0   9 * * 1-5", prompt: "Plan the day")
        #expect(beat.cron == "0 9 * * 1-5" && beat.enabled)
        try state.pause(id: beat.id)
        #expect(!state.beats[0].enabled)
        try state.enable(id: beat.id)
        #expect(state.beats[0].enabled)
        // Editing never changes whether recurrence runs.
        try state.edit(id: beat.id, cron: "30 9 * * *", prompt: nil, session: nil, basedOn: nil)
        #expect(state.beats[0].enabled && state.beats[0].revision == 4)
        // Moving to another session keeps it on or off (ADR 0007: a Beat is simply on or off).
        try state.edit(id: beat.id, cron: nil, prompt: "New words", session: second, basedOn: nil)
        #expect(state.beats[0].sessionId == second.uuidString.lowercased())
        #expect(state.beats[0].enabled && state.beats[0].prompt == "New words")
        try state.pause(id: beat.id)
        try state.edit(id: beat.id, cron: nil, prompt: nil, session: first, basedOn: nil)
        #expect(!state.beats[0].enabled)
        try state.delete(id: beat.id)
        #expect(state.beats.isEmpty)
        #expect(throws: BeatsError.self) { try state.delete(id: beat.id) }
    }

    @Test func staleEditIsRefusedAndKeepsTheNewerChange() throws {
        var state = SidebarBeatsState()
        let beat = try state.create(session: UUID(), cron: "0 9 * * *", prompt: "Original")
        let opened = state.beats[0]
        // Another writer (an agent) changes the prompt after the form opened.
        try state.edit(id: beat.id, cron: nil, prompt: "Agent words", session: nil, basedOn: nil)
        #expect(throws: BeatsError.changedElsewhere) {
            try state.edit(id: beat.id, cron: "30 9 * * *", prompt: "Human words", session: nil, basedOn: opened)
        }
        #expect(state.beats[0].prompt == "Agent words" && state.beats[0].cron == "0 9 * * *")
        // "Load latest" bases the same draft on the current Beat.
        try state.edit(id: beat.id, cron: "30 9 * * *", prompt: "Human words", session: nil, basedOn: state.beats[0])
        #expect(state.beats[0].prompt == "Human words" && state.beats[0].cron == "30 9 * * *")
    }

    @Test func pauseOrResumeElsewhereIsNotAConflict() throws {
        var state = SidebarBeatsState()
        let beat = try state.create(session: UUID(), cron: "0 9 * * *", prompt: "Original")
        let opened = state.beats[0]
        try state.pause(id: beat.id)
        try state.edit(id: beat.id, cron: nil, prompt: "Human words", session: nil, basedOn: opened)
        #expect(state.beats[0].prompt == "Human words" && !state.beats[0].enabled)
    }

    @Test func staleSaveThroughTheSharedFileIsRefused() throws {
        let root = try temporaryRoot().appendingPathComponent("Beats")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let controller = SidebarBeatsController(file: SidebarBeatsFile(root: root))
        #expect(controller.perform { _ = try $0.create(session: UUID(), cron: "0 9 * * *", prompt: "Original") } == nil)
        let opened = try #require(controller.beats.first)
        _ = try SidebarBeatsFile(root: root).mutate {
            try $0.edit(id: opened.id, cron: nil, prompt: "Agent words", session: nil, basedOn: nil)
        }
        let failure = controller.perform {
            try $0.edit(id: opened.id, cron: nil, prompt: "Human words", session: nil, basedOn: opened)
        }
        #expect(failure == BeatsError.changedElsewhere.message)
        controller.refresh()
        #expect(controller.beats.first?.prompt == "Agent words")
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
        #expect(throws: BeatsError.self) { try file.mutate { try $0.edit(id: id, cron: "bogus", prompt: nil, session: nil, basedOn: nil) } }
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
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let elsewhere = root.deletingLastPathComponent().appendingPathComponent("elsewhere.json")
        try Data("{\"beats\":[],\"version\":2}\n".utf8).write(to: elsewhere)
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
