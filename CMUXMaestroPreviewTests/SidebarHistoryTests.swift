import Foundation
import Testing

@MainActor
struct SidebarHistoryTests {
    private let fixtures = SidebarTreeFixtures()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let eventID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!

    @Test(arguments: [CopilotWorkState.completed, .failed, .cancelled])
    func preciseExpiryBoundaryAndNever(_ state: CopilotWorkState) throws {
        let child = child("ended", state: state, age: 15)
        let before = project([child], at: now.addingTimeInterval(-0.001))
        #expect(before.retainedHistoryCount == 1)
        #expect(before.nextHistoryExpiry == now)
        let boundary = project([child])
        #expect(boundary.sessions.first?.nodes.isEmpty == true)
        #expect(boundary.hiddenHistoryCount == 1)
        #expect(boundary.nextHistoryExpiry == nil)
        let never = project([child], history: .init(retention: .never))
        #expect(never.retainedHistoryCount == 1)
        #expect(never.nextHistoryExpiry == nil)
        #expect(never.dismissibleOutcomes.count == 1)
    }

    @Test(arguments: SidebarHistoryRetention.allCases)
    func eachPresetUsesAcceptedTimestamp(_ retention: SidebarHistoryRetention) {
        let tree = project([child("ended", age: 1)], history: .init(retention: retention))
        #expect(tree.nextHistoryExpiry == retention.duration.map { now.addingTimeInterval($0 - 1) })
    }

    @Test func missingAndFutureTimingNeverInventAgeOrAutoExpire() {
        let legacy = CopilotChildWork(id: "legacy", parentID: nil, kind: .subagent, name: "Same", state: .completed, model: nil)
        let tree = project([child("missing", age: nil), child("future", age: -3600), legacy])
        #expect(tree.retainedHistoryCount == 3)
        #expect(tree.hiddenHistoryCount == 0)
        #expect(tree.nextHistoryExpiry == nil)
        #expect(tree.sessions.first?.nodes.allSatisfy { $0.terminalTimestamp == nil } == true)
        #expect(tree.dismissibleOutcomes.count == 2)
        let observedEarlier = fixtures.session(children: [child("later-than-observation", age: 1)], now: now.addingTimeInterval(-2))
        let earlier = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [observedEarlier], now: now), onto: fixtures.topology(), now: now
        )
        #expect(earlier.nextHistoryExpiry == nil)
        #expect(earlier.sessions.first?.nodes.first?.terminalTimestamp == nil)
    }

    @Test func ancientEvidenceExpiresOnReconstructionNotFirstPoll() {
        let tree = project([child("old", age: 86_400)])
        #expect(tree.hiddenHistoryCount == 1)
        #expect(tree.retainedHistoryCount == 0)
        #expect(tree.nextHistoryExpiry == nil)
        #expect(project([child("old", age: 86_400)]) == tree)
    }

    @Test(arguments: [CopilotWorkState.working, .blocked, .idle, .unknown])
    func nonterminalWorkAndRequiredAncestryAreImmune(_ state: CopilotWorkState) throws {
        let children = [
            child("parent", age: 60), child("child", parent: "parent", state: state, age: 60),
            child("ended", age: 60)
        ]
        let tree = project(children, history: .init(dismissed: [key("parent"), key("child")]))
        let session = try #require(tree.sessions.first)
        #expect(session.nodes.map(\.id) == ["parent", "child"])
        #expect(session.nodes.first?.historyAncestor == true)
        #expect(session.nodes.last?.historyAncestor == false)
        #expect(session.nodes.map(\.depth) == [0, 1])
        #expect(tree.retainedHistoryCount == 0)
        #expect(tree.dismissibleOutcomes.isEmpty)
        #expect(tree.hiddenHistoryCount == 2)
        #expect(tree.knownRunningChildren == (state == .working ? 1 : 0))
        #expect(session.visibleNodes(collapsed: ["parent"]).map(\.id) == ["parent"])
    }

    @Test func identityIsSessionChildAndOutcomeNotLabelOrTopology() {
        let children = [child("one", age: 1), child("two", age: 1)]
        let history = SidebarHistorySettings(dismissed: [key("one")])
        let snapshot = fixtures.snapshot(sessions: [
            fixtures.session(children: children, now: now),
            fixtures.session(id: fixtures.otherSessionID, surface: fixtures.surfaceB, children: children, now: now)
        ], now: now)
        for moved in [false, true] {
            let tree = SidebarCopilotTree.project(snapshot, onto: fixtures.topology(moved: moved), now: now, history: history)
            #expect(tree.sessions[0].nodes.map(\.id) == ["two"])
            #expect(tree.sessions[1].nodes.map(\.id) == ["one", "two"])
            #expect(tree.retainedHistoryCount == 3)
        }
        #expect(project([child("one", state: .working, age: 1)], history: history).sessions.first?.nodes.count == 1)
        #expect(project([child("one", age: 1, event: UUID())], history: history).retainedHistoryCount == 1)
    }

    @Test func bulkClearOnlyTargetsEligibleProjectedOutcomesAndPreservesDescendants() {
        let children = [
            child("parent", age: 1), child("run", parent: "parent", state: .working),
            child("finished", age: 1), child("failed", state: .failed, age: nil),
            child("cancelled", state: .cancelled, age: 1), child("expired", age: 60),
            child("unknown", state: .unknown)
        ]
        let initial = project(children)
        #expect(Set(initial.dismissibleOutcomes.map(\.childID)) == ["parent", "finished", "failed", "cancelled"])
        let cleared = project(children, history: .init(dismissed: initial.dismissibleOutcomes))
        #expect(cleared.sessions.first?.nodes.map(\.id) == ["parent", "run", "unknown"])
        #expect(cleared.sessions.first?.nodes.first?.historyAncestor == true)
        #expect(cleared.knownRunningChildren == 1)
        #expect(cleared.dismissibleOutcomes.isEmpty)
        #expect(!cleared.hasCompleteCounts)

        let capped = project((0...SidebarCopilotTree.maximumNodes).map { child("terminal-\($0)", age: 1) })
        #expect(capped.dismissibleOutcomes.count == SidebarCopilotTree.maximumNodes)
        #expect(!capped.dismissibleOutcomes.contains(key("terminal-\(SidebarCopilotTree.maximumNodes)")))
        let offWindow = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [fixtures.session(surface: UUID(), children: children, now: now)], now: now),
            onto: fixtures.topology(), now: now
        )
        #expect(offWindow.dismissibleOutcomes.isEmpty)
    }

    @Test func persistedPreferencesReconstructAndRestoreWithoutChangingMode() throws {
        try withDefaults { defaults in
            let prefs = SidebarPreferences(defaults: defaults)
            #expect(prefs.history.retention == .fifteenSeconds)
            #expect(defaults.data(forKey: "sidebar.completedHistory.v1") != nil)
            prefs.selectedMode = .taskboard
            prefs.setRetention(.never)
            prefs.dismiss([key("child")])
            let reconstructed = SidebarPreferences(defaults: defaults)
            #expect(reconstructed.history == prefs.history)
            #expect(reconstructed.selectedMode == .taskboard)
            #expect(project([child("child", age: 1)], history: reconstructed.history).retainedHistoryCount == 0)
            reconstructed.restoreDismissed()
            #expect(reconstructed.history.retention == .never)
            #expect(reconstructed.history.dismissed.isEmpty)
            #expect(reconstructed.selectedMode == .taskboard)
            reconstructed.resetHistory()
            #expect(reconstructed.history == SidebarHistorySettings())
            #expect(reconstructed.selectedMode == .taskboard)
            let wire = try #require(defaults.data(forKey: "sidebar.completedHistory.v1"))
            #expect(!String(decoding: wire, as: UTF8.self).contains("Same label"))
        }
    }

    @Test func corruptStorageFailsOpenWithBoundedRecoverableNotice() throws {
        let invalid = [
            Data("broken".utf8),
            Data(#"{"version":999,"retention":"never","dismissed":[]}"#.utf8),
            Data(#"{"version":1,"retention":"invalid","dismissed":[]}"#.utf8),
            Data(#"{"version":1,"retention":"never","dismissed":[{"sessionID":"bad","childID":"c","eventID":"bad"}]}"#.utf8),
            Data(repeating: 0, count: SidebarHistorySettings.maximumStoredBytes + 1),
            try JSONEncoder().encode(SidebarHistorySettings(dismissed: [
                .init(sessionID: fixtures.sessionID, childID: "bad\nvalue", eventID: eventID)
            ]))
        ]
        for stored: Any in invalid + ["wrong-storage-type"] {
            withDefaults { defaults in
                defaults.set(stored, forKey: "sidebar.completedHistory.v1")
                let prefs = SidebarPreferences(defaults: defaults)
                #expect(prefs.history.retention == .never)
                #expect(prefs.history.dismissed.isEmpty)
                #expect((prefs.historyNotice?.count ?? 0) > 0)
                #expect((prefs.historyNotice?.count ?? 1000) < 300)
                #expect(project([child("old", age: 60)], history: prefs.history).retainedHistoryCount == 1)
                prefs.resetHistory()
                #expect(prefs.historyNotice == nil)
                #expect(SidebarPreferences(defaults: defaults).history == SidebarHistorySettings())
            }
        }
    }

    @Test func dismissalStorageBoundRejectsWholeBatchWithoutEvictingExistingRecords() throws {
        try withDefaults { defaults in
            let prefs = SidebarPreferences(defaults: defaults)
            let full = Set((0..<SidebarHistorySettings.maximumDismissals).map { key("child-\($0)") })
            prefs.dismiss(full)
            #expect(prefs.history.dismissed == full)
            prefs.dismiss([key("extra")])
            #expect(prefs.history.dismissed == full)
            #expect(prefs.historyNotice != nil)
            prefs.restoreDismissed()
            #expect(prefs.history.dismissed.isEmpty)
            #expect(prefs.historyNotice == nil)
            let oversized = SidebarHistorySettings(dismissed: full.union([key("extra")]))
            defaults.set(try JSONEncoder().encode(oversized), forKey: "sidebar.completedHistory.v1")
            #expect(SidebarPreferences(defaults: defaults).history.retention == .never)
        }
    }

    @Test func bothViewsConsumeSameHistoryProjectionAndUseDistinctDismissButtons() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("CMUXMaestroSidebar/UI/SidebarView.swift"), encoding: .utf8)
        #expect(view.contains("HierarchyContent(model: model, dismiss: dismiss)"))
        #expect(view.contains("tree: model.copilot.tree, hierarchy: model.hierarchy"))
        #expect(view.components(separatedBy: "DismissOutcomeButton(node: node, sessionID: session.id, dismiss: dismiss)").count == 3)
        #expect(view.contains(".popover(isPresented: $showingHistory)"))
        #expect(view.contains("Completion age unknown"))
        #expect(view.contains("model.copilot.tree.dismissibleOutcomes.contains(outcome)"))
        #expect(!view.contains("No recorded child tasks"))
    }

    private func child(
        _ id: String, parent: String? = nil, state: CopilotWorkState = .completed,
        age: TimeInterval? = nil, event: UUID? = nil
    ) -> CopilotChildWork {
        .init(id: id, parentID: parent, kind: .subagent, name: "Same label", state: state, model: nil,
              terminalEvent: .init(id: event ?? eventID, timestamp: age.map { now.addingTimeInterval(-$0) }))
    }

    private func key(_ child: String) -> SidebarDismissedOutcome {
        .init(sessionID: fixtures.sessionID, childID: child, eventID: eventID)
    }

    private func project(
        _ children: [CopilotChildWork], at date: Date? = nil,
        history: SidebarHistorySettings = SidebarHistorySettings()
    ) -> SidebarCopilotTree {
        let date = date ?? now
        return SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [fixtures.session(children: children, now: date)], now: date),
            onto: fixtures.topology(), now: date, history: history
        )
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "SidebarHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
