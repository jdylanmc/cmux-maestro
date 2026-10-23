import Foundation
import Testing

@MainActor
struct SidebarWorkspaceCountTests {
    private let fixtures = SidebarTreeFixtures()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func semanticChangesInvalidateOnlyTheirWorkspacePresentationKey() {
        let first = tree([
            session(fixtures.sessionID, surface: fixtures.surfaceA),
            session(fixtures.otherSessionID, surface: fixtures.surfaceB, workspace: fixtures.workspaceB)
        ])
        var second = first
        second.sessions[0].sessionName = "Changed session"
        #expect(SidebarCopilotPresentationKey(first, now: now, workspaceID: fixtures.workspaceA)
            != SidebarCopilotPresentationKey(second, now: now, workspaceID: fixtures.workspaceA))
        #expect(SidebarCopilotPresentationKey(first, now: now, workspaceID: fixtures.workspaceB)
            == SidebarCopilotPresentationKey(second, now: now, workspaceID: fixtures.workspaceB))
        second.sessions.append(session(fixtures.otherSessionID, surface: fixtures.surfaceA))
        #expect(SidebarCopilotPresentationKey(first, now: now, workspaceID: fixtures.workspaceB)
            != SidebarCopilotPresentationKey(second, now: now, workspaceID: fixtures.workspaceB),
            "A duplicate identity in another workspace must invalidate its affected owner")
    }

    @Test(arguments: ["historical", "duplicate", "ambiguous", "stale-snapshot", "stale-observation"])
    func cachedPlacementsPreserveIdentityBarriers(_ variant: String) {
        let cache = SidebarPlacementCache()
        let observed = variantTree(variant)
        let managed = [owner(sessionID: fixtures.otherSessionID)]
        let expected = SidebarPresentation.sessionPlacements(
            observed.sessions, managed: managed, observations: observed, now: now
        )
        let value = cache.placements(tree: observed, managed: managed, now: now)
        let placements = value.byWorkspace[fixtures.workspaceA] ?? []
        #expect(placements.map(\.sessionIndex) == Array(observed.sessions.indices))
        #expect(placements.map(\.managedNodeID) == expected.map(\.managedNodeID))
        #expect(placements.map(\.contentOwnerID) == expected.map(\.contentOwnerID))
        #expect(value.displaced == SidebarPresentation.displacedManagedNodeIDs(managed, observations: observed, now: now))
    }

    @Test func groupedConsumersReuseOwnershipWithoutRescanningEvidence() {
        let cache = SidebarPlacementCache()
        let root = owner(sessionID: fixtures.sessionID)
        let competitor = owner(sessionID: fixtures.sessionID)
        let observed = tree([session(fixtures.sessionID, surface: fixtures.surfaceA)])
        for _ in 0..<30 {
            let snapshot = cache.placements(tree: observed, managed: [root, competitor], now: now)
            #expect(snapshot.ownedSessionIndices(managed: [root, competitor]).isEmpty)
            // A Worktrees member restricts the displayed owners, not the identity evidence.
            #expect(snapshot.ownedSessionIndices(managed: [root])[root.id] == [0])
            let scoped = snapshot.materialize(observed.sessions, managed: [root])
            #expect(scoped.first?.contentOwnerID == root.id)
            let cached = SidebarPresentation.collapsedActivity(
                sessions: observed.sessions, managed: [root], availability: .ready,
                observations: observed, now: now, placements: scoped
            )
            #expect(cached?.count == 1)
            #expect(cached?.visual == SidebarPresentation.state(.working))
        }
        #expect(cache.computationCount == 1)
    }

    @Test func cachedPlacementsInvalidateOnOwnershipPermissionAndTopologyChanges() {
        let cache = SidebarPlacementCache()
        let managed = owner(sessionID: fixtures.sessionID)
        var observed = tree([session(fixtures.sessionID, surface: fixtures.surfaceA)])
        #expect(cache.placements(tree: observed, managed: [managed], now: now)
            .byWorkspace[fixtures.workspaceA]?.first?.contentOwnerID == managed.id)
        observed.sessions = [session(fixtures.otherSessionID, surface: fixtures.surfaceA)]
        #expect(cache.placements(tree: observed, managed: [managed], now: now).displaced == [managed.id])
        observed.issues = [.permissionDenied]
        #expect(cache.placements(tree: observed, managed: [managed], now: now).displaced.isEmpty)
        observed.issues = []
        observed.sessions = [session(fixtures.sessionID, surface: fixtures.surfaceB, workspace: fixtures.workspaceB)]
        let moved = cache.placements(tree: observed, managed: [managed], now: now)
        #expect(moved.byWorkspace[fixtures.workspaceA] == nil)
        #expect(moved.byWorkspace[fixtures.workspaceB]?.first?.managedNodeID == nil)
        #expect(cache.computationCount == 4)
        observed.sessions = [session(fixtures.sessionID, surface: fixtures.surfaceA)]
        #expect(cache.placements(tree: observed, managed: [], now: now)
            .byWorkspace[fixtures.workspaceA]?.first?.contentOwnerID == nil)
        #expect(cache.computationCount == 5)
    }

    @Test func collapsedWorkspaceKeepsWorkingCountWithoutDoubleCountingManagedSessions() throws {
        let root = owner(sessionID: fixtures.sessionID)
        let observed = tree([
            session(fixtures.sessionID, surface: fixtures.surfaceA),
            session(fixtures.otherSessionID, surface: fixtures.surfaceB)
        ])
        let attention = SidebarPresentation.workspaceAttention(
            sessions: observed.sessions, managed: [root], availability: .ready, now: now, observations: observed
        )
        let activity = try #require(summary(observed, managed: [root]).collapsedActivity(attention: attention))
        #expect(activity.count == 2)
        #expect(activity.visual == SidebarPresentation.state(.working))
    }

    @Test(arguments: ["input", "blocked", "failed", "idle", "unknown", "incomplete"])
    func collapsedWorkspacePrioritizesActionAndNeverHidesUncertainty(_ scenario: String) throws {
        let state: AgentWorkState = switch scenario {
        case "blocked": .blocked
        case "failed": .failed
        case "unknown": .unknown
        default: .idle
        }

        var observed = session(fixtures.sessionID, surface: fixtures.surfaceA, state: state)
        if scenario == "input" {
            observed.attention = [.init(kind: .permission, evidence: .init(source: "copilot.events", eventID: UUID()),
                                        occurredAt: now)]
        }
        if scenario == "incomplete" { observed.attentionDegraded = true }
        let competing = ["input", "blocked", "failed"].contains(scenario)
            ? [session(fixtures.otherSessionID, surface: fixtures.surfaceB)] : []
        let snapshot = tree([observed] + competing)
        let activity = SidebarPresentation.collapsedActivity(
            sessions: snapshot.sessions, managed: [], availability: .ready, observations: snapshot, now: now
        )
        if scenario == "idle" {
            #expect(activity == nil)
        } else {
            let cue = try #require(activity)
            let expected = switch scenario {
            case "input": "Needs input"
            case "blocked": "Blocked"
            case "failed": "Failed"
            case "unknown": "Unknown"
            default: "Counts incomplete"
            }
            #expect(cue.title == expected)
            #expect(cue.count == (scenario == "incomplete" ? 0 : 1))
        }
    }

    @Test(arguments: [false, true])
    func collapsedActivityIncludesInternalWorkButDoesNotReviveStaleChildWork(_ stale: Bool) throws {
        let root = owner(sessionID: fixtures.sessionID)
        var observed = session(fixtures.sessionID, surface: fixtures.surfaceA, state: .idle)
        observed.nodes = [
            .init(id: "running", parentID: nil, depth: 0, kind: .subagent, name: "Internal task",
                  state: .working, model: nil, ancestryUnresolved: false, hasChildren: false,
                  observedParent: .session(.init(providerID: "copilot", sessionID: observed.id.uuidString)))
        ]
        let snapshot = tree([observed], generatedAt: stale ? now.addingTimeInterval(-9) : now)
        let summary = SidebarPresentation.workspaceSummary(
            surfaces: [], sessions: snapshot.sessions, managed: [root], orchestrationAvailability: .ready,
            countsComplete: true, now: now, observations: snapshot, scope: .activity
        )
        let attention = SidebarPresentation.workspaceAttention(
            sessions: snapshot.sessions, managed: [root], availability: .ready, now: now, observations: snapshot
        )
        let cue = try #require(summary.collapsedActivity(attention: attention))
        #expect(cue.visual == SidebarPresentation.state(stale ? .unknown : .working))
        #expect(cue.label == (stale ? "1 unknown, counts incomplete" : "1 working"))
        #expect(SidebarPresentation.activityTreatment(cue.visual, reduceMotion: true)
                == (stale ? .none : .steadyWorking))
    }

    @Test(arguments: [AgentProcessLiveness.dead, .ambiguous, .unknown])
    func collapsedActivityKeepsRetainedTaskFailureAheadOfOtherWorkingSessions(_ liveness: AgentProcessLiveness) throws {
        var ended = session(fixtures.sessionID, surface: fixtures.surfaceA, state: .idle, liveness: liveness)
        ended.nodes = [
            .init(id: "failed", parentID: nil, depth: 0, kind: .subagent, name: "Failed task",
                  state: .failed, model: nil, ancestryUnresolved: false, hasChildren: false,
                  terminalEvent: .init(id: UUID(), timestamp: now),
                  observedParent: .session(.init(providerID: "copilot", sessionID: ended.id.uuidString)))
        ]
        let observed = tree([ended, session(fixtures.otherSessionID, surface: fixtures.surfaceB)])
        let cue = try #require(SidebarPresentation.collapsedActivity(
            sessions: observed.sessions, managed: [], availability: .ready,
            observations: observed, now: now
        ))
        #expect(cue.visual == SidebarPresentation.state(.failed))
        #expect(cue.count == 1)
    }

    @Test(arguments: [SidebarOrchestrationAvailability.stale, .waiting, .ready], [false, true])
    func quietCollapsedScopeIgnoresOtherWorkspacesIncompleteEvidence(
        _ availability: SidebarOrchestrationAvailability, _ hasIdleSession: Bool
    ) {
        let scoped = hasIdleSession ? [session(fixtures.sessionID, surface: fixtures.surfaceA, state: .idle)] : []
        var unrelated = session(fixtures.otherSessionID, surface: fixtures.surfaceB,
                                state: .unknown, workspace: fixtures.workspaceB)
        unrelated.internalTaskCountsIncomplete = true
        let snapshot = tree(scoped + [unrelated])
        #expect(!snapshot.hasCompleteCounts)
        #expect(SidebarPresentation.collapsedActivity(
            sessions: scoped, managed: [], availability: availability,
            observations: snapshot, now: now
        ) == nil)
    }

    @Test func emptyCollapsedScopeDoesNotTurnMissingObservationIntoActivity() {
        let snapshot = SidebarCopilotTree.waiting
        #expect(SidebarPresentation.collapsedActivity(
            sessions: [], managed: [], availability: .waiting,
            observations: snapshot, now: now
        ) == nil)
    }

    @Test(arguments: [SidebarOrchestrationAvailability.loading, .partial, .unavailable])
    func collapsedScopeKeepsFailuresThatMayHideManagedNodes(_ availability: SidebarOrchestrationAvailability) throws {
        let cue = try #require(SidebarPresentation.collapsedActivity(
            sessions: [], managed: [], availability: availability, observations: tree([]), now: now
        ))
        #expect(cue.label == "Counts incomplete")
        #expect(cue.visual.symbol == "circle.dashed")
    }

    @Test(arguments: [SidebarOrchestrationAvailability.stale, .waiting])
    func collapsedScopeKeepsItsOwnUnverifiedManagedNode(_ availability: SidebarOrchestrationAvailability) throws {
        let cue = try #require(SidebarPresentation.collapsedActivity(
            sessions: [], managed: [owner()], availability: availability, observations: tree([]), now: now
        ))
        #expect(cue.label == "1 unknown, counts incomplete")
    }

    @Test(arguments: ["unavailable", "loading", "waiting", "denied", "stale"])
    func managedOnlyActivityQualifiesMissingCopilotEvidence(_ scenario: String) throws {
        var snapshot = tree([])
        switch scenario {
        case "unavailable": snapshot.availability = .unavailable
        case "loading": snapshot.availability = .loading
        case "waiting": snapshot = .waiting
        case "denied": snapshot.issues = [.permissionDenied]
        case "stale": snapshot.generatedAt = now.addingTimeInterval(-9)
        default: preconditionFailure("Unknown missing observation fixture")
        }
        let running = directNode(role: "worker", phase: "turn-running", age: 0, mode: .bounded)
        let activity = try #require(SidebarPresentation.collapsedActivity(
            sessions: [], managed: [running], availability: .ready, observations: snapshot, now: now
        ))
        #expect(activity.label == "1 working, counts incomplete")
        #expect(SidebarPresentation.collapsedActivity(
            sessions: [], managed: [], availability: .ready, observations: snapshot, now: now
        ) == nil)
    }

    @Test(arguments: ["session", "child"])
    func attentionDegradationQualifiesActivityWithoutChangingAgentCounts(_ owner: String) throws {
        var observed = session(fixtures.sessionID, surface: fixtures.surfaceA)
        observed.nodes = [
            .init(id: "legacy-child", parentID: nil, depth: 0, kind: .subagent, name: "Legacy child",
                  state: .working, model: nil, ancestryUnresolved: false, hasChildren: false)
        ]
        if owner == "session" { observed.attentionDegraded = true }
        else { observed.nodes[0].attentionDegraded = true }
        let snapshot = tree([observed])
        let agents = summary(snapshot, managed: [])
        #expect(agents.agentLine == "2 agents · 2 working")
        #expect(!agents.incomplete)
        let activity = try #require(SidebarPresentation.collapsedActivity(
            sessions: snapshot.sessions, managed: [], availability: .ready, observations: snapshot, now: now
        ))
        #expect(activity.label == "2 working, counts incomplete")
    }

    @Test func legacyCoordinatorCountsOneSurfaceWithoutClaimingSessionContents() throws {
        let root = owner()
        let observed = session(fixtures.sessionID, surface: fixtures.surfaceA)
        let tree = tree([observed])
        let summary = summary(tree, managed: [root])
        #expect(summary.agentCount == 1)
        #expect(summary.states.map { "\($0.title):\($0.count)" } == ["Working:1"])
        #expect(summary.agentLine == "1 agent · 1 working")
        let placement = try #require(SidebarPresentation.sessionPlacements(
            tree.sessions, managed: [root], observations: tree, now: now
        ).first)
        #expect(placement.managedNodeID == root.id)
        #expect(placement.contentOwnerID == nil && placement.hasNoSurfaceRow)
    }

    @Test(arguments: [false, true])
    func legacyCoordinatorKeepsItsLiveSessionStateInVisibleWork(_ showEnded: Bool) throws {
        let root = owner()
        var observed = session(fixtures.sessionID, surface: fixtures.surfaceA)
        observed.attention = [.init(kind: .permission, evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: now)]
        let raw = tree([observed])
        let visible = SidebarVisibleWork(tree: raw, managed: [root], history: .init(), showEnded: showEnded, now: now)
        #expect(visible.managed == [root])
        #expect(visible.tree.sessions.map(\.id) == [fixtures.sessionID], "Evidence stays; only its own row is omitted")
        #expect(SidebarPresentation.managedState(root, availability: .ready, now: now, tree: visible.tree)
                == SidebarPresentation.managedState(root, availability: .ready, now: now, tree: raw))
        #expect(SidebarPresentation.managedState(root, availability: .ready, now: now, tree: visible.tree).title == "Working")
        #expect(SidebarPresentation.managedNeedsInput(root, tree: visible.tree, now: now))
        #expect(SidebarPresentation.rowlessSessionIDs(visible.tree, managed: visible.managed, now: now) == [fixtures.sessionID])
    }

    @Test(arguments: [false, true])
    func supplementalHistoryDoesNotInflateExactManagedAndUnmanagedCounts(_ exactOwner: Bool) throws {
        let root = owner(sessionID: exactOwner ? fixtures.sessionID : nil)
        let current = session(fixtures.sessionID, surface: fixtures.surfaceA)
        let historical = session(fixtures.otherSessionID, surface: fixtures.surfaceA, state: .completed, liveness: .dead)
        let independent = session(UUID(), surface: fixtures.surfaceB, state: .idle)
        let terminal = surface(UUID()), browser = surface(UUID(), kind: .browser)
        let surfaces = [surface(fixtures.surfaceA), surface(fixtures.surfaceB), terminal, browser]
        let tree = tree([current, historical, independent])
        let summary = summary(tree, managed: [root], surfaces: surfaces)
        #expect(summary.agentCount == 2)
        #expect(summary.states.map { "\($0.title):\($0.count)" } == ["Working:1", "Idle:1"])
        #expect(summary.tabs.contains(.init(kind: .terminal, count: 1)))
        #expect(summary.tabs.contains(.init(kind: .browser, count: 1)))
        #expect(summary.tabs.reduce(0) { $0 + $1.count } == 2)
        #expect(summary.agentLine.hasPrefix("2 agents"))
        let placements = SidebarPresentation.sessionPlacements(tree.sessions, managed: [root], observations: tree, now: now)
        #expect(placements[0].contentOwnerID == (exactOwner ? root.id : nil))
        #expect(placements[1].session.id == historical.id && placements[1].contentOwnerID == nil)
        #expect(placements[1].hasNoSurfaceRow)
        #expect(placements[2].managedNodeID == nil && placements[2].contentOwnerID == nil)
        #expect(SidebarPresentation.rowlessSessionIDs(tree, managed: [root], now: now).contains(historical.id))
        #expect(tree.dismissibleOutcomes.count == 3, "Counting cannot hide or merge exact task outcomes")
        #expect(SidebarPresentation.unmanagedSurfaces(
            surfaces, workspaceID: fixtures.workspaceA, managed: [root], observations: tree, now: now
        ).map(\.id) == [fixtures.surfaceB, terminal.id, browser.id])
    }

    @Test(arguments: ["duplicate", "ambiguous", "stale-snapshot", "stale-observation"], [false, true])
    func uncertainSameSurfaceObservationsNeverAddManagedAgents(_ variant: String, _ exactOwner: Bool) {
        let root = owner(sessionID: exactOwner ? fixtures.sessionID : nil)
        let tree = variantTree(variant)
        let summary = summary(tree, managed: [root])
        #expect(summary.agentCount == 1 && summary.incomplete)
        #expect(summary.states.reduce(0) { $0 + $1.count } == 1)
        let expected = exactOwner && variant == "ambiguous" ? "Working:1" : "Registered:1"
        #expect(summary.states.map { "\($0.title):\($0.count)" } == [expected])
        let placements = SidebarPresentation.sessionPlacements(tree.sessions, managed: [root], observations: tree, now: now)
        #expect(placements.allSatisfy { $0.managedNodeID == root.id })
        #expect(placements.filter { $0.session.id != fixtures.sessionID }.allSatisfy { $0.contentOwnerID == nil })
    }

    @Test(arguments: ["historical", "duplicate", "ambiguous", "stale-snapshot", "stale-observation"])
    func unmanagedCountsUseOneDestinationAndDoNotChooseAmbiguousActivity(_ variant: String) {
        let tree = variantTree(variant)
        let terminal = surface(UUID()), browser = surface(UUID(), kind: .browser)
        let summary = summary(tree, managed: [], surfaces: [surface(fixtures.surfaceA), terminal, browser])
        #expect(summary.agentCount == 1)
        #expect(summary.states.map { "\($0.title):\($0.count)" } == [variant == "historical" ? "Working:1" : "Unknown:1"])
        if variant != "historical" { #expect(summary.incomplete) }
        #expect(summary.tabs.contains(.init(kind: .terminal, count: 1)))
        #expect(summary.tabs.contains(.init(kind: .browser, count: 1)))
    }

    @Test(arguments: ["coordinator", "worker"], ["launching", "turn-running"])
    func directInteractiveStateUsesFreshExactObservationAfterControllerExpires(_ role: String, _ phase: String) {
        let node = directNode(role: role, phase: phase)
        let projection = SidebarOrchestrationSnapshot(
            version: 1, generatedAt: node.updatedAt, complete: true, omittedCount: 0, nodes: [node]
        )
        #expect(SidebarOrchestrationReader.isStale(projection, now: now))
        for work: AgentWorkState in [.working, .idle, .blocked] {
            let observed = session(fixtures.sessionID, surface: fixtures.surfaceA, state: work)
            let tree = tree([observed])
            for availability: SidebarOrchestrationAvailability in [.ready, .partial, .stale] {
                #expect(SidebarPresentation.managedState(node, availability: availability, now: now, tree: tree)
                        == SidebarPresentation.state(work))
                let summary = summary(tree, managed: [node], availability: availability)
                #expect(summary.agentCount == 1)
                #expect(summary.states.map(\.title) == [SidebarPresentation.state(work).title])
                if availability != .ready { #expect(summary.incomplete) }
            }
        }
        #expect(node.updatedAt == now.addingTimeInterval(-61), "Observation does not refresh controller metadata")
    }

    @Test(arguments: ["coordinator", "worker"], ["launching", "turn-running"])
    func directProviderObservationWithoutWorkNeverMeansWorking(_ role: String, _ phase: String) {
        let node = directNode(role: role, phase: phase, age: 0)
        for tree in [tree([]), tree([session(fixtures.sessionID, surface: fixtures.surfaceA, state: .unknown)])] {
            let row = SidebarPresentation.managedState(node, availability: .ready, now: now, tree: tree)
            #expect(row.tone == .neutral)
            let summary = summary(tree, managed: [node])
            #expect(summary.states.map(\.title) == ["Unknown"])
            #expect(summary.agentCount == 1 && summary.incomplete)
        }
        let noSnapshot = SidebarPresentation.workspaceSummary(
            surfaces: [], sessions: [], managed: [node], orchestrationAvailability: .ready,
            countsComplete: true, now: now
        )
        #expect(noSnapshot.states.map(\.title) == ["Unknown"])
    }

    @Test(arguments: [
        "absent", "stale-snapshot", "missing-date", "future-snapshot", "unavailable", "denied",
        "stale-session", "future-session", "after-snapshot", "unknown", "ambiguous", "dead",
        "foreign-session", "foreign-surface", "foreign-workspace", "missing-managed-session",
        "duplicate", "duplicate-foreign-placement", "duplicate-stale"
    ])
    func directInteractiveStateRejectsUnavailableOrNonuniqueEvidence(_ variant: String) {
        let exact = session(fixtures.sessionID, surface: fixtures.surfaceA)
        var observed = tree([exact])
        switch variant {
        case "absent": observed.sessions = []
        case "stale-snapshot": observed.generatedAt = now.addingTimeInterval(-9)
        case "missing-date": observed.generatedAt = nil
        case "future-snapshot": observed.generatedAt = now.addingTimeInterval(2)
        case "unavailable": observed.availability = .unavailable
        case "denied": observed.issues = [.permissionDenied]
        case "stale-session":
            observed.sessions = [session(fixtures.sessionID, surface: fixtures.surfaceA, observedAt: now.addingTimeInterval(-9))]
        case "future-session":
            observed.sessions = [session(fixtures.sessionID, surface: fixtures.surfaceA, observedAt: now.addingTimeInterval(2))]
        case "after-snapshot": observed.generatedAt = now.addingTimeInterval(-2)
        case "unknown", "ambiguous", "dead":
            let liveness: AgentProcessLiveness = variant == "unknown" ? .unknown : variant == "ambiguous" ? .ambiguous : .dead
            observed.sessions = [session(fixtures.sessionID, surface: fixtures.surfaceA, liveness: liveness)]
        case "foreign-session": observed.sessions = [session(fixtures.otherSessionID, surface: fixtures.surfaceA)]
        case "foreign-surface": observed.sessions = [session(fixtures.sessionID, surface: fixtures.surfaceB)]
        case "foreign-workspace":
            observed.sessions = [session(fixtures.sessionID, surface: fixtures.surfaceA, workspace: fixtures.workspaceB)]
        case "missing-managed-session": break
        case "duplicate": observed.sessions.append(exact)
        case "duplicate-foreign-placement":
            observed.sessions.append(session(fixtures.sessionID, surface: fixtures.surfaceB, workspace: fixtures.workspaceB))
        case "duplicate-stale":
            observed.sessions.append(session(fixtures.sessionID, surface: fixtures.surfaceA, observedAt: now.addingTimeInterval(-9)))
        default: preconditionFailure("Unknown direct observation fixture")
        }
        for role in ["coordinator", "worker"] {
            for phase in ["launching", "turn-running"] {
                let node = directNode(role: role, phase: phase, age: 0, pinnedIdentity: variant != "missing-managed-session")
                #expect(SidebarPresentation.managedState(node, availability: .ready, now: now, tree: observed).tone == .neutral)
                // Inspect only the managed entry; unrelated observed sessions have their own identity and state.
                let summary = SidebarPresentation.workspaceSummary(
                    surfaces: [], sessions: [], managed: [node], orchestrationAvailability: .ready,
                    countsComplete: true, now: now, observations: observed
                )
                #expect(summary.states.map(\.title) == ["Unknown"])
                #expect(summary.agentCount == 1 && summary.incomplete)
            }
        }
    }

    @Test func freshInteractiveActivityDoesNotRefreshGitOrClaimOtherSessionContents() throws {
        let node = directNode(role: "worker", phase: "launching")
        let exact = session(fixtures.sessionID, surface: fixtures.surfaceA, state: .idle)
        let other = session(fixtures.otherSessionID, surface: fixtures.surfaceA, state: .blocked)
        let tree = tree([exact, other])
        let placements = SidebarPresentation.sessionPlacements(tree.sessions, managed: [node], observations: tree, now: now)
        #expect(placements.map(\.managedNodeID) == [node.id, node.id])
        #expect(placements.map(\.contentOwnerID) == [node.id, nil])
        #expect(placements[1].hasNoSurfaceRow)
        #expect(SidebarPresentation.managedState(node, availability: .stale, now: now, tree: tree).title == "Idle")
        let details = SidebarPresentation.managedNodeDetails(node, hierarchy: fixtures.hierarchy(), tree: tree, now: now)
        #expect(!details.contains { $0.title == "Branch" || $0.title == "Worktree" })
        #expect(try #require(details.first { $0.title == "Git evidence" }).value.hasPrefix("Assigned directory: Stale"))
        #expect(node.currentGitChanges(at: now) == nil)
        #expect(node.updatedAt == now.addingTimeInterval(-61))
    }

    @Test func legacyBoundedReportsAndTurnStateDoNotUseInteractiveObservation() {
        let observed = tree([session(fixtures.sessionID, surface: fixtures.surfaceA, state: .working)])
        let completed = directNode(role: "worker", phase: "reported-completed", age: 0, mode: .bounded)
        #expect(SidebarPresentation.managedState(completed, availability: .ready, now: now, tree: observed)
            .title == "Completed · available")
        #expect(summary(observed, managed: [completed]).states.map(\.title) == ["Finished"])
        let stale = directNode(role: "worker", phase: "reported-completed", mode: .bounded)
        #expect(SidebarPresentation.managedState(stale, availability: .stale, now: now, tree: observed).title
            .contains("State unverified"))
        #expect(summary(observed, managed: [stale], availability: .stale).states.map(\.title) == ["Unknown"])
        let running = directNode(role: "worker", phase: "turn-running", age: 0, mode: .bounded)
        #expect(SidebarPresentation.managedState(running, availability: .ready, now: now).title == "Working")
        #expect(summary(tree([]), managed: [running]).states.map(\.title) == ["Working"])
    }

    private func directNode(
        role: String, phase: String, age: TimeInterval = 61, mode: SidebarWorkerMode = .interactive,
        pinnedIdentity: Bool = true
    ) -> SidebarOrchestrationNode {
        let recordedAt = now.addingTimeInterval(-age)
        return .init(
            id: UUID(), runId: UUID(), parentId: role == "worker" ? UUID() : nil, role: role, label: "Managed",
            workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA, generation: 1,
            phase: phase, availability: phase == "reported-completed" ? "idle" : "busy",
            copilotSessionId: pinnedIdentity ? fixtures.sessionID : nil, executionMode: mode,
            worktreeLabel: "observed-worktree", branchLabel: "observed-branch",
            gitEvidenceStatus: "verified", gitEvidenceAt: recordedAt,
            gitChangesStatus: "verified",
            gitChanges: .init(files: 1, insertions: 2, deletions: 0, untrackedFiles: 0, binaryFiles: 0),
            gitChangesAt: recordedAt, createdAt: recordedAt, updatedAt: recordedAt
        )
    }

    private func variantTree(_ variant: String) -> SidebarCopilotTree {
        let current = session(fixtures.sessionID, surface: fixtures.surfaceA)
        switch variant {
        case "historical":
            return tree([session(fixtures.otherSessionID, surface: fixtures.surfaceA, state: .completed, liveness: .dead), current])
        case "duplicate": return tree([current, current])
        case "ambiguous": return tree([current, session(fixtures.otherSessionID, surface: fixtures.surfaceA)])
        case "stale-snapshot": return tree([current], generatedAt: now.addingTimeInterval(-9))
        case "stale-observation": return tree([session(fixtures.sessionID, surface: fixtures.surfaceA, observedAt: now.addingTimeInterval(-9))])
        default: preconditionFailure("Unknown count fixture")
        }
    }

    private func summary(
        _ tree: SidebarCopilotTree, managed: [SidebarOrchestrationNode], surfaces: [HierarchySurface] = [],
        availability: SidebarOrchestrationAvailability = .ready
    ) -> SidebarWorkspaceSummary {
        SidebarPresentation.workspaceSummary(
            surfaces: surfaces, sessions: tree.sessions, managed: managed,
            orchestrationAvailability: availability, countsComplete: true, now: now, observations: tree
        )
    }

    private func tree(_ sessions: [SidebarCopilotSession], generatedAt: Date? = nil) -> SidebarCopilotTree {
        .init(availability: .ready, sessions: sessions, issues: [], generatedAt: generatedAt ?? now)
    }

    private func owner(sessionID: UUID? = nil) -> SidebarOrchestrationNode {
        .init(id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Same title",
              workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA, generation: sessionID == nil ? 0 : 1,
              phase: "registered", availability: "active", copilotSessionId: sessionID,
              executionMode: sessionID == nil ? nil : .interactive, createdAt: now, updatedAt: now)
    }

    private func session(
        _ id: UUID, surface: UUID, state: AgentWorkState = .working,
        liveness: AgentProcessLiveness = .alive, observedAt: Date? = nil, workspace: UUID? = nil
    ) -> SidebarCopilotSession {
        .init(
            id: id, workspaceID: workspace ?? fixtures.workspaceA, surfaceID: surface, liveness: liveness,
            state: state, model: nil, observedAt: observedAt ?? now,
            nodes: [.init(id: "task", parentID: nil, depth: 0, kind: .subagent, name: "Same task name",
                          state: .completed, model: nil, ancestryUnresolved: false, hasChildren: false,
                          terminalEvent: .init(id: id, timestamp: now),
                          observedParent: .session(.init(providerID: "copilot", sessionID: id.uuidString)))],
            childrenComplete: true, treeDegraded: false, omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
    }

    private func surface(_ id: UUID, kind: HierarchySurfaceKind = .terminal) -> HierarchySurface {
        .init(id: id, title: "Same title", kind: kind, isFocused: false, isPinned: false,
              unreadCount: 0, workingDirectory: .unavailable)
    }
}
