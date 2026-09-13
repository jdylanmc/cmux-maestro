import Foundation
import Observation
import Testing

@MainActor
@Suite(.serialized)
struct SidebarPreferenceCoordinationTests {
    private let sessionID = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
    private let eventID = UUID(uuidString: "70000000-0000-0000-0000-000000000002")!

    @Test func existingInstancesMergeActionsAndRestoreOrResetOnlyTheirScope() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let a = fixture.preferences()
        let b = fixture.preferences()
        await Task.yield()
        a.selectedMode = .taskboard
        fixture.defaults.set("untouched", forKey: "sidebar.attention.v1")
        fixture.defaults.set("untouched", forKey: "sidebar.layout.v1")

        a.setRetention(.never)
        b.dismiss([key("b")])
        await Task.yield()
        a.dismiss([key("a")])
        b.dismiss([key("c")])
        #expect(a.history == b.history)
        #expect(a.history == .init(retention: .never, dismissed: [key("a"), key("b"), key("c")]))

        a.restoreDismissed()
        #expect(b.history == .init(retention: .never))
        await Task.yield()
        b.dismiss([key("after-restore")])
        a.setRetention(.oneHour)
        #expect(b.history == .init(retention: .oneHour, dismissed: [key("after-restore")]))
        b.resetHistory()
        #expect(a.history == .init())
        a.dismiss([key("after-reset")])
        #expect(b.history == .init(dismissed: [key("after-reset")]))
        #expect(a.selectedMode == .taskboard)
        #expect(fixture.defaults.string(forKey: "sidebar.selectedMode") == "taskboard")
        #expect(fixture.defaults.string(forKey: "sidebar.attention.v1") == "untouched")
        #expect(fixture.defaults.string(forKey: "sidebar.layout.v1") == "untouched")
        #expect(fixture.preferences().history == a.history)
    }

    @Test func migrationIsBoundedOneTimeAndCannotResurrectAfterRestoreOrReset() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let legacy = SidebarHistorySettings(retention: .never, dismissed: [key("legacy")])
        fixture.defaults.set(try JSONEncoder().encode(legacy), forKey: "sidebar.completedHistory.v1")
        fixture.defaults.set("taskboard", forKey: "sidebar.selectedMode")
        let first = fixture.preferences()
        #expect(first.history == legacy)
        #expect(first.selectedMode == .taskboard)
        #expect(fixture.defaults.object(forKey: "sidebar.completedHistory.v1") == nil)
        #expect(try JSONDecoder().decode(SidebarHistorySettings.self, from: Data(contentsOf: fixture.historyFile)) == legacy)
        await Task.yield()

        first.restoreDismissed()
        // Simulate another process still holding an old defaults snapshot.
        fixture.defaults.set(try JSONEncoder().encode(legacy), forKey: "sidebar.completedHistory.v1")
        let second = fixture.preferences()
        #expect(second.history == .init(retention: .never))
        await Task.yield()
        second.resetHistory()
        fixture.defaults.set("broken legacy", forKey: "sidebar.completedHistory.v1")
        let third = fixture.preferences()
        #expect(third.history == .init())
        #expect(third.historyNotice == nil)
        #expect(fixture.defaults.object(forKey: "sidebar.completedHistory.v1") == nil)
    }

    @Test func injectedFilesDoNotShareHistoryEvenWithTheSameDefaultsSuite() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let a = fixture.preferences()
        let b = fixture.preferences(historyFile: fixture.root.appendingPathComponent("other.json"))
        a.setRetention(.never)
        a.dismiss([key("a")])
        #expect(b.history == .init())
        b.resetHistory()
        #expect(a.history == .init(retention: .never, dismissed: [key("a")]))
    }

    @Test func corruptFilesRejectEveryOrdinaryActionUntilExplicitReset() async throws {
        let invalid = [
            Data("broken".utf8),
            Data(#"{"version":2,"retention":"never","dismissed":[]}"#.utf8),
            Data(#"{"version":1,"retention":"invalid","dismissed":[]}"#.utf8),
            Data(repeating: 0, count: SidebarHistorySettings.maximumStoredBytes + 1),
            try JSONEncoder().encode(SidebarHistorySettings(dismissed: [key("bad\nid")])),
        ]
        for bytes in invalid {
            let fixture = try SidebarPreferenceFixture()
            defer { fixture.cleanup() }
            try bytes.write(to: fixture.historyFile)
            let a = fixture.preferences()
            let b = fixture.preferences()
            a.setRetention(.oneMinute)
            b.dismiss([key("b")])
            a.restoreDismissed()
            #expect(a.history == .failOpen)
            #expect(b.history == .failOpen)
            #expect(a.historyNotice == SidebarHistorySettings.unreadableNotice)
            #expect(try Data(contentsOf: fixture.historyFile) == bytes)
            b.resetHistory()
            #expect(a.history == .init())
            #expect(a.historyNotice == nil)
            #expect(try JSONDecoder().decode(SidebarHistorySettings.self, from: Data(contentsOf: fixture.historyFile)) == .init())
            // Coordinated fixture I/O must not monopolize the actor used by other suites' timers.
            await Task.yield()
        }
    }

    @Test func capacityChecksUseLatestRecordAndRejectWholeBatchIncludingByteLimit() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let a = fixture.preferences()
        let b = fixture.preferences()
        a.setRetention(.never)
        let full = Set((0..<SidebarHistorySettings.maximumDismissals).map { key("child-\($0)") })
        a.dismiss(full)
        let before = try Data(contentsOf: fixture.historyFile)
        await Task.yield()
        b.dismiss([key("new")])
        #expect(a.history == .init(retention: .never, dismissed: full))
        #expect(b.history == a.history)
        #expect(b.historyNotice != nil)
        #expect(try Data(contentsOf: fixture.historyFile) == before)
        b.restoreDismissed()
        a.dismiss([key("preserved")])
        await Task.yield()
        let large = Set((0..<SidebarHistorySettings.maximumDismissals - 1).map {
            key(String(repeating: "x", count: 500) + String($0))
        })
        #expect(large.allSatisfy { $0.isValid })
        #expect(try JSONEncoder().encode(SidebarHistorySettings(dismissed: large)).count > SidebarHistorySettings.maximumStoredBytes)
        b.dismiss(large)
        #expect(a.history == .init(retention: .never, dismissed: [key("preserved")]))
        #expect(b.historyNotice != nil)
        a.dismiss([key("bad\nvalue")])
        #expect(a.history.dismissed == [key("preserved")])
    }

    @Test func storageFailureFailsOpenAndCanBeRetriedWithoutWritingDefaults() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let legacy = try JSONEncoder().encode(SidebarHistorySettings(dismissed: [key("legacy")]))
        fixture.defaults.set(legacy, forKey: "sidebar.completedHistory.v1")
        let blocker = fixture.root.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        let preferences = fixture.preferences(historyFile: blocker.appendingPathComponent("history.json"))
        preferences.dismiss([key("a")])
        #expect(preferences.history == .failOpen)
        #expect(preferences.historyNotice != nil)
        #expect(fixture.defaults.data(forKey: "sidebar.completedHistory.v1") == legacy)
        try FileManager.default.removeItem(at: blocker)
        preferences.setRetention(.never)
        #expect(preferences.history == .init(retention: .never, dismissed: [key("legacy")]))
        #expect(preferences.historyNotice == nil)
        #expect(fixture.defaults.object(forKey: "sidebar.completedHistory.v1") == nil)
    }

    @Test func separateProcessesSerializeActionsAndAutomaticallyConvergeExistingProjections() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.selectedMode = .taskboard
        let projection = HistoryPreferenceProjection(preferences: preferences, sessionID: sessionID, eventID: eventID)
        let a = try PreferenceTestChild(fixture)
        let b = try PreferenceTestChild(fixture)
        defer { a.stop(); b.stop() }
        #expect(try await a.line() == "ready")
        #expect(try await b.line() == "ready")
        try a.send("retain never")
        #expect(try await a.line() == "done")
        try await eventually { preferences.history.retention == .never && projection.tree.retainedHistoryCount == 2 }

        try a.send("hold a")
        #expect(try await a.line() == "locked")
        try b.send("dismiss b")
        #expect(try await b.line() == "applying")
        try a.send("continue")
        #expect(try await a.line() == "done")
        #expect(try await b.line() == "done")
        try await eventually {
            preferences.history == .init(retention: .never, dismissed: [key("a"), key("b")])
                && projection.tree.hiddenHistoryCount == 2
        }
        #expect(projection.tree.knownRunningChildren == 1)
        try a.send("expect 2 never")
        #expect(try await a.line() == "done")

        preferences.restoreDismissed()
        try a.send("expect 0 never")
        try b.send("expect 0 never")
        #expect(try await a.line() == "done")
        #expect(try await b.line() == "done")
        try await eventually { projection.tree.retainedHistoryCount == 2 }

        try b.send("reset")
        #expect(try await b.line() == "done")
        try await eventually { preferences.history == .init() && projection.tree.hiddenHistoryCount == 2 }
        try a.send("expect 0 fifteenSeconds")
        #expect(try await a.line() == "done")
        #expect(preferences.selectedMode == .taskboard)
        #expect(projection.updates >= 4)
        #expect(preferences.historyNotice == nil)
        #expect(try JSONDecoder().decode(SidebarHistorySettings.self, from: Data(contentsOf: fixture.historyFile)) == .init())
    }

    private func key(_ child: String) -> SidebarDismissedOutcome {
        .init(sessionID: sessionID, childID: child, eventID: eventID)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Existing observable preferences did not converge from file presentation")
    }
}

/// Mirrors SidebarView's observed history -> projection path, without a manual refresh.
@MainActor
private final class HistoryPreferenceProjection {
    private let preferences: SidebarPreferences
    private let snapshot: CopilotSnapshot
    private let topology: SidebarTopology
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var tree: SidebarCopilotTree
    private(set) var updates = 0

    init(preferences: SidebarPreferences, sessionID: UUID, eventID: UUID) {
        self.preferences = preferences
        let fixtures = SidebarTreeFixtures()
        let now = self.now
        let children = ["a", "b"].map {
            CopilotChildWork(id: $0, parentID: nil, kind: .subagent, name: $0, state: .completed, model: nil,
                             terminalEvent: .init(id: eventID, timestamp: now.addingTimeInterval(-60)))
        } + [fixtures.child("working", state: .working)]
        snapshot = fixtures.snapshot(sessions: [fixtures.session(id: sessionID, children: children, now: now)], now: now)
        topology = fixtures.topology()
        tree = SidebarCopilotTree.project(snapshot, onto: topology, now: now, history: preferences.history)
        observe()
    }

    private func observe() {
        withObservationTracking {
            tree = SidebarCopilotTree.project(snapshot, onto: topology, now: now, history: preferences.history)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updates += 1
                self?.observe()
            }
        }
    }
}

@MainActor
final class PreferenceTestChild {
    private let process: Process
    private let input = Pipe()
    private let output = Pipe()
    private let lines: AsyncStream<String>

    init(_ fixture: SidebarPreferenceFixture) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        process = Process()
        process.executableURL = root.appendingPathComponent(".build/preference-coordination/preference-test-client")
        process.arguments = [fixture.historyFile.path, fixture.suiteName, fixture.attentionFile.path]
        process.standardInput = input
        process.standardOutput = output
        let (stream, continuation) = AsyncStream<String>.makeStream()
        lines = stream
        let buffer = PreferenceLineBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { continuation.finish(); return }
            for line in buffer.append(data) { continuation.yield(line) }
        }
        process.terminationHandler = { _ in continuation.finish() }
        try process.run()
    }

    func send(_ command: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data("\(command)\n".utf8))
    }

    func line() async throws -> String {
        let lines = lines
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for await line in lines { return line }
                throw CocoaError(.fileReadUnknown)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw CocoaError(.coderValueNotFound)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

private final class PreferenceLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) -> [String] {
        lock.withLock {
            data.append(chunk)
            var lines: [String] = []
            while let newline = data.firstIndex(of: 10) {
                lines.append(String(decoding: data[..<newline], as: UTF8.self))
                data.removeSubrange(...newline)
            }
            return lines
        }
    }
}
