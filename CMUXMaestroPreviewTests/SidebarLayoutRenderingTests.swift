import AppKit
import SwiftUI
import Testing

/// Offscreen synthetic SwiftUI/AppKit rendering only, not CMUX-host visual or system AX verification.
@MainActor
struct SidebarLayoutRenderingTests {
    @Test func syntheticSidebarRendersAtNarrowWidthsInBothDensitiesAndModes() async throws {
        let fixtures = SidebarTreeFixtures()
        let model = makeModel(fixtures: fixtures, longMetadata: false)
        let unmanagedBaseline = makeModel(
            fixtures: fixtures, longMetadata: false, childLimit: 0
        )
        let unmanagedOrdinary = makeModel(
            fixtures: fixtures, longMetadata: false, childLimit: 2
        )
        let commandModel = makeModel(fixtures: fixtures, longMetadata: false, shellActivity: true)
        let longModel = makeModel(fixtures: fixtures, longMetadata: true)
        let managedModel = makeManagedModel(fixtures: fixtures)
        let mixedModel = makeManagedModel(fixtures: fixtures, nodeCount: 2, mixed: true)
        defer {
            model.setVisible(false)
            unmanagedBaseline.setVisible(false)
            unmanagedOrdinary.setVisible(false)
            commandModel.setVisible(false)
            longModel.setVisible(false)
            managedModel.setVisible(false)
            mixedModel.setVisible(false)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent(".build/layout-validation/offscreen")
        let state = root.appendingPathComponent(".build/layout-tests/\(UUID())")
        defer { try? FileManager.default.removeItem(at: state) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "SidebarLayoutRenderingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SidebarPreferences(
            defaults: defaults,
            historyFile: state.appendingPathComponent("history.json"),
            attentionFile: state.appendingPathComponent("attention.json"),
            layoutStore: SidebarLayoutStore(file: .init(url: state.appendingPathComponent("layout.json")))
        )
        preferences.setRetention(.never)
        let scenarios: [(String, SidebarExpansionID?)] = [
            ("expanded", nil), ("workspace", .workspace(fixtures.workspaceA)),
            ("surface", .surface(fixtures.surfaceA)), ("session", .session(fixtures.sessionID)),
            ("child", .child("root", sessionID: fixtures.sessionID))
        ]
        for density in SidebarDensity.allCases {
            preferences.setDensity(density)
            for (name, collapsed) in scenarios {
                preferences.expandAll()
                if let collapsed { preferences.setExpanded(false, for: collapsed) }
                for width in [240, 349] {
                    preferences.selectedMode = .hierarchy
                    try await render(model: model, preferences: preferences, width: width,
                                     destination: folder.appendingPathComponent("\(density.rawValue)-\(name)-\(width).png"))
                }
            }
            preferences.selectedMode = .taskboard
            for width in [240, 349] {
                try await render(model: model, preferences: preferences, width: width,
                                 destination: folder.appendingPathComponent("\(density.rawValue)-taskboard-\(width).png"))
            }
            let additional: [(String, RenderAppearance, SidebarConnectionModel)] = [
                ("dark", .dark, model), ("increased-contrast", .increasedContrast, model),
                ("long-metadata", .light, longModel),
                ("long-metadata-dark-contrast", .darkIncreasedContrast, longModel)
            ]
            for (name, appearance, scenarioModel) in additional {
                preferences.expandAll()
                if scenarioModel === model {
                    preferences.setExpanded(false, for: .child("root", sessionID: fixtures.sessionID))
                }
                for mode in SidebarMode.allCases {
                    preferences.selectedMode = mode
                    for width in [240, 349] {
                        try await render(
                            model: scenarioModel, preferences: preferences, width: width, appearance: appearance,
                            destination: folder.appendingPathComponent("\(density.rawValue)-\(name)-\(mode.rawValue)-\(width).png")
                        )
                    }
                }
            }
        }
        preferences.setDensity(.compact)
        preferences.selectedMode = .hierarchy
        for (width, appearance) in [
            (240, RenderAppearance.light), (300, .light), (340, .light), (349, .light),
            (340, .dark), (340, .increasedContrast),
        ] {
            let metrics = try await render(
                model: managedModel, preferences: preferences, width: width, height: 600,
                appearance: appearance, managed: true, expectedSessions: 6,
                destination: folder.appendingPathComponent(
                    "managed-\(appearance.name)-\(width)x600.png"
                )
            )
            if width == 340 {
                #expect(metrics.documentHeight <= metrics.viewportHeight + 0.5)
            }
        }
        preferences.expandAll()
        let mixedImage = folder.appendingPathComponent("mixed-incomplete-outline-dark-340x940.png")
        let mixedMetrics = try await render(
            model: mixedModel, preferences: preferences, width: 340, height: 940,
            appearance: .dark, managed: true, expectedSessions: 6,
            destination: mixedImage
        )
        #expect(mixedMetrics.documentHeight <= 420)
        // Read the pixels: offscreen hosting does not expose a system accessibility tree.
        let lines = try SidebarRenderingEvidence.recognizedLines(in: mixedImage, dark: true)
        // Recognize the title lane separately: Vision otherwise joins the robot with "Coordinator".
        let titleLines = try SidebarRenderingEvidence.recognizedLines(
            in: mixedImage, dark: true, excludingLeadingFraction: 64.0 / 340.0
        )
        try JSONEncoder().encode(lines).write(to: mixedImage.appendingPathExtension("text.json"))
        for title in ["Coordinator", "Implementation", "Hierarchy recovery", "Readiness check"] {
            #expect(titleLines.filter { $0.contains(title) }.count == 1, "Expected one title-lane \(title): \(titleLines)")
        }
        for title in ["Managed workspace", "Context review"] {
            #expect(lines.filter { $0.contains(title) }.count == 1, "Expected one rendered \(title): \(lines)")
        }
        #expect(!lines.contains { $0.contains("Copilot agent") || $0.lowercased().contains("session ") })
        #expect(!lines.contains { $0.contains("counts incomplete") || $0.contains("0 agents") || $0.contains("Other tabs") })
        #expect(lines.contains { $0.contains("Agent") && $0.contains("review-worktree") })
        #expect(lines.contains { $0.contains("State unavailable") })
        #expect(lines.contains { $0.contains("Terminal") })
        #expect(!lines.contains { $0.contains("Earlier skill") || $0.contains("Branch collapsed")
            || $0.contains("Other sessions/activity") })
        let unmanagedMetrics = try await render(
            model: model, preferences: preferences, width: 340, height: 600,
            appearance: .light,
            destination: folder.appendingPathComponent("unmanaged-light-340x600.png")
        )
        #expect(unmanagedMetrics.documentWidth <= unmanagedMetrics.viewportWidth + 0.5)
        #expect(unmanagedMetrics.documentHeight <= 380)
        let unmanagedBaselineMetrics = try await render(
            model: unmanagedBaseline, preferences: preferences, width: 340, height: 600,
            appearance: .light,
            destination: folder.appendingPathComponent("unmanaged-baseline-light-340x600.png")
        )
        let ordinaryMetrics = try await render(
            model: unmanagedOrdinary, preferences: preferences, width: 340, height: 600,
            appearance: .light,
            destination: folder.appendingPathComponent("unmanaged-ordinary-light-340x600.png")
        )
        unmanagedOrdinary.setVisible(true)
        unmanagedBaseline.setVisible(true)
        await sidebarEventually {
            unmanagedOrdinary.copilot.tree.sessions.count == 1
                && unmanagedBaseline.copilot.tree.sessions.count == 1
        }
        let ordinaryNodes = unmanagedOrdinary.copilot.tree.sessions.flatMap(\.nodes)
        let fullCount = ordinaryNodes.count
        let baselineCount = unmanagedBaseline.copilot.tree.sessions.flatMap(\.nodes).count
        try #require(fullCount > baselineCount)
        #expect(fullCount == 2)
        #expect(baselineCount == 0)
        #expect(ordinaryNodes.allSatisfy { $0.attention.isEmpty && $0.state != .blocked })
        #expect(unmanagedBaselineMetrics.documentHeight < ordinaryMetrics.documentHeight)
        #expect((ordinaryMetrics.documentHeight - unmanagedBaselineMetrics.documentHeight)
                / Double(fullCount - baselineCount) <= 40)
        let commandImage = folder.appendingPathComponent("command-activity-light-340x600.png")
        let commandMetrics = try await render(
            model: commandModel, preferences: preferences, width: 340, height: 600,
            destination: commandImage
        )
        let commandLines = try SidebarRenderingEvidence.recognizedLines(in: commandImage)
        #expect(commandLines.filter { $0.contains("Running a command") }.count == 1)
        #expect(!commandLines.contains { $0.contains("Executing tool:") || $0.contains("bash invocation") })
        #expect(commandMetrics.documentHeight > unmanagedBaselineMetrics.documentHeight)
        #expect(commandMetrics.documentHeight <= unmanagedBaselineMetrics.documentHeight + 20)
    }

    @Test func managedRowsStayWithinCompactHeightBudgetAtThreeHundredWidth() async throws {
        let fixtures = SidebarTreeFixtures()
        let rootModel = makeManagedModel(fixtures: fixtures, nodeCount: 1)
        let treeModel = makeManagedModel(fixtures: fixtures, nodeCount: 5)
        defer { rootModel.setVisible(false); treeModel.setVisible(false) }
        let suite = "SidebarRootMeasure.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: state)
        }
        let preferences = SidebarPreferences(
            defaults: defaults,
            historyFile: state.appendingPathComponent("history.json"),
            attentionFile: state.appendingPathComponent("attention.json"),
            layoutStore: SidebarLayoutStore(file: .init(url: state.appendingPathComponent("layout.json")))
        )
        preferences.setDensity(.compact)
        preferences.selectedMode = .hierarchy
        await sidebarEventually { rootModel.orchestration.snapshot.nodes.count == 1 }
        await sidebarEventually { treeModel.orchestration.snapshot.nodes.count == 5 }
        func height(_ model: SidebarConnectionModel) -> Double {
            let view = NSHostingView(rootView: ManagedHierarchyContent(
                polling: model.orchestration, hierarchy: model.hierarchy,
                navigation: model.navigation, layout: preferences.layout,
                setExpanded: { _, _ in }, selectedID: .constant(nil)
            ).frame(width: 300, alignment: .leading))
            view.layoutSubtreeIfNeeded()
            return view.fittingSize.height
        }
        let rootHeight = height(rootModel)
        let treeHeight = height(treeModel)
        #expect(rootHeight <= 120)
        #expect((treeHeight - rootHeight) / 4 <= 40)
    }

    @Test func frozenManagedRenderFixtureDoesNotExpireOnWallClock() async throws {
        let model = makeManagedModel(fixtures: SidebarTreeFixtures())
        defer { model.setVisible(false) }
        await sidebarEventually { model.copilot.tree.sessions.count == 6 }
        try #require(model.copilot.tree.sessions.count == 6)
        try await Task.sleep(for: .seconds(SidebarCopilotTree.maximumAge + 0.1))
        #expect(model.copilot.tree.sessions.count == 6)
    }

    nonisolated private static func suspendFrozenClock(_: TimeInterval) async throws {
        let (ticks, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        for await _ in ticks {}
        try Task.checkCancellation()
    }

    private func makeManagedModel(
        fixtures: SidebarTreeFixtures, nodeCount: Int = 6, mixed: Bool = false
    ) -> SidebarConnectionModel {
        let workspace = fixtures.workspaceA
        let surfaces = (0..<nodeCount).map { _ in UUID() }
        let firstRun = UUID()
        let secondRun = UUID()
        let firstRootID = UUID()
        let secondRootID = UUID()
        let now = Date()
        let sessionIDs = (0..<nodeCount).map { _ in UUID() }
        let extraSurfaces = mixed ? [UUID(), UUID(), UUID()] : []
        let extraObservations: [CopilotSessionObservation] = mixed
            ? (0..<4).map { index in
                let last = index == 3
                return CopilotSessionObservation(
                    sessionID: UUID(), surfaceID: extraSurfaces[min(index, 2)],
                    launchWorkspaceID: index >= 2 ? fixtures.workspaceB : workspace,
                    liveness: last ? .alive : .unknown, state: last ? .idle : .unknown,
                    model: nil,
                    children: last ? (0..<3).map {
                        CopilotChildWork(id: "passive-\($0)", parentID: nil, kind: .skill,
                                         name: "Earlier skill \($0)", state: .unknown, model: nil)
                    } : [],
                    observedAt: now,
                    attention: last ? [.init(kind: .turnFinished, evidence: .init(
                        source: "copilot.events", eventID: UUID()
                    ), occurredAt: now)] : nil
                )
            } : []
        let labels = [
            "Coordinator", "Implementation", "Implementation",
            "Verification", "Documentation", "Release workspace"
        ]
        let phases = [
            "registered", "turn-running", "reported-blocked",
            "reported-completed", "report-missing", "registered"
        ]
        let nodes = surfaces.enumerated().map { index, surface in
            let secondWorkspace = index == 5
            let role = index == 0 || secondWorkspace ? "coordinator" : "worker"
            let parent: UUID? = index == 0 || secondWorkspace ? nil
                : index == 2 ? surfaces.count > 1 ? nil : firstRootID
                : firstRootID
            let resolvedParent = index == 2 && nodeCount > 2
                ? nil : parent
            return SidebarOrchestrationNode(
                id: index == 0 ? firstRootID : secondWorkspace ? secondRootID : UUID(),
                runId: secondWorkspace ? secondRun : firstRun,
                parentId: resolvedParent,
                role: role, label: labels[index],
                workspaceId: secondWorkspace ? fixtures.workspaceB : workspace,
                surfaceId: surface, generation: role == "coordinator" ? 0 : 1,
                phase: phases[index],
                availability: role == "coordinator" ? "active" : index == 1 ? "busy" : "idle",
                copilotSessionId: role == "worker" ? sessionIDs[index] : nil,
                worktreeLabel: secondWorkspace ? "release-worktree" : index == 0
                    ? "cmux-maestro-hierarchy-first" : "worker-\(index)",
                branchLabel: secondWorkspace ? "release/next" : index == 2
                    ? "feat/a-deliberately-long-nested-verification-branch" : "feat/worker-\(index)",
                gitEvidenceStatus: "verified", gitEvidenceAt: now,
                gitChangesStatus: "verified",
                gitChanges: .init(files: 3, insertions: 42, deletions: 7, untrackedFiles: 1, binaryFiles: 0),
                gitChangesAt: now,
                createdAt: now.addingTimeInterval(-Double(index)), updatedAt: now
            )
        }
        let nestedNodes: [SidebarOrchestrationNode]
        if nodeCount > 2 {
            let childID = nodes[1].id
            nestedNodes = nodes.enumerated().map { index, node in
                guard index == 2 else { return node }
                return SidebarOrchestrationNode(
                    id: node.id, runId: node.runId, parentId: childID,
                    role: node.role, label: node.label, workspaceId: node.workspaceId,
                    surfaceId: node.surfaceId, generation: node.generation,
                    phase: node.phase, availability: node.availability,
                    copilotSessionId: node.copilotSessionId,
                    worktreeLabel: node.worktreeLabel, branchLabel: node.branchLabel,
                    gitEvidenceStatus: node.gitEvidenceStatus,
                    gitEvidenceAt: node.gitEvidenceAt,
                    gitChangesStatus: node.gitChangesStatus, gitChanges: node.gitChanges,
                    gitChangesAt: node.gitChangesAt,
                    createdAt: node.createdAt, updatedAt: node.updatedAt
                )
            }
        } else {
            nestedNodes = nodes
        }
        let orchestration = SidebarOrchestrationPolling(
            read: {
                SidebarOrchestrationSnapshot(
                    version: 1, generatedAt: now, complete: true, omittedCount: 0, nodes: nestedNodes
                )
            },
            pause: { try await Task.sleep(for: .seconds(60)) }
        )
        let copilot = SidebarCopilotPolling(
            read: {
                _ in CopilotSnapshot(generatedAt: now, sessions: nestedNodes.map { node in
                    CopilotSessionObservation(
                        sessionID: node.copilotSessionId ?? sessionIDs[
                            surfaces.firstIndex(of: node.surfaceId)!
                        ],
                        surfaceID: node.surfaceId,
                        launchWorkspaceID: node.workspaceId,
                        liveness: .alive,
                        state: node.availability == "busy" ? .working : .idle,
                        model: node.role == "coordinator"
                            ? "coordinator-model" : "worker-model",
                        children: [], observedAt: now
                    )
                } + extraObservations, issues: mixed ? [.loadingHistory] : [], isComplete: !mixed)
            },
            pause: { try await Task.sleep(for: .seconds(60)) },
            expiryPause: Self.suspendFrozenClock,
            now: { now }
        )
        let hierarchy = HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: true, surfaceMetadataAvailable: true,
            workspacePathsAvailable: true,
            workspaces: [HierarchyWorkspace(
                id: workspace, title: .available("Managed workspace"), detail: .available(nil),
                isSelected: .available(true), isPinned: .available(false),
                unreadCount: .available(0), rootPath: .available("/synthetic/managed"),
                projectRootPath: .available("/synthetic/managed"),
                surfaces: .available(Array(surfaces.prefix(min(nodeCount, 5))).map {
                    HierarchySurface(
                        id: $0, title: "Terminal", kind: .terminal, isFocused: false,
                        isPinned: false, unreadCount: 0,
                        workingDirectory: .available("/synthetic/managed")
                    )
                } + extraSurfaces.prefix(2).enumerated().map { index, id in
                    HierarchySurface(
                        id: id, title: index == 0 ? "Hierarchy recovery" : "Readiness check",
                        kind: .terminal, isFocused: false, isPinned: false, unreadCount: 0,
                        workingDirectory: .available("/synthetic/review-worktree")
                    )
                })
            )] + (nodeCount > 5 ? [HierarchyWorkspace(
                id: fixtures.workspaceB, title: .available("Release tools"), detail: .available(nil),
                isSelected: .available(false), isPinned: .available(false),
                unreadCount: .available(0), rootPath: .available("/synthetic/release"),
                projectRootPath: .available("/synthetic/release"),
                surfaces: .available([HierarchySurface(
                    id: surfaces[5], title: "Terminal", kind: .terminal, isFocused: false,
                    isPinned: false, unreadCount: 0,
                    workingDirectory: .available("/synthetic/release")
                )])
            )] : mixed ? [HierarchyWorkspace(
                id: fixtures.workspaceB, title: .available("Context review"), detail: .available(nil),
                isSelected: .available(false), isPinned: .available(false), unreadCount: .available(0),
                rootPath: .available("/synthetic/context"), projectRootPath: .available("/synthetic/context"),
                surfaces: .available([HierarchySurface(
                    id: extraSurfaces[2], title: "Review latest changes", kind: .terminal,
                    isFocused: false, isPinned: false, unreadCount: 0,
                    workingDirectory: .available("/synthetic/context-worktree")
                )])
            )] : []),
            windowID: fixtures.windowID
        )
        let model = SidebarConnectionModel(copilot: copilot, orchestration: orchestration)
        model.replaceHierarchy(with: hierarchy)
        model.showConnected(workspaceCount: nodeCount > 5 ? 2 : 1, surfaceCount: surfaces.count)
        let topology = SidebarTopology(hierarchy)
        copilot.update(topology: topology, connected: true)
        orchestration.update(topology: topology, connected: true)
        model.navigation.update(
            topology: topology, connected: true, workspaceAllowed: true,
            surfaceAllowed: true, perform: { _ in }
        )
        model.setVisible(true)
        return model
    }

    private func makeModel(
        fixtures: SidebarTreeFixtures, longMetadata: Bool, childLimit: Int? = nil, shellActivity: Bool = false
    ) -> SidebarConnectionModel {
        let now = Date()
        let rootLabel = "Synthetic coordinator reviewing deeply nested layout and accessibility coverage"
        let childLabel = "Synthetic child verifying long metadata without losing running or blocked status"
        var children: [CopilotChildWork] = [
            .init(id: "root", parentID: nil, kind: .subagent, name: longMetadata ? rootLabel : "Same name",
                  state: .idle, model: nil)
        ]
        if longMetadata {
            children.append(.init(
                id: "nested", parentID: "root", kind: .subagent,
                name: "Synthetic nested coordinator for the deliberately long presentation fixture",
                state: .idle, model: nil
            ))
        }
        children.append(.init(
            id: "running", parentID: longMetadata ? "nested" : "root", kind: .subagent,
            name: longMetadata ? childLabel : "Same name", state: .working, model: nil
        ))
        children.append(.init(
            id: "blocked", parentID: longMetadata ? "running" : "root", kind: .subagent,
            name: longMetadata ? "Synthetic nested child waiting for an explicit permission decision" : "Synthetic waiting task",
            state: .blocked, model: nil, attention: [
                .init(kind: .permission, evidence: .init(source: "copilot.events", eventID: fixtures.otherSessionID), occurredAt: now)
            ]
        ))
        if let childLimit {
            children = Array(children.prefix(childLimit))
        }
        if shellActivity {
            children = [.init(id: "shell:command", parentID: nil, kind: .shell, name: "bash invocation",
                              state: .working, model: nil)]
        }
        let snapshot = fixtures.snapshot(sessions: [
            .init(sessionID: fixtures.sessionID, surfaceID: fixtures.surfaceA, launchWorkspaceID: fixtures.workspaceA,
                  liveness: .alive, state: .working,
                  model: longMetadata ? "synthetic-model-with-a-deliberately-long-display-name-for-narrow-layout-review" : nil,
                  children: children, observedAt: now,
                  activity: shellActivity ? .init(kind: .executing, summary: "Executing tool: bash",
                                                 lastEventAt: now) : nil)
        ], now: now)
        let polling = SidebarCopilotPolling(
            read: { _ in snapshot }, pause: { try await Task.sleep(for: .seconds(60)) },
            expiryPause: Self.suspendFrozenClock, now: { now }
        )
        let original = fixtures.hierarchy()
        let path = "/synthetic/workspaces/long-project-name/worktrees/accessible-layout/components/deeply-nested-presentation"
        let hierarchy = HierarchySnapshot(
            sequence: original.sequence, receivedSnapshot: true, workspaceListAvailable: true,
            workspaceMetadataAvailable: true, surfaceMetadataAvailable: true, workspacePathsAvailable: true,
            workspaces: original.workspaces.map { workspace in
                guard longMetadata, workspace.id == fixtures.workspaceA else { return workspace }
                return HierarchyWorkspace(
                    id: workspace.id, title: .available("Synthetic workspace with a deliberately long display title"),
                    detail: .available(nil), isSelected: .available(false), isPinned: .available(false),
                    unreadCount: .available(0), rootPath: .available(path),
                    projectRootPath: .available(path + "/project-root"),
                    surfaces: .available([
                        .init(id: fixtures.surfaceA, title: "Synthetic surface for long metadata and nested task labels",
                              kind: .terminal, isFocused: false, isPinned: false, unreadCount: 0,
                              workingDirectory: .available(path + "/project-root/feature-layout"))
                    ])
                )
            },
            windowID: fixtures.windowID
        )
        let model = SidebarConnectionModel(copilot: polling)
        model.replaceHierarchy(with: hierarchy)
        model.showConnected(workspaceCount: 2, surfaceCount: 2)
        let topology = SidebarTopology(hierarchy)
        model.navigation.update(
            topology: topology, connected: true, workspaceAllowed: true, surfaceAllowed: true, perform: { _ in }
        )
        polling.update(topology: topology, connected: true)
        model.setVisible(true)
        return model
    }

    @discardableResult
    private func render(
        model: SidebarConnectionModel, preferences: SidebarPreferences, width: Int,
        height: Int = 941, appearance: RenderAppearance = .light, managed: Bool = false,
        expectedSessions: Int = 1,
        destination: URL
    ) async throws -> SidebarRenderingEvidence.Metrics {
        // Yield between renders so unrelated asynchronous navigation tests can service their deadlines.
        try await Task.sleep(for: .milliseconds(10))
        model.setVisible(true)
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance.nativeName)
        let evidence = AppearanceEvidence()
        // The public contrast getter is read-only; this SDK-exposed backing key is test-only.
        // A high-contrast NSAppearance alone does not update SwiftUI's contrast environment.
        let view = NSHostingView(rootView: SidebarView(model: model, preferences: preferences)
            .background(AppearanceProbe(evidence: evidence).frame(width: 0, height: 0))
            .environment(\._colorSchemeContrast, appearance.contrast)
            .background(appearance.colorScheme == .dark ? Color.black : Color.white))
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        // onAppear can refresh history and clear observations; wait after mounting, for both sources.
        await sidebarEventually {
            model.copilot.tree.sessions.count == expectedSessions
                && (!managed || !model.orchestration.snapshot.nodes.isEmpty)
        }
        try #require(model.copilot.tree.sessions.count == expectedSessions)
        view.layoutSubtreeIfNeeded()
        #expect(!window.isVisible)
        // Keep logical sidebar widths unchanged while giving OCR stable Retina-resolution text.
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(evidence.colorScheme == appearance.colorScheme)
        #expect(evidence.contrast == appearance.contrast)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bitmap.pixelsWide >= width)
        #expect(bitmap.pixelsHigh >= height)
        #expect(png.count > 1_024)
        try png.write(to: destination)
        let metrics = SidebarRenderingEvidence.metrics(for: view)
        #expect(metrics.viewportHeight > 0)
        #expect(metrics.documentHeight > 0)
        #expect(metrics.documentWidth <= metrics.viewportWidth + 0.5)
        try JSONEncoder().encode(metrics).write(to: destination.deletingPathExtension().appendingPathExtension("json"))
        return metrics
    }

    private enum RenderAppearance {
        case light, dark, increasedContrast, darkIncreasedContrast

        var colorScheme: ColorScheme {
            self == .dark || self == .darkIncreasedContrast ? .dark : .light
        }

        var contrast: ColorSchemeContrast {
            self == .increasedContrast || self == .darkIncreasedContrast ? .increased : .standard
        }

        var nativeName: NSAppearance.Name {
            switch self {
            case .light: .aqua
            case .dark: .darkAqua
            case .increasedContrast: .accessibilityHighContrastAqua
            case .darkIncreasedContrast: .accessibilityHighContrastDarkAqua
            }
        }

        var name: String {
            switch self {
            case .light: "light"
            case .dark: "dark"
            case .increasedContrast: "contrast"
            case .darkIncreasedContrast: "dark-contrast"
            }
        }
    }

    private final class AppearanceEvidence {
        var colorScheme: ColorScheme?
        var contrast: ColorSchemeContrast?
    }

    private struct AppearanceProbe: NSViewRepresentable {
        let evidence: AppearanceEvidence

        func makeNSView(context: Context) -> NSView {
            evidence.colorScheme = context.environment.colorScheme
            evidence.contrast = context.environment.colorSchemeContrast
            return NSView()
        }

        func updateNSView(_ view: NSView, context: Context) {
            evidence.colorScheme = context.environment.colorScheme
            evidence.contrast = context.environment.colorSchemeContrast
        }
    }
}
