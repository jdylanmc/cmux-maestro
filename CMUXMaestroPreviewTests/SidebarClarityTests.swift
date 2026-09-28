import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarClarityTests {
    private let fixtures = SidebarTreeFixtures()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func obsoleteRegistrationVisibilityPreservesOnlyNeededContextAndExactObservations() throws {
        let old = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Previous failed coordinator",
            workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA, generation: 1, phase: "turn-failed",
            availability: "idle", copilotSessionId: fixtures.otherSessionID, executionMode: .interactive,
            createdAt: now.addingTimeInterval(-120), updatedAt: now.addingTimeInterval(-120)
        )
        func validate(_ nodes: [SidebarOrchestrationNode]) throws {
            try SidebarOrchestrationReader.validate(
                .init(version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: nodes), now: now
            )
        }
        try validate([old])
        var observation = managedSession(id: fixtures.otherSessionID, surface: fixtures.surfaceA, model: nil, liveness: .dead)
        var current = managedSession(id: fixtures.sessionID, surface: fixtures.surfaceA, model: nil)
        current.attention = [signal(.permission)]
        var tree = SidebarCopilotTree(availability: .partial, sessions: [observation, current],
                                     issues: [.ambiguousTurn], generatedAt: now)
        func visible(_ candidate: SidebarCopilotTree, nodes: [SidebarOrchestrationNode]? = nil, showEnded: Bool = true) -> SidebarVisibleWork {
            SidebarVisibleWork(tree: candidate, managed: nodes ?? [old], history: .init(), showEnded: showEnded, now: now)
        }
        for showEnded in [false, true] {
            #expect(visible(tree, showEnded: showEnded).managed.isEmpty)
            #expect(visible(tree, showEnded: showEnded).tree.sessions == [current])
            #expect(visible(tree, showEnded: showEnded).hiddenSurfaces.isEmpty)
        }
        for liveness: CopilotLiveness in [.alive, .ambiguous, .unknown] {
            var noEndProof = tree
            noEndProof.sessions = [
                managedSession(id: fixtures.otherSessionID, surface: fixtures.surfaceA, model: nil, liveness: liveness),
                current
            ]
            #expect(visible(noEndProof).managed == [old], "A recorded failed turn is not process-end proof")
        }
        for observedAt in [now.addingTimeInterval(-9), now.addingTimeInterval(2)] {
            var noEndProof = tree
            noEndProof.sessions = [managedSession(
                id: fixtures.otherSessionID, surface: fixtures.surfaceA, model: nil, liveness: .dead, observedAt: observedAt
            ), current]
            #expect(visible(noEndProof).managed == [old], "Original death observation must itself be fresh")
        }
        var absentOld = tree
        absentOld.sessions = [current]
        #expect(visible(absentOld).managed == [old], "Missing original observation is not death proof")
        for kind: AgentAttentionKind in [.answer, .permission, .error] {
            observation.attention = [signal(kind)]
            tree.sessions = [observation, current]
            #expect(visible(tree).managed == [old] && visible(tree).tree.sessions == tree.sessions)
        }
        observation.attention = []
        for state: CopilotWorkState in [.working, .idle, .unknown, .blocked, .failed] {
            observation.nodes = [node(state: state)]
            tree.sessions = [observation, current]
            for showEnded in [false, true] {
                #expect(visible(tree, showEnded: showEnded).managed == [old])
                #expect(visible(tree, showEnded: showEnded).tree.sessions.first?.nodes == observation.nodes,
                        "Unknown/active original child context must survive the Show ended shortcut")
            }
        }
        observation.nodes = []
        observation.attentionDegraded = true
        tree.sessions = [observation, current]
        #expect(visible(tree).managed == [old])
        observation.attentionDegraded = false
        tree.sessions = [observation, current]
        for (degraded, omitted) in [(true, 0), (false, 1)] {
            var protected = tree
            protected.sessions[0] = .init(
                id: observation.id, workspaceID: observation.workspaceID, surfaceID: observation.surfaceID,
                liveness: .dead, state: .unknown, model: nil, observedAt: now, nodes: [],
                childrenComplete: false, treeDegraded: degraded, omittedChildrenCount: omitted, omittedActiveChildrenCount: omitted
            )
            #expect(visible(protected).managed == [old])
        }
        for phase in ["reported-blocked", "permission-denied", "reported-failed", "report-missing", "turn-running"] {
            let protected = SidebarOrchestrationNode(
                id: UUID(), runId: old.runId, parentId: old.id, role: "worker", label: "Unresolved child",
                workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceB, generation: 1,
                phase: phase, availability: phase == "turn-running" ? "busy" : "idle",
                copilotSessionId: UUID(), executionMode: .bounded, createdAt: now, updatedAt: now
            )
            try validate([old, protected])
            var withReplacement = tree
            withReplacement.sessions.append(managedSession(id: UUID(), surface: fixtures.surfaceB, model: nil))
            #expect(visible(withReplacement, nodes: [old, protected]).managed == [old, protected])
        }
        let child = SidebarOrchestrationNode(
            id: UUID(), runId: old.runId, parentId: old.id, role: "worker", label: "Context ancestor",
            workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceB, generation: 1,
            phase: "reported-completed", availability: "idle", copilotSessionId: UUID(),
            createdAt: now, updatedAt: now
        )
        let otherCurrent = managedSession(id: UUID(), surface: fixtures.surfaceB, model: nil)
        tree.sessions.append(otherCurrent)
        try validate([old, child])
        #expect(visible(tree, nodes: [old, child]).managed.isEmpty,
                "Entire obsolete branches can disappear when none of their nodes are needed")
        let grandchild = SidebarOrchestrationNode(
            id: UUID(), runId: old.runId, parentId: child.id, role: "worker", label: "Protected grandchild",
            workspaceId: fixtures.workspaceA, surfaceId: UUID(), generation: 1,
            phase: "permission-denied", availability: "idle", createdAt: now, updatedAt: now
        )
        try validate([old, child, grandchild])
        #expect(visible(tree, nodes: [old, child, grandchild]).managed == [old, child, grandchild],
                "A kept grandchild retains the full original managed ancestor chain")
        for availability: SidebarCopilotAvailability in [.waiting, .loading, .hidden, .disconnected, .unavailable] {
            var candidate = tree
            candidate.availability = availability
            #expect(visible(candidate).managed == [old])
        }
        for date: Date? in [nil, now.addingTimeInterval(-9), now.addingTimeInterval(2)] {
            var candidate = tree
            candidate.generatedAt = date
            #expect(visible(candidate).managed == [old])
        }
        var denied = tree
        denied.issues = [.permissionDenied]
        #expect(visible(denied).managed == [old])
        for observations in [
            [observation], [observation, current, current], [observation, observation, current],
            [observation, current, managedSession(id: UUID(), surface: fixtures.surfaceA, model: nil)],
            [managedSession(id: fixtures.otherSessionID, surface: fixtures.surfaceA, model: nil)],
            [observation, managedSession(id: fixtures.sessionID, surface: fixtures.surfaceA, model: nil, liveness: .ambiguous)],
            [observation, managedSession(id: fixtures.sessionID, surface: fixtures.surfaceA, model: nil, workspace: fixtures.workspaceB)]
        ] {
            var candidate = tree
            candidate.sessions = observations
            #expect(visible(candidate).managed == [old])
        }
        let sameSession = SidebarOrchestrationNode(
            id: old.id, runId: old.runId, parentId: nil, role: "coordinator", label: old.label,
            workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA, generation: 1, phase: "turn-running",
            availability: "busy", copilotSessionId: fixtures.sessionID, executionMode: .interactive,
            createdAt: now, updatedAt: now
        )
        try validate([sameSession])
        #expect(visible(tree, nodes: [sameSession]).managed == [sameSession],
                "A source-valid managed instance matching the current session is not an obsolete registration")
        let registration = managedNode(role: "coordinator", surface: fixtures.surfaceA)
        try validate([registration])
        #expect(registration.generation == 0 && registration.copilotSessionId == nil)
        #expect(SidebarPresentation.displacedManagedNodeIDs([registration], observations: tree, now: now).isEmpty)
        #expect(visible(tree, nodes: [registration]).managed == [registration],
                "Nil-ID generation-zero registration behavior stays unchanged; never fabricate provider identity")
    }

    @Test func quietMetadataUsesOnlyConciseObservedContext() {
        #expect(SidebarPresentation.rowMetadata(kind: "Agent", directory: "/synthetic/worktrees/design") == "Agent · design")
        #expect(SidebarPresentation.rowMetadata(kind: "Terminal", directory: "/synthetic/worktrees/design/") == "Terminal · design")
        #expect(SidebarPresentation.rowMetadata(kind: "Browser") == "Browser")
        #expect(SidebarPresentation.rowMetadata(kind: "Surface", directory: nil) == "Surface")
        #expect(SidebarPresentation.rowMetadata(kind: "Agent", directory: "/synthetic/design",
                                              activity: "Running a command") == "Agent · Running a command")
    }

    @Test func consolidatedCueKeepsUnknownAndIncompleteEvidenceExplicit() {
        let session = SidebarCopilotSession(
            id: UUID(), workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA,
            liveness: .unknown, state: .working, model: "synthetic-model", observedAt: now, nodes: [],
            childrenComplete: false, treeDegraded: true, omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
        #expect(SidebarPresentation.sessionStatus(session) ==
                "State unavailable. Child history incomplete; missing work is not assumed finished")
        #expect(SidebarPresentation.activityTreatment(SidebarPresentation.sessionState(session), reduceMotion: false) == .none)
        #expect(SidebarPresentation.sessionDetails(session).contains(.init(title: "Child history",
            value: "Incomplete; missing work is not assumed finished")))
    }

    @Test func focusedBorderUsesOnlyTheSelectedWorkspacesUniqueFocusedSurface() {
        let a = UUID(), b = UUID(), surfaceA = UUID(), surfaceB = UUID()
        func workspace(_ id: UUID, selected: Bool, surface: UUID) -> HierarchyWorkspace {
            .init(
                id: id, title: .available("Workspace"), detail: .unavailable,
                isSelected: .available(selected), isPinned: .available(false), unreadCount: .available(0),
                rootPath: .unavailable, projectRootPath: .unavailable,
                surfaces: .available([.init(
                    id: surface, title: "Tab", kind: .terminal, isFocused: true, isPinned: false,
                    unreadCount: 0, workingDirectory: .unavailable
                )])
            )
        }
        func hierarchy(_ workspaces: [HierarchyWorkspace]) -> HierarchySnapshot {
            .init(sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
                  workspaceMetadataAvailable: true, surfaceMetadataAvailable: true, workspacePathsAvailable: false,
                  workspaces: workspaces, windowID: UUID())
        }
        let normal = hierarchy([workspace(a, selected: true, surface: surfaceA),
                                workspace(b, selected: false, surface: surfaceB)])
        #expect(SidebarPresentation.focusedSurface(in: normal) == .surface(workspaceID: a, surfaceID: surfaceA))
        #expect(SidebarPresentation.focusedSurface(in: hierarchy([
            workspace(a, selected: true, surface: surfaceA), workspace(b, selected: true, surface: surfaceB)
        ])) == nil)
        #expect(SidebarPresentation.focusedSurface(in: hierarchy([
            workspace(a, selected: true, surface: surfaceA), workspace(b, selected: false, surface: surfaceA)
        ])) == nil)
        #expect(SidebarPresentation.focusedSurface(in: .empty) == nil)
    }

    @Test func interactiveWorkerRemainsVisibleWhenIdleAndNeverInfersActivityFromItsMode() {
        let worker = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: UUID(), role: "worker", label: "Interactive worker",
            workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA, generation: 1,
            phase: "turn-running", availability: "busy", copilotSessionId: fixtures.sessionID,
            executionMode: .interactive, createdAt: now, updatedAt: now
        )
        let session = SidebarCopilotSession(
            id: fixtures.sessionID, workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA,
            liveness: .alive, state: .idle, model: nil, observedAt: now, nodes: [],
            childrenComplete: true, treeDegraded: false, omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
        let tree = SidebarCopilotTree(availability: .ready, sessions: [session], issues: [], generatedAt: now)
        #expect(SidebarPresentation.managedState(worker, availability: .ready, now: now, tree: tree).title == "Idle")
        #expect(SidebarVisibleWork(tree: tree, managed: [worker], history: .init(), showEnded: false).managed.count == 1)
        #expect(SidebarPresentation.managedState(worker, availability: .ready, now: now).tone == .neutral)
        #expect(SidebarPresentation.managedState(worker, availability: .ready, now: now)
            .title.contains("session state unavailable"))
    }

    @Test func workspaceAttentionOmitsQuietWorkAndRoutineCompletionNotices() {
        var tree = makeTree(nodes: [node(state: .working), node(state: .idle), node(state: .completed)])
        tree.sessions[0].attention = [signal(.turnFinished)]
        let summary = SidebarPresentation.workspaceAttention(
            sessions: tree.sessions, managed: [], availability: .stale, now: now
        )
        #expect(summary.total == 0)
        #expect(summary.label == nil)
        #expect(summary.detail.isEmpty)
        #expect(SidebarPresentation.workspaceAttention(
            sessions: [], managed: [], availability: .unavailable, now: now
        ).label == nil)
    }

    @Test func workspaceAttentionCountsQuestionsAndApprovalsWithoutManagedDuplicates() {
        var tree = makeTree(nodes: [node(state: .blocked, attention: [signal(.permission)])])
        tree.sessions[0].attention = [signal(.answer)]
        let managed = managedNode(
            role: "worker", surface: fixtures.surfaceA, sessionID: fixtures.sessionID, phase: "reported-blocked"
        )
        let summary = SidebarPresentation.workspaceAttention(
            sessions: tree.sessions, managed: [managed], availability: .ready, now: now
        )
        #expect(summary.needsInput == 2)
        #expect(summary.questions == 1)
        #expect(summary.approvals == 1)
        #expect(summary.blocked == 0)
        #expect(summary.label == "2 need input")
        #expect(summary.total == 2)
    }

    @Test func workspaceAttentionKeepsLastReportedBlocksWithoutInventingAQuestion() {
        let managed = managedNode(role: "worker", surface: fixtures.surfaceA, phase: "reported-blocked")
        let summary = SidebarPresentation.workspaceAttention(
            sessions: [], managed: [managed], availability: .stale, now: now.addingTimeInterval(120)
        )
        #expect(summary.label == "1 blocked")
        #expect(summary.needsInput == 0)
        #expect(summary.questions == 0)
        #expect(summary.lastReportedBlocked == 1)
        #expect(summary.detail.contains("live state unverified"))
    }

    @Test func glyphHasTwoPointInsetsInsideItsExistingTwentyFourPointSlot() throws {
        let frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: SidebarGlyphIcon(name: "md-square", tint: .black).background(.white))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.frame = frame
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize == frame.size)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / 24
        for (x, y) in [(1.0, 12.0), (22.5, 12.0), (12.0, 1.0), (12.0, 22.5)] {
            let color = try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
            #expect(color.redComponent > 0.95 && color.greenComponent > 0.95 && color.blueComponent > 0.95)
        }
        let inner = try #require(bitmap.colorAt(x: Int(3 * scale), y: Int(12 * scale))?.usingColorSpace(.deviceRGB))
        #expect(inner.redComponent < 0.05 && inner.greenComponent < 0.05 && inner.blueComponent < 0.05)
    }

    @Test func activityIndicatorsSeparateWorkingBlockedIdleAndReducedMotion() {
        #expect(SidebarPresentation.activityTreatment(SidebarPresentation.state(.working), reduceMotion: false) == .rotatingWorking)
        #expect(SidebarPresentation.activityTreatment(SidebarPresentation.state(.working), reduceMotion: true) == .steadyWorking)
        for state: CopilotWorkState in [.blocked, .failed] {
            #expect(SidebarPresentation.activityTreatment(SidebarPresentation.state(state), reduceMotion: false) == .steadyAlert)
            #expect(SidebarPresentation.activityTreatment(SidebarPresentation.state(state), reduceMotion: true) == .steadyAlert)
        }
        for state: CopilotWorkState in [.idle, .unknown, .completed, .cancelled] {
            #expect(SidebarPresentation.activityTreatment(SidebarPresentation.state(state), reduceMotion: false) == .none)
        }
    }

    @Test func coordinatorActivityRequiresFreshUniqueOwnedCopilotEvidence() {
        let root = managedNode(role: "coordinator", surface: fixtures.surfaceA)
        let session = managedSession(id: fixtures.sessionID, surface: fixtures.surfaceA, model: nil)
        let tree = SidebarCopilotTree(availability: .ready, sessions: [session], issues: [], generatedAt: now)
        let running = SidebarPresentation.managedState(root, availability: .ready, now: now, tree: tree)
        #expect(running == SidebarPresentation.state(.working))
        let summary = SidebarPresentation.workspaceSummary(
            surfaces: [], sessions: [session], managed: [root], orchestrationAvailability: .ready,
            countsComplete: true, now: now, observations: tree
        )
        #expect(summary.agentCount == 1)
        #expect(summary.states.map(\.title) == ["Working"])
        var stale = tree
        stale.generatedAt = now.addingTimeInterval(-9)
        #expect(SidebarPresentation.managedState(root, availability: .ready, now: now, tree: stale).tone == .neutral)
        var ambiguous = tree
        ambiguous.sessions.append(managedSession(id: UUID(), surface: fixtures.surfaceA, model: nil))
        #expect(SidebarPresentation.managedState(root, availability: .ready, now: now, tree: ambiguous).tone == .neutral)
    }

    @Test func bundledNerdFontCoversCatalogAndRequestedBrowserGlyph() throws {
        let catalog = try SidebarGlyphCatalog.shared.get()
        #expect(catalog.glyphs.count == 10_994)
        #expect(catalog.glyph(named: "cod-blank") == nil)
        #expect(catalog.glyph(named: "nf-fa-edge")?.code == "f282")
        #expect(catalog.glyph(named: "browser")?.name == "fa-edge")
        #expect(catalog.glyph(named: "ghostty")?.name == "md-ghost")
        #expect(catalog.glyph(named: "nf-mdi-altimeter") == nil)
        #expect(catalog.path(for: "../../font.ttf") == nil)
        let missing = catalog.glyphs.keys.filter { catalog.path(for: $0) == nil }.sorted()
        #expect(missing.isEmpty, "Glyphs without drawable outlines: \(missing.prefix(20))")
        #expect(!SidebarAvatarColor.allCases.map(\.rawValue).contains("orange"))
    }

    @Test(arguments: [false, true])
    func renderNerdFontPresetCatalog(dark: Bool) throws {
        let catalog = try SidebarGlyphCatalog.shared.get()
        let frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
            Text("Nerd Fonts · synthetic icon preview").font(.headline)
            Text("Favorites, not limits · 10,994 searchable names · 24 pt icons").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4),
                      alignment: .leading, spacing: 16) {
                ForEach(catalog.presets) { preset in
                    HStack(spacing: 8) {
                        if preset.id == "ghostty" {
                            SidebarTerminalIcon()
                        } else if preset.id == "cli" {
                            SidebarTerminalIcon(style: .cli)
                        } else if preset.id == "browser" {
                            SidebarGlyphIcon(name: preset.glyph)
                        } else {
                            SidebarAgentIcon(
                                visual: SidebarPresentation.state(.working),
                                avatar: preset.glyph, color: preset.color
                            )
                        }
                        VStack(alignment: .leading) {
                            Text(preset.name).font(.caption)
                            Text(preset.glyph).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .background {
                        if !["ghostty", "cli", "browser"].contains(preset.id) {
                            SidebarActivityBackground(visual: SidebarPresentation.state(.working))
                        }
                    }
                }
            }
            Divider()
            Text("Runtime state · working ring rotates live; this preview is static").font(.caption.weight(.semibold))
            HStack(spacing: 20) {
                ForEach([CopilotWorkState.working, .blocked, .idle, .unknown, .failed], id: \.self) { state in
                    HStack(spacing: 6) {
                        SidebarAgentIcon(visual: SidebarPresentation.state(state), avatar: "md-robot")
                        SidebarStateBadge(visual: SidebarPresentation.state(state)).environment(\._accessibilityReduceMotion, true)
                        Text(SidebarPresentation.state(state).title).font(.caption)
                    }
                    .frame(width: 140, alignment: .leading)
                    .padding(6)
                    .background { SidebarActivityBackground(visual: SidebarPresentation.state(state)) }
                }
            }
            Text("Identity palette · state remains independent").font(.caption.weight(.semibold))
            HStack(spacing: 16) {
                ForEach(SidebarAvatarColor.allCases) { color in
                    VStack(spacing: 4) {
                        SidebarAgentIcon(visual: SidebarPresentation.state(.working), avatar: "md-bird", color: color)
                        Text(color.title).font(.caption2)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.frame = frame
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1_024)
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/sidebar-clarity/nerd-font-catalog")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent(dark ? "dark.png" : "light.png"))
    }

    @Test func iconChoicePersistsWithoutChangingWorkOrAttention() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        #expect(preferences.agentIconStyle == .maestro)
        #expect(preferences.terminalIconStyle == .ghost)
        let history = preferences.history
        let attention = preferences.attention
        let layout = preferences.layout
        preferences.agentIconStyle = .copilot
        preferences.terminalIconStyle = .cli
        #expect(fixture.preferences().agentIconStyle == .copilot)
        #expect(fixture.preferences().terminalIconStyle == .cli)
        #expect(preferences.history == history)
        #expect(preferences.attention == attention)
        #expect(preferences.layout == layout)
        #expect(try SidebarGlyphCatalog.shared.get().path(for: "oct-copilot") != nil)
    }

    @Test(arguments: [false, true])
    func compareBothAgentIconStylesAtSidebarSize(dark: Bool) throws {
        _ = try SidebarGlyphCatalog.shared.get()
        let frame = NSRect(x: 0, y: 0, width: 680, height: 380)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let rows: [(String, CopilotWorkState)] = [
            ("Orchestrator", .working), ("Implementation", .working),
            ("Waiting for input", .blocked), ("Idle agent", .idle),
            ("Unknown agent", .unknown), ("Failed agent", .failed)
        ]
        let hosting = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
            Text("Synthetic comparison · actual sidebar icon size").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 24) {
                ForEach(SidebarAgentIconStyle.allCases) { style in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(style.title).font(.headline)
                        ForEach(rows, id: \.0) { label, state in
                            HStack(spacing: 8) {
                                SidebarAgentIcon(
                                    visual: SidebarPresentation.state(state), style: style
                                )
                                Text(label).font(.caption)
                            }
                        }
                        HStack(spacing: 8) {
                            SidebarTerminalIcon()
                            Text("Terminal").font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.frame = frame
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1_024)
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/sidebar-clarity/icon-comparison")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent(dark ? "dark.png" : "light.png"))
    }

    @Test func activeOutlineHidesEndedProcessesButPreservesBlockersUnknownAndLiveAncestry() throws {
        let parent = SidebarCopilotNode(
            id: "parent", parentID: nil, depth: 0, kind: .subagent, name: "Ended parent",
            state: .completed, model: nil, ancestryUnresolved: false, hasChildren: true
        )
        let child = SidebarCopilotNode(
            id: "child", parentID: "parent", depth: 1, kind: .subagent, name: "Working child",
            state: .working, model: nil, ancestryUnresolved: false, hasChildren: false
        )
        var tree = makeTree(nodes: [parent, child, node(state: .completed), node(state: .cancelled), node(state: .unknown)])
        let ended = managedSession(id: UUID(), surface: fixtures.surfaceB, model: nil, liveness: .dead)
        tree.sessions.append(ended)
        let visible = SidebarVisibleWork(tree: tree, managed: [], history: .init(), showEnded: false)
        #expect(visible.tree.sessions.count == 1)
        #expect(visible.tree.sessions[0].nodes.map(\.id) == ["parent", "child", "unknown"])
        #expect(visible.hiddenSurfaces == [fixtures.surfaceB])
        #expect(tree.sessions.count == 2)
        #expect(SidebarVisibleWork(tree: tree, managed: [], history: .init(), showEnded: true).tree == tree)

        var protected = ended
        protected.attention = [signal(.permission)]
        tree.sessions = [protected]
        #expect(SidebarVisibleWork(tree: tree, managed: [], history: .init(), showEnded: false).tree.sessions.count == 1)
        let replacement = managedSession(id: UUID(), surface: fixtures.surfaceB, model: nil)
        tree.sessions = [ended, replacement]
        let reused = SidebarVisibleWork(tree: tree, managed: [], history: .init(), showEnded: false)
        #expect(reused.tree.sessions.map(\.id) == [replacement.id])
        #expect(reused.hiddenSurfaces.isEmpty)
    }

    @Test func readingFailureIsScopedPersistentAndDoesNotClearNewNoticesOrBlockers() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        var failure = node(state: .failed, attention: [signal(.error)])
        failure.terminalEvent = .init(id: UUID(), timestamp: now)
        let tree = makeTree(nodes: [failure, node(state: .blocked, attention: [signal(.permission)])])
        let session = try #require(tree.sessions.first)
        let target = SidebarSeenTarget.child(sessionID: session.id, childID: failure.id)
        let captured = SidebarSeenWork.capture(target, tree: tree)
        preferences.markSeen(captured, in: tree)
        #expect(preferences.attention.acknowledged == captured.notices)
        #expect(preferences.history.dismissed.isEmpty)
        let restored = fixture.preferences()
        #expect(restored.history.dismissed.isEmpty)
        var acknowledged = tree
        acknowledged.sessions[0].nodes[0].attention = []
        let visible = SidebarVisibleWork(tree: acknowledged, managed: [], history: restored.history, showEnded: false)
        #expect(visible.tree.sessions[0].nodes.map(\.id) == ["failed", "blocked"])

        var changed = tree
        changed.sessions[0].nodes[0].attention = [
            .init(kind: .error, evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: now)
        ]
        changed.sessions[0].nodes[0].terminalEvent = .init(id: UUID(), timestamp: now)
        preferences.markSeen(captured, in: changed)
        #expect(preferences.attention.acknowledged == captured.notices)
        #expect(preferences.history.dismissed.isEmpty)
        #expect(SidebarVisibleWork(tree: changed, managed: [], history: preferences.history, showEnded: false)
            .tree.sessions[0].nodes.count == 2)

        changed.sessions[0].nodes[0].attention.append(signal(.answer))
        let blocked = SidebarSeenWork.capture(target, tree: changed)
        #expect(blocked.notices.isEmpty)
        #expect(changed.sessions[0].nodes[0].dismissibleOutcome(sessionID: session.id) == nil)
    }

    @Test func managedRetirementKeepsLiveDescendantsAndDoesNotHideNewGenerations() throws {
        let root = managedNode(role: "coordinator", surface: fixtures.surfaceA)
        let failed = SidebarOrchestrationNode(
            id: UUID(), runId: root.runId, parentId: root.id, role: "worker", label: "Failed worker",
            workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceB, generation: 1,
            phase: "reported-failed", availability: "idle", createdAt: now, updatedAt: now
        )
        let key = SidebarDismissedManagedOutcome(nodeID: failed.id, generation: 1, phase: failed.phase)
        let history = SidebarHistorySettings(dismissedManaged: [key])
        let tree = makeTree(nodes: [])
        let hidden = SidebarVisibleWork(
            tree: tree, managed: [root, failed], history: history, showEnded: false
        )
        #expect(hidden.managed.map(\.id) == [root.id])
        #expect(hidden.hiddenSurfaces.contains(fixtures.surfaceB))
        #expect(SidebarVisibleWork(tree: tree, managed: [root, failed], history: history,
                                  showEnded: true).managed.count == 2)
        let next = SidebarOrchestrationNode(
            id: failed.id, runId: root.runId, parentId: root.id, role: "worker", label: failed.label,
            workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceB, generation: 2,
            phase: "turn-running", availability: "busy", createdAt: now, updatedAt: now
        )
        #expect(SidebarVisibleWork(tree: tree, managed: [root, next], history: history,
                                  showEnded: false).managed.count == 2)
        let child = SidebarOrchestrationNode(
            id: UUID(), runId: root.runId, parentId: failed.id, role: "worker", label: "Live child",
            workspaceId: fixtures.workspaceA, surfaceId: UUID(), generation: 1,
            phase: "turn-running", availability: "busy", createdAt: now, updatedAt: now
        )
        #expect(SidebarVisibleWork(tree: tree, managed: [root, failed, child], history: history,
                                  showEnded: false).managed.count == 3)
    }

    @Test func failedManagedRowsRequireExplicitDismissalAndLegacySeenFlagsAreIgnored() throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let failed = managedNode(role: "worker", surface: fixtures.surfaceA, phase: "turn-failed")
        var tree = makeTree(nodes: [])
        let outcome = try #require(SidebarPresentation.dismissibleManagedFailure(failed, tree: tree))
        let seen = SidebarSeenWork.capture(.surface(workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA), tree: tree)
        preferences.markSeen(seen, in: tree)
        #expect(preferences.history.dismissedManaged == nil)
        #expect(SidebarVisibleWork(tree: tree, managed: [failed], history: preferences.history, showEnded: false).managed.count == 1)
        preferences.dismissManaged(outcome)
        #expect(fixture.preferences().history.dismissedManaged == [outcome])
        #expect(SidebarVisibleWork(tree: tree, managed: [failed], history: preferences.history, showEnded: false).managed.isEmpty)

        let legacy: [String: Any] = [
            "version": 1, "retention": "fifteenSeconds", "dismissed": [],
            "viewedManaged": [["nodeID": failed.id.uuidString, "generation": 1, "phase": "turn-failed"]]
        ]
        let decoded = try JSONDecoder().decode(SidebarHistorySettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.dismissedManaged == nil)
        #expect(SidebarVisibleWork(tree: tree, managed: [failed], history: decoded, showEnded: false).managed.count == 1)

        tree.sessions[0].attention = [signal(.permission)]
        #expect(SidebarPresentation.dismissibleManagedFailure(failed, tree: tree) == nil)
        tree.sessions = [managedSession(id: UUID(), surface: fixtures.surfaceA, model: nil)]
        #expect(SidebarPresentation.dismissibleManagedFailure(failed, tree: tree) == nil)
    }

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

    @Test func workspaceSummaryCountsDistinctAgentsStatesAndOtherTabTypes() {
        let managedSurface = fixtures.surfaceA
        let browserSurface = fixtures.surfaceB
        let terminalSurface = UUID()
        let managed = managedNode(
            role: "worker", surface: managedSurface, sessionID: fixtures.sessionID
        )
        let managedObservation = managedSession(
            id: fixtures.sessionID, surface: managedSurface, model: nil
        )
        let unmanagedSession = SidebarCopilotSession(
            id: fixtures.otherSessionID, workspaceID: fixtures.workspaceA,
            surfaceID: terminalSurface, liveness: .alive, state: .idle, model: nil,
            observedAt: now, nodes: [
                .init(id: "agent", parentID: nil, depth: 0, kind: .subagent,
                      name: "Nested agent", state: .blocked, model: nil,
                      ancestryUnresolved: false, hasChildren: false),
                .init(id: "shell", parentID: nil, depth: 0, kind: .shell,
                      name: "Command", state: .working, model: nil,
                      ancestryUnresolved: false, hasChildren: false)
            ], childrenComplete: true, treeDegraded: false,
            omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
        let summary = SidebarPresentation.workspaceSummary(
            surfaces: [
                .init(id: managedSurface, title: "Managed", kind: .terminal,
                      isFocused: false, isPinned: false, unreadCount: 0,
                      workingDirectory: .available(nil)),
                .init(id: terminalSurface, title: "Agent", kind: .terminal,
                      isFocused: false, isPinned: false, unreadCount: 0,
                      workingDirectory: .available(nil)),
                .init(id: browserSurface, title: "Docs", kind: .browser,
                      isFocused: false, isPinned: false, unreadCount: 0,
                      workingDirectory: .available(nil))
            ],
            sessions: [managedObservation, unmanagedSession],
            managed: [managed],
            orchestrationAvailability: .ready,
            countsComplete: true,
            now: now
        )
        #expect(summary.agentCount == 3)
        #expect(summary.states.map { "\($0.title):\($0.count)" } == [
            "Working:1", "Blocked:1", "Idle:1"
        ])
        #expect(summary.tabs == [.init(kind: .browser, count: 1)])
        #expect(summary.agentLine == "3 agents · 1 working · 1 blocked · 1 idle")
        #expect(summary.tabLine == "1 browser")
        #expect(!summary.incomplete)
    }

    @Test func coalescingRequiresFreshUniqueContradictorySessionIdentity() {
        let old = managedNode(role: "coordinator", surface: fixtures.surfaceA,
                              sessionID: fixtures.otherSessionID, phase: "turn-failed")
        let current = managedSession(id: fixtures.sessionID, surface: fixtures.surfaceA, model: nil)
        let tree = SidebarCopilotTree(availability: .ready, sessions: [current], issues: [], generatedAt: now)
        func coalesced(_ candidate: SidebarCopilotTree?) -> Bool {
            SidebarPresentation.coalescingManagedNodes([old], observations: candidate, now: now) == [old]
        }
        #expect(!coalesced(tree))
        #expect(coalesced(nil))
        for availability: SidebarCopilotAvailability in [.waiting, .loading, .hidden, .disconnected, .unavailable] {
            var unavailable = tree
            unavailable.availability = availability
            #expect(coalesced(unavailable))
        }
        var partial = tree
        partial.availability = .partial
        #expect(!coalesced(partial), "Validated identity can remain available in a partial tree")
        partial.issues = [.permissionDenied]
        #expect(coalesced(partial))
        for date in [now.addingTimeInterval(-9), now.addingTimeInterval(2)] {
            var stale = tree
            stale.generatedAt = date
            #expect(coalesced(stale))
        }
        var staleObservation = tree
        staleObservation.sessions = [managedSession(
            id: fixtures.sessionID, surface: fixtures.surfaceA, model: nil, observedAt: now.addingTimeInterval(-9)
        )]
        #expect(coalesced(staleObservation))
        #expect(SidebarPresentation.coalescingManagedNodes(
            [old], observations: tree, now: now.addingTimeInterval(9)
        ) == [old])
        for liveness: CopilotLiveness in [.dead, .ambiguous, .unknown] {
            var uncertain = tree
            uncertain.sessions = [managedSession(id: fixtures.sessionID, surface: fixtures.surfaceA, model: nil, liveness: liveness)]
            #expect(coalesced(uncertain))
            uncertain.sessions.append(current)
            #expect(coalesced(uncertain), "Duplicate session identity is not unique proof")
        }
        var multiple = tree
        multiple.sessions.append(managedSession(id: UUID(), surface: fixtures.surfaceA, model: nil))
        #expect(coalesced(multiple))
        var offSurface = tree
        offSurface.sessions = [managedSession(id: fixtures.sessionID, surface: fixtures.surfaceB, model: nil)]
        #expect(coalesced(offSurface))
        var offWorkspace = tree
        offWorkspace.sessions = [managedSession(
            id: fixtures.sessionID, surface: fixtures.surfaceA, model: nil, workspace: fixtures.workspaceB
        )]
        #expect(coalesced(offWorkspace))
        var duplicatedElsewhere = tree
        duplicatedElsewhere.sessions.append(managedSession(id: fixtures.sessionID, surface: fixtures.surfaceB, model: nil))
        #expect(coalesced(duplicatedElsewhere))
        let matching = managedNode(role: "coordinator", surface: fixtures.surfaceA, sessionID: fixtures.sessionID)
        let unspecified = managedNode(role: "coordinator", surface: fixtures.surfaceA)
        #expect(SidebarPresentation.coalescingManagedNodes([matching, unspecified], observations: tree, now: now)
            == [matching, unspecified])
    }

    @Test(arguments: [CopilotWorkState.working, .idle, .blocked, .completed, .failed, .cancelled, .unknown])
    func newerObservedIdentityKeepsItsOwnRowAcrossStateTransitions(state: CopilotWorkState) throws {
        let old = managedNode(role: "coordinator", surface: fixtures.surfaceA,
                              sessionID: fixtures.otherSessionID, phase: "turn-failed")
        let tree = SidebarCopilotTree.project(
            fixtures.snapshot(sessions: [fixtures.session(state: state, now: now)], now: now),
            onto: fixtures.topology(), now: now
        )
        let visible = SidebarVisibleWork(tree: tree, managed: [old], history: .init(), showEnded: false)
        #expect(visible.managed == [old])
        #expect(visible.tree.sessions.first?.id == fixtures.sessionID)
        #expect(visible.tree.sessions.first?.state == state)
        #expect(visible.hiddenSurfaces.isEmpty)
        let surface = HierarchySurface(id: fixtures.surfaceA, title: "Same title", kind: .terminal,
                                       isFocused: false, isPinned: false, unreadCount: 0, workingDirectory: .unavailable)
        #expect(SidebarPresentation.unmanagedSurfaces(
            [surface], workspaceID: fixtures.workspaceA, managed: visible.managed,
            observations: visible.tree, now: now
        ) == [surface])
        #expect(SidebarPresentation.managedState(old, availability: .stale, now: now, tree: tree).tone == .neutral)
        let summary = SidebarPresentation.workspaceSummary(
            surfaces: [surface], sessions: visible.tree.sessions, managed: visible.managed,
            orchestrationAvailability: .stale, countsComplete: true, now: now, observations: tree
        )
        #expect(summary.agentCount == 2)
        #expect(summary.agentLine.hasPrefix("2 entries · 1 needed for context"),
                "Record totals must not claim two current sessions")
        #expect(summary.incomplete)
        let session = try #require(tree.sessions.first)
        #expect(SidebarPresentation.sessionState(session) == SidebarPresentation.state(state))
    }

    @Test func distinctObservedIdentityDoesNotAcknowledgeOrMergeRetainedAttention() {
        let old = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Retained",
            workspaceId: fixtures.workspaceA, surfaceId: fixtures.surfaceA, generation: 1,
            phase: "reported-blocked", availability: "idle", copilotSessionId: fixtures.otherSessionID,
            executionMode: .interactive, createdAt: now.addingTimeInterval(-90), updatedAt: now.addingTimeInterval(-90)
        )
        var session = managedSession(id: fixtures.sessionID, surface: fixtures.surfaceA, model: nil)
        session.attention = [signal(.permission)]
        let tree = SidebarCopilotTree(availability: .ready, sessions: [session], issues: [], generatedAt: now)
        let attention = SidebarPresentation.workspaceAttention(
            sessions: [session], managed: [old], availability: .stale, now: now, observations: tree
        )
        #expect(attention.needsInput == 1)
        #expect(attention.blocked == 1)
        #expect(attention.lastReportedBlocked == 1)
        #expect(tree.sessions.first?.attention == session.attention)
    }

    @Test(arguments: [CopilotWorkState.working, .idle])
    func retainedObservedIdentityCountsOnceAlongsideItsLiveReplacement(state: CopilotWorkState) {
        let old = managedNode(role: "coordinator", surface: fixtures.surfaceA,
                              sessionID: fixtures.otherSessionID, phase: "reported-blocked")
        var ended = managedSession(id: fixtures.otherSessionID, surface: fixtures.surfaceA,
                                   model: nil, liveness: .dead)
        ended.attention = [signal(.answer)]
        var current = SidebarCopilotSession(
            id: fixtures.sessionID, workspaceID: fixtures.workspaceA, surfaceID: fixtures.surfaceA,
            liveness: .alive, state: state, model: nil, observedAt: now, nodes: [],
            childrenComplete: true, treeDegraded: false, omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
        current.attention = [signal(.permission)]
        let tree = SidebarCopilotTree(availability: .ready, sessions: [ended, current], issues: [], generatedAt: now)
        let visible = SidebarVisibleWork(tree: tree, managed: [old], history: .init(), showEnded: true)
        let summary = SidebarPresentation.workspaceSummary(
            surfaces: [], sessions: visible.tree.sessions, managed: visible.managed,
            orchestrationAvailability: .ready, countsComplete: true, now: now, observations: tree
        )
        #expect(summary.agentCount == 2)
        #expect(summary.states.map { "\($0.title):\($0.count)" } ==
                (state == .working ? ["Working:1", "Blocked:1"] : ["Blocked:1", "Idle:1"]))
        let attention = SidebarPresentation.workspaceAttention(
            sessions: visible.tree.sessions, managed: visible.managed,
            availability: .ready, now: now, observations: tree
        )
        print("R117 identity state=\(state.rawValue) agents=\(summary.agentCount) "
              + "states=\(summary.states.map { "\($0.title):\($0.count)" }) "
              + "needsInput=\(attention.needsInput) otherBlocked=\(attention.blocked)")
        #expect(attention.needsInput == 2)
        #expect(attention.questions == 1 && attention.approvals == 1)
        #expect(attention.blocked == 0, "The old question belongs to the old managed block, not a third agent")
        #expect(visible.managed == [old] && visible.tree == tree)
    }

    @Test func retainedHistoryPlacementPreservesUncertainEvidenceFallbacks() {
        let old = managedNode(role: "coordinator", surface: fixtures.surfaceA,
                              sessionID: fixtures.otherSessionID, phase: "turn-failed")
        let ended = managedSession(id: fixtures.otherSessionID, surface: fixtures.surfaceA,
                                   model: nil, liveness: .dead)
        let current = managedSession(id: fixtures.sessionID, surface: fixtures.surfaceA, model: nil)
        let tree = SidebarCopilotTree(availability: .ready, sessions: [ended, current], issues: [], generatedAt: now)
        func placements(_ observations: SidebarCopilotTree?) -> [SidebarSessionPlacement] {
            SidebarPresentation.sessionPlacements([ended, current], managed: [old],
                                                   observations: observations, now: now)
        }
        #expect(placements(tree).map(\.managedNodeID) == [old.id, nil])
        #expect(placements(tree).map(\.retainsContents) == [true, false])
        var cases: [(String, SidebarCopilotTree?)] = [("missing", nil)]
        for availability: SidebarCopilotAvailability in [.waiting, .loading, .hidden, .disconnected, .unavailable] {
            var unavailable = tree
            unavailable.availability = availability
            cases.append(("\(availability)", unavailable))
        }
        for date: Date? in [nil, now.addingTimeInterval(-9), now.addingTimeInterval(2)] {
            var stale = tree
            stale.generatedAt = date
            cases.append(("missing/stale/future snapshot", stale))
        }
        var denied = tree
        denied.availability = .partial
        denied.issues = [.permissionDenied]
        cases.append(("denied", denied))
        for liveness: CopilotLiveness in [.unknown, .ambiguous, .dead] {
            var uncertain = tree
            uncertain.sessions = [ended, managedSession(
                id: fixtures.sessionID, surface: fixtures.surfaceA, model: nil, liveness: liveness
            )]
            cases.append(("\(liveness)", uncertain))
        }
        var stale = tree
        stale.sessions = [ended, managedSession(id: fixtures.sessionID, surface: fixtures.surfaceA,
                                               model: nil, observedAt: now.addingTimeInterval(-9))]
        cases.append(("stale observation", stale))
        var future = tree
        future.generatedAt = now.addingTimeInterval(-2)
        cases.append(("observation later than snapshot", future))
        var wrongWorkspace = tree
        wrongWorkspace.sessions = [ended, managedSession(id: fixtures.sessionID, surface: fixtures.surfaceA,
                                                        model: nil, workspace: fixtures.workspaceB)]
        cases.append(("wrong workspace", wrongWorkspace))
        var wrongSurface = tree
        wrongSurface.sessions = [ended, managedSession(id: fixtures.sessionID, surface: fixtures.surfaceB, model: nil)]
        cases.append(("wrong surface", wrongSurface))
        var ambiguous = tree
        ambiguous.sessions.append(managedSession(id: UUID(), surface: fixtures.surfaceA, model: nil))
        cases.append(("multiple live candidates", ambiguous))
        var duplicate = tree
        duplicate.sessions.append(managedSession(id: fixtures.sessionID, surface: fixtures.surfaceB, model: nil))
        cases.append(("duplicate live identity", duplicate))
        for (name, candidate) in cases {
            let result = placements(candidate)
            #expect(result.map(\.managedNodeID) == [old.id, old.id], "Preserve surface fallback: \(name)")
            #expect(result.allSatisfy { !$0.retainsContents }, "No new identity attachment from \(name)")
        }
        var partial = tree
        partial.availability = .partial
        #expect(placements(partial).map(\.managedNodeID) == [old.id, nil])
        var duplicateHistory = tree
        duplicateHistory.sessions.append(managedSession(
            id: fixtures.otherSessionID, surface: fixtures.surfaceB, model: nil, liveness: .dead
        ))
        #expect(placements(duplicateHistory).allSatisfy { $0.managedNodeID == nil && !$0.retainsContents },
                "Do not attach a duplicated historical identity")
    }

    @Test func workspaceSummaryKeepsStaleAndUnknownEvidenceExplicit() {
        let managed = managedNode(role: "worker", surface: fixtures.surfaceA)
        let unknown = managedSession(
            id: fixtures.sessionID, surface: fixtures.surfaceB, model: nil,
            liveness: .ambiguous
        )
        let summary = SidebarPresentation.workspaceSummary(
            surfaces: [], sessions: [unknown], managed: [managed],
            orchestrationAvailability: .stale, countsComplete: false, now: now
        )
        #expect(summary.agentCount == 2)
        #expect(summary.states.map { "\($0.title):\($0.count)" } == ["Unknown:2"])
        #expect(summary.incomplete)
        #expect(summary.agentLine.contains("counts incomplete"))
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

    @Test func commandActivityIsFoldedOnlyIntoItsExactOwnerWithoutHidingProblems() throws {
        func shell(_ id: String, parent: String? = nil, state: CopilotWorkState = .working,
                   attention: [AgentAttention] = []) -> SidebarCopilotNode {
            .init(id: id, parentID: parent, depth: parent == nil ? 0 : 1, kind: .shell,
                  name: "bash invocation", state: state, model: nil, ancestryUnresolved: false,
                  hasChildren: false, attention: attention)
        }
        let nodes: [SidebarCopilotNode] = [
            shell("first"), shell("second"),
            .init(id: "owner", parentID: nil, depth: 0, kind: .subagent, name: "Worker",
                  state: .working, model: nil, ancestryUnresolved: false, hasChildren: true),
            shell("child", parent: "owner"),
            shell("blocked", state: .blocked), shell("failed", state: .failed),
            shell("attention", attention: [signal(.permission)]),
            shell("unresolved", parent: "missing"),
            shell("ancestor"),
            .init(id: "descendant", parentID: "ancestor", depth: 1, kind: .subagent, name: "Nested worker",
                  state: .working, model: nil, ancestryUnresolved: false, hasChildren: false)
        ]
        let session = try #require(makeTree(nodes: nodes).sessions.first)
        #expect(session.foldedShellIDs == ["first", "second", "child"])
        #expect(session.foldedShellCount(parentID: nil) == 2)
        #expect(session.foldedShellCount(parentID: "owner") == 1)
        #expect(session.foldedShellCount(parentID: "different-owner") == 0)
        #expect(session.outlineNodes.map(\.id) == [
            "owner", "blocked", "failed", "attention", "unresolved", "ancestor", "descendant"
        ])
        #expect(session.secondaryActivity.map(\.id) == ["first", "second", "child"])
        #expect(session.nodes == nodes)
    }

    @Test func activityCaptionsAreConciseAndKeepRawProducerEvidenceSeparate() {
        let shell = AgentActivity(kind: .executing, summary: "Executing tool: bash", lastEventAt: now)
        #expect(SidebarPresentation.activityCaption(shell) == "Running a command")
        #expect(SidebarPresentation.activityCaption(shell, runningShells: 2) == "Running 2 commands")
        #expect(shell.summary == "Executing tool: bash")
        let read = AgentActivity(kind: .executing, summary: "Executing tool: view", lastEventAt: now)
        #expect(SidebarPresentation.activityCaption(read, runningShells: 1) == "Reading files · 1 command")
        #expect(SidebarPresentation.activityCaption(
            .init(kind: .idle, summary: "Last completed tool: bash", lastEventAt: now)
        ) == nil)
        #expect(SidebarPresentation.activityCaption(
            .init(kind: .executing, summary: "unverified prompt text", lastEventAt: now)
        ) == nil)
        #expect(SidebarPresentation.activityCaption(nil, runningShells: 1) == "Running a command")
    }

    @Test func statusGlyphsUseOneFamilyWithoutRelyingOnColorAlone() {
        let states: [CopilotWorkState] = [.working, .idle, .blocked, .completed, .failed, .cancelled, .unknown]
        let visuals = states.map(SidebarPresentation.state)
        #expect(Set(visuals.map(\.symbol)).count == states.count)
        #expect(Set(visuals.map(\.title)).count == states.count)
        #expect(visuals.allSatisfy { $0.symbol.contains("circle") })
        for visual in visuals + [.alive, .dead, .ambiguous, .unknown].map(SidebarPresentation.process) {
            #expect(NSImage(systemSymbolName: visual.symbol, accessibilityDescription: visual.title) != nil)
        }
        #expect(visuals.filter { $0.tone == .green } == [SidebarPresentation.state(.working)])
        #expect(SidebarPresentation.state(.working).symbol == "circle.fill")
        #expect(SidebarPresentation.state(.idle).symbol == "circle")
        #expect(SidebarPresentation.state(.unknown).symbol == "circle.dashed")
        #expect(SidebarPresentation.state(.completed).tone == .neutral)
        #expect(SidebarPresentation.state(.failed).tone == .red)
        #expect(SidebarPresentation.state(.blocked).tone == .red)
        #expect(SidebarPresentation.state(.unknown).tone == .neutral)
        #expect(SidebarPresentation.process(.alive).tone == .neutral)
        #expect(SidebarPresentation.process(.dead).title == "Process ended")
        #expect(SidebarPresentation.process(.dead).symbol != SidebarPresentation.state(.completed).symbol)
    }

    @Test func managedAndObservedWorkUseTheSameStatusGlyphs() {
        let phases: [(String, CopilotWorkState)] = [
            ("turn-running", .working), ("reported-blocked", .blocked),
            ("reported-completed", .completed), ("reported-failed", .failed),
            ("permission-denied", .blocked)
        ]
        for (phase, state) in phases {
            let node = managedNode(role: "worker", surface: fixtures.surfaceA, phase: phase)
            let managed = SidebarPresentation.managedState(node, availability: .ready, now: now)
            #expect(managed.symbol == SidebarPresentation.state(state).symbol)
            #expect(managed.tone == SidebarPresentation.state(state).tone)
        }
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
    func statusGlyphPaletteRendersInLightAndDark(dark: Bool) throws {
        let states: [CopilotWorkState] = [.working, .blocked, .completed, .failed, .idle, .cancelled, .unknown]
        let frame = NSRect(x: 0, y: 0, width: 349, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            Text("Visual key").font(.headline)
            HStack {
                SidebarAgentIcon(visual: SidebarPresentation.state(.working))
                Text("Agent · Working")
            }
            HStack {
                SidebarAgentIcon(visual: SidebarPresentation.state(.working))
                Text("Orchestrator · Working")
            }
            HStack {
                SidebarTerminalIcon()
                Text("Terminal")
            }
            ForEach(states, id: \.self) { state in
                HStack {
                    SidebarStateBadge(visual: SidebarPresentation.state(state))
                    Text(SidebarPresentation.state(state).title)
                }
            }
            SidebarStateBadge(visual: SidebarPresentation.process(.dead))
            Text("Synthetic Git changes").font(.caption)
            GitChangeBadge(changes: .init(files: 3, insertions: 42, deletions: 7, untrackedFiles: 1, binaryFiles: 0))
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
        var greenPixels = 0
        var redPixels = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.greenComponent > color.redComponent + 0.12 { greenPixels += 1 }
                if color.redComponent > color.greenComponent + 0.12 { redPixels += 1 }
                if max(color.redComponent, color.greenComponent, color.blueComponent)
                    - min(color.redComponent, color.greenComponent, color.blueComponent) > 0.15 {
                    coloredPixels += 1
                }
            }
        }
        #expect(coloredPixels > 0)
        #expect(greenPixels > 10)
        #expect(redPixels > 10)
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
        #expect(!source.contains(".orange"))
        #expect(!source.contains("Text(\"Copilot agent\")"))
        #expect(source.contains("agentGlyph: node.iconId, agentColor: node.iconColor"))
        #expect(!source.contains("isOrchestrating:"))
        #expect(source.contains("dismiss-managed-"))
        #expect(source.contains("Image(systemName: surface.kind.symbolName)"))
        #expect(source.contains("else if surface.kind == .terminal"))
        #expect(source.contains("kind: .terminal, target: .surface(surface.id)"))
        #expect(NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Worktree") != nil)
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
            #expect(!label.contains("SidebarItemIcon"))
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
        role: String, surface: UUID, sessionID: UUID? = nil, phase: String? = nil
    ) -> SidebarOrchestrationNode {
        SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: role == "worker" ? UUID() : nil,
            role: role, label: "Same name", workspaceId: fixtures.workspaceA,
            surfaceId: surface, generation: role == "worker" ? 1 : 0,
            phase: phase ?? (role == "worker" ? "turn-running" : "registered"),
            availability: role == "worker" ? "busy" : "active",
            copilotSessionId: sessionID, createdAt: now, updatedAt: now
        )
    }

    private func managedSession(
        id: UUID, surface: UUID, model: String?, liveness: CopilotLiveness = .alive,
        workspace: UUID? = nil, observedAt: Date? = nil
    ) -> SidebarCopilotSession {
        SidebarCopilotSession(
            id: id, workspaceID: workspace ?? fixtures.workspaceA, surfaceID: surface,
            liveness: liveness, state: .working, model: model, observedAt: observedAt ?? now,
            nodes: [], childrenComplete: true, treeDegraded: false,
            omittedChildrenCount: 0, omittedActiveChildrenCount: 0
        )
    }
}
