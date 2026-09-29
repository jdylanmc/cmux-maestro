import Foundation
import Testing

@MainActor
struct NeutralObservationValidationTests {
    enum Malformation: String, CaseIterable {
        case nestedObservation, wrongNestedParent, flatLegacyEdges, sessionStateDetail
        case terminalExecuting, terminalInvalidActivity, childStateDetail
    }

    enum InvalidCanonicalPeer: CaseIterable {
        case none, emptyID, duplicateID, invalidMetadata
    }

    enum HistoryAction: CaseIterable {
        case expire, offerDismissal, applyDismissal, acknowledge
    }

    private let fixtures = SidebarTreeFixtures()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let eventID = UUID(uuidString: "10000000-1000-1000-1000-000000000010")!
    private var identity: ProviderSessionIdentity {
        .init(providerID: "copilot", sessionID: fixtures.sessionID.uuidString)
    }

    @Test(arguments: Malformation.allCases)
    func productionProjectionRejectsMalformedEvidenceWithoutLosingValidPeers(_ kind: Malformation) throws {
        let snapshot = malformed(kind)
        #expect(throws: AgentSessionSnapshotValidationError.self) { try snapshot.validate() }
        assertSafe(SidebarCopilotTree.project(snapshot, onto: fixtures.topology(), now: now), kind: kind)
    }

    @Test(arguments: Malformation.allCases)
    func injectedPollingReadEnforcesTheSameBoundaryBeforeHistory(_ kind: Malformation) async {
        let snapshot = malformed(kind)
        let now = now
        let poller = SidebarCopilotPolling(
            read: { _ in snapshot }, pause: { try await sidebarFrozenExpiry(0) },
            expiryPause: sidebarFrozenExpiry, now: { now }
        )
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        await sidebarEventually { !poller.isReading && poller.tree.sessions.count == 2 }
        assertSafe(poller.tree, kind: kind)
        poller.setVisible(false)
        await sidebarEventually { !poller.isReading }
    }

    @Test func invalidTerminalEvidenceCannotBeDismissedOrEvictKnownExecutingWork() throws {
        let bad = child("active", state: .unknown(), detail: .cancelled,
                        activity: .known(.init(kind: .executing, summary: "Executing tool: view")), terminal: true)
        let history = (0..<SidebarCopilotTree.maximumNodes).map {
            child("history-\($0)", state: .known(.done))
        }
        let snapshot = snapshot(observed: history + [bad])
        let settings = SidebarHistorySettings(retention: .never, dismissed: [
            .init(sessionID: fixtures.sessionID, childID: "active", eventID: eventID)
        ])
        let tree = SidebarCopilotTree.project(snapshot, onto: fixtures.topology(), now: now, history: settings)
        let session = try #require(tree.sessions.first)
        let active = try #require(session.nodes.first { $0.id == "active" })
        #expect(active.state == .unknown && active.activity?.kind == .executing)
        #expect(active.attentionDegraded)
        #expect(session.hiddenHistoryCount == 0)
        #expect(session.omittedChildrenCount == 1 && session.omittedActiveChildrenCount == 0)
        #expect(tree.dismissibleOutcomes.isEmpty)
        #expect(!tree.hasCompleteCounts)
    }

    @Test func invalidTerminalParentCannotHideItsKnownActiveDescendant() throws {
        let descendant = child("descendant", parent: .child(.init("active")))
        let parent = child("active", state: .unknown(), detail: .cancelled,
                           activity: .known(.init(kind: .executing, summary: "Executing tool: view")), terminal: true)
        let tree = SidebarCopilotTree.project(snapshot(observed: [parent, descendant]),
                                              onto: fixtures.topology(), now: now)
        let session = try #require(tree.sessions.first)
        #expect(session.nodes.map(\.id) == ["active", "descendant"])
        #expect(session.nodes.map(\.state) == [.unknown, .working])
        #expect(session.hiddenHistoryCount == 0)
        #expect(session.nodes[1].parentID == "active")
        #expect(session.nodes[1].depth == 1)
        #expect(!session.childrenComplete)
    }

    @Test func intentionalMissingParentsAndCyclesAreValidObservedEvidenceNotLegacyHierarchy() throws {
        let items = [child("orphan", parent: .child(.init("missing"))),
                     child("a", parent: .child(.init("b"))), child("b", parent: .child(.init("a")))]
        let valid = snapshot(observed: items)
        try valid.validate()
        let tree = SidebarCopilotTree.project(valid, onto: fixtures.topology(), now: now)
        #expect(tree.sessions.first?.nodes.count == 3)
        #expect(tree.sessions.first?.nodes.allSatisfy(\.ancestryUnresolved) == true)
        #expect(tree.sessions.last?.id == fixtures.otherSessionID)
        #expect(throws: AgentSessionSnapshotValidationError.self) { try snapshot(legacy: items).validate() }
    }

    @Test(arguments: [false, true])
    func untrustedTraversalIsBoundedAndOmissionsRemainExplicit(_ deep: Bool) throws {
        let limit = AgentSessionObservationAssessment.maximumNodes
        let input: AgentSessionSnapshot
        if deep {
            var nested = child("last", parent: .child(.init("n-\(AgentSessionObservationAssessment.maximumDepth - 1)")))
            for index in (0..<AgentSessionObservationAssessment.maximumDepth).reversed() {
                nested = child("n-\(index)", parent: index == 0 ? .session(identity) : .child(.init("n-\(index - 1)")),
                               state: .unknown(), detail: .idle, children: [nested])
            }
            input = snapshot(legacy: [nested])
        } else {
            input = snapshot(observed: (0...limit).map {
                child("n-\($0)", state: $0 == limit ? .known(.working) : .unknown(),
                      detail: $0 == limit ? nil : .idle)
            })
        }
        let assessment = input.assess(input.sessions[0], at: "sessions[0]")
        #expect(!assessment.isValid && assessment.hasUncountedChildren)
        #expect(assessment.children.count <= limit)
        #expect(assessment.omittedChildren == 1)
        #expect(throws: AgentSessionSnapshotValidationError.self) { try input.validate() }
        let tree = SidebarCopilotTree.project(input, onto: fixtures.topology(), now: now)
        #expect(tree.sessions.last?.id == fixtures.otherSessionID)
        #expect(tree.sessions.first?.nodes.count ?? 0 <= SidebarCopilotTree.maximumNodes)
        #expect(tree.hasUncountedChildren && tree.omittedChildrenCount >= 1)
        #expect(!tree.hasCompleteCounts && tree.availability == .partial)
        #expect(tree.dismissibleOutcomes.isEmpty && tree.acknowledgeableOutcomes.isEmpty)
        #expect(tree.omittedChildrenDescription.contains("At least") && tree.omittedChildrenDescription.contains("unknown"))
        #expect(SidebarPresentation.overviewWarnings(tree).contains { $0.contains("active counts unknown") })
    }

    @Test func compatibilityProjectionCannotContradictOrFalselyClaimFullObservationCoverage() {
        let raw = child("active")
        for legacy in [[child("active", state: .known(.done))], []] {
            let input = snapshot(legacy: legacy, observed: [raw], lossless: true)
            #expect(throws: AgentSessionSnapshotValidationError.self) { try input.validate() }
            let tree = SidebarCopilotTree.project(input, onto: fixtures.topology(), now: now)
            #expect(tree.sessions.first?.nodes.first?.state == .working)
            #expect(tree.availability == .partial && !tree.hasCompleteCounts)
        }
    }

    @Test func inconsistentCompatibilityEvidenceCannotAuthorizeTerminalHistory() {
        let terminal = child("active", state: .known(.done), terminal: true)
        let input = snapshot(legacy: [child("active")], observed: [terminal])
        #expect(throws: AgentSessionSnapshotValidationError.self) { try input.validate() }
        let tree = SidebarCopilotTree.project(input, onto: fixtures.topology(), now: now)
        #expect(tree.sessions.first?.nodes.map(\.id) == ["active"])
        #expect(tree.sessions.first?.nodes.first?.attentionDegraded == true)
        #expect(tree.hiddenHistoryCount == 0 && tree.dismissibleOutcomes.isEmpty)
        #expect(tree.availability == .partial && !tree.hasCompleteCounts)
    }

    @Test(arguments: InvalidCanonicalPeer.allCases, [false, true])
    func canonicalErrorsCannotWeakenConsistencyHistorySafety(
        _ invalidPeer: InvalidCanonicalPeer, _ falselyLossless: Bool
    ) async {
        for action in HistoryAction.allCases {
            let terminal = terminalForHistory(action)
            let safe = child("safe")
            let input = snapshot(
                legacy: falselyLossless ? [] : [child("active"), safe],
                observed: [terminal, safe] + invalidPeers(invalidPeer), lossless: falselyLossless
            )
            #expect(throws: AgentSessionSnapshotValidationError.self) { try input.validate() }
            let assessment = input.assess(input.sessions[0], at: "sessions[0]")
            #expect(assessment.invalidChildren.contains(.init("active")))
            let history = historyFor(action)
            let direct = SidebarCopilotTree.project(input, onto: fixtures.topology(), now: now, history: history)
            let polled = await poll(input, history: history)
            #expect(polled == direct)
            for tree in [direct, polled] {
                #expect(tree.availability == .partial && !tree.hasCompleteCounts)
                #expect(tree.sessions.map(\.id) == [fixtures.sessionID, fixtures.otherSessionID])
                #expect(tree.sessions.last?.state == .working && tree.sessions.last?.childrenComplete == true)
                #expect(tree.sessions.first?.nodes.first { $0.id == "safe" }?.state == .working)
                #expect(tree.sessions.first?.nodes.first { $0.id == "active" }?.attentionDegraded == true)
                #expect(tree.hiddenHistoryCount == 0)
                #expect(tree.dismissibleOutcomes.isEmpty && tree.acknowledgeableOutcomes.isEmpty)
            }
        }
    }

    @Test(arguments: HistoryAction.allCases)
    func validConsistentEvidenceRetainsExistingHistoryAuthority(_ action: HistoryAction) async throws {
        let children = [terminalForHistory(action), child("safe")]
        let input = snapshot(legacy: children, observed: children, lossless: true)
        try input.validate()
        let history = historyFor(action)
        let direct = SidebarCopilotTree.project(input, onto: fixtures.topology(), now: now, history: history)
        let polled = await poll(input, history: history)
        #expect(polled == direct)
        #expect(direct.availability == .ready && direct.hasCompleteCounts)
        #expect(direct.sessions.last?.state == .working && direct.sessions.last?.childrenComplete == true)
        #expect(direct.sessions.first?.nodes.first { $0.id == "safe" }?.state == .working)
        switch action {
        case .expire, .applyDismissal:
            #expect(direct.hiddenHistoryCount == 1)
            #expect(direct.sessions.first?.nodes.map(\.id) == ["safe"])
        case .offerDismissal:
            #expect(direct.hiddenHistoryCount == 0)
            #expect(direct.dismissibleOutcomes == [historyKey])
        case .acknowledge:
            #expect(direct.hiddenHistoryCount == 0)
            #expect(direct.acknowledgeableOutcomes == [
                .init(sessionID: fixtures.sessionID, ownerID: "active",
                      evidence: .init(source: "copilot.events", eventID: eventID))
            ])
        }
    }

    private var historyKey: SidebarDismissedOutcome {
        .init(sessionID: fixtures.sessionID, childID: "active", eventID: eventID)
    }

    private func historyFor(_ action: HistoryAction) -> SidebarHistorySettings {
        switch action {
        case .expire: .init()
        case .offerDismissal, .acknowledge: .init(retention: .never)
        case .applyDismissal: .init(retention: .never, dismissed: [historyKey])
        }
    }

    private func terminalForHistory(_ action: HistoryAction) -> AgentChildWork {
        child("active", state: .known(.done), terminal: true, attention: action == .acknowledge ? [
            .init(kind: .turnFinished, evidence: .init(source: "copilot.events", eventID: eventID),
                  occurredAt: now.addingTimeInterval(-60))
        ] : nil)
    }

    private func invalidPeers(_ kind: InvalidCanonicalPeer) -> [AgentChildWork] {
        switch kind {
        case .none: []
        case .emptyID: [child("")]
        case .duplicateID: [child("noise"), child("noise")]
        case .invalidMetadata: [
            .init(id: .init("noise"), parent: .session(identity), title: .known("Noise"),
                  state: .known(.working), activity: .unknown(), kind: .subagent,
                  model: .known(.init(identifier: "")))
        ]
        }
    }

    private func poll(_ input: AgentSessionSnapshot, history: SidebarHistorySettings) async -> SidebarCopilotTree {
        let now = now
        let poller = SidebarCopilotPolling(
            read: { _ in input }, pause: { try await sidebarFrozenExpiry(0) },
            expiryPause: sidebarFrozenExpiry, now: { now }
        )
        poller.updateHistory(history)
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        await sidebarEventually { !poller.isReading && poller.tree.sessions.count == 2 }
        let result = poller.tree
        poller.setVisible(false)
        await sidebarEventually { !poller.isReading }
        return result
    }

    private func assertSafe(_ tree: SidebarCopilotTree, kind: Malformation) {
        #expect(tree.sessions.map(\.id) == [fixtures.sessionID, fixtures.otherSessionID])
        #expect(tree.sessions.last?.state == .working && tree.sessions.last?.childrenComplete == true)
        #expect(tree.availability == .partial && !tree.hasCompleteCounts)
        #expect(tree.sessions.first?.treeDegraded == true && tree.sessions.first?.childrenComplete == false)
        #expect(tree.hiddenHistoryCount == 0)
        #expect(tree.dismissibleOutcomes.isEmpty && tree.acknowledgeableOutcomes.isEmpty)
        if kind == .sessionStateDetail {
            #expect(tree.sessions.first?.state == .unknown)
        } else {
            let active = tree.sessions.first?.nodes.first { $0.id == "active" }
            #expect(active != nil)
            switch kind {
            case .nestedObservation, .wrongNestedParent, .flatLegacyEdges:
                #expect(active?.state == .working && active?.ancestryUnresolved == true)
            case .terminalExecuting, .childStateDetail:
                #expect(active?.state == .unknown && active?.attentionDegraded == true)
            case .terminalInvalidActivity:
                #expect(active?.attentionDegraded == true)
            case .sessionStateDetail: break
            }
        }
    }

    private func malformed(_ kind: Malformation) -> AgentSessionSnapshot {
        switch kind {
        case .nestedObservation:
            return snapshot(observed: [child("parent", state: .unknown(), detail: .idle,
                                              children: [child("active", parent: .child(.init("parent")))])])
        case .wrongNestedParent:
            return snapshot(legacy: [child("parent", children: [child("active")])])
        case .flatLegacyEdges:
            return snapshot(legacy: [child("parent"), child("active", parent: .child(.init("parent")))])
        case .sessionStateDetail:
            return snapshot(state: .known(.done), detail: .failed)
        case .terminalExecuting:
            return snapshot(observed: [child("active", state: .unknown(), detail: .cancelled,
                                              activity: .known(.init(kind: .executing, summary: "Executing tool: view")),
                                              terminal: true)])
        case .terminalInvalidActivity:
            return snapshot(observed: [child("active", state: .known(.done),
                                              activity: .init(availability: .unknown, value: .init(kind: .executing)),
                                              terminal: true)])
        case .childStateDetail:
            return snapshot(observed: [child("active", state: .known(.done), detail: .failed, terminal: true)])
        }
    }

    private func child(
        _ id: String, parent: AgentChildWorkParent? = nil,
        state: SnapshotValue<AgentSessionState> = .known(.working), detail: AgentSessionStateDetail? = nil,
        activity: SnapshotValue<AgentActivity> = .unknown(), terminal: Bool = false,
        children: [AgentChildWork] = [], attention: [AgentAttention]? = nil
    ) -> AgentChildWork {
        .init(id: .init(id), parent: parent ?? .session(identity), title: .known(id), state: state,
              activity: activity, children: children, stateDetail: detail, kind: .subagent,
              terminalEvent: terminal ? .init(id: eventID, timestamp: now.addingTimeInterval(-60)) : nil,
              attention: attention)
    }

    private func snapshot(
        legacy: [AgentChildWork] = [], observed: [AgentChildWork]? = nil, lossless: Bool = false,
        state: SnapshotValue<AgentSessionState> = .known(.working), detail: AgentSessionStateDetail? = nil
    ) -> AgentSessionSnapshot {
        let adapted = CopilotSnapshotAdapter.snapshot(fixtures.snapshot(sessions: [
            fixtures.session(now: now), fixtures.session(id: fixtures.otherSessionID, state: .working, now: now)
        ], now: now), workspaceBySurface: fixtures.topology().workspaceBySurface)
        let item = AgentSessionSnapshotItem(
            identity: identity, binding: adapted.sessions[0].binding, title: .unknown(), state: state,
            activity: .unknown(), model: .unknown(), paths: .unknown(), timing: .unknown(), childWork: legacy,
            stateDetail: detail, liveness: .alive, observedAt: now,
            childWorkObservation: observed.map { .init(items: $0, legacyProjectionIsLossless: lossless) }
        )
        return .init(generatedAt: now, workspaces: adapted.workspaces, sessions: [item, adapted.sessions[1]],
                     issues: [], completeness: .known(true))
    }
}
