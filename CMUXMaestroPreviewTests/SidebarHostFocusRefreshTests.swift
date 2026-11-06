import AppKit
@_spi(CmuxHostTransport) @_spi(CmuxExtensionTransport) import CmuxExtensionKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import CMUXMaestroPreview

/// CMUX pushes no snapshot when only tab, pane or workspace focus changes, so each window pulls its
/// own snapshot on a bounded cadence while it can matter (ADR 0032). Ticks are explicit barriers.
@MainActor
@Suite
struct SidebarHostFocusRefreshTests {
    /// The reported case: a custom-titled workspace, a human tab click, and no other host change.
    @Test func tabFocusInACustomTitledWorkspaceReachesTheSidebarWithinOneTickOverXPC() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let ticks = ManualTicks()
        let binding = SidebarWindowBinding(
            preferences: fixture.preferences(),
            focusRefresh: SidebarHostFocusRefresh(pause: ticks.pause, hostActivity: nil)
        )
        let scene = CmuxSidebarScene(manifest: CmuxExtensionManifest(
            id: "com.example.focusrefresh", displayName: "Focus refresh test",
            readScopes: [.workspaceMetadata, .surfaceMetadata], actionScopes: []
        ))
        binding.bind(to: scene)
        scene.viewDidAppear(UUID())
        let world = FocusWorld()
        let host = try PullOnlyCmuxWindow(scene: scene, snapshot: world.snapshot())
        defer { host.close() }
        host.push()
        await sidebarEventually { Self.focused(binding) == world.focus }

        binding.setVisible(true)
        binding.focusRefresh.setActive(true)
        await sidebarEventually {
            host.requests == 1 && ticks.pauses == 1 && !binding.focusRefresh.isAwaitingReply
        }

        world.focus = world.secondTab
        host.replace(world.snapshot())
        #expect(Self.focused(binding) == world.firstTab, "Nothing was pushed; the sidebar still shows the old tab")
        ticks.advance()
        await sidebarEventually { Self.focused(binding) == world.secondTab }
        #expect(host.requests == 2 && host.pushes == 1, "One pull, no host push, moved the focus bar")
        let footer = SidebarPresentation.pinnedDetails(
            hierarchy: binding.model.hierarchy, connected: true, tree: binding.model.copilot.presentationTree,
            managed: binding.model.orchestration.snapshot, availability: binding.model.orchestration.availability,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(footer.title == "Second tab", "The Active window footer follows the same focused surface")
    }

    /// Workspace switches, split-pane focus and non-agent surfaces travel the same pull.
    @Test(arguments: FocusMove.allCases)
    func everyHostFocusMoveIsPickedUpOnTheNextTick(_ move: FocusMove) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let ticks = ManualTicks()
        let world = FocusWorld()
        let host = ClosureHost()
        let binding = SidebarWindowBinding(
            preferences: fixture.preferences(),
            focusRefresh: SidebarHostFocusRefresh(pause: ticks.pause, hostActivity: nil)
        )
        host.reply = { [weak binding] in binding?.apply(host.bound(world.snapshot())) }
        binding.apply(host.bound(world.snapshot()))
        binding.setVisible(true)
        binding.focusRefresh.setActive(true)
        await sidebarEventually {
            host.requests == 1 && ticks.pauses == 1 && !binding.focusRefresh.isAwaitingReply
        }

        let expected: SidebarSeenTarget
        switch move {
        case .tab:
            world.focus = world.secondTab
            expected = .surface(workspaceID: world.workspace, surfaceID: world.secondTab)
        case .splitPane:
            world.focus = world.otherPane
            expected = .surface(workspaceID: world.workspace, surfaceID: world.otherPane)
        case .browser:
            world.focus = world.browser
            expected = .surface(workspaceID: world.workspace, surfaceID: world.browser)
        case .workspace:
            world.selected = world.otherWorkspace
            expected = .surface(workspaceID: world.otherWorkspace, surfaceID: world.otherWorkspaceTab)
        }
        ticks.advance()
        await sidebarEventually { SidebarPresentation.focusedSurface(in: binding.model.hierarchy) == expected }
        #expect(host.requests == 2)
        #expect(SidebarPresentation.focusedSurface(in: binding.model.hierarchy)
                != .surface(workspaceID: world.workspace, surfaceID: world.firstTab),
                "The previous agent row loses its focus bar")
    }

    @Test func nothingIsRequestedWhileHiddenInactiveOrDisconnected() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let ticks = ManualTicks()
        let world = FocusWorld()
        let host = ClosureHost()
        let binding = SidebarWindowBinding(
            preferences: fixture.preferences(),
            focusRefresh: SidebarHostFocusRefresh(pause: ticks.pause, hostActivity: nil)
        )
        let refresh = binding.focusRefresh
        binding.apply(host.bound(world.snapshot()))

        binding.setVisible(true)
        #expect(!refresh.isRunning, "Visible and connected, but CMUX is not the active app")
        binding.setVisible(false)
        refresh.setActive(true)
        #expect(!refresh.isRunning, "Active and connected, but this window's sidebar is hidden")
        binding.apply(.bound(connection: host.connection, status: .waitingForHost, context: nil))
        binding.setVisible(true)
        #expect(!refresh.isRunning, "Visible and active, but disconnected")
        binding.apply(.unpaired)
        #expect(!refresh.isRunning)

        binding.apply(host.bound(world.snapshot()))
        await sidebarEventually { host.requests == 1 && ticks.pauses == 1 }
        refresh.setActive(false)
        #expect(!refresh.isRunning, "Deactivating CMUX stops the cadence")
        ticks.advance()
        for _ in 0..<5 { await Task.yield() }
        #expect(host.requests == 1 && ticks.pauses == 1, "A stopped cadence neither requests nor reschedules")
    }

    @Test func onlyCMUXOrItsVariantsCountAsTheActiveHost() {
        #expect(SidebarHostActivity.isHost("com.cmuxterm.app"))
        #expect(SidebarHostActivity.isHost("com.cmuxterm.app.debug"))
        #expect(!SidebarHostActivity.isHost("com.cmuxterm.application"))
        #expect(!SidebarHostActivity.isHost("com.example.other"))
        #expect(!SidebarHostActivity.isHost(nil))
    }

    /// The production gate reads the frontmost app on each app-switch notification.
    @Test func appSwitchNotificationsOpenAndCloseTheActivityGate() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let switches = NotificationCenter()
        let frontmost = FrontmostApp("com.example.other")
        let source = SidebarHostActivity.Source(
            frontmostBundleIdentifier: { frontmost.id }, isAppActive: { frontmost.selfActive },
            changes: [(switches, NSWorkspace.didActivateApplicationNotification)]
        )
        let ticks = ManualTicks()
        let world = FocusWorld()
        let host = ClosureHost()
        let refresh = SidebarHostFocusRefresh(pause: ticks.pause, hostActivity: source)
        let binding = SidebarWindowBinding(preferences: fixture.preferences(), focusRefresh: refresh)
        binding.apply(host.bound(world.snapshot()))
        binding.setVisible(true)
        #expect(!refresh.isActive && !refresh.isRunning, "Another app is frontmost")

        frontmost.id = SidebarHostActivity.hostBundleIdentifier
        #expect(!refresh.isRunning, "Activity is re-read only on an app switch")
        switches.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await sidebarEventually { refresh.isActive && host.requests == 1 }
        #expect(refresh.isRunning)

        frontmost.id = "com.example.other"
        switches.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await sidebarEventually { !refresh.isActive }
        #expect(!refresh.isRunning, "Switching away from CMUX stops the cadence")

        frontmost.id = nil
        frontmost.selfActive = true
        switches.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await sidebarEventually { refresh.isActive }
        #expect(refresh.isRunning, "The sidebar's own process being active also counts")

        let startsActive = SidebarHostFocusRefresh(pause: ticks.pause, hostActivity: SidebarHostActivity.Source(
            frontmostBundleIdentifier: { "com.cmuxterm.app.nightly" }, isAppActive: { false }, changes: []
        ))
        #expect(startsActive.isActive, "CMUX already frontmost opens the gate at creation")
    }

    /// The hosted view's own mount lifecycle starts and stops refreshing.
    @Test func mountingTheSidebarViewStartsRefreshingAndUnmountingStopsIt() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let ticks = ManualTicks()
        let refresh = SidebarHostFocusRefresh(pause: ticks.pause, hostActivity: nil)
        let binding = SidebarWindowBinding(preferences: fixture.preferences(), focusRefresh: refresh)
        let scene = CmuxSidebarScene(manifest: CmuxExtensionManifest(
            id: "com.example.focusrefresh.mount", displayName: "Focus refresh mount test",
            readScopes: [.workspaceMetadata, .surfaceMetadata], actionScopes: []
        ))
        binding.bind(to: scene)
        scene.viewDidAppear(UUID())
        let world = FocusWorld()
        let host = try PullOnlyCmuxWindow(scene: scene, snapshot: world.snapshot())
        defer { host.close() }
        host.push()
        await sidebarEventually { Self.focused(binding) == world.focus }
        refresh.setActive(true)
        #expect(!refresh.isRunning, "Connected and active, but not mounted")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: Color.clear.modifier(SidebarWindowLifecycle(binding: binding, scene: scene)))
        window.contentView = hosting
        await sidebarEventually {
            hosting.layoutSubtreeIfNeeded()
            return refresh.isRunning
        }
        await sidebarEventually { host.requests == 1 }

        window.contentView = nil
        await sidebarEventually { !refresh.isRunning }
        #expect(host.requests == 1)
    }

    @Test func activationVisibilityAndReconnectionEachRefreshAtOnce() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let ticks = ManualTicks()
        let world = FocusWorld()
        let host = ClosureHost()
        let binding = SidebarWindowBinding(
            preferences: fixture.preferences(),
            focusRefresh: SidebarHostFocusRefresh(pause: ticks.pause, hostActivity: nil)
        )
        host.reply = { [weak binding] in binding?.apply(host.bound(world.snapshot())) }
        let refresh = binding.focusRefresh
        binding.apply(host.bound(world.snapshot()))
        binding.setVisible(true)

        // Each transition waits for the previous reply: a request still outstanding is never repeated.
        refresh.setActive(true)
        await sidebarEventually { host.requests == 1 && host.answered == 1 }
        refresh.setActive(false)
        refresh.setActive(true)
        await sidebarEventually { host.requests == 2 && host.answered == 2 }
        binding.setVisible(false)
        binding.setVisible(true)
        await sidebarEventually { host.requests == 3 && host.answered == 3 }
        binding.apply(.bound(connection: host.connection, status: .waitingForHost, context: nil))
        binding.apply(host.bound(world.snapshot()))
        await sidebarEventually { host.requests == 4 }
        #expect(ticks.advances == 0, "Each refresh came from the transition, not a tick")
    }

    @Test func aRequestNeverOverlapsAnotherUntilAnsweredOrAbandoned() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let ticks = ManualTicks()
        let world = FocusWorld()
        let host = ClosureHost()
        let binding = SidebarWindowBinding(
            preferences: fixture.preferences(),
            focusRefresh: SidebarHostFocusRefresh(pause: ticks.pause, hostActivity: nil)
        )
        let refresh = binding.focusRefresh
        let limit = SidebarHostFocusRefresh.unansweredTickLimit
        binding.apply(host.bound(world.snapshot()))
        binding.setVisible(true)
        refresh.setActive(true)
        await sidebarEventually { ticks.pauses == 1 }
        #expect(host.requests == 1 && refresh.isAwaitingReply)

        // ticks.pauses counts parked waits, so each advance releases exactly the parked tick.
        for tick in 1..<limit {
            ticks.advance()
            await sidebarEventually { ticks.pauses == tick + 1 }
            #expect(host.requests == 1, "Tick \(tick) skipped: the previous request is unanswered")
        }
        ticks.advance()
        await sidebarEventually { ticks.pauses == limit + 1 }
        #expect(host.requests == 2, "After \(limit - 1) skipped ticks a lost reply stops blocking")

        binding.apply(host.bound(world.snapshot()))
        #expect(!refresh.isAwaitingReply)
        ticks.advance()
        await sidebarEventually { ticks.pauses == limit + 2 }
        #expect(host.requests == 3, "An answered request lets the next tick ask again")

        // Stopping and restarting keeps the outstanding request: the restart's first tick is skipped.
        refresh.setActive(false)
        refresh.setActive(true)
        await sidebarEventually { ticks.pauses == limit + 3 }
        binding.setVisible(false)
        binding.setVisible(true)
        await sidebarEventually { ticks.pauses == limit + 4 }
        #expect(host.requests == 3 && refresh.isAwaitingReply, "A restart never overlaps an outstanding request")

        // A lost connection never answers, so reconnecting asks at once.
        binding.apply(.bound(connection: host.connection, status: .waitingForHost, context: nil))
        #expect(!refresh.isRunning && !refresh.isAwaitingReply)
        binding.apply(host.bound(world.snapshot()))
        await sidebarEventually { ticks.pauses == limit + 5 }
        #expect(host.requests == 4)
    }

    @Test func anUnchangedRefreshedSnapshotInvalidatesNothing() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let world = FocusWorld()
        let host = ClosureHost()
        let binding = SidebarWindowBinding(
            preferences: fixture.preferences(),
            focusRefresh: SidebarHostFocusRefresh(pause: ManualTicks().pause, hostActivity: nil)
        )
        let model = binding.model
        binding.apply(host.bound(world.snapshot()))
        let hierarchy = model.hierarchy
        let invalidated = InvalidationFlag()
        withObservationTracking {
            _ = model.hierarchy
            _ = model.state
            _ = model.navigation.status
            _ = model.copilot.presentationTree
            _ = model.orchestration.snapshot
            // Re-installed by every re-apply, and rendered by the sidebar's open-workspace control.
            _ = model.openWorkspaceAtPath
        } onChange: { invalidated.set() }

        // The SDK publishes a pulled snapshot and then its connected status: two applications.
        binding.apply(host.bound(world.snapshot()))
        binding.apply(host.bound(world.snapshot()))
        #expect(!invalidated.value, "An identical snapshot re-applies nothing and invalidates no view")
        #expect(model.hierarchy == hierarchy)

        world.focus = world.secondTab
        binding.apply(host.bound(world.snapshot()))
        #expect(invalidated.value, "A changed snapshot still applies")
    }

    /// A realistic window: eight workspaces, 24 rows and six Copilot sessions. Repeated
    /// unchanged pulls neither invalidate views nor make Copilot or orchestration read again.
    @Test func unchangedPullsOfALargeWindowNeverReprojectIt() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let world = LargeWindow()
        let host = ClosureHost()
        let (binding, reads, polls) = world.binding(preferences: fixture.preferences())
        let model = binding.model
        binding.apply(host.bound(world.snapshot()))
        model.setVisible(true)
        defer { model.setVisible(false) }
        // Both readers have published their first read and parked; expiry timers never fire here.
        await sidebarEventually { polls.copilot.pauses == 1 && polls.orchestration.pauses == 1 }
        #expect(model.copilot.presentationTree.sessions.count == LargeWindow.sessionCount)
        #expect(model.orchestration.availability == .ready)
        let copilotReads = reads.copilot, orchestrationReads = reads.orchestration
        let projections = model.copilot.projectionCount
        let invalidated = InvalidationFlag()
        withObservationTracking {
            _ = model.hierarchy
            _ = model.state
            _ = model.copilot.presentationTree
            _ = model.orchestration.snapshot
            // Re-installed by every re-apply, and rendered by the sidebar's open-workspace control.
            _ = model.openWorkspaceAtPath
        } onChange: { invalidated.set() }

        for _ in 1...20 {
            let next = world.snapshot()
            binding.apply(host.bound(next))
            binding.apply(host.bound(next))
        }
        for _ in 0..<5 { await Task.yield() }
        #expect(!invalidated.value)
        #expect(reads.copilot == copilotReads && reads.orchestration == orchestrationReads)
        #expect(model.copilot.projectionCount == projections, "No Copilot re-projection")

        world.focus = world.surfaces[3]
        binding.apply(host.bound(world.snapshot()))
        #expect(invalidated.value, "Only a real focus change re-applies")
        for _ in 0..<5 { await Task.yield() }
        #expect(reads.copilot == copilotReads, "Focus is not part of the Copilot topology")
    }
}

@MainActor
private final class FrontmostApp {
    var id: String?
    var selfActive = false
    init(_ id: String?) { self.id = id }
}

private final class InvalidationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    var value: Bool { lock.withLock { fired } }
    func set() { lock.withLock { fired = true } }
}

enum FocusMove: CaseIterable, Sendable {
    case tab, splitPane, browser, workspace
}

/// A synthetic CMUX window: one custom-titled workspace with two tabs, a second pane and a
/// browser, plus a second workspace. Only focus and selection ever change.
@MainActor
private final class FocusWorld {
    let window = UUID()
    let workspace = UUID(), otherWorkspace = UUID()
    let firstTab = UUID(), secondTab = UUID(), otherPane = UUID(), browser = UUID(), otherWorkspaceTab = UUID()
    lazy var focus = firstTab
    lazy var selected = workspace
    private var sequence: UInt64 = 1
    private var last: CmuxSidebarSnapshot?

    /// Like CMUX's snapshot cache, identical content keeps its sequence.
    func snapshot() -> CmuxSidebarSnapshot {
        func surface(_ id: UUID, _ title: String, _ kind: CmuxSidebarSurfaceKind, focused: Bool) -> CmuxSidebarSurface {
            CmuxSidebarSurface(id: id, title: title, kind: kind, isFocused: focused)
        }
        var next = CmuxSidebarSnapshot(
            sequence: sequence, windowID: window, selectedWorkspaceID: selected,
            grantedReadScopes: [.workspaceMetadata, .surfaceMetadata],
            workspaces: [
                CmuxSidebarWorkspace(id: workspace, title: "SYNTHETIC", surfaces: [
                    surface(firstTab, "First tab", .terminal, focused: focus == firstTab),
                    surface(secondTab, "Second tab", .terminal, focused: focus == secondTab),
                    surface(otherPane, "Other pane", .terminal, focused: focus == otherPane),
                    surface(browser, "Docs", .browser, focused: focus == browser),
                ]),
                CmuxSidebarWorkspace(id: otherWorkspace, title: "OTHER", surfaces: [
                    surface(otherWorkspaceTab, "Other tab", .terminal, focused: true),
                ]),
            ]
        )
        if let last {
            var comparable = next
            comparable.sequence = last.sequence
            if comparable == last { return last }
            sequence = last.sequence + 1
            next.sequence = sequence
        }
        last = next
        return next
    }
}

/// Eight custom-titled workspaces with 24 surfaces (16 terminals, 8 browsers); six terminals host Copilot sessions.
@MainActor
private final class LargeWindow {
    static let workspaceCount = 8
    static let sessionCount = 6
    let window = UUID()
    let workspaces = (0..<LargeWindow.workspaceCount).map { _ in UUID() }
    let surfaces = (0..<24).map { _ in UUID() }
    lazy var focus = surfaces[0]

    @MainActor final class Reads {
        var copilot = 0
        var orchestration = 0
    }

    private func workspace(of index: Int) -> Int { min(index / 3, Self.workspaceCount - 1) }

    func snapshot() -> CmuxSidebarSnapshot {
        CmuxSidebarSnapshot(
            sequence: 1, windowID: window, selectedWorkspaceID: workspaces[workspace(of: surfaces.firstIndex(of: focus)!)],
            grantedReadScopes: [.workspaceList, .workspaceMetadata, .surfaceMetadata, .workspacePaths],
            workspaces: workspaces.enumerated().map { w, id in
                CmuxSidebarWorkspace(
                    id: id, title: "SYNTHETIC \(w)", detail: "Synthetic detail", rootPath: "/synthetic/\(w)",
                    gitBranch: "feature/\(w)", unreadCount: w % 3, listeningPorts: [3000 + w],
                    surfaces: surfaces.indices.filter { workspace(of: $0) == w }.map { s in
                        CmuxSidebarSurface(
                            id: surfaces[s], title: "Synthetic tab \(s)", kind: s % 3 == 2 ? .browser : .terminal,
                            isFocused: surfaces[s] == focus || (workspace(of: s) != workspace(of: surfaces.firstIndex(of: focus)!)
                                && s == surfaces.indices.first { workspace(of: $0) == w })
                        )
                    }
                )
            }
        )
    }

    /// The pollers' cadences; their expiry timers are separate ticks the test never advances.
    struct Polls {
        let copilot = ManualTicks(), orchestration = ManualTicks(), expiry = ManualTicks()
    }

    func binding(preferences: SidebarPreferences) -> (SidebarWindowBinding, Reads, Polls) {
        let reads = Reads()
        let polls = Polls()
        let expiry = polls.expiry
        // Each reading is a step later than the last, so every read is fresh and newer than any invalidation.
        let clock = SteppingClock()
        let surfaces = surfaces, workspaces = workspaces
        let sessionPlacements = (0..<Self.sessionCount).map { index in
            (session: UUID(), surface: surfaces[index * 3], workspace: workspaces[workspace(of: index * 3)])
        }
        let copilot = SidebarCopilotPolling(read: { [reads] placements in
            await MainActor.run { reads.copilot += 1 }
            let observed = clock.now()
            let sessions = sessionPlacements.enumerated().map { index, placement -> CopilotSessionObservation in
                .init(sessionID: placement.session, surfaceID: placement.surface, launchWorkspaceID: placement.workspace,
                      liveness: .alive, state: index % 2 == 0 ? .working : .idle, model: nil, children: [
                          .init(id: "child-\(index)", parentID: nil, kind: .skill, name: "Synthetic child",
                                state: .working, model: nil, attention: nil)
                      ], observedAt: observed, attention: nil)
            }
            return CopilotSnapshotAdapter.snapshot(
                .init(generatedAt: observed, sessions: sessions.filter { placements[$0.surfaceID] != nil },
                      issues: [], isComplete: true),
                workspaceBySurface: placements
            )
        }, pause: polls.copilot.pause, expiryPause: { _ in try await expiry.pause() }, now: { clock.now() })
        let orchestration = SidebarOrchestrationPolling(read: { [reads] in
            await MainActor.run { reads.orchestration += 1 }
            return .init(version: 1, generatedAt: clock.now(), complete: true, omittedCount: 0, nodes: [])
        }, pause: polls.orchestration.pause, expiryPause: { _ in try await expiry.pause() }, now: { clock.now() })
        let binding = SidebarWindowBinding(
            preferences: preferences,
            model: SidebarConnectionModel(copilot: copilot, orchestration: orchestration),
            focusRefresh: SidebarHostFocusRefresh(pause: ManualTicks().pause, hostActivity: nil)
        )
        return (binding, reads, polls)
    }
}

/// A deterministic clock that advances one millisecond per reading.
private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var readings = 0
    func now() -> Date {
        lock.withLock {
            readings += 1
            return Date(timeIntervalSince1970: 1_800_000_000 + Double(readings) / 1_000)
        }
    }
}

/// The SDK's host channel with a counted refresh and a test-controlled reply.
@MainActor
private final class ClosureHost {
    let connection = CmuxSidebarConnectionID(rawValue: 1)
    private(set) var requests = 0
    private(set) var answered = 0
    var reply: (@MainActor () -> Void)?

    func bound(_ snapshot: CmuxSidebarSnapshot) -> CmuxSidebarSceneState {
        .bound(connection: connection, status: .connected, context: CmuxSidebarContext(
            snapshot: snapshot,
            host: CmuxSidebarHost(performAction: { _, _ in }, refreshSnapshot: { [weak self] in
                guard let self else { return }
                requests += 1
                // Replies arrive later, on their own main-actor turn, as over XPC.
                if let reply {
                    Task { @MainActor [weak self] in
                        reply()
                        self?.answered += 1
                    }
                }
            })
        ))
    }
}

/// Explicit tick barrier: each pause waits until the test advances it. A pause is counted only
/// once it is parked, in the same critical section, so an `advance()` issued after observing the
/// count always releases it. Lock-protected because continuation and cancellation closures may
/// run off the main actor.
private final class ManualTicks: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var pauseCount = 0
    private var advanceCount = 0

    var pauses: Int { lock.withLock { pauseCount } }
    var advances: Int { lock.withLock { advanceCount } }

    func pause() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock { () -> Bool in
                    if Task.isCancelled { return true }
                    waiters[id] = continuation
                    pauseCount += 1
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    func advance() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            advanceCount += 1
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        for continuation in resumed { continuation.resume() }
    }
}

/// A CMUX window over real in-process XPC that answers pulls but pushes only when told.
@MainActor
private final class PullOnlyCmuxWindow {
    private let extensionSide: PullListener
    private let host: PullHostObject
    private let connection: NSXPCConnection

    var requests: Int { host.requests }
    private(set) var pushes = 0

    init(scene: CmuxSidebarScene, snapshot: CmuxSidebarSnapshot) throws {
        host = PullHostObject(snapshot: snapshot)
        extensionSide = PullListener(scene: scene)
        connection = NSXPCConnection(listenerEndpoint: extensionSide.listener.endpoint)
        connection.exportedInterface = NSXPCInterface(with: CMUXSidebarHostXPC.self)
        connection.exportedObject = host
        connection.remoteObjectInterface = NSXPCInterface(with: CMUXSidebarExtensionXPC.self)
        connection.resume()
    }

    func replace(_ snapshot: CmuxSidebarSnapshot) { host.replace(snapshot) }

    func push() {
        guard let payload = host.payload() else { return }
        pushes += 1
        (connection.remoteObjectProxy as? CMUXSidebarExtensionXPC)?.sidebarSnapshotDidChange(payload)
    }

    func close() {
        connection.invalidate()
        extensionSide.listener.invalidate()
    }
}

private final class PullListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    private let scene: CmuxSidebarScene

    init(scene: CmuxSidebarScene) {
        self.scene = scene
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        scene.accept(connection)
    }
}

// XPC callbacks share only lock-protected synthetic state.
private final class PullHostObject: NSObject, CMUXSidebarHostXPC, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: CmuxSidebarSnapshot
    private var requestCount = 0

    init(snapshot: CmuxSidebarSnapshot) { self.snapshot = snapshot }

    var requests: Int { lock.withLock { requestCount } }
    func replace(_ snapshot: CmuxSidebarSnapshot) { lock.withLock { self.snapshot = snapshot } }
    func payload() -> NSData? { try? CmuxSidebarXPCCodec.encodeSnapshot(lock.withLock { snapshot }) }

    func requestSidebarSnapshot(reply: @escaping (NSData?, NSString?) -> Void) {
        lock.withLock { requestCount += 1 }
        reply(payload(), nil)
    }

    func performSidebarAction(_ payload: NSData, reply: @escaping (NSData?, NSString?) -> Void) {
        reply(try? CmuxSidebarXPCCodec.encodeActionResult(.rejected("unsupported")), nil)
    }
}

extension SidebarHostFocusRefreshTests {
    fileprivate static func focused(_ binding: SidebarWindowBinding) -> UUID? {
        guard case .surface(_, let surface) = SidebarPresentation.focusedSurface(in: binding.model.hierarchy) else {
            return nil
        }
        return surface
    }
}
