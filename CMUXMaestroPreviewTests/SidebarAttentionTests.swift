import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct SidebarAttentionTests {
    private let fixtures = SidebarTreeFixtures()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func acknowledgementPersistsBySessionOwnerAndEvidenceNotSurfaceOrLabel() throws {
        try withDefaults { defaults, historyFile, attentionFile, layoutStore in
            let outcome = signal(.turnFinished)
            let first = session(attention: [outcome])
            let sibling = session(id: fixtures.otherSessionID, surface: fixtures.surfaceB, attention: [outcome])
            let tree = project([first, sibling])
            let key = SidebarAcknowledgedOutcome(sessionID: first.sessionID, ownerID: nil, evidence: outcome.evidence)
            let preferences = SidebarPreferences(defaults: defaults, historyFile: historyFile, attentionFile: attentionFile, layoutStore: layoutStore)
            preferences.acknowledge([key], in: tree)
            let reloaded = SidebarPreferences(defaults: defaults, historyFile: historyFile, attentionFile: attentionFile, layoutStore: layoutStore)
            #expect(reloaded.attention == preferences.attention)
            for moved in [false, true] {
                let shown = project([first, sibling], attention: reloaded.attention, moved: moved)
                #expect(shown.sessions.first?.attention.isEmpty == true)
                #expect(shown.sessions.last?.attention == [outcome])
                #expect(shown.attentionOwnerCount == 1)
            }
            let newOutcome = signal(.turnFinished)
            #expect(project([session(attention: [newOutcome])], attention: reloaded.attention).attentionOwnerCount == 1)
            let sameEventOtherOwner = child("child", state: .failed, attention: [outcome])
            #expect(project([session(children: [sameEventOtherOwner])], attention: reloaded.attention).attentionOwnerCount == 1)
            let stored = try Data(contentsOf: attentionFile)
            #expect(defaults.object(forKey: "sidebar.attention.v1") == nil)
            #expect(!String(decoding: stored, as: UTF8.self).contains("Same label"))
        }
    }

    @Test func blockersCannotBeAcknowledgedEvenWithForgedStoredKeysOrStaleButtons() throws {
        try withDefaults { defaults, historyFile, attentionFile, layoutStore in
            let permission = signal(.permission)
            let answer = signal(.answer)
            let outcome = signal(.turnFinished)
            let keys = Set([permission, answer, outcome].map {
                SidebarAcknowledgedOutcome(sessionID: fixtures.sessionID, ownerID: nil, evidence: $0.evidence)
            })
            let blocked = session(state: .blocked, attention: [permission, answer, outcome])
            let tree = project([blocked])
            #expect(tree.acknowledgeableOutcomes.isEmpty)
            #expect(tree.dismissibleOutcomes.isEmpty)
            let preferences = SidebarPreferences(defaults: defaults, historyFile: historyFile, attentionFile: attentionFile, layoutStore: layoutStore)
            preferences.acknowledge(keys, in: tree)
            #expect(preferences.attention.acknowledged.isEmpty)
            let forged = project([blocked], attention: .init(acknowledged: keys))
            #expect(forged.sessions.first?.attention.map(\.kind) == [.permission, .answer])
            #expect(forged.sessions.first?.state == .blocked)
            #expect(forged.acknowledgeableOutcomes.isEmpty)
            let staleKey = SidebarAcknowledgedOutcome(sessionID: fixtures.sessionID, ownerID: nil, evidence: outcome.evidence)
            preferences.acknowledge([staleKey], in: project([session(state: .working)]))
            #expect(preferences.attention.acknowledged.isEmpty)
        }
    }

    @Test func bulkActionIsCurrentWindowAndPreservesBlockingOwners() throws {
        try withDefaults { defaults, historyFile, attentionFile, layoutStore in
            let error = signal(.error)
            let permission = signal(.permission)
            let tree = project([
                session(attention: [signal(.turnFinished)], children: [
                    child("failed", state: .failed, attention: [error]),
                    child("blocked", state: .blocked, attention: [permission, error])
                ]),
                session(id: fixtures.otherSessionID, surface: UUID(), attention: [signal(.turnFinished)])
            ])
            #expect(tree.acknowledgeableOutcomes.count == 2)
            #expect(Set(tree.acknowledgeableOutcomes.compactMap(\.ownerID)) == ["failed"])
            #expect(tree.acknowledgeableOutcomes.allSatisfy { $0.sessionID == fixtures.sessionID })
            let prefs = SidebarPreferences(defaults: defaults, historyFile: historyFile, attentionFile: attentionFile, layoutStore: layoutStore)
            prefs.acknowledge(tree.acknowledgeableOutcomes, in: tree)
            #expect(prefs.attention.acknowledged.count == 2)
            #expect(!prefs.attention.acknowledged.contains {
                $0.ownerID == "blocked" || $0.sessionID == fixtures.otherSessionID
            })
        }
    }

    @Test func attentionSurvivesRetentionDismissalAndCollapseUntilExplicitAcknowledgement() throws {
        let error = signal(.error, age: 120)
        let key = SidebarDismissedOutcome(sessionID: fixtures.sessionID, childID: "failed", eventID: error.evidence.eventID)
        let failed = child("failed", state: .failed, attention: [error])
        let pending = child("waiting", parent: "failed", state: .blocked, attention: [signal(.permission)])
        let history = SidebarHistorySettings(dismissed: [key])
        let original = session(children: [failed, pending])
        let tree = project([original], history: history)
        #expect(tree.sessions.first?.nodes.map(\.id) == ["failed", "waiting"])
        #expect(tree.sessions.first?.visibleNodes(collapsed: ["failed"]).map(\.id) == ["failed"])
        #expect(tree.attentionOwnerCount == 2)
        #expect(tree.dismissibleOutcomes.isEmpty)
        #expect(tree.hiddenHistoryCount == 0)
        let acknowledged = SidebarAttentionSettings(acknowledged: tree.acknowledgeableOutcomes)
        let after = project([original], history: history, attention: acknowledged)
        #expect(after.sessions.first?.nodes.first?.historyAncestor == true)
        #expect(after.sessions.first?.nodes.last?.attention.first?.kind == .permission)
        #expect(after.attentionOwnerCount == 1)
        #expect(after.hiddenHistoryCount == 1)
        #expect(after.acknowledgeableOutcomes.isEmpty)
        #expect(project([session(children: [failed])], attention: acknowledged).sessions.first?.nodes.isEmpty == true)
    }

    @Test func unknownOrDeadLivenessNeverImpliesCompletionButKeepsPendingEvidence() {
        let permission = signal(.permission)
        for liveness in [CopilotLiveness.dead, .unknown, .ambiguous] {
            let tree = project([session(
                state: .blocked, liveness: liveness, attention: [permission],
                activity: .init(kind: .executing, summary: "Executing tool: rg", lastEventAt: now)
            )])
            #expect(tree.sessions.first?.state == .unknown)
            #expect(tree.sessions.first?.attention == [permission])
            #expect(tree.sessions.first?.activity == nil)
            #expect(tree.acknowledgeableOutcomes.isEmpty)
            #expect(!tree.hasCompleteCounts)
        }
    }

    @Test func absentUnsafeOrUntrustedSignalsCannotInventContextOrAcknowledgement() {
        let missing = project([session(state: .idle)])
        #expect(missing.sessions.first?.activity == nil)
        #expect(missing.attentionOwnerCount == 0)
        #expect(missing.acknowledgeableOutcomes.isEmpty)
        let unsafe = AgentAttention(kind: .error, evidence: .init(source: "untrusted", eventID: UUID()), occurredAt: now)
        let invalid = project([session(attention: [unsafe], activity: .init(
            kind: .executing, summary: "PRIVATE_ARGUMENTS", lastEventAt: now
        ), children: [child("bad", state: .failed, attention: [unsafe])])])
        #expect(invalid.availability == .partial)
        #expect(invalid.sessions.first?.activity == nil)
        #expect(invalid.sessions.first?.nodes.first?.id == "bad")
        #expect(invalid.dismissibleOutcomes.isEmpty)
        #expect(invalid.sessions.first?.attentionDegraded == true)
        #expect(invalid.sessions.first?.nodes.first?.attentionDegraded == true)
        #expect(invalid.acknowledgeableOutcomes.isEmpty)
        for date in [nil, now.addingTimeInterval(1), Date(timeIntervalSince1970: .infinity)] {
            let outcome = AgentAttention(kind: .turnFinished, evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: date)
            let tree = project([session(attention: [outcome], activity: .init(
                kind: .idle, summary: "Last completed tool: view", lastEventAt: date
            ))])
            #expect(tree.sessions.first?.activity?.summary == "Last completed tool: view")
            #expect(tree.sessions.first?.activity?.lastEventAt == nil)
            #expect(tree.sessions.first?.attention.first?.occurredAt == nil)
            #expect(tree.acknowledgeableOutcomes.count == 1)
        }
    }

    @Test func corruptionFailsOpenAndResetDoesNotChangeHistoryOrMode() async throws {
        for stored: Any in [
            Data("invalid".utf8), "wrong-type",
            Data(#"{"version":99,"acknowledged":[]}"#.utf8),
            Data(#"{"version":1,"acknowledged":[{"sessionID":"bad"}]}"#.utf8),
            Data(repeating: 0, count: SidebarAttentionSettings.maximumStoredBytes + 1)
        ] {
            try withDefaults { defaults, historyFile, attentionFile, layoutStore in
                defaults.set(stored, forKey: "sidebar.attention.v1")
                let prefs = SidebarPreferences(defaults: defaults, historyFile: historyFile, attentionFile: attentionFile, layoutStore: layoutStore)
                prefs.selectedMode = .taskboard
                prefs.setRetention(.never)
                #expect(prefs.attention.acknowledged.isEmpty)
                #expect(prefs.attentionNotice != nil)
                #expect((prefs.attentionNotice?.count ?? 1000) < 300)
                #expect(project([session(attention: [signal(.error)])], attention: prefs.attention).attentionOwnerCount == 1)
                let tree = project([session(attention: [signal(.error)])])
                prefs.acknowledge(tree.acknowledgeableOutcomes, in: tree)
                #expect(prefs.attention.acknowledged.isEmpty)
                #expect(prefs.attentionNotice != nil)
                #expect(defaults.object(forKey: "sidebar.attention.v1") != nil)
                #expect(!FileManager.default.fileExists(atPath: attentionFile.path))
                prefs.resetAcknowledgements()
                #expect(prefs.attentionNotice == nil)
                #expect(prefs.history.retention == .never)
                #expect(prefs.selectedMode == .taskboard)
                #expect(SidebarPreferences(defaults: defaults, historyFile: historyFile, attentionFile: attentionFile, layoutStore: layoutStore).attention == prefs.attention)
                let stored = try Data(contentsOf: attentionFile)
                #expect(defaults.object(forKey: "sidebar.attention.v1") == nil)
                #expect(try JSONDecoder().decode(SidebarAttentionSettings.self, from: stored).isValid)
            }
            await Task.yield()
        }
    }

    @Test func fullStorageRefusesBatchWithoutEvictingPreviouslyAcknowledgedEvidence() throws {
        try withDefaults { defaults, historyFile, attentionFile, layoutStore in
            let stored = SidebarAttentionSettings(acknowledged: Set((0..<SidebarAttentionSettings.maximumAcknowledgements).map { index in
                SidebarAcknowledgedOutcome(sessionID: fixtures.sessionID, ownerID: "child-\(index)",
                                           evidence: .init(source: "copilot.events", eventID: UUID()))
            }))
            defaults.set(try JSONEncoder().encode(stored), forKey: "sidebar.attention.v1")
            let prefs = SidebarPreferences(defaults: defaults, historyFile: historyFile, attentionFile: attentionFile, layoutStore: layoutStore)
            let tree = project([session(attention: [signal(.turnFinished)])])
            prefs.acknowledge(tree.acknowledgeableOutcomes, in: tree)
            #expect(prefs.attention == stored)
            #expect(prefs.attentionNotice != nil)
            #expect(SidebarPreferences(defaults: defaults, historyFile: historyFile, attentionFile: attentionFile, layoutStore: layoutStore).attention == stored)
            prefs.resetAcknowledgements()
            prefs.acknowledge(tree.acknowledgeableOutcomes, in: tree)
            #expect(prefs.attention.acknowledged == tree.acknowledgeableOutcomes)
        }
    }

    @Test func displayCapsPrioritizeBlockersAndOnlyAcknowledgeDisplayedEvidence() {
        let failures = (0...SidebarCopilotTree.maximumNodes).map {
            child("failed-\($0)", state: .failed, attention: [signal(.error)])
        }
        let blocked = child("waiting", state: .blocked, attention: [signal(.answer)])
        let tree = project([session(children: failures + [blocked])], history: .init(retention: .never))
        #expect(tree.sessions.first?.nodes.count == SidebarCopilotTree.maximumNodes)
        #expect(tree.sessions.first?.nodes.contains { $0.id == "waiting" } == true)
        #expect(tree.acknowledgeableOutcomes.count == SidebarCopilotTree.maximumNodes - 1)
        #expect(!tree.acknowledgeableOutcomes.contains { $0.ownerID == "waiting" })
        #expect(tree.omittedChildrenCount == 2)
        #expect(tree.availability == .partial)
        #expect(!tree.hasCompleteCounts)
    }

    @Test func malformedBlockingEvidencePreventsAcknowledgementOfSameOwnersValidOutcome() {
        let malformed = AgentAttention(kind: .permission, evidence: .init(source: "untrusted", eventID: UUID()), occurredAt: now)
        let tree = project([session(attention: [signal(.turnFinished), malformed])])
        #expect(tree.sessions.first?.attentionDegraded == true)
        #expect(tree.acknowledgeableOutcomes.isEmpty)
        #expect(tree.attentionOwnerCount == 1)
    }

    @Test func uiWiresBothModesToGuardedPreferencesAndIndependentNavigation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("CMUXMaestroSidebar/UI/SidebarView.swift"), encoding: .utf8)
        #expect(view.contains("preferences.acknowledge(outcomes, in: model.copilot.tree)"))
        #expect(view.contains("model.copilot.updateAttention(preferences.attention)"))
        #expect(view.contains("sidebar-acknowledge-all"))
        #expect(view.contains("taskboard-session-attention-"))
        #expect(view.components(separatedBy: "attention: node.attention, sessionID: session.id, ownerID: node.id,").count == 3)
        #expect(view.components(separatedBy: "attention: session.attention, sessionID: session.id, ownerID: nil,").count == 3)
        #expect(view.components(separatedBy: "degraded: node.attentionDegraded, acknowledge: acknowledge").count == 3)
        #expect(view.components(separatedBy: "degraded: session.attentionDegraded, acknowledge: acknowledge").count == 3)
        #expect(view.contains("Button { navigation.select(target) }"))
        #expect(view.contains("Blocking reason unavailable"))
        #expect(view.contains("Activity time unknown"))
        let project = try String(contentsOf: root.appendingPathComponent("CMUXMaestroPreview.xcodeproj/project.pbxproj"), encoding: .utf8)
        #expect(project.contains("AgentSignals.swift in Sidebar Sources"))
        #expect(project.contains("AgentSignals.swift in Test Sources"))
        #expect(!project.contains("AgentSignals.swift in Hook Sources"))
    }

    private func signal(_ kind: AgentAttentionKind, age: TimeInterval = 0) -> AgentAttention {
        .init(kind: kind, evidence: .init(source: "copilot.events", eventID: UUID()),
              occurredAt: now.addingTimeInterval(-age))
    }

    private func child(
        _ id: String, parent: String? = nil, state: CopilotWorkState, attention: [AgentAttention]
    ) -> CopilotChildWork {
        .init(id: id, parentID: parent, kind: .subagent, name: "Same label", state: state, model: nil,
              terminalEvent: state.isTerminal ? attention.first.map { .init(id: $0.evidence.eventID, timestamp: $0.occurredAt) } : nil,
              attention: attention)
    }

    private func session(
        id: UUID? = nil, surface: UUID? = nil, state: CopilotWorkState = .idle,
        liveness: CopilotLiveness = .alive, attention: [AgentAttention] = [],
        activity: AgentActivity? = nil, children: [CopilotChildWork] = []
    ) -> CopilotSessionObservation {
        .init(sessionID: id ?? fixtures.sessionID, surfaceID: surface ?? fixtures.surfaceA,
              launchWorkspaceID: fixtures.workspaceA, liveness: liveness, state: state,
              model: nil, children: children, observedAt: now, attention: attention, activity: activity)
    }

    private func project(
        _ sessions: [CopilotSessionObservation], history: SidebarHistorySettings = .init(),
        attention: SidebarAttentionSettings = .init(), moved: Bool = false
    ) -> SidebarCopilotTree {
        SidebarCopilotTree.project(fixtures.snapshot(sessions: sessions, now: now),
                                   onto: fixtures.topology(moved: moved), now: now, history: history, attention: attention)
    }

    private func withDefaults(_ body: (UserDefaults, URL, URL, SidebarLayoutStore) throws -> Void) throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        try body(fixture.defaults, fixture.historyFile, fixture.attentionFile, .init(file: .init(url: fixture.layoutFile)))
    }
}
