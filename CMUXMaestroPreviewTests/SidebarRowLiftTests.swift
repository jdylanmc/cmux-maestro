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
        print("row-lift115 unhidden-title: responderIsTitle=\(window.firstResponder === title), responder=\(String(describing: window.firstResponder)), controlRect=\(anchor.convert(title.bounds, from: title)), rowBounds=\(anchor.bounds), visible=\(anchor.visibleRect)")
        // Showing a hidden control need not restore the responder AppKit resigned.
        try #require(window.makeFirstResponder(title))
        try #require(window.firstResponder === title)
        anchor.refreshKeyboardFocus()
        try #require(anchor.keyboardFocused)
        title.frame.origin.x = 150
        try #require(window.firstResponder === title)
        try #require(!anchor.bounds.contains(anchor.convert(title.bounds, from: title)))
        anchor.refreshKeyboardFocus()
        #expect(!anchor.keyboardFocused, "Partially overlapping controls are not contained by this row")
        title.frame.origin.x = 20
        try #require(window.firstResponder === title)
        try #require(anchor.bounds.contains(anchor.convert(title.bounds, from: title)))
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

    @Test(arguments: [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown])
    func explicitControlFocusSurvivesTokenHandoffButNotPointerSelection(_ pointerType: NSEvent.EventType) throws {
        let window = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentLayoutRect)
        let anchor = SidebarRowMenuAnchorView(frame: NSRect(x: 0, y: 0, width: 200, height: 46))
        let unrelated = SidebarTitleNativeButton(frame: NSRect(x: 20, y: 70, width: 100, height: 30))
        let presenter = SidebarRowMenuPresenter()
        presenter.liftEligible = true
        presenter.anchor = anchor
        anchor.presenter = presenter
        var transitions: [Bool] = []
        presenter.liftFocusChanged = { transitions.append($0) }
        root.addSubview(anchor)
        root.addSubview(unrelated)
        window.contentView = root
        defer { anchor.detach(); window.contentView = nil; window.close() }
        try #require(window.makeFirstResponder(unrelated))
        anchor.observeInput(try keyEvent(window))
        #expect(!anchor.keyboardFocused, "Native responder geometry alone cannot explain this row's focus")
        let disclosure = UUID(), overflow = UUID()
        presenter.controlFocusChanged(disclosure, focused: true)
        #expect(anchor.keyboardFocused && transitions == [true])
        presenter.controlFocusChanged(overflow, focused: true)
        presenter.controlFocusChanged(disclosure, focused: false)
        presenter.controlFocusChanged(disclosure, focused: false)
        #expect(presenter.focusedControls == [overflow])
        #expect(anchor.keyboardFocused && transitions == [true],
                "Removing a disappearing control must not clear a different control's focus")

        anchor.observeInput(try pointerEvent(window, type: pointerType, point: NSPoint(x: 280, y: 110)))
        #expect(!anchor.keyboardFocused && !anchor.keyboardInteraction)
        #expect(presenter.focusedControls == [overflow], "Pointer modality, not invented focus mutation, clears the lift")
        anchor.refreshKeyboardFocus()
        #expect(transitions == [true, false])
        #expect(window.firstResponder === unrelated)
        anchor.observeInput(try keyEvent(window))
        #expect(anchor.keyboardFocused && transitions == [true, false, true])
        presenter.controlFocusChanged(overflow, focused: false)
        #expect(!anchor.keyboardFocused && presenter.focusedControls.isEmpty)
        #expect(transitions == [true, false, true, false])
        #expect(window.firstResponder === unrelated && !window.isVisible)
    }

    @Test func explicitControlFocusHonorsEligibilityWindowVisibilityAndDetach() throws {
        let window = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        let foreign = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        foreign.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentLayoutRect)
        root.clipsToBounds = true
        let frame = NSRect(x: 0, y: 0, width: 200, height: 46)
        let anchor = SidebarRowMenuAnchorView(frame: frame)
        let presenter = SidebarRowMenuPresenter()
        presenter.anchor = anchor
        anchor.presenter = presenter
        root.addSubview(anchor)
        window.contentView = root
        defer { anchor.detach(); window.contentView = nil; window.close(); foreign.close() }
        let control = UUID()
        presenter.controlFocusChanged(control, focused: true)
        anchor.observeInput(try keyEvent(window))
        #expect(!anchor.keyboardFocused && !anchor.keyboardInteraction, "Explicit focus cannot opt an excluded row in")
        presenter.liftEligible = true
        anchor.observeInput(try keyEvent(foreign))
        #expect(!anchor.keyboardFocused && !anchor.keyboardInteraction)
        anchor.observeInput(try keyEvent(window))
        try #require(anchor.keyboardFocused)
        anchor.observeInput(try pointerEvent(foreign, point: .zero))
        #expect(anchor.keyboardFocused, "Only this window's pointer changes this row's input modality")
        window.reportsKeyState = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!anchor.keyboardFocused && presenter.focusedControls == [control])
        window.reportsKeyState = true
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        try #require(anchor.keyboardFocused)
        let originalBounds = anchor.bounds
        anchor.frame = .zero
        anchor.refreshKeyboardFocus()
        #expect(anchor.frame.isEmpty && !anchor.keyboardFocused)
        #expect(presenter.focusedControls == [control], "Zero frame suppresses decoration, not the control's focus token")
        anchor.frame = frame
        try #require(anchor.bounds == originalBounds)
        anchor.refreshKeyboardFocus()
        try #require(anchor.keyboardFocused)

        anchor.bounds = .zero
        anchor.refreshKeyboardFocus()
        #expect(anchor.bounds.isEmpty && !anchor.keyboardFocused)
        #expect(presenter.focusedControls == [control])
        anchor.bounds = originalBounds
        try #require(anchor.frame == frame)
        anchor.refreshKeyboardFocus()
        try #require(anchor.keyboardFocused)

        root.isHidden = true
        anchor.refreshKeyboardFocus()
        #expect(anchor.isHiddenOrHasHiddenAncestor && !anchor.keyboardFocused)
        #expect(presenter.focusedControls == [control])
        root.isHidden = false
        try #require(!anchor.isHiddenOrHasHiddenAncestor && anchor.window === window)
        anchor.refreshKeyboardFocus()
        try #require(anchor.keyboardFocused)

        // Clip through the ancestor without changing the row's own coordinate space or attachment.
        anchor.setFrameOrigin(NSPoint(x: root.bounds.maxX + 1, y: frame.minY))
        try #require(!root.bounds.intersects(root.convert(anchor.bounds, from: anchor)))
        try #require(anchor.bounds == originalBounds && anchor.window === window && anchor.presenter === presenter)
        try #require(anchor.visibleRect.isEmpty)
        print("row-lift115 clipped-row: parent=\(root.bounds), rowInParent=\(root.convert(anchor.bounds, from: anchor)), rowBounds=\(anchor.bounds), visible=\(anchor.visibleRect), clips=\(root.clipsToBounds)")
        anchor.refreshKeyboardFocus()
        #expect(!anchor.keyboardFocused && presenter.focusedControls == [control])
        anchor.frame = frame
        try #require(!anchor.visibleRect.isEmpty && anchor.bounds == originalBounds)
        anchor.refreshKeyboardFocus()
        try #require(anchor.keyboardFocused)
        presenter.liftEligible = false
        anchor.refreshKeyboardFocus()
        #expect(!anchor.keyboardFocused)
        anchor.detach()
        #expect(presenter.focusedControls.isEmpty && presenter.anchor == nil && anchor.presenter == nil)
        #expect(!anchor.keyboardInteraction && !anchor.keyboardFocused)
        #expect(!window.isVisible && !foreign.isVisible)
    }

    @Test(arguments: [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown], FocusTarget.allCases)
    func pointerDuringIneligibilityCannotReviveKeyboardLift(
        _ pointerType: NSEvent.EventType, focusTarget: FocusTarget
    ) throws {
        let window = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        let foreign = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        foreign.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentLayoutRect)
        let anchor = SidebarRowMenuAnchorView(frame: NSRect(x: 0, y: 0, width: 240, height: 46))
        let title = SidebarTitleNativeButton(frame: NSRect(x: 40, y: 8, width: 180, height: 30))
        let icon = SidebarIconNativeButton()
        icon.frame = NSRect(x: 8, y: 10, width: 24, height: 24)
        let unrelated = SidebarTitleNativeButton(frame: NSRect(x: 40, y: 70, width: 180, height: 30))
        let presenter = SidebarRowMenuPresenter()
        presenter.liftEligible = true
        presenter.anchor = anchor
        anchor.presenter = presenter
        let views: [NSView] = [anchor, title, icon, unrelated]
        for view in views { root.addSubview(view) }
        window.contentView = root
        defer { anchor.detach(); window.contentView = nil; window.close(); foreign.close() }
        let frames = root.subviews.map(\.frame)
        let control: NSView
        switch focusTarget {
        case .title: control = title
        case .icon: control = icon
        case .explicit: control = unrelated
        }
        try #require(window.makeFirstResponder(control))
        let token = UUID()
        if focusTarget == .explicit { presenter.controlFocusChanged(token, focused: true) }
        let tokens = presenter.focusedControls
        anchor.observeInput(try keyEvent(window))
        try #require(anchor.keyboardFocused && window.firstResponder === control)
        presenter.liftEligible = false
        anchor.refreshKeyboardFocus()
        #expect(!anchor.keyboardFocused)
        let ineligibleModality = anchor.keyboardInteraction
        anchor.observeInput(try keyEvent(foreign))
        anchor.observeInput(try pointerEvent(foreign, type: pointerType, point: .zero))
        #expect(!anchor.keyboardFocused && anchor.keyboardInteraction == ineligibleModality,
                "Foreign input cannot change this row's remembered modality")
        anchor.observeInput(try pointerEvent(window, type: pointerType, point: NSPoint(x: 280, y: 110)))
        #expect(!anchor.keyboardFocused && !anchor.keyboardInteraction)
        presenter.liftEligible = true
        anchor.refreshKeyboardFocus()
        #expect(!anchor.keyboardFocused && !anchor.keyboardInteraction,
                "Reusing the same row cannot restore pre-pointer keyboard modality")
        anchor.observeInput(try keyEvent(foreign))
        #expect(!anchor.keyboardFocused)
        anchor.observeInput(try keyEvent(window))
        #expect(anchor.keyboardFocused, "Only fresh same-window keyboard input restores the lift")
        anchor.observeInput(try pointerEvent(foreign, type: pointerType, point: .zero))
        #expect(anchor.keyboardFocused)
        #expect(window.firstResponder === control && presenter.focusedControls == tokens)
        #expect(anchor.presenter === presenter && presenter.anchor === anchor)
        #expect(root.subviews.map(\.frame) == frames && !window.isVisible && !foreign.isVisible)
    }

    @Test(arguments: [false, true], [false, true])
    func windowInputBroadcastPrecedesSiblingContextHandling(reverseOrder: Bool, controlClick: Bool) throws {
        let (window, root) = inputWindow()
        let (foreign, foreignRoot) = inputWindow()
        let rows = [InputRow(y: 100), InputRow(y: 20)]
        let foreignRow = InputRow(y: 20)
        for row in reverseOrder ? Array(rows.reversed()) : rows { row.attach(to: root) }
        foreignRow.attach(to: foreignRoot)
        defer {
            for row in rows + [foreignRow] { row.detach() }
            window.contentView = nil; foreign.contentView = nil
            window.close(); foreign.close()
        }
        try #require(foreign.makeFirstResponder(foreignRow.title))
        foreignRow.anchor.observeInput(try keyEvent(foreign))
        try #require(foreignRow.anchor.keyboardFocused)
        let pointerType: NSEvent.EventType = controlClick ? .leftMouseDown : .rightMouseDown
        let modifiers: NSEvent.ModifierFlags = controlClick ? [.control] : []
        for focusedIndex in rows.indices {
            let focused = rows[focusedIndex], other = rows[1 - focusedIndex]
            for menuEligible in [true, false] {
                focused.presenter.liftEligible = true
                other.presenter.liftEligible = menuEligible
                try #require(window.makeFirstResponder(focused.title))
                focused.anchor.observeInput(try keyEvent(window))
                try #require(focused.anchor.keyboardFocused)
                other.anchor.observeInput(try pointerEvent(foreign, type: pointerType, point: .zero))
                #expect(focused.anchor.keyboardFocused && foreignRow.anchor.keyboardFocused)
                let point = NSPoint(x: 245, y: other.anchor.frame.midY)
                let event = try pointerEvent(window, type: pointerType, point: point, modifiers: modifiers)
                other.anchor.observeInput(event)
                #expect(rows.allSatisfy { !$0.anchor.keyboardInteraction && !$0.anchor.keyboardFocused },
                        "Every same-window row must see pointer input before another row handles a context menu")
                try #require(other.anchor.handles(event))
                var presentations = 0
                other.presenter.present = { _, _, _ in
                    presentations += 1
                    #expect(!focused.anchor.keyboardFocused && window.firstResponder === focused.title)
                }
                other.presenter.show()
                #expect(presentations == 1)
                focused.anchor.observeInput(event)
                #expect(!focused.anchor.keyboardFocused && foreignRow.anchor.keyboardFocused)
                #expect(window.firstResponder === focused.title)

                focused.anchor.observeInput(try keyEvent(window))
                let iconPoint = root.convert(NSPoint(x: other.icon.bounds.midX, y: other.icon.bounds.midY), from: other.icon)
                let iconEvent = try pointerEvent(window, type: pointerType, point: iconPoint, modifiers: modifiers)
                other.anchor.observeInput(iconEvent)
                #expect(!other.anchor.handles(iconEvent), "Icon secondary-click remains owned by its existing picker route")
                #expect(!focused.anchor.keyboardFocused && foreignRow.anchor.keyboardFocused)
            }
        }
        #expect(!window.isVisible && !foreign.isVisible)
    }

    @Test(arguments: [
        NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseUp, .rightMouseUp, .otherMouseUp, .keyDown, .keyUp
    ], MenuBoundary.allCases)
    func trackedMenuCompletionReconcilesOnlyItsOwner(_ eventType: NSEvent.EventType, boundary: MenuBoundary) throws {
        let (window, root) = inputWindow()
        let (foreign, foreignRoot) = inputWindow()
        let row = InputRow(y: 100), sibling = InputRow(y: 20), foreignRow = InputRow(y: 20)
        for owned in [row, sibling] { owned.attach(to: root) }
        foreignRow.attach(to: foreignRoot)
        defer {
            for owned in [row, sibling, foreignRow] { owned.detach() }
            window.contentView = nil; foreign.contentView = nil
            window.close(); foreign.close()
        }
        try #require(window.makeFirstResponder(row.title))
        try #require(foreign.makeFirstResponder(foreignRow.title))
        row.anchor.observeInput(try keyEvent(window))
        foreignRow.anchor.observeInput(try keyEvent(foreign))
        try #require(row.anchor.keyboardFocused && foreignRow.anchor.keyboardFocused)
        let keyboardReturn = eventType == .keyDown || eventType == .keyUp
        var sampled: NSEvent?
        var presentations = 0, actions = 0
        row.presenter.currentMenuEvent = { sampled }
        row.presenter.groups = [.init(title: "Navigation", actions: [
            .init(title: "Non-focusing action", perform: {
                actions += 1
                #expect(row.anchor.keyboardFocused == keyboardReturn,
                        "Input reconciliation must precede the unchanged action")
            })
        ])]
        row.presenter.present = { menu, _, _ in
            presentations += 1
            // Owner-window sampler evidence only; actual nil/menu-window event ownership is not inferred.
            sampled = sampledMenuEvent(eventType, window: window, timestamp: ProcessInfo.processInfo.systemUptime)
            guard sampled != nil else { Issue.record("Expected a native menu input event"); return }
            #expect(sampled?.window === window)
            switch boundary {
            case .close:
                row.presenter.menuDidClose(menu)
            case .action:
                guard let item = menu.items.first?.submenu?.items.first else {
                    Issue.record("Expected the actual presented menu action")
                    return
                }
                row.presenter.invoke(item)
            case .return:
                #expect(row.anchor.keyboardFocused, "Return reconciliation must not happen before the boundary")
            }
            if boundary != .return { #expect(row.anchor.keyboardFocused == keyboardReturn) }
        }
        row.presenter.show()
        #expect(presentations == 1 && sampled != nil)
        #expect(actions == (boundary == .action ? 1 : 0))
        #expect(row.anchor.keyboardFocused == keyboardReturn && row.anchor.keyboardInteraction == keyboardReturn)
        #expect(sibling.anchor.keyboardInteraction == keyboardReturn && !sibling.anchor.keyboardFocused)
        #expect(foreignRow.anchor.keyboardFocused, "Owner-window menu input cannot alter an unrelated window")
        #expect(window.firstResponder === row.title && foreign.firstResponder === foreignRow.title)
        #expect(row.title.focusRingType == .exterior && !window.isVisible && !foreign.isVisible)
    }

    @Test func menuSamplingRejectsStaleWrongMenuEndedAndDetachedLifetimes() throws {
        let (window, root) = inputWindow()
        let (foreign, foreignRoot) = inputWindow()
        let row = InputRow(y: 100), sibling = InputRow(y: 20), foreignRow = InputRow(y: 20)
        for owned in [row, sibling] { owned.attach(to: root) }
        foreignRow.attach(to: foreignRoot)
        defer {
            for owned in [row, sibling, foreignRow] { owned.detach() }
            window.contentView = nil; foreign.contentView = nil
            window.close(); foreign.close()
        }
        try #require(window.makeFirstResponder(row.title))
        try #require(foreign.makeFirstResponder(foreignRow.title))
        row.anchor.observeInput(try keyEvent(window))
        foreignRow.anchor.observeInput(try keyEvent(foreign))
        var sampled: NSEvent?
        var reads = 0
        var completedMenu: NSMenu?
        row.presenter.currentMenuEvent = { reads += 1; return sampled }
        row.presenter.present = { menu, _, _ in
            completedMenu = menu
            sampled = sampledMenuEvent(.leftMouseUp, window: foreign, timestamp: ProcessInfo.processInfo.systemUptime)
            guard sampled != nil else { Issue.record("Expected a current event"); return }
            #expect(sampled?.window === foreign)
            row.presenter.menuDidClose(NSMenu(title: "Unrelated menu"))
            #expect(reads == 0 && row.anchor.keyboardFocused)
            row.presenter.menuDidClose(menu)
            #expect(row.anchor.keyboardFocused && foreignRow.anchor.keyboardFocused,
                    "A newer event from an ordinary foreign window is not evidence of this menu's input")
            sampled = sampledMenuEvent(.leftMouseUp, window: window, timestamp: 0)
            guard sampled != nil else { Issue.record("Expected a stale event"); return }
            row.presenter.menuDidClose(menu)
            #expect(row.anchor.keyboardFocused && foreignRow.anchor.keyboardFocused)
        }
        row.presenter.show()
        let oldMenu = try #require(completedMenu)
        let readsAfterReturn = reads
        sampled = try #require(sampledMenuEvent(.leftMouseUp, window: window, timestamp: ProcessInfo.processInfo.systemUptime))
        row.presenter.menuDidClose(oldMenu)
        #expect(reads == readsAfterReturn && row.anchor.keyboardFocused)

        foreignRow.presenter.currentMenuEvent = { sampled }
        foreignRow.presenter.present = { menu, _, _ in
            sampled = sampledMenuEvent(.rightMouseUp, window: foreign, timestamp: ProcessInfo.processInfo.systemUptime)
            guard sampled != nil else { Issue.record("Expected a different owner's current event"); return }
            row.presenter.menuDidClose(oldMenu)
            #expect(row.anchor.keyboardFocused && foreignRow.anchor.keyboardFocused && reads == readsAfterReturn)
            foreignRow.presenter.menuDidClose(menu)
            #expect(row.anchor.keyboardFocused && !foreignRow.anchor.keyboardFocused)
        }
        foreignRow.presenter.show()
        #expect(row.anchor.keyboardFocused && !foreignRow.anchor.keyboardFocused)

        row.presenter.present = { menu, _, _ in
            row.anchor.detach()
            #expect(window.makeFirstResponder(sibling.title))
            guard let keyboard = sampledMenuEvent(.keyDown, window: window, timestamp: ProcessInfo.processInfo.systemUptime) else {
                Issue.record("Expected fresh sibling keyboard input")
                return
            }
            sibling.anchor.observeInput(keyboard)
            #expect(sibling.anchor.keyboardFocused)
            sampled = sampledMenuEvent(.leftMouseUp, window: window, timestamp: ProcessInfo.processInfo.systemUptime)
            guard sampled != nil else { Issue.record("Expected post-detach pointer input"); return }
            let readsBeforeClose = reads
            row.presenter.menuDidClose(menu)
            #expect(reads == readsBeforeClose && sibling.anchor.keyboardFocused)
        }
        row.presenter.show()
        #expect(row.anchor.presenter == nil && row.presenter.anchor == nil)
        #expect(sibling.anchor.keyboardFocused && window.firstResponder === sibling.title)
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
            let captureName = "\(appearance.rawValue)-\(width)-\(density.rawValue)"
            try save(rest, name: "\(captureName)-rest")
            let lanePoints = anchors.map { anchor in
                let rect = mounted.host.convert(anchor.bounds, from: anchor)
                return NSPoint(x: rect.minX + 2, y: rect.midY)
            }
            let laneColors = try lanePoints.map { try pixel(rest, at: $0, bounds: mounted.host.bounds) }
            let eligible = anchors.filter { $0.presenter?.liftEligible == true }
            try #require(!eligible.isEmpty)
            for anchor in anchors { anchor.presenter?.hoverChanged(true) }
            await Task.yield()
            mounted.host.layoutSubtreeIfNeeded()
            let lifted = try capture(mounted.host)
            try save(lifted, name: "\(captureName)-lift")
            #expect(differences(rest, lifted) > 0, "The production callback must change the rendered surface")
            #expect(titles(mounted.host).map(ObjectIdentifier.init) == controls.map(ObjectIdentifier.init))
            #expect(descendants(mounted.host).compactMap { $0 as? SidebarRowMenuAnchorView }.map(ObjectIdentifier.init)
                == anchors.map(ObjectIdentifier.init))
            for (index, anchor) in anchors.enumerated() {
                let before = laneColors[index]
                let after = try pixel(lifted, at: lanePoints[index], bounds: mounted.host.bounds)
                #expect(before.alphaComponent == 1 && after.alphaComponent == 1,
                        "Decoration cannot erase the opaque underlying selected/activity/window background")
                if anchor.presenter?.liftEligible == true {
                    if appearance == .dark || appearance == .darkContrast {
                        #expect(after.redComponent + after.greenComponent + after.blueComponent
                            > before.redComponent + before.greenComponent + before.blueComponent,
                                "The blank leading lane of each eligible row must lighten, not merely reveal overflow")
                    }
                } else {
                    #expect(before == after, "Excluded header/activity/utility interiors must remain unchanged")
                }
            }
            #expect(controls.map { mounted.host.convert($0.bounds, from: $0) } == beforeFrames)
            #expect(iconControls.map { mounted.host.convert($0.bounds, from: $0) } == iconFrames)
            #expect(controls.allSatisfy { !$0.isBordered && $0.focusRingType == .exterior })
            #expect(iconControls.allSatisfy { !$0.isBordered && $0.focusRingType == .exterior })
            #expect(anchors.map { $0.presenter?.menu().items.map(\.title) } == menuBefore)
            for anchor in eligible { anchor.presenter?.hoverChanged(true) }
            await Task.yield()
            let repeated = try capture(mounted.host)
            try save(repeated, name: "\(captureName)-repeated")
            diagnoseDifference(lifted, repeated, phase: "\(captureName)-repeated", host: mounted.host, anchors: anchors)
            #expect(differences(lifted, repeated) == 0,
                    "Repeated hover input cannot add or restart another surface")
            for anchor in eligible {
                anchor.presenter?.liftFocusChanged(true)
                anchor.presenter?.hoverChanged(false)
            }
            await Task.yield()
            let keyboardOnly = try capture(mounted.host)
            try save(keyboardOnly, name: "\(captureName)-keyboard")
            diagnoseDifference(lifted, keyboardOnly, phase: "\(captureName)-keyboard", host: mounted.host, anchors: anchors)
            #expect(differences(lifted, keyboardOnly) == 0,
                    "Keyboard-only focus must retain the same row elevation after the pointer leaves")
            for anchor in eligible {
                anchor.presenter?.hoverChanged(true)
                anchor.presenter?.liftFocusChanged(false)
            }
            await Task.yield()
            let hoverOnly = try capture(mounted.host)
            try save(hoverOnly, name: "\(captureName)-hover-return")
            diagnoseDifference(lifted, hoverOnly, phase: "\(captureName)-hover-return", host: mounted.host, anchors: anchors)
            #expect(differences(lifted, hoverOnly) == 0,
                    "Losing keyboard focus while still hovered must not drop or double the lift")
            for anchor in anchors { anchor.presenter?.hoverChanged(false) }
            await Task.yield()
            mounted.host.layoutSubtreeIfNeeded()
            let restored = try capture(mounted.host)
            try save(restored, name: "\(captureName)-restored")
            diagnoseDifference(rest, restored, phase: "\(captureName)-restored", host: mounted.host, anchors: anchors)
            #expect(differences(rest, restored) == 0, "Leaving restores selected and resting appearance exactly")
            #expect(model.hierarchy == beforeHierarchy && model.copilot.tree == beforeTree)
            #expect(model.orchestration.snapshot == beforeManaged)
            #expect(preferences.layout == beforeLayout && preferences.history == beforeHistory)
            #expect(preferences.attention == beforeAttention && preferences.icons == beforeIcons)
            #expect(pinned(model, now: data.now) == beforePinned && model.navigation.status == .idle)
            #expect(!mounted.window.isVisible)
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

    @Test(arguments: Appearance.allCases)
    func staticSurfaceInteriorMatchesFourPercentSemanticReference(_ appearance: Appearance) throws {
        let frame = NSRect(x: 0, y: 0, width: 280, height: 100)
        let backgrounds: [(String, NSColor)] = [("black", .black), ("window", .windowBackgroundColor)]
        for (backgroundName, background) in backgrounds {
            // Independent literal acceptance reference, not the production opacity constant or shadow implementation.
            let variants: [(String, AnyView)] = [
                ("base", AnyView(Color.clear)),
                ("reference", AnyView(Rectangle().fill(Color(nsColor: .highlightColor).opacity(0.04)))),
                ("production", AnyView(SidebarRowLiftSurface(lifted: true)))
            ]
            var images: [String: NSBitmapImageRep] = [:]
            for (name, content) in variants {
                let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance.nativeName)
                let host = NSHostingView(rootView: content
                    .frame(width: 248, height: 46)
                    .frame(width: 280, height: 100)
                    .environment(\._accessibilityReduceMotion, true)
                    .environment(\._colorSchemeContrast, appearance.contrast)
                    .background(Color(nsColor: background)))
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.frame = frame
                host.layoutSubtreeIfNeeded()
                let bitmap = try capture(host)
                images[name] = bitmap
                try save(bitmap, name: "semantic-\(appearance.rawValue)-\(backgroundName)-\(name)")
                #expect(!window.isVisible && host.bounds == frame)
            }
            let base = try #require(images["base"])
            let reference = try #require(images["reference"])
            let production = try #require(images["production"])
            for y in [36.0, 50.0, 64.0] {
                for x in [64.0, 140.0, 216.0] {
                    let point = NSPoint(x: x, y: y)
                    let before = try pixel(base, at: point, bounds: frame)
                    let expected = try pixel(reference, at: point, bounds: frame)
                    let actual = try pixel(production, at: point, bounds: frame)
                    #expect(before.alphaComponent == 1 && expected.alphaComponent == 1 && actual.alphaComponent == 1,
                            "Baseline, independent reference and production must all preserve opaque backing")
                    let beforeRGBA = [before.redComponent, before.greenComponent, before.blueComponent, before.alphaComponent]
                    let expectedRGBA = [expected.redComponent, expected.greenComponent, expected.blueComponent, expected.alphaComponent]
                    let actualRGBA = [actual.redComponent, actual.greenComponent, actual.blueComponent, actual.alphaComponent]
                    print("row-lift115 semantic \(appearance.rawValue)-\(backgroundName) \(point): base=\(beforeRGBA), fourPercent=\(expectedRGBA), production=\(actualRGBA)")
                    if backgroundName == "black" {
                        #expect(beforeRGBA != expectedRGBA, "The independent reference must expose a nonzero highlight")
                    }
                    #expect(actualRGBA == expectedRGBA,
                            "The row interior must contain only the four-percent semantic highlight, not an opaque shadow source")
                }
            }
        }
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
        let hitParent = try #require(host.superview)
        // NSView.hitTest receives superview coordinates, not the flipped hosting view's coordinates.
        let hitPoints = points.map { host.convert($0, to: hitParent) }
        try #require(hitPoints.map { host.convert($0, from: hitParent) } == points)
        let hitTargets = hitPoints.map { host.hitTest($0).map(ObjectIdentifier.init) }
        print("row-lift115 short-hit \(width)x\(height): hostFlipped=\(host.isFlipped), parentFlipped=\(hitParent.isFlipped), title=\(titleFrame), icon=\(iconFrame), hostPoints=\(points), parentPoints=\(hitPoints), hits=\(hitTargets)")
        #expect(hitTargets[0] == ObjectIdentifier(title))
        #expect(hitTargets[1] == ObjectIdentifier(icon))
        for hovered in [true, true, false] {
            anchor.presenter?.hoverChanged(hovered)
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            #expect(host.convert(title.bounds, from: title) == titleFrame)
            #expect(host.convert(icon.bounds, from: icon) == iconFrame)
            #expect(host.convert(anchor.bounds, from: anchor) == rowFrame)
            #expect(host.superview === hitParent)
            #expect(hitPoints.map { host.hitTest($0).map(ObjectIdentifier.init) } == hitTargets,
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

    enum FocusTarget: CaseIterable, Equatable, Sendable {
        case title, icon, explicit
    }

    enum MenuBoundary: CaseIterable, Equatable, Sendable {
        case close, action, `return`
    }

    @MainActor
    private struct InputRow {
        let anchor: SidebarRowMenuAnchorView
        let presenter = SidebarRowMenuPresenter()
        let title: SidebarTitleNativeButton
        let icon = SidebarIconNativeButton()

        init(y: CGFloat) {
            anchor = SidebarRowMenuAnchorView(frame: NSRect(x: 0, y: y, width: 280, height: 46))
            title = SidebarTitleNativeButton(frame: NSRect(x: 40, y: y + 8, width: 180, height: 30))
            icon.frame = NSRect(x: 8, y: y + 10, width: 24, height: 24)
            presenter.liftEligible = true
            presenter.anchor = anchor
            presenter.currentMenuEvent = { nil }
            anchor.presenter = presenter
        }

        func attach(to root: NSView) {
            let views: [NSView] = [anchor, title, icon]
            for view in views { root.addSubview(view) }
        }

        func detach() {
            presenter.present = { _, _, _ in }
            presenter.currentMenuEvent = { nil }
            anchor.detach()
        }
    }

    private func inputWindow() -> (KeyboardWindow, NSView) {
        let window = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        return (window, root)
    }

    private func sampledMenuEvent(
        _ type: NSEvent.EventType, window: NSWindow, timestamp: TimeInterval
    ) -> NSEvent? {
        switch type {
        case .keyDown, .keyUp:
            return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: timestamp,
                                   windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: timestamp,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                     clickCount: 1, pressure: 1)
        default:
            Issue.record("Unsupported menu input fixture type")
            return nil
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
        _ window: NSWindow, type: NSEvent.EventType = .leftMouseDown, point: NSPoint,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0,
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
    private func diagnoseDifference(
        _ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep, phase: String,
        host: NSView, anchors: [SidebarRowMenuAnchorView]
    ) {
        let changed = differences(lhs, rhs)
        guard changed > 0 else { return }
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh,
              lhs.bitsPerPixel == rhs.bitsPerPixel, lhs.bitsPerPixel.isMultiple(of: 8),
              let left = lhs.bitmapData, let right = rhs.bitmapData else {
            Issue.record("Diagnostic captures require equal geometry and byte-aligned native storage")
            return
        }
        let bytesPerPixel = lhs.bitsPerPixel / 8
        var bounds = NSRect.null
        for y in 0..<lhs.pixelsHigh {
            for x in 0..<lhs.pixelsWide {
                if (0..<bytesPerPixel).contains(where: {
                    left[y * lhs.bytesPerRow + x * bytesPerPixel + $0]
                        != right[y * rhs.bytesPerRow + x * bytesPerPixel + $0]
                }) {
                    bounds = bounds.union(NSRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        print("row-lift115 \(phase): changedBytes=\(changed), bitmapBounds=\(bounds), bitmapSize=\(lhs.pixelsWide)x\(lhs.pixelsHigh), hostBounds=\(host.bounds), hostFlipped=\(host.isFlipped), key=\(host.window?.isKeyWindow == true), responder=\(String(describing: host.window?.firstResponder))")
        for (index, anchor) in anchors.enumerated() {
            print("row-lift115 \(phase) anchor[\(index)]: rect=\(host.convert(anchor.bounds, from: anchor)), eligible=\(anchor.presenter?.liftEligible == true), keyboardInput=\(anchor.keyboardInteraction), keyboardFocused=\(anchor.keyboardFocused), explicitControls=\(anchor.presenter?.focusedControls.count ?? 0)")
        }
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
