import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized, SidebarAppKitTestScope())
struct SidebarMotionTests {
    @Test(arguments: [(false, true, false, false), (false, true, true, false),
                      (true, true, false, false), (true, false, false, false),
                      (true, true, true, false), (true, false, true, false),
                      (false, true, false, true)])
    func retainedManagedIdentityDoesNotMaskNewWorkingObservation(
        _ scenario: (showEnded: Bool, expanded: Bool, protectedObservation: Bool, delayedIdle: Bool)
    ) async throws {
        let f = SidebarTreeFixtures()
        let preferenceFixture = try SidebarPreferenceFixture()
        defer { preferenceFixture.cleanup() }
        let preferences = preferenceFixture.preferences()
        let now = Date()
        let oldDate = now.addingTimeInterval(-172_800)
        let old = SidebarOrchestrationNode(
            id: UUID(), runId: UUID(), parentId: nil, role: "coordinator", label: "Retained coordinator",
            workspaceId: f.workspaceA, surfaceId: f.surfaceA, generation: 1,
            phase: "turn-failed", availability: "idle", copilotSessionId: f.otherSessionID,
            executionMode: .interactive, createdAt: oldDate, updatedAt: oldDate
        )
        let child = SidebarOrchestrationNode(
            id: UUID(), runId: old.runId, parentId: old.id, role: "worker", label: "Protected descendant",
            workspaceId: f.workspaceA, surfaceId: f.surfaceB, generation: 1,
            phase: "permission-denied", availability: "idle", copilotSessionId: UUID(),
            executionMode: .interactive, createdAt: oldDate, updatedAt: oldDate
        )
        let oldObservation = CopilotSessionObservation(
            sessionID: f.otherSessionID, surfaceID: f.surfaceA, launchWorkspaceID: f.workspaceA,
            liveness: .dead, state: .unknown, model: nil,
            children: scenario.protectedObservation ? [
                .init(id: "protected-observed", parentID: nil, kind: .subagent, name: "Protected observed child",
                      state: .blocked, model: nil)
            ] : [], observedAt: now,
            attention: scenario.protectedObservation ? [
                .init(kind: .answer, evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: now)
            ] : []
        )
        let snapshots = SidebarMotionSnapshots(f.snapshot(sessions: [
            oldObservation, f.session(state: .working, now: now)
        ], now: now))
        let poller = SidebarCopilotPolling(read: { _ in await snapshots.read() },
                                          pause: { try await Task.sleep(for: .milliseconds(10)) })
        let orchestration = SidebarOrchestrationPolling(read: {
            .init(version: 1, generatedAt: oldDate, complete: true, omittedCount: 0, nodes: [old, child])
        }, pause: { try await Task.sleep(for: .seconds(60)) })
        let model = SidebarConnectionModel(copilot: poller, orchestration: orchestration)
        let hierarchy = HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true, workspaceMetadataAvailable: true,
            surfaceMetadataAvailable: true, workspacePathsAvailable: false,
            workspaces: [.init(id: f.workspaceA, title: .available("Synthetic"), detail: .available(nil),
                              isSelected: .available(true), isPinned: .available(false), unreadCount: .available(0),
                              rootPath: .unavailable, projectRootPath: .unavailable,
                              surfaces: .available([f.surfaceA, f.surfaceB].map {
                                  .init(id: $0, title: "New observed session", kind: .terminal, isFocused: false,
                                        isPinned: false, unreadCount: 0, workingDirectory: .unavailable)
                              }))], windowID: f.windowID
        )
        model.showConnected(workspaceCount: 1, surfaceCount: 2)
        model.replaceHierarchy(with: hierarchy)
        model.navigation.update(topology: SidebarTopology(hierarchy), connected: true,
                                workspaceAllowed: true, surfaceAllowed: true,
                                perform: { _ in Issue.record("Projection must not navigate") })
        model.setVisible(true)
        defer { model.setVisible(false) }
        preferences.showEnded = scenario.showEnded
        preferences.setExpanded(true, for: .managed(old.id))
        preferences.setExpanded(scenario.expanded, for: .surface(f.surfaceA))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        await sidebarEventually { poller.tree.sessions.count == 2 && orchestration.snapshot.nodes.count == 2 }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let history = preferences.history
        for state: CopilotWorkState in [.working, .idle] {
            if state == .idle {
                if scenario.delayedIdle {
                    try await Task.sleep(for: .seconds(SidebarCopilotTree.maximumAge + 0.1))
                }
                await snapshots.replace(f.snapshot(sessions: [
                    oldObservation, f.session(state: state, now: now)
                ], now: now))
                await sidebarEventually { poller.tree.sessions.first { $0.id == f.sessionID }?.state == .idle }
            }
            await sidebarEventually {
                hosting.layoutSubtreeIfNeeded()
                return descendants(hosting).compactMap { $0 as? SidebarTitleNativeButton }.contains {
                    $0.accessibilityLabel() == "Focus Terminal New observed session"
                        && $0.toolTip?.contains(state == .working ? "Working" : "Idle") == true
                }
            }
            let rows = descendants(hosting).compactMap { $0 as? SidebarTitleNativeButton }
            let retained = rows.filter { $0.accessibilityLabel() == "Focus Retained coordinator" }
            let retainedRow = try #require(retained.first)
            let current = rows.filter { $0.accessibilityLabel() == "Focus Terminal New observed session" }
            let observedRow = try #require(current.first)
            #expect(retained.count == 1 && current.count == 1)
            #expect(!rows.contains { $0.accessibilityLabel() == "Focus Copilot session 20000000" },
                    "History must not duplicate the exact managed identity")
            #expect(rows.contains { $0.accessibilityLabel() == "Focus Protected descendant" })
            if scenario.protectedObservation {
                #expect(rows.contains {
                    $0.accessibilityLabel() == "Open parent chat for Protected observed child, Copilot 20000000"
                }, "Coalescing must preserve observed descendants without a managed equivalent")
            }
            #expect(try greenPixels(in: retainedRow) == 0, "Never borrow the new session's working state")
            #expect((try greenPixels(in: observedRow) > 0) == (state == .working),
                    "The primary production row reflects its own working-to-idle transition, even when collapsed")
            #expect(observedRow.toolTip?.contains(state == .working ? "Working" : "Idle") == true)
            if state == .idle && scenario.delayedIdle {
                let observation = try #require(poller.tree.sessions.first { $0.id == f.sessionID })
                #expect(observation.observedAt.timeIntervalSince(now) > SidebarCopilotTree.maximumAge,
                        "The delayed transition must use a new observation, not the aged fixture timestamp")
            }
            let visible = SidebarVisibleWork(tree: poller.tree, managed: [old, child],
                                             history: preferences.history, showEnded: preferences.showEnded)
            let summary = SidebarPresentation.workspaceSummary(
                surfaces: [], sessions: visible.tree.sessions, managed: visible.managed,
                orchestrationAvailability: orchestration.availability, countsComplete: true,
                now: Date(), observations: visible.tree
            )
            print("R117 history scenario=\(scenario) state=\(state.rawValue) agents=\(summary.agentCount) "
                  + "states=\(summary.states.map { "\($0.title):\($0.count)" }) "
                  + "primaryGreenPixels=\(try greenPixels(in: observedRow)) "
                  + "oldObservedRows=\(rows.filter { $0.accessibilityLabel() == "Focus Copilot session 20000000" }.count)")
            #expect(summary.agentCount == (scenario.protectedObservation ? 4 : 3))
            #expect(summary.states.first { $0.title == (state == .working ? "Working" : "Idle") }?.count == 1)
            #expect(orchestration.snapshot.nodes == [old, child], "Ownership, ancestry and generations are unchanged")
            #expect(!window.isVisible && model.navigation.status == .idle)
            #expect(preferences.attention.acknowledged.isEmpty && preferences.history == history)
        }
    }

    @Test(arguments: [(2, 340.0, SidebarDensity.compact), (2, 240.0, SidebarDensity.comfortable),
                      (8, 240.0, SidebarDensity.compact), (8, 340.0, SidebarDensity.comfortable)])
    func retainedObservedSubtreeKeepsItsManagedOwnersIndentation(
        _ scenario: (depth: Int, width: Double, density: SidebarDensity)
    ) async throws {
        let f = SidebarTreeFixtures()
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.showEnded = true
        preferences.setDensity(scenario.density)
        let now = Date()
        let oldDate = now.addingTimeInterval(-172_800)
        let runID = UUID()
        var chain: [SidebarOrchestrationNode] = []
        for depth in 0...scenario.depth {
            chain.append(.init(
                id: UUID(), runId: runID, parentId: chain.last?.id,
                role: depth == 0 ? "coordinator" : "worker", label: "Managed \(depth)",
                workspaceId: f.workspaceA, surfaceId: depth == scenario.depth ? f.surfaceA : UUID(),
                generation: 1, phase: "turn-failed", availability: "idle",
                copilotSessionId: depth == scenario.depth ? f.otherSessionID : UUID(),
                executionMode: .interactive, createdAt: oldDate.addingTimeInterval(Double(depth)), updatedAt: oldDate
            ))
        }
        let owner = try #require(chain.last)
        let root = chain[0]
        let ancestor = chain[1]
        let sibling = SidebarOrchestrationNode(
            id: UUID(), runId: runID, parentId: root.id, role: "worker", label: "Unrelated sibling",
            workspaceId: f.workspaceA, surfaceId: f.surfaceB, generation: 1,
            phase: "turn-failed", availability: "idle", copilotSessionId: UUID(),
            executionMode: .interactive, createdAt: now, updatedAt: oldDate
        )
        let managed = chain + [sibling]
        let oldObservation = CopilotSessionObservation(
            sessionID: f.otherSessionID, surfaceID: f.surfaceA, launchWorkspaceID: f.workspaceA,
            liveness: .dead, state: .unknown, model: nil, children: [
                .init(id: "nested-child", parentID: nil, kind: .subagent, name: "Observed child",
                      state: .blocked, model: nil, attention: [
                        .init(kind: .permission, evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: now)
                      ]),
                .init(id: "nested-grandchild", parentID: "nested-child", kind: .subagent, name: "Observed grandchild",
                      state: .blocked, model: nil, attention: [
                        .init(kind: .answer, evidence: .init(source: "copilot.events", eventID: UUID()), occurredAt: now)
                      ])
            ], observedAt: now
        )
        let snapshots = SidebarMotionSnapshots(f.snapshot(
            sessions: [oldObservation, f.session(state: .working, now: now)], now: now
        ))
        let poller = SidebarCopilotPolling(read: { _ in await snapshots.read() },
                                          pause: { try await Task.sleep(for: .milliseconds(10)) })
        let orchestration = SidebarOrchestrationPolling(read: {
            .init(version: 1, generatedAt: oldDate, complete: true, omittedCount: 0, nodes: managed)
        }, pause: { try await Task.sleep(for: .seconds(60)) })
        let model = SidebarConnectionModel(copilot: poller, orchestration: orchestration)
        let hierarchy = HierarchySnapshot(
            sequence: 1, receivedSnapshot: true, workspaceListAvailable: true, workspaceMetadataAvailable: true,
            surfaceMetadataAvailable: true, workspacePathsAvailable: false,
            workspaces: [.init(
                id: f.workspaceA, title: .available("Synthetic nesting"), detail: .available(nil),
                isSelected: .available(true), isPinned: .available(false), unreadCount: .available(0),
                rootPath: .unavailable, projectRootPath: .unavailable,
                surfaces: .available(managed.map {
                    .init(id: $0.surfaceId, title: "Replacement", kind: .terminal, isFocused: false,
                          isPinned: false, unreadCount: 0, workingDirectory: .unavailable)
                })
            )], windowID: f.windowID
        )
        model.showConnected(workspaceCount: 1, surfaceCount: managed.count)
        model.replaceHierarchy(with: hierarchy)
        model.navigation.update(topology: SidebarTopology(hierarchy), connected: true,
                                workspaceAllowed: true, surfaceAllowed: true,
                                perform: { _ in Issue.record("Nesting must not navigate") })
        model.setVisible(true)
        defer { model.setVisible(false) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: scenario.width, height: 1200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: SidebarView(model: model, preferences: preferences))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        await sidebarEventually { poller.tree.sessions.count == 2 && orchestration.snapshot.nodes.count == managed.count }
        func titles(_ view: NSView) -> [SidebarTitleNativeButton] {
            view.subviews.flatMap { child in
                (child as? SidebarTitleNativeButton).map { [$0] } ?? titles(child)
            }
        }
        for (ancestorExpanded, ownerExpanded) in [(true, true), (true, false), (false, true)] {
            preferences.setExpanded(ancestorExpanded, for: .managed(ancestor.id))
            preferences.setExpanded(ownerExpanded, for: .managed(owner.id))
            await sidebarEventually {
                hosting.layoutSubtreeIfNeeded()
                let rows = titles(hosting)
                return rows.contains {
                    $0.accessibilityLabel() == "Focus Terminal Replacement" && $0.toolTip?.contains("Working") == true
                } && rows.contains { $0.accessibilityLabel() == "Focus Managed \(scenario.depth)" } == ancestorExpanded
                    && rows.filter { $0.accessibilityLabel()?.hasPrefix("Open parent chat for Observed ") == true }.count
                        == (ancestorExpanded && ownerExpanded ? 2 : 0)
            }
            let rows = titles(hosting)
            let rootRow = try #require(rows.first { $0.accessibilityLabel() == "Focus Managed 0" })
            let siblingRow = try #require(rows.first { $0.accessibilityLabel() == "Focus Unrelated sibling" })
            let ownerRow = rows.first { $0.accessibilityLabel() == "Focus Managed \(scenario.depth)" }
            let observedRows = rows.filter { $0.accessibilityLabel()?.hasPrefix("Open parent chat for Observed ") == true }
            let replacement = try #require(rows.first { $0.accessibilityLabel() == "Focus Terminal Replacement" })
            let origin = hosting.convert(rootRow.bounds, from: rootRow).minX
            let step = scenario.density == .compact ? 8.0 : 10.8
            let scale = window.backingScaleFactor
            #expect(Double(hosting.convert(siblingRow.bounds, from: siblingRow).minX) == pixelAligned(origin + step, scale: scale))
            #expect(observedRows.count == (ancestorExpanded && ownerExpanded ? 2 : 0))
            #expect((ownerRow != nil) == ancestorExpanded)
            if ancestorExpanded, let ownerRow {
                let ownerX = hosting.convert(ownerRow.bounds, from: ownerRow).minX
                if ownerExpanded {
                    let child = try #require(observedRows.first { $0.accessibilityLabel()?.contains("Observed child,") == true })
                    let grandchild = try #require(observedRows.first { $0.accessibilityLabel()?.contains("Observed grandchild,") == true })
                    let childFrame = hosting.convert(child.bounds, from: child)
                    let grandchildFrame = hosting.convert(grandchild.bounds, from: grandchild)
                    let densityScale = scenario.density == .compact ? 1.0 : 1.35
                    let cap = min(32, (scenario.width - (scenario.density == .compact ? 10 : 13.5)) * 0.12)
                    let ownerIndent = min((scenario.depth == 2 ? 16.0 : 44.0) * densityScale, cap)
                    let grandchildIndent = min((scenario.depth == 2 ? 24.0 : 48.0) * densityScale, cap)
                    print("R117 nesting \(scenario) scale=\(scale) originX=\(origin) ownerX=\(ownerX) "
                          + "childX=\(childFrame.minX) grandchildX=\(grandchildFrame.minX) "
                          + "expectedOwner=\(pixelAligned(origin + ownerIndent, scale: scale)) "
                          + "expectedChild=\(pixelAligned(origin + step + ownerIndent, scale: scale))")
                    #expect(Double(ownerX) == pixelAligned(origin + ownerIndent, scale: scale))
                    #expect(Double(childFrame.minX) == pixelAligned(origin + step + ownerIndent, scale: scale))
                    #expect(Double(grandchildFrame.minX) == pixelAligned(origin + step + grandchildIndent, scale: scale))
                    #expect(grandchildFrame.minX >= childFrame.minX)
                    let renderedCap = ceil((step + cap) * window.backingScaleFactor) / window.backingScaleFactor
                    #expect(grandchildFrame.minX - origin <= renderedCap,
                            "Combined managed/session depth must be capped once, not accumulated")
                } else {
                    let ownerFrame = hosting.convert(ownerRow.bounds, from: ownerRow)
                    let siblingFrame = hosting.convert(siblingRow.bounds, from: siblingRow)
                    let rowPadding = (scenario.density.rowHeight - ownerFrame.height) / 2
                    let top = ownerFrame.maxY + rowPadding
                    let strip = NSRect(x: 0, y: top, width: scenario.width,
                                       height: siblingFrame.minY - rowPadding - top)
                    try #require(strip.height > 0, "The collapsed retained summary occupies its own row")
                    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: strip))
                    hosting.cacheDisplay(in: strip, to: bitmap)
                    var ink: [Int] = []
                    for x in 0..<bitmap.pixelsWide {
                        for y in 0..<bitmap.pixelsHigh {
                            let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                            if color.alphaComponent > 0.2
                                && max(color.redComponent, color.greenComponent, color.blueComponent) < 0.75 {
                                ink.append(x)
                                break
                            }
                        }
                    }
                    let summaryX = Double(try #require(ink.first)) * strip.width / Double(bitmap.pixelsWide)
                    print("R117 nesting collapsed \(scenario) ownerX=\(ownerX) summaryInkX=\(summaryX)")
                    #expect((ownerX - 28 - 0.5...ownerX - 28 + 4).contains(summaryX),
                            "Collapsed summary ink stays aligned with its owner, allowing glyph inset")
                }
            }
            #expect(rows.allSatisfy {
                let frame = hosting.convert($0.bounds, from: $0)
                return frame.minX >= 0 && frame.maxX <= scenario.width && frame.width >= 80
            })
            #expect(try greenPixels(in: replacement) > 0)
            let summary = SidebarPresentation.workspaceSummary(
                surfaces: [], sessions: poller.tree.sessions, managed: managed,
                orchestrationAvailability: orchestration.availability, countsComplete: true, now: Date(),
                observations: poller.tree
            )
            let attention = SidebarPresentation.workspaceAttention(
                sessions: poller.tree.sessions, managed: managed, availability: orchestration.availability,
                now: Date(), observations: poller.tree
            )
            #expect(summary.agentCount == scenario.depth + 5)
            #expect(attention.needsInput == 2 && attention.questions == 1 && attention.approvals == 1)
            #expect(orchestration.snapshot.nodes == managed && preferences.attention.acknowledged.isEmpty)
            #expect(model.navigation.status == .idle && !window.isVisible)
        }
    }

    @Test(arguments: [(1.0, 85.0, 95.0), (2.0, 84.5, 95.5)])
    func retainedGeometryMatchesIndependentlyAlignedBackingCoordinates(
        _ sample: (scale: Double, ownerX: Double, childX: Double)
    ) {
        #expect(pixelAligned(63 + 21.6, scale: sample.scale) == sample.ownerX)
        #expect(pixelAligned(63 + 21.6 + 10.8, scale: sample.scale) == sample.childX)
        #expect(pixelAligned(63 + 27.18 + 10.8, scale: sample.scale) == 101)
        #expect(pixelAligned(63 + 10.8, scale: sample.scale) != sample.childX,
                "Omitting the managed-owner indentation must still fail on either backing grid")
    }

    private func pixelAligned(_ coordinate: Double, scale: Double) -> Double {
        (coordinate * scale).rounded() / scale
    }

    private actor SidebarMotionSnapshots {
        private var snapshot: CopilotSnapshot
        init(_ snapshot: CopilotSnapshot) { self.snapshot = snapshot }
        func read() -> CopilotSnapshot {
            // Production rows use wall time; each synthetic read is a new observation.
            let now = Date()
            return .init(generatedAt: now, sessions: snapshot.sessions.map { session in
                var observation = CopilotSessionObservation(
                    sessionID: session.sessionID, surfaceID: session.surfaceID,
                    launchWorkspaceID: session.launchWorkspaceID, liveness: session.liveness,
                    state: session.state, model: session.model, children: session.children, observedAt: now,
                    attention: session.attention, activity: session.activity
                )
                observation.iconId = session.iconId
                observation.iconColor = session.iconColor
                return observation
            }, issues: snapshot.issues, isComplete: snapshot.isComplete)
        }
        func replace(_ snapshot: CopilotSnapshot) { self.snapshot = snapshot }
    }

    private func greenPixels(in row: NSView) throws -> Int {
        row.layoutSubtreeIfNeeded()
        let bitmap = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
        row.cacheDisplay(in: row.bounds, to: bitmap)
        var green = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.greenComponent > color.redComponent + 0.15
                    && color.greenComponent > color.blueComponent + 0.15 { green += 1 }
            }
        }
        return green
    }

    @Test func ringMakesOneLinearRevolutionAndReducedMotionHasNoPhaseChange() throws {
        #expect(SidebarPresentation.statusDescription(SidebarPresentation.state(.blocked), needsInput: true) == "Needs input. Blocked")
        #expect(SidebarPresentation.statusDescription(SidebarPresentation.state(.unknown)) == "Unknown")
        for (time, angle) in [(0.0, 0.0), (0.25, 90), (0.5, 180), (0.75, 270), (1, 0), (1.25, 90)] {
            let date = Date(timeIntervalSinceReferenceDate: time)
            #expect(SidebarPresentation.workingRotation(at: date, reduceMotion: false) == angle)
            #expect(SidebarPresentation.workingRotation(at: date, reduceMotion: true) == 0)
        }
    }

    @Test func nativeMotionAndStaticNegativeControlsStayInsideTheStatusLane() async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, reduceMotion, needsInput) in [
            ("working", false, false), ("reduced-motion", true, false), ("needs-input", false, true)
        ] {
            let host = NSHostingView(rootView:
                HStack {
                    SidebarStateBadge(visual: SidebarPresentation.state(.working), needsInput: needsInput)
                    Text("Synthetic status").font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 5)
                .environment(\._accessibilityReduceMotion, reduceMotion)
                .background(SidebarActivityBackground(visual: SidebarPresentation.state(.working)))
                .background(Color.white)
                .frame(width: 280, height: 40)
            )
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 40),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            let first = try capture(host, to: folder.appendingPathComponent("polish-\(name)-frame0.png"))
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let second = try capture(host, to: folder.appendingPathComponent("polish-\(name)-frame1.png"))
            #expect(!window.isVisible)
            let left = differences(first, second, columns: 0..<40)
            let rest = differences(first, second, columns: 40..<first.pixelsWide)
            #expect(rest == 0, "No row shimmer or text motion: \(name)")
            if name == "working" {
                #expect(left > 0, "The actual native working ring advances while hosted")
            } else {
                #expect(left == 0, "Static negative control: \(name)")
            }
            print("P57 native motion \(name): changedStatusPixels=\(left), changedOtherPixels=\(rest)")
        }
    }

    private func capture(_ view: NSView, to file: URL) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        try #require(view.bounds == NSRect(x: 0, y: 0, width: 280, height: 40),
                     "Both native snapshots must use the same logical viewport, not a transient intrinsic height")
        let before = view.bounds
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 560, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(view.bounds == before && bitmap.size == before.size)
        print("P57 capture \(file.lastPathComponent): before=\(before), after=\(view.bounds), bitmapSize=\(bitmap.size)")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
        return bitmap
    }

    private func differences(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, columns: Range<Int>) -> Int {
        var count = 0
        for y in 0..<a.pixelsHigh {
            for x in columns {
                if a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { count += 1 }
            }
        }
        return count
    }
}
