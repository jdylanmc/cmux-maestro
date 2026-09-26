import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized)
struct SidebarHoverTests {
    @Test(arguments: ["tab", "escape", "shift-tab"])
    func hostedPreviewKeysContinueToFollowingRow(exit: String) async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let fixture = SidebarTreeFixtures()
        let hierarchy = fixture.hierarchy()
        let navigation = SidebarNavigation()
        var selected: [SidebarNavigationTarget] = []
        var seen: [SidebarSeenTarget] = []
        var copied: [UUID] = []
        navigation.update(topology: SidebarTopology(hierarchy), connected: true,
                          workspaceAllowed: true, surfaceAllowed: true, perform: { selected.append($0) })
        let pinned = SidebarPresentation.pinnedDetails(
            hierarchy: hierarchy, connected: true, tree: .waiting, managed: .empty, availability: .ready, now: Date()
        )
        let presenter = SidebarHoverPresenter(copySessionID: { copied.append($0); return true })
        defer { presenter.detach() }
        let hosting = NSHostingView(rootView: VStack {
            FocusButton(target: .surface(workspaceID: fixture.workspaceA, surfaceID: fixture.surfaceA),
                        navigation: navigation, label: "First row") { Text("First row") }
                .environment(\.sidebarPreviewInteraction, .init(
                    available: true, focus: { presenter.keyboardFocus($0) }, enter: { presenter.enterFromKeyboard() },
                    origin: { presenter.rememberKeyboardOrigin($0) }, dismiss: { presenter.dismiss(restoreFocus: false) }
                ))
            FocusButton(target: .surface(workspaceID: fixture.workspaceB, surfaceID: fixture.surfaceB),
                        navigation: navigation, label: "Following row") { Text("Following row") }
        }.environment(\.sidebarPrepareSeen, { target in { seen.append(target) } }))
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let titles = descendants(hosting).compactMap { $0 as? SidebarTitleNativeButton }
        let origin = try #require(titles.first { $0.accessibilityLabel() == "First row" })
        let following = try #require(titles.first { $0.accessibilityLabel() == "Following row" })
        // Keep the real SwiftUI responder chain, with a deterministic next-row edge.
        window.autorecalculatesKeyViewLoop = false
        origin.nextKeyView = following
        following.nextKeyView = origin
        presenter.update(anchor: origin, data: .init(
            id: "exact-keyboard-session", category: "Agent preview", title: "First row",
            lines: [.sessionID(fixture.sessionID)]
        ), group: SidebarHoverGroup())
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        await sidebarEventually { window.isKeyWindow }
        #expect(window.makeFirstResponder(origin))
        try #require(window.isKeyWindow && presenter.state.mode == .keyboard)
        func send(_ code: UInt16, to target: NSWindow, flags: NSEvent.ModifierFlags = []) throws {
            let characters = code == 48 ? "\t" : code == 49 ? " " : "\u{1b}"
            NSApp.sendEvent(try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: target.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            )))
        }
        try send(48, to: window)
        let panel = try #require(presenter.panel)
        try #require(panel.isKeyWindow && !window.isKeyWindow && presenter.state.mode == .explicit)
        #expect((panel.firstResponder as? NSButton)?.accessibilityIdentifier() == "hover-close")
        try send(48, to: panel)
        let copy = try #require(panel.firstResponder as? NSButton)
        #expect(copy.accessibilityIdentifier() == "hover-copy-value")
        try send(49, to: panel)
        await sidebarEventually { copy.accessibilityValue() as? String == "Copied" }
        #expect(copied == [fixture.sessionID])
        if exit == "tab" {
            try send(48, to: panel)
        } else {
            try send(exit == "escape" ? 53 : 48, to: panel, flags: exit == "shift-tab" ? .shift : [])
            #expect(window.isKeyWindow && window.firstResponder === origin)
            #expect(presenter.state.mode == .hidden && !panel.isVisible)
            try send(48, to: window)
        }
        #expect(window.isKeyWindow && window.firstResponder === following)
        #expect(presenter.state.mode == .hidden && !panel.isVisible && !presenter.isMonitoring)
        #expect(selected.isEmpty && seen.isEmpty && navigation.status == .idle)
        #expect(SidebarPresentation.pinnedDetails(
            hierarchy: hierarchy, connected: true, tree: .waiting, managed: .empty, availability: .ready, now: Date()
        ) == pinned)
        print("R1 \(exit): hosted title -> key panel -> exact Copy -> following row; host/seen=0; pinned unchanged")
    }

    @Test func nativeTitleContinuesForwardAfterReturningAndReentersOnANewVisit() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 120),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 120))
        let origin = SidebarTitleNativeButton(frame: NSRect(x: 0, y: 60, width: 200, height: 30))
        let following = SidebarTitleNativeButton(frame: NSRect(x: 0, y: 20, width: 200, height: 30))
        root.addSubview(origin)
        root.addSubview(following)
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        window.autorecalculatesKeyViewLoop = false
        origin.nextKeyView = following
        following.nextKeyView = origin
        var entries = 0, activations = 0
        origin.preview = .init(enter: { entries += 1; return true })
        origin.activate = { activations += 1 }
        following.activate = { activations += 1 }
        let tab = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
        ))
        #expect(window.makeFirstResponder(origin))
        window.sendEvent(tab)
        #expect(entries == 1 && window.firstResponder === origin)
        window.sendEvent(tab)
        #expect(entries == 1 && window.firstResponder === following && activations == 0)
        #expect(window.makeFirstResponder(origin))
        window.sendEvent(tab)
        #expect(entries == 2 && activations == 0)
    }

    @Test func previewTabExitsAtLastNativeControlInsteadOfWrapping() throws {
        let panel = SidebarHoverPanel(contentRect: NSRect(x: 100, y: 100, width: 280, height: 120),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 120))
        let close = SidebarTitleNativeButton(frame: NSRect(x: 0, y: 60, width: 200, height: 30))
        let copy = SidebarTitleNativeButton(frame: NSRect(x: 0, y: 20, width: 200, height: 30))
        close.setAccessibilityIdentifier("hover-close")
        copy.setAccessibilityIdentifier("hover-copy-value")
        root.addSubview(close)
        root.addSubview(copy)
        panel.contentView = root
        panel.allowsKeyboard = true
        var exits = 0
        panel.advanceFromPreview = { exits += 1 }
        #expect(panel.focusControls() && panel.firstResponder === close)
        panel.selectNextKeyView(nil)
        #expect(panel.firstResponder === copy && exits == 0)
        panel.selectNextKeyView(nil)
        #expect(panel.firstResponder === copy && exits == 1)
    }

    @Test func nativeTabTraversesIntoExactCopyControlWithoutPressingOrReplacingOrigin() async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 200))
        let button = SidebarTitleNativeButton(frame: NSRect(x: 0, y: 150, width: 240, height: 30))
        root.addSubview(button)
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        let sessionID = UUID()
        var copied: [UUID] = []
        var pressed = 0
        let presenter = SidebarHoverPresenter(copySessionID: { copied.append($0); return true }, showPanel: { _, _, _ in })
        defer { presenter.detach() }
        presenter.update(anchor: button, data: .init(
            id: "keyboard-session", category: "Agent preview", title: "Synthetic keyboard agent",
            lines: [.sessionID(sessionID)]
        ), group: SidebarHoverGroup())
        button.activate = { pressed += 1 }
        button.preview = .init(
            available: true, focus: { presenter.keyboardFocus($0) }, enter: { presenter.enterFromKeyboard() },
            origin: { presenter.rememberKeyboardOrigin($0) }, dismiss: { presenter.dismiss(restoreFocus: false) }
        )
        #expect(window.makeFirstResponder(button))
        #expect(presenter.state.mode == .keyboard && pressed == 0 && copied.isEmpty)
        func key(_ code: UInt16, in target: NSWindow, characters: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: target.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ))
        }
        button.keyDown(with: try key(48, in: window, characters: "\t"))
        let panel = try #require(presenter.panel)
        #expect(presenter.state.mode == .explicit && panel.canBecomeKey)
        panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let panelContent = try #require(panel.contentView)
        let copy = try #require(descendants(panelContent).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "hover-copy-value" })
        panel.recalculateKeyViewLoop()
        for _ in 0..<12 where panel.firstResponder !== copy {
            panel.selectNextKeyView(nil)
        }
        print("P57 preview key loop: copyEligible=\(copy.canBecomeKeyView), responder=\(String(describing: panel.firstResponder))")
        #expect(panel.firstResponder === copy, "Native Tab order must reach the preview's copy control")
        try #require(panel.firstResponder === copy)
        panel.sendEvent(try key(49, in: panel, characters: " "))
        await sidebarEventually { copy.accessibilityValue() as? String == "Copied" }
        #expect(copied == [sessionID] && pressed == 0)
        #expect(copy.accessibilityValue() as? String == "Copied")
        presenter.dismiss(restoreFocus: true)
        #expect(presenter.state.mode == .hidden)
        #expect(window.firstResponder === button)
        #expect(!window.isVisible && !panel.isVisible)
        print("P57 native keyboard: passive row focus -> Tab -> exact copy -> Copied; origin retained; host activations=0")
    }

    @Test func sharedNativeMenusKeepTargetsAndUnavailableActionsInert() async throws {
        let fixture = SidebarTreeFixtures()
        let navigation = SidebarNavigation()
        var selected: [SidebarNavigationTarget] = []
        var seen: [SidebarSeenTarget] = []
        navigation.update(topology: SidebarTopology(fixture.hierarchy()), connected: true,
                          workspaceAllowed: true, surfaceAllowed: true, perform: { selected.append($0) })
        let focus = SidebarRowAction.focus(
            .surface(workspaceID: fixture.workspaceA, surfaceID: fixture.surfaceA),
            navigation: navigation, prepareSeen: { target in { seen.append(target) } }, parentChat: true
        )
        let presenter = SidebarRowMenuPresenter()
        presenter.groups = [
            .init(title: "Navigation", actions: [focus]),
            .appearance(icon: nil, agent: true, child: true), .placement, .lifecycle(child: true)
        ]
        let menu = presenter.menu()
        #expect(menu.items.map(\.title) == ["Navigation", "Appearance", "Organization", "Lifecycle"])
        #expect(selected.isEmpty && seen.isEmpty && navigation.status == .idle)
        let command = try #require(menu.items[0].submenu?.items.first)
        #expect(command.title == "Open parent chat" && command.isEnabled)
        for group in menu.items.dropFirst() {
            for item in try #require(group.submenu).items {
                #expect(!item.isEnabled)
                presenter.invoke(item)
            }
        }
        #expect(selected.isEmpty && seen.isEmpty)
        presenter.invoke(command)
        await sidebarEventually { navigation.status == .selected }
        #expect(selected == [.surface(workspaceID: fixture.workspaceA, surfaceID: fixture.surfaceA)])
        #expect(seen == [.surface(workspaceID: fixture.workspaceA, surfaceID: fixture.surfaceA)])
        navigation.update(topology: SidebarTopology(fixture.hierarchy(moved: true)), connected: true,
                          workspaceAllowed: true, surfaceAllowed: true, perform: { selected.append($0) })
        presenter.invoke(command)
        #expect(navigation.status == .staleTarget)
        #expect(selected.count == 1 && seen.count == 1)
        let denied = SidebarRowAction.focus(.workspace(fixture.workspaceA), navigation: SidebarNavigation(),
                                          prepareSeen: { _ in { Issue.record("Denied menu cannot acknowledge") } })
        #expect(denied.unavailable != nil)
    }

    @Test func nativeContextBoundaryDistinguishesIconRowAndOutsideAndKeyboardUsesSameMenu() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        let anchor = SidebarRowMenuAnchorView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let icon = SidebarIconNativeButton()
        icon.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        let title = SidebarTitleNativeButton(frame: NSRect(x: 28, y: 0, width: 180, height: 24))
        root.addSubview(anchor)
        root.addSubview(icon)
        root.addSubview(title)
        window.contentView = root
        defer { anchor.detach(); window.contentView = nil; window.close() }
        let presenter = SidebarRowMenuPresenter()
        presenter.anchor = anchor
        anchor.presenter = presenter
        var presses = 0, menus = 0, icons = 0
        presenter.groups = [.init(title: "Navigation", actions: [.init(title: "Exact action", perform: { presses += 1 })])]
        presenter.present = { menu, _, _ in
            #expect(menu.items.first?.submenu?.items.first?.title == "Exact action")
            menus += 1
        }
        title.showActions = { presenter.show() }
        icon.activate = { icons += 1 }
        func event(_ point: NSPoint, type: NSEvent.EventType = .rightMouseDown,
                   flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 1))
        }
        #expect(!anchor.handles(try event(NSPoint(x: 10, y: 10))))
        #expect(anchor.handles(try event(NSPoint(x: 80, y: 10))))
        #expect(anchor.handles(try event(NSPoint(x: 80, y: 10), type: .leftMouseDown, flags: .control)))
        #expect(!anchor.handles(try event(NSPoint(x: 260, y: 10))))
        #expect(!anchor.handles(try event(NSPoint(x: 80, y: 10), type: .leftMouseDown)))
        icon.rightMouseDown(with: try event(NSPoint(x: 10, y: 10)))
        #expect(icons == 1 && menus == 0 && presses == 0)
        presenter.show()
        title.keyDown(with: try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 109
        )))
        #expect(menus == 2 && presses == 0 && icons == 1)
        #expect(!window.isVisible)
    }

    @Test func realHostedWorkspaceNameHasNoTrackingOverBlankFillOrControls() async throws {
        for text in ["Short", String(repeating: "Long workspace ", count: 12)] {
            let content = HStack(spacing: 5) {
                Button("Disclosure") {}
                SidebarHoverRegion(data: .init(id: "workspace", category: "Workspace", title: text), nameOnly: true) {
                    SidebarTitleButton(label: text, hint: text, action: { Issue.record("Passive render must not press") }) {
                        HStack {
                            Text(text).font(.caption).lineLimit(1).sidebarNameHover()
                            Spacer(minLength: 0)
                        }
                    }
                }
                Button("Actions") {}
            }.frame(width: 280)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 40),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: content)
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
            let name = try #require(descendants(host).compactMap { $0 as? SidebarHoverAnchorView }.first)
            let button = try #require(descendants(host).compactMap { $0 as? SidebarTitleNativeButton }.first)
            let textRect = host.convert(name.bounds, from: name)
            let buttonRect = host.convert(button.bounds, from: button)
            #expect(buttonRect.contains(textRect))
            #expect(textRect.width > 0 && textRect.width <= buttonRect.width)
            if text == "Short" { #expect(textRect.width < buttonRect.width - 10) }
            #expect(textRect.minX > 0 && textRect.maxX < 280)
            #expect(!window.isVisible)
        }
    }

    @Test func nativeNameTrackingCancelsPendingAndVisiblePreviewAtItsBoundary() async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        let anchor = SidebarHoverAnchorView(frame: NSRect(x: 24, y: 340, width: 90, height: 14))
        root.addSubview(anchor)
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        let presenter = SidebarHoverPresenter(showPanel: { _, _, _ in })
        anchor.presenter = presenter
        anchor.tracksName = true
        presenter.update(anchor: anchor, data: .init(id: "name", category: "Workspace", title: "Long workspace name"),
                         group: SidebarHoverGroup())
        let event = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        for _ in 0..<3 {
            anchor.mouseEntered(with: event)
            anchor.mouseExited(with: event)
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(presenter.state.mode == .hidden && presenter.panel == nil)
        anchor.mouseEntered(with: event)
        await sidebarEventually { presenter.state.mode == .hover }
        #expect(presenter.state.mode == .hover)
        anchor.mouseExited(with: event)
        #expect(presenter.state.mode == .hidden)
        #expect(!presenter.isMonitoring)
        #expect(anchor.hitTest(NSPoint(x: 25, y: 345)) == nil, "Tracking must not intercept name activation")
        #expect(anchor.bounds.width == 90, "Blank name fill and adjacent controls are outside the tracking area")
        presenter.detach()
    }

    @Test func nativeKeyboardPreviewDoesNotPressTitleAndTabEntersControls() throws {
        let button = SidebarTitleNativeButton(frame: NSRect(x: 0, y: 0, width: 140, height: 24))
        var activations = 0, entries = 0, dismissals = 0
        button.activate = { activations += 1 }
        button.preview = .init(focus: { _ in }, enter: { entries += 1; return true }, dismiss: { dismissals += 1 })
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                         isARepeat: false, keyCode: code))
        }
        button.keyDown(with: try key(48))
        #expect(entries == 1 && activations == 0)
        button.keyDown(with: try key(53))
        #expect(dismissals == 1 && activations == 0)
        button.keyDown(with: try key(36))
        #expect(activations == 1 && dismissals == 2)
        button.keyDown(with: try key(49))
        #expect(activations == 2)
    }

    @Test func pointerTravelAndExplicitDismissalHaveSeparateState() {
        var state = SidebarHoverState()
        #expect(!state.shouldOpen)
        state.anchor(true)
        #expect(state.shouldOpen)
        state.open(explicit: false)
        state.anchor(false)
        #expect(state.shouldClose)
        state.card(true)
        #expect(!state.shouldClose)
        state.card(false)
        #expect(state.shouldClose)
        state.dismiss()
        #expect(state.mode == .hidden)
        state.anchor(true)
        state.open(explicit: true)
        state.anchor(false)
        state.card(false)
        #expect(!state.shouldClose)
        state.anchor(true)
        state.dismiss()
        #expect(!state.shouldOpen)
        state.anchor(false)
        state.anchor(true)
        #expect(state.shouldOpen)
    }

    @Test func leavingOrDetachingCancelsPendingHover() async throws {
        let presenter = SidebarHoverPresenter()
        presenter.hoverAnchor(true)
        presenter.hoverAnchor(false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(presenter.panel == nil && presenter.state.mode == .hidden)
        presenter.hoverAnchor(true)
        presenter.detach()
        try await Task.sleep(for: .milliseconds(400))
        #expect(presenter.panel == nil && presenter.state.mode == .hidden)
    }

    @Test func hoverPanelsCannotBecomeKeyOrMainUnlessExplicitlyRequested() {
        let panel = SidebarHoverPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        panel.allowsKeyboard = true
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.isVisible)
    }

    @Test func losingPanelFocusOrApplicationActivationReleasesPreviewOwnership() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        window.contentView = anchor
        defer { window.contentView = nil; window.close() }
        let group = SidebarHoverGroup()
        for notification in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            let presenter = SidebarHoverPresenter(showPanel: { _, _, _ in })
            presenter.update(anchor: anchor, data: .init(id: "one", category: "Preview", title: "One"), group: group)
            let original = window.firstResponder
            presenter.open(explicit: true)
            #expect(presenter.state.mode == .explicit)
            #expect(presenter.isMonitoring)
            let panel = try #require(presenter.panel)
            #expect(!panel.isVisible && !window.isVisible)
            let other = SidebarHoverPresenter(showPanel: { _, _, _ in })
            #expect(!group.claim(other, explicit: false))
            NotificationCenter.default.post(
                name: notification,
                object: notification == NSWindow.didResignKeyNotification ? panel : NSApp
            )
            #expect(presenter.state.mode == .hidden)
            #expect(!presenter.isMonitoring && panel.contentView == nil)
            #expect(window.firstResponder === original)
            #expect(group.claim(other, explicit: false))
        }
    }

    @Test func placementFitsScreenEdgesAndShortAvailableSpace() {
        for visible in [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: -1440, y: 70, width: 1440, height: 830),
            CGRect(x: 100, y: 100, width: 240, height: 180)
        ] {
            for anchor in [
                CGRect(x: visible.minX + 10, y: visible.maxY - 40, width: 180, height: 24),
                CGRect(x: visible.maxX - 190, y: visible.minY + 10, width: 180, height: 24),
                CGRect(x: visible.midX, y: visible.midY, width: 24, height: 24)
            ] {
                let frame = SidebarHoverPlacement.frame(anchor: anchor, visible: visible,
                                                       preferred: CGSize(width: 300, height: 360))
                #expect(visible.contains(frame))
                #expect(frame.width <= 300 && frame.height <= 360)
            }
        }
        let right = SidebarHoverPlacement.frame(
            anchor: CGRect(x: 20, y: 400, width: 180, height: 24),
            visible: CGRect(x: 0, y: 0, width: 1400, height: 900),
            preferred: CGSize(width: 300, height: 260)
        )
        #expect(right.minX == 206)
    }

    @Test func workspaceCardsUseExactIdentityAndGrantedCurrentMetadata() throws {
        let fixtures = SidebarTreeFixtures()
        let original = fixtures.hierarchy()
        let a = try #require(SidebarHoverContent.workspace(fixtures.workspaceA, hierarchy: original, connected: true))
        let b = try #require(SidebarHoverContent.workspace(fixtures.workspaceB, hierarchy: original, connected: true))
        #expect(a.id != b.id && a.title == b.title)
        #expect(a.category == "Workspace preview")
        #expect(a.lines.contains(.init(title: "Shared surfaces", value: "1 terminal")))
        #expect(a.lines.contains(.init(title: "Workspace ID", value: fixtures.workspaceA.uuidString)))
        #expect(!a.lines.contains { $0.title.contains("Agent") || $0.title.contains("Pet") })
        #expect(SidebarHoverContent.workspace(fixtures.workspaceA, hierarchy: original, connected: false) == nil)
        #expect(SidebarHoverContent.workspace(UUID(), hierarchy: original, connected: true) == nil)
        let denied = try #require(SidebarHoverContent.workspace(
            fixtures.workspaceA, hierarchy: fixtures.hierarchy(granted: false), connected: true
        ))
        #expect(denied.lines.isEmpty && denied.notice == "Workspace metadata unavailable")
        let ambiguous = try #require(SidebarHoverContent.workspace(
            fixtures.workspaceA, hierarchy: fixtures.hierarchy(duplicateSurface: true), connected: true
        ))
        #expect(ambiguous.lines.contains(.init(title: "Shared surfaces", value: "Count unavailable; placement is ambiguous")))
        let moved = try #require(SidebarHoverContent.workspace(
            fixtures.workspaceA, hierarchy: fixtures.hierarchy(moved: true), connected: true
        ))
        #expect(moved.lines.contains(.init(title: "Shared surfaces", value: "None")))
    }

    @Test func passiveComponentsHaveNoNavigationOrPreferenceMutationDependencies() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("CMUXMaestroSidebar/UI/SidebarHoverCard.swift"), encoding: .utf8)
        for forbidden in ["SidebarNavigation", "SidebarPreferences", "SidebarSeen", "UserDefaults", "context.host", "markSeen", "acknowledge"] {
            #expect(!source.contains(forbidden))
        }
        #expect(source.contains(".nonactivatingPanel"))
        #expect(source.contains("override var canBecomeMain: Bool { false }"))
    }

    @Test(arguments: [false, true])
    func renderWorkspaceCardWithoutClippingOrSideEffects(dark: Bool) async throws {
        let fixture = try SidebarPreferenceFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences()
        let before = (preferences.history, preferences.attention, preferences.layout, preferences.icons)
        let data = SidebarHoverCardData(
            id: "synthetic-workspace", category: "Workspace preview",
            title: "Maestro design", subtitle: "Sidebar and personalization",
            lines: [
                .init(title: "Shared surfaces", value: "3 terminal, 1 browser"),
                .init(title: "Workspace path", value: "/synthetic/repository/with/a/long/path/that/must/wrap/without/clipping"),
                .init(title: "Project path", value: "Path unavailable"),
                .init(title: "Workspace ID", value: UUID().uuidString)
            ]
        )
        for size in [NSSize(width: 300, height: 360), NSSize(width: 224, height: 164)] {
            let frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: SidebarHoverCard(data: data, close: {
                Issue.record("Rendering must not dismiss the card")
            }, copySessionID: { _ in
                Issue.record("Rendering must not copy")
                return false
            }).environment(\.colorScheme, dark ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            hosting.frame = frame
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
            #expect(!window.isVisible)
            let metrics = SidebarRenderingEvidence.metrics(for: hosting)
            #expect(metrics.documentWidth <= metrics.viewportWidth + 0.5)
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/layout-validation/offscreen")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let image = root.appendingPathComponent("hover-workspace-\(Int(size.width))-\(dark ? "dark" : "light").png")
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
            let text = try SidebarRenderingEvidence.recognizedLines(in: image, dark: dark, naturalLanguage: true).joined(separator: " ")
            #expect(text.contains("Maestro design"))
            #expect(text.contains("Preview only"))
        }
        #expect(preferences.history == before.0 && preferences.attention == before.1)
        #expect(preferences.layout == before.2 && preferences.icons == before.3)
    }
}
