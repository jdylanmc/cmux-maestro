import Foundation
import Testing

@MainActor
struct SidebarCopilotTreeTests {
    private let fixtures = SidebarTreeFixtures()

    @Test
    func exactSurfacePlacementIgnoresNamesPathsAndLaunchWorkspace() {
        let now = Date()
        let snapshot = fixtures.snapshot(sessions: [
            fixtures.session(id: fixtures.sessionID, surface: fixtures.surfaceA, now: now),
            fixtures.session(id: fixtures.otherSessionID, surface: fixtures.surfaceA, now: now),
        ], now: now)
        let tree = SidebarCopilotTree.project(snapshot, onto: fixtures.topology(moved: true), now: now)

        #expect(tree.sessions.map(\.id) == [fixtures.sessionID, fixtures.otherSessionID])
        #expect(tree.sessions.allSatisfy { $0.workspaceID == fixtures.workspaceB })
        #expect(tree.sessions.allSatisfy { $0.surfaceID == fixtures.surfaceA })
        #expect(Set(tree.sessions.map(\.shortID)).count == 2)
    }

    @Test
    func rejectsConflictingSessionIDsAndOffWindowRowsButKeepsValidPositives() {
        let now = Date()
        let duplicate = fixtures.session(id: fixtures.sessionID, now: now)
        let valid = fixtures.session(id: fixtures.otherSessionID, now: now)
        let offWindow = fixtures.session(id: UUID(), surface: UUID(), now: now)
        let tree = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [duplicate, duplicate, valid, offWindow], now: now),
            onto: fixtures.topology(), now: now
        )
        #expect(tree.availability == .partial)
        #expect(tree.sessions.map(\.id) == [fixtures.otherSessionID])
        #expect(!tree.hasCompleteCounts)
    }

    @Test
    func topologyRequiresCurrentWindowAndGrantedSurfaceMetadata() {
        var hierarchy = fixtures.hierarchy()
        hierarchy.windowID = nil
        #expect(!SidebarTopology(hierarchy).canReadSessions)
        #expect(SidebarTopology(hierarchy).workspaceBySurface.isEmpty)
        let revoked = fixtures.topology(granted: false)
        #expect(!revoked.canReadSessions)
        #expect(revoked.workspaceBySurface.isEmpty)

        let duplicate = fixtures.hierarchy(duplicateSurface: true)
        #expect(SidebarTopology(duplicate).workspaceBySurface[fixtures.surfaceA] == nil)
    }

    @Test
    func loadingMissingRecordsAndEmptyHistoryAreNotEquivalent() {
        let now = Date()
        let empty = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [], now: now), onto: fixtures.topology(), now: now
        )
        let loading = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [], issues: [.loadingHistory], complete: false, now: now),
            onto: fixtures.topology(), now: now
        )
        let missing = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [], issues: [.noIdentityRecords], now: now),
            onto: fixtures.topology(), now: now
        )
        let notInstalled = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [], issues: [.integrationNotInstalled], complete: false, now: now),
            onto: fixtures.topology(), now: now
        )
        #expect(empty.hasCompleteCounts)
        #expect(!loading.hasCompleteCounts)
        #expect(loading.summary.contains("Loading"))
        #expect(missing.summary.contains("No bound"))
        #expect(notInstalled.summary.contains("Enable Copilot integration in CMUX Maestro"))
        #expect(notInstalled.summary.contains("Restart"))
    }

    @Test
    func partialKnownChildrenRemainVisibleWithoutInventingZeroOrModels() {
        let now = Date()
        let observation = fixtures.session(
            state: .unknown, children: [fixtures.child("working", state: .working)], now: now
        )
        let tree = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [observation], issues: [.loadingHistory], complete: false, now: now),
            onto: fixtures.topology(), now: now
        )
        #expect(tree.sessions.first?.nodes.count == 1)
        #expect(tree.knownRunningChildren == 1)
        #expect(!tree.hasCompleteCounts)
        #expect(tree.sessions.first?.model == nil)
    }

    @Test
    func completeEmptyUnknownRootProvesZeroButUnknownChildLifetimeDoesNot() {
        let now = Date()
        let empty = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [fixtures.session(state: .unknown, now: now)], now: now),
            onto: fixtures.topology(), now: now
        )
        #expect(empty.sessions.first?.childrenComplete == true)
        #expect(empty.hasCompleteCounts)
        #expect(empty.knownRunningChildren == 0)
        #expect(empty.sessions.first?.state == .unknown)

        let unknownLifetime = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [fixtures.session(
                state: .unknown, children: [fixtures.child("invocation", state: .unknown)], now: now
            )], now: now),
            onto: fixtures.topology(), now: now
        )
        #expect(unknownLifetime.sessions.first?.childrenComplete == true)
        #expect(!unknownLifetime.hasCompleteCounts)
        #expect(unknownLifetime.knownRunningChildren == 0)
    }

    @Test
    func freshnessAndLivenessAreIndependentFromReportedTaskState() {
        let now = Date()
        let current = fixtures.session(state: .idle, children: [fixtures.child("run", state: .working)], now: now)
        let tree = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [current], now: now), onto: fixtures.topology(), now: now
        )
        #expect(tree.sessions.first?.state == .idle)
        #expect(tree.sessions.first?.knownRunningChildren == 1)

        let dead = fixtures.session(liveness: .dead, state: .working, children: [
            fixtures.child("run", state: .working), fixtures.child("failure", state: .failed),
            fixtures.child("cancel", state: .cancelled),
        ], now: now)
        let deadTree = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [dead], now: now), onto: fixtures.topology(), now: now
        )
        #expect(deadTree.sessions.first?.liveness == .dead)
        #expect(deadTree.sessions.first?.state == .unknown)
        #expect(deadTree.sessions.first?.nodes.map(\.state) == [.unknown, .failed, .cancelled])
        #expect(deadTree.knownRunningChildren == 0)
        #expect(!deadTree.hasCompleteCounts)

        let stale = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [current], now: now.addingTimeInterval(-20)),
            onto: fixtures.topology(), now: now
        )
        #expect(stale.availability == .unavailable)
        #expect(stale.sessions.isEmpty)
        let future = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [current], now: now.addingTimeInterval(20)),
            onto: fixtures.topology(), now: now
        )
        #expect(future.sessions.isEmpty)
    }

    @Test
    func nestedStableIDsKeepSameNamedSiblingsAndHandleCyclesOrphansAndDepth() throws {
        let now = Date()
        var children = [
            fixtures.child("root"), fixtures.child("one", parent: "root"),
            fixtures.child("two", parent: "root"), fixtures.child("grandchild", parent: "one"),
            fixtures.child("orphan", parent: "missing"), fixtures.child("cycle-a", parent: "cycle-b"),
            fixtures.child("cycle-b", parent: "cycle-a"), fixtures.child("self", parent: "self"),
            fixtures.child("duplicate"), fixtures.child("duplicate"),
        ]
        for index in 0..<35 {
            children.append(fixtures.child("deep-\(index)", parent: index == 0 ? nil : "deep-\(index - 1)"))
        }
        let tree = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [fixtures.session(children: children, now: now)], now: now),
            onto: fixtures.topology(), now: now
        )
        let session = try #require(tree.sessions.first)
        #expect(session.nodes.prefix(4).map(\.id) == ["root", "one", "grandchild", "two"])
        #expect(session.nodes.prefix(4).map(\.depth) == [0, 1, 2, 1])
        #expect(session.nodes.filter { $0.name == "Same name" }.count == session.nodes.count)
        #expect(!session.nodes.contains { $0.id == "duplicate" })
        #expect(Set(session.nodes.map(\.id)).count == session.nodes.count)
        #expect(session.nodes.allSatisfy { $0.depth <= SidebarCopilotTree.maximumDepth })
        #expect(session.nodes.first { $0.id == "root" }?.ancestryUnresolved == false)
        #expect(session.nodes.first { $0.id == "orphan" }?.ancestryUnresolved == true)
        #expect(session.nodes.first { $0.id == "cycle-a" }?.ancestryUnresolved == true)
        #expect(session.treeDegraded)
        #expect(session.visibleNodes(collapsed: ["one"]).prefix(3).map(\.id) == ["root", "one", "two"])
    }

    @Test
    func childProjectionIsBounded() {
        let now = Date()
        let children = (0..<1000).map { fixtures.child("child-\($0)") }
        let tree = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [fixtures.session(children: children, now: now)], now: now),
            onto: fixtures.topology(), now: now
        )
        #expect(tree.sessions.first?.nodes.count == SidebarCopilotTree.maximumNodes)
        #expect(tree.sessions.first?.treeDegraded == true)
        #expect(tree.omittedChildrenCount == 1000 - SidebarCopilotTree.maximumNodes)
    }

    @Test
    func activeAndBlockedWorkKeepRequiredAncestryAheadOfHistoricalFill() throws {
        let now = Date()
        let history = (0..<SidebarCopilotTree.maximumNodes).map {
            fixtures.child("history-\($0)", state: .completed)
        }
        let children = history + [
            fixtures.child("working", parent: "ancestor", state: .working),
            fixtures.child("blocked", parent: "ancestor", state: .blocked),
            fixtures.child("ancestor", parent: "root", state: .completed),
            fixtures.child("root", state: .completed),
        ]
        let tree = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [fixtures.session(children: children, now: now)], now: now),
            onto: fixtures.topology(), now: now
        )
        let session = try #require(tree.sessions.first)
        #expect(session.nodes.prefix(4).map(\.id) == ["root", "ancestor", "working", "blocked"])
        #expect(session.nodes.prefix(4).map(\.depth) == [0, 1, 2, 2])
        #expect(session.nodes.prefix(4).allSatisfy { !$0.ancestryUnresolved })
        #expect(session.nodes.count == SidebarCopilotTree.maximumNodes)
        #expect(session.nodes.filter { $0.state == .working }.map(\.id) == ["working"])
        #expect(session.nodes.filter { $0.state == .blocked }.map(\.id) == ["blocked"])
        #expect(session.omittedChildrenCount == 4)
        #expect(session.omittedActiveChildrenCount == 0)
        #expect(tree.knownRunningChildren == 1)
        #expect(!tree.hasCompleteCounts)
        #expect(tree.availability == .partial)
    }

    @Test
    func activeOverflowIsExplicitAndDoesNotGiveCapacityToHistory() throws {
        let now = Date()
        let history = (0..<100).map { fixtures.child("history-\($0)", state: .completed) }
        let active = (0...SidebarCopilotTree.maximumNodes).map {
            fixtures.child("active-\($0)", state: $0.isMultiple(of: 2) ? .working : .blocked)
        }
        let tree = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [fixtures.session(children: history + active, now: now)], now: now),
            onto: fixtures.topology(), now: now
        )
        let session = try #require(tree.sessions.first)
        #expect(session.nodes.count == SidebarCopilotTree.maximumNodes)
        #expect(session.nodes.allSatisfy { $0.state == .working || $0.state == .blocked })
        #expect(session.omittedChildrenCount == 101)
        #expect(session.omittedActiveChildrenCount == 1)
        #expect(tree.omittedActiveChildrenCount == 1)
        #expect(!session.childrenComplete)
    }

    @Test
    func pollingReplacesFullHistoryWithNewlyObservedActiveWork() async {
        let harness = SidebarReadHarness()
        let history = (0..<SidebarCopilotTree.maximumNodes).map {
            fixtures.child("history-\($0)", state: .completed)
        }
        let poller = SidebarCopilotPolling(
            read: { try await harness.read($0) },
            pause: { try await Task.sleep(for: .milliseconds(5)) }
        )
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        await sidebarEventually { await harness.callCount == 1 }
        await harness.succeed(0, with: fixtures.snapshot(sessions: [fixtures.session(children: history)]))
        await sidebarEventually { await harness.callCount == 2 }
        #expect(poller.tree.knownRunningChildren == 0)
        let children = history + [
            fixtures.child("new-working", parent: "parent", state: .working),
            fixtures.child("new-blocked", parent: "parent", state: .blocked),
            fixtures.child("parent", state: .completed),
        ]
        await harness.succeed(1, with: fixtures.snapshot(sessions: [fixtures.session(children: children)]))
        await sidebarEventually { poller.tree.knownRunningChildren == 1 }
        #expect(poller.tree.sessions.first?.nodes.contains { $0.id == "new-blocked" } == true)
        #expect(poller.tree.sessions.first?.nodes.first?.id == "parent")
        #expect(poller.tree.omittedChildrenCount == 3)
        poller.setVisible(false)
        await harness.finishPending()
    }

    @Test
    func duplicateBeyondDisplayLimitIsStillRejected() {
        let now = Date()
        let children = [fixtures.child("duplicate")]
            + (0..<SidebarCopilotTree.maximumNodes).map { fixtures.child("child-\($0)") }
            + [fixtures.child("duplicate")]
        let tree = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [fixtures.session(children: children, now: now)], now: now),
            onto: fixtures.topology(), now: now
        )
        #expect(tree.sessions.first?.nodes.contains { $0.id == "duplicate" } == false)
        #expect(tree.availability == .partial)
    }

    @Test
    func pollingUsesOnlyGrantedVisibleSurfacesAndClearsOnRevocation() async {
        let harness = SidebarReadHarness()
        let poller = SidebarCopilotPolling(read: { try await harness.read($0) })
        poller.update(topology: fixtures.topology(), connected: true)
        await Task.yield()
        #expect(await harness.callCount == 0)
        poller.setVisible(true)
        await sidebarEventually { await harness.callCount == 1 }
        #expect(await harness.request(0) == Set([fixtures.surfaceA, fixtures.surfaceB]))
        await harness.succeed(0, with: fixtures.snapshot(sessions: [fixtures.session()]))
        await sidebarEventually { poller.tree.sessions.count == 1 }
        poller.update(topology: fixtures.topology(granted: false), connected: true)
        #expect(poller.tree.sessions.isEmpty)
        #expect(poller.tree.availability == .waiting)
        await sidebarEventually { !poller.isReading }
        #expect(await harness.callCount == 1)
        poller.setVisible(false)
    }

    @Test
    func lateTopologyReadSettlesBeforeNextReadAndCannotReattachOldPlacement() async {
        let harness = SidebarReadHarness()
        let poller = SidebarCopilotPolling(read: { try await harness.read($0) })
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        await sidebarEventually { await harness.callCount == 1 }
        poller.update(topology: fixtures.topology(moved: true), connected: true)
        #expect(poller.tree.sessions.isEmpty)
        #expect(await harness.callCount == 1)
        await harness.succeed(0, with: fixtures.snapshot(sessions: [fixtures.session()]))
        await sidebarEventually { await harness.callCount == 2 }
        #expect(poller.tree.sessions.isEmpty)
        await harness.succeed(1, with: fixtures.snapshot(sessions: [fixtures.session()]))
        await sidebarEventually { poller.tree.sessions.first?.workspaceID == fixtures.workspaceB }
        #expect(await harness.maximumActive == 1)
        poller.setVisible(false)
    }

    @Test
    func hideShowDropsLateResultAndCooperativeCancellationAllowsNewTopology() async {
        let harness = SidebarReadHarness()
        let poller = SidebarCopilotPolling(read: { try await harness.read($0) })
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        await sidebarEventually { await harness.callCount == 1 }
        poller.setVisible(false)
        poller.setVisible(true)
        await harness.succeed(0, with: fixtures.snapshot(sessions: [fixtures.session()]))
        await sidebarEventually { await harness.callCount == 2 }
        #expect(poller.tree.sessions.isEmpty)
        await harness.succeed(1, with: fixtures.snapshot(sessions: [fixtures.session()]))
        await sidebarEventually { poller.tree.sessions.count == 1 }
        poller.setVisible(false)
        #expect(poller.tree.availability == .hidden)
        await sidebarEventually { !poller.isReading }

        let cooperative = SidebarCancellationHarness()
        let next = SidebarCopilotPolling(read: { try await cooperative.read($0) })
        next.update(topology: fixtures.topology(), connected: true)
        next.setVisible(true)
        await sidebarEventually { await cooperative.calls == 1 }
        next.update(topology: fixtures.topology(moved: true), connected: true)
        await sidebarEventually { await cooperative.calls == 2 }
        #expect(await cooperative.cancelled == 1)
        next.setVisible(false)
        await sidebarEventually { !next.isReading }
        #expect(await cooperative.cancelled == 2)
    }

    @Test
    func actualPollingRejectsRegressingGenerationAndClearsFailedLiveState() async {
        let harness = SidebarReadHarness()
        let now = Date()
        let poller = SidebarCopilotPolling(
            read: { try await harness.read($0) },
            pause: { try await Task.sleep(for: .milliseconds(5)) },
            now: { now }
        )
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        await sidebarEventually { await harness.callCount == 1 }
        await harness.succeed(0, with: fixtures.snapshot(sessions: [fixtures.session(now: now)], now: now))
        await sidebarEventually { await harness.callCount == 2 }
        await harness.succeed(1, with: fixtures.snapshot(
            sessions: [], now: now.addingTimeInterval(-1)
        ))
        await sidebarEventually { await harness.callCount == 3 }
        #expect(poller.tree.sessions.count == 1)
        await harness.fail(2)
        await sidebarEventually { poller.tree.availability == .unavailable }
        #expect(poller.tree.sessions.isEmpty)
        poller.setVisible(false)
        await harness.finishPending()
    }

    @Test
    func freshnessDeadlineExpiresOldestVisibleObservationEvenDuringAnotherRead() async {
        let harness = SidebarReadHarness()
        let expiry = SidebarExpiryHarness()
        let now = Date()
        let poller = SidebarCopilotPolling(
            read: { try await harness.read($0) },
            pause: { try await Task.sleep(for: .milliseconds(5)) },
            expiryPause: { try await expiry.wait($0) },
            now: { now }
        )
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        await sidebarEventually { await harness.callCount == 1 }
        await harness.succeed(0, with: fixtures.snapshot(
            sessions: [fixtures.session(state: .working, now: now.addingTimeInterval(-7))], now: now
        ))
        await sidebarEventually { await expiry.delay != nil }
        #expect(await expiry.delay == 1)
        await sidebarEventually { await harness.callCount == 2 }
        await expiry.expire()
        await sidebarEventually { poller.tree.availability == .unavailable }
        #expect(poller.tree.sessions.isEmpty)
        poller.setVisible(false)
        await harness.finishPending()
    }

    @Test
    func unreadHistoryContinuesSeriallyWithoutNormalPollingDelay() async {
        let harness = SidebarReadHarness()
        let cadence = SidebarCadenceHarness()
        let now = Date(timeIntervalSince1970: 2_000)
        let poller = SidebarCopilotPolling(
            read: { try await harness.read($0) },
            hasPendingHistory: { await harness.hasPendingHistory },
            pause: { try await cadence.idle() },
            catchUpPause: { try await cadence.catchUp() },
            expiryPause: { _ in
                // Cadence owns a frozen clock; unrelated test scheduling cannot expire its snapshots.
                let (ticks, continuation) = AsyncStream<Void>.makeStream()
                defer { continuation.finish() }
                for await _ in ticks {}
                try Task.checkCancellation()
            },
            now: { now }
        )
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        for index in 0..<3 {
            await sidebarEventually { await harness.callCount == index + 1 }
            await harness.succeed(index, with: fixtures.snapshot(
                sessions: [], issues: [.loadingHistory, .readLimitReached], complete: false, now: now
            ), pendingHistory: true)
        }
        await sidebarEventually { await harness.callCount == 4 }
        #expect(await cadence.idleCalls == 0)
        #expect(await cadence.catchUpCalls == 3)
        #expect(await harness.maximumActive == 1)
        #expect(!poller.tree.hasCompleteCounts)
        #expect(poller.tree.summary.contains("Loading"))
        await harness.succeed(3, with: fixtures.snapshot(sessions: [
            fixtures.session(children: [fixtures.child("tail-child", state: .working)], now: now),
        ], now: now))
        await sidebarEventually { await cadence.idleCalls == 1 }
        #expect(poller.tree.availability == .ready)
        #expect(poller.tree.knownRunningChildren == 1)
        #expect(await harness.callCount == 4)
        poller.setVisible(false)
    }

    @Test
    func tornEOFAndReadLimitsWithoutUnreadHistoryUseNormalDelay() async {
        let harness = SidebarReadHarness()
        let cadence = SidebarCadenceHarness()
        let poller = SidebarCopilotPolling(
            read: { try await harness.read($0) },
            hasPendingHistory: { await harness.hasPendingHistory },
            pause: { try await cadence.idle() },
            catchUpPause: { try await cadence.catchUp() }
        )
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        await sidebarEventually { await harness.callCount == 1 }
        await harness.succeed(0, with: fixtures.snapshot(
            sessions: [], issues: [.loadingHistory, .readLimitReached], complete: false
        ))
        await sidebarEventually { await cadence.idleCalls == 1 }
        #expect(await cadence.catchUpCalls == 0)
        #expect(await harness.callCount == 1)
        #expect(!poller.tree.hasCompleteCounts)
        poller.setVisible(false)
    }

    @Test
    func staleHistoryCannotTriggerCatchUpAndHideCancelsCatchUpPause() async {
        let harness = SidebarReadHarness()
        let cadence = SidebarCadenceHarness()
        let now = Date()
        let poller = SidebarCopilotPolling(
            read: { try await harness.read($0) },
            hasPendingHistory: { await harness.hasPendingHistory },
            pause: { try await cadence.idle() },
            catchUpPause: { try await cadence.catchUp() },
            now: { now }
        )
        poller.update(topology: fixtures.topology(), connected: true)
        poller.setVisible(true)
        await sidebarEventually { await harness.callCount == 1 }
        await harness.succeed(0, with: fixtures.snapshot(
            sessions: [], issues: [.loadingHistory], complete: false, now: now.addingTimeInterval(-20)
        ), pendingHistory: true)
        await sidebarEventually { await cadence.idleCalls == 1 }
        #expect(await cadence.catchUpCalls == 0)
        poller.setVisible(false)
        poller.setVisible(true)
        await sidebarEventually { await harness.callCount == 2 }
        await harness.succeed(1, with: fixtures.snapshot(
            sessions: [], issues: [.loadingHistory], complete: false, now: now
        ), pendingHistory: true)
        await sidebarEventually { await cadence.catchUpCalls == 1 }
        poller.setVisible(false)
        await harness.finishPending()
        let readsWhenHidden = await harness.callCount
        try? await Task.sleep(for: .milliseconds(10))
        #expect(await harness.callCount == readsWhenHidden)
        #expect(poller.tree.availability == .hidden)
    }

    @Test
    func sidebarTestSourcesHaveExplicitTargetMembership() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(
            contentsOf: root.appendingPathComponent("CMUXMaestroPreview.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let plist = try #require(
            PropertyListSerialization.propertyList(from: Data(project.utf8), format: nil) as? [String: Any]
        )
        let objects = try #require(plist["objects"] as? [String: [String: Any]])
        let target = try #require(objects.values.first {
            $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == "CMUXMaestroPreviewTests"
        })
        let phases = try #require(target["buildPhases"] as? [String])
        let sources = phases.compactMap { objects[$0] }.filter { $0["isa"] as? String == "PBXSourcesBuildPhase" }
        let buildFiles = sources.flatMap { $0["files"] as? [String] ?? [] }
        let sourcePaths = buildFiles.compactMap { objects[$0]?["fileRef"] as? String }
            .compactMap { objects[$0]?["path"] as? String }
        for path in [
            "CMUXMaestroSidebar/Copilot/SidebarCopilotTree.swift",
            "CMUXMaestroSidebar/Copilot/SidebarCopilotPolling.swift",
            "CMUXMaestroSidebar/Navigation/SidebarNavigation.swift",
        ] {
            #expect(sourcePaths.contains(path))
        }
        let view = try String(
            contentsOf: root.appendingPathComponent("CMUXMaestroSidebar/UI/SidebarView.swift"), encoding: .utf8
        )
        #expect(view.contains("CopilotSessionRow"))
        #expect(view.contains("FocusButton"))
        #expect(!view.contains("Provider data is not enabled"))
        #expect(!view.contains("future update"))
    }
}

@MainActor
struct SidebarTreeFixtures {
    let windowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let workspaceA = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    let workspaceB = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    let surfaceA = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
    let surfaceB = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let sessionID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let otherSessionID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

    func hierarchy(moved: Bool = false, granted: Bool = true, duplicateSurface: Bool = false) -> HierarchySnapshot {
        func surface(_ id: UUID) -> HierarchySurface {
            HierarchySurface(
                id: id, title: "Same title", kind: .terminal, isFocused: false,
                isPinned: false, unreadCount: 0, workingDirectory: .available("/same/directory")
            )
        }
        func workspace(_ id: UUID, _ surfaces: [UUID]) -> HierarchyWorkspace {
            HierarchyWorkspace(
                id: id, title: .available("Same name"), detail: .available(nil),
                isSelected: .available(false), isPinned: .available(false),
                unreadCount: .available(0), rootPath: .available("/same/directory"),
                projectRootPath: .available("/same/directory"),
                surfaces: granted ? .available(surfaces.map(surface)) : .unavailable
            )
        }
        return HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: granted, surfaceMetadataAvailable: granted,
            workspacePathsAvailable: true,
            workspaces: [
                workspace(workspaceA, moved ? [] : [surfaceA]),
                workspace(workspaceB, moved || duplicateSurface ? [surfaceA, surfaceB] : [surfaceB]),
            ], windowID: windowID
        )
    }

    func topology(moved: Bool = false, granted: Bool = true) -> SidebarTopology {
        SidebarTopology(hierarchy(moved: moved, granted: granted))
    }

    func session(
        id: UUID? = nil, surface: UUID? = nil, liveness: CopilotLiveness = .alive,
        state: CopilotWorkState = .idle, children: [CopilotChildWork] = [], now: Date = Date()
    ) -> CopilotSessionObservation {
        CopilotSessionObservation(
            sessionID: id ?? sessionID, surfaceID: surface ?? surfaceA,
            launchWorkspaceID: workspaceA, liveness: liveness, state: state,
            model: nil, children: children, observedAt: now
        )
    }

    func child(_ id: String, parent: String? = nil, state: CopilotWorkState = .idle) -> CopilotChildWork {
        CopilotChildWork(id: id, parentID: parent, kind: .subagent, name: "Same name", state: state, model: nil)
    }

    func snapshot(
        sessions: [CopilotSessionObservation], issues: [CopilotIssue] = [],
        complete: Bool = true, now: Date = Date()
    ) -> CopilotSnapshot {
        CopilotSnapshot(generatedAt: now, sessions: sessions, issues: issues, isComplete: complete)
    }
}

private actor SidebarReadHarness {
    private var requests: [Set<UUID>] = []
    private var pending: [Int: CheckedContinuation<CopilotSnapshot, Error>] = [:]
    private(set) var maximumActive = 0
    private(set) var hasPendingHistory = false
    var callCount: Int { requests.count }

    func read(_ ids: Set<UUID>) async throws -> CopilotSnapshot {
        let index = requests.count
        requests.append(ids)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            maximumActive = max(maximumActive, pending.count)
        }
    }

    func request(_ index: Int) -> Set<UUID> { requests[index] }
    func succeed(_ index: Int, with snapshot: CopilotSnapshot, pendingHistory: Bool = false) {
        hasPendingHistory = pendingHistory
        pending.removeValue(forKey: index)?.resume(returning: snapshot)
    }
    func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoPermission)) }
    func finishPending() {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

private actor SidebarCancellationHarness {
    private(set) var calls = 0
    private(set) var cancelled = 0
    func read(_ ids: Set<UUID>) async throws -> CopilotSnapshot {
        calls += 1
        do { try await Task.sleep(for: .seconds(60)) } catch {
            cancelled += 1
            throw error
        }

        throw CancellationError()
    }
}

private actor SidebarExpiryHarness {
    private(set) var delay: TimeInterval?
    private var continuation: CheckedContinuation<Void, Error>?
    func wait(_ delay: TimeInterval) async throws {
        self.delay = delay
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func expire() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
func sidebarEventually(
    _ condition: @MainActor () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<300 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition did not settle", sourceLocation: sourceLocation)
}

private actor SidebarCadenceHarness {
    private(set) var idleCalls = 0
    private(set) var catchUpCalls = 0
    func idle() async throws {
        idleCalls += 1
        try await Task.sleep(for: .seconds(60))
    }
    func catchUp() async throws {
        catchUpCalls += 1
        try await Task.sleep(for: .milliseconds(1))
    }
}
