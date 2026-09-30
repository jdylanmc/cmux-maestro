import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct SidebarInternalTaskTests {
    private let fixtures = SidebarTreeFixtures()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let event = UUID(uuidString: "13100000-0000-0000-0000-000000000001")!

    @Test(arguments: ["missing", "unknown", "queued", "working", "blocked", "done"],
          ["none", "idle", "failed", "cancelled"])
    func everyNeutralStateDetailCombinationPreservesTruthOrDegrades(_ primary: String, _ detail: String) throws {
        let state: SnapshotValue<AgentSessionState> = primary == "missing" ? .unknown()
            : .known(try #require(AgentSessionState(rawValue: primary)))
        let child = AgentChildWork(
            id: .init("task"), parent: .session(identity), title: .known("Task"), state: state, activity: .unknown(),
            stateDetail: AgentSessionStateDetail(rawValue: detail), kind: .subagent,
            terminalEvent: .init(id: event, timestamp: now)
        )
        let adapted = CopilotSnapshotAdapter.snapshot(fixtures.snapshot(sessions: [fixtures.session(now: now)], now: now),
                                                       workspaceBySurface: fixtures.topology().workspaceBySurface)
        let item = AgentSessionSnapshotItem(
            identity: identity, binding: adapted.sessions[0].binding, title: .unknown(),
            state: .unknown(), activity: .unknown(), model: .unknown(), paths: .unknown(), timing: .unknown(),
            liveness: .alive, observedAt: now, childWorkObservation: .init(items: [child])
        )
        let snapshot = AgentSessionSnapshot(generatedAt: now, workspaces: adapted.workspaces,
                                           sessions: [item], issues: [], completeness: .known(true))
        let tree = SidebarCopilotTree.project(snapshot, onto: fixtures.topology(), now: now,
                                              revealingIdleTasksIn: [fixtures.workspaceA])
        if detail != "none" && primary != "missing" {
            let node = try #require(tree.sessions[0].nodes.first)
            #expect(node.state == .unknown && node.attentionDegraded)
            #expect(node.stateDetail?.rawValue == detail)
            #expect(tree.dismissibleOutcomes.isEmpty)
        } else {
            let expected = detail != "none" ? detail : primary == "done" ? "completed" : primary
            if ["unknown", "missing", "cancelled"].contains(expected) {
                #expect(tree.sessions[0].nodes.isEmpty)
            } else {
                let node = try #require(tree.sessions[0].nodes.first)
                #expect(node.state.rawValue == expected)
                #expect(node.stateDetail?.rawValue == (detail == "none" ? nil : detail))
            }
        }
    }

    @Test(arguments: [CopilotWorkState.working, .idle, .blocked, .completed, .failed, .cancelled, .unknown])
    func detailAndRelevanceSurviveNeutralProjection(_ state: CopilotWorkState) throws {
        let source = task("task", state: state)
        let neutral = CopilotSnapshotAdapter.child(source, session: identity)
        #expect(neutral.workState.rawValue == state.rawValue)
        #expect(neutral.isInternalTask)
        let visibleByDefault = [CopilotWorkState.working, .blocked, .completed, .failed].contains(state)
        let tree = project([source])
        #expect(tree.sessions[0].nodes.count == (visibleByDefault ? 1 : 0))
        let revealed = project([source], revealing: [fixtures.workspaceA])
        #expect(revealed.sessions[0].nodes.count == (visibleByDefault || state == .idle ? 1 : 0))
        if let node = revealed.sessions[0].nodes.first {
            #expect(node.state.rawValue == state.rawValue)
            #expect(node.stateDetail == neutral.stateDetail)
            #expect(node.observedParent == .session(identity))
            #expect(node.terminalEvent?.id == event)
        }
        #expect(tree.nextHistoryExpiry == nil)
        #expect(tree.hasCompleteCounts == (state != .unknown))
    }

    @Test func kindAndLiteralParentNotNamesOrMissingSurfacesClassifyTasks() throws {
        let children: [CopilotChildWork] = [
            task("provider", state: .working),
            .init(id: "skill", parentID: "provider", kind: .skill, name: "subagent", state: .working, model: nil),
            .init(id: "shell", parentID: "provider", kind: .shell, name: "subagent", state: .working, model: nil),
            .init(id: "unknown", parentID: nil, kind: .unknown, name: "subagent", state: .working, model: nil)
        ]
        let tree = project(children)
        #expect(tree.sessions[0].nodes.filter(\.isInternalTask).map(\.id) == ["provider"])
        let unattested = SidebarCopilotNode(
            id: "unattested", parentID: nil, depth: 0, kind: .subagent, name: "subagent",
            state: .working, model: nil, ancestryUnresolved: false, hasChildren: false
        )
        #expect(!unattested.isInternalTask)
        #expect(!SidebarInternalTaskPolicy.isInternalTask(kind: .subagent, parent: .child(.init(""))))
        let realChild = fixtures.session(id: fixtures.otherSessionID, surface: fixtures.surfaceB,
                                         state: .working, now: now)
        let snapshot = CopilotSnapshotAdapter.snapshot(fixtures.snapshot(sessions: [
            fixtures.session(children: children, now: now), realChild
        ], now: now), workspaceBySurface: fixtures.topology().workspaceBySurface)
        let projected = SidebarCopilotTree.project(snapshot, onto: fixtures.topology(), now: now)
        #expect(projected.sessions.map(\.surfaceID) == [fixtures.surfaceA, fixtures.surfaceB])
        #expect(projected.sessions[1].nodes.isEmpty)
    }

    @Test func internalOutcomesIgnoreEveryRetentionClockButLegacyActivityStillExpires() {
        for retention in SidebarHistoryRetention.allCases {
            let children = [
                task("finished", state: .completed), task("failed", state: .failed),
                CopilotChildWork(id: "skill", parentID: nil, kind: .skill, name: "Skill",
                                 state: .completed, model: nil,
                                 terminalEvent: .init(id: event, timestamp: now.addingTimeInterval(-86_400)))
            ]
            let tree = project(children, history: .init(retention: retention))
            #expect(tree.sessions[0].nodes.filter(\.isInternalTask).map(\.id) == ["finished", "failed"])
            #expect(tree.sessions[0].nodes.contains { $0.id == "skill" } == (retention == .never))
            #expect(tree.nextHistoryExpiry == nil)
        }
    }

    @Test func dismissedOutcomeReturnsOnlyForNewEvidenceWorkOrAttention() {
        let history = SidebarHistorySettings(dismissed: [key("result")])
        #expect(project([task("result", state: .completed)], history: history, revealing: [fixtures.workspaceA])
            .sessions[0].nodes.isEmpty)
        for state in [CopilotWorkState.working, .blocked] {
            #expect(project([task("result", state: state)], history: history).sessions[0].nodes.map(\.id) == ["result"])
        }
        #expect(project([task("result", state: .failed, eventID: UUID())], history: history).sessions[0].nodes.count == 1)
        #expect(project([task("result", state: .completed, attention: [signal(.error)])], history: history)
            .sessions[0].nodes.count == 1)
        #expect(project([task("result", state: .cancelled)], history: history, revealing: [fixtures.workspaceA])
            .sessions[0].nodes.isEmpty)
    }

    @Test func attentionAndRequiredAncestorsRemainWithoutMakingThemDismissible() throws {
        let children = [
            task("idle-parent", state: .idle),
            task("unknown-parent", parent: "idle-parent", state: .unknown),
            task("cancelled-parent", parent: "unknown-parent", state: .cancelled),
            task("finished-parent", parent: "cancelled-parent", state: .completed),
            task("blocked", parent: "finished-parent", state: .blocked, attention: [signal(.permission)]),
            task("unrelated", state: .unknown)
        ]
        let tree = project(children, history: .init(dismissed: [key("finished-parent")]))
        #expect(tree.sessions[0].nodes.map(\.id) == [
            "idle-parent", "unknown-parent", "cancelled-parent", "finished-parent", "blocked"
        ])
        #expect(tree.dismissibleOutcomes.isEmpty)
        #expect(tree.sessions[0].nodes.map(\.depth) == [0, 1, 2, 3, 4])
        let work = SidebarVisibleWork(tree: tree, managed: [], history: .init(), showEnded: false, now: now)
        #expect(work.tree.sessions[0].nodes == tree.sessions[0].nodes)
        let section = try #require(tree.sessions[0].childSections(layout: .init()).first)
        let summary = tree.sessions[0].taskSummary(for: section)
        #expect(summary.running == 0 && summary.blocked == 1 && summary.attention == 1)
        #expect(summary.incomplete)
    }

    @Test func staleDismissControlsCannotHideRenewalReplacementAttentionOrOffWindowWork() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let captured = key("result")
        let alternatives = [
            project([task("result", state: .working)]),
            project([task("result", state: .completed, eventID: UUID())]),
            project([task("result", state: .completed, attention: [signal(.error)])]),
            project([task("result", state: .completed), task("child", parent: "result", state: .working)]),
            SidebarCopilotTree.waiting
        ]
        for tree in alternatives {
            #expect(!preferences.dismissInternalTask(captured, in: tree, now: now))
            #expect(preferences.history.dismissed.isEmpty)
        }
        let current = project([task("result", state: .completed)])
        #expect(!preferences.dismissInternalTask(captured, in: current, now: now.addingTimeInterval(9)))
        #expect(preferences.dismissInternalTask(captured, in: current, now: now))
        #expect(fixture.preferences().history.dismissed == [captured])
        #expect(preferences.attention.acknowledged.isEmpty)
    }

    @Test func independentDisclosureAndWorkspaceEyesMergeAndSurviveReload() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let first = fixture.preferences()
        let second = fixture.preferences()
        let group = SidebarExpansionID.internalTasks(sessionID: fixtures.sessionID)
        let nested = SidebarExpansionID.child("parent", sessionID: fixtures.sessionID)
        first.setExpanded(false, for: group)
        second.setExpanded(false, for: nested)
        first.setIdleTasksVisible(true, in: fixtures.workspaceA)
        second.setIdleTasksVisible(true, in: fixtures.workspaceB)
        first.setIdleTasksVisible(false, in: fixtures.workspaceA)
        let reloaded = fixture.preferences()
        #expect(reloaded.layout == first.layout && first.layout == second.layout)
        #expect(!reloaded.layout.isExpanded(group) && !reloaded.layout.isExpanded(nested))
        #expect(reloaded.layout.isExpanded(.internalTasks(sessionID: fixtures.otherSessionID)))
        #expect(reloaded.layout.isExpanded(.child("parent", sessionID: fixtures.otherSessionID)))
        #expect(reloaded.layout.revealingIdleTasksIn == [fixtures.workspaceB])
        #expect(!reloaded.showEnded)
        #expect(reloaded.history == .init() && reloaded.attention == .init())
        let bytes = try JSONDecoder().decode(SidebarLayoutSettings.self, from: Data(contentsOf: fixture.layoutFile))
        #expect(bytes == reloaded.layout)
    }

    @Test func corruptTaskLayoutCannotSilentlyPersistDisclosureOrChangeWorkspaceChoices() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let bytes = Data("invalid layout".utf8)
        try bytes.write(to: fixture.layoutFile)
        let preferences = fixture.preferences()
        preferences.setExpanded(false, for: .internalTasks(sessionID: fixtures.sessionID))
        preferences.setIdleTasksVisible(true, in: fixtures.workspaceA)
        #expect(preferences.layoutNotice != nil)
        #expect(preferences.layout.isExpanded(.internalTasks(sessionID: fixtures.sessionID)))
        #expect(preferences.layout.revealingIdleTasksIn.isEmpty)
        #expect(try Data(contentsOf: fixture.layoutFile) == bytes)
        #expect(preferences.history == .init() && preferences.attention == .init())
    }

    @Test func producerIncompletenessAndNonTaskAncestorsSurviveBothTaskConsumers() throws {
        let children: [CopilotChildWork] = [
            .init(id: "skill", parentID: nil, kind: .skill, name: "Skill", state: .idle, model: nil),
            task("working", parent: "skill", state: .working)
        ]
        let session = project(children, complete: false).sessions[0]
        let sections = session.taskSections(layout: .init())
        #expect(sections.map(\.id) == ["skill", "working"])
        #expect(sections[0].taskDisclosure == nil)
        #expect(sections[1].taskDisclosure == .internalTasks(sessionID: fixtures.sessionID, parentID: "skill"))
        #expect(session.taskSummary(for: sections[1]).incomplete)
        #expect(session.taskSummary(for: sections[1]).taskCount == 1)
        #expect(session.nodes[0].kind == .skill && !session.nodes[0].isInternalTask)
    }

    @Test func workspaceEyeUsesCurrentPlacementWithoutChangingOtherWorkspaceOrRealTabs() {
        let children = [task("idle", state: .idle), task("unknown", state: .unknown), task("cancelled", state: .cancelled)]
        let topology = fixtures.topology(moved: true)
        let snapshot = CopilotSnapshotAdapter.snapshot(fixtures.snapshot(sessions: [
            fixtures.session(children: children, now: now)
        ], now: now), workspaceBySurface: topology.workspaceBySurface)
        let hidden = SidebarCopilotTree.project(snapshot, onto: topology, now: now, revealingIdleTasksIn: [fixtures.workspaceA])
        let visible = SidebarCopilotTree.project(snapshot, onto: topology, now: now, revealingIdleTasksIn: [fixtures.workspaceB])
        #expect(hidden.sessions[0].nodes.isEmpty)
        #expect(visible.sessions[0].nodes.map(\.id) == ["idle"])
        #expect(visible.sessions[0].surfaceID == fixtures.surfaceA)
        #expect(topology.workspaceBySurface == fixtures.topology(moved: true).workspaceBySurface)
    }

    @Test func disclosureSummaryIncludesHiddenDescendantsInBothConsumers() throws {
        let session = project([
            task("parent", state: .completed), task("working", parent: "parent", state: .working),
            task("blocked", parent: "parent", state: .blocked, attention: [signal(.permission)])
        ]).sessions[0]
        var layout = SidebarLayoutSettings()
        layout.setExpanded(false, for: .child("parent", sessionID: session.id))
        for taskboard in [false, true] {
            let section = try #require(session.childSections(layout: layout, taskboard: taskboard).first)
            #expect(section.rows.map(\.id) == ["parent"])
            let summary = session.taskSummary(for: section)
            #expect(summary.taskCount == 3)
            #expect(summary.running == 1 && summary.blocked == 1 && summary.attention == 1)
            #expect(!summary.incomplete)
        }
    }

    @Test func finishedParentIsRetainedOnlyWhileTaskOutcomeNeedsReview() throws {
        let tree = project([task("result", state: .completed)], liveness: .dead)
        let before = SidebarVisibleWork(tree: tree, managed: [], history: .init(), showEnded: false, now: now)
        #expect(before.tree.sessions.map(\.id) == [fixtures.sessionID])
        let history = SidebarHistorySettings(dismissed: [key("result")])
        let after = SidebarVisibleWork(tree: project([task("result", state: .completed)], history: history, liveness: .dead),
                                       managed: [], history: history, showEnded: false, now: now)
        #expect(after.tree.sessions.isEmpty)
        #expect(fixtures.topology().workspaceBySurface[fixtures.surfaceA] == fixtures.workspaceA)
    }

    @Test func productionBoundsRetainActiveWorkAndExplicitIncompleteCounts() throws {
        let children = (0..<SidebarCopilotTree.maximumNodes).map { task("finished-\($0)", state: .completed) }
            + (0...SidebarCopilotTree.maximumDepth).map {
                task("deep-\($0)", parent: $0 == 0 ? nil : "deep-\($0 - 1)", state: .working)
            }
        let tree = project(children)
        let session = try #require(tree.sessions.first)
        #expect(session.nodes.count == 256)
        #expect(session.knownRunningChildren == 13)
        #expect(session.nodes.map(\.depth).max() == 12)
        #expect(session.omittedChildrenCount == 13)
        #expect(!tree.hasCompleteCounts)
        for width in [280.0, 350, 460] {
            #expect(SidebarInternalTaskRow.indentation(depth: 12, width: width) <= 36)
            #expect(SidebarInternalTaskRow.indentation(depth: 1200, width: width) <= 36)
        }
    }

    @Test func stateShapesAreDistinctAndOnlyWorkingAnimatesIncludingReducedMotion() {
        let states: [AgentWorkState] = [.unknown, .queued, .working, .idle, .blocked, .completed, .failed, .cancelled]
        let visuals = states.map { state in
            var node = project([task("task", state: .working)]).sessions[0].nodes[0]
            node = .init(id: node.id, parentID: nil, depth: 0, kind: node.kind, name: node.name,
                         state: state, model: nil, ancestryUnresolved: false, hasChildren: false,
                         observedParent: node.observedParent)
            return SidebarPresentation.internalTaskState(node)
        }
        #expect(Set(visuals.map(\.symbol)).count == 8)
        #expect(visuals.filter { $0.tone == .green }.map(\.title) == ["Working"])
        #expect(SidebarPresentation.activityTreatment(visuals[2], reduceMotion: false) == .rotatingWorking)
        #expect(SidebarPresentation.activityTreatment(visuals[2], reduceMotion: true) == .steadyWorking)
        #expect(SidebarPresentation.workingRotation(at: now, reduceMotion: true) == 0)
    }

    private var identity: ProviderSessionIdentity {
        .init(providerID: "copilot", sessionID: fixtures.sessionID.uuidString)
    }
    private func key(_ id: String) -> SidebarDismissedOutcome {
        .init(sessionID: fixtures.sessionID, childID: id, eventID: event)
    }
    private func signal(_ kind: AgentAttentionKind) -> AgentAttention {
        .init(kind: kind, evidence: .init(source: "copilot.events", eventID: event), occurredAt: now)
    }
    private func task(
        _ id: String, parent: String? = nil, state: CopilotWorkState, eventID: UUID? = nil,
        attention: [AgentAttention] = []
    ) -> CopilotChildWork {
        .init(id: id, parentID: parent, kind: .subagent, name: "Task \(id)", state: state, model: nil,
              terminalEvent: .init(id: eventID ?? event, timestamp: now.addingTimeInterval(-86_400)),
              attention: attention)
    }
    private func project(
        _ children: [CopilotChildWork], history: SidebarHistorySettings = .init(),
        revealing: Set<UUID> = [], liveness: CopilotLiveness = .alive, complete: Bool = true
    ) -> SidebarCopilotTree {
        let topology = fixtures.topology()
        let snapshot = CopilotSnapshotAdapter.snapshot(fixtures.snapshot(sessions: [
            fixtures.session(liveness: liveness, children: children, now: now)
        ], complete: complete, now: now), workspaceBySurface: topology.workspaceBySurface)
        return SidebarCopilotTree.project(snapshot, onto: topology, now: now, history: history,
                                          revealingIdleTasksIn: revealing)
    }
}
