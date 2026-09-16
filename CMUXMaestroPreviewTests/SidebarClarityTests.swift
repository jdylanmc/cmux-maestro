import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized)
struct SidebarClarityTests {
    private let fixtures = SidebarTreeFixtures()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func emptyChildNoticeDoesNotClaimTheWholeTaskboardIsUnavailable() {
        #expect(SidebarPresentation.emptyChildHistoryTitle(complete: true) == "No visible child tasks")
        #expect(SidebarPresentation.emptyChildHistoryTitle(complete: false) == "Child history unavailable")
    }

    @Test func unifiedOutlineClaimsOnlyExactManagedWorkspaceSurfacePairs() throws {
        let surface = HierarchySurface(
            id: fixtures.surfaceA, title: "Duplicate title", kind: .terminal,
            isFocused: true, isPinned: false, unreadCount: 0, workingDirectory: .available(nil)
        )
        let other = HierarchySurface(
            id: fixtures.surfaceB, title: "Duplicate title", kind: .terminal,
            isFocused: false, isPinned: false, unreadCount: 0, workingDirectory: .available(nil)
        )
        let managed = managedNode(role: "coordinator", surface: fixtures.surfaceA)
        #expect(SidebarPresentation.unmanagedSurfaces(
            [surface, other], workspaceID: fixtures.workspaceA, managed: [managed]
        ).map(\.id) == [fixtures.surfaceB])
        #expect(SidebarPresentation.unmanagedSurfaces(
            [surface], workspaceID: fixtures.workspaceB, managed: [managed]
        ).map(\.id) == [fixtures.surfaceA])
        #expect(SidebarPresentation.unmanagedSurfaces(
            [surface, other], workspaceID: fixtures.workspaceA, managed: []
        ).count == 2)
    }

    @Test func staleManagedStateAndRegistrationNeverClaimRunning() {
        let root = managedNode(role: "coordinator", surface: fixtures.surfaceA)
        let worker = managedNode(role: "worker", surface: fixtures.surfaceB)
        #expect(SidebarPresentation.managedState(root, availability: .ready, now: now).tone == .neutral)
        #expect(SidebarPresentation.managedState(worker, availability: .ready, now: now).tone == .green)
        for availability: SidebarOrchestrationAvailability in [.stale, .unavailable, .loading, .disconnected] {
            let visual = SidebarPresentation.managedState(worker, availability: availability, now: now)
            #expect(visual.tone == .neutral)
            #expect(visual.title.contains("unverified"))
            #expect(NSImage(systemSymbolName: visual.symbol, accessibilityDescription: visual.title) != nil)
        }
        #expect(SidebarPresentation.managedState(
            worker, availability: .ready, now: now.addingTimeInterval(61)
        ).tone == .neutral)
        var summary = SidebarBranchSummary(sessions: [])
        summary.include(managed: [worker], availability: .stale, now: now)
        #expect(summary.running == 0)
        #expect(summary.incomplete)
        #expect(SidebarPresentation.collapsed(SidebarBranchSummary(sessions: [])).isEmpty)
    }

    @Test func outlineMovesPassiveToolActivityToDetailsButRetainsWorkAndAncestors() throws {
        let nodes: [SidebarCopilotNode] = [
            .init(id: "passive-skill", parentID: nil, depth: 0, kind: .skill,
                  name: "Explain", state: .unknown, model: nil, ancestryUnresolved: false, hasChildren: false),
            .init(id: "ancestor", parentID: nil, depth: 0, kind: .skill,
                  name: "Delegate", state: .idle, model: nil, ancestryUnresolved: false, hasChildren: true),
            .init(id: "agent", parentID: "ancestor", depth: 1, kind: .subagent,
                  name: "Worker", state: .idle, model: nil, ancestryUnresolved: false, hasChildren: false),
            .init(id: "blocked", parentID: nil, depth: 0, kind: .shell,
                  name: "Permission", state: .blocked, model: nil, ancestryUnresolved: false, hasChildren: false),
            .init(id: "working", parentID: nil, depth: 0, kind: .skill,
                  name: "Executing", state: .working, model: nil, ancestryUnresolved: false, hasChildren: false),
            .init(id: "attention", parentID: nil, depth: 0, kind: .skill,
                  name: "Outcome", state: .idle, model: nil, ancestryUnresolved: false, hasChildren: false,
                  attention: [signal(.turnFinished)])
        ]
        let session = try #require(makeTree(nodes: nodes).sessions.first)
        let primaryIDs = ["ancestor", "agent", "blocked", "working", "attention"]
        #expect(session.outlineNodes.map(\.id) == primaryIDs)
        #expect(session.secondaryActivity.map(\.id) == ["passive-skill"])
        #expect(session.outlineChildRows(layout: .init()).map(\.id) == primaryIDs)
        #expect(session.nodes == nodes)
        var collapsed = SidebarLayoutSettings()
        collapsed.setExpanded(false, for: .child("ancestor", sessionID: session.id))
        #expect(!session.outlineChildRows(layout: collapsed).contains { $0.id == "agent" })
        #expect(session.outlineNodes.first?.hasChildren == true)
    }

    @Test func endedOrUnconfirmedSessionsNeverBorrowWorkingColor() {
        for liveness: CopilotLiveness in [.dead, .unknown, .ambiguous] {
            let session = managedSession(
                id: fixtures.sessionID, surface: fixtures.surfaceA, model: nil, liveness: liveness
            )
            #expect(SidebarPresentation.sessionState(session).tone == .neutral)
        }
    }

    @Test func entityIconsAndStateBadgesDoNotRelyOnColorAlone() {
        let kinds = [
            SidebarPresentation.workspace, SidebarPresentation.surface(.terminal),
            SidebarPresentation.session, SidebarPresentation.work(.subagent),
            SidebarPresentation.work(.skill)
        ]
        #expect(Set(kinds.map(\.symbol)).count == kinds.count)
        #expect(Set(kinds.map(\.title)).count == kinds.count)
        #expect(Set(kinds.map(\.tone)).count >= 4)
        let states: [CopilotWorkState] = [.working, .idle, .blocked, .completed, .failed, .cancelled, .unknown]
        let visuals = states.map(SidebarPresentation.state)
        #expect(Set(visuals.map(\.symbol)).count == states.count)
        #expect(Set(visuals.map(\.title)).count == states.count)
        for visual in kinds + visuals + [.alive, .dead, .ambiguous, .unknown].map(SidebarPresentation.process) {
            #expect(NSImage(systemSymbolName: visual.symbol, accessibilityDescription: visual.title) != nil)
        }
        #expect(SidebarPresentation.state(.completed).tone == .green)
        #expect(SidebarPresentation.state(.failed).tone == .red)
        #expect(SidebarPresentation.state(.blocked).tone == .amber)
        #expect(SidebarPresentation.state(.unknown).tone == .neutral)
        #expect(SidebarPresentation.process(.dead).title == "Process ended")
        #expect(SidebarPresentation.process(.dead).symbol != SidebarPresentation.state(.completed).symbol)
    }

    @Test func compactWarningsRetainUrgentSignalsAndExposeEveryReasonInDetails() {
        var tree = makeTree(nodes: [node(state: .unknown)], complete: false, omittedActive: 3)
        tree.issues = [.permissionDenied, .malformedData, .ambiguousIdentity, .readLimitReached]
        let primary = SidebarPresentation.primaryWarnings(tree)
        #expect(primary == ["Copilot access denied", "3 working/blocked tasks not shown"])
        #expect(SidebarPresentation.overviewWarnings(tree).contains("Some Copilot history is unreadable"))
        #expect(SidebarPresentation.overviewWarnings(tree).contains("Session identity is unconfirmed"))
    }

    @Test(arguments: [false, true])
    func iconAndStatusPaletteRendersInLightAndDark(dark: Bool) throws {
        let kinds = [SidebarPresentation.workspace, SidebarPresentation.surface(.terminal),
                     SidebarPresentation.session, SidebarPresentation.work(.subagent), SidebarPresentation.work(.skill)]
        let states: [CopilotWorkState] = [.working, .blocked, .completed, .failed, .idle, .cancelled, .unknown]
        let frame = NSRect(x: 0, y: 0, width: 349, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            Text("Visual key").font(.headline)
            ForEach(kinds, id: \.title) { visual in
                HStack { SidebarKindIcon(visual: visual); Text(visual.title) }
            }
            Divider()
            ForEach(states, id: \.self) { state in SidebarStateBadge(visual: SidebarPresentation.state(state)) }
            SidebarStateBadge(visual: SidebarPresentation.process(.dead))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.frame = frame
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(!window.isVisible)
        var coloredPixels = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if max(color.redComponent, color.greenComponent, color.blueComponent)
                    - min(color.redComponent, color.greenComponent, color.blueComponent) > 0.15 {
                    coloredPixels += 1
                }
            }
        }
        #expect(coloredPixels > 100)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/sidebar-clarity/visual-key")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent(dark ? "dark.png" : "light.png"))
    }

    @Test func healthyOverviewIsOneSummaryWithoutZeroCountOrDiagnosticWalls() {
        let tree = makeTree(nodes: [node(state: .working)])
        #expect(SidebarPresentation.overview(tree) == "1 session · 1 working")
        #expect(SidebarPresentation.overviewWarnings(tree).isEmpty)
        let idle = makeTree(nodes: [])
        #expect(SidebarPresentation.overview(idle) == "1 session")
        #expect(!SidebarPresentation.overview(idle).contains("0"))
        #expect(!SidebarPresentation.overview(tree).contains("Process"))
        #expect(!SidebarPresentation.overview(tree).contains("retained"))
    }

    @Test func unknownPartialDeniedAndOmittedActiveSignalsStayPrimary() {
        var tree = makeTree(nodes: [node(state: .unknown)], complete: false, omittedActive: 3)
        #expect(SidebarPresentation.overview(tree).contains("state unknown"))
        #expect(SidebarPresentation.overviewWarnings(tree).contains("Partial data · counts may be incomplete"))
        #expect(SidebarPresentation.overviewWarnings(tree).contains("3 working/blocked tasks beyond display limits"))
        tree.issues = [.permissionDenied]
        #expect(SidebarPresentation.overviewWarnings(tree).contains("Copilot access denied"))
        tree.issues = [.malformedData, .unsupportedFormat, .identityChanged, .ambiguousIdentity, .ambiguousTurn, .stateUnavailable, .readLimitReached]
        #expect(SidebarPresentation.overviewWarnings(tree).contains("Some Copilot history is unreadable"))
        #expect(SidebarPresentation.overviewWarnings(tree).contains("Session identity is unconfirmed"))
        #expect(SidebarPresentation.overviewWarnings(tree).contains("Turn identity is unconfirmed"))
        #expect(SidebarPresentation.overviewWarnings(tree).contains("History read limit reached"))
        for availability: SidebarCopilotAvailability in [.waiting, .loading, .hidden, .disconnected, .unavailable] {
            tree.availability = availability
            #expect(!SidebarPresentation.overviewWarnings(tree).isEmpty)
        }
    }

    @Test func blockingUnknownAndDegradedReasonsAreNeverMovedIntoDetailsOnly() {
        let permission = signal(.permission)
        let answer = signal(.answer)
        let inline = SidebarPresentation.attention([permission, answer], state: .blocked, degraded: true)
        #expect(inline.contains("Waiting for permission"))
        #expect(inline.contains("Waiting for answer"))
        #expect(inline.contains("Attention evidence incomplete"))
        #expect(SidebarPresentation.attention([], state: .blocked, degraded: false) == ["Blocking reason unavailable"])
        #expect(SidebarPresentation.attention([signal(.turnFinished)], state: .idle, degraded: false) == ["Turn finished"])
        #expect(SidebarPresentation.attentionDetails([signal(.turnFinished)]).contains {
            $0.value == "Main turn only; background work may continue."
        })
        let summary = SidebarBranchSummary(nodes: [node(state: .blocked, attention: [permission]), node(state: .unknown)])
        #expect(SidebarPresentation.collapsed(summary).contains("States or counts incomplete"))
        #expect(SidebarPresentation.collapsed(summary)[0].contains("1 blocked"))
        #expect(!SidebarPresentation.collapsed(summary)[0].contains("0"))
    }

    @Test func selectionMetadataShowsOnlyObservedModelAndGrantedPaths() throws {
        let ended = node(state: .completed)
        let session = try #require(makeTree(nodes: [ended]).sessions.first)
        let details = SidebarPresentation.nodeDetails(ended, session: session)
        #expect(!details.contains { $0.title == "Model" })
        #expect(details.contains(.init(title: "Completion", value: "Completion age unknown")))
        #expect(!details.contains { $0.title == "Context usage" })
        let observed = SidebarCopilotNode(
            id: "observed", parentID: nil, depth: 0, kind: .subagent,
            name: "Observed", state: .working, model: "gpt-observed",
            ancestryUnresolved: false, hasChildren: false
        )
        #expect(SidebarPresentation.nodeDetails(observed, session: session)
            .contains(.init(title: "Model", value: "gpt-observed")))
        let full = "/synthetic/workspace/with/a/long/granted/path"
        let paths = HierarchyPathContext(rootPath: .available(full), projectRootPath: .unavailable, workingDirectory: .available(nil))
        #expect(SidebarPresentation.briefPath(root: paths.rootPath, project: paths.projectRootPath) == full)
        #expect(SidebarPresentation.paths(paths).contains(.init(title: "Workspace path", value: full)))
        #expect(SidebarPresentation.paths(paths).contains(.init(title: "Project path", value: "Path unavailable")))
        #expect(SidebarPresentation.briefPath(root: .unavailable, project: .unavailable) == nil)
        #expect(SidebarPresentation.briefPath(root: .available(nil), project: .available(full)) == full)
    }

    @Test func managedModelUsesOnlyFreshExactSurfaceAndSessionIdentity() throws {
        let workerSessionID = UUID()
        let workerSurface = UUID()
        let root = managedNode(role: "coordinator", surface: fixtures.surfaceA)
        let worker = managedNode(
            role: "worker", surface: workerSurface, sessionID: workerSessionID
        )
        let rootSession = managedSession(
            id: fixtures.sessionID, surface: fixtures.surfaceA, model: "root-model"
        )
        let workerSession = managedSession(
            id: workerSessionID, surface: workerSurface, model: "worker-model"
        )
        let extraSameName = managedSession(
            id: UUID(), surface: workerSurface, model: "other-model"
        )
        let exact = SidebarCopilotTree(
            availability: .ready,
            sessions: [rootSession, workerSession, extraSameName],
            issues: [], generatedAt: now
        )
        #expect(SidebarPresentation.managedModel(for: root, in: exact, now: now) == "root-model")
        #expect(SidebarPresentation.managedModel(for: worker, in: exact, now: now) == "worker-model")
        #expect(SidebarPresentation.managedNodeDetails(
            worker, hierarchy: fixtures.hierarchy(), tree: exact, now: now
        ).contains(.init(title: "Model", value: "worker-model")))
        #expect(!SidebarPresentation.managedNodeDetails(
            worker, hierarchy: fixtures.hierarchy(), tree: exact, now: now
        ).contains { $0.title == "Context usage" })

        let ambiguousRoot = SidebarCopilotTree(
            availability: .ready,
            sessions: [rootSession, managedSession(
                id: UUID(), surface: fixtures.surfaceA, model: "ambiguous"
            )],
            issues: [], generatedAt: now
        )
        #expect(SidebarPresentation.managedModel(for: root, in: ambiguousRoot, now: now) == nil)
        #expect(SidebarPresentation.managedModel(
            for: managedNode(role: "worker", surface: workerSurface),
            in: exact, now: now
        ) == nil)
        #expect(SidebarPresentation.managedModel(
            for: managedNode(role: "worker", surface: UUID(), sessionID: workerSessionID),
            in: exact, now: now
        ) == nil)
        let stale = SidebarCopilotTree(
            availability: .ready, sessions: [rootSession], issues: [],
            generatedAt: now.addingTimeInterval(-SidebarCopilotTree.maximumAge - 1)
        )
        #expect(SidebarPresentation.managedModel(for: root, in: stale, now: now) == nil)
        let absent = SidebarCopilotTree(
            availability: .ready,
            sessions: [managedSession(
                id: workerSessionID, surface: workerSurface, model: nil
            )],
            issues: [], generatedAt: now
        )
        #expect(SidebarPresentation.managedModel(for: worker, in: absent, now: now) == nil)
    }

    @Test(arguments: [CopilotLiveness.dead, .ambiguous, .unknown])
    func managedModelRejectsNonLiveOwners(liveness: CopilotLiveness) {
        let sessionID = UUID()
        let surfaceID = UUID()
        let root = managedNode(role: "coordinator", surface: surfaceID)
        let worker = managedNode(role: "worker", surface: surfaceID, sessionID: sessionID)
        let inactive = managedSession(
            id: sessionID, surface: surfaceID, model: "not-current", liveness: liveness
        )
        let tree = SidebarCopilotTree(
            availability: .ready, sessions: [inactive], issues: [], generatedAt: now
        )
        #expect(SidebarPresentation.managedModel(for: root, in: tree, now: now) == nil)
        #expect(SidebarPresentation.managedModel(for: worker, in: tree, now: now) == nil)
        let current = managedSession(id: UUID(), surface: surfaceID, model: "current-model")
        let reused = SidebarCopilotTree(
            availability: .ready, sessions: [inactive, current], issues: [], generatedAt: now
        )
        #expect(SidebarPresentation.managedModel(for: root, in: reused, now: now) == "current-model")
        #expect(SidebarPresentation.managedModel(for: worker, in: reused, now: now) == nil)
    }

    @Test func realDetailsAndFocusHandlersAreIndependentAndKeepTypedNavigationGuards() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let navigation = SidebarNavigation()
        var targets: [SidebarNavigationTarget] = []
        navigation.update(topology: fixtures.topology(), connected: true, workspaceAllowed: true, surfaceAllowed: true) {
            targets.append($0)
        }
        let target = SidebarNavigationTarget.surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA)
        let focus = FocusButton(target: target, navigation: navigation, label: "Focus synthetic task") { Text("Synthetic task") }
        var expanded = false
        let details = SidebarDetailsButton(
            expanded: Binding(get: { expanded }, set: { expanded = $0 }),
            label: "Synthetic task", id: "details-synthetic"
        )
        let history = preferences.history
        let attention = preferences.attention
        let layout = preferences.layout
        #expect(details.accessibilityTitle == "Details for Synthetic task")
        #expect(SidebarPresentation.minimumControlSize >= 24)
        details.toggle()
        #expect(expanded)
        #expect(targets.isEmpty)
        #expect(navigation.status == .idle)
        focus.focus()
        await sidebarEventually { navigation.status == .selected }
        #expect(targets == [target])
        #expect(expanded)
        details.toggle()
        #expect(!expanded)
        #expect(preferences.history == history)
        #expect(preferences.attention == attention)
        #expect(preferences.layout == layout)
        navigation.update(topology: fixtures.topology(moved: true), connected: true, workspaceAllowed: true, surfaceAllowed: true) {
            targets.append($0)
        }
        focus.focus()
        #expect(navigation.status == .staleTarget)
        #expect(targets == [target])
    }

    @Test(arguments: [240, 349])
    func fullMetadataRendersOffscreenWithoutHorizontalClipping(width: Int) throws {
        let ended = node(state: .completed)
        let session = try #require(makeTree(nodes: [ended]).sessions.first)
        let full = "/synthetic/" + String(repeating: "long-directory/", count: 20)
        let paths = HierarchyPathContext(rootPath: .available(full), projectRootPath: .available(full + "project"),
                                        workingDirectory: .available(full + "working"))
        let lines = SidebarPresentation.nodeDetails(ended, session: session) + SidebarPresentation.paths(paths)
        let frame = NSRect(x: 0, y: 0, width: width, height: 941)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: ScrollView {
            SidebarMetadataDetails(lines: lines).padding(10)
        })
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        #expect(!window.isVisible)
        let metrics = SidebarRenderingEvidence.metrics(for: view)
        #expect(metrics.documentWidth <= metrics.viewportWidth + 0.5)
        #expect(metrics.documentHeight > 250)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1_024)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/sidebar-clarity/details")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try png.write(to: root.appendingPathComponent("metadata-\(width).png"))
    }

    @Test func presentationDoesNotNestSecondaryInteractiveControlsInsideFocusLabels() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("CMUXMaestroSidebar/UI/SidebarView.swift"), encoding: .utf8)
        let expression = try NSRegularExpression(pattern: #"FocusButton\([\s\S]*?\)\s*\{"#)
        let text = source as NSString
        let ranges = expression.matches(in: source, range: NSRange(location: 0, length: text.length))
        #expect(ranges.count >= 4)
        for match in ranges {
            var end = match.range.location + match.range.length
            let start = end
            var depth = 1
            while end < text.length && depth > 0 {
                let character = text.character(at: end)
                if character == 123 { depth += 1 }
                if character == 125 { depth -= 1 }
                end += 1
            }
            let label = text.substring(with: NSRange(location: start, length: end - start))
            #expect(!label.contains("SidebarDetailsButton"))
            #expect(!label.contains("AcknowledgeOutcomeButton"))
            #expect(!label.contains("DismissOutcomeButton"))
            #expect(!label.contains(".popover"))
        }
    }

    private func node(state: CopilotWorkState, attention: [AgentAttention] = []) -> SidebarCopilotNode {
        .init(id: state.rawValue, parentID: nil, depth: 0, kind: .subagent, name: "Synthetic task",
              state: state, model: nil, ancestryUnresolved: false, hasChildren: false, attention: attention)
    }

    private func signal(_ kind: AgentAttentionKind) -> AgentAttention {
        .init(kind: kind, evidence: .init(source: "copilot.events", eventID: fixtures.sessionID), occurredAt: now)
    }

    private func makeTree(nodes: [SidebarCopilotNode], complete: Bool = true, omittedActive: Int = 0) -> SidebarCopilotTree {
        .init(availability: complete ? .ready : .partial, sessions: [
            .init(id: fixtures.sessionID, workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA,
                  liveness: .alive, state: .idle, model: nil, observedAt: now, nodes: nodes,
                  childrenComplete: complete, treeDegraded: !complete, omittedChildrenCount: omittedActive,
                  omittedActiveChildrenCount: omittedActive)
        ], issues: [], generatedAt: now)
    }

    private func managedNode(
        role: String, surface: UUID, sessionID: UUID? = nil
    ) -> SidebarOrchestrationNode {
        SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: role == "worker" ? UUID() : nil,
            role: role, label: "Same name", workspaceId: fixtures.workspaceA,
            surfaceId: surface, generation: role == "worker" ? 1 : 0,
            phase: role == "worker" ? "turn-running" : "registered",
            availability: role == "worker" ? "busy" : "active",
            copilotSessionId: sessionID, createdAt: now, updatedAt: now
        )
    }

    private func managedSession(
        id: UUID, surface: UUID, model: String?, liveness: CopilotLiveness = .alive
    ) -> SidebarCopilotSession {
        SidebarCopilotSession(
            id: id, workspaceID: fixtures.workspaceA, surfaceID: surface,
            liveness: liveness, state: .working, model: model, observedAt: now,
            nodes: [], childrenComplete: true, treeDegraded: false,
            omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
    }
}
