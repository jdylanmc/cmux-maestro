import AppKit
import SwiftUI
import Testing

// Synthetic hosted AppKit evidence, not installed CMUX, system focus, or pointer-routing proof.
@MainActor
@Suite(SidebarAppKitTestScope())
struct SidebarRowLiftTests {
    @Test(arguments: [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown])
    func pointerInputClearsKeyboardLiftWithoutMovingTheFirstResponder(_ pointerType: NSEvent.EventType) throws {
        let window = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentLayoutRect)
        let anchor = SidebarRowMenuAnchorView(frame: NSRect(x: 0, y: 60, width: 300, height: 46))
        let presenter = SidebarRowMenuPresenter()
        presenter.liftEligible = true
        presenter.anchor = anchor
        anchor.presenter = presenter
        var transitions: [Bool] = []
        presenter.liftFocusChanged = { transitions.append($0) }
        root.addSubview(anchor)
        let title = SidebarTitleNativeButton(frame: NSRect(x: 40, y: 68, width: 180, height: 30))
        let icon = SidebarIconNativeButton()
        icon.frame = NSRect(x: 8, y: 70, width: 24, height: 24)
        let overflow = SidebarTitleNativeButton(frame: NSRect(x: 266, y: 70, width: 24, height: 24))
        let disclosure = SidebarTitleNativeButton(frame: NSRect(x: 0, y: 70, width: 8, height: 24))
        let sibling = SidebarTitleNativeButton(frame: NSRect(x: 40, y: 10, width: 180, height: 30))
        let controls: [NSView] = [title, icon, overflow, disclosure, sibling]
        for control in controls { root.addSubview(control) }
        window.contentView = root
        defer { anchor.detach(); window.contentView = nil; window.close() }
        let frames = root.subviews.map(\.frame)
        var activations = 0
        title.activate = { activations += 1 }
        icon.activate = { activations += 1 }

        try #require(window.makeFirstResponder(title))
        anchor.refreshKeyboardFocus()
        #expect(!anchor.keyboardFocused, "A first responder alone is not keyboard-visible focus")
        anchor.observeInput(try keyEvent(window))
        #expect(anchor.keyboardFocused && transitions == [true])
        let crossing: [NSView] = [icon, title, overflow, disclosure, title]
        for control in crossing {
            try #require(window.makeFirstResponder(control))
            anchor.refreshKeyboardFocus()
            #expect(anchor.keyboardFocused, "Every control belongs to the same row-owned lift")
            #expect(transitions == [true], "Crossing inner controls must not restart the lift")
        }

        anchor.observeInput(try pointerEvent(window, type: pointerType, point: NSPoint(x: 50, y: 80)))
        #expect(!anchor.keyboardInteraction && !anchor.keyboardFocused)
        #expect(window.firstResponder === title, "Decorative modality sampling must not move focus")
        anchor.refreshKeyboardFocus()
        #expect(transitions == [true, false], "Pointer-selected first responder must not stick")
        anchor.observeInput(try keyEvent(window))
        #expect(anchor.keyboardFocused && transitions == [true, false, true])
        try #require(window.makeFirstResponder(sibling))
        anchor.refreshKeyboardFocus()
        #expect(!anchor.keyboardFocused)
        #expect(anchor.hitTest(NSPoint(x: 50, y: 80)) == nil)
        #expect(root.subviews.map(\.frame) == frames)
        #expect(title.focusRingType == .exterior && icon.focusRingType == .exterior)
        #expect(!title.isBordered && !icon.isBordered)
        #expect(activations == 0 && !window.isVisible)
    }

    @Test func focusSamplingRejectsExcludedHiddenClippedForeignAndDetachedControls() throws {
        let window = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        let foreign = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        foreign.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentLayoutRect)
        let anchor = SidebarRowMenuAnchorView(frame: NSRect(x: 0, y: 0, width: 200, height: 46))
        let presenter = SidebarRowMenuPresenter()
        presenter.anchor = anchor
        anchor.presenter = presenter
        let title = SidebarTitleNativeButton(frame: NSRect(x: 20, y: 8, width: 100, height: 30))
        root.addSubview(anchor)
        root.addSubview(title)
        window.contentView = root
        defer { anchor.detach(); window.contentView = nil; window.close(); foreign.close() }
        try #require(window.makeFirstResponder(title))
        anchor.observeInput(try keyEvent(window))
        #expect(!anchor.keyboardFocused && !anchor.keyboardInteraction, "Excluded rows never acquire lift state")
        presenter.liftEligible = true
        anchor.observeInput(try keyEvent(foreign))
        #expect(!anchor.keyboardInteraction, "Another window's input is not row input")
        anchor.observeInput(try keyEvent(window))
        try #require(anchor.keyboardFocused)
        anchor.observeInput(try pointerEvent(foreign, point: .zero))
        #expect(anchor.keyboardFocused, "Unrelated window input does not alter this row's modality")
        title.isHidden = true
        anchor.refreshKeyboardFocus()
        #expect(!anchor.keyboardFocused)
        title.isHidden = false
        title.frame.origin.x = 150
        anchor.refreshKeyboardFocus()
        #expect(!anchor.keyboardFocused, "Partially overlapping controls are not contained by this row")
        title.frame.origin.x = 20
        anchor.refreshKeyboardFocus()
        try #require(anchor.keyboardFocused)
        window.reportsKeyState = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!anchor.keyboardFocused)
        window.reportsKeyState = true
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(anchor.keyboardFocused)
        presenter.liftEligible = false
        anchor.refreshKeyboardFocus()
        #expect(!anchor.keyboardFocused, "Eligibility changes must clear an existing lift")
        anchor.detach()
        #expect(anchor.presenter == nil && presenter.anchor == nil)
        #expect(!anchor.keyboardFocused && !anchor.keyboardInteraction)
        #expect(!window.isVisible && !foreign.isVisible)
    }

    @Test(arguments: Appearance.allCases, [240, 350])
    func productionRowsPreserveGeometryAndPassiveStateAcrossNativeAppearances(
        appearance: Appearance, width: Int
    ) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.setRetention(.never)
        let data = Fixture()
        preferences.setIcon(.init(glyph: "md-robot", color: .purple), for: .session(data.observedSession))
        let model = await makeModel(data)
        defer { model.setVisible(false) }
        for density in SidebarDensity.allCases {
            preferences.setDensity(density)
            let mounted = mount(model, preferences, width: width, appearance: appearance, now: data.now)
            defer { unmount(mounted) }
            await sidebarEventually {
                mounted.host.layoutSubtreeIfNeeded()
                return model.copilot.tree.sessions.count == data.observations.count
                    && titles(mounted.host).contains { $0.accessibilityLabel() == "Focus Lift managed" }
            }
            let controls = titles(mounted.host)
            let anchors = descendants(mounted.host).compactMap { $0 as? SidebarRowMenuAnchorView }
            let surfaces = try #require(data.hierarchy.workspaces.first?.surfaces)
            guard case .available(let rows) = surfaces else {
                Issue.record("Synthetic surface fixture must remain available")
                return
            }
            for row in rows where row.id != data.managedSurface && row.id != data.legacySurface {
                let title = try #require(controls.first { $0.accessibilityLabel() == "Focus \(row.kind.title) \(row.title)" })
                let owners = owners(of: title, in: anchors)
                try #require(owners.count == 1, "A full row has exactly one native row owner")
                let eligible = [.terminal, .browser, .agentSession].contains(row.kind)
                #expect(owners[0].presenter?.liftEligible == eligible, "Actual native kind \(row.kind.rawValue)")
            }
            let managed = try #require(controls.first { $0.accessibilityLabel() == "Focus Lift managed" })
            #expect(try owner(of: managed, in: anchors).presenter?.liftEligible == true)
            let legacy = try #require(controls.first { $0.accessibilityLabel() == "Focus Lift legacy" })
            #expect(try owner(of: legacy, in: anchors).presenter?.liftEligible == true,
                    "A full actionable legacy worker row is eligible independently of execution mode")
            let legacyNode = try #require(model.orchestration.snapshot.nodes.first { $0.id == data.legacyNode })
            #expect(legacyNode.role == "worker" && legacyNode.executionMode == nil)
            for session in [data.multiSessionA, data.multiSessionB] {
                let label = "Focus Copilot session \(session.uuidString.prefix(8).lowercased())"
                let title = try #require(controls.first { $0.accessibilityLabel() == label })
                #expect(try owner(of: title, in: anchors).presenter?.liftEligible == true)
            }
            let retained = try #require(controls.first {
                $0.accessibilityLabel() == "Inspect context session \(data.retainedSession.uuidString.prefix(8).lowercased())"
            })
            #expect(try owner(of: retained, in: anchors).presenter?.liftEligible == false)
            for title in controls where title.accessibilityLabel()?.hasPrefix("Focus workspace") == true
                || title.accessibilityLabel()?.hasPrefix("Open parent chat") == true {
                #expect(try owner(of: title, in: anchors).presenter?.liftEligible == false)
            }
            let taskNames = descendants(mounted.host).compactMap { $0 as? NSTextField }
                .filter { $0.accessibilityIdentifier() == "internal-task-name" }
            try #require(taskNames.count == 2)
            for task in taskNames {
                #expect(owners(of: task, in: anchors).allSatisfy { $0.presenter?.liftEligible == false })
            }
            let internalSummary = try #require(controls.first {
                $0.localFocusID == "task-disclosure:\(data.observedSession):session"
            })
            #expect(owners(of: internalSummary, in: anchors).allSatisfy { $0.presenter?.liftEligible == false })

            let beforeHierarchy = model.hierarchy
            let beforeTree = model.copilot.tree
            try #require(!beforeTree.acknowledgeableOutcomes.isEmpty)
            let beforeManaged = model.orchestration.snapshot
            let beforeLayout = preferences.layout
            let beforeHistory = preferences.history
            let beforeAttention = preferences.attention
            let beforeIcons = preferences.icons
            let beforePinned = pinned(model, now: data.now)
            let beforeFrames = controls.map { mounted.host.convert($0.bounds, from: $0) }
            let iconControls = descendants(mounted.host).compactMap { $0 as? SidebarIconNativeButton }
            let iconFrames = iconControls.map { mounted.host.convert($0.bounds, from: $0) }
            let menuBefore = anchors.map { $0.presenter?.menu().items.map(\.title) }
            let rest = try capture(mounted.host)
            let eligible = anchors.filter { $0.presenter?.liftEligible == true }
            try #require(!eligible.isEmpty)
            for anchor in anchors { anchor.presenter?.hoverChanged(true) }
            await Task.yield()
            mounted.host.layoutSubtreeIfNeeded()
            let lifted = try capture(mounted.host)
            #expect(differences(rest, lifted) > 0, "The production callback must change the rendered surface")
            #expect(titles(mounted.host).map(ObjectIdentifier.init) == controls.map(ObjectIdentifier.init))
            #expect(descendants(mounted.host).compactMap { $0 as? SidebarRowMenuAnchorView }.map(ObjectIdentifier.init)
                == anchors.map(ObjectIdentifier.init))
            if appearance == .dark || appearance == .darkContrast {
                for anchor in anchors {
                    let rect = mounted.host.convert(anchor.bounds, from: anchor)
                    let point = NSPoint(x: rect.minX + 2, y: rect.midY)
                    let before = try pixel(rest, at: point, bounds: mounted.host.bounds)
                    let after = try pixel(lifted, at: point, bounds: mounted.host.bounds)
                    if anchor.presenter?.liftEligible == true {
                        #expect(after.redComponent + after.greenComponent + after.blueComponent
                            > before.redComponent + before.greenComponent + before.blueComponent,
                                "The blank leading lane of each eligible row must lighten, not merely reveal overflow")
                    } else {
                        #expect(before == after, "Excluded header/activity/utility interiors must remain unchanged")
                    }
                }
            }
            #expect(controls.map { mounted.host.convert($0.bounds, from: $0) } == beforeFrames)
            #expect(iconControls.map { mounted.host.convert($0.bounds, from: $0) } == iconFrames)
            #expect(controls.allSatisfy { !$0.isBordered && $0.focusRingType == .exterior })
            #expect(iconControls.allSatisfy { !$0.isBordered && $0.focusRingType == .exterior })
            #expect(anchors.map { $0.presenter?.menu().items.map(\.title) } == menuBefore)
            for anchor in eligible { anchor.presenter?.hoverChanged(true) }
            await Task.yield()
            #expect(differences(lifted, try capture(mounted.host)) == 0,
                    "Repeated hover input cannot add or restart another surface")
            for anchor in eligible {
                anchor.presenter?.liftFocusChanged(true)
                anchor.presenter?.hoverChanged(false)
            }
            await Task.yield()
            #expect(differences(lifted, try capture(mounted.host)) == 0,
                    "Keyboard-only focus must retain the same row elevation after the pointer leaves")
            for anchor in eligible {
                anchor.presenter?.hoverChanged(true)
                anchor.presenter?.liftFocusChanged(false)
            }
            await Task.yield()
            #expect(differences(lifted, try capture(mounted.host)) == 0,
                    "Losing keyboard focus while still hovered must not drop or double the lift")
            for anchor in anchors { anchor.presenter?.hoverChanged(false) }
            await Task.yield()
            mounted.host.layoutSubtreeIfNeeded()
            let restored = try capture(mounted.host)
            #expect(differences(rest, restored) == 0, "Leaving restores selected and resting appearance exactly")
            #expect(model.hierarchy == beforeHierarchy && model.copilot.tree == beforeTree)
            #expect(model.orchestration.snapshot == beforeManaged)
            #expect(preferences.layout == beforeLayout && preferences.history == beforeHistory)
            #expect(preferences.attention == beforeAttention && preferences.icons == beforeIcons)
            #expect(pinned(model, now: data.now) == beforePinned && model.navigation.status == .idle)
            #expect(!mounted.window.isVisible)
            try save(rest, name: "\(appearance.rawValue)-\(width)-\(density.rawValue)-rest")
            try save(lifted, name: "\(appearance.rawValue)-\(width)-\(density.rawValue)-lift")
        }
    }

    @Test func taskboardAndCollapsedInternalTasksDoNotAcquireIndependentLift() async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        preferences.setRetention(.never)
        preferences.selectedMode = .taskboard
        let data = Fixture()
        let model = await makeModel(data)
        defer { model.setVisible(false) }
        let mounted = mount(model, preferences, width: 280, appearance: .light, now: data.now)
        defer { unmount(mounted) }
        await sidebarEventually {
            mounted.host.layoutSubtreeIfNeeded()
            return titles(mounted.host).contains { $0.accessibilityLabel()?.hasPrefix("Open parent chat") == true }
        }
        let anchors = descendants(mounted.host).compactMap { $0 as? SidebarRowMenuAnchorView }
        let utility = titles(mounted.host).filter {
            $0.accessibilityLabel()?.hasPrefix("Focus Copilot session") == true
                || $0.accessibilityLabel()?.hasPrefix("Open parent chat") == true
                || $0.accessibilityLabel()?.hasPrefix("Inspect context session") == true
        }
        try #require(!utility.isEmpty)
        for title in utility { #expect(try owner(of: title, in: anchors).presenter?.liftEligible == false) }
        for name in ["Legacy shell", "Legacy skill", "Legacy unknown"] {
            let activity = try #require(utility.first {
                $0.accessibilityLabel() == "Open parent chat for \(name), Copilot \(data.observedSession.uuidString.prefix(8).lowercased())"
            })
            #expect(try owner(of: activity, in: anchors).presenter?.liftEligible == false)
        }
        preferences.setExpanded(false, for: .internalTasks(sessionID: data.observedSession))
        await sidebarEventually {
            mounted.host.layoutSubtreeIfNeeded()
            return !descendants(mounted.host).contains {
                $0.accessibilityIdentifier() == "internal-task-name"
                    && $0.identifier?.rawValue.hasPrefix("\(data.observedSession):") == true
            }
        }
        let summary = try #require(titles(mounted.host).first {
            $0.localFocusID == "task-disclosure:\(data.observedSession):session"
        })
        #expect(summary.accessibilityValue() as? String == "Collapsed")
        #expect(owners(of: summary, in: descendants(mounted.host).compactMap { $0 as? SidebarRowMenuAnchorView })
            .allSatisfy { $0.presenter?.liftEligible == false })
        #expect(model.navigation.status == .idle && preferences.attention.acknowledged.isEmpty)
    }

    @Test(arguments: Appearance.allCases)
    func reducedMotionMatchesTheStaticNativeSurfaceWithoutChangingHitGeometry(_ appearance: Appearance) throws {
        var images: [NSBitmapImageRep] = []
        for reduceMotion in [false, true] {
            let frame = NSRect(x: 0, y: 0, width: 280, height: 100)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance.nativeName)
            let host = NSHostingView(rootView: SidebarRowLiftSurface(lifted: true)
                .frame(width: 248, height: 46)
                .frame(width: 280, height: 100)
                .environment(\._accessibilityReduceMotion, reduceMotion)
                .environment(\._colorSchemeContrast, appearance.contrast)
                .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.frame = frame
            host.layoutSubtreeIfNeeded()
            #expect(host.bounds == frame && !window.isVisible)
            images.append(try capture(host))
        }
        #expect(differences(images[0], images[1]) == 0, "Reduce Motion retains the same static native highlight and shadow")
    }

    @Test func metadataCopyRemainsAnExplicitUnliftedControl() async throws {
        var copies = 0
        let frame = NSRect(x: 0, y: 0, width: 280, height: 100)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SidebarCopyableValue(value: "synthetic-session", label: "Session ID") {
            copies += 1
            return true
        })
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        let button = try #require(descendants(host).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "hover-copy-value" })
        #expect(!descendants(host).contains { $0 is SidebarRowMenuAnchorView })
        try #require(window.makeFirstResponder(button))
        #expect(copies == 0, "Merely focusing metadata must not copy or acquire a row lift")
        button.performClick(nil)
        await sidebarEventually {
            host.layoutSubtreeIfNeeded()
            return button.accessibilityValue() as? String == "Copied"
        }
        #expect(copies == 1 && !window.isVisible)
        #expect(!descendants(host).contains { $0 is SidebarRowMenuAnchorView })
    }

    @Test(arguments: [80, 140], [240, 350])
    func shortSharedRowRetainsTitleIconAndOutsideHitTargets(height: Int, width: Int) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var activations = 0
        let host = NSHostingView(rootView: SidebarRowActions(
            title: "Short row", groups: [], liftEligible: true
        ) {
            HStack(spacing: 4) {
                SidebarItemIcon(kind: .terminal, target: .surface(UUID()), title: "Short row", inspect: {})
                SidebarTitleButton(label: "Short row title", hint: "Synthetic short viewport", action: { activations += 1 }) {
                    Text("Short row title").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 46)
        }
        .padding(8)
        .frame(width: CGFloat(width), height: CGFloat(height), alignment: .top)
        .environment(preferences)
        .environment(\._accessibilityReduceMotion, true))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        let title = try #require(titles(host).first { $0.accessibilityLabel() == "Short row title" })
        let icon = try #require(descendants(host).compactMap { $0 as? SidebarIconNativeButton }.first)
        let anchor = try #require(descendants(host).compactMap { $0 as? SidebarRowMenuAnchorView }.first)
        let titleFrame = host.convert(title.bounds, from: title)
        let iconFrame = host.convert(icon.bounds, from: icon)
        let rowFrame = host.convert(anchor.bounds, from: anchor)
        try #require(host.bounds.contains(titleFrame) && host.bounds.contains(iconFrame))
        try #require(rowFrame.height == 46)
        let points = [
            NSPoint(x: titleFrame.midX, y: titleFrame.midY),
            NSPoint(x: iconFrame.midX, y: iconFrame.midY),
            NSPoint(x: rowFrame.midX, y: rowFrame.maxY + 12)
        ]
        try #require(points.allSatisfy(host.bounds.contains))
        let hitTargets = points.map { host.hitTest($0).map(ObjectIdentifier.init) }
        #expect(hitTargets[0] == ObjectIdentifier(title))
        #expect(hitTargets[1] == ObjectIdentifier(icon))
        for hovered in [true, true, false] {
            anchor.presenter?.hoverChanged(hovered)
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            #expect(host.convert(title.bounds, from: title) == titleFrame)
            #expect(host.convert(icon.bounds, from: icon) == iconFrame)
            #expect(host.convert(anchor.bounds, from: anchor) == rowFrame)
            #expect(points.map { host.hitTest($0).map(ObjectIdentifier.init) } == hitTargets,
                    "The decorative shadow cannot enlarge or intercept existing hit targets")
        }
        #expect(activations == 0 && !window.isVisible)
        title.performClick(nil)
        #expect(activations == 1, "The unchanged title remains explicitly actionable")
    }

    // Only key-state reporting is injected. Real AppKit containment, responder changes,
    // notifications and production observer callbacks run without ordering any window.
    private final class KeyboardWindow: NSWindow {
        var reportsKeyState = true
        override var isKeyWindow: Bool { reportsKeyState }
    }

    enum Appearance: String, CaseIterable, Sendable {
        case light, dark, lightContrast, darkContrast
        var nativeName: NSAppearance.Name {
            switch self {
            case .light: .aqua
            case .dark: .darkAqua
            case .lightContrast: .accessibilityHighContrastAqua
            case .darkContrast: .accessibilityHighContrastDarkAqua
            }
        }
        var contrast: ColorSchemeContrast {
            self == .lightContrast || self == .darkContrast ? .increased : .standard
        }
    }

    private struct Fixture {
        let now = Date()
        let windowID = UUID()
        let workspace = UUID()
        let managedSurface = UUID(), legacySurface = UUID(), observedSurface = UUID(), multiSurface = UUID()
        let managedSession = UUID(), legacySession = UUID(), observedSession = UUID(), multiSessionA = UUID(), multiSessionB = UUID()
        let retainedSession = UUID()
        let node = UUID()
        let legacyNode = UUID()
        let baseSurfaces = HierarchySurfaceKind.allCases.map { kind in
            HierarchySurface(id: UUID(), title: "Lift \(kind.rawValue)", kind: kind,
                             isFocused: kind == .terminal, isPinned: kind == .browser,
                             unreadCount: kind == .browser ? 2 : 0,
                             workingDirectory: .available("/synthetic/row-lift"))
        }
        var hierarchy: HierarchySnapshot {
            let additional = [
                (managedSurface, "Lift managed"), (legacySurface, "Lift legacy"),
                (observedSurface, "Lift observed"), (multiSurface, "Lift multi")
            ]
                .map { id, title in
                    HierarchySurface(id: id, title: title, kind: .terminal, isFocused: false,
                                     isPinned: false, unreadCount: 0, workingDirectory: .available("/synthetic/row-lift"))
                }
            return .init(sequence: 1, receivedSnapshot: true, workspaceListAvailable: true,
                         workspaceMetadataAvailable: true, surfaceMetadataAvailable: true, workspacePathsAvailable: true,
                         workspaces: [.init(id: workspace, title: .available("Lift workspace"), detail: .available(nil),
                                            isSelected: .available(true), isPinned: .available(false), unreadCount: .available(0),
                                            rootPath: .available("/synthetic/row-lift"), projectRootPath: .available(nil),
                                            surfaces: .available(baseSurfaces + additional))], windowID: windowID)
        }
        var observations: [CopilotSessionObservation] {
            let current: [CopilotSessionObservation] = [
                (managedSession, managedSurface), (legacySession, legacySurface), (observedSession, observedSurface),
                (multiSessionA, multiSurface), (multiSessionB, multiSurface)
            ].map { session, surface in
                let kinds: [(CopilotWorkKind, String)] = [
                    (.subagent, "Internal task"), (.shell, "Legacy shell"),
                    (.skill, "Legacy skill"), (.unknown, "Legacy unknown")
                ]
                let children: [CopilotChildWork] = session == observedSession
                    ? kinds.map { kind, name in
                            CopilotChildWork(id: name, parentID: nil, kind: kind, name: name, state: .working, model: nil)
                        } : []
                return .init(sessionID: session, surfaceID: surface, launchWorkspaceID: workspace,
                             liveness: .alive, state: session == observedSession ? .idle : .blocked,
                             model: nil, children: children, observedAt: now,
                             attention: session == observedSession ? [
                                .init(kind: .turnFinished, evidence: .init(source: "copilot.events", eventID: session),
                                      occurredAt: now)
                             ] : [])
            }
            return current + [
                .init(sessionID: retainedSession, surfaceID: managedSurface, launchWorkspaceID: workspace,
                      liveness: .dead, state: .completed, model: nil, children: [
                        .init(id: "Retained task", parentID: nil, kind: .subagent, name: "Retained task",
                              state: .completed, model: nil, terminalEvent: .init(id: retainedSession, timestamp: now))
                      ], observedAt: now)
            ]
        }
    }

    private func makeModel(_ data: Fixture) async -> SidebarConnectionModel {
        let now = data.now
        let observations = CopilotSnapshot(generatedAt: now, sessions: data.observations, issues: [], isComplete: true)
        let polling = SidebarCopilotPolling(read: neutralRead { _ in observations },
                                           pause: { try await sidebarFrozenExpiry(0) },
                                           expiryPause: sidebarFrozenExpiry, now: { now })
        let snapshot = SidebarOrchestrationSnapshot(version: 1, generatedAt: data.now, complete: true, omittedCount: 0, nodes: [
            .init(id: data.node, runId: UUID(), parentId: nil, role: "coordinator", label: "Lift managed",
                  workspaceId: data.workspace, surfaceId: data.managedSurface, generation: 1, phase: "registered",
                  availability: "active", copilotSessionId: data.managedSession, executionMode: .interactive,
                  createdAt: data.now, updatedAt: data.now),
            .init(id: data.legacyNode, runId: UUID(), parentId: nil, role: "worker", label: "Lift legacy",
                  workspaceId: data.workspace, surfaceId: data.legacySurface, generation: 1, phase: "turn-running",
                  availability: "busy", copilotSessionId: data.legacySession,
                  createdAt: data.now, updatedAt: data.now)
        ])
        let orchestration = SidebarOrchestrationPolling(read: { snapshot }, pause: { try await sidebarFrozenExpiry(0) })
        let model = SidebarConnectionModel(copilot: polling, orchestration: orchestration)
        let hierarchy = data.hierarchy
        model.replaceHierarchy(with: hierarchy)
        model.showConnected(workspaceCount: 1, surfaceCount: data.baseSurfaces.count + 4)
        let topology = SidebarTopology(hierarchy)
        polling.update(topology: topology, connected: true)
        orchestration.update(topology: topology, connected: true)
        model.navigation.update(topology: topology, connected: true, workspaceAllowed: true, surfaceAllowed: true,
                                perform: { _ in Issue.record("Row decoration must not navigate") })
        orchestration.setVisible(true)
        await sidebarEventually { orchestration.snapshot.generatedAt == data.now }
        polling.updateManagedSubjects(orchestration.snapshot)
        model.setVisible(true)
        return model
    }

    private func mount(
        _ model: SidebarConnectionModel, _ preferences: SidebarPreferences,
        width: Int, appearance: Appearance, now: Date
    ) -> (window: NSWindow, host: NSView) {
        let frame = NSRect(x: 0, y: 0, width: width, height: 1600)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance.nativeName)
        let host = NSHostingView(rootView: SidebarView(model: model, preferences: preferences)
            .environment(\.sidebarPresentationNow, { now })
            .environment(\._accessibilityReduceMotion, true)
            .environment(\._colorSchemeContrast, appearance.contrast)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func unmount(_ mounted: (window: NSWindow, host: NSView)) {
        for anchor in descendants(mounted.host).compactMap({ $0 as? SidebarHoverAnchorView }) { anchor.presenter?.detach() }
        mounted.window.contentView = nil
        mounted.window.close()
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func titles(_ view: NSView) -> [SidebarTitleNativeButton] {
        descendants(view).compactMap { $0 as? SidebarTitleNativeButton }
    }
    private func owners(of view: NSView, in anchors: [SidebarRowMenuAnchorView]) -> [SidebarRowMenuAnchorView] {
        anchors.filter { $0.bounds.contains($0.convert(view.bounds, from: view)) }
    }
    private func owner(of view: NSView, in anchors: [SidebarRowMenuAnchorView]) throws -> SidebarRowMenuAnchorView {
        let matches = owners(of: view, in: anchors)
        try #require(matches.count == 1)
        return matches[0]
    }
    private func keyEvent(_ window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "\t",
                                     charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
    }
    private func pointerEvent(
        _ window: NSWindow, type: NSEvent.EventType = .leftMouseDown, point: NSPoint
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1))
    }
    private func pinned(_ model: SidebarConnectionModel, now: Date) -> SidebarDetailContent {
        SidebarPresentation.pinnedDetails(hierarchy: model.hierarchy, connected: true, tree: model.copilot.tree,
                                          managed: model.orchestration.snapshot,
                                          availability: model.orchestration.availability, now: now)
    }
    private func capture(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    private func differences(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else {
            Issue.record("Row lift changed the capture geometry")
            return Int.max
        }
        guard lhs.bitsPerPixel == rhs.bitsPerPixel, let left = lhs.bitmapData, let right = rhs.bitmapData else {
            Issue.record("Captures must have comparable native pixel storage")
            return Int.max
        }
        let rowBytes = lhs.pixelsWide * lhs.bitsPerPixel / 8
        var changed = 0
        for y in 0..<lhs.pixelsHigh {
            for x in 0..<rowBytes where left[y * lhs.bytesPerRow + x] != right[y * rhs.bytesPerRow + x] {
                changed += 1
            }
        }
        return changed
    }
    private func pixel(_ bitmap: NSBitmapImageRep, at point: NSPoint, bounds: NSRect) throws -> NSColor {
        let x = Int((point.x - bounds.minX) * Double(bitmap.pixelsWide) / bounds.width)
        let y = Int((point.y - bounds.minY) * Double(bitmap.pixelsHigh) / bounds.height)
        try #require((0..<bitmap.pixelsWide).contains(x) && (0..<bitmap.pixelsHigh).contains(y))
        return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }
    private func save(_ bitmap: NSBitmapImageRep, name: String) throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/layout-validation/offscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent("row-lift115-\(name).png"))
    }
}
