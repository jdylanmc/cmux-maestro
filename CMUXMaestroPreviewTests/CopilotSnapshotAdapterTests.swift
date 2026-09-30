import Foundation
import Testing

@MainActor
struct CopilotSnapshotAdapterTests {
    private let fixtures = SidebarTreeFixtures()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let eventID = UUID(uuidString: "10000000-1000-1000-1000-000000000010")!

    @Test(arguments: [CopilotWorkState.working, .idle, .blocked, .completed, .failed, .cancelled, .unknown],
          [CopilotLiveness.alive, .dead, .ambiguous, .unknown])
    func lifecycleAndProcessEvidenceRemainIndependent(_ state: CopilotWorkState, _ liveness: CopilotLiveness) throws {
        let source = fixtures.snapshot(sessions: [fixtures.session(
            liveness: liveness, state: state, children: [fixtures.child("child", state: state)], now: now
        )], now: now)
        let snapshot = adapt(source)
        try snapshot.validate()
        let item = try #require(snapshot.sessions.first)
        #expect(item.workState.rawValue == state.rawValue)
        #expect(item.childWorkObservation?.items.first?.workState.rawValue == state.rawValue)
        #expect(item.liveness?.rawValue == liveness.rawValue)
        #expect(item.timing == .unknown())
        #expect(item.paths == .unknown())
        #expect(item.appearance == nil)
        if [.idle, .failed, .cancelled].contains(state) {
            #expect(item.state == .unknown())
            #expect(item.stateDetail?.rawValue == state.rawValue)
            #expect(item.childWork.first?.state == .unknown())
        } else {
            #expect(item.stateDetail == nil)
        }
        let tree = SidebarCopilotTree.project(snapshot, onto: fixtures.topology(), now: now)
        let expected = liveness == .alive || state.isTerminal ? state.rawValue : "unknown"
        #expect(tree.sessions.first?.state.rawValue == expected)
        let visible = expected != "unknown" && expected != "idle" && expected != "cancelled"
        #expect(tree.sessions.first?.nodes.first?.state.rawValue == (visible ? expected : nil))
        #expect(tree.knownRunningChildren == (liveness == .alive && state == .working ? 1 : 0))
        #expect(tree.hasCompleteCounts == (liveness == .alive && state != .unknown))
        #expect(try AgentSessionSnapshotJSONCodec.decode(AgentSessionSnapshotJSONCodec.encode(snapshot)) == snapshot)
    }

    @Test func preservesOrderedLiteralEdgesModelsSignalsTimesAndAppearance() throws {
        let attention = signal(.permission)
        let activity = AgentActivity(kind: .executing, summary: "Executing tool: view", lastEventAt: now)
        let children: [CopilotChildWork] = [
            .init(id: "child", parentID: "parent", kind: .subagent, name: "Same name", state: .blocked,
                  model: "child-model", attention: [attention], activity: activity),
            .init(id: "parent", parentID: nil, kind: .skill, name: "Same name", state: .completed,
                  model: nil, terminalEvent: .init(id: eventID, timestamp: now.addingTimeInterval(-1))),
            .init(id: "shell", parentID: "child", kind: .shell, name: "Shell", state: .working, model: nil),
            .init(id: "orphan", parentID: "not-observed", kind: .unknown, name: "Unknown",
                  state: .unknown, model: nil),
            .init(id: "cycle-a", parentID: "cycle-b", kind: .subagent, name: "Cycle", state: .idle, model: nil),
            .init(id: "cycle-b", parentID: "cycle-a", kind: .subagent, name: "Cycle", state: .idle, model: nil)
        ]
        var observation = CopilotSessionObservation(
            sessionID: fixtures.sessionID, surfaceID: fixtures.surfaceA, launchWorkspaceID: fixtures.workspaceA,
            liveness: .alive, state: .blocked, model: "root-model", children: children,
            observedAt: now.addingTimeInterval(-0.25), attention: [attention]
        )
        observation.iconId = "md-robot"
        observation.iconColor = "blue"
        let source = fixtures.snapshot(sessions: [observation], issues: [.loadingHistory], complete: false, now: now)
        let snapshot = adapt(source, moved: true)
        try snapshot.validate()
        let item = try #require(snapshot.sessions.first)
        #expect(item.binding == .bound(.init(workspaceID: WorkspaceID(fixtures.workspaceB.uuidString),
                                             surfaceID: SurfaceID(fixtures.surfaceA.uuidString))))
        #expect(item.launchBinding?.workspaceID.rawValue == fixtures.workspaceA.uuidString)
        #expect(item.observedAt == observation.observedAt)
        #expect(snapshot.generatedAt == now)
        #expect(item.model.value?.identifier == "root-model")
        #expect(item.appearance == .init(iconId: "md-robot", iconColor: "blue"))
        #expect(item.attention == [attention])
        let evidence = try #require(item.childWorkObservation)
        #expect(!evidence.legacyProjectionIsLossless)
        #expect(evidence.items.map(\.id.rawValue) == ["child", "parent", "shell", "orphan", "cycle-a", "cycle-b"])
        #expect(evidence.items.map(\.parentID) == ["parent", nil, "child", "not-observed", "cycle-b", "cycle-a"])
        #expect(evidence.items.map(\.kind) == [.subagent, .skill, .shell, .unknown, .subagent, .subagent])
        #expect(evidence.items[0].model?.value?.identifier == "child-model")
        #expect(evidence.items[0].activity.value == activity)
        #expect(evidence.items[1].terminalEvent?.id == eventID)
        #expect(item.childWork.map(\.id.rawValue) == ["parent"])
        #expect(item.childWork.first?.children.first?.id.rawValue == "child")
        #expect(!snapshot.isComplete)
        let tree = SidebarCopilotTree.project(snapshot, onto: fixtures.topology(moved: true), now: now,
                                              history: .init(retention: .never),
                                              revealingIdleTasksIn: [fixtures.workspaceB])
        let session = try #require(tree.sessions.first)
        #expect(session.nodes.prefix(3).map(\.id) == ["parent", "child", "shell"])
        #expect(session.nodes.prefix(3).map(\.depth) == [0, 1, 2])
        #expect(session.nodes.first { $0.id == "orphan" }?.ancestryUnresolved == true)
        #expect(session.nodes.first { $0.id == "cycle-a" }?.ancestryUnresolved == true)
        #expect(session.attentionOwnerCount == 2)
        #expect(session.workspaceID == fixtures.workspaceB)
        #expect(session.iconId == "md-robot" && session.iconColor == "blue")
        #expect(session.treeDegraded && !tree.hasCompleteCounts)
        #expect(session.nodes.first { $0.id == "child" }?.activity?.lastEventAt == nil,
                "An activity timestamp later than its observation remains unknown")
    }

    @Test func vanishedSurfaceKeepsOnlyLaunchEvidenceWithoutInventingCurrentTopology() throws {
        let snapshot = CopilotSnapshotAdapter.snapshot(
            fixtures.snapshot(sessions: [fixtures.session(now: now)], now: now), workspaceBySurface: [:]
        )
        try snapshot.validate()
        #expect(snapshot.workspaces.isEmpty)
        let item = try #require(snapshot.sessions.first)
        guard case .unknown(let lastKnown, _) = item.binding else {
            Issue.record("Missing current topology must not become a bound session")
            return
        }
        #expect(lastKnown == nil)
        #expect(item.launchBinding?.surfaceID.rawValue == fixtures.surfaceA.uuidString)
        let tree = SidebarCopilotTree.project(snapshot, onto: fixtures.topology(), now: now)
        #expect(tree.sessions.isEmpty && tree.availability == .partial)
        #expect(tree.dismissibleOutcomes.isEmpty && tree.acknowledgeableOutcomes.isEmpty)
    }

    @Test func allReaderIssuesAndUnknownNeutralCodesSurviveSerializationAndProjection() throws {
        let codes: [CopilotIssue] = [
            .integrationNotInstalled, .noIdentityRecords, .stateUnavailable, .permissionDenied,
            .malformedData, .unsupportedFormat, .loadingHistory, .identityChanged, .ambiguousIdentity,
            .ambiguousTurn, .readLimitReached, .appearanceUnavailable
        ]
        let snapshot = adapt(fixtures.snapshot(sessions: [], issues: codes, complete: false, now: now))
        #expect(snapshot.issues?.map(\.rawValue) == codes.map(\.rawValue))
        let future = AgentSessionSnapshot(
            generatedAt: now, workspaces: [], sessions: [],
            issues: [.init(rawValue: "future-observation-code")], completeness: .known(false)
        )
        let decoded = try AgentSessionSnapshotJSONCodec.decode(AgentSessionSnapshotJSONCodec.encode(future))
        try decoded.validate()
        let tree = SidebarCopilotTree.project(decoded, onto: fixtures.topology(), now: now)
        #expect(tree.issues.map(\.rawValue) == ["future-observation-code"])
        #expect(tree.availability == .partial && !tree.hasCompleteCounts)
    }

    @Test func missingCompletenessAndLivenessAreNotPositiveEvidence() throws {
        let original = try #require(adapt(fixtures.snapshot(sessions: [fixtures.session(now: now)], now: now)).sessions.first)
        let item = AgentSessionSnapshotItem(
            identity: original.identity, binding: original.binding, title: .unknown(),
            state: .known(.working), activity: .unknown(), model: .unknown(), paths: .unknown(),
            timing: .unknown(), observedAt: now
        )
        let snapshot = AgentSessionSnapshot(generatedAt: now, workspaces: [], sessions: [item])
        let tree = SidebarCopilotTree.project(snapshot, onto: fixtures.topology(), now: now)
        #expect(tree.sessions.first?.liveness == .unknown)
        #expect(tree.sessions.first?.state == .unknown)
        #expect(!snapshot.isComplete && !tree.hasCompleteCounts)
        let invalidCompleteness = AgentSessionSnapshot(
            generatedAt: now, workspaces: [], sessions: [],
            completeness: .init(availability: .known, value: true, detail: "Contradictory availability")
        )
        #expect(throws: AgentSessionSnapshotValidationError.invalidAvailability(path: "completeness")) {
            try invalidCompleteness.validate()
        }
        #expect(!invalidCompleteness.isComplete)
        #expect(!SidebarCopilotTree.project(invalidCompleteness, onto: fixtures.topology(), now: now).hasCompleteCounts)
    }

    @Test func duplicateUUIDSpellingsAndMalformedObservationDoNotDisplaceValidPeers() throws {
        let source = adapt(fixtures.snapshot(sessions: [
            fixtures.session(id: UUID(uuidString: "ABCDEF00-0000-0000-0000-000000000001")!, now: now),
            fixtures.session(id: fixtures.otherSessionID, now: now)
        ], now: now))
        let data = try AgentSessionSnapshotJSONCodec.encode(source)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var sessions = try #require(object["sessions"] as? [[String: Any]])
        var duplicate = sessions[0]
        duplicate["identity"] = ["providerID": "copilot", "sessionID": "abcdef00-0000-0000-0000-000000000001"]
        sessions.append(duplicate)
        object["sessions"] = sessions
        let decoded = try AgentSessionSnapshotJSONCodec.decode(JSONSerialization.data(withJSONObject: object))
        let tree = SidebarCopilotTree.project(decoded, onto: fixtures.topology(), now: now)
        #expect(tree.sessions.map(\.id) == [fixtures.otherSessionID])
        #expect(tree.availability == .partial)
        object["schemaVersion"] = 2
        let unsupported = try AgentSessionSnapshotJSONCodec.decode(JSONSerialization.data(withJSONObject: object))
        #expect(throws: AgentSessionSnapshotValidationError.unsupportedSchemaVersion(2)) { try unsupported.validate() }
        #expect(SidebarCopilotTree.project(unsupported, onto: fixtures.topology(), now: now).availability == .unavailable)
    }

    @Test func validatesStateDetailPrecedenceAndFlatObservationStructure() throws {
        let identity = ProviderSessionIdentity(providerID: "copilot", sessionID: fixtures.sessionID.uuidString)
        func snapshot(
            _ child: AgentChildWork, observed: Bool = true
        ) -> AgentSessionSnapshot {
            .init(generatedAt: now, workspaces: [], sessions: [
                .init(identity: identity, binding: .unknown(), title: .unknown(), state: .unknown(),
                      activity: .unknown(), model: .unknown(), paths: .unknown(), timing: .unknown(),
                      childWork: observed ? [] : [child],
                      childWorkObservation: observed ? .init(items: [child]) : nil)
            ])
        }
        let unresolved = AgentChildWork(
            id: ChildWorkID("child"), parent: .child(ChildWorkID("not-observed")),
            title: .known("Child"), state: .unknown(), activity: .unknown(), stateDetail: .failed
        )
        try snapshot(unresolved).validate()
        #expect(throws: AgentSessionSnapshotValidationError.self) { try snapshot(unresolved, observed: false).validate() }
        let contradiction = AgentChildWork(
            id: ChildWorkID("child"), parent: .session(identity), title: .known("Child"),
            state: .known(.done), activity: .unknown(), stateDetail: .failed
        )
        #expect(contradiction.workState == .unknown)
        #expect(throws: AgentSessionSnapshotValidationError.incompatibleStateDetail(path: "sessions[0].childWorkObservation.items[0].stateDetail")) {
            try snapshot(contradiction).validate()
        }
        let foreign = AgentChildWork(
            id: ChildWorkID("child"), parent: .session(.init(providerID: "copilot", sessionID: "foreign")),
            title: .unknown(), state: .unknown(), activity: .unknown()
        )
        #expect(throws: AgentSessionSnapshotValidationError.self) { try snapshot(foreign).validate() }
        let nested = AgentChildWork(
            id: ChildWorkID("parent"), parent: .session(identity), title: .unknown(),
            state: .unknown(), activity: .unknown(), children: [unresolved]
        )
        #expect(throws: AgentSessionSnapshotValidationError.self) { try snapshot(nested).validate() }
    }

    @Test(arguments: [SnapshotAvailability.degraded, .unknown])
    func unavailableValuesCannotReappearAsCurrentActivityModelOrCompletedHistory(_ availability: SnapshotAvailability) throws {
        let source = adapt(fixtures.snapshot(sessions: [fixtures.session(now: now)], now: now))
        let original = try #require(source.sessions.first)
        let detail = availability == .degraded ? "Not currently observed" : nil
        let activity = SnapshotValue(
            availability: availability, value: AgentActivity(kind: .executing, summary: "Executing tool: view"),
            detail: detail
        )
        let model = SnapshotValue(availability: availability, value: AgentModel(identifier: "stale-model"), detail: detail)
        let state = SnapshotValue(availability: availability, value: AgentSessionState.done, detail: detail)
        let child = AgentChildWork(
            id: ChildWorkID("child"), parent: .session(original.identity), title: .known("Child"),
            state: state, activity: activity, kind: .subagent, model: model,
            terminalEvent: .init(id: eventID, timestamp: now.addingTimeInterval(-60))
        )
        let snapshot = AgentSessionSnapshot(
            generatedAt: now, workspaces: source.workspaces, sessions: [.init(
                identity: original.identity, binding: original.binding, title: .unknown(), state: state,
                activity: activity, model: model, paths: .unknown(), timing: .unknown(),
                liveness: .alive, observedAt: now, childWorkObservation: .init(items: [child])
            )], issues: [], completeness: .known(true)
        )
        if availability == .degraded {
            try snapshot.validate()
        } else {
            #expect(throws: AgentSessionSnapshotValidationError.self) { try snapshot.validate() }
        }
        let tree = SidebarCopilotTree.project(snapshot, onto: fixtures.topology(), now: now)
        #expect(tree.availability == .partial && !tree.hasCompleteCounts)
        #expect(tree.sessions.first?.model == nil && tree.sessions.first?.activity == nil)
        #expect(tree.sessions.first?.state == .unknown)
        #expect(tree.sessions.first?.nodes.first?.state == .unknown)
        #expect(tree.sessions.first?.nodes.first?.model == nil && tree.sessions.first?.nodes.first?.activity == nil)
        #expect(tree.hiddenHistoryCount == 0 && tree.dismissibleOutcomes.isEmpty)
    }

    @Test(arguments: [AgentSessionStateDetail.failed, .cancelled])
    func detailedTerminalStatesRetainStrictActivityAndTimingValidation(_ detail: AgentSessionStateDetail) throws {
        let identity = ProviderSessionIdentity(providerID: "copilot", sessionID: fixtures.sessionID.uuidString)
        func snapshot(activity: SnapshotValue<AgentActivity>, timing: SnapshotValue<AgentSessionTiming>) -> AgentSessionSnapshot {
            .init(generatedAt: now, workspaces: [], sessions: [
                .init(identity: identity, binding: .unknown(), title: .unknown(), state: .unknown(),
                      activity: activity, model: .unknown(), paths: .unknown(), timing: timing, stateDetail: detail)
            ])
        }
        #expect(throws: AgentSessionSnapshotValidationError.incompatibleStateActivity(path: "sessions[0].activity")) {
            try snapshot(activity: .known(.init(kind: .executing)), timing: .unknown()).validate()
        }
        #expect(throws: AgentSessionSnapshotValidationError.invalidStateTiming(path: "sessions[0].timing")) {
            try snapshot(activity: .unknown(), timing: .known(.init(startedAt: now, updatedAt: now))).validate()
        }
        try snapshot(activity: .unknown(), timing: .unknown()).validate()
    }

    @Test func resumedReaderObservationKeepsSavedIdentityWithoutInventingTerminalOrResumeAuthority() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([
            copilotTestEvent("subagent.started", agent: "child", data: ["toolCallId": "old", "agentDisplayName": "Child"]),
            copilotTestEvent("subagent.completed", agent: "child", data: ["toolCallId": "old"]),
            copilotTestEvent("session.resume")
        ])
        let now = now
        let source = try await fixture.reader(clock: { now }).read(surfaceIDs: [fixture.surface])
        let snapshot = CopilotSnapshotAdapter.snapshot(source, workspaceBySurface: [fixture.surface: fixture.workspace])
        try snapshot.validate()
        #expect(snapshot.sessions.first?.identity.sessionID == fixture.sessionID.uuidString)
        #expect(snapshot.sessions.first?.workState == .unknown)
        let tree = SidebarCopilotTree.project(snapshot, onto: readerTopology(fixture), now: now)
        #expect(tree.sessions.first?.state == .unknown)
        #expect(tree.sessions.first?.nodes.allSatisfy { !$0.state.isTerminal && $0.terminalEvent == nil } == true)
        #expect(tree.dismissibleOutcomes.isEmpty)
    }

    @Test func productionPollingUsesTheReaderAdapterWithoutReadingAnyPrivateSession() async throws {
        let fixture = try CopilotReaderFixture()
        defer { fixture.remove() }
        try fixture.writeEvents([
            copilotTestEvent("subagent.started", agent: "parent", data: ["toolCallId": "spawn-parent", "agentDisplayName": "Parent"]),
            copilotTestEvent("subagent.started", agent: "child", data: [
                "toolCallId": "spawn-child", "agentDisplayName": "Child", "parentId": "parent"
            ]),
            copilotTestEvent("subagent.configured", agent: "child", data: ["model": "synthetic-model"]),
            copilotTestEvent("assistant.turn_start", agent: "child", data: ["turnId": "child-turn"])
        ])
        let now = now
        let reader = fixture.reader(clock: { now })
        let poller = SidebarCopilotPolling(
            reader: reader, pause: { try await sidebarFrozenExpiry(0) },
            expiryPause: sidebarFrozenExpiry, now: { now }
        )
        let topology = readerTopology(fixture)
        poller.update(topology: topology, connected: true)
        poller.setVisible(true)
        await sidebarEventually { poller.tree.sessions.count == 1 && !poller.isReading }
        let session = try #require(poller.tree.sessions.first)
        #expect(session.id == fixture.sessionID && session.surfaceID == fixture.surface)
        #expect(session.nodes.map(\.id) == ["parent", "child"])
        #expect(session.nodes.map(\.depth) == [0, 1])
        #expect(session.nodes.last?.model == "synthetic-model")
        #expect(session.nodes.last?.state == .working)
        #expect(session.nodes.last?.kind == .subagent)
        poller.setVisible(false)
        await sidebarEventually { !poller.isReading }
        let neutral = CopilotSnapshotAdapter.snapshot(
            try await reader.read(surfaceIDs: [fixture.surface]), workspaceBySurface: topology.workspaceBySurface
        )
        try neutral.validate()
        let encoded = try #require(String(data: AgentSessionSnapshotJSONCodec.encode(neutral), encoding: .utf8))
        for forbidden in ["ownerPID", "ownerStart", "parentPID", ":4242", "arguments", "credentials", "resumeCapability"] {
            #expect(!encoded.contains(forbidden))
        }
    }

    private func adapt(_ source: CopilotSnapshot, moved: Bool = false) -> AgentSessionSnapshot {
        CopilotSnapshotAdapter.snapshot(source, workspaceBySurface: fixtures.topology(moved: moved).workspaceBySurface)
    }

    private func signal(_ kind: AgentAttentionKind) -> AgentAttention {
        .init(kind: kind, evidence: .init(source: "copilot.events", eventID: eventID), occurredAt: now)
    }

    private func readerTopology(_ fixture: CopilotReaderFixture) -> SidebarTopology {
        SidebarTopology(.init(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: true, surfaceMetadataAvailable: true, workspacePathsAvailable: false,
            workspaces: [.init(
                id: fixture.workspace, title: .unavailable, detail: .unavailable,
                isSelected: .unavailable, isPinned: .unavailable, unreadCount: .unavailable,
                rootPath: .unavailable, projectRootPath: .unavailable,
                surfaces: .available([.init(id: fixture.surface, title: "Synthetic", kind: .terminal,
                                             isFocused: false, isPinned: false, unreadCount: 0, workingDirectory: .unavailable)])
            )], windowID: UUID()
        ))
    }
}
