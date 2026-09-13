import Foundation
import Observation
import Testing

@MainActor
@Suite(.serialized)
struct SidebarAttentionCoordinationTests {
    private let evidence = PreferenceAttentionFixture()

    @Test func existingInstancesMergeAcknowledgementsAndKeepHistoryAndModeIndependent() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let a = fixture.preferences()
        let b = fixture.preferences()
        a.selectedMode = .taskboard
        a.setRetention(.never)
        await Task.yield()
        a.dismiss([historyKey])
        let historyBytes = try Data(contentsOf: fixture.historyFile)
        let tree = evidence.tree()
        b.acknowledge([evidence.key("b")], in: tree)
        await Task.yield()
        a.acknowledge([evidence.key("a")], in: tree)
        #expect(a.attention == .init(acknowledged: [evidence.key("a"), evidence.key("b")]))
        #expect(b.attention == a.attention)
        b.resetAcknowledgements()
        #expect(a.attention == .init())
        await Task.yield()
        a.acknowledge([evidence.key("a")], in: tree)
        b.acknowledge([evidence.key("blocked")], in: tree)
        #expect(b.attention == .init(acknowledged: [evidence.key("a")]))
        #expect(a.history == .init(retention: .never, dismissed: [historyKey]))
        #expect(try Data(contentsOf: fixture.historyFile) == historyBytes)
        let attentionBytes = try Data(contentsOf: fixture.attentionFile)
        b.restoreDismissed()
        a.resetHistory()
        #expect(try Data(contentsOf: fixture.attentionFile) == attentionBytes)
        #expect(a.attention == b.attention)
        #expect(a.selectedMode == .taskboard)
        #expect(fixture.defaults.string(forKey: "sidebar.selectedMode") == "taskboard")
    }

    @Test func legacyImportIsOneTimeAndResetDoesNotResurrectStaleAcknowledgements() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let legacy = SidebarAttentionSettings(acknowledged: [evidence.key("a")])
        fixture.defaults.set(try JSONEncoder().encode(legacy), forKey: "sidebar.attention.v1")
        let first = fixture.preferences()
        #expect(first.attention == legacy)
        #expect(fixture.defaults.object(forKey: "sidebar.attention.v1") == nil)
        #expect(try JSONDecoder().decode(SidebarAttentionSettings.self, from: Data(contentsOf: fixture.attentionFile)) == legacy)
        await Task.yield()
        first.resetAcknowledgements()
        fixture.defaults.set(try JSONEncoder().encode(legacy), forKey: "sidebar.attention.v1")
        let second = fixture.preferences()
        #expect(second.attention == .init())
        second.acknowledge([evidence.key("b")], in: evidence.tree())
        await Task.yield()
        fixture.defaults.set("broken legacy", forKey: "sidebar.attention.v1")
        let third = fixture.preferences()
        #expect(third.attention == .init(acknowledged: [evidence.key("b")]))
        #expect(third.attentionNotice == nil)
        #expect(fixture.defaults.object(forKey: "sidebar.attention.v1") == nil)
    }

    @Test func corruptFilesFailOpenAndOnlyExplicitAcknowledgementResetReplacesThem() async throws {
        for bytes in try invalidRecords() {
            let fixture = try SidebarPreferenceFixture()
            defer { fixture.cleanup() }
            try bytes.write(to: fixture.attentionFile)
            let a = fixture.preferences()
            let b = fixture.preferences()
            a.setRetention(.never)
            await Task.yield()
            let tree = evidence.tree()
            a.acknowledge([evidence.key("a")], in: tree)
            b.acknowledge([evidence.key("b")], in: tree)
            a.resetHistory()
            #expect(a.attention == .failOpen)
            #expect(b.attention == .failOpen)
            #expect(a.attentionNotice == SidebarAttentionSettings.unreadableNotice)
            #expect(try Data(contentsOf: fixture.attentionFile) == bytes)
            #expect(evidence.tree(attention: a.attention).attentionOwnerCount == 3)
            await Task.yield()
            b.resetAcknowledgements()
            #expect(a.attentionNotice == nil)
            a.acknowledge([evidence.key("a")], in: tree)
            #expect(b.attention == .init(acknowledged: [evidence.key("a")]))
            await Task.yield()
        }
    }

    @Test func invalidLegacyCountAndIdentityRemainUntouchedUntilReset() async throws {
        for bytes in try invalidRecords().suffix(2) {
            let fixture = try SidebarPreferenceFixture()
            defer { fixture.cleanup() }
            fixture.defaults.set(bytes, forKey: "sidebar.attention.v1")
            let preferences = fixture.preferences()
            preferences.acknowledge([evidence.key("a")], in: evidence.tree())
            #expect(preferences.attention == .failOpen)
            #expect(preferences.attentionNotice != nil)
            #expect(fixture.defaults.data(forKey: "sidebar.attention.v1") == bytes)
            #expect(!FileManager.default.fileExists(atPath: fixture.attentionFile.path))
            preferences.resetAcknowledgements()
            #expect(preferences.attentionNotice == nil)
            #expect(fixture.defaults.object(forKey: "sidebar.attention.v1") == nil)
            await Task.yield()
        }
    }

    @Test(arguments: [false, true])
    func capacityUsesLatestRecordAndRejectsWholeBatchWithoutEviction(byteLimit: Bool) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let stored = byteLimit ? try nearByteLimit() : SidebarAttentionSettings(acknowledged: Set(
            (0..<SidebarAttentionSettings.maximumAcknowledgements - 1).map { evidence.key("old-\($0)") }
        ))
        fixture.defaults.set(try JSONEncoder().encode(stored), forKey: "sidebar.attention.v1")
        let a = fixture.preferences()
        let b = fixture.preferences()
        await Task.yield()
        if !byteLimit { a.acknowledge([evidence.key("a")], in: evidence.tree()) }
        let latest = a.attention
        let before = try Data(contentsOf: fixture.attentionFile)
        let owners = byteLimit ? [String(repeating: "x", count: 512), String(repeating: "y", count: 512)] : ["b", "c"]
        let tree = evidence.tree(owners: owners, blocked: false)
        #expect(tree.acknowledgeableOutcomes.count == 2)
        var oversized = latest
        oversized.acknowledged.formUnion(tree.acknowledgeableOutcomes)
        if byteLimit {
            #expect(oversized.isValid)
            #expect(try JSONEncoder().encode(oversized).count > SidebarAttentionSettings.maximumStoredBytes)
        } else {
            #expect(!oversized.isValid)
        }
        b.acknowledge(tree.acknowledgeableOutcomes, in: tree)
        #expect(a.attention == latest)
        #expect(b.attention == latest)
        #expect(b.attentionNotice != nil)
        #expect(try Data(contentsOf: fixture.attentionFile) == before)
        await Task.yield()
        a.resetAcknowledgements()
        b.acknowledge([evidence.key("b")], in: evidence.tree())
        #expect(a.attention == .init(acknowledged: [evidence.key("b")]))
    }

    @Test func failedMigrationPreservesLegacyAndRetryMergesOnlySuccessfulActions() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let legacy = try JSONEncoder().encode(SidebarAttentionSettings(acknowledged: [evidence.key("a")]))
        fixture.defaults.set(legacy, forKey: "sidebar.attention.v1")
        let blocker = fixture.root.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        let file = blocker.appendingPathComponent("attention.json")
        let preferences = fixture.preferences(attentionFile: file)
        preferences.setRetention(.never)
        await Task.yield()
        preferences.acknowledge([evidence.key("b")], in: evidence.tree())
        #expect(preferences.attention == .failOpen)
        #expect(preferences.attentionNotice != nil)
        #expect(fixture.defaults.data(forKey: "sidebar.attention.v1") == legacy)
        try FileManager.default.removeItem(at: blocker)
        preferences.acknowledge([evidence.key("b")], in: evidence.tree())
        #expect(preferences.attention == .init(acknowledged: [evidence.key("a"), evidence.key("b")]))
        #expect(preferences.attentionNotice == nil)
        #expect(preferences.history.retention == .never)
        #expect(fixture.defaults.object(forKey: "sidebar.attention.v1") == nil)
    }

    @Test func separateAttentionFilesStayIsolatedWhileSharedHistoryStillPropagates() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let a = fixture.preferences()
        let b = fixture.preferences(attentionFile: fixture.root.appendingPathComponent("other-attention.json"))
        a.acknowledge([evidence.key("a")], in: evidence.tree())
        await Task.yield()
        #expect(b.attention == .init())
        a.setRetention(.never)
        #expect(b.history.retention == .never)
        b.resetAcknowledgements()
        #expect(a.attention == .init(acknowledged: [evidence.key("a")]))
    }

    @Test func separateProcessesMergeAcknowledgeResetAndAutomaticallyReprojectWithBlockers() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.selectedMode = .taskboard
        preferences.setRetention(.never)
        let projection = AttentionPreferenceProjection(preferences: preferences)
        let a = try PreferenceTestChild(fixture)
        let b = try PreferenceTestChild(fixture)
        defer { a.stop(); b.stop() }
        #expect(try await a.line() == "ready")
        #expect(try await b.line() == "ready")
        try a.send("hold-ack a")
        #expect(try await a.line() == "locked")
        try b.send("ack b")
        #expect(try await b.line() == "applying")
        try a.send("continue")
        #expect(try await a.line() == "done")
        #expect(try await b.line() == "done")
        try await eventually {
            preferences.attention == .init(acknowledged: [evidence.key("a"), evidence.key("b")])
                && projection.tree.attentionOwnerCount == 1
        }
        try a.send("expect-ack 2")
        #expect(try await a.line() == "done")

        preferences.resetAcknowledgements()
        try a.send("expect-ack 0")
        try b.send("expect-ack 0")
        #expect(try await a.line() == "done")
        #expect(try await b.line() == "done")
        try await eventually { projection.tree.attentionOwnerCount == 3 }

        try b.send("ack b")
        #expect(try await b.line() == "applying")
        #expect(try await b.line() == "done")
        try await eventually { preferences.attention == .init(acknowledged: [evidence.key("b")]) }
        try a.send("expect-ack 1")
        #expect(try await a.line() == "done")
        try a.send("ack a")
        #expect(try await a.line() == "applying")
        #expect(try await a.line() == "done")
        try await eventually { preferences.attention.acknowledged.count == 2 && projection.tree.attentionOwnerCount == 1 }

        preferences.resetHistory()
        try b.send("expect 0 fifteenSeconds")
        #expect(try await b.line() == "done")
        try b.send("expect-ack 2")
        #expect(try await b.line() == "done")
        try b.send("ack blocked")
        #expect(try await b.line() == "applying")
        #expect(try await b.line() == "done")
        try await eventually { projection.tree.hiddenHistoryCount == 2 }
        #expect(preferences.attention.acknowledged.count == 2)
        #expect(projection.tree.sessions.first?.nodes.map(\.id) == ["a", "blocked"])
        #expect(projection.tree.sessions.first?.nodes.first?.historyAncestor == true)
        #expect(projection.tree.sessions.first?.nodes.last?.attention.first?.kind == .permission)
        #expect(preferences.selectedMode == .taskboard)
        #expect(projection.updates >= 5)
    }

    private var historyKey: SidebarDismissedOutcome {
        .init(sessionID: evidence.sessionID, childID: "history", eventID: evidence.eventID)
    }

    private func invalidRecords() throws -> [Data] {
        [
            Data("broken".utf8),
            Data(#"{"version":2,"acknowledged":[]}"#.utf8),
            Data(repeating: 0, count: SidebarAttentionSettings.maximumStoredBytes + 1),
            try JSONEncoder().encode(SidebarAttentionSettings(acknowledged: [evidence.key("bad\nid")])),
            try JSONEncoder().encode(SidebarAttentionSettings(acknowledged: Set(
                (0...SidebarAttentionSettings.maximumAcknowledgements).map { evidence.key("over-limit-\($0)") }
            )))
        ]
    }

    private func nearByteLimit() throws -> SidebarAttentionSettings {
        let keys = (0..<SidebarAttentionSettings.maximumAcknowledgements).map {
            evidence.key(String(repeating: "old", count: 167) + String($0))
        }
        var low = 0
        var high = keys.count
        while low < high {
            let mid = (low + high + 1) / 2
            let value = SidebarAttentionSettings(acknowledged: Set(keys.prefix(mid)))
            if try JSONEncoder().encode(value).count <= SidebarAttentionSettings.maximumStoredBytes {
                low = mid
            } else { high = mid - 1 }
        }
        return .init(acknowledged: Set(keys.prefix(low)))
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Existing acknowledgement observation/projection did not converge")
    }
}

@MainActor
private final class AttentionPreferenceProjection {
    private let preferences: SidebarPreferences
    private let evidence = PreferenceAttentionFixture()
    private(set) var tree: SidebarCopilotTree
    private(set) var updates = 0

    init(preferences: SidebarPreferences) {
        self.preferences = preferences
        tree = evidence.tree(history: preferences.history, attention: preferences.attention)
        observe()
    }

    private func observe() {
        withObservationTracking {
            tree = evidence.tree(history: preferences.history, attention: preferences.attention)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updates += 1
                self?.observe()
            }
        }
    }
}
